class_name RealPipelineBenchmark
extends Node
## Real engine callbacks only: driven commands -> Jolt -> Sandbox's one subscriber.

const SANDBOX: PackedScene = preload("res://world/sandbox/Sandbox.tscn")
const FRAME_CAPACITY: int = 120000
const TARGET_HP: int = 20000000

var result: RealPipelineResult = RealPipelineResult.new()
var _sandbox: Node3D
var _player: FPSController
var _camera: Camera3D
var _weapon: HitscanWeapon
var _mobility: MobilityRuntime
var _resolver: ShotResolver
var _batch: ShotBatch
var _visuals: ShotVisualPool
var _target: int
var _driver: InputDriver
var _baseline: PackedInt64Array = PackedInt64Array()
var _occupancy: int = 0
var _objects: int = 0
var _nodes: int = 0
var _resources: int = 0
var _orphans: int = 0
var _memory: int = 0
var _last_logic_tick: int = 0
var _position: Vector3
var _yaw: float = 0.0
var _ground_jumps: int = 0
var _signal_damage: int = 0
var _inject_leak: bool = false
var _leaked: Node
var _capture_path: String = ""
var _done: bool = false
var _measuring: bool = false
var _frame_usec: PackedInt64Array = PackedInt64Array()
var _frame_count: int = 0
var _frame_usec_sum: int = 0
var _frame_overflows: int = 0
var _measure_start_usec: int = 0
var _last_frame_usec: int = 0


class InputDriver extends Node:
	var benchmark: RealPipelineBenchmark
	var ticks: int = 0
	var ground_jump_requested: bool = false


	func _physics_process(_delta: float) -> void:
		ticks += 1
		var phase: int = ticks % 240
		var direction: float = 1.0 if (ticks / 240) % 2 == 0 else -1.0
		benchmark._player.set_move_input(Vector2(direction, 0.0))
		ground_jump_requested = phase == 2 and benchmark._player.is_on_floor()
		benchmark._player.set_jump_pressed(phase == 2 or phase == 14)
		benchmark._player.set_dash_pressed(phase == 28 or phase == 170)
		benchmark._player.set_slide_pressed(phase == 120)
		benchmark._player.add_look_input(Vector2(0.2 if ticks % 2 == 0 else -0.2, 0.0))
		benchmark._weapon.set_fire_pressed(ticks % 30 == 1)
		if benchmark._inject_leak and ticks == RealPipelineResult.WARMUP_TICKS + 1:
			benchmark._leaked = Node.new()  # Deliberate negative probe, cleaned after capture.


func _ready() -> void:
	process_physics_priority = 1200
	for argument: String in OS.get_cmdline_user_args():
		if argument == "--inject-leak":
			_inject_leak = true
		elif argument.begins_with("--capture="):
			_capture_path = argument.trim_prefix("--capture=")
		else:
			_abort("unknown option: " + argument)
			return
	if Engine.physics_ticks_per_second != 60 or Engine.time_scale != 1.0:
		_abort("requires 60 Hz physics and time_scale 1")
		return
	result.graphical = DisplayServer.get_name() != "headless"
	if result.graphical:
		for argument: String in OS.get_cmdline_args():
			if argument == "--fixed-fps" or argument.begins_with("--fixed-fps=") \
					or argument == "--time-scale" or argument.begins_with("--time-scale=") \
					or argument == "--max-fps" or argument.begins_with("--max-fps="):
				_abort("graphical evidence requires real-time unmodified frame pacing")
				return
	if not _capture_path.is_empty() and not result.graphical:
		_abort("capture requires graphical rendering")
		return
	_baseline.resize(RealPipelineResult.Counter.COUNT)
	_frame_usec.resize(FRAME_CAPACITY)
	_sandbox = SANDBOX.instantiate() as Node3D
	_player = _sandbox.get_node(^"Player") as FPSController
	_player.hardware_input_enabled = false
	_camera = _player.get_node(^"Camera3D") as Camera3D
	_weapon = _camera.get_node(^"HitscanWeapon") as HitscanWeapon
	_weapon.hardware_input_enabled = false
	_prepare_geometry()
	add_child(_sandbox)
	_mobility = _sandbox.get(&"mobility") as MobilityRuntime
	_resolver = _sandbox.get(&"resolver") as ShotResolver
	_batch = _sandbox.get(&"shots") as ShotBatch
	_visuals = _sandbox.get(&"visuals") as ShotVisualPool
	if _mobility == null or _resolver == null or not _weapon.is_initialized():
		_abort("Sandbox initialization failed")
		return
	var targets: PackedInt64Array = _sandbox.get(&"target_handles")
	_target = targets[1]
	_mobility.stats.set_stat(_target, StatBlock.Stat.MAX_HP, TARGET_HP)
	_mobility.stats.set_stat(_target, StatBlock.Stat.HP, TARGET_HP)
	_resolver.on_hit.connect(_on_hit)
	_driver = InputDriver.new()
	_driver.benchmark = self
	_driver.process_physics_priority = -100
	add_child(_driver)
	_position = _player.global_position
	_yaw = _player.rotation.y
	print("REAL_PIPELINE setup: warmup=300 measure=3600 physics_hz=60 simulated_seconds=60 inject_leak=%s" % _inject_leak)
	print("REAL_PIPELINE render: display=%s method=%s driver=%s gpu=%s resolution=%s vsync=%d graphical=%s" % [
		DisplayServer.get_name(), RenderingServer.get_current_rendering_method(),
		RenderingServer.get_current_rendering_driver_name(), RenderingServer.get_video_adapter_name(),
		get_viewport().get_visible_rect().size, DisplayServer.window_get_vsync_mode(), result.graphical])


