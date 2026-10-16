class_name StatusRuntime
extends RefCounted
## Status authority of the room (contracts §2, StatusRuntime). One packed record per
## StatBlock slot, bound to a full target handle and an immutable capability profile.
## A logic step visits only slots with live status state, in ascending slot order.
## Burn pulses are autonomous: no attack context, identity (target, generation, ordinal).

enum Profile { ORDINARY, PLAYER, ELITE, INERT }
enum Mask { SHOCK = 1, BURN = 2, CHILL = 4, FREEZE = 8, CORROSION = 16 }

## Int64 fields of one slot record, stored at slot * WIDTH_64 + field.
enum Field64 {
	TARGET, SHOCK_UNTIL, SHOCK_READY, BURN_UNTIL, BURN_NEXT_DUE, BURN_AMOUNT, BURN_SOURCE,
	BURN_CREDIT, BURN_EPOCH, BURN_SEQUENCE, BURN_TRACE, BURN_TAGS, BURN_GENERATION,
	BURN_ORDINAL, CHILL_UNTIL, FREEZE_UNTIL, FREEZE_READY, ACID_UNTIL,
}
## Int32 fields of one slot record, stored at slot * WIDTH_32 + field.
enum Field32 { PROFILE, CHILL_STACKS, ACID_STACKS }

signal on_pulse_hit(source: int, target: int, credit: int, generation: int, ordinal: int,
		hp_damage: int, epoch: int, sequence: int, trace: int, tags: int)
signal on_pulse_kill(source: int, target: int, credit: int, generation: int, ordinal: int,
		hp_damage: int, epoch: int, sequence: int, trace: int, tags: int)
signal on_pulse_resolved(source: int, target: int, credit: int, generation: int, ordinal: int,
		hp_damage: int, epoch: int, sequence: int, trace: int, tags: int)

const CONFIGURATION_ERROR: String = "StatusRuntime: invalid configuration, state or call"
const WIDTH_64: int = 18
const WIDTH_32: int = 3
const NO_TARGET: int = -1
const NO_PROFILE: int = -1
## Active-list tail sentinel; sorts after every slot index.
const NO_SLOT: int = 0x7FFFFFFF
## Accepted logic ticks are 0..MAX_TICK, so every deadline fits int64.
const MAX_TICK: int = 1 << 62
## Burn generation and pulse ordinal stay below this bound (one step per logic tick).
const MAX_COUNT: int = 1 << 62
const MAX_INT: int = 0x7FFFFFFFFFFFFFFF
const SNAPSHOT_VERSION: int = 1
const SNAPSHOT_KEYS: PackedStringArray = ["version", "capacity", "last_tick",
		"external_stats", "slots_64", "slots_32"]

var configuration_errors: int = 0
var applied_statuses: int = 0
var processed_pulses: int = 0
var pulse_hp_damage: int = 0
var pulse_kills: int = 0
## Active slots visited by logic steps since the last room reset.
var visited_slots: int = 0
var _stats: StatBlock
var _capacity: int = 0
var _initialized: bool = false
var _reported: bool = false
## A step, contact or pulse is in progress: every mutating call is refused.
var _busy: bool = false
var _contact_open: bool = false
var _pulse_open: bool = false
var _last_tick: int = 0
var _slots_64: PackedInt64Array = PackedInt64Array()
var _slots_32: PackedInt32Array = PackedInt32Array()
## Sorted slot indices with live status state; entries past _active_count are NO_SLOT.
var _active: PackedInt32Array = PackedInt32Array()
var _active_count: int = 0
var _is_active: PackedByteArray = PackedByteArray()
var _payloads: DamagePayloadBuffer
var _pipeline: DamagePipeline
var _shock_ticks: int
var _shock_cooldown: int
var _burn_ticks: int
var _burn_period: int
var _burn_divisor: int
var _chill_ticks: int
var _chill_slow: int
var _freeze_ticks: int
var _freeze_cooldown: int
var _acid_ticks: int
var _acid_armor: int
var _acid_cap: int


