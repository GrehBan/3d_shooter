extends GdUnitTestSuite
## RoomCombat owns the room's StatBlock; runtimes only hold references to it.

const SANDBOX: PackedScene = preload("res://world/sandbox/Sandbox.tscn")
var _scene: Node3D


func after_test() -> void:
	if is_instance_valid(_scene):
		_scene.free()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func test_cold_creation_then_hot_stat_access_does_not_allocate() -> void:
	var objects_before_create: int = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var combat := RoomCombat.new(4)
	var created: int = int(Performance.get_monitor(Performance.OBJECT_COUNT)) - objects_before_create
	var entity: int = combat.stats.allocate()
	var mobility := MobilityRuntime.new(combat.stats)
	for i: int in 300:
		combat.stats.set_stat(entity, StatBlock.Stat.HP, i)
		combat.stats.add_stat_clamped(entity, StatBlock.Stat.ENERGY, 50, 0, 3000)
	var objects: int = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var memory: int = int(Performance.get_monitor(Performance.MEMORY_STATIC))
	for i: int in 3600:
		combat.stats.set_stat(entity, StatBlock.Stat.HP, combat.stats.get_stat(entity, StatBlock.Stat.HP) + 1)
		combat.stats.add_stat_clamped(entity, StatBlock.Stat.ENERGY, 50, 0, 3000)
		mobility.logic_step(i + 1)
	var object_delta: int = int(Performance.get_monitor(Performance.OBJECT_COUNT)) - objects
	var memory_delta: int = int(Performance.get_monitor(Performance.MEMORY_STATIC)) - memory
	assert_int(created).is_greater(0)  # creation is the cold path and does allocate
	assert_int(object_delta).is_equal(0)
	assert_int(memory_delta).is_less_equal(1024 * 1024)
	assert_object(mobility.stats).is_same(combat.stats)
	assert_int(combat.stats.capacity()).is_equal(4)
	assert_int(combat.stats.get_stat(entity, StatBlock.Stat.HP)).is_equal(299 + 3600)


func test_sandbox_room_owns_the_single_stat_block_and_reset_keeps_it() -> void:
	_scene = SANDBOX.instantiate() as Node3D
	(_scene.get_node(^"Player") as FPSController).hardware_input_enabled = false
	(_scene.get_node(^"Player/Camera3D/HitscanWeapon") as HitscanWeapon).hardware_input_enabled = false
	add_child(_scene)
	var combat: RoomCombat = _scene.get(&"combat") as RoomCombat
	var mobility: MobilityRuntime = _scene.get(&"mobility") as MobilityRuntime
	var player: int = _scene.get(&"player_handle")
	var stats_before: StatBlock = combat.stats
	var alive_before: int = combat.stats.alive_count()
	combat.stats.set_stat(player, StatBlock.Stat.HP, 12345)
	_scene.call(&"reset_mobility_clock")
	assert_object(mobility.stats).is_same(combat.stats)
	assert_object(combat.stats).is_same(stats_before)
	assert_int(alive_before).is_equal(4)  # player and three targets
	assert_int(combat.stats.alive_count()).is_equal(4)
	assert_int(combat.stats.get_stat(player, StatBlock.Stat.HP)).is_equal(12345)
