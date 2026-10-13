extends GdUnitTestSuite

var _root: Node3D
var _weapon: HitscanWeapon
var _pool: ShotVisualPool


func before_test() -> void:
	_root = Node3D.new()
	add_child(_root)
	_weapon = HitscanWeapon.new()
	_weapon.hardware_input_enabled = false
	_root.add_child(_weapon)
	var stats := StatBlock.new(4)
	var source: int = stats.allocate()
	stats.set_stat(source, StatBlock.Stat.HP, 100000)
	_weapon.initialize(WeaponData.new(), stats, ShotBatch.new(4, 8, 4), source)
	_weapon.set_physics_process(false)
	var socket := Node3D.new()
	socket.position = Vector3(0.27, -0.2, -1.2)
	_weapon.add_child(socket)
	_pool = ShotVisualPool.new()
	_root.add_child(_pool)
	assert_bool(_pool.initialize(ShotVisualData.new(), _weapon, socket, 0)).is_true()
	_pool.set_physics_process(false)
	_pool.set_process(false)


func after_test() -> void:
	_root.free()


func _advance(ticks: int) -> void:
	for tick: int in ticks:
		_pool._physics_process(1.0 / 60.0)


func test_room_validation_lifetimes_capacities_producers_and_memory_boundaries() -> void:
	var data := ShotVisualData.new()
	var weapons: Array[WeaponData] = [WeaponData.new()]
	assert_bool(ShotVisualData.validate_room(data, weapons, 4, 8, 1, 125, 8256, 32768)).is_true()
	assert_bool(ShotVisualData.validate_room(data, weapons, 4, 8, 2, 128, 16384, 32768)).is_false()
	assert_bool(ShotVisualData.validate_room(data, weapons, 4, 9, 1, 128, 16384, 32768)).is_false()
	assert_bool(ShotVisualData.validate_room(data, weapons, 4, 8, 1, 124, 16384, 32768)).is_false()
	assert_bool(ShotVisualData.validate_room(data, weapons, 4, 8, 1, 128, 8255, 32768)).is_false()
	assert_bool(ShotVisualData.validate_room(data, weapons, 4, 8, 1, 128, 16384, 32767)).is_false()
	weapons[0].cooldown_ticks = 14
	assert_bool(ShotVisualData.validate_room(data, weapons, 4, 8, 1, 128, 16384, 32768)).is_false()
	weapons[0].cooldown_ticks = 15
	data.mark_ticks = 181
	assert_bool(data.is_valid()).is_false()
	data.mark_ticks = 180
	data.mark_capacity = 79
	assert_bool(ShotVisualData.validate_room(data, weapons, 4, 8, 1, 128, 16384, 32768)).is_false()
	data.mark_capacity = 80
	data.mark_depth = NAN
	assert_bool(data.is_valid()).is_false()


func test_exact_expiry_reuse_kind_and_full_generation_handles() -> void:
	var muzzle: int = _pool._show_muzzle(0, 0, 0)
	var mark: int = _pool._show_contact(0, 0, 0, Vector3(1, 2, 3), Vector3.BACK)
	var impact: int = _pool.handle_at(ShotVisualPool.Kind.IMPACT, 0)
	assert_int(muzzle).is_equal(0)
	assert_int(impact).is_equal(256)
	assert_int(mark).is_equal(512)
	var original: Node3D = _pool.node_for(muzzle)
	_advance(2)
	assert_bool(original.visible).is_true()
	_advance(1)
	assert_bool(original.visible).is_false()
	assert_bool(original.global_transform == Transform3D.IDENTITY).is_true()
	var reused: int = _pool._show_muzzle(0, 0, 1)
	assert_int(reused).is_equal(65536)
	assert_object(_pool.node_for(reused)).is_same(original)
	assert_bool(_pool.release(muzzle)).is_false()
	assert_bool(original.visible).is_true()
	_advance(2)
	assert_int(_pool.active_count(ShotVisualPool.Kind.IMPACT)).is_equal(1)
	_advance(1)
	assert_int(_pool.active_count(ShotVisualPool.Kind.IMPACT)).is_equal(0)
	assert_bool(_pool.release(impact)).is_false()
	_advance(173)
	assert_int(_pool.active_count(ShotVisualPool.Kind.MARK)).is_equal(1)
	_advance(1)
	assert_int(_pool.active_count(ShotVisualPool.Kind.MARK)).is_equal(0)
	assert_int(_pool.expired_count).is_equal(4)
	assert_int(_pool.reused_count).is_equal(1)


