extends GdUnitTestSuite
## M2.3 statuses. Exact-integer independent oracle: tests/tools/status_ref.py.

var _hash: int
var _words: int
var _stats: StatBlock
var _statuses: StatusRuntime
var _pipeline: DamagePipeline
var _payloads: DamagePayloadBuffer
var _source: int
var _tick: int
var _contacts: int
var _pulses: int
var _pulse_kills: int


func _word(value: int) -> void:
	_hash = ((_hash ^ (value & 0xFFFFFFFF)) * 16777619) & 0xFFFFFFFF
	_hash = ((_hash ^ ((value >> 32) & 0xFFFFFFFF)) * 16777619) & 0xFFFFFFFF
	_words += 1


func _record(values: PackedInt64Array) -> void:
	for value: int in values:
		_word(value)


func _fresh(capacity: int, profiles: Dictionary) -> void:
	_stats = StatBlock.new(capacity)
	for index: int in capacity:
		_stats.allocate()
		_stats.set_stat(index, StatBlock.Stat.HP, 1000000)
	_statuses = StatusRuntime.new(_stats)
	for index: int in capacity:
		var profile: int = profiles.get(index, StatusRuntime.Profile.ORDINARY)
		assert_bool(_statuses.register_target(index, profile as StatusRuntime.Profile)).is_true()
	_pipeline = DamagePipeline.new(_stats, _statuses)
	_payloads = DamagePayloadBuffer.new(1)
	_source = 0
	_tick = 1


func _contact(target: int, amount: int, element: DamagePayload.Element,
		record: bool = true) -> void:
	assert_int(_payloads.push(_source, target, amount, element,
			(1 << 40) + target, 0, -1)).is_greater_equal(0)
	var damage: int = _pipeline.resolve_front(_payloads, (1 << 50) + _source,
			7, _tick * 100 + target, target)
	assert_int(damage).is_greater_equal(0)
	_payloads.pop_front()
	if record:
		_contacts += 1
		_record(PackedInt64Array([100, _tick, _source, target, amount, element, damage]))


func _pulse(kind: int, source: int, target: int, credit: int, generation: int,
		ordinal: int, damage: int, epoch: int, sequence: int, trace: int, tags: int) -> void:
	_record(PackedInt64Array([kind, source, target, credit, generation, ordinal,
			damage, epoch, sequence, trace, tags]))
	if kind == 203: _pulses += 1
	if kind == 202: _pulse_kills += 1


func _pulse_hit(s: int, t: int, c: int, g: int, o: int, d: int,
		e: int, q: int, r: int, tags: int) -> void:
	_pulse(201, s, t, c, g, o, d, e, q, r, tags)


func _pulse_kill(s: int, t: int, c: int, g: int, o: int, d: int,
		e: int, q: int, r: int, tags: int) -> void:
	_pulse(202, s, t, c, g, o, d, e, q, r, tags)


func _pulse_resolved(s: int, t: int, c: int, g: int, o: int, d: int,
		e: int, q: int, r: int, tags: int) -> void:
	_pulse(203, s, t, c, g, o, d, e, q, r, tags)


func _connect_pulses() -> void:
	_statuses.on_pulse_hit.connect(_pulse_hit)
	_statuses.on_pulse_kill.connect(_pulse_kill)
	_statuses.on_pulse_resolved.connect(_pulse_resolved)


