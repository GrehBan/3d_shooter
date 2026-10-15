extends GdUnitTestSuite

var _stats: StatBlock
var _pipeline: DamagePipeline
var _payloads: DamagePayloadBuffer
var _target: int


func before_test() -> void:
	_stats = StatBlock.new(2)
	_target = _stats.allocate()
	_stats.set_stat(_target, StatBlock.Stat.HP, 10_000)
	_stats.set_stat(_target, StatBlock.Stat.SHIELD, 2_000)
	_stats.set_stat(_target, StatBlock.Stat.ARMOR, 25_000)
	_pipeline = DamagePipeline.new(_stats)
	_payloads = DamagePayloadBuffer.new(3)


func _push(amount: int = 6_000, target: int = -2) -> int:
	return _payloads.push(0x7FFFFFFFFFFFFFFF, _target if target == -2 else target, amount,
			DamagePayload.Element.NONE, -1, 0, 40_000 * 65_536 + 7)


func _snapshot() -> PackedInt64Array:
	var result := PackedInt64Array([_payloads.count(), _payloads.front_slot()])
	for index: int in _payloads.count():
		var slot: int = _payloads.slot_at(index)
		result.append_array(PackedInt64Array([slot, _payloads.get_source(slot),
				_payloads.get_target(slot), _payloads.get_attack_context(slot),
				_payloads.get_amount(slot), _payloads.get_element(slot),
				_payloads.get_tags(slot), _payloads.get_flags(slot), _payloads.get_phase(slot)]))
	return result


func _expect_first_error() -> void:
	var notification: GdUnitGodotErrorAssert = assert_error(func() -> void:
		assert_int(_pipeline.resolve_front(_payloads)).is_equal(DamagePipeline.INVALID_RESULT))
	await notification.is_push_error(DamagePipeline.INVALID_PAYLOAD_ERROR)
	var logger: GodotGdErrorMonitor.GdUnitLogger = notification.get("_logger")
	assert_int(logger.entries().size()).is_equal(1)


func test_front_only_physical_shield_armor_and_opaque_metadata() -> void:
	var slot: int = _push()
	var next: int = _push(1_000)
	assert_int(_pipeline.resolve_front(_payloads)).is_equal(3_000)
	assert_int(_stats.get_stat(_target, StatBlock.Stat.HP)).is_equal(7_000)
	assert_int(_stats.get_stat(_target, StatBlock.Stat.SHIELD)).is_equal(0)
	assert_int(_stats.get_stat(_target, StatBlock.Stat.ARMOR)).is_equal(25_000)
	assert_int(_payloads.count()).is_equal(2)
	assert_int(_payloads.front_slot()).is_equal(slot)
	assert_int(_payloads.get_phase(slot)).is_equal(DamagePayload.Phase.POST_HIT)
	assert_int(_payloads.get_phase(next)).is_equal(DamagePayload.Phase.BASE)
	assert_int(_payloads.get_source(slot)).is_equal(0x7FFFFFFFFFFFFFFF)
	assert_int(_payloads.get_attack_context(slot)).is_equal(40_000 * 65_536 + 7)
	assert_int(_payloads.get_tags(slot)).is_equal(-1)
	assert_int(_payloads.get_amount(slot)).is_equal(6_000)
	assert_int(_pipeline.configuration_errors).is_equal(0)


func test_empty_is_normal_and_zero_damage_does_not_normalize_stats() -> void:
	assert_int(_pipeline.resolve_front(_payloads)).is_equal(DamagePipeline.INVALID_RESULT)
	_stats.set_stat(_target, StatBlock.Stat.SHIELD, -500)
	var slot: int = _push(0)
	assert_int(_pipeline.resolve_front(_payloads)).is_equal(0)
	assert_int(_stats.get_stat(_target, StatBlock.Stat.SHIELD)).is_equal(-500)
	assert_int(_stats.get_stat(_target, StatBlock.Stat.HP)).is_equal(10_000)
	assert_int(_payloads.get_phase(slot)).is_equal(DamagePayload.Phase.POST_HIT)
	assert_int(_pipeline.configuration_errors).is_equal(0)


