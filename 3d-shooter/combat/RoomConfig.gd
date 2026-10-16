class_name RoomConfig
extends Resource
## Capacities and quotas of one room (contracts §2, RoomConfig). Validated once on the cold
## path; RoomCombat keeps its own copy, so a running room never reads this Resource again.
## EffectRunner capacity and quota are derived from these fields, never configured apart.

const ERROR_PREFIX: String = "RoomConfig: invalid "
## Upper bound of the derived EffectRunner work quota (contracts §2, EffectRunner quota).
const MAX_EFFECT_QUOTA: int = 512

## Entity slots: StatBlock, EffectHost hosts and StatusRuntime records.
@export var host_capacity: int = 16
## ShotBatch shots in flight per logic tick.
@export var shot_capacity: int = 4
## Largest pellet count a weapon of this room may have.
@export var trace_cap: int = 8
## Packed-store budget of ShotBatch and the resolver's context pool.
@export var shot_packed_bytes: int = 131_072
@export var context_capacity: int = 128
## Contexts reserved for deferred owners beyond direct pellets.
@export var deferred_reserve: int = 16
@export var landing_capacity: int = LandingEventQueue.DEFAULT_CAPACITY
@export var effect_entries: int = 64
## Effect entries one event may capture (EffectRunner max_subscriptions).
@export var effect_max_subscriptions: int = 8
## Packed budget of EffectHost and EffectRunner together.
@export var effect_packed_bytes: int = 32_768
@export var visual_nodes: int = 128
@export var visual_packed_bytes: int = 16_384
@export var visual_texture_bytes: int = 32_768
## Reaction candidates per trace (K): hitboxes the physics adapter may hand to one reaction.
## More bodies in the area is normal (a crowd): extras are dropped and counted.
@export var reaction_candidates: int = 8


## Empty string if every field is in range, otherwise the error naming the first bad field.
func validation_error() -> String:
	if host_capacity < 1 or host_capacity > StatBlock.MAX_CAPACITY:
		return ERROR_PREFIX + "host_capacity"
	if shot_capacity < 1 or shot_capacity > HandlePool.MAX_CAPACITY:
		return ERROR_PREFIX + "shot_capacity"
	if trace_cap < 1 or trace_cap > AttackContextPool.HITS_PER_CONTEXT:
		return ERROR_PREFIX + "trace_cap"
	if shot_packed_bytes < 1:
		return ERROR_PREFIX + "shot_packed_bytes"
	if context_capacity < 1 or context_capacity > HandlePool.MAX_CAPACITY:
		return ERROR_PREFIX + "context_capacity"
	if deferred_reserve < 0 or deferred_reserve >= context_capacity:
		return ERROR_PREFIX + "deferred_reserve"
	if landing_capacity < 1 or landing_capacity > LandingEventQueue.MAX_CAPACITY:
		return ERROR_PREFIX + "landing_capacity"
	if effect_entries < 1 or effect_entries > HandlePool.MAX_CAPACITY:
		return ERROR_PREFIX + "effect_entries"
	if effect_max_subscriptions < 1 or effect_max_subscriptions > EffectRunner.MAX_SUBSCRIPTIONS:
		return ERROR_PREFIX + "effect_max_subscriptions"
	if effect_packed_bytes < 1:
		return ERROR_PREFIX + "effect_packed_bytes"
	if visual_nodes < 1:
		return ERROR_PREFIX + "visual_nodes"
	if visual_packed_bytes < 1:
		return ERROR_PREFIX + "visual_packed_bytes"
	if visual_texture_bytes < 1:
		return ERROR_PREFIX + "visual_texture_bytes"
	if reaction_candidates < 1 or reaction_candidates > AttackContextPool.HITS_PER_CONTEXT:
		return ERROR_PREFIX + "reaction_candidates"
	if effect_work_quota() > MAX_EFFECT_QUOTA:
		return ERROR_PREFIX + "effect quota: (shot_capacity * trace_cap + host_capacity) * effect_max_subscriptions > 512"
	return ""


## Worst-case EffectRunner events accepted in one logic tick: one OnHit per pellet of every
## shot in flight plus one burn pulse per status record. Secondary reaction hits never reach
## EffectRunner in M2.3b, so they are not counted.
func effect_event_capacity() -> int:
	return shot_capacity * trace_cap + host_capacity


## Candidates of those events: every event may capture effect_max_subscriptions entries. A
## quota this large drains the queue every tick, so work is never deferred.
func effect_work_quota() -> int:
	return effect_event_capacity() * effect_max_subscriptions
