extends GdUnitTestSuite
## ReactionRuntime (M2.3b) through ShotResolver: gates, corrosion consumption, budgets,
## stale candidates, reentrancy and the secondary-only signal path.

var _stats: StatBlock
var _statuses: StatusRuntime
var _reactions: ReactionRuntime
var _batch: ShotBatch
var _resolver: ShotResolver
var _tick: int = 0
var _secondary: PackedInt64Array = PackedInt64Array()
var _primary_hits: int = 0
var _kill_on_hit: int = -1
var _reentry: PackedInt64Array = PackedInt64Array()


func before_test() -> void:
	_build(128)


func _build(contexts: int) -> void:
	_stats = StatBlock.new(8)
	for index: int in 8:
		_stats.allocate()
		_stats.set_stat(index, StatBlock.Stat.HP, 1_000_000)
	_statuses = StatusRuntime.new(_stats)
	_reactions = ReactionRuntime.new(_stats, _statuses)
	for index: int in 8:
		_statuses.register_target(index)
		_reactions.register_target(index, 1 if index == 0 else 2)
	_batch = ShotBatch.new(4, 8, 8, 8)
	_resolver = ShotResolver.new(_stats, _batch, contexts, _statuses, _reactions)
	_resolver.on_hit.connect(_on_hit)
	_resolver.on_secondary_hit.connect(_on_secondary)
	_tick = 0
	_secondary.clear()
	_primary_hits = 0
	_kill_on_hit = -1
	_reentry.clear()


func _shoot(element: DamagePayload.Element, raw: int, primary: int, candidates: Array,
		source: int = 0) -> void:
	_tick += 1
	_statuses.logic_step(_tick)
	var ticket: int = _batch.reserve(source, 1, raw, element)
	_batch.write_trace(ticket, 0, primary)
	for candidate: int in candidates:
		_batch.add_candidate(ticket, 0, candidate)
	_batch.publish(ticket)
	_resolver.logic_step(_tick)


func _on_hit(_source: int, _target: int, _epoch: int, _sequence: int, _trace: int, _child: int,
		_damage: int) -> void:
	_primary_hits += 1
	if _kill_on_hit >= 0:
		_stats.set_stat(_kill_on_hit, StatBlock.Stat.HP, 0)  # a listener kills a selected target


func _on_secondary(_source: int, target: int, _epoch: int, _sequence: int, _trace: int, _child: int,
		damage: int) -> void:
	_secondary.append(target)
	_secondary.append(damage)


func _try_reentry(_source: int, _target: int, _epoch: int, _sequence: int, _trace: int, _child: int,
		_damage: int) -> void:
	_reentry.append(int(_reactions.register_target(3, 2)))
	_reentry.append(int(_reactions.plan(0, 3, 1000, DamagePayload.Element.ELECTRIC)))
	_reentry.append(int(_reactions.reset_room()))
	_reactions.finish()  # refused while executing: the reaction keeps going


func test_arcs_skip_ally_neutral_and_dead_candidates_with_smaller_handles() -> void:
	# The ineligible 2, 3 and 4 sort first: without the filters they would take both arcs.
	_reactions.register_target(2, 1)  # an ally of the source
	_reactions.register_target(3, 0)  # neutral
	_stats.set_stat(4, StatBlock.Stat.HP, 0)  # dead
	_shoot(DamagePayload.Element.ELECTRIC, 10000, 1, [7, 6, 5, 4, 3, 2, 0, 1])
	assert_array(_secondary).is_equal(PackedInt64Array([5, 5000, 6, 5000]))
	assert_int(_reactions.arcs).is_equal(1)
	assert_int(_reactions.inspected_candidates).is_equal(8)
	assert_int(_reactions.stale_skips).is_equal(0)


func test_primary_that_is_neutral_or_on_the_source_team_never_reacts() -> void:
	_reactions.register_target(1, 0)  # neutral primary
	_reactions.register_target(2, 1)  # primary on the source's team
	_shoot(DamagePayload.Element.ELECTRIC, 10000, 1, [3, 4])
	_shoot(DamagePayload.Element.ELECTRIC, 10000, 2, [3, 4])
	assert_array(_secondary).is_empty()
	assert_int(_reactions.admitted_reactions).is_equal(0)
	assert_int(_primary_hits).is_equal(2)  # the hits themselves still land