## Cold: allocates one record per StatBlock slot and the pulse scratch.
func _init(stats: StatBlock, rules: StatusRules = preload("res://data/status/default_status_rules.tres")) -> void:
	if stats == null or rules == null or not rules.is_valid():
		_refuse()
		return
	_stats = stats
	_capacity = stats.capacity()
	_shock_ticks = rules.shock_ticks
	_shock_cooldown = rules.shock_cooldown_ticks
	_burn_ticks = rules.burn_ticks
	_burn_period = rules.burn_period_ticks
	_burn_divisor = 1000 / rules.burn_percent
	_chill_ticks = rules.chill_ticks
	_chill_slow = rules.chill_slow_per_stack
	_freeze_ticks = rules.freeze_ticks
	_freeze_cooldown = rules.freeze_cooldown_ticks
	_acid_ticks = rules.corrosion_ticks
	_acid_armor = rules.corrosion_armor_per_stack
	_acid_cap = rules.corrosion_max_stacks
	_slots_64.resize(_capacity * WIDTH_64)
	_slots_32.resize(_capacity * WIDTH_32)
	for index: int in _capacity:
		_unbind(index)
	_active.resize(_capacity)
	_active.fill(NO_SLOT)
	_is_active.resize(_capacity)
	_payloads = DamagePayloadBuffer.new(1)
	_pipeline = DamagePipeline.new(stats)
	_initialized = true


func is_initialized() -> bool:
	return _initialized


func uses_stats(stats: StatBlock) -> bool:
	return _initialized and _stats == stats


## Packed bytes of the slot records and the active list (wrappers excluded).
func packed_bytes() -> int:
	return _capacity * (WIDTH_64 * 8 + WIDTH_32 * 4 + 4 + 1) if _initialized else 0


func current_tick() -> int:
	return _last_tick


func active_count() -> int:
	return _active_count


## Binds a full handle to an immutable profile. The same handle with the same profile is
## idempotent; another profile is refused. A new occupant of the slot starts clean.
## A stale handle is an ordinary false.
func register_target(target: int, profile: Profile = Profile.ORDINARY) -> bool:
	if not _initialized or _busy or profile < Profile.ORDINARY or profile > Profile.INERT:
		return _refuse()
	var index: int = _stats.index_of(target)
	if index < 0:
		return false
	if _slots_64[index * WIDTH_64 + Field64.TARGET] == target:
		return true if _slots_32[index * WIDTH_32 + Field32.PROFILE] == profile else _refuse()
	_unbind(index)
	_slots_64[index * WIDTH_64 + Field64.TARGET] = target
	_slots_32[index * WIDTH_32 + Field32.PROFILE] = profile
	return true


func profile_of(target: int) -> int:
	var index: int = _index(target)
	return NO_PROFILE if index < 0 else _slots_32[index * WIDTH_32 + Field32.PROFILE]


func status_mask(target: int) -> int:
	var index: int = _index(target)
	if index < 0 or _stats.get_stat(target, StatBlock.Stat.HP) <= 0:
		return 0
	var base: int = index * WIDTH_64
	var mask: int = 0
	if _slots_64[base + Field64.SHOCK_UNTIL] > _last_tick: mask |= Mask.SHOCK
	if _slots_64[base + Field64.BURN_UNTIL] != 0: mask |= Mask.BURN
	if _slots_32[index * WIDTH_32 + Field32.CHILL_STACKS] > 0: mask |= Mask.CHILL
	if _slots_64[base + Field64.FREEZE_UNTIL] > _last_tick: mask |= Mask.FREEZE
	if _slots_32[index * WIDTH_32 + Field32.ACID_STACKS] > 0: mask |= Mask.CORROSION
	return mask


## O(1): true if the target has any status of the given Mask bits.
func has_status(target: int, mask: int) -> bool:
	return (status_mask(target) & mask) != 0


## Desired-movement scale ×1000: 0 while shocked or frozen, chill subtracts per stack.
func movement_scale(target: int) -> int:
	var mask: int = status_mask(target)
	if (mask & (Mask.SHOCK | Mask.FREEZE)) != 0:
		return 0
	if (mask & Mask.CHILL) == 0:
		return 1000
	return 1000 - _chill_slow * _slots_32[_index(target) * WIDTH_32 + Field32.CHILL_STACKS]


