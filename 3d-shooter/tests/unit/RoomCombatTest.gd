extends GdUnitTestSuite
## RoomCombat owns the room's StatBlock and StatusRuntime; runtimes only hold references.

const SANDBOX: PackedScene = preload("res://world/sandbox/Sandbox.tscn")
var _scene: Node3D
var _made_combat: RoomCombat


func after_test() -> void:
	if is_instance_valid(_scene):
		_scene.free()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


static func _config(host_capacity: int) -> RoomConfig:
	var config := RoomConfig.new()
	config.host_capacity = host_capacity
	return config


func test_cold_creation_then_hot_stat_access_does_not_allocate() -> void:
	var objects_before_create: int = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var combat := RoomCombat.new(_config(4))
	var created: int = int(Performance.get_monitor(Performance.OBJECT_COUNT)) - objects_before_create
	var entity: int = combat.stats.allocate()
	var mobility := MobilityRuntime.new(combat.stats)
	for i: int in 300:
		combat.stats.set_stat(entity, StatBlock.Stat.HP, combat.stats.get_stat(entity, StatBlock.Stat.HP) + 1)
		combat.stats.add_stat_clamped(entity, StatBlock.Stat.ENERGY, 50, 0, 3000)
		mobility.logic_step(i + 1)
	var objects: int = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var memory: int = int(Performance.get_monitor(Performance.MEMORY_STATIC))
	for i: int in 3600:
		combat.stats.set_stat(entity, StatBlock.Stat.HP, combat.stats.get_stat(entity, StatBlock.Stat.HP) + 1)
		combat.stats.add_stat_clamped(entity, StatBlock.Stat.ENERGY, 50, 0, 3000)
		mobility.logic_step(300 + i + 1)
	var object_delta: int = int(Performance.get_monitor(Performance.OBJECT_COUNT)) - objects
	var memory_delta: int = int(Performance.get_monitor(Performance.MEMORY_STATIC)) - memory
	assert_int(created).is_greater(0)  # creation is the cold path and does allocate
	assert_int(object_delta).is_equal(0)
	assert_int(memory_delta).is_less_equal(1024 * 1024)
	assert_object(mobility.stats).is_same(combat.stats)
	assert_int(combat.stats.capacity()).is_equal(4)
	assert_int(combat.stats.get_stat(entity, StatBlock.Stat.HP)).is_equal(300 + 3600)
	assert_int(mobility.logic_steps).is_equal(300 + 3600)


func test_sandbox_room_owns_the_single_stat_block_and_reset_keeps_it() -> void:
	_scene = SANDBOX.instantiate() as Node3D
	(_scene.get_node(^"Player") as FPSController).hardware_input_enabled = false
	(_scene.get_node(^"Player/Camera3D/HitscanWeapon") as HitscanWeapon).hardware_input_enabled = false
	add_child(_scene)
	var combat: RoomCombat = _scene.get(&"combat") as RoomCombat
	var mobility: MobilityRuntime = _scene.get(&"mobility") as MobilityRuntime
	var player: int = _scene.get(&"player_handle")
	var shots: ShotBatch = _scene.get(&"shots") as ShotBatch
	var stats_before: StatBlock = combat.stats
	var alive_before: int = combat.stats.alive_count()
	combat.stats.set_stat(player, StatBlock.Stat.HP, 12345)
	for frame: int in 6:
		await get_tree().physics_frame
	var tick_before: int = GameLoop.get_logic_tick()
	var epoch_before: int = shots.epoch
	_scene.call(&"reset_mobility_clock")
	assert_int(tick_before).is_greater(0)
	assert_int(GameLoop.get_logic_tick()).is_equal(0)  # the reset really ran to the end
	assert_int(shots.epoch).is_equal(epoch_before + 1)
	assert_int(_scene.process_mode).is_not_equal(Node.PROCESS_MODE_DISABLED)
	assert_object(mobility.stats).is_same(combat.stats)
	assert_object(_scene.get(&"effects").get(&"_stats")).is_same(combat.stats)
	assert_object(_scene.get(&"resolver").get(&"_stats")).is_same(combat.stats)
	assert_object(_scene.get(&"weapon").get(&"_stats")).is_same(combat.stats)
	assert_object(combat.stats).is_same(stats_before)
	assert_int(alive_before).is_equal(4)  # player and three targets
	assert_int(combat.stats.alive_count()).is_equal(4)
	assert_int(combat.stats.get_stat(player, StatBlock.Stat.HP)).is_equal(12345)


