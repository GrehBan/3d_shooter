extends GdUnitTestSuite
## StatusRuntime (M2.3a): approved preset, tick semantics, active list, snapshots, guards.

const F := StatusRuntime.Field64

var _stats: StatBlock
var _statuses: StatusRuntime
var _pipeline: DamagePipeline
var _payloads: DamagePayloadBuffer
var _target: int
var _source: int
var _events: Array[PackedInt64Array] = []
var _kill_events: int = 0
var _completions: int = 0
var _reentry: PackedInt64Array = PackedInt64Array()
var _order: PackedInt64Array = PackedInt64Array()


func before_test() -> void:
	_stats = StatBlock.new(4)
	_target = _stats.allocate()
	_source = _stats.allocate()
	_stats.set_stat(_target, StatBlock.Stat.HP, 1000000)
	_statuses = StatusRuntime.new(_stats)
	_statuses.register_target(_target)
	_pipeline = DamagePipeline.new(_stats, _statuses)
	_payloads = DamagePayloadBuffer.new(1)
	_events.clear()
	_kill_events = 0
	_completions = 0
	_reentry.clear()
	_order.clear()
	_statuses.on_pulse_hit.connect(_on_pulse)
	_statuses.on_pulse_kill.connect(_on_kill)
	_statuses.on_pulse_resolved.connect(_on_complete)
	_statuses.logic_step(1)


func _hit(element: DamagePayload.Element, amount: int = 10000, target: int = -2,
		source: int = -2, credit: int = 99) -> int:
	_payloads.push(_source if source == -2 else source, _target if target == -2 else target,
			amount, element, 1 << 60, 0, -1)
	var damage: int = _pipeline.resolve_front(_payloads, credit, 7, 11, 3)
	_payloads.pop_front()
	return damage


func _advance(tick: int) -> void:
	while _statuses.current_tick() < tick:
		_statuses.logic_step(_statuses.current_tick() + 1)


func _on_pulse(source: int, target: int, credit: int, generation: int, ordinal: int,
		damage: int, epoch: int, sequence: int, trace: int, tags: int) -> void:
	_events.append(PackedInt64Array([_statuses.current_tick(), source, target, credit,
			generation, ordinal, damage, epoch, sequence, trace, tags]))


func _on_kill(_source_arg: int, _target_arg: int, _credit: int, _generation: int, _ordinal: int,
		_damage: int, _epoch: int, _sequence: int, _trace: int, _tags: int) -> void:
	_kill_events += 1


func _on_complete(_source_arg: int, _target_arg: int, _credit: int, _generation: int, _ordinal: int,
		_damage: int, _epoch: int, _sequence: int, _trace: int, _tags: int) -> void:
	_completions += 1


func _burn(field: StatusRuntime.Field64) -> int:
	return _statuses.burn_field(_target, field)


static func _field(state: Dictionary, index: int, field: int) -> int:
	return (state.slots_64 as PackedInt64Array)[index * StatusRuntime.WIDTH_64 + field]


## Deep copy of a snapshot with one int64 slot field replaced.
static func _with_64(state: Dictionary, index: int, field: int, value: int) -> Dictionary:
	var copy: Dictionary = state.duplicate(true)
	var slots: PackedInt64Array = copy.slots_64
	slots[index * StatusRuntime.WIDTH_64 + field] = value
	copy.slots_64 = slots
	return copy


static func _with_32(state: Dictionary, index: int, field: int, value: int) -> Dictionary:
	var copy: Dictionary = state.duplicate(true)
	var slots: PackedInt32Array = copy.slots_32
	slots[index * StatusRuntime.WIDTH_32 + field] = value
	copy.slots_32 = slots
	return copy


func _assert_refused_restore(bad: Dictionary, tick: int, before: Dictionary) -> void:
	_statuses.reset_diagnostics()
	await assert_error(func() -> void:
		assert_bool(_statuses.set_state(bad, tick)).is_false()
	).is_push_error(StatusRuntime.CONFIGURATION_ERROR)
	assert_dict(_statuses.get_state()).is_equal(before)


func test_burn_six_endpoint_pulses_and_provenance() -> void:
	assert_int(_hit(DamagePayload.Element.FIRE)).is_equal(10000)
	_advance(91)
	assert_int(_events.size()).is_equal(6)
	for index: int in 6:
		assert_array(_events[index]).is_equal(PackedInt64Array([16 + 15 * index, _source,
				_target, 99, 1, index + 1, 2000, 7, 11, 3, 1 << 60]))
	assert_int(_stats.get_stat(_target, StatBlock.Stat.HP)).is_equal(978000)
	assert_int(_statuses.status_mask(_target)).is_equal(0)
	assert_int(_completions).is_equal(6)
	assert_int(_burn(F.BURN_GENERATION)).is_equal(1)
	assert_int(_statuses.processed_pulses).is_equal(6)
	assert_int(_statuses.pulse_hp_damage).is_equal(12000)


