extends GdUnitTestSuite
## Real Jolt rays and physical input edges. A post-GameLoop barrier isolates phases.

var _viewport: SubViewport
var _arena: Node3D
var _weapon: HitscanWeapon
var _mobility: MobilityRuntime
var _batch: ShotBatch
var _resolver: ShotResolver
var _barrier: StepBarrier
var _body: StaticBody3D
var _target: int
var _compose: bool = true
var _visuals: ShotVisualPool
var _captured_point: Vector3
var _captured_normal: Vector3
var _captured_sequence: int


class RoutedWeapon extends HitscanWeapon:
	var capture: bool = false


	func _has_mouse_capture() -> bool:
		return capture


class StepBarrier extends Node:
	signal stepped


	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		process_physics_priority = 1100


	func _physics_process(_delta: float) -> void:
		stepped.emit()


func before_test() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_viewport = SubViewport.new()
	_viewport.process_mode = Node.PROCESS_MODE_PAUSABLE
	_viewport.world_3d = World3D.new()
	_viewport.size = Vector2i(64, 64)
	add_child(_viewport)
	_arena = Node3D.new()
	_viewport.add_child(_arena)
	_mobility = MobilityRuntime.new(StatBlock.new(4))
	var source: int = _mobility.stats.allocate()
	_mobility.stats.set_stat(source, StatBlock.Stat.HP, 100000)
	_target = _mobility.stats.allocate()
	_mobility.stats.set_stat(_target, StatBlock.Stat.HP, 1000000)
	_batch = ShotBatch.new(4, 8, 4)
	_resolver = ShotResolver.new(_mobility.stats, _batch, 64)
	_weapon = RoutedWeapon.new()
	_weapon.hardware_input_enabled = false
	_arena.add_child(_weapon)
	assert_bool(_weapon.initialize(WeaponData.new(), _mobility.stats, _batch, source)).is_true()
	var socket := Node3D.new()
	socket.position = Vector3(0.27, -0.2, -1.2)
	_weapon.add_child(socket)
	_visuals = ShotVisualPool.new()
	_arena.add_child(_visuals)
	assert_bool(_visuals.initialize(ShotVisualData.new(), _weapon, socket, _batch.epoch)).is_true()
	_body = _box(Vector3(8.0, 8.0, 0.5), Vector3(0.0, 0.0, -10.0), 64)
	Damageable.attach(_body, _target)
	_barrier = StepBarrier.new()
	_arena.add_child(_barrier)
	_compose = true
	GameLoop.logic_tick.connect(_logic)
	await _ticks(2)


func after_test() -> void:
	get_tree().paused = false
	if GameLoop.logic_tick.is_connected(_logic):
		GameLoop.logic_tick.disconnect(_logic)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	Input.action_release(&"fire_primary")
	_viewport.free()


func _logic(tick: int) -> void:
	if _compose:
		_resolver.logic_step(tick)
		_mobility.logic_step(tick)


func _box(size: Vector3, position: Vector3, layer: int) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = position
	body.collision_layer = layer
	body.collision_mask = 0
	var shape := BoxShape3D.new()
	shape.size = size
	var collision := CollisionShape3D.new()
	collision.shape = shape
	body.add_child(collision)
	_arena.add_child(body)
	return body


func _ticks(count: int) -> void:
	for index: int in count:
		await _barrier.stepped


func _edge() -> void:
	_weapon.set_fire_pressed(false)
	_weapon.set_fire_pressed(true)


func _ready_to_fire() -> void:
	while GameLoop.get_logic_tick() < _weapon.state.ready_tick:
		await _ticks(1)


func test_real_eight_rays_same_tick_logic_and_semiauto_exact_cooldown() -> void:
	# An even physical step triggers GameLoop; the weapon's same-step shot must be visible.
	while GameLoop.get_physics_tick() % 2 != 1:
		await _ticks(1)
	var fired_at: int = GameLoop.get_logic_tick()
	_edge()
	await _ticks(1)
	assert_int(_weapon.traces_cast).is_equal(8)
	assert_int(_resolver.registered_hits).is_equal(8)
	assert_int(_resolver.resolved_shots).is_equal(1)
	assert_int(_weapon.state.ready_tick).is_equal(fired_at + 15)
	assert_int(_mobility.stats.get_stat(_target, StatBlock.Stat.HP)).is_equal(952000)
	await _ticks(40)
	assert_int(_weapon.state.accepted_shots).is_equal(1)
	_edge()
	await _ticks(1)
	assert_int(_weapon.state.accepted_shots).is_equal(2)
	var ready: int = _weapon.state.ready_tick
	while GameLoop.get_logic_tick() < ready - 1:
		await _ticks(1)
	_edge()
	await _ticks(1)
	assert_int(_weapon.state.accepted_shots).is_equal(2)
	await _ready_to_fire()
	assert_int(_weapon.state.accepted_shots).is_equal(2)  # refused press was consumed
	_edge()
	await _ticks(1)
	assert_int(_weapon.state.accepted_shots).is_equal(3)


