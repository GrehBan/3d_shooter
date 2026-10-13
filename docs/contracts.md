# Контракты ядра боя (M1a)

Справочник по чистым классам логики боя: кто их вызывает, что гарантировано и что
запрещено. Код лежит в `3d-shooter/` (`res://`). Реализованные классы ядра здесь — `RefCounted` или
`Resource`; это проверяет `tests/unit/LogicIsolationTest.gd`. Исключения (`GameLoop`,
`EventBus`, физические `FPSController` и `HitscanWeapon`) перечислены в его allowlist с причиной.
§7 описывает реализованный минимальный пакет 3 M1 в `codex/m1-current-plan`.
На 2026-10-13 runtime пакета 3 принят локально: независимый обзор полного diff
`b73a4be` → `9a4fead` дал PASS без блокеров, обязательные CI Linux/Windows для
`9a4feade15e98d6c870f89163e659572b7ecb9a0` завершились SUCCESS.
Текущая интеграция 2026-10-13: зависимости PR #8–#10 слиты; #11 подготовлен к
публикации обновлённого HEAD и fresh required CI, ещё не слит. Closing docs пакета3
приняты в `d9f1a53`; пакет4 принят отдельно в `codex/m1-visual-pools`, PR #12 не слит.
В этом checkout нет runtime пакета4; пакет5 и полный M2 не реализованы, вся M1 не завершена.
Прежние publication/status ниже — история соответствующих версий;
актуальные факты — [журнал интеграции PR](notes/pr-integration-log.md).

## 1. Общие правила

### Время и порядок внутри кадра

* **Физический тик, 60 Гц** (`_physics_process`): FPS-контроллер, Jolt, hitscan, снаряды.
  Общий событийный транспорт — `HitEventQueue.push()`; здесь также вызывается
  `MovementAbilities.try_activate()`. Для hitscan-дробовика пакета 3 оговорено отдельное
  weapon-specific исключение: полная запись выстрела в ShotBatch (§7),
  а не поштучные `HitEventQueue.push()` для дробин.
* **Логический тик, 30 Гц**: `GameLoop` испускает `logic_tick(tick)` на каждом втором
  физическом тике. У `GameLoop` `process_physics_priority = 1000`, поэтому логика идёт после
  всех физических обработчиков этого тика и видит их события: попадание raycast-hitscan
  из `_physics_process` попадает в тот же тик. Сигналы контактов Jolt (`body_entered` и т. п.
  у снарядов и зон) приходят после шага физики, поэтому логика видит их только в следующем
  физическом тике. Существующий событийный конвейер логического тика
  вызывает `HitEventQueue.prepare()` → обход → `clear()`, разрешает `AttackContext`, обходит
  `EffectHost`, применяет `DamagePayloadBuffer` к `StatBlock`, вызывает
  `MovementAbilities.regen_energy()`.
  M1 weapon-path использует один Sandbox composition-root subscriber:
  ShotBatch resolver → `MobilityRuntime.logic_step(tick)` (landing damage → regen).
  Его порядок и coordinated reset описаны в §7; legacy-конвейер/синтетика сохраняются.
* **Кадр** (`_process`): только визуал. В логику не пишет.
* Логическое время — номер логического тика из `GameLoop.get_logic_tick()`. Кулдауны
  считаются в логических тиках, а не в секундах или кадрах.

### Детерминизм

* Детерминированы целые и фиксированная точка ×1000 (`Fixed`), `SeededRng`, порядок
  событий после `HitEventQueue.prepare()`, решения `AttackContextPool`, порядок резолва
  `EffectHost`, применение урона к `StatBlock`. Одинаковые входы дают побитово одинаковый
  результат на любой платформе (golden-тесты идут в CI на Linux и Windows).
* Не детерминированы физика, движение и порядок колбэков Jolt: они передают в логику только
  handle сущностей и события.
* Детерминизм каждого буфера и пула гарантирован только при нулевых счётчиках ошибок
  конфигурации (см. ниже).
* ShotBatch канонизирует полные source/sequence, затем trace index (§7).
  Его integer resolver детерминирован для одинаковых завершённых записей выстрелов;
  физический raycast и input не приобретают побитовую гарантию.

### Аллокации

* Горячий путь (всё, что вызывается в физическом или логическом тике) не выделяет память:
  ни `new()`, ни временных `Array`/`Dictionary`/`String`. Проверяется тестами аллокаций
  каждого класса и бенчмарком `tests/perf/regress.gd`.
* Можно выделять память в конструкторах (ёмкости фиксируются при создании, при загрузке
  комнаты) и в `get_state()` / `set_state()` (сохранение и загрузка).

### Handle сущности

* Handle — `int64`: `generation · 65536 + index`. Хранить только в `PackedInt64Array` или `int`:
  после 32768 переиспользований слота значение выходит за пределы Int32.
