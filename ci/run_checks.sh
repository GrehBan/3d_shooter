#!/usr/bin/env bash
# Полный прогон проверок проекта: импорт, проверка скриптов, тесты gdUnit4, бенчмарки
# regress.gd, real_pipeline и status_pipeline.
# Используется в CI и локально. Запуск из корня репозитория:
#   GODOT=/путь/к/godot ci/run_checks.sh
# Код выхода ненулевой, если упал любой шаг или в выводе Godot есть ошибка скрипта.
set -euo pipefail

GODOT="${GODOT:?укажите путь к исполняемому файлу Godot в переменной GODOT}"
PROJECT_DIR="3d-shooter"
LOG_DIR="${LOG_DIR:-ci-logs}"
SCRIPT_ERROR_PATTERN='SCRIPT ERROR|Parse Error|Failed to load script|Compile Error'
# Godot может зависнуть после внутренней ошибки скрипта: каждый шаг ограничен по времени.
STEP_TIMEOUT="${STEP_TIMEOUT:-600}"

mkdir -p "$LOG_DIR"

# Падает, если в логе есть ошибка загрузки или разбора скрипта.
check_script_errors() {
	local step="$1" log="$2"
	if grep -E -n "$SCRIPT_ERROR_PATTERN" "$log"; then
		echo "::error::$step: в выводе Godot есть ошибки скриптов (см. $log)"
		exit 1
	fi
}

# Запускает Godot, пишет лог и проверяет код выхода и ошибки скриптов.
run_step() {
	local step="$1"
	shift
	local log="$LOG_DIR/$step.log"
	echo "::group::$step"
	set +e
	timeout "$STEP_TIMEOUT" "$GODOT" --headless --path "$PROJECT_DIR" "$@" < /dev/null 2>&1 | tee "$log"
	local code=${PIPESTATUS[0]}
	set -e
	echo "::endgroup::"
	if [[ $code -eq 124 ]]; then
		echo "::error::$step: Godot не завершился за $STEP_TIMEOUT с (см. $log)"
		exit 1
	fi
	if [[ $code -ne 0 ]]; then
		echo "::error::$step: Godot завершился с кодом $code (см. $log)"
		exit "$code"
	fi
	check_script_errors "$step" "$log"
	echo "$step: OK"
}

"$GODOT" --version

# The real pipeline keeps the synthetic benchmark independent and unchanged.
run_real_pipeline() {
	run_step real_pipeline --fixed-fps 60 res://tests/perf/RealPipelineBenchmark.tscn
	local log="$LOG_DIR/real_pipeline_leak.log"
	echo "::group::real_pipeline_leak"
	set +e
	timeout "$STEP_TIMEOUT" "$GODOT" --headless --path "$PROJECT_DIR" --fixed-fps 60 \
		res://tests/perf/RealPipelineBenchmark.tscn -- --inject-leak < /dev/null 2>&1 | tee "$log"
	local code=${PIPESTATUS[0]}
	set -e
	echo "::endgroup::"
	check_script_errors real_pipeline_leak "$log"
	if [[ $code -ne 1 ]] \
		|| ! grep -q 'allocations: objects=+1 nodes=+0 resources=+0 orphans=+1' "$log" \
		|| ! grep -q 'actions: shots=120 traces=960 hits=960 resolved=120 damage=5760000 signal_damage=5760000' "$log" \
		|| ! grep -q 'effects: accepted=960 processed=960 inspected=3840 actions=2040 condition=960 cooldown=840 deferred=0 counters=960,1920,0,360 pending=0' "$log" \
		|| ! grep -q 'leak_cleanup: objects=+0 orphans=+0' "$log" \
		|| ! grep -q '^REAL_PIPELINE FAIL: object/node/resource/orphan growth$' "$log" \
		|| [[ $(grep -c '^REAL_PIPELINE FAIL:' "$log") -ne 1 ]]; then
		echo "::error::real_pipeline_leak: expected one detected and cleaned orphan, exit 1 (see $log)"
		exit 1
	fi
	echo "real_pipeline_leak: OK (expected rejection and cleanup)"
	log="$LOG_DIR/real_pipeline_unknown_option.log"
	set +e
	timeout "$STEP_TIMEOUT" "$GODOT" --headless --path "$PROJECT_DIR" \
		res://tests/perf/RealPipelineBenchmark.tscn -- --unknown-option < /dev/null > "$log" 2>&1
	code=$?
	set -e
	check_script_errors real_pipeline_unknown_option "$log"
	if [[ $code -ne 2 ]] || ! grep -q '^REAL_PIPELINE SETUP ERROR: unknown option: --unknown-option$' "$log"; then
		echo "::error::real_pipeline_unknown_option: expected setup rejection, exit 2 (see $log)"
		exit 1
	fi
	echo "real_pipeline_unknown_option: OK"
}

