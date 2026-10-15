class_name MobilityRuntime
extends RefCounted
## Pure shared stores. One composition-root subscription drains landings before regen.
## Bind several physical controllers to this same runtime; none subscribes independently.

const ENERGY_REGEN: int = 50  # raw per 30 Hz logic tick, 1500 raw/second
const CONFIGURATION_ERROR: String = "MobilityRuntime: the room StatBlock is required"

var stats: StatBlock
var abilities: MovementAbilities
var landings: LandingEventQueue
var logic_steps: int = 0
var resolved_landings: int = 0
var stale_landings: int = 0
var _last_tick: int = -1


## `room_stats` belongs to the room (`RoomCombat`); this runtime only keeps a reference.
## A null StatBlock is a configuration error: the runtime stays uninitialized and inert.
func _init(room_stats: StatBlock, landing_capacity: int = LandingEventQueue.DEFAULT_CAPACITY) -> void:
	if room_stats == null:
		push_error(CONFIGURATION_ERROR)
		return
	stats = room_stats
	abilities = MovementAbilities.new(room_stats.capacity(), ENERGY_REGEN)
	landings = LandingEventQueue.new(landing_capacity)


func is_initialized() -> bool:
	return stats != null


## Cold initialization only. Validate the complete M1 preset before ANY grant.
## false is a caller configuration error: do not start this room with invalid content.
func grant_content(entity: int, registry: Registry, category: int) -> bool:
	if not is_initialized() or not stats.is_valid(entity) or registry == null or not registry.is_frozen() or registry.count(category) != 3:
		return false
	var seen: int = 0
	for id: int in registry.count(category):
		var data: MovementAbilityData = registry.get_resource(category, id) as MovementAbilityData
		if data == null or data.kind < MovementAbilityData.Kind.DASH or data.kind > MovementAbilityData.Kind.SLIDE:
			return false
		if data.energy_cost < 0 or data.energy_cost > StatBlock.VALUE_MAX \
				or data.cooldown_ticks < 0 or data.cooldown_ticks > StatBlock.VALUE_MAX:
			return false
		var bit: int = 1 << data.kind
		if (seen & bit) != 0:
			return false
		seen |= bit
		if data.usable_on_ground != (data.kind != MovementAbilityData.Kind.DOUBLE_JUMP) \
				or data.usable_in_air != (data.kind != MovementAbilityData.Kind.SLIDE):
			return false
	if seen != 7:
		return false
	for id: int in registry.count(category):
		var data: MovementAbilityData = registry.get_resource(category, id) as MovementAbilityData
		if not abilities.grant(entity, data.kind, data.energy_cost, data.cooldown_ticks,
				data.usable_on_ground, data.usable_in_air):
			return false
	return true


## Monotonic logic tick; duplicate composition-root calls cannot double regenerate.
func logic_step(tick: int) -> void:
	if not is_initialized() or tick <= _last_tick:
		return
	_last_tick = tick
	for i: int in landings.count():
		var entity: int = landings.get_entity(i)
		if not stats.is_valid(entity):
			stale_landings += 1
			continue
		resolved_landings += 1
		if landings.get_cancel_flags(i) == 0:
			DamageApply.apply(stats, entity, fall_damage(landings.get_height_mm(i)))
	landings.clear()
	abilities.regen_energy(stats)
	logic_steps += 1


static func fall_damage(height_mm: int) -> int:
	return mini(maxi(clampi(height_mm, 0, LandingEventQueue.MAX_HEIGHT_MM) - 8000, 0) * 10,
			DamageApply.MAX_DAMAGE)


## Explicit room clock reset: discard pending events and preserve remaining cooldown.
## old_logic_tick MUST come from the caller's GameLoop before its reset, not _last_tick.
func reset_clock(old_logic_tick: int) -> void:
	if not is_initialized():
		return
	abilities.rebase_clock(old_logic_tick)
	_last_tick = -1
	landings.clear()
	landings.reset_dropped_count()
	logic_steps = 0
	resolved_landings = 0
	stale_landings = 0
