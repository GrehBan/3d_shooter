extends Node3D
## Composition root. Content and stores allocate only while loading the sandbox.

var combat: RoomCombat
var mobility: MobilityRuntime
var player_handle: int = StatBlock.INVALID_HANDLE
@export_dir var movement_data_directory: String = "res://data/movement"
@export_dir var weapon_data_directory: String = "res://data/weapons"
@export var visual_data: ShotVisualData = preload("res://data/visuals/shotgun.tres")
@export var effect_definitions: Array[EffectRuleData] = []
## Identity passed to EventBus.room_entered on successful load and room reset.
@export var room_id: int = 0
const ROOM_SHOTS: int = 4
const ROOM_TRACE_CAP: int = 32
const ROOM_PACKED_BYTES: int = 131_072
const ROOM_HOSTS: int = 16
const ROOM_CONTEXTS: int = 64
const ROOM_DEFERRED_RESERVE: int = 16
const ROOM_VISUAL_NODES: int = 128
const ROOM_VISUAL_PACKED_BYTES: int = 16384
const ROOM_VISUAL_TEXTURE_BYTES: int = 32768
const ROOM_EFFECT_ENTRIES: int = 64
const ROOM_EFFECT_PACKED_BYTES: int = 32768
# EffectHost: heads, owner/host lists, HandlePool and ten int32 + one int64 columns.
const ROOM_EFFECT_HOST_BYTES: int = ROOM_HOSTS * (EffectTrigger.TRIGGER_COUNT * 4 + 12) \
		+ ROOM_EFFECT_ENTRIES * 57
var effect_host: EffectHost
var effects: EffectRunner
var shots: ShotBatch
var resolver: ShotResolver
var weapon: HitscanWeapon
var visuals: ShotVisualPool
var target_handles: PackedInt64Array = PackedInt64Array()
var _target_meshes: Array[MeshInstance3D] = []
var _dead_material: StandardMaterial3D
# Kill events mark targets here; the frame applies the defeated look.
var _dead_pending: PackedByteArray = PackedByteArray()
var _dead_dirty: bool = false
## Diagnostic logic-phase timing (resolver, effects, mobility), outside the deterministic
## contour: only benchmarks read it, gameplay logic never does.
enum Phase { RESOLVER, EFFECTS, MOBILITY }
const PHASE_COUNT: int = 3
var _phase_last: PackedInt64Array = PackedInt64Array([0, 0, 0])
var _phase_max: PackedInt64Array = PackedInt64Array([0, 0, 0])
var _phase_sum: PackedInt64Array = PackedInt64Array([0, 0, 0])
var _phase_steps: int = 0
## Per-phase histogram of PHASE_BUCKETS buckets of PHASE_BUCKET_USEC each (last bucket
## collects everything slower), preallocated so recording a tick never allocates.
const PHASE_BUCKET_USEC: int = 10
const PHASE_BUCKETS: int = 1000
var _phase_histogram: PackedInt32Array = _zeroes(PHASE_COUNT * PHASE_BUCKETS)


