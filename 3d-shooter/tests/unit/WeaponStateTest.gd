extends GdUnitTestSuite


func _stats() -> StatBlock:
	var stats := StatBlock.new(2)
	var entity: int = stats.allocate()
	stats.set_stat(entity, StatBlock.Stat.HP, 100000)
	return stats


func test_semiauto_exact_boundary_refused_edge_and_immutable_copy() -> void:
	var stats: StatBlock = _stats()
	var batch := ShotBatch.new(4, 8, 2)
	var state := WeaponState.new()
	var data := WeaponData.new()
	assert_bool(state.configure(data, 0)).is_true()
	data.cooldown_ticks = 1
	data.damage_raw = 99
	state.set_pressed(true)
	assert_int(state.request_shot(batch, stats, 1000)).is_greater(0)
	assert_int(state.ready_tick).is_equal(1015)
	state.set_pressed(true)
	assert_int(state.request_shot(batch, stats, 1015)).is_equal(-1)
	state.set_pressed(false)
	state.set_pressed(true)
	assert_int(state.request_shot(batch, stats, 1014)).is_equal(-1)
	assert_int(state.request_shot(batch, stats, 1015)).is_equal(-1)
	state.set_pressed(false)
	state.set_pressed(true)
	assert_int(state.request_shot(batch, stats, 1015)).is_greater(0)
	assert_int(state.accepted_shots).is_equal(2)
	assert_int(state.ready_tick).is_equal(1030)
	assert_int(batch._damage[0]).is_equal(6000)


func test_atomic_capacity_refusal_does_not_change_cooldown_or_resources() -> void:
	var stats: StatBlock = _stats()
	stats.set_stat(0, StatBlock.Stat.ENERGY, 3000)
	var batch := ShotBatch.new(1, 7, 2)
	var state := WeaponState.new()
	state.configure(WeaponData.new(), 0)
	state.set_pressed(true)
	assert_error(func() -> void: state.request_shot(batch, stats, 1000)).is_push_error("ShotBatch: invalid request, capacity or identity exhausted")
	assert_int(state.ready_tick).is_equal(0)
	assert_int(state.accepted_shots).is_equal(0)
	assert_int(batch.pending_count()).is_equal(0)
	assert_int(stats.get_stat(0, StatBlock.Stat.ENERGY)).is_equal(3000)
	assert_int(state.request_shot(batch, stats, 1001)).is_equal(-1)


func test_reset_exact_old_tick_before_first_logic_preserves_held_and_discards_press() -> void:
	var stats: StatBlock = _stats()
	var batch := ShotBatch.new(4, 8, 2)
	var state := WeaponState.new()
	state.configure(WeaponData.new(), 0)
	state.set_pressed(true)
	state.request_shot(batch, stats, 1000)
	state.reset_clock(1003)
	batch.reset_room()
	assert_int(state.ready_tick).is_equal(12)
	state.set_pressed(true)
	assert_int(state.request_shot(batch, stats, 12)).is_equal(-1)
	state.set_pressed(false)
	state.set_pressed(true)
	state.reset_clock(0)
	assert_int(state.request_shot(batch, stats, 12)).is_equal(-1)
	state.set_pressed(false)
	state.set_pressed(true)
	assert_int(state.request_shot(batch, stats, 11)).is_equal(-1)
	state.set_pressed(false)
	state.set_pressed(true)
	assert_int(state.request_shot(batch, stats, 12)).is_greater(0)


func test_two_weapons_use_one_allocator_and_new_full_handle_lifecycle() -> void:
	var stats: StatBlock = _stats()
	var batch := ShotBatch.new(4, 8, 2)
	var a := WeaponState.new()
	var b := WeaponState.new()
	a.configure(WeaponData.new(), 0)
	b.configure(WeaponData.new(), 0)
	a.set_pressed(true)
	b.set_pressed(true)
	a.request_shot(batch, stats, 0)
	b.request_shot(batch, stats, 0)
	assert_int(batch._sequence[0]).is_equal(0)
	assert_int(batch._sequence[1]).is_equal(1)
	stats.release(0)
	var fresh: int = stats.allocate()
	a.set_pressed(false)
	a.set_pressed(true)
	assert_int(a.request_shot(batch, stats, 1000)).is_equal(-1)
	assert_bool(a.configure(WeaponData.new(), fresh)).is_true()
	assert_int(a.ready_tick).is_equal(0)
	assert_int(a.request_shot(batch, stats, 1000)).is_equal(-1)


func test_clock_addition_exhaustion_refuses_before_reservation() -> void:
	var stats: StatBlock = _stats()
	var batch := ShotBatch.new(4, 8, 2)
	var state := WeaponState.new()
	state.configure(WeaponData.new(), 0)
	state.set_pressed(true)
	assert_error(func() -> void: state.request_shot(batch, stats, ShotBatch.INT_MAX)).is_push_error("ShotBatch: invalid request, capacity or identity exhausted")
	assert_int(state.ready_tick).is_equal(0)
	assert_int(batch.pending_count()).is_equal(0)
