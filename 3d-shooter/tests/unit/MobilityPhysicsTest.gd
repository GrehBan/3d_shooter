extends GdUnitTestSuite
## Real Jolt mobility integration. Physics is intentionally outside bit-exact logic.

var _viewport: SubViewport
var _arena: Node3D
var _player: FPSController
var _runtime: MobilityRuntime
var _entity: int
var _step_barrier: PhysicsStepBarrier


class PhysicsStepBarrier extends Node:
	signal stepped

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		process_physics_priority = 1100  # after controllers AND GameLoop logic step

	func _physics_process(_delta: float) -> void:
		stepped.emit()

func before_test() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_viewport = SubViewport.new()
	_viewport.process_mode = Node.PROCESS_MODE_PAUSABLE
	_viewport.world_3d = World3D.new()
	_viewport.size = Vector2i(64, 64)
	add_child(_viewport)
	_arena = Node3D.new()
	_viewport.add_child(_arena)
	_add_box(Vector3(2000.0, 1.0, 2000.0), Vector3(0.0, -0.5, 0.0))
	_player = _make_player()
	_runtime = MobilityRuntime.new(StatBlock.new(4), 256)
	_entity = _spawn()
	_player.bind_mobility(_runtime, _entity)
	_step_barrier = PhysicsStepBarrier.new()
	_arena.add_child(_step_barrier)

func _make_player() -> FPSController:
	var player := FPSController.new()
	player.hardware_input_enabled = false
	player.collision_layer = 2
	player.collision_mask = 1
	player.position = Vector3(0.0, 0.95, 0.0)
	var shape := CapsuleShape3D.new()
	shape.radius = 0.35
	shape.height = 1.8
	var collision := CollisionShape3D.new()
	collision.name = "CollisionShape3D"
	collision.shape = shape
	player.add_child(collision)
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	player.add_child(camera)
	_arena.add_child(player)
	return player

func _spawn() -> int:
	var entity: int = _runtime.stats.allocate()
	_runtime.stats.set_stat(entity, StatBlock.Stat.HP, 100_000)
	_runtime.stats.set_stat(entity, StatBlock.Stat.ENERGY, 3000)
	_runtime.stats.set_stat(entity, StatBlock.Stat.MAX_ENERGY, 3000)
	_runtime.abilities.grant(entity, MovementAbilityData.Kind.DASH, 1000, 6, true, true)
	_runtime.abilities.grant(entity, MovementAbilityData.Kind.SLIDE, 500, 6, true, false)
	_runtime.abilities.grant(entity, MovementAbilityData.Kind.DOUBLE_JUMP, 1000, 0, false, true)
	return entity

func after_test() -> void:
	get_tree().paused = false
	Input.action_release(&"move_forward")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if is_instance_valid(_viewport):
		_viewport.free()

