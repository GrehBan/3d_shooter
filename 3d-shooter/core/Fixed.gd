class_name Fixed
extends RefCounted
## Арифметика фиксированной точки ×1000 для детерминированного контура
## (урон, статы, шансы, множители). Только int64, float не используется.
##
## Округление: всегда к нулю (отбрасывание дробной части), как у целочисленного
## деления GDScript. Например, mul(-1500, 333) = -499, а не -500.
##
## Допустимые диапазоны, при которых промежуточный результат не выходит за int64
## (проверяются assert, то есть только в debug-сборке):
##   mul(a, b): |a| ≤ MAX_MUL_OPERAND и |b| ≤ MAX_MUL_OPERAND
##              (≈ 3 037 000.499 в единицах, |a·b| < 2^63);
##   div(a, b): |a| ≤ MAX_DIV_DIVIDEND (≈ 9.22·10^12 в единицах, |a·1000| < 2^63).
## Деление на ноль детерминированно: результат 0 и push_error.

const SCALE: int = 1000
const MAX_MUL_OPERAND: int = 3_037_000_499  # floor(sqrt(2^63 - 1))
const MAX_DIV_DIVIDEND: int = 9_223_372_036_854_775  # floor((2^63 - 1) / SCALE)


## Целое число единиц → фиксированная точка.
static func from_int(units: int) -> int:
	assert(absi(units) <= MAX_DIV_DIVIDEND, "Fixed.from_int: выход за диапазон")
	return units * SCALE


## Фиксированная точка → целое число единиц с округлением к нулю.
static func to_int(value: int) -> int:
	return value / SCALE


## Произведение двух значений ×1000, округление к нулю.
static func mul(a: int, b: int) -> int:
	assert(absi(a) <= MAX_MUL_OPERAND and absi(b) <= MAX_MUL_OPERAND, "Fixed.mul: выход за диапазон")
	return (a * b) / SCALE


## Частное двух значений ×1000, округление к нулю. При b == 0 возвращает 0.
static func div(a: int, b: int) -> int:
	if b == 0:
		push_error("Fixed.div: деление на ноль")
		return 0
	assert(absi(a) <= MAX_DIV_DIVIDEND, "Fixed.div: выход за диапазон")
	return (a * SCALE) / b
