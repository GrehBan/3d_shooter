# План M1: движение, стрельба и Zero-Allocation

Статус: M1 закрыта 2026-10-14 слиянием PR #10–#13, кроме frame-слоя (покачивание камеры
и процедурная анимация оружия в `_process`), который закрывается отдельной задачей до M2.3.
Состояние вехи — в [roadmap](../roadmap.md#m1-движение-стрельба-и-zero-allocation),
история пакетов, проверок и слияний — в [журнале интеграции PR](notes/pr-integration-log.md)
и [журнале работ](notes/work-log.md). Здесь — постановка и критерии приёмки пакетов.

Источники: [roadmap.md](../roadmap.md), [GDD](../gdd.md), [технический манифест](../tech_manifest.md),
[контракты](contracts.md), [открытые долги](notes/follow-ups.md).

## Порядок

Пакеты выполнялись строго последовательно, каждый после приёмки предыдущего, в отдельной
ветке с явным списком файлов. Общие файлы (`Sandbox`, контроллер, тесты, контракты)
переходили к следующему пакету только после завершения предыдущего.

Каждый пакет обновлял затронутые MD и [журнал](notes/work-log.md), проходил импорт,
проверку скриптов и соответствующие unit/golden-тесты по [CLAUDE.md](../CLAUDE.md) и
`ci/run_checks.sh`; горячие пути дополнительно проверялись измерениями и бенчмарком.
При интеграции независимо проверялся полный итоговый diff.

## 1. Физический FPS-контроллер и полигон

Владелец: исполнитель контроллера; области `player/FPSController.gd`, `world/sandbox/Sandbox.tscn`
и `tests/unit/FPSControllerTest.gd` внутри `res://`. `FPSController` — `CharacterBody3D`,
физический адаптер: ходьба, мышь, обычный прыжок и переходы земля/воздух.
`GameLoop` и его частоты не менять; визуал кадра не пишет состояние чистой логики.

Приёмка: тесты с реальными коллизиями проверяют движение, диагональную скорость,
гравитацию, прыжок на границе перехода земля/воздух, ограничение pitch, паузу и отсутствие
аллокаций в горячем пути. Ручная проверка плавности движения и мыши фиксируется отдельно;
headless-тесты её не доказывают. Обычные параметры скорости, мыши и прыжка координатор
фиксирует в постановке в рамках GDD и делегированной задачи.

Минимальный пакет — ходьба, yaw/pitch, обычный edge-прыжок, физические состояния
земля/воздух и полигон со стеной, пологим склоном и платформой. Стартовые exports:
скорость 8 м/с, прыжок 5.5 м/с, мышь 0.002 рад/пиксель, pitch ±85°, гравитация из
ProjectSettings (по умолчанию 9.8). Это параметры физического прототипа, а не
утверждённый баланс GDD. API и пауза — в [контрактах](contracts.md). Тест активного
движения использует 300 тиков прогрева и 3600 тиков замера, обычную физику 60 Гц и
локальный test timeout 120000 мс через штатный API gdUnit; общие пороги CI не меняются.
Поддерживаемые физические transforms (мировой ортонормированный basis, положительный
равномерный масштаб) — в [контрактах](contracts.md#5-физический-адаптер-fpscontroller-m1-пакет-1).

## 2. Рывок, скольжение и воздушные прыжки

Владелец: исполнитель движения; области контроллера, `MovementAbilities`,
настройки Sandbox и соответствующие unit/интеграционные тесты. Начальная энергия — 3000
в масштабе ×1000, соответствуя трём зарядам из GDD. Проверки допустимости физического
действия выполняются до `try_activate()`, чтобы отказ не расходовал энергию и кулдаун.
Счётчик воздушных прыжков сбрасывается только при подтверждённом приземлении;
регенерация энергии вызывается на логическом тике 30 Гц.

Приёмка: земля/воздух, отклонённое действие без расхода, границы энергии/кулдаунов,
ограничение двойного прыжка при нулевой цене и кулдауне, сброс после приземления,
регенерация и отсутствие аллокаций. GDD уже требует урон за падение с высоты >8 м
с тайминговой отменой рывком/скольжением; формула и защита приняты пользователем:
10 HP/метр сверх 8 м, floor целых mm; успешный dash за последние 12 физических тиков
либо успешный post-landing slide из бесплатного воздушного edge prearm на 12 тиков
отменяют падение. Щит первым, процентная броня снижает остаток, HP clamp ≥0;
см. [контракт](contracts.md#6-m1-мобильность-и-приземление-пакет-2).
HP изменяет чистая логика по событию,
физический контроллер не рассчитывает и не применяет урон напрямую.

Параметры прототипа: dash 24 м/с ×9 физических шагов, cost 1000/cooldown 6 logic;
slide speed entry ≥4 м/с, cost 500/cooldown 6, deceleration 5 м/с² ×36 шагов без
изменения капсулы; double jump один на AIR episode, vy 5.5, cost 1000/cooldown 0,
ground jump free. ENERGY/MAX 3000; общий store регенерирует 50 raw ровно раз в logic
tick (1500/с). Все проверки допустимости физики предшествуют try_activate; отказ
может уступить следующему действию dash→slide→jump, успех максимум один.

## 3. Дробовик hitscan и разрешение попаданий

Утверждённый пресет: 8 дробин × 6000 raw (6 HP), дальность 40 м, центральная дробина и
кольцо из 7 с разбросом 5°, semi-auto по фронту нажатия, кулдаун 15 логических тиков
(0.5 с), без патронов и перезарядки. Один root на выстрел, включая промах,
sibling-child на каждую попавшую дробину, урон по дробине.

Владелец: исполнитель оружия; области `weapons/`, физическая интеграция в Sandbox,
минимальные чистые ShotBatch/resolver, существующие stores/пулы контрактов и
unit/golden/интеграционные тесты оружия. Состояние и данные оружия — чистые классы;
input/raycast adapter работает на 60 Гц, resolver — на 30 Гц. Полный M2 DamagePipeline,
EffectRunner, карточки и элементы в пакет не входят; API и `MAX_DEPTH = 4` у `AttackContextPool`
не меняются. Пакеты 4/5 этим договором не расширяются.

Конкретный `WeaponData` — пресет выше. Число дробин и разброс этого пресета не являются
универсальными техническими максимумами. Подробности игровой семантики —
[GDD](../gdd.md#принято-для-m1-минимальный-hitscan-дробовик--2026-10-13),
транспорт, контексты и интеграция — [контракт §7](contracts.md#7-m1-hitscan-дробовик-и-shotbatch-пакет-3).
Реализованный Sandbox назначает лимиты комнаты: shots 4, trace cap 32, stride 8, hosts 16,
contexts 64, deferred reserve 16 и консервативный лимит packed-хранилищ 128 КиБ. RayCast3D
предсозданы холодно; world range сохраняется при supported yaw/pitch/uniform scale.
Shared ACP API/MAX_DEPTH и legacy stores/эталоны сохранены. Deferred owners используют
только resolver.open_child/close_context; quiescent reset отменяет owned trees без
completion events. Sandbox показывает оружие, прицел и видимые серые defeated targets.

Для N из immutable cold-валидированных данных оружия транспорт предвыделяется с
`C_trace = max(N)` разрешённых пресетов комнаты и независимой `C_shots`, проверенными
по явным room trace/memory cap. В запись входят все N traces, включая miss; публикация
атомарная, tail не читается. Нехватка slots/`N > C_trace` отвергает весь запрос до
acceptance/cooldown/resources/VFX/трасс; partial write, truncation и hot resize запрещены.
Единственный room-owner allocator выдаёт strictly increasing nonrepeat sequence всем
оружиям одного full source; identity=(room epoch, full source, sequence). Wrap запрещён:
exhaustion отказывает до acceptance/cooldown/resources/VFX/traces. Порядок —
source/sequence, затем stable trace index. Числовые universal capacity cap не назначаются.
Legacy HitEventQueue/payload/target-first sort/goldens и synthetic checksum 3032385286 сохраняются;
M1 hitscan→ShotBatch — явное исключение из общего событийного маршрута.

Root на accepted shot, включая miss, имеет пустой hit-set; live-hit каждой дробины
идёт через sibling-child на глубине 1. Stale/dead no-op проверяется до child/budget/щита/триггеров;
Apply/PostHit завершаются до следующей дробины. OnHit живой зарегистрированной цели
сохраняется при HP damage 0; OnKill только HP>0→0. Root держится до всех traces,
отложенные descendants — до final close. Metadata сохраняются до любого close;
OnAttackResolved ровно один после close()==true, освобождённое дерево не читается.
Для N прямых дробин `hit_budget >= N`; pool sizing учитывает 1+N, закрытые children, одновременно
живые деревья и отложенные descendants. Схема root-per-hit из SyntheticCombatLoad
не переносится в игровой resolver и не переписывается в синтетике.

Один Sandbox subscriber вызывает shot resolver → MobilityRuntime.logic_step:
shots перед landing damage/regen. Duplicate/старый tick игнорируется resolver.
Room reset: capture old GameLoop tick → reset batch pending/guard/identity с новым epoch →
weapon.reset_clock(old) → existing mobility.reset_clock(old) → GameLoop.reset_clock();
оставшийся кулдаун оружия `max(ready_tick - old, 0)` переносится к началу отсчёта 0, включая physics fire до
первого logic_step. Pending press очищается, held latch сохраняется, удержание не
создаёт rising edge после reset; lifecycle нового full entity handle отдельный.
Точный old tick и
сохранение оставшегося mobility cooldown, energy/grants/physical episode обязательны.

### Проверки пакета 3

Тесты пакета: `ShotBatchTest`, `WeaponStateTest`, `ShotResolverTest`, `ShotgunPhysicsTest`,
`ShotgunSandboxTest` и `ShotgunGoldenTest` с независимой моделью `shotgun_ref.py`.

* Unit/golden транспорта: WeaponData validation и invalid room init; параметризуемые
  C_trace/C_shots, fixed stride/нечитаемый tail, все N trace results включая miss,
  whole-shot публикация. Нехватка capacity и N>C_trace не меняют cooldown/resources/VFX
  и не оставляют записи; каждый отказ увеличивает счётчик, диагностика однократна
  до reset, горячего resize нет. Ненулевые ошибки конфигурации блокируют приёмку.
* Identity/order: общий owner sequence allocator нескольких оружий одного source,
  no-wrap exhaustion без acceptance/cooldown/traces, полные source/target поколения,
  уникальная shot identity, канонические source/sequence/trace index независимо от
  порядка поступления; несколько целей, препятствие, stale handle и miss.
* Resolver: 8 × 6000 raw по HP 10000 при shield/armor 0 → два живых hits, один OnKill,
  шесть no-op. Щит/броня, давшие HP damage 0, сохраняют OnHit без OnKill.
  Stale/dead цель не расходует контекстную capacity, hit budget или shield и не
  испускает триггеров; повторные дробины по живой цели проходят sibling-ветвями.
* Context lifecycle: пустой hit-set root, miss root, budget ≥ N, `MAX_DEPTH = 4` и pool sizing
  с удержанием закрытых children. Каждый owned context закрывается ровно один раз;
  отложенный descendant удержан до final close, завершение даёт один OnAttackResolved
  по сохранённым metadata, операции с freed handles отвергаются.
* Integration/reset: один subscriber, duplicate/old tick, shot-before-landing/regen,
  сброс pending/guard/identity; mobility cooldown сохраняет remaining от точного old
  GameLoop tick, включая activation до первого logic_step. Weapon remaining cooldown
  также сохраняется; pending press очищается, held-input не создаёт свежий edge.
  Identity старой комнаты
  не смешивается с новой; существующие mobility lifecycle/grant гарантии сохраняются.
* Реальный Jolt/input adapter: raycasts и rising-edge выстрелы на физике 60 Гц,
  кулдаун 15 логических тиков и resolver на 30 Гц; удержание не повторяет semi-auto edge.
  Headless не подтверждает GUI/плавность или доставку ввода ОС.
* Активные 60 с после прогрева: подтверждённые счётчики выстрелов/hits/resolved,
  дельты objects/nodes/resources 0, static memory ≤ 1 МиБ, ошибок config/dropped 0;
  проверки горячих путей и прежние unit/golden/эталоны остаются. Synthetic checksum
  3032385286 не меняется и не заменяет реальный CPU-бюджет/приёмку всей M1.

При проверке реализации используется существующая gdUnit4 система и команды из
[CLAUDE.md](../CLAUDE.md): импорт/скрипты, unit/golden и `regress.gd` через
`GODOT=/путь/к/godot bash ci/run_checks.sh all` из корня репозитория;
focused gdUnit suites запускаются существующей командой `GdUnitCmdTool.gd --add`.
Новая тестовая система не требуется. После проверок — независимое ревью точного
итогового кода и затронутых MD; приёмка документационного договора не доказывает
реализацию, отсутствие аллокаций или прохождение будущих тестов.

## 4. Пулы используемых VFX и декалей

Координатор утвердил visual preset без изменения игрового баланса:
muzzle/impact/mark живут 3/6/180 физических тиков, размеры 0.16/0.08/0.14 м,
глубина проекции mark 0.04 м. Настоящие Decal, shared cold RGBA текстуры 64×64
и MeshInstance3D flashes предсоздаются при загрузке. Room envelope: один producer,
кулдаун не меньше 15 логических (30 физических) тиков, stride 8, burst 4. Conservative capacity
`4 + ceil(lifetime / 30)` для muzzle и `stride * (4 + ceil(lifetime / 30))` для contact
дают muzzle 5 / impact 40 / decal 80 (125 узлов при лимите 128).
Лимит сырых текстур 32768 байт, packed-хранилищ представления 16384 байт — отдельно
от боевого лимита 128 КиБ. Эти cap не описывают полный внутренний heap/VRAM Godot nodes.

Физический snapshot читается синхронно только после успешного publish; pure
ShotBatch/resolver не получают float point/normal. Miss даёт muzzle; любой
physical contact, включая wall NO_HANDLE/dead/stale, даёт flash+surface mark
независимо damage. Abort/reserve/publish отказ и чтение вне snapshot не дают визуал.
Impact/decal pair атомарна. Visual overflow повышает собственные counters и
однократную диагностику, не меняя cooldown/damage/shot; acceptance требует zero.
Истечение (priority 5) перед оружием (priority 10), pause замораживает age, reset отменяет metadata
и active nodes с сохранением generation allocator. Kind/full-generation handles
и epoch/sequence guards защищают повторное использование. Muzzle следует socket
на конце Barrel; decals исключают weapon/flash render layer 2.
У пула и узлов физическая интерполяция выключена, вспышка ствола следует
отображаемому transform сокета.

Владелец: исполнитель визуальных пулов; области используемых сцен/ресурсов эффектов,
их пулов, интеграции оружия/Sandbox и тестов. Предсоздавать только реальные эффекты
и декали этого дробовика. Новое оружие или снаряд не добавляются ради демонстрации пула.

Приёмка: повторное использование, возврат и очистка состояния, подобранная ёмкость,
измерения objects/nodes/resources и памяти после прогрева. В боевом цикле нет
`new()`/`instantiate()`/`queue_free()`; визуал не меняет расчёт урона и статы.

## 5. Бенчмарк реального конвейера и приёмка M1

Пакет добавляет настоящий Sandbox под нагрузкой (`RealPipelineBenchmark.tscn`), драйвер
ввода (priority −100) и сэмплер (priority 1200), чистый результат приёмки с тестом и
отдельный шаг CI `real_pipeline`. Рабочие колбэки, подписка и хранилища не меняются;
полный набор активности, диагностик, проверок аллокаций, CPU и FPS —
[контракт §9](contracts.md#9-m1-реальный-интеграционный-бенчмарк-пакет-5).

Команды из Git root:

```sh
# Ускоренный active workload, deliberate leak и unknown option в CI.
GODOT=/path/to/godot bash ci/run_checks.sh real_pipeline
# Реальное графическое время; без --headless/--fixed-fps/--max-fps/--time-scale.
godot --path 3d-shooter --resolution 1280x720 res://tests/perf/RealPipelineBenchmark.tscn
```

Владелец: исполнитель проверки интеграции; области `tests/perf/`, тестовой сцены реального
контроллера/оружия/пулов и необходимых интеграционных тестов. Прогон должен доказывать,
что движение, выстрелы и повторное использование пулов действительно выполнялись:
включить проверяемые счётчики действий и результатов, а не только итоговый checksum.
После прогрева измерять 3600 физических тиков (60 с при 60 Гц).

Приёмка: сохранить существующий synthetic checksum `3032385286` и его проверки;
для реального конвейера — нулевые дельты objects/nodes/resources, рост static memory
не более 1 МБ, нулевые dropped/config errors и отрицательная самопроверка с введённой утечкой.
CPU-бюджет 7 мс для реальной игровой логики должен соблюдаться и подтверждаться
измерениями по манифесту: текущий синтетический тест выводит время,
но не применяет его как жёсткий порог. Он не заменяет профилирование реального конвейера.
Headless-прогон не доказывает 60 FPS или плавность; нужна отдельная проверка в графическом
режиме с зафиксированными условиями. Финальная версия проходит полный набор проверок,
независимое ревью интеграции и критерии M1 из дорожной карты; результаты и ограничения
записываются в журнал. M2 не начинается до выполнения prerequisites.
