# План M2: физический конвейер, эффекты и карточки

Дата: 2026-10-14. База `master` —
`962741d9fabc3aa599255126a03b5c2de6b54227` после squash merge PR #13.
M1 принят локально: независимое ревью, Windows all, native same-fixture measurements
и качественная ручная проверка movement/mouse. Required Linux/Windows CI проверял
точный опубликованный HEAD #13 `062534d`, run38595049442, обе проверки SUCCESS.
Числа и ограничения — [журнал интеграции](notes/pr-integration-log.md).

Пользователь поручил начать M2 («работаем»). Это разрешает локальную разработку,
а не публикацию, создание PR или слияние M2. M2.1 принят локально после Windows
all/native PASS и независимого ревью, затем committed как
`bc1810450ffe150cd6ccea5930b6bc31a69b5bb2`. Это согласованная зависимая база M2.2:
ветка `codex/m2-effect-runner`, worktree `m2-effect-runner/3d_shooter`.
M2.2 принят локально 2026-10-15 после Windows all/native PASS и независимого
exact full-diff review без замечаний. Следующий шаг — числовой контракт M2.3.
M2.2 ещё не staged/committed/published; M2 GitHub CI и merge отсутствуют.
Версия и доказательства зафиксированы в [журнале](notes/work-log.md).

Источники: [манифест](../tech_manifest.md), [GDD](../gdd.md),
[контракты](contracts.md), [roadmap](../roadmap.md), [правила агентов](../AGENTS.md).

## Порядок и владельцы

Координатор назначает scope, базу, одного writer на файл и отдельного reviewer.
Lead developer реализует; архитектор проверяет контракт/бюджеты; QA/SDET владеет
независимыми моделями и доказательствами; game designer ратифицирует числовые
правила до зависимого кода. Перед каждым следующим пакетом нужны принятый точный
diff предыдущего, зафиксированные контракт и ёмкости, отдельные ветка/worktree.
Назначения M2.2: lead developer — counter runner, Sandbox/benchmark integration,
unit tests и CI marker; отдельный writer завершает документы после runtime freeze;
QA/SDET — отдельные Python oracle и golden test;
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

Для M2.2 единица работы и квота назначены ниже. Общая цель ≤7 ms gameplay logic сохраняется;
≤2 ms slice из манифеста относится к генерации/navigation, не автоматически к
боевым реакциям. Текущая M1 fixture не доказывает M3 workload.

## M2.2: approved and implemented counter foundation

The coordinator approved this restricted contract before implementation. `EffectRuleData`
provides ALWAYS/MIN_VALUE conditions and only INCREMENT_COUNTER; no damage, spawn,
status, branching, card state or content expansion. Cold scalar copies isolate shared
resources. Full subscription handles and owners key room-local state; `state_slot`
is not card persistence. Snapshot admission is atomic; 32 FIFO events capture at most 8
ordered handles each from 64 room entries. Quota 16 counts every inspected candidate
and preserves the front cursor between ticks. Overflow rejects a whole event with
configuration/drop counters; quota exhaustion defers it without errors.

Source full-handle validity is checked at admission/execution; dead-but-valid sources
continue. OnHit supplies captured nonnegative HP damage only. No target/context handle
is retained, so existing immediate attack completion and damage balance stay intact.
Cooldown starts on successful execution and compares elapsed integer ticks. Counter
overflow refuses atomically. Diagnostic reset preserves work/state/time; room reset
cancels all runner-local work/state but preserves definitions/subscriptions. Sandbox
performs resolver reset successfully before clearing runner state, then existing clock
resets. Normal Sandbox has no content effects; four test resources activate benchmark.

Separate packed payload cap 32768 B covers both EffectHost/HandlePool and runner:
9792 B empty, 9904 B four definitions, 11584 B maximum 64 definitions, excluding Godot
wrappers/allocator/Resources. The exact ledger, APIs, refusal counters, state semantics
and benchmark expected values are in [contracts](contracts.md#effectruledata-и-effectrunner-effects-m22).
This is a bounded counter foundation, not full M2 or persistent CardInstance state.

Required checks: focused boundary/stale/reuse/cold-copy/int64/reset tests, active 20k
mutation/allocation and suppressed-error loops, independent Python/golden 3633298175,
Sandbox immediate completion/target death/failed reset, full Windows all, real positive
and injected leak fixture (same counter workload), native same-fixture and independent
review of the exact final diff. Runtime freeze precedes full checks. Local review,
commit, publication, CI and merge remain distinct. M2.3+ stays blocked on its own
approved mechanics and acceptance; this package does not assign status/card balance.

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

M2.1 Windows all итогового runtime: import PASS, scripts70/0, 265/265 tests в35 suites,
synthetic3032385286 PASS; активный joint benchmark, negative leak и setup refusal
PASS. Native same-fixture Forward+/D3D12 RTX4050: mean143.841FPS, p99 frame9926us,
max logic356us; object/node/resource/orphan/static-memory deltas0. Это подтверждает
текущий workload, не будущие 40 enemies/effect storms M3 или все GPU.

Для M2.2 final Windows all от2026-10-15 PASS: import, scripts75/0,
280/280tests в38 suites, synthetic3032385286 и active joint positive/leak/setup gates.
Native same-fixture Forward+/D3D12 RTX4050 PASS: mean142.984FPS,
p99 frame7741us/max logic431us, все5 monitor deltas0 и ожидаемые effect counters.
Focused21/21 и Python/golden3633298175 подтверждены отдельно. Независимый review
точного29-file diff от `bc1810450ffe150cd6ccea5930b6bc31a69b5bb2` дал PASS,
координатор принял M2.2 локально; manifest и ограничения — в журнале.
Ранние прерванные all-прогоны не используются как PASS.
