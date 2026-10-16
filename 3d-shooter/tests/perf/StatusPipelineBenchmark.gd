class_name StatusPipelineBenchmark
extends Node
## M2.3a profile "40 targets + 1 source": the real Sandbox composition root with its
## RoomCombat statuses, resolver, counter effects and mobility under GameLoop. A physics
## driver publishes one 8-pellet record per logic tick into ShotBatch (15x the shotgun's
## cadence), rotating five groups of eight targets over FIRE, ICE, ACID, ELECTRIC and NONE,
## so every target keeps burning, chilling, freezing, shattering and corroding. Raycasts are
## not part of this profile: real_pipeline measures them.

const SANDBOX: PackedScene = preload("res://world/sandbox/Sandbox.tscn")
const ROOM: RoomConfig = preload("res://tests/fixtures/rooms/status_load_40.tres")
const WARMUP_TICKS: int = 300
const MEASURE_TICKS: int = 3600
const TARGETS: int = 40
const GROUP: int = 8
const RAW_DAMAGE: int = 1000
const TARGET_HP: int = 1_000_000_000
const TARGET_ARMOR: int = 30_000
const MEMORY_LIMIT: int = 1024 * 1024
const LOGIC_LIMIT_USEC: int = 7000
const FRAME_CAPACITY: int = 120000
const ELEMENTS: PackedInt32Array = [DamagePayload.Element.FIRE, DamagePayload.Element.ICE,
		DamagePayload.Element.ACID, DamagePayload.Element.ELECTRIC, DamagePayload.Element.NONE]
const PHASE_NAMES: PackedStringArray = ["statuses", "resolver", "effects", "mobility"]

var _sandbox: Node3D
var _combat: RoomCombat
var _batch: ShotBatch
var _resolver: ShotResolver
var _effects: EffectRunner
var _visuals: ShotVisualPool
var _mobility: MobilityRuntime
var _player: int = StatBlock.INVALID_HANDLE
var _targets: PackedInt64Array = PackedInt64Array()
var _driver: Driver
var _published: int = 0
var _inject_leak: bool = false
var _leaked: Node
var _graphical: bool = false
var _done: bool = false
var _measuring: bool = false
var _physics_ticks: int = 0
var _last_logic_tick: int = 0
var _logic_samples: int = 0
var _logic_sum: int = 0
var _logic_max: int = 0
var _monitors: PackedInt64Array = PackedInt64Array()
var _baseline: PackedInt64Array = PackedInt64Array()
var _frame_usec: PackedInt64Array = PackedInt64Array()
var _frame_count: int = 0
var _frame_sum: int = 0
var _last_frame_usec: int = 0


## Physics transport stand-in: runs before GameLoop in the same physics tick.
class Driver extends Node:
	var benchmark: StatusPipelineBenchmark
	var ticks: int = 0


	func _physics_process(_delta: float) -> void:
		ticks += 1
		if ticks % 2 == 0:
			benchmark._publish_shot()
		if benchmark._inject_leak and ticks == WARMUP_TICKS + 1:
			benchmark._leaked = Node.new()  # Deliberate negative probe, cleaned after capture.


