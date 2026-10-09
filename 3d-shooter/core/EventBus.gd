extends Node
## Глобальная шина событий (autoload EventBus).
## Только переходы состояния забега, биома и комнаты. Высокочастотные боевые
## события сюда не идут: они живут в EffectHost/EffectRunner и кольцевых буферах.
## Подписчики (UI, VFX, аудио) не меняют состояние игры.

@warning_ignore("unused_signal")
signal run_started(run_seed: int)
@warning_ignore("unused_signal")
signal run_ended(victory: bool)
@warning_ignore("unused_signal")
signal biome_changed(biome_index: int)
@warning_ignore("unused_signal")
signal room_entered(room_id: int)
@warning_ignore("unused_signal")
signal room_cleared(room_id: int)
@warning_ignore("unused_signal")
signal boss_spawned(boss_id: int)