# M2.3a profile 40 targets + 1 source: whole logic tick <= 7000 us, no allocations, exact
# deterministic status workload; the injected leak run must be rejected.
STATUS_ACTIVITY='activity: hits=14400 pulses=4800 statuses_applied=11520 pulse_damage=960000 effect_events=19200 effect_actions=21000 active=40 kills=0'
run_status_pipeline() {
	run_step status_pipeline --fixed-fps 60 res://tests/perf/StatusPipelineBenchmark.tscn
	if ! grep -q "$STATUS_ACTIVITY" "$LOG_DIR/status_pipeline.log"; then
		echo "::error::status_pipeline: status workload differs from the expected activity (see $LOG_DIR/status_pipeline.log)"
		exit 1
	fi
	local log="$LOG_DIR/status_pipeline_leak.log"
	echo "::group::status_pipeline_leak"
	set +e
	timeout "$STEP_TIMEOUT" "$GODOT" --headless --path "$PROJECT_DIR" --fixed-fps 60 \
		res://tests/perf/StatusPipelineBenchmark.tscn -- --inject-leak < /dev/null 2>&1 | tee "$log"
	local code=${PIPESTATUS[0]}
	set -e
	echo "::endgroup::"
	check_script_errors status_pipeline_leak "$log"
	if [[ $code -ne 1 ]] \
		|| ! grep -q 'allocations: objects=+1 nodes=+0 resources=+0 orphans=+1' "$log" \
		|| ! grep -q "$STATUS_ACTIVITY" "$log" \
		|| ! grep -q 'leak_cleanup: objects=+0 orphans=+0' "$log" \
		|| ! grep -q '^STATUS_PIPELINE FAIL: object/node/resource/orphan growth$' "$log" \
		|| [[ $(grep -c '^STATUS_PIPELINE FAIL:' "$log") -ne 1 ]]; then
		echo "::error::status_pipeline_leak: expected one detected and cleaned orphan, exit 1 (see $log)"
		exit 1
	fi
	echo "status_pipeline_leak: OK (expected rejection and cleanup)"
}

# gdUnit4 rotates old reports itself, but on this Windows/OneDrive checkout it fails to
# remove the emptied report directories and floods the log with "Delete ... failed". Start
# from an empty report directory instead; reports are build output and ignored by git.
run_tests() {
	rm -rf "${PROJECT_DIR:?}/reports"
	run_step tests -s addons/gdUnit4/bin/GdUnitCmdTool.gd --ignoreHeadlessMode --add res://tests/
}

case "${1:-all}" in
	import)
		run_step import --import
		;;
	scripts)
		run_step scripts -s res://tests/check_scripts.gd
		;;
	tests)
		run_tests
		;;
	regress)
		run_step regress --fixed-fps 60 -s res://tests/perf/regress.gd
		;;
	real_pipeline)
		run_real_pipeline
		;;
	status_pipeline)
		run_status_pipeline
		;;
	all)
		run_step import --import
		run_step scripts -s res://tests/check_scripts.gd
		run_tests
		run_step regress --fixed-fps 60 -s res://tests/perf/regress.gd
		run_real_pipeline
		run_status_pipeline
		;;
	*)
		echo "Использование: GODOT=... ci/run_checks.sh [import|scripts|tests|regress|real_pipeline|status_pipeline|all]" >&2
		exit 2
		;;
esac