func test_reset_preserves_generation_clears_transforms_and_rejects_old_epoch() -> void:
	var handle: int = _pool._show_contact(0, 0, 0, Vector3(3, 4, 5), Vector3.UP)
	var node: Node3D = _pool.node_for(handle)
	assert_bool(_pool.reset_room(1)).is_true()
	assert_bool(node.visible).is_false()
	assert_bool(node.global_transform == Transform3D.IDENTITY).is_true()
	assert_int(_pool.emitted_marks).is_equal(0)
	assert_bool(_pool.reset_room(1)).is_false()
	assert_int(_pool._show_contact(0, 0, 1, Vector3.ZERO, Vector3.UP)).is_equal(-1)
	var fresh: int = _pool._show_contact(1, 0, 0, Vector3.ONE, Vector3.UP)
	assert_int(fresh).is_equal(65536 + 512)
	assert_bool(_pool.release(handle)).is_false()
	assert_bool(_pool.node_for(fresh).visible).is_true()
	assert_vector(_pool.node_for(fresh).global_position).is_equal(Vector3.ONE)
	assert_int(_pool.node_for(fresh).physics_interpolation_mode).is_equal(Node.PHYSICS_INTERPOLATION_MODE_OFF)
	assert_int(_pool.active_count(ShotVisualPool.Kind.IMPACT)).is_equal(1)
	assert_int(_pool.configuration_errors).is_equal(0)


func test_pair_overflow_is_atomic_diagnostics_once_and_reset_rearms() -> void:
	for index: int in 40:
		_pool._show_contact(0, 0, 0, Vector3.ZERO, Vector3.UP)
	assert_error(func() -> void: _pool._show_contact(0, 0, 0, Vector3.ZERO, Vector3.UP)).is_push_error("ShotVisualPool: invalid contact or visual capacity exhausted")
	assert_int(_pool._show_contact(0, 0, 0, Vector3.ZERO, Vector3.UP)).is_equal(-1)
	assert_int(_pool.active_count(ShotVisualPool.Kind.IMPACT)).is_equal(40)
	assert_int(_pool.active_count(ShotVisualPool.Kind.MARK)).is_equal(40)
	assert_int(_pool.configuration_errors).is_equal(2)
	assert_int(_pool.dropped_count).is_equal(2)
	_pool.reset_room(1)
	assert_error(func() -> void: _pool._show_contact(1, 0, 0, Vector3.ZERO, Vector3.ZERO)).is_push_error("ShotVisualPool: invalid contact or visual capacity exhausted")
	assert_int(_pool.active_count(ShotVisualPool.Kind.IMPACT)).is_equal(0)
	assert_int(_pool.active_count(ShotVisualPool.Kind.MARK)).is_equal(0)


func test_burst_four_plus_paced_shots_fit_mark_window_without_eviction() -> void:
	for shot: int in 4:
		_pool._show_muzzle(0, 0, shot)
		for trace: int in 8:
			_pool._show_contact(0, 0, shot, Vector3.ZERO, Vector3.UP)
	assert_int(_pool.active_count(ShotVisualPool.Kind.MARK)).is_equal(32)
	for shot: int in 6:
		_advance(30)
		_pool._show_muzzle(0, 0, shot + 4)
		for trace: int in 8:
			_pool._show_contact(0, 0, shot + 4, Vector3.ZERO, Vector3.UP)
	assert_int(_pool.emitted_muzzles).is_equal(10)
	assert_int(_pool.emitted_marks).is_equal(80)
	assert_int(_pool.active_count(ShotVisualPool.Kind.MARK)).is_equal(48)
	assert_int(_pool.configuration_errors).is_equal(0)
	assert_int(_pool.dropped_count).is_equal(0)


func test_mark_full_impact_free_refusal_creates_neither_half() -> void:
	for phase: int in 2:
		for index: int in 40:
			_pool._show_contact(0, 0, 0, Vector3.ZERO, Vector3.UP)
		_advance(6)
	assert_int(_pool.active_count(ShotVisualPool.Kind.MARK)).is_equal(80)
	assert_int(_pool.active_count(ShotVisualPool.Kind.IMPACT)).is_equal(0)
	assert_error(func() -> void: _pool._show_contact(0, 0, 1, Vector3.ZERO, Vector3.UP)).is_push_error("ShotVisualPool: invalid contact or visual capacity exhausted")
	assert_int(_pool.active_count(ShotVisualPool.Kind.MARK)).is_equal(80)
	assert_int(_pool.active_count(ShotVisualPool.Kind.IMPACT)).is_equal(0)
	assert_int(_pool.emitted_impacts).is_equal(80)