func test_candidate_released_or_reused_between_physics_and_logic_is_skipped() -> void:
	_tick += 1
	_statuses.logic_step(_tick)
	var ticket: int = _batch.reserve(0, 1, 10000, DamagePayload.Element.ELECTRIC)
	_batch.write_trace(ticket, 0, 1)
	_batch.add_candidate(ticket, 0, 2)  # physics saw 2 and 3
	_batch.add_candidate(ticket, 0, 3)
	_batch.publish(ticket)
	_stats.release(2)  # 2 dies and its slot is reused before the logic tick
	var reused: int = _stats.allocate()
	_stats.set_stat(reused, StatBlock.Stat.HP, 1_000_000)
	_statuses.register_target(reused)
	_reactions.register_target(reused, 2)
	_stats.release(3)  # 3 is released and its slot stays free
	_resolver.logic_step(_tick)
	assert_array(_secondary).is_empty()  # neither the replacement nor a free slot is hit
	assert_int(_stats.get_stat(reused, StatBlock.Stat.HP)).is_equal(1_000_000)
	assert_int(_reactions.arcs).is_equal(1)


func test_room_reset_is_refused_during_a_reaction_and_resets_nothing() -> void:
	var combat := RoomCombat.new()
	var stats: StatBlock = combat.stats
	for index: int in 4:
		stats.allocate()
		stats.set_stat(index, StatBlock.Stat.HP, 1_000_000)
		combat.statuses.register_target(index)
		combat.reactions.register_target(index, 1 if index == 0 else 2)
	var batch := ShotBatch.new(4, 8, 16, 8)
	var resolver := ShotResolver.new(stats, batch, 128, combat.statuses, combat.reactions)
	var results := PackedInt64Array()
	resolver.on_secondary_hit.connect(func(_s: int, _t: int, _e: int, _q: int, _r: int, _c: int, _d: int) -> void:
		results.append(int(combat.reset_room())))
	combat.statuses.logic_step(1)
	var acid := batch.reserve(0, 1, 1000, DamagePayload.Element.ACID)
	batch.write_trace(acid, 0, 3)
	batch.publish(acid)
	resolver.logic_step(1)
	var ticket: int = batch.reserve(0, 1, 10000, DamagePayload.Element.ELECTRIC)
	batch.write_trace(ticket, 0, 1)
	batch.add_candidate(ticket, 0, 2)
	batch.add_candidate(ticket, 0, 3)
	batch.publish(ticket)
	combat.statuses.logic_step(2)
	await assert_error(func() -> void: resolver.logic_step(2)).is_push_error(ReactionRuntime.CONFIGURATION_ERROR)
	assert_int(results.size()).is_equal(2)
	assert_bool(results.has(1)).is_false()
	assert_int(combat.statuses.acid_stacks(3)).is_equal(1)  # nothing was reset
	assert_int(combat.reactions.secondary_hits).is_equal(2)
	assert_bool(combat.reset_room()).is_true()  # quiescent again
	assert_int(combat.statuses.acid_stacks(3)).is_equal(0)


func test_no_reaction_without_hp_damage_team_or_reactive_element() -> void:
	_stats.set_stat(1, StatBlock.Stat.SHIELD, 20000)
	_shoot(DamagePayload.Element.ELECTRIC, 10000, 1, [2])  # shield only: no HP damage
	_reactions.register_target(0, 0)  # neutral source
	_shoot(DamagePayload.Element.ELECTRIC, 10000, 2, [3])
	_reactions.register_target(0, 1)
	for element: DamagePayload.Element in [DamagePayload.Element.NONE, DamagePayload.Element.ICE,
			DamagePayload.Element.FIRE, DamagePayload.Element.ACID]:  # FIRE without corrosion
		_shoot(element, 10000, 2, [3])
	assert_array(_secondary).is_empty()
	assert_int(_reactions.admitted_reactions).is_equal(0)
	assert_int(_primary_hits).is_equal(6)
	assert_int(_reactions.configuration_errors).is_equal(0)


