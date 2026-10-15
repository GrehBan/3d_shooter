extends GdUnitTestSuite

const HP := StatBlock.Stat.HP
const SHIELD := StatBlock.Stat.SHIELD
const ARMOR := StatBlock.Stat.ARMOR
const ENERGY := StatBlock.Stat.ENERGY
const MAX_ENERGY := StatBlock.Stat.MAX_ENERGY


func test_damage_shield_then_percentage_and_hp_clamp() -> void:
	var stats := StatBlock.new(1)
	var entity: int = stats.allocate()
	stats.set_stat(entity, HP, 100_000)
	stats.set_stat(entity, SHIELD, 10_000)
	stats.set_stat(entity, ARMOR, 25_000)
	assert_int(DamageApply.apply(stats, entity, 30_000)).is_equal(15_000)
	assert_int(stats.get_stat(entity, HP)).is_equal(85_000)
	assert_int(stats.get_stat(entity, SHIELD)).is_equal(0)
	assert_int(stats.get_stat(entity, ARMOR)).is_equal(25_000)
	assert_int(DamageApply.apply(stats, entity, 1_000_000)).is_equal(85_000)
	assert_int(stats.get_stat(entity, HP)).is_equal(0)
	assert_int(DamageApply.apply(stats, entity, -20)).is_equal(0)


func test_armor_clamp_and_int64_damage_without_product_overflow() -> void:
	var stats := StatBlock.new(1)
	var entity: int = stats.allocate()
	for armor: int in [-1000, 0, 99_999, 100_000, 110_000]:
		stats.set_stat(entity, HP, StatBlock.VALUE_MAX)
		stats.set_stat(entity, SHIELD, 10)
		stats.set_stat(entity, ARMOR, armor)
		var applied: int = DamageApply.apply(stats, entity, 0x7FFFFFFFFFFFFFFF)
		assert_int(applied).is_equal(StatBlock.VALUE_MAX if armor < 100_000 else 0)
		assert_int(stats.get_stat(entity, SHIELD)).is_equal(0)
	stats.set_stat(entity, HP, 100)
	stats.set_stat(entity, ARMOR, 33_333)
	assert_int(DamageApply.apply(stats, entity, 2)).is_equal(1)


func test_integer_fall_boundaries_and_cancellation() -> void:
	var runtime := MobilityRuntime.new(StatBlock.new(1))
	var entity: int = runtime.stats.allocate()
	runtime.stats.set_stat(entity, HP, 1000)
	for mm: int in [7999, 8000, 8001]:
		runtime.landings.push(entity, mm, 0)
	runtime.logic_step(0)
	assert_int(runtime.stats.get_stat(entity, HP)).is_equal(990)
	assert_int(runtime.resolved_landings).is_equal(3)
	runtime.landings.push(entity, 100_000, LandingEventQueue.CANCEL_DASH)
	runtime.landings.push(entity, 100_000, LandingEventQueue.CANCEL_SLIDE)
	runtime.logic_step(1)
	assert_int(runtime.stats.get_stat(entity, HP)).is_equal(990)
	assert_int(MobilityRuntime.fall_damage(0x7FFFFFFFFFFFFFFF)).is_equal(9_223_372_036_854_775_800)
	assert_int(FPSController.quantize_height_mm(7.999)).is_equal(7999)
	assert_int(FPSController.quantize_height_mm(8.0)).is_equal(8000)
	# Decimal 8.001 lies just below its mm boundary as binary float; do not add epsilon.
	assert_int(FPSController.quantize_height_mm(8.0011)).is_equal(8001)
	assert_int(FPSController.quantize_height_mm(8.000999)).is_equal(8000)


