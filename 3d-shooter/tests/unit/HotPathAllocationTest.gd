extends GdUnitTestSuite
## Hot-path allocation checks for the classes earlier covered only by integration runs:
## ShotBatch, WeaponState, ShotResolver, LandingEventQueue and ShotVisualPool.
## Each case warms up, then measures 3600 iterations; deltas are captured before asserts.

const WARMUP: int = 300
const MEASURED: int = 3600
const MEMORY_TOLERANCE: int = 1024 * 1024

var _objects: int
var _nodes: int
var _memory: int
var _root: Node3D


func after_test() -> void:
	if is_instance_valid(_root):
		_root.free()


func _begin() -> void:
	_objects = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	_nodes = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	_memory = int(Performance.get_monitor(Performance.MEMORY_STATIC))


func _deltas() -> PackedInt64Array:
	return PackedInt64Array([
		int(Performance.get_monitor(Performance.OBJECT_COUNT)) - _objects,
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)) - _nodes,
		int(Performance.get_monitor(Performance.MEMORY_STATIC)) - _memory,
	])


func _assert_no_growth(deltas: PackedInt64Array) -> void:
	assert_int(deltas[0]).is_equal(0)
	assert_int(deltas[1]).is_equal(0)
	assert_int(deltas[2]).is_less_equal(MEMORY_TOLERANCE)


func _shot_batch_cycle(batch: ShotBatch, source: int, target: int) -> int:
	var ticket: int = batch.reserve(source, 8, 6000)
	for trace: int in 8:
		batch.write_trace(ticket, trace, target if trace % 2 == 0 else ShotBatch.INVALID)
	batch.publish(ticket)
	var aborted: int = batch.reserve(source, 2, 6000)
	batch.abort(aborted)
	var sum: int = 0
	var prepared: int = batch.prepare()
	for shot: int in prepared:
		sum += batch.source_at(shot) + batch.sequence_at(shot) + batch.damage_at(shot)
		for trace: int in batch.trace_count_at(shot):
			sum += batch.target_at(shot, trace)
	batch.consume_prepared()
	return sum


func test_shot_batch_reserve_publish_prepare_consume() -> void:
	var batch := ShotBatch.new(4, 8, 4)
	for i: int in WARMUP:
		_shot_batch_cycle(batch, 0, 1)
	_begin()
	var sum: int = 0
	for i: int in MEASURED:
		sum += _shot_batch_cycle(batch, 0, 1)
		if i % 600 == 599:
			batch.reset_room()
	var deltas: PackedInt64Array = _deltas()
	_assert_no_growth(deltas)
	assert_int(batch.configuration_errors).is_equal(0)
	assert_int(batch.pending_count()).is_equal(0)
	assert_int(sum).is_not_equal(0)


func test_weapon_state_press_request_release_and_clock_reset() -> void:
	var stats := StatBlock.new(4)
	var source: int = stats.allocate()
	stats.set_stat(source, StatBlock.Stat.HP, 100000)
	var batch := ShotBatch.new(4, 8, 4)
	var state := WeaponState.new()
	assert_bool(state.configure(WeaponData.new(), source)).is_true()
	var accepted: int = 0
	var tick: int = 0
	for i: int in WARMUP + MEASURED:
		if i == WARMUP:
			_begin()
			accepted = 0
		state.set_pressed(true)
		var ticket: int = state.request_shot(batch, stats, tick)
		if ticket != ShotBatch.INVALID:
			accepted += 1
			batch.abort(ticket)
		state.set_pressed(false)
		tick += 1
		if i % 900 == 899:
			state.reset_clock(tick)
			tick = 0
	var deltas: PackedInt64Array = _deltas()
	_assert_no_growth(deltas)
	assert_int(accepted).is_greater(0)
	assert_int(batch.configuration_errors).is_equal(0)


var _hits: int = 0


func _count_hit(_source: int, _target: int, _epoch: int, _sequence: int, _trace: int,
		_child: int, _damage: int) -> void:
	_hits += 1


func test_shot_resolver_logic_step_with_listeners() -> void:
	var stats := StatBlock.new(4)
	var source: int = stats.allocate()
	var target: int = stats.allocate()
	var batch := ShotBatch.new(4, 8, 4)
	var resolver := ShotResolver.new(stats, batch, 64)
	resolver.on_hit.connect(_count_hit)
	_hits = 0
	for i: int in WARMUP + MEASURED:
		if i == WARMUP:
			_begin()
		stats.set_stat(target, StatBlock.Stat.HP, 1_000_000)
		var ticket: int = batch.reserve(source, 8, 6000)
		for trace: int in 8:
			batch.write_trace(ticket, trace, target)
		batch.publish(ticket)
		resolver.logic_step(i)
	var deltas: PackedInt64Array = _deltas()
	_assert_no_growth(deltas)
	assert_int(_hits).is_equal((WARMUP + MEASURED) * 8)
	assert_int(resolver.contexts.alive_count()).is_equal(0)
	assert_int(resolver.damage_configuration_errors()).is_equal(0)


func test_landing_event_queue_push_read_clear_and_overflow() -> void:
	var queue := LandingEventQueue.new(4)
	var sum: int = 0
	await assert_error(func() -> void:
		for i: int in 5:
			queue.push(i, 9000, 0)
	).is_push_error("LandingEventQueue: overflow, landing event dropped")
	queue.clear()
	for i: int in WARMUP + MEASURED:
		if i == WARMUP:
			_begin()
		for event: int in 4:
			queue.push(event, 8000 + event, event & 1)
		for event: int in queue.count():
			sum += queue.get_entity(event) + queue.get_height_mm(event) + queue.get_cancel_flags(event)
		queue.clear()
		queue.reset_dropped_count()
	var deltas: PackedInt64Array = _deltas()
	_assert_no_growth(deltas)
	assert_int(sum).is_greater(0)


func test_shot_visual_pool_show_expire_and_frame_follow() -> void:
	_root = Node3D.new()
	add_child(_root)
	var weapon := HitscanWeapon.new()
	weapon.hardware_input_enabled = false
	_root.add_child(weapon)
	var stats := StatBlock.new(4)
	var source: int = stats.allocate()
	stats.set_stat(source, StatBlock.Stat.HP, 100000)
	weapon.initialize(WeaponData.new(), stats, ShotBatch.new(4, 8, 4), source)
	weapon.set_physics_process(false)
	var socket := Node3D.new()
	weapon.add_child(socket)
	var pool := ShotVisualPool.new()
	_root.add_child(pool)
	assert_bool(pool.initialize(ShotVisualData.new(), weapon, socket, 0)).is_true()
	pool.set_physics_process(false)
	pool.set_process(false)
	var sequence: int = 0
	for i: int in WARMUP + MEASURED:
		if i == WARMUP:
			_begin()
		if i % 30 == 0:
			pool._show_muzzle(0, source, sequence)
			for contact: int in 8:
				pool._show_contact(0, source, sequence, Vector3(contact, 0, -5), Vector3.BACK)
			sequence += 1
		pool._physics_process(1.0 / 60.0)
		pool._process(1.0 / 60.0)
	var deltas: PackedInt64Array = _deltas()
	_assert_no_growth(deltas)
	assert_int(pool.dropped_count).is_equal(0)
	assert_int(pool.reused_count).is_greater(0)
