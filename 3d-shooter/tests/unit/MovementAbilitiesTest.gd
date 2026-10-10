extends GdUnitTestSuite
## MovementAbilities: кулдауны в логических тиках, плата энергией, земля и воздух,
## повторный grant, revoke, спавн и смерть в бою, устаревшие handle, аллокации.

const SPAN: int = HandlePool.INDEX_SPAN
const K := MovementAbilityData.Kind
const ENERGY := StatBlock.Stat.ENERGY
const MAX_ENERGY := StatBlock.Stat.MAX_ENERGY


static func _spawn(stats: StatBlock, energy: int) -> int:
	var e: int = stats.allocate()
	stats.set_stat(e, MAX_ENERGY, 3000)
	stats.set_stat(e, ENERGY, energy)
	return e


func test_kind_count_matches_enum() -> void:
	assert_int(MovementAbilityData.KIND_COUNT).is_equal(MovementAbilityData.Kind.size())
	assert_int(MovementAbilities.KIND_COUNT).is_equal(MovementAbilityData.Kind.size())


func test_cooldown_counts_logic_ticks() -> void:
	var stats := StatBlock.new(4)
	var abilities := MovementAbilities.new(4)
	var e: int = _spawn(stats, 3000)
	abilities.grant(e, K.DOUBLE_JUMP, 0, 10, true, true)
	assert_bool(abilities.try_activate(e, K.DOUBLE_JUMP, 5, true, stats)).is_true()
	assert_int(abilities.ready_tick(e, K.DOUBLE_JUMP)).is_equal(15)
	assert_bool(abilities.try_activate(e, K.DOUBLE_JUMP, 14, true, stats)).is_false()
	assert_bool(abilities.try_activate(e, K.DOUBLE_JUMP, 15, true, stats)).is_true()  # граница now == ready


func test_three_dashes_then_refusal_then_regen() -> void:
	var stats := StatBlock.new(4)
	var abilities := MovementAbilities.new(4, 250)
	var e: int = _spawn(stats, 3000)
	abilities.grant(e, K.DASH, 1000, 0, true, true)
	for i: int in 3:
		assert_bool(abilities.try_activate(e, K.DASH, 1, false, stats)).is_true()
	assert_int(stats.get_stat(e, ENERGY)).is_equal(0)
	assert_bool(abilities.try_activate(e, K.DASH, 1, false, stats)).is_false()
	for tick: int in 3:
		abilities.regen_energy(stats)
	assert_bool(abilities.try_activate(e, K.DASH, 2, false, stats)).is_false()  # 750 < 1000
	abilities.regen_energy(stats)
	assert_bool(abilities.try_activate(e, K.DASH, 2, false, stats)).is_true()


func test_regen_is_clamped_to_max_energy() -> void:
	var stats := StatBlock.new(4)
	var abilities := MovementAbilities.new(4, 400)
	var e: int = _spawn(stats, 2900)
	abilities.grant(e, K.DASH, 1000, 0, true, true)
	abilities.regen_energy(stats)
	assert_int(stats.get_stat(e, ENERGY)).is_equal(3000)


func test_ground_and_air_restrictions() -> void:
	var stats := StatBlock.new(4)
	var abilities := MovementAbilities.new(4)
	var e: int = _spawn(stats, 3000)
	abilities.grant(e, K.SLIDE, 0, 0, true, false)
	abilities.grant(e, K.DOUBLE_JUMP, 0, 0, false, true)
	assert_bool(abilities.try_activate(e, K.SLIDE, 1, true, stats)).is_false()
	assert_bool(abilities.try_activate(e, K.SLIDE, 1, false, stats)).is_true()
	assert_bool(abilities.try_activate(e, K.DOUBLE_JUMP, 1, false, stats)).is_false()
	assert_bool(abilities.try_activate(e, K.DOUBLE_JUMP, 1, true, stats)).is_true()


func test_regrant_updates_params_but_keeps_cooldown() -> void:
	var stats := StatBlock.new(4)
	var abilities := MovementAbilities.new(4)
	var e: int = _spawn(stats, 3000)
	abilities.grant(e, K.DASH, 1000, 30, true, true)
	assert_bool(abilities.try_activate(e, K.DASH, 10, false, stats)).is_true()
	abilities.grant(e, K.DASH, 500, 5, true, true)  # смена карточки
	assert_int(abilities.ready_tick(e, K.DASH)).is_equal(40)
	assert_bool(abilities.try_activate(e, K.DASH, 20, false, stats)).is_false()
	assert_bool(abilities.try_activate(e, K.DASH, 40, false, stats)).is_true()
	assert_int(stats.get_stat(e, ENERGY)).is_equal(3000 - 1000 - 500)  # новая цена
	assert_int(abilities.ready_tick(e, K.DASH)).is_equal(45)  # новый кулдаун


func test_revoke_and_ungranted_kinds() -> void:
	var stats := StatBlock.new(4)
	var abilities := MovementAbilities.new(4)
	var e: int = _spawn(stats, 3000)
	assert_bool(abilities.try_activate(e, K.GRAPPLE, 1, false, stats)).is_false()
	abilities.grant(e, K.GRAPPLE, 0, 0, true, true)
	assert_int(abilities.active_count()).is_equal(1)
	assert_bool(abilities.revoke(e, K.GRAPPLE)).is_true()
	assert_bool(abilities.revoke(e, K.GRAPPLE)).is_false()
	assert_bool(abilities.try_activate(e, K.GRAPPLE, 1, false, stats)).is_false()
	assert_int(abilities.active_count()).is_equal(0)