func _ready() -> void:
	process_physics_priority = 1200
	for argument: String in OS.get_cmdline_user_args():
		if argument == "--inject-leak":
			_inject_leak = true
		else:
			_abort("unknown option: " + argument)
			return
	if Engine.physics_ticks_per_second != 60 or Engine.time_scale != 1.0:
		_abort("requires 60 Hz physics and time_scale 1")
		return
	_graphical = DisplayServer.get_name() != "headless"
	if _graphical:
		for argument: String in OS.get_cmdline_args():
			if argument == "--fixed-fps" or argument.begins_with("--fixed-fps=") \
					or argument == "--time-scale" or argument.begins_with("--time-scale=") \
					or argument == "--max-fps" or argument.begins_with("--max-fps="):
				_abort("graphical evidence requires real-time unmodified frame pacing")
				return
	_frame_usec.resize(FRAME_CAPACITY)
	_monitors.resize(5)
	_sandbox = SANDBOX.instantiate() as Node3D
	_sandbox.set(&"room_config", ROOM)
	var definitions: Array[EffectRuleData] = [
		preload("res://tests/fixtures/effects/count_hit.tres"),
		preload("res://tests/fixtures/effects/min_damage.tres"),
		preload("res://tests/fixtures/effects/refuse_damage.tres"),
		preload("res://tests/fixtures/effects/cooldown_hit.tres")]
	_sandbox.set(&"effect_definitions", definitions)
	var player_node: FPSController = _sandbox.get_node(^"Player") as FPSController
	player_node.hardware_input_enabled = false
	(player_node.get_node(^"Camera3D/HitscanWeapon") as HitscanWeapon).hardware_input_enabled = false
	add_child(_sandbox)
	_combat = _sandbox.get(&"combat") as RoomCombat
	_batch = _sandbox.get(&"shots") as ShotBatch
	_resolver = _sandbox.get(&"resolver") as ShotResolver
	_effects = _sandbox.get(&"effects") as EffectRunner
	_visuals = _sandbox.get(&"visuals") as ShotVisualPool
	_mobility = _sandbox.get(&"mobility") as MobilityRuntime
	if _combat == null or _resolver == null or _effects == null:
		_abort("Sandbox initialization failed")
		return
	_player = _sandbox.get(&"player_handle")
	var host: EffectHost = _sandbox.get(&"effect_host") as EffectHost
	for index: int in definitions.size():
		host.add_effect(_player, EffectTrigger.Trigger.ON_HIT, EffectTrigger.Phase.MAIN, index, index, index, index)
	# The scene's targets plus extra entities make forty status targets; all cold.
	_targets = (_sandbox.get(&"target_handles") as PackedInt64Array).duplicate()
	while _targets.size() < TARGETS:
		var entity: int = _combat.stats.allocate()
		if entity == StatBlock.INVALID_HANDLE or not _combat.statuses.register_target(entity):
			_abort("target allocation failed")
			return
		_targets.append(entity)
	for target: int in _targets:
		_combat.stats.set_stat(target, StatBlock.Stat.MAX_HP, TARGET_HP)
		_combat.stats.set_stat(target, StatBlock.Stat.HP, TARGET_HP)
		_combat.stats.set_stat(target, StatBlock.Stat.ARMOR, TARGET_ARMOR)
	_driver = Driver.new()
	_driver.benchmark = self
	_driver.process_physics_priority = -100
	add_child(_driver)
	print("STATUS_PIPELINE setup: targets=%d sources=1 warmup=%d measure=%d hosts=%d event_capacity=%d quota=%d status_packed=%d inject_leak=%s" % [
		_targets.size(), WARMUP_TICKS, MEASURE_TICKS, _combat.config.host_capacity,
		_combat.config.effect_event_capacity(), _combat.config.effect_work_quota(),
		_combat.statuses.packed_bytes(), _inject_leak])
	print("STATUS_PIPELINE render: display=%s method=%s driver=%s gpu=%s resolution=%s vsync=%d graphical=%s" % [
		DisplayServer.get_name(), RenderingServer.get_current_rendering_method(),
		RenderingServer.get_current_rendering_driver_name(), RenderingServer.get_video_adapter_name(),
		get_viewport().get_visible_rect().size, DisplayServer.window_get_vsync_mode(), _graphical])


func _publish_shot() -> void:
	if _done:
		return
	var group: int = _published % (TARGETS / GROUP)
	var element: int = ELEMENTS[(_published / (TARGETS / GROUP)) % ELEMENTS.size()]
	var ticket: int = _batch.reserve(_player, GROUP, RAW_DAMAGE, element as DamagePayload.Element)
	if ticket == ShotBatch.INVALID:
		return
	for pellet: int in GROUP:
		_batch.write_trace(ticket, pellet, _targets[group * GROUP + pellet])
	_batch.publish(ticket)
	_published += 1


