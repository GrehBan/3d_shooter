extends SceneTree
## Бенчмарк регрессии: аллокации в бою и время логического тика
## (манифест I.4 и II.1, CLAUDE.md, догма 3).
##
## Запуск из корня репозитория:
##   godot --headless --path 3d-shooter --fixed-fps 60 -s res://tests/perf/regress.gd [-- опции]
## --fixed-fps 60 делает 60 с боя 3600 симулированными кадрами без ожидания
## реального времени. Опции после «--»:
##   --scene=res://...tscn  сцена-полигон (по умолчанию Sandbox; в M1–M2 — арена боя)
##   --no-synthetic         без синтетической нагрузки, когда в сцене есть настоящий бой
##   --inject-leak          самопроверка: нагрузка намеренно течёт, бенчмарк обязан упасть
##
## Критерии (жёсткие, ненулевой exit code при нарушении):
##   дельта OBJECT_COUNT, OBJECT_NODE_COUNT, OBJECT_RESOURCE_COUNT за замер = 0;
##   дельта OBJECT_ORPHAN_NODE_COUNT = 0 (OBJECT_NODE_COUNT считает только узлы
##   в дереве, а утёкший Node.new() вне дерева виден лишь здесь и в OBJECT_COUNT);
##   прирост MEMORY_STATIC за замер ≤ 1 МБ;
##   с синтетической нагрузкой: контрольная сумма совпадает с эталоном
##   (детерминизм математики; эталон меняется только вместе с LOAD_SEED,
##   числом тиков или формулой нагрузки), ни одна запись урона не отброшена
##   из-за переполнения DamagePayloadBuffer и счётчики ошибок конфигурации
##   конвейера равны 0 (HitEventQueue.dropped_count, AttackContextPool
##   hit_set_overflows и capacity_refusals, EffectHost.capacity_refusals).
## Время логического тика (среднее и максимум) только выводится: задел под
## бюджет 7 мс, жёстким порогом станет на сцене-бенчмарке M3.

const DEFAULT_SCENE: String = "res://world/sandbox/Sandbox.tscn"
const WARMUP_TICKS: int = 300  # 5 с при 60 Гц
const MEASURE_TICKS: int = 3600  # 60 с при 60 Гц
const MEMORY_STATIC_TOLERANCE: int = 1024 * 1024
const LOAD_SEED: int = 0x5EED
const EXPECTED_SYNTHETIC_CHECKSUM: int = 3032385286
const EXIT_PASS: int = 0
const EXIT_FAIL: int = 1
const EXIT_SETUP_ERROR: int = 2
const SyntheticCombatLoad: Script = preload("res://tests/perf/SyntheticCombatLoad.gd")

enum Phase { LOADING, WARMUP, MEASURE, DONE }

var _phase: Phase = Phase.LOADING
var _ticks: int = 0
var _scene_path: String = DEFAULT_SCENE
var _use_synthetic: bool = true
var _inject_leak: bool = false
var _game_loop: Node
var _load: RefCounted

var _objects_before: int = 0
var _nodes_before: int = 0
var _resources_before: int = 0
var _orphans_before: int = 0
var _memory_before: int = 0
var _last_logic_tick: int = 0
var _logic_samples: int = 0
var _logic_usec_sum: int = 0
var _logic_usec_max: int = 0
var _wall_start_msec: int = 0


func _initialize() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--scene="):
			_scene_path = arg.trim_prefix("--scene=")
		elif arg == "--no-synthetic":
			_use_synthetic = false
		elif arg == "--inject-leak":
			_inject_leak = true
		else:
			_abort("неизвестная опция %s" % arg)
			return
	_game_loop = root.get_node_or_null(^"GameLoop")
	if _game_loop == null:
		_abort("autoload GameLoop не найден")
		return
	if change_scene_to_file(_scene_path) != OK:
		_abort("не удалось открыть сцену %s" % _scene_path)
		return
	_wall_start_msec = Time.get_ticks_msec()
	print("REGRESS scene=%s synthetic=%s inject_leak=%s warmup_ticks=%d measure_ticks=%d" % [
		_scene_path, _use_synthetic, _inject_leak, WARMUP_TICKS, MEASURE_TICKS])


func _physics_process(_delta: float) -> bool:
	match _phase:
		Phase.LOADING:
			if current_scene != null:
				_start_warmup()
		Phase.WARMUP:
			_ticks += 1
			if _ticks >= WARMUP_TICKS:
				_start_measure()
		Phase.MEASURE:
			_ticks += 1
			_sample_logic_tick()
			if _ticks >= MEASURE_TICKS:
				_finish()
	return false


func _start_warmup() -> void:
	if _use_synthetic:
		_load = SyntheticCombatLoad.new(LOAD_SEED)
		_load.set(&"inject_leak", _inject_leak)
		_game_loop.connect(&"logic_tick", Callable(_load, &"on_logic_tick"))
	_phase = Phase.WARMUP
	_ticks = 0


