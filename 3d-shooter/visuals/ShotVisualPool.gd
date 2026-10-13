class_name ShotVisualPool
extends Node3D
## Fixed presentation-only pools. Contact visuals describe geometry, not damage.

enum Kind { MUZZLE, IMPACT, MARK }
const INVALID: int = -1
const KIND_SPAN: int = ShotVisualData.KIND_SPAN

var emitted_muzzles: int = 0
var emitted_impacts: int = 0
var emitted_marks: int = 0
var expired_count: int = 0
var released_count: int = 0
var reused_count: int = 0
var configuration_errors: int = 0
var dropped_count: int = 0
var room_epoch: int = 0
var _reported: bool = false
var _bound: bool = false
var _weapon: HitscanWeapon
var _socket: Node3D
var _source: int = INVALID
var _last_sequence: int = INVALID
var _allocators: Array[HandlePool] = []
var _nodes: Array[Node3D] = []
var _starts: PackedInt32Array = PackedInt32Array()
var _ttl: PackedInt32Array = PackedInt32Array()
var _age: PackedInt32Array = PackedInt32Array()
var _owner: PackedInt64Array = PackedInt64Array()
var _epoch: PackedInt64Array = PackedInt64Array()
var _sequence: PackedInt64Array = PackedInt64Array()
var _sizes: PackedFloat32Array = PackedFloat32Array()


func _ready() -> void:
	process_physics_priority = 5


## Cold construction only, after the composition root validates all room budgets.
func initialize(data: ShotVisualData, weapon: HitscanWeapon, socket: Node3D,
		epoch: int) -> bool:
	if _bound or data == null or not data.is_valid() or weapon == null or socket == null \
			or epoch < 0 or not weapon.is_initialized() or not is_inside_tree() \
			or not weapon.is_inside_tree() or not socket.is_inside_tree():
		return false
	if not data.validate_limits(weapon.visual_burst_limit(), weapon.visual_stride_limit(),
			weapon.visual_cooldown_ticks(), 128, 16384, 32768):
		return false
	_weapon = weapon
	_socket = socket
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	# The first call creates Godot's interpolation pump; do this during cold loading.
	_socket.get_global_transform_interpolated()
	room_epoch = epoch
	_source = weapon.state.source
	_starts.resize(3)
	_ttl.resize(3)
	_sizes.resize(3)
	_starts[0] = 0
	_starts[1] = data.muzzle_capacity
	_starts[2] = data.muzzle_capacity + data.impact_capacity
	_ttl[0] = data.muzzle_ticks
	_ttl[1] = data.impact_ticks
	_ttl[2] = data.mark_ticks
	_sizes[0] = data.muzzle_size
	_sizes[1] = data.impact_size
	_sizes[2] = data.mark_size
	_allocators.resize(3)
	_allocators[0] = HandlePool.new(data.muzzle_capacity)
	_allocators[1] = HandlePool.new(data.impact_capacity)
	_allocators[2] = HandlePool.new(data.mark_capacity)
	var total: int = data.muzzle_capacity + data.impact_capacity + data.mark_capacity
	_nodes.resize(total)
	_age.resize(total)
	_owner.resize(total)
	_owner.fill(INVALID)
	_epoch.resize(total)
	_epoch.fill(INVALID)
	_sequence.resize(total)
	_sequence.fill(INVALID)
	var flash_texture: ImageTexture = _texture(false)
	var mark_texture: ImageTexture = _texture(true)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_texture = flash_texture
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	quad.material = material
	for kind: int in 3:
		for index: int in _allocators[kind].capacity():
			var slot: int = _starts[kind] + index
			var visual: Node3D
			if kind == Kind.MARK:
				var decal := Decal.new()
				decal.texture_albedo = mark_texture
				decal.size = Vector3(data.mark_size, data.mark_depth, data.mark_size)
				decal.cull_mask = 1
				decal.normal_fade = 0.5
				decal.upper_fade = 0.0
				decal.lower_fade = 0.0
				visual = decal
			else:
				var mesh := MeshInstance3D.new()
				mesh.mesh = quad
				mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				mesh.layers = 2
				visual = mesh
			add_child(visual)
			visual.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
			visual.set_as_top_level(true)
			visual.visible = false
			_nodes[slot] = visual
	_weapon.shot_presented.connect(_on_shot_presented)
	_bound = true
	return true