func _add_box(size: Vector3, origin: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = origin
	body.collision_layer = 1
	body.collision_mask = 0
	var shape := BoxShape3D.new()
	shape.size = size
	var collision := CollisionShape3D.new()
	collision.shape = shape
	body.add_child(collision)
	_arena.add_child(body)
	return body

func _ticks(count: int) -> void:
	for tick: int in count:
		await _step_barrier.stepped

func _settle() -> void:
	await _ticks(30)
	assert_bool(_player.is_on_floor()).is_true()
	_runtime.landings.clear()

func _energy() -> int:
	return _runtime.stats.get_stat(_entity, StatBlock.Stat.ENERGY)

func test_dash_exact_nine_steps_fixed_direction_and_edge() -> void:
	await _settle()
	var start: Vector3 = _player.global_position
	_player.set_dash_pressed(true)  # no input => camera/body forward
	await _ticks(1)
	assert_int(_energy()).is_equal(2000)
	assert_bool(_player.is_dashing()).is_true()
	_player.set_move_input(Vector2.RIGHT)
	_player.add_look_input(Vector2(200.0, 0.0))
	await _ticks(8)
	assert_float(_player.global_position.z - start.z).is_equal_approx(-3.6, 0.02)
	assert_float(_player.global_position.x - start.x).is_equal_approx(0.0, 0.02)
	assert_bool(_player.is_dashing()).is_false()
	await _ticks(30)
	_player.set_dash_pressed(true)
	await _ticks(1)
	assert_int(_player.dash_activations).is_equal(1)
	assert_int(_energy()).is_equal(2000)

func test_air_dash_preserves_vertical_gravity_and_wall_collision() -> void:
	_add_box(Vector3(0.5, 20.0, 20.0), Vector3(2.0, 10.0, 0.0))
	_player.position.y = 6.0
	await _ticks(2)
	var vy: float = _player.velocity.y
	_player.set_move_input(Vector2.RIGHT)
	_player.set_dash_pressed(true)
	await _ticks(9)
	assert_int(_player.dash_activations).is_equal(1)
	assert_float(_player.velocity.y).is_less(vy - 1.0)
	assert_float(_player.global_position.x).is_equal_approx(1.4, 0.03)
	assert_bool(_player.is_on_wall()).is_true()
	assert_int(_energy()).is_equal(2000)

func test_dash_world_yaw_uniform_scale_and_analog_normalization() -> void:
	var parent := Node3D.new()
	parent.rotation.y = PI / 2.0
	parent.scale = Vector3.ONE * 2.0
	_arena.add_child(parent)
	_player.reparent(parent, false)
	await _settle()
	var start: Vector3 = _player.global_position
	_player.set_move_input(Vector2(0.0, -0.5))
	_player.set_dash_pressed(true)
	await _ticks(9)
	assert_float(_player.global_position.x - start.x).is_equal_approx(-3.6, 0.04)
	assert_float(_player.global_position.z - start.z).is_equal_approx(0.0, 0.02)

func test_slide_inertia_exact_thirty_six_steps_and_capsule_unchanged() -> void:
	await _settle()
	_player.set_move_input(Vector2.RIGHT)
	await _ticks(1)
	var start: Vector3 = _player.position
	var shape: CapsuleShape3D = (_player.get_node(^"CollisionShape3D") as CollisionShape3D).shape as CapsuleShape3D
	var initial_height: float = shape.height
	_player.set_slide_pressed(true)
	_player.set_move_input(Vector2.LEFT)
	await _ticks(1)
	assert_int(_energy()).is_equal(2500)
	assert_float(_player.velocity.x).is_equal_approx(8.0, 0.01)
	_player.set_move_input(Vector2.ZERO)
	_player.add_look_input(Vector2(200.0, 0.0))
	await _ticks(35)
	assert_bool(_player.is_sliding()).is_false()
	assert_float(_player.position.x - start.x).is_equal_approx(3.925, 0.03)
	assert_float(_player.position.z - start.z).is_equal_approx(0.0, 0.02)
	assert_float(shape.height).is_equal(initial_height)
	await _ticks(1)
	assert_float(_player.velocity.x).is_equal_approx(0.0, 0.01)
	_player.set_slide_pressed(true)
	await _ticks(1)
	assert_int(_player.slide_activations).is_equal(1)

func test_slide_refuses_slow_entry_and_dash_incompatibility_without_payment() -> void:
	await _settle()
	var ready: int = _runtime.abilities.ready_tick(_entity, MovementAbilityData.Kind.SLIDE)
	_player.set_slide_pressed(true)
	_player.set_move_input(Vector2.RIGHT)
	await _ticks(1)
	assert_int(_energy()).is_equal(3000)
	assert_int(_runtime.abilities.ready_tick(_entity, MovementAbilityData.Kind.SLIDE)).is_equal(ready)
	_player.set_slide_pressed(false)
	_player.set_slide_pressed(true)
	_player.set_dash_pressed(true)
	_player.set_jump_pressed(true)
	await _ticks(1)
	assert_int(_energy()).is_equal(2000)
	assert_int(_player.dash_activations).is_equal(1)
	assert_int(_player.slide_activations).is_equal(0)
	assert_bool(_player.is_on_floor()).is_true()

func test_failed_dash_can_yield_to_slide_or_free_ground_jump() -> void:
	await _settle()
	_runtime.stats.set_stat(_entity, StatBlock.Stat.ENERGY, 500)
	_player.set_move_input(Vector2.RIGHT)
	await _ticks(1)
	_player.set_dash_pressed(true)
	_player.set_slide_pressed(true)
	_player.set_jump_pressed(true)
	await _ticks(1)
	assert_int(_player.dash_activations).is_equal(0)
	assert_int(_player.slide_activations).is_equal(1)
	assert_bool(_player.is_on_floor()).is_true()
	assert_int(_energy()).is_equal(0)
	await _ticks(36)
	_player.set_dash_pressed(false)
	_player.set_dash_pressed(true)
	_player.set_slide_pressed(false)
	_player.set_slide_pressed(true)
	_player.set_jump_pressed(false)
	_player.set_jump_pressed(true)
	await _ticks(1)
	assert_float(_player.velocity.y).is_greater(5.0)
	assert_int(_energy()).is_equal(0)

func test_slide_loses_ground_without_air_continuation() -> void:
	_add_box(Vector3(2.0, 2.0, 2.0), Vector3(0.0, 1.0, 0.0))
	_player.position.y = 2.95
	await _settle()
	_player.set_move_input(Vector2.RIGHT)
	await _ticks(1)
	_player.set_slide_pressed(true)
	await _ticks(20)
	assert_bool(_player.is_on_floor()).is_false()
	assert_bool(_player.is_sliding()).is_false()
	assert_int(_player.slide_activations).is_equal(1)

func test_double_jump_free_cooldown_zero_regrant_spam_does_not_reset_air_limit() -> void:
	await _settle()
	_runtime.abilities.grant(_entity, MovementAbilityData.Kind.DOUBLE_JUMP, 0, 0, false, true)
	_player.set_jump_pressed(true)
	await _ticks(1)
	assert_int(_energy()).is_equal(3000)
	_player.set_jump_pressed(false)
	_player.set_jump_pressed(true)
	await _ticks(1)
	assert_int(_player.double_jump_activations).is_equal(1)
	assert_float(_player.velocity.y).is_equal_approx(5.5, 0.01)
	for tick: int in 15:
		_runtime.abilities.grant(_entity, MovementAbilityData.Kind.DOUBLE_JUMP, 0, 0, false, true)
		_player.set_jump_pressed(false)
		_player.set_jump_pressed(true)
		await _ticks(1)
	assert_int(_player.double_jump_activations).is_equal(1)
	await _ticks(100)
	assert_bool(_player.is_on_floor()).is_true()
	_player.set_jump_pressed(false)
	_player.set_jump_pressed(true)
	await _ticks(1)
	_player.set_jump_pressed(false)
	_player.set_jump_pressed(true)
	await _ticks(1)
	assert_int(_player.double_jump_activations).is_equal(2)

func test_wall_and_ceiling_contacts_do_not_reset_air_jump_limit() -> void:
	_add_box(Vector3(8.0, 1.0, 8.0), Vector3(0.0, 3.2, 0.0))
	_add_box(Vector3(0.5, 8.0, 8.0), Vector3(1.0, 4.0, 0.0))
	await _settle()
	_runtime.abilities.grant(_entity, MovementAbilityData.Kind.DOUBLE_JUMP, 0, 0, false, true)
	_player.set_jump_pressed(true)
	_player.set_move_input(Vector2.RIGHT)
	await _ticks(1)
	_player.set_jump_pressed(false)
	_player.set_jump_pressed(true)
	await _ticks(1)
	var ceiling_seen: bool = false
	var wall_seen: bool = false
	for tick: int in 20:
		_player.set_jump_pressed(false)
		_player.set_jump_pressed(true)
		await _ticks(1)
		ceiling_seen = ceiling_seen or _player.is_on_ceiling()
		wall_seen = wall_seen or _player.is_on_wall()
	assert_bool(ceiling_seen).is_true()
	assert_bool(wall_seen).is_true()
	assert_int(_player.double_jump_activations).is_equal(1)

func test_pause_focus_and_rebind_clear_requests_prearm_and_stale_entity() -> void:
	_player.position.y = 6.0
	await _ticks(2)
	_player.set_slide_pressed(true)
	await _ticks(1)
	assert_int(_player._slide_prearm_tick).is_greater_equal(0)
	_player.set_dash_pressed(true)
	_player.set_jump_pressed(true)
	get_tree().paused = true
	await _ticks(2)
	get_tree().paused = false
	await _ticks(1)
	assert_int(_energy()).is_equal(3000)
	assert_int(_player._slide_prearm_tick).is_equal(-1)
	_player.set_slide_pressed(true)
	await _ticks(1)
	_player._notification(NOTIFICATION_APPLICATION_FOCUS_OUT)
	assert_int(_player._slide_prearm_tick).is_equal(-1)
	_player.set_dash_pressed(true)
	_player.set_jump_pressed(true)
	var fresh: int = _spawn()
	_player.bind_mobility(_runtime, fresh)
	await _ticks(1)
	assert_int(_runtime.stats.get_stat(fresh, StatBlock.Stat.ENERGY)).is_equal(3000)
	assert_bool(_player.is_dashing()).is_false()
	assert_bool(_player._double_jump_used).is_false()
	_runtime.stats.release(fresh)
	await _ticks(1)
	assert_int(_player.mobility_entity()).is_equal(StatBlock.INVALID_HANDLE)

func test_hardware_dash_slide_echo_and_held_do_not_repeat() -> void:
	await _settle()
	_player.set_hardware_input_enabled(true)
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	_player._unhandled_input(click)
	var key := InputEventKey.new()
	key.physical_keycode = KEY_SHIFT
	key.pressed = true
	key.echo = true
	_player._unhandled_input(key)
	await _ticks(1)
	assert_int(_player.dash_activations).is_equal(0)
	key.echo = false
	_player._unhandled_input(key)
	await _ticks(30)
	_player._unhandled_input(key)
	await _ticks(1)
	assert_int(_player.dash_activations).is_equal(1)
	Input.action_press(&"move_forward")
	await _ticks(1)
	key.physical_keycode = KEY_CTRL
	key.echo = true
	_player._unhandled_input(key)
	await _ticks(1)
	assert_int(_player.slide_activations).is_equal(0)
	key.echo = false
	_player._unhandled_input(key)
	await _ticks(40)
	_player._unhandled_input(key)
	await _ticks(1)
	assert_int(_player.slide_activations).is_equal(1)
	Input.action_release(&"move_forward")
	_player.set_hardware_input_enabled(false)

# Fixed speed falling through real Jolt: 13 steps to floor; activation tick 1 => age 12.
func _controlled_fall(steps_to_floor: int = 13) -> void:
	# End slightly through contact, avoiding a tangent-only last step in Jolt.
	_player.position = Vector3(0.0, 0.8 + 0.85 * float(steps_to_floor), 0.0)
	_player.gravity = 0.0
	# A test teleport must discard the engine's previous floor contact before dropping.
	_player.velocity = Vector3.ZERO
	_player.move_and_slide()
	_player.velocity.y = -51.0
	_player.reset_physics_interpolation()
	_runtime.landings.clear()

func _wait_landing(max_ticks: int = 25) -> void:
	for tick: int in max_ticks:
		await _ticks(1)
		if _player.is_on_floor():
			return
	assert_bool(_player.is_on_floor()).is_true()

func test_real_landing_once_height_and_logic_applies_after_physics() -> void:
	_controlled_fall()
	await _wait_landing()
	assert_int(_runtime.landings.count()).is_equal(1)
	assert_int(_runtime.landings.get_entity(0)).is_equal(_entity)
	assert_int(_runtime.landings.get_height_mm(0)).is_greater(10_900)
	assert_int(_runtime.landings.get_cancel_flags(0)).is_equal(0)
	assert_int(_runtime.stats.get_stat(_entity, StatBlock.Stat.HP)).is_equal(100_000)
	await _ticks(5)
	assert_int(_runtime.landings.count()).is_equal(1)
	_runtime.logic_step(0)
	assert_int(_runtime.stats.get_stat(_entity, StatBlock.Stat.HP)).is_between(70_490, 70_520)
	assert_int(_runtime.landings.count()).is_equal(0)
	_runtime.logic_step(1)
	assert_int(_runtime.resolved_landings).is_equal(1)

func test_dash_cancels_exact_twelve_tick_boundary() -> void:
	_controlled_fall(13)
	_player.set_dash_pressed(true)
	await _wait_landing()
	assert_int(_player._physical_tick - _player._last_dash_tick).is_equal(12)
	assert_int(_runtime.landings.get_cancel_flags(0)).is_equal(LandingEventQueue.CANCEL_DASH)
	_runtime.logic_step(0)
	assert_int(_runtime.stats.get_stat(_entity, StatBlock.Stat.HP)).is_equal(100_000)

func test_dash_outside_window_and_held_does_not_cancel() -> void:
	_controlled_fall(14)
	_player.set_dash_pressed(true)
	await _wait_landing()
	assert_int(_player._physical_tick - _player._last_dash_tick).is_equal(13)
	assert_int(_runtime.landings.get_cancel_flags(0)).is_equal(0)
	assert_int(_player.dash_activations).is_equal(1)
	_runtime.logic_step(0)
	assert_int(_runtime.stats.get_stat(_entity, StatBlock.Stat.HP)).is_less(70_000)

func test_rejected_dash_and_dash_after_contact_do_not_retroactively_cancel() -> void:
	_controlled_fall()
	_runtime.stats.set_stat(_entity, StatBlock.Stat.ENERGY, 0)
	_player.set_dash_pressed(true)
	await _wait_landing()
	assert_int(_player.dash_activations).is_equal(0)
	assert_int(_runtime.landings.get_cancel_flags(0)).is_equal(0)
	_runtime.stats.set_stat(_entity, StatBlock.Stat.ENERGY, 3000)
	_player.set_dash_pressed(false)
	_player.set_dash_pressed(true)
	await _ticks(1)
	assert_int(_player.dash_activations).is_equal(1)
	assert_int(_runtime.landings.get_cancel_flags(0)).is_equal(0)

func test_air_slide_prearm_exact_boundary_free_until_success_and_next_step() -> void:
	_controlled_fall(13)
	_player.set_move_input(Vector2.RIGHT)
	_player.set_slide_pressed(true)
	await _ticks(1)
	assert_int(_energy()).is_equal(3000)
	assert_int(_player.slide_activations).is_equal(0)
	await _wait_landing()
	assert_int(_player._physical_tick).is_equal(13)
	assert_int(_energy()).is_equal(2500)
	assert_bool(_player.is_sliding()).is_true()
	assert_int(_player._slide_ticks).is_equal(36)
	assert_int(_runtime.landings.get_cancel_flags(0)).is_equal(LandingEventQueue.CANCEL_SLIDE)
	_player.set_move_input(Vector2.LEFT)
	await _ticks(1)
	assert_float(_player.velocity.x).is_equal_approx(8.0, 0.01)
	assert_int(_player._slide_ticks).is_equal(35)

func test_air_slide_prearm_outside_window_held_and_failed_energy_do_not_protect() -> void:
	_controlled_fall(14)
	_player.set_move_input(Vector2.RIGHT)
	_player.set_slide_pressed(true)
	for tick: int in 14:
		_player.set_slide_pressed(true)
		await _ticks(1)
	assert_bool(_player.is_on_floor()).is_true()
	assert_int(_player.slide_activations).is_equal(0)
	assert_int(_runtime.landings.get_cancel_flags(0)).is_equal(0)
	assert_int(_energy()).is_equal(3000)
	# New physical lifecycle, fresh edge, insufficient energy at real landing.
	_player.bind_mobility(null, StatBlock.INVALID_HANDLE)
	_player.bind_mobility(_runtime, _entity)
	_runtime.landings.clear()
	_runtime.stats.set_stat(_entity, StatBlock.Stat.ENERGY, 499)
	_controlled_fall(13)
	_player.set_move_input(Vector2.RIGHT)
	_player.set_slide_pressed(false)
	await _ticks(1)  # discard old floor contact before prearm
	_player.set_slide_pressed(true)
	await _ticks(1)
	assert_int(_player._slide_prearm_tick).is_greater_equal(0)
	assert_float(Vector2(_player.velocity.x, _player.velocity.z).length()).is_greater_equal(4.0)
	await _wait_landing()
	assert_int(_runtime.landings.get_cancel_flags(0)).is_equal(0)
	assert_int(_energy()).is_equal(499)

func test_air_slide_prearm_speed_and_dash_incompatibility_refusals() -> void:
	_controlled_fall(13)
	_player.set_slide_pressed(false)
	_player.set_slide_pressed(true)
	await _ticks(1)
	assert_int(_player._slide_prearm_tick).is_greater_equal(0)
	assert_float(Vector2(_player.velocity.x, _player.velocity.z).length()).is_less(4.0)
	await _wait_landing()
	assert_int(_runtime.landings.get_cancel_flags(0)).is_equal(0)
	assert_int(_energy()).is_equal(3000)
	_player.bind_mobility(null, StatBlock.INVALID_HANDLE)
	_player.bind_mobility(_runtime, _entity)
	_runtime.landings.clear()
	_controlled_fall(13)
	_player.set_move_input(Vector2.RIGHT)
	await _ticks(10)
	assert_float(Vector2(_player.velocity.x, _player.velocity.z).length()).is_greater_equal(4.0)
	_player.set_slide_pressed(false)
	_player.set_slide_pressed(true)
	_player.set_dash_pressed(true)
	await _ticks(1)
	assert_int(_player._slide_prearm_tick).is_greater_equal(0)
	assert_float(Vector2(_player.velocity.x, _player.velocity.z).length()).is_greater_equal(4.0)
	await _wait_landing()
	assert_int(_player.slide_activations).is_equal(0)
	assert_int(_runtime.landings.get_cancel_flags(0)).is_equal(LandingEventQueue.CANCEL_DASH)
	assert_int(_energy()).is_equal(2000)

func test_two_controllers_share_single_regen_and_scene_subscriber_lifecycle() -> void:
	var second: FPSController = _make_player()
	var other: int = _spawn()
	second.bind_mobility(_runtime, other)
	_runtime.stats.set_stat(_entity, StatBlock.Stat.ENERGY, 0)
	_runtime.stats.set_stat(other, StatBlock.Stat.ENERGY, 0)
	GameLoop.logic_tick.connect(_runtime.logic_step)
	await _ticks(60)
	GameLoop.logic_tick.disconnect(_runtime.logic_step)
	assert_int(_runtime.logic_steps).is_equal(30)
	assert_int(_energy()).is_equal(1500)
	assert_int(_runtime.stats.get_stat(other, StatBlock.Stat.ENERGY)).is_equal(1500)
	var before: int = GameLoop.logic_tick.get_connections().size()
	var scene: Node3D = load("res://world/sandbox/Sandbox.tscn").instantiate() as Node3D
	(scene.get_node(^"Player") as FPSController).hardware_input_enabled = false
	_arena.add_child(scene)
	assert_int(GameLoop.logic_tick.get_connections().size()).is_equal(before + 1)
	scene.free()
	assert_int(GameLoop.logic_tick.get_connections().size()).is_equal(before)

func test_invalid_sandbox_preset_disables_controller_and_logic_subscription() -> void:
	var before: int = GameLoop.logic_tick.get_connections().size()
	var scene: Sandbox = load("res://world/sandbox/Sandbox.tscn").instantiate() as Sandbox
	scene.movement_data_directory = "res://tests/fixtures/movement_invalid"
	var player: FPSController = scene.get_node(^"Player") as FPSController
	player.hardware_input_enabled = false
	var initial_position: Vector3 = player.position
	await assert_error(func() -> void: _arena.add_child(scene)) \
		.is_push_error("Sandbox: movement grant failed")
	assert_int(scene.process_mode).is_equal(Node.PROCESS_MODE_DISABLED)
	assert_int(GameLoop.logic_tick.get_connections().size()).is_equal(before)
	await _ticks(3)
	assert_int(player._physical_tick).is_equal(0)
	assert_vector(player.position).is_equal(initial_position)

class ActiveMobilityMeasure extends Node:
	signal finished
	const WARMUP: int = 300
	const MEASURE: int = 3600
	var player: FPSController
	var runtime: MobilityRuntime
	var ticks: int = 0
	var distance: float = 0.0
	var dash_count: int
	var slide_count: int
	var double_count: int
	var landing_count: int
	var regen_count: int
	var objects_delta: int
	var nodes_delta: int
	var resources_delta: int
	var orphans_delta: int
	var memory_delta: int
	var _position: Vector3
	var _objects: int
	var _nodes: int
	var _resources: int
	var _orphans: int
	var _memory: int
	var _dash: int
	var _slide: int
	var _double: int
	var _landing: int
	var _regen: int

	func _ready() -> void:
		process_physics_priority = 20
		_position = player.position

	func _physics_process(_delta: float) -> void:
		ticks += 1
		if ticks == WARMUP:
			_objects = int(Performance.get_monitor(Performance.OBJECT_COUNT))
			_nodes = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
			_resources = int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT))
			_orphans = int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
			_memory = int(Performance.get_monitor(Performance.MEMORY_STATIC))
			_dash = player.dash_activations
			_slide = player.slide_activations
			_double = player.double_jump_activations
			_landing = player.landing_events
			_regen = runtime.logic_steps
		elif ticks > WARMUP:
			distance += player.position.distance_to(_position)
		if ticks == WARMUP + MEASURE:
			objects_delta = int(Performance.get_monitor(Performance.OBJECT_COUNT)) - _objects
			nodes_delta = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)) - _nodes
			resources_delta = int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)) - _resources
			orphans_delta = int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)) - _orphans
			memory_delta = int(Performance.get_monitor(Performance.MEMORY_STATIC)) - _memory
			dash_count = player.dash_activations - _dash
			slide_count = player.slide_activations - _slide
			double_count = player.double_jump_activations - _double
			landing_count = player.landing_events - _landing
			regen_count = runtime.logic_steps - _regen
			set_physics_process(false)
			finished.emit()  # Snapshots precede signal/coroutine/assert allocations.
			return
		_position = player.position
		player.set_move_input(Vector2.RIGHT)
		var phase: int = ticks % 240
		player.set_jump_pressed(phase == 2 or phase == 14)
		player.set_dash_pressed(phase == 28 or phase == 170)
		player.set_slide_pressed(phase == 120)

