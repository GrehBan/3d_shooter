class_name EffectHost
extends RefCounted
## Хранилище подписок эффектов на триггеры для всех хостов (игрок, элиты):
## одно на мир, а не объект на сущность (DOD). EffectRunner (M2) обходит
## эффекты (хост, триггер) в детерминированном порядке; исполнения здесь нет.
##
## Хост — handle сущности StatBlock (int64); его слот = handle % INDEX_SPAN,
## поэтому host_capacity совпадает с ёмкостью StatBlock. Таблица голов списков
## host_capacity × TRIGGER_COUNT хранит первую запись каждого списка (хост,
## триггер); слот помнит полный handle хоста-владельца, и first() по
## устаревшему handle (другое поколение) возвращает -1.
##
## Записи — SoA-массивы с handle по поколениям (HandlePool) и двусвязными
## интрузивными списками: по (хост, триггер) и по хосту. add_effect вставляет
## запись на место по ключу (phase, priority, slot_index, effect_id, handle
## записи) за O(длины списка); remove_effect и clear_host снимают записи без
## пересборки. Добавлять и снимать эффекты можно прямо в бою (спавн и смерть
## элит): аллокаций и сортировки нет. Если слот занят устаревшим хостом,
## который не сняли clear_host, его записи освобождаются при первом
## add_effect нового хоста.
## clear_host освобождает записи в обратном порядке добавления (список хоста
## растёт с головы); это часть детерминированного поведения: от порядка
## освобождения зависит, какие слоты записей выдаются дальше.
##
## Порядок резолва: фаза (PRE → MAIN → POST), затем priority по возрастанию,
## затем slot_index и effect_id по возрастанию, затем handle записи.
##
## Переполнение ёмкости записей — ошибка конфигурации: push_error один раз
## до reset_counters(), счётчик capacity_refusals; корректность только при нуле.
## TODO(M1a шаг 8): regress.gd и интеграционный тест падают при capacity_refusals != 0.

const NO_ENTRY: int = -1
const INVALID_HANDLE: int = HandlePool.INVALID_HANDLE
const DEFAULT_ENTRY_CAPACITY: int = 512
const TRIGGER_COUNT: int = EffectTrigger.TRIGGER_COUNT

var capacity_refusals: int = 0

var _host_capacity: int = 0
var _heads: PackedInt32Array = PackedInt32Array()  # host_capacity × TRIGGER_COUNT
var _slot_host: PackedInt64Array = PackedInt64Array()  # полный handle владельца слота
var _host_first: PackedInt32Array = PackedInt32Array()  # голова списка записей хоста

var _entries: HandlePool
var _host: PackedInt64Array = PackedInt64Array()
var _trigger: PackedInt32Array = PackedInt32Array()
var _phase: PackedInt32Array = PackedInt32Array()
var _priority: PackedInt32Array = PackedInt32Array()
var _slot_index: PackedInt32Array = PackedInt32Array()
var _effect_id: PackedInt32Array = PackedInt32Array()
var _state_slot: PackedInt32Array = PackedInt32Array()
var _next_in_trigger: PackedInt32Array = PackedInt32Array()
var _prev_in_trigger: PackedInt32Array = PackedInt32Array()
var _next_in_host: PackedInt32Array = PackedInt32Array()
var _prev_in_host: PackedInt32Array = PackedInt32Array()
var _capacity_reported: bool = false


func _init(host_capacity: int = StatBlock.DEFAULT_CAPACITY, entry_capacity: int = DEFAULT_ENTRY_CAPACITY) -> void:
	assert(host_capacity > 0 and host_capacity <= HandlePool.MAX_CAPACITY, "EffectHost: недопустимая ёмкость хостов")
	_host_capacity = clampi(host_capacity, 1, HandlePool.MAX_CAPACITY)
	_heads.resize(_host_capacity * TRIGGER_COUNT)
	_heads.fill(NO_ENTRY)
	_slot_host.resize(_host_capacity)
	_slot_host.fill(INVALID_HANDLE)
	_host_first.resize(_host_capacity)
	_host_first.fill(NO_ENTRY)
	_entries = HandlePool.new(entry_capacity)
	var n: int = _entries.capacity()
	_host.resize(n)
	_trigger.resize(n)
	_phase.resize(n)
	_priority.resize(n)
	_slot_index.resize(n)
	_effect_id.resize(n)
	_state_slot.resize(n)
	_next_in_trigger.resize(n)
	_prev_in_trigger.resize(n)
	_next_in_host.resize(n)
	_prev_in_host.resize(n)


func entry_capacity() -> int:
	return _entries.capacity()


func entry_count() -> int:
	return _entries.alive_count()


func reset_counters() -> void:
	capacity_refusals = 0
	_capacity_reported = false


## Подписывает эффект хоста на триггер. Возвращает handle записи или
## INVALID_HANDLE, если хост вне диапазона или ёмкость записей исчерпана.
func add_effect(host: int, trigger: EffectTrigger.Trigger, phase: EffectTrigger.Phase,
		priority: int, slot_index: int, effect_id: int, state_slot: int) -> int:
	var slot: int = _host_slot(host)
	if slot < 0 or trigger < 0 or trigger >= TRIGGER_COUNT:
		return INVALID_HANDLE
	if _slot_host[slot] != host:
		if _slot_host[slot] != INVALID_HANDLE:
			_clear_slot(slot)
		_slot_host[slot] = host
	var entry: int = _entries.allocate()
	if entry == INVALID_HANDLE:
		if _host_first[slot] == NO_ENTRY:
			_slot_host[slot] = INVALID_HANDLE
		capacity_refusals += 1
		if not _capacity_reported:
			_capacity_reported = true
			push_error("EffectHost: ёмкость записей исчерпана")
		return INVALID_HANDLE
	var index: int = _entries.index_of(entry)
	_host[index] = host
	_trigger[index] = trigger
	_phase[index] = phase
	_priority[index] = priority
	_slot_index[index] = slot_index
	_effect_id[index] = effect_id
	_state_slot[index] = state_slot
	_link_trigger(slot * TRIGGER_COUNT + trigger, index)
	_link_host(slot, index)
	return entry