func test_refresh_preserves_due_generation_and_strongest_attribution() -> void:
	_hit(DamagePayload.Element.FIRE)
	_advance(20)
	_hit(DamagePayload.Element.FIRE, 5000, -2, -1, 55)
	assert_int(_burn(F.BURN_NEXT_DUE)).is_equal(31)
	assert_int(_burn(F.BURN_UNTIL)).is_equal(110)
	assert_int(_burn(F.BURN_SOURCE)).is_equal(_source)
	_hit(DamagePayload.Element.FIRE, 15000, -2, -1, 77)
	assert_int(_burn(F.BURN_GENERATION)).is_equal(1)
	assert_int(_burn(F.BURN_NEXT_DUE)).is_equal(31)
	assert_int(_burn(F.BURN_AMOUNT)).is_equal(3000)
	assert_int(_burn(F.BURN_SOURCE)).is_equal(-1)
	assert_int(_burn(F.BURN_CREDIT)).is_equal(77)
	_advance(110)
	assert_int(_events.size()).is_equal(7)
	assert_int(_events.back()[0]).is_equal(106)
	assert_int(_events.back()[6]).is_equal(3000)
	assert_int(_statuses.status_mask(_target)).is_equal(0)


func test_shield_armor_hp_gate_and_tiny_fire() -> void:
	_stats.set_stat(_target, StatBlock.Stat.SHIELD, 10000)
	assert_int(_hit(DamagePayload.Element.FIRE)).is_equal(0)
	assert_int(_statuses.status_mask(_target)).is_equal(0)
	_stats.set_stat(_target, StatBlock.Stat.SHIELD, 9000)
	assert_int(_hit(DamagePayload.Element.FIRE)).is_equal(1000)
	assert_int(_burn(F.BURN_AMOUNT)).is_equal(2000)
	_stats.set_stat(_target, StatBlock.Stat.ARMOR, 100000)
	assert_int(_hit(DamagePayload.Element.ACID)).is_equal(0)
	assert_int(_statuses.acid_stacks(_target)).is_equal(0)
	_stats.set_stat(_target, StatBlock.Stat.ARMOR, 0)
	assert_bool(_statuses.reset_room()).is_true()
	_statuses.logic_step(1)
	_hit(DamagePayload.Element.FIRE, 4)  # 20% of 4 rounds to 0: no burn
	assert_int(_statuses.status_mask(_target)).is_equal(0)


func test_corrosion_subsequent_hits_pulses_and_expiry_do_not_mutate_base() -> void:
	_stats.set_stat(_target, StatBlock.Stat.ARMOR, 50000)
	assert_int(_hit(DamagePayload.Element.ACID)).is_equal(5000)
	assert_int(_hit(DamagePayload.Element.NONE)).is_equal(6000)
	_hit(DamagePayload.Element.ACID)
	_hit(DamagePayload.Element.ACID)
	_hit(DamagePayload.Element.ACID)
	assert_int(_statuses.acid_stacks(_target)).is_equal(3)
	assert_int(_statuses.effective_armor(_target)).is_equal(20000)
	_hit(DamagePayload.Element.FIRE)
	_advance(16)
	assert_int(_events[0][6]).is_equal(1600)
	_advance(91)
	assert_int(_events.back()[6]).is_equal(1000)  # corrosion expired at 91, before that pulse
	assert_int(_stats.get_stat(_target, StatBlock.Stat.ARMOR)).is_equal(50000)
	assert_int(_statuses.acid_stacks(_target)).is_equal(0)


func test_ice_third_contact_shatter_shield_retention_and_cooldown() -> void:
	_hit(DamagePayload.Element.ICE)
	assert_int(_statuses.movement_scale(_target)).is_equal(800)
	_hit(DamagePayload.Element.ICE)
	assert_int(_statuses.movement_scale(_target)).is_equal(600)
	assert_int(_hit(DamagePayload.Element.ICE)).is_equal(10000)  # the freezing hit is not doubled
	assert_bool(_statuses.control_blocked(_target)).is_true()
	assert_int(_statuses.movement_scale(_target)).is_equal(0)
	_stats.set_stat(_target, StatBlock.Stat.SHIELD, 20000)
	assert_int(_hit(DamagePayload.Element.ICE)).is_equal(0)  # shield-only: freeze kept
	assert_bool(_statuses.is_frozen(_target)).is_true()
	assert_int(_hit(DamagePayload.Element.ICE)).is_equal(20000)
	assert_bool(_statuses.is_frozen(_target)).is_false()
	assert_int(_statuses.movement_scale(_target)).is_equal(1000)
	for index: int in 3: _hit(DamagePayload.Element.ICE)
	assert_int(_statuses.movement_scale(_target)).is_equal(600)  # freeze cooldown caps chill at 2
	assert_bool(_statuses.is_frozen(_target)).is_false()
	_advance(60)
	_hit(DamagePayload.Element.ICE)
	assert_bool(_statuses.is_frozen(_target)).is_false()
	_advance(61)
	_hit(DamagePayload.Element.ICE)
	assert_bool(_statuses.is_frozen(_target)).is_true()


