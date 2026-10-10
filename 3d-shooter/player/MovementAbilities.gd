class_name MovementAbilities
extends RefCounted
## Логический контракт способностей движения (рывок, двойной прыжок, скольжение,
## бег по стенам, крюк, тройной прыжок): выдача, кулдауны и плата энергией.
## Физика движения — в FPS-контроллере (M1): он спрашивает try_activate() и сам
## двигает тело. Одно хранилище на все сущности (DOD), SoA по (слот × Kind).
##
## try_activate() вызывается из физического тика контроллера ради отзывчивости:
## буфер до логического тика добавил бы до 33 мс задержки рывка. Поэтому ENERGY
## меняется вне логического тика и не входит в детерминированный контур; само
## решение зависит только от логического времени (now_tick из GameLoop) и статов.
##
## Энергия — общий пул StatBlock.ENERGY (один заряд = 1000), восстанавливается
## regen_energy() раз в логический тик до MAX_ENERGY. Скорость регенерации —
## параметр конструктора (отдельного стата пока нет, см. docs/notes/follow-ups.md).
##
## Сущность — handle StatBlock (int64), слот = handle % INDEX_SPAN; слот помнит
## полный handle владельца. try_activate, revoke и clear_entity по устаревшему
## handle отказывают; способности устаревшей сущности, которую не сняли
## clear_entity, снимаются при grant() сущности более нового поколения в том же
## слоте. grant() по handle более старого поколения, чем у владельца слота,
## отказывает и не трогает живую сущность (отложенный эффект убитой цели).
## Повторный grant() обновляет параметры, но не сбрасывает кулдаун.
## Сущности хотя бы с одной способностью лежат в плотном массиве для
## regen_energy(); grant/revoke/clear_entity поддерживают его swap-remove.
## После конструктора аллокаций нет.

const KIND_COUNT: int = MovementAbilityData.KIND_COUNT
const INVALID_HANDLE: int = HandlePool.INVALID_HANDLE
const FLAG_GROUND: int = 1
const FLAG_AIR: int = 2

var _host_capacity: int = 0
var _regen_per_tick: int = 0
var _slot_host: PackedInt64Array = PackedInt64Array()
var _grant_count: PackedInt32Array = PackedInt32Array()
var _active_pos: PackedInt32Array = PackedInt32Array()  # позиция слота в _active или -1
var _active: PackedInt64Array = PackedInt64Array()  # handle сущностей со способностями
var _active_count: int = 0

var _granted: PackedByteArray = PackedByteArray()  # слот × Kind
var _cost: PackedInt32Array = PackedInt32Array()
var _cooldown: PackedInt32Array = PackedInt32Array()
var _flags: PackedInt32Array = PackedInt32Array()
var _ready_tick: PackedInt64Array = PackedInt64Array()


func _init(host_capacity: int = StatBlock.DEFAULT_CAPACITY, regen_per_tick: int = 0) -> void:
	assert(host_capacity > 0 and host_capacity <= HandlePool.MAX_CAPACITY, "MovementAbilities: недопустимая ёмкость")
	_host_capacity = clampi(host_capacity, 1, HandlePool.MAX_CAPACITY)
	_regen_per_tick = maxi(regen_per_tick, 0)
	_slot_host.resize(_host_capacity)
	_slot_host.fill(INVALID_HANDLE)
	_grant_count.resize(_host_capacity)
	_active_pos.resize(_host_capacity)
	_active_pos.fill(-1)
	_active.resize(_host_capacity)
	var n: int = _host_capacity * KIND_COUNT
	_granted.resize(n)
	_cost.resize(n)
	_cooldown.resize(n)
	_flags.resize(n)
	_ready_tick.resize(n)


func active_count() -> int:
	return _active_count


## Выдаёт способность (или обновляет параметры уже выданной, не трогая кулдаун).
## false, если сущность или вид вне диапазона либо handle устарел относительно
## владельца слота.
func grant(entity: int, kind: MovementAbilityData.Kind, energy_cost: int, cooldown_ticks: int,
		usable_on_ground: bool, usable_in_air: bool) -> bool:
	var slot: int = _slot_of(entity)
	if slot < 0 or kind < 0 or kind >= KIND_COUNT:
		return false
	var owner: int = _slot_host[slot]
	if owner != entity:
		if owner != INVALID_HANDLE:
			# Слот занят: очистка только ради более нового поколения.
			if entity / HandlePool.INDEX_SPAN < owner / HandlePool.INDEX_SPAN:
				return false
			_clear_slot(slot)
		_slot_host[slot] = entity
	var cell: int = slot * KIND_COUNT + kind
	if _granted[cell] == 0:
		_granted[cell] = 1
		_ready_tick[cell] = 0
		_grant_count[slot] += 1
		if _grant_count[slot] == 1:
			_activate(slot, entity)
	_cost[cell] = maxi(energy_cost, 0)
	_cooldown[cell] = maxi(cooldown_ticks, 0)
	_flags[cell] = (FLAG_GROUND if usable_on_ground else 0) | (FLAG_AIR if usable_in_air else 0)
	return true


