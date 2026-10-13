class_name ShotResolver
extends RefCounted
## Minimal M1 Apply/PostHit. Local signals expose the contract without an M2 engine.

signal on_fire(source: int, epoch: int, sequence: int, root: int)
signal on_hit(source: int, target: int, epoch: int, sequence: int, trace: int, child: int, hp_damage: int)
signal on_kill(source: int, target: int, epoch: int, sequence: int, trace: int)
signal on_attack_resolved(source: int, epoch: int, sequence: int, root: int)

var contexts: AttackContextPool
var resolved_shots: int = 0
var registered_hits: int = 0
var kills: int = 0
var no_op_traces: int = 0
var logic_steps: int = 0
var _stats: StatBlock
var _batch: ShotBatch
var _last_tick: int = -1
var _root: PackedInt64Array = PackedInt64Array()
var _source: PackedInt64Array = PackedInt64Array()
var _sequence: PackedInt64Array = PackedInt64Array()
var _epoch: PackedInt64Array = PackedInt64Array()
var _owned: PackedInt64Array = PackedInt64Array()
var _owned_root: PackedInt64Array = PackedInt64Array()


func _init(stats: StatBlock, batch: ShotBatch, capacity: int) -> void:
	_stats = stats
	_batch = batch
	contexts = AttackContextPool.new(capacity)
	_root.resize(capacity)
	_root.fill(AttackContextPool.INVALID_HANDLE)
	_source.resize(capacity)
	_sequence.resize(capacity)
	_epoch.resize(capacity)
	_owned.resize(capacity)
	_owned.fill(AttackContextPool.INVALID_HANDLE)
	_owned_root.resize(capacity)
	_owned_root.fill(AttackContextPool.INVALID_HANDLE)


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
	var root: int = contexts.open_root(source, traces)
	if root == AttackContextPool.INVALID_HANDLE:
		return
	var slot: int = root % HandlePool.INDEX_SPAN
	_owned[slot] = root
	_owned_root[slot] = root
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
			var damage: int = DamageApply.apply(_stats, target, _batch.damage_at(shot))
			var killed: bool = before > 0 and _stats.get_stat(target, StatBlock.Stat.HP) == 0
			registered_hits += 1
			on_hit.emit(source, target, _epoch[slot], _sequence[slot], trace, child, damage)
			if killed:
				kills += 1
				on_kill.emit(source, target, _epoch[slot], _sequence[slot], trace)
		close_context(child)
	close_context(root)


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
	for index: int in _owned.size():
		if _owned_root[index] == root:
			_owned[index] = AttackContextPool.INVALID_HANDLE
			_owned_root[index] = AttackContextPool.INVALID_HANDLE
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
		_owned[slot] = child
		_owned_root[slot] = root
	return child


## Quiescent room reset cancels retained trees as well as pending physical records.
func reset_room() -> bool:
	if not _batch.reset_room():
		return false
	for handle: int in _owned:
		if contexts.is_valid(handle):
			contexts.close(handle)
	_owned.fill(AttackContextPool.INVALID_HANDLE)
	_owned_root.fill(AttackContextPool.INVALID_HANDLE)
	_root.fill(AttackContextPool.INVALID_HANDLE)
	contexts.reset_counters()
	_last_tick = -1
	resolved_shots = 0
	registered_hits = 0
	kills = 0
	no_op_traces = 0
	logic_steps = 0
	return true