func test_jolt_occlusion_miss_and_stale_handle() -> void:
	var blocker: StaticBody3D = _box(Vector3(8.0, 8.0, 0.5), Vector3(0.0, 0.0, -5.0), 1)
	await _ticks(2)
	_edge()
	await _ticks(2)
	assert_int(_resolver.registered_hits).is_equal(0)
	assert_int(_resolver.resolved_shots).is_equal(1)
	assert_int(_resolver.no_op_traces).is_equal(8)
	blocker.position.x = 50.0
	_mobility.stats.release(_target)
	var fresh: int = _mobility.stats.allocate()
	_mobility.stats.set_stat(fresh, StatBlock.Stat.HP, 100000)
	await _ready_to_fire()
	_edge()
	await _ticks(2)
	assert_int(_resolver.registered_hits).is_equal(0)
	assert_int(_mobility.stats.get_stat(fresh, StatBlock.Stat.HP)).is_equal(100000)
	_weapon.rotation.y = PI
	await _ready_to_fire()
	_edge()
	await _ticks(2)
	assert_int(_resolver.resolved_shots).is_equal(3)
	assert_int(_resolver.no_op_traces).is_equal(24)


func test_jolt_eight_trace_shot_stops_hits_after_second_pellet_death() -> void:
	_mobility.stats.set_stat(_target, StatBlock.Stat.HP, 10000)
	_edge()
	await _ticks(2)
	assert_int(_weapon.traces_cast).is_equal(8)
	assert_int(_resolver.registered_hits).is_equal(2)
	assert_int(_resolver.kills).is_equal(1)
	assert_int(_resolver.no_op_traces).is_equal(6)
	assert_int(_resolver.resolved_shots).is_equal(1)


func test_same_identity_bind_preserves_edge_cooldown_and_new_generation_clears_input() -> void:
	_weapon.set_fire_pressed(true)
	assert_bool(_weapon.bind_source(0)).is_true()
	await _ticks(2)
	assert_int(_weapon.state.accepted_shots).is_equal(1)
	var ready: int = _weapon.state.ready_tick
	assert_bool(_weapon.bind_source(0)).is_true()
	assert_int(_weapon.state.ready_tick).is_equal(ready)
	await _ready_to_fire()
	_weapon.set_fire_pressed(true)
	await _ticks(1)
	assert_int(_weapon.state.accepted_shots).is_equal(1)
	_mobility.stats.release(0)
	var fresh: int = _mobility.stats.allocate()
	_mobility.stats.set_stat(fresh, StatBlock.Stat.HP, 100000)
	assert_bool(_weapon.bind_source(fresh)).is_true()
	assert_int(_weapon.state.ready_tick).is_equal(0)
	await _ticks(1)
	assert_int(_weapon.state.accepted_shots).is_equal(0)
	_weapon.set_fire_pressed(true)
	await _ticks(2)
	assert_int(_weapon.state.accepted_shots).is_equal(1)


