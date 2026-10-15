class_name DamagePipeline
extends RefCounted
## Phase boundary for one payload at the FIFO front. The caller owns FIFO removal and the
## attack lifecycle. Without a StatusRuntime only physical payloads are accepted (M2.1);
## with one, direct contacts carry elements and statuses (M2.3, contracts §2).

const INVALID_RESULT: int = -1
const INVALID_PAYLOAD_ERROR: String = "DamagePipeline: unsupported or malformed payload"
const DOT_FLAGS: int = DamagePayload.Flag.DOT | DamagePayload.Flag.SECONDARY

var configuration_errors: int = 0
var _stats: StatBlock
var _statuses: StatusRuntime
var _compatible: bool = false
var _error_reported: bool = false


## statuses, when given, must be built on the same StatBlock; otherwise every call refuses.
func _init(stats: StatBlock, statuses: StatusRuntime = null) -> void:
	_stats = stats
	_statuses = statuses
	_compatible = stats != null and (statuses == null or statuses.uses_stats(stats))
	if not _compatible:
		_reject()


## Resolves only the front BASE direct contact; rejection preserves payload and stats.
## credit/epoch/sequence/trace are opaque provenance copied into a burn this contact starts.
func resolve_front(payloads: DamagePayloadBuffer, credit: int = 0, epoch: int = 0,
		sequence: int = 0, trace: int = 0) -> int:
	if not _compatible:
		return _reject()
	var slot: int = payloads.front_slot()
	if slot == DamagePayloadBuffer.INVALID_SLOT:
		return INVALID_RESULT
	var element: DamagePayload.Element = payloads.get_element(slot)
	var raw: int = payloads.get_amount(slot)
	if payloads.get_phase(slot) != DamagePayload.Phase.BASE or payloads.get_flags(slot) != 0 or raw < 0 \
			or element < DamagePayload.Element.NONE or element > DamagePayload.Element.ACID \
			or (_statuses == null and element != DamagePayload.Element.NONE):
		return _reject()
	var target: int = payloads.get_target(slot)
	if not _stats.is_valid(target) or _stats.get_stat(target, StatBlock.Stat.HP) <= 0:
		payloads.set_phase(slot, DamagePayload.Phase.POST_HIT)
		return 0
	if _statuses == null:
		# BASE through CRIT are identity: amount is already the physical raw damage.
		# Mitigation stays inside DamageApply so shield/armor are committed once at APPLY.
		payloads.set_phase(slot, DamagePayload.Phase.MITIGATION)
		payloads.set_phase(slot, DamagePayload.Phase.APPLY)
		var physical: int = DamageApply.apply(_stats, target, raw)
		payloads.set_phase(slot, DamagePayload.Phase.POST_HIT)
		return physical
	# A refused contact (status store busy) writes nothing; the store counts the error.
	if not _statuses.begin_contact():
		return INVALID_RESULT
	# ELEMENT: a target frozen at contact start takes x2 raw (shatter), saturating at int64.
	var frozen: bool = _statuses.is_frozen(target)
	var amount: int = raw
	if frozen:
		amount = DamageApply.MAX_DAMAGE if raw > DamageApply.MAX_DAMAGE / 2 else raw * 2
	payloads.set_phase(slot, DamagePayload.Phase.MITIGATION)
	payloads.set_phase(slot, DamagePayload.Phase.APPLY)
	var applied: int = DamageApply.apply_with_armor(_stats, target, amount, _statuses.effective_armor(target))
	_statuses.end_contact(payloads.get_source(slot), target, raw, element, applied, frozen,
			credit, epoch, sequence, trace, payloads.get_tags(slot))
	payloads.set_phase(slot, DamagePayload.Phase.POST_HIT)
	return applied


## Burn pulse of the given status store: FIRE with exactly DOT|SECONDARY, admitted only
## while that store resolves its own pulse. No statuses, shatter or reactions follow.
func resolve_dot_front(payloads: DamagePayloadBuffer, statuses: StatusRuntime) -> int:
	if not _compatible:
		return _reject()
	var slot: int = payloads.front_slot()
	if slot == DamagePayloadBuffer.INVALID_SLOT:
		return INVALID_RESULT
	if statuses == null or not statuses.uses_stats(_stats) or not statuses.is_resolving_pulse() \
			or payloads.get_phase(slot) != DamagePayload.Phase.BASE \
			or payloads.get_element(slot) != DamagePayload.Element.FIRE \
			or payloads.get_flags(slot) != DOT_FLAGS or payloads.get_amount(slot) < 0:
		return _reject()
	var target: int = payloads.get_target(slot)
	var damage: int = 0
	if _stats.is_valid(target) and _stats.get_stat(target, StatBlock.Stat.HP) > 0:
		payloads.set_phase(slot, DamagePayload.Phase.MITIGATION)
		payloads.set_phase(slot, DamagePayload.Phase.APPLY)
		damage = DamageApply.apply_with_armor(_stats, target, payloads.get_amount(slot),
				statuses.effective_armor(target))
	payloads.set_phase(slot, DamagePayload.Phase.POST_HIT)
	return damage


func reset_counters() -> void:
	configuration_errors = 0
	_error_reported = false


func _reject() -> int:
	configuration_errors += 1
	if not _error_reported:
		_error_reported = true
		push_error(INVALID_PAYLOAD_ERROR)
	return INVALID_RESULT
