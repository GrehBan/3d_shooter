extends GdUnitTestSuite
## HitEventQueue: детерминированный порядок при любом порядке вставки,
## разрешение совпадающих префиксов, переполнение, отсутствие аллокаций.

const SPAN: int = StatBlock.HANDLE_INDEX_SPAN


static func _make_events(n: int) -> Array[PackedInt64Array]:
	# [target, source, kind, payload] — с повторами индексов при разных поколениях
	# и payload шире 17 бит, чтобы префиксы ключей совпадали.
	var events: Array[PackedInt64Array] = []
	for i: int in n:
		var target: int = (i * 37) % 23 + ((i * 7) % 3) * SPAN
		var source: int = Damageable.NO_HANDLE if i % 11 == 0 else (i * 13) % 17 + ((i * 5) % 2) * SPAN
		var kind: int = (i * 3) % 4
		var payload: int = (i * 104729) % (1 << 20) - (1 << 19)
		events.append(PackedInt64Array([target, source, kind, payload]))
	return events


static func _drain(queue: HitEventQueue) -> PackedInt64Array:
	var out := PackedInt64Array()
	for i: int in queue.prepare():
		out.append(queue.get_target(i))
		out.append(queue.get_source(i))
		out.append(queue.get_kind(i))
		out.append(queue.get_payload(i))
	queue.clear()
	return out


static func _fill(queue: HitEventQueue, events: Array[PackedInt64Array], order: PackedInt32Array) -> void:
	for index: int in order:
		var e: PackedInt64Array = events[index]
		queue.push(e[1], e[0], e[2] as HitEventQueue.HitKind, e[3])


func test_order_does_not_depend_on_insertion_order() -> void:
	var events := _make_events(120)
	var forward := PackedInt32Array()
	for i: int in events.size():
		forward.append(i)
	var backward := forward.duplicate()
	backward.reverse()
	var shuffled := forward.duplicate()
	SeededRng.new(99).shuffle_int32(shuffled)

	var queue := HitEventQueue.new(256)
	_fill(queue, events, forward)
	var a := _drain(queue)
	_fill(queue, events, backward)
	var b := _drain(queue)
	_fill(queue, events, shuffled)
	var c := _drain(queue)
	assert_int(a.size()).is_equal(120 * 4)
	assert_array(b).is_equal(a)
	assert_array(c).is_equal(a)


# Канонический ключ очереди: префикс (индексы слотов, вид, младшие биты payload),
# затем полные поля.
static func _canonical_key(target: int, source: int, kind: int, payload: int) -> PackedInt64Array:
	var prefix: int = target & 0xFFFF
	prefix = prefix << 16 | (source & 0xFFFF)
	prefix = prefix << 4 | (kind & 0xF)
	prefix = prefix << 17 | (payload & 0x1FFFF)
	return PackedInt64Array([prefix, target, source, kind, payload])


func test_result_is_in_canonical_order() -> void:
	var events := _make_events(200)
	var order := PackedInt32Array()
	for i: int in events.size():
		order.append(events.size() - 1 - i)
	var queue := HitEventQueue.new(256)
	_fill(queue, events, order)
	var out := _drain(queue)
	var violations: int = 0
	for i: int in range(1, out.size() / 4):
		var prev := _canonical_key(out[(i - 1) * 4], out[(i - 1) * 4 + 1], out[(i - 1) * 4 + 2], out[(i - 1) * 4 + 3])
		var cur := _canonical_key(out[i * 4], out[i * 4 + 1], out[i * 4 + 2], out[i * 4 + 3])
		for f: int in prev.size():
			if prev[f] != cur[f]:
				if prev[f] > cur[f]:
					violations += 1
				break
	assert_int(violations).is_equal(0)


func test_prefix_collisions_are_resolved_by_full_key() -> void:
	# Одинаковые индексы цели и источника, разные поколения; payload совпадает
	# в младших 17 битах. Префикс ключа у всех трёх одинаков.
	var queue := HitEventQueue.new(8)
	var low: int = 5
	queue.push(3, 2 * SPAN + 4, HitEventQueue.HitKind.HITSCAN, low + (2 << 17))
	queue.push(3, 1 * SPAN + 4, HitEventQueue.HitKind.HITSCAN, low + (1 << 17))
	queue.push(3, 1 * SPAN + 4, HitEventQueue.HitKind.HITSCAN, low)
	queue.prepare()
	assert_int(queue.get_target(0)).is_equal(1 * SPAN + 4)
	assert_int(queue.get_payload(0)).is_equal(low)
	assert_int(queue.get_payload(1)).is_equal(low + (1 << 17))
	assert_int(queue.get_target(2)).is_equal(2 * SPAN + 4)


func test_int64_handles_survive_queue() -> void:
	var queue := HitEventQueue.new(4)
	var big: int = 40_000 * SPAN + 7
	queue.push(big, big + 1, HitEventQueue.HitKind.PROJECTILE, big + 2)
	queue.prepare()
	assert_int(queue.get_source(0)).is_equal(big)
	assert_int(queue.get_target(0)).is_equal(big + 1)
	assert_int(queue.get_payload(0)).is_equal(big + 2)
	assert_int(queue.get_kind(0)).is_equal(HitEventQueue.HitKind.PROJECTILE)