func test_active_mobility_does_not_allocate_after_warmup(_timeout: int = 120000) -> void:
	var measure := ActiveMobilityMeasure.new()
	measure.player = _player
	measure.runtime = _runtime
	GameLoop.logic_tick.connect(_runtime.logic_step)
	_arena.add_child(measure)
	await measure.finished
	GameLoop.logic_tick.disconnect(_runtime.logic_step)
	print("MOBILITY ACTIVE ticks=%d distance=%.2f dash=%d slide=%d double=%d landing=%d regen=%d objects=%d nodes=%d resources=%d orphans=%d memory=%d dropped=%d" % [
		measure.ticks, measure.distance, measure.dash_count, measure.slide_count, measure.double_count,
		measure.landing_count, measure.regen_count, measure.objects_delta, measure.nodes_delta,
		measure.resources_delta, measure.orphans_delta, measure.memory_delta, _runtime.landings.dropped_count()])
	assert_int(measure.ticks).is_equal(3900)
	assert_float(measure.distance).is_greater(450.0)
	assert_int(measure.dash_count).is_equal(30)
	assert_int(measure.slide_count).is_equal(15)
	assert_int(measure.double_count).is_equal(15)
	assert_int(measure.landing_count).is_equal(15)
	assert_int(measure.regen_count).is_equal(1800)
	assert_int(measure.objects_delta).is_equal(0)
	assert_int(measure.nodes_delta).is_equal(0)
	assert_int(measure.resources_delta).is_equal(0)
	assert_int(measure.orphans_delta).is_equal(0)
	assert_int(measure.memory_delta).is_less_equal(1024 * 1024)
	assert_int(_runtime.landings.dropped_count()).is_equal(0)

