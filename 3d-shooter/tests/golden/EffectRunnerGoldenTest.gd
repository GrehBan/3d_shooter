extends GdUnitTestSuite
## Independent oracle: tests/tools/effect_runner_ref.py.
## Trace covers quota continuation, copied rules, full handles, mutation and reset.

const HIGH: int = 40000 * 65536
const INT64_MAX: int = 0x7FFFFFFFFFFFFFFF

var _hash: int


func _word(value: int) -> void:
	_hash = ((_hash ^ (value & 0xFFFFFFFF)) * 16777619) & 0xFFFFFFFF
	_hash = ((_hash ^ ((value >> 32) & 0xFFFFFFFF)) * 16777619) & 0xFFFFFFFF


func _rule(condition: EffectRuleData.Condition, minimum: int, increment: int, cooldown: int) -> EffectRuleData:
	var rule := EffectRuleData.new()
	rule.condition = condition
	rule.minimum_value = minimum
	rule.counter_increment = increment
	rule.cooldown_ticks = cooldown
	return rule


func _add(host: EffectHost, owner: int, rule: int, phase: EffectTrigger.Phase, priority: int, slot: int) -> int:
	var entry: int = host.add_effect(owner, EffectTrigger.Trigger.ON_HIT, phase, priority, slot, rule, 123)
	_word(entry)
	return entry


func _enqueue(runner: EffectRunner, owner: int, value: int) -> void:
	_word(1 if runner.enqueue(owner, EffectTrigger.Trigger.ON_HIT, value) else 0)


func _record(runner: EffectRunner, label: int, watches: PackedInt64Array) -> void:
	_word(label)
	for value: int in [runner.accepted_events, runner.processed_events,
			runner.inspected_candidates, runner.executed_actions, runner.condition_refusals,
			runner.cooldown_refusals, runner.stale_skips, runner.deferred_steps,
			runner.configuration_errors, runner.dropped_events, runner.pending_count(), watches.size()]:
		_word(value)
	for entry: int in watches:
		_word(runner.counter_for(entry))


func test_fifo_mutation_full_owner_cooldown_and_room_reset_golden() -> void:
	var stats := StatBlock.new(1)
	stats.allocate()
	var snapshot: Dictionary = stats.get_state()
	snapshot.generation[0] = 40000
	assert_bool(stats.set_state(snapshot)).is_true()
	var host := EffectHost.new(1, 8)
	var rules: Array[EffectRuleData] = [
		_rule(EffectRuleData.Condition.ALWAYS, 0, 1, 0),
		_rule(EffectRuleData.Condition.MIN_VALUE, 5, 7, 0),
		_rule(EffectRuleData.Condition.ALWAYS, 0, 3, 2),
		_rule(EffectRuleData.Condition.MIN_VALUE, 6, 11, 0),
	]
	var runner := EffectRunner.new(stats, host, rules, 3, 4, 3)
	assert_bool(runner.is_initialized()).is_true()
	# A post-construction definition mutation must not change executable rules.
	rules[0].counter_increment = 100
	_hash = 2166136261
	var a: int = _add(host, HIGH, 0, EffectTrigger.Phase.MAIN, 0, 2)
	var b: int = _add(host, HIGH, 1, EffectTrigger.Phase.PRE, 10, 1)
	var c: int = _add(host, HIGH, 2, EffectTrigger.Phase.MAIN, 0, 1)
	var d: int = _add(host, HIGH, 3, EffectTrigger.Phase.POST, -4, 0)
	var watches := PackedInt64Array([a, b, c, d])
	_enqueue(runner, HIGH, 5)
	_enqueue(runner, HIGH, 6)
	var ticks := PackedInt64Array([0, 0, 1, 0, 2])
	for label: int in ticks.size():
		_word(runner.logic_step(ticks[label]))
		_record(runner, label, watches)

	_enqueue(runner, HIGH, 6)
	_word(1 if host.remove_effect(b) else 0)
	var b2: int = _add(host, HIGH, 1, EffectTrigger.Phase.PRE, 10, 1)
	_word(runner.logic_step(3))
	_record(runner, 5, PackedInt64Array([a, b2, c, d]))
	_word(1 if host.remove_effect(d) else 0)
	_word(runner.logic_step(4))
	_record(runner, 6, PackedInt64Array([a, b2, c]))

	_enqueue(runner, HIGH, 6)
	_word(1 if stats.release(HIGH) else 0)
	var owner: int = stats.allocate()
	_word(owner)
	_enqueue(runner, HIGH, 6)
	_word(runner.logic_step(5))
	_record(runner, 7, PackedInt64Array())
	var e: int = _add(host, owner, 2, EffectTrigger.Phase.PRE, 0, 0)
	assert_int(stats.get_stat(owner, StatBlock.Stat.HP)).is_equal(0)
	_enqueue(runner, owner, 0)
	_enqueue(runner, owner, 0)
	_word(runner.logic_step(6))
	_record(runner, 8, PackedInt64Array([e]))
	_enqueue(runner, owner, 0)
	_word(runner.logic_step(7))
	_record(runner, 9, PackedInt64Array([e]))
	_enqueue(runner, owner, 0)
	_word(runner.logic_step(8))
	_record(runner, 10, PackedInt64Array([e]))
	_enqueue(runner, owner, 0)
	runner.reset_diagnostics()
	_record(runner, 11, PackedInt64Array([e]))
	_word(runner.logic_step(8))
	_record(runner, 12, PackedInt64Array([e]))
	_word(runner.logic_step(10))
	_record(runner, 13, PackedInt64Array([e]))

	_enqueue(runner, owner, 0)
	runner.reset_room()
	_record(runner, 14, PackedInt64Array([e]))
	_word(runner.logic_step(0))
	_enqueue(runner, owner, 0)
	_word(runner.logic_step(0))
	_record(runner, 15, PackedInt64Array([e]))
	_word(runner.logic_step(1))
	_record(runner, 16, PackedInt64Array([e]))
	var late_ticks := PackedInt64Array([INT64_MAX - 2, INT64_MAX - 1, INT64_MAX])
	for index: int in late_ticks.size():
		_enqueue(runner, owner, 0)
		_word(runner.logic_step(late_ticks[index]))
		_record(runner, 17 + index, PackedInt64Array([e]))
	assert_int(_hash).is_equal(3633298175)  # Independent Python oracle, 343 words.
	assert_int(runner.counter_for(e)).is_equal(9)
	assert_int(runner.executed_actions).is_equal(3)
	assert_int(runner.cooldown_refusals).is_equal(1)
	assert_int(runner.configuration_errors).is_equal(0)
	assert_int(runner.dropped_events).is_equal(0)
	assert_int(runner.pending_count()).is_equal(0)