## This callback must consume values while the adapter's synchronous snapshot is live.
func _on_shot_presented() -> void:
	if not _bound or not _weapon.has_visual_snapshot():
		return
	var epoch: int = _weapon.visual_epoch()
	var source: int = _weapon.visual_source()
	var sequence: int = _weapon.visual_sequence()
	if epoch != room_epoch or source != _weapon.state.source:
		return
	if source != _source:
		_source = source
		_last_sequence = INVALID
	if sequence <= _last_sequence:
		return
	_last_sequence = sequence
	_show_muzzle(epoch, source, sequence)
	for index: int in _weapon.visual_trace_count():
		if _weapon.visual_collided(index):
			_show_contact(epoch, source, sequence, _weapon.visual_point(index), _weapon.visual_normal(index))


func _show_muzzle(epoch: int, source: int, sequence: int) -> int:
	if not _identity_valid(epoch, source, sequence):
		return INVALID
	if _allocators[Kind.MUZZLE].is_full():
		return _overflow()
	var handle: int = _activate(Kind.MUZZLE, epoch, source, sequence)
	var node: Node3D = node_for(handle)
	var displayed: Transform3D = _socket.get_global_transform_interpolated()
	node.global_transform = Transform3D(displayed.basis.orthonormalized().scaled(Vector3.ONE * _sizes[0]), displayed.origin)
	emitted_muzzles += 1
	return handle


## Both slots are checked before either allocation: no partial contact pair.
func _show_contact(epoch: int, source: int, sequence: int, point: Vector3, normal: Vector3) -> int:
	if not _identity_valid(epoch, source, sequence):
		return INVALID
	if not point.is_finite() or not normal.is_finite() or normal.length_squared() < 0.000001 \
			or _allocators[Kind.IMPACT].is_full() or _allocators[Kind.MARK].is_full():
		return _overflow()
	var n: Vector3 = normal.normalized()
	var tangent: Vector3 = Vector3.UP
	if absf(n.dot(tangent)) > 0.95:
		tangent = Vector3.RIGHT
	var x: Vector3 = tangent.cross(n).normalized()
	var y: Vector3 = n.cross(x).normalized()
	var impact: int = _activate(Kind.IMPACT, epoch, source, sequence)
	var mark: int = _activate(Kind.MARK, epoch, source, sequence)
	node_for(impact).global_transform = Transform3D(Basis(x, y, n).scaled(Vector3.ONE * _sizes[1]), point + n * 0.01)
	# Decal projects along -Y, with outward surface normal on +Y.
	node_for(mark).global_transform = Transform3D(Basis(x, n, x.cross(n)), point)
	emitted_impacts += 1
	emitted_marks += 1
	return mark


func _identity_valid(epoch: int, source: int, sequence: int) -> bool:
	return _bound and not get_tree().paused and epoch == room_epoch \
			and source == _source and source == _weapon.state.source and sequence >= 0


func _activate(kind: int, epoch: int, source: int, sequence: int) -> int:
	var internal: int = _allocators[kind].allocate()
	var index: int = internal % HandlePool.INDEX_SPAN
	var slot: int = _starts[kind] + index
	_age[slot] = 0
	_owner[slot] = source
	_epoch[slot] = epoch
	_sequence[slot] = sequence
	_nodes[slot].visible = true
	if internal >= HandlePool.INDEX_SPAN:
		reused_count += 1
	return internal + kind * KIND_SPAN


## Kind occupies the low index region; the generation is never truncated or repacked.
func release(handle: int) -> bool:
	var slot: int = _slot_for(handle)
	if slot < 0:
		return false
	var kind: int = (handle % HandlePool.INDEX_SPAN) / KIND_SPAN
	if not _allocators[kind].release(handle - kind * KIND_SPAN):
		return false
	_nodes[slot].visible = false
	_nodes[slot].global_transform = Transform3D.IDENTITY
	_age[slot] = 0
	_owner[slot] = INVALID
	_epoch[slot] = INVALID
	_sequence[slot] = INVALID
	released_count += 1
	return true