func test_pattern_each_trace_hits_own_central_or_ring_collider() -> void:
	_compose = false
	_body.position.x = 50.0
	var data := WeaponData.new()
	var radius: float = tan(deg_to_rad(5.0)) * 10.0
	var handles: PackedInt64Array = PackedInt64Array()
	var stats := StatBlock.new(16)
	stats.allocate()
	stats.set_stat(0, StatBlock.Stat.HP, 100000)
	var batch := ShotBatch.new(2, 8, 16)
	var weapon := HitscanWeapon.new()
	weapon.hardware_input_enabled = false
	_arena.add_child(weapon)
	weapon.initialize(data, stats, batch, 0)
	for index: int in 8:
		var position: Vector3 = Vector3(0.0, 0.0, -10.0)
		if index > 0:
			var angle: float = TAU * float(index - 1) / 7.0
			position.x = cos(angle) * radius
			position.y = sin(angle) * radius
		var body: StaticBody3D = _box(Vector3(0.12, 0.12, 0.12), position, 64)
		var handle: int = stats.allocate()
		Damageable.attach(body, handle)
		handles.append(handle)
	await _ticks(2)
	weapon.set_fire_pressed(true)
	await _ticks(1)
	assert_int(batch.prepare()).is_equal(1)
	for index: int in 8:
		assert_int(batch.target_at(0, index)).is_equal(handles[index])
	assert_int(weapon.traces_cast).is_equal(8)


func test_world_range_yaw_pitch_under_uniform_parent_scale() -> void:
	_body.position.x = 100.0
	var parent := Node3D.new()
	parent.scale = Vector3.ONE * 2.0
	parent.rotation.y = PI / 2.0
	_arena.add_child(parent)
	_weapon.reparent(parent, false)
	_weapon.rotation.x = 0.2
	var direction: Vector3 = -_weapon.global_basis.orthonormalized().z
	var far: StaticBody3D = _box(Vector3(8.0, 8.0, 8.0), direction * 50.0, 64)
	Damageable.attach(far, _target)
	await _ticks(2)
	_edge()
	await _ticks(2)
	assert_int(_resolver.registered_hits).is_equal(0)
	far.position = direction * 30.0
	await _ready_to_fire()
	_edge()
	await _ticks(2)
	assert_int(_resolver.registered_hits).is_equal(8)
	assert_int(_weapon.traces_cast).is_equal(16)


func test_full_batch_refuses_before_raycasts_and_consumes_edge() -> void:
	_compose = false
	for index: int in 4:
		_batch.reserve(0, 8, 6000)
	_edge()
	assert_error(func() -> void: _weapon._physics_process(1.0 / 60.0)).is_push_error("ShotBatch: invalid request, capacity or identity exhausted")
	await _ticks(1)
	assert_int(_weapon.traces_cast).is_equal(0)
	assert_int(_weapon.state.ready_tick).is_equal(0)
	assert_int(_weapon.state.accepted_shots).is_equal(0)
	assert_int(_batch.configuration_errors).is_equal(1)
	assert_int(_batch.pending_count()).is_equal(4)
	_batch.reset_room()
	await _ticks(1)
	assert_int(_weapon.state.accepted_shots).is_equal(0)
	_edge()
	await _ticks(1)
	assert_int(_weapon.traces_cast).is_equal(8)


func test_pause_focus_and_hardware_release_capture_policy() -> void:
	_edge()
	get_tree().paused = true
	await _ticks(2)
	_weapon.set_fire_pressed(false)
	get_tree().paused = false
	await _ticks(1)
	assert_int(_weapon.state.accepted_shots).is_equal(0)
	_weapon.set_fire_pressed(true)  # released while paused; fresh press must work directly
	await _ticks(2)
	assert_int(_weapon.state.accepted_shots).is_equal(1)
	await _ready_to_fire()
	_weapon._notification(NOTIFICATION_APPLICATION_FOCUS_OUT)
	_weapon.hardware_input_enabled = true
	var press := InputEventAction.new()
	press.action = &"fire_primary"
	press.pressed = true
	_weapon._unhandled_input(press)
	await _ticks(1)
	assert_int(_weapon.state.accepted_shots).is_equal(1)
	_weapon._notification(NOTIFICATION_APPLICATION_FOCUS_IN)
	# Inject capture intent in the test adapter; headless cannot capture an OS cursor.
	var release := InputEventAction.new()
	release.action = &"fire_primary"
	release.pressed = false
	_weapon._unhandled_input(release)
	(_weapon as RoutedWeapon).capture = true
	_weapon._unhandled_input(press)
	await _ticks(1)
	assert_int(_weapon.state.accepted_shots).is_equal(2)
	await _ready_to_fire()
	(_weapon as RoutedWeapon).capture = false
	await _ticks(1)
	_weapon._unhandled_input(release)
	(_weapon as RoutedWeapon).capture = true
	_weapon._unhandled_input(press)
	await _ticks(1)
	assert_int(_weapon.state.accepted_shots).is_equal(3)
	await _ready_to_fire()
	Input.action_press(&"fire_primary")
	get_tree().paused = true
	await _ticks(2)
	Input.action_release(&"fire_primary")
	get_tree().paused = false
	_weapon._unhandled_input(press)
	await _ticks(1)
	assert_int(_weapon.state.accepted_shots).is_equal(4)


