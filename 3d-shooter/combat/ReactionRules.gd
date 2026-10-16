class_name ReactionRules
extends Resource
## Approved M2.3 reaction preset (GDD §5). Only this preset is supported; balance changes
## need a new approved contract. Percentages are ×1000 of the direct contact's raw damage.
## reaction_kind() is the only element -> reaction mapping of the project.

enum Kind { NONE, ARC, CONDUCTING, EXPLOSION }

@export var radius_mm: int = 3000
@export var arc_targets: int = 2
@export var conducting_targets: int = 4
@export var explosion_targets: int = 4
@export var electric_percent: int = 500
@export var explosion_percent: int = 750


func is_valid() -> bool:
	return radius_mm == 3000 and arc_targets == 2 and conducting_targets == 4 \
			and explosion_targets == 4 and electric_percent == 500 and explosion_percent == 750


## The reaction a direct contact of `element` triggers on a primary that was corroded and/or
## WET before the contact.
func reaction_kind(element: DamagePayload.Element, corroded: bool, wet: bool) -> Kind:
	match element:
		DamagePayload.Element.ELECTRIC:
			return Kind.CONDUCTING if corroded or wet else Kind.ARC
		DamagePayload.Element.FIRE:
			return Kind.EXPLOSION if corroded else Kind.NONE
	return Kind.NONE


func targets_for(kind: Kind) -> int:
	match kind:
		Kind.ARC: return arc_targets
		Kind.CONDUCTING: return conducting_targets
		Kind.EXPLOSION: return explosion_targets
	return 0


func percent_for(kind: Kind) -> int:
	match kind:
		Kind.ARC, Kind.CONDUCTING: return electric_percent
		Kind.EXPLOSION: return explosion_percent
	return 0


## True if some reaction of this element hits other targets, so the physics adapter must
## supply area candidates for its pellets. Derived from reaction_kind() only.
func needs_candidates(element: DamagePayload.Element) -> bool:
	for corroded: bool in [false, true]:
		for wet: bool in [false, true]:
			if targets_for(reaction_kind(element, corroded, wet)) > 0:
				return true
	return false


## Largest number of secondary targets one reaction may hit.
func max_targets() -> int:
	return maxi(arc_targets, maxi(conducting_targets, explosion_targets))
