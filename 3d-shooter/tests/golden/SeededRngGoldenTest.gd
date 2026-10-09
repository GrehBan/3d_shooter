extends GdUnitTestSuite
## Золотые тесты SeededRng. Эталонные значения посчитаны независимой реализацией
## того же алгоритма на Python (целые произвольной точности). Любое изменение
## алгоритма, сидинга или вывода подпотоков ломает эти тесты и сохранённые забеги.

const FNV_OFFSET: int = 2166136261
const FNV_PRIME: int = 16777619


static func _fnv(h: int, v: int) -> int:
	return ((h ^ (v & SeededRng.MASK32)) * FNV_PRIME) & SeededRng.MASK32


func test_xoshiro128ss_reference_vector() -> void:
	# Опорный вектор xoshiro128** для состояния {1, 2, 3, 4}.
	var r := SeededRng.new(0)
	r.set_state(PackedInt64Array([0, 1, 2, 3, 4]))
	var got := PackedInt64Array()
	for i: int in 6:
		got.append(r.next_u32())
	assert_array(got).is_equal(PackedInt64Array([11520, 0, 5927040, 70819200, 2031721883, 1637235492]))


func test_first_values_for_fixed_seed() -> void:
	var r := SeededRng.new(0x5EED)
	var got := PackedInt64Array()
	for i: int in 8:
		got.append(r.next_u32())
	assert_array(got).is_equal(PackedInt64Array([
		355486304, 4065437606, 3710674182, 442870578,
		2759093909, 403268678, 3185430419, 204211739]))


func test_first_values_for_edge_seeds() -> void:
	var cases := {
		0: [2912319371, 472665592, 2301050904, 272118488, 1386037721],
		-1: [3628566168, 4238238907, 319704874, 3818781754, 2979500754],
		-987654321012345: [2480284848, 4233395335, 1698833464, 4252504341, 3152081089],
		9223372036854775807: [3266939116, 1525056987, 3904885013, 3922359193, 2540144594],
	}
	for s: int in cases:
		var r := SeededRng.new(s)
		var expected: Array = cases[s]
		for v: int in expected:
			assert_int(r.next_u32()).is_equal(v)


func test_hash_of_10000_values() -> void:
	var r := SeededRng.new(20261009)
	var h: int = FNV_OFFSET
	for i: int in 10000:
		h = _fnv(h, r.next_u32())
	assert_int(h).is_equal(968629223)


func test_hash_of_range_int() -> void:
	var r := SeededRng.new(7)
	var h: int = FNV_OFFSET
	for i: int in 10000:
		h = _fnv(h, r.range_int(0, 99))
	assert_int(h).is_equal(1378026941)


func test_hash_of_mixed_api_sequence() -> void:
	var r := SeededRng.new(-123)
	var h: int = FNV_OFFSET
	var weights := PackedInt32Array([5, 10, 20, 65])
	var arr := PackedInt32Array()
	for i: int in 16:
		arr.append(i)
	for i: int in 2000:
		h = _fnv(h, 1 if r.chance_permille(333) else 0)
		h = _fnv(h, r.weighted_index(weights))
		h = _fnv(h, r.range_int(-50, 50))
		if i % 100 == 0:
			r.shuffle_int32(arr)
			for x: int in arr:
				h = _fnv(h, x)
	assert_int(h).is_equal(3105920842)
	assert_array(arr).is_equal(PackedInt32Array([1, 7, 11, 9, 14, 15, 2, 10, 13, 0, 6, 12, 3, 8, 5, 4]))


func test_derived_seeds() -> void:
	assert_int(SeededRng.derive_seed(0x5EED, 0)).is_equal(8109932521780162825)
	assert_int(SeededRng.derive_seed(0x5EED, 1)).is_equal(1574427992550687910)
	assert_int(SeededRng.derive_seed(0x5EED, 2)).is_equal(748611381726930133)
	assert_int(SeededRng.derive_seed(-1, -1)).is_equal(8547408552214738999)


func test_substream_first_values() -> void:
	var sub := SeededRng.new(42).substream(3)
	var got := PackedInt64Array()
	for i: int in 4:
		got.append(sub.next_u32())
	assert_array(got).is_equal(PackedInt64Array([1068246899, 3471446107, 174591386, 731130490]))
