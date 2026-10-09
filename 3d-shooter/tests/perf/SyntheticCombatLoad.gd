extends RefCounted
## Синтетическая боевая нагрузка для regress.gd, пока в игре нет боя (M0).
## На каждом логическом тике имитирует 40 врагов: выбор данных из Registry,
## броски SeededRng, урон в фиксированной точке ×1000 по плотному массиву HP.
## Когда появится настоящая арена боя (M1–M2), бенчмарк запускается с
## --no-synthetic, и этот класс больше не нужен.

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
var _hp: PackedInt32Array = PackedInt32Array()
var _leaked: Array[Node] = []


func _init(rng_seed: int) -> void:
	_rng = SeededRng.new(rng_seed)
	_registry = Registry.new()
	_items = _registry.add_category(&"items", FixtureData)
	_registry.load_directory(_items, ITEMS_DIR)
	_registry.freeze()
	_hp.resize(ENEMY_COUNT)
	_hp.fill(ENEMY_MAX_HP)


func on_logic_tick(tick: int) -> void:
	var item_count: int = _registry.count(_items)
	for e: int in ENEMY_COUNT:
		var data: Resource = _registry.get_resource(_items, _rng.range_int(0, item_count - 1))
		var damage: int = _rng.range_int(1_000, 5_000) + int(data.get(&"value")) * 100
		if _rng.chance_permille(150):
			damage *= 2
		damage += _rng.weighted_index(_weights) * 250
		var hp: int = _hp[e] - damage
		if hp <= 0:
			hp = ENEMY_MAX_HP
		_hp[e] = hp
		checksum = (checksum * 31 + hp + tick) & SeededRng.MASK32
	if inject_leak:
		_leaked.append(Node.new())


## Освобождает намеренно удержанные узлы самопроверки.
func dispose() -> void:
	for node: Node in _leaked:
		node.free()
	_leaked.clear()
