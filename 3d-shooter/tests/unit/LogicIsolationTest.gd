extends GdUnitTestSuite
## «Логика и визуал независимы» (roadmap M1a): скрипты логики — чистые классы.
## Каждый скрипт в core/, combat/, effects/ (рекурсивно, с подпапками) и
## player/MovementAbilit* должен
## наследовать RefCounted или Resource. Исключения — только в ALLOWED_NODES,
## с причиной; новый Node-класс в логике без записи здесь роняет тест.

const LOGIC_DIRS: PackedStringArray = ["res://core", "res://combat", "res://effects"]
const LOGIC_FILE_PREFIXES: Dictionary = {"res://player": "MovementAbilit"}
const ALLOWED_BASES: PackedStringArray = ["RefCounted", "Resource"]
const ALLOWED_NODES: Dictionary = {
	# Autoload: центральный цикл, принимает _physics_process движка; логики не держит.
	"res://core/GameLoop.gd": "autoload, тонкая обёртка над LogicClock",
	# Autoload: шина глобальных сигналов забега и комнат; сигналы требуют Object.
	"res://core/EventBus.gd": "autoload, только сигналы переходов",
}


static func _collect_recursive(dir_path: String, paths: PackedStringArray) -> void:
	for file_name: String in DirAccess.get_files_at(dir_path):
		if file_name.get_extension() == "gd":
			paths.append(dir_path.path_join(file_name))
	for sub_dir: String in DirAccess.get_directories_at(dir_path):
		_collect_recursive(dir_path.path_join(sub_dir), paths)


static func _collect(paths: PackedStringArray) -> PackedStringArray:
	for dir_path: String in LOGIC_DIRS:
		_collect_recursive(dir_path, paths)
	for dir_path: String in LOGIC_FILE_PREFIXES:
		var prefix: String = LOGIC_FILE_PREFIXES[dir_path]
		for file_name: String in DirAccess.get_files_at(dir_path):
			if file_name.get_extension() == "gd" and file_name.begins_with(prefix):
				paths.append(dir_path.path_join(file_name))
	return paths


func test_logic_scripts_are_pure_classes() -> void:
	var paths := _collect(PackedStringArray())
	assert_int(paths.size()).is_greater(10)  # обход реально нашёл скрипты логики
	var violations := PackedStringArray()
	for path: String in paths:
		var script: Script = load(path) as Script
		var base: String = script.get_instance_base_type()
		if base in ALLOWED_BASES:
			continue
		if ALLOWED_NODES.has(path):
			continue
		violations.append("%s наследует %s" % [path, base])
	assert_array(violations).is_empty()


func test_allowlist_entries_still_exist_and_are_nodes() -> void:
	# Исключение без файла или уже не Node — устаревшая запись, её надо убрать.
	for path: String in ALLOWED_NODES:
		assert_bool(ResourceLoader.exists(path)).is_true()
		var script: Script = load(path) as Script
		assert_bool(ClassDB.is_parent_class(script.get_instance_base_type(), "Node")).is_true()