func test_dash_active_and_cooldown_refusals_do_not_pay_or_change_direction() -> void:
	await _settle()
	_player.set_dash_pressed(true)
	await _ticks(1)
	var ready: int = _runtime.abilities.ready_tick(_entity, MovementAbilityData.Kind.DASH)
	_player.set_dash_pressed(false)
	_player.set_dash_pressed(true)
	_player.set_move_input(Vector2.RIGHT)
	await _ticks(1)
	assert_int(_energy()).is_equal(2000)
	assert_int(_runtime.abilities.ready_tick(_entity, MovementAbilityData.Kind.DASH)).is_equal(ready)
	await _ticks(7)
	_player.set_dash_pressed(false)
	_player.set_dash_pressed(true)
	await _ticks(1)
	assert_int(_energy()).is_equal(2000)
	assert_int(_player.dash_activations).is_equal(1)
	await _ticks(12)
	_player.set_dash_pressed(false)
	_player.set_dash_pressed(true)
	await _ticks(1)
	assert_int(_energy()).is_equal(1000)
	assert_int(_player.dash_activations).is_equal(2)

func test_double_jump_energy_refusal_does_not_spend_air_use() -> void:
	await _settle()
	_runtime.stats.set_stat(_entity, StatBlock.Stat.ENERGY, 999)
	_player.set_jump_pressed(true)
	await _ticks(1)
	_player.set_jump_pressed(false)
	_player.set_jump_pressed(true)
	await _ticks(1)
	assert_bool(_player._double_jump_used).is_false()
	assert_int(_energy()).is_equal(999)
	_runtime.stats.set_stat(_entity, StatBlock.Stat.ENERGY, 1000)
	_player.set_jump_pressed(false)
	_player.set_jump_pressed(true)
	await _ticks(1)
	assert_bool(_player._double_jump_used).is_true()
	assert_int(_energy()).is_equal(0)
	assert_int(_player.double_jump_activations).is_equal(1)

