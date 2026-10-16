class_name Sandbox
extends Node3D
## Composition root. Content and stores allocate only while loading the sandbox.

## Reaction teams: the player and the room's hostile targets (0 would be neutral).
const TEAM_PLAYER: int = 1
const TEAM_HOSTILE: int = 2

var combat: RoomCombat
var mobility: MobilityRuntime
var player_handle: int = StatBlock.INVALID_HANDLE
@export_dir var movement_data_directory: String = "res://data/movement"
@export_dir var weapon_data_directory: String = "res://data/weapons"
@export var visual_data: ShotVisualData = preload("res://data/visuals/shotgun.tres")
@export var effect_definitions: Array[EffectRuleData] = []
## Every room capacity and quota; validated when the room loads (contracts §2, RoomConfig).
@export var room_config: RoomConfig = preload("res://data/rooms/sandbox_room.tres")
## Identity passed to EventBus.room_entered on successful load and room reset.
@export var room_id: int = 0
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
# The same kill events mark targets here; the next physics tick takes them out of the
# reaction neighbour cache and off the hitbox layer, so the logic tick never touches nodes.
var _retire_pending: PackedByteArray = PackedByteArray()
var _retire_dirty: bool = false
# Set only by a complete load; logic_step refuses before it, after an abort and for
# a tick that is not newer than the last one it ran.
var _loaded: bool = false
var _last_logic_step: int = -1
## Diagnostic logic-phase timing (statuses, resolver, effects, mobility), outside the
## deterministic contour: only benchmarks read it, gameplay logic never does.
enum Phase { STATUSES, RESOLVER, EFFECTS, MOBILITY }
const PHASE_COUNT: int = 4
var _phase_last: PackedInt64Array = _zeroes_64(PHASE_COUNT)
var _phase_max: PackedInt64Array = _zeroes_64(PHASE_COUNT)
var _phase_sum: PackedInt64Array = _zeroes_64(PHASE_COUNT)
var _phase_steps: int = 0
## Per-phase histogram of PHASE_BUCKETS buckets of PHASE_BUCKET_USEC each (last bucket
## collects everything slower), preallocated so recording a tick never allocates.
const PHASE_BUCKET_USEC: int = 10
const PHASE_BUCKETS: int = 1000
var _phase_histogram: PackedInt32Array = _zeroes(PHASE_COUNT * PHASE_BUCKETS)


