class_name ReactionRules
extends Resource
## Approved M2.3 reaction preset (GDD §5). Only this preset is supported; balance changes
## need a new approved contract. Percentages are ×1000 of the direct contact's raw damage.

@export var radius_mm: int = 3000
@export var arc_targets: int = 2
@export var conducting_targets: int = 4
@export var explosion_targets: int = 4
@export var electric_percent: int = 500
@export var explosion_percent: int = 750


func is_valid() -> bool:
	return radius_mm == 3000 and arc_targets == 2 and conducting_targets == 4 \
			and explosion_targets == 4 and electric_percent == 500 and explosion_percent == 750


## True if some reaction this element can trigger hits other targets around the primary,
## so the physics adapter must gather area candidates for its pellets.
func needs_candidates(element: DamagePayload.Element) -> bool:
	match element:
		DamagePayload.Element.ELECTRIC:
			return arc_targets > 0 or conducting_targets > 0
		DamagePayload.Element.FIRE:
			return explosion_targets > 0
	return false


## Largest number of secondary targets one reaction may hit.
func max_targets() -> int:
	return maxi(arc_targets, maxi(conducting_targets, explosion_targets))
