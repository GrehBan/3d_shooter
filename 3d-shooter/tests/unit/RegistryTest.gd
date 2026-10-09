extends GdUnitTestSuite
## Registry: детерминированные id, загрузка каталога, проверка типов, заморозка.

const FixtureData: Script = preload("res://tests/fixtures/registry/RegistryFixtureData.gd")
const ITEMS_DIR: String = "res://tests/fixtures/registry/items"
const MIXED_DIR: String = "res://tests/fixtures/registry/mixed"


static func _make(value: int) -> Resource:
	var data: Resource = FixtureData.new()
	data.set("value", value)
	return data


func test_ids_are_sorted_by_key_regardless_of_registration_order() -> void:
	var a := Registry.new()
	var ca: int = a.add_category(&"items")
	a.register(ca, &"gamma", _make(3))
	a.register(ca, &"alpha", _make(1))
	a.register(ca, &"beta", _make(2))
	a.freeze()

	var b := Registry.new()
	var cb: int = b.add_category(&"items")
	b.register(cb, &"beta", _make(2))
	b.register(cb, &"gamma", _make(3))
	b.register(cb, &"alpha", _make(1))
	b.freeze()

	for key: StringName in [&"alpha", &"beta", &"gamma"]:
		assert_int(a.id_of(ca, key)).is_equal(b.id_of(cb, key))
	assert_int(a.id_of(ca, &"alpha")).is_equal(0)
	assert_int(a.id_of(ca, &"beta")).is_equal(1)
	assert_int(a.id_of(ca, &"gamma")).is_equal(2)
	assert_int(a.get_resource(ca, 2).get("value")).is_equal(3)
	assert_str(String(a.key_of(ca, 1))).is_equal("beta")


func test_load_directory_registers_tres_by_file_name() -> void:
	var registry := Registry.new()
	var items: int = registry.add_category(&"items", FixtureData)
	assert_int(registry.load_directory(items, ITEMS_DIR)).is_equal(3)
	registry.freeze()
	assert_int(registry.count(items)).is_equal(3)
	for id: int in 3:
		# alpha=1, beta=2, gamma=3: id совпадает с порядком ключей.
		assert_int(registry.get_resource(items, id).get("value")).is_equal(id + 1)


func test_lookup_misses_return_sentinels() -> void:
	var registry := Registry.new()
	var items: int = registry.add_category(&"items")
	registry.register(items, &"alpha", _make(1))
	assert_int(registry.id_of(items, &"alpha")).is_equal(Registry.INVALID_ID)  # до freeze()
	registry.freeze()
	assert_int(registry.id_of(items, &"missing")).is_equal(Registry.INVALID_ID)
	assert_object(registry.get_resource(items, 1)).is_null()
	assert_object(registry.get_resource(items, -1)).is_null()
	assert_object(registry.get_resource(7, 0)).is_null()
	assert_str(String(registry.key_of(items, 5))).is_empty()
	assert_int(registry.count(7)).is_equal(0)


func test_categories_are_independent() -> void:
	var registry := Registry.new()
	var weapons: int = registry.add_category(&"weapons")
	var cards: int = registry.add_category(&"cards")
	assert_int(registry.add_category(&"weapons")).is_equal(weapons)
	assert_int(registry.category_index(&"cards")).is_equal(cards)
	registry.register(weapons, &"shotgun", _make(10))
	registry.register(cards, &"shotgun", _make(20))
	registry.register(cards, &"chain", _make(30))
	registry.freeze()
	assert_int(registry.count(weapons)).is_equal(1)
	assert_int(registry.count(cards)).is_equal(2)
	assert_int(registry.get_resource(weapons, registry.id_of(weapons, &"shotgun")).get("value")).is_equal(10)
	assert_int(registry.get_resource(cards, registry.id_of(cards, &"shotgun")).get("value")).is_equal(20)


func test_duplicate_key_is_rejected() -> void:
	var registry := Registry.new()
	var items: int = registry.add_category(&"items")
	assert_bool(registry.register(items, &"alpha", _make(1))).is_true()
	await assert_error(func() -> void: registry.register(items, &"alpha", _make(2))) \
		.is_push_error("Registry: дубликат ключа 'alpha' в категории 'items'")
	registry.freeze()
	assert_int(registry.get_resource(items, 0).get("value")).is_equal(1)


func test_wrong_type_is_rejected_on_load() -> void:
	var registry := Registry.new()
	var items: int = registry.add_category(&"items", FixtureData)
	await assert_error(func() -> void: registry.load_directory(items, MIXED_DIR)) \
		.is_push_error("Registry: 'plain' в категории 'items' не наследует %s" % FixtureData.resource_path)


func test_register_after_freeze_is_rejected() -> void:
	var registry := Registry.new()
	var items: int = registry.add_category(&"items")
	registry.freeze()
	assert_bool(registry.is_frozen()).is_true()
	await assert_error(func() -> void: registry.register(items, &"late", _make(1))) \
		.is_push_error("Registry: регистрация 'late' после freeze()")
	assert_int(registry.count(items)).is_equal(0)


func test_missing_directory_is_reported() -> void:
	var registry := Registry.new()
	var items: int = registry.add_category(&"items")
	await assert_error(func() -> void: registry.load_directory(items, "res://tests/fixtures/registry/nope")) \
		.is_push_error("Registry: каталог не найден: res://tests/fixtures/registry/nope")


func test_get_resource_does_not_allocate() -> void:
	var registry := Registry.new()
	var items: int = registry.add_category(&"items", FixtureData)
	registry.load_directory(items, ITEMS_DIR)
	registry.freeze()
	var objects_before: int = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var memory_before: int = int(Performance.get_monitor(Performance.MEMORY_STATIC))
	var hits: int = 0
	for i: int in 30000:
		if registry.get_resource(items, i % 3) != null:
			hits += 1
	var objects_delta: int = int(Performance.get_monitor(Performance.OBJECT_COUNT)) - objects_before
	var memory_delta: int = int(Performance.get_monitor(Performance.MEMORY_STATIC)) - memory_before
	assert_int(hits).is_equal(30000)
	assert_int(objects_delta).is_equal(0)
	assert_int(memory_delta).is_equal(0)