* Выдаёт handle `StatBlock` (сущности) или `HandlePool` (контексты атак, записи эффектов).
  Поколение растёт при каждом освобождении слота; устаревший handle отвергается любым
  обращением, без ошибки в логе (запоздавшее попадание по умершему врагу — штатная ситуация).
* `NO_HANDLE` / `INVALID_HANDLE` = `-1`.

### Хранилища «по сущности»

`EffectHost` и `MovementAbilities` хранят данные по слоту сущности:

* слот = `handle % 65536`; ёмкость по хостам совпадает с ёмкостью `StatBlock`;
* слот помнит полный handle владельца; чтение по устаревшему handle даёт пустой результат;
* если слот занят устаревшим владельцем, которого не очистили при смерти, его данные
  снимаются лениво при первой записи сущности **более нового** поколения;
* запись по handle **более старого** поколения, чем у владельца слота, отказывает и не трогает
  живую сущность (отложенный эффект или прок, держащий handle убитой цели).

### Ошибки конфигурации

Переполнение очередей и пулов — ошибка подбора ёмкости, а не штатный режим:

* В существующих классах `push_error` пишется один раз до ближайшего `clear()` / `reset_counters()`;
  для `DamagePayloadBuffer` сброс уведомления также выполняет `reset_dropped_count()`.
  Отказ детерминированный, событие или запись отбрасывается;
* счётчик растёт на каждый отказ: `HitEventQueue.dropped_count()`,
  `DamagePayloadBuffer.dropped_count()`, `AttackContextPool.hit_set_overflows` и
  `capacity_refusals`, `EffectHost.capacity_refusals`, `LandingEventQueue.dropped_count()`;
* корректность и детерминизм гарантированы только при нулевых счётчиках; `regress.gd` и
  `CombatContractsGoldenTest` падают при ненулевых.
* Для ShotBatch (§7) отказ атомарен для всего запроса ДО принятия выстрела;
  диагностическое сообщение однократно до явного reset, счётчик растёт на каждый отказ.
  Ненулевые ошибки транспорта/пулов блокируют приёмку пакета.

Штатные ограничители игры (глубина цепи, бюджет ударов атаки, повторная цель в ветке) — не
ошибки: они отказывают без лога и считаются отдельно (`depth_refusals`, `budget_refusals`).

## 2. Классы

### Fixed (`core/Fixed.gd`)

Арифметика ×1000 для урона, статов, шансов и множителей.

* `mul(a, b)`, `div(a, b)`, `from_int`, `to_int`. Округление всегда к нулю:
  `mul(-1500, 333) = -499`.
* Диапазоны (assert в debug); `a`, `b` — сырые значения ×1000: `mul` требует
  |a·b| ≤ INT64_MAX; `div` требует |a| ≤ INT64_MAX / 1000 ≈ 9.22·10^15 сырых
  (≈9.22·10^12 целых единиц).
* Деление на 0 → результат 0 и `push_error`.

### SeededRng (`core/SeededRng.gd`)

Целочисленный xoshiro128**. Подпотоки (`substream(id)`) зависят только от исходного сида и id,
а не от того, сколько значений уже выдано. `range_int`, `chance_permille` (×1000),
`weighted_index`, `shuffle_int32` не выделяют память; `substream()` выделяет — не в бою.

### StatBlock (`combat/StatBlock.gd`)

Плотное хранилище статов сущностей (игрок, враги, ломаемое окружение).

* Статы: `HP, MAX_HP, SHIELD, MAX_SHIELD, ARMOR, ENERGY, MAX_ENERGY`, значения ×1000 в Int32:
  лимит ≈ 2.1 млн единиц (≈2.1 млн HP). Суммы урона и всё, что умножается на множители,
  считать в Int64 до записи в стат.
* 64-битная маска статусов на сущность.
* `allocate()` выдаёт индексы с нуля в детерминированном порядке; `release()` повышает
  поколение. При исчерпании ёмкости — `push_error` и `INVALID_HANDLE`.
* `get_state()` возвращает снимок; `set_state()` проверяет его типы и согласованность
  (Zero-Trust) до изменения состояния. Все восемь полей обязательны: `capacity`,
  `free_count`, `alive_count` — строго `int`; `data`, `generation`, `free` —
  `PackedInt32Array`; `status` — `PackedInt64Array`; `alive` — `PackedByteArray`.
  Строки, `float`, `bool`, обычные `Array`, `null` и пропущенные поля не приводятся к
  ожидаемым типам: отказ с `push_error` и `false`, прежнее состояние полностью сохранено.
  При верных типах проверяются ёмкость, размеры, счётчики, free-list, флаги и поколения.

### DamagePayload и DamagePayloadBuffer (`combat/`)

* `DamagePayload` — словарь: `Phase` (Base → Add → Multiply → Element → Crit → Mitigation →
  Apply → PostHit, фазы конвейера урона M2), `Element`, битовые `Flag`.
