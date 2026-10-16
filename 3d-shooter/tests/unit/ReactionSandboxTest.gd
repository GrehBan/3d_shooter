extends GdUnitTestSuite
## M2.3b in the composition root: secondary hits reach the resolver's secondary signals and
## the kill repaint, never EffectRunner; Sandbox.logic_step guards (P3).

const SANDBOX: PackedScene = preload("res://world/sandbox/Sandbox.tscn")

var _scene: Sandbox
var _secondary_hits: int = 0


func after_test() -> void:
	if is_instance_valid(_scene):
		_scene.free()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _instantiate() -> void:
	_secondary_hits = 0
	_scene = SANDBOX.instantiate() as Sandbox
	(_scene.get_node(^"Player") as FPSController).hardware_input_enabled = false
	(_scene.get_node(^"Player/Camera3D/HitscanWeapon") as HitscanWeapon).hardware_input_enabled = false


func _load(definitions: Array[EffectRuleData] = []) -> void:
	_instantiate()
	_scene.effect_definitions = definitions
	add_child(_scene)


## Logic-side injection: the record a physics adapter would have published.
func _fire(primary: int, candidates: PackedInt64Array, raw: int, element: DamagePayload.Element) -> void:
	var ticket: int = _scene.shots.reserve(_scene.player_handle, 1, raw, element)
	_scene.shots.write_trace(ticket, 0, primary)
	for candidate: int in candidates:
		_scene.shots.add_candidate(ticket, 0, candidate)
	_scene.shots.publish(ticket)


func _count_secondary(_source: int, _target: int, _epoch: int, _sequence: int, _trace: int,
		_child: int, _damage: int) -> void:
	_secondary_hits += 1


func test_room_wires_reactions_teams_and_candidate_adapter() -> void:
	_load()
	var reactions: ReactionRuntime = _scene.combat.reactions
	assert_bool(reactions.uses_statuses(_scene.combat.statuses)).is_true()
	assert_int(reactions.team_of(_scene.player_handle)).is_equal(Sandbox.TEAM_PLAYER)
	for target: int in _scene.target_handles:
		assert_int(reactions.team_of(target)).is_equal(Sandbox.TEAM_HOSTILE)
	assert_object(_scene.weapon.reaction_candidates).is_not_null()
	assert_int(_scene.shots.candidate_capacity()).is_equal(_scene.combat.config.reaction_candidates)


func test_secondary_hits_reach_observers_but_never_effect_runner() -> void:
	var definitions: Array[EffectRuleData] = [preload("res://tests/fixtures/effects/count_hit.tres")]
	_load(definitions)
	var entry: int = _scene.effect_host.add_effect(_scene.player_handle,
			EffectTrigger.Trigger.ON_HIT, EffectTrigger.Phase.MAIN, 0, 0, 0, 0)
	_scene.resolver.on_secondary_hit.connect(_count_secondary)
	var targets: PackedInt64Array = _scene.target_handles
	_fire(targets[1], PackedInt64Array([targets[0], targets[2]]), 10000, DamagePayload.Element.ELECTRIC)
	_scene.logic_step(GameLoop.get_logic_tick() + 1)
	assert_int(_secondary_hits).is_equal(2)
	assert_int(_scene.combat.reactions.secondary_hits).is_equal(2)
	assert_int(_scene.effects.accepted_events).is_equal(1)  # the primary OnHit only
	assert_int(_scene.effects.counter_for(entry)).is_equal(1)
	assert_int(_scene.combat.stats.get_stat(targets[0], StatBlock.Stat.HP)).is_equal(95_000)


func test_secondary_kill_greys_target_in_the_next_frame() -> void:
	_load()
	var targets: PackedInt64Array = _scene.target_handles
	var mesh: MeshInstance3D = _scene.get_node(^"Targets").get_child(2).get_child(1) as MeshInstance3D
	_scene.combat.stats.set_stat(targets[2], StatBlock.Stat.HP, 1000)
	_fire(targets[1], PackedInt64Array([targets[2]]), 10000, DamagePayload.Element.ELECTRIC)
	_scene.logic_step(GameLoop.get_logic_tick() + 1)
	var after_logic: Material = mesh.material_override
	_scene.apply_dead_marks()
	assert_int(_scene.combat.reactions.secondary_kills).is_equal(1)
	assert_object(after_logic).is_null()
	assert_object(mesh.material_override).is_not_null()


func test_logic_step_is_guarded_before_load_after_abort_and_for_old_ticks() -> void:
	_instantiate()
	_scene.logic_step(1)  # not loaded yet: nothing to run, no crash
	assert_int(_scene.phase_steps()).is_equal(0)
	add_child(_scene)
	var tick: int = GameLoop.get_logic_tick() + 10
	_scene.reset_phase_metrics()
	_scene.logic_step(tick)
	_scene.logic_step(tick)  # same tick: phases are not run twice
	_scene.logic_step(tick - 1)
	assert_int(_scene.phase_steps()).is_equal(1)
	_scene.free()
	_instantiate()
	var config := RoomConfig.new()
	config.trace_cap = 0
	_scene.room_config = config
	await assert_error(func() -> void: add_child(_scene)).is_push_error("Sandbox: invalid room configuration")
	_scene.logic_step(GameLoop.get_logic_tick() + 1)  # aborted load: still a no-op
	assert_int(_scene.phase_steps()).is_equal(0)