func control_blocked(target: int) -> bool:
	return (status_mask(target) & (Mask.SHOCK | Mask.FREEZE)) != 0


func is_frozen(target: int) -> bool:
	return (status_mask(target) & Mask.FREEZE) != 0


## Base ARMOR clamped to 0..ARMOR_SCALE minus corrosion, floor 0. Base ARMOR is never written.
func effective_armor(target: int) -> int:
	var armor: int = clampi(_stats.get_stat(target, StatBlock.Stat.ARMOR), 0, DamageApply.ARMOR_SCALE)
	var index: int = _index(target)
	if index < 0:
		return armor
	return maxi(0, armor - _acid_armor * _slots_32[index * WIDTH_32 + Field32.ACID_STACKS])


func acid_stacks(target: int) -> int:
	var index: int = _index(target)
	return 0 if index < 0 else _slots_32[index * WIDTH_32 + Field32.ACID_STACKS]


## A kill outside a contact or pulse (a reaction's secondary hit, a fall) clears the dead
## target's statuses at once, keeping its registration and burn generation. Refused while a
## step, contact or pulse is in progress; a living, unregistered or stale target is a no-op.
func clear_dead_target(target: int) -> bool:
	if not _initialized or _busy:
		return _refuse()
	var index: int = _index(target)
	if index >= 0 and _stats.get_stat(target, StatBlock.Stat.HP) <= 0:
		_clear_statuses(index)
	return true


## An admitted toxic explosion consumes the primary target's corrosion (M2.3b). Refused
## while a step, contact or pulse is in progress; an unregistered or stale handle is a no-op.
func consume_corrosion(target: int) -> bool:
	if not _initialized or _busy:
		return _refuse()
	var index: int = _index(target)
	if index >= 0:
		_slots_32[index * WIDTH_32 + Field32.ACID_STACKS] = 0
		_slots_64[index * WIDTH_64 + Field64.ACID_UNTIL] = 0
	return true


func chill_stacks(target: int) -> int:
	var index: int = _index(target)
	return 0 if index < 0 else _slots_32[index * WIDTH_32 + Field32.CHILL_STACKS]


## Burn field of a registered target (Field64.BURN_*), 0 for unregistered or stale handles.
func burn_field(target: int, field: Field64) -> int:
	var index: int = _index(target)
	if index < 0 or field < Field64.BURN_UNTIL or field > Field64.BURN_ORDINAL:
		return 0
	return _slots_64[index * WIDTH_64 + field]


## Expires statuses and executes due burn pulses. Any first tick is accepted; a repeated
## or past tick is a no-op. After skipped ticks each active burn executes at most one
## overdue pulse (due <= tick) and schedules the next one from the current tick.
func logic_step(tick: int) -> bool:
	if not _initialized or _busy or tick < 0 or tick > MAX_TICK:
		return _refuse()
	if tick <= _last_tick:
		return true
	_last_tick = tick
	_busy = true
	var kept: int = 0
	for read: int in _active_count:
		var index: int = _active[read]
		visited_slots += 1
		if _step_slot(index, tick):
			_active[kept] = index
			kept += 1
		else:
			_is_active[index] = 0
	for read: int in range(kept, _active_count):
		_active[read] = NO_SLOT
	_active_count = kept
	_busy = false
	return true


## DamagePipeline opens a direct contact before any damage write. Refused while a step,
## pulse or another contact is in progress, so callbacks cannot reenter the store.
func begin_contact() -> bool:
	if not _initialized or _busy:
		return _refuse()
	_busy = true
	_contact_open = true
	return true