* `DamagePayloadBuffer` — кольцевой SoA-буфер записей урона. `source`, `target`,
  `attack_context`, `amount`, `tags` — Int64.
* FIFO: `push()` в хвост, `front_slot()` / `slot_at(i)` / `pop_front()` с головы.
* Переполнение: `push()` возвращает `INVALID_SLOT`, не меняет очередь и повышает
  `dropped_count()` на каждый отказ. `push_error` пишется ровно один раз до ближайшего
  `clear()` или `reset_dropped_count()`; успешный `push()` и `pop_front()` уведомление
  не сбрасывают, даже если очередь стала пустой.
* `clear()` очищает очередь и сбрасывает уведомление, сохраняя `dropped_count()`.
  `reset_dropped_count()` обнуляет счётчик и сбрасывает уведомление, сохраняя очередь,
  её голову, порядок FIFO и поля записей.
* **Аксессоры по слоту не проверяют его валидность**: чтение после `pop_front()` вернёт старые
  данные без ошибки. Обходить только через `front_slot()` или `slot_at(i)` для `i < count()`.

### Damageable (`combat/Damageable.gd`)

Граница визуала и логики. Коллайдер (хитбокс врага, ломаемый ящик) хранит только handle
сущности в метаданных и не считает урон.

* `attach(collider, handle)` — первый вызов при создании пула узлов (запись метаданных
  создаётся один раз); при спавне из пула — только перезапись.
* `detach(collider)` пишет `NO_HANDLE`, запись не удаляется: повторное использование узла
  не выделяет память.
* `handle_of(collider)` — что физика кладёт в `HitEventQueue`, либо в trace record
  ShotBatch для weapon-specific M1 hitscan (§7).

### HitEventQueue (`combat/HitEventQueue.gd`)

Существующий транспорт отдельных попаданий из физики для логического тика.
Mock/golden/synthetic используют его прежний контракт. Weapon-specific hitscan пакета 3
использует ShotBatch (§7): четыре поля и target-first sort этой очереди не сохраняют
идентичность полного выстрела и его trace-order. API, payload, сортировка и эталоны
`HitEventQueue` не меняются; shot identity/index не упаковываются в legacy payload.

* Физика: `push(source, target, kind, payload)`. Логика: `prepare()` → обход
  `get_*(i)` для `i < count()` → `clear()`.
* `prepare()` приводит события к **каноническому порядку**: сначала префикс (индекс слота цели,
  индекс слота источника, вид, младшие 17 бит payload), при равном префиксе — полные значения.
  Это не порядок по полным handle, но он полный и однозначный: одинаковый набор попаданий даёт
  одинаковую последовательность при любом порядке колбэков Jolt.
* **Детерминизм только при `dropped_count() == 0`**: при переполнении сохраняются первые
  пришедшие события, а их набор зависит от порядка колбэков.

### AttackContextPool (`effects/AttackContextPool.gd`)

Атака — дерево: корень на выстрел, дочерние контексты на вторичные удары.
Пакет 3 использует тот же API для sibling-child прямых дробин (§7), без изменения MAX_DEPTH.

* `open_root(source, hit_budget)`, `open_child(parent)`: глубина ≤ 4; бюджет ударов общий на
  дерево. `open_child` от уже закрытого родителя разрешён, пока дерево живо (отложенные
  эффекты), и невозможен после освобождения дерева.
* `try_register_hit(context, target)`: цель хранится полным handle; одна цель не поражается
  дважды в ветке (контекст и его предки), но может быть поражена в соседней ветке.
* `close(context)` возвращает `true` для последнего открытого контекста дерева — момент
  `OnAttackResolved`; дерево освобождается, все его handle становятся недействительными.
  Повторный `close()` отказывает.

### EffectTrigger и EffectHost (`effects/`)

* `EffectTrigger.Trigger` — события GDD (`ON_FIRE` … `PERIODIC`), `TRIGGER_COUNT` закреплён
  тестом. `EffectTrigger.Phase`: `PRE` меняет событие до основных реакций, `MAIN` — основные
  реакции, `POST` — реакции на результат (например, цепочки on-kill). **Это не
  `DamagePayload.Phase`**: та описывает фазы конвейера урона.
* `EffectHost` — подписки эффектов всех хостов на триггеры. `add_effect` / `remove_effect` /
  `clear_host` работают прямо в бою (спавн и смерть элит), без пересборки и аллокаций.
* Порядок резолва: фаза, затем priority по возрастанию, затем slot_index, effect_id и handle
  записи. Порядок освобождения записей в `clear_host` (новые первыми) — часть детерминизма.
* Чтение: `first(host, trigger)` → `next(index)` до `NO_ENTRY`; поля через `*_at(index)`.
  **`next()` и `*_at()` не проверяют индекс**: обходить только через `first()`/`next()`.
  Снимать эффект во время обхода того же списка можно только сохранив `next` заранее.

### MovementAbilityData и MovementAbilities (`player/`)