func test_slide_prearm_cooldown_refusal_does_not_protect() -> void:
	const TEST_COOLDOWN_TICKS: int = 120
	var activated_at_tick: int = GameLoop.get_logic_tick()
	assert_bool(_runtime.abilities.grant(_entity, MovementAbilityData.Kind.SLIDE,
			500, TEST_COOLDOWN_TICKS, true, false)).is_true()
	assert_bool(_runtime.abilities.try_activate(_entity, MovementAbilityData.Kind.SLIDE,
			activated_at_tick, false, _runtime.stats)).is_true()
	var expected_ready_tick: int = activated_at_tick + TEST_COOLDOWN_TICKS
	assert_int(_runtime.abilities.ready_tick(_entity, MovementAbilityData.Kind.SLIDE)).is_equal(expected_ready_tick)
	_runtime.stats.set_stat(_entity, StatBlock.Stat.ENERGY, 3000)
	_controlled_fall(13)
	_player.set_move_input(Vector2.RIGHT)
	_player.set_slide_pressed(false)
	_player.set_slide_pressed(true)
	await _ticks(1)
	assert_int(_player._slide_prearm_tick).is_greater_equal(0)
	var prearm_tick: int = _player._slide_prearm_tick
	assert_bool(_player.is_on_floor()).is_false()
	assert_bool(_player.is_dashing()).is_false()
	assert_bool(_player.is_sliding()).is_false()
	assert_int(_energy()).is_equal(3000)
	assert_float(Vector2(_player.velocity.x, _player.velocity.z).length()).is_greater_equal(4.0)
	assert_int(GameLoop.get_logic_tick()).is_less(expected_ready_tick)
	await _wait_landing()
	assert_int(GameLoop.get_logic_tick()).is_less(expected_ready_tick)
	assert_int(_player._physical_tick - prearm_tick).is_equal(FPSController.CANCEL_WINDOW_TICKS)
	assert_float(Vector2(_player.velocity.x, _player.velocity.z).length()).is_greater_equal(4.0)
	assert_bool(_player.is_dashing()).is_false()
	assert_bool(_player.is_sliding()).is_false()
	assert_int(_runtime.landings.count()).is_equal(1)
	assert_int(_runtime.landings.get_cancel_flags(0)).is_equal(0)
	assert_int(_player.slide_activations).is_equal(0)
	assert_int(_energy()).is_equal(3000)
	assert_int(_runtime.abilities.ready_tick(_entity, MovementAbilityData.Kind.SLIDE)).is_equal(expected_ready_tick)


