extends GdUnitTestSuite
## Real Jolt bodies; tolerances describe engine physics, not bit-exact combat math.

const SANDBOX: PackedScene = preload("res://world/sandbox/Sandbox.tscn")
var _viewport: SubViewport
var _arena: Node3D
var _player: FPSController
var _saved_mouse_mode: Input.MouseMode
var _barrier: PhysicsStepBarrier


class PhysicsStepBarrier extends Node:
	signal stepped


	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		process_physics_priority = 1100


	func _physics_process(_delta: float) -> void:
		stepped.emit()


class MotionMeasure extends Node:
	signal finished
	const WARMUP: int = 300
	const MEASURE: int = 3600
	var player: FPSController
	var ticks: int = 0
	var distance: float = 0.0
	var jumps: int = 0
	var landings: int = 0
	var _previous_position: Vector3
	var _previous_grounded: bool = false
	var _objects: int
	var _nodes: int
	var _resources: int
	var _orphans: int
	var _memory: int
	var objects_delta: int
	var nodes_delta: int
	var resources_delta: int
	var orphans_delta: int
	var memory_delta: int

	func _ready() -> void:
		# Runs after the real controller. Commands are consumed on the next tick.
		process_physics_priority = 10
		_previous_position = player.position
		_previous_grounded = player.is_on_floor()

	func _physics_process(_delta: float) -> void:
		ticks += 1
		if ticks == WARMUP:
			_objects = int(Performance.get_monitor(Performance.OBJECT_COUNT))
			_nodes = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
			_resources = int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT))
			_orphans = int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
			_memory = int(Performance.get_monitor(Performance.MEMORY_STATIC))
		elif ticks > WARMUP:
			distance += player.position.distance_to(_previous_position)
			if _previous_grounded and not player.is_on_floor() and player.velocity.y > 0.0:
				jumps += 1
			if not _previous_grounded and player.is_on_floor():
				landings += 1
		if ticks == WARMUP + MEASURE:
			objects_delta = int(Performance.get_monitor(Performance.OBJECT_COUNT)) - _objects
			nodes_delta = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)) - _nodes
			resources_delta = int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)) - _resources
			orphans_delta = int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)) - _orphans
			memory_delta = int(Performance.get_monitor(Performance.MEMORY_STATIC)) - _memory
			set_physics_process(false)
			finished.emit()  # All counters are captured before coroutine/assert allocations.
			return
		_previous_position = player.position
		_previous_grounded = player.is_on_floor()
		match (ticks / 60) % 4:
			0: player.set_move_input(Vector2.RIGHT)
			1: player.set_move_input(Vector2.UP)
			2: player.set_move_input(Vector2.LEFT)
			3: player.set_move_input(Vector2.DOWN)
		player.set_jump_pressed(ticks % 120 == 1)
		player.add_look_input(Vector2(0.0, 0.25 if ticks % 2 == 0 else -0.25))


func before_test() -> void:
	_saved_mouse_mode = Input.mouse_mode
	process_mode = Node.PROCESS_MODE_ALWAYS
	_viewport = SubViewport.new()
	_viewport.process_mode = Node.PROCESS_MODE_PAUSABLE
	_viewport.world_3d = World3D.new()
	_viewport.size = Vector2i(64, 64)
	add_child(_viewport)
	_arena = Node3D.new()
	_viewport.add_child(_arena)
	_add_box(Vector3(200.0, 1.0, 200.0), Vector3(0.0, -0.5, 0.0))
	_player = FPSController.new()
	_player.hardware_input_enabled = false
	_player.collision_layer = 2
	_player.collision_mask = 1
	_player.position = Vector3(0.0, 0.95, 0.0)
	var shape := CapsuleShape3D.new()
	shape.radius = 0.35
	shape.height = 1.8
	var collision := CollisionShape3D.new()
	collision.shape = shape
	_player.add_child(collision)
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	camera.position.y = 0.65
	_player.add_child(camera)
	_arena.add_child(_player)
	_barrier = PhysicsStepBarrier.new()
	_arena.add_child(_barrier)


func after_test() -> void:
	get_tree().paused = false
	Input.action_release(&"move_forward")
	Input.mouse_mode = _saved_mouse_mode
	if is_instance_valid(_viewport):
		_viewport.free()


func _add_box(size: Vector3, origin: Vector3, tilt: float = 0.0) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = origin
	body.rotation.x = tilt
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
		await _barrier.stepped


func _settle() -> void:
	await _ticks(30)
	assert_bool(_player.is_on_floor()).is_true()
	assert_int(_player.motion_state).is_equal(FPSController.MotionState.GROUND)