func test_coordinated_reset_remaining_weapon_mobility_and_held_input() -> void:
	_compose = false
	_mobility.abilities.grant(0, MovementAbilityData.Kind.DASH, 1000, 30, true, true)
	_mobility.stats.set_stat(0, StatBlock.Stat.ENERGY, 3000)
	_mobility.stats.set_stat(0, StatBlock.Stat.MAX_ENERGY, 3000)
	var old_tick: int = GameLoop.get_logic_tick()
	_mobility.abilities.try_activate(0, MovementAbilityData.Kind.DASH, old_tick, false, _mobility.stats)
	_edge()
	await _ticks(1)
	old_tick = GameLoop.get_logic_tick()
	var weapon_remaining: int = _weapon.state.ready_tick - old_tick
	var mobility_remaining: int = _mobility.abilities.ready_tick(0, MovementAbilityData.Kind.DASH) - old_tick
	assert_int(_batch.count()).is_equal(1)
	_resolver.reset_room()
	_weapon.reset_clock(old_tick)
	_visuals.reset_room(_batch.epoch)
	_mobility.reset_clock(old_tick)
	GameLoop.reset_clock()
	_compose = true
	assert_int(_batch.count()).is_equal(0)
	assert_int(_weapon.state.ready_tick).is_equal(weapon_remaining)
	assert_int(_mobility.abilities.ready_tick(0, MovementAbilityData.Kind.DASH)).is_equal(mobility_remaining)
	assert_int(_mobility.stats.get_stat(0, StatBlock.Stat.ENERGY)).is_equal(2000)
	await _ticks(40)
	assert_int(_weapon.state.accepted_shots).is_equal(0)
	_edge()
	await _ticks(2)
	assert_int(_weapon.state.accepted_shots).is_equal(1)
	assert_int(_resolver.resolved_shots).is_equal(1)
	assert_int(_batch.epoch).is_equal(1)


class ActiveShotMeasure extends Node:
	signal finished
	var weapon: HitscanWeapon
	var resolver: ShotResolver
	var stats: StatBlock
	var target: int
	var visuals: ShotVisualPool
	var warmup: int = 300
	var measure: int = 3600
	var inject_leak: bool = false
	var ticks: int = 0
	var shots: int
	var traces: int
	var hits: int
	var resolved: int
	var objects_delta: int
	var nodes_delta: int
	var resources_delta: int
	var orphans_delta: int
	var memory_delta: int
	var leaked: Node
	var _objects: int
	var _nodes: int
	var _resources: int
	var _orphans: int
	var _memory: int
	var _shots: int
	var _traces: int
	var _hits: int
	var _resolved: int
	var muzzles: int
	var impacts: int
	var marks: int
	var reused: int
	var expired: int
	var _muzzles: int
	var _impacts: int
	var _marks: int
	var _reused: int
	var _expired: int


	func _ready() -> void:
		process_physics_priority = 1200


	func _physics_process(_delta: float) -> void:
		ticks += 1
		if ticks == warmup:
			_objects = int(Performance.get_monitor(Performance.OBJECT_COUNT))
			_nodes = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
			_resources = int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT))
			_orphans = int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
			_memory = int(Performance.get_monitor(Performance.MEMORY_STATIC))
			_shots = weapon.state.accepted_shots
			_traces = weapon.traces_cast
			_hits = resolver.registered_hits
			_resolved = resolver.resolved_shots
			_muzzles = visuals.emitted_muzzles
			_impacts = visuals.emitted_impacts
			_marks = visuals.emitted_marks
			_reused = visuals.reused_count
			_expired = visuals.expired_count
		if inject_leak and ticks == warmup + 1:
			leaked = Node.new()  # Deliberate instrumentation probe, never production.
		if ticks == warmup + measure:
			objects_delta = int(Performance.get_monitor(Performance.OBJECT_COUNT)) - _objects
			nodes_delta = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)) - _nodes
			resources_delta = int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)) - _resources
			orphans_delta = int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)) - _orphans
			memory_delta = int(Performance.get_monitor(Performance.MEMORY_STATIC)) - _memory
			shots = weapon.state.accepted_shots - _shots
			traces = weapon.traces_cast - _traces
			hits = resolver.registered_hits - _hits
			resolved = resolver.resolved_shots - _resolved
			muzzles = visuals.emitted_muzzles - _muzzles
			impacts = visuals.emitted_impacts - _impacts
			marks = visuals.emitted_marks - _marks
			reused = visuals.reused_count - _reused
			expired = visuals.expired_count - _expired
			set_physics_process(false)
			finished.emit()  # Capture monitors before coroutine/print/assert allocations.
			return
		if ticks % 30 == 1:
			stats.set_stat(target, StatBlock.Stat.HP, 1000000)
			weapon.set_fire_pressed(false)
			weapon.set_fire_pressed(true)


