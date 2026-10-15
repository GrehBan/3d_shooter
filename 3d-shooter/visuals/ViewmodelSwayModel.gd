class_name ViewmodelSwayModel
extends RefCounted
## Frame-only presentation math for weapon bob, weapon sway and camera bob.
## Outside the deterministic contour (float, frame delta). Never writes gameplay state.
## Smoothing uses 1 - exp(-response * delta), and the step phase advances with the distance
## walked, so the same motion gives the same pose at any frame rate.

const CAMERA_BOB_LIMIT_M: float = 0.015

var intensity: float = 1.0  ## 0 disables bob and sway completely (motion comfort)
var reference_speed: float = 8.0  ## m/s at which the step bob reaches full amplitude
var bob_amplitude_m: float = 0.012
var bob_cycles_per_m: float = 0.55
var camera_bob_m: float = 0.01
var sway_m_per_rad_per_s: float = 0.006
var max_sway_m: float = 0.03
var response: float = 12.0

var offset: Vector3 = Vector3.ZERO  ## weapon viewmodel local offset, metres
var roll: float = 0.0  ## weapon viewmodel roll, radians
var camera_offset: Vector2 = Vector2.ZERO  ## Camera3D h_offset / v_offset, metres
var _phase: float = 0.0
var _bob_weight: float = 0.0
var _sway: Vector2 = Vector2.ZERO


## speed — horizontal speed in m/s; yaw_rate and pitch_rate — displayed look rate in rad/s.
func step(delta: float, speed: float, grounded: bool, yaw_rate: float, pitch_rate: float) -> void:
	if not (delta > 0.0) or not is_finite(delta):
		return
	if not is_finite(speed):
		speed = 0.0  # a NaN would otherwise stick in the smoothed weight forever
	var blend: float = 1.0 - exp(-response * delta)
	var target_weight: float = clampf(speed / reference_speed, 0.0, 1.0) if grounded else 0.0
	_bob_weight = lerpf(_bob_weight, target_weight, blend)
	if grounded and is_finite(speed):
		_phase = fmod(_phase + speed * delta * bob_cycles_per_m * TAU, TAU)
	var target_sway := Vector2.ZERO
	if is_finite(yaw_rate) and is_finite(pitch_rate):
		target_sway = Vector2(-yaw_rate, pitch_rate) * sway_m_per_rad_per_s
		target_sway = target_sway.limit_length(max_sway_m)
	_sway = _sway.lerp(target_sway, blend)
	var strength: float = clampf(intensity, 0.0, 1.0)
	var bob: float = bob_amplitude_m * _bob_weight
	offset = Vector3(sin(_phase) * bob + _sway.x, -absf(cos(_phase)) * bob + _sway.y, 0.0) * strength
	roll = _sway.x * 2.0 * strength
	var camera_bob: float = minf(camera_bob_m, CAMERA_BOB_LIMIT_M) * _bob_weight * strength
	camera_offset = Vector2(cos(_phase) * camera_bob * 0.5, sin(_phase * 2.0) * camera_bob)