func test_frozen_fire_uses_original_unshattered_raw_and_saturates() -> void:
	for index: int in 3: _hit(DamagePayload.Element.ICE)
	assert_int(_hit(DamagePayload.Element.FIRE)).is_equal(20000)
	assert_int(_burn(F.BURN_AMOUNT)).is_equal(2000)
	_advance(61)
	for index: int in 3: _hit(DamagePayload.Element.ICE)
	_stats.set_stat(_target, StatBlock.Stat.ARMOR, 99999)
	var before: int = _stats.get_stat(_target, StatBlock.Stat.HP)
	assert_int(_hit(DamagePayload.Element.NONE, StatusRuntime.MAX_INT)).is_equal(before)
	assert_int(_stats.get_stat(_target, StatBlock.Stat.HP)).is_equal(0)
	assert_int(_statuses.status_mask(_target)).is_equal(0)


func test_shock_half_open_and_rate_limited() -> void:
	_hit(DamagePayload.Element.ELECTRIC)
	assert_bool(_statuses.control_blocked(_target)).is_true()
	assert_bool(_statuses.has_status(_target, StatusRuntime.Mask.SHOCK)).is_true()
	_advance(3)
	_hit(DamagePayload.Element.ELECTRIC)  # cooldown: no extension
	assert_int(_field(_statuses.get_state(), 0, F.SHOCK_UNTIL)).is_equal(4)
	_advance(4)
	assert_bool(_statuses.control_blocked(_target)).is_false()
	_hit(DamagePayload.Element.ELECTRIC)
	assert_bool(_statuses.control_blocked(_target)).is_false()
	_advance(16)
	_hit(DamagePayload.Element.ELECTRIC)
	assert_bool(_statuses.control_blocked(_target)).is_true()


func test_profiles_idempotency_and_unknown_targets() -> void:
	for profile: int in [StatusRuntime.Profile.PLAYER, StatusRuntime.Profile.ELITE, StatusRuntime.Profile.INERT]:
		var entity: int = _stats.allocate()
		_stats.set_stat(entity, StatBlock.Stat.HP, 1000000)
		_statuses.register_target(entity, profile as StatusRuntime.Profile)
		assert_int(_statuses.profile_of(entity)).is_equal(profile)
		for index: int in 4: _hit(DamagePayload.Element.ICE, 100, entity)
		_hit(DamagePayload.Element.ELECTRIC, 100, entity)
		assert_bool(_statuses.control_blocked(entity)).is_false()
		assert_int(_statuses.movement_scale(entity)).is_equal(1000 if profile == StatusRuntime.Profile.INERT else 600)
		_hit(DamagePayload.Element.FIRE, 100, entity)
		_hit(DamagePayload.Element.ACID, 100, entity)
		assert_int(_statuses.status_mask(entity)).is_equal(0 if profile == StatusRuntime.Profile.INERT \
				else StatusRuntime.Mask.BURN | StatusRuntime.Mask.CORROSION | StatusRuntime.Mask.CHILL)
		_stats.release(entity)
	_hit(DamagePayload.Element.FIRE)
	var before: Dictionary = _statuses.get_state()
	assert_bool(_statuses.register_target(_target)).is_true()
	assert_dict(_statuses.get_state()).is_equal(before)
	await assert_error(func() -> void:
		assert_bool(_statuses.register_target(_target, StatusRuntime.Profile.ELITE)).is_false()
	).is_push_error(StatusRuntime.CONFIGURATION_ERROR)
	assert_dict(_statuses.get_state()).is_equal(before)
	# An unregistered target takes ordinary damage and receives no statuses.
	_stats.set_stat(_source, StatBlock.Stat.HP, 1000)
	assert_int(_hit(DamagePayload.Element.FIRE, 100, _source)).is_equal(100)
	assert_int(_statuses.status_mask(_source)).is_equal(0)
	assert_int(_statuses.profile_of(_source)).is_equal(StatusRuntime.NO_PROFILE)


func test_source_and_target_release_reuse_preserve_credit() -> void:
	_hit(DamagePayload.Element.FIRE)
	var old_source: int = _source
	_stats.release(_source)
	_source = _stats.allocate()
	_stats.set_stat(_source, StatBlock.Stat.HP, 123456)
	_advance(16)
	assert_int(_events[0][1]).is_equal(old_source)
	assert_int(_events[0][3]).is_equal(99)
	assert_int(_stats.get_stat(_source, StatBlock.Stat.HP)).is_equal(123456)
	var stale: int = _target
	_stats.release(_target)
	_target = _stats.allocate()
	_stats.set_stat(_target, StatBlock.Stat.HP, 54321)
	assert_bool(_statuses.register_target(_target)).is_true()
	_advance(91)
	assert_int(_events.size()).is_equal(1)
	assert_int(_stats.get_stat(_target, StatBlock.Stat.HP)).is_equal(54321)
	assert_int(_statuses.status_mask(stale)).is_equal(0)
	assert_bool(_statuses.has_status(stale, StatusRuntime.Mask.BURN)).is_false()
	assert_int(_statuses.active_count()).is_equal(0)


