extends GdUnitTestSuite
## Independent exact-integer oracle: tests/tools/damage_pipeline_ref.py.
## The capacity-three FIFO wraps while full-width metadata stays opaque.

const HIGH: int = 40000 * 65536
const REPLACEMENT: int = 65536 + 2
const INT64_MAX: int = 0x7FFFFFFFFFFFFFFF
const INT32_MAX: int = 2147483647

var _hash: int


func _word(value: int) -> void:
	_hash = ((_hash ^ (value & 0xFFFFFFFF)) * 16777619) & 0xFFFFFFFF
	_hash = ((_hash ^ ((value >> 32) & 0xFFFFFFFF)) * 16777619) & 0xFFFFFFFF


func _enqueue(payloads: DamagePayloadBuffer, cases: Array[PackedInt64Array], index: int) -> void:
	var source: int = -1 if index % 3 == 0 else (1 << 50) + index * 65536 + 7
	var context: int = INT64_MAX - index * 65536 if index % 2 == 0 else -1
	var tags: int = (1 << 60) + index if index % 2 == 0 else -(1 << 60) + index
	payloads.push(source, cases[index][0], cases[index][4], DamagePayload.Element.NONE,
			tags, 0, context)


func _record_payload(payloads: DamagePayloadBuffer, slot: int) -> void:
	_word(payloads.get_source(slot))
	_word(payloads.get_target(slot))
	_word(payloads.get_attack_context(slot))
	_word(payloads.get_amount(slot))
	_word(payloads.get_tags(slot))
	_word(payloads.get_element(slot))
	_word(payloads.get_flags(slot))
	_word(payloads.get_phase(slot))


func test_physical_floor_int64_metadata_stale_and_fifo_wrap_golden() -> void:
	# target, initial HP, initial shield, armor, raw amount
	var cases: Array[PackedInt64Array] = [
		PackedInt64Array([HIGH, 100000, 0, 0, 12345]),
		PackedInt64Array([HIGH, 100000, 20000, 33333, 12345]),
		PackedInt64Array([HIGH, 100000, 12345, 99999, 12345]),
		PackedInt64Array([HIGH, 100000, 12344, 33333, 12346]),
		PackedInt64Array([HIGH, 100000, 0, 33333, 100001]),
		PackedInt64Array([HIGH, 100000, 0, 1, 100001]),
		PackedInt64Array([HIGH, 100000, 0, 99999, 99999]),
		PackedInt64Array([HIGH, 100000, 0, 99999, 100000]),
		PackedInt64Array([HIGH, 100000, 0, -123, 100001]),
		PackedInt64Array([HIGH, 100000, 2500, 100000, INT64_MAX]),
		PackedInt64Array([HIGH, 100000, 2500, 100001, INT64_MAX - 1]),
		PackedInt64Array([HIGH, INT32_MAX, INT32_MAX, 99999, INT64_MAX]),
		PackedInt64Array([HIGH, INT32_MAX, 0, 0, INT64_MAX]),
		PackedInt64Array([HIGH, INT32_MAX, 0, 33333, INT64_MAX - 65535]),
		PackedInt64Array([HIGH, 1, 0, 99999, 100000]),
		PackedInt64Array([HIGH, 1, 0, 99999, 99999]),
		PackedInt64Array([HIGH, 12345, -17, 33333, 12346]),
		PackedInt64Array([HIGH, 12345, -17, 33333, 0]),
		PackedInt64Array([HIGH, 0, -17, 33333, INT64_MAX]),
		PackedInt64Array([HIGH, -7, 3456, 33333, INT64_MAX]),
		PackedInt64Array([1, 100000, 0, 0, INT64_MAX]),
		PackedInt64Array([2, 100000, 4321, 33333, INT64_MAX]),
		PackedInt64Array([REPLACEMENT, 100000, 4321, 33333, 5432]),
		PackedInt64Array([-1, 100000, 4321, 33333, INT64_MAX]),
		PackedInt64Array([HIGH + 1, 100000, 4321, 33333, INT64_MAX]),
		PackedInt64Array([HIGH, INT32_MAX, INT32_MAX, 0, INT32_MAX]),
		PackedInt64Array([HIGH, INT32_MAX, INT32_MAX, 0, INT32_MAX + 1]),
		PackedInt64Array([HIGH, INT32_MAX, 1, 99999, 200001]),
	]
	var stats := StatBlock.new(3)
	for index: int in 3:
		stats.allocate()
	var snapshot: Dictionary = stats.get_state()
	snapshot.generation[0] = 40000
	assert_bool(stats.set_state(snapshot)).is_true()
	assert_bool(stats.release(2)).is_true()
	assert_int(stats.allocate()).is_equal(REPLACEMENT)
	for handle: int in [HIGH, REPLACEMENT]:
		stats.set_stat(handle, StatBlock.Stat.MAX_HP, INT32_MAX)
		stats.set_stat(handle, StatBlock.Stat.MAX_SHIELD, INT32_MAX)
		stats.set_stat(handle, StatBlock.Stat.ENERGY, 4321)
		stats.set_stat(handle, StatBlock.Stat.MAX_ENERGY, 9876)
	stats.set_status(HIGH, (1 << 60) + 17)
	stats.set_status(REPLACEMENT, -(1 << 60) + 19)
	stats.set_stat(1, StatBlock.Stat.MAX_HP, 100000)
	stats.set_stat(1, StatBlock.Stat.SHIELD, 3456)
	stats.set_stat(1, StatBlock.Stat.MAX_SHIELD, 10000)
	stats.set_stat(1, StatBlock.Stat.ARMOR, 22222)
	stats.set_stat(1, StatBlock.Stat.ENERGY, 765)
	stats.set_stat(1, StatBlock.Stat.MAX_ENERGY, 1234)
	stats.set_status(1, 7)
	var payloads := DamagePayloadBuffer.new(3)
	var pipeline := DamagePipeline.new(stats)
	_hash = 2166136261
	_word(pipeline.resolve_front(payloads))
	for index: int in 3:
		_enqueue(payloads, cases, index)
	var next_index: int = 3
	var positive: int = 0
	for index: int in cases.size():
		for handle: int in [HIGH, REPLACEMENT]:
			stats.set_stat(handle, StatBlock.Stat.HP, cases[index][1])
			stats.set_stat(handle, StatBlock.Stat.SHIELD, cases[index][2])
			stats.set_stat(handle, StatBlock.Stat.ARMOR, cases[index][3])
		_word(index)
		_word(payloads.front_slot())
		_word(payloads.count())
		var applied: int = pipeline.resolve_front(payloads)
		positive += 1 if applied > 0 else 0
		_word(applied)
		_word(payloads.front_slot())
		_word(payloads.count())
		_record_payload(payloads, payloads.front_slot())
		for handle: int in [HIGH, 1, REPLACEMENT]:
			for stat: int in StatBlock.STAT_COUNT:
				_word(stats.get_stat(handle, stat))
			_word(stats.get_status(handle))
		payloads.pop_front()
		if next_index < cases.size():
			_enqueue(payloads, cases, next_index)
			next_index += 1
	_word(pipeline.resolve_front(payloads))
	_word(payloads.count())
	_word(payloads.dropped_count())
	_word(pipeline.configuration_errors)
	assert_int(_hash).is_equal(2671520872)  # Independent Python oracle.
	assert_int(cases.size()).is_equal(28)
	assert_int(positive).is_equal(14)
	assert_int(payloads.dropped_count()).is_equal(0)
	assert_int(pipeline.configuration_errors).is_equal(0)