func _ready() -> void:
	# Death marks retire before the reaction cache refresh (0) and the weapon (10).
	process_physics_priority = -1
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
	combat = RoomCombat.new(room_config)
	if not combat.is_initialized():
		_abort_initialization("Sandbox: invalid room configuration")
		return
	var config: RoomConfig = combat.config
	var stride: int = WeaponData.validate_room(definitions, config.shot_capacity, config.trace_cap,
			config.shot_packed_bytes, config.host_capacity, config.context_capacity, config.deferred_reserve,
			config.reaction_candidates, true)
	if stride < 0:
		_abort_initialization("Sandbox: invalid weapon preset or room capacity")
		return
	if not ShotVisualData.validate_room(visual_data, definitions, config.shot_capacity, stride,
			1, config.visual_nodes, config.visual_packed_bytes, config.visual_texture_bytes):
		_abort_initialization("Sandbox: invalid visual preset or room capacity")
		return
	mobility = MobilityRuntime.new(combat.stats, config.landing_capacity, combat.statuses)
	if not mobility.is_initialized():
		_abort_initialization("Sandbox: mobility runtime requires the room stores")
		return
	effect_host = EffectHost.new(config.host_capacity, config.effect_entries)
	# Worst-case events and quota of one logic tick (contracts §2, RoomConfig).
	effects = EffectRunner.new(combat.stats, effect_host, effect_definitions,
			config.effect_event_capacity(), config.effect_max_subscriptions, config.effect_work_quota())
	if not effects.is_initialized() \
			or effects.packed_bytes() + effect_host_bytes(config) > config.effect_packed_bytes:
		_abort_initialization("Sandbox: invalid effect definitions or room capacity")
		return
	combat.statuses.on_pulse_hit.connect(_on_pulse_hit)
	combat.statuses.on_pulse_kill.connect(_on_pulse_kill)
	player_handle = combat.stats.allocate()
	if not combat.statuses.register_target(player_handle, StatusRuntime.Profile.PLAYER) \
			or not combat.reactions.register_target(player_handle, TEAM_PLAYER):
		_abort_initialization("Sandbox: player status registration failed")
		return
	combat.stats.set_stat(player_handle, StatBlock.Stat.MAX_HP, 100_000)
	combat.stats.set_stat(player_handle, StatBlock.Stat.HP, 100_000)
	combat.stats.set_stat(player_handle, StatBlock.Stat.ENERGY, 3000)
	combat.stats.set_stat(player_handle, StatBlock.Stat.MAX_ENERGY, 3000)
	if not mobility.grant_content(player_handle, registry, category):
		_abort_initialization("Sandbox: movement grant failed")
		return
	(get_node(^"Player") as FPSController).bind_mobility(mobility, player_handle)
	shots = ShotBatch.new(config.shot_capacity, stride, config.host_capacity, config.reaction_candidates)
	resolver = ShotResolver.new(combat.stats, shots, config.context_capacity, combat.statuses,
			combat.reactions)
	resolver.on_hit.connect(_on_hit)
	resolver.on_kill.connect(_on_kill)
	# Secondary reaction hits only repaint kills; they never reach EffectRunner in M2.3b.
	resolver.on_secondary_kill.connect(_on_kill)
	weapon = get_node(^"Player/Camera3D/HitscanWeapon") as HitscanWeapon
	if not weapon.initialize(definitions[0], combat.stats, shots, player_handle, get_node(^"Player") as FPSController) \
			or not weapon.bind_reactions(combat.reactions, config.host_capacity, config.candidate_queries_per_tick):
		_abort_initialization("Sandbox: weapon initialization failed")
		return
	visuals = get_node(^"ShotVisualPool") as ShotVisualPool
	if not visuals.initialize(visual_data, weapon, weapon.get_node(^"Viewmodel/MuzzleSocket") as Node3D, shots.epoch):
		_abort_initialization("Sandbox: visual initialization failed")
		return
	for body: Node in get_node(^"Targets").get_children():
		var target: int = combat.stats.allocate()
		if not combat.statuses.register_target(target, StatusRuntime.Profile.ORDINARY) \
				or not combat.reactions.register_target(target, TEAM_HOSTILE):
			_abort_initialization("Sandbox: target status registration failed")
			return
		combat.stats.set_stat(target, StatBlock.Stat.MAX_HP, 100_000)
		combat.stats.set_stat(target, StatBlock.Stat.HP, 100_000)
		Damageable.attach(body, target)
		weapon.reaction_candidates.track(body as CollisionObject3D, target)
		target_handles.append(target)
		_target_meshes.append(body.get_child(1) as MeshInstance3D)
	_dead_pending.resize(target_handles.size())
	_retire_pending.resize(target_handles.size())
	(weapon.get_node(^"Viewmodel") as ViewmodelSway).bind(get_node(^"Player") as FPSController,
			get_node(^"Player/Camera3D") as Camera3D)
	_dead_material = StandardMaterial3D.new()
	_dead_material.albedo_color = Color(0.22, 0.25, 0.27)
	GameLoop.logic_tick.connect(_on_logic_tick)
	_loaded = true
	EventBus.room_entered.emit(room_id)


func _on_logic_tick(tick: int) -> void:
	logic_step(tick)