func test_lethal_pulse_captured_kill_and_generation_survive_heal() -> void:
	_hit(DamagePayload.Element.FIRE)
	_stats.set_stat(_target, StatBlock.Stat.HP, 1000)
	_advance(16)
	assert_int(_kill_events).is_equal(1)
	assert_int(_completions).is_equal(1)
	assert_int(_events[0][6]).is_equal(1000)
	assert_int(_statuses.pulse_kills).is_equal(1)
	_stats.set_stat(_target, StatBlock.Stat.HP, 100000)
	_statuses.register_target(_target)
	_hit(DamagePayload.Element.FIRE)
	assert_int(_burn(F.BURN_GENERATION)).is_equal(2)


func test_room_starting_at_tick_500_steps_and_accepts_contacts() -> void:
	var statuses := StatusRuntime.new(_stats)
	statuses.register_target(_target)
	var pipeline := DamagePipeline.new(_stats, statuses)
	# A contact before the first step is accepted at logic time 0.
	_payloads.push(_source, _target, 1000, DamagePayload.Element.ACID, 0, 0, -1)
	assert_int(pipeline.resolve_front(_payloads)).is_equal(1000)
	_payloads.pop_front()
	assert_bool(statuses.logic_step(500)).is_true()
	assert_int(statuses.current_tick()).is_equal(500)
	assert_int(statuses.acid_stacks(_target)).is_equal(0)  # expired at 90 <= 500
	_payloads.push(_source, _target, 10000, DamagePayload.Element.FIRE, 0, 0, -1)
	assert_int(pipeline.resolve_front(_payloads)).is_equal(10000)
	_payloads.pop_front()
	assert_int(statuses.burn_field(_target, F.BURN_NEXT_DUE)).is_equal(515)
	assert_int(statuses.burn_field(_target, F.BURN_UNTIL)).is_equal(590)
	for tick: int in range(501, 591):
		assert_bool(statuses.logic_step(tick)).is_true()
	assert_int(statuses.processed_pulses).is_equal(6)
	assert_int(statuses.configuration_errors).is_equal(0)


func test_skipped_ticks_run_one_overdue_pulse_and_reschedule_from_current_tick() -> void:
	_hit(DamagePayload.Element.FIRE)  # due 16, until 91
	assert_bool(_statuses.logic_step(50)).is_true()
	assert_int(_events.size()).is_equal(1)
	assert_int(_events[0][0]).is_equal(50)
	assert_int(_burn(F.BURN_NEXT_DUE)).is_equal(65)
	assert_bool(_statuses.logic_step(65)).is_true()
	assert_int(_burn(F.BURN_NEXT_DUE)).is_equal(80)
	assert_bool(_statuses.logic_step(200)).is_true()  # one overdue pulse, then past its end
	assert_int(_events.size()).is_equal(3)
	assert_array(_events.map(func(event: PackedInt64Array) -> int: return event[5])).is_equal([1, 2, 3])
	assert_int(_statuses.status_mask(_target)).is_equal(0)
	assert_int(_statuses.active_count()).is_equal(0)


func test_repeated_past_and_invalid_ticks_change_nothing() -> void:
	_hit(DamagePayload.Element.FIRE)
	_hit(DamagePayload.Element.ICE)
	_advance(10)
	var before: Dictionary = _statuses.get_state()
	var visited: int = _statuses.visited_slots
	assert_bool(_statuses.logic_step(10)).is_true()
	assert_bool(_statuses.logic_step(3)).is_true()
	assert_bool(_statuses.logic_step(0)).is_true()
	assert_dict(_statuses.get_state()).is_equal(before)
	assert_int(_statuses.visited_slots).is_equal(visited)
	for tick: int in [-1, StatusRuntime.MAX_TICK + 1]:
		_statuses.reset_diagnostics()
		await assert_error(func() -> void:
			assert_bool(_statuses.logic_step(tick)).is_false()
		).is_push_error(StatusRuntime.CONFIGURATION_ERROR)
		assert_dict(_statuses.get_state()).is_equal(before)
	_statuses.reset_diagnostics()
	_payloads.push(_source, _target, 100, DamagePayload.Element.FIRE, 0, DamagePayload.Flag.CRIT, -1)
	await assert_error(func() -> void:
		assert_int(_pipeline.resolve_front(_payloads)).is_equal(-1)
	).is_push_error(DamagePipeline.INVALID_PAYLOAD_ERROR)
	assert_int(_payloads.get_phase(_payloads.front_slot())).is_equal(DamagePayload.Phase.BASE)
	assert_dict(_statuses.get_state()).is_equal(before)


