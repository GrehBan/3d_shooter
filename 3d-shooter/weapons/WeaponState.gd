class_name WeaponState
extends RefCounted
## Per-weapon mutable input/cooldown; identities are allocated by shared ShotBatch.

var source: int = StatBlock.INVALID_HANDLE
var ready_tick: int = 0
var accepted_shots: int = 0
var _pellets: int = 0
var _damage: int = 0
var _cooldown: int = 0
var _held: bool = false
var _pending: bool = false


func configure(data: WeaponData, entity: int) -> bool:
	if data == null or not data.is_valid() or entity < 0:
		return false
	_pellets = data.pellet_count
	_damage = data.damage_raw
	_cooldown = data.cooldown_ticks
	source = entity
	ready_tick = 0
	accepted_shots = 0
	clear_input()
	return true


func set_pressed(pressed: bool) -> void:
	if pressed and not _held:
		_pending = true
	_held = pressed


func request_shot(batch: ShotBatch, stats: StatBlock, tick: int) -> int:
	var requested: bool = _pending
	_pending = false
	if not requested or tick < ready_tick or tick < 0 or not stats.is_valid(source) \
			or stats.get_stat(source, StatBlock.Stat.HP) <= 0:
		return ShotBatch.INVALID
	if tick > ShotBatch.INT_MAX - _cooldown:
		return batch.reject_configuration()
	var ticket: int = batch.reserve(source, _pellets, _damage)
	if ticket == ShotBatch.INVALID:
		return ticket
	ready_tick = tick + _cooldown
	accepted_shots += 1
	return ticket


func reset_clock(old_tick: int) -> void:
	ready_tick = maxi(ready_tick - maxi(old_tick, 0), 0)
	_pending = false
	accepted_shots = 0


func discard_press() -> void:
	_pending = false


## Resume hardware latch without fabricating an edge from a held button.
func reconcile_held(pressed: bool) -> void:
	_held = pressed
	_pending = false


func clear_input() -> void:
	_held = false
	_pending = false
