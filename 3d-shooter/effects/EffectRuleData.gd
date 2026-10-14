class_name EffectRuleData
extends Resource
## Cold immutable input to the restricted M2.2 counter runner.

enum Condition { ALWAYS, MIN_VALUE }
enum Action { INCREMENT_COUNTER }

@export var condition: Condition = Condition.ALWAYS
@export var minimum_value: int = 0
@export var action: Action = Action.INCREMENT_COUNTER
@export var counter_increment: int = 1
@export var cooldown_ticks: int = 0


func is_valid() -> bool:
	return condition >= Condition.ALWAYS and condition <= Condition.MIN_VALUE \
			and minimum_value >= 0 and action == Action.INCREMENT_COUNTER \
			and counter_increment > 0 and cooldown_ticks >= 0
