extends GdUnitTestSuite
## Золотой тест EffectHost: 200 шагов добавления, снятия эффектов, clear_host и
## переиспользования слотов хостов новым поколением (в том числе без clear_host);
## итог — свёртка порядка резолва по всем спискам. Эталон посчитан независимой
## Python-моделью: tests/tools/effect_host_ref.py
## (запуск из корня репозитория: python 3d-shooter/tests/tools/effect_host_ref.py).

const FNV_OFFSET: int = 2166136261
const FNV_PRIME: int = 16777619
const MASK32: int = 0xFFFFFFFF
const SPAN: int = HandlePool.INDEX_SPAN


static func _fnv(h: int, v: int) -> int:
	return ((h ^ (v & MASK32)) * FNV_PRIME) & MASK32


func test_spawn_death_and_resolution_order_hash() -> void:
	var host := EffectHost.new(8, 256)
	var gens := PackedInt64Array([0, 0, 0, 0, 0])
	var hosts := PackedInt64Array([0, 1, 2, 3, 4])
	var stale := PackedInt64Array()
	var live: Array[int] = []
	var h: int = FNV_OFFSET
	for step: int in 200:
		var k: int = (step * 37) % 101
		var op: int = k % 10
		if op <= 5:
			var entry: int = host.add_effect(hosts[k % 5], (k % 6) as EffectTrigger.Trigger,
					(k % 3) as EffectTrigger.Phase, (k * 7) % 5 - 2, (k * 3) % 4, k % 9, step)
			live.append(entry)
			h = _fnv(h, entry)
		elif op == 6:
			if not live.is_empty():
				var entry: int = live.pop_at(k % live.size())
				h = _fnv(h, 1 if host.remove_effect(entry) else 0)
		elif op == 7:
			h = _fnv(h, host.clear_host(hosts[k % 5]))
		elif op == 8:
			var i: int = k % 5
			stale.append(hosts[i])
			gens[i] += 1
			hosts[i] = gens[i] * SPAN + i
	var probe := hosts.duplicate()
	probe.append_array(stale.slice(maxi(0, stale.size() - 3)))
	for owner: int in probe:
		for trigger: int in 6:
			var index: int = host.first(owner, trigger as EffectTrigger.Trigger)
			while index != EffectHost.NO_ENTRY:
				h = _fnv(h, host.entry_at(index))
				h = _fnv(h, host.effect_id_at(index))
				h = _fnv(h, host.phase_at(index))
				h = _fnv(h, host.priority_at(index))
				h = _fnv(h, host.slot_index_at(index))
				h = _fnv(h, host.state_slot_at(index))
				index = host.next(index)
			h = _fnv(h, 0xABCD)
	h = _fnv(h, host.entry_count())
	assert_int(host.entry_count()).is_equal(75)
	assert_int(host.capacity_refusals).is_equal(0)
	assert_int(h).is_equal(3280552288)