func test_explosion_consumes_corrosion_even_without_targets() -> void:
	_shoot(DamagePayload.Element.ACID, 1000, 1, [])
	assert_int(_statuses.acid_stacks(1)).is_equal(1)
	_shoot(DamagePayload.Element.FIRE, 10000, 1, [])
	assert_int(_reactions.explosions).is_equal(1)
	assert_int(_statuses.acid_stacks(1)).is_equal(0)
	_shoot(DamagePayload.Element.FIRE, 10000, 1, [2])  # no corrosion left: no second explosion
	assert_int(_reactions.explosions).is_equal(1)
	assert_array(_secondary).is_empty()


func test_corroded_or_wet_primary_conducts_to_four() -> void:
	_reactions.register_target(1, 2, true)
	_shoot(DamagePayload.Element.ELECTRIC, 2000, 1, [7, 6, 5, 4, 3, 2])
	assert_array(_secondary).is_equal(PackedInt64Array([2, 1000, 3, 1000, 4, 1000, 5, 1000]))
	assert_bool(_reactions.is_wet(1)).is_true()
	assert_int(_reactions.conducting).is_equal(1)


func test_refused_reaction_child_keeps_corrosion() -> void:
	_build(2)  # room for the root and the direct child only
	_shoot(DamagePayload.Element.ACID, 1000, 1, [])
	await assert_error(func() -> void: _shoot(DamagePayload.Element.FIRE, 10000, 1, [2])).is_push_error(
			"AttackContextPool: ёмкость пула исчерпана")
	assert_int(_resolver.reaction_refusals).is_equal(1)
	assert_int(_statuses.acid_stacks(1)).is_equal(1)
	assert_int(_reactions.explosions).is_equal(0)
	assert_array(_secondary).is_empty()
	assert_int(_resolver.contexts.alive_count()).is_equal(0)


func test_lethal_primary_still_reacts_after_its_callbacks() -> void:
	_stats.set_stat(1, StatBlock.Stat.HP, 500)
	_kill_on_hit = 2  # the primary's OnHit listener kills a selected target first
	_shoot(DamagePayload.Element.ELECTRIC, 10000, 1, [2, 3])
	assert_int(_stats.get_stat(1, StatBlock.Stat.HP)).is_equal(0)
	# Selection runs after the primary callbacks, so the dead target is simply not chosen.
	assert_array(_secondary).is_equal(PackedInt64Array([3, 5000]))
	assert_int(_reactions.stale_skips).is_equal(0)
	assert_int(_reactions.arcs).is_equal(1)


func test_target_killed_after_selection_is_a_stale_skip() -> void:
	_reactions.on_hit.connect(_kill_three)
	_shoot(DamagePayload.Element.ELECTRIC, 10000, 1, [2, 3])
	assert_array(_secondary).is_equal(PackedInt64Array([2, 5000]))
	assert_int(_reactions.stale_skips).is_equal(1)
	assert_int(_stats.get_stat(3, StatBlock.Stat.HP)).is_equal(0)


func _kill_three(_source: int, _target: int, _epoch: int, _sequence: int, _trace: int, _child: int,
		_damage: int) -> void:
	_stats.set_stat(3, StatBlock.Stat.HP, 0)


func test_secondary_kill_uses_its_own_signal() -> void:
	var kills: Array[int] = []
	_resolver.on_kill.connect(func(_s: int, target: int, _e: int, _q: int, _t: int) -> void: kills.append(-target))
	_resolver.on_secondary_kill.connect(func(_s: int, target: int, _e: int, _q: int, _t: int) -> void: kills.append(target))
	_stats.set_stat(2, StatBlock.Stat.HP, 100)
	_shoot(DamagePayload.Element.ELECTRIC, 10000, 1, [2])
	assert_array(kills).is_equal([2])
	assert_int(_reactions.secondary_kills).is_equal(1)
	assert_int(_resolver.kills).is_equal(0)


func test_reentry_during_execution_is_refused() -> void:
	_reactions.on_hit.connect(_try_reentry)
	await assert_error(func() -> void:
		_shoot(DamagePayload.Element.ELECTRIC, 10000, 1, [2])
	).is_push_error(ReactionRuntime.CONFIGURATION_ERROR)
	assert_array(_reentry).is_equal(PackedInt64Array([0, 0, 0]))
	assert_array(_secondary).is_equal(PackedInt64Array([2, 5000]))
	assert_int(_reactions.configuration_errors).is_equal(4)


