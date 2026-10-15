class_name FPSController
extends CharacterBody3D
## Engine physics adapter. Combat math stays in the pure MobilityRuntime/DamageApply.
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

const DASH_SPEED: float = 24.0
const DASH_TICKS: int = 9
const SLIDE_ENTRY_SPEED: float = 4.0
const SLIDE_DECELERATION: float = 5.0
const SLIDE_TICKS: int = 36
const CANCEL_WINDOW_TICKS: int = 12

var dash_activations: int = 0
var slide_activations: int = 0
var double_jump_activations: int = 0
var landing_events: int = 0
var _mobility: MobilityRuntime
var _entity: int = StatBlock.INVALID_HANDLE
var _dash_pressed: bool = false
var _dash_requested: bool = false
var _slide_pressed: bool = false
var _slide_requested: bool = false
var _dash_ticks: int = 0
var _slide_ticks: int = 0
var _motion_direction: Vector3 = Vector3.ZERO
var _slide_speed: float = 0.0
var _double_jump_used: bool = false
var _physical_tick: int = 0
var _last_dash_tick: int = -1
var _slide_prearm_tick: int = -1
var _air_episode: bool = false
var _peak_world_y: float = 0.0


func _ready() -> void:
	_camera = get_node(^"Camera3D") as Camera3D
	if hardware_input_enabled and not _headless:
		_capture_mouse(true)


func set_hardware_input_enabled(enabled: bool) -> void:
	hardware_input_enabled = enabled
	_clear_input()


## Explicit entity lifecycle. Regranting abilities never resets physical air limits.
## null/INVALID_HANDLE detaches. No controller owns the shared logic subscription.
func bind_mobility(runtime: MobilityRuntime, entity: int) -> void:
	if runtime == null or entity == StatBlock.INVALID_HANDLE:
		runtime = null
		entity = StatBlock.INVALID_HANDLE
	elif runtime == _mobility and entity == _entity:
		return  # Same identity is idempotent; it cannot reset a physical air episode.
	_mobility = runtime
	_entity = entity
	_clear_input()
	_dash_ticks = 0
	_slide_ticks = 0
	_motion_direction = Vector3.ZERO
	_slide_speed = 0.0
	_double_jump_used = false
	_physical_tick = 0
	_last_dash_tick = -1
	_air_episode = false
	_peak_world_y = global_position.y
	velocity = Vector3.ZERO
	motion_state = MotionState.AIR


func mobility_entity() -> int:
	return _entity


func is_dashing() -> bool:
	return _dash_ticks > 0


func is_sliding() -> bool:
	return _slide_ticks > 0


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


func set_dash_pressed(pressed: bool) -> void:
	if not _accepts_commands():
		return
	if pressed and not _dash_pressed:
		_dash_requested = true
	_dash_pressed = pressed


func set_slide_pressed(pressed: bool) -> void:
	if not _accepts_commands():
		return
	if pressed and not _slide_pressed:
		_slide_requested = true
	_slide_pressed = pressed


func _accepts_commands() -> bool:
	return is_inside_tree() and not get_tree().paused


func _clear_input() -> void:
	_move_input = Vector2.ZERO
	_look_input = Vector2.ZERO
	_jump_pressed = false
	_jump_requested = false
	_dash_pressed = false
	_dash_requested = false
	_slide_pressed = false
	_slide_requested = false
	_slide_prearm_tick = -1


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
	elif event.is_action(&"dash") and not event.is_echo():
		set_dash_pressed(event.is_pressed())
	elif event.is_action(&"slide") and not event.is_echo():
		set_slide_pressed(event.is_pressed())