func _physics_process(_delta: float) -> void:
	if _done or _driver == null:
		return
	_physics_ticks += 1
	if _physics_ticks == WARMUP_TICKS:
		_capture_baseline()
	elif _measuring:
		var logic_tick: int = GameLoop.get_logic_tick()
		if logic_tick != _last_logic_tick:
			_last_logic_tick = logic_tick
			var usec: int = GameLoop.get_last_logic_tick_usec()
			_logic_samples += 1
			_logic_sum += usec
			_logic_max = maxi(_logic_max, usec)
		if _physics_ticks == WARMUP_TICKS + MEASURE_TICKS:
			_finish()


func _process(_delta: float) -> void:
	if not _measuring or _done:
		return
	var now: int = Time.get_ticks_usec()
	if _last_frame_usec != 0 and _frame_count < _frame_usec.size():
		_frame_usec[_frame_count] = now - _last_frame_usec
		_frame_sum += now - _last_frame_usec
		_frame_count += 1
	_last_frame_usec = now


## [hits, pulses, statuses applied, pulse damage, effect events, effect actions]
func _activity() -> PackedInt64Array:
	return PackedInt64Array([_resolver.registered_hits, _combat.statuses.processed_pulses,
			_combat.statuses.applied_statuses, _combat.statuses.pulse_hp_damage,
			_effects.processed_events, _effects.executed_actions])


func _capture_baseline() -> void:
	_monitors[0] = _monitor(Performance.OBJECT_COUNT)
	_monitors[1] = _monitor(Performance.OBJECT_NODE_COUNT)
	_monitors[2] = _monitor(Performance.OBJECT_RESOURCE_COUNT)
	_monitors[3] = _monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	_monitors[4] = _monitor(Performance.MEMORY_STATIC)
	_baseline = _activity()
	_last_logic_tick = GameLoop.get_logic_tick()
	_sandbox.call(&"reset_phase_metrics")
	_measuring = true


