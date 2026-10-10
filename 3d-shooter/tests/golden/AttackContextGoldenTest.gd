extends GdUnitTestSuite
## Золотой тест AttackContextPool: сценарий цепной молнии в ширину с ветвлением,
## отказами по глубине, бюджету и повторной цели в ветке; цели — полные handle,
## среди них одинаковые слоты разных поколений. Эталон посчитан независимой
## Python-моделью HandlePool + AttackContextPool: tests/tools/acp_ref.py
## (запуск из корня репозитория: python 3d-shooter/tests/tools/acp_ref.py).

const FNV_OFFSET: int = 2166136261
const FNV_PRIME: int = 16777619
const MASK32: int = 0xFFFFFFFF
const SPAN: int = HandlePool.INDEX_SPAN


static func _fnv(h: int, v: int) -> int:
	return ((h ^ (v & MASK32)) * FNV_PRIME) & MASK32


func test_chain_lightning_scenario_hash() -> void:
	var targets := PackedInt64Array()
	for i: int in 25:
		targets.append((i % 3) * SPAN + (i % 7))
	var pool := AttackContextPool.new(32)
	var results := PackedInt64Array()
	var root: int = pool.open_root(7, 23)
	results.append(root)
	var opened := PackedInt64Array([root])
	var queue_ctx := PackedInt64Array([root])
	var queue_seed := PackedInt64Array([0])
	var head: int = 0
	var step: int = 0
	while head < queue_ctx.size() and step < 60:
		var ctx: int = queue_ctx[head]
		var seed: int = queue_seed[head]
		head += 1
		for b: int in 3:
			var target: int = targets[(seed * 3 + b) % 25]
			var ok: bool = pool.try_register_hit(ctx, target)
			results.append(1 if ok else 0)
			if ok and b < 2:
				var child: int = pool.open_child(ctx)
				results.append(child)
				if child != AttackContextPool.INVALID_HANDLE:
					opened.append(child)
					queue_ctx.append(child)
					queue_seed.append(seed * 3 + b + 1)
		step += 1
	for context: int in opened:
		results.append(1 if pool.close(context) else 0)
	results.append(1 if pool.is_valid(root) else 0)
	results.append(pool.depth_refusals)
	results.append(pool.budget_refusals)
	results.append(opened.size())
	results.append(pool.capacity() - pool.alive_count())

	var h: int = FNV_OFFSET
	for v: int in results:
		h = _fnv(h, v)
	assert_int(results.size()).is_equal(81)
	assert_int(opened.size()).is_equal(15)
	assert_int(pool.depth_refusals).is_equal(1)
	assert_int(pool.budget_refusals).is_equal(2)
	assert_int(pool.alive_count()).is_equal(0)
	assert_int(h).is_equal(1200451129)