func _physics_process(delta: float) -> void:
	_physical_tick += 1
	if _mobility != null and not _mobility.stats.is_valid(_entity):
		bind_mobility(null, StatBlock.INVALID_HANDLE)
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
	var grounded: bool = is_on_floor()
	if not grounded and not _air_episode:
		_air_episode = true
		_peak_world_y = global_position.y
	if _air_episode:
		_peak_world_y = maxf(_peak_world_y, global_position.y)
	if not grounded:
		_slide_ticks = 0
	if _slide_prearm_tick >= 0 and _physical_tick - _slide_prearm_tick > CANCEL_WINDOW_TICKS:
		_slide_prearm_tick = -1
	# Physical predicates precede try_activate. Failure permits a lower priority action.
	var activated: bool = false
	if _dash_requested and _dash_ticks == 0 and _slide_ticks == 0:
		if _try_ability(MovementAbilityData.Kind.DASH, not grounded):
			_motion_direction = direction.normalized() if direction.length_squared() > 0.0 \
					else -world_orientation.z
			_dash_ticks = DASH_TICKS
			_last_dash_tick = _physical_tick
			dash_activations += 1
			activated = true
	if _slide_requested:
		if not grounded:
			_slide_prearm_tick = _physical_tick
		elif not activated:
			activated = _try_slide()
	if grounded:
		velocity.y = 0.0
	else:
		velocity.y -= gravity * delta
	if _jump_requested and not activated and _dash_ticks == 0 and _slide_ticks == 0:
		if grounded:
			velocity.y = jump_velocity  # ordinary ground jump is free
			activated = true
		elif not _double_jump_used and _try_ability(MovementAbilityData.Kind.DOUBLE_JUMP, true):
			velocity.y = jump_velocity
			_double_jump_used = true
			double_jump_activations += 1
			activated = true
	if _dash_ticks > 0:
		velocity.x = _motion_direction.x * DASH_SPEED
		velocity.z = _motion_direction.z * DASH_SPEED
	elif _slide_ticks > 0:
		velocity.x = _motion_direction.x * _slide_speed
		velocity.z = _motion_direction.z * _slide_speed
	else:
		velocity.x = direction.x * move_speed
		velocity.z = direction.z * move_speed
	_jump_requested = false
	_dash_requested = false
	_slide_requested = false
	var world_y_before: float = global_position.y
	move_and_slide()
	var now_grounded: bool = is_on_floor()
	if _dash_ticks > 0:
		_dash_ticks -= 1
	if _slide_ticks > 0:
		_slide_ticks -= 1
		_slide_speed = maxf(_slide_speed - SLIDE_DECELERATION * delta, 0.0)
		if not now_grounded or _slide_speed == 0.0:
			_slide_ticks = 0
	if not now_grounded:
		if not _air_episode:
			_air_episode = true
			_peak_world_y = world_y_before
		_peak_world_y = maxf(_peak_world_y, global_position.y)
	elif _air_episode:
		# One event per confirmed AIR→GROUND episode. A floor does not reset via walls/ceiling.
		var flags: int = 0
		if _last_dash_tick >= 0 and _physical_tick - _last_dash_tick <= CANCEL_WINDOW_TICKS:
			flags |= LandingEventQueue.CANCEL_DASH
		if _slide_prearm_tick >= 0 and not activated and _try_slide():
			flags |= LandingEventQueue.CANCEL_SLIDE
		if _mobility != null:
			var height_mm: int = quantize_height_mm(_peak_world_y - global_position.y)
			_mobility.landings.push(_entity, height_mm, flags)
			landing_events += 1
		_air_episode = false
		_double_jump_used = false
		_slide_prearm_tick = -1
	motion_state = MotionState.GROUND if now_grounded else MotionState.AIR


func _try_ability(kind: MovementAbilityData.Kind, in_air: bool) -> bool:
	return _mobility != null and _mobility.abilities.try_activate(
			_entity, kind, GameLoop.get_logic_tick(), in_air, _mobility.stats)


func _try_slide() -> bool:
	if _dash_ticks != 0 or _slide_ticks != 0:
		return false
	var speed: float = Vector2(velocity.x, velocity.z).length()
	if speed < SLIDE_ENTRY_SPEED or not _try_ability(MovementAbilityData.Kind.SLIDE, false):
		return false
	_motion_direction = Vector3(velocity.x, 0.0, velocity.z) / speed
	_slide_speed = speed
	_slide_ticks = SLIDE_TICKS
	slide_activations += 1
	return true


## Physics boundary only. No epsilon: 7999/8000/8001 millimetres stay distinct.
## A height ≥ float(cap), that is ≥ cap − 12 mm, saturates to the exact integer cap:
## float(MAX_HEIGHT_MM) rounds to 922337203685485568, so the cap never goes through float.
static func quantize_height_mm(height_m: float) -> int:
	if not is_finite(height_m) or height_m <= 0.0:
		return 0
	var height_mm: float = height_m * 1000.0
	if height_mm >= float(LandingEventQueue.MAX_HEIGHT_MM):
		return LandingEventQueue.MAX_HEIGHT_MM
	return clampi(int(floor(height_mm)), 0, LandingEventQueue.MAX_HEIGHT_MM)
