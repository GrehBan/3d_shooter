extends GdUnitTestSuite
## M1 frame layer: weapon bob/sway and camera bob are presentation only.

const SANDBOX: PackedScene = preload("res://world/sandbox/Sandbox.tscn")
const VALIDATOR_SHIFT: int = 24
const VALIDATOR_MASK: int = (1 << 39) - 1
const EPSILON: float = 0.0001

var _scene: Node3D


func after_test() -> void:
	if is_instance_valid(_scene):
		_scene.free()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


## Runs `seconds` of one motion segment with a fixed frame delta.
func _run(model: ViewmodelSwayModel, delta: float, seconds: float, speed: float,
		grounded: bool, yaw_rate: float = 0.0, pitch_rate: float = 0.0) -> void:
	for frame: int in roundi(seconds / delta):
		model.step(delta, speed, grounded, yaw_rate, pitch_rate)


func test_walking_bobs_and_rest_returns_to_zero() -> void:
	var model := ViewmodelSwayModel.new()
	_run(model, 1.0 / 60.0, 0.9, 8.0, true)
	var walking: float = model.offset.length()
	var camera_walking: float = model.camera_offset.length()
	_run(model, 1.0 / 60.0, 2.0, 0.0, true)
	assert_float(walking).is_greater(0.001)
	assert_float(camera_walking).is_greater(0.0)
	assert_float(model.offset.length()).is_less(EPSILON)
	assert_float(model.camera_offset.length()).is_less(EPSILON)
	assert_float(absf(model.roll)).is_less(EPSILON)


func test_airborne_step_bob_fades() -> void:
	var model := ViewmodelSwayModel.new()
	_run(model, 1.0 / 60.0, 1.0, 8.0, true)
	_run(model, 1.0 / 60.0, 2.0, 8.0, false)  # same speed, but no ground contact
	assert_float(model.offset.length()).is_less(EPSILON)
	assert_float(model.camera_offset.length()).is_less(EPSILON)


func test_look_sway_is_bounded() -> void:
	var model := ViewmodelSwayModel.new()
	_run(model, 1.0 / 60.0, 1.0, 0.0, true, 50.0, -50.0)  # a violent mouse flick
	assert_float(Vector2(model.offset.x, model.offset.y).length()).is_less_equal(model.max_sway_m + EPSILON)
	assert_float(model.offset.x).is_less(0.0)  # the weapon lags against the yaw
	_run(model, 1.0 / 60.0, 2.0, 0.0, true)
	assert_float(model.offset.length()).is_less(EPSILON)


func test_same_motion_gives_same_pose_at_30_60_144_fps() -> void:
	var poses: Array[Vector3] = []
	var cameras: Array[Vector2] = []
	for fps: int in [30, 60, 144]:
		var model := ViewmodelSwayModel.new()
		var delta: float = 1.0 / float(fps)
		_run(model, delta, 1.0, 8.0, true)
		_run(model, delta, 0.5, 6.0, true, 2.0, 0.5)
		_run(model, delta, 0.5, 6.0, false)
		poses.append(model.offset)
		cameras.append(model.camera_offset)
	assert_float((poses[0] - poses[1]).length()).is_less(0.001)
	assert_float((poses[2] - poses[1]).length()).is_less(0.001)
	assert_float((cameras[0] - cameras[1]).length()).is_less(0.001)
	assert_float((cameras[2] - cameras[1]).length()).is_less(0.001)


func test_camera_bob_is_clamped_and_rests_at_zero() -> void:
	var model := ViewmodelSwayModel.new()
	model.camera_bob_m = 0.2  # a misconfigured amplitude stays within the hard limit
	var worst: float = 0.0
	for frame: int in 600:
		model.step(1.0 / 144.0, 12.0, true, 0.0, 0.0)
		worst = maxf(worst, maxf(absf(model.camera_offset.x), absf(model.camera_offset.y)))
	_run(model, 1.0 / 144.0, 2.0, 0.0, true)
	assert_float(worst).is_greater(0.0)
	assert_float(worst).is_less_equal(ViewmodelSwayModel.CAMERA_BOB_LIMIT_M)
	assert_float(model.camera_offset.length()).is_less(EPSILON)


