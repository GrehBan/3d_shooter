class_name StatBlock
extends RefCounted
## Плотное SoA-хранилище статов сущностей (игрок, враги, ломаемое окружение).
##
## Значения — int ×1000 в одном PackedInt32Array, разложенном по статам:
## _data[stat * capacity + index]. Каждый стат лежит непрерывно, что удобно для
## пакетной обработки. Лимит Int32: 2 147 483 ед. ×1000, то есть ~2.1 млн HP.
## Статусы — 64-битная маска на сущность (битовая упаковка для M2).
##
## Handle сущности = generation · HANDLE_INDEX_SPAN + index. Поколение растёт при
## каждом release(), поэтому handle умершей сущности, чей индекс уже выдан новой,
## отвергается при любом обращении: урон по устаревшему id не попадёт в чужую цель.
##
## Ёмкость фиксируется в конструкторе. allocate()/release() и все аксессоры
## не выделяют память; при исчерпании ёмкости allocate() возвращает INVALID_HANDLE.

enum Stat { HP, MAX_HP, SHIELD, MAX_SHIELD, ARMOR, ENERGY, MAX_ENERGY }

const STAT_COUNT: int = 7
const INVALID_HANDLE: int = -1
const HANDLE_INDEX_SPAN: int = 1 << 16
const MAX_CAPACITY: int = HANDLE_INDEX_SPAN
const DEFAULT_CAPACITY: int = 256
const VALUE_MIN: int = -2_147_483_648  # пределы хранения стата (Int32)
const VALUE_MAX: int = 2_147_483_647

var _capacity: int = 0
var _data: PackedInt32Array = PackedInt32Array()
var _status: PackedInt64Array = PackedInt64Array()
var _generation: PackedInt32Array = PackedInt32Array()
var _alive: PackedByteArray = PackedByteArray()
var _free: PackedInt32Array = PackedInt32Array()  # стек свободных индексов
var _free_count: int = 0
var _alive_count: int = 0


func _init(capacity: int = DEFAULT_CAPACITY) -> void:
	assert(capacity > 0 and capacity <= MAX_CAPACITY, "StatBlock: недопустимая ёмкость")
	_capacity = clampi(capacity, 1, MAX_CAPACITY)
	_data.resize(_capacity * STAT_COUNT)
	_status.resize(_capacity)
	_generation.resize(_capacity)
	_alive.resize(_capacity)
	_free.resize(_capacity)
	_reset_free_list()


func capacity() -> int:
	return _capacity


func alive_count() -> int:
	return _alive_count


## Выдаёт новую сущность с нулевыми статами. INVALID_HANDLE, если ёмкость исчерпана.
func allocate() -> int:
	if _free_count == 0:
		push_error("StatBlock: ёмкость %d исчерпана" % _capacity)
		return INVALID_HANDLE
	_free_count -= 1
	var index: int = _free[_free_count]
	for stat: int in STAT_COUNT:
		_data[stat * _capacity + index] = 0
	_status[index] = 0
	_alive[index] = 1
	_alive_count += 1
	return _generation[index] * HANDLE_INDEX_SPAN + index


## Освобождает сущность. Устаревший или чужой handle — false без побочных эффектов.
func release(handle: int) -> bool:
	var index: int = index_of(handle)
	if index < 0:
		return false
	_alive[index] = 0
	_generation[index] += 1
	_free[_free_count] = index
	_free_count += 1
	_alive_count -= 1
	return true


func is_valid(handle: int) -> bool:
	return index_of(handle) >= 0


## Индекс в плотных массивах или -1 для недействительного handle.
func index_of(handle: int) -> int:
	if handle < 0:
		return -1
	var index: int = handle % HANDLE_INDEX_SPAN
	if index >= _capacity or _alive[index] == 0:
		return -1
	if handle / HANDLE_INDEX_SPAN != _generation[index]:
		return -1
	return index


## Значение стата ×1000; 0 для недействительного handle.
func get_stat(handle: int, stat: Stat) -> int:
	var index: int = index_of(handle)
	if index < 0:
		return 0
	return _data[stat * _capacity + index]


## Записывает стат ×1000. false для недействительного handle.
func set_stat(handle: int, stat: Stat, value: int) -> bool:
	assert(value >= VALUE_MIN and value <= VALUE_MAX, "StatBlock.set_stat: значение вне Int32")
	var index: int = index_of(handle)
	if index < 0:
		return false
	_data[stat * _capacity + index] = value
	return true


## Прибавляет delta к стату и ограничивает результат [min_value, max_value].
## Возвращает новое значение; 0 для недействительного handle.
func add_stat_clamped(handle: int, stat: Stat, delta: int, min_value: int, max_value: int) -> int:
	assert(min_value >= VALUE_MIN and max_value <= VALUE_MAX, "StatBlock.add_stat_clamped: границы вне Int32")
	var index: int = index_of(handle)
	if index < 0:
		return 0
	var offset: int = stat * _capacity + index
	var value: int = clampi(_data[offset] + delta, min_value, max_value)
	_data[offset] = value
	return value


func get_status(handle: int) -> int:
	var index: int = index_of(handle)
	if index < 0:
		return 0
	return _status[index]


func set_status(handle: int, mask: int) -> bool:
	var index: int = index_of(handle)
	if index < 0:
		return false
	_status[index] = mask
	return true


## Снимок для SaveSystem (Zero-Trust State). Аллоцирует: только при сохранении.
func get_state() -> Dictionary:
	return {
		"capacity": _capacity,
		"data": _data.duplicate(),
		"status": _status.duplicate(),
		"generation": _generation.duplicate(),
		"alive": _alive.duplicate(),
		"free": _free.duplicate(),
		"free_count": _free_count,
		"alive_count": _alive_count,
	}


## Восстановление из get_state(). false, если снимок не подходит по ёмкости или формату.
func set_state(state: Dictionary) -> bool:
	if int(state.get("capacity", -1)) != _capacity:
		push_error("StatBlock.set_state: ёмкость снимка не совпадает")
		return false
	var data: PackedInt32Array = state.get("data", PackedInt32Array())
	var status: PackedInt64Array = state.get("status", PackedInt64Array())
	var generation: PackedInt32Array = state.get("generation", PackedInt32Array())
	var alive: PackedByteArray = state.get("alive", PackedByteArray())
	var free: PackedInt32Array = state.get("free", PackedInt32Array())
	var free_count: int = int(state.get("free_count", -1))
	var alive_count: int = int(state.get("alive_count", -1))
	if data.size() != _capacity * STAT_COUNT or status.size() != _capacity \
			or generation.size() != _capacity or alive.size() != _capacity \
			or free.size() != _capacity or free_count < 0 or free_count > _capacity \
			or alive_count != _capacity - free_count:
		push_error("StatBlock.set_state: повреждённый снимок")
		return false
	_data = data.duplicate()
	_status = status.duplicate()
	_generation = generation.duplicate()
	_alive = alive.duplicate()
	_free = free.duplicate()
	_free_count = free_count
	_alive_count = alive_count
	return true


func _reset_free_list() -> void:
	# Стек заполняется так, чтобы первым выдавался индекс 0: порядок выдачи детерминирован.
	for i: int in _capacity:
		_free[i] = _capacity - 1 - i
	_free_count = _capacity
	_alive_count = 0
