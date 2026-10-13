class_name HitscanWeapon
extends Node3D
## Physics/input adapter. Reused RayCast3D avoids intersect_ray's temporary Dictionary.

@export var hardware_input_enabled: bool = true
var state: WeaponState = WeaponState.new()
var traces_cast: int = 0
var _stats: StatBlock
var _batch: ShotBatch
var _rays: Array[RayCast3D] = []
var _endpoints: PackedVector3Array = PackedVector3Array()
var _pellets: int = 0
var _bound: bool = false
var _focused: bool = true


func _ready() -> void:
	process_physics_priority = 10  # after FPS motion/look, before GameLoop's 1000


## Cold initialization only, after the complete room configuration has been validated.
func initialize(data: WeaponData, stats: StatBlock, batch: ShotBatch, source: int,
		excluded_body: CollisionObject3D = null) -> bool:
	if _bound or data == null or not data.is_valid() or stats == null or batch == null \
			or not stats.is_valid(source) or data.pellet_count > batch.trace_capacity():
		return false
	if not state.configure(data, source):
		return false
	_stats = stats
	_batch = batch
	_pellets = data.pellet_count
	_rays.resize(batch.trace_capacity())
	_endpoints.resize(batch.trace_capacity())
	var distance: float = float(data.range_mm) / 1000.0
	var radius: float = tan(deg_to_rad(float(data.spread_millidegrees) / 1000.0))
	for index: int in _rays.size():
		var ray := RayCast3D.new()
		ray.enabled = false
		ray.collision_mask = 1 | 4 | 64
		ray.collide_with_areas = false
		var direction: Vector3 = Vector3.FORWARD
		if index > 0 and index < _pellets:
			var angle: float = TAU * float(index - 1) / float(_pellets - 1)
			direction = Vector3(cos(angle) * radius, sin(angle) * radius, -1.0).normalized()
		ray.target_position = direction * distance
		_endpoints[index] = direction * distance
		add_child(ray)
		if excluded_body != null:
			ray.add_exception(excluded_body)
		_rays[index] = ray
	_bound = true
	return true


func set_fire_pressed(pressed: bool) -> void:
	if _bound and is_inside_tree() and (not pressed or not get_tree().paused):
		state.set_pressed(pressed)


func _unhandled_input(event: InputEvent) -> void:
	if not hardware_input_enabled or not _focused or event.is_echo():
		return
	if event.is_action(&"pause"):
		state.clear_input()
	elif event.is_action(&"fire_primary"):
		if not event.is_pressed() or _has_mouse_capture():
			set_fire_pressed(event.is_pressed())


func _notification(what: int) -> void:
	if what == NOTIFICATION_PAUSED:
		state.discard_press()
	elif what == NOTIFICATION_UNPAUSED and hardware_input_enabled:
		state.reconcile_held(Input.is_action_pressed(&"fire_primary"))
	elif what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_focused = false
		state.clear_input()
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_focused = true


func _physics_process(_delta: float) -> void:
	if not _bound:
		return
	if hardware_input_enabled and (not _focused or not _has_mouse_capture()):
		state.clear_input()
		return
	var ticket: int = state.request_shot(_batch, _stats, GameLoop.get_logic_tick())
	if ticket == ShotBatch.INVALID:
		return
	# Ray endpoints are world metres even under the controller's supported uniform scale.
	var local_aim: Basis = global_basis.inverse() * global_basis.orthonormalized()
	for index: int in _pellets:
		var ray: RayCast3D = _rays[index]
		ray.target_position = local_aim * _endpoints[index]
		ray.force_raycast_update()
		_batch.write_trace(ticket, index, Damageable.handle_of(ray.get_collider()))
		traces_cast += 1
	var published: bool = _batch.publish(ticket)
	assert(published, "HitscanWeapon: complete reservation must publish")


func _has_mouse_capture() -> bool:
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


func reset_clock(old_tick: int) -> void:
	state.reset_clock(old_tick)
	traces_cast = 0


## Entity lifecycle is distinct from room clock reset; same identity is idempotent.
func bind_source(source: int) -> bool:
	if not _bound or not _stats.is_valid(source):
		return false
	if state.source == source:
		return true
	state.source = source
	state.ready_tick = 0
	state.accepted_shots = 0
	state.clear_input()
	return true
