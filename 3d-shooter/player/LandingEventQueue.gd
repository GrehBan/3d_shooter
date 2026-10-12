class_name LandingEventQueue
extends RefCounted
## Preallocated FIFO SoA ring. Events are integer observations from engine physics.
## Consumer rejects stale full handles. No deterministic promise for Jolt inputs.

const DEFAULT_CAPACITY: int = 256
const MAX_CAPACITY: int = 65_536
const CANCEL_DASH: int = 1
const CANCEL_SLIDE: int = 2
const MAX_HEIGHT_MM: int = 922_337_203_685_485_580  # INT64_MAX / 10 + 8000

var _capacity: int
var _head: int = 0
var _count: int = 0
var _dropped: int = 0
var _reported: bool = false
var _entity: PackedInt64Array = PackedInt64Array()
var _height: PackedInt64Array = PackedInt64Array()
var _cancel: PackedInt32Array = PackedInt32Array()


func _init(capacity: int = DEFAULT_CAPACITY) -> void:
	assert(capacity > 0 and capacity <= MAX_CAPACITY, "LandingEventQueue: invalid capacity")
	_capacity = clampi(capacity, 1, MAX_CAPACITY)
	_entity.resize(_capacity)
	_height.resize(_capacity)
	_cancel.resize(_capacity)


func capacity() -> int:
	return _capacity


func count() -> int:
	return _count


func dropped_count() -> int:
	return _dropped


func reset_dropped_count() -> void:
	_dropped = 0


func push(entity: int, height_mm: int, cancel_flags: int) -> bool:
	if _count == _capacity:
		_dropped += 1
		if not _reported:
			_reported = true
			push_error("LandingEventQueue: overflow, landing event dropped")
		return false
	var record: int = (_head + _count) % _capacity
	_entity[record] = entity
	_height[record] = clampi(height_mm, 0, MAX_HEIGHT_MM)
	_cancel[record] = cancel_flags & (CANCEL_DASH | CANCEL_SLIDE)
	_count += 1
	return true


func get_entity(i: int) -> int:
	return _entity[(_head + i) % _capacity]


func get_height_mm(i: int) -> int:
	return _height[(_head + i) % _capacity]


func get_cancel_flags(i: int) -> int:
	return _cancel[(_head + i) % _capacity]


## Clears events and overflow report latch, preserving cumulative dropped count.
func clear() -> void:
	_head = (_head + _count) % _capacity
	_count = 0
	_reported = false
