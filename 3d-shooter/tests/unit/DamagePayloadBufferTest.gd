extends GdUnitTestSuite
## DamagePayloadBuffer: FIFO, перенос через границу кольца, переполнение, int64-поля.


func _push_simple(buffer: DamagePayloadBuffer, value: int) -> int:
	return buffer.push(value, value + 1, value * 1000, DamagePayload.Element.NONE, 0, 0, DamagePayload.NO_HANDLE)


func test_push_stores_all_fields_in_base_phase() -> void:
	var buffer := DamagePayloadBuffer.new(4)
	var slot: int = buffer.push(11, 22, 1_500, DamagePayload.Element.FIRE, 1 << 40,
			DamagePayload.Flag.CRIT | DamagePayload.Flag.SECONDARY, 33)
	assert_int(slot).is_not_equal(DamagePayloadBuffer.INVALID_SLOT)
	assert_int(buffer.get_source(slot)).is_equal(11)
	assert_int(buffer.get_target(slot)).is_equal(22)
	assert_int(buffer.get_amount(slot)).is_equal(1_500)
	assert_int(buffer.get_element(slot)).is_equal(DamagePayload.Element.FIRE)
	assert_int(buffer.get_tags(slot)).is_equal(1 << 40)
	assert_int(buffer.get_flags(slot)).is_equal(DamagePayload.Flag.CRIT | DamagePayload.Flag.SECONDARY)
	assert_int(buffer.get_attack_context(slot)).is_equal(33)
	assert_int(buffer.get_phase(slot)).is_equal(DamagePayload.Phase.BASE)


func test_fifo_order_across_ring_wraparound() -> void:
	var buffer := DamagePayloadBuffer.new(3)
	var popped := PackedInt64Array()
	for value: int in 10:
		_push_simple(buffer, value)
		if buffer.count() == 3:
			popped.append(buffer.get_source(buffer.front_slot()))
			buffer.pop_front()
	while not buffer.is_empty():
		popped.append(buffer.get_source(buffer.front_slot()))
		buffer.pop_front()
	assert_array(popped).is_equal(PackedInt64Array([0, 1, 2, 3, 4, 5, 6, 7, 8, 9]))
	assert_int(buffer.dropped_count()).is_equal(0)


func test_slot_at_walks_from_head() -> void:
	var buffer := DamagePayloadBuffer.new(4)
	for value: int in 6:
		_push_simple(buffer, value)
		if buffer.count() == 4:
			buffer.pop_front()
	var seen := PackedInt64Array()
	for i: int in buffer.count():
		seen.append(buffer.get_source(buffer.slot_at(i)))
	assert_array(seen).is_equal(PackedInt64Array([3, 4, 5]))
	assert_int(buffer.slot_at(3)).is_equal(DamagePayloadBuffer.INVALID_SLOT)
	assert_int(buffer.slot_at(-1)).is_equal(DamagePayloadBuffer.INVALID_SLOT)


func test_overflow_drops_new_records_and_counts_them() -> void:
	var buffer := DamagePayloadBuffer.new(2)
	_push_simple(buffer, 1)
	_push_simple(buffer, 2)
	assert_int(_push_simple(buffer, 3)).is_equal(DamagePayloadBuffer.INVALID_SLOT)
	assert_int(_push_simple(buffer, 4)).is_equal(DamagePayloadBuffer.INVALID_SLOT)
	assert_int(buffer.dropped_count()).is_equal(2)
	# Уже лежащие записи не тронуты.
	assert_int(buffer.get_source(buffer.slot_at(0))).is_equal(1)
	assert_int(buffer.get_source(buffer.slot_at(1))).is_equal(2)
	buffer.reset_dropped_count()
	assert_int(buffer.dropped_count()).is_equal(0)


func test_overflow_is_deterministic() -> void:
	var results: Array[PackedInt64Array] = []
	for run: int in 2:
		var buffer := DamagePayloadBuffer.new(5)
		var trace := PackedInt64Array()
		for value: int in 40:
			trace.append(_push_simple(buffer, value))
			if value % 3 == 0:
				buffer.pop_front()
		trace.append(buffer.dropped_count())
		results.append(trace)
	assert_array(results[0]).is_equal(results[1])


func test_mutators_update_slot() -> void:
	var buffer := DamagePayloadBuffer.new(2)
	var slot: int = _push_simple(buffer, 5)
	buffer.set_amount(slot, 12_345)
	buffer.set_element(slot, DamagePayload.Element.ICE)
	buffer.set_flags(slot, DamagePayload.Flag.DOT)
	buffer.set_phase(slot, DamagePayload.Phase.MITIGATION)
	assert_int(buffer.get_amount(slot)).is_equal(12_345)
	assert_int(buffer.get_element(slot)).is_equal(DamagePayload.Element.ICE)
	assert_int(buffer.get_flags(slot)).is_equal(DamagePayload.Flag.DOT)
	assert_int(buffer.get_phase(slot)).is_equal(DamagePayload.Phase.MITIGATION)


func test_int64_fields_keep_values_beyond_int32() -> void:
	var buffer := DamagePayloadBuffer.new(2)
	var big_handle: int = 40_000 * StatBlock.HANDLE_INDEX_SPAN + 3
	var big_amount: int = 10_000_000_000  # 10 млн ед. ×1000
	var slot: int = buffer.push(big_handle, big_handle + 1, big_amount,
			DamagePayload.Element.NONE, 0, 0, big_handle + 2)
	assert_int(buffer.get_source(slot)).is_equal(big_handle)
	assert_int(buffer.get_target(slot)).is_equal(big_handle + 1)
	assert_int(buffer.get_attack_context(slot)).is_equal(big_handle + 2)
	assert_int(buffer.get_amount(slot)).is_equal(big_amount)


func test_empty_buffer_behaviour() -> void:
	var buffer := DamagePayloadBuffer.new(2)
	assert_int(buffer.front_slot()).is_equal(DamagePayloadBuffer.INVALID_SLOT)
	assert_bool(buffer.pop_front()).is_false()
	_push_simple(buffer, 1)
	buffer.clear()
	assert_bool(buffer.is_empty()).is_true()


func test_hot_path_does_not_allocate() -> void:
	var buffer := DamagePayloadBuffer.new(64)
	for value: int in 200:
		_push_simple(buffer, value)
		buffer.pop_front()
	var objects_before: int = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var memory_before: int = int(Performance.get_monitor(Performance.MEMORY_STATIC))
	var acc: int = 0
	for value: int in 20000:
		var slot: int = buffer.push(value, value, value * 3, DamagePayload.Element.ACID, 0, 0, 0)
		if slot != DamagePayloadBuffer.INVALID_SLOT:
			buffer.set_amount(slot, buffer.get_amount(slot) / 2)
			buffer.set_phase(slot, DamagePayload.Phase.APPLY)
		if value % 2 == 0:
			while not buffer.is_empty():
				acc += buffer.get_amount(buffer.front_slot())
				buffer.pop_front()
	var objects_delta: int = int(Performance.get_monitor(Performance.OBJECT_COUNT)) - objects_before
	var memory_delta: int = int(Performance.get_monitor(Performance.MEMORY_STATIC)) - memory_before
	assert_int(objects_delta).is_equal(0)
	assert_int(memory_delta).is_equal(0)
	assert_int(acc).is_not_equal(-1)
