extends GdUnitTestSuite
## Hot-path allocation checks for the classes earlier covered only by integration runs:
## ShotBatch, WeaponState, ShotResolver, LandingEventQueue and ShotVisualPool.
## Each case warms up, then measures MEASURED iterations without gdUnit calls inside the
## window. Deltas are captured before the first assert_*:
## * OBJECT_COUNT and OBJECT_NODE_COUNT catch retained objects and nodes;
## * the ObjectDB validator of two probe objects catches objects created and freed inside
##   the window (each new Object advances it by one);
## * MEMORY_STATIC is held to 4 KiB.
## Temporary Array, Dictionary and String values are not Objects and are not caught here.

const GdUnitErrorCount: Script = preload("res://tests/util/GdUnitErrorCount.gd")
const WARMUP: int = 300
const MEASURED: int = 3600
const MEMORY_TOLERANCE: int = 4096
const VALIDATOR_SHIFT: int = 24
const VALIDATOR_MASK: int = (1 << 39) - 1

var _objects: int
var _nodes: int
var _memory: int
var _validator: int
var _root: Node3D
var _hits: int = 0
var _kills: int = 0
var _fired: int = 0
var _resolved: int = 0


func after_test() -> void:
	if is_instance_valid(_root):
		_root.free()


## ObjectDB validator of a fresh probe object; the probe itself is freed immediately.
## Objects created by other engine threads inside the window can only make the count larger:
## they may cause a false failure but never hide a leak of the code under test.
static func _validator_now() -> int:
	return (RefCounted.new().get_instance_id() >> VALIDATOR_SHIFT) & VALIDATOR_MASK


func _begin() -> void:
	_objects = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	_nodes = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	_memory = int(Performance.get_monitor(Performance.MEMORY_STATIC))
	_validator = _validator_now()


## [retained objects, retained nodes, static memory growth, objects created in the window]
func _deltas() -> PackedInt64Array:
	var created: int = ((_validator_now() - _validator) & VALIDATOR_MASK) - 1
	return PackedInt64Array([
		int(Performance.get_monitor(Performance.OBJECT_COUNT)) - _objects,
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)) - _nodes,
		int(Performance.get_monitor(Performance.MEMORY_STATIC)) - _memory,
		created,
	])


func _assert_no_growth(deltas: PackedInt64Array) -> void:
	assert_int(deltas[0]).is_equal(0)
	assert_int(deltas[1]).is_equal(0)
	assert_int(deltas[2]).is_less_equal(MEMORY_TOLERANCE)
	assert_int(deltas[3]).is_equal(0)


func test_validator_probe_catches_a_temporary_object() -> void:
	_begin()
	for i: int in 3:
		var temporary := RefCounted.new()
		temporary.get_instance_id()
	var deltas: PackedInt64Array = _deltas()
	assert_int(deltas[0]).is_equal(0)  # nothing retained
	assert_int(deltas[3]).is_equal(3)  # but three objects were created


func _shot_batch_cycle(batch: ShotBatch, source: int, target: int) -> int:
	var ticket: int = batch.reserve(source, 8, 6000)
	for trace: int in 8:
		batch.write_trace(ticket, trace, target if trace % 2 == 0 else ShotBatch.INVALID)
	batch.publish(ticket)
	batch.abort(batch.reserve(source, 2, 6000))
	var prepared: int = batch.prepare()
	for shot: int in prepared:
		for trace: int in batch.trace_count_at(shot):
			batch.target_at(shot, trace)
		batch.source_at(shot)
		batch.sequence_at(shot)
		batch.damage_at(shot)
	batch.consume_prepared()
	return prepared


func test_shot_batch_reserve_publish_prepare_consume() -> void:
	var batch := ShotBatch.new(4, 8, 4)
	for i: int in WARMUP:
		_shot_batch_cycle(batch, 0, 1)
	var prepared: int = 0
	_begin()
	for i: int in MEASURED:
		prepared += _shot_batch_cycle(batch, 0, 1)
		if i % 600 == 599:
			batch.reset_room()
	var deltas: PackedInt64Array = _deltas()
	_assert_no_growth(deltas)
	assert_int(prepared).is_equal(MEASURED)
	assert_int(batch.configuration_errors).is_equal(0)
	assert_int(batch.pending_count()).is_equal(0)


func test_weapon_state_press_request_release_and_clock_reset() -> void:
	var stats := StatBlock.new(4)
	var source: int = stats.allocate()
	stats.set_stat(source, StatBlock.Stat.HP, 100000)
	var batch := ShotBatch.new(4, 8, 4)
	var data := WeaponData.new()
	var state := WeaponState.new()
	assert_bool(state.configure(data, source)).is_true()
	var accepted: int = 0
	var tick: int = 0
	for i: int in WARMUP + MEASURED:
		if i == WARMUP:
			accepted = 0
			_begin()
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
	# A fresh press every tick fires exactly once per cooldown; resets land on cooldown edges.
	assert_int(accepted).is_equal(MEASURED / data.cooldown_ticks)
	assert_int(batch.configuration_errors).is_equal(0)


func _count_hit(_source: int, _target: int, _epoch: int, _sequence: int, _trace: int,
		_child: int, _damage: int) -> void:
	_hits += 1


func _count_kill(_source: int, _target: int, _epoch: int, _sequence: int, _trace: int) -> void:
	_kills += 1


func _count_fire(_source: int, _epoch: int, _sequence: int, _root_handle: int) -> void:
	_fired += 1


func _count_resolved(_source: int, _epoch: int, _sequence: int, _root_handle: int) -> void:
	_resolved += 1