func test_shared_regen_once_per_logic_tick_and_stale_handles() -> void:
	var runtime := MobilityRuntime.new(StatBlock.new(2))
	var a: int = runtime.stats.allocate()
	var b: int = runtime.stats.allocate()
	for entity: int in [a, b]:
		runtime.stats.set_stat(entity, MAX_ENERGY, 3000)
		runtime.abilities.grant(entity, MovementAbilityData.Kind.DASH, 1000, 6, true, true)
	for tick: int in 30:
		runtime.logic_step(tick)
		runtime.logic_step(tick)
	assert_int(runtime.stats.get_stat(a, ENERGY)).is_equal(1500)
	assert_int(runtime.stats.get_stat(b, ENERGY)).is_equal(1500)
	assert_int(runtime.logic_steps).is_equal(30)
	runtime.landings.push(a, 10000, 0)
	runtime.stats.release(a)
	var replacement: int = runtime.stats.allocate()
	runtime.stats.set_stat(replacement, HP, 100_000)
	runtime.stats.set_stat(replacement, MAX_ENERGY, 3000)
	runtime.logic_step(30)
	assert_int(runtime.stats.get_stat(replacement, HP)).is_equal(100_000)
	assert_int(runtime.stats.get_stat(replacement, ENERGY)).is_equal(0)
	assert_int(runtime.stale_landings).is_equal(1)
	assert_int(DamageApply.apply(runtime.stats, a, 10_000)).is_equal(0)
	assert_int(runtime.stats.get_stat(replacement, HP)).is_equal(100_000)
	runtime.abilities.grant(replacement, MovementAbilityData.Kind.DASH, 1000, 6, true, true)
	runtime.logic_step(31)
	assert_int(runtime.stats.get_stat(replacement, ENERGY)).is_equal(50)
	runtime.reset_clock(31)
	runtime.logic_step(0)
	assert_int(runtime.stats.get_stat(replacement, ENERGY)).is_equal(100)
	assert_int(runtime.logic_steps).is_equal(1)


func test_registry_content_grants_only_cold_and_initial_balance() -> void:
	var registry := Registry.new()
	var category: int = registry.add_category(&"movement", preload("res://player/MovementAbilityData.gd"))
	assert_int(registry.load_directory(category, "res://data/movement")).is_equal(3)
	registry.freeze()
	var runtime := MobilityRuntime.new(StatBlock.new(1))
	var entity: int = runtime.stats.allocate()
	runtime.stats.set_stat(entity, ENERGY, 3000)
	runtime.stats.set_stat(entity, MAX_ENERGY, 3000)
	assert_bool(runtime.grant_content(entity, registry, category)).is_true()
	assert_bool(runtime.abilities.try_activate(entity, MovementAbilityData.Kind.DASH, 0, true, runtime.stats)).is_true()
	assert_int(runtime.stats.get_stat(entity, ENERGY)).is_equal(2000)
	assert_int(runtime.abilities.ready_tick(entity, MovementAbilityData.Kind.DASH)).is_equal(6)
	assert_bool(runtime.abilities.try_activate(entity, MovementAbilityData.Kind.SLIDE, 0, true, runtime.stats)).is_false()
	assert_bool(runtime.abilities.try_activate(entity, MovementAbilityData.Kind.DOUBLE_JUMP, 0, true, runtime.stats)).is_true()
	assert_int(runtime.abilities.ready_tick(entity, MovementAbilityData.Kind.DOUBLE_JUMP)).is_equal(0)


func test_landing_ring_wrap_overflow_report_once_and_reset_contract() -> void:
	var queue := LandingEventQueue.new(2)
	queue.push(0x100000000, 9000, 0)
	queue.push(2, 8001, LandingEventQueue.CANCEL_SLIDE)
	var results: Array[bool] = []
	var notification: GdUnitGodotErrorAssert = assert_error(func() -> void:
		results.append(queue.push(3, 9000, 0))
		results.append(queue.push(4, 9000, 0)))
	await notification.is_push_error("LandingEventQueue: overflow, landing event dropped")
	# Same pinned logger API as DamagePayloadBufferTest; explicitly count notifications.
	var logger: GodotGdErrorMonitor.GdUnitLogger = notification.get("_logger")
	assert_int(logger.entries().size()).is_equal(1)
	assert_array(results).is_equal([false, false])
	assert_int(queue.dropped_count()).is_equal(2)
	assert_int(queue.get_entity(0)).is_equal(0x100000000)
	assert_int(queue.get_height_mm(0)).is_equal(9000)
	queue.clear()
	assert_int(queue.dropped_count()).is_equal(2)
	queue.push(5, -100, 0)
	assert_int(queue.get_entity(0)).is_equal(5)
	assert_int(queue.get_height_mm(0)).is_equal(0)
	queue.clear()  # one consumed record advances head to 1; next fill wraps indices 1,0
	queue.push(6, 9000, 0)
	queue.push(7, 9001, LandingEventQueue.CANCEL_DASH)
	assert_int(queue.get_entity(0)).is_equal(6)
	assert_int(queue.get_entity(1)).is_equal(7)
	assert_int(queue.get_height_mm(1)).is_equal(9001)
	assert_int(queue.get_cancel_flags(1)).is_equal(LandingEventQueue.CANCEL_DASH)
	await assert_error(func() -> void: queue.push(8, 9000, 0)) \
		.is_push_error("LandingEventQueue: overflow, landing event dropped")
	queue.reset_dropped_count()
	assert_int(queue.dropped_count()).is_equal(0)
	assert_int(queue.count()).is_equal(2)
	await assert_error(func() -> void: queue.push(9, 9000, 0)).is_success()
	assert_int(queue.dropped_count()).is_equal(1)

