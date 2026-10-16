extends GdUnitTestSuite

var _stats: StatBlock
var _batch: ShotBatch
var _resolver: ShotResolver
var _target: int
var _seen_hits: PackedInt32Array
var _seen_damage: PackedInt64Array
var _seen_roots: PackedInt64Array
var _completion: PackedInt64Array
var _deferred: int = -1
var _heal_on_hit: bool = false
var _held: PackedInt64Array


func before_test() -> void:
	_stats = StatBlock.new(4)
	_stats.allocate()
	_target = _stats.allocate()
	_stats.set_stat(_target, StatBlock.Stat.HP, 10000)
	_batch = ShotBatch.new(4, 12, 4)
	_resolver = ShotResolver.new(_stats, _batch, 64)
	_seen_hits = PackedInt32Array()
	_seen_damage = PackedInt64Array()
	_seen_roots = PackedInt64Array()
	_completion = PackedInt64Array()
	_deferred = -1
	_heal_on_hit = false
	_held = PackedInt64Array()
	_resolver.on_fire.connect(_on_fire)
	_resolver.on_hit.connect(_on_hit)
	_resolver.on_attack_resolved.connect(_on_resolved)


func _shot(target: int, count: int = 8) -> void:
	var ticket: int = _batch.reserve(0, count, 6000)
	for trace: int in count:
		_batch.write_trace(ticket, trace, target)
	_batch.publish(ticket)


func _on_fire(_source: int, _epoch: int, _sequence: int, root: int) -> void:
	_seen_roots.append(root)
	assert_int(_resolver.contexts.hit_count(root)).is_equal(0)


func _on_hit(_source: int, target: int, _epoch: int, _sequence: int, trace: int,
		child: int, damage: int) -> void:
	_seen_hits.append(trace)
	_seen_damage.append(damage)
	assert_int(_resolver.contexts.depth_of(child)).is_equal(1)
	assert_int(_resolver.contexts.parent_of(child)).is_equal(_seen_roots[-1])
	assert_int(_resolver.contexts.hit_count(_seen_roots[-1])).is_equal(0)
	if _heal_on_hit:
		_stats.set_stat(target, StatBlock.Stat.HP, 10000)


func _on_resolved(source: int, epoch: int, sequence: int, root: int) -> void:
	assert_bool(_resolver.contexts.is_valid(root)).is_false()
	_completion.append(source)
	_completion.append(epoch)
	_completion.append(sequence)


func test_eight_pellets_death_noop_and_exact_completion() -> void:
	_shot(_target)
	_resolver.logic_step(0)
	assert_int(_resolver.registered_hits).is_equal(2)
	assert_int(_resolver.kills).is_equal(1)
	assert_int(_resolver.no_op_traces).is_equal(6)
	assert_array(_seen_hits).is_equal([0, 1])
	assert_array(_seen_damage).is_equal([6000, 4000])
	assert_int(_stats.get_stat(_target, StatBlock.Stat.HP)).is_equal(0)
	assert_int(_resolver.contexts.alive_count()).is_equal(0)
	assert_int(_resolver.resolved_shots).is_equal(1)
	assert_bool(_resolver.close_context(_seen_roots[0])).is_false()
	assert_int(_resolver.contexts.capacity_refusals).is_equal(0)


func test_shield_and_full_armor_zero_damage_still_emit_hits() -> void:
	_stats.set_stat(_target, StatBlock.Stat.SHIELD, 48000)
	_shot(_target)
	_resolver.logic_step(0)
	assert_int(_resolver.registered_hits).is_equal(8)
	assert_int(_resolver.kills).is_equal(0)
	assert_int(_stats.get_stat(_target, StatBlock.Stat.HP)).is_equal(10000)
	assert_int(_stats.get_stat(_target, StatBlock.Stat.SHIELD)).is_equal(0)
	_stats.set_stat(_target, StatBlock.Stat.ARMOR, DamageApply.ARMOR_SCALE)
	_shot(_target)
	_resolver.logic_step(1)
	assert_int(_resolver.registered_hits).is_equal(16)
	assert_int(_resolver.kills).is_equal(0)
	assert_int(_stats.get_stat(_target, StatBlock.Stat.HP)).is_equal(10000)
	assert_int(_seen_damage[15]).is_equal(0)