func test_stale_and_dead_targets_complete_without_shield_or_hp_writes() -> void:
	var stale: int = _target
	_stats.release(stale)
	_target = _stats.allocate()
	_stats.set_stat(_target, StatBlock.Stat.HP, 10_000)
	_stats.set_stat(_target, StatBlock.Stat.SHIELD, 2_000)
	var slot: int = _push(6_000, stale)
	assert_int(_pipeline.resolve_front(_payloads)).is_equal(0)
	assert_int(_payloads.get_phase(slot)).is_equal(DamagePayload.Phase.POST_HIT)
	assert_int(_stats.get_stat(_target, StatBlock.Stat.HP)).is_equal(10_000)
	assert_int(_stats.get_stat(_target, StatBlock.Stat.SHIELD)).is_equal(2_000)
	_payloads.pop_front()
	_stats.set_stat(_target, StatBlock.Stat.HP, -1)
	slot = _push()
	assert_int(_pipeline.resolve_front(_payloads)).is_equal(0)
	assert_int(_payloads.get_phase(slot)).is_equal(DamagePayload.Phase.POST_HIT)
	assert_int(_stats.get_stat(_target, StatBlock.Stat.HP)).is_equal(-1)
	assert_int(_stats.get_stat(_target, StatBlock.Stat.SHIELD)).is_equal(2_000)
	assert_int(_pipeline.configuration_errors).is_equal(0)


func test_rejection_is_atomic_counts_every_attempt_and_reset_preserves_queue() -> void:
	var slot: int = _push(-1)
	_push()
	var before: PackedInt64Array = _snapshot()
	await _expect_first_error()
	await assert_error(func() -> void:
		assert_int(_pipeline.resolve_front(_payloads)).is_equal(-1)).is_success()
	assert_int(_pipeline.configuration_errors).is_equal(2)
	assert_array(_snapshot()).is_equal(before)
	assert_int(_stats.get_stat(_target, StatBlock.Stat.HP)).is_equal(10_000)
	assert_int(_stats.get_stat(_target, StatBlock.Stat.SHIELD)).is_equal(2_000)
	_pipeline.reset_counters()
	assert_int(_pipeline.configuration_errors).is_equal(0)
	assert_array(_snapshot()).is_equal(before)
	await _expect_first_error()
	assert_int(_pipeline.configuration_errors).is_equal(1)
	_payloads.set_amount(slot, 6_000)
	assert_int(_pipeline.resolve_front(_payloads)).is_equal(3_000)
	await assert_error(func() -> void:
		assert_int(_pipeline.resolve_front(_payloads)).is_equal(-1)).is_success()
	assert_int(_pipeline.configuration_errors).is_equal(2)
	assert_int(_stats.get_stat(_target, StatBlock.Stat.HP)).is_equal(7_000)


func test_unsupported_elements_flags_and_each_non_base_phase_reject_before_target() -> void:
	var slot: int = _push(1_000, -1)
	for element: int in range(DamagePayload.Element.ELECTRIC, DamagePayload.Element.ACID + 1):
		_payloads.set_element(slot, element as DamagePayload.Element)
		_pipeline.reset_counters()
		var before: PackedInt64Array = _snapshot()
		await _expect_first_error()
		assert_array(_snapshot()).is_equal(before)
	_payloads.set_element(slot, DamagePayload.Element.NONE)
	for flag: int in [DamagePayload.Flag.CRIT, DamagePayload.Flag.DOT, DamagePayload.Flag.SECONDARY, -1]:
		_payloads.set_flags(slot, flag)
		_pipeline.reset_counters()
		var before: PackedInt64Array = _snapshot()
		await _expect_first_error()
		assert_array(_snapshot()).is_equal(before)
	_payloads.set_flags(slot, 0)
	for phase: int in range(DamagePayload.Phase.ADD, DamagePayload.Phase.POST_HIT + 1):
		_payloads.set_phase(slot, phase as DamagePayload.Phase)
		_pipeline.reset_counters()
		var before: PackedInt64Array = _snapshot()
		await _expect_first_error()
		assert_array(_snapshot()).is_equal(before)
	assert_int(_stats.get_stat(_target, StatBlock.Stat.HP)).is_equal(10_000)
	assert_int(_stats.get_stat(_target, StatBlock.Stat.SHIELD)).is_equal(2_000)


