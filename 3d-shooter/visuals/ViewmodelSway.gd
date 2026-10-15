class_name ViewmodelSway
extends Node3D
## Frame-layer adapter (M1): weapon bob and sway on this Viewmodel node plus camera bob
## through Camera3D.h_offset/v_offset. It only reads the controller and the displayed camera
## pose; Camera3D, HitscanWeapon and its rays never move, so hits are unchanged.

@export_range(0.0, 1.0, 0.05) var intensity: float = 1.0

var model: ViewmodelSwayModel = ViewmodelSwayModel.new()
var _controller: FPSController
var _camera: Camera3D
var _previous_basis: Basis
var _has_previous: bool = false


func _ready() -> void:
	# Moved in _process: physics interpolation of the parent must not overwrite it.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF


## Cold binding by the composition root.
func bind(controller: FPSController, camera: Camera3D) -> void:
	_controller = controller
	_camera = camera
	_has_previous = false


func _process(delta: float) -> void:
	if _controller == null or _camera == null or not (delta > 0.0):
		return
	model.intensity = intensity
	var displayed: Basis = _camera.get_global_transform_interpolated().basis.orthonormalized()
	var yaw_rate: float = 0.0
	var pitch_rate: float = 0.0
	if _has_previous:
		var turn: Vector3 = (_previous_basis.inverse() * displayed).get_euler()
		yaw_rate = turn.y / delta
		pitch_rate = turn.x / delta
	_previous_basis = displayed
	_has_previous = true
	var velocity: Vector3 = _controller.velocity
	model.step(delta, Vector2(velocity.x, velocity.z).length(),
			_controller.motion_state == FPSController.MotionState.GROUND, yaw_rate, pitch_rate)
	position = model.offset
	rotation = Vector3(0.0, 0.0, model.roll)
	_camera.h_offset = model.camera_offset.x
	_camera.v_offset = model.camera_offset.y
