class_name MovementAbilityData
extends Resource
## Данные способности движения (контент .tres через Registry). Только данные:
## в бою MovementAbilities получает параметры явно через grant(), этот ресурс
## в горячем пути не читается. Физика рывка, прыжка и скольжения — в FPS-контроллере (M1).

enum Kind { DASH, DOUBLE_JUMP, SLIDE, WALL_RUN, GRAPPLE, TRIPLE_JUMP }

const KIND_COUNT: int = 6  # = Kind.size(), проверяется тестом

@export var kind: Kind = Kind.DASH
## Стоимость в энергии ×1000 (один заряд = 1000).
@export var energy_cost: int = 1000
## Минимальный интервал между применениями, в логических тиках (30 Гц).
@export var cooldown_ticks: int = 0
@export var usable_on_ground: bool = true
@export var usable_in_air: bool = true
