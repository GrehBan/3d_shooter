extends RefCounted
## Синтетическая боевая нагрузка для regress.gd, пока в игре нет боя (M0–M1).
## На каждом логическом тике имитирует 40 врагов: выбор данных из Registry,
## броски SeededRng, урон ×1000 в DamagePayloadBuffer, затем пакетное
## применение урона к HP в StatBlock. Арифметика и порядок бросков те же, что
## в версии M0 с плотным массивом HP, поэтому эталон контрольной суммы не менялся.
## Когда появится настоящая арена боя, бенчмарк запускается с --no-synthetic.

const ENEMY_COUNT: int = 40
const ENEMY_MAX_HP: int = 100_000  # 100.0 HP ×1000
const FixtureData: Script = preload("res://tests/fixtures/registry/RegistryFixtureData.gd")
const ITEMS_DIR: String = "res://tests/fixtures/registry/items"

## Самопроверка бенчмарка: при true каждый тик создаёт и удерживает Node.
var inject_leak: bool = false
## Детерминированная свёртка результатов: одинакова при одинаковом числе тиков.
var checksum: int = 0

var _rng: SeededRng
var _registry: Registry
var _items: int = Registry.INVALID_ID
var _weights: PackedInt32Array = PackedInt32Array([50, 30, 15, 5])
var _stats: StatBlock
var _payloads: DamagePayloadBuffer
var _enemies: PackedInt64Array = PackedInt64Array()
var _leaked: Array[Node] = []


func _init(rng_seed: int) -> void:
	_rng = SeededRng.new(rng_seed)
	_registry = Registry.new()
	_items = _registry.add_category(&"items", FixtureData)
	_registry.load_directory(_items, ITEMS_DIR)
	_registry.freeze()
	_stats = StatBlock.new(StatBlock.DEFAULT_CAPACITY)
	_payloads = DamagePayloadBuffer.new(DamagePayloadBuffer.DEFAULT_CAPACITY)
	_enemies.resize(ENEMY_COUNT)
	for e: int in ENEMY_COUNT:
		var handle: int = _stats.allocate()
		_stats.set_stat(handle, StatBlock.Stat.MAX_HP, ENEMY_MAX_HP)
		_stats.set_stat(handle, StatBlock.Stat.HP, ENEMY_MAX_HP)
		_enemies[e] = handle


## Записи урона, отброшенные из-за переполнения буфера (в норме 0).
func dropped_payloads() -> int:
	return _payloads.dropped_count()


func on_logic_tick(tick: int) -> void:
	var item_count: int = _registry.count(_items)
	for e: int in ENEMY_COUNT:
		var data: Resource = _registry.get_resource(_items, _rng.range_int(0, item_count - 1))
		var damage: int = _rng.range_int(1_000, 5_000) + int(data.get(&"value")) * 100
		var flags: int = 0
		if _rng.chance_permille(150):
			damage *= 2
			flags = DamagePayload.Flag.CRIT
		damage += _rng.weighted_index(_weights) * 250
		_payloads.push(DamagePayload.NO_HANDLE, _enemies[e], damage, DamagePayload.Element.NONE,
				0, flags, DamagePayload.NO_HANDLE)
	while not _payloads.is_empty():
		var slot: int = _payloads.front_slot()
		var target: int = _payloads.get_target(slot)
		var hp: int = _stats.get_stat(target, StatBlock.Stat.HP) - _payloads.get_amount(slot)
		if hp <= 0:
			hp = ENEMY_MAX_HP
		_stats.set_stat(target, StatBlock.Stat.HP, hp)
		checksum = (checksum * 31 + hp + tick) & SeededRng.MASK32
		_payloads.pop_front()
	if inject_leak:
		_leaked.append(Node.new())


## Освобождает намеренно удержанные узлы самопроверки.
func dispose() -> void:
	for node: Node in _leaked:
		node.free()
	_leaked.clear()
