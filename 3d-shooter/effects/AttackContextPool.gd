class_name AttackContextPool
extends RefCounted
## Контексты атак (GDD §5, «Attack Context»): атака — дерево, а не одно событие.
## Корень открывается выстрелом; вторичные удары (дуга цепной молнии, взрыв)
## открывают дочерние контексты. Пул фиксированной ёмкости, SoA-массивы, handle
## по поколениям (HandlePool), хранить только в int64.
##
## Ограничители GDD: глубина не больше MAX_DEPTH (корень — 0); общий бюджет
## ударов на всё дерево задаётся при открытии корня; одна и та же цель не
## поражается дважды в пределах ветки (контекст и все его предки), но может быть
## поражена в соседней ветке. Множество поражённых целей — плотный массив
## HITS_PER_CONTEXT записей на контекст, без Dictionary.
##
## Разрешение графа: close() каждого открытого контекста; когда закрыт последний
## контекст дерева, close() возвращает true (момент OnAttackResolved) и все
## контексты дерева освобождаются. Отказы (глубина, бюджет, переполнение
## множества целей, ёмкость пула) детерминированны и считаются в счётчиках.

const MAX_DEPTH: int = 4
const HITS_PER_CONTEXT: int = 16
const DEFAULT_CAPACITY: int = 128
const INVALID_HANDLE: int = HandlePool.INVALID_HANDLE

var _capacity: int = 0
var _handles: HandlePool
var _root: PackedInt64Array = PackedInt64Array()
var _parent: PackedInt64Array = PackedInt64Array()
var _source: PackedInt64Array = PackedInt64Array()
var _depth: PackedInt32Array = PackedInt32Array()
var _budget_left: PackedInt32Array = PackedInt32Array()  # значим только у корня
var _open_count: PackedInt32Array = PackedInt32Array()  # у корня: открытые контексты дерева
var _closed: PackedByteArray = PackedByteArray()
var _hit_count: PackedInt32Array = PackedInt32Array()
var _hits: PackedInt64Array = PackedInt64Array()  # capacity × HITS_PER_CONTEXT

var depth_refusals: int = 0
var budget_refusals: int = 0
var hit_set_overflows: int = 0
var capacity_refusals: int = 0


func _init(capacity: int = DEFAULT_CAPACITY) -> void:
	_handles = HandlePool.new(capacity)
	_capacity = _handles.capacity()
	_root.resize(_capacity)
	_parent.resize(_capacity)
	_source.resize(_capacity)
	_depth.resize(_capacity)
	_budget_left.resize(_capacity)
	_open_count.resize(_capacity)
	_closed.resize(_capacity)
	_hit_count.resize(_capacity)
	_hits.resize(_capacity * HITS_PER_CONTEXT)


func capacity() -> int:
	return _capacity


func alive_count() -> int:
	return _handles.alive_count()


func is_valid(context: int) -> bool:
	return _handles.is_valid(context)


## Открывает корень атаки от источника source (handle сущности или -1) с общим
## бюджетом ударов. INVALID_HANDLE, если пул исчерпан.
func open_root(source: int, hit_budget: int) -> int:
	var context: int = _open_slot()
	if context == INVALID_HANDLE:
		return INVALID_HANDLE
	var index: int = _handles.index_of(context)
	_root[index] = context
	_parent[index] = INVALID_HANDLE
	_source[index] = source
	_depth[index] = 0
	_budget_left[index] = maxi(hit_budget, 0)
	_open_count[index] = 1
	return context


## Открывает дочерний контекст (вторичный удар). INVALID_HANDLE, если родитель
## недействителен или закрыт, превышена глубина или исчерпан пул.
func open_child(parent: int) -> int:
	var parent_index: int = _handles.index_of(parent)
	if parent_index < 0 or _closed[parent_index] == 1:
		return INVALID_HANDLE
	var depth: int = _depth[parent_index] + 1
	if depth > MAX_DEPTH:
		depth_refusals += 1
		return INVALID_HANDLE
	var context: int = _open_slot()
	if context == INVALID_HANDLE:
		return INVALID_HANDLE
	var index: int = _handles.index_of(context)
	var root: int = _root[parent_index]
	_root[index] = root
	_parent[index] = parent
	_source[index] = _source[parent_index]
	_depth[index] = depth
	_budget_left[index] = 0
	_open_count[index] = 0
	_open_count[_handles.index_of(root)] += 1
	return context


## Регистрирует удар по цели. false, если контекст недействителен или закрыт,
## цель уже поражена в этой ветке, бюджет дерева исчерпан или множество целей
## контекста заполнено. При true бюджет дерева уменьшается на 1.
func try_register_hit(context: int, target: int) -> bool:
	var index: int = _handles.index_of(context)
	if index < 0 or _closed[index] == 1:
		return false
	if _branch_has_hit(index, target):
		return false
	var root_index: int = _handles.index_of(_root[index])
	if _budget_left[root_index] <= 0:
		budget_refusals += 1
		return false
	var count: int = _hit_count[index]
	if count >= HITS_PER_CONTEXT:
		hit_set_overflows += 1
		return false
	_hits[index * HITS_PER_CONTEXT + count] = target
	_hit_count[index] = count + 1
	_budget_left[root_index] -= 1
	return true


## Закрывает контекст. true, если это был последний открытый контекст дерева:
## граф разрешён (OnAttackResolved), все контексты дерева освобождены и их
## handle становятся недействительными.
func close(context: int) -> bool:
	var index: int = _handles.index_of(context)
	if index < 0 or _closed[index] == 1:
		return false
	_closed[index] = 1
	var root: int = _root[index]
	var root_index: int = _handles.index_of(root)
	_open_count[root_index] -= 1
	if _open_count[root_index] > 0:
		return false
	for i: int in _capacity:
		var handle: int = _handles.handle_at(i)
		if handle != INVALID_HANDLE and _root[i] == root:
			_handles.release(handle)
	return true


func depth_of(context: int) -> int:
	var index: int = _handles.index_of(context)
	return -1 if index < 0 else _depth[index]


func root_of(context: int) -> int:
	var index: int = _handles.index_of(context)
	return INVALID_HANDLE if index < 0 else _root[index]


func parent_of(context: int) -> int:
	var index: int = _handles.index_of(context)
	return INVALID_HANDLE if index < 0 else _parent[index]


func source_of(context: int) -> int:
	var index: int = _handles.index_of(context)
	return INVALID_HANDLE if index < 0 else _source[index]


## Остаток бюджета ударов всего дерева; -1 для недействительного контекста.
func budget_left(context: int) -> int:
	var index: int = _handles.index_of(context)
	if index < 0:
		return -1
	return _budget_left[_handles.index_of(_root[index])]


func hit_count(context: int) -> int:
	var index: int = _handles.index_of(context)
	return 0 if index < 0 else _hit_count[index]


func _open_slot() -> int:
	var context: int = _handles.allocate()
	if context == INVALID_HANDLE:
		capacity_refusals += 1
		push_error("AttackContextPool: ёмкость %d исчерпана" % _capacity)
		return INVALID_HANDLE
	var index: int = _handles.index_of(context)
	_closed[index] = 0
	_hit_count[index] = 0
	return context


# Поражена ли цель в контексте index или у любого его предка.
func _branch_has_hit(index: int, target: int) -> bool:
	var current: int = index
	while current >= 0:
		var base: int = current * HITS_PER_CONTEXT
		for k: int in _hit_count[current]:
			if _hits[base + k] == target:
				return true
		var parent: int = _parent[current]
		current = -1 if parent == INVALID_HANDLE else _handles.index_of(parent)
	return false