func _ready() -> void:
	var registry := Registry.new()
	var category: int = registry.add_category(&"movement", preload("res://player/MovementAbilityData.gd"))
	if registry.load_directory(category, movement_data_directory) != 3:
		_abort_initialization("Sandbox: three movement definitions required")
		return
	var weapon_category: int = registry.add_category(&"weapon", preload("res://weapons/WeaponData.gd"))
	if registry.load_directory(weapon_category, weapon_data_directory) != 1:
		_abort_initialization("Sandbox: one weapon definition required")
		return
	registry.freeze()
	var definitions: Array[WeaponData] = []
	for id: int in registry.count(weapon_category):
		definitions.append(registry.get_resource(weapon_category, id) as WeaponData)
	var stride: int = WeaponData.validate_room(definitions, ROOM_SHOTS, ROOM_TRACE_CAP,
			ROOM_PACKED_BYTES, ROOM_HOSTS, ROOM_CONTEXTS, ROOM_DEFERRED_RESERVE)
	if stride < 0:
		_abort_initialization("Sandbox: invalid weapon preset or room capacity")
		return
	if not ShotVisualData.validate_room(visual_data, definitions, ROOM_SHOTS, stride,
			1, ROOM_VISUAL_NODES, ROOM_VISUAL_PACKED_BYTES, ROOM_VISUAL_TEXTURE_BYTES):
		_abort_initialization("Sandbox: invalid visual preset or room capacity")
		return
	combat = RoomCombat.new(ROOM_HOSTS)
	if not combat.is_initialized():
		_abort_initialization("Sandbox: invalid room combat capacity")
		return
	mobility = MobilityRuntime.new(combat.stats)
	if not mobility.is_initialized():
		_abort_initialization("Sandbox: mobility runtime requires the room StatBlock")
		return
	effect_host = EffectHost.new(ROOM_HOSTS, ROOM_EFFECT_ENTRIES)
	effects = EffectRunner.new(combat.stats, effect_host, effect_definitions)
	if not effects.is_initialized() or effects.packed_bytes() + ROOM_EFFECT_HOST_BYTES > ROOM_EFFECT_PACKED_BYTES:
		_abort_initialization("Sandbox: invalid effect definitions or room capacity")
		return
	player_handle = combat.stats.allocate()
	combat.stats.set_stat(player_handle, StatBlock.Stat.MAX_HP, 100_000)
	combat.stats.set_stat(player_handle, StatBlock.Stat.HP, 100_000)
	combat.stats.set_stat(player_handle, StatBlock.Stat.ENERGY, 3000)
	combat.stats.set_stat(player_handle, StatBlock.Stat.MAX_ENERGY, 3000)
	if not mobility.grant_content(player_handle, registry, category):
		_abort_initialization("Sandbox: movement grant failed")
		return
	(get_node(^"Player") as FPSController).bind_mobility(mobility, player_handle)
	shots = ShotBatch.new(ROOM_SHOTS, stride, ROOM_HOSTS)
	resolver = ShotResolver.new(combat.stats, shots, ROOM_CONTEXTS)
	resolver.on_hit.connect(_on_hit)
	resolver.on_kill.connect(_on_kill)
	weapon = get_node(^"Player/Camera3D/HitscanWeapon") as HitscanWeapon
	if not weapon.initialize(definitions[0], combat.stats, shots, player_handle, get_node(^"Player") as FPSController):
		_abort_initialization("Sandbox: weapon initialization failed")
		return
	visuals = get_node(^"ShotVisualPool") as ShotVisualPool
	if not visuals.initialize(visual_data, weapon, weapon.get_node(^"Viewmodel/MuzzleSocket") as Node3D, shots.epoch):
		_abort_initialization("Sandbox: visual initialization failed")
		return
	for body: Node in get_node(^"Targets").get_children():
		var target: int = combat.stats.allocate()
		combat.stats.set_stat(target, StatBlock.Stat.MAX_HP, 100_000)
		combat.stats.set_stat(target, StatBlock.Stat.HP, 100_000)
		Damageable.attach(body, target)
		target_handles.append(target)
		_target_meshes.append(body.get_child(1) as MeshInstance3D)
	_dead_pending.resize(target_handles.size())
	(weapon.get_node(^"Viewmodel") as ViewmodelSway).bind(get_node(^"Player") as FPSController,
			get_node(^"Player/Camera3D") as Camera3D)
	_dead_material = StandardMaterial3D.new()
	_dead_material.albedo_color = Color(0.22, 0.25, 0.27)
	GameLoop.logic_tick.connect(_on_logic_tick)
	EventBus.room_entered.emit(room_id)


