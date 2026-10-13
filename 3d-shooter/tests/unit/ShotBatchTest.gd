extends GdUnitTestSuite


func test_published_ticket_sequence_getter_does_not_expose_pending_or_consumed_slot() -> void:
	var batch := ShotBatch.new(4, 8, 4)
	var ticket: int = batch.reserve(40000 * 65536, 1, 6000)
	assert_int(batch.sequence_for_ticket(ticket)).is_equal(-1)
	batch.write_trace(ticket, 0, -1)
	assert_bool(batch.publish(ticket)).is_true()
	assert_int(batch.sequence_for_ticket(ticket)).is_equal(0)
	assert_int(batch.prepare()).is_equal(1)
	batch.consume_prepared()
	assert_int(batch.sequence_for_ticket(ticket)).is_equal(-1)
	var next: int = batch.reserve(40000 * 65536, 1, 6000)
	batch.abort(next)
	assert_int(batch.sequence_for_ticket(next)).is_equal(-1)
	assert_int(batch.sequence_for_ticket(ticket)).is_equal(-1)


func test_atomic_publication_indices_abort_and_tail() -> void:
	var batch := ShotBatch.new(2, 9, 4)
	var ticket: int = batch.reserve(1, 3, 6000)
	assert_int(batch.pending_count()).is_equal(1)
	assert_int(batch.prepare()).is_equal(0)
	assert_bool(batch.write_trace(ticket, 2, 33)).is_true()
	assert_bool(batch.write_trace(ticket, 2, 999)).is_false()
	assert_bool(batch.publish(ticket)).is_false()
	assert_bool(batch.write_trace(ticket, 0, 11)).is_true()
	assert_bool(batch.write_trace(ticket, 1, -1)).is_true()
	assert_bool(batch.write_trace(ticket, 3, 444)).is_false()
	batch._target[3] = 444  # Poison unused tail: consumers must use trace_count, not stride.
	assert_bool(batch.publish(ticket)).is_true()
	assert_int(batch.prepare()).is_equal(1)
	assert_int(batch.trace_count_at(0)).is_equal(3)
	assert_int(batch.target_at(0, 0)).is_equal(11)
	assert_int(batch.target_at(0, 1)).is_equal(-1)
	assert_int(batch.target_at(0, 2)).is_equal(33)
	var pending: int = batch.reserve(2, 1, 6000)
	batch.consume_prepared()
	assert_int(batch.pending_count()).is_equal(1)
	assert_bool(batch.abort(pending)).is_true()
	assert_bool(batch.write_trace(pending, 0, 44)).is_false()
	var fresh: int = batch.reserve(2, 1, 6000)
	assert_bool(batch.publish(fresh)).is_false()
	assert_bool(batch.write_trace(fresh, 0, -1)).is_true()
	assert_bool(batch.publish(fresh)).is_true()


func test_shared_full_source_sequence_and_publication_order() -> void:
	var batch := ShotBatch.new(4, 3, 4)
	var large: int = 40_000 * HandlePool.INDEX_SPAN + 1
	var first: int = batch.reserve(large, 2, 6000)
	var other: int = batch.reserve(2, 1, 6000)
	var second: int = batch.reserve(large, 1, 6000)
	batch.write_trace(second, 0, large + 1)
	batch.publish(second)
	batch.write_trace(other, 0, -1)
	batch.publish(other)
	batch.write_trace(first, 1, large + 2)
	batch.write_trace(first, 0, large + 1)
	batch.publish(first)
	assert_int(batch.prepare()).is_equal(3)
	assert_int(batch.source_at(0)).is_equal(2)
	assert_int(batch.source_at(1)).is_equal(large)
	assert_int(batch.sequence_at(1)).is_equal(0)
	assert_int(batch.sequence_at(2)).is_equal(1)
	assert_int(batch.target_at(1, 1)).is_equal(large + 2)
	assert_int(batch.epoch_at(1)).is_equal(0)