func test_clock_reset_preserves_remaining_cooldown_energy_grants_and_resumes_regen() -> void:
	var runtime := MobilityRuntime.new(StatBlock.new(1))
	var entity: int = runtime.stats.allocate()
	runtime.stats.set_stat(entity, ENERGY, 3000)
	runtime.stats.set_stat(entity, MAX_ENERGY, 3000)
	runtime.abilities.grant(entity, MovementAbilityData.Kind.DASH, 1000, 6, true, true)
	runtime.abilities.grant(entity, MovementAbilityData.Kind.SLIDE, 500, 2, true, false)
	assert_bool(runtime.abilities.try_activate(entity, MovementAbilityData.Kind.SLIDE, 900, false, runtime.stats)).is_true()
	assert_bool(runtime.abilities.try_activate(entity, MovementAbilityData.Kind.DASH, 1000, false, runtime.stats)).is_true()
	# No logic_step has happened: the runtime's _last_tick is still -1.
	runtime.landings.push(entity, 20_000, 0)
	runtime.reset_clock(1000)
	assert_int(runtime.landings.count()).is_equal(0)
	assert_int(runtime.abilities.ready_tick(entity, MovementAbilityData.Kind.DASH)).is_equal(6)
	assert_int(runtime.abilities.ready_tick(entity, MovementAbilityData.Kind.SLIDE)).is_equal(0)
	assert_int(runtime.abilities.ready_tick(entity, MovementAbilityData.Kind.DOUBLE_JUMP)).is_equal(-1)
	assert_int(runtime.abilities.active_count()).is_equal(1)
	assert_int(runtime.stats.get_stat(entity, ENERGY)).is_equal(1500)
	assert_bool(runtime.abilities.try_activate(entity, MovementAbilityData.Kind.DASH, 5, false, runtime.stats)).is_false()
	runtime.logic_step(0)
	runtime.logic_step(0)
	assert_int(runtime.stats.get_stat(entity, ENERGY)).is_equal(1550)
	assert_int(runtime.logic_steps).is_equal(1)
	assert_bool(runtime.abilities.try_activate(entity, MovementAbilityData.Kind.DASH, 6, false, runtime.stats)).is_true()
	assert_int(runtime.stats.get_stat(entity, ENERGY)).is_equal(550)
	# The exact old clock also matters when physics activation is later than last drain.
	runtime.logic_step(1000)
	assert_bool(runtime.abilities.try_activate(entity, MovementAbilityData.Kind.SLIDE, 1001, false, runtime.stats)).is_true()
	runtime.reset_clock(1001)
	assert_int(runtime.abilities.ready_tick(entity, MovementAbilityData.Kind.SLIDE)).is_equal(2)
	assert_int(runtime.abilities.ready_tick(entity, MovementAbilityData.Kind.DASH)).is_equal(0)
	assert_int(runtime.stats.get_stat(entity, ENERGY)).is_equal(100)


