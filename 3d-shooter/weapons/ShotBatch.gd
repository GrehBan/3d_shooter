class_name ShotBatch
extends RefCounted
## Atomic complete-shot transport. The room owns this ONE sequence allocator.
## Each trace may carry up to candidate_capacity() reaction candidates: full handles found
## by the physics adapter around the hit target, written only before publish (physics
## tick) and read only from prepared shots (logic tick).

const INVALID: int = -1
const INT_MAX: int = 0x7FFFFFFFFFFFFFFF

var configuration_errors: int = 0
var epoch: int = 0
var _reported: bool = false
var _shots: int
var _stride: int
var _next_ticket: int = 0
var _occupied: int = 0
var _complete: int = 0
var _prepared: int = 0
var _ticket: PackedInt64Array = PackedInt64Array()
var _source: PackedInt64Array = PackedInt64Array()
var _sequence: PackedInt64Array = PackedInt64Array()
var _epoch: PackedInt64Array = PackedInt64Array()
var _damage: PackedInt64Array = PackedInt64Array()
var _element: PackedInt32Array = PackedInt32Array()
var _count: PackedInt32Array = PackedInt32Array()
var _written_count: PackedInt32Array = PackedInt32Array()
var _state: PackedByteArray = PackedByteArray()
var _target: PackedInt64Array = PackedInt64Array()
var _written: PackedByteArray = PackedByteArray()
var _order: PackedInt32Array = PackedInt32Array()
var _owner: PackedInt64Array = PackedInt64Array()
var _next_sequence: PackedInt64Array = PackedInt64Array()
var _candidate_capacity: int = 0
var _candidates: PackedInt64Array = PackedInt64Array()
var _candidate_count: PackedInt32Array = PackedInt32Array()


func _init(shots: int, stride: int, hosts: int, candidates: int = 0) -> void:
	assert(shots > 0 and stride > 0 and hosts > 0 and hosts <= HandlePool.MAX_CAPACITY and candidates >= 0)
	_shots = shots
	_stride = stride
	_candidate_capacity = maxi(candidates, 0)
	_candidates.resize(shots * stride * _candidate_capacity)
	_candidate_count.resize(shots * stride)
	_ticket.resize(shots)
	_source.resize(shots)
	_sequence.resize(shots)
	_epoch.resize(shots)
	_damage.resize(shots)
	_element.resize(shots)
	_count.resize(shots)
	_written_count.resize(shots)
	_state.resize(shots)
	_order.resize(shots)
	_target.resize(shots * stride)
	_written.resize(shots * stride)
	_owner.resize(hosts)
	_owner.fill(INVALID)
	_next_sequence.resize(hosts)


func trace_capacity() -> int:
	return _stride


func shot_capacity() -> int:
	return _shots


func candidate_capacity() -> int:
	return _candidate_capacity


func count() -> int:
	return _complete


func pending_count() -> int:
	return _occupied - _complete


## Reserve before cooldown, resources, effects or raycasts. No wrap is permitted.
func reserve(source: int, traces: int, damage: int,
		element: DamagePayload.Element = DamagePayload.Element.NONE) -> int:
	if source < 0 or traces <= 0 or traces > _stride or damage <= 0 \
			or element < DamagePayload.Element.NONE or element > DamagePayload.Element.ACID \
			or _occupied >= _shots or _next_ticket == INT_MAX:
		return reject_configuration()
	var host: int = source % HandlePool.INDEX_SPAN
	if host >= _owner.size() or (_owner[host] > source):
		return reject_configuration()
	if _owner[host] == source and _next_sequence[host] == INT_MAX:
		return reject_configuration()
	var slot: int = 0
	while _state[slot] != 0:
		slot += 1
	if _owner[host] != source:
		_owner[host] = source
		_next_sequence[host] = 0
	_next_ticket += 1
	_ticket[slot] = _next_ticket
	_source[slot] = source
	_sequence[slot] = _next_sequence[host]
	_next_sequence[host] += 1
	_epoch[slot] = epoch
	_damage[slot] = damage
	_element[slot] = element
	_count[slot] = traces
	_written_count[slot] = 0
	_state[slot] = 1
	for trace: int in traces:
		_written[slot * _stride + trace] = 0
		_candidate_count[slot * _stride + trace] = 0
	_occupied += 1
	return _ticket[slot]


