extends GdUnitTestSuite

var _stats: StatBlock
var _host: EffectHost
var _owner: int
var _definitions: Array[EffectRuleData]
var _runner: EffectRunner
var _mutation_entry: int


func before_test() -> void:
	_stats = StatBlock.new(2)
	_owner = _stats.allocate()
	_host = EffectHost.new(2, 12)
	_definitions = [EffectRuleData.new()]
	_runner = EffectRunner.new(_stats, _host, _definitions, 4, 8, 1)


func _add(definition: int = 0, priority: int = 0) -> int:
	return _host.add_effect(_owner, EffectTrigger.Trigger.ON_HIT, EffectTrigger.Phase.MAIN,
			priority, 0, definition, 0)


func _enqueue(value: int = 6000) -> bool:
	return _runner.enqueue(_owner, EffectTrigger.Trigger.ON_HIT, value)


func test_fifo_one_candidate_quota_snapshots_priority_and_reuse() -> void:
	var first: int = _add(0, 0)
	var second: int = _add(0, 1)
	_enqueue()
	_enqueue()
	assert_int(_runner.logic_step(0)).is_equal(1)
	assert_int(_runner.counter_for(first)).is_equal(1)
	assert_int(_runner.counter_for(second)).is_equal(0)
	_host.remove_effect(second)
	var replacement: int = _add(0, -1)
	assert_int(_runner.logic_step(1)).is_equal(1)
	assert_int(_runner.counter_for(replacement)).is_equal(0)
	assert_int(_runner.processed_events).is_equal(1)
	_runner.logic_step(2)
	_runner.logic_step(3)
	assert_int(_runner.counter_for(first)).is_equal(2)
	assert_int(_runner.stale_skips).is_equal(2)
	assert_int(_runner.deferred_steps).is_equal(3)
	assert_int(_runner.pending_count()).is_equal(0)
	_enqueue()
	_runner.logic_step(4)
	assert_int(_runner.counter_for(replacement)).is_equal(1)
	assert_int(_runner.counter_for(second)).is_equal(0)


func test_conditions_cooldowns_and_stale_each_consume_quota() -> void:
	var conditional := EffectRuleData.new()
	conditional.condition = EffectRuleData.Condition.MIN_VALUE
	conditional.minimum_value = 6001
	var cooled := EffectRuleData.new()
	cooled.cooldown_ticks = 5
	_definitions = [conditional, cooled]
	_runner = EffectRunner.new(_stats, _host, _definitions, 4, 8, 1)
	_add(0, 0)
	var entry: int = _add(1, 1)
	_enqueue()
	_enqueue()
	for tick: int in 4:
		assert_int(_runner.logic_step(tick)).is_equal(1)
	assert_int(_runner.condition_refusals).is_equal(2)
	assert_int(_runner.cooldown_refusals).is_equal(1)
	assert_int(_runner.counter_for(entry)).is_equal(1)
	_enqueue()
	_stats.release(_owner)
	_runner.logic_step(4)
	_runner.logic_step(5)
	assert_int(_runner.stale_skips).is_equal(2)
	assert_int(_runner.counter_for(entry)).is_equal(0)


func test_cold_definition_copy_dead_valid_owner_and_int64_elapsed_cooldown() -> void:
	_definitions[0].counter_increment = 2
	_definitions[0].cooldown_ticks = 2
	_runner = EffectRunner.new(_stats, _host, _definitions)
	var entry: int = _add()
	_definitions[0].counter_increment = 100
	_definitions[0].cooldown_ticks = 0
	_stats.set_stat(_owner, StatBlock.Stat.HP, 0)
	_enqueue()
	_runner.logic_step(EffectRunner.MAX_INT - 2)
	_enqueue()
	_runner.logic_step(EffectRunner.MAX_INT - 1)
	_enqueue()
	_runner.logic_step(EffectRunner.MAX_INT)
	assert_int(_runner.counter_for(entry)).is_equal(4)
	assert_int(_runner.cooldown_refusals).is_equal(1)


