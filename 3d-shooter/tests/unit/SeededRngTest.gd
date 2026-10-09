extends GdUnitTestSuite
## SeededRng: свойства генератора, изоляция подпотоков, отсутствие аллокаций.


func test_same_seed_gives_same_sequence() -> void:
	var a := SeededRng.new(123456789)
	var b := SeededRng.new(123456789)
	for i: int in 1000:
		assert_int(a.next_u32()).is_equal(b.next_u32())


func test_nearby_seeds_differ_from_first_value() -> void:
	# Первый выход xoshiro128** зависит только от слова s1: сидинг обязан
	# подмешивать в него обе половины сида.
	var firsts := {}
	for s: int in 64:
		firsts[SeededRng.new(s).next_u32()] = true
	assert_int(firsts.size()).is_equal(64)


func test_next_u32_stays_in_32_bits_for_extreme_seeds() -> void:
	for s: int in [0, -1, 9223372036854775807, -9223372036854775807 - 1]:
		var r := SeededRng.new(s)
		for i: int in 1000:
			var v: int = r.next_u32()
			assert_bool(v >= 0 and v <= SeededRng.MASK32).is_true()


func test_range_int_bounds_and_coverage() -> void:
	var r := SeededRng.new(2024)
	var counts := PackedInt32Array()
	counts.resize(6)
	for i: int in 60000:
		var v: int = r.range_int(-2, 3)
		assert_bool(v >= -2 and v <= 3).is_true()
		counts[v + 2] += 1
	for c: int in counts:
		# Ожидание 10000 на ячейку, сигма около 91: допуск ±500 с большим запасом.
		assert_int(c).is_between(9500, 10500)


func test_range_int_degenerate_and_full_span() -> void:
	var r := SeededRng.new(1)
	assert_int(r.range_int(7, 7)).is_equal(7)
	var v: int = r.range_int(0, SeededRng.MASK32)
	assert_bool(v >= 0 and v <= SeededRng.MASK32).is_true()


func test_chance_permille_edges_and_rate() -> void:
	var r := SeededRng.new(99)
	assert_bool(r.chance_permille(0)).is_false()
	assert_bool(r.chance_permille(-5)).is_false()
	assert_bool(r.chance_permille(1000)).is_true()
	assert_bool(r.chance_permille(5000)).is_true()
	var hits: int = 0
	for i: int in 100000:
		if r.chance_permille(250):
			hits += 1
	assert_int(hits).is_between(24400, 25600)


func test_weighted_index_respects_weights() -> void:
	var r := SeededRng.new(5)
	var weights := PackedInt32Array([1, 0, 3])
	var counts := PackedInt32Array([0, 0, 0])
	for i: int in 40000:
		counts[r.weighted_index(weights)] += 1
	assert_int(counts[1]).is_equal(0)
	assert_int(counts[0]).is_between(9500, 10500)
	assert_int(counts[2]).is_between(29500, 30500)
	assert_int(r.weighted_index(PackedInt32Array([0, 0]))).is_equal(-1)
	assert_int(r.weighted_index(PackedInt32Array())).is_equal(-1)


func test_shuffle_is_permutation_in_place() -> void:
	var r := SeededRng.new(77)
	var values := PackedInt32Array([0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
	r.shuffle_int32(values)
	assert_array(values).is_not_equal(PackedInt32Array([0, 1, 2, 3, 4, 5, 6, 7, 8, 9]))
	var sorted := values.duplicate()
	sorted.sort()
	assert_array(sorted).is_equal(PackedInt32Array([0, 1, 2, 3, 4, 5, 6, 7, 8, 9]))


func test_substream_does_not_depend_on_parent_consumption() -> void:
	var root := SeededRng.new(777)
	var expected: int = root.substream(2).next_u32()
	var other := root.substream(1)
	for i: int in 1000:
		other.next_u32()
	for i: int in 50:
		root.next_u32()
	assert_int(root.substream(2).next_u32()).is_equal(expected)


func test_substreams_are_distinct() -> void:
	var root := SeededRng.new(777)
	var seeds := {}
	for id: int in 256:
		var s: int = root.substream_seed(id)
		assert_bool(s >= 0).is_true()
		seeds[s] = true
	assert_int(seeds.size()).is_equal(256)
	assert_int(SeededRng.derive_seed(1, 2)).is_not_equal(SeededRng.derive_seed(2, 1))


func test_state_roundtrip_continues_sequence() -> void:
	var r := SeededRng.new(31337)
	for i: int in 10:
		r.next_u32()
	var state := r.get_state()
	var expected := PackedInt64Array()
	for i: int in 5:
		expected.append(r.next_u32())
	var restored := SeededRng.new(0)
	restored.set_state(state)
	assert_int(restored.get_seed()).is_equal(31337)
	for i: int in 5:
		assert_int(restored.next_u32()).is_equal(expected[i])


func test_reseed_resets_to_initial_sequence() -> void:
	var r := SeededRng.new(10)
	var first: int = r.next_u32()
	r.next_u32()
	r.reseed(10)
	assert_int(r.next_u32()).is_equal(first)


func test_hot_path_does_not_allocate() -> void:
	var r := SeededRng.new(5)
	var weights := PackedInt32Array([5, 10, 20, 65])
	var buf := PackedInt32Array([0, 1, 2, 3, 4, 5, 6, 7])
	for i: int in 1000:
		r.next_u32()
	var objects_before: int = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var memory_before: int = int(Performance.get_monitor(Performance.MEMORY_STATIC))
	var acc: int = 0
	for i: int in 20000:
		acc ^= r.next_u32()
		acc ^= r.range_int(0, 999)
		acc ^= int(r.chance_permille(300))
		acc ^= r.weighted_index(weights)
		if i % 20 == 0:
			r.shuffle_int32(buf)
	var objects_delta: int = int(Performance.get_monitor(Performance.OBJECT_COUNT)) - objects_before
	var memory_delta: int = int(Performance.get_monitor(Performance.MEMORY_STATIC)) - memory_before
	assert_int(objects_delta).is_equal(0)
	assert_int(memory_delta).is_equal(0)
	assert_int(acc).is_not_equal(-1)  # результат используется, цикл не выкидывается