## Replace only benchmark-instance geometry while loading; shared definitions stay frozen.
func _prepare_geometry() -> void:
	var floor_body: StaticBody3D = _sandbox.get_node(^"Floor") as StaticBody3D
	_replace_box(floor_body, Vector3(200.0, 1.0, 200.0))
	var center: StaticBody3D = _sandbox.get_node(^"Targets/TargetCenter") as StaticBody3D
	center.position.y = 6.0
	_replace_box(center, Vector3(100.0, 12.0, 0.5))
	for path: NodePath in [^"Targets/TargetLeft", ^"Targets/TargetRight", ^"Slope", ^"Platform"]:
		var body: StaticBody3D = _sandbox.get_node(path) as StaticBody3D
		body.collision_layer = 0
		body.visible = false


func _replace_box(body: StaticBody3D, size: Vector3) -> void:
	var shape := BoxShape3D.new()
	shape.size = size
	(body.get_node(^"CollisionShape3D") as CollisionShape3D).shape = shape
	var visual: MeshInstance3D = body.get_node(^"MeshInstance3D") as MeshInstance3D
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = visual.mesh.surface_get_material(0)
	visual.mesh = mesh


func _on_hit(_source: int, _target_handle: int, _epoch: int, _sequence: int,
		_trace: int, _child: int, hp_damage: int) -> void:
	_signal_damage += hp_damage


func _physics_process(_delta: float) -> void:
	if _done or _driver == null:
		return
	if _driver.ground_jump_requested and _player.velocity.y > 0.0:
		_ground_jumps += 1
	if _driver.ticks == RealPipelineResult.WARMUP_TICKS:
		_capture_baseline()
	elif _measuring:
		result.measured_ticks += 1
		result.distance += _player.global_position.distance_to(_position)
		result.peak_abs_x = maxf(result.peak_abs_x, absf(_player.global_position.x))
		result.look_radians += absf(_player.rotation.y - _yaw)
		var logic_tick: int = GameLoop.get_logic_tick()
		if logic_tick != _last_logic_tick:
			_last_logic_tick = logic_tick
			var usec: int = GameLoop.get_last_logic_tick_usec()
			result.logic_samples += 1
			result.logic_usec_sum += usec
			result.logic_usec_max = maxi(result.logic_usec_max, usec)
		if result.measured_ticks == RealPipelineResult.MEASURE_TICKS:
			_finish()
	_position = _player.global_position
	_yaw = _player.rotation.y