func test_mixed_shield_then_death_and_stale_dead_guard_before_capacity() -> void:
	_stats.set_stat(_target, StatBlock.Stat.SHIELD, 6000)
	_shot(_target)
	_resolver.logic_step(0)
	assert_int(_resolver.registered_hits).is_equal(3)
	assert_int(_resolver.kills).is_equal(1)
	assert_int(_resolver.no_op_traces).is_equal(5)
	assert_int(_seen_damage[0]).is_equal(0)
	_stats.release(_target)
	var fresh: int = _stats.allocate()
	_stats.set_stat(fresh, StatBlock.Stat.HP, 10000)
	_stats.set_stat(fresh, StatBlock.Stat.SHIELD, 9999)
	var minimal := ShotResolver.new(_stats, _batch, 1)
	_shot(_target)
	minimal.logic_step(0)
	assert_int(minimal.contexts.capacity_refusals).is_equal(0)
	assert_int(minimal.registered_hits).is_equal(0)
	assert_int(_stats.get_stat(fresh, StatBlock.Stat.SHIELD)).is_equal(9999)
	_stats.set_stat(fresh, StatBlock.Stat.HP, 0)
	_shot(fresh)
	minimal.logic_step(1)
	assert_int(minimal.contexts.capacity_refusals).is_equal(0)
	assert_int(_stats.get_stat(fresh, StatBlock.Stat.SHIELD)).is_equal(9999)


func test_miss_root_duplicate_tick_and_pending_reservation() -> void:
	_shot(-1)
	_resolver.logic_step(4)
	assert_int(_resolver.resolved_shots).is_equal(1)
	assert_int(_resolver.registered_hits).is_equal(0)
	_shot(-1)
	_resolver.logic_step(4)
	_resolver.logic_step(3)
	assert_int(_batch.count()).is_equal(1)
	assert_int(_resolver.resolved_shots).is_equal(1)
	_resolver.logic_step(5)
	assert_int(_resolver.resolved_shots).is_equal(2)
	var pending: int = _batch.reserve(0, 2, 6000)
	_resolver.logic_step(6)
	assert_int(_batch.pending_count()).is_equal(1)
	assert_bool(_batch.publish(pending)).is_false()


func _hold_descendant(_source: int, _target_handle: int, _epoch: int, _sequence: int,
		trace: int, child: int, _damage: int) -> void:
	if trace == 0:
		_deferred = _resolver.open_child(child)


func test_deferred_descendant_closed_children_capacity_and_saved_metadata() -> void:
	_stats.set_stat(_target, StatBlock.Stat.HP, 100000)
	_resolver.on_hit.connect(_hold_descendant)
	_shot(_target)
	_resolver.logic_step(0)
	assert_int(_resolver.contexts.alive_count()).is_equal(10)  # root + 8 closed siblings + held child
	assert_int(_resolver.contexts.open_count(_deferred)).is_equal(1)
	assert_int(_resolver.resolved_shots).is_equal(0)
	assert_bool(_resolver.contexts.is_valid(_seen_roots[0])).is_true()
	assert_bool(_resolver.close_context(_deferred)).is_true()
	assert_int(_resolver.resolved_shots).is_equal(1)
	assert_array(_completion).is_equal([0, 0, 0])
	assert_int(_resolver.contexts.alive_count()).is_equal(0)
	assert_bool(_resolver.close_context(_deferred)).is_false()
	assert_int(_resolver.contexts.open_child(_seen_roots[0])).is_equal(-1)


func test_reset_cancels_pending_and_held_descendant_then_allows_old_tick() -> void:
	_resolver.on_hit.connect(_hold_descendant)
	_shot(_target, 1)
	_resolver.logic_step(1000)
	_batch.reserve(0, 3, 6000)
	assert_bool(_resolver.reset_room()).is_true()
	assert_int(_resolver.contexts.alive_count()).is_equal(0)
	assert_int(_batch.pending_count()).is_equal(0)
	assert_bool(_resolver.close_context(_deferred)).is_false()
	_shot(-1)
	_resolver.logic_step(0)
	assert_int(_resolver.resolved_shots).is_equal(1)
	assert_array(_completion).is_equal([0, 1, 0])


func test_apply_kill_transition_is_snapshotted_before_onhit_healing() -> void:
	_heal_on_hit = true
	_stats.set_stat(_target, StatBlock.Stat.HP, 1000)
	_shot(_target, 1)
	_resolver.logic_step(0)
	assert_int(_resolver.kills).is_equal(1)
	assert_int(_stats.get_stat(_target, StatBlock.Stat.HP)).is_equal(10000)


func _hold_every_hit(_source: int, _target_handle: int, _epoch: int, _sequence: int,
		_trace: int, child: int, _damage: int) -> void:
	_held.append(_resolver.open_child(child))