func test_cooldown_rebase_does_not_allocate() -> void:
	var runtime := MobilityRuntime.new(StatBlock.new(1))
	var entity: int = runtime.stats.allocate()
	runtime.abilities.grant(entity, MovementAbilityData.Kind.DASH, 0, 6, true, true)
	for i: int in 300:
		runtime.abilities.try_activate(entity, MovementAbilityData.Kind.DASH, 1000, false, runtime.stats)
		runtime.reset_clock(1000)
	var objects: int = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var memory: int = int(Performance.get_monitor(Performance.MEMORY_STATIC))
	for i: int in 3600:
		runtime.abilities.try_activate(entity, MovementAbilityData.Kind.DASH, 1000, false, runtime.stats)
		runtime.reset_clock(1000)
	var object_delta: int = int(Performance.get_monitor(Performance.OBJECT_COUNT)) - objects
	var memory_delta: int = int(Performance.get_monitor(Performance.MEMORY_STATIC)) - memory
	assert_int(object_delta).is_equal(0)
	assert_int(memory_delta).is_less_equal(1024 * 1024)
	assert_int(runtime.abilities.ready_tick(entity, MovementAbilityData.Kind.DASH)).is_equal(6)


func _definition(kind: int, cost: int = 1000, cooldown: int = 6) -> MovementAbilityData:
	var data := MovementAbilityData.new()
	data.set("kind", kind)
	data.energy_cost = cost
	data.cooldown_ticks = cooldown
	data.usable_on_ground = kind != MovementAbilityData.Kind.DOUBLE_JUMP
	data.usable_in_air = kind != MovementAbilityData.Kind.SLIDE
	return data


func _preset(definitions: Array[MovementAbilityData]) -> Registry:
	var registry := Registry.new()
	var category: int = registry.add_category(&"movement", preload("res://player/MovementAbilityData.gd"))
	for i: int in definitions.size():
		registry.register(category, StringName("entry%d" % i), definitions[i])
	registry.freeze()
	return registry


func test_invalid_content_is_atomic_for_missing_duplicate_extra_kind_and_parameter_bounds() -> void:
	var runtime := MobilityRuntime.new(StatBlock.new(1))
	var entity: int = runtime.stats.allocate()
	runtime.stats.set_stat(entity, ENERGY, 3000)
	runtime.stats.set_stat(entity, MAX_ENERGY, 3000)
	runtime.abilities.grant(entity, MovementAbilityData.Kind.DASH, 777, 13, true, true)
	runtime.abilities.grant(entity, MovementAbilityData.Kind.DOUBLE_JUMP, 333, 0, false, true)
	runtime.abilities.grant(entity, MovementAbilityData.Kind.SLIDE, 555, 9, true, false)
	runtime.abilities.try_activate(entity, MovementAbilityData.Kind.DASH, 1000, false, runtime.stats)
	var presets: Array[Registry] = [
		_preset([_definition(0), _definition(2)]),
		_preset([_definition(0), _definition(0), _definition(2)]),
		_preset([_definition(0), _definition(3), _definition(2)]),
		_preset([_definition(0), _definition(1), _definition(2), _definition(3)]),
		_preset([_definition(0), _definition(-1), _definition(2)]),
		_preset([_definition(0), _definition(1), _definition(2, -1)]),
		_preset([_definition(0), _definition(1), _definition(2, StatBlock.VALUE_MAX + 1)]),
		_preset([_definition(0), _definition(1), _definition(2, 1000, -1)]),
		_preset([_definition(0), _definition(1), _definition(2, 1000, StatBlock.VALUE_MAX + 1)]),
	]
	for registry: Registry in presets:
		assert_bool(runtime.grant_content(entity, registry, 0)).is_false()
		assert_int(runtime.abilities.ready_tick(entity, MovementAbilityData.Kind.DASH)).is_equal(1013)
		assert_int(runtime.stats.get_stat(entity, ENERGY)).is_equal(2223)
		assert_bool(runtime.abilities.is_granted(entity, MovementAbilityData.Kind.DOUBLE_JUMP)).is_true()
		assert_bool(runtime.abilities.is_granted(entity, MovementAbilityData.Kind.SLIDE)).is_true()
	# Existing prices and cooldowns must be untouched by rejected records earlier in the preset.
	assert_bool(runtime.abilities.try_activate(entity, MovementAbilityData.Kind.SLIDE, 1000, false, runtime.stats)).is_true()
	assert_int(runtime.stats.get_stat(entity, ENERGY)).is_equal(1668)
	assert_int(runtime.abilities.ready_tick(entity, MovementAbilityData.Kind.SLIDE)).is_equal(1009)
	assert_bool(runtime.abilities.try_activate(entity, MovementAbilityData.Kind.DASH, 1013, false, runtime.stats)).is_true()
	assert_int(runtime.stats.get_stat(entity, ENERGY)).is_equal(891)
	assert_int(runtime.abilities.ready_tick(entity, MovementAbilityData.Kind.DASH)).is_equal(1026)
	assert_bool(runtime.grant_content(entity, _preset([_definition(0, 555, 2), _definition(1, 0, 0), _definition(2, 0, 0)]), 0)).is_true()
	assert_int(runtime.abilities.ready_tick(entity, MovementAbilityData.Kind.DASH)).is_equal(1026)
	assert_int(runtime.stats.get_stat(entity, ENERGY)).is_equal(891)
	assert_bool(runtime.abilities.try_activate(entity, MovementAbilityData.Kind.DASH, 1025, false, runtime.stats)).is_false()
	assert_bool(runtime.abilities.try_activate(entity, MovementAbilityData.Kind.DASH, 1026, false, runtime.stats)).is_true()
	assert_int(runtime.stats.get_stat(entity, ENERGY)).is_equal(336)
	assert_int(runtime.abilities.ready_tick(entity, MovementAbilityData.Kind.DASH)).is_equal(1028)


