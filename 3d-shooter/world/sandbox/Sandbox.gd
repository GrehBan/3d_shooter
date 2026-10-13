extends Node3D
## Composition root. Content and stores allocate only while loading the sandbox.

var mobility: MobilityRuntime
var player_handle: int = StatBlock.INVALID_HANDLE
@export_dir var movement_data_directory: String = "res://data/movement"


func _ready() -> void:
	var registry := Registry.new()
	var category: int = registry.add_category(&"movement", preload("res://player/MovementAbilityData.gd"))
	if registry.load_directory(category, movement_data_directory) != 3:
		_abort_initialization("Sandbox: three movement definitions required")
		return
	registry.freeze()
	mobility = MobilityRuntime.new()
	player_handle = mobility.stats.allocate()
	mobility.stats.set_stat(player_handle, StatBlock.Stat.MAX_HP, 100_000)
	mobility.stats.set_stat(player_handle, StatBlock.Stat.HP, 100_000)
	mobility.stats.set_stat(player_handle, StatBlock.Stat.ENERGY, 3000)
	mobility.stats.set_stat(player_handle, StatBlock.Stat.MAX_ENERGY, 3000)
	if not mobility.grant_content(player_handle, registry, category):
		_abort_initialization("Sandbox: movement grant failed")
		return
	(get_node(^"Player") as FPSController).bind_mobility(mobility, player_handle)
	GameLoop.logic_tick.connect(_on_logic_tick)


func _on_logic_tick(tick: int) -> void:
	mobility.logic_step(tick)


func _abort_initialization(message: String) -> void:
	process_mode = Node.PROCESS_MODE_DISABLED
	if GameLoop.logic_tick.is_connected(_on_logic_tick):
		GameLoop.logic_tick.disconnect(_on_logic_tick)
	push_error(message)


## Explicit room/run reset from the composition root owning the shared runtime.
## Physical episode/input are deliberately preserved; spawning a new entity is separate.
func reset_mobility_clock() -> void:
	mobility.reset_clock(GameLoop.get_logic_tick())
	GameLoop.reset_clock()
