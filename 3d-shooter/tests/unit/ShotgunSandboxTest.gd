extends GdUnitTestSuite

const SANDBOX: PackedScene = preload("res://world/sandbox/Sandbox.tscn")
var _scene: Node3D
var _hp_on_hit: int
var _energy_on_hit: int
var _entered_rooms: PackedInt64Array = PackedInt64Array()


func before_test() -> void:
	_entered_rooms = PackedInt64Array()
	EventBus.room_entered.connect(_on_room_entered)


func after_test() -> void:
	if EventBus.room_entered.is_connected(_on_room_entered):
		EventBus.room_entered.disconnect(_on_room_entered)
	if is_instance_valid(_scene):
		_scene.free()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _on_room_entered(room_id: int) -> void:
	_entered_rooms.append(room_id)


func test_invalid_weapon_disables_complete_room_before_runtime_and_subscription() -> void:
	_scene = SANDBOX.instantiate() as Node3D
	_scene.set(&"weapon_data_directory", "res://tests/fixtures/weapon_invalid")
	var player: FPSController = _scene.get_node(^"Player") as FPSController
	player.hardware_input_enabled = false
	var subscribers: int = GameLoop.logic_tick.get_connections().size()
	assert_error(func() -> void: add_child(_scene)).is_push_error("Sandbox: invalid weapon preset or room capacity")
	assert_int(_scene.process_mode).is_equal(Node.PROCESS_MODE_DISABLED)
	assert_int(GameLoop.logic_tick.get_connections().size()).is_equal(subscribers)
	assert_object(_scene.get(&"mobility")).is_null()
	assert_object(_scene.get(&"shots")).is_null()
	assert_object(_scene.get(&"resolver")).is_null()
	assert_array(_entered_rooms).is_empty()


func _hit(_source: int, _target: int, _epoch: int, _sequence: int, _trace: int,
		_child: int, _damage: int) -> void:
	var mobility: MobilityRuntime = _scene.get(&"mobility") as MobilityRuntime
	var player: int = _scene.get(&"player_handle")
	_hp_on_hit = mobility.stats.get_stat(player, StatBlock.Stat.HP)
	_energy_on_hit = mobility.stats.get_stat(player, StatBlock.Stat.ENERGY)


func test_one_subscription_resolves_shots_before_landing_then_regen() -> void:
	_scene = SANDBOX.instantiate() as Node3D
	(_scene.get_node(^"Player") as FPSController).hardware_input_enabled = false
	(_scene.get_node(^"Player/Camera3D/HitscanWeapon") as HitscanWeapon).hardware_input_enabled = false
	var before: int = GameLoop.logic_tick.get_connections().size()
	add_child(_scene)
	assert_int(GameLoop.logic_tick.get_connections().size()).is_equal(before + 1)
	var mobility: MobilityRuntime = _scene.get(&"mobility") as MobilityRuntime
	var resolver: ShotResolver = _scene.get(&"resolver") as ShotResolver
	var shots: ShotBatch = _scene.get(&"shots") as ShotBatch
	var player: int = _scene.get(&"player_handle")
	mobility.stats.set_stat(player, StatBlock.Stat.HP, 20000)
	mobility.stats.set_stat(player, StatBlock.Stat.ENERGY, 0)
	var ticket: int = shots.reserve(player, 1, 6000)
	shots.write_trace(ticket, 0, player)
	shots.publish(ticket)
	mobility.landings.push(player, 9000, 0)
	resolver.on_hit.connect(_hit)
	_scene.call(&"_on_logic_tick", GameLoop.get_logic_tick())
	assert_int(_hp_on_hit).is_equal(14000)
	assert_int(_energy_on_hit).is_equal(0)
	assert_int(mobility.stats.get_stat(player, StatBlock.Stat.HP)).is_equal(4000)
	assert_int(mobility.stats.get_stat(player, StatBlock.Stat.ENERGY)).is_equal(50)
	assert_int(resolver.resolved_shots).is_equal(1)
	_scene.call(&"_on_logic_tick", GameLoop.get_logic_tick())
	assert_int(mobility.stats.get_stat(player, StatBlock.Stat.ENERGY)).is_equal(50)
	assert_int(resolver.resolved_shots).is_equal(1)