## Each field outside its range refuses the room with a push_error naming that field.
func test_every_invalid_room_config_field_refuses_the_room() -> void:
	var over: int = HandlePool.MAX_CAPACITY + 1
	# [field named by the error, edit of a fresh default config]
	var cases: Array = [
		["host_capacity", func(c: RoomConfig) -> void: c.host_capacity = 0],
		["host_capacity", func(c: RoomConfig) -> void: c.host_capacity = StatBlock.MAX_CAPACITY + 1],
		["shot_capacity", func(c: RoomConfig) -> void: c.shot_capacity = 0],
		["shot_capacity", func(c: RoomConfig) -> void: c.shot_capacity = over],
		["trace_cap", func(c: RoomConfig) -> void: c.trace_cap = 0],
		["trace_cap", func(c: RoomConfig) -> void: c.trace_cap = AttackContextPool.HITS_PER_CONTEXT + 1],
		["shot_packed_bytes", func(c: RoomConfig) -> void: c.shot_packed_bytes = 0],
		["context_capacity", func(c: RoomConfig) -> void: c.context_capacity = 0],
		["context_capacity", func(c: RoomConfig) -> void: c.context_capacity = over],
		["deferred_reserve", func(c: RoomConfig) -> void: c.deferred_reserve = -1],
		["deferred_reserve", func(c: RoomConfig) -> void: c.deferred_reserve = 64],
		["landing_capacity", func(c: RoomConfig) -> void: c.landing_capacity = 0],
		["landing_capacity", func(c: RoomConfig) -> void: c.landing_capacity = LandingEventQueue.MAX_CAPACITY + 1],
		["effect_entries", func(c: RoomConfig) -> void: c.effect_entries = 0],
		["effect_entries", func(c: RoomConfig) -> void: c.effect_entries = over],
		["effect_max_subscriptions", func(c: RoomConfig) -> void: c.effect_max_subscriptions = 0],
		["effect_max_subscriptions",
				func(c: RoomConfig) -> void: c.effect_max_subscriptions = EffectRunner.MAX_SUBSCRIPTIONS + 1],
		["effect_packed_bytes", func(c: RoomConfig) -> void: c.effect_packed_bytes = 0],
		["visual_nodes", func(c: RoomConfig) -> void: c.visual_nodes = 0],
		["visual_packed_bytes", func(c: RoomConfig) -> void: c.visual_packed_bytes = 0],
		["visual_texture_bytes", func(c: RoomConfig) -> void: c.visual_texture_bytes = 0],
	]
	for entry: Array in cases:
		var config := RoomConfig.new()
		(entry[1] as Callable).call(config)
		_made_combat = null
		await assert_error(func() -> void: _made_combat = RoomCombat.new(config)).is_push_error(
				RoomConfig.ERROR_PREFIX + entry[0])
		assert_bool(_made_combat.is_initialized()).is_false()
		assert_object(_made_combat.stats).is_null()
		assert_object(_made_combat.statuses).is_null()
	# The derived EffectRunner quota is bounded: 4 * 8 + 48 events * 8 subscriptions = 640.
	var greedy := RoomConfig.new()
	greedy.host_capacity = 48
	assert_int(greedy.effect_work_quota()).is_equal(640)
	await assert_error(func() -> void: _made_combat = RoomCombat.new(greedy)).is_push_error(
			RoomConfig.ERROR_PREFIX + "effect quota: (shot_capacity * trace_cap + host_capacity) * effect_max_subscriptions > 512")
	assert_bool(_made_combat.is_initialized()).is_false()
	assert_bool(RoomCombat.new(_config(1)).is_initialized()).is_true()


