extends GdUnitTestSuite
## M2.3a in the composition root: RoomCombat statuses, phase order, pulse routing, reset.

const SANDBOX: PackedScene = preload("res://world/sandbox/Sandbox.tscn")
const F := StatusRuntime.Field64

var _scene: Node3D
var _order: PackedStringArray = PackedStringArray()


func after_test() -> void:
	if is_instance_valid(_scene):
		_scene.free()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _load(definitions: Array[EffectRuleData] = []) -> void:
	_order.clear()
	_scene = SANDBOX.instantiate() as Node3D
	_scene.set(&"effect_definitions", definitions)
	(_scene.get_node(^"Player") as FPSController).hardware_input_enabled = false
	(_scene.get_node(^"Player/Camera3D/HitscanWeapon") as HitscanWeapon).hardware_input_enabled = false
	add_child(_scene)


func _combat() -> RoomCombat:
	return _scene.get(&"combat") as RoomCombat


func _fire_at(target: int, damage: int, element: DamagePayload.Element) -> void:
	var shots: ShotBatch = _scene.get(&"shots") as ShotBatch
	var ticket: int = shots.reserve(_scene.get(&"player_handle"), 1, damage, element)
	shots.write_trace(ticket, 0, target)
	shots.publish(ticket)


func test_room_registers_profiles_and_wires_one_status_store() -> void:
	_load()
	var combat: RoomCombat = _combat()
	var targets: PackedInt64Array = _scene.get(&"target_handles")
	assert_bool(combat.statuses.uses_stats(combat.stats)).is_true()
	assert_int(combat.statuses.profile_of(_scene.get(&"player_handle"))).is_equal(StatusRuntime.Profile.PLAYER)
	for target: int in targets:
		assert_int(combat.statuses.profile_of(target)).is_equal(StatusRuntime.Profile.ORDINARY)
	assert_object(_scene.get(&"resolver").get(&"damage_pipeline").get(&"_statuses")).is_same(combat.statuses)
	assert_object(_scene.get(&"mobility").get(&"_statuses")).is_same(combat.statuses)
	assert_int(combat.config.host_capacity).is_equal(16)


func test_room_loaded_mid_run_burns_from_the_current_tick() -> void:
	_load()
	var combat: RoomCombat = _combat()
	var target: int = (_scene.get(&"target_handles") as PackedInt64Array)[0]
	var start: int = GameLoop.get_logic_tick() + 1000  # GameLoop is global: rooms load mid-run
	_fire_at(target, 10000, DamagePayload.Element.FIRE)
	_scene.call(&"_on_logic_tick", start)
	assert_int(combat.statuses.burn_field(target, F.BURN_NEXT_DUE)).is_equal(start + 15)
	assert_int(combat.stats.get_stat(target, StatBlock.Stat.HP)).is_equal(90_000)
	for tick: int in range(start + 1, start + 16):
		_scene.call(&"_on_logic_tick", tick)
	assert_int(combat.statuses.processed_pulses).is_equal(1)
	assert_int(combat.stats.get_stat(target, StatBlock.Stat.HP)).is_equal(88_000)
	assert_int(_scene.process_mode).is_not_equal(Node.PROCESS_MODE_DISABLED)
	assert_int(combat.statuses.configuration_errors).is_equal(0)


func test_due_pulse_precedes_same_tick_shots_and_feeds_effects() -> void:
	var definitions: Array[EffectRuleData] = [preload("res://tests/fixtures/effects/count_hit.tres")]
	_load(definitions)
	var combat: RoomCombat = _combat()
	var player: int = _scene.get(&"player_handle")
	var entry: int = (_scene.get(&"effect_host") as EffectHost).add_effect(player,
			EffectTrigger.Trigger.ON_HIT, EffectTrigger.Phase.MAIN, 0, 0, 0, 0)
	var target: int = (_scene.get(&"target_handles") as PackedInt64Array)[1]
	combat.statuses.on_pulse_hit.connect(_on_pulse)
	(_scene.get(&"resolver") as ShotResolver).on_hit.connect(_on_shot_hit)
	var start: int = GameLoop.get_logic_tick() + 1
	_fire_at(target, 10000, DamagePayload.Element.FIRE)
	_scene.call(&"_on_logic_tick", start)
	for tick: int in range(start + 1, start + 15):
		_scene.call(&"_on_logic_tick", tick)
	_fire_at(target, 1000, DamagePayload.Element.NONE)
	_scene.call(&"_on_logic_tick", start + 15)  # the pulse is due on this tick
	var effects: EffectRunner = _scene.get(&"effects") as EffectRunner
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
	var combat: RoomCombat = _combat()
	var target: int = (_scene.get(&"target_handles") as PackedInt64Array)[0]
	var mesh: MeshInstance3D = _scene.get_node(^"Targets").get_child(0).get_child(1) as MeshInstance3D
	var start: int = GameLoop.get_logic_tick() + 1
	_fire_at(target, 10000, DamagePayload.Element.FIRE)
	_scene.call(&"_on_logic_tick", start)
	combat.stats.set_stat(target, StatBlock.Stat.HP, 1500)
	for tick: int in range(start + 1, start + 16):
		_scene.call(&"_on_logic_tick", tick)
	var after_logic: Material = mesh.material_override
	_scene.call(&"_process", 0.0)
	assert_int(combat.statuses.pulse_kills).is_equal(1)
	assert_int((_scene.get(&"resolver") as ShotResolver).kills).is_equal(0)  # not a shot kill
	assert_object(after_logic).is_null()  # logic never touches visuals
	assert_object(mesh.material_override).is_not_null()


func test_room_reset_clears_statuses_and_keeps_registrations() -> void:
	_load()
	var combat: RoomCombat = _combat()
	var target: int = (_scene.get(&"target_handles") as PackedInt64Array)[2]
	_fire_at(target, 1000, DamagePayload.Element.ACID)
	_scene.call(&"_on_logic_tick", GameLoop.get_logic_tick() + 1)
	var corroded: int = combat.statuses.acid_stacks(target)
	_scene.call(&"reset_mobility_clock")
	assert_int(corroded).is_equal(1)
	assert_int(combat.statuses.acid_stacks(target)).is_equal(0)
	assert_int(combat.statuses.active_count()).is_equal(0)
	assert_int(combat.statuses.current_tick()).is_equal(0)
	assert_int(combat.statuses.profile_of(target)).is_equal(StatusRuntime.Profile.ORDINARY)
	assert_int(_scene.process_mode).is_not_equal(Node.PROCESS_MODE_DISABLED)


func test_invalid_room_config_disables_room_before_runtime_and_subscription() -> void:
	_scene = SANDBOX.instantiate() as Node3D
	var config := RoomConfig.new()
	config.effect_max_subscriptions = 0
	_scene.set(&"room_config", config)
	(_scene.get_node(^"Player") as FPSController).hardware_input_enabled = false
	var subscribers: int = GameLoop.logic_tick.get_connections().size()
	await assert_error(func() -> void: add_child(_scene)).is_push_error("Sandbox: invalid room configuration")
	assert_int(_scene.process_mode).is_equal(Node.PROCESS_MODE_DISABLED)
	assert_int(GameLoop.logic_tick.get_connections().size()).is_equal(subscribers)
	assert_object(_scene.get(&"mobility")).is_null()
	assert_object(_scene.get(&"shots")).is_null()