func test_invalid_visual_disables_room_before_stores_binding_or_subscription() -> void:
	_scene = SANDBOX.instantiate() as Node3D
	var data := ShotVisualData.new()
	data.mark_capacity = 79
	_scene.set(&"visual_data", data)
	(_scene.get_node(^"Player") as FPSController).hardware_input_enabled = false
	var subscribers: int = GameLoop.logic_tick.get_connections().size()
	assert_error(func() -> void: add_child(_scene)).is_push_error("Sandbox: invalid visual preset or room capacity")
	assert_int(_scene.process_mode).is_equal(Node.PROCESS_MODE_DISABLED)
	assert_int(GameLoop.logic_tick.get_connections().size()).is_equal(subscribers)
	assert_object(_scene.get(&"mobility")).is_null()
	assert_object(_scene.get(&"shots")).is_null()
	assert_object(_scene.get(&"resolver")).is_null()
	assert_object(_scene.get(&"visuals")).is_null()
	assert_bool((_scene.get_node(^"Player/Camera3D/HitscanWeapon") as HitscanWeapon).is_initialized()).is_false()
	assert_array(_entered_rooms).is_empty()


func test_kill_event_greys_target_in_frame_and_reset_announces_room() -> void:
	_scene = SANDBOX.instantiate() as Node3D
	_scene.set(&"room_id", 7)
	(_scene.get_node(^"Player") as FPSController).hardware_input_enabled = false
	(_scene.get_node(^"Player/Camera3D/HitscanWeapon") as HitscanWeapon).hardware_input_enabled = false
	add_child(_scene)
	var mobility: MobilityRuntime = _scene.get(&"mobility") as MobilityRuntime
	var shots: ShotBatch = _scene.get(&"shots") as ShotBatch
	var player: int = _scene.get(&"player_handle")
	var targets: PackedInt64Array = _scene.get(&"target_handles")
	var mesh: MeshInstance3D = _scene.get_node(^"Targets").get_child(0).get_child(1) as MeshInstance3D
	mobility.stats.set_stat(targets[0], StatBlock.Stat.HP, 6000)
	mobility.stats.set_stat(targets[1], StatBlock.Stat.HP, 0)
	var ticket: int = shots.reserve(player, 1, 6000)
	shots.write_trace(ticket, 0, targets[0])
	shots.publish(ticket)
	_scene.call(&"_on_logic_tick", GameLoop.get_logic_tick() + 1)
	var after_logic: Material = mesh.material_override
	_scene.call(&"_process", 0.0)
	var after_frame: Material = mesh.material_override
	var untouched: Material = (_scene.get_node(^"Targets").get_child(1).get_child(1) as MeshInstance3D).material_override
	var epoch_before: int = shots.epoch
	_scene.call(&"reset_mobility_clock")
	assert_int(shots.epoch).is_equal(epoch_before + 1)  # the reset ran to the end
	assert_object(after_logic).is_null()  # the logic tick does not touch visuals
	assert_object(after_frame).is_not_null()
	assert_object(untouched).is_null()  # HP 0 without a kill event is not repainted
	assert_array(_entered_rooms).is_equal(PackedInt64Array([7, 7]))
	assert_object(mesh.material_override).is_not_null()  # targets and HP survive reset
	# Reset order (contracts §7): the visual pool follows the new ShotBatch epoch.
	assert_int((_scene.get(&"visuals") as ShotVisualPool).room_epoch).is_equal(shots.epoch)


func test_kill_mark_pending_at_reset_is_applied_on_next_frame() -> void:
	_scene = SANDBOX.instantiate() as Node3D
	(_scene.get_node(^"Player") as FPSController).hardware_input_enabled = false
	(_scene.get_node(^"Player/Camera3D/HitscanWeapon") as HitscanWeapon).hardware_input_enabled = false
	add_child(_scene)
	var mobility: MobilityRuntime = _scene.get(&"mobility") as MobilityRuntime
	var shots: ShotBatch = _scene.get(&"shots") as ShotBatch
	var player: int = _scene.get(&"player_handle")
	var targets: PackedInt64Array = _scene.get(&"target_handles")
	var mesh: MeshInstance3D = _scene.get_node(^"Targets").get_child(0).get_child(1) as MeshInstance3D
	mobility.stats.set_stat(targets[0], StatBlock.Stat.HP, 6000)
	var ticket: int = shots.reserve(player, 1, 6000)
	shots.write_trace(ticket, 0, targets[0])
	shots.publish(ticket)
	_scene.call(&"_on_logic_tick", GameLoop.get_logic_tick() + 1)
	var before_reset: Material = mesh.material_override
	var epoch_before: int = shots.epoch
	_scene.call(&"reset_mobility_clock")
	var after_reset: Material = mesh.material_override
	assert_int(shots.epoch).is_equal(epoch_before + 1)
	assert_array(_entered_rooms).is_equal(PackedInt64Array([0, 0]))  # load and this reset
	_scene.call(&"_process", 0.0)
	assert_object(before_reset).is_null()
	assert_object(after_reset).is_null()  # the mark is still pending, reset does not drop it
	assert_object(mesh.material_override).is_not_null()
	assert_int(mobility.stats.get_stat(targets[0], StatBlock.Stat.HP)).is_equal(0)


