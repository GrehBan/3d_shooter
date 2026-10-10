class_name EffectTrigger
extends RefCounted
## Словарь триггеров и фаз резолва эффектов (GDD §5, «Trigger → Condition → Action»).
##
## Trigger — событие, на которое подписан эффект карточки или модификатора элиты.
## Phase — порядок резолва эффектов одного триггера:
##   PRE  — меняет событие до основных реакций (например, удваивает урон выстрела);
##   MAIN — основные реакции на событие;
##   POST — реакции на результат (например, цепочки on-kill после смерти цели).
## Не путать с DamagePayload.Phase: та описывает фазы конвейера урона
## (Base → … → PostHit), а EffectTrigger.Phase — очерёдность реакций на триггер.

enum Trigger {
	ON_FIRE,
	ON_HIT,
	ON_CRIT,
	ON_KILL,
	ON_ATTACK_RESOLVED,
	ON_RELOAD,
	ON_EMPTY_MAG,
	ON_DASH,
	ON_SLIDE,
	ON_JUMP,
	ON_LAND,
	ON_DAMAGED,
	ON_SHIELD_BREAK,
	ON_STATUS_APPLIED,
	ON_ABILITY_USED,
	ON_ROOM_START,
	ON_ROOM_CLEAR,
	PERIODIC,
}

enum Phase { PRE, MAIN, POST }

const TRIGGER_COUNT: int = 18