func test_counter_overflow_is_atomic_and_diagnostic_reset_preserves_state() -> void:
	_definitions[0].counter_increment = EffectRunner.MAX_INT
	_runner = EffectRunner.new(_stats, _host, _definitions)
	var entry: int = _add()
	_enqueue()
	_runner.logic_step(0)
	_enqueue()
	await assert_error(func() -> void: _runner.logic_step(1)).is_push_error(EffectRunner.CONFIGURATION_ERROR)
	assert_int(_runner.counter_for(entry)).is_equal(EffectRunner.MAX_INT)
	assert_int(_runner.executed_actions).is_equal(1)
	assert_int(_runner.configuration_errors).is_equal(1)
	_enqueue()
	_runner.reset_diagnostics()
	assert_int(_runner.pending_count()).is_equal(1)
	assert_int(_runner.accepted_events).is_equal(3)
	assert_int(_runner.logic_step(1)).is_equal(0)
	assert_int(_runner.counter_for(entry)).is_equal(EffectRunner.MAX_INT)
	await assert_error(func() -> void: _runner.logic_step(2)).is_push_error(EffectRunner.CONFIGURATION_ERROR)
	assert_int(_runner.executed_actions).is_equal(1)


func test_queue_and_snapshot_overflow_reject_whole_event() -> void:
	_runner = EffectRunner.new(_stats, _host, _definitions, 1, 1, 1)
	var entry: int = _add()
	_enqueue()
	await assert_error(func() -> void: _enqueue()).is_push_error(EffectRunner.CONFIGURATION_ERROR)
	assert_int(_runner.accepted_events).is_equal(1)
	assert_int(_runner.pending_count()).is_equal(1)
	assert_int(_runner.dropped_events).is_equal(1)
	_runner.logic_step(0)
	assert_int(_runner.counter_for(entry)).is_equal(1)
	_add()
	await assert_error(func() -> void: _enqueue()).is_success()
	assert_int(_runner.pending_count()).is_equal(0)
	assert_int(_runner.configuration_errors).is_equal(2)
	assert_int(_runner.dropped_events).is_equal(2)
	assert_int(_runner.counter_for(entry)).is_equal(1)


func test_invalid_input_unknown_definition_and_empty_match() -> void:
	assert_bool(_enqueue()).is_true()
	assert_int(_runner.accepted_events).is_equal(0)
	assert_bool(_runner.enqueue(-1, EffectTrigger.Trigger.ON_HIT, 0)).is_false()
	await assert_error(func() -> void: _enqueue(-1)).is_push_error(EffectRunner.CONFIGURATION_ERROR)
	await assert_error(func() -> void:
		_runner.enqueue(_owner, -1 as EffectTrigger.Trigger, 0)).is_success()
	_add(4)
	await assert_error(func() -> void: _enqueue()).is_success()
	assert_int(_runner.configuration_errors).is_equal(3)
	assert_int(_runner.dropped_events).is_equal(0)
	assert_int(_runner.pending_count()).is_equal(0)


func test_clock_pause_and_room_reset_preserve_subscriptions_only() -> void:
	var entry: int = _add()
	assert_int(_runner.logic_step(10)).is_equal(0)
	_enqueue()
	assert_int(_runner.logic_step(10)).is_equal(0)
	assert_int(_runner.logic_step(9)).is_equal(0)
	assert_int(_runner.logic_step(-1)).is_equal(0)
	assert_int(_runner.pending_count()).is_equal(1)
	_runner.logic_step(11)
	_enqueue()
	_runner.reset_room()
	assert_int(_runner.pending_count()).is_equal(0)
	assert_int(_runner.accepted_events).is_equal(0)
	assert_int(_runner.counter_for(entry)).is_equal(0)
	assert_int(_host.entry_count()).is_equal(1)
	_enqueue()
	_runner.logic_step(0)
	assert_int(_runner.counter_for(entry)).is_equal(1)


func test_full_entry_and_owner_handles_above_int32() -> void:
	var entry: int = _add()
	for index: int in 32769:
		_host.remove_effect(entry)
		entry = _add()
	assert_int(entry).is_greater(0x7FFFFFFF)
	_enqueue()
	_runner.logic_step(0)
	assert_int(_runner.counter_for(entry)).is_equal(1)
	_host.clear_host(_owner)
	for index: int in 32769:
		_stats.release(_owner)
		_owner = _stats.allocate()
	entry = _add()
	assert_int(_owner).is_greater(0x7FFFFFFF)
	_enqueue()
	_runner.logic_step(1)
	assert_int(_runner.counter_for(entry)).is_equal(1)


