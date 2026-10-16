class_name ReactionRuntime
extends RefCounted
## Elemental reactions of the room (M2.3b, contracts §2 ReactionRuntime). One inline reaction
## per direct pellet: radial arcs, a conducting pulse or a toxic explosion. Area candidates
## come from the physics adapter through ShotBatch; this class never sees positions. It
## keeps a per-slot registry of full handle, team and WET, sorts candidates by full handle
## and resolves secondary hits through its own DamagePipeline.

signal on_hit(source: int, target: int, epoch: int, sequence: int, trace: int, child: int, hp_damage: int)
signal on_kill(source: int, target: int, epoch: int, sequence: int, trace: int)

const CONFIGURATION_ERROR: String = "ReactionRuntime: invalid configuration, state or call"
const NO_TARGET: int = -1
const MAX_TEAM: int = 0x7FFFFFFF

var configuration_errors: int = 0
var admitted_reactions: int = 0
var arcs: int = 0
var conducting: int = 0
var explosions: int = 0
var inspected_candidates: int = 0
var secondary_hits: int = 0
var secondary_hp_damage: int = 0
var secondary_kills: int = 0
## Selected targets that died or were released before their secondary hit.
var stale_skips: int = 0
## Secondary hits refused by the attack context (hit budget or branch hit-set).
var hit_refusals: int = 0
var _stats: StatBlock
var _statuses: StatusRuntime
var _pipeline: DamagePipeline
var _payloads: DamagePayloadBuffer
var _initialized: bool = false
var _reported: bool = false
var _capacity: int = 0
var _max_targets: int = 0
var _rules: ReactionRules
var _target: PackedInt64Array = PackedInt64Array()
var _team: PackedInt32Array = PackedInt32Array()
var _wet: PackedByteArray = PackedByteArray()
var _selected: PackedInt64Array = PackedInt64Array()
var _selected_count: int = 0
var _planned: bool = false
var _admitted: bool = false
var _executing: bool = false
var _kind: ReactionRules.Kind = ReactionRules.Kind.NONE
var _source: int = NO_TARGET
var _primary: int = NO_TARGET
var _source_team: int = 0
var _damage: int = 0
var _limit: int = 0


## Cold: one registry record per StatBlock slot. statuses must be built on the same StatBlock.
func _init(stats: StatBlock, statuses: StatusRuntime,
		rules: ReactionRules = preload("res://data/status/default_reaction_rules.tres")) -> void:
	if stats == null or statuses == null or not statuses.uses_stats(stats) \
			or rules == null or not rules.is_valid():
		_refuse()
		return
	_stats = stats
	_statuses = statuses
	_rules = rules.duplicate() as ReactionRules
	_capacity = stats.capacity()
	_max_targets = rules.max_targets()
	_target.resize(_capacity)
	_target.fill(NO_TARGET)
	_team.resize(_capacity)
	_wet.resize(_capacity)
	_selected.resize(_max_targets)
	_payloads = DamagePayloadBuffer.new(1)
	_pipeline = DamagePipeline.new(stats, statuses)
	_initialized = true


func is_initialized() -> bool:
	return _initialized


func uses_stats(stats: StatBlock) -> bool:
	return _initialized and _stats == stats


func uses_statuses(statuses: StatusRuntime) -> bool:
	return _initialized and _statuses == statuses


## Packed bytes of the registry and the selection (wrappers excluded).
func packed_bytes() -> int:
	return _capacity * 13 + _max_targets * 8 if _initialized else 0


## Largest number of secondary targets of one reaction (root hit budget sizing).
func max_targets() -> int:
	return _max_targets


## Area radius of the approved preset, millimetres (physics adapter sizing).
func radius_mm() -> int:
	return _rules.radius_mm if _initialized else 0


## True if a pellet of this element needs area candidates from the physics adapter.
func needs_candidates(element: DamagePayload.Element) -> bool:
	return _initialized and _rules.needs_candidates(element)


func is_executing() -> bool:
	return _executing


## Binds a full handle to its team (0 = neutral, never reacts or is hit) and WET flag. The
## same handle may be re-registered to change them; a stale handle is an ordinary false.
func register_target(target: int, team: int, wet: bool = false) -> bool:
	if not _initialized or _planned or _executing or team < 0 or team > MAX_TEAM:
		return _refuse()
	var index: int = _stats.index_of(target)
	if index < 0:
		return false
	_target[index] = target
	_team[index] = team
	_wet[index] = 1 if wet else 0
	return true


func team_of(target: int) -> int:
	var index: int = _index(target)
	return 0 if index < 0 else _team[index]


func is_wet(target: int) -> bool:
	var index: int = _index(target)
	return index >= 0 and _wet[index] != 0


## Before the direct contact: captures source team, the primary's pre-contact corrosion and
## WET and the raw amount. Returns true if a reaction is planned. finish() must follow.
## A neutral source and a primary that is neutral or on the source's team never react.
func plan(source: int, primary: int, raw: int, element: DamagePayload.Element) -> bool:
	if not _initialized or _planned or _executing:
		_refuse()
		return false
	_planned = true
	_kind = ReactionRules.Kind.NONE
	_source = source
	_primary = primary
	_damage = 0
	_limit = 0
	var source_index: int = _index(source)
	var primary_index: int = _index(primary)
	if source_index < 0 or primary_index < 0 or raw <= 0 or _team[source_index] == 0 \
			or _team[primary_index] == 0 or _team[primary_index] == _team[source_index]:
		return false
	_source_team = _team[source_index]
	var kind: ReactionRules.Kind = _rules.reaction_kind(element, _statuses.acid_stacks(primary) > 0,
			_wet[primary_index] != 0)
	_limit = _rules.targets_for(kind)
	_damage = _fraction(raw, _rules.percent_for(kind))
	_kind = kind if _damage > 0 and _limit > 0 else ReactionRules.Kind.NONE
	return _kind != ReactionRules.Kind.NONE