func test_status_timeline_pulses_full_handles_and_active_restore_golden() -> void:
	_hash = 2166136261
	_words = 0
	_contacts = 0
	_pulses = 0
	_pulse_kills = 0
	_fresh(8, {2: StatusRuntime.Profile.PLAYER, 3: StatusRuntime.Profile.ELITE,
			4: StatusRuntime.Profile.INERT})
	_stats.set_stat(1, StatBlock.Stat.ARMOR, 50000)
	_stats.set_stat(5, StatBlock.Stat.ARMOR, 100000)
	_stats.set_stat(7, StatBlock.Stat.SHIELD, 10000)
	_connect_pulses()
	var handles := PackedInt64Array([0, 1, 2, 3, 4, 5, 6, 7])
	for tick: int in range(1, 126):
		_tick = tick
		assert_bool(_statuses.logic_step(tick)).is_true()
		if tick == 1:
			_contact(1, 10001, DamagePayload.Element.FIRE)
			_contact(1, 1000, DamagePayload.Element.ACID)
			for target: int in [2, 3]:
				_contact(target, 1000, DamagePayload.Element.FIRE)
				for hit: int in 3:
					_contact(target, 1000, DamagePayload.Element.ICE)
				_contact(target, 1000, DamagePayload.Element.ELECTRIC)
			for element: DamagePayload.Element in [DamagePayload.Element.FIRE,
					DamagePayload.Element.ACID, DamagePayload.Element.ICE, DamagePayload.Element.ELECTRIC]:
				_contact(4, 1000, element)
			_contact(5, 1000, DamagePayload.Element.ACID)
			_contact(7, 10000, DamagePayload.Element.FIRE)
			_contact(6, 5000, DamagePayload.Element.FIRE)
		if tick == 2:
			_contact(1, 1001, DamagePayload.Element.ACID)
			_contact(1, 1000, DamagePayload.Element.ICE)
			_contact(6, 1000, DamagePayload.Element.ICE)
		if tick == 3:
			_contact(1, 1000, DamagePayload.Element.ICE)
			_contact(1, 1000, DamagePayload.Element.ELECTRIC)
			_contact(7, 10001, DamagePayload.Element.FIRE)
		if tick == 4: _contact(1, 1000, DamagePayload.Element.ICE)
		if tick == 5:
			_contact(1, 1001, DamagePayload.Element.NONE)
			_contact(1, 1000, DamagePayload.Element.ELECTRIC)
		if tick == 10: _contact(1, 5000, DamagePayload.Element.FIRE)
		if tick == 15:
			assert_bool(_stats.release(0)).is_true()
			_source = _stats.allocate()
			assert_int(_source).is_equal(65536)
		if tick == 16: _contact(1, 20001, DamagePayload.Element.FIRE)
		if tick == 17:
			assert_bool(_stats.release(6)).is_true()
			handles[6] = _stats.allocate()
			assert_int(handles[6]).is_equal(65542)
			_stats.set_stat(handles[6], StatBlock.Stat.HP, 1000000)
			assert_bool(_statuses.register_target(handles[6])).is_true()
			_contact(6, 10000, DamagePayload.Element.FIRE)
		if tick in [18, 19, 20]: _contact(65542, 1000, DamagePayload.Element.ICE)
		if tick == 20: _contact(1, 5, DamagePayload.Element.FIRE)
		if tick == 21:
			_stats.set_stat(65542, StatBlock.Stat.SHIELD, 40000)
			_contact(65542, 10000, DamagePayload.Element.NONE)
		if tick == 22: _contact(65542, 10001, DamagePayload.Element.NONE)
		if tick == 30: _contact(1, 1000, DamagePayload.Element.ELECTRIC)
		if tick == 31: _contact(1, 1000, DamagePayload.Element.ACID)
		if tick in [64, 65, 66]: _contact(1, 1000, DamagePayload.Element.ICE)
		if tick == 67: _contact(1, 9999, DamagePayload.Element.FIRE)
		if tick == 80: _stats.set_stat(3, StatBlock.Stat.HP, 100)
		if tick == 45:
			var snapshot: Dictionary = _statuses.get_state()
			var external: Dictionary = _stats.get_state()
			var restored := StatusRuntime.new(_stats)
			assert_bool(restored.set_state(snapshot, tick)).is_true()
			assert_dict(_stats.get_state()).is_equal(external)
			_statuses = restored
			_pipeline = DamagePipeline.new(_stats, _statuses)
			_connect_pulses()
			_record(PackedInt64Array([400, tick]))
		_record(PackedInt64Array([300, tick]))
		for index: int in range(1, 8):
			var handle: int = handles[index]
			_record(PackedInt64Array([handle, _stats.get_stat(handle, StatBlock.Stat.HP),
					_stats.get_stat(handle, StatBlock.Stat.SHIELD), _statuses.status_mask(handle),
					_statuses.movement_scale(handle), int(_statuses.control_blocked(handle)),
					_statuses.effective_armor(handle), _statuses.acid_stacks(handle)]))
	assert_int(_hash).is_equal(4200031361)
	assert_int(_words).is_equal(8158)
	assert_int(_contacts).is_equal(43)
	assert_int(_pulses).is_equal(27)
	assert_int(_pulse_kills).is_equal(1)
	assert_int(_statuses.configuration_errors).is_equal(0)
	assert_int(_pipeline.configuration_errors).is_equal(0)
	assert_int(_payloads.dropped_count()).is_equal(0)