func _finish() -> void:
	# Every monitor is read before output, sorting and cleanup.
	var objects: int = _monitor(Performance.OBJECT_COUNT) - _monitors[0]
	var nodes: int = _monitor(Performance.OBJECT_NODE_COUNT) - _monitors[1]
	var resources: int = _monitor(Performance.OBJECT_RESOURCE_COUNT) - _monitors[2]
	var orphans: int = _monitor(Performance.OBJECT_ORPHAN_NODE_COUNT) - _monitors[3]
	var memory: int = _monitor(Performance.MEMORY_STATIC) - _monitors[4]
	_done = true
	var activity: PackedInt64Array = _activity()
	for index: int in activity.size():
		activity[index] -= _baseline[index]
	var errors: int = _combat.statuses.configuration_errors + _batch.configuration_errors \
			+ _resolver.damage_configuration_errors() + _effects.configuration_errors + _visuals.configuration_errors
	var dropped: int = _effects.dropped_events + _mobility.landings.dropped_count() + _visuals.dropped_count
	var refusals: int = _resolver.contexts.capacity_refusals + _resolver.contexts.hit_set_overflows \
			+ _resolver.contexts.budget_refusals + _resolver.contexts.depth_refusals \
			+ (_sandbox.get(&"effect_host") as EffectHost).capacity_refusals
	var steps: int = _sandbox.call(&"phase_steps")
	get_tree().paused = true
	var failures := PackedStringArray()
	if objects != 0 or nodes != 0 or resources != 0 or orphans != 0:
		failures.append("object/node/resource/orphan growth")
	if memory > MEMORY_LIMIT:
		failures.append("static memory exceeds 1 MiB")
	if _logic_samples != MEASURE_TICKS / 2 or steps != MEASURE_TICKS / 2:
		failures.append("logic sampling incomplete")
	if _logic_max > LOGIC_LIMIT_USEC:
		failures.append("logic tick max %d us exceeds the 7000 us budget" % _logic_max)
	if activity[0] != MEASURE_TICKS / 2 * GROUP or activity[1] <= 0 or activity[2] <= 0 or activity[4] <= 0:
		failures.append("status workload inactive")
	if _combat.statuses.active_count() != TARGETS:
		failures.append("not every target carries statuses")
	if errors != 0 or dropped != 0 or refusals != 0:
		failures.append("pipeline diagnostics are nonzero")
	if _effects.pending_count() != 0 or _effects.deferred_steps != 0 or _resolver.contexts.alive_count() != 0:
		failures.append("pipeline is not quiescent or deferred effect work")
	print("STATUS_PIPELINE allocations: objects=%+d nodes=%+d resources=%+d orphans=%+d memory_static=%+d B" % [
		objects, nodes, resources, orphans, memory])
	print("STATUS_PIPELINE activity: hits=%d pulses=%d statuses_applied=%d pulse_damage=%d effect_events=%d effect_actions=%d active=%d kills=%d" % [
		activity[0], activity[1], activity[2], activity[3], activity[4], activity[5],
		_combat.statuses.active_count(), _resolver.kills + _combat.statuses.pulse_kills])
	print("STATUS_PIPELINE logic: samples=%d avg=%.1f us max=%d us limit=%d us" % [
		_logic_samples, float(_logic_sum) / maxf(1.0, float(_logic_samples)), _logic_max, LOGIC_LIMIT_USEC])
	var line: String = "STATUS_PIPELINE phases: steps=%d" % steps
	for phase: int in PHASE_NAMES.size():
		line += " %s avg=%.1f p99<=%d max=%d" % [PHASE_NAMES[phase],
			float(int(_sandbox.call(&"phase_sum_usec", phase))) / maxf(1.0, float(steps)),
			int(_sandbox.call(&"phase_percentile_usec", phase, 990)), int(_sandbox.call(&"phase_max_usec", phase))]
	print(line + " us")
	print("STATUS_PIPELINE diagnostics: configuration=%d dropped=%d refusals=%d pending_effects=%d deferred=%d contexts=%d" % [
		errors, dropped, refusals, _effects.pending_count(), _effects.deferred_steps, _resolver.contexts.alive_count()])
	_report_frames()
	if _leaked != null:
		_leaked.free()
		_leaked = null
		print("STATUS_PIPELINE leak_cleanup: objects=%+d orphans=%+d" % [
			_monitor(Performance.OBJECT_COUNT) - _monitors[0], _monitor(Performance.OBJECT_ORPHAN_NODE_COUNT) - _monitors[3]])
	for failure: String in failures:
		printerr("STATUS_PIPELINE FAIL: " + failure)
	print("STATUS_PIPELINE RESULT: " + ("PASS" if failures.is_empty() else "FAIL"))
	get_tree().quit(0 if failures.is_empty() else 1)


func _report_frames() -> void:
	if _frame_count == 0:
		return
	_frame_usec.resize(_frame_count)
	_frame_usec.sort()
	print("STATUS_PIPELINE frames: graphical=%s samples=%d mean_fps=%.3f p95_us=%d p99_us=%d worst_us=%d" % [
		_graphical, _frame_count, float(_frame_count) * 1000000.0 / maxf(1.0, float(_frame_sum)),
		_frame_usec[int((_frame_count - 1) * 0.95)], _frame_usec[int((_frame_count - 1) * 0.99)],
		_frame_usec[_frame_count - 1]])


func _abort(reason: String) -> void:
	_done = true
	printerr("STATUS_PIPELINE SETUP ERROR: " + reason)
	get_tree().quit(2)


static func _monitor(monitor: Performance.Monitor) -> int:
	return int(Performance.get_monitor(monitor))
