class_name RealPipelineResult
extends RefCounted
## Acceptance policy for the active movement/shot/counter fixture.

enum Counter { SHOTS, TRACES, HITS, RESOLVED, TARGET_DAMAGE, SIGNAL_DAMAGE,
	DASH, SLIDE, DOUBLE_JUMP, LANDINGS, RESOLVED_LANDINGS, MOBILITY_STEPS,
	SHOT_STEPS, GROUND_JUMPS, MUZZLES, IMPACTS, MARKS, EXPIRED, REUSED,
	EFFECT_ACCEPTED, EFFECT_PROCESSED, EFFECT_INSPECTED, EFFECT_ACTIONS,
	EFFECT_CONDITION, EFFECT_COOLDOWN, EFFECT_DEFERRED,
	EFFECT_COUNTER_0, EFFECT_COUNTER_1, EFFECT_COUNTER_2, EFFECT_COUNTER_3, COUNT }

const WARMUP_TICKS: int = 300
const MEASURE_TICKS: int = 3600
const MEMORY_LIMIT: int = 1024 * 1024
const LOGIC_LIMIT_USEC: int = 7000
const EXPECTED: PackedInt64Array = [120, 960, 960, 120, 5760000, 5760000,
	30, 15, 15, 15, 15, 1800, 1800, 15, 120, 960, 960, 2040, 2040,
	960, 960, 3840, 2160, 960, 720, 120, 960, 1920, 0, 720]

var counters: PackedInt64Array = PackedInt64Array()
var warmup_ticks: int = 0
var measured_ticks: int = 0
var objects_delta: int = 0
var nodes_delta: int = 0
var resources_delta: int = 0
var orphans_delta: int = 0
var memory_delta: int = 0
var logic_samples: int = 0
var logic_usec_sum: int = 0
var logic_usec_max: int = 0
var phase_steps: int = 0
const PHASE_COUNT: int = 3  # resolver, effects, mobility; mirrors Sandbox.PHASE_COUNT
var phase_usec_sum: PackedInt64Array = PackedInt64Array()
var phase_usec_max: PackedInt64Array = PackedInt64Array()
var phase_usec_p99: PackedInt64Array = PackedInt64Array()
var distance: float = 0.0
var peak_abs_x: float = 0.0
var look_radians: float = 0.0
var configuration_errors: int = 0
var dropped: int = 0
var refusals: int = 0
var stale_landings: int = 0
var no_op_traces: int = 0
var kills: int = 0
var pending_shots: int = 0
var pending_landings: int = 0
var pending_effects: int = 0
var stale_effects: int = 0
var live_contexts: int = 0
var visual_occupancy_delta: int = 0
var graphical: bool = false
var frame_fps_mean: float = 0.0


func _init() -> void:
	counters.resize(Counter.COUNT)
	phase_usec_sum.resize(PHASE_COUNT)
	phase_usec_max.resize(PHASE_COUNT)
	phase_usec_p99.resize(PHASE_COUNT)


## Called only after monitor capture; diagnostic arrays/strings are cold output.
func failures() -> PackedStringArray:
	var out := PackedStringArray()
	if warmup_ticks != WARMUP_TICKS or measured_ticks != MEASURE_TICKS:
		out.append("incomplete physics window")
	for index: int in EXPECTED.size():
		if counters[index] != EXPECTED[index]:
			out.append("activity counter %d: got %d expected %d" % [index, counters[index], EXPECTED[index]])
	if counters[Counter.REUSED] <= 0:
		out.append("visual slots were not reused")
	if objects_delta != 0 or nodes_delta != 0 or resources_delta != 0 or orphans_delta != 0:
		out.append("object/node/resource/orphan growth")
	if memory_delta > MEMORY_LIMIT:
		out.append("static memory exceeds 1 MiB")
	if logic_samples != MEASURE_TICKS / 2 or logic_usec_max > LOGIC_LIMIT_USEC:
		out.append("logic sampling or M1 7000 us budget failed")
	# Phases are timed inside the same logic_tick emission, so together they cannot exceed it.
	var phase_total: int = 0
	for phase: int in PHASE_COUNT:
		phase_total += phase_usec_sum[phase]
	if (phase_steps != MEASURE_TICKS / 2) or (phase_total > logic_usec_sum):
		out.append("phase timing does not cover the measured logic ticks")
	if distance <= 450.0 or peak_abs_x > 45.0 or look_radians <= 0.0:
		out.append("movement/look activity or fixture bounds failed")
	if configuration_errors != 0 or dropped != 0 or refusals != 0 or stale_landings != 0:
		out.append("pipeline diagnostics are nonzero")
	if no_op_traces != 0 or kills != 0 or pending_shots != 0 or pending_landings != 0 \
			or live_contexts != 0 or visual_occupancy_delta != 0 or pending_effects != 0 or stale_effects != 0:
		out.append("pipeline is inactive, incomplete or not quiescent")
	if graphical and frame_fps_mean < 60.0:
		out.append("graphical mean FPS below 60")
	return out
