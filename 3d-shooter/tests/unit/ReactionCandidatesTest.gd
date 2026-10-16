extends GdUnitTestSuite
## Physics adapter of M2.3b reactions: ShapeCast3D candidates written into ShotBatch in the
## physics tick, overflow accounting, per-shot dedup and element gating in HitscanWeapon.

const VALIDATOR_SHIFT: int = 24
const VALIDATOR_MASK: int = (1 << 39) - 1

var _root: Node3D


func before_test() -> void:
	_root = Node3D.new()
	add_child(_root)


func after_test() -> void:
	if is_instance_valid(_root):
		_root.free()


func _body(position: Vector3, layer: int, handle: int) -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.6, 1.6, 0.6)
	shape.shape = box
	body.add_child(shape)
	body.position = position
	body.collision_layer = layer
	body.collision_mask = 0
	_root.add_child(body)
	if handle >= 0:
		Damageable.attach(body, handle)
	return body


func _candidates(batch: ShotBatch, trace: int) -> Array[int]:
	var out: Array[int] = []
	batch.prepare()
	for index: int in batch.candidate_count_at(0, trace):
		out.append(batch.candidate_at(0, trace, index))
	out.sort()
	return out


func test_collect_writes_hitboxes_in_the_sphere_except_the_primary() -> void:
	var primary: StaticBody3D = _body(Vector3.ZERO, ReactionCandidates.CANDIDATE_MASK, 10)
	_body(Vector3(2, 0, 0), ReactionCandidates.CANDIDATE_MASK, 11)
	_body(Vector3(0, 0, -2), ReactionCandidates.CANDIDATE_MASK, 12)
	_body(Vector3(5, 0, 0), ReactionCandidates.CANDIDATE_MASK, 13)  # outside 3 m
	_body(Vector3(-1, 0, 0), 1, 14)  # world layer: never a candidate
	_body(Vector3(0, 0, 1.5), ReactionCandidates.CANDIDATE_MASK, -1)  # no handle
	var batch := ShotBatch.new(1, 2, 16, 8)
	var adapter := ReactionCandidates.new()
	assert_bool(adapter.initialize(batch, 3000)).is_true()
	_root.add_child(adapter)
	await get_tree().physics_frame
	var ticket: int = batch.reserve(0, 1, 1000)
	batch.write_trace(ticket, 0, 10)
	assert_int(adapter.collect(ticket, 0, primary, 10)).is_equal(2)
	batch.publish(ticket)
	assert_array(_candidates(batch, 0)).is_equal([11, 12])
	assert_int(adapter.queries).is_equal(1)
	assert_int(adapter.overflows).is_equal(0)


func test_crowd_over_capacity_counts_an_overflow_and_keeps_k() -> void:
	var primary: StaticBody3D = _body(Vector3.ZERO, ReactionCandidates.CANDIDATE_MASK, 10)
	for index: int in 3:
		_body(Vector3(1.5 * (index + 1) - 2.5, 0, 1.5), ReactionCandidates.CANDIDATE_MASK, 20 + index)
	var batch := ShotBatch.new(1, 1, 32, 2)
	var adapter := ReactionCandidates.new()
	adapter.initialize(batch, 3000)
	_root.add_child(adapter)
	await get_tree().physics_frame
	var ticket: int = batch.reserve(0, 1, 1000)
	batch.write_trace(ticket, 0, 10)
	var overflow := func() -> void: assert_int(adapter.collect(ticket, 0, primary, 10)).is_equal(2)
	await assert_error(overflow).is_push_warning(ReactionCandidates.OVERFLOW_WARNING)
	batch.publish(ticket)
	assert_int(adapter.overflows).is_equal(1)
	assert_int(_candidates(batch, 0).size()).is_equal(2)
	assert_int(batch.configuration_errors).is_equal(0)  # a crowd is not a configuration error


func test_candidates_are_written_only_before_publish() -> void:
	var batch := ShotBatch.new(1, 2, 8, 2)
	var ticket: int = batch.reserve(0, 2, 1000)
	assert_bool(batch.add_candidate(ticket, 2, 5)).is_false()  # trace out of range
	assert_bool(batch.add_candidate(ticket, 0, 5)).is_true()
	assert_bool(batch.add_candidate(ticket, 0, 6)).is_true()
	assert_bool(batch.add_candidate(ticket, 0, 7)).is_false()  # full
	assert_bool(batch.copy_candidates(ticket, 0, 1)).is_true()
	batch.write_trace(ticket, 0, 1)
	batch.write_trace(ticket, 1, 1)
	batch.publish(ticket)
	assert_bool(batch.add_candidate(ticket, 1, 8)).is_false()  # published: physics is done
	assert_int(batch.prepare()).is_equal(1)
	assert_int(batch.candidate_count_at(0, 1)).is_equal(2)
	assert_int(batch.candidate_at(0, 1, 1)).is_equal(6)