func test_overflow_drops_and_counts() -> void:
	var queue := HitEventQueue.new(2)
	assert_bool(queue.push(1, 1, HitEventQueue.HitKind.MELEE, 0)).is_true()
	assert_bool(queue.push(1, 2, HitEventQueue.HitKind.MELEE, 0)).is_true()
	var results: Array[bool] = []
	await assert_error(func() -> void:
		results.append(queue.push(1, 3, HitEventQueue.HitKind.MELEE, 0))
		results.append(queue.push(1, 4, HitEventQueue.HitKind.MELEE, 0))) \
		.is_push_error("HitEventQueue: переполнение, события отбрасываются")
	assert_array(results).is_equal([false, false])
	assert_int(queue.dropped_count()).is_equal(2)
	assert_int(queue.prepare()).is_equal(2)
	# Сохраняются первые пришедшие события.
	assert_int(queue.get_target(0)).is_equal(1)
	assert_int(queue.get_target(1)).is_equal(2)
	queue.clear()
	assert_int(queue.count()).is_equal(0)
	assert_int(queue.prepare()).is_equal(0)


func test_physics_to_logic_flow_with_mock_colliders() -> void:
	# Mock физики: два физических тика кладут попадания по коллайдерам,
	# логический тик забирает их и применяет урон к StatBlock.
	var stats := StatBlock.new(8)
	var enemy_a: int = stats.allocate()
	var enemy_b: int = stats.allocate()
	stats.set_stat(enemy_a, StatBlock.Stat.HP, 10_000)
	stats.set_stat(enemy_b, StatBlock.Stat.HP, 10_000)
	var collider_a := StaticBody3D.new()
	var collider_b := StaticBody3D.new()
	var wall := StaticBody3D.new()
	Damageable.attach(collider_a, enemy_a)
	Damageable.attach(collider_b, enemy_b)

	var queue := HitEventQueue.new(16)
	for collider: Object in [collider_b, wall, collider_a]:  # физический тик 1
		var target: int = Damageable.handle_of(collider)
		if target != Damageable.NO_HANDLE:
			queue.push(Damageable.NO_HANDLE, target, HitEventQueue.HitKind.HITSCAN, 2_500)
	queue.push(Damageable.NO_HANDLE, Damageable.handle_of(collider_a), HitEventQueue.HitKind.HITSCAN, 2_500)  # тик 2

	for i: int in queue.prepare():  # логический тик
		stats.add_stat_clamped(queue.get_target(i), StatBlock.Stat.HP, -queue.get_payload(i), 0, 10_000)
	queue.clear()
	assert_int(stats.get_stat(enemy_a, StatBlock.Stat.HP)).is_equal(5_000)
	assert_int(stats.get_stat(enemy_b, StatBlock.Stat.HP)).is_equal(7_500)
	assert_int(Damageable.handle_of(wall)).is_equal(Damageable.NO_HANDLE)
	collider_a.free()
	collider_b.free()
	wall.free()


func test_damageable_pool_cycle_does_not_allocate() -> void:
	var collider := StaticBody3D.new()
	Damageable.attach(collider, 1)  # создание пула
	Damageable.detach(collider)
	assert_int(Damageable.handle_of(collider)).is_equal(Damageable.NO_HANDLE)
	var acc: int = 0
	for i: int in 100:
		Damageable.attach(collider, i)
		Damageable.detach(collider)
	var objects_before: int = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var memory_before: int = int(Performance.get_monitor(Performance.MEMORY_STATIC))
	for i: int in 20000:
		Damageable.attach(collider, i)  # спавн из пула
		acc += Damageable.handle_of(collider)
		Damageable.detach(collider)  # возврат в пул
		acc += Damageable.handle_of(collider)
	var objects_delta: int = int(Performance.get_monitor(Performance.OBJECT_COUNT)) - objects_before
	var memory_delta: int = int(Performance.get_monitor(Performance.MEMORY_STATIC)) - memory_before
	var after_detach: int = Damageable.handle_of(collider)
	collider.free()
	assert_int(objects_delta).is_equal(0)
	assert_int(memory_delta).is_equal(0)
	assert_int(after_detach).is_equal(Damageable.NO_HANDLE)
	# Каждый attach восстанавливает handle i, каждый detach даёт NO_HANDLE (-1):
	# сумма 0 + 1 + … + 19999 − 20000.
	assert_int(acc).is_equal(19999 * 20000 / 2 - 20000)


func test_hot_path_does_not_allocate() -> void:
	var queue := HitEventQueue.new(512)
	var events := _make_events(64)
	for pass_index: int in 3:
		for e: PackedInt64Array in events:
			queue.push(e[1], e[0], e[2] as HitEventQueue.HitKind, e[3])
		queue.prepare()
		queue.clear()
	var objects_before: int = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var memory_before: int = int(Performance.get_monitor(Performance.MEMORY_STATIC))
	var acc: int = 0
	for pass_index: int in 200:
		for i: int in 64:
			queue.push(i % 17, (i * 37) % 23 + pass_index, HitEventQueue.HitKind.AREA, i * pass_index)
		for i: int in queue.prepare():
			acc += queue.get_target(i) + queue.get_payload(i)
		queue.clear()
	var objects_delta: int = int(Performance.get_monitor(Performance.OBJECT_COUNT)) - objects_before
	var memory_delta: int = int(Performance.get_monitor(Performance.MEMORY_STATIC)) - memory_before
	assert_int(objects_delta).is_equal(0)
	assert_int(memory_delta).is_equal(0)
	assert_int(acc).is_not_equal(-1)
