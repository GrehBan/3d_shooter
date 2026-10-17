extends GdUnitTestSuite

const SANDBOX: PackedScene = preload("res://world/sandbox/Sandbox.tscn")
var _scene: Sandbox


func after_test() -> void:
	if is_instance_valid(_scene):
		_scene.free()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _room() -> void:
	_scene = SANDBOX.instantiate() as Sandbox
	var definitions: Array[EffectRuleData] = [preload("res://tests/fixtures/effects/count_hit.tres")]
	_scene.effect_definitions = definitions
	(_scene.get_node(^"Player") as FPSController).hardware_input_enabled = false
	(_scene.get_node(^"Player/Camera3D/HitscanWeapon") as HitscanWeapon).hardware_input_enabled = false
	add_child(_scene)


func test_shot_completes_immediately_and_captured_damage_survives_target_death() -> void:
	var connections: int = GameLoop.logic_tick.get_connections().size()
	_room()
	assert_int(GameLoop.logic_tick.get_connections().size()).is_equal(connections + 1)
	var host: EffectHost = _scene.effect_host
	var effects: EffectRunner = _scene.effects
	var resolver: ShotResolver = _scene.resolver
	var shots: ShotBatch = _scene.shots
	var mobility: MobilityRuntime = _scene.mobility
	var player: int = _scene.player_handle
	var targets: PackedInt64Array = _scene.target_handles
	var entry: int = host.add_effect(player, EffectTrigger.Trigger.ON_HIT, EffectTrigger.Phase.MAIN, 0, 0, 0, 0)
	mobility.stats.set_stat(targets[0], StatBlock.Stat.HP, 6000)
	var shot: int = shots.reserve(player, 1, 6000)
	shots.write_trace(shot, 0, targets[0])
	shots.publish(shot)
	resolver.logic_step(0)
	assert_int(resolver.resolved_shots).is_equal(1)
	assert_int(resolver.contexts.alive_count()).is_equal(0)
	assert_int(effects.pending_count()).is_equal(1)
	assert_int(mobility.stats.get_stat(targets[0], StatBlock.Stat.HP)).is_equal(0)
	mobility.stats.release(targets[0])
	effects.logic_step(0)
	assert_int(effects.counter_for(entry)).is_equal(1)
	effects.enqueue(player, EffectTrigger.Trigger.ON_HIT, 1)
	_scene.reset_mobility_clock()
	assert_int(effects.pending_count()).is_equal(0)
	assert_int(effects.counter_for(entry)).is_equal(0)
	assert_int(host.entry_count()).is_equal(1)
	effects.enqueue(player, EffectTrigger.Trigger.ON_HIT, 1)
	_scene.logic_step(0)
	assert_int(effects.counter_for(entry)).is_equal(1)


func test_failed_resolver_reset_preserves_effect_queue_counter_and_clock() -> void:
	_room()
	var host: EffectHost = _scene.effect_host
	var effects: EffectRunner = _scene.effects
	var shots: ShotBatch = _scene.shots
	var player: int = _scene.player_handle
	var entry: int = host.add_effect(player, EffectTrigger.Trigger.ON_HIT, EffectTrigger.Phase.MAIN, 0, 0, 0, 0)
	effects.enqueue(player, EffectTrigger.Trigger.ON_HIT, 1)
	effects.logic_step(5)
	effects.enqueue(player, EffectTrigger.Trigger.ON_HIT, 1)
	shots.epoch = ShotBatch.INT_MAX
	await assert_error(func() -> void: _scene.reset_mobility_clock()).is_push_error(
			"Sandbox: room epoch exhausted")
	assert_int(effects.counter_for(entry)).is_equal(1)
	assert_int(effects.pending_count()).is_equal(1)
	assert_int(effects.logic_step(5)).is_equal(0)
	assert_int(effects.accepted_events).is_equal(2)
