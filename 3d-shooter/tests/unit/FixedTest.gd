extends GdUnitTestSuite
## Fixed: арифметика ×1000, округление к нулю, границы диапазонов, деление на ноль.


func test_from_int_and_to_int() -> void:
	assert_int(Fixed.from_int(7)).is_equal(7000)
	assert_int(Fixed.from_int(-3)).is_equal(-3000)
	assert_int(Fixed.to_int(7999)).is_equal(7)
	assert_int(Fixed.to_int(-7999)).is_equal(-7)


func test_mul_exact() -> void:
	assert_int(Fixed.mul(1500, 2000)).is_equal(3000)  # 1.5 × 2 = 3
	assert_int(Fixed.mul(1000, 1000)).is_equal(1000)
	assert_int(Fixed.mul(0, 123456)).is_equal(0)


func test_mul_truncates_toward_zero_for_all_sign_combinations() -> void:
	# 1.5 × 0.333 = 0.4995 → 0.499
	assert_int(Fixed.mul(1500, 333)).is_equal(499)
	assert_int(Fixed.mul(-1500, 333)).is_equal(-499)
	assert_int(Fixed.mul(1500, -333)).is_equal(-499)
	assert_int(Fixed.mul(-1500, -333)).is_equal(499)


func test_div_truncates_toward_zero_for_all_sign_combinations() -> void:
	# 1 / 3 = 0.333…
	assert_int(Fixed.div(1000, 3000)).is_equal(333)
	assert_int(Fixed.div(-1000, 3000)).is_equal(-333)
	assert_int(Fixed.div(1000, -3000)).is_equal(-333)
	assert_int(Fixed.div(-1000, -3000)).is_equal(333)


func test_div_exact() -> void:
	assert_int(Fixed.div(3000, 2000)).is_equal(1500)  # 3 / 2 = 1.5
	assert_int(Fixed.div(0, 2000)).is_equal(0)


func test_div_by_zero_returns_zero_and_reports() -> void:
	await assert_error(func() -> void: Fixed.div(5000, 0)) \
		.is_push_error("Fixed.div: деление на ноль")
	# Результат не зависит от знака делимого.
	var results := PackedInt64Array()
	await assert_error(func() -> void:
		results.append(Fixed.div(5000, 0))
		results.append(Fixed.div(-5000, 0))
		results.append(Fixed.div(0, 0))).is_push_error("Fixed.div: деление на ноль")
	assert_array(results).is_equal(PackedInt64Array([0, 0, 0]))


func test_mul_at_range_limit_does_not_overflow() -> void:
	var m: int = Fixed.MAX_MUL_OPERAND
	var expected: int = (m * m) / Fixed.SCALE
	assert_bool(expected > 0).is_true()
	assert_int(Fixed.mul(m, m)).is_equal(expected)
	assert_int(Fixed.mul(-m, m)).is_equal(-expected)


func test_div_at_range_limit_does_not_overflow() -> void:
	var d: int = Fixed.MAX_DIV_DIVIDEND
	assert_int(Fixed.div(d, Fixed.SCALE)).is_equal(d)
	assert_int(Fixed.div(-d, Fixed.SCALE)).is_equal(-d)


func test_operations_do_not_allocate() -> void:
	var acc: int = 0
	for i: int in 1000:
		acc += Fixed.mul(i, 1337) + Fixed.div(i, 7000) + Fixed.to_int(i)
	var objects_before: int = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var memory_before: int = int(Performance.get_monitor(Performance.MEMORY_STATIC))
	for i: int in 50000:
		acc += Fixed.mul(i, 1337) + Fixed.div(i, 7000) + Fixed.to_int(i)
	# Обе дельты снимаются до первого assert: сами assert-объекты gdUnit аллоцируют.
	var objects_delta: int = int(Performance.get_monitor(Performance.OBJECT_COUNT)) - objects_before
	var memory_delta: int = int(Performance.get_monitor(Performance.MEMORY_STATIC)) - memory_before
	assert_int(objects_delta).is_equal(0)
	assert_int(memory_delta).is_equal(0)
	assert_int(acc).is_not_equal(-1)