## Снимает эффект. false для устаревшего или чужого handle записи.
func remove_effect(entry: int) -> bool:
	var index: int = _entries.index_of(entry)
	if index < 0:
		return false
	var slot: int = _host[index] % HandlePool.INDEX_SPAN
	_unlink(slot, index)
	_entries.release(entry)
	if _host_first[slot] == NO_ENTRY:
		_slot_host[slot] = INVALID_HANDLE
	return true


## Снимает все эффекты хоста (смерть, деспавн). Возвращает число снятых записей;
## 0 для устаревшего handle хоста.
func clear_host(host: int) -> int:
	var slot: int = _host_slot(host)
	if slot < 0 or _slot_host[slot] != host:
		return 0
	return _clear_slot(slot)


## Первая запись списка (хост, триггер) в порядке резолва или NO_ENTRY.
## Устаревший handle хоста (слот переиспользован) даёт NO_ENTRY.
func first(host: int, trigger: EffectTrigger.Trigger) -> int:
	var slot: int = _host_slot(host)
	if slot < 0 or _slot_host[slot] != host or trigger < 0 or trigger >= TRIGGER_COUNT:
		return NO_ENTRY
	return _heads[slot * TRIGGER_COUNT + trigger]


## Следующая запись того же списка или NO_ENTRY. index — значение из first()/next().
func next(index: int) -> int:
	return _next_in_trigger[index]


## Handle записи по индексу из first()/next() (для remove_effect).
func entry_at(index: int) -> int:
	return _entries.handle_at(index)


func effect_id_at(index: int) -> int:
	return _effect_id[index]


func phase_at(index: int) -> EffectTrigger.Phase:
	return _phase[index] as EffectTrigger.Phase


func priority_at(index: int) -> int:
	return _priority[index]


func slot_index_at(index: int) -> int:
	return _slot_index[index]


func state_slot_at(index: int) -> int:
	return _state_slot[index]


func host_at(index: int) -> int:
	return _host[index]


func _host_slot(host: int) -> int:
	if host < 0:
		return -1
	var slot: int = host % HandlePool.INDEX_SPAN
	return slot if slot < _host_capacity else -1


# Вставка в двусвязный список (хост, триггер) по ключу резолва.
func _link_trigger(head_index: int, index: int) -> void:
	var prev: int = NO_ENTRY
	var current: int = _heads[head_index]
	while current != NO_ENTRY and not _before(index, current):
		prev = current
		current = _next_in_trigger[current]
	_prev_in_trigger[index] = prev
	_next_in_trigger[index] = current
	if prev == NO_ENTRY:
		_heads[head_index] = index
	else:
		_next_in_trigger[prev] = index
	if current != NO_ENTRY:
		_prev_in_trigger[current] = index


# Вставка в начало списка хоста (порядок в нём не важен).
func _link_host(slot: int, index: int) -> void:
	var head: int = _host_first[slot]
	_prev_in_host[index] = NO_ENTRY
	_next_in_host[index] = head
	if head != NO_ENTRY:
		_prev_in_host[head] = index
	_host_first[slot] = index


func _unlink(slot: int, index: int) -> void:
	var prev: int = _prev_in_trigger[index]
	var next_index: int = _next_in_trigger[index]
	if prev == NO_ENTRY:
		_heads[slot * TRIGGER_COUNT + _trigger[index]] = next_index
	else:
		_next_in_trigger[prev] = next_index
	if next_index != NO_ENTRY:
		_prev_in_trigger[next_index] = prev
	prev = _prev_in_host[index]
	next_index = _next_in_host[index]
	if prev == NO_ENTRY:
		_host_first[slot] = next_index
	else:
		_next_in_host[prev] = next_index
	if next_index != NO_ENTRY:
		_prev_in_host[next_index] = prev


func _clear_slot(slot: int) -> int:
	var removed: int = 0
	var current: int = _host_first[slot]
	while current != NO_ENTRY:
		var next_index: int = _next_in_host[current]
		_heads[slot * TRIGGER_COUNT + _trigger[current]] = NO_ENTRY
		_entries.release(_entries.handle_at(current))
		removed += 1
		current = next_index
	_host_first[slot] = NO_ENTRY
	_slot_host[slot] = INVALID_HANDLE
	return removed


# true, если запись a резолвится раньше записи b.
func _before(a: int, b: int) -> bool:
	if _phase[a] != _phase[b]:
		return _phase[a] < _phase[b]
	if _priority[a] != _priority[b]:
		return _priority[a] < _priority[b]
	if _slot_index[a] != _slot_index[b]:
		return _slot_index[a] < _slot_index[b]
	if _effect_id[a] != _effect_id[b]:
		return _effect_id[a] < _effect_id[b]
	return _entries.handle_at(a) < _entries.handle_at(b)
