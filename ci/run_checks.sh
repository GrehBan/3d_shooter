#!/usr/bin/env bash
# Полный прогон проверок проекта: импорт, проверка скриптов, тесты gdUnit4, бенчмарк regress.gd.
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

case "${1:-all}" in
	import)
		run_step import --import
		;;
	scripts)
		run_step scripts -s res://tests/check_scripts.gd
		;;
	tests)
		run_step tests -s addons/gdUnit4/bin/GdUnitCmdTool.gd --ignoreHeadlessMode --add res://tests/
		;;
	regress)
		run_step regress --fixed-fps 60 -s res://tests/perf/regress.gd
		;;
	all)
		run_step import --import
		run_step scripts -s res://tests/check_scripts.gd
		run_step tests -s addons/gdUnit4/bin/GdUnitCmdTool.gd --ignoreHeadlessMode --add res://tests/
		run_step regress --fixed-fps 60 -s res://tests/perf/regress.gd
		;;
	*)
		echo "Использование: GODOT=... ci/run_checks.sh [import|scripts|tests|regress|all]" >&2
		exit 2
		;;
esac
