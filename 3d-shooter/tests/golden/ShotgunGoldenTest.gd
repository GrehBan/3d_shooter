extends GdUnitTestSuite
## Oracle: tests/tools/shotgun_ref.py. Legacy queue and synthetic references are untouched.

var _hash: int


func _word(value: int) -> void:
	_hash = ((_hash ^ (value & 0xFFFFFFFF)) * 16777619) & 0xFFFFFFFF
	_hash = ((_hash ^ ((value >> 32) & 0xFFFFFFFF)) * 16777619) & 0xFFFFFFFF


func _fire(source: int, epoch: int, sequence: int, _root: int) -> void:
	_word(0)
	_word(source)
	_word(epoch)
	_word(sequence)


func _hit(source: int, target: int, _epoch: int, _sequence: int, trace: int,
		_child: int, damage: int) -> void:
	_word(1)
	_word(source)
	_word(target)
	_word(trace)
	_word(damage)


func _kill(source: int, target: int, _epoch: int, _sequence: int, trace: int) -> void:
	_word(2)
	_word(source)
	_word(target)
	_word(trace)


func _resolved(source: int, epoch: int, sequence: int, _root: int) -> void:
	_word(3)
	_word(source)
	_word(epoch)
	_word(sequence)


func test_canonical_shots_pellet_posthit_death_and_zero_damage_golden() -> void:
	var stats := StatBlock.new(4)
	for index: int in 4:
		stats.allocate()
	var snapshot: Dictionary = stats.get_state()
	snapshot.generation[0] = 40000
	assert_bool(stats.set_state(snapshot)).is_true()
	const LARGE: int = 40000 * HandlePool.INDEX_SPAN
	stats.set_stat(2, StatBlock.Stat.HP, 10000)
	stats.set_stat(2, StatBlock.Stat.SHIELD, 6000)
	stats.set_stat(3, StatBlock.Stat.HP, 100000)
	stats.set_stat(3, StatBlock.Stat.ARMOR, 100000)
	var batch := ShotBatch.new(4, 8, 4)
	var resolver := ShotResolver.new(stats, batch, 64)
	resolver.on_fire.connect(_fire)
	resolver.on_hit.connect(_hit)
	resolver.on_kill.connect(_kill)
	resolver.on_attack_resolved.connect(_resolved)
	var high: int = batch.reserve(LARGE, 8, 6000)
	var low: int = batch.reserve(1, 8, 6000)
	var low_next: int = batch.reserve(1, 3, 6000)
	var pattern: PackedInt64Array = [3, 2, -1, 2, 2, 2, 2, 2]
	for trace: int in 8:
		batch.write_trace(high, 7 - trace, 2)
		batch.write_trace(low, trace, pattern[trace])
	for trace: int in 3:
		batch.write_trace(low_next, trace, 3)
	batch._target[2 * 8 + 3] = 3  # A live poisoned tail must not create a fourth hit.
	batch.publish(low_next)
	batch.publish(high)
	batch.publish(low)
	_hash = 2166136261
	resolver.logic_step(0)
	_word(stats.get_stat(2, StatBlock.Stat.HP))
	_word(stats.get_stat(2, StatBlock.Stat.SHIELD))
	_word(stats.get_stat(3, StatBlock.Stat.HP))
	_word(stats.get_stat(3, StatBlock.Stat.SHIELD))
	_word(resolver.registered_hits)
	_word(resolver.kills)
	_word(resolver.no_op_traces)
	_word(resolver.resolved_shots)
	assert_int(_hash).is_equal(3770191677)  # Independent Python oracle.
	assert_int(resolver.registered_hits).is_equal(7)
	assert_int(resolver.kills).is_equal(1)
	assert_int(resolver.no_op_traces).is_equal(12)
	assert_int(resolver.resolved_shots).is_equal(3)
	assert_int(batch.configuration_errors).is_equal(0)
	assert_int(resolver.contexts.capacity_refusals).is_equal(0)
	assert_int(resolver.contexts.hit_set_overflows).is_equal(0)