func test_full_int64_amount_saturates_hp_without_overflow() -> void:
	var slot: int = _push(0x7FFFFFFFFFFFFFFF)
	assert_int(_pipeline.resolve_front(_payloads)).is_equal(10_000)
	assert_int(_stats.get_stat(_target, StatBlock.Stat.HP)).is_equal(0)
	assert_int(_stats.get_stat(_target, StatBlock.Stat.SHIELD)).is_equal(0)
	assert_int(_payloads.get_amount(slot)).is_equal(0x7FFFFFFFFFFFFFFF)


func _active_iteration() -> int:
	_stats.set_stat(_target, StatBlock.Stat.HP, 10_000)
	_stats.set_stat(_target, StatBlock.Stat.SHIELD, 2_000)
	_push()
	var applied: int = _pipeline.resolve_front(_payloads)
	_payloads.pop_front()
	return applied


func test_active_hot_path_no_allocations() -> void:
	for index: int in 300:
		_active_iteration()
	var objects_before: int = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var nodes_before: int = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var resources_before: int = int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT))
	var memory_before: int = int(Performance.get_monitor(Performance.MEMORY_STATIC))
	var damage: int = 0
	for index: int in 20_000:
		damage += _active_iteration()
	var objects_delta: int = int(Performance.get_monitor(Performance.OBJECT_COUNT)) - objects_before
	var nodes_delta: int = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)) - nodes_before
	var resources_delta: int = int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)) - resources_before
	var memory_delta: int = int(Performance.get_monitor(Performance.MEMORY_STATIC)) - memory_before
	assert_int(objects_delta).is_equal(0)
	assert_int(nodes_delta).is_equal(0)
	assert_int(resources_delta).is_equal(0)
	assert_int(memory_delta).is_equal(0)
	assert_int(damage).is_equal(60_000_000)
	assert_int(_pipeline.configuration_errors).is_equal(0)
	assert_int(_payloads.dropped_count()).is_equal(0)


func test_suppressed_invalid_hot_path_no_allocations() -> void:
	_push(-1)
	await _expect_first_error()
	var objects_before: int = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var memory_before: int = int(Performance.get_monitor(Performance.MEMORY_STATIC))
	var result: int = 0
	for index: int in 20_000:
		result += _pipeline.resolve_front(_payloads)
	var objects_delta: int = int(Performance.get_monitor(Performance.OBJECT_COUNT)) - objects_before
	var memory_delta: int = int(Performance.get_monitor(Performance.MEMORY_STATIC)) - memory_before
	assert_int(objects_delta).is_equal(0)
	assert_int(memory_delta).is_equal(0)
	assert_int(result).is_equal(-20_000)
	assert_int(_pipeline.configuration_errors).is_equal(20_001)


func test_resolver_scratch_failure_closes_tree_without_negative_hit_and_resets() -> void:
	var batch := ShotBatch.new(1, 1, 1)
	var resolver := ShotResolver.new(_stats, batch, 4)
	var scratch: DamagePayloadBuffer = resolver.get("_payloads") as DamagePayloadBuffer
	scratch.push(0, _target, 1_000, DamagePayload.Element.NONE, 0, 0, -1)
	var ticket: int = batch.reserve(65_536, 1, 1_000)
	batch.write_trace(ticket, 0, _target)
	batch.publish(ticket)
	await assert_error(func() -> void: resolver.logic_step(0)).is_push_error(
			"DamagePayloadBuffer: переполнение, записи отбрасываются")
	assert_int(resolver.damage_configuration_errors()).is_equal(1)
	assert_int(resolver.registered_hits).is_equal(0)
	assert_int(resolver.kills).is_equal(0)
	assert_int(resolver.contexts.alive_count()).is_equal(0)
	assert_int(resolver.resolved_shots).is_equal(1)
	assert_int(_stats.get_stat(_target, StatBlock.Stat.HP)).is_equal(10_000)
	assert_bool(resolver.reset_room()).is_true()
	assert_int(scratch.count()).is_equal(0)
	assert_int(resolver.damage_configuration_errors()).is_equal(0)
	ticket = batch.reserve(65_536, 1, 1_000)
	batch.write_trace(ticket, 0, _target)
	batch.publish(ticket)
	resolver.logic_step(0)
	assert_int(resolver.registered_hits).is_equal(1)
	assert_int(resolver.damage_configuration_errors()).is_equal(0)
	assert_int(resolver.contexts.alive_count()).is_equal(0)
