class_name ShotResolver
extends RefCounted
## Sequential pellet damage and local PostHit signals; caller owns attack trees.

signal on_fire(source: int, epoch: int, sequence: int, root: int)
signal on_hit(source: int, target: int, epoch: int, sequence: int, trace: int, child: int, hp_damage: int)
signal on_kill(source: int, target: int, epoch: int, sequence: int, trace: int)
signal on_attack_resolved(source: int, epoch: int, sequence: int, root: int)
## Secondary hits of reactions (M2.3b), kept apart from on_hit/on_kill so that direct-hit
## consumers such as EffectRunner never receive them by accident.
signal on_secondary_hit(source: int, target: int, epoch: int, sequence: int, trace: int, child: int, hp_damage: int)
signal on_secondary_kill(source: int, target: int, epoch: int, sequence: int, trace: int)

const NO_SLOT: int = -1
const REACTIONS_ERROR: String = "ShotResolver: reactions must be initialized on the resolver's StatusRuntime"

var contexts: AttackContextPool
var damage_pipeline: DamagePipeline
var resolved_shots: int = 0
var registered_hits: int = 0
var kills: int = 0
var no_op_traces: int = 0
var logic_steps: int = 0
var reaction_refusals: int = 0
## Construction errors: reactions that are not initialized or use another StatusRuntime.
var configuration_errors: int = 0
var _stats: StatBlock
var _batch: ShotBatch
var _payloads: DamagePayloadBuffer
var _reactions: ReactionRuntime
var _hit_budget_per_trace: int = 1
var _last_tick: int = -1
var _root: PackedInt64Array = PackedInt64Array()
var _source: PackedInt64Array = PackedInt64Array()
var _sequence: PackedInt64Array = PackedInt64Array()
var _epoch: PackedInt64Array = PackedInt64Array()
var _owned: PackedInt64Array = PackedInt64Array()
# Intrusive list of owned slots per root slot: final close clears only its own tree.
var _owned_head: PackedInt32Array = PackedInt32Array()
var _owned_next: PackedInt32Array = PackedInt32Array()


## statuses, when given, enables elemental pellets; it must use the same StatBlock.
## reactions, when given, must use the same statuses; each pellet may then add one reaction
## child (depth 2) with up to reactions.max_targets() secondary hits.
func _init(stats: StatBlock, batch: ShotBatch, capacity: int, statuses: StatusRuntime = null,
		reactions: ReactionRuntime = null) -> void:
	_stats = stats
	_batch = batch
	damage_pipeline = DamagePipeline.new(stats, statuses)
	if reactions != null:
		if statuses == null or not reactions.uses_statuses(statuses):
			configuration_errors += 1
			push_error(REACTIONS_ERROR)
		else:
			_reactions = reactions
			_hit_budget_per_trace = 1 + reactions.max_targets()
			reactions.on_hit.connect(_on_reaction_hit)
			reactions.on_kill.connect(_on_reaction_kill)
	_payloads = DamagePayloadBuffer.new(1)
	contexts = AttackContextPool.new(capacity)
	_root.resize(capacity)
	_root.fill(AttackContextPool.INVALID_HANDLE)
	_source.resize(capacity)
	_sequence.resize(capacity)
	_epoch.resize(capacity)
	_owned.resize(capacity)
	_owned.fill(AttackContextPool.INVALID_HANDLE)
	_owned_head.resize(capacity)
	_owned_head.fill(NO_SLOT)
	_owned_next.resize(capacity)
	_owned_next.fill(NO_SLOT)


func logic_step(tick: int) -> void:
	if tick <= _last_tick:
		return
	_last_tick = tick
	logic_steps += 1
	var shots: int = _batch.prepare()
	for shot: int in shots:
		_resolve(shot)
	_batch.consume_prepared()


func _resolve(shot: int) -> void:
	var source: int = _batch.source_at(shot)
	var traces: int = _batch.trace_count_at(shot)
	var root: int = contexts.open_root(source, traces * _hit_budget_per_trace)
	if root == AttackContextPool.INVALID_HANDLE:
		return
	var slot: int = root % HandlePool.INDEX_SPAN
	_owned[slot] = root
	_owned_next[slot] = NO_SLOT
	_owned_head[slot] = slot
	_root[slot] = root
	_source[slot] = source
	_sequence[slot] = _batch.sequence_at(shot)
	_epoch[slot] = _batch.epoch_at(shot)
	on_fire.emit(source, _epoch[slot], _sequence[slot], root)
	for trace: int in traces:
		var target: int = _batch.target_at(shot, trace)
		if not _stats.is_valid(target) or _stats.get_stat(target, StatBlock.Stat.HP) <= 0:
			no_op_traces += 1
			continue
		var child: int = open_child(root)
		if child == AttackContextPool.INVALID_HANDLE:
			continue
		if contexts.try_register_hit(child, target):
			var before: int = _stats.get_stat(target, StatBlock.Stat.HP)
			var raw: int = _batch.damage_at(shot)
			var element: DamagePayload.Element = _batch.element_at(shot)
			# Reaction inputs (team, pre-contact corrosion, WET) are captured before the contact.
			var planned: bool = _reactions != null and _reactions.plan(source, target, raw, element)
			var payload: int = _payloads.push(source, target, raw, element, 0, 0, child)
			if payload == DamagePayloadBuffer.INVALID_SLOT:
				_finish_reaction()
				close_context(child)
				continue
			var damage: int = damage_pipeline.resolve_front(_payloads, source, _epoch[slot],
					_sequence[slot], trace)
			if damage == DamagePipeline.INVALID_RESULT:
				_finish_reaction()
				_payloads.pop_front()
				close_context(child)
				continue
			var killed: bool = before > 0 and _stats.get_stat(target, StatBlock.Stat.HP) == 0
			var reaction_child: int = AttackContextPool.INVALID_HANDLE
			if planned and damage > 0:
				reaction_child = _open_reaction(child, damage, shot, trace)
			registered_hits += 1
			on_hit.emit(source, target, _epoch[slot], _sequence[slot], trace, child, damage)
			if killed:
				kills += 1
				on_kill.emit(source, target, _epoch[slot], _sequence[slot], trace)
			if reaction_child != AttackContextPool.INVALID_HANDLE:
				_reactions.execute(trace, contexts, reaction_child, _epoch[slot], _sequence[slot])
				close_context(reaction_child)
			_finish_reaction()
			_payloads.pop_front()
		close_context(child)
	close_context(root)