## Closes the contact opened by begin_contact. hp_damage is the HP actually applied;
## shattered means the target was frozen when the contact started.
func end_contact(source: int, target: int, raw: int, element: DamagePayload.Element,
		hp_damage: int, shattered: bool, credit: int = 0, epoch: int = 0,
		sequence: int = 0, trace: int = 0, tags: int = 0) -> void:
	if not _contact_open:
		_refuse()
		return
	var index: int = _index(target)
	if index >= 0 and hp_damage > 0:
		if _stats.get_stat(target, StatBlock.Stat.HP) <= 0:
			_clear_statuses(index)
		else:
			if shattered:
				var base: int = index * WIDTH_64
				_slots_64[base + Field64.FREEZE_UNTIL] = 0
				_slots_64[base + Field64.CHILL_UNTIL] = 0
				_slots_32[index * WIDTH_32 + Field32.CHILL_STACKS] = 0
			if _slots_32[index * WIDTH_32 + Field32.PROFILE] != Profile.INERT:
				_apply_element(index, source, raw, element, shattered, credit, epoch, sequence, trace, tags)
	_contact_open = false
	_busy = false


## True only inside this runtime's own pulse; DamagePipeline admits DOT payloads then.
func is_resolving_pulse() -> bool:
	return _pulse_open


## Clears all status state, pulse progress and metrics; keeps registrations, profiles and
## burn generations (StatBlock and its handles survive a room reset). O(active slots).
func reset_room() -> bool:
	if not _initialized or _busy:
		return _refuse()
	for read: int in _active_count:
		var index: int = _active[read]
		_clear_statuses(index)
		_is_active[index] = 0
		_active[read] = NO_SLOT
	_active_count = 0
	_last_tick = 0
	_payloads.clear()
	_payloads.reset_dropped_count()
	_pipeline.reset_counters()
	applied_statuses = 0
	processed_pulses = 0
	pulse_hp_damage = 0
	pulse_kills = 0
	visited_slots = 0
	reset_diagnostics()
	return true


func can_reset_room() -> bool:
	return _initialized and not _busy


func reset_diagnostics() -> void:
	configuration_errors = 0
	_reported = false


## Cold, status-only snapshot with an external StatBlock witness that restore compares and
## never writes. Dead or stale targets are canonicalized in the copy.
func get_state() -> Dictionary:
	if not _initialized or _busy:
		_refuse()
		return {}
	var slots_64: PackedInt64Array = _slots_64.duplicate()
	var slots_32: PackedInt32Array = _slots_32.duplicate()
	for index: int in _capacity:
		var base: int = index * WIDTH_64
		var target: int = slots_64[base + Field64.TARGET]
		if target == NO_TARGET:
			continue
		var generation: int = slots_64[base + Field64.BURN_GENERATION]
		if not _stats.is_valid(target):
			target = NO_TARGET
			generation = 0
			slots_32[index * WIDTH_32 + Field32.PROFILE] = NO_PROFILE
		elif _stats.get_stat(target, StatBlock.Stat.HP) > 0:
			continue
		var profile: int = slots_32[index * WIDTH_32 + Field32.PROFILE]
		_write_cleared(slots_64, slots_32, index)
		slots_64[base + Field64.TARGET] = target
		slots_64[base + Field64.BURN_GENERATION] = generation
		slots_32[index * WIDTH_32 + Field32.PROFILE] = profile
	return {"version": SNAPSHOT_VERSION, "capacity": _capacity, "last_tick": _last_tick,
			"external_stats": _stats.get_state(), "slots_64": slots_64, "slots_32": slots_32}


## Restores a status-only snapshot taken at compatible_tick (the caller's clock). Every
## field is validated before any write; a refused restore changes nothing.
func set_state(state: Dictionary, compatible_tick: int) -> bool:
	if not _initialized or _busy or not _validate_state(state, compatible_tick):
		return _refuse()
	var slots_64: PackedInt64Array = state.slots_64
	var slots_32: PackedInt32Array = state.slots_32
	_slots_64 = slots_64.duplicate()
	_slots_32 = slots_32.duplicate()
	_last_tick = state.last_tick
	_active.fill(NO_SLOT)
	_is_active.fill(0)
	_active_count = 0
	for index: int in _capacity:
		if _has_state(index):
			_active[_active_count] = index
			_is_active[index] = 1
			_active_count += 1
	return true