func _on_logic_tick(tick: int) -> void:
	var start: int = Time.get_ticks_usec()
	resolver.logic_step(tick)
	var resolved: int = Time.get_ticks_usec()
	effects.logic_step(tick)
	var effected: int = Time.get_ticks_usec()
	mobility.logic_step(tick)
	var finished: int = Time.get_ticks_usec()
	_record_phase(Phase.RESOLVER, resolved - start)
	_record_phase(Phase.EFFECTS, effected - resolved)
	_record_phase(Phase.MOBILITY, finished - effected)
	_phase_steps += 1


static func _zeroes(size: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(size)
	return out


func _record_phase(phase: Phase, usec: int) -> void:
	_phase_last[phase] = usec
	_phase_sum[phase] += usec
	_phase_max[phase] = maxi(_phase_max[phase], usec)
	_phase_histogram[phase * PHASE_BUCKETS + clampi(usec / PHASE_BUCKET_USEC, 0, PHASE_BUCKETS - 1)] += 1


## Upper bound of the bucket holding the given percentile (permille), e.g. 990 for p99.
## The histogram covers 0..10 ms; a percentile in the last, open bucket returns the actual
## phase maximum. Cold read for reports; returns 0 before any tick and for permille
## outside 1..1000.
func phase_percentile_usec(phase: Phase, permille: int) -> int:
	if permille < 1 or permille > 1000 or _phase_steps == 0:
		return 0
	var rank: int = (_phase_steps * permille + 999) / 1000
	var seen: int = 0
	for bucket: int in PHASE_BUCKETS:
		seen += _phase_histogram[phase * PHASE_BUCKETS + bucket]
		if seen >= rank:
			if bucket == PHASE_BUCKETS - 1:
				return _phase_max[phase]
			return (bucket + 1) * PHASE_BUCKET_USEC
	return _phase_max[phase]


func phase_steps() -> int:
	return _phase_steps


func phase_last_usec(phase: Phase) -> int:
	return _phase_last[phase]


func phase_max_usec(phase: Phase) -> int:
	return _phase_max[phase]


func phase_sum_usec(phase: Phase) -> int:
	return _phase_sum[phase]


func reset_phase_metrics() -> void:
	_phase_last.fill(0)
	_phase_max.fill(0)
	_phase_sum.fill(0)
	_phase_histogram.fill(0)
	_phase_steps = 0


# Visible defeated targets preserve an inspectable collider and full handle.
func _process(_delta: float) -> void:
	if not _dead_dirty:
		return
	_dead_dirty = false
	for index: int in _dead_pending.size():
		if _dead_pending[index] != 0:
			_dead_pending[index] = 0
			_target_meshes[index].material_override = _dead_material


func _on_kill(_source: int, target: int, _epoch: int, _sequence: int, _trace: int) -> void:
	for index: int in target_handles.size():
		if target_handles[index] == target:
			_dead_pending[index] = 1
			_dead_dirty = true


func _on_hit(source: int, _target: int, _epoch: int, _sequence: int,
		_trace: int, _child: int, hp_damage: int) -> void:
	effects.enqueue(source, EffectTrigger.Trigger.ON_HIT, hp_damage)


func _abort_initialization(message: String) -> void:
	process_mode = Node.PROCESS_MODE_DISABLED
	if GameLoop.logic_tick.is_connected(_on_logic_tick):
		GameLoop.logic_tick.disconnect(_on_logic_tick)
	push_error(message)


## Explicit room/run reset from the composition root owning the shared runtime.
## Physical episode/input are deliberately preserved; spawning a new entity is separate.
func reset_mobility_clock() -> void:
	var old_tick: int = GameLoop.get_logic_tick()
	if not resolver.reset_room():
		_abort_initialization("Sandbox: room epoch exhausted")
		return
	effects.reset_room()
	weapon.reset_clock(old_tick)
	if not visuals.reset_room(shots.epoch):
		_abort_initialization("Sandbox: visual epoch reset failed")
		return
	mobility.reset_clock(old_tick)
	GameLoop.reset_clock()
	reset_phase_metrics()
	EventBus.room_entered.emit(room_id)
