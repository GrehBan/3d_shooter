class_name StatBlock
extends RefCounted
## Плотное SoA-хранилище статов сущностей (игрок, враги, ломаемое окружение).
##
## Значения — int ×1000 в одном PackedInt32Array, разложенном по статам:
## _data[stat * capacity + index]. Каждый стат лежит непрерывно, что удобно для
## пакетной обработки. Лимит Int32: 2 147 483 ед. ×1000, то есть ~2.1 млн HP.
## Статусы — 64-битная маска на сущность (битовая упаковка для M2).
##
## Handle сущности (int64) выдаёт HandlePool: generation · HANDLE_INDEX_SPAN + index.
## Хранить handle только в int64 (PackedInt64Array): после 32768 переиспользований
## одного слота он выходит за пределы Int32. Поколение растёт при каждом
## release(), поэтому handle умершей сущности, чей индекс уже выдан новой,
## отвергается при любом обращении: урон по устаревшему id не попадёт в чужую цель.
##
## Ёмкость фиксируется в конструкторе. allocate()/release() и все аксессоры
## не выделяют память; при исчерпании ёмкости allocate() возвращает INVALID_HANDLE.

enum Stat { HP, MAX_HP, SHIELD, MAX_SHIELD, ARMOR, ENERGY, MAX_ENERGY }

const STAT_COUNT: int = 7
const INVALID_HANDLE: int = HandlePool.INVALID_HANDLE
const HANDLE_INDEX_SPAN: int = HandlePool.INDEX_SPAN
const MAX_CAPACITY: int = HandlePool.MAX_CAPACITY
const DEFAULT_CAPACITY: int = 256
const VALUE_MIN: int = -2_147_483_648  # пределы хранения стата (Int32)
const VALUE_MAX: int = 2_147_483_647

var _capacity: int = 0
var _handles: HandlePool
var _data: PackedInt32Array = PackedInt32Array()
var _status: PackedInt64Array = PackedInt64Array()


func _init(capacity: int = DEFAULT_CAPACITY) -> void:
	assert(capacity > 0 and capacity <= MAX_CAPACITY, "StatBlock: недопустимая ёмкость")
	_capacity = clampi(capacity, 1, MAX_CAPACITY)
	_handles = HandlePool.new(_capacity)
	_data.resize(_capacity * STAT_COUNT)
	_status.resize(_capacity)


func capacity() -> int:
	return _capacity


func alive_count() -> int:
	return _handles.alive_count()


## Выдаёт новую сущность с нулевыми статами. INVALID_HANDLE, если ёмкость исчерпана.
func allocate() -> int:
	var handle: int = _handles.allocate()
	if handle == INVALID_HANDLE:
		push_error("StatBlock: ёмкость %d исчерпана" % _capacity)
		return INVALID_HANDLE
	var index: int = _handles.index_of(handle)
	for stat: int in STAT_COUNT:
		_data[stat * _capacity + index] = 0
	_status[index] = 0
	return handle


## Освобождает сущность. Устаревший или чужой handle — false без побочных эффектов.
func release(handle: int) -> bool:
	return _handles.release(handle)


func is_valid(handle: int) -> bool:
	return _handles.is_valid(handle)


## Индекс в плотных массивах или -1 для недействительного handle.
func index_of(handle: int) -> int:
	return _handles.index_of(handle)


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
	var state: Dictionary = _handles.get_state()
	state["data"] = _data.duplicate()
	state["status"] = _status.duplicate()
	state["alive_count"] = _handles.alive_count()
	return state


## Восстановление из get_state(). false, если снимок не подходит по ёмкости или
## повреждён (проверки согласованности слотов — в HandlePool.set_state()).
func set_state(state: Dictionary) -> bool:
	if int(state.get("capacity", -1)) != _capacity:
		push_error("StatBlock.set_state: ёмкость снимка не совпадает")
		return false
	var data: PackedInt32Array = state.get("data", PackedInt32Array())
	var status: PackedInt64Array = state.get("status", PackedInt64Array())
	var free_count: int = int(state.get("free_count", -1))
	var alive_count: int = int(state.get("alive_count", -1))
	if data.size() != _capacity * STAT_COUNT or status.size() != _capacity \
			or alive_count != _capacity - free_count or not _handles.set_state(state):
		push_error("StatBlock.set_state: повреждённый снимок")
		return false
	_data = data.duplicate()
	_status = status.duplicate()
	return true