func _index(target: int) -> int:
	if not _initialized:
		return -1
	var index: int = _stats.index_of(target)
	return index if index >= 0 and _slots_64[index * WIDTH_64 + Field64.TARGET] == target else -1


func _step_slot(index: int, tick: int) -> bool:
	var base: int = index * WIDTH_64
	var target: int = _slots_64[base + Field64.TARGET]
	if not _stats.is_valid(target):
		_unbind(index)
		return false
	if _stats.get_stat(target, StatBlock.Stat.HP) <= 0:
		_clear_statuses(index)
		return false
	if _slots_64[base + Field64.SHOCK_UNTIL] <= tick: _slots_64[base + Field64.SHOCK_UNTIL] = 0
	if _slots_64[base + Field64.SHOCK_READY] <= tick: _slots_64[base + Field64.SHOCK_READY] = 0
	if _slots_64[base + Field64.CHILL_UNTIL] <= tick:
		_slots_64[base + Field64.CHILL_UNTIL] = 0
		_slots_32[index * WIDTH_32 + Field32.CHILL_STACKS] = 0
	if _slots_64[base + Field64.FREEZE_UNTIL] <= tick: _slots_64[base + Field64.FREEZE_UNTIL] = 0
	if _slots_64[base + Field64.FREEZE_READY] <= tick: _slots_64[base + Field64.FREEZE_READY] = 0
	if _slots_64[base + Field64.ACID_UNTIL] <= tick:
		_slots_64[base + Field64.ACID_UNTIL] = 0
		_slots_32[index * WIDTH_32 + Field32.ACID_STACKS] = 0
	if _slots_64[base + Field64.BURN_UNTIL] != 0 and _slots_64[base + Field64.BURN_NEXT_DUE] <= tick:
		_resolve_pulse(index, tick)
	return _has_state(index)


func _has_state(index: int) -> bool:
	var base: int = index * WIDTH_64
	return _slots_64[base + Field64.SHOCK_UNTIL] != 0 or _slots_64[base + Field64.SHOCK_READY] != 0 \
			or _slots_64[base + Field64.BURN_UNTIL] != 0 or _slots_64[base + Field64.CHILL_UNTIL] != 0 \
			or _slots_64[base + Field64.FREEZE_UNTIL] != 0 or _slots_64[base + Field64.FREEZE_READY] != 0 \
			or _slots_64[base + Field64.ACID_UNTIL] != 0


## Inserts the slot into the sorted active list once. Called only outside a step.
func _activate(index: int) -> void:
	if _is_active[index] != 0:
		return
	_is_active[index] = 1
	var position: int = _active.bsearch(index)
	for read: int in range(_active_count, position, -1):
		_active[read] = _active[read - 1]
	_active[position] = index
	_active_count += 1