func write_trace(ticket: int, index: int, target: int) -> bool:
	var slot: int = _find(ticket)
	if slot < 0 or _state[slot] != 1 or index < 0 or index >= _count[slot]:
		return false
	var offset: int = slot * _stride + index
	if _written[offset] != 0:
		return false
	_target[offset] = target
	_written[offset] = 1
	_written_count[slot] += 1
	return true


## Physics tick, before publish: appends one candidate handle to a trace. false when the
## ticket is not an open reservation, the trace is out of range or its candidates are full.
func add_candidate(ticket: int, trace: int, handle: int) -> bool:
	var slot: int = _find(ticket)
	if slot < 0 or _state[slot] != 1 or trace < 0 or trace >= _count[slot]:
		return false
	var offset: int = slot * _stride + trace
	var used: int = _candidate_count[offset]
	if used >= _candidate_capacity:
		return false
	_candidates[offset * _candidate_capacity + used] = handle
	_candidate_count[offset] = used + 1
	return true


## Free candidate slots of an open reservation's trace; -1 if the ticket is not an open
## reservation or the trace is out of range.
func candidate_space(ticket: int, trace: int) -> int:
	var slot: int = _find(ticket)
	if slot < 0 or _state[slot] != 1 or trace < 0 or trace >= _count[slot]:
		return INVALID
	return _candidate_capacity - _candidate_count[slot * _stride + trace]


func publish(ticket: int) -> bool:
	var slot: int = _find(ticket)
	if slot < 0 or _state[slot] != 1 or _written_count[slot] != _count[slot]:
		return false
	_state[slot] = 2
	_complete += 1
	return true


## Read only while a published ticket is still retained, before consume_prepared.
func sequence_for_ticket(ticket: int) -> int:
	var slot: int = _find(ticket)
	return INVALID if slot < 0 or _state[slot] != 2 else _sequence[slot]


func abort(ticket: int) -> bool:
	var slot: int = _find(ticket)
	if slot < 0 or _state[slot] != 1:
		return false
	_state[slot] = 0
	_occupied -= 1
	return true


func prepare() -> int:
	_prepared = 0
	for slot: int in _shots:
		if _state[slot] != 2:
			continue
		var position: int = _prepared
		while position > 0 and _before(slot, _order[position - 1]):
			_order[position] = _order[position - 1]
			position -= 1
		_order[position] = slot
		_prepared += 1
	return _prepared


func source_at(index: int) -> int:
	return _source[_order[index]]


func sequence_at(index: int) -> int:
	return _sequence[_order[index]]


func epoch_at(index: int) -> int:
	return _epoch[_order[index]]


func damage_at(index: int) -> int:
	return _damage[_order[index]]


func element_at(index: int) -> DamagePayload.Element:
	return _element[_order[index]] as DamagePayload.Element


func trace_count_at(index: int) -> int:
	return _count[_order[index]]


func target_at(index: int, trace: int) -> int:
	assert(trace >= 0 and trace < trace_count_at(index))
	return _target[_order[index] * _stride + trace]


func candidate_count_at(index: int, trace: int) -> int:
	return _candidate_count[_order[index] * _stride + trace]


func candidate_at(index: int, trace: int, candidate: int) -> int:
	return _candidates[(_order[index] * _stride + trace) * _candidate_capacity + candidate]


## Only prepared complete shots are consumed; unfinished reservations remain hidden.
func consume_prepared() -> void:
	for index: int in _prepared:
		_state[_order[index]] = 0
	_occupied -= _prepared
	_complete -= _prepared
	_prepared = 0


func reset_room() -> bool:
	if epoch == INT_MAX:
		reject_configuration()
		return false
	epoch += 1
	_state.fill(0)
	_owner.fill(INVALID)
	_next_sequence.fill(0)
	_occupied = 0
	_complete = 0
	_prepared = 0
	configuration_errors = 0
	_reported = false
	return true


func reject_configuration() -> int:
	configuration_errors += 1
	if not _reported:
		_reported = true
		push_error("ShotBatch: invalid request, capacity or identity exhausted")
	return INVALID


func _find(ticket: int) -> int:
	for slot: int in _shots:
		if _state[slot] != 0 and _ticket[slot] == ticket:
			return slot
	return INVALID


func _before(a: int, b: int) -> bool:
	return _source[a] < _source[b] or (_source[a] == _source[b] and _sequence[a] < _sequence[b])
