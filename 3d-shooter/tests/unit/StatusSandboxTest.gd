extends GdUnitTestSuite
## M2.3a in the composition root: RoomCombat statuses, phase order, pulse routing, reset.
## Only the public Sandbox API is used: no string calls or reflection.

const SANDBOX: PackedScene = preload("res://world/sandbox/Sandbox.tscn")
const F := StatusRuntime.Field64

var _scene: Sandbox
var _order: PackedStringArray = PackedStringArray()


func after_test() -> void:
	if is_instance_valid(_scene):
		_scene.free()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _instantiate() -> void:
	_order.clear()
	_scene = SANDBOX.instantiate() as Sandbox
	(_scene.get_node(^"Player") as FPSController).hardware_input_enabled = false
	(_scene.get_node(^"Player/Camera3D/HitscanWeapon") as HitscanWeapon).hardware_input_enabled = false


func _load(definitions: Array[EffectRuleData] = []) -> void:
	_instantiate()
	_scene.effect_definitions = definitions
	add_child(_scene)


func _fire_at(target: int, damage: int, element: DamagePayload.Element) -> void:
	var ticket: int = _scene.shots.reserve(_scene.player_handle, 1, damage, element)
	_scene.shots.write_trace(ticket, 0, target)
	_scene.shots.publish(ticket)


func _run_ticks(first: int, last: int) -> void:
	for tick: int in range(first, last + 1):
		_scene.logic_step(tick)


func test_room_registers_profiles_and_wires_one_status_store() -> void:
	_load()
	var combat: RoomCombat = _scene.combat
	assert_bool(combat.statuses.uses_stats(combat.stats)).is_true()
	assert_int(combat.statuses.profile_of(_scene.player_handle)).is_equal(StatusRuntime.Profile.PLAYER)
	for target: int in _scene.target_handles:
		assert_int(combat.statuses.profile_of(target)).is_equal(StatusRuntime.Profile.ORDINARY)
	assert_bool(_scene.resolver.damage_pipeline.uses_statuses(combat.statuses)).is_true()
	assert_bool(_scene.mobility.uses_statuses(combat.statuses)).is_true()
	assert_int(combat.config.host_capacity).is_equal(16)


func test_room_loaded_mid_run_burns_from_the_current_tick() -> void:
	_load()
	var combat: RoomCombat = _scene.combat
	var target: int = _scene.target_handles[0]
	var start: int = GameLoop.get_logic_tick() + 1000  # GameLoop is global: rooms load mid-run
	_fire_at(target, 10000, DamagePayload.Element.FIRE)
	_scene.logic_step(start)
	assert_int(combat.statuses.burn_field(target, F.BURN_NEXT_DUE)).is_equal(start + 15)
	assert_int(combat.stats.get_stat(target, StatBlock.Stat.HP)).is_equal(90_000)
	_run_ticks(start + 1, start + 15)
	assert_int(combat.statuses.processed_pulses).is_equal(1)
	assert_int(combat.stats.get_stat(target, StatBlock.Stat.HP)).is_equal(88_000)
	assert_int(_scene.process_mode).is_not_equal(Node.PROCESS_MODE_DISABLED)
	assert_int(combat.statuses.configuration_errors).is_equal(0)


func test_due_pulse_precedes_same_tick_shots_and_feeds_effects() -> void:
	var definitions: Array[EffectRuleData] = [preload("res://tests/fixtures/effects/count_hit.tres")]
	_load(definitions)
	var combat: RoomCombat = _scene.combat
	var entry: int = _scene.effect_host.add_effect(_scene.player_handle,
			EffectTrigger.Trigger.ON_HIT, EffectTrigger.Phase.MAIN, 0, 0, 0, 0)
	var target: int = _scene.target_handles[1]
	combat.statuses.on_pulse_hit.connect(_on_pulse)
	_scene.resolver.on_hit.connect(_on_shot_hit)
	var start: int = GameLoop.get_logic_tick() + 1
	_fire_at(target, 10000, DamagePayload.Element.FIRE)
	_run_ticks(start, start + 14)
	_fire_at(target, 1000, DamagePayload.Element.NONE)
	_scene.logic_step(start + 15)  # the pulse is due on this tick
	var effects: EffectRunner = _scene.effects
	assert_array(_order).is_equal(PackedStringArray(["hit", "pulse", "hit"]))
	assert_int(effects.accepted_events).is_equal(3)  # two shot hits and one pulse
	assert_int(effects.counter_for(entry)).is_equal(3)
	assert_int(effects.deferred_steps).is_equal(0)
	assert_int(effects.configuration_errors).is_equal(0)


func _on_pulse(_source: int, _target: int, _credit: int, _generation: int, _ordinal: int,
		_damage: int, _epoch: int, _sequence: int, _trace: int, _tags: int) -> void:
	_order.append("pulse")


func _on_shot_hit(_source: int, _target: int, _epoch: int, _sequence: int, _trace: int,
		_child: int, _damage: int) -> void:
	_order.append("hit")


func test_lethal_pulse_greys_target_in_the_next_frame() -> void:
	_load()
	var combat: RoomCombat = _scene.combat
	var target: int = _scene.target_handles[0]
	var mesh: MeshInstance3D = _scene.get_node(^"Targets").get_child(0).get_child(1) as MeshInstance3D
	var start: int = GameLoop.get_logic_tick() + 1
	_fire_at(target, 10000, DamagePayload.Element.FIRE)
	_scene.logic_step(start)
	combat.stats.set_stat(target, StatBlock.Stat.HP, 1500)
	_run_ticks(start + 1, start + 15)
	var after_logic: Material = mesh.material_override
	_scene.apply_dead_marks()
	assert_int(combat.statuses.pulse_kills).is_equal(1)
	assert_int(_scene.resolver.kills).is_equal(0)  # not a shot kill
	assert_object(after_logic).is_null()  # logic never touches visuals
	assert_object(mesh.material_override).is_not_null()


func test_room_reset_clears_statuses_and_keeps_registrations() -> void:
	_load()
	var combat: RoomCombat = _scene.combat
	var target: int = _scene.target_handles[2]
	_fire_at(target, 1000, DamagePayload.Element.ACID)
	_scene.logic_step(GameLoop.get_logic_tick() + 1)
	var corroded: int = combat.statuses.acid_stacks(target)
	_scene.reset_mobility_clock()
	assert_int(corroded).is_equal(1)
	assert_int(combat.statuses.acid_stacks(target)).is_equal(0)
	assert_int(combat.statuses.active_count()).is_equal(0)
	assert_int(combat.statuses.current_tick()).is_equal(0)
	assert_int(combat.statuses.profile_of(target)).is_equal(StatusRuntime.Profile.ORDINARY)
	assert_int(_scene.process_mode).is_not_equal(Node.PROCESS_MODE_DISABLED)


func test_invalid_room_config_disables_room_before_runtime_and_subscription() -> void:
	_instantiate()
	var config := RoomConfig.new()
	config.effect_max_subscriptions = 0
	_scene.room_config = config
	var subscribers: int = GameLoop.logic_tick.get_connections().size()
	await assert_error(func() -> void: add_child(_scene)).is_push_error("Sandbox: invalid room configuration")
	assert_int(_scene.process_mode).is_equal(Node.PROCESS_MODE_DISABLED)
	assert_int(GameLoop.logic_tick.get_connections().size()).is_equal(subscribers)
	assert_object(_scene.mobility).is_null()
	assert_object(_scene.shots).is_null()