func _apply_element(index: int, source: int, raw: int, element: DamagePayload.Element,
		shattered: bool, credit: int, epoch: int, sequence: int, trace: int, tags: int) -> void:
	var base: int = index * WIDTH_64
	var ordinary: bool = _slots_32[index * WIDTH_32 + Field32.PROFILE] == Profile.ORDINARY
	var now: int = _last_tick
	match element:
		DamagePayload.Element.ELECTRIC:
			if not ordinary or _slots_64[base + Field64.SHOCK_READY] > now:
				return
			_slots_64[base + Field64.SHOCK_UNTIL] = now + _shock_ticks
			_slots_64[base + Field64.SHOCK_READY] = now + _shock_cooldown
		DamagePayload.Element.FIRE:
			var pulse: int = raw / _burn_divisor
			if pulse <= 0:
				return
			if _slots_64[base + Field64.BURN_UNTIL] == 0:
				_slots_64[base + Field64.BURN_GENERATION] += 1
				_slots_64[base + Field64.BURN_NEXT_DUE] = now + _burn_period
				_slots_64[base + Field64.BURN_ORDINAL] = 0
			# A stronger pulse replaces amount and attribution together.
			if pulse > _slots_64[base + Field64.BURN_AMOUNT]:
				_slots_64[base + Field64.BURN_AMOUNT] = pulse
				_slots_64[base + Field64.BURN_SOURCE] = source
				_slots_64[base + Field64.BURN_CREDIT] = credit
				_slots_64[base + Field64.BURN_EPOCH] = epoch
				_slots_64[base + Field64.BURN_SEQUENCE] = sequence
				_slots_64[base + Field64.BURN_TRACE] = trace
				_slots_64[base + Field64.BURN_TAGS] = tags
			_slots_64[base + Field64.BURN_UNTIL] = now + _burn_ticks
		DamagePayload.Element.ICE:
			if shattered or _slots_64[base + Field64.FREEZE_UNTIL] > now:
				return
			var stacks: int = _slots_32[index * WIDTH_32 + Field32.CHILL_STACKS]
			# Two old stacks plus an eligible third contact on an ordinary target freeze it.
			if stacks == 2 and ordinary and _slots_64[base + Field64.FREEZE_READY] <= now:
				_slots_32[index * WIDTH_32 + Field32.CHILL_STACKS] = 0
				_slots_64[base + Field64.CHILL_UNTIL] = 0
				_slots_64[base + Field64.FREEZE_UNTIL] = now + _freeze_ticks
				_slots_64[base + Field64.FREEZE_READY] = now + _freeze_cooldown
			else:
				_slots_32[index * WIDTH_32 + Field32.CHILL_STACKS] = mini(2, stacks + 1)
				_slots_64[base + Field64.CHILL_UNTIL] = now + _chill_ticks
		DamagePayload.Element.ACID:
			var acid: int = _slots_32[index * WIDTH_32 + Field32.ACID_STACKS]
			_slots_32[index * WIDTH_32 + Field32.ACID_STACKS] = mini(_acid_cap, acid + 1)
			_slots_64[base + Field64.ACID_UNTIL] = now + _acid_ticks
		_:
			return
	applied_statuses += 1
	_activate(index)


func _resolve_pulse(index: int, tick: int) -> void:
	var base: int = index * WIDTH_64
	var target: int = _slots_64[base + Field64.TARGET]
	var source: int = _slots_64[base + Field64.BURN_SOURCE]
	var credit: int = _slots_64[base + Field64.BURN_CREDIT]
	var generation: int = _slots_64[base + Field64.BURN_GENERATION]
	var ordinal: int = _slots_64[base + Field64.BURN_ORDINAL] + 1
	var epoch: int = _slots_64[base + Field64.BURN_EPOCH]
	var sequence: int = _slots_64[base + Field64.BURN_SEQUENCE]
	var trace: int = _slots_64[base + Field64.BURN_TRACE]
	var tags: int = _slots_64[base + Field64.BURN_TAGS]
	var before: int = _stats.get_stat(target, StatBlock.Stat.HP)
	_payloads.push(source, target, _slots_64[base + Field64.BURN_AMOUNT], DamagePayload.Element.FIRE,
			tags, DamagePayload.Flag.DOT | DamagePayload.Flag.SECONDARY, AttackContextPool.INVALID_HANDLE)
	_pulse_open = true
	var damage: int = _pipeline.resolve_dot_front(_payloads, self)
	_pulse_open = false
	if damage < 0:
		# Unreachable with a validated store: the burn is dropped, not retried every tick.
		_payloads.clear()
		_clear_burn(index)
		_refuse()
		return
	var killed: bool = before > 0 and _stats.get_stat(target, StatBlock.Stat.HP) == 0
	_slots_64[base + Field64.BURN_ORDINAL] = ordinal
	processed_pulses += 1
	pulse_hp_damage += damage
	if killed:
		pulse_kills += 1
		_clear_statuses(index)
	elif tick + _burn_period > _slots_64[base + Field64.BURN_UNTIL]:
		_clear_burn(index)
	else:
		_slots_64[base + Field64.BURN_NEXT_DUE] = tick + _burn_period
	on_pulse_hit.emit(source, target, credit, generation, ordinal, damage, epoch, sequence, trace, tags)
	if killed:
		on_pulse_kill.emit(source, target, credit, generation, ordinal, damage, epoch, sequence, trace, tags)
	_payloads.pop_front()
	on_pulse_resolved.emit(source, target, credit, generation, ordinal, damage, epoch, sequence, trace, tags)


