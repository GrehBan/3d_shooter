class_name DamagePipeline
extends RefCounted
## Physical phase foundation. The caller owns FIFO removal and attack lifecycle.

const INVALID_RESULT: int = -1
const INVALID_PAYLOAD_ERROR: String = "DamagePipeline: unsupported or malformed payload"

var configuration_errors: int = 0
var _stats: StatBlock
var _error_reported: bool = false


func _init(stats: StatBlock) -> void:
	_stats = stats


## Resolves only the front BASE record; rejection preserves payload and stats.
func resolve_front(payloads: DamagePayloadBuffer) -> int:
	var slot: int = payloads.front_slot()
	if slot == DamagePayloadBuffer.INVALID_SLOT:
		return INVALID_RESULT
	if payloads.get_phase(slot) != DamagePayload.Phase.BASE \
			or payloads.get_element(slot) != DamagePayload.Element.NONE \
			or payloads.get_flags(slot) != 0 or payloads.get_amount(slot) < 0:
		configuration_errors += 1
		if not _error_reported:
			_error_reported = true
			push_error(INVALID_PAYLOAD_ERROR)
		return INVALID_RESULT
	var target: int = payloads.get_target(slot)
	if not _stats.is_valid(target) or _stats.get_stat(target, StatBlock.Stat.HP) <= 0:
		payloads.set_phase(slot, DamagePayload.Phase.POST_HIT)
		return 0
	# BASE through CRIT are identity: amount is already the physical raw damage.
	# Mitigation stays inside DamageApply so shield/armor are committed once at APPLY.
	payloads.set_phase(slot, DamagePayload.Phase.MITIGATION)
	payloads.set_phase(slot, DamagePayload.Phase.APPLY)
	var applied: int = DamageApply.apply(_stats, target, payloads.get_amount(slot))
	payloads.set_phase(slot, DamagePayload.Phase.POST_HIT)
	return applied


func reset_counters() -> void:
	configuration_errors = 0
	_error_reported = false