func test_step_visits_only_active_slots_in_slot_order() -> void:
	var stats := StatBlock.new(64)
	var handles := PackedInt64Array()
	for index: int in 64:
		handles.append(stats.allocate())
		stats.set_stat(handles[index], StatBlock.Stat.HP, 1000000)
	var statuses := StatusRuntime.new(stats)
	for handle: int in handles:
		statuses.register_target(handle)
	var pipeline := DamagePipeline.new(stats, statuses)
	statuses.on_pulse_hit.connect(_record_order)
	assert_bool(statuses.logic_step(1)).is_true()
	assert_int(statuses.visited_slots).is_equal(0)  # 64 registered, none active
	for index: int in [40, 3, 17]:  # applied out of slot order
		_payloads.push(_source, handles[index], 10000, DamagePayload.Element.FIRE, 0, 0, -1)
		pipeline.resolve_front(_payloads)
		_payloads.pop_front()
	assert_int(statuses.active_count()).is_equal(3)
	for tick: int in range(2, 17):
		statuses.logic_step(tick)
	assert_int(statuses.visited_slots).is_equal(15 * 3)
	assert_array(_order).is_equal(PackedInt64Array([handles[3], handles[17], handles[40]]))
	assert_bool(statuses.has_status(handles[17], StatusRuntime.Mask.BURN)).is_true()
	assert_bool(statuses.has_status(handles[17], StatusRuntime.Mask.FREEZE)).is_false()
	assert_bool(statuses.has_status(handles[18], StatusRuntime.Mask.BURN)).is_false()
	stats.set_stat(handles[17], StatBlock.Stat.HP, 0)
	assert_bool(statuses.has_status(handles[17], StatusRuntime.Mask.BURN)).is_false()  # dead
	statuses.logic_step(17)
	assert_int(statuses.active_count()).is_equal(2)


func _record_order(_source_arg: int, target: int, _credit: int, _generation: int, _ordinal: int,
		_damage: int, _epoch: int, _sequence: int, _trace: int, _tags: int) -> void:
	_order.append(target)


func test_reset_room_clears_statuses_keeps_registration_and_generation() -> void:
	_hit(DamagePayload.Element.FIRE)
	_hit(DamagePayload.Element.ACID)
	_advance(20)
	assert_bool(_statuses.reset_room()).is_true()
	assert_int(_statuses.current_tick()).is_equal(0)
	assert_int(_statuses.active_count()).is_equal(0)
	assert_int(_statuses.status_mask(_target)).is_equal(0)
	assert_int(_statuses.processed_pulses).is_equal(0)
	assert_int(_statuses.profile_of(_target)).is_equal(StatusRuntime.Profile.ORDINARY)
	assert_int(_burn(F.BURN_GENERATION)).is_equal(1)
	_statuses.logic_step(1)
	_hit(DamagePayload.Element.FIRE)
	assert_int(_burn(F.BURN_GENERATION)).is_equal(2)  # pulse identity never repeats


func test_snapshot_roundtrip_active_cadence_and_unchanged_external_state() -> void:
	_hit(DamagePayload.Element.FIRE)
	_hit(DamagePayload.Element.ACID)
	_advance(20)
	var snapshot: Dictionary = _statuses.get_state()
	var restored := StatusRuntime.new(_stats)
	assert_bool(restored.set_state(snapshot, 20)).is_true()
	assert_dict(restored.get_state()).is_equal(snapshot)
	assert_int(restored.active_count()).is_equal(1)
	var before_hp: int = _stats.get_stat(_target, StatBlock.Stat.HP)
	for tick: int in range(21, 32): restored.logic_step(tick)
	# The restored burn keeps its cadence: one 2000 pulse at 31 (zero base armor).
	assert_int(_stats.get_stat(_target, StatBlock.Stat.HP)).is_equal(before_hp - 2000)
	await assert_error(func() -> void:
		assert_bool(_statuses.set_state(snapshot, 21)).is_false()
	).is_push_error(StatusRuntime.CONFIGURATION_ERROR)
	assert_int(_statuses.current_tick()).is_equal(20)


