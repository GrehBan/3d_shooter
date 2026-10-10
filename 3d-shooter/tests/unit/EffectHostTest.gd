extends GdUnitTestSuite
## EffectHost: порядок резолва, независимость от порядка регистрации, снятие
## эффектов, спавн и смерть хостов в бою, устаревшие handle, отсутствие аллокаций.

const SPAN: int = HandlePool.INDEX_SPAN
const T := EffectTrigger.Trigger
const P := EffectTrigger.Phase


static func _effect_ids(host: EffectHost, owner: int, trigger: EffectTrigger.Trigger) -> PackedInt32Array:
	var ids := PackedInt32Array()
	var index: int = host.first(owner, trigger)
	while index != EffectHost.NO_ENTRY:
		ids.append(host.effect_id_at(index))
		index = host.next(index)
	return ids


func test_resolution_order_is_phase_priority_slot() -> void:
	var host := EffectHost.new(4, 16)
	var owner: int = 1
	host.add_effect(owner, T.ON_HIT, P.POST, 0, 0, 50, 0)
	host.add_effect(owner, T.ON_HIT, P.MAIN, 5, 0, 40, 0)
	host.add_effect(owner, T.ON_HIT, P.MAIN, -1, 3, 30, 0)
	host.add_effect(owner, T.ON_HIT, P.MAIN, -1, 1, 20, 0)
	host.add_effect(owner, T.ON_HIT, P.PRE, 9, 9, 10, 0)
	assert_array(_effect_ids(host, owner, T.ON_HIT)).is_equal(PackedInt32Array([10, 20, 30, 40, 50]))


func test_registration_order_does_not_change_resolution() -> void:
	var specs: Array[PackedInt32Array] = [
		PackedInt32Array([P.MAIN, 2, 1, 7]), PackedInt32Array([P.PRE, 0, 0, 3]),
		PackedInt32Array([P.MAIN, 2, 0, 9]), PackedInt32Array([P.POST, -3, 2, 1]),
		PackedInt32Array([P.MAIN, 1, 5, 4]), PackedInt32Array([P.MAIN, 2, 1, 2]),
	]
	var results: Array[PackedInt32Array] = []
	for reverse: bool in [false, true]:
		var host := EffectHost.new(4, 16)
		var order: Array[int] = [0, 1, 2, 3, 4, 5]
		if reverse:
			order.reverse()
		for i: int in order:
			var s: PackedInt32Array = specs[i]
			host.add_effect(2, T.ON_KILL, s[0] as EffectTrigger.Phase, s[1], s[2], s[3], i)
		results.append(_effect_ids(host, 2, T.ON_KILL))
	assert_array(results[0]).is_equal(PackedInt32Array([3, 4, 9, 2, 7, 1]))
	assert_array(results[1]).is_equal(results[0])


func test_triggers_and_hosts_are_isolated() -> void:
	var host := EffectHost.new(4, 16)
	host.add_effect(0, T.ON_FIRE, P.MAIN, 0, 0, 1, 0)
	host.add_effect(1, T.ON_FIRE, P.MAIN, 0, 0, 2, 0)
	host.add_effect(0, T.ON_DASH, P.MAIN, 0, 0, 3, 0)
	assert_array(_effect_ids(host, 0, T.ON_FIRE)).is_equal(PackedInt32Array([1]))
	assert_array(_effect_ids(host, 1, T.ON_FIRE)).is_equal(PackedInt32Array([2]))
	assert_array(_effect_ids(host, 0, T.ON_DASH)).is_equal(PackedInt32Array([3]))
	assert_int(host.first(1, T.ON_DASH)).is_equal(EffectHost.NO_ENTRY)


func test_remove_effect_relinks_list() -> void:
	var host := EffectHost.new(4, 16)
	var a: int = host.add_effect(0, T.ON_HIT, P.MAIN, 0, 0, 1, 0)
	var b: int = host.add_effect(0, T.ON_HIT, P.MAIN, 0, 1, 2, 0)
	var c: int = host.add_effect(0, T.ON_HIT, P.MAIN, 0, 2, 3, 0)
	assert_bool(host.remove_effect(b)).is_true()
	assert_array(_effect_ids(host, 0, T.ON_HIT)).is_equal(PackedInt32Array([1, 3]))
	assert_bool(host.remove_effect(b)).is_false()  # устаревший handle записи
	assert_bool(host.remove_effect(a)).is_true()
	assert_bool(host.remove_effect(c)).is_true()
	assert_int(host.first(0, T.ON_HIT)).is_equal(EffectHost.NO_ENTRY)
	assert_int(host.entry_count()).is_equal(0)


