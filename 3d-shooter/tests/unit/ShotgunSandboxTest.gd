extends GdUnitTestSuite

const SANDBOX: PackedScene = preload("res://world/sandbox/Sandbox.tscn")
var _scene: Node3D
var _hp_on_hit: int
var _energy_on_hit: int


func after_test() -> void:
	if is_instance_valid(_scene):
		_scene.free()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func test_invalid_weapon_disables_complete_room_before_runtime_and_subscription() -> void:
	_scene = SANDBOX.instantiate() as Node3D
	_scene.set(&"weapon_data_directory", "res://tests/fixtures/weapon_invalid")
	var player: FPSController = _scene.get_node(^"Player") as FPSController
	player.hardware_input_enabled = false
	var subscribers: int = GameLoop.logic_tick.get_connections().size()
	assert_error(func() -> void: add_child(_scene)).is_push_error("Sandbox: invalid weapon preset or room capacity")
	assert_int(_scene.process_mode).is_equal(Node.PROCESS_MODE_DISABLED)
	assert_int(GameLoop.logic_tick.get_connections().size()).is_equal(subscribers)
	assert_object(_scene.get(&"mobility")).is_null()
	assert_object(_scene.get(&"shots")).is_null()
	assert_object(_scene.get(&"resolver")).is_null()


func _hit(_source: int, _target: int, _epoch: int, _sequence: int, _trace: int,
		_child: int, _damage: int) -> void:
	var mobility: MobilityRuntime = _scene.get(&"mobility") as MobilityRuntime
	var player: int = _scene.get(&"player_handle")
	_hp_on_hit = mobility.stats.get_stat(player, StatBlock.Stat.HP)
	_energy_on_hit = mobility.stats.get_stat(player, StatBlock.Stat.ENERGY)


func test_one_subscription_resolves_shots_before_landing_then_regen() -> void:
	_scene = SANDBOX.instantiate() as Node3D
	(_scene.get_node(^"Player") as FPSController).hardware_input_enabled = false
	(_scene.get_node(^"Player/Camera3D/HitscanWeapon") as HitscanWeapon).hardware_input_enabled = false
	var before: int = GameLoop.logic_tick.get_connections().size()
	add_child(_scene)
	assert_int(GameLoop.logic_tick.get_connections().size()).is_equal(before + 1)
	var mobility: MobilityRuntime = _scene.get(&"mobility") as MobilityRuntime
	var resolver: ShotResolver = _scene.get(&"resolver") as ShotResolver
	var shots: ShotBatch = _scene.get(&"shots") as ShotBatch
	var player: int = _scene.get(&"player_handle")
	mobility.stats.set_stat(player, StatBlock.Stat.HP, 20000)
	mobility.stats.set_stat(player, StatBlock.Stat.ENERGY, 0)
	var ticket: int = shots.reserve(player, 1, 6000)
	shots.write_trace(ticket, 0, player)
	shots.publish(ticket)
	mobility.landings.push(player, 9000, 0)
	resolver.on_hit.connect(_hit)
	_scene.call(&"_on_logic_tick", GameLoop.get_logic_tick())
	assert_int(_hp_on_hit).is_equal(14000)
	assert_int(_energy_on_hit).is_equal(0)
	assert_int(mobility.stats.get_stat(player, StatBlock.Stat.HP)).is_equal(4000)
	assert_int(mobility.stats.get_stat(player, StatBlock.Stat.ENERGY)).is_equal(50)
	assert_int(resolver.resolved_shots).is_equal(1)
	_scene.call(&"_on_logic_tick", GameLoop.get_logic_tick())
	assert_int(mobility.stats.get_stat(player, StatBlock.Stat.ENERGY)).is_equal(50)
	assert_int(resolver.resolved_shots).is_equal(1)


func test_invalid_visual_disables_room_before_stores_binding_or_subscription() -> void:
	_scene = SANDBOX.instantiate() as Node3D
	var data := ShotVisualData.new()
	data.mark_capacity = 79
	_scene.set(&"visual_data", data)
	(_scene.get_node(^"Player") as FPSController).hardware_input_enabled = false
	var subscribers: int = GameLoop.logic_tick.get_connections().size()
	assert_error(func() -> void: add_child(_scene)).is_push_error("Sandbox: invalid visual preset or room capacity")
	assert_int(_scene.process_mode).is_equal(Node.PROCESS_MODE_DISABLED)
	assert_int(GameLoop.logic_tick.get_connections().size()).is_equal(subscribers)
	assert_object(_scene.get(&"mobility")).is_null()
	assert_object(_scene.get(&"shots")).is_null()
	assert_object(_scene.get(&"resolver")).is_null()
	assert_object(_scene.get(&"visuals")).is_null()
	assert_bool((_scene.get_node(^"Player/Camera3D/HitscanWeapon") as HitscanWeapon).is_initialized()).is_false()