Логический контракт способностей движения; физика рывка, прыжка и скольжения — в FPS-контроллере (M1).

* `MovementAbilityData` — данные контента (вид, цена, кулдаун, земля/воздух); в бою не читается,
  параметры передаются в `grant()` явно.
* `grant` / `revoke` / `clear_entity` — без аллокаций, в бою. Повторный `grant` обновляет
  параметры, но не сбрасывает кулдаун.
* `try_activate(entity, kind, now_tick, in_air, stats)` вызывается из физического тика ради
  отзывчивости (буфер до логического тика добавил бы до 33 мс задержки рывка). Поэтому
  `ENERGY` меняется вне логического тика и **не входит в детерминированный контур**; само
  решение зависит только от логического `now_tick` и статов.
* Энергия — общий пул `StatBlock.ENERGY` (один заряд = 1000); `regen_energy(stats)` раз в
  логический тик.

## 3. Независимость логики и визуала

* Чистая логика боя хранит состояние и рассчитывает урон; физический адаптер передаёт ей
  handle сущностей (через `Damageable`) и события, не рассчитывая урон самостоятельно.
  Физический FPS-контроллер вправе вызывать существующий `MovementAbilities.try_activate()`
  из физического тика: этот API изменяет `ENERGY` вне детерминированного контура, как описано
  выше. Это не разрешает физическому адаптеру напрямую менять HP или рассчитывать урон.
* Визуал в `_process` получает handle и события (`EventBus`, сигналы узлов для локальной
  связи UI), не пишет в `StatBlock` и не вызывает логику урона.
* Логика не держит ссылок на узлы сцены и не наследует `Node`; `LogicIsolationTest` роняет CI
  при новом Node-классе в `core/`, `combat/`, `effects/` или `player/` без
  записи в allowlist.
* Сквозной `tests/golden/CombatContractsGoldenTest.gd` проверяет конвейер целиком:
  mock-дробовик → `Damageable` → `HitEventQueue` → `AttackContextPool` → `EffectHost` →
  `DamagePayloadBuffer` → `StatBlock`, плюс рывок `MovementAbilities`, с двумя порядками
  колбэков физики и эталоном из Python-модели `tests/tools/combat_contracts_ref.py`.

## 4. Эталонные модели

Эталоны golden-тестов считаются независимыми Python-моделями в `3d-shooter/tests/tools/`
(`seeded_rng_ref.py`, `fixed_ref.py`, `stat_block_ref.py`, `hit_event_queue_ref.py`,
`acp_ref.py`, `effect_host_ref.py`, `movement_ref.py`, `combat_contracts_ref.py`), запуск —
`python 3d-shooter/tests/tools/<модель>.py` из корня репозитория. Пути моделей указаны
в шапках соответствующих golden-тестов.

## 5. Физический адаптер FPSController (M1, пакет 1)

Исторический контракт пакета 1 ниже расширяется пакетом 2 в §6.

`player/FPSController.gd` наследует `CharacterBody3D` и не относится к чистому ядру
выше: хранит только физические данные движка и команды ввода. Состояние `GROUND` / `AIR`
обновляется после `move_and_slide()` по реальному `is_on_floor()`; контакт предыдущего
физического тика определяет допустимость обычного прыжка. Jolt, движение и эти состояния
не входят в гарантию побитового детерминизма. В пакете 1 контроллер не рассчитывает урон, не меняет
`StatBlock`, не вызывает способности и не подписывается на логический тик этого пакета.

* `set_move_input(Vector2)` задаёт сохраняемое направление: x — вправо, y — назад.
  Длина ограничивается единицей; аналоговый ввод меньшей длины сохраняется.
  Направление преобразуется ортонормированным мировым basis тела, поэтому yaw родителя
  учитывается, а положительный равномерный масштаб не меняет скорость в мировых м/с.
* `add_look_input(Vector2)` накапливает относительные пиксели до следующего физического
  тика. Тогда изменяются yaw тела и ограниченный pitch дочерней `Camera3D`; pitch
  не влияет на горизонтальное направление ходьбы. `_process` отсутствует.
* `set_jump_pressed(bool)` ставит запрос только на переходе false → true.
  Следующий физический тик потребляет запрос один раз. В воздухе запрос отбрасывается;
  удержание, повторные true и последующее приземление сами не создают нового прыжка.
* `set_hardware_input_enabled(bool)` переключает аппаратный ввод и очищает команды.
  Аппаратные события мыши/прыжка и `Input.get_vector()` используют тот же командный API
  и единственный физический путь, что и headless-драйвер. Mouse motion использует
  `screen_relative`; Escape освобождает курсор, левый клик вновь захватывает его.
* Команды принимаются только внутри дерева и вне паузы; векторы с NaN/Inf отвергаются.
  Режим узла — `PROCESS_MODE_INHERIT`. Пауза и потеря фокуса очищают запросы, сохраняя
  transform, velocity и физическое состояние. После паузы отложенного прыжка/поворота нет.