func test_ground_motion_and_diagonal_speed() -> void:
	await _settle()
	var start: Vector3 = _player.position
	_player.set_move_input(Vector2.UP)
	await _ticks(30)
	var straight_distance: float = _player.position.distance_to(start)
	assert_float(straight_distance).is_equal_approx(4.0, 0.15)
	assert_float(_player.velocity.length()).is_equal_approx(8.0, 0.02)
	start = _player.position
	_player.set_move_input(Vector2(1.0, -1.0))
	await _ticks(30)
	assert_float(_player.position.distance_to(start)).is_equal_approx(straight_distance, 0.15)
	assert_float(Vector2(_player.velocity.x, _player.velocity.z).length()).is_equal_approx(8.0, 0.02)
	_player.set_move_input(Vector2.ZERO)
	await _ticks(2)
	assert_float(_player.velocity.length()).is_equal_approx(0.0, 0.02)


func test_analog_input_and_tunable_speed_preserve_magnitude() -> void:
	await _settle()
	_player.move_speed = 10.0
	_player.set_move_input(Vector2(0.5, 0.0))
	await _ticks(30)
	assert_float(_player.position.x).is_equal_approx(2.5, 0.15)
	assert_float(_player.velocity.x).is_equal_approx(5.0, 0.01)
	_player.set_move_input(Vector2(100.0, 0.0))
	await _ticks(1)
	assert_float(_player.velocity.x).is_equal_approx(10.0, 0.01)


func test_nonfinite_commands_do_not_poison_physics() -> void:
	await _settle()
	_player.set_move_input(Vector2(NAN, 1.0))
	_player.add_look_input(Vector2(INF, 1.0))
	await _ticks(2)
	assert_bool(_player.position.is_finite()).is_true()
	assert_float(_player.velocity.length()).is_equal_approx(0.0, 0.01)
	assert_float(_player.rotation.y).is_equal(0.0)


func test_look_accumulates_only_in_physics_and_clamps_pitch() -> void:
	await _settle()
	var camera: Camera3D = _player.get_node(^"Camera3D") as Camera3D
	_player.add_look_input(Vector2(100.0, -100.0))
	_player.add_look_input(Vector2(50.0, -50.0))
	assert_float(_player.rotation.y).is_equal(0.0)
	assert_float(camera.rotation.x).is_equal(0.0)
	await _ticks(1)
	assert_float(_player.rotation.y).is_equal_approx(-0.3, 0.0001)
	assert_float(camera.rotation.x).is_equal_approx(0.3, 0.0001)
	await _ticks(2)
	assert_float(_player.rotation.y).is_equal_approx(-0.3, 0.0001)
	_player.add_look_input(Vector2(0.0, -100000.0))
	await _ticks(1)
	assert_float(camera.rotation.x).is_equal_approx(deg_to_rad(85.0), 0.0001)
	_player.add_look_input(Vector2(0.0, 100000.0))
	await _ticks(1)
	assert_float(camera.rotation.x).is_equal_approx(-deg_to_rad(85.0), 0.0001)


func test_yaw_relative_motion_stays_horizontal_at_pitch_limit() -> void:
	await _settle()
	_player.add_look_input(Vector2(-PI / (2.0 * _player.mouse_sensitivity), -100000.0))
	await _ticks(1)
	var start: Vector3 = _player.position
	_player.set_move_input(Vector2.UP)
	await _ticks(30)
	assert_float(_player.position.x - start.x).is_equal_approx(-4.0, 0.15)
	assert_float(_player.position.z - start.z).is_equal_approx(0.0, 0.02)
	assert_float(_player.position.y - start.y).is_equal_approx(0.0, 0.02)


func test_world_wall_blocks_real_body() -> void:
	_add_box(Vector3(8.0, 3.0, 0.5), Vector3(0.0, 1.5, -2.0))
	await _settle()
	_player.set_move_input(Vector2.UP)
	await _ticks(60)
	assert_bool(_player.is_on_wall()).is_true()
	assert_float(_player.position.z).is_equal_approx(-1.4, 0.03)
	assert_bool(_player.is_on_floor()).is_true()


