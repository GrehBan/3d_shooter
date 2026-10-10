extends GdUnitTestSuite
## Золотой тест MovementAbilities: 300 логических тиков ввода по таблице для трёх
## сущностей, смерть и спавн в том же слоте, повторный grant с новыми параметрами,
## revoke; свёртка решений, энергии и кулдаунов. Эталон посчитан независимой
## Python-моделью: tests/tools/movement_ref.py
## (запуск из корня репозитория: python 3d-shooter/tests/tools/movement_ref.py).

const FNV_OFFSET: int = 2166136261
const FNV_PRIME: int = 16777619
const MASK32: int = 0xFFFFFFFF
const K := MovementAbilityData.Kind
const ENERGY := StatBlock.Stat.ENERGY
const MAX_ENERGY := StatBlock.Stat.MAX_ENERGY


static func _fnv(h: int, v: int) -> int:
	return ((h ^ (v & MASK32)) * FNV_PRIME) & MASK32


static func _spawn(stats: StatBlock, max_energy: int, energy: int) -> int:
	var e: int = stats.allocate()
	stats.set_stat(e, MAX_ENERGY, max_energy)
	stats.set_stat(e, ENERGY, energy)
	return e


func test_input_table_scenario_hash() -> void:
	var stats := StatBlock.new(8)
	var abilities := MovementAbilities.new(8, 50)
	var ents := PackedInt64Array()
	for i: int in 3:
		ents.append(_spawn(stats, 3000, 3000))
	abilities.grant(ents[0], K.DASH, 1000, 6, true, true)
	abilities.grant(ents[0], K.DOUBLE_JUMP, 0, 10, false, true)
	abilities.grant(ents[1], K.DASH, 1000, 3, true, true)
	abilities.grant(ents[1], K.SLIDE, 500, 0, true, false)
	abilities.grant(ents[2], K.GRAPPLE, 1500, 20, true, true)
	var h: int = FNV_OFFSET
	var activations: int = 0
	for t: int in 300:
		if t == 100:
			h = _fnv(h, abilities.clear_entity(ents[1]))
			stats.release(ents[1])
			ents[1] = _spawn(stats, 2000, 500)
			abilities.grant(ents[1], K.DASH, 700, 4, true, true)
		if t == 150:
			abilities.grant(ents[0], K.DASH, 800, 6, true, true)
		if t == 200:
			h = _fnv(h, 1 if abilities.revoke(ents[0], K.DOUBLE_JUMP) else 0)
		for n: int in ents.size():
			var k: int = (t * 7 + n * 3) % 11
			if k < MovementAbilityData.KIND_COUNT:
				var in_air: bool = (t / 5 + n) % 2 == 1
				var ok: bool = abilities.try_activate(ents[n], k as MovementAbilityData.Kind, t, in_air, stats)
				if ok:
					activations += 1
				h = _fnv(h, 1 if ok else 0)
		abilities.regen_energy(stats)
		for e: int in ents:
			h = _fnv(h, stats.get_stat(e, ENERGY))
	for e: int in ents:
		for k: int in MovementAbilityData.KIND_COUNT:
			h = _fnv(h, abilities.ready_tick(e, k as MovementAbilityData.Kind))
	h = _fnv(h, abilities.active_count())
	assert_int(activations).is_equal(61)
	assert_int(h).is_equal(2744406475)