func _clear_burn(index: int) -> void:
	var base: int = index * WIDTH_64
	for field: int in range(Field64.BURN_UNTIL, Field64.BURN_ORDINAL + 1):
		if field != Field64.BURN_GENERATION:
			_slots_64[base + field] = 0
	_slots_64[base + Field64.BURN_SOURCE] = NO_TARGET


## Clears every status but keeps the registration and burn generation.
func _clear_statuses(index: int) -> void:
	var base: int = index * WIDTH_64
	var target: int = _slots_64[base + Field64.TARGET]
	var generation: int = _slots_64[base + Field64.BURN_GENERATION]
	var profile: int = _slots_32[index * WIDTH_32 + Field32.PROFILE]
	_write_cleared(_slots_64, _slots_32, index)
	_slots_64[base + Field64.TARGET] = target
	_slots_64[base + Field64.BURN_GENERATION] = generation
	_slots_32[index * WIDTH_32 + Field32.PROFILE] = profile


func _unbind(index: int) -> void:
	_write_cleared(_slots_64, _slots_32, index)


## Canonical empty record: no target, no profile, every field zero, burn source invalid.
static func _write_cleared(slots_64: PackedInt64Array, slots_32: PackedInt32Array, index: int) -> void:
	var base: int = index * WIDTH_64
	for field: int in WIDTH_64:
		slots_64[base + field] = 0
	slots_64[base + Field64.TARGET] = NO_TARGET
	slots_64[base + Field64.BURN_SOURCE] = NO_TARGET
	slots_32[index * WIDTH_32 + Field32.PROFILE] = NO_PROFILE
	slots_32[index * WIDTH_32 + Field32.CHILL_STACKS] = 0
	slots_32[index * WIDTH_32 + Field32.ACID_STACKS] = 0


func _refuse() -> bool:
	configuration_errors += 1
	if not _reported:
		_reported = true
		push_error(CONFIGURATION_ERROR)
	return false


func _validate_state(state: Dictionary, compatible_tick: int) -> bool:
	if state.size() != SNAPSHOT_KEYS.size():
		return false
	for key: String in SNAPSHOT_KEYS:
		if not state.has(key):
			return false
	if typeof(state.version) != TYPE_INT or typeof(state.capacity) != TYPE_INT \
			or typeof(state.last_tick) != TYPE_INT or typeof(state.external_stats) != TYPE_DICTIONARY \
			or typeof(state.slots_64) != TYPE_PACKED_INT64_ARRAY \
			or typeof(state.slots_32) != TYPE_PACKED_INT32_ARRAY:
		return false
	if state.version != SNAPSHOT_VERSION or state.capacity != _capacity \
			or state.last_tick < 0 or state.last_tick > MAX_TICK or state.last_tick != compatible_tick:
		return false
	var witness: Dictionary = state.external_stats
	var external: Dictionary = _stats.get_state()
	if witness.size() != external.size():
		return false
	for key: String in external:
		if not witness.has(key) or typeof(witness[key]) != typeof(external[key]) or witness[key] != external[key]:
			return false
	var slots_64: PackedInt64Array = state.slots_64
	var slots_32: PackedInt32Array = state.slots_32
	if slots_64.size() != _capacity * WIDTH_64 or slots_32.size() != _capacity * WIDTH_32:
		return false
	for index: int in _capacity:
		if not _validate_slot(slots_64, slots_32, index, state.last_tick):
			return false
	return true


