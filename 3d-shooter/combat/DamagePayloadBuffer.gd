class_name DamagePayloadBuffer
extends RefCounted
## Кольцевой буфер записей урона (DamagePayload) фиксированной ёмкости.
## Структура SoA: каждое поле в своём плотном массиве, слот — индекс.
##
## Очередь FIFO: push() добавляет в хвост, front_slot()/pop_front() читают с головы.
## Слот действителен, пока запись не снята pop_front() или clear().
##
## Переполнение детерминированно: push() возвращает INVALID_SLOT, запись
## отбрасывается, dropped_count() растёт. Ошибка в лог не пишется, чтобы шторм
## эффектов не спамил; счётчик проверяет бенчмарк regress.gd (в норме 0).
## Ни один метод не выделяет память после конструктора.

const INVALID_SLOT: int = -1
const DEFAULT_CAPACITY: int = 1024

var _capacity: int = 0
var _head: int = 0
var _count: int = 0
var _dropped: int = 0

var _source: PackedInt64Array = PackedInt64Array()
var _target: PackedInt64Array = PackedInt64Array()
var _attack_context: PackedInt64Array = PackedInt64Array()
var _amount: PackedInt64Array = PackedInt64Array()
var _tags: PackedInt64Array = PackedInt64Array()
var _element: PackedInt32Array = PackedInt32Array()
var _flags: PackedInt32Array = PackedInt32Array()
var _phase: PackedInt32Array = PackedInt32Array()


func _init(capacity: int = DEFAULT_CAPACITY) -> void:
	assert(capacity > 0, "DamagePayloadBuffer: недопустимая ёмкость")
	_capacity = maxi(capacity, 1)
	_source.resize(_capacity)
	_target.resize(_capacity)
	_attack_context.resize(_capacity)
	_amount.resize(_capacity)
	_tags.resize(_capacity)
	_element.resize(_capacity)
	_flags.resize(_capacity)
	_phase.resize(_capacity)


func capacity() -> int:
	return _capacity


func count() -> int:
	return _count


func is_empty() -> bool:
	return _count == 0


## Сколько записей отброшено из-за переполнения с последнего reset_dropped_count().
func dropped_count() -> int:
	return _dropped


func reset_dropped_count() -> void:
	_dropped = 0


## Добавляет запись в фазе BASE. Возвращает слот или INVALID_SLOT при переполнении.
func push(source: int, target: int, amount: int, element: DamagePayload.Element,
		tags: int, flags: int, attack_context: int) -> int:
	if _count == _capacity:
		_dropped += 1
		return INVALID_SLOT
	var slot: int = (_head + _count) % _capacity
	_count += 1
	_source[slot] = source
	_target[slot] = target
	_amount[slot] = amount
	_element[slot] = element
	_tags[slot] = tags
	_flags[slot] = flags
	_attack_context[slot] = attack_context
	_phase[slot] = DamagePayload.Phase.BASE
	return slot


## Слот головы очереди или INVALID_SLOT, если буфер пуст.
func front_slot() -> int:
	return INVALID_SLOT if _count == 0 else _head


## Слот i-й записи от головы (0 ≤ i < count()) для пакетного обхода без снятия.
func slot_at(i: int) -> int:
	if i < 0 or i >= _count:
		return INVALID_SLOT
	return (_head + i) % _capacity


## Снимает запись с головы. false, если буфер пуст.
func pop_front() -> bool:
	if _count == 0:
		return false
	_head = (_head + 1) % _capacity
	_count -= 1
	return true


func clear() -> void:
	_head = 0
	_count = 0


func get_source(slot: int) -> int:
	return _source[slot]


func get_target(slot: int) -> int:
	return _target[slot]


func get_attack_context(slot: int) -> int:
	return _attack_context[slot]


func get_amount(slot: int) -> int:
	return _amount[slot]


func set_amount(slot: int, amount: int) -> void:
	_amount[slot] = amount


func get_element(slot: int) -> DamagePayload.Element:
	return _element[slot] as DamagePayload.Element


func set_element(slot: int, element: DamagePayload.Element) -> void:
	_element[slot] = element


func get_tags(slot: int) -> int:
	return _tags[slot]


func get_flags(slot: int) -> int:
	return _flags[slot]


func set_flags(slot: int, flags: int) -> void:
	_flags[slot] = flags


func get_phase(slot: int) -> DamagePayload.Phase:
	return _phase[slot] as DamagePayload.Phase


func set_phase(slot: int, phase: DamagePayload.Phase) -> void:
	_phase[slot] = phase
