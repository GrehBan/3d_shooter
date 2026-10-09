class_name Damageable
extends RefCounted
## Контракт «что можно ранить» (GDD §9; красный флаг CLAUDE.md о логике урона в Area3D).
##
## Ранимая сущность — это handle в StatBlock, а не узел. Визуальный слой
## связывает коллайдер (CollisionObject3D: хитбокс врага, ломаемый ящик) с
## handle через метаданные и больше ничего не знает о бое. При попадании
## физика читает handle_of(collider) и кладёт событие в HitEventQueue; урон
## считает логика на логическом тике. Коллайдер не хранит HP и не меняет статы.
##
## Без аллокаций в бою: первый attach() вызывается при создании пула узлов
## (запись метаданных создаётся один раз), detach() не удаляет запись, а пишет
## в неё NO_HANDLE. Повторные attach()/detach() того же узла при спавне из пула
## и возврате в пул только перезаписывают значение.

const META_KEY: StringName = &"rc_entity_handle"
const NO_HANDLE: int = -1


## Привязывает коллайдер к сущности. Вызывается визуальным слоем при спавне из пула.
static func attach(collider: Object, handle: int) -> void:
	collider.set_meta(META_KEY, handle)


## Отвязывает коллайдер при возврате узла в пул. Запись метаданных остаётся.
static func detach(collider: Object) -> void:
	collider.set_meta(META_KEY, NO_HANDLE)


## Handle сущности коллайдера или NO_HANDLE, если коллайдер не ранимый.
static func handle_of(collider: Object) -> int:
	if collider == null or not collider.has_meta(META_KEY):
		return NO_HANDLE
	return int(collider.get_meta(META_KEY))
