extends GdUnitTestSuite
## HandlePool: формат handle, поколения, порядок выдачи, Zero-Trust снимка.

const SPAN: int = HandlePool.INDEX_SPAN


func test_handle_format_and_issue_order() -> void:
	var pool := HandlePool.new(4)
	for expected: int in 4:
		var h: int = pool.allocate()
		assert_int(h).is_equal(expected)  # поколение 0, индексы с нуля
	assert_bool(pool.is_full()).is_true()
	assert_int(pool.allocate()).is_equal(HandlePool.INVALID_HANDLE)


func test_generation_rejects_stale_handle() -> void:
	var pool := HandlePool.new(2)
	var old: int = pool.allocate()
	assert_bool(pool.release(old)).is_true()
	var fresh: int = pool.allocate()
	assert_int(fresh).is_equal(1 * SPAN + 0)
	assert_bool(pool.is_valid(old)).is_false()
	assert_bool(pool.release(old)).is_false()
	assert_int(pool.handle_at(0)).is_equal(fresh)
	assert_int(pool.handle_at(1)).is_equal(HandlePool.INVALID_HANDLE)


func test_state_roundtrip() -> void:
	var pool := HandlePool.new(4)
	var a: int = pool.allocate()
	var b: int = pool.allocate()
	pool.release(a)
	var state: Dictionary = pool.get_state()
	var restored := HandlePool.new(4)
	assert_bool(restored.set_state(state)).is_true()
	assert_bool(restored.is_valid(b)).is_true()
	assert_bool(restored.is_valid(a)).is_false()
	assert_int(restored.allocate()).is_equal(pool.allocate())


func test_corrupted_states_are_rejected() -> void:
	var base := HandlePool.new(4)
	base.allocate()
	base.allocate()
	var cases: Array[Dictionary] = []
	var dup: Dictionary = base.get_state()
	var dup_free: PackedInt32Array = dup["free"]
	dup_free[1] = dup_free[0]
	dup["free"] = dup_free
	cases.append(dup)
	var out_of_range: Dictionary = base.get_state()
	var oor_free: PackedInt32Array = out_of_range["free"]
	oor_free[0] = 99
	out_of_range["free"] = oor_free
	cases.append(out_of_range)
	var mismatch: Dictionary = base.get_state()
	var alive: PackedByteArray = mismatch["alive"]
	alive[3] = 1
	mismatch["alive"] = alive
	cases.append(mismatch)
	var negative: Dictionary = base.get_state()
	var generation: PackedInt32Array = negative["generation"]
	generation[0] = -1
	negative["generation"] = generation
	cases.append(negative)
	var wrong_capacity: Dictionary = HandlePool.new(8).get_state()
	cases.append(wrong_capacity)
	for state: Dictionary in cases:
		var target := HandlePool.new(4)
		assert_bool(target.set_state(state)).is_false()
		assert_int(target.alive_count()).is_equal(0)  # состояние не изменилось


func test_hot_path_does_not_allocate() -> void:
	var pool := HandlePool.new(64)
	var handles := PackedInt64Array()
	for i: int in 32:
		handles.append(pool.allocate())
	var objects_before: int = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var memory_before: int = int(Performance.get_monitor(Performance.MEMORY_STATIC))
	var acc: int = 0
	for i: int in 20000:
		var slot: int = i % 32
		acc += pool.index_of(handles[slot])
		pool.release(handles[slot])
		handles[slot] = pool.allocate()
	var objects_delta: int = int(Performance.get_monitor(Performance.OBJECT_COUNT)) - objects_before
	var memory_delta: int = int(Performance.get_monitor(Performance.MEMORY_STATIC)) - memory_before
	assert_int(objects_delta).is_equal(0)
	assert_int(memory_delta).is_equal(0)
	assert_int(acc).is_not_equal(-1)
