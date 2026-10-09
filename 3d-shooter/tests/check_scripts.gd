extends SceneTree
## Проверка всех скриптов проекта на ошибки разбора и типизации (CI).
## Импорт и тесты загружают не каждый скрипт, поэтому сломанный файл без
## тестов иначе прошёл бы незамеченным. addons/ не проверяется: @tool-скрипты
## аддонов рассчитаны на редактор.
##
## Запуск из корня репозитория:
##   godot --headless --path 3d-shooter -s res://tests/check_scripts.gd

const SKIPPED_DIRS: PackedStringArray = ["res://addons", "res://.godot"]


func _initialize() -> void:
	var paths := PackedStringArray()
	_collect_scripts("res://", paths)
	paths.sort()
	var checked: int = 0
	var failed: int = 0
	var self_path: String = (get_script() as Script).resource_path
	for path: String in paths:
		if path == self_path:
			continue  # перезагрузка выполняющегося скрипта ломает VM
		checked += 1
		var script: Script = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as Script
		# TODO(первый @abstract-класс): can_instantiate() у абстрактного класса
		# вернёт false, тогда проверять только ошибку загрузки.
		if script == null or not script.can_instantiate():
			printerr("CHECK FAIL: %s" % path)
			failed += 1
	print("CHECK scripts=%d failed=%d" % [checked, failed])
	quit(1 if failed > 0 else 0)


func _collect_scripts(dir_path: String, out: PackedStringArray) -> void:
	for file_name: String in DirAccess.get_files_at(dir_path):
		if file_name.get_extension() == "gd":
			out.append(dir_path.path_join(file_name))
	for sub_dir: String in DirAccess.get_directories_at(dir_path):
		var sub_path: String = dir_path.path_join(sub_dir)
		if sub_path in SKIPPED_DIRS:
			continue
		_collect_scripts(sub_path, out)
