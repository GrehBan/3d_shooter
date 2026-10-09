class_name SeededRng
extends RefCounted
## Детерминированный целочисленный ГПСЧ с изолированными подпотоками.
##
## Алгоритм — xoshiro128** (Blackman, Vigna): состояние из четырёх 32-битных слов.
## Все промежуточные значения держатся в [0, 2^32) явной маской, умножения
## раскладываются на 16-битные половины, поэтому int64 GDScript никогда не
## переполняется и не сдвигает отрицательные числа. Результат побитово одинаков
## на любой платформе. Float, глобальные randi()/randf() и RandomNumberGenerator
## движка не используются.
##
## Подпотоки: substream_seed(stream_id) выводится из исходного сида и id потока,
## а не из текущего состояния. Сколько бы значений ни потребил один поток,
## выдача другого не сдвигается (GDD §7).
##
## Горячий путь (next_u32, range_int, chance_permille, weighted_index, shuffle)
## не выделяет память. Аллоцируют только substream() и get_state(): их зовут
## при загрузке комнаты или сохранении, а не в бою. Для переиспользования
## объекта в бою есть reseed().

const MASK32: int = 0xFFFFFFFF
const TWO_POW_32: int = 0x100000000
const PERMILLE_SCALE: int = 1000

# Константы сидинга: произвольные нечётные 32-битные значения.
const _SEED_K0: int = 0x9E3779B9
const _SEED_K1: int = 0x7F4A7C15
const _SEED_K2: int = 0x85EBCA77
const _SEED_K3: int = 0xC2B2AE3D
const _STREAM_K_LO: int = 0x27D4EB2F
const _STREAM_K_HI: int = 0x165667B1

var _seed: int = 0
var _s0: int = 0
var _s1: int = 0
var _s2: int = 0
var _s3: int = 0


func _init(rng_seed: int = 0) -> void:
	reseed(rng_seed)


## Сбрасывает генератор в начальное состояние для сида (любой int64).
func reseed(rng_seed: int) -> void:
	_seed = rng_seed
	var lo: int = rng_seed & MASK32
	var hi: int = _high32(rng_seed)
	# mix32 — биекция на 32 битах, поэтому пара (_s0, _s1) однозначно задаёт сид.
	# _s1 зависит от обеих половин сида: первый выход xoshiro128** определяется
	# только _s1, и без этого сиды с одинаковыми старшими битами дали бы
	# одинаковый первый бросок.
	_s0 = _mix32(lo ^ _SEED_K0)
	_s1 = _mix32(hi ^ _SEED_K1 ^ _s0)
	_s2 = _mix32(_s0 ^ _mix32(_s1 ^ _SEED_K2))
	_s3 = _mix32(_s1 ^ _mix32(_s0 ^ _SEED_K3))
	if (_s0 | _s1 | _s2 | _s3) == 0:
		_s0 = 1


## Исходный сид генератора.
func get_seed() -> int:
	return _seed


## Сид подпотока: зависит только от исходного сида и stream_id. Результат в [0, 2^63).
func substream_seed(stream_id: int) -> int:
	return derive_seed(_seed, stream_id)


## Новый независимый генератор для подпотока. Аллоцирует: не вызывать в бою.
func substream(stream_id: int) -> SeededRng:
	return SeededRng.new(substream_seed(stream_id))


## Следующее 32-битное значение в [0, 2^32).
func next_u32() -> int:
	var result: int = _mul32(_rotl32(_mul32(_s1, 5), 7), 9)
	var t: int = (_s1 << 9) & MASK32
	_s2 ^= _s0
	_s3 ^= _s1
	_s1 ^= _s2
	_s0 ^= _s3
	_s2 ^= t
	_s3 = _rotl32(_s3, 11)
	return result


