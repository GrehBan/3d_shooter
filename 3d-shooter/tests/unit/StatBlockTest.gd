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


func _corrupted_state_is_rejected(state: Dictionary) -> void:
	var target := StatBlock.new(4)
	await assert_error(func() -> void: target.set_state(state)) \
		.is_push_error("StatBlock.set_state: повреждённый снимок")
	# Отвергнутый снимок не меняет состояние.
	assert_int(target.alive_count()).is_equal(0)


func _sample_state() -> Dictionary:
	var sb := StatBlock.new(4)
	sb.allocate()
	sb.allocate()
	return sb.get_state()  # индексы 0 и 1 живы, свободны 3 и 2


func test_state_with_duplicate_free_index_is_rejected() -> void:
	var state: Dictionary = _sample_state()
	var free: PackedInt32Array = state["free"]
	free[1] = free[0]  # один индекс дважды в free-list
	state["free"] = free
	await _corrupted_state_is_rejected(state)


func test_state_with_free_index_out_of_range_is_rejected() -> void:
	var state: Dictionary = _sample_state()
	var free: PackedInt32Array = state["free"]
	free[0] = 99
	state["free"] = free
	await _corrupted_state_is_rejected(state)


func test_state_with_alive_flag_mismatch_is_rejected() -> void:
	var state: Dictionary = _sample_state()
	var alive: PackedByteArray = state["alive"]
	alive[3] = 1  # индекс 3 в free-list, но помечен живым
	state["alive"] = alive
	await _corrupted_state_is_rejected(state)


func test_state_with_negative_generation_is_rejected() -> void:
	var state: Dictionary = _sample_state()
	var generation: PackedInt32Array = state["generation"]
	generation[0] = -1
	state["generation"] = generation
	await _corrupted_state_is_rejected(state)


func test_handle_beyond_int32_stays_valid() -> void:
	var sb := StatBlock.new(4)
	var state: Dictionary = sb.get_state()
	# Слот 0 переиспользован 40000 раз и сейчас занят.
	var generation: PackedInt32Array = state["generation"]
	generation[0] = 40_000
	var alive: PackedByteArray = state["alive"]
	alive[0] = 1
	var free: PackedInt32Array = state["free"]
	free.remove_at(free.find(0))
	free.append(0)  # хвост за пределами free_count не проверяется
	state["generation"] = generation
	state["alive"] = alive
	state["free"] = free
	state["free_count"] = 3
	state["alive_count"] = 1
	assert_bool(sb.set_state(state)).is_true()
	var handle: int = 40_000 * StatBlock.HANDLE_INDEX_SPAN
	assert_bool(handle > 2_147_483_647).is_true()
	assert_bool(sb.is_valid(handle)).is_true()
	assert_bool(sb.set_stat(handle, StatBlock.Stat.HP, 5_000)).is_true()
	assert_int(sb.get_stat(handle, StatBlock.Stat.HP)).is_equal(5_000)
	# Усечённый до Int32 handle недействителен.
	assert_bool(sb.is_valid(handle & 0x7FFFFFFF)).is_false()


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
