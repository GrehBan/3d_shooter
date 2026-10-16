class_name StatusRules
extends Resource
## Only the approved starter preset is supported; arbitrary balance is a later gate.

@export var shock_ticks: int = 3
@export var shock_cooldown_ticks: int = 15
@export var burn_ticks: int = 90
@export var burn_period_ticks: int = 15
@export var burn_percent: int = 200
@export var chill_ticks: int = 60
@export var chill_slow_per_stack: int = 200
@export var freeze_ticks: int = 30
@export var freeze_cooldown_ticks: int = 60
@export var corrosion_ticks: int = 90
@export var corrosion_armor_per_stack: int = 10000
@export var corrosion_max_stacks: int = 3


func is_valid() -> bool:
	return shock_ticks == 3 and shock_cooldown_ticks == 15 and burn_ticks == 90 \
			and burn_period_ticks == 15 and burn_percent == 200 and chill_ticks == 60 \
			and chill_slow_per_stack == 200 and freeze_ticks == 30 and freeze_cooldown_ticks == 60 \
			and corrosion_ticks == 90 and corrosion_armor_per_stack == 10000 and corrosion_max_stacks == 3