func test_final_close_releases_only_its_own_tree_ownership() -> void:
	_stats.set_stat(_target, StatBlock.Stat.HP, 100000)
	_resolver.on_hit.connect(_hold_every_hit)
	_shot(_target, 1)
	_shot(_target, 1)
	_resolver.logic_step(0)
	assert_int(_held.size()).is_equal(2)
	assert_int(_resolver.resolved_shots).is_equal(0)
	var second_root: int = _resolver.contexts.root_of(_held[1])
	assert_int(_resolver.owned_count(second_root)).is_equal(3)  # root, pellet, held child
	var first_root: int = _resolver.contexts.root_of(_held[0])
	var first_slots := PackedInt64Array([first_root % HandlePool.INDEX_SPAN,
			_resolver.contexts.parent_of(_held[0]) % HandlePool.INDEX_SPAN,
			_held[0] % HandlePool.INDEX_SPAN])
	assert_bool(_resolver.close_context(_held[0])).is_true()
	assert_int(_resolver.resolved_shots).is_equal(1)
	# A third shot reuses the first tree's freed slots while the second tree is alive.
	_shot(_target, 1)
	_resolver.logic_step(1)
	assert_int(_held.size()).is_equal(3)
	var third_root: int = _resolver.contexts.root_of(_held[2])
	assert_bool(first_slots.has(third_root % HandlePool.INDEX_SPAN)).is_true()  # slot reuse is real
	assert_int(_resolver.owned_count(third_root)).is_equal(3)
	assert_int(_resolver.owned_count(second_root)).is_equal(3)
	# The second tree keeps its ownership after the first tree's final close and slot reuse.
	var nested: int = _resolver.open_child(_held[1])
	assert_int(nested).is_not_equal(AttackContextPool.INVALID_HANDLE)
	assert_int(_resolver.owned_count(second_root)).is_equal(4)
	assert_bool(_resolver.close_context(_held[1])).is_false()
	assert_bool(_resolver.close_context(nested)).is_true()
	assert_int(_resolver.owned_count(second_root)).is_equal(0)
	assert_int(_resolver.owned_count(third_root)).is_equal(3)
	assert_bool(_resolver.close_context(_held[2])).is_true()
	assert_int(_resolver.owned_count(third_root)).is_equal(0)
	assert_int(_resolver.resolved_shots).is_equal(3)
	assert_int(_resolver.contexts.alive_count()).is_equal(0)
	assert_bool(_resolver.reset_room()).is_true()


## M2.3a: the weapon element travels WeaponData -> WeaponState -> ShotBatch -> pipeline.
func test_element_travels_through_the_batch_and_starts_statuses() -> void:
	var statuses := StatusRuntime.new(_stats)
	statuses.register_target(_target)
	var resolver := ShotResolver.new(_stats, _batch, 64, statuses)
	var data := WeaponData.new()
	data.element = DamagePayload.Element.ACID
	var state := WeaponState.new()
	_stats.set_stat(0, StatBlock.Stat.HP, 1000)  # a living source may fire
	assert_bool(state.configure(data, 0)).is_true()
	state.set_pressed(true)
	var ticket: int = state.request_shot(_batch, _stats, 0)
	for trace: int in data.pellet_count:
		_batch.write_trace(ticket, trace, _target if trace == 0 else ShotBatch.INVALID)
	_batch.publish(ticket)
	assert_int(_batch.prepare()).is_equal(1)
	assert_int(_batch.element_at(0)).is_equal(DamagePayload.Element.ACID)
	resolver.logic_step(1)
	assert_int(statuses.acid_stacks(_target)).is_equal(1)
	assert_int(resolver.damage_configuration_errors()).is_equal(0)


func test_invalid_element_is_refused_and_physical_pipeline_rejects_elements() -> void:
	await assert_error(func() -> void:
		assert_int(_batch.reserve(0, 1, 6000, 9 as DamagePayload.Element)).is_equal(ShotBatch.INVALID)
	).is_push_error("ShotBatch: invalid request, capacity or identity exhausted")
	var data := WeaponData.new()
	data.element = 9 as DamagePayload.Element
	assert_bool(data.is_valid()).is_false()
	# Without a StatusRuntime the M2.1 physical contract stays: an elemental pellet is a
	# configuration error, its child closes and the shot still completes once.
	var ticket: int = _batch.reserve(0, 1, 6000, DamagePayload.Element.FIRE)
	_batch.write_trace(ticket, 0, _target)
	_batch.publish(ticket)
	await assert_error(func() -> void: _resolver.logic_step(1)).is_push_error(DamagePipeline.INVALID_PAYLOAD_ERROR)
	assert_int(_stats.get_stat(_target, StatBlock.Stat.HP)).is_equal(10000)
	assert_int(_resolver.damage_configuration_errors()).is_equal(1)
	assert_int(_completion.size()).is_equal(3)
	assert_int(_resolver.contexts.alive_count()).is_equal(0)