func test_refused_room_reset_does_not_announce_room() -> void:
	_scene = SANDBOX.instantiate() as Node3D
	(_scene.get_node(^"Player") as FPSController).hardware_input_enabled = false
	(_scene.get_node(^"Player/Camera3D/HitscanWeapon") as HitscanWeapon).hardware_input_enabled = false
	add_child(_scene)
	var shots: ShotBatch = _scene.get(&"shots") as ShotBatch
	_scene.call(&"reset_phase_metrics")
	_scene.call(&"_on_logic_tick", GameLoop.get_logic_tick() + 1)
	shots.epoch = ShotBatch.INT_MAX
	await assert_error(func() -> void: _scene.call(&"reset_mobility_clock")).is_push_error(
			"Sandbox: room epoch exhausted")
	assert_array(_entered_rooms).is_equal(PackedInt64Array([0]))  # only the successful load
	assert_int(_scene.call(&"phase_steps")).is_equal(1)  # a refused reset keeps the metrics


func test_refused_visual_reset_does_not_announce_room() -> void:
	# effects.reset_room() and weapon.reset_clock() have no refusal path; the resolver
	# refusal is covered above, the visual pool refusal here.
	_scene = SANDBOX.instantiate() as Node3D
	(_scene.get_node(^"Player") as FPSController).hardware_input_enabled = false
	(_scene.get_node(^"Player/Camera3D/HitscanWeapon") as HitscanWeapon).hardware_input_enabled = false
	add_child(_scene)
	(_scene.get(&"visuals") as ShotVisualPool).room_epoch = ShotBatch.INT_MAX
	await assert_error(func() -> void: _scene.call(&"reset_mobility_clock")).is_push_error(
			"Sandbox: visual epoch reset failed")
	assert_int(_scene.process_mode).is_equal(Node.PROCESS_MODE_DISABLED)
	assert_array(_entered_rooms).is_equal(PackedInt64Array([0]))


func test_phase_metrics_count_logic_ticks_and_reset_with_the_room() -> void:
	_scene = SANDBOX.instantiate() as Node3D
	(_scene.get_node(^"Player") as FPSController).hardware_input_enabled = false
	(_scene.get_node(^"Player/Camera3D/HitscanWeapon") as HitscanWeapon).hardware_input_enabled = false
	add_child(_scene)
	_scene.call(&"reset_phase_metrics")
	var first: int = GameLoop.get_logic_tick() + 1
	for tick: int in 3:
		_scene.call(&"_on_logic_tick", first + tick)
	var steps: int = _scene.call(&"phase_steps")
	var consistent: bool = true
	for phase: int in 4:  # statuses, resolver, effects, mobility
		var last: int = _scene.call(&"phase_last_usec", phase)
		var maximum: int = _scene.call(&"phase_max_usec", phase)
		var total: int = _scene.call(&"phase_sum_usec", phase)
		var p99: int = _scene.call(&"phase_percentile_usec", phase, 990)
		# With three samples p99 is the bucket of the maximum (upper bound, at most 10 us above).
		var ordered: bool = (last >= 0) and (maximum >= last) and (total >= maximum)
		consistent = consistent and ordered and (p99 >= maximum) and (p99 - maximum <= 10)
	_scene.call(&"reset_mobility_clock")
	assert_int(steps).is_equal(3)
	assert_bool(consistent).is_true()
	assert_int(_scene.call(&"phase_steps")).is_equal(0)  # the room reset clears diagnostics
	assert_int(_scene.call(&"phase_sum_usec", 0)).is_equal(0)