В headless DisplayServer не захватывает курсор: тест обработчика хранит намерение
захвата после события клика. В графическом режиме используется фактический mouse mode.
Тест явно вызывает input-обработчик и `Input.action_press()`; транспортировку событий
от ОС, реальный курсор и субъективное ощущение управления он не подтверждает.

Обычные настраиваемые exports физического слоя: скорость 8 м/с, импульс прыжка 5.5 м/с,
чувствительность 0.002 рад/пиксель, предел pitch 85°. Гравитация берётся из
`physics/3d/default_gravity` (по умолчанию 9.8 м/с²). Это стартовые параметры прототипа,
согласованные координатором, а не утверждённые балансные числа GDD или данные боевого
контента. Коллизии Sandbox: player layer 2, mask 1 (world); капсула radius 0.35 м,
height 1.8 м, камера на 0.65 м выше центра. Физика остаётся 60 Гц с интерполяцией,
`GameLoop` — 30 Гц. Создание узлов и ресурсов допускается только при загрузке.

Поддерживаемая конфигурация физического адаптера: вертикальное тело и его родители
вращаются только вокруг world-up (yaw), масштаб тела/предков положительный и равномерный.
Pitch задаётся только дочерней камерой. Наклонённые физические родители и неравномерный
масштаб не входят в поддерживаемую конфигурацию; произвольный affine transform не обещан.

`tests/unit/FPSControllerTest.gd` проверяет контакты реальных тел Jolt с допусками и
измеряет активное движение после прогрева. Эти проверки не подтверждают графическую
плавность, мышь на реальном дисплее или готовность всего M1.

## 6. M1: мобильность и приземление (пакет 2)

Принятые до реализации падения параметры: world peak центра тела → центр при AIR→GROUND,
целые mm через floor; raw урон ×1000 = `max(mm - 8000, 0) * 10`. Успешный dash отменяет
падение при разнице физических тиков 0..12 включительно. Slide edge в воздухе бесплатно
взводится на тот же срок; после move_and_slide подтверждённое приземление проверяет
скорость ≥4 м/с, совместимость, энергию/кулдаун, затем try_activate(in_air=false).
Только успех отменяет падение и начинает slide со следующего физического шага.
Удержание/echo не обновляют окно; pause/focus-out очищают prearm. FPS передаёт событие,
не считает урон и не меняет HP.

Минимальный чистый M1 DamageApply: shield-first; затем процентная броня, не расходуемая
уроном. ARMOR — процент ×1000 (10000=10%, 100000=100%), clamp 0..100000;
`remaining * (100000 - armor) / 100000` с целочисленным trunc-to-zero, HP clamp ≥0.
Промежуточные значения int64; процент считается точным quotient/remainder:
`(remaining/100000)*retained + (remaining%100000)*retained/100000`, без переполнения
для любого неотрицательного int64 raw урона. Высота насыщается до
`INT64_MAX/10 + 8000 = 922337203685485580` mm перед умножением на 10.
Полный M2 DamagePipeline, элементы, карточки и реген щита
не входят в этот пакет; существующие synthetic fixtures/checksum не меняются.

`bind_mobility(runtime, entity)` — новый runtime reference либо новый полный handle
(включая новое поколение) начинает lifecycle: очищает ввод, velocity, dash/slide,
prearm, peak/эпизод и лимит двойного прыжка. Same runtime + same full handle — idempotent
NO-OP: сохраняет velocity/peak/episode, air-used, active ability и queued input. Nullable
runtime или INVALID_HANDLE явно отсоединяет и очищает физическое состояние/ввод.
Устаревший StatBlock
handle автоматически отсоединяется на следующем физическом шаге; regrant способностей
не сбрасывает физический лимит. Воздушный прыжок сбрасывается только после реального
AIR→GROUND move_and_slide; стена/потолок не сбрасывают. Ground jump бесплатен.

Edge API `set_dash_pressed`/`set_slide_pressed` совместим с `set_jump_pressed`;
отказ потребляет запрос без платы/кулдауна и может уступить следующему действию.
Приоритет dash→slide→jump, максимум одно успешное действие в физическом тике.
Dash/slide несовместимы и блокируют прыжок, пока активны. Dash фиксирует normalized
world input direction (или forward при нуле), 24 м/с ровно 9 шагов; gravity/vy сохраняются.
Slide фиксирует world direction и фактическую горизонтальную скорость ≥4 м/с,
убывает на 5 м/с², максимум 36 шагов; потеря земли прекращает slide, капсула не меняется.
Входной `.tres` читается только при cold Registry grant; цены/cooldown/flags копируются
в MovementAbilities: dash 1000/6/ground+air, slide 500/6/ground, double jump 1000/0/air.

