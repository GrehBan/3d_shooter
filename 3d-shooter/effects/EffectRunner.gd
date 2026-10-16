class_name EffectRunner
extends RefCounted
## Fixed FIFO snapshots and per-subscription counter/cooldown state. No attack ownership.

const CONFIGURATION_ERROR: String = "EffectRunner: invalid configuration or capacity"
const MAX_DEFINITIONS: int = 64
const MAX_EVENTS: int = 4096
const MAX_SUBSCRIPTIONS: int = 64
const MAX_INT: int = 0x7FFFFFFFFFFFFFFF

var configuration_errors: int = 0
var dropped_events: int = 0
var accepted_events: int = 0
var processed_events: int = 0
var inspected_candidates: int = 0
var executed_actions: int = 0
var condition_refusals: int = 0
var cooldown_refusals: int = 0
var stale_skips: int = 0
var deferred_steps: int = 0

var _stats: StatBlock
var _host: EffectHost
var _initialized: bool = false
var _reported: bool = false
var _event_capacity: int = 0
var _max_subscriptions: int = 0
var _work_quota: int = 0
var _head: int = 0
var _count: int = 0
var _cursor: int = 0
var _last_tick: int = -1
var _condition: PackedInt32Array = PackedInt32Array()
var _minimum: PackedInt64Array = PackedInt64Array()
var _increment: PackedInt64Array = PackedInt64Array()
var _cooldown: PackedInt64Array = PackedInt64Array()
var _owners: PackedInt64Array = PackedInt64Array()
var _values: PackedInt64Array = PackedInt64Array()
var _sizes: PackedInt32Array = PackedInt32Array()
var _entries: PackedInt64Array = PackedInt64Array()
var _scratch: PackedInt64Array = PackedInt64Array()
var _state_entry: PackedInt64Array = PackedInt64Array()
var _state_owner: PackedInt64Array = PackedInt64Array()
var _counters: PackedInt64Array = PackedInt64Array()
var _last_success: PackedInt64Array = PackedInt64Array()


func _init(stats: StatBlock, host: EffectHost, definitions: Array[EffectRuleData],
		event_capacity: int = 32, max_subscriptions: int = 8, work_quota: int = 16) -> void:
	if stats == null or host == null or definitions.size() > MAX_DEFINITIONS \
			or event_capacity <= 0 or event_capacity > MAX_EVENTS \
			or max_subscriptions <= 0 or max_subscriptions > MAX_SUBSCRIPTIONS or work_quota <= 0:
		_configuration_failure()
		return
	if host.host_capacity() != stats.capacity():
		_configuration_failure()
		return
	for definition: EffectRuleData in definitions:
		if definition == null or not definition.is_valid():
			_configuration_failure()
			return
	_stats = stats
	_host = host
	_event_capacity = event_capacity
	_max_subscriptions = max_subscriptions
	_work_quota = work_quota
	_condition.resize(definitions.size())
	_minimum.resize(definitions.size())
	_increment.resize(definitions.size())
	_cooldown.resize(definitions.size())
	for index: int in definitions.size():
		_condition[index] = definitions[index].condition
		_minimum[index] = definitions[index].minimum_value
		_increment[index] = definitions[index].counter_increment
		_cooldown[index] = definitions[index].cooldown_ticks
	_owners.resize(event_capacity)
	_values.resize(event_capacity)
	_sizes.resize(event_capacity)
	_entries.resize(event_capacity * max_subscriptions)
	_scratch.resize(max_subscriptions)
	_state_entry.resize(host.entry_capacity())
	_state_owner.resize(host.entry_capacity())
	_counters.resize(host.entry_capacity())
	_last_success.resize(host.entry_capacity())
	_state_entry.fill(-1)
	_state_owner.fill(-1)
	_last_success.fill(-1)
	_initialized = true


func is_initialized() -> bool:
	return _initialized


## Exact packed payload only; excludes RefCounted/Variant/packed-array wrappers.
func uses_stats(stats: StatBlock) -> bool:
	return _stats != null and _stats == stats


func packed_bytes() -> int:
	return _condition.size() * 28 + _event_capacity * (20 + 8 * _max_subscriptions) \
			+ _scratch.size() * 8 + _state_entry.size() * 32