func _slot_for(handle: int) -> int:
	if not _bound or handle < 0:
		return INVALID
	var kind: int = (handle % HandlePool.INDEX_SPAN) / KIND_SPAN
	if kind < 0 or kind >= 3:
		return INVALID
	var index: int = _allocators[kind].index_of(handle - kind * KIND_SPAN)
	if index < 0:
		return INVALID
	return _starts[kind] + index


func node_for(handle: int) -> Node3D:
	var slot: int = _slot_for(handle)
	return null if slot < 0 else _nodes[slot]


func handle_at(kind: int, index: int) -> int:
	if not _bound or kind < 0 or kind >= 3:
		return INVALID
	var internal: int = _allocators[kind].handle_at(index)
	return INVALID if internal < 0 else internal + kind * KIND_SPAN


func active_count(kind: int) -> int:
	return 0 if not _bound or kind < 0 or kind >= 3 else _allocators[kind].alive_count()


func _physics_process(_delta: float) -> void:
	if not _bound:
		return
	for kind: int in 3:
		for index: int in _allocators[kind].capacity():
			var internal: int = _allocators[kind].handle_at(index)
			if internal < 0:
				continue
			var slot: int = _starts[kind] + index
			_age[slot] += 1
			if _age[slot] >= _ttl[kind]:
				release(internal + kind * KIND_SPAN)
				expired_count += 1


func _process(_delta: float) -> void:
	if not _bound:
		return
	var displayed: Transform3D = _socket.get_global_transform_interpolated()
	for index: int in _allocators[Kind.MUZZLE].capacity():
		if _allocators[Kind.MUZZLE].handle_at(index) >= 0:
			_nodes[index].global_transform = Transform3D(displayed.basis.orthonormalized().scaled(Vector3.ONE * _sizes[0]), displayed.origin)


func reset_room(epoch: int) -> bool:
	if not _bound or epoch <= room_epoch:
		return false
	for kind: int in 3:
		for index: int in _allocators[kind].capacity():
			var internal: int = _allocators[kind].handle_at(index)
			if internal >= 0:
				release(internal + kind * KIND_SPAN)
	room_epoch = epoch
	_source = _weapon.state.source
	_last_sequence = INVALID
	emitted_muzzles = 0
	emitted_impacts = 0
	emitted_marks = 0
	expired_count = 0
	released_count = 0
	reused_count = 0
	configuration_errors = 0
	dropped_count = 0
	_reported = false
	return true


func _overflow() -> int:
	configuration_errors += 1
	dropped_count += 1
	if not _reported:
		_reported = true
		push_error("ShotVisualPool: invalid contact or visual capacity exhausted")
	return INVALID


## Shared bitmaps are generated once while loading, never uploaded in the hot path.
static func _texture(mark: bool) -> ImageTexture:
	var image: Image = Image.create(ShotVisualData.TEXTURE_SIDE, ShotVisualData.TEXTURE_SIDE, false, Image.FORMAT_RGBA8)
	for y: int in ShotVisualData.TEXTURE_SIDE:
		for x: int in ShotVisualData.TEXTURE_SIDE:
			var p: Vector2 = (Vector2(x, y) + Vector2.ONE * 0.5) / float(ShotVisualData.TEXTURE_SIDE) * 2.0 - Vector2.ONE
			var r: float = p.length()
			var color: Color
			if mark:
				var edge: float = 0.78 + 0.06 * cos(p.angle() * 9.0) + 0.04 * sin(p.angle() * 13.0)
				var alpha: float = clampf((edge - r) * 16.0, 0.0, 1.0)
				var rim: float = clampf((r - 0.46) * 4.0, 0.0, 1.0)
				color = Color(0.035, 0.045, 0.055).lerp(Color(0.65, 0.69, 0.72), rim)
				color.a = alpha
			else:
				var arm: float = maxf(1.0 - absf(p.x) * 5.0, 1.0 - absf(p.y) * 5.0)
				var alpha: float = clampf((1.0 - r) * maxf(arm, 0.15) * 2.0, 0.0, 1.0)
				color = Color(0.25, 0.9, 1.0).lerp(Color.WHITE, clampf(1.0 - r * 3.0, 0.0, 1.0))
				color.a = alpha
			image.set_pixel(x, y, color)
	return ImageTexture.create_from_image(image)
