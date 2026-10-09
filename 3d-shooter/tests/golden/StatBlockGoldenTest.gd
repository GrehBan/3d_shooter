extends GdUnitTestSuite
## Золотой тест StatBlock: сценарий выдачи, освобождения и записи статов,
## эталон посчитан независимой моделью на Python. Фиксирует порядок выдачи
## индексов, рост поколений и отказ для устаревших handle.

const FNV_OFFSET: int = 2166136261
const FNV_PRIME: int = 16777619
const MASK32: int = 0xFFFFFFFF


static func _fnv(h: int, v: int) -> int:
	return ((h ^ (v & MASK32)) * FNV_PRIME) & MASK32


func test_allocation_scenario_hash() -> void:
	var sb := StatBlock.new(8)
	var handles: Array[int] = []
	var dead: Array[int] = []
	var h: int = FNV_OFFSET
	for step: int in 200:
		if (step % 5 == 4 or sb.alive_count() == sb.capacity()) and not handles.is_empty():
			var victim: int = handles.pop_at((step * 7) % handles.size())
			h = _fnv(h, 1 if sb.release(victim) else 0)
			dead.append(victim)
		else:
			var handle: int = sb.allocate()
			handles.append(handle)
			h = _fnv(h, handle)
			sb.set_stat(handle, StatBlock.Stat.MAX_HP, 100_000)
			sb.set_stat(handle, StatBlock.Stat.HP, step * 1000)
			h = _fnv(h, sb.add_stat_clamped(handle, StatBlock.Stat.HP, -step * 37, 0, 100_000))
			sb.set_status(handle, (1 << 40) | step)
		# Устаревшие handle обязаны отвергаться.
		for d: int in dead.slice(maxi(0, dead.size() - 3)):
			h = _fnv(h, 1 if sb.set_stat(d, StatBlock.Stat.ARMOR, 999) else 0)
			h = _fnv(h, sb.get_stat(d, StatBlock.Stat.HP))
	for handle: int in handles:
		for stat: int in StatBlock.STAT_COUNT:
			h = _fnv(h, sb.get_stat(handle, stat))
		h = _fnv(h, sb.get_status(handle))
		h = _fnv(h, sb.get_status(handle) >> 32)
	assert_int(handles.size()).is_equal(6)
	assert_array(handles.slice(0, 4)).is_equal([458754, 851972, 589830, 458759])
	assert_int(h).is_equal(1088715370)