Sandbox — единственный composition-root subscriber на GameLoop.logic_tick для своего
общего MobilityRuntime; контроллеры не подписываются. Runtime держит ссылки только на
чистые stores, без Node/time/float. На 30 Гц сначала drain landing events → DamageApply,
потом regen_energy 50 raw на entity (MAX_ENERGY=3000), то есть 1500 raw/с. logic_step
игнорирует duplicate/старый tick, поэтому повторный вызов не удваивает regen. Перед
GameLoop.reset_clock при повторном использовании runtime обязателен
`runtime.reset_clock(old_logic_tick)` с ТОЧНЫМ старым GameLoop.get_logic_tick(), включая
physics activation до первого logic_step. Этот явный room reset отбрасывает pending
landing events, сбрасывает dropped/diagnostic counters и duplicate logic guard;
MovementAbilities.rebase_clock сохраняет оставшийся cooldown `max(ready-old_now,0)`
с новым origin0, energy/grants/costs/flags и physical episode не меняются. Истёкший срок0;
ungranted остаётся ungranted. Последовательность реализованного пакета 2 Sandbox.reset_mobility_clock:
capture old GameLoop tick → runtime.reset_clock(old) → GameLoop.reset_clock().
Расширение composition root для пакета 3 добавляет reset shot resolver
до существующего mobility reset (§7); точный old tick и cooldown rebase сохраняются.
Новая комната может создать новый runtime. Обычный same-identity bind ничего не
отбрасывает и не сбрасывает; lifecycle нового entity отличается от room clock reset.

Cold MobilityRuntime.grant_content валидирует весь M1 preset ДО любого grant:
ровно три записи, по одному DASH/DOUBLE_JUMP/SLIDE; только эти kinds, cost/cooldown
0..StatBlock.VALUE_MAX (Int32), flags dash ground+air / double air-only / slide ground-only.
Invalid missing/duplicate/extra-kind/params/flags → false без частичных grants и без
изменения ранее выданных параметров/cooldown. Registry type+freeze сами по себе не
валидируют gameplay. Caller считает false конфигурационной ошибкой и не запускает
такую комнату (Sandbox пишет ясный push_error). Valid regrant сохраняет cooldown.
Если Registry не загрузил три записи или grant_content отклонил пресет, Sandbox
отключает process_mode своего корня (и унаследованную обработку всего поддерева),
не подписывается на logic_tick и удаляет возможную прежнюю подписку при abort.

LandingEventQueue — предвыделенный SoA FIFO ring полного int64 handle, mm, cancel flags.
Один event на подтверждённое приземление, consumer отвергает stale handle. При overflow
push=false, первый event сохраняется, каждый отказ увеличивает cumulative dropped;
один push_error до clear. clear сбрасывает события и report latch, не dropped;
reset_dropped_count сбрасывает только счётчик. Ненулевой dropped блокирует приёмку.
Физическое преобразование height→mm = буквальный floor без epsilon; значения binary
float непосредственно ниже границы остаются ниже (decimal 8.001 может дать 8000).
Сам resolver и Python golden получают целые mm и проверяют 7999/8000/8001 bit-exact.
Максимальная float height квантуется с cap выше; NaN/Inf/отрицательная высота дают 0.
Порядок входных событий от Jolt не обещан bit-exact; integer apply одинаков для одного
и того же последовательного event stream. Очередь не переносит HP-логику в физику.

## 7. M1: hitscan-дробовик и ShotBatch (пакет 3)

### Статус и границы