func test_slide_prearm_focus_refusal_does_not_protect() -> void:
	_player.bind_mobility(null, StatBlock.INVALID_HANDLE)
	_player.bind_mobility(_runtime, _entity)
	_runtime.landings.clear()
	_controlled_fall(13)
	_player.set_move_input(Vector2.RIGHT)
	_player.set_slide_pressed(false)
	_player.set_slide_pressed(true)
	await _ticks(1)
	assert_int(_player._slide_prearm_tick).is_greater_equal(0)
	assert_float(Vector2(_player.velocity.x, _player.velocity.z).length()).is_greater_equal(4.0)
	_player._notification(NOTIFICATION_APPLICATION_FOCUS_OUT)
	await _wait_landing()
	assert_int(_runtime.landings.get_cancel_flags(0)).is_equal(0)
	assert_int(_player._slide_prearm_tick).is_equal(-1)
	assert_int(_energy()).is_equal(3000)

func test_landing_height_tracks_peak_rather_than_spawn_or_speed() -> void:
	_controlled_fall(13)
	_player.velocity.y = 51.0
	await _ticks(5)
	_player.velocity.y = -51.0
	await _wait_landing(30)
	assert_int(_runtime.landings.count()).is_equal(1)
	assert_int(_runtime.landings.get_height_mm(0)).is_between(15_190, 15_200)
	_runtime.logic_step(0)
	assert_int(_runtime.stats.get_stat(_entity, StatBlock.Stat.HP)).is_between(28_000, 28_100)