## Opens the reaction child before the primary callbacks and admits the planned reaction
## on it (target selection; an admitted explosion consumes corrosion here). A full context
## pool or a hit budget smaller than the reaction's targets is a configuration error, and a
## reaction without eligible candidates is not admitted: no acid is consumed either way.
func _open_reaction(child: int, damage: int, shot: int, trace: int) -> int:
	if contexts.budget_left(child) < _reactions.planned_limit():
		reaction_refusals += 1
		return AttackContextPool.INVALID_HANDLE
	var reaction_child: int = open_child(child)
	if reaction_child == AttackContextPool.INVALID_HANDLE:
		reaction_refusals += 1
		return reaction_child
	if not _reactions.admit(damage, _batch, shot, trace):
		close_context(reaction_child)
		return AttackContextPool.INVALID_HANDLE
	return reaction_child


func _finish_reaction() -> void:
	if _reactions != null:
		_reactions.finish()


func _on_reaction_hit(source: int, target: int, epoch: int, sequence: int, trace: int,
		child: int, hp_damage: int) -> void:
	on_secondary_hit.emit(source, target, epoch, sequence, trace, child, hp_damage)


func _on_reaction_kill(source: int, target: int, epoch: int, sequence: int, trace: int) -> void:
	on_secondary_kill.emit(source, target, epoch, sequence, trace)


## The resolver's one-record payload scratch, for fault-injection tests of its overflow
## path. Gameplay never writes it.
func scratch_payloads() -> DamagePayloadBuffer:
	return _payloads


func damage_configuration_errors() -> int:
	var reaction_errors: int = 0 if _reactions == null else _reactions.damage_configuration_errors()
	return _payloads.dropped_count() + damage_pipeline.configuration_errors + reaction_errors \
			+ configuration_errors


func uses_stats(stats: StatBlock) -> bool:
	return _stats == stats


## Read-only inspection: owned slots listed at this root's slot. A released root's list is
## empty; 0 is also returned when another live root now occupies the slot.
func owned_count(root: int) -> int:
	if root < 0:
		return 0
	var slot: int = root % HandlePool.INDEX_SPAN
	if slot >= _root.size() or (_root[slot] != root and _root[slot] != AttackContextPool.INVALID_HANDLE):
		return 0
	var count: int = 0
	var index: int = _owned_head[slot]
	while index != NO_SLOT:
		count += 1
		index = _owned_next[index]
	return count


## Deferred owners must close through this boundary so final completion retains metadata.
func close_context(context: int) -> bool:
	var root: int = contexts.root_of(context)
	if root == AttackContextPool.INVALID_HANDLE:
		return false
	var slot: int = root % HandlePool.INDEX_SPAN
	if _root[slot] != root:
		return false
	var source: int = _source[slot]
	var sequence: int = _sequence[slot]
	var room_epoch: int = _epoch[slot]
	if not contexts.close(context):
		return false
	_root[slot] = AttackContextPool.INVALID_HANDLE
	var index: int = _owned_head[slot]
	while index != NO_SLOT:
		var next_index: int = _owned_next[index]
		_owned[index] = AttackContextPool.INVALID_HANDLE
		_owned_next[index] = NO_SLOT
		index = next_index
	_owned_head[slot] = NO_SLOT
	resolved_shots += 1
	on_attack_resolved.emit(source, room_epoch, sequence, root)
	return true


## Deferred owners reserve through this boundary before final close, then close_context.
func open_child(parent: int) -> int:
	var root: int = contexts.root_of(parent)
	if root == AttackContextPool.INVALID_HANDLE or _root[root % HandlePool.INDEX_SPAN] != root:
		return AttackContextPool.INVALID_HANDLE
	var child: int = contexts.open_child(parent)
	if child != AttackContextPool.INVALID_HANDLE:
		var slot: int = child % HandlePool.INDEX_SPAN
		var root_slot: int = root % HandlePool.INDEX_SPAN
		_owned[slot] = child
		_owned_next[slot] = _owned_head[root_slot]
		_owned_head[root_slot] = slot
	return child


## Quiescent room reset cancels retained trees as well as pending physical records.
func reset_room() -> bool:
	if not _batch.reset_room():
		return false
	for handle: int in _owned:
		if contexts.is_valid(handle):
			contexts.close(handle)
	_owned.fill(AttackContextPool.INVALID_HANDLE)
	_owned_head.fill(NO_SLOT)
	_owned_next.fill(NO_SLOT)
	_root.fill(AttackContextPool.INVALID_HANDLE)
	contexts.reset_counters()
	_payloads.clear()
	_payloads.reset_dropped_count()
	damage_pipeline.reset_counters()
	_last_tick = -1
	reaction_refusals = 0
	resolved_shots = 0
	registered_hits = 0
	kills = 0
	no_op_traces = 0
	logic_steps = 0
	return true
