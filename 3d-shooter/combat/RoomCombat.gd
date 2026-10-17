class_name RoomCombat
extends RefCounted
## Owner of the room's combat stores. Created cold when the room loads; every runtime
## of the room (mobility, effects, weapons, resolver) receives references to these stores.
## Room reset clears room state (statuses) but keeps entities and stats: entity lifecycle
## is separate (contracts §6, §7).

const READ_ONLY_ERROR: String = "RoomCombat: config is read-only"

## The room's validated RoomConfig. Read-only: every read returns a fresh copy, so neither
## assignment nor field writes reach the room. Cold path only (load, tests, reports).
var config: RoomConfig:
	get:
		return null if _config == null else _config.duplicate() as RoomConfig
	set(_value):
		push_error(READ_ONLY_ERROR)
## The single StatBlock of the room. Never reassign it: runtimes hold this exact reference.
var stats: StatBlock
## The single status authority of the room, built on `stats`.
var statuses: StatusRuntime
## The room's reactions, built on `stats` and `statuses`.
var reactions: ReactionRuntime
var _config: RoomConfig


## An invalid config is a configuration error: push_error names the first bad field and
## the room stays uninitialized. null means the default RoomConfig.
func _init(room_config: RoomConfig = null) -> void:
	var source: RoomConfig = room_config if room_config != null else RoomConfig.new()
	var error: String = source.validation_error()
	if not error.is_empty():
		push_error(error)
		return
	_config = source.duplicate() as RoomConfig
	stats = StatBlock.new(_config.host_capacity)
	statuses = StatusRuntime.new(stats)
	reactions = ReactionRuntime.new(stats, statuses)


func is_initialized() -> bool:
	return stats != null and statuses.is_initialized() and reactions.is_initialized()


## Quiescent room reset of room-owned state (statuses, reaction metrics); StatBlock and
## registrations survive. false, with the busy store's own diagnostic and nothing reset,
## while a status step, contact, pulse or reaction is in progress.
func reset_room() -> bool:
	if not is_initialized():
		return false
	if not reactions.can_reset_room():
		return reactions.reset_room()
	return statuses.reset_room() and reactions.reset_room()