func test_same_identity_bind_preserves_air_limit_velocity_active_action_and_queued_input() -> void:
	await _settle()
	_runtime.abilities.grant(_entity, MovementAbilityData.Kind.DOUBLE_JUMP, 0, 0, false, true)
	_player.set_jump_pressed(true)
	await _ticks(1)
	_player.set_jump_pressed(false)
	_player.set_jump_pressed(true)
	await _ticks(1)
	var before: Vector3 = _player.velocity
	var peak: float = _player._peak_world_y
	_player.set_move_input(Vector2.RIGHT)
	_player.set_jump_pressed(false)
	_player.set_jump_pressed(true)
	_player.bind_mobility(_runtime, _entity)
	assert_vector(_player.velocity).is_equal(before)
	assert_float(_player._peak_world_y).is_equal(peak)
	assert_bool(_player._double_jump_used).is_true()
	assert_bool(_player._jump_requested).is_true()
	await _ticks(1)
	assert_int(_player.double_jump_activations).is_equal(1)
	assert_float(_player.velocity.y).is_less(5.5)
	assert_float(_player.velocity.x).is_equal_approx(8.0, 0.01)
	_player.set_dash_pressed(true)
	await _ticks(1)
	var remaining: int = _player._dash_ticks
	before = _player.velocity
	_player.bind_mobility(_runtime, _entity)
	assert_int(_player._dash_ticks).is_equal(remaining)
	assert_vector(_player.velocity).is_equal(before)