func _capture_baseline() -> void:
	_objects = _monitor(Performance.OBJECT_COUNT)
	_nodes = _monitor(Performance.OBJECT_NODE_COUNT)
	_resources = _monitor(Performance.OBJECT_RESOURCE_COUNT)
	_orphans = _monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	_memory = _monitor(Performance.MEMORY_STATIC)
	for index: int in _baseline.size():
		_baseline[index] = _counter(index)
	_occupancy = _visual_occupancy()
	_last_logic_tick = GameLoop.get_logic_tick()
	result.warmup_ticks = _driver.ticks
	_measure_start_usec = Time.get_ticks_usec()
	_measuring = true


func _counter(index: int) -> int:
	match index:
		RealPipelineResult.Counter.SHOTS: return _weapon.state.accepted_shots
		RealPipelineResult.Counter.TRACES: return _weapon.traces_cast
		RealPipelineResult.Counter.HITS: return _resolver.registered_hits
		RealPipelineResult.Counter.RESOLVED: return _resolver.resolved_shots
		RealPipelineResult.Counter.TARGET_DAMAGE: return TARGET_HP - _mobility.stats.get_stat(_target, StatBlock.Stat.HP)
		RealPipelineResult.Counter.SIGNAL_DAMAGE: return _signal_damage
		RealPipelineResult.Counter.DASH: return _player.dash_activations
		RealPipelineResult.Counter.SLIDE: return _player.slide_activations
		RealPipelineResult.Counter.DOUBLE_JUMP: return _player.double_jump_activations
		RealPipelineResult.Counter.LANDINGS: return _player.landing_events
		RealPipelineResult.Counter.RESOLVED_LANDINGS: return _mobility.resolved_landings
		RealPipelineResult.Counter.MOBILITY_STEPS: return _mobility.logic_steps
		RealPipelineResult.Counter.SHOT_STEPS: return _resolver.logic_steps
		RealPipelineResult.Counter.GROUND_JUMPS: return _ground_jumps
		RealPipelineResult.Counter.MUZZLES: return _visuals.emitted_muzzles
		RealPipelineResult.Counter.IMPACTS: return _visuals.emitted_impacts
		RealPipelineResult.Counter.MARKS: return _visuals.emitted_marks
		RealPipelineResult.Counter.EXPIRED: return _visuals.expired_count
		RealPipelineResult.Counter.REUSED: return _visuals.reused_count
	return 0


func _visual_occupancy() -> int:
	return _visuals.active_count(ShotVisualPool.Kind.MUZZLE) \
			+ _visuals.active_count(ShotVisualPool.Kind.IMPACT) + _visuals.active_count(ShotVisualPool.Kind.MARK)


func _process(_delta: float) -> void:
	if not _measuring or _done:
		return
	var now_usec: int = Time.get_ticks_usec()
	if _last_frame_usec == 0:
		_last_frame_usec = now_usec
		return
	var usec: int = now_usec - _last_frame_usec
	_last_frame_usec = now_usec
	if _frame_count < _frame_usec.size():
		_frame_usec[_frame_count] = usec
		_frame_count += 1
		_frame_usec_sum += usec
	else:
		_frame_overflows += 1


