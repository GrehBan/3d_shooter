class_name DamagePayload
extends RefCounted
## Контракт записи урона (GDD §9, постулат 3). Сама запись не объект, а слот
## в DamagePayloadBuffer: поля лежат в плотных массивах буфера. Здесь только
## словарь значений, общий для логики и визуала.
##
## Поля записи:
##   source, target, attack_context — handle (int64, см. StatBlock);
##   amount — урон ×1000 в int64 (умножается на множители, Int32 мало);
##   element — Element; tags — 64-битная маска тегов контента;
##   flags — битовая маска Flag; phase — текущая фаза DamagePipeline (M2).

## Фазы конвейера урона: Base → Add → Multiply → Element → Crit → Mitigation → Apply → PostHit.
enum Phase { BASE, ADD, MULTIPLY, ELEMENT, CRIT, MITIGATION, APPLY, POST_HIT }

## Элементы (GDD §5). NONE — физический урон.
enum Element { NONE, ELECTRIC, FIRE, ICE, ACID }

## Флаги записи (битовая маска).
enum Flag {
	CRIT = 1 << 0,  ## критическое попадание
	DOT = 1 << 1,  ## периодический урон (горение и т.п.)
	SECONDARY = 1 << 2,  ## вторичный удар графа атаки (цепь, взрыв)
}

const NO_HANDLE: int = -1