func test_zero_intensity_disables_bob_and_sway() -> void:
	var model := ViewmodelSwayModel.new()
	model.intensity = 0.0
	var largest: float = 0.0
	for frame: int in 300:
		model.step(1.0 / 60.0, 8.0, true, 5.0, 5.0)
		largest = maxf(largest, model.offset.length() + model.camera_offset.length() + absf(model.roll))
	assert_float(largest).is_equal(0.0)


func _sandbox() -> ViewmodelSway:
	_scene = SANDBOX.instantiate() as Node3D
	(_scene.get_node(^"Player") as FPSController).hardware_input_enabled = false
	(_scene.get_node(^"Player/Camera3D/HitscanWeapon") as HitscanWeapon).hardware_input_enabled = false
	add_child(_scene)
	var sway := _scene.get_node(^"Player/Camera3D/HitscanWeapon/Viewmodel") as ViewmodelSway
	sway.set_process(false)  # the test drives the frames explicitly
	return sway


func _ray_transforms(weapon: HitscanWeapon) -> Array[Transform3D]:
	var out: Array[Transform3D] = [weapon.global_transform]
	for child: Node in weapon.get_children():
		if child is RayCast3D:
			out.append((child as RayCast3D).global_transform)
	return out


func test_sway_never_moves_camera_weapon_or_rays() -> void:
	var sway: ViewmodelSway = _sandbox()
	var player := _scene.get_node(^"Player") as FPSController
	var camera := _scene.get_node(^"Player/Camera3D") as Camera3D
	var weapon := _scene.get_node(^"Player/Camera3D/HitscanWeapon") as HitscanWeapon
	player.set_physics_process(false)  # freeze the physical pose, only frames run
	player.velocity = Vector3(8, 0, 0)
	player.motion_state = FPSController.MotionState.GROUND
	var camera_before: Transform3D = camera.global_transform
	var rays_before: Array[Transform3D] = _ray_transforms(weapon)
	var largest: float = 0.0
	for frame: int in 600:
		sway._process(1.0 / 144.0)
		largest = maxf(largest, sway.position.length())
	var rays_after: Array[Transform3D] = _ray_transforms(weapon)
	assert_int(sway.physics_interpolation_mode).is_equal(Node.PHYSICS_INTERPOLATION_MODE_OFF)
	assert_float(largest).is_greater(0.001)  # the viewmodel really moved
	assert_bool(camera.global_transform.is_equal_approx(camera_before)).is_true()
	assert_int(rays_after.size()).is_equal(rays_before.size())
	assert_int(rays_after.size()).is_greater(8)
	for index: int in rays_after.size():
		assert_bool(rays_after[index].is_equal_approx(rays_before[index])).is_true()
	assert_float(absf(camera.v_offset)).is_less_equal(ViewmodelSwayModel.CAMERA_BOB_LIMIT_M)


func test_frame_step_does_not_allocate() -> void:
	var sway: ViewmodelSway = _sandbox()
	var player := _scene.get_node(^"Player") as FPSController
	player.set_physics_process(false)
	player.velocity = Vector3(6, 0, 2)
	player.motion_state = FPSController.MotionState.GROUND
	for frame: int in 300:
		sway._process(1.0 / 144.0)
	var objects: int = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var memory: int = int(Performance.get_monitor(Performance.MEMORY_STATIC))
	var validator: int = (RefCounted.new().get_instance_id() >> VALIDATOR_SHIFT) & VALIDATOR_MASK
	for frame: int in 3600:
		sway._process(1.0 / 144.0)
	var created: int = ((RefCounted.new().get_instance_id() >> VALIDATOR_SHIFT) & VALIDATOR_MASK) - validator - 1
	var object_delta: int = int(Performance.get_monitor(Performance.OBJECT_COUNT)) - objects
	var memory_delta: int = int(Performance.get_monitor(Performance.MEMORY_STATIC)) - memory
	assert_int(object_delta).is_equal(0)
	assert_int(created).is_equal(0)
	assert_int(memory_delta).is_less_equal(4096)
