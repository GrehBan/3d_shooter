extends GdUnitTestSuite
## StatBlock: handle с поколениями, ёмкость, аксессоры, снимок состояния, аллокации.


func test_allocate_gives_zeroed_entity_and_valid_handle() -> void:
	var sb := StatBlock.new(4)
	var h: int = sb.allocate()
	assert_bool(sb.is_valid(h)).is_true()
	assert_int(sb.alive_count()).is_equal(1)
	for stat: int in StatBlock.STAT_COUNT:
		assert_int(sb.get_stat(h, stat)).is_equal(0)
	assert_int(sb.get_status(h)).is_equal(0)


func test_indices_are_issued_from_zero_upwards() -> void:
	var sb := StatBlock.new(4)
	for expected_index: int in 4:
		assert_int(sb.index_of(sb.allocate())).is_equal(expected_index)


func test_stale_handle_is_rejected_after_index_reuse() -> void:
	var sb := StatBlock.new(4)
	var old: int = sb.allocate()
	sb.set_stat(old, StatBlock.Stat.HP, 50_000)
	assert_bool(sb.release(old)).is_true()
	var fresh: int = sb.allocate()
	# Индекс переиспользован, поколение другое.
	assert_int(sb.index_of(fresh)).is_equal(0)
	assert_int(fresh).is_not_equal(old)
	assert_bool(sb.is_valid(old)).is_false()
	assert_bool(sb.set_stat(old, StatBlock.Stat.HP, 1)).is_false()
	assert_int(sb.get_stat(old, StatBlock.Stat.HP)).is_equal(0)
	assert_bool(sb.release(old)).is_false()
	# Новая сущность не задета ни старым значением, ни попыткой записи.
	assert_int(sb.get_stat(fresh, StatBlock.Stat.HP)).is_equal(0)
	assert_bool(sb.is_valid(fresh)).is_true()


func test_invalid_handles_are_rejected() -> void:
	var sb := StatBlock.new(4)
	for bad: int in [StatBlock.INVALID_HANDLE, -12345, 7, 4 + StatBlock.HANDLE_INDEX_SPAN]:
		assert_bool(sb.is_valid(bad)).is_false()
		assert_bool(sb.set_stat(bad, StatBlock.Stat.HP, 1)).is_false()
		assert_bool(sb.release(bad)).is_false()


func test_capacity_exhaustion_is_reported() -> void:
	var sb := StatBlock.new(2)
	sb.allocate()
	sb.allocate()
	var result: Array[int] = []
	await assert_error(func() -> void: result.append(sb.allocate())) \
		.is_push_error("StatBlock: ёмкость 2 исчерпана")
	assert_array(result).is_equal([StatBlock.INVALID_HANDLE])
	assert_int(sb.alive_count()).is_equal(2)


func test_stats_are_independent_per_entity() -> void:
	var sb := StatBlock.new(4)
	var a: int = sb.allocate()
	var b: int = sb.allocate()
	sb.set_stat(a, StatBlock.Stat.HP, 10_000)
	sb.set_stat(b, StatBlock.Stat.HP, 20_000)
	sb.set_stat(a, StatBlock.Stat.ARMOR, 5_000)
	assert_int(sb.get_stat(a, StatBlock.Stat.HP)).is_equal(10_000)
	assert_int(sb.get_stat(b, StatBlock.Stat.HP)).is_equal(20_000)
	assert_int(sb.get_stat(b, StatBlock.Stat.ARMOR)).is_equal(0)


func test_add_stat_clamped() -> void:
	var sb := StatBlock.new(2)
	var h: int = sb.allocate()
	sb.set_stat(h, StatBlock.Stat.HP, 30_000)
	assert_int(sb.add_stat_clamped(h, StatBlock.Stat.HP, -50_000, 0, 100_000)).is_equal(0)
	assert_int(sb.add_stat_clamped(h, StatBlock.Stat.HP, 250_000, 0, 100_000)).is_equal(100_000)
	assert_int(sb.add_stat_clamped(h, StatBlock.Stat.HP, -1, 0, 100_000)).is_equal(99_999)


func test_status_mask_uses_64_bits() -> void:
	var sb := StatBlock.new(2)
	var h: int = sb.allocate()
	var mask: int = (1 << 62) | (1 << 33) | 1
	assert_bool(sb.set_status(h, mask)).is_true()
	assert_int(sb.get_status(h)).is_equal(mask)


func test_state_roundtrip_preserves_entities_and_generations() -> void:
	var sb := StatBlock.new(4)
	var a: int = sb.allocate()
	var b: int = sb.allocate()
	sb.set_stat(a, StatBlock.Stat.HP, 42_000)
	sb.release(b)
	var c: int = sb.allocate()  # переиспользует индекс b с новым поколением
	sb.set_status(c, 0b101)
	var state: Dictionary = sb.get_state()

	var restored := StatBlock.new(4)
	assert_bool(restored.set_state(state)).is_true()
	assert_int(restored.get_stat(a, StatBlock.Stat.HP)).is_equal(42_000)
	assert_int(restored.get_status(c)).is_equal(0b101)
	assert_bool(restored.is_valid(b)).is_false()
	assert_int(restored.alive_count()).is_equal(2)
	# Порядок выдачи после восстановления тот же, что у оригинала.
	assert_int(restored.allocate()).is_equal(sb.allocate())


func test_state_with_wrong_capacity_is_rejected() -> void:
	var state: Dictionary = StatBlock.new(4).get_state()
	var other := StatBlock.new(8)
	await assert_error(func() -> void: other.set_state(state)) \
		.is_push_error("StatBlock.set_state: ёмкость снимка не совпадает")


func test_hot_path_does_not_allocate() -> void:
	var sb := StatBlock.new(64)
	var handles := PackedInt64Array()
	for i: int in 40:
		handles.append(sb.allocate())
	var acc: int = 0
	for i: int in 200:
		acc += sb.add_stat_clamped(handles[i % 40], StatBlock.Stat.HP, 7, 0, 100_000)
	var objects_before: int = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var memory_before: int = int(Performance.get_monitor(Performance.MEMORY_STATIC))
	for i: int in 20000:
		var h: int = handles[i % 40]
		sb.set_stat(h, StatBlock.Stat.SHIELD, i)
		acc += sb.get_stat(h, StatBlock.Stat.SHIELD)
		acc += sb.add_stat_clamped(h, StatBlock.Stat.HP, -3, 0, 100_000)
		acc += int(sb.is_valid(h))
		if i % 50 == 0:
			sb.release(h)
			handles[i % 40] = sb.allocate()
	var objects_delta: int = int(Performance.get_monitor(Performance.OBJECT_COUNT)) - objects_before
	var memory_delta: int = int(Performance.get_monitor(Performance.MEMORY_STATIC)) - memory_before
	assert_int(objects_delta).is_equal(0)
	assert_int(memory_delta).is_equal(0)
	assert_int(acc).is_not_equal(-1)