func test_active_jolt_shots_zero_allocations_300_warmup_3600_measure(_timeout: int = 120000) -> void:
	var measure := ActiveShotMeasure.new()
	measure.weapon = _weapon
	measure.resolver = _resolver
	measure.stats = _mobility.stats
	measure.target = _target
	measure.visuals = _visuals
	_arena.add_child(measure)
	await measure.finished
	print("SHOTGUN ACTIVE ticks=%d shots=%d traces=%d hits=%d resolved=%d objects=%d nodes=%d resources=%d orphans=%d memory=%d config=%d" % [
			measure.ticks, measure.shots, measure.traces, measure.hits, measure.resolved,
			measure.objects_delta, measure.nodes_delta, measure.resources_delta,
			measure.orphans_delta, measure.memory_delta, _batch.configuration_errors])
	assert_int(measure.ticks).is_equal(3900)
	assert_int(measure.shots).is_equal(120)
	assert_int(measure.traces).is_equal(960)
	assert_int(measure.hits).is_equal(960)
	assert_int(measure.resolved).is_equal(120)
	assert_int(measure.objects_delta).is_equal(0)
	assert_int(measure.nodes_delta).is_equal(0)
	assert_int(measure.resources_delta).is_equal(0)
	assert_int(measure.orphans_delta).is_equal(0)
	assert_int(measure.memory_delta).is_less_equal(1024 * 1024)
	assert_int(_batch.configuration_errors).is_equal(0)
	assert_int(_resolver.contexts.capacity_refusals).is_equal(0)
	assert_int(_resolver.contexts.hit_set_overflows).is_equal(0)
	assert_int(_resolver.contexts.budget_refusals).is_equal(0)
	print("VISUAL ACTIVE muzzles=%d impacts=%d marks=%d reused=%d expired=%d config=%d dropped=%d" % [measure.muzzles, measure.impacts, measure.marks, measure.reused, measure.expired, _visuals.configuration_errors, _visuals.dropped_count])
	assert_int(measure.muzzles).is_equal(120)
	assert_int(measure.impacts).is_equal(960)
	assert_int(measure.marks).is_equal(960)
	assert_int(measure.reused).is_greater(0)
	assert_int(measure.expired).is_equal(2040)
	assert_int(_visuals.configuration_errors).is_equal(0)
	assert_int(_visuals.dropped_count).is_equal(0)


func test_active_measure_detects_injected_orphan_leak() -> void:
	var measure := ActiveShotMeasure.new()
	measure.weapon = _weapon
	measure.resolver = _resolver
	measure.stats = _mobility.stats
	measure.target = _target
	measure.visuals = _visuals
	measure.warmup = 60
	measure.measure = 60
	measure.inject_leak = true
	_arena.add_child(measure)
	await measure.finished
	measure.leaked.free()
	assert_int(measure.objects_delta).is_equal(1)
	assert_int(measure.nodes_delta).is_equal(0)
	assert_int(measure.orphans_delta).is_equal(1)
	assert_int(measure.resources_delta).is_equal(0)
	assert_int(measure.shots).is_equal(2)
	assert_int(measure.hits).is_equal(16)
	assert_int(measure.muzzles).is_equal(2)
	assert_int(measure.marks).is_equal(16)


func _snapshot_replay() -> void:
	_captured_point = _weapon.visual_point(0)
	_captured_normal = _weapon.visual_normal(0)
	_captured_sequence = _weapon.visual_sequence()
	_visuals._on_shot_presented()  # Replay during the same live snapshot must be ignored.


