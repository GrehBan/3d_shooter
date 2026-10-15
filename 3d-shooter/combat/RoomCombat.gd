class_name RoomCombat
extends RefCounted
## Owner of the room's combat stores. Created cold when the room loads; every runtime
## of the room (mobility, effects, weapons, resolver) receives references to these stores.
## Room clock reset keeps entities and stats: entity lifecycle is separate (contracts §6, §7).

const CONFIGURATION_ERROR: String = "RoomCombat: host capacity must be within 1..StatBlock.MAX_CAPACITY"

## The single StatBlock of the room. Never reassign it: runtimes hold this exact reference.
var stats: StatBlock


func _init(host_capacity: int = StatBlock.DEFAULT_CAPACITY) -> void:
	if host_capacity <= 0 or host_capacity > StatBlock.MAX_CAPACITY:
		push_error(CONFIGURATION_ERROR)
		return
	stats = StatBlock.new(host_capacity)


func is_initialized() -> bool:
	return stats != null
