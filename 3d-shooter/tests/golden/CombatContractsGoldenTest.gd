extends GdUnitTestSuite
## Сквозной mock-тест контрактов M1a: mock-дробовик → Damageable (коллайдеры
## хранят только handle) → HitEventQueue (попадания в перемешанном порядке) →
## AttackContext (бюджет, защита ветки, цепной удар) → EffectHost (ON_HIT-бонусы)
## → DamagePayloadBuffer → StatBlock (смерть и респавн в том же слоте), плюс рывок
## MovementAbilities между выстрелами. Сценарий прогоняется с двумя сидами
## перемешивания: хеш обязан совпасть, то есть результат не зависит от порядка
## колбэков физики. Эталон посчитан Python-моделью: tests/tools/combat_contracts_ref.py
## (запуск из корня репозитория: python 3d-shooter/tests/tools/combat_contracts_ref.py).

const FNV_OFFSET: int = 2166136261
const FNV_PRIME: int = 16777619
const MASK32: int = 0xFFFFFFFF
const SPAN: int = HandlePool.INDEX_SPAN
const SHOTS: int = 12
const PELLETS: int = 6
const ENEMIES: int = 6
const ENEMY_HP: int = 20_000
const BASE_DAMAGE: int = 3_000
const CHAIN_DAMAGE: int = 1_000
const SHUFFLE_STREAM: int = 77
const HP := StatBlock.Stat.HP
const MAX_HP := StatBlock.Stat.MAX_HP


static func _fnv(h: int, v: int) -> int:
	return ((h ^ (v & MASK32)) * FNV_PRIME) & MASK32


# Mock-действие эффекта: бонус урона ×1000 по effect_id.
static func _bonus(effect_id: int) -> int:
	match effect_id:
		1:
			return 500
		2:
			return 100
	return 0


static func _spawn_enemy(stats: StatBlock) -> int:
	var e: int = stats.allocate()
	stats.set_stat(e, MAX_HP, ENEMY_HP)
	stats.set_stat(e, HP, ENEMY_HP)
	return e


# Сценарий целиком; возвращает [хеш, сумма счётчиков ошибок конфигурации].
static func _run(shuffle_seed: int) -> PackedInt64Array:
	var stats := StatBlock.new(16)
	var hits := HitEventQueue.new(64)
	var contexts := AttackContextPool.new(32)
	var effects := EffectHost.new(16, 32)
	var payloads := DamagePayloadBuffer.new(64)
	var moves := MovementAbilities.new(16, 200)
	var player: int = stats.allocate()
	stats.set_stat(player, StatBlock.Stat.MAX_ENERGY, 3000)
	stats.set_stat(player, StatBlock.Stat.ENERGY, 3000)
	var enemies := PackedInt64Array()
	var colliders: Array[StaticBody3D] = []
	for i: int in ENEMIES:
		enemies.append(_spawn_enemy(stats))
		var collider := StaticBody3D.new()
		Damageable.attach(collider, enemies[i])
		colliders.append(collider)
	effects.add_effect(player, EffectTrigger.Trigger.ON_HIT, EffectTrigger.Phase.MAIN, 0, 0, 1, 0)
	effects.add_effect(player, EffectTrigger.Trigger.ON_HIT, EffectTrigger.Phase.PRE, 0, 1, 2, 0)
	moves.grant(player, MovementAbilityData.Kind.DASH, 1000, 5, true, true)
	var rng: SeededRng = SeededRng.new(shuffle_seed).substream(SHUFFLE_STREAM)
	var order := PackedInt32Array()
	order.resize(PELLETS)
	var h: int = FNV_OFFSET

	for shot: int in SHOTS:
		var tick: int = shot * 3
		var dashed: bool = moves.try_activate(player, MovementAbilityData.Kind.DASH, tick, false, stats)
		h = _fnv(h, 1 if dashed else 0)
		for t: int in 3:
			moves.regen_energy(stats)
		# «Физика»: дробь в перемешанном порядке колбэков.
		for p: int in PELLETS:
			order[p] = p
		rng.shuffle_int32(order)
		for p: int in order:
			var collider: StaticBody3D = colliders[(shot + p * p) % ENEMIES]
			hits.push(player, Damageable.handle_of(collider), HitEventQueue.HitKind.HITSCAN, shot * 16 + p)
		# Логический тик.
		var count: int = hits.prepare()
		var root: int = contexts.open_root(player, 4)
		var child: int = AttackContextPool.INVALID_HANDLE
		var chain_opened: bool = false
		for i: int in count:
			var target: int = hits.get_target(i)
			if not contexts.try_register_hit(root, target):
				h = _fnv(h, 0)
				continue
			var damage: int = BASE_DAMAGE
			var index: int = effects.first(player, EffectTrigger.Trigger.ON_HIT)
			while index != EffectHost.NO_ENTRY:
				damage += _bonus(effects.effect_id_at(index))
				index = effects.next(index)
			payloads.push(player, target, damage, DamagePayload.Element.NONE, 0, 0, root)
			h = _fnv(h, target)
			if not chain_opened:
				chain_opened = true
				child = contexts.open_child(root)
				var enemy_index: int = target % SPAN - 1  # слот 0 занят игроком
				var chain_target: int = enemies[(enemy_index + 1) % ENEMIES]
				var chained: bool = contexts.try_register_hit(child, chain_target)
				if chained:
					payloads.push(player, chain_target, CHAIN_DAMAGE, DamagePayload.Element.ELECTRIC,
							0, DamagePayload.Flag.SECONDARY, child)
				h = _fnv(h, 1 if chained else 0)
		hits.clear()
		while not payloads.is_empty():
			var slot: int = payloads.front_slot()
			var target: int = payloads.get_target(slot)
			if not stats.is_valid(target):
				h = _fnv(h, -1)  # цель умерла раньше в этом же тике
			else:
				var hp: int = stats.add_stat_clamped(target, HP, -payloads.get_amount(slot), 0,
						stats.get_stat(target, MAX_HP))
				h = _fnv(h, hp)
				if hp == 0:
					var enemy_index: int = target % SPAN - 1
					Damageable.detach(colliders[enemy_index])
					stats.release(target)
					enemies[enemy_index] = _spawn_enemy(stats)
					Damageable.attach(colliders[enemy_index], enemies[enemy_index])
			payloads.pop_front()
		if child != AttackContextPool.INVALID_HANDLE:
			contexts.close(child)
		h = _fnv(h, 1 if contexts.close(root) else 0)

	for e: int in enemies:
		h = _fnv(h, e)
		h = _fnv(h, stats.get_stat(e, HP))
	h = _fnv(h, stats.get_stat(player, StatBlock.Stat.ENERGY))
	var config_errors: int = hits.dropped_count() + contexts.hit_set_overflows \
			+ contexts.capacity_refusals + effects.capacity_refusals + payloads.dropped_count()
	for collider: StaticBody3D in colliders:
		collider.free()
	return PackedInt64Array([h, config_errors, contexts.alive_count()])


func test_pipeline_hash_matches_reference_for_any_callback_order() -> void:
	var first := _run(1)
	var second := _run(424242)
	assert_int(first[1]).is_equal(0)  # ошибки конфигурации: корректность только при нуле
	assert_int(first[2]).is_equal(0)  # все деревья атак разрешены и освобождены
	assert_int(second[0]).is_equal(first[0])
	assert_int(first[0]).is_equal(3387878494)
