extends GdUnitTestSuite
## AttackContextPool: глубина, бюджет на дерево, двойное поражение в ветке,
## разрешение графа, освобождение, краевые случаи, отсутствие аллокаций.

const SPAN: int = HandlePool.INDEX_SPAN
const INVALID: int = AttackContextPool.INVALID_HANDLE


func test_root_and_children_track_depth_parent_and_source() -> void:
	var pool := AttackContextPool.new(8)
	var root: int = pool.open_root(42, 10)
	var child: int = pool.open_child(root)
	var grandchild: int = pool.open_child(child)
	assert_int(pool.depth_of(root)).is_equal(0)
	assert_int(pool.depth_of(grandchild)).is_equal(2)
	assert_int(pool.parent_of(grandchild)).is_equal(child)
	assert_int(pool.root_of(grandchild)).is_equal(root)
	assert_int(pool.source_of(grandchild)).is_equal(42)
	assert_int(pool.open_count(root)).is_equal(3)


func test_depth_limit_refuses_deterministically() -> void:
	var pool := AttackContextPool.new(16)
	var ctx: int = pool.open_root(1, 100)
	for depth: int in AttackContextPool.MAX_DEPTH:
		ctx = pool.open_child(ctx)
		assert_int(ctx).is_not_equal(INVALID)
	assert_int(pool.depth_of(ctx)).is_equal(AttackContextPool.MAX_DEPTH)
	assert_int(pool.open_child(ctx)).is_equal(INVALID)
	assert_int(pool.depth_refusals).is_equal(1)


func test_hit_budget_is_shared_by_the_whole_tree() -> void:
	var pool := AttackContextPool.new(8)
	var root: int = pool.open_root(1, 3)
	var a: int = pool.open_child(root)
	var b: int = pool.open_child(root)
	assert_bool(pool.try_register_hit(root, 100)).is_true()
	assert_bool(pool.try_register_hit(a, 101)).is_true()
	assert_bool(pool.try_register_hit(b, 102)).is_true()
	assert_bool(pool.try_register_hit(b, 103)).is_false()
	assert_int(pool.budget_left(a)).is_equal(0)
	assert_int(pool.budget_refusals).is_equal(1)


func test_same_target_blocked_in_branch_but_allowed_in_sibling() -> void:
	var pool := AttackContextPool.new(8)
	var root: int = pool.open_root(1, 10)
	assert_bool(pool.try_register_hit(root, 500)).is_true()
	var left: int = pool.open_child(root)
	var right: int = pool.open_child(root)
	assert_bool(pool.try_register_hit(left, 500)).is_false()  # поражена предком
	assert_bool(pool.try_register_hit(left, 600)).is_true()
	var deeper: int = pool.open_child(left)
	assert_bool(pool.try_register_hit(deeper, 600)).is_false()  # поражена родителем
	assert_bool(pool.try_register_hit(right, 600)).is_true()  # соседняя ветка
	assert_int(pool.budget_left(root)).is_equal(7)


func test_targets_are_compared_by_full_handle() -> void:
	var pool := AttackContextPool.new(4)
	var root: int = pool.open_root(1, 10)
	var old_enemy: int = 0 * SPAN + 5  # слот 5, поколение 0
	var new_enemy: int = 1 * SPAN + 5  # тот же слот после переиспользования
	assert_bool(pool.try_register_hit(root, old_enemy)).is_true()
	assert_bool(pool.try_register_hit(root, new_enemy)).is_true()
	assert_int(pool.hit_count(root)).is_equal(2)


func test_graph_resolves_only_after_last_close_and_frees_tree() -> void:
	var pool := AttackContextPool.new(8)
	var root: int = pool.open_root(1, 10)
	var a: int = pool.open_child(root)
	var b: int = pool.open_child(a)
	assert_bool(pool.close(root)).is_false()
	assert_bool(pool.close(b)).is_false()
	assert_int(pool.alive_count()).is_equal(3)
	assert_bool(pool.close(a)).is_true()  # OnAttackResolved
	assert_int(pool.alive_count()).is_equal(0)
	for ctx: int in [root, a, b]:
		assert_bool(pool.is_valid(ctx)).is_false()