func _resolver_run(target_hp: int) -> PackedInt64Array:
	var stats := StatBlock.new(4)
	var source: int = stats.allocate()
	var target: int = stats.allocate()
	var batch := ShotBatch.new(4, 8, 4)
	var resolver := ShotResolver.new(stats, batch, 64)
	resolver.on_fire.connect(_count_fire)
	resolver.on_hit.connect(_count_hit)
	resolver.on_kill.connect(_count_kill)
	resolver.on_attack_resolved.connect(_count_resolved)
	for i: int in WARMUP + MEASURED:
		if i == WARMUP:
			_hits = 0
			_kills = 0
			_fired = 0
			_resolved = 0
			_begin()
		stats.set_stat(target, StatBlock.Stat.HP, target_hp)
		var ticket: int = batch.reserve(source, 8, 6000)
		for trace: int in 8:
			batch.write_trace(ticket, trace, target)
		batch.publish(ticket)
		resolver.logic_step(i)
	var deltas: PackedInt64Array = _deltas()
	_assert_no_growth(deltas)
	assert_int(resolver.contexts.alive_count()).is_equal(0)
	assert_int(resolver.damage_configuration_errors()).is_equal(0)
	return PackedInt64Array([_fired, _hits, _kills, _resolved])


func test_shot_resolver_logic_step_with_listeners() -> void:
	var counts: PackedInt64Array = _resolver_run(1_000_000)
	assert_array(counts).is_equal(PackedInt64Array([MEASURED, MEASURED * 8, 0, MEASURED]))


func test_shot_resolver_kill_path_each_tick() -> void:
	# The first pellet kills (HP > 0 -> 0); the other seven are dead-target no-ops.
	var counts: PackedInt64Array = _resolver_run(6000)
	assert_array(counts).is_equal(PackedInt64Array([MEASURED, MEASURED, MEASURED, MEASURED]))


func test_landing_event_queue_push_read_clear_and_overflow() -> void:
	var queue := LandingEventQueue.new(4)
	var sum: int = 0
	for i: int in WARMUP + MEASURED:
		if i == WARMUP:
			sum = 0
			_begin()
		for event: int in 4:
			queue.push(event, 8000 + event, event & 1)
		for event: int in queue.count():
			sum += queue.get_entity(event) + queue.get_height_mm(event) + queue.get_cancel_flags(event)
		queue.clear()
	var deltas: PackedInt64Array = _deltas()
	_assert_no_growth(deltas)
	assert_int(sum).is_equal(MEASURED * (0 + 1 + 2 + 3 + 4 * 8000 + 6 + 2))
	assert_int(queue.dropped_count()).is_equal(0)


func test_landing_event_queue_suppressed_overflow() -> void:
	var queue := LandingEventQueue.new(4)
	for event: int in 4:
		queue.push(event, 9000, 0)
	# The first refusal reports once; later refusals only count until clear().
	var notification: GdUnitGodotErrorAssert = assert_error(func() -> void:
		for i: int in WARMUP:
			queue.push(9, 9000, 0)
	)
	await notification.is_push_error("LandingEventQueue: overflow, landing event dropped")
	assert_int(GdUnitErrorCount.entries(notification)).is_equal(1)
	queue.reset_dropped_count()
	_begin()
	for i: int in MEASURED:
		queue.push(9, 9000, 0)
	var deltas: PackedInt64Array = _deltas()
	_assert_no_growth(deltas)
	assert_int(queue.dropped_count()).is_equal(MEASURED)
	assert_int(queue.count()).is_equal(4)


func test_shot_visual_pool_through_real_shot_signal() -> void:
	_root = Node3D.new()
	add_child(_root)
	var wall := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20, 20, 1)
	shape.shape = box
	wall.add_child(shape)
	wall.position = Vector3(0, 0, -5)
	_root.add_child(wall)
	var weapon := HitscanWeapon.new()
	weapon.hardware_input_enabled = false
	_root.add_child(weapon)
	var stats := StatBlock.new(4)
	var source: int = stats.allocate()
	stats.set_stat(source, StatBlock.Stat.HP, 100000)
	var batch := ShotBatch.new(4, 8, 4)
	var initialized: bool = weapon.initialize(WeaponData.new(), stats, batch, source)
	weapon.set_physics_process(false)
	var socket := Node3D.new()
	weapon.add_child(socket)
	var pool := ShotVisualPool.new()
	_root.add_child(pool)
	var pool_initialized: bool = pool.initialize(ShotVisualData.new(), weapon, socket, 0)
	pool.set_physics_process(false)
	pool.set_process(false)
	await get_tree().physics_frame  # register the wall in the physics space
	var reused_before: int = 0
	for i: int in WARMUP + MEASURED:
		if i == WARMUP:
			reused_before = pool.reused_count
			_begin()
		if i % 30 == 0:
			# The production route: input edge -> weapon physics step -> shot_presented -> pool.
			weapon.set_fire_pressed(true)
			weapon._physics_process(1.0 / 60.0)
			weapon.set_fire_pressed(false)
			weapon.reset_clock(1_000_000)  # clear the logic-tick cooldown without frames
			batch.prepare()
			batch.consume_prepared()
		pool._physics_process(1.0 / 60.0)
		pool._process(1.0 / 60.0)
	var deltas: PackedInt64Array = _deltas()
	assert_bool(initialized).is_true()
	assert_bool(pool_initialized).is_true()
	_assert_no_growth(deltas)
	assert_int(pool.dropped_count).is_equal(0)
	assert_int(pool.configuration_errors).is_equal(0)
	# Warmup fills every slot, so each of the 120 shots reuses 1 muzzle + 8 impacts + 8 marks.
	assert_int(pool.reused_count - reused_before).is_equal(MEASURED / 30 * 17)
	assert_int(pool.active_count(ShotVisualPool.Kind.MARK)).is_greater(0)  # rays hit the wall
	assert_int(batch.configuration_errors).is_equal(0)