## Отзывает способность. false для устаревшей сущности или невыданной способности.
func revoke(entity: int, kind: MovementAbilityData.Kind) -> bool:
	var slot: int = _owned_slot(entity)
	if slot < 0 or kind < 0 or kind >= KIND_COUNT:
		return false
	var cell: int = slot * KIND_COUNT + kind
	if _granted[cell] == 0:
		return false
	_granted[cell] = 0
	_grant_count[slot] -= 1
	if _grant_count[slot] == 0:
		_deactivate(slot)
	return true


## Снимает все способности сущности (смерть, деспавн). Возвращает их число.
func clear_entity(entity: int) -> int:
	var slot: int = _owned_slot(entity)
	if slot < 0:
		return 0
	return _clear_slot(slot)


func is_granted(entity: int, kind: MovementAbilityData.Kind) -> bool:
	var slot: int = _owned_slot(entity)
	if slot < 0 or kind < 0 or kind >= KIND_COUNT:
		return false
	return _granted[slot * KIND_COUNT + kind] == 1


## Логический тик, с которого способность снова доступна; -1 для невыданной.
func ready_tick(entity: int, kind: MovementAbilityData.Kind) -> int:
	if not is_granted(entity, kind):
		return -1
	return _ready_tick[_owned_slot(entity) * KIND_COUNT + kind]


## Пытается применить способность в логический тик now_tick. При успехе списывает
## энергию из stats и запускает кулдаун. false — способность не выдана, на
## кулдауне, недоступна в текущем положении (in_air) или не хватает энергии.
func try_activate(entity: int, kind: MovementAbilityData.Kind, now_tick: int, in_air: bool,
		stats: StatBlock) -> bool:
	var slot: int = _owned_slot(entity)
	if slot < 0 or kind < 0 or kind >= KIND_COUNT:
		return false
	var cell: int = slot * KIND_COUNT + kind
	if _granted[cell] == 0 or now_tick < _ready_tick[cell]:
		return false
	if (_flags[cell] & (FLAG_AIR if in_air else FLAG_GROUND)) == 0:
		return false
	var cost: int = _cost[cell]
	if not stats.is_valid(entity) or stats.get_stat(entity, StatBlock.Stat.ENERGY) < cost:
		return false
	if cost > 0:
		stats.add_stat_clamped(entity, StatBlock.Stat.ENERGY, -cost, 0,
				stats.get_stat(entity, StatBlock.Stat.MAX_ENERGY))
	_ready_tick[cell] = now_tick + _cooldown[cell]
	return true


## Восстанавливает энергию всем сущностям со способностями. Раз в логический тик.
func regen_energy(stats: StatBlock) -> void:
	if _regen_per_tick == 0:
		return
	for i: int in _active_count:
		var entity: int = _active[i]
		if stats.is_valid(entity):
			stats.add_stat_clamped(entity, StatBlock.Stat.ENERGY, _regen_per_tick, 0,
					stats.get_stat(entity, StatBlock.Stat.MAX_ENERGY))


func _slot_of(entity: int) -> int:
	if entity < 0:
		return -1
	var slot: int = entity % HandlePool.INDEX_SPAN
	return slot if slot < _host_capacity else -1


func _owned_slot(entity: int) -> int:
	var slot: int = _slot_of(entity)
	if slot < 0 or _slot_host[slot] != entity:
		return -1
	return slot


func _clear_slot(slot: int) -> int:
	var removed: int = 0
	for kind: int in KIND_COUNT:
		var cell: int = slot * KIND_COUNT + kind
		if _granted[cell] == 1:
			_granted[cell] = 0
			removed += 1
	_grant_count[slot] = 0
	_deactivate(slot)
	_slot_host[slot] = INVALID_HANDLE
	return removed


func _activate(slot: int, entity: int) -> void:
	_active[_active_count] = entity
	_active_pos[slot] = _active_count
	_active_count += 1


# swap-remove из плотного массива активных сущностей.
func _deactivate(slot: int) -> void:
	var pos: int = _active_pos[slot]
	if pos < 0:
		return
	_active_count -= 1
	var last: int = _active[_active_count]
	_active[pos] = last
	_active_pos[last % HandlePool.INDEX_SPAN] = pos
	_active_pos[slot] = -1
