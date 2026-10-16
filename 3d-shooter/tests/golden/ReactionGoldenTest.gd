extends GdUnitTestSuite
## M2.3b reactions through the real ShotResolver. Independent oracle:
## tests/tools/reaction_ref.py (reference()).

const FIRE := DamagePayload.Element.FIRE
const ELECTRIC := DamagePayload.Element.ELECTRIC
const ACID := DamagePayload.Element.ACID

var _hash: int
var _words: int
var _tick: int
var _secondary_hits: int
var _secondary_kills: int


func _word(value: int) -> void:
	_hash = ((_hash ^ (value & 0xFFFFFFFF)) * 16777619) & 0xFFFFFFFF
	_hash = ((_hash ^ ((value >> 32) & 0xFFFFFFFF)) * 16777619) & 0xFFFFFFFF
	_words += 1


func _record(values: PackedInt64Array) -> void:
	for value: int in values:
		_word(value)


func _on_hit(source: int, target: int, _epoch: int, _sequence: int, trace: int, _child: int,
		damage: int) -> void:
	_record(PackedInt64Array([100, _tick, source, target, trace, damage]))


func _on_kill(source: int, target: int, _epoch: int, _sequence: int, _trace: int) -> void:
	_record(PackedInt64Array([101, _tick, source, target]))


func _on_secondary_hit(source: int, target: int, _epoch: int, _sequence: int, trace: int,
		_child: int, damage: int) -> void:
	_secondary_hits += 1
	_record(PackedInt64Array([200, _tick, source, target, trace, damage]))


func _on_secondary_kill(source: int, target: int, _epoch: int, _sequence: int, _trace: int) -> void:
	_secondary_kills += 1
	_record(PackedInt64Array([201, _tick, source, target]))


func test_arcs_conduction_explosion_and_gates_golden() -> void:
	_hash = 2166136261
	_words = 0
	_secondary_hits = 0
	_secondary_kills = 0
	var stats := StatBlock.new(12)
	for index: int in 12:
		stats.allocate()
		stats.set_stat(index, StatBlock.Stat.HP, 1000000)
	stats.set_stat(3, StatBlock.Stat.ARMOR, 50000)
	stats.set_stat(4, StatBlock.Stat.SHIELD, 2000)
	stats.set_stat(6, StatBlock.Stat.HP, 3000)
	var statuses := StatusRuntime.new(stats)
	var reactions := ReactionRuntime.new(stats, statuses)
	for index: int in 12:
		statuses.register_target(index)
		var team: int = 2
		if index == 0 or index == 10:
			team = 1
		elif index == 11:
			team = 0
		reactions.register_target(index, team, index == 9)
	var batch := ShotBatch.new(4, 8, 12, 8)
	var resolver := ShotResolver.new(stats, batch, 128, statuses, reactions)
	resolver.on_hit.connect(_on_hit)
	resolver.on_kill.connect(_on_kill)
	resolver.on_secondary_hit.connect(_on_secondary_hit)
	resolver.on_secondary_kill.connect(_on_secondary_kill)
	# [tick, source, element, raw, [[primary, [candidates]], ...], {handle: hp before the shot}]
	var shots: Array = [
		[1, 0, ELECTRIC, 10003, [[1, [5, 3, 11, 10, 2, 0, 1]]], {}],
		[2, 0, ACID, 1000, [[1, []]], {}],
		[3, 0, ELECTRIC, 2000, [[1, [8, 7, 6, 5, 4, 3]]], {}],
		[4, 0, FIRE, 10000, [[1, [6, 7, 8, 9]]], {}],
		[5, 0, FIRE, 10000, [[1, [7]]], {}],
		[6, 0, ELECTRIC, 4000, [[9, [1, 2, 7, 9]]], {}],
		[7, 0, ELECTRIC, 1000, [[4, [5]]], {}],
		[8, 11, ELECTRIC, 3000, [[2, [3]]], {}],
		[9, 0, ELECTRIC, 10000, [[8, [7, 5]]], {8: 500}],
		[10, 0, ELECTRIC, 2000, [[5, [3, 7]], [5, [3, 7]]], {}],
	]
	var corroded_before_explosion: int = 0
	for shot: Array in shots:
		_tick = shot[0]
		assert_bool(statuses.logic_step(_tick)).is_true()
		for handle: int in (shot[5] as Dictionary):
			stats.set_stat(handle, StatBlock.Stat.HP, shot[5][handle])
		var pellets: Array = shot[4]
		var ticket: int = batch.reserve(shot[1], pellets.size(), shot[3], shot[2])
		for trace: int in pellets.size():
			batch.write_trace(ticket, trace, pellets[trace][0])
			for candidate: int in pellets[trace][1]:
				assert_bool(batch.add_candidate(ticket, trace, candidate)).is_true()
		assert_bool(batch.publish(ticket)).is_true()
		if _tick == 4:
			corroded_before_explosion = statuses.acid_stacks(1)
		resolver.logic_step(_tick)
		_record(PackedInt64Array([300, _tick]))
		for handle: int in 12:
			_record(PackedInt64Array([stats.get_stat(handle, StatBlock.Stat.HP),
					stats.get_stat(handle, StatBlock.Stat.SHIELD), statuses.acid_stacks(handle)]))
	assert_int(_hash).is_equal(2234811627)
	assert_int(_words).is_equal(568)
	assert_int(_secondary_hits).is_equal(19)
	assert_int(_secondary_kills).is_equal(1)
	assert_int(corroded_before_explosion).is_equal(1)
	assert_int(reactions.arcs).is_equal(4)  # t1, t9 and both pellets of t10
	assert_int(reactions.conducting).is_equal(2)  # corroded t3, WET t6
	assert_int(reactions.explosions).is_equal(1)
	assert_int(reactions.configuration_errors).is_equal(0)
	assert_int(resolver.damage_configuration_errors()).is_equal(0)
	assert_int(resolver.reaction_refusals).is_equal(0)
	assert_int(resolver.contexts.alive_count()).is_equal(0)