func _validate_slot(slots_64: PackedInt64Array, slots_32: PackedInt32Array, index: int, tick: int) -> bool:
	var base: int = index * WIDTH_64
	var target: int = slots_64[base + Field64.TARGET]
	var profile: int = slots_32[index * WIDTH_32 + Field32.PROFILE]
	var chill: int = slots_32[index * WIDTH_32 + Field32.CHILL_STACKS]
	var acid: int = slots_32[index * WIDTH_32 + Field32.ACID_STACKS]
	var generation: int = slots_64[base + Field64.BURN_GENERATION]
	if generation < 0 or generation >= MAX_COUNT:
		return false
	if target == NO_TARGET:
		if profile != NO_PROFILE or generation != 0:
			return false
	elif _stats.index_of(target) != index or profile < Profile.ORDINARY or profile > Profile.INERT:
		return false
	# Every deadline is zero or within its own duration of the snapshot tick.
	if not _deadline_ok(slots_64[base + Field64.SHOCK_UNTIL], tick, _shock_ticks) \
			or not _deadline_ok(slots_64[base + Field64.SHOCK_READY], tick, _shock_cooldown) \
			or not _deadline_ok(slots_64[base + Field64.BURN_UNTIL], tick, _burn_ticks) \
			or not _deadline_ok(slots_64[base + Field64.CHILL_UNTIL], tick, _chill_ticks) \
			or not _deadline_ok(slots_64[base + Field64.FREEZE_UNTIL], tick, _freeze_ticks) \
			or not _deadline_ok(slots_64[base + Field64.FREEZE_READY], tick, _freeze_cooldown) \
			or not _deadline_ok(slots_64[base + Field64.ACID_UNTIL], tick, _acid_ticks):
		return false
	if chill < 0 or chill > 2 or (chill == 0) != (slots_64[base + Field64.CHILL_UNTIL] == 0) \
			or acid < 0 or acid > _acid_cap or (acid == 0) != (slots_64[base + Field64.ACID_UNTIL] == 0):
		return false
	var shock_until: int = slots_64[base + Field64.SHOCK_UNTIL]
	if shock_until != 0 and slots_64[base + Field64.SHOCK_READY] - shock_until != _shock_cooldown - _shock_ticks:
		return false
	var freeze_until: int = slots_64[base + Field64.FREEZE_UNTIL]
	if freeze_until != 0 and (chill != 0 \
			or slots_64[base + Field64.FREEZE_READY] - freeze_until != _freeze_cooldown - _freeze_ticks):
		return false
	if profile != Profile.ORDINARY and (shock_until != 0 or slots_64[base + Field64.SHOCK_READY] != 0 \
			or freeze_until != 0 or slots_64[base + Field64.FREEZE_READY] != 0):
		return false
	var burn_until: int = slots_64[base + Field64.BURN_UNTIL]
	var ordinal: int = slots_64[base + Field64.BURN_ORDINAL]
	if burn_until == 0:
		for field: int in range(Field64.BURN_NEXT_DUE, Field64.BURN_ORDINAL + 1):
			if field != Field64.BURN_GENERATION and field != Field64.BURN_SOURCE and slots_64[base + field] != 0:
				return false
		if slots_64[base + Field64.BURN_SOURCE] != NO_TARGET:
			return false
	else:
		var next_due: int = slots_64[base + Field64.BURN_NEXT_DUE]
		var amount: int = slots_64[base + Field64.BURN_AMOUNT]
		if generation <= 0 or amount <= 0 or amount > MAX_INT / _burn_divisor \
				or slots_64[base + Field64.BURN_SOURCE] < 0 or ordinal < 0 or ordinal >= MAX_COUNT \
				or next_due <= tick or next_due > tick + _burn_period or next_due > burn_until:
			return false
	# Statuses belong only to a live, non-inert, registered target.
	var has_state: bool = chill != 0 or acid != 0 or shock_until != 0 or freeze_until != 0 \
			or burn_until != 0 or slots_64[base + Field64.SHOCK_READY] != 0 \
			or slots_64[base + Field64.FREEZE_READY] != 0
	if has_state and (target == NO_TARGET or profile == Profile.INERT \
			or _stats.get_stat(target, StatBlock.Stat.HP) <= 0):
		return false
	return true


static func _deadline_ok(deadline: int, tick: int, duration: int) -> bool:
	return deadline == 0 or (deadline > tick and deadline <= tick + duration)
