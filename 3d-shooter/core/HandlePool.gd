class_name HandlePool
extends RefCounted
## Выдача слотов фиксированной ёмкости с handle по поколениям (AttackContextPool).
## StatBlock использует тот же формат handle, но проверку держит inline: вызов
## метода HandlePool на каждом обращении к стату дал +5% к логическому тику.
##
## Handle (int64) = generation · INDEX_SPAN + index. Поколение растёт при каждом
## release(), поэтому устаревший handle, чей слот уже выдан снова, отвергается.
## Хранить handle только в int64: после 32768 переиспользований слота он выходит
## за пределы Int32. Слоты выдаются со стека свободных индексов, первым — 0:
## порядок выдачи детерминирован. После конструктора методы не выделяют память,
## кроме get_state()/set_state() (путь сохранения и загрузки). Поколение хранится
## в Int32 и переполнилось бы только через 2^31 освобождений одного слота.

const INVALID_HANDLE: int = -1
const INDEX_SPAN: int = 1 << 16
const MAX_CAPACITY: int = INDEX_SPAN

var _capacity: int = 0
var _generation: PackedInt32Array = PackedInt32Array()
var _alive: PackedByteArray = PackedByteArray()
var _free: PackedInt32Array = PackedInt32Array()  # стек свободных индексов
var _free_count: int = 0


func _init(capacity: int) -> void:
	assert(capacity > 0 and capacity <= MAX_CAPACITY, "HandlePool: недопустимая ёмкость")
	_capacity = clampi(capacity, 1, MAX_CAPACITY)
	_generation.resize(_capacity)
	_alive.resize(_capacity)
	_free.resize(_capacity)
	for i: int in _capacity:
		_free[i] = _capacity - 1 - i
	_free_count = _capacity


func capacity() -> int:
	return _capacity


func alive_count() -> int:
	return _capacity - _free_count


func is_full() -> bool:
	return _free_count == 0


## Выдаёт слот. INVALID_HANDLE, если свободных нет (сообщение — забота владельца).
func allocate() -> int:
	if _free_count == 0:
		return INVALID_HANDLE
	_free_count -= 1
	var index: int = _free[_free_count]
	_alive[index] = 1
	return _generation[index] * INDEX_SPAN + index


## Освобождает слот. Устаревший или чужой handle — false без побочных эффектов.
func release(handle: int) -> bool:
	var index: int = index_of(handle)
	if index < 0:
		return false
	_alive[index] = 0
	_generation[index] += 1
	_free[_free_count] = index
	_free_count += 1
	return true


func is_valid(handle: int) -> bool:
	return index_of(handle) >= 0


## Индекс слота или -1 для недействительного handle.
func index_of(handle: int) -> int:
	if handle < 0:
		return -1
	var index: int = handle % INDEX_SPAN
	if index >= _capacity or _alive[index] == 0:
		return -1
	if handle / INDEX_SPAN != _generation[index]:
		return -1
	return index


## Handle живого слота по индексу или INVALID_HANDLE.
func handle_at(index: int) -> int:
	if index < 0 or index >= _capacity or _alive[index] == 0:
		return INVALID_HANDLE
	return _generation[index] * INDEX_SPAN + index


## Снимок для сохранения. Аллоцирует.
func get_state() -> Dictionary:
	return {
		"capacity": _capacity,
		"generation": _generation.duplicate(),
		"alive": _alive.duplicate(),
		"free": _free.duplicate(),
		"free_count": _free_count,
	}


## Восстановление из get_state() с проверкой согласованности (Zero-Trust):
## типы полей, свободные индексы различны и лежат в [0, capacity), alive == 0
## ровно для них и 1 для остальных, поколения неотрицательны. false — снимок
## отвергнут, состояние не изменено.
func set_state(state: Dictionary) -> bool:
	if typeof(state.get("capacity")) != TYPE_INT or typeof(state.get("free_count")) != TYPE_INT \
			or typeof(state.get("generation")) != TYPE_PACKED_INT32_ARRAY \
			or typeof(state.get("free")) != TYPE_PACKED_INT32_ARRAY \
			or typeof(state.get("alive")) != TYPE_PACKED_BYTE_ARRAY:
		return false
	if int(state["capacity"]) != _capacity:
		return false
	var generation: PackedInt32Array = state["generation"]
	var alive: PackedByteArray = state["alive"]
	var free: PackedInt32Array = state["free"]
	var free_count: int = int(state["free_count"])
	if generation.size() != _capacity or alive.size() != _capacity or free.size() != _capacity \
			or free_count < 0 or free_count > _capacity:
		return false
	var is_free := PackedByteArray()
	is_free.resize(_capacity)
	for i: int in free_count:
		var index: int = free[i]
		if index < 0 or index >= _capacity or is_free[index] == 1:
			return false
		is_free[index] = 1
	for index: int in _capacity:
		if generation[index] < 0 or alive[index] != 1 - is_free[index]:
			return false
	_generation = generation.duplicate()
	_alive = alive.duplicate()
	_free = free.duplicate()
	_free_count = free_count
	return true