func _start_measure() -> void:
	_objects_before = _monitor(Performance.OBJECT_COUNT)
	_nodes_before = _monitor(Performance.OBJECT_NODE_COUNT)
	_resources_before = _monitor(Performance.OBJECT_RESOURCE_COUNT)
	_orphans_before = _monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	_memory_before = _monitor(Performance.MEMORY_STATIC)
	_last_logic_tick = _game_loop.call(&"get_logic_tick")
	_phase = Phase.MEASURE
	_ticks = 0


func _sample_logic_tick() -> void:
	var logic_tick: int = _game_loop.call(&"get_logic_tick")
	if logic_tick == _last_logic_tick:
		return
	_last_logic_tick = logic_tick
	var usec: int = _game_loop.call(&"get_last_logic_tick_usec")
	_logic_samples += 1
	_logic_usec_sum += usec
	if usec > _logic_usec_max:
		_logic_usec_max = usec


func _finish() -> void:
	_phase = Phase.DONE
	var objects_delta: int = _monitor(Performance.OBJECT_COUNT) - _objects_before
	var nodes_delta: int = _monitor(Performance.OBJECT_NODE_COUNT) - _nodes_before
	var resources_delta: int = _monitor(Performance.OBJECT_RESOURCE_COUNT) - _resources_before
	var orphans_delta: int = _monitor(Performance.OBJECT_ORPHAN_NODE_COUNT) - _orphans_before
	var memory_delta: int = _monitor(Performance.MEMORY_STATIC) - _memory_before

	var failures := PackedStringArray()
	if objects_delta != 0:
		failures.append("OBJECT_COUNT изменился на %d (ожидается 0)" % objects_delta)
	if nodes_delta != 0:
		failures.append("OBJECT_NODE_COUNT изменился на %d (ожидается 0)" % nodes_delta)
	if resources_delta != 0:
		failures.append("OBJECT_RESOURCE_COUNT изменился на %d (ожидается 0)" % resources_delta)
	if orphans_delta != 0:
		failures.append("OBJECT_ORPHAN_NODE_COUNT изменился на %d (ожидается 0)" % orphans_delta)
	if memory_delta > MEMORY_STATIC_TOLERANCE:
		failures.append("MEMORY_STATIC вырос на %d байт (допуск %d)" % [memory_delta, MEMORY_STATIC_TOLERANCE])
	var checksum: int = -1
	var dropped: int = 0
	var config_errors: int = 0
	if _load != null:
		checksum = int(_load.get(&"checksum"))
		if checksum != EXPECTED_SYNTHETIC_CHECKSUM:
			failures.append("контрольная сумма нагрузки %d, эталон %d" % [checksum, EXPECTED_SYNTHETIC_CHECKSUM])
		dropped = int(_load.call(&"dropped_payloads"))
		if dropped != 0:
			failures.append("отброшено записей урона: %d (ожидается 0)" % dropped)
		config_errors = int(_load.call(&"config_errors"))
		if config_errors != 0:
			failures.append("ошибок конфигурации конвейера: %d (ожидается 0)" % config_errors)

	var avg_usec: float = float(_logic_usec_sum) / maxf(1.0, float(_logic_samples))
	print("REGRESS allocations: objects=%+d nodes=%+d resources=%+d orphans=%+d memory_static=%+d B" % [
		objects_delta, nodes_delta, resources_delta, orphans_delta, memory_delta])
	print("REGRESS logic_tick: samples=%d avg=%.1f us max=%d us (бюджет 7000 us, не порог)" % [
		_logic_samples, avg_usec, _logic_usec_max])
	if _load != null:
		print("REGRESS synthetic_checksum=%d (эталон %d) dropped_payloads=%d config_errors=%d" % [
			checksum, EXPECTED_SYNTHETIC_CHECKSUM, dropped, config_errors])
	print("REGRESS wall_time=%d ms" % (Time.get_ticks_msec() - _wall_start_msec))

	if _load != null:
		_game_loop.disconnect(&"logic_tick", Callable(_load, &"on_logic_tick"))
		_load.call(&"dispose")
		_load = null

	if failures.is_empty():
		print("REGRESS RESULT: PASS")
		quit(EXIT_PASS)
	else:
		for failure: String in failures:
			printerr("REGRESS FAIL: %s" % failure)
		print("REGRESS RESULT: FAIL")
		quit(EXIT_FAIL)


func _abort(reason: String) -> void:
	printerr("REGRESS SETUP ERROR: %s" % reason)
	_phase = Phase.DONE
	quit(EXIT_SETUP_ERROR)


static func _monitor(monitor: Performance.Monitor) -> int:
	return int(Performance.get_monitor(monitor))