func test_snapshot_rejects_every_malformed_category_atomically() -> void:
	_hit(DamagePayload.Element.FIRE)
	_hit(DamagePayload.Element.ICE)
	_hit(DamagePayload.Element.ACID)
	var before: Dictionary = _statuses.get_state()
	for key: String in StatusRuntime.SNAPSHOT_KEYS:
		var missing: Dictionary = before.duplicate(true)
		missing.erase(key)
		await _assert_refused_restore(missing, 1, before)
		var wrong_type: Dictionary = before.duplicate(true)
		wrong_type[key] = "1"
		await _assert_refused_restore(wrong_type, 1, before)
	var extra: Dictionary = before.duplicate(true)
	extra["status"] = PackedInt64Array()
	await _assert_refused_restore(extra, 1, before)
	for pair: Array in [["version", 2], ["capacity", 8], ["last_tick", 2]]:
		var bad: Dictionary = before.duplicate(true)
		bad[pair[0]] = pair[1]
		await _assert_refused_restore(bad, 1, before)
	var short_64: Dictionary = before.duplicate(true)
	short_64.slots_64 = PackedInt64Array([0])
	await _assert_refused_restore(short_64, 1, before)
	var witness: Dictionary = before.duplicate(true)
	var external: Dictionary = witness.external_stats
	var data: PackedInt32Array = external.data
	data[0] += 1
	external.data = data
	await _assert_refused_restore(witness, 1, before)
	var w := StatusRuntime.Field32
	var invalid: Array[Dictionary] = [
		_with_64(before, 0, F.BURN_GENERATION, -1),
		_with_64(before, 0, F.TARGET, _source),  # bound to another slot's handle
		_with_32(before, 0, w.PROFILE, 9),
		_with_64(before, 0, F.BURN_NEXT_DUE, 30),  # beyond one period
		_with_64(before, 0, F.BURN_NEXT_DUE, 1),  # not in the future
		_with_64(before, 0, F.BURN_UNTIL, 200),
		_with_64(before, 0, F.BURN_AMOUNT, 0),
		_with_64(before, 0, F.BURN_SOURCE, -5),
		_with_64(before, 0, F.BURN_ORDINAL, -1),
		_with_64(before, 0, F.SHOCK_UNTIL, 3),  # shock without its cooldown pair
		_with_32(before, 0, w.CHILL_STACKS, 3),
		_with_32(before, 0, w.CHILL_STACKS, 0),  # chill deadline without stacks
		_with_32(before, 0, w.ACID_STACKS, 4),
		_with_64(before, 0, F.ACID_UNTIL, 0),  # stacks without a deadline
		_with_64(before, 0, F.FREEZE_UNTIL, 31),  # frozen while chilled
		_with_32(before, 0, w.PROFILE, StatusRuntime.Profile.INERT),  # statuses on an inert target
		_with_64(before, 2, F.BURN_GENERATION, 1),  # unbound slot with history
		_with_64(before, 2, F.BURN_SOURCE, 0),  # unbound slot with a burn source
	]
	for bad: Dictionary in invalid:
		await _assert_refused_restore(bad, 1, before)
	# A dead target must carry no statuses; the matching witness isolates that rule.
	var hp: int = _stats.get_stat(_target, StatBlock.Stat.HP)
	_stats.set_stat(_target, StatBlock.Stat.HP, 0)
	var dead: Dictionary = before.duplicate(true)
	dead.external_stats = _stats.get_state()
	_statuses.reset_diagnostics()
	await assert_error(func() -> void:
		assert_bool(_statuses.set_state(dead, 1)).is_false()
	).is_push_error(StatusRuntime.CONFIGURATION_ERROR)
	_stats.set_stat(_target, StatBlock.Stat.HP, hp)
	assert_dict(_statuses.get_state()).is_equal(before)


func test_player_profile_snapshot_rejects_shock_and_freeze() -> void:
	var player: int = _stats.allocate()
	_stats.set_stat(player, StatBlock.Stat.HP, 1000)
	_statuses.register_target(player, StatusRuntime.Profile.PLAYER)
	var before: Dictionary = _statuses.get_state()
	var index: int = player % StatBlock.HANDLE_INDEX_SPAN
	var shocked: Dictionary = _with_64(_with_64(before, index, F.SHOCK_UNTIL, 3), index, F.SHOCK_READY, 15)
	await _assert_refused_restore(shocked, 1, before)
	var frozen: Dictionary = _with_64(_with_64(before, index, F.FREEZE_UNTIL, 30), index, F.FREEZE_READY, 60)
	await _assert_refused_restore(frozen, 1, before)


func test_pulse_callback_reentry_is_refused() -> void:
	_statuses.on_pulse_hit.connect(_try_reentry)
	_hit(DamagePayload.Element.FIRE)
	_advance(15)
	var hp: int = _stats.get_stat(_target, StatBlock.Stat.HP)
	await assert_error(func() -> void:
		assert_bool(_statuses.logic_step(16)).is_true()
	).is_push_error(StatusRuntime.CONFIGURATION_ERROR)
	assert_array(_reentry).is_equal(PackedInt64Array([0, 0, -1, 0, 0, 0]))
	assert_int(_stats.get_stat(_target, StatBlock.Stat.HP)).is_equal(hp - 2000)
	assert_int(_statuses.acid_stacks(_target)).is_equal(0)
	assert_int(_statuses.configuration_errors).is_equal(6)