func test_same_bind_during_high_fall_cannot_lower_peak_or_damage() -> void:
	_controlled_fall(13)
	await _ticks(6)
	var peak: float = _player._peak_world_y
	var before: Vector3 = _player.velocity
	_player.bind_mobility(_runtime, _entity)
	assert_float(_player._peak_world_y).is_equal(peak)
	assert_vector(_player.velocity).is_equal(before)
	await _wait_landing()
	assert_int(_runtime.landings.get_height_mm(0)).is_between(10_940, 10_960)
	_runtime.logic_step(0)
	assert_int(_runtime.stats.get_stat(_entity, StatBlock.Stat.HP)).is_between(70_490, 70_520)


func test_new_generation_or_runtime_binding_starts_new_physical_lifecycle() -> void:
	_player.position.y = 6.0
	await _ticks(1)
	_player.set_jump_pressed(true)
	await _ticks(1)
	assert_bool(_player._double_jump_used).is_true()
	var old: int = _entity
	_runtime.stats.release(old)
	var replacement: int = _spawn()
	assert_int(replacement % StatBlock.HANDLE_INDEX_SPAN).is_equal(old % StatBlock.HANDLE_INDEX_SPAN)
	assert_int(replacement).is_not_equal(old)
	_player.bind_mobility(_runtime, replacement)
	assert_bool(_player._double_jump_used).is_false()
	assert_vector(_player.velocity).is_equal(Vector3.ZERO)
	assert_bool(_player._air_episode).is_false()
	_player.set_jump_pressed(true)
	await _ticks(1)
	assert_bool(_player._double_jump_used).is_true()
	var different := MobilityRuntime.new(StatBlock.new(1))
	different.stats.release(different.stats.allocate())
	var other: int = different.stats.allocate()
	assert_int(other).is_equal(replacement)  # same full handle, DIFFERENT runtime reference
	_player.bind_mobility(different, other)
	assert_bool(_player._double_jump_used).is_false()
	assert_vector(_player.velocity).is_equal(Vector3.ZERO)
	_player.set_move_input(Vector2.RIGHT)
	_player.bind_mobility(null, StatBlock.INVALID_HANDLE)
	assert_int(_player.mobility_entity()).is_equal(StatBlock.INVALID_HANDLE)
	assert_vector(_player._move_input).is_equal(Vector2.ZERO)


func test_scene_clock_reset_uses_exact_old_game_loop_tick() -> void:
	var scene: Sandbox = load("res://world/sandbox/Sandbox.tscn").instantiate() as Sandbox
	(scene.get_node(^"Player") as FPSController).hardware_input_enabled = false
	_arena.add_child(scene)
	var runtime: MobilityRuntime = scene.mobility
	var entity: int = scene.player_handle
	assert_bool(runtime.abilities.try_activate(entity, MovementAbilityData.Kind.DASH,
		GameLoop.get_logic_tick(), false, runtime.stats)).is_true()
	scene.reset_mobility_clock()
	assert_int(GameLoop.get_logic_tick()).is_equal(0)
	assert_int(runtime.abilities.ready_tick(entity, MovementAbilityData.Kind.DASH)).is_equal(6)
	assert_int(runtime.stats.get_stat(entity, StatBlock.Stat.ENERGY)).is_equal(2000)
	await _ticks(2)
	assert_int(runtime.logic_steps).is_equal(1)
	assert_int(runtime.stats.get_stat(entity, StatBlock.Stat.ENERGY)).is_equal(2050)
	scene.free()
