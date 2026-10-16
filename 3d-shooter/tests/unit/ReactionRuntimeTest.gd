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


func test_arcs_pick_the_smallest_eligible_handles() -> void:
	_reactions.register_target(6, 1)  # an ally of the source
	_reactions.register_target(7, 0)  # neutral
	_shoot(DamagePayload.Element.ELECTRIC, 10000, 1, [5, 7, 6, 4, 0, 1, 3])
	assert_array(_secondary).is_equal(PackedInt64Array([3, 5000, 4, 5000]))
	assert_int(_reactions.arcs).is_equal(1)
	assert_int(_reactions.inspected_candidates).is_equal(7)


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
	assert_int(_reactions.configuration_errors).is_equal(3)


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
