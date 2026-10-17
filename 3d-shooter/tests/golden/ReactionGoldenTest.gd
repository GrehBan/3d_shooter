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
	stats.set_stat(6, StatBlock.Stat.ARMOR, 50000)
	stats.set_stat(7, StatBlock.Stat.SHIELD, 2000)
	stats.set_stat(8, StatBlock.Stat.HP, 3000)
	var statuses := StatusRuntime.new(stats)
	var reactions := ReactionRuntime.new(stats, statuses)
	for index: int in 12:
		statuses.register_target(index)
		var team: int = 2  # source 0 and ally 2 are team 1, 3 is neutral
		if index == 0 or index == 2:
			team = 1
		elif index == 3:
			team = 0
		reactions.register_target(index, team, index == 9 or index == 11)
	var batch := ShotBatch.new(4, 8, 12, 8)
	var resolver := ShotResolver.new(stats, batch, 128, statuses, reactions)
	resolver.on_hit.connect(_on_hit)
	resolver.on_kill.connect(_on_kill)
	resolver.on_secondary_hit.connect(_on_secondary_hit)
	resolver.on_secondary_kill.connect(_on_secondary_kill)
	# [tick, source, element, raw, [[primary, [candidates]], ...], {handle: hp before the shot}]
	var shots: Array = [
		# Ally 2, neutral 3 and dead 4 sort below the eligible 5, 6, 7: the filters must drop them.
		[1, 0, ELECTRIC, 10003, [[1, [2, 3, 4, 5, 6, 7]]], {4: 0}],
		[2, 0, ACID, 1000, [[1, []]], {}],
		[3, 0, ELECTRIC, 2000, [[1, [11, 10, 9, 8, 7, 6, 5, 2]]], {}],
		[4, 0, FIRE, 10000, [[10, []]], {}],
		[5, 0, ACID, 1000, [[10, []]], {}],
		# 10 burns and is corroded; the explosion kills it and its statuses go at once.
		[6, 0, FIRE, 10000, [[1, [10, 11, 9, 8]]], {10: 1500}],
		[7, 0, ELECTRIC, 4000, [[9, [1, 2, 9, 11]]], {}],
		[8, 0, ELECTRIC, 1000, [[7, [5]]], {}],
		[9, 3, ELECTRIC, 3000, [[5, [6]]], {}],
		[10, 0, ELECTRIC, 3000, [[2, [5]], [3, [5]]], {}],
		[11, 0, ELECTRIC, 10000, [[9, [11, 5]]], {9: 500}],
		[12, 0, ELECTRIC, 2000, [[5, [6, 11]], [5, [6, 11]]], {}],
		# WET 11 is not corroded: conduction reaches the three eligible targets, arcs would hit two.
		[13, 0, ELECTRIC, 2000, [[11, [8, 7, 6, 5, 10, 2]]], {}],
		[14, 0, ACID, 1000, [[11, []]], {}],
		# Only the ally and the neutral stand nearby: the explosion still fires and takes the acid.
		[15, 0, FIRE, 2000, [[11, [2, 3]]], {}],
		[16, 0, FIRE, 2000, [[11, [6, 5]]], {}],  # no acid left: no explosion
		[17, 0, ACID, 1000, [[11, []]], {}],
		[18, 0, FIRE, 2000, [[11, [6, 5]]], {}],
	]
	var corroded_before_explosion: int = 0
	var acid_after_empty_explosion: int = -1
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
		if _tick == 6:
			corroded_before_explosion = statuses.acid_stacks(1)
		resolver.logic_step(_tick)
		if _tick == 15:
			acid_after_empty_explosion = statuses.acid_stacks(11)
		_record(PackedInt64Array([300, _tick]))
		for handle: int in 12:
			_record(PackedInt64Array([stats.get_stat(handle, StatBlock.Stat.HP),
					stats.get_stat(handle, StatBlock.Stat.SHIELD), statuses.acid_stacks(handle),
					statuses.burn_field(handle, StatusRuntime.Field64.BURN_UNTIL)]))
	assert_int(_hash).is_equal(3107360089)
	assert_int(_words).is_equal(1170)
	assert_int(_secondary_hits).is_equal(23)
	assert_int(_secondary_kills).is_equal(2)
	assert_int(corroded_before_explosion).is_equal(1)
	assert_int(reactions.arcs).is_equal(3)  # t1 and both pellets of t12
	assert_int(reactions.conducting).is_equal(4)  # corroded t3, WET t7, t11 and t13
	assert_int(reactions.explosions).is_equal(3)  # t6, t15 (no eligible target) and t18
	assert_int(reactions.empty_reactions).is_equal(1)
	assert_int(acid_after_empty_explosion).is_equal(0)  # the empty explosion took the acid
	assert_int(statuses.acid_stacks(11)).is_equal(0)  # consumed by the t18 explosion
	assert_int(statuses.acid_stacks(10)).is_equal(0)  # the secondary kill cleared it at once
	assert_int(reactions.configuration_errors).is_equal(0)
	assert_int(resolver.damage_configuration_errors()).is_equal(0)
	assert_int(resolver.reaction_refusals).is_equal(0)
	assert_int(resolver.contexts.alive_count()).is_equal(0)