func _try_reentry(_source_arg: int, _target_arg: int, _credit: int, _generation: int, _ordinal: int,
		_damage: int, _epoch: int, _sequence: int, _trace: int, _tags: int) -> void:
	_reentry.append(int(_statuses.register_target(_target)))
	_reentry.append(int(_statuses.logic_step(17)))
	_reentry.append(_hit(DamagePayload.Element.ACID))
	_reentry.append(int(_statuses.reset_room()))
	_reentry.append(_statuses.get_state().size())
	_statuses.end_contact(_source, _target, 10000, DamagePayload.Element.ACID, 10000, false)
	_reentry.append(_statuses.acid_stacks(_target))


func test_contact_protocol_and_dot_admission_are_owned() -> void:
	await assert_error(func() -> void:
		_statuses.end_contact(_source, _target, 1000, DamagePayload.Element.ACID, 1000, false)
	).is_push_error(StatusRuntime.CONFIGURATION_ERROR)
	assert_int(_statuses.acid_stacks(_target)).is_equal(0)
	_payloads.push(_source, _target, 1000, DamagePayload.Element.FIRE, 0, DamagePipeline.DOT_FLAGS, -1)
	var hp: int = _stats.get_stat(_target, StatBlock.Stat.HP)
	await assert_error(func() -> void:
		assert_int(_pipeline.resolve_dot_front(_payloads, _statuses)).is_equal(-1)
	).is_push_error(DamagePipeline.INVALID_PAYLOAD_ERROR)
	assert_int(_stats.get_stat(_target, StatBlock.Stat.HP)).is_equal(hp)
	_pipeline.reset_counters()
	await assert_error(func() -> void:
		assert_int(_pipeline.resolve_front(_payloads)).is_equal(-1)  # DOT flags are not a direct contact
	).is_push_error(DamagePipeline.INVALID_PAYLOAD_ERROR)
	assert_int(_stats.get_stat(_target, StatBlock.Stat.HP)).is_equal(hp)


func test_rules_are_copied_cold_and_invalid_rules_refused() -> void:
	var rules := StatusRules.new()
	var copied := StatusRuntime.new(_stats, rules)
	assert_bool(copied.is_initialized()).is_true()
	assert_int(copied.packed_bytes()).is_equal(4 * 161)
	rules.burn_ticks = 30
	copied.register_target(_target)
	copied.logic_step(1)
	var pipeline := DamagePipeline.new(_stats, copied)
	_payloads.push(_source, _target, 10000, DamagePayload.Element.FIRE, 0, 0, -1)
	pipeline.resolve_front(_payloads)
	_payloads.pop_front()
	assert_int(copied.burn_field(_target, F.BURN_UNTIL)).is_equal(91)
	await assert_error(func() -> void:
		assert_bool(StatusRuntime.new(_stats, rules).is_initialized()).is_false()
	).is_push_error(StatusRuntime.CONFIGURATION_ERROR)
	await assert_error(func() -> void:
		assert_bool(StatusRuntime.new(null).is_initialized()).is_false()
	).is_push_error(StatusRuntime.CONFIGURATION_ERROR)


func test_mobility_landing_uses_corrosion_armor_without_base_writes() -> void:
	var stats := StatBlock.new(4)
	var entity: int = stats.allocate()
	stats.set_stat(entity, StatBlock.Stat.HP, 100000)
	stats.set_stat(entity, StatBlock.Stat.ARMOR, 50000)
	var statuses := StatusRuntime.new(stats)
	var mobility := MobilityRuntime.new(stats, LandingEventQueue.DEFAULT_CAPACITY, statuses)
	assert_bool(mobility.is_initialized()).is_true()
	await assert_error(func() -> void:
		assert_bool(MobilityRuntime.new(stats, 4, _statuses).is_initialized()).is_false()
	).is_push_error(MobilityRuntime.STATUS_ERROR)
	statuses.register_target(entity, StatusRuntime.Profile.PLAYER)
	statuses.logic_step(1)
	var pipeline := DamagePipeline.new(stats, statuses)
	var payloads := DamagePayloadBuffer.new(1)
	payloads.push(-1, entity, 1000, DamagePayload.Element.ACID, 0, 0, -1)
	pipeline.resolve_front(payloads)
	payloads.pop_front()
	var before: int = stats.get_stat(entity, StatBlock.Stat.HP)
	mobility.landings.push(entity, 9000, 0)  # 10000 raw fall damage
	mobility.logic_step(1)
	assert_int(stats.get_stat(entity, StatBlock.Stat.HP)).is_equal(before - 6000)
	assert_int(stats.get_stat(entity, StatBlock.Stat.ARMOR)).is_equal(50000)


