extends Node
## Центральный цикл (autoload GameLoop).
## Физический тик 60 Гц приходит из _physics_process; каждый второй физический
## тик GameLoop испускает logic_tick (30 Гц) для FSM, кулдаунов, EffectRunner,
## DamagePipeline и WaveDirector. Своей логики не содержит: счёт ведёт LogicClock.
##
## Приоритет обработки поднят, чтобы логический тик шёл после всех
## физических обработчиков этого тика (контроллер, hitscan) и видел их события.

signal logic_tick(tick: int)

const EXPECTED_PHYSICS_TICKS_PER_SECOND: int = 60
const PHYSICS_PROCESS_PRIORITY: int = 1000

var _clock: LogicClock = LogicClock.new()


func _ready() -> void:
	process_physics_priority = PHYSICS_PROCESS_PRIORITY
	if Engine.physics_ticks_per_second != EXPECTED_PHYSICS_TICKS_PER_SECOND:
		push_error("GameLoop: physics_ticks_per_second = %d, ожидается %d" % [
			Engine.physics_ticks_per_second, EXPECTED_PHYSICS_TICKS_PER_SECOND])


func _physics_process(_delta: float) -> void:
	if _clock.advance():
		logic_tick.emit(_clock.logic_tick)


func get_physics_tick() -> int:
	return _clock.physics_tick


func get_logic_tick() -> int:
	return _clock.logic_tick


## Сбрасывает логическое время (начало забега или комнаты).
func reset_clock() -> void:
	_clock.reset()