## Равномерное целое в [min_inclusive, max_inclusive] без смещения (отбраковка).
## Ширина диапазона — от 1 до 2^32 значений.
func range_int(min_inclusive: int, max_inclusive: int) -> int:
	var span: int = max_inclusive - min_inclusive + 1
	assert(span >= 1 and span <= TWO_POW_32, "SeededRng.range_int: недопустимый диапазон")
	var threshold: int = (TWO_POW_32 - span) % span
	var r: int = next_u32()
	while r < threshold:
		r = next_u32()
	return min_inclusive + r % span


## Бросок шанса в фиксированной точке ×1000: 0 — никогда, 1000 — всегда.
func chance_permille(permille: int) -> bool:
	if permille <= 0:
		return false
	if permille >= PERMILLE_SCALE:
		return true
	return range_int(0, PERMILLE_SCALE - 1) < permille


## Индекс по целым неотрицательным весам. Возвращает -1, если сумма весов 0.
func weighted_index(weights: PackedInt32Array) -> int:
	var total: int = 0
	for w: int in weights:
		assert(w >= 0, "SeededRng.weighted_index: отрицательный вес")
		total += w
	if total <= 0:
		return -1
	var pick: int = range_int(0, total - 1)
	for i: int in weights.size():
		pick -= weights[i]
		if pick < 0:
			return i
	return weights.size() - 1


## Перемешивание Фишера–Йетса на месте (массив передаётся по ссылке).
func shuffle_int32(values: PackedInt32Array) -> void:
	var i: int = values.size() - 1
	while i > 0:
		var j: int = range_int(0, i)
		var tmp: int = values[i]
		values[i] = values[j]
		values[j] = tmp
		i -= 1


## Снимок состояния для SaveSystem: [seed, s0, s1, s2, s3]. Аллоцирует.
func get_state() -> PackedInt64Array:
	return PackedInt64Array([_seed, _s0, _s1, _s2, _s3])


## Восстановление из снимка get_state(). Проверку снимка из файла делает
## загрузчик сохранений: assert ниже вырезается в релизной сборке.
## Нулевое состояние (xoshiro128** из него выдаёт только нули) исправляется
## так же, как в reseed().
func set_state(state: PackedInt64Array) -> void:
	assert(state.size() == 5, "SeededRng.set_state: ожидается 5 значений")
	_seed = state[0]
	_s0 = state[1] & MASK32
	_s1 = state[2] & MASK32
	_s2 = state[3] & MASK32
	_s3 = state[4] & MASK32
	if (_s0 | _s1 | _s2 | _s3) == 0:
		_s0 = 1


## Сид подпотока из родительского сида и id потока. Результат в [0, 2^63).
static func derive_seed(parent_seed: int, stream_id: int) -> int:
	var lo: int = _mix32((parent_seed & MASK32) ^ _mix32((stream_id & MASK32) ^ _STREAM_K_LO))
	var hi: int = _mix32(_high32(parent_seed) ^ _mix32(_high32(stream_id) ^ _STREAM_K_HI) ^ lo)
	return ((hi & 0x7FFFFFFF) << 32) | lo


# Старшие 32 бита int64 без сдвига отрицательного числа.
static func _high32(value: int) -> int:
	if value >= 0:
		return value >> 32
	return ((value & 0x7FFFFFFFFFFFFFFF) >> 32) | 0x80000000


# (a * b) mod 2^32 для a, b в [0, 2^32): частичные произведения не превышают 2^48.
static func _mul32(a: int, b: int) -> int:
	var low: int = a * (b & 0xFFFF)
	var high: int = ((a * (b >> 16)) & 0xFFFF) << 16
	return (low + high) & MASK32


static func _rotl32(x: int, k: int) -> int:
	return ((x << k) | (x >> (32 - k))) & MASK32


# Финализатор murmur3 (fmix32): биекция на 32 битах.
static func _mix32(x: int) -> int:
	var h: int = x & MASK32
	h ^= h >> 16
	h = _mul32(h, 0x85EBCA6B)
	h ^= h >> 13
	h = _mul32(h, 0xC2B2AE35)
	h ^= h >> 16
	return h