func test_spawn_and_death_mid_combat() -> void:
	var stats := StatBlock.new(4)
	var abilities := MovementAbilities.new(4, 100)
	var old_enemy: int = _spawn(stats, 3000)
	abilities.grant(old_enemy, K.DASH, 1000, 0, true, true)
	abilities.grant(old_enemy, K.WALL_RUN, 0, 0, true, true)
	assert_int(abilities.clear_entity(old_enemy)).is_equal(2)
	stats.release(old_enemy)
	var new_enemy: int = _spawn(stats, 1000)  # тот же слот, новое поколение
	assert_int(new_enemy).is_equal(1 * SPAN + (old_enemy % SPAN))
	abilities.grant(new_enemy, K.DASH, 1000, 0, true, true)
	assert_bool(abilities.try_activate(old_enemy, K.DASH, 1, false, stats)).is_false()
	assert_bool(abilities.revoke(old_enemy, K.DASH)).is_false()
	assert_int(abilities.clear_entity(old_enemy)).is_equal(0)
	assert_bool(abilities.try_activate(new_enemy, K.DASH, 1, false, stats)).is_true()


func test_stale_entity_abilities_dropped_on_slot_reuse_without_clear() -> void:
	var stats := StatBlock.new(4)
	var abilities := MovementAbilities.new(4, 100)
	var old_enemy: int = _spawn(stats, 3000)
	abilities.grant(old_enemy, K.DASH, 0, 0, true, true)
	abilities.grant(old_enemy, K.GRAPPLE, 0, 0, true, true)
	stats.release(old_enemy)  # смерть без clear_entity
	var new_enemy: int = _spawn(stats, 3000)
	abilities.grant(new_enemy, K.SLIDE, 0, 0, true, true)
	assert_bool(abilities.is_granted(new_enemy, K.DASH)).is_false()
	assert_bool(abilities.is_granted(new_enemy, K.SLIDE)).is_true()
	assert_int(abilities.active_count()).is_equal(1)


func test_grant_with_older_generation_does_not_touch_live_entity() -> void:
	var stats := StatBlock.new(4)
	var abilities := MovementAbilities.new(4)
	var dead: int = _spawn(stats, 3000)
	stats.release(dead)
	var live: int = _spawn(stats, 3000)  # тот же слот, поколение 1
	abilities.grant(live, K.DASH, 1000, 0, true, true)
	# Отложенный эффект убитой сущности (поколение 0) выдаёт ей способность.
	assert_bool(abilities.grant(dead, K.GRAPPLE, 0, 0, true, true)).is_false()
	assert_bool(abilities.is_granted(live, K.DASH)).is_true()
	assert_bool(abilities.is_granted(live, K.GRAPPLE)).is_false()
	assert_int(abilities.active_count()).is_equal(1)
	assert_bool(abilities.try_activate(live, K.DASH, 1, false, stats)).is_true()


func test_active_list_swap_remove_keeps_other_entities() -> void:
	var stats := StatBlock.new(8)
	var abilities := MovementAbilities.new(8, 100)
	var a: int = _spawn(stats, 0)
	var b: int = _spawn(stats, 0)
	var c: int = _spawn(stats, 0)
	for e: int in [a, b, c]:
		abilities.grant(e, K.DASH, 0, 0, true, true)
	abilities.clear_entity(a)  # c переезжает на место a
	abilities.regen_energy(stats)
	assert_int(abilities.active_count()).is_equal(2)
	assert_int(stats.get_stat(a, ENERGY)).is_equal(0)
	assert_int(stats.get_stat(b, ENERGY)).is_equal(100)
	assert_int(stats.get_stat(c, ENERGY)).is_equal(100)


func test_invalid_inputs_are_refused() -> void:
	var stats := StatBlock.new(4)
	var abilities := MovementAbilities.new(4)
	assert_bool(abilities.grant(-1, K.DASH, 0, 0, true, true)).is_false()
	assert_bool(abilities.grant(9, K.DASH, 0, 0, true, true)).is_false()
	assert_bool(abilities.grant(0, 99 as MovementAbilityData.Kind, 0, 0, true, true)).is_false()
	assert_bool(abilities.try_activate(-1, K.DASH, 0, false, stats)).is_false()
	assert_int(abilities.active_count()).is_equal(0)


func test_combat_cycle_does_not_allocate() -> void:
	var stats := StatBlock.new(64)
	var abilities := MovementAbilities.new(64, 100)
	var ents := PackedInt64Array()
	for i: int in 40:
		var e: int = _spawn(stats, 3000)
		abilities.grant(e, K.DASH, 1000, 3, true, true)
		ents.append(e)
	var objects_before: int = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var memory_before: int = int(Performance.get_monitor(Performance.MEMORY_STATIC))
	var acc: int = 0
	for tick: int in 2000:
		var slot: int = tick % 40
		acc += int(abilities.try_activate(ents[slot], K.DASH, tick, false, stats))
		abilities.regen_energy(stats)
		if tick % 50 == 0:  # смерть и спавн элиты
			abilities.clear_entity(ents[slot])
			stats.release(ents[slot])
			ents[slot] = _spawn(stats, 3000)
			abilities.grant(ents[slot], K.DASH, 1000, 3, true, true)
	var objects_delta: int = int(Performance.get_monitor(Performance.OBJECT_COUNT)) - objects_before
	var memory_delta: int = int(Performance.get_monitor(Performance.MEMORY_STATIC)) - memory_before
	assert_int(objects_delta).is_equal(0)
	assert_int(memory_delta).is_equal(0)
	assert_int(abilities.active_count()).is_equal(40)
	assert_int(acc).is_equal(2000)  # каждую сущность зовут раз в 40 тиков: энергии и кулдауна хватает
