extends GdUnitTestSuite
## Золотой тест HitEventQueue: 300 событий с совпадающими индексами разных
## поколений, NO_HANDLE и отрицательными payload вставляются в обратном порядке;
## эталонный хеш упорядоченной последовательности посчитан на Python
## сортировкой по каноническому ключу очереди (префикс, затем полные поля).

const FNV_OFFSET: int = 2166136261
const FNV_PRIME: int = 16777619
const MASK32: int = 0xFFFFFFFF
const SPAN: int = StatBlock.HANDLE_INDEX_SPAN


static func _fnv(h: int, v: int) -> int:
	return ((h ^ (v & MASK32)) * FNV_PRIME) & MASK32


func test_sorted_sequence_hash() -> void:
	var queue := HitEventQueue.new(512)
	var i: int = 299
	while i >= 0:
		var target: int = (i * 37) % 23 + ((i * 7) % 3) * SPAN
		var source: int = Damageable.NO_HANDLE if i % 11 == 0 else (i * 13) % 17 + ((i * 5) % 2) * SPAN
		var kind: int = (i * 3) % 4
		var payload: int = (i * 104729) % (1 << 20) - (1 << 19)
		queue.push(source, target, kind as HitEventQueue.HitKind, payload)
		i -= 1
	var h: int = FNV_OFFSET
	for k: int in queue.prepare():
		h = _fnv(h, queue.get_target(k))
		h = _fnv(h, queue.get_source(k))
		h = _fnv(h, queue.get_kind(k))
		h = _fnv(h, queue.get_payload(k))
	assert_int(queue.count()).is_equal(300)
	assert_int(queue.get_target(0)).is_equal(0)
	assert_int(queue.get_source(0)).is_equal(1)
	assert_int(queue.get_payload(0)).is_equal(69364)
	assert_int(h).is_equal(4173027423)
