extends Node3D
## Composition root. Content and stores allocate only while loading the sandbox.

var mobility: MobilityRuntime
var player_handle: int = StatBlock.INVALID_HANDLE
@export_dir var movement_data_directory: String = "res://data/movement"
@export_dir var weapon_data_directory: String = "res://data/weapons"
const ROOM_SHOTS: int = 4
const ROOM_TRACE_CAP: int = 32
const ROOM_PACKED_BYTES: int = 131_072
const ROOM_HOSTS: int = 16
const ROOM_CONTEXTS: int = 64
const ROOM_DEFERRED_RESERVE: int = 16
var shots: ShotBatch
var resolver: ShotResolver
var weapon: HitscanWeapon
var target_handles: PackedInt64Array = PackedInt64Array()
var _target_meshes: Array[MeshInstance3D] = []
var _dead_material: StandardMaterial3D


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
	mobility = MobilityRuntime.new(ROOM_HOSTS)
	player_handle = mobility.stats.allocate()
	mobility.stats.set_stat(player_handle, StatBlock.Stat.MAX_HP, 100_000)
	mobility.stats.set_stat(player_handle, StatBlock.Stat.HP, 100_000)
	mobility.stats.set_stat(player_handle, StatBlock.Stat.ENERGY, 3000)
	mobility.stats.set_stat(player_handle, StatBlock.Stat.MAX_ENERGY, 3000)
	if not mobility.grant_content(player_handle, registry, category):
		_abort_initialization("Sandbox: movement grant failed")
		return
	(get_node(^"Player") as FPSController).bind_mobility(mobility, player_handle)
	shots = ShotBatch.new(ROOM_SHOTS, stride, ROOM_HOSTS)
	resolver = ShotResolver.new(mobility.stats, shots, ROOM_CONTEXTS)
	weapon = get_node(^"Player/Camera3D/HitscanWeapon") as HitscanWeapon
	if not weapon.initialize(definitions[0], mobility.stats, shots, player_handle, get_node(^"Player") as FPSController):
		_abort_initialization("Sandbox: weapon initialization failed")
		return
	for body: Node in get_node(^"Targets").get_children():
		var target: int = mobility.stats.allocate()
		mobility.stats.set_stat(target, StatBlock.Stat.MAX_HP, 100_000)
		mobility.stats.set_stat(target, StatBlock.Stat.HP, 100_000)
		Damageable.attach(body, target)
		target_handles.append(target)
		_target_meshes.append(body.get_child(1) as MeshInstance3D)
	_dead_material = StandardMaterial3D.new()
	_dead_material.albedo_color = Color(0.22, 0.25, 0.27)
	GameLoop.logic_tick.connect(_on_logic_tick)


func _on_logic_tick(tick: int) -> void:
	resolver.logic_step(tick)
	mobility.logic_step(tick)
	# Visible defeated targets preserve an inspectable collider and full handle.
	for index: int in target_handles.size():
		if mobility.stats.get_stat(target_handles[index], StatBlock.Stat.HP) <= 0:
			_target_meshes[index].material_override = _dead_material


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
	weapon.reset_clock(old_tick)
	mobility.reset_clock(old_tick)
	GameLoop.reset_clock()
