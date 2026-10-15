# План M2: физический конвейер, эффекты и карточки

Дата: 2026-10-14. База `master` —
`962741d9fabc3aa599255126a03b5c2de6b54227` после squash merge PR #13.
M1 принят локально: независимое ревью, Windows all, native same-fixture measurements
и качественная ручная проверка movement/mouse. Required Linux/Windows CI проверял
точный опубликованный HEAD #13 `062534d`, run38595049442, обе проверки SUCCESS.
Числа и ограничения — [журнал интеграции](notes/pr-integration-log.md).

Пользователь поручил начать M2 («работаем»). Это разрешает локальную разработку,
а не публикацию, создание PR или слияние M2. Текущая ветка `codex/m2-combat-plan`,
изолированный worktree `pr-stack-integration/3d_shooter`; M2.1 принят локально после
Windows all/native PASS и независимого ревью точного итогового diff без блокеров.
Версия и доказательства зафиксированы в [журнале](notes/work-log.md). Следующий шаг —
согласование контракта M2.2; его реализация и последующие пакеты не начаты.

Источники: [манифест](../tech_manifest.md), [GDD](../gdd.md),
[контракты](contracts.md), [roadmap](../roadmap.md), [правила агентов](../AGENTS.md).

## Порядок и владельцы

Координатор назначает scope, базу, одного writer на файл и отдельного reviewer.
Lead developer реализует; архитектор проверяет контракт/бюджеты; QA/SDET владеет
независимыми моделями и доказательствами; game designer ратифицирует числовые
правила до зависимого кода. Перед каждым следующим пакетом нужны принятый точный
diff предыдущего, зафиксированные контракт и ёмкости, отдельные ветка/worktree.
Назначения текущего пакета: lead developer — `DamagePipeline`, resolver integration,
unit tests и документы; QA/SDET — отдельные Python oracle и golden test;
архитектор — независимое read-only ревью итогового полного diff.

| Пакет | Результат | Gate до реализации / приёмка |
| --- | --- | --- |
| M2.1 | Физическая граница фаз и минимальная интеграция дробовика | Контракт ниже согласован до кода; focused, golden, allocation, полный Windows all, независимый final-diff review |
| M2.2 | Детерминированный `EffectRunner`, ограниченные Conditions/Actions | Сначала порядок триггеров, quota/continuation, overflow и ownership; затем bounded processing, cooldown/reset/stale tests, независимая модель |
| M2.3 | Элементы, реакции и статусы | Сначала утверждённые величины, длительности, stacking/refresh, immunities, crit/RNG и порядок фаз; затем packed state, атомарное восстановление и golden |
| M2.4 | Определения карточек и отдельный mutable runtime | Сначала схема content keys, уровни/слоты, immutable Registry и save validation; `ENERGY_REGEN` только если утверждённые карточки меняют регенерацию |
| M2.5 | Утверждённые 10 карточек, включая цепь «Громового дробовика» | Сначала точный roster, баланс, теги и ёмкости; реальные Trigger → Condition → Action и взаимодействия в golden |
| M2.6 | Debug inspection и общая интеграционная приёмка M2 | Bounded/preallocated trace, активная fixture, allocation/performance gates и независимый обзор интеграции; при согласованном scope может объединяться с M2.5 |

Полного списка десяти карточек и числовых правил статусов/критов/реакций в GDD
сейчас нет. Это prerequisites зависимых пакетов, не повод изобретать значения в
M2.1. Новые оружие, противники, комнаты, procedural generation и M3 workload
с 40 врагами/effect storms в этот шаг не входят.

## M2.1: принятый физический контракт

Чистый typed `DamagePipeline.new(stats)` разрешает одну голову существующего
`DamagePayloadBuffer`: `resolve_front(payloads) -> int` возвращает фактический
HP damage ≥0 либо `INVALID_RESULT = -1`. Не снимает запись, не испускает события,
не создаёт/закрывает контексты и не обрабатывает следующую запись.