func _weapon(element: DamagePayload.Element) -> Array:
	var stats := StatBlock.new(16)
	var source: int = stats.allocate()
	stats.set_stat(source, StatBlock.Stat.HP, 100000)
	var statuses := StatusRuntime.new(stats)
	var reactions := ReactionRuntime.new(stats, statuses)
	var batch := ShotBatch.new(4, 8, 16, 8)
	var weapon := HitscanWeapon.new()
	weapon.hardware_input_enabled = false
	_root.add_child(weapon)
	var data := WeaponData.new()
	data.element = element
	assert_bool(weapon.initialize(data, stats, batch, source)).is_true()
	weapon.set_physics_process(false)
	assert_bool(weapon.bind_reactions(reactions)).is_true()
	assert_bool(weapon.bind_reactions(reactions)).is_false()  # bound once
	return [weapon, batch]


func test_weapon_queries_once_per_distinct_target_for_reactive_elements() -> void:
	var wall: StaticBody3D = _body(Vector3(0, 0, -6), ReactionCandidates.CANDIDATE_MASK, 3)
	((wall.get_child(0) as CollisionShape3D).shape as BoxShape3D).size = Vector3(4, 4, 0.5)  # every pellet
	_body(Vector3(2.5, 0, -6), ReactionCandidates.CANDIDATE_MASK, 4)
	var parts: Array = _weapon(DamagePayload.Element.ELECTRIC)
	var weapon: HitscanWeapon = parts[0]
	var batch: ShotBatch = parts[1]
	await get_tree().physics_frame
	weapon.set_fire_pressed(true)
	weapon._physics_process(1.0 / 60.0)
	assert_int(weapon.reaction_candidates.queries).is_equal(1)
	assert_int(batch.prepare()).is_equal(1)
	for trace: int in batch.trace_count_at(0):
		assert_int(batch.target_at(0, trace)).is_equal(3)
		assert_int(batch.candidate_count_at(0, trace)).is_equal(1)
		assert_int(batch.candidate_at(0, trace, 0)).is_equal(4)


func test_weapon_without_area_reaction_never_queries() -> void:
	var wall: StaticBody3D = _body(Vector3(0, 0, -6), ReactionCandidates.CANDIDATE_MASK, 3)
	((wall.get_child(0) as CollisionShape3D).shape as BoxShape3D).size = Vector3(4, 4, 0.5)
	_body(Vector3(2.5, 0, -6), ReactionCandidates.CANDIDATE_MASK, 4)
	var parts: Array = _weapon(DamagePayload.Element.ICE)
	var weapon: HitscanWeapon = parts[0]
	await get_tree().physics_frame
	weapon.set_fire_pressed(true)
	weapon._physics_process(1.0 / 60.0)
	assert_int(weapon.reaction_candidates.queries).is_equal(0)
	assert_int(weapon.traces_cast).is_equal(8)


func test_collect_does_not_allocate() -> void:
	var primary: StaticBody3D = _body(Vector3.ZERO, ReactionCandidates.CANDIDATE_MASK, 10)
	for index: int in 6:
		_body(Vector3(cos(index) * 2.0, 0, sin(index) * 2.0), ReactionCandidates.CANDIDATE_MASK, 20 + index)
	var batch := ShotBatch.new(1, 1, 64, 8)
	var adapter := ReactionCandidates.new()
	adapter.initialize(batch, 3000)
	_root.add_child(adapter)
	await get_tree().physics_frame
	for index: int in 300:
		var ticket: int = batch.reserve(0, 1, 1000)
		adapter.collect(ticket, 0, primary, 10)
		batch.abort(ticket)
	var objects: int = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var memory: int = int(Performance.get_monitor(Performance.MEMORY_STATIC))
	var validator: int = (RefCounted.new().get_instance_id() >> VALIDATOR_SHIFT) & VALIDATOR_MASK
	var written: int = 0
	for index: int in 3600:
		var ticket: int = batch.reserve(0, 1, 1000)
		written += adapter.collect(ticket, 0, primary, 10)
		batch.abort(ticket)
	var created: int = ((RefCounted.new().get_instance_id() >> VALIDATOR_SHIFT) & VALIDATOR_MASK) - validator - 1
	var object_delta: int = int(Performance.get_monitor(Performance.OBJECT_COUNT)) - objects
	var memory_delta: int = int(Performance.get_monitor(Performance.MEMORY_STATIC)) - memory
	assert_int(object_delta).is_equal(0)
	assert_int(created).is_equal(0)
	assert_int(memory_delta).is_less_equal(4096)
	assert_int(written).is_equal(3600 * 6)
