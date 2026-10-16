class_name DamageApply
extends RefCounted
## Integer damage policy: shield first, then armor, HP clamp. No triggers or shield regen.

const ARMOR_SCALE: int = 100_000
const MAX_DAMAGE: int = 0x7FFFFFFFFFFFFFFF


## Returns HP damage actually applied; rejects stale handles without any writes.
static func apply(stats: StatBlock, entity: int, raw_damage: int) -> int:
	return apply_with_armor(stats, entity, raw_damage, stats.get_stat(entity, StatBlock.Stat.ARMOR))


## Same policy with the effective armor supplied by the caller (corrosion lowers it);
## the base ARMOR stat is never written. Armor is clamped to 0..ARMOR_SCALE.
static func apply_with_armor(stats: StatBlock, entity: int, raw_damage: int, armor: int) -> int:
	if not stats.is_valid(entity) or raw_damage <= 0:
		return 0
	var damage: int = mini(raw_damage, MAX_DAMAGE)
	var shield: int = maxi(stats.get_stat(entity, StatBlock.Stat.SHIELD), 0)
	var absorbed: int = mini(shield, damage)
	stats.set_stat(entity, StatBlock.Stat.SHIELD, shield - absorbed)
	var remaining: int = damage - absorbed
	var retained: int = ARMOR_SCALE - clampi(armor, 0, ARMOR_SCALE)
	# quotient/remainder gives the exact floor without overflowing int64.
	var hp_damage: int = (remaining / ARMOR_SCALE) * retained \
			+ (remaining % ARMOR_SCALE) * retained / ARMOR_SCALE
	var hp: int = maxi(stats.get_stat(entity, StatBlock.Stat.HP), 0)
	var applied: int = mini(hp, hp_damage)
	stats.set_stat(entity, StatBlock.Stat.HP, hp - applied)
	return applied