func test_physical_snapshot_wall_no_handle_miss_and_duplicate_callback() -> void:
	var wall: StaticBody3D = _box(Vector3(8, 8, 0.5), Vector3(0, 0, -5), 1)
	_weapon.shot_presented.connect(_snapshot_replay)
	await _ticks(2)
	_edge()
	await _ticks(1)
	assert_int(_visuals.emitted_muzzles).is_equal(1)
	assert_int(_visuals.emitted_impacts).is_equal(8)
	assert_int(_visuals.emitted_marks).is_equal(8)
	assert_vector(_captured_point).is_equal(Vector3(0, 0, -4.75))
	assert_vector(_captured_normal).is_equal(Vector3.BACK)
	assert_int(_captured_sequence).is_equal(0)
	var decal: Decal = _visuals.node_for(_visuals.handle_at(ShotVisualPool.Kind.MARK, 0)) as Decal
	assert_vector(decal.global_position).is_equal(_captured_point)
	assert_vector(decal.global_basis.y).is_equal(_captured_normal)
	assert_bool(_weapon.has_visual_snapshot()).is_false()
	assert_vector(_weapon.visual_point(0)).is_equal(Vector3.ZERO)
	await _ticks(1)
	assert_int(_resolver.registered_hits).is_equal(0)
	wall.position.x = 50
	_weapon.rotation.y = PI
	await _ready_to_fire()
	_edge()
	await _ticks(2)
	assert_int(_visuals.emitted_muzzles).is_equal(2)
	assert_int(_visuals.emitted_marks).is_equal(8)
	assert_int(_resolver.resolved_shots).is_equal(2)


func test_dead_stale_geometry_and_new_source_identity_still_present() -> void:
	_mobility.stats.set_stat(_target, StatBlock.Stat.HP, 0)
	_edge()
	await _ticks(2)
	assert_int(_resolver.registered_hits).is_equal(0)
	assert_int(_visuals.emitted_marks).is_equal(8)
	_mobility.stats.release(_target)
	var fresh_target: int = _mobility.stats.allocate()
	_mobility.stats.set_stat(fresh_target, StatBlock.Stat.HP, 100000)
	await _ready_to_fire()
	_edge()
	await _ticks(2)
	assert_int(_visuals.emitted_marks).is_equal(16)
	assert_int(_mobility.stats.get_stat(fresh_target, StatBlock.Stat.HP)).is_equal(100000)
	_mobility.stats.release(0)
	var source: int = _mobility.stats.allocate()
	_mobility.stats.set_stat(source, StatBlock.Stat.HP, 100000)
	assert_bool(_weapon.bind_source(source)).is_true()
	_weapon.set_fire_pressed(true)
	await _ticks(2)
	assert_int(_visuals.emitted_muzzles).is_equal(3)
	assert_int(_visuals.emitted_marks).is_equal(24)
	assert_int(_visuals._show_muzzle(_batch.epoch, 0, 9)).is_equal(-1)
	assert_int(_visuals.configuration_errors).is_equal(0)


func test_pause_exact_flash_lifetime_and_room_reset_cancels_old_handles() -> void:
	_edge()
	await _ticks(1)
	var muzzle: int = _visuals.handle_at(ShotVisualPool.Kind.MUZZLE, 0)
	var mark: int = _visuals.handle_at(ShotVisualPool.Kind.MARK, 0)
	get_tree().paused = true
	await _ticks(5)
	assert_bool(_visuals.node_for(muzzle).visible).is_true()
	get_tree().paused = false
	await _ticks(2)
	assert_bool(_visuals.node_for(muzzle).visible).is_true()
	await _ticks(1)
	assert_object(_visuals.node_for(muzzle)).is_null()
	var old: int = GameLoop.get_logic_tick()
	_resolver.reset_room()
	_weapon.reset_clock(old)
	_visuals.reset_room(_batch.epoch)
	assert_bool(_visuals.release(mark)).is_false()
	assert_int(_visuals.active_count(ShotVisualPool.Kind.MARK)).is_equal(0)
	assert_int(_visuals._show_contact(0, 0, 0, Vector3.ZERO, Vector3.UP)).is_equal(-1)


class RejectPublishBatch extends ShotBatch:
	func publish(_ticket: int) -> bool:
		return false