func test_capacity_and_identity_exhaustion_are_atomic_and_report_once() -> void:
	var batch := ShotBatch.new(1, 2, 2)
	var ticket: int = batch.reserve(0, 2, 6000)
	assert_error(func() -> void: batch.reserve(0, 2, 6000)).is_push_error("ShotBatch: invalid request, capacity or identity exhausted")
	assert_int(batch.reserve(0, 3, 6000)).is_equal(-1)
	assert_int(batch.configuration_errors).is_equal(2)
	assert_int(batch.pending_count()).is_equal(1)
	assert_bool(batch.abort(ticket)).is_true()
	batch._next_sequence[0] = ShotBatch.INT_MAX
	assert_int(batch.reserve(0, 1, 6000)).is_equal(-1)
	assert_int(batch.pending_count()).is_equal(0)
	assert_int(batch._next_sequence[0]).is_equal(ShotBatch.INT_MAX)
	assert_bool(batch.reset_room()).is_true()
	assert_int(batch.epoch).is_equal(1)
	assert_int(batch.configuration_errors).is_equal(0)
	var next: int = batch.reserve(0, 1, 6000)
	assert_bool(batch.write_trace(ticket, 0, 999)).is_false()
	batch.write_trace(next, 0, -1)
	batch.publish(next)
	batch.prepare()
	assert_int(batch.sequence_at(0)).is_equal(0)
	assert_int(batch.epoch_at(0)).is_equal(1)
	batch.epoch = ShotBatch.INT_MAX
	assert_error(func() -> void: batch.reset_room()).is_push_error("ShotBatch: invalid request, capacity or identity exhausted")
	assert_int(batch.count()).is_equal(1)


func test_room_preset_dimensions_memory_and_retained_children_budget() -> void:
	var data := WeaponData.new()
	assert_int(WeaponData.validate_room([data], 4, 32, 131072, 16, 64, 16)).is_equal(8)
	assert_int(WeaponData.validate_room([data], 4, 7, 131072, 16, 64, 16)).is_equal(-1)
	assert_int(WeaponData.validate_room([data], 4, 32, 1024, 16, 64, 16)).is_equal(-1)
	assert_int(WeaponData.validate_room([data], 4, 32, 131072, 16, 35, 0)).is_equal(-1)
	data.pellet_count = 12
	assert_int(WeaponData.validate_room([data], 2, 32, 131072, 16, 32, 0)).is_equal(12)
	for property: StringName in [&"pellet_count", &"damage_raw", &"range_mm", &"cooldown_ticks"]:
		var invalid := WeaponData.new()
		invalid.set(property, 0)
		assert_bool(invalid.is_valid()).is_false()
	data.spread_millidegrees = 90000
	assert_bool(data.is_valid()).is_false()
	data.spread_millidegrees = 5000
	data.pattern = &"random"
	assert_bool(data.is_valid()).is_false()
	var invalid := WeaponData.new()
	invalid.semi_auto = false
	assert_bool(invalid.is_valid()).is_false()
	invalid.semi_auto = true
	invalid.spread_millidegrees = -1
	assert_bool(invalid.is_valid()).is_false()
	assert_int(WeaponData.validate_room([null], 1, 32, 131072, 16, 64, 0)).is_equal(-1)
	var larger := WeaponData.new()
	larger.pellet_count = 12
	assert_int(WeaponData.validate_room([WeaponData.new(), larger], 2, 32, 131072, 16, 64, 0)).is_equal(12)


func test_live_pending_ticket_cannot_write_after_reset_and_ticket_exhaustion() -> void:
	var batch := ShotBatch.new(2, 8, 2)
	var old: int = batch.reserve(0, 8, 6000)
	batch.write_trace(old, 0, 123)
	batch.reset_room()
	var fresh: int = batch.reserve(0, 8, 6000)
	assert_bool(batch.write_trace(old, 1, 999)).is_false()
	assert_bool(batch.publish(old)).is_false()
	assert_bool(batch.publish(fresh)).is_false()
	batch.abort(fresh)
	batch._next_ticket = ShotBatch.INT_MAX
	assert_error(func() -> void: batch.reserve(0, 1, 6000)).is_push_error("ShotBatch: invalid request, capacity or identity exhausted")
	assert_int(batch.pending_count()).is_equal(0)
	assert_int(batch._next_ticket).is_equal(ShotBatch.INT_MAX)