Вход: `BASE`, `Element.NONE`, `flags = 0`, `amount >= 0`. `source`, `attack_context`
и `tags` — непрозрачные int64 metadata, их live-validity не проверяется. Все поля,
включая raw amount, сохраняются. Base/Add/Multiply/Element/Crit — identity над уже
рассчитанным физическим raw damage; RNG, modifiers, элементы и статусы отсутствуют.
Mitigation не пишет stats: единственный authority shield/armor остаётся
`DamageApply`, целиком вызываемый на Apply; терминальная фаза — `POST_HIT`.
В этом синхронном foundation промежуточные identity-фазы не являются callbacks.

Пустой буфер — обычный `-1` без диагностики. Некорректная/неподдерживаемая запись
отвергается до любых записей в payload/stats; каждый вызов увеличивает
`configuration_errors`, `push_error` однократен до `reset_counters()`.
Сброс не меняет FIFO/stats. Даже для stale target неподдерживаемые данные сначала
отвергаются. Для допустимой записи stale/dead target — обычный no-op 0 с
`POST_HIT`, без HP/shield writes и без ошибки конфигурации.

ShotResolver предвыделяет pipeline и scratch buffer ёмкости 1. Сохраняются guard
полного target handle/HP до child/budget и поштучный порядок:
push → resolve → capture kill → OnHit → OnKill → pop → close child; затем следующая
дробина. Root/retained-descendant ownership не меняется. Нет нового source guard.
При неожиданном push/resolve отказе отрицательный damage не уходит в OnHit,
child закрывается, итоговый root completion сохраняется. Quiescent room reset
очищает scratch и его dropped counter, сбрасывает pipeline diagnostics.
`damage_configuration_errors()` суммирует оба источника и входит в gate реального
benchmark. MobilityRuntime и synthetic reference/checksum не меняются.

## Детерминированная квота и измеряемое время

В [roadmap M2](../roadmap.md#m2-ядро-боя-карточек-и-dod-data-oriented-design)
раньше было «жёсткий бюджет времени», тогда как
[манифест §I.3](../tech_manifest.md#3-детерминизм-в-заданных-границах-bit-exactness)
запрещает системное время в детерминированных решениях, а §II.1 задаёт фиксированный
бюджет обхода. Принятое уточнение: runner принимает решения по целочисленной
квоте работы, глубине и hit budget; wall-clock только измеряет выполнение.
Превышение CPU budget проваливает приёмку и требует оптимизации/изменения
согласованных квот, но не меняет набор эффектов по скорости конкретного компьютера.

До M2.2 требуется определить единицу работы, число операций, приоритеты FIFO,
continuation между logic ticks, сохранение порядка и close/release на отказе.
Значения квоты ещё не назначены. Общая цель ≤7 ms gameplay logic сохраняется;
≤2 ms slice из манифеста относится к генерации/navigation, не автоматически к
боевым реакциям. Текущая M1 fixture не доказывает M3 workload.

## Проверки и передача

Для M2.1: import, script checks, focused unit/golden, независимый Python reference,
active и suppressed-error allocation tests, все suites и synthetic/real benchmarks
через `ci/run_checks.sh all`. Golden проверяет целочисленный floor независимой
арифметикой Python, int64 metadata/amount, stale/dead targets и FIFO wraparound.
Существующие shotgun tests сохраняют heal-in-OnHit/kill snapshot, dead guards и
retained descendant lifecycle. Новая fault injection проверяет diagnostic/reset.
Финальный diff с manifest/hash передаётся независимому reviewer; изменённые после
ревью bytes требуют повторного review. Runtime PASS, local acceptance, commit,
publication, CI и merge отражаются раздельно в [журнале](notes/work-log.md).

Windows all итогового runtime: import PASS, scripts70/0, 265/265 tests в35 suites,
synthetic3032385286 PASS; активный joint benchmark, negative leak и setup refusal
PASS. Native same-fixture Forward+/D3D12 RTX4050: mean143.841FPS, p99 frame9926us,
max logic356us; object/node/resource/orphan/static-memory deltas0. Это подтверждает
текущий workload, не будущие 40 enemies/effect storms M3 или все GPU.