func test_invalid_content_flags_never_create_partial_grants_and_int32_limits_are_valid() -> void:
	for kind: int in 3:
		for flag: int in 2:
			var definitions: Array[MovementAbilityData] = [_definition(0), _definition(1), _definition(2)]
			if flag == 0:
				definitions[kind].usable_on_ground = not definitions[kind].usable_on_ground
			else:
				definitions[kind].usable_in_air = not definitions[kind].usable_in_air
			var runtime := MobilityRuntime.new(StatBlock.new(1))
			var entity: int = runtime.stats.allocate()
			assert_bool(runtime.grant_content(entity, _preset(definitions), 0)).is_false()
			assert_int(runtime.abilities.active_count()).is_equal(0)
			for k: int in 3:
				assert_bool(runtime.abilities.is_granted(entity, k as MovementAbilityData.Kind)).is_false()
	var runtime := MobilityRuntime.new(StatBlock.new(1))
	var entity: int = runtime.stats.allocate()
	runtime.stats.set_stat(entity, ENERGY, StatBlock.VALUE_MAX)
	runtime.stats.set_stat(entity, MAX_ENERGY, StatBlock.VALUE_MAX)
	var registry: Registry = _preset([_definition(0, StatBlock.VALUE_MAX, StatBlock.VALUE_MAX), _definition(1, 0, 0), _definition(2, 0, 0)])
	assert_bool(runtime.grant_content(entity, registry, 0)).is_true()
	assert_bool(runtime.abilities.try_activate(entity, MovementAbilityData.Kind.DASH, 1000, false, runtime.stats)).is_true()
	assert_int(runtime.abilities.ready_tick(entity, MovementAbilityData.Kind.DASH)).is_equal(1000 + StatBlock.VALUE_MAX)
	assert_int(runtime.stats.get_stat(entity, ENERGY)).is_equal(0)
	assert_bool(runtime.grant_content(entity, null, 0)).is_false()
	assert_bool(runtime.grant_content(entity, Registry.new(), 0)).is_false()
	assert_bool(runtime.grant_content(entity, registry, 99)).is_false()
	var wrong_type := Registry.new()
	wrong_type.add_category(&"movement")
	wrong_type.register(0, &"dash", _definition(0))
	wrong_type.register(0, &"bad", Resource.new())
	wrong_type.register(0, &"slide", _definition(2))
	wrong_type.freeze()
	assert_bool(runtime.grant_content(entity, wrong_type, 0)).is_false()
	assert_int(runtime.abilities.ready_tick(entity, MovementAbilityData.Kind.DASH)).is_equal(1000 + StatBlock.VALUE_MAX)
