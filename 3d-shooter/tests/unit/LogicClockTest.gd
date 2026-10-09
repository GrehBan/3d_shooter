extends GdUnitTestSuite
## LogicClock: делитель физического тика 60 Гц в логический 30 Гц.


func test_logic_tick_fires_on_every_second_physics_tick() -> void:
	var clock := LogicClock.new()
	var pattern := PackedInt32Array()
	for i: int in 6:
		pattern.append(1 if clock.advance() else 0)
	assert_array(pattern).is_equal(PackedInt32Array([0, 1, 0, 1, 0, 1]))


func test_counters_after_ten_physics_ticks() -> void:
	var clock := LogicClock.new()
	var fired: int = 0
	for i: int in 10:
		if clock.advance():
			fired += 1
	assert_int(clock.physics_tick).is_equal(10)
	assert_int(clock.logic_tick).is_equal(5)
	assert_int(fired).is_equal(5)


func test_reset_restores_initial_phase() -> void:
	var clock := LogicClock.new()
	clock.advance()  # фаза сдвинута на нечётный тик
	clock.reset()
	assert_int(clock.physics_tick).is_equal(0)
	assert_int(clock.logic_tick).is_equal(0)
	assert_bool(clock.advance()).is_false()
	assert_bool(clock.advance()).is_true()


func test_ratio_matches_physics_ticks_per_logic_tick() -> void:
	var clock := LogicClock.new()
	for i: int in 600:
		clock.advance()
	assert_int(clock.logic_tick).is_equal(600 / LogicClock.PHYSICS_TICKS_PER_LOGIC_TICK)