## Targets the planned reaction may hit; the caller checks the hit budget against it.
func planned_limit() -> int:
	return _limit if _planned and _kind != ReactionRules.Kind.NONE else 0


## After the direct contact, before its callbacks: admits the planned reaction if the
## captured HP damage is positive (lethal hits included). An explosion consumes the
## primary's corrosion here, even if it later finds no targets.
func admit(hp_damage: int) -> bool:
	if not _planned or _admitted or _executing:
		_refuse()
		return false
	if _kind == ReactionRules.Kind.NONE or hp_damage <= 0:
		return false
	if _kind == ReactionRules.Kind.EXPLOSION and not _statuses.consume_corrosion(_primary):
		return _refuse()
	_admitted = true
	admitted_reactions += 1
	match _kind:
		ReactionRules.Kind.ARC: arcs += 1
		ReactionRules.Kind.CONDUCTING: conducting += 1
		ReactionRules.Kind.EXPLOSION: explosions += 1
	return true


## After the primary callbacks: selects up to the planned number of eligible candidates of
## this shot's trace, smallest full handle first, and resolves each secondary hit on the
## reaction child. Candidates that died or were released are skipped, never retargeted.
func execute(batch: ShotBatch, shot: int, trace: int, contexts: AttackContextPool, child: int,
		epoch: int, sequence: int) -> void:
	if not _admitted or _executing:
		_refuse()
		return
	_select(batch, shot, trace)
	_executing = true
	var element: DamagePayload.Element = DamagePayload.Element.FIRE if _kind == ReactionRules.Kind.EXPLOSION \
			else DamagePayload.Element.ELECTRIC
	for index: int in _selected_count:
		var target: int = _selected[index]
		var before: int = _stats.get_stat(target, StatBlock.Stat.HP)
		if not _stats.is_valid(target) or before <= 0:
			stale_skips += 1
			continue
		if not contexts.try_register_hit(child, target):
			hit_refusals += 1
			continue
		if _payloads.push(_source, target, _damage, element, 0, DamagePayload.Flag.SECONDARY, child) \
				== DamagePayloadBuffer.INVALID_SLOT:
			_refuse()
			continue
		var damage: int = _pipeline.resolve_secondary_front(_payloads, self)
		if damage < 0:
			_payloads.pop_front()
			_refuse()
			continue
		var killed: bool = _stats.get_stat(target, StatBlock.Stat.HP) == 0
		if killed:
			_statuses.clear_dead_target(target)  # like every other kill: statuses go at once
		secondary_hits += 1
		secondary_hp_damage += damage
		on_hit.emit(_source, target, epoch, sequence, trace, child, damage)
		if killed:
			secondary_kills += 1
			on_kill.emit(_source, target, epoch, sequence, trace)
		_payloads.pop_front()
	_executing = false


## Ends the pellet's reaction cycle, planned or not. Refused during execute().
func finish() -> void:
	if _executing:
		_refuse()
		return
	_planned = false
	_admitted = false
	_kind = ReactionRules.Kind.NONE
	_selected_count = 0


## Quiescent room reset: metrics and diagnostics; registrations survive like entities do.
func reset_room() -> bool:
	if not can_reset_room():
		return _refuse()
	admitted_reactions = 0
	arcs = 0
	conducting = 0
	explosions = 0
	inspected_candidates = 0
	secondary_hits = 0
	secondary_hp_damage = 0
	secondary_kills = 0
	stale_skips = 0
	hit_refusals = 0
	_payloads.clear()
	_payloads.reset_dropped_count()
	_pipeline.reset_counters()
	reset_diagnostics()
	return true


func can_reset_room() -> bool:
	return _initialized and not _planned and not _executing


func reset_diagnostics() -> void:
	configuration_errors = 0
	_reported = false


## Pipeline and scratch diagnostics of secondary hits, for acceptance gates.
func damage_configuration_errors() -> int:
	return _pipeline.configuration_errors + _payloads.dropped_count() if _initialized else 0


func _select(batch: ShotBatch, shot: int, trace: int) -> void:
	_selected_count = 0
	for candidate: int in batch.candidate_count_at(shot, trace):
		inspected_candidates += 1
		var target: int = batch.candidate_at(shot, trace, candidate)
		var index: int = _index(target)
		if index < 0 or target == _primary or target == _source or _team[index] == 0 \
				or _team[index] == _source_team or _stats.get_stat(target, StatBlock.Stat.HP) <= 0:
			continue
		# Keep the _limit smallest full handles, ascending; duplicates are ignored.
		var at: int = 0
		while at < _selected_count and _selected[at] < target:
			at += 1
		if at >= _limit or (at < _selected_count and _selected[at] == target):
			continue
		var shift: int = mini(_selected_count, _limit - 1)
		while shift > at:
			_selected[shift] = _selected[shift - 1]
			shift -= 1
		_selected[at] = target
		_selected_count = mini(_selected_count + 1, _limit)


static func _fraction(raw: int, percent: int) -> int:
	return (raw / 1000) * percent + ((raw % 1000) * percent) / 1000


func _index(target: int) -> int:
	if not _initialized:
		return -1
	var index: int = _stats.index_of(target)
	return index if index >= 0 and _target[index] == target else -1


func _refuse() -> bool:
	configuration_errors += 1
	if not _reported:
		_reported = true
		push_error(CONFIGURATION_ERROR)
	return false