Договорённости подготовлены 2026-10-13 от `b73a4be701276373b3704b7f8c801a8815939872`.
Игровая семантика ратифицирована, значение 8 относится только к утверждённому
[пресету GDD](../gdd.md#принято-для-m1-минимальный-hitscan-дробовик--2026-10-13).
После независимого PASS уточнённого договора минимальные ShotBatch, WeaponData,
WeaponState, ShotResolver и физический HitscanWeapon реализованы в `res://weapons/`.
Их runtime принят локально по итоговому независимому PASS полного diff на `9a4fead`;
новая документационная запись проходит отдельное ревью. Доказательства и точная база —
в [журнале приёмки](notes/work-log.md#возобновление-работы-и-локальная-приёмка-runtime-пакета-3--2026-10-13).
Объём M1: проверенные данные оружия, input/physics adapter, минимальные чистые
transport/resolver и существующие stores/пулы/AttackContext. Полный M2 DamagePipeline,
EffectRunner, карточки и элементы не переносятся в пакет 3; synthetic fixtures,
legacy очереди и checksum `3032385286` сохраняются.

### WeaponData и атомарный транспорт

* `N` — число дробин из утверждённых immutable WeaponData, полностью проверенных
  при cold загрузке. Параметры пресета не читаются из изменяемого контента в бою.
  Число дробин, raw damage, дальность, рисунок/spread и cooldown валидируются до
  запуска комнаты; Registry freeze сам по себе не заменяет gameplay validation.
* `C_trace = max(N)` всех разрешённых в комнате пресетов, отдельно проверенный по
  явно заданным room trace/memory cap. `C_shots` — независимая ёмкость записей выстрелов.
  Пределы памяти, безопасные размеры массивов и ёмкости пулов валидируются при загрузке;
  универсальные числовые максимумы этим контрактом не назначаются.
* ShotBatch предвыделяется при загрузке: фиксированный stride `C_trace`, header
  с `trace_count = N` и ровно N результатов, включая промахи. Неиспользуемый хвост
  записи не читается. Каждый trace хранит stable index `0..N-1` и полный int64 target
  либо `NO_HANDLE`; header хранит безопасную shot identity, полный int64 source
  и монотонную sequence. Единственный room-owner allocator выдаёт для каждого полного
  source строго возрастающую, неповторяющуюся sequence для всех его оружий совместно.
  Identity = (room epoch, full source, sequence); переиспользование entity slot не стирает
  поколение source. Переполнение sequence/epoch не допускает wrap и отвергает запрос
  до acceptance, cooldown, ресурсов, VFX и трасс с тем же диагностическим контрактом.
* Полная запись публикуется атомарно: consumer видит только завершённые выстрелы.
  Канонический порядок — полный source, sequence, затем stable trace index;
  порядок колбэков/целей не меняет порядок дробин внутри выстрела.
* Invalid preset или невозможная room-конфигурация блокирует инициализацию комнаты.
  В бою отсутствие свободного слота или `N > C_trace` отвергает ВЕСЬ запрос до
  acceptance, cooldown, оплаты ресурсов, VFX и записи трасс. Отказ не оставляет
  частичной записи; усечение числа дробин и горячий resize запрещены.
  Диагностика — однократно до явного reset, накопительный счётчик — на каждый отказ;
  ненулевые ошибки конфигурации блокируют приёмку.

### Дробины, смерть и контексты

Один accepted shot открывает один root depth0, включая полный miss; hit-set root
остаётся пустым. Все N trace results обходятся по stable trace index.
Перед каждой дробиной resolver проверяет full target handle и `HP > 0`.
Stale/`NO_HANDLE`/`HP <= 0` — полный no-op ДО child, регистрации hit budget,
DamageApply, расхода щита и триггеров. `StatBlock.is_valid()` проверяет поколение,
а не HP; отдельная проверка живой цели обязательна. Death-policy принадлежит resolver,
не физике и не `DamageApply`; auto-release entity в DamageApply не добавляется.

Для живой цели создаётся отдельный sibling-child depth1 и регистрируется hit только
в нём через существующий `try_register_hit()`. Повторные дробины могут поражать
ту же живую цель в соседних ветвях; регистрация цели в root нарушила бы этот контракт.
Зарегистрированное живое попадание даёт `OnHit`, даже при нулевом HP damage из-за
щита/брони. Урон применяется минимальной M1 shield-first/armor политикой (§6);
`OnKill` — только переход HP>0→0. Apply и PostHit одной дробины полностью завершены
до проверки следующей, поэтому последующие дробины по убитой цели не создают
контекстов и не расходуют бюджет/щит. Это словарь и последовательность событий
минимального resolver, не реализация полного M2 engine.

`AttackContextPool.MAX_DEPTH = 4` и существующий API сохраняются: pellet занимает
depth1, дальнейшие реакции могут занимать depth2–4. Для N прямых дробин без эффектов
`hit_budget >= N`; будущие реакции требуют отдельного резерва. Cold sizing пула
учитывает до `1 + N` root/children на выстрел, одновременно живые деревья и удержанные
descendants. Закрытые children занимают слоты до освобождения всего дерева, даже
при последовательном обходе. Существующие hit-set/pool limits проверяются при sizing;
8/9 не становятся универсальными ёмкостями. Capacity/hit-set errors блокируют приёмку.

Root удерживается открытым до обработки всех traces. Каждый owned child/root закрывается
ровно один раз; отложенный descendant создаётся/удерживается при планировании ДО
последнего close. Он может продлить жизнь дерева после закрытия root. Любой
`close(context)`, вернувший `true`, атомарно освобождает всё дерево и делает все handles
невалидными. Поэтому root/source/shot metadata и итоги сохраняются ДО close;
единственный `OnAttackResolved` выпускается после `close() == true` по сохранённым
данным. Чтение освобождённого дерева или создание descendant после final close запрещено.
Для miss root закрывается без children и также даёт ровно один `OnAttackResolved`.
Отложенные владельцы создают child только через `ShotResolver.open_child(parent)`
и закрывают через `close_context(handle)`; прямые мутации его AttackContextPool
нарушают ownership. Предвыделенный реестр owned handles/root обеспечивает reset,
не расширяя API существующего AttackContextPool. Read-only inspection пула разрешён.
Факт HP>0→0 снимается сразу после Apply до синхронных OnHit listeners: их последующее
исцеление/освобождение цели не стирает OnKill этого Apply.

### Интеграция 60/30 Гц и room reset

Input/raycast adapter работает на физике 60 Гц; чистый shot resolver — на логике 30 Гц.
Один Sandbox composition-root subscriber вызывает shot resolver, затем существующий
`MobilityRuntime.logic_step(tick)`: все shots данного тика идут перед landing damage
и regen. Weapon/controller не добавляют собственных подписок. Resolver игнорирует
duplicate/старый logic tick, сохраняя единственную обработку событий; mobility guard
и его существующие гарантии остаются.

Room reset координируется этим же владельцем: capture точного старого
`GameLoop.get_logic_tick()` → reset shot resolver/ShotBatch (pending, diagnostic counters,
duplicate guard, новый room epoch и согласованная shot sequence) →
`weapon.reset_clock(old_tick)` для каждого оружия →
`MobilityRuntime.reset_clock(old_tick)` → `GameLoop.reset_clock()`.
Identity reset не должен смешивать старые и новые записи комнаты. Существующий
`MovementAbilities.rebase_clock` сохраняет оставшийся cooldown относительно ТОЧНОГО
old tick, включая physics activation до первого logic_step; energy/grants и физический
episode не сбрасываются room clock reset. Обычный same-identity bind не заменяет reset.
Weapon reset переносит remaining = max(ready_tick - old_tick, 0) к новому origin0,
включая выстрел из physics до первого logic_step. Pending press отбрасывается,
held-input latch сохраняется: удержание не создаёт новый rising edge после reset.
Lifecycle нового полного entity handle отдельно сбрасывает weapon state/input;
room reset не подменяет этот lifecycle.
Reset выполняется в quiescent boundary composition root: pending shots и retained
owned trees отменяются без OnAttackResolved. Старые handles после отмены невалидны.

### Реализованная конфигурация Sandbox и физического адаптера

Sandbox задаёт room-specific `C_shots=4`, trace cap32, `C_trace=max(N)=8` для единственного
разрешённого shotgun.tres, host capacity16, context capacity64, deferred reserve16.
Cold `WeaponData.validate_room` проверяет все presets до создания stores/bind/subscriber:
memory cap128KiB покрывает conservative packed-store budget: 64+9*C_trace bytes на
shot,16 на source allocator,640 на context с HandlePool/hit-set/metadata/owned registry.
Этот cap относится к packed combat stores, не к внутренней памяти Godot ray/mesh nodes;
их число фиксируется холодной загрузкой и проверяется активными monitor deltas.
Context sizing требует `C_shots*(1+C_trace)+deferred_reserve<=context_capacity`;
удержание сверх назначенного резерва является ошибкой конфигурации, а не новой механикой.

`ShotBatch.reserve` выдаёт монотонный reservation ticket без wrap; `write_trace` принимает
каждый stable index один раз, `publish` отказывает до всех N результатов. `prepare`
видит только complete records; `consume_prepared` не удаляет unfinished reservations.
Аксессоры читаются только в prepared диапазоне, trace только `<trace_count`.
Abort освобождает unpublished reservation, но sequence не переиспользуется.
Room reset повышает epoch и сбрасывает sequences; ticket не переиспользуется, поэтому
старый незавершённый writer не может записать в новый slot после reset.

HitscanWeapon создаёт `C_trace` RayCast3D при загрузке, исключает тело игрока и использует
world/enemy/hitbox mask. Physics priority10 следует FPS priority0 и предшествует
GameLoop1000. Фиксированные central+ring endpoints сохраняют world range40м при yaw/pitch
и поддержанном положительном uniform scale контроллера; после acceptance все rays
обновляются и unconditional publish выполняется вне assert, включая release build.
Hardware route принимает fire только при focus/captured mouse, игнорирует echo;
release очищает latch и вне capture. Capture loss/focus loss очищают input. Pause
отбрасывает pending press, hardware resume сверяет held с Input без создания edge;
driven command release допускается при pause. Headless route tests используют injected
capture intent и не доказывают доставку событий ОС.

Sandbox содержит три видимые статические damageable цели, mesh оружия и фиксированный
прицел. Убитые цели становятся серыми общим cold material, остаются видимыми и сохраняют
collider/full handle. Это inspectable death/no-op полигон, не enemy FSM/контент M2.

Unit/golden/Jolt/аллокационные проверки и команды заданы в
[плане пакета 3](m1-plan.md#3-дробовик-hitscan-и-разрешение-попаданий).
Результаты реализации и итогового независимого обзора записаны отдельно в журнале;
локальная приёмка runtime не доказывает графическую плавность или real-combat CPU-бюджет.
Последний Windows all exit0: scripts61/0,230/230 tests31suites, active120shots/960hits
zero deltas/config0; synthetic3032385286 PASS. Это инструментальные проверки,
они дополнены independent full-diff PASS и CI SUCCESS точного `9a4fead`, но не закрывают
графические проверки или общую приёмку M1. Runtime-проверки в этом docs-only шаге не повторялись.