func pending_count() -> int:
	return _count


func counter_for(entry: int) -> int:
	if not _initialized:
		return 0
	var index: int = _host.entry_index(entry)
	if index < 0 or _state_entry[index] != entry or not _stats.is_valid(_state_owner[index]) \
			or _host.host_at(index) != _state_owner[index]:
		return 0
	return _counters[index]


func enqueue(owner: int, trigger: EffectTrigger.Trigger, value: int) -> bool:
	if not _initialized:
		return false
	if trigger < 0 or trigger >= EffectTrigger.TRIGGER_COUNT or value < 0:
		_configuration_failure()
		return false
	if not _stats.is_valid(owner):
		return false
	var size: int = 0
	var index: int = _host.first(owner, trigger)
	while index != EffectHost.NO_ENTRY:
		if size == _max_subscriptions:
			_configuration_failure(true)
			return false
		var definition: int = _host.effect_id_at(index)
		if definition < 0 or definition >= _condition.size():
			_configuration_failure()
			return false
		_scratch[size] = _host.entry_at(index)
		size += 1
		index = _host.next(index)
	if size == 0:
		return true
	if _count == _event_capacity:
		_configuration_failure(true)
		return false
	var tail: int = (_head + _count) % _event_capacity
	_owners[tail] = owner
	_values[tail] = value
	_sizes[tail] = size
	for offset: int in size:
		_entries[tail * _max_subscriptions + offset] = _scratch[offset]
	_count += 1
	accepted_events += 1
	return true


## Each inspected snapshot candidate consumes one unit, including all refusals.
func logic_step(tick: int) -> int:
	if not _initialized or tick < 0 or tick <= _last_tick:
		return 0
	_last_tick = tick
	var work: int = 0
	while _count > 0 and work < _work_quota:
		var entry: int = _entries[_head * _max_subscriptions + _cursor]
		_execute(entry, _owners[_head], _values[_head], tick)
		work += 1
		inspected_candidates += 1
		_cursor += 1
		if _cursor == _sizes[_head]:
			_cursor = 0
			_head = (_head + 1) % _event_capacity
			_count -= 1
			processed_events += 1
	if _count > 0 and work == _work_quota:
		deferred_steps += 1
	return work


func _execute(entry: int, owner: int, value: int, tick: int) -> void:
	var index: int = _host.entry_index(entry)
	if index < 0 or not _stats.is_valid(owner) or _host.host_at(index) != owner:
		stale_skips += 1
		return
	var definition: int = _host.effect_id_at(index)
	if _condition[definition] == EffectRuleData.Condition.MIN_VALUE and value < _minimum[definition]:
		condition_refusals += 1
		return
	var same_state: bool = _state_entry[index] == entry and _state_owner[index] == owner
	var last: int = _last_success[index] if same_state else -1
	if last >= 0 and tick - last < _cooldown[definition]:
		cooldown_refusals += 1
		return
	var counter: int = _counters[index] if same_state else 0
	if counter > MAX_INT - _increment[definition]:
		_configuration_failure()
		return
	_state_entry[index] = entry
	_state_owner[index] = owner
	_counters[index] = counter + _increment[definition]
	_last_success[index] = tick
	executed_actions += 1


func reset_diagnostics() -> void:
	configuration_errors = 0
	dropped_events = 0
	_reported = false


## Quiescent composition-root boundary. Definitions and subscriptions survive.
func reset_room() -> void:
	_head = 0
	_count = 0
	_cursor = 0
	_last_tick = -1
	_state_entry.fill(-1)
	_state_owner.fill(-1)
	_counters.fill(0)
	_last_success.fill(-1)
	accepted_events = 0
	processed_events = 0
	inspected_candidates = 0
	executed_actions = 0
	condition_refusals = 0
	cooldown_refusals = 0
	stale_skips = 0
	deferred_steps = 0
	reset_diagnostics()


func _configuration_failure(dropped: bool = false) -> void:
	configuration_errors += 1
	if dropped:
		dropped_events += 1
	if not _reported:
		_reported = true
		push_error(CONFIGURATION_ERROR)