## The room's single logic subscriber, public so tests and benchmarks can drive a tick:
## statuses (expiry, burn pulses) -> resolver -> effects -> mobility. A no-op before a
## complete load, after an aborted one and for a tick not newer than the last step.
func logic_step(tick: int) -> void:
	if not _loaded or tick <= _last_logic_step:
		return
	_last_logic_step = tick
	var start: int = Time.get_ticks_usec()
	if not combat.statuses.logic_step(tick):
		_abort_initialization("Sandbox: status tick failed")
		return
	var stepped: int = Time.get_ticks_usec()
	resolver.logic_step(tick)
	var resolved: int = Time.get_ticks_usec()
	effects.logic_step(tick)
	var effected: int = Time.get_ticks_usec()
	mobility.logic_step(tick)
	var finished: int = Time.get_ticks_usec()
	_record_phase(Phase.STATUSES, stepped - start)
	_record_phase(Phase.RESOLVER, resolved - stepped)
	_record_phase(Phase.EFFECTS, effected - resolved)
	_record_phase(Phase.MOBILITY, finished - effected)
	_phase_steps += 1


static func _zeroes(size: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(size)
	return out


static func _zeroes_64(size: int) -> PackedInt64Array:
	var out := PackedInt64Array()
	out.resize(size)
	return out


## EffectHost packed bytes: heads, owner/host lists, HandlePool and ten int32 + one int64
## columns. Counted with the runner against RoomConfig.effect_packed_bytes.
static func effect_host_bytes(config: RoomConfig) -> int:
	return config.host_capacity * (EffectTrigger.TRIGGER_COUNT * 4 + 12) + config.effect_entries * 57


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


func _process(_delta: float) -> void:
	apply_dead_marks()


func _physics_process(_delta: float) -> void:
	apply_retire_marks()


## Physics-side half of the kill path: the targets marked by kill events since the last
## physics tick leave the reaction neighbour cache and the hitbox layer (contracts §7).
func apply_retire_marks() -> void:
	if not _retire_dirty:
		return
	_retire_dirty = false
	for index: int in _retire_pending.size():
		if _retire_pending[index] != 0:
			_retire_pending[index] = 0
			weapon.reaction_candidates.untrack(target_handles[index])


## Frame-side half of the kill path: greys the targets marked by kill events since the last
## frame. Defeated targets stay visible; their hitbox has left layer 7 in the physics tick.
func apply_dead_marks() -> void:
	if not _dead_dirty:
		return
	_dead_dirty = false
	for index: int in _dead_pending.size():
		if _dead_pending[index] != 0:
			_dead_pending[index] = 0
			_target_meshes[index].material_override = _dead_material


func _on_kill(_source: int, target: int, _epoch: int, _sequence: int, _trace: int) -> void:
	_mark_dead(target)


func _on_pulse_kill(_source: int, target: int, _credit: int, _generation: int, _ordinal: int,
		_hp_damage: int, _epoch: int, _sequence: int, _trace: int, _tags: int) -> void:
	_mark_dead(target)


## Logic tick: only marks. The frame repaints, the next physics tick retires the hitbox.
func _mark_dead(target: int) -> void:
	for index: int in target_handles.size():
		if target_handles[index] == target:
			_dead_pending[index] = 1
			_dead_dirty = true
			_retire_pending[index] = 1
			_retire_dirty = true


func _on_hit(source: int, _target: int, _epoch: int, _sequence: int,
		_trace: int, _child: int, hp_damage: int) -> void:
	effects.enqueue(source, EffectTrigger.Trigger.ON_HIT, hp_damage)


## Burn pulses credit their original full source handle; a reused slot receives nothing.
func _on_pulse_hit(source: int, _target: int, _credit: int, _generation: int, _ordinal: int,
		hp_damage: int, _epoch: int, _sequence: int, _trace: int, _tags: int) -> void:
	effects.enqueue(source, EffectTrigger.Trigger.ON_HIT, hp_damage)


func _abort_initialization(message: String) -> void:
	_loaded = false
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
	if not combat.reset_room():
		_abort_initialization("Sandbox: room combat reset failed")
		return
	effects.reset_room()
	weapon.reset_clock(old_tick)
	if not visuals.reset_room(shots.epoch):
		_abort_initialization("Sandbox: visual epoch reset failed")
		return
	mobility.reset_clock(old_tick)
	GameLoop.reset_clock()
	_last_logic_step = -1
	reset_phase_metrics()
	EventBus.room_entered.emit(room_id)