func test_double_close_is_refused_without_side_effects() -> void:
	var pool := AttackContextPool.new(8)
	var root: int = pool.open_root(1, 10)
	var child: int = pool.open_child(root)
	assert_bool(pool.close(child)).is_false()
	assert_bool(pool.close(child)).is_false()
	assert_int(pool.open_count(root)).is_equal(1)
	assert_bool(pool.close(root)).is_true()


func test_child_of_closed_parent_allowed_while_tree_lives() -> void:
	var pool := AttackContextPool.new(8)
	var root: int = pool.open_root(1, 10)
	var a: int = pool.open_child(root)
	assert_bool(pool.close(root)).is_false()  # корень закрыт, a ещё открыт
	var late: int = pool.open_child(root)  # отложенный эффект от закрытого корня
	assert_int(late).is_not_equal(INVALID)
	assert_bool(pool.try_register_hit(pool.open_child(late), 7)).is_true()
	assert_int(pool.open_count(root)).is_equal(3)


func test_stale_handles_are_refused_after_tree_release() -> void:
	var pool := AttackContextPool.new(4)
	var root: int = pool.open_root(1, 10)
	var child: int = pool.open_child(root)
	pool.close(child)
	assert_bool(pool.close(root)).is_true()
	var fresh: int = pool.open_root(2, 10)  # переиспользует слот корня
	assert_int(pool.open_child(root)).is_equal(INVALID)
	assert_bool(pool.try_register_hit(child, 9)).is_false()
	assert_bool(pool.close(root)).is_false()
	assert_int(pool.budget_left(root)).is_equal(-1)
	assert_int(pool.open_count(fresh)).is_equal(1)


func test_hit_set_overflow_is_reported_once() -> void:
	var pool := AttackContextPool.new(2)
	var root: int = pool.open_root(1, 1000)
	for t: int in AttackContextPool.HITS_PER_CONTEXT:
		pool.try_register_hit(root, 1000 + t)
	var results: Array[bool] = []
	await assert_error(func() -> void:
		results.append(pool.try_register_hit(root, 1))
		results.append(pool.try_register_hit(root, 2))) \
		.is_push_error("AttackContextPool: переполнено множество поражённых целей")
	assert_array(results).is_equal([false, false])
	assert_int(pool.hit_set_overflows).is_equal(2)


func test_pool_exhaustion_is_reported_once() -> void:
	var pool := AttackContextPool.new(2)
	var root: int = pool.open_root(1, 10)
	pool.open_child(root)
	var results: Array[int] = []
	await assert_error(func() -> void:
		results.append(pool.open_child(root))
		results.append(pool.open_root(3, 1))) \
		.is_push_error("AttackContextPool: ёмкость пула исчерпана")
	assert_array(results).is_equal([INVALID, INVALID])
	assert_int(pool.capacity_refusals).is_equal(2)
	pool.reset_counters()
	assert_int(pool.capacity_refusals).is_equal(0)


func test_attack_cycle_does_not_allocate() -> void:
	var pool := AttackContextPool.new(128)
	var acc: int = 0
	for warm: int in 50:
		var r: int = pool.open_root(1, 20)
		pool.try_register_hit(r, warm)
		pool.close(r)
	var objects_before: int = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var memory_before: int = int(Performance.get_monitor(Performance.MEMORY_STATIC))
	for attack: int in 3000:
		var root: int = pool.open_root(attack, 12)
		var a: int = pool.open_child(root)
		var b: int = pool.open_child(a)
		for t: int in 4:
			acc += int(pool.try_register_hit(root, t))
			acc += int(pool.try_register_hit(a, t + 10))
			acc += int(pool.try_register_hit(b, t + 20))
		pool.close(b)
		pool.close(root)
		acc += int(pool.close(a))
	var objects_delta: int = int(Performance.get_monitor(Performance.OBJECT_COUNT)) - objects_before
	var memory_delta: int = int(Performance.get_monitor(Performance.MEMORY_STATIC)) - memory_before
	assert_int(objects_delta).is_equal(0)
	assert_int(memory_delta).is_equal(0)
	assert_int(pool.alive_count()).is_equal(0)
	assert_int(acc).is_equal(3000 * 13)  # 12 ударов в бюджете + разрешение графа
