extends RefCounted
## Синтетическая боевая нагрузка для regress.gd, пока в игре нет боя (M1a).
## На каждом логическом тике имитирует 40 врагов по полному конвейеру
## контрактов: физика кладёт попадания в HitEventQueue, логика упорядочивает
## их, открывает AttackContext на каждое попадание, обходит ON_HIT-эффекты
## атакующего в EffectHost, кладёт урон ×1000 в DamagePayloadBuffer и применяет
## его к HP в StatBlock. Арифметика и порядок бросков те же, что в версии M0
## (цели в тике уникальны, канонический порядок очереди совпадает с порядком
## врагов), поэтому эталон контрольной суммы не менялся.
## Когда появится настоящая арена боя, бенчмарк запускается с --no-synthetic.

const ENEMY_COUNT: int = 40
const ENEMY_MAX_HP: int = 100_000  # 100.0 HP ×1000
const ON_HIT_EFFECTS: int = 4  # подписки атакующего, обходятся на каждое попадание
const FixtureData: Script = preload("res://tests/fixtures/registry/RegistryFixtureData.gd")
const ITEMS_DIR: String = "res://tests/fixtures/registry/items"

## Самопроверка бенчмарка: при true каждый тик создаёт и удерживает Node.
var inject_leak: bool = false
## Детерминированная свёртка результатов: одинакова при одинаковом числе тиков.
var checksum: int = 0
## Свёртка обхода эффектов: только чтобы обход не был пустым, в checksum не входит.
var effect_trace: int = 0

var _rng: SeededRng
var _registry: Registry
var _items: int = Registry.INVALID_ID
var _weights: PackedInt32Array = PackedInt32Array([50, 30, 15, 5])
var _stats: StatBlock
var _hits: HitEventQueue
var _contexts: AttackContextPool
var _effects: EffectHost
var _payloads: DamagePayloadBuffer
var _attacker: int = HandlePool.INVALID_HANDLE
var _enemies: PackedInt64Array = PackedInt64Array()
var _open_contexts: PackedInt64Array = PackedInt64Array()
var _leaked: Array[Node] = []


func _init(rng_seed: int) -> void:
	_rng = SeededRng.new(rng_seed)
	_registry = Registry.new()
	_items = _registry.add_category(&"items", FixtureData)
	_registry.load_directory(_items, ITEMS_DIR)
	_registry.freeze()
	_stats = StatBlock.new(StatBlock.DEFAULT_CAPACITY)
	_hits = HitEventQueue.new(HitEventQueue.DEFAULT_CAPACITY)
	_contexts = AttackContextPool.new(AttackContextPool.DEFAULT_CAPACITY)
	_effects = EffectHost.new(StatBlock.DEFAULT_CAPACITY, EffectHost.DEFAULT_ENTRY_CAPACITY)
	_payloads = DamagePayloadBuffer.new(DamagePayloadBuffer.DEFAULT_CAPACITY)
	_enemies.resize(ENEMY_COUNT)
	_open_contexts.resize(ENEMY_COUNT)
	for e: int in ENEMY_COUNT:
		var handle: int = _stats.allocate()
		_stats.set_stat(handle, StatBlock.Stat.MAX_HP, ENEMY_MAX_HP)
		_stats.set_stat(handle, StatBlock.Stat.HP, ENEMY_MAX_HP)
		_enemies[e] = handle
	# Атакующий выделяется последним: слоты врагов идут подряд с нуля, и канонический
	# порядок очереди (по слоту цели) совпадает с порядком врагов.
	_attacker = _stats.allocate()
	for i: int in ON_HIT_EFFECTS:
		_effects.add_effect(_attacker, EffectTrigger.Trigger.ON_HIT, EffectTrigger.Phase.MAIN, i, i, i + 1, i)


## Записи урона, отброшенные из-за переполнения буфера (в норме 0).
func dropped_payloads() -> int:
	return _payloads.dropped_count()


## Сумма счётчиков ошибок конфигурации конвейера (в норме 0): отброшенные
## попадания, переполнение множества целей и пула контекстов, переполнение EffectHost.
func config_errors() -> int:
	return _hits.dropped_count() + _contexts.hit_set_overflows + _contexts.capacity_refusals \
			+ _effects.capacity_refusals


func on_logic_tick(tick: int) -> void:
	# «Физика»: попадания за тик.
	var item_count: int = _registry.count(_items)
	for e: int in ENEMY_COUNT:
		var data: Resource = _registry.get_resource(_items, _rng.range_int(0, item_count - 1))
		var damage: int = _rng.range_int(1_000, 5_000) + int(data.get(&"value")) * 100
		if _rng.chance_permille(150):
			damage *= 2
		damage += _rng.weighted_index(_weights) * 250
		_hits.push(_attacker, _enemies[e], HitEventQueue.HitKind.HITSCAN, damage)
	# Логический тик: упорядочить, открыть контексты, обойти эффекты, положить урон.
	var count: int = _hits.prepare()
	for i: int in count:
		var target: int = _hits.get_target(i)
		var context: int = _contexts.open_root(_attacker, 1)
		_open_contexts[i] = context
		if not _contexts.try_register_hit(context, target):
			continue
		var index: int = _effects.first(_attacker, EffectTrigger.Trigger.ON_HIT)
		while index != EffectHost.NO_ENTRY:
			effect_trace = (effect_trace * 31 + _effects.effect_id_at(index)) & SeededRng.MASK32
			index = _effects.next(index)
		_payloads.push(_attacker, target, _hits.get_payload(i), DamagePayload.Element.NONE,
				0, 0, context)
	_hits.clear()
	while not _payloads.is_empty():
		var slot: int = _payloads.front_slot()
		var target: int = _payloads.get_target(slot)
		var hp: int = _stats.get_stat(target, StatBlock.Stat.HP) - _payloads.get_amount(slot)
		if hp <= 0:
			hp = ENEMY_MAX_HP
		_stats.set_stat(target, StatBlock.Stat.HP, hp)
		checksum = (checksum * 31 + hp + tick) & SeededRng.MASK32
		_payloads.pop_front()
	for i: int in count:
		_contexts.close(_open_contexts[i])
	if inject_leak:
		_leaked.append(Node.new())


## Освобождает намеренно удержанные узлы самопроверки.
func dispose() -> void:
	for node: Node in _leaked:
		node.free()
	_leaked.clear()