func _finish() -> void:
	# All allocation monitors precede output, sorting, cleanup, image capture and signals.
	result.objects_delta = _monitor(Performance.OBJECT_COUNT) - _objects
	result.nodes_delta = _monitor(Performance.OBJECT_NODE_COUNT) - _nodes
	result.resources_delta = _monitor(Performance.OBJECT_RESOURCE_COUNT) - _resources
	result.orphans_delta = _monitor(Performance.OBJECT_ORPHAN_NODE_COUNT) - _orphans
	result.memory_delta = _monitor(Performance.MEMORY_STATIC) - _memory
	_done = true
	for index: int in _baseline.size():
		result.counters[index] = _counter(index) - _baseline[index]
	result.configuration_errors = _batch.configuration_errors + _visuals.configuration_errors + _frame_overflows \
			+ _resolver.damage_configuration_errors()
	result.dropped = _mobility.landings.dropped_count() + _visuals.dropped_count
	result.refusals = _resolver.contexts.capacity_refusals + _resolver.contexts.hit_set_overflows \
			+ _resolver.contexts.budget_refusals + _resolver.contexts.depth_refusals
	result.stale_landings = _mobility.stale_landings
	result.no_op_traces = _resolver.no_op_traces
	result.kills = _resolver.kills
	result.pending_shots = _batch.pending_count() + _batch.count()
	result.pending_landings = _mobility.landings.count()
	result.live_contexts = _resolver.contexts.alive_count()
	result.visual_occupancy_delta = _visual_occupancy() - _occupancy
	result.frame_fps_mean = float(_frame_count) * 1000000.0 / maxf(1.0, float(_frame_usec_sum))
	get_tree().paused = true
	var failures: PackedStringArray = result.failures()
	print("REAL_PIPELINE allocations: objects=%+d nodes=%+d resources=%+d orphans=%+d memory_static=%+d B" % [
		result.objects_delta, result.nodes_delta, result.resources_delta, result.orphans_delta, result.memory_delta])
	print("REAL_PIPELINE actions: shots=%d traces=%d hits=%d resolved=%d damage=%d signal_damage=%d dash=%d slide=%d double=%d landing=%d ground_jump=%d distance=%.2f peak_x=%.2f look=%.4f" % [
		result.counters[0], result.counters[1], result.counters[2], result.counters[3], result.counters[4], result.counters[5],
		result.counters[6], result.counters[7], result.counters[8], result.counters[9], result.counters[13],
		result.distance, result.peak_abs_x, result.look_radians])
	print("REAL_PIPELINE visuals: muzzle=%d impact=%d mark=%d expired=%d reused=%d occupancy_delta=%d" % [
		result.counters[14], result.counters[15], result.counters[16], result.counters[17], result.counters[18], result.visual_occupancy_delta])
	print("REAL_PIPELINE logic: samples=%d avg=%.1f us max=%d us limit=7000 us scope=M1_fixture" % [
		result.logic_samples, float(result.logic_usec_sum) / maxf(1.0, float(result.logic_samples)), result.logic_usec_max])
	print("REAL_PIPELINE diagnostics: configuration=%d dropped=%d refusals=%d stale=%d noops=%d kills=%d pending=%d landings=%d contexts=%d" % [
		result.configuration_errors, result.dropped, result.refusals, result.stale_landings, result.no_op_traces,
		result.kills, result.pending_shots, result.pending_landings, result.live_contexts])
	_report_frames()
	print("REAL_PIPELINE physics: warmup=%d measured=%d wall_ms=%.1f" % [result.warmup_ticks, result.measured_ticks,
		float(Time.get_ticks_usec() - _measure_start_usec) / 1000.0])
	if _leaked != null:
		_leaked.free()
		_leaked = null
		print("REAL_PIPELINE leak_cleanup: objects=%+d orphans=%+d" % [
			_monitor(Performance.OBJECT_COUNT) - _objects, _monitor(Performance.OBJECT_ORPHAN_NODE_COUNT) - _orphans])
	if not _capture_path.is_empty():
		await RenderingServer.frame_post_draw
		var captured: Image = get_viewport().get_texture().get_image()
		if captured.save_png(_capture_path) != OK:
			failures.append("post-measure screenshot failed")
	for failure: String in failures:
		printerr("REAL_PIPELINE FAIL: " + failure)
	print("REAL_PIPELINE RESULT: " + ("PASS" if failures.is_empty() else "FAIL"))
	get_tree().quit(0 if failures.is_empty() else 1)


func _report_frames() -> void:
	_frame_usec.resize(_frame_count)
	_frame_usec.sort()
	var slow: int = 0
	for usec: int in _frame_usec:
		if usec > 16667:
			slow += 1
	if _frame_count > 0:
		print("REAL_PIPELINE frames: graphical=%s samples=%d mean_fps=%.3f p95_us=%d p99_us=%d worst_us=%d slow_fraction=%.5f" % [
			result.graphical, _frame_count, result.frame_fps_mean, _frame_usec[int((_frame_count - 1) * 0.95)],
			_frame_usec[int((_frame_count - 1) * 0.99)], _frame_usec[_frame_count - 1], float(slow) / float(_frame_count)])


func _abort(reason: String) -> void:
	_done = true
	printerr("REAL_PIPELINE SETUP ERROR: " + reason)
	get_tree().quit(2)


static func _monitor(monitor: Performance.Monitor) -> int:
	return int(Performance.get_monitor(monitor))
