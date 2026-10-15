class_name RoomCombat
extends RefCounted
## Owner of the room's combat stores. Created cold when the room loads; every runtime
## of the room (mobility, effects, weapons, resolver) receives references to these stores.
## Room clock reset keeps entities and stats: entity lifecycle is separate (contracts §6, §7).

var stats: StatBlock


func _init(host_capacity: int = StatBlock.DEFAULT_CAPACITY) -> void:
	stats = StatBlock.new(host_capacity)
