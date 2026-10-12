class_name FPSController
extends CharacterBody3D
## Engine physics adapter. No combat state or deterministic game math lives here.
## Input only queues commands; movement and look are applied on the 60 Hz physics tick.

enum MotionState { GROUND, AIR }

@export_range(0.0, 40.0, 0.1) var move_speed: float = 8.0
@export_range(0.0, 20.0, 0.1) var jump_velocity: float = 5.5
@export_range(0.0, 50.0, 0.1) var gravity: float = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
@export_range(0.0001, 0.02, 0.0001) var mouse_sensitivity: float = 0.002
@export_range(1.0, 89.0, 1.0) var pitch_limit_degrees: float = 85.0
@export var hardware_input_enabled: bool = true

var motion_state: MotionState = MotionState.AIR
var _move_input: Vector2 = Vector2.ZERO
var _look_input: Vector2 = Vector2.ZERO
var _jump_pressed: bool = false
var _jump_requested: bool = false
var _camera: Camera3D
var _capture_requested: bool = false
var _headless: bool = DisplayServer.get_name() == "headless"


func _ready() -> void:
	_camera = get_node(^"Camera3D") as Camera3D
	if hardware_input_enabled and not _headless:
		_capture_mouse(true)


func set_hardware_input_enabled(enabled: bool) -> void:
	hardware_input_enabled = enabled
	_clear_input()


## x = strafe right, y = backward. Analog magnitude is preserved up to one.
func set_move_input(direction: Vector2) -> void:
	if _accepts_commands() and direction.is_finite():
		_move_input = direction.limit_length(1.0)


## Pixel deltas accumulate until the next physics tick (also for driven input).
func add_look_input(pixel_delta: Vector2) -> void:
	if _accepts_commands() and pixel_delta.is_finite():
		_look_input += pixel_delta


## A rising edge lasts one physics tick; an airborne request is discarded.
func set_jump_pressed(pressed: bool) -> void:
	if not _accepts_commands():
		return
	if pressed and not _jump_pressed:
		_jump_requested = true
	_jump_pressed = pressed


func _accepts_commands() -> bool:
	return is_inside_tree() and not get_tree().paused


func _clear_input() -> void:
	_move_input = Vector2.ZERO
	_look_input = Vector2.ZERO
	_jump_pressed = false
	_jump_requested = false


func _notification(what: int) -> void:
	if what == NOTIFICATION_PAUSED or what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_clear_input()
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_capture_mouse(false)


func _capture_mouse(captured: bool) -> void:
	_capture_requested = captured
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if captured else Input.MOUSE_MODE_VISIBLE


func _mouse_is_captured() -> bool:
	# Headless DisplayServer cannot capture a cursor; preserve intent for driven events.
	if _headless:
		return _capture_requested
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if not hardware_input_enabled or not _accepts_commands():
		return
	if event.is_action_pressed(&"pause"):
		_capture_mouse(false)
		_clear_input()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_capture_mouse(true)
	if not _mouse_is_captured():
		return
	if event is InputEventMouseMotion:
		add_look_input(event.screen_relative)
	elif event.is_action(&"jump") and not event.is_echo():
		set_jump_pressed(event.is_pressed())


func _physics_process(delta: float) -> void:
	if hardware_input_enabled:
		if _mouse_is_captured():
			set_move_input(Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_back"))
		else:
			set_move_input(Vector2.ZERO)
	rotation.y = wrapf(rotation.y - _look_input.x * mouse_sensitivity, -PI, PI)
	var pitch_limit: float = deg_to_rad(pitch_limit_degrees)
	_camera.rotation.x = clampf(_camera.rotation.x - _look_input.y * mouse_sensitivity, -pitch_limit, pitch_limit)
	_look_input = Vector2.ZERO
	var world_orientation: Basis = global_transform.basis.orthonormalized()
	var direction: Vector3 = world_orientation * Vector3(_move_input.x, 0.0, _move_input.y)
	velocity.x = direction.x * move_speed
	velocity.z = direction.z * move_speed
	if is_on_floor():
		velocity.y = 0.0
		if _jump_requested:
			velocity.y = jump_velocity
	else:
		velocity.y -= gravity * delta
	_jump_requested = false
	move_and_slide()
	motion_state = MotionState.GROUND if is_on_floor() else MotionState.AIR