func test_host_spawn_and_death_mid_combat() -> void:
	var host := EffectHost.new(4, 16)
	var old_elite: int = 0 * SPAN + 2
	host.add_effect(old_elite, T.ON_DAMAGED, P.MAIN, 0, 0, 11, 0)
	host.add_effect(old_elite, T.ON_KILL, P.POST, 0, 0, 12, 0)
	assert_int(host.clear_host(old_elite)).is_equal(2)  # смерть элиты
	var new_elite: int = 1 * SPAN + 2  # тот же слот, новое поколение
	host.add_effect(new_elite, T.ON_DAMAGED, P.MAIN, 0, 0, 21, 0)
	assert_array(_effect_ids(host, new_elite, T.ON_DAMAGED)).is_equal(PackedInt32Array([21]))
	assert_int(host.first(old_elite, T.ON_DAMAGED)).is_equal(EffectHost.NO_ENTRY)
	assert_int(host.clear_host(old_elite)).is_equal(0)
	assert_int(host.entry_count()).is_equal(1)


func test_stale_host_entries_freed_on_slot_reuse_without_clear() -> void:
	var host := EffectHost.new(4, 16)
	var old_elite: int = 0 * SPAN + 3
	host.add_effect(old_elite, T.ON_HIT, P.MAIN, 0, 0, 1, 0)
	host.add_effect(old_elite, T.ON_FIRE, P.MAIN, 0, 0, 2, 0)
	var new_elite: int = 1 * SPAN + 3  # смерть без clear_host, слот переиспользован
	host.add_effect(new_elite, T.ON_HIT, P.MAIN, 0, 0, 3, 0)
	assert_int(host.entry_count()).is_equal(1)
	assert_int(host.first(old_elite, T.ON_FIRE)).is_equal(EffectHost.NO_ENTRY)
	assert_array(_effect_ids(host, new_elite, T.ON_HIT)).is_equal(PackedInt32Array([3]))


func test_invalid_host_or_trigger_is_refused() -> void:
	var host := EffectHost.new(4, 16)
	assert_int(host.add_effect(-1, T.ON_HIT, P.MAIN, 0, 0, 1, 0)).is_equal(EffectHost.INVALID_HANDLE)
	assert_int(host.add_effect(7, T.ON_HIT, P.MAIN, 0, 0, 1, 0)).is_equal(EffectHost.INVALID_HANDLE)
	assert_int(host.first(-1, T.ON_HIT)).is_equal(EffectHost.NO_ENTRY)
	assert_int(host.entry_count()).is_equal(0)


func test_entry_capacity_exhaustion_is_reported_once() -> void:
	var host := EffectHost.new(4, 2)
	host.add_effect(0, T.ON_HIT, P.MAIN, 0, 0, 1, 0)
	host.add_effect(0, T.ON_HIT, P.MAIN, 0, 0, 2, 0)
	var results: Array[int] = []
	await assert_error(func() -> void:
		results.append(host.add_effect(1, T.ON_HIT, P.MAIN, 0, 0, 3, 0))
		results.append(host.add_effect(1, T.ON_HIT, P.MAIN, 0, 0, 4, 0))) \
		.is_push_error("EffectHost: ёмкость записей исчерпана")
	assert_array(results).is_equal([EffectHost.INVALID_HANDLE, EffectHost.INVALID_HANDLE])
	assert_int(host.capacity_refusals).is_equal(2)
	assert_int(host.first(1, T.ON_HIT)).is_equal(EffectHost.NO_ENTRY)


func test_combat_cycle_does_not_allocate() -> void:
	var host := EffectHost.new(64, 512)
	var gens := PackedInt64Array()
	gens.resize(40)
	for warm: int in 40:
		host.add_effect(warm, T.ON_HIT, P.MAIN, 0, 0, warm, 0)
		host.clear_host(warm)
	var objects_before: int = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var memory_before: int = int(Performance.get_monitor(Performance.MEMORY_STATIC))
	var acc: int = 0
	for tick: int in 2000:
		var slot: int = tick % 40
		var elite: int = gens[slot] * SPAN + slot
		host.add_effect(elite, T.ON_HIT, P.MAIN, tick % 3, 0, 1, tick)  # спавн элиты
		host.add_effect(elite, T.ON_KILL, P.POST, 0, 1, 2, tick)
		host.add_effect(elite, T.ON_HIT, P.PRE, 0, 2, 3, tick)
		var index: int = host.first(elite, T.ON_HIT)
		while index != EffectHost.NO_ENTRY:
			acc += host.effect_id_at(index)
			index = host.next(index)
		acc += host.clear_host(elite)  # смерть
		gens[slot] += 1
	var objects_delta: int = int(Performance.get_monitor(Performance.OBJECT_COUNT)) - objects_before
	var memory_delta: int = int(Performance.get_monitor(Performance.MEMORY_STATIC)) - memory_before
	assert_int(objects_delta).is_equal(0)
	assert_int(memory_delta).is_equal(0)
	assert_int(host.entry_count()).is_equal(0)
	assert_int(acc).is_equal(2000 * (1 + 3 + 3))  # эффекты ON_HIT 1 и 3 + 3 снятых записи