func test_yaw_parent_uniform_scale_preserves_world_direction_and_speed() -> void:
	var parent := Node3D.new()
	parent.rotation.y = PI / 2.0
	parent.scale = Vector3.ONE * 2.0
	_arena.add_child(parent)
	_player.reparent(parent, false)
	_player.reset_physics_interpolation()
	await _settle()
	var camera: Camera3D = _player.get_node(^"Camera3D") as Camera3D
	var forward: Vector3 = -camera.global_transform.basis.z.normalized()
	assert_float(forward.dot(Vector3.LEFT)).is_greater(0.999)
	var start: Vector3 = _player.global_position
	_player.set_move_input(Vector2.UP)
	await _ticks(30)
	var displacement: Vector3 = _player.global_position - start
	assert_float(displacement.dot(forward)).is_equal_approx(4.0, 0.15)
	assert_float(displacement.length()).is_equal_approx(4.0, 0.15)
	assert_float(Vector2(_player.velocity.x, _player.velocity.z).length()).is_equal_approx(8.0, 0.02)
	start = _player.global_position
	_player.set_move_input(Vector2(0.0, -0.5))
	await _ticks(30)
	displacement = _player.global_position - start
	assert_float(displacement.dot(forward)).is_equal_approx(2.0, 0.15)
	assert_float(displacement.length()).is_equal_approx(2.0, 0.15)
	assert_float(Vector2(_player.velocity.x, _player.velocity.z).length()).is_equal_approx(4.0, 0.02)


func test_gravity_and_landing_use_contacts() -> void:
	_player.position.y = 4.0
	_player.reset_physics_interpolation()
	await _ticks(10)
	assert_int(_player.motion_state).is_equal(FPSController.MotionState.AIR)
	assert_float(_player.position.y).is_less(3.95)
	assert_float(_player.velocity.y).is_less(-1.0)
	await _ticks(90)
	assert_bool(_player.is_on_floor()).is_true()
	assert_int(_player.motion_state).is_equal(FPSController.MotionState.GROUND)
	assert_float(_player.position.y).is_equal_approx(0.9, 0.03)


func test_jump_edge_held_input_does_not_repeat_after_landing() -> void:
	await _settle()
	_player.set_jump_pressed(true)
	await _ticks(1)
	assert_float(_player.velocity.y).is_greater(5.0)
	assert_int(_player.motion_state).is_equal(FPSController.MotionState.AIR)
	var peak: float = _player.position.y
	for tick: int in 100:
		_player.set_jump_pressed(true)
		await _ticks(1)
		peak = maxf(peak, _player.position.y)
	assert_float(peak).is_greater(2.2)
	assert_bool(_player.is_on_floor()).is_true()
	await _ticks(30)
	assert_bool(_player.is_on_floor()).is_true()
	_player.set_jump_pressed(false)
	_player.set_jump_pressed(true)
	await _ticks(1)
	assert_float(_player.velocity.y).is_greater(5.0)


func test_airborne_jump_request_expires_at_landing() -> void:
	_player.position.y = 2.0
	_player.set_jump_pressed(true)
	await _ticks(90)
	assert_bool(_player.is_on_floor()).is_true()
	assert_float(_player.position.y).is_equal_approx(0.9, 0.03)
	await _ticks(20)
	assert_bool(_player.is_on_floor()).is_true()
	_player.set_jump_pressed(false)
	_player.set_jump_pressed(true)
	await _ticks(1)
	assert_float(_player.velocity.y).is_greater(5.0)


func test_walk_off_platform_transitions_to_air_and_lands() -> void:
	_add_box(Vector3(2.0, 1.5, 2.0), Vector3(0.0, 0.75, 0.0))
	_player.position.y = 2.45
	await _settle()
	assert_float(_player.position.y).is_equal_approx(2.4, 0.03)
	_player.set_move_input(Vector2.RIGHT)
	await _ticks(15)
	assert_int(_player.motion_state).is_equal(FPSController.MotionState.AIR)
	_player.set_jump_pressed(true)
	await _ticks(1)
	assert_float(_player.velocity.y).is_less(0.0)
	await _ticks(60)
	assert_bool(_player.is_on_floor()).is_true()
	assert_float(_player.position.y).is_equal_approx(0.9, 0.03)


func test_walk_up_slope_keeps_ground_contact() -> void:
	_add_box(Vector3(4.0, 0.5, 6.0), Vector3(0.0, 0.5, -4.0), deg_to_rad(15.0))
	await _settle()
	_player.set_move_input(Vector2.UP)
	await _ticks(40)
	assert_bool(_player.is_on_floor()).is_true()
	assert_float(_player.position.y).is_greater(1.7)
	assert_float(_player.get_floor_normal().y).is_equal_approx(cos(deg_to_rad(15.0)), 0.02)


func test_pause_preserves_ground_and_air_physics_and_discards_requests() -> void:
	await _settle()
	_player.set_move_input(Vector2.RIGHT)
	await _ticks(2)
	await _check_pause()
	_player.set_jump_pressed(true)
	await _ticks(1)
	assert_int(_player.motion_state).is_equal(FPSController.MotionState.AIR)
	await _check_pause()
	await _ticks(90)
	assert_bool(_player.is_on_floor()).is_true()


