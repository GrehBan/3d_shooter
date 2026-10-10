# Отложенные доработки (follow-up)

Небольшие известные долги, которые не вошли в текущий шаг. Каждый пункт закрывается
отдельным PR с тестом.

- **StatBlock.set_state: проверка типов полей (Zero-Trust).** Типизированные присваивания
  `var data: PackedInt32Array = state.get(...)` и `int(state.get(...))` при значении другого
  типа из испорченного сейва (Array, String, null) падают с ошибкой выполнения вместо
  `return false`. Сделать как в `HandlePool.set_state`: проверять `typeof` до присваивания
  (`TYPE_INT`, `TYPE_PACKED_INT32_ARRAY`, `TYPE_PACKED_INT64_ARRAY`, `TYPE_PACKED_BYTE_ARRAY`)
  и добавить в тесты случаи с неверными типами. Найдено на ревью M1a шага 5.
- **Python-модели эталонов прошлых golden-тестов вне репозитория.** Эталоны
  `SeededRngGoldenTest`, `FixedGoldenTest`, `StatBlockGoldenTest` и `HitEventQueueGoldenTest`
  посчитаны моделями, которые не сохранены в репозитории. Восстановить модели в
  `3d-shooter/tests/tools/` (по образцу `acp_ref.py`) и указать путь в шапке каждого теста.