func _record_targets(count: int) -> void:
	_record(PackedInt64Array([300, _statuses.current_tick()]))
	for handle: int in range(1, count):
		_record(PackedInt64Array([handle, _stats.get_stat(handle, StatBlock.Stat.HP),
				_stats.get_stat(handle, StatBlock.Stat.SHIELD), _statuses.status_mask(handle),
				_statuses.movement_scale(handle), int(_statuses.control_blocked(handle)),
				_statuses.effective_armor(handle), _statuses.acid_stacks(handle)]))


## Same oracle, skip_reference(): the room starts at logic tick 500; skipped ticks run at
## most one overdue pulse per burn, repeated and past ticks change nothing.
func test_skipped_repeated_and_past_ticks_golden() -> void:
	_hash = 2166136261
	_words = 0
	_contacts = 0
	_pulses = 0
	_pulse_kills = 0
	_fresh(7, {6: StatusRuntime.Profile.PLAYER})
	_stats.set_stat(3, StatBlock.Stat.ARMOR, 50000)
	_connect_pulses()
	var fire := DamagePayload.Element.FIRE
	var ice := DamagePayload.Element.ICE
	var acid := DamagePayload.Element.ACID
	var electric := DamagePayload.Element.ELECTRIC
	var timeline: Array = [
		[500, [[1, 10000, fire], [2, 1000, ice], [2, 1000, ice], [2, 1000, ice], [3, 1000, acid],
				[4, 1000, electric], [5, 5000, fire], [6, 1000, ice], [6, 1000, ice], [6, 1000, ice]]],
		[501, [[5, 20000, fire], [3, 1000, acid]]],
		[509, [[2, 3000, ice], [4, 1000, electric]]],
		[530, [[4, 1000, electric]]],
		[530, []],
		[520, []],
		[531, [[1, 10000, fire]]],
		[600, []],
		[620, []],
		[5000, []],
	]
	var visits: PackedInt64Array = PackedInt64Array()
	for entry: Array in timeline:
		assert_bool(_statuses.logic_step(entry[0])).is_true()
		visits.append(_statuses.visited_slots)
		_tick = _statuses.current_tick()
		for contact: Array in entry[1]:
			_contact(contact[0], contact[1], contact[2])
		_word(entry[0])
		_record_targets(7)
	assert_int(_hash).is_equal(2162921167)
	assert_int(_words).is_equal(732)
	assert_int(_contacts).is_equal(16)
	assert_int(_pulses).is_equal(5)
	assert_int(_pulse_kills).is_equal(0)
	assert_int(_statuses.current_tick()).is_equal(5000)
	assert_int(_statuses.active_count()).is_equal(0)
	# Repeated and past ticks visit nothing; the work is O(active slots), not O(capacity).
	assert_int(visits[4]).is_equal(visits[3])
	assert_int(visits[5]).is_equal(visits[3])
	assert_int(_statuses.configuration_errors).is_equal(0)
	assert_int(_pipeline.configuration_errors).is_equal(0)
