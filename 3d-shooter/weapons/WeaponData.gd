class_name WeaponData
extends Resource
## Shared content is validated and copied into runtime fields while loading.

@export var pellet_count: int = 8
@export var damage_raw: int = 6000
@export var range_mm: int = 40_000
@export var spread_millidegrees: int = 5000
@export var cooldown_ticks: int = 15
@export var pattern: StringName = &"central_ring"
@export var semi_auto: bool = true
## Element of every pellet; NONE is physical. Statuses come from the room StatusRuntime.
@export var element: DamagePayload.Element = DamagePayload.Element.NONE


func is_valid() -> bool:
	return pellet_count > 0 and pellet_count <= StatBlock.VALUE_MAX \
			and damage_raw > 0 and damage_raw <= StatBlock.VALUE_MAX \
			and range_mm > 0 and range_mm <= StatBlock.VALUE_MAX \
			and spread_millidegrees >= 0 and spread_millidegrees < 90_000 \
			and cooldown_ticks > 0 and cooldown_ticks <= StatBlock.VALUE_MAX \
			and pattern == &"central_ring" and semi_auto \
			and element >= DamagePayload.Element.NONE and element <= DamagePayload.Element.ACID


## Room limits belong to the composition root, not the gameplay pellet preset.
## candidates: reaction candidates per trace (K, 0 = none). With reactions every pellet
## may own a reaction child, so each shot reserves 1 + 2 * stride contexts instead of
## 1 + stride.
static func validate_room(definitions: Array[WeaponData], shots: int, trace_cap: int,
		memory_cap: int, hosts: int, context_capacity: int, deferred_reserve: int,
		candidates: int = 0, reactions: bool = false) -> int:
	if definitions.is_empty() or shots <= 0 or trace_cap <= 0 or memory_cap <= 0 \
			or hosts <= 0 or hosts > HandlePool.MAX_CAPACITY or deferred_reserve < 0 or candidates < 0:
		return -1
	var stride: int = 0
	for data: WeaponData in definitions:
		if data == null or not data.is_valid() or data.pellet_count > trace_cap:
			return -1
		stride = maxi(stride, data.pellet_count)
	# Conservative packed-store budget, including context handles/hit sets and metadata.
	var bytes_per_shot: int = 68 + stride * (9 + 4 + 8 * candidates)
	if hosts > memory_cap / 16 or context_capacity <= 0 or context_capacity > memory_cap / 640:
		return -1
	var fixed_bytes: int = hosts * 16 + context_capacity * 640
	if fixed_bytes >= memory_cap or shots > (memory_cap - fixed_bytes) / bytes_per_shot:
		return -1
	if context_capacity <= 0 or context_capacity > HandlePool.MAX_CAPACITY \
			or deferred_reserve > context_capacity \
			or shots > (context_capacity - deferred_reserve) / (1 + (2 if reactions else 1) * stride):
		return -1
	return stride