func test_default_and_sandbox_configs_are_valid_and_the_copy_is_cold() -> void:
	var resource: RoomConfig = load("res://data/rooms/sandbox_room.tres") as RoomConfig
	assert_str(resource.validation_error()).is_empty()
	assert_str(RoomConfig.new().validation_error()).is_empty()
	assert_int(resource.effect_event_capacity()).is_equal(4 * 8 + 16)
	assert_int(resource.effect_work_quota()).is_equal(384)
	var source := _config(8)
	var combat := RoomCombat.new(source)
	source.host_capacity = 2  # later edits of the Resource never reach the running room
	assert_int(combat.config.host_capacity).is_equal(8)
	assert_int(combat.stats.capacity()).is_equal(8)
	assert_object(combat.config).is_not_same(source)
	combat.config.host_capacity = 3  # the getter hands out copies: the room copy stays intact
	assert_int(combat.config.host_capacity).is_equal(8)
	await assert_error(func() -> void: combat.config = RoomConfig.new()).is_push_error(
			RoomCombat.READ_ONLY_ERROR)
	assert_int(combat.config.host_capacity).is_equal(8)
	assert_bool(combat.statuses.uses_stats(combat.stats)).is_true()
	assert_bool(RoomCombat.new().is_initialized()).is_true()


func test_reset_room_clears_statuses_without_allocating() -> void:
	var combat := RoomCombat.new(_config(16))
	var stats: StatBlock = combat.stats
	var statuses: StatusRuntime = combat.statuses
	var pipeline := DamagePipeline.new(stats, statuses)
	var payloads := DamagePayloadBuffer.new(1)
	var handles := PackedInt64Array()
	for index: int in 16:
		handles.append(stats.allocate())
		stats.set_stat(handles[index], StatBlock.Stat.HP, 2_000_000_000)
		statuses.register_target(handles[index])
	var elements := PackedInt32Array([DamagePayload.Element.FIRE, DamagePayload.Element.ICE,
			DamagePayload.Element.ACID, DamagePayload.Element.ELECTRIC])
	var objects: int = 0
	var memory: int = 0
	var validator: int = 0
	var resets: int = 0
	var active_before_min: int = 1 << 30
	var active_after_max: int = 0
	for cycle: int in 360:
		if cycle == 60:
			objects = int(Performance.get_monitor(Performance.OBJECT_COUNT))
			memory = int(Performance.get_monitor(Performance.MEMORY_STATIC))
			validator = (RefCounted.new().get_instance_id() >> 24) & ((1 << 39) - 1)
			resets = 0
		for tick: int in range(1, 31):
			statuses.logic_step(tick)
			for index: int in 16:
				payloads.push(handles[0], handles[index], 1000, elements[(tick + index) % 4] as DamagePayload.Element,
						0, 0, -1)
				pipeline.resolve_front(payloads)
				payloads.pop_front()
		active_before_min = mini(active_before_min, statuses.active_count())
		if combat.reset_room():
			resets += 1
		active_after_max = maxi(active_after_max, statuses.active_count())
	var created: int = ((RefCounted.new().get_instance_id() >> 24) & ((1 << 39) - 1)) - validator - 1
	var object_delta: int = int(Performance.get_monitor(Performance.OBJECT_COUNT)) - objects
	var memory_delta: int = int(Performance.get_monitor(Performance.MEMORY_STATIC)) - memory
	assert_int(object_delta).is_equal(0)
	assert_int(created).is_equal(0)
	assert_int(memory_delta).is_less_equal(4096)
	assert_int(resets).is_equal(300)
	assert_int(active_before_min).is_equal(16)  # every cycle really had statuses to clear
	assert_int(active_after_max).is_equal(0)
	assert_int(statuses.active_count()).is_equal(0)
	assert_int(statuses.current_tick()).is_equal(0)
	assert_int(statuses.profile_of(handles[3])).is_equal(StatusRuntime.Profile.ORDINARY)
	assert_int(stats.alive_count()).is_equal(16)  # entities survive a room reset
	assert_int(statuses.configuration_errors).is_equal(0)
	assert_int(pipeline.configuration_errors).is_equal(0)