func _check_pause() -> void:
	_player.add_look_input(Vector2(100.0, 100.0))
	_player.set_jump_pressed(false)
	_player.set_jump_pressed(true)
	var transform_before: Transform3D = _player.transform
	var velocity_before: Vector3 = _player.velocity
	var state_before: int = _player.motion_state
	var floor_before: bool = _player.is_on_floor()
	var logic_before: int = GameLoop.get_logic_tick()
	get_tree().paused = true
	_player.set_move_input(Vector2.DOWN)
	_player.add_look_input(Vector2(100.0, 100.0))
	_player.set_jump_pressed(true)
	await _ticks(5)
	assert_vector(_player.position).is_equal(transform_before.origin)
	assert_vector(_player.rotation).is_equal(transform_before.basis.get_euler())
	assert_vector(_player.velocity).is_equal(velocity_before)
	assert_int(_player.motion_state).is_equal(state_before)
	assert_bool(_player.is_on_floor()).is_equal(floor_before)
	assert_int(GameLoop.get_logic_tick()).is_equal(logic_before)
	get_tree().paused = false
	await _ticks(1)
	assert_float(_player.rotation.y).is_equal_approx(0.0, 0.0001)
	assert_float(_player.velocity.x).is_equal_approx(0.0, 0.001)
	assert_float(_player.velocity.y).is_less_equal(velocity_before.y)


func test_hardware_events_queue_the_same_commands() -> void:
	await _settle()
	_player.set_hardware_input_enabled(true)
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	_player._unhandled_input(click)
	var look := InputEventMouseMotion.new()
	look.screen_relative = Vector2(25.0, -10.0)
	_player._unhandled_input(look)
	var jump := InputEventAction.new()
	jump.action = &"jump"
	jump.pressed = true
	_player._unhandled_input(jump)
	Input.action_press(&"move_forward")
	assert_float(_player.rotation.y).is_equal(0.0)
	await _ticks(1)
	assert_float(_player.rotation.y).is_equal_approx(-0.05, 0.0001)
	assert_float(_player.velocity.y).is_greater(5.0)
	assert_float(Vector2(_player.velocity.x, _player.velocity.z).length()).is_equal_approx(8.0, 0.02)
	Input.action_release(&"move_forward")
	jump.pressed = false
	_player._unhandled_input(jump)
	_player.set_hardware_input_enabled(false)


func test_sandbox_wires_player_and_prototype_geometry() -> void:
	var scene: Node3D = SANDBOX.instantiate() as Node3D
	var player: FPSController = scene.get_node(^"Player") as FPSController
	player.hardware_input_enabled = false
	_arena.add_child(scene)
	assert_int(player.collision_layer).is_equal(2)
	assert_int(player.collision_mask).is_equal(1)
	assert_bool(player.get_node(^"Camera3D") is Camera3D).is_true()
	assert_bool(player.get_node(^"CollisionShape3D") is CollisionShape3D).is_true()
	assert_bool(scene.get_node(^"Wall") is StaticBody3D).is_true()
	assert_bool(scene.get_node(^"Slope") is StaticBody3D).is_true()
	assert_bool(scene.get_node(^"Platform") is StaticBody3D).is_true()
	await _ticks(30)
	assert_bool(player.is_on_floor()).is_true()


func test_actual_motion_does_not_allocate_after_warmup(_timeout: int = 120000) -> void:
	var measure := MotionMeasure.new()
	measure.player = _player
	_arena.add_child(measure)
	await measure.finished
	print("FPS MOTION ticks=%d distance=%.2f jumps=%d landings=%d objects=%d nodes=%d resources=%d orphans=%d memory=%d" % [
		measure.ticks, measure.distance, measure.jumps, measure.landings, measure.objects_delta,
		measure.nodes_delta, measure.resources_delta, measure.orphans_delta, measure.memory_delta])
	assert_int(measure.ticks).is_equal(3900)
	assert_float(measure.distance).is_greater(450.0)
	assert_int(measure.jumps).is_greater(20)
	assert_int(measure.landings).is_greater(20)
	assert_int(measure.objects_delta).is_equal(0)
	assert_int(measure.nodes_delta).is_equal(0)
	assert_int(measure.resources_delta).is_equal(0)
	assert_int(measure.orphans_delta).is_equal(0)
	assert_int(measure.memory_delta).is_less_equal(1024 * 1024)