func test_publish_rejection_aborts_record_without_visual_snapshot() -> void:
	var batch := RejectPublishBatch.new(4, 8, 4)
	var weapon := HitscanWeapon.new()
	weapon.hardware_input_enabled = false
	_arena.add_child(weapon)
	weapon.initialize(WeaponData.new(), _mobility.stats, batch, 0)
	var pool := ShotVisualPool.new()
	_arena.add_child(pool)
	pool.initialize(ShotVisualData.new(), weapon, weapon, 0)
	weapon.set_fire_pressed(true)
	assert_error(func() -> void: weapon._physics_process(1.0 / 60.0)).is_push_error("ShotBatch: invalid request, capacity or identity exhausted")
	await _ticks(2)
	assert_int(weapon.state.accepted_shots).is_equal(1)
	assert_int(weapon.traces_cast).is_equal(8)
	assert_int(batch.pending_count()).is_equal(0)
	assert_int(batch.count()).is_equal(0)
	assert_int(batch.configuration_errors).is_equal(1)
	assert_bool(weapon.has_visual_snapshot()).is_false()
	assert_int(pool.emitted_muzzles).is_equal(0)
	assert_int(pool.emitted_marks).is_equal(0)


func test_visual_overflow_does_not_change_damage_or_cooldown() -> void:
	for index: int in 40:
		_visuals._show_contact(0, 0, 0, Vector3.ZERO, Vector3.UP)
	# Report once through a direct request so the physics callback has no unexpected log.
	assert_error(func() -> void: _visuals._show_contact(0, 0, 0, Vector3.ZERO, Vector3.UP)).is_push_error("ShotVisualPool: invalid contact or visual capacity exhausted")
	var fired_at: int = GameLoop.get_logic_tick()
	_edge()
	await _ticks(2)
	assert_int(_resolver.registered_hits).is_equal(8)
	assert_int(_mobility.stats.get_stat(_target, StatBlock.Stat.HP)).is_equal(952000)
	assert_int(_weapon.state.ready_tick).is_equal(fired_at + 15)
	assert_int(_visuals.configuration_errors).is_equal(9)
	assert_int(_visuals.emitted_marks).is_equal(40)
	assert_int(_visuals.emitted_muzzles).is_equal(1)


func test_floor_contact_normal_and_uniform_scale_world_placement() -> void:
	_body.position.x = 100
	var floor_body: StaticBody3D = _box(Vector3(10, 0.5, 10), Vector3(0, -5, 0), 1)
	var parent := Node3D.new()
	parent.scale = Vector3.ONE * 2
	_arena.add_child(parent)
	_weapon.reparent(parent, false)
	_weapon.rotation.x = -PI / 2
	_weapon.shot_presented.connect(_snapshot_replay)
	await _ticks(2)
	_edge()
	await _ticks(1)
	assert_vector(_captured_normal).is_equal(Vector3.UP)
	assert_float(_captured_point.y).is_equal_approx(-4.75, 0.0001)
	var decal: Decal = _visuals.node_for(_visuals.handle_at(ShotVisualPool.Kind.MARK, 0)) as Decal
	assert_vector(decal.global_position).is_equal(_captured_point)
	assert_vector(decal.global_basis.y).is_equal(Vector3.UP)
	assert_float(decal.global_basis.x.length()).is_equal_approx(1.0, 0.00001)
	assert_int(_visuals.emitted_marks).is_equal(8)
	assert_object(floor_body).is_not_null()


func test_expiry_before_weapon_reuses_capacity_in_same_physics_tick() -> void:
	for index: int in 5:
		_visuals._show_muzzle(0, 0, 0)
	await _ticks(2)
	assert_int(_visuals.active_count(ShotVisualPool.Kind.MUZZLE)).is_equal(5)
	_edge()
	await _ticks(1)
	assert_int(_visuals.process_physics_priority).is_equal(5)
	assert_int(_weapon.process_physics_priority).is_equal(10)
	assert_int(_visuals.active_count(ShotVisualPool.Kind.MUZZLE)).is_equal(1)
	assert_int(_visuals.expired_count).is_equal(5)
	assert_int(_visuals.reused_count).is_equal(1)
	assert_int(_weapon.state.accepted_shots).is_equal(1)
	assert_int(_visuals.configuration_errors).is_equal(0)
