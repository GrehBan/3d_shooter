class_name HitEventQueue
extends RefCounted
## Очередь событий попаданий из физики (60 Гц) для логического тика (30 Гц),
## манифест II.4. Физика (hitscan, снаряды, ближний бой, зоны) только кладёт
## событие push(); логика забирает накопленное раз в логический тик:
## prepare() → обход get_*(i) для i < count() → clear().
##
## Детерминизм: порядок колбэков Jolt не детерминирован, поэтому prepare()
## приводит события к каноническому порядку: сначала по префиксу (индекс слота
## цели, индекс слота источника, вид, младшие 17 бит payload), при равных
## префиксах — по полным значениям (target, source, kind, payload). Это не порядок
## по полным handle, но полный и однозначный: одинаковый набор попаданий даёт
## одинаковую последовательность при любом порядке вставки. Совпадение всех
## четырёх полей означает одинаковые события, их взаимный порядок не важен.
##
## Сортировка без аллокаций: в предвыделенный PackedInt64Array пишутся ключи
## «индекс цели | индекс источника | вид | младшие биты payload | номер записи»,
## нативный sort() упорядочивает их, затем короткие серии с равным префиксом
## доупорядочиваются вставками по полному ключу. Худший случай — O(n²) вставок,
## если почти все события тика имеют одинаковый префикс (одни слоты цели и
## источника при разных поколениях и payload, совпадающих в младших 17 битах).
##
## Ёмкость фиксирована (по умолчанию 512, не больше MAX_CAPACITY) и подбирается
## под худший случай: переполнение — ошибка конфигурации, а не штатный режим.
## При переполнении push() возвращает false, сохраняются первые пришедшие
## события, остальные отбрасываются, dropped_count() растёт, а push_error
## пишется один раз до ближайшего clear(). Порядок детерминирован только при
## dropped_count() == 0: отбор при переполнении зависит от порядка колбэков.
## Бенчмарк и интеграционные тесты боя обязаны падать при dropped_count() != 0.

enum HitKind { HITSCAN, PROJECTILE, MELEE, AREA }

const DEFAULT_CAPACITY: int = 512
const MAX_CAPACITY: int = 1 << _RECORD_BITS

const _RECORD_BITS: int = 10
const _PAYLOAD_BITS: int = 17
const _KIND_BITS: int = 4
const _INDEX_BITS: int = 16
const _RECORD_MASK: int = (1 << _RECORD_BITS) - 1
const _PAYLOAD_MASK: int = (1 << _PAYLOAD_BITS) - 1
const _KIND_MASK: int = (1 << _KIND_BITS) - 1
const _INDEX_MASK: int = (1 << _INDEX_BITS) - 1
const _PREFIX_SHIFT: int = _RECORD_BITS

var _capacity: int = 0
var _count: int = 0
var _dropped: int = 0
var _overflow_reported: bool = false
var _source: PackedInt64Array = PackedInt64Array()
var _target: PackedInt64Array = PackedInt64Array()
var _payload: PackedInt64Array = PackedInt64Array()
var _kind: PackedInt32Array = PackedInt32Array()
var _keys: PackedInt64Array = PackedInt64Array()  # ключи сортировки, длина = capacity
var _order: PackedInt32Array = PackedInt32Array()  # номер записи в отсортированном порядке


func _init(capacity: int = DEFAULT_CAPACITY) -> void:
	assert(capacity > 0 and capacity <= MAX_CAPACITY, "HitEventQueue: недопустимая ёмкость")
	_capacity = clampi(capacity, 1, MAX_CAPACITY)
	_source.resize(_capacity)
	_target.resize(_capacity)
	_payload.resize(_capacity)
	_kind.resize(_capacity)
	_keys.resize(_capacity)
	_order.resize(_capacity)


func capacity() -> int:
	return _capacity


func count() -> int:
	return _count


func dropped_count() -> int:
	return _dropped


func reset_dropped_count() -> void:
	_dropped = 0


## Регистрирует попадание. source и target — handle (int64), payload — id
## атаки или оружия (int64). false, если очередь переполнена.
func push(source: int, target: int, kind: HitKind, payload: int) -> bool:
	if _count == _capacity:
		_dropped += 1
		if not _overflow_reported:
			_overflow_reported = true
			push_error("HitEventQueue: переполнение, события отбрасываются")
		return false
	_source[_count] = source
	_target[_count] = target
	_kind[_count] = kind
	_payload[_count] = payload
	_count += 1
	return true


## Упорядочивает накопленные события. Вызывается один раз в начале логического тика.
func prepare() -> int:
	for record: int in _count:
		_keys[record] = _prefix_of(record) << _PREFIX_SHIFT | record
	# Хвост за пределами _count заполняется максимумом, чтобы нативная сортировка
	# всего массива оставила реальные ключи в начале.
	for i: int in range(_count, _capacity):
		_keys[i] = 0x7FFFFFFFFFFFFFFF
	_keys.sort()
	for i: int in _count:
		_order[i] = _keys[i] & _RECORD_MASK
	_fix_prefix_ties()
	return _count


## Поля i-го события в упорядоченной последовательности (после prepare()).
func get_source(i: int) -> int:
	return _source[_order[i]]


func get_target(i: int) -> int:
	return _target[_order[i]]


func get_kind(i: int) -> HitKind:
	return _kind[_order[i]] as HitKind


func get_payload(i: int) -> int:
	return _payload[_order[i]]


## Очищает очередь после обработки логическим тиком.
func clear() -> void:
	_count = 0
	_overflow_reported = false


# Ключ без номера записи: индекс цели, индекс источника, вид, младшие биты payload.
# NO_HANDLE (-1) и прочие отрицательные значения маскируются: префикс лишь ускоряет
# сортировку, точный порядок задаёт _less() при равных префиксах.
func _prefix_of(record: int) -> int:
	var target_index: int = _target[record] & _INDEX_MASK
	var source_index: int = _source[record] & _INDEX_MASK
	var prefix: int = target_index
	prefix = prefix << _INDEX_BITS | source_index
	prefix = prefix << _KIND_BITS | (_kind[record] & _KIND_MASK)
	prefix = prefix << _PAYLOAD_BITS | (_payload[record] & _PAYLOAD_MASK)
	return prefix


# Вставками доупорядочивает соседние записи с одинаковым префиксом по полному ключу.
func _fix_prefix_ties() -> void:
	var i: int = 1
	while i < _count:
		var current: int = _order[i]
		var current_prefix: int = _keys[i] >> _PREFIX_SHIFT
		var j: int = i - 1
		while j >= 0 and (_keys[j] >> _PREFIX_SHIFT) == current_prefix and _less(current, _order[j]):
			_order[j + 1] = _order[j]
			j -= 1
		_order[j + 1] = current
		i += 1


func _less(a: int, b: int) -> bool:
	if _target[a] != _target[b]:
		return _target[a] < _target[b]
	if _source[a] != _source[b]:
		return _source[a] < _source[b]
	if _kind[a] != _kind[b]:
		return _kind[a] < _kind[b]
	return _payload[a] < _payload[b]