func test_kind_tagged_handles_preserve_generations_above_int32() -> void:
	for allocator: HandlePool in _pool._allocators:
		var state: Dictionary = allocator.get_state()
		var generations: PackedInt32Array = state["generation"]
		generations.fill(40000)
		state["generation"] = generations
		assert_bool(allocator.set_state(state)).is_true()
	var muzzle: int = _pool._show_muzzle(0, 0, 0)
	var mark: int = _pool._show_contact(0, 0, 0, Vector3.ZERO, Vector3.UP)
	assert_int(muzzle).is_equal(40000 * 65536)
	assert_int(mark).is_equal(40000 * 65536 + 512)
	assert_bool(_pool.release(muzzle)).is_true()
	var next: int = _pool._show_muzzle(0, 0, 1)
	assert_int(next).is_equal(40001 * 65536)
	assert_bool(_pool.release(muzzle)).is_false()
	assert_bool(_pool.node_for(next).visible).is_true()
	assert_bool(_pool.release(mark)).is_true()


func test_floor_ceiling_wall_basis_shared_bitmaps_and_world_scale() -> void:
	_root.scale = Vector3.ONE * 2.0
	var normals: Array[Vector3] = [Vector3.UP, Vector3.DOWN, Vector3.BACK]
	for normal: Vector3 in normals:
		var mark: int = _pool._show_contact(0, 0, 0, Vector3(2, 3, 4), normal)
		var decal: Decal = _pool.node_for(mark) as Decal
		assert_vector(decal.global_position).is_equal(Vector3(2, 3, 4))
		assert_vector(decal.global_basis.y).is_equal(normal)
		assert_float(decal.global_basis.determinant()).is_equal_approx(1.0, 0.00001)
		assert_int(decal.cull_mask).is_equal(1)
		assert_int(decal.physics_interpolation_mode).is_equal(Node.PHYSICS_INTERPOLATION_MODE_OFF)
		assert_vector(decal.size).is_equal(Vector3(0.14, 0.04, 0.14))
		assert_int(decal.texture_albedo.get_width()).is_equal(64)
		_pool.release(mark)
	var muzzle: int = _pool._show_muzzle(0, 0, 0)
	assert_float(_pool.node_for(muzzle).global_basis.x.length()).is_equal_approx(0.16, 0.00001)
	assert_int((_pool.node_for(muzzle) as MeshInstance3D).layers).is_equal(2)
	assert_int(_pool.node_for(muzzle).physics_interpolation_mode).is_equal(Node.PHYSICS_INTERPOLATION_MODE_OFF)
	_pool._process(0.0)
	assert_vector(_pool.node_for(muzzle).global_position).is_equal(_pool._socket.get_global_transform_interpolated().origin)


func test_callback_without_snapshot_has_no_output() -> void:
	_weapon.shot_presented.emit()
	_pool._on_shot_presented()
	assert_int(_pool.emitted_muzzles).is_equal(0)
	assert_int(_pool.emitted_marks).is_equal(0)
	assert_int(_weapon.visual_source()).is_equal(-1)
	assert_int(_weapon.visual_sequence()).is_equal(-1)
	assert_int(_weapon.visual_trace_count()).is_equal(0)
	assert_vector(_weapon.visual_point(0)).is_equal(Vector3.ZERO)


func test_invalid_cold_initialize_has_no_nodes_or_signal_subscription() -> void:
	var candidate := ShotVisualPool.new()
	_root.add_child(candidate)
	var data := ShotVisualData.new()
	data.mark_capacity = 79
	var connections: int = _weapon.shot_presented.get_connections().size()
	assert_bool(candidate.initialize(data, _weapon, _weapon, 0)).is_false()
	assert_int(candidate.get_child_count()).is_equal(0)
	assert_int(_weapon.shot_presented.get_connections().size()).is_equal(connections)
	assert_int(candidate.active_count(0)).is_equal(0)