func test_invalid_cold_definitions_and_capacities_do_not_initialize() -> void:
	var corruptions: Array[Callable] = [
		func(d: EffectRuleData) -> void: d.minimum_value = -1,
		func(d: EffectRuleData) -> void: d.counter_increment = -1,
		func(d: EffectRuleData) -> void: d.cooldown_ticks = -1,
		func(d: EffectRuleData) -> void: d.condition = -1 as EffectRuleData.Condition,
		func(d: EffectRuleData) -> void: d.action = -1 as EffectRuleData.Action,
	]
	for corrupt: Callable in corruptions:
		var definition := EffectRuleData.new()
		corrupt.call(definition)
		var definitions: Array[EffectRuleData] = [definition]
		await assert_error(func() -> void:
			var runner := EffectRunner.new(_stats, _host, definitions)
			assert_bool(runner.is_initialized()).is_false()).is_push_error(EffectRunner.CONFIGURATION_ERROR)
	await assert_error(func() -> void:
		var runner := EffectRunner.new(_stats, _host, _definitions, 0)
		assert_bool(runner.is_initialized()).is_false()).is_push_error(EffectRunner.CONFIGURATION_ERROR)
	var mismatched := EffectHost.new(1, 1)
	await assert_error(func() -> void:
		var runner := EffectRunner.new(_stats, mismatched, _definitions)
		assert_bool(runner.is_initialized()).is_false()).is_push_error(EffectRunner.CONFIGURATION_ERROR)
	var excessive: Array[EffectRuleData] = []
	excessive.resize(65)
	await assert_error(func() -> void:
		var runner := EffectRunner.new(_stats, _host, excessive)
		assert_bool(runner.is_initialized()).is_false()).is_push_error(EffectRunner.CONFIGURATION_ERROR)
	var empty: Array[EffectRuleData] = []
	assert_bool(EffectRunner.new(_stats, _host, empty).is_initialized()).is_true()


func test_suppressed_configuration_refusals_have_no_allocations() -> void:
	_add(99)
	await assert_error(func() -> void: _enqueue()).is_push_error(EffectRunner.CONFIGURATION_ERROR)
	var objects_before: int = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var memory_before: int = int(Performance.get_monitor(Performance.MEMORY_STATIC))
	var accepted: int = 0
	for index: int in 20_000:
		if _enqueue():
			accepted += 1
	var objects_delta: int = int(Performance.get_monitor(Performance.OBJECT_COUNT)) - objects_before
	var memory_delta: int = int(Performance.get_monitor(Performance.MEMORY_STATIC)) - memory_before
	assert_int(objects_delta).is_equal(0)
	assert_int(memory_delta).is_equal(0)
	assert_int(accepted).is_equal(0)
	assert_int(_runner.configuration_errors).is_equal(20_001)


func _mutation_iteration(tick: int) -> void:
	_enqueue()
	_runner.logic_step(tick * 2)
	_host.remove_effect(_mutation_entry)
	_mutation_entry = _add(0, 1)
	_runner.logic_step(tick * 2 + 1)


func test_active_twenty_thousand_mutating_snapshots_have_no_allocations() -> void:
	var entry: int = _add()
	_mutation_entry = _add(0, 1)
	for tick: int in 300:
		_mutation_iteration(tick)
	var objects_before: int = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var nodes_before: int = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var resources_before: int = int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT))
	var orphans_before: int = int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	var memory_before: int = int(Performance.get_monitor(Performance.MEMORY_STATIC))
	for tick: int in range(300, 20300):
		_mutation_iteration(tick)
	var objects_delta: int = int(Performance.get_monitor(Performance.OBJECT_COUNT)) - objects_before
	var nodes_delta: int = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)) - nodes_before
	var resources_delta: int = int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)) - resources_before
	var orphans_delta: int = int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)) - orphans_before
	var memory_delta: int = int(Performance.get_monitor(Performance.MEMORY_STATIC)) - memory_before
	assert_int(objects_delta).is_equal(0)
	assert_int(nodes_delta).is_equal(0)
	assert_int(resources_delta).is_equal(0)
	assert_int(orphans_delta).is_equal(0)
	assert_int(memory_delta).is_equal(0)
	assert_int(_runner.counter_for(entry)).is_equal(20300)
	assert_int(_runner.counter_for(_mutation_entry)).is_equal(0)
	assert_int(_runner.executed_actions).is_equal(20300)
	assert_int(_runner.stale_skips).is_equal(20300)
	assert_int(_runner.inspected_candidates).is_equal(40600)
	assert_int(_runner.deferred_steps).is_equal(20300)
	assert_int(_runner.processed_events).is_equal(20300)
	assert_int(_runner.pending_count()).is_equal(0)
	assert_int(_runner.dropped_events).is_equal(0)
	assert_int(_runner.configuration_errors).is_equal(0)
