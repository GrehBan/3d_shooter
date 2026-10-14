extends GdUnitTestSuite


func _valid_result() -> RealPipelineResult:
	var result := RealPipelineResult.new()
	for index: int in RealPipelineResult.EXPECTED.size():
		result.counters[index] = RealPipelineResult.EXPECTED[index]
	result.counters[RealPipelineResult.Counter.REUSED] = 2040
	result.warmup_ticks = 300
	result.measured_ticks = 3600
	result.logic_samples = 1800
	result.logic_usec_max = 7000
	result.distance = 557.0
	result.peak_abs_x = 38.0
	result.look_radians = 1.44
	return result


func test_idle_pipeline_and_incomplete_window_cannot_pass() -> void:
	assert_array(RealPipelineResult.new().failures()).is_not_empty()
	var result: RealPipelineResult = _valid_result()
	result.measured_ticks = 3599
	assert_array(result.failures()).contains(["incomplete physics window"])
	result.measured_ticks = 3600
	result.warmup_ticks = 299
	assert_array(result.failures()).contains(["incomplete physics window"])


func test_exact_cpu_and_memory_limits_accept_but_one_over_fails() -> void:
	var result: RealPipelineResult = _valid_result()
	result.memory_delta = 1024 * 1024
	assert_array(result.failures()).is_empty()
	result.memory_delta += 1
	assert_array(result.failures()).contains(["static memory exceeds 1 MiB"])
	result.memory_delta = 0
	result.logic_usec_max = 7001
	assert_array(result.failures()).contains(["logic sampling or M1 7000 us budget failed"])
	result.logic_usec_max = 7000
	result.logic_samples = 1799
	assert_array(result.failures()).is_not_empty()


func test_one_orphan_fails_while_activity_remains_valid() -> void:
	var result: RealPipelineResult = _valid_result()
	result.objects_delta = 1
	result.orphans_delta = 1
	assert_array(result.failures()).is_equal(["object/node/resource/orphan growth"])


func test_damage_completions_and_pool_reuse_are_required() -> void:
	var result: RealPipelineResult = _valid_result()
	result.counters[RealPipelineResult.Counter.SIGNAL_DAMAGE] -= 6000
	assert_array(result.failures()).is_not_empty()
	result = _valid_result()
	result.counters[RealPipelineResult.Counter.RESOLVED] -= 1
	assert_array(result.failures()).is_not_empty()
	result = _valid_result()
	result.counters[RealPipelineResult.Counter.REUSED] = 0
	assert_array(result.failures()).contains(["visual slots were not reused"])


func test_diagnostics_and_unreleased_work_fail_acceptance() -> void:
	var result: RealPipelineResult = _valid_result()
	result.configuration_errors = 1
	assert_array(result.failures()).contains(["pipeline diagnostics are nonzero"])
	result = _valid_result()
	result.dropped = 1
	assert_array(result.failures()).is_not_empty()
	result = _valid_result()
	result.refusals = 1
	assert_array(result.failures()).is_not_empty()
	result = _valid_result()
	result.live_contexts = 1
	assert_array(result.failures()).is_not_empty()
	result = _valid_result()
	result.visual_occupancy_delta = 1
	assert_array(result.failures()).is_not_empty()


func test_graphical_fps_is_separate_from_headless_activity() -> void:
	var result: RealPipelineResult = _valid_result()
	assert_array(result.failures()).is_empty()
	result.graphical = true
	result.frame_fps_mean = 59.999
	assert_array(result.failures()).contains(["graphical mean FPS below 60"])
	result.frame_fps_mean = 60.0
	assert_array(result.failures()).is_empty()
