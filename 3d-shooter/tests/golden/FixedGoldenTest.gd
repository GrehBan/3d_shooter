extends GdUnitTestSuite
## Золотой тест Fixed: эталонный хеш посчитан независимой реализацией на Python
## (целые произвольной точности, деление с округлением к нулю).

const FNV_OFFSET: int = 2166136261
const FNV_PRIME: int = 16777619
const MASK32: int = 0xFFFFFFFF


static func _fnv(h: int, v: int) -> int:
	return ((h ^ (v & MASK32)) * FNV_PRIME) & MASK32


func test_hash_of_mul_div_sweep() -> void:
	var h: int = FNV_OFFSET
	var count: int = 0
	for i: int in range(-500, 500):
		var a: int = i * 7919 - 13
		var b: int = ((i + 500) * 104729) % 50000 - 25000
		h = _fnv(h, Fixed.mul(a, b))
		count += 1
		if b != 0:
			h = _fnv(h, Fixed.div(a, b))
			count += 1
	assert_int(count).is_equal(2000)
	assert_int(h).is_equal(1272520513)