func test_resolver_refuses_reactions_bound_elsewhere() -> void:
	var other := StatusRuntime.new(_stats)
	await assert_error(func() -> void:
		var resolver := ShotResolver.new(_stats, _batch, 64, other, _reactions)
		assert_int(resolver.configuration_errors).is_equal(1)
		assert_int(resolver.damage_configuration_errors()).is_equal(1)
	).is_push_error(ShotResolver.REACTIONS_ERROR)
	var broken := ReactionRuntime.new(StatBlock.new(4), _statuses)  # fails: other StatBlock
	_reactions.reset_diagnostics()
	await assert_error(func() -> void:
		var resolver := ShotResolver.new(_stats, _batch, 64, _statuses, broken)
		assert_int(resolver.configuration_errors).is_equal(1)
	).is_push_error(ShotResolver.REACTIONS_ERROR)


func test_secondary_payloads_are_admitted_only_inside_execution() -> void:
	var pipeline := DamagePipeline.new(_stats, _statuses)
	var payloads := DamagePayloadBuffer.new(1)
	payloads.push(0, 2, 1000, DamagePayload.Element.ELECTRIC, 0, DamagePayload.Flag.SECONDARY, -1)
	await assert_error(func() -> void:
		assert_int(pipeline.resolve_secondary_front(payloads, _reactions)).is_equal(-1)
	).is_push_error(DamagePipeline.INVALID_PAYLOAD_ERROR)
	pipeline.reset_counters()
	await assert_error(func() -> void:
		assert_int(pipeline.resolve_front(payloads)).is_equal(-1)  # SECONDARY is not a direct contact
	).is_push_error(DamagePipeline.INVALID_PAYLOAD_ERROR)
	assert_int(_stats.get_stat(2, StatBlock.Stat.HP)).is_equal(1_000_000)


func test_invalid_configuration_and_calls_are_refused() -> void:
	await assert_error(func() -> void:
		assert_bool(ReactionRuntime.new(_stats, StatusRuntime.new(StatBlock.new(8))).is_initialized()).is_false()
	).is_push_error(ReactionRuntime.CONFIGURATION_ERROR)
	var rules := ReactionRules.new()
	rules.arc_targets = 3
	await assert_error(func() -> void:
		assert_bool(ReactionRuntime.new(_stats, _statuses, rules).is_initialized()).is_false()
	).is_push_error(ReactionRuntime.CONFIGURATION_ERROR)
	await assert_error(func() -> void:
		assert_bool(_reactions.admit(1000)).is_false()  # nothing planned
	).is_push_error(ReactionRuntime.CONFIGURATION_ERROR)
	_reactions.reset_diagnostics()
	await assert_error(func() -> void:
		assert_bool(_reactions.register_target(1, -1)).is_false()
	).is_push_error(ReactionRuntime.CONFIGURATION_ERROR)
	assert_bool(_reactions.register_target(StatBlock.HANDLE_INDEX_SPAN + 1, 2)).is_false()  # stale
	assert_bool(_reactions.needs_candidates(DamagePayload.Element.ELECTRIC)).is_true()
	assert_bool(_reactions.needs_candidates(DamagePayload.Element.FIRE)).is_true()
	assert_bool(_reactions.needs_candidates(DamagePayload.Element.ICE)).is_false()
	assert_int(_reactions.packed_bytes()).is_equal(8 * 13 + 4 * 8)


func test_room_reset_clears_metrics_and_keeps_registrations() -> void:
	_shoot(DamagePayload.Element.ELECTRIC, 10000, 1, [2])
	assert_bool(_reactions.reset_room()).is_true()
	assert_int(_reactions.arcs).is_equal(0)
	assert_int(_reactions.secondary_hits).is_equal(0)
	assert_int(_reactions.team_of(2)).is_equal(2)
	_shoot(DamagePayload.Element.ELECTRIC, 10000, 1, [2])
	assert_int(_reactions.arcs).is_equal(1)
