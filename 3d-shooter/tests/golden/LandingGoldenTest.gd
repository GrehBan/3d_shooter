extends GdUnitTestSuite
## Independent arbitrary-precision Python reference: tests/tools/landing_ref.py.


func test_fall_damage_shield_armor_integer_reference() -> void:
	var stats := StatBlock.new(1)
	var entity: int = stats.allocate()
	var h: int = 2166136261
	var armor_values: PackedInt32Array = [-1000, 0, 10000, 33333, 99999, 100000, 120000]
	var mm_values: PackedInt64Array = [7999, 8000, 8001, 12345, 100000, LandingEventQueue.MAX_HEIGHT_MM]
	for i: int in 1000:
		stats.set_stat(entity, StatBlock.Stat.HP, (i * 7919) % 200001)
		stats.set_stat(entity, StatBlock.Stat.SHIELD, (i * 197) % 30001)
		stats.set_stat(entity, StatBlock.Stat.ARMOR, armor_values[i % 7])
		var damage: int = MobilityRuntime.fall_damage(mm_values[i % 6])
		if i % 11 == 0:
			damage = 0x7FFFFFFFFFFFFFFF
		var actual: int = DamageApply.apply(stats, entity, damage)
		h = ((h ^ (actual & 0xFFFFFFFF)) * 16777619) & 0xFFFFFFFF
		for stat: StatBlock.Stat in [StatBlock.Stat.HP, StatBlock.Stat.SHIELD, StatBlock.Stat.ARMOR]:
			h = ((h ^ (stats.get_stat(entity, stat) & 0xFFFFFFFF)) * 16777619) & 0xFFFFFFFF
	assert_int(h).is_equal(2555885940)