func test_cold_snapshot_canonicalizes_external_release_and_death_without_live_writes() -> void:
	_hit(DamagePayload.Element.FIRE)
	_stats.set_stat(_target, StatBlock.Stat.HP, 0)
	var state: Dictionary = _statuses.get_state()
	assert_int(_field(state, 0, F.BURN_UNTIL)).is_equal(0)
	assert_int(_field(state, 0, F.BURN_GENERATION)).is_equal(1)
	assert_int(_statuses.active_count()).is_equal(1)  # the live store is untouched
	assert_bool(_statuses.set_state(state, 1)).is_true()
	assert_int(_statuses.active_count()).is_equal(0)
	_stats.release(_target)
	state = _statuses.get_state()
	assert_int(_field(state, 0, F.TARGET)).is_equal(-1)
	assert_int(_field(state, 0, F.BURN_GENERATION)).is_equal(0)
	assert_bool(_statuses.set_state(state, 1)).is_true()


func test_mismatched_pipeline_stats_rejected_cold_and_never_write() -> void:
	var other := StatBlock.new(4)
	var handle: int = other.allocate()
	other.set_stat(handle, StatBlock.Stat.HP, 12345)
	await assert_error(func() -> void:
		var bad := DamagePipeline.new(other, _statuses)
		_payloads.push(-1, handle, 1000, DamagePayload.Element.FIRE, 0, 0, -1)
		assert_int(bad.resolve_front(_payloads)).is_equal(-1)
	).is_push_error(DamagePipeline.INVALID_PAYLOAD_ERROR)
	assert_int(other.get_stat(handle, StatBlock.Stat.HP)).is_equal(12345)


## clear_dead_target (M2.3b kill paths): a no-op on a living target and on a stale handle,
## refused while a pulse is being resolved.
func test_clear_dead_target_needs_a_dead_target_and_a_quiet_runtime() -> void:
	_hit(DamagePayload.Element.ACID)
	_hit(DamagePayload.Element.FIRE)
	assert_bool(_statuses.clear_dead_target(_target)).is_true()  # alive: statuses stay
	assert_int(_statuses.acid_stacks(_target)).is_equal(1)
	assert_int(_burn(F.BURN_UNTIL)).is_greater(0)
	assert_bool(_statuses.clear_dead_target(_target + HandlePool.INDEX_SPAN)).is_true()  # stale
	assert_int(_statuses.acid_stacks(_target)).is_equal(1)
	_statuses.on_pulse_hit.connect(_try_clear_dead)
	await assert_error(func() -> void:
		_advance(_burn(F.BURN_NEXT_DUE))
	).is_push_error(StatusRuntime.CONFIGURATION_ERROR)
	assert_array(_reentry).is_equal(PackedInt64Array([0]))
	assert_int(_statuses.acid_stacks(_target)).is_equal(1)
	_statuses.on_pulse_hit.disconnect(_try_clear_dead)
	_stats.set_stat(_target, StatBlock.Stat.HP, 0)
	assert_bool(_statuses.clear_dead_target(_target)).is_true()
	assert_int(_statuses.acid_stacks(_target)).is_equal(0)
	assert_int(_burn(F.BURN_UNTIL)).is_equal(0)
	assert_int(_statuses.configuration_errors).is_equal(1)


func _try_clear_dead(_source_arg: int, _target_arg: int, _credit: int, _generation: int, _ordinal: int,
		_damage: int, _epoch: int, _sequence: int, _trace: int, _tags: int) -> void:
	if _reentry.is_empty():
		_reentry.append(int(_statuses.clear_dead_target(_target)))


func test_lethal_landing_clears_statuses_at_once() -> void:
	var stats := StatBlock.new(4)
	var entity: int = stats.allocate()
	stats.set_stat(entity, StatBlock.Stat.HP, 100000)
	var statuses := StatusRuntime.new(stats)
	var mobility := MobilityRuntime.new(stats, LandingEventQueue.DEFAULT_CAPACITY, statuses)
	statuses.register_target(entity, StatusRuntime.Profile.ORDINARY)
	statuses.logic_step(1)
	var pipeline := DamagePipeline.new(stats, statuses)
	var payloads := DamagePayloadBuffer.new(1)
	for element: DamagePayload.Element in [DamagePayload.Element.ACID, DamagePayload.Element.FIRE]:
		payloads.push(-1, entity, 1000, element, 0, 0, -1)
		pipeline.resolve_front(payloads)
		payloads.pop_front()
	assert_int(statuses.acid_stacks(entity)).is_equal(1)
	stats.set_stat(entity, StatBlock.Stat.HP, 1000)
	mobility.landings.push(entity, 9000, 0)  # 10000 raw fall damage: lethal
	mobility.logic_step(1)
	assert_int(stats.get_stat(entity, StatBlock.Stat.HP)).is_equal(0)
	assert_int(statuses.acid_stacks(entity)).is_equal(0)
	assert_int(statuses.burn_field(entity, F.BURN_UNTIL)).is_equal(0)
	assert_int(statuses.configuration_errors).is_equal(0)
