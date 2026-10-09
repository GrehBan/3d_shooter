extends Node
## Центральный цикл (autoload GameLoop).
## Физический тик 60 Гц приходит из _physics_process; каждый второй физический
## тик GameLoop испускает logic_tick (30 Гц) для FSM, кулдаунов, EffectRunner,
## DamagePipeline и WaveDirector. Своей логики не содержит: счёт ведёт LogicClock.
##
## Приоритет обработки поднят, чтобы логический тик шёл после всех
## физических обработчиков этого тика (контроллер, hitscan) и видел их события.
##
## process_mode намеренно остаётся PROCESS_MODE_INHERIT (по умолчанию):
## при паузе дерева логический тик останавливается вместе с физикой.
## Не менять на ALWAYS, иначе кулдауны и эффекты пойдут на паузе.

signal logic_tick(tick: int)

const EXPECTED_PHYSICS_TICKS_PER_SECOND: int = 60
const PHYSICS_PROCESS_PRIORITY: int = 1000

var _clock: LogicClock = LogicClock.new()
var _last_logic_tick_usec: int = 0


func _ready() -> void:
	process_physics_priority = PHYSICS_PROCESS_PRIORITY
	if Engine.physics_ticks_per_second != EXPECTED_PHYSICS_TICKS_PER_SECOND:
		push_error("GameLoop: physics_ticks_per_second = %d, ожидается %d" % [
			Engine.physics_ticks_per_second, EXPECTED_PHYSICS_TICKS_PER_SECOND])


func _physics_process(_delta: float) -> void:
	if _clock.advance():
		var start_usec: int = Time.get_ticks_usec()
		logic_tick.emit(_clock.logic_tick)
		_last_logic_tick_usec = Time.get_ticks_usec() - start_usec


func get_physics_tick() -> int:
	return _clock.physics_tick


func get_logic_tick() -> int:
	return _clock.logic_tick


## Длительность последнего логического тика в микросекундах (все подписчики
## logic_tick). Только метрика для профилирования и бенчмарка: в логику не идёт.
func get_last_logic_tick_usec() -> int:
	return _last_logic_tick_usec


## Сбрасывает логическое время (начало забега или комнаты).
func reset_clock() -> void:
	_clock.reset()
