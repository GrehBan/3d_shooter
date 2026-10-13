class_name ShotVisualData
extends Resource
## Immutable presentation preset; no combat decisions or deterministic values.

@export var muzzle_ticks: int = 3
@export var impact_ticks: int = 6
@export var mark_ticks: int = 180
@export var muzzle_size: float = 0.16
@export var impact_size: float = 0.08
@export var mark_size: float = 0.14
@export var mark_depth: float = 0.04
@export var muzzle_capacity: int = 5
@export var impact_capacity: int = 40
@export var mark_capacity: int = 80

const TEXTURE_SIDE: int = 64
const RAW_TEXTURE_BYTES: int = TEXTURE_SIDE * TEXTURE_SIDE * 4 * 2
const PACKED_BYTES_PER_SLOT: int = 64
const PACKED_FIXED_BYTES: int = 256
const KIND_SPAN: int = 256


func is_valid() -> bool:
	return muzzle_ticks > 0 and muzzle_ticks <= 180 and impact_ticks > 0 \
			and impact_ticks <= 180 and mark_ticks > 0 and mark_ticks <= 180 \
			and is_finite(muzzle_size) and muzzle_size > 0.0 and muzzle_size <= 1.0 \
			and is_finite(impact_size) and impact_size > 0.0 and impact_size <= 1.0 \
			and is_finite(mark_size) and mark_size > 0.0 and mark_size <= 1.0 \
			and is_finite(mark_depth) and mark_depth > 0.0 and mark_depth <= 0.1 \
			and muzzle_capacity > 0 and muzzle_capacity < KIND_SPAN \
			and impact_capacity > 0 and impact_capacity < KIND_SPAN \
			and mark_capacity > 0 and mark_capacity < KIND_SPAN


static func validate_room(data: ShotVisualData, weapons: Array[WeaponData],
		burst: int, stride: int, producers: int, node_cap: int,
		packed_cap: int, texture_cap: int) -> bool:
	if data == null or not data.is_valid() or weapons.size() != 1 or producers != 1 \
			or burst != 4 or stride <= 0 or stride > 8 or node_cap <= 0:
		return false
	var weapon: WeaponData = weapons[0]
	if weapon == null or not weapon.is_valid() or weapon.pellet_count > stride \
			or weapon.cooldown_ticks < 15:
		return false
	return data.validate_limits(burst, stride, weapon.cooldown_ticks, node_cap, packed_cap, texture_cap)


func validate_limits(burst: int, stride: int, cooldown: int, node_cap: int,
		packed_cap: int, texture_cap: int) -> bool:
	if not is_valid() or burst != 4 or stride <= 0 or stride > 8 or cooldown < 15 \
			or cooldown > StatBlock.VALUE_MAX:
		return false
	var period: int = cooldown * 2
	var muzzle_required: int = burst + (muzzle_ticks + period - 1) / period
	var impact_required: int = stride * (burst + (impact_ticks + period - 1) / period)
	var mark_required: int = stride * (burst + (mark_ticks + period - 1) / period)
	var nodes: int = muzzle_capacity + impact_capacity + mark_capacity
	return muzzle_capacity >= muzzle_required and impact_capacity >= impact_required \
			and mark_capacity >= mark_required and nodes <= node_cap \
			and PACKED_FIXED_BYTES + nodes * PACKED_BYTES_PER_SLOT <= packed_cap \
			and RAW_TEXTURE_BYTES <= texture_cap
