class_name Registry
extends RefCounted
## Реестр контента: строковый ключ → плотный int id → read-only Resource (GDD §9).
##
## Жизненный цикл: add_category() → register()/load_directory() → freeze().
## freeze() сортирует ключи каждой категории по кодовым точкам и раздаёт id
## 0..n-1, поэтому id не зависят от порядка регистрации и порядка файлов на диске.
## После freeze() реестр только читается.
##
## Горячий путь — get_resource(category, id): индекс в массиве, без хеширования
## строк и без аллокаций. id_of()/key_of() нужны при загрузке и сохранении
## (в сейве хранится ключ, а не id: id сдвигаются при добавлении контента).
##
## Zero-Trust State: ресурсы из реестра общие и не мутируются. Состояние
## забега живёт в рантайм-инстансах, созданных по этим данным.

const INVALID_ID: int = -1

var _category_names: Array[StringName] = []
var _required_scripts: Array[Script] = []  # по категории: обязательный тип или null
var _pending: Array[Dictionary] = []  # по категории: ключ → Resource, до freeze()
var _keys: Array[PackedStringArray] = []  # по категории: ключи в порядке id
var _resources: Array[Array] = []  # по категории: Resource в порядке id
var _ids: Array[Dictionary] = []  # по категории: ключ → id
var _frozen: bool = false


## Заводит категорию и возвращает её индекс. Если задан required_script, каждый
## ресурс категории обязан использовать этот скрипт или его наследника: тип
## проверяется при регистрации, а не в бою. Повторный вызов с тем же именем
## возвращает существующий индекс.
func add_category(category_name: StringName, required_script: Script = null) -> int:
	var existing: int = _category_names.find(category_name)
	if existing != -1:
		return existing
	if _frozen:
		push_error("Registry: нельзя добавить категорию '%s' после freeze()" % category_name)
		return INVALID_ID
	_category_names.append(category_name)
	_required_scripts.append(required_script)
	_pending.append({})
	_keys.append(PackedStringArray())
	_resources.append([])
	_ids.append({})
	return _category_names.size() - 1


## Индекс категории по имени или INVALID_ID.
func category_index(category_name: StringName) -> int:
	return _category_names.find(category_name)


## Регистрирует ресурс под ключом. Возвращает false при ошибке.
func register(category: int, key: StringName, resource: Resource) -> bool:
	if _frozen:
		push_error("Registry: регистрация '%s' после freeze()" % key)
		return false
	if not _is_valid_category(category):
		push_error("Registry: неизвестная категория %d" % category)
		return false
	if key.is_empty() or resource == null:
		push_error("Registry: пустой ключ или ресурс в категории '%s'" % _category_names[category])
		return false
	var required: Script = _required_scripts[category]
	if required != null and not _uses_script(resource, required):
		push_error("Registry: '%s' в категории '%s' не наследует %s" % [
			key, _category_names[category], required.resource_path])
		return false
	var pending: Dictionary = _pending[category]
	if pending.has(key):
		push_error("Registry: дубликат ключа '%s' в категории '%s'" % [key, _category_names[category]])
		return false
	pending[key] = resource
	return true


## Загружает все .tres/.res из каталога (без рекурсии), ключ — имя файла без
## расширения. Возвращает число загруженных ресурсов или INVALID_ID при ошибке.
## INVALID_ID — фатальная ошибка старта: часть ресурсов каталога к этому моменту
## уже зарегистрирована, поэтому вызывающий не продолжает с таким реестром.
func load_directory(category: int, dir_path: String) -> int:
	if not DirAccess.dir_exists_absolute(dir_path):
		push_error("Registry: каталог не найден: %s" % dir_path)
		return INVALID_ID
	var files: PackedStringArray = DirAccess.get_files_at(dir_path)
	var loaded: int = 0
	for file_name: String in files:
		# В экспортной сборке текстовые ресурсы лежат как *.tres.remap.
		var resource_name: String = file_name.trim_suffix(".remap")
		var extension: String = resource_name.get_extension()
		if extension != "tres" and extension != "res":
			continue
		var resource: Resource = ResourceLoader.load(dir_path.path_join(resource_name))
		if resource == null:
			push_error("Registry: не удалось загрузить %s" % dir_path.path_join(resource_name))
			return INVALID_ID
		if not register(category, StringName(resource_name.get_basename()), resource):
			return INVALID_ID
		loaded += 1
	return loaded


## Фиксирует реестр: сортирует ключи и раздаёт плотные id.
func freeze() -> void:
	if _frozen:
		return
	for category: int in _category_names.size():
		var pending: Dictionary = _pending[category]
		var keys := PackedStringArray()
		for key: StringName in pending:
			keys.append(String(key))
		keys.sort()
		var resources: Array = _resources[category]
		var ids: Dictionary = _ids[category]
		for id: int in keys.size():
			var key := StringName(keys[id])
			resources.append(pending[key])
			ids[key] = id
		_keys[category] = keys
		pending.clear()
	_frozen = true


func is_frozen() -> bool:
	return _frozen


## Число записей в категории (после freeze()).
func count(category: int) -> int:
	if not _is_valid_category(category):
		return 0
	return _keys[category].size()


## Ресурс по id. Горячий путь: без аллокаций. null, если id вне диапазона.
func get_resource(category: int, id: int) -> Resource:
	if not _is_valid_category(category):
		return null
	var resources: Array = _resources[category]
	if id < 0 or id >= resources.size():
		return null
	return resources[id]


## id по ключу или INVALID_ID. Для загрузки и сохранения, не для боя.
func id_of(category: int, key: StringName) -> int:
	if not _frozen or not _is_valid_category(category):
		return INVALID_ID
	return _ids[category].get(key, INVALID_ID)


## Ключ по id или пустой StringName. Для сохранения и отладки.
func key_of(category: int, id: int) -> StringName:
	if not _is_valid_category(category):
		return &""
	var keys: PackedStringArray = _keys[category]
	if id < 0 or id >= keys.size():
		return &""
	return StringName(keys[id])


func _is_valid_category(category: int) -> bool:
	return category >= 0 and category < _category_names.size()


static func _uses_script(resource: Resource, required: Script) -> bool:
	var script: Script = resource.get_script() as Script
	while script != null:
		if script == required:
			return true
		script = script.get_base_script()
	return false
