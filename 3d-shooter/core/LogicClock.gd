class_name LogicClock
extends RefCounted
## Делитель физического тика (60 Гц) в логический (30 Гц).
## Чистый класс без зависимостей от сцены: GameLoop лишь вызывает advance()
## один раз за физический тик. Счётчики — логическое время, а не номер кадра.

const PHYSICS_TICKS_PER_LOGIC_TICK: int = 2

var physics_tick: int = 0
var logic_tick: int = 0
var _phase: int = 0


## Продвигает часы на один физический тик.
## Возвращает true, если на этом тике должен выполниться логический тик.
func advance() -> bool:
	physics_tick += 1
	_phase += 1
	if _phase < PHYSICS_TICKS_PER_LOGIC_TICK:
		return false
	_phase = 0
	logic_tick += 1
	return true


func reset() -> void:
	physics_tick = 0
	logic_tick = 0
	_phase = 0
