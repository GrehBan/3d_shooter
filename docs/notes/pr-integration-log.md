# Журнал интеграции PR

Хронология публикаций, проверок, приёмок и слияний. Справочные документы
([roadmap](../../roadmap.md), [контракты](../contracts.md), планы M1/M2) описывают
только текущее состояние; история шагов — здесь, подробности решений и проверок —
в [журнале работ](work-log.md).

Термины: **required CI** — оба обязательных задания GitHub Actions
«Tests and benchmark (ubuntu-latest)» и «(windows-latest)»; **squash** — слияние
PR одним коммитом в `master`.

## Текущее состояние — 2026-10-17

* `master` — `1ea0e52` (squash PR #27), required CI SUCCESS
  ([run 39019050732](https://github.com/GrehBan/3d_shooter/actions/runs/39019050732)).
* Слиты PR #1–#27, открытых PR нет.
* Закрыты вехи M0, M1a и M1, в M2 слиты M2.1, M2.2 и M2.3 (M2.3a — PR #25, M2.3b — PR #27).
* Снимок M2.3 от Codex `m23-element-contract/` после проверки удалён; что в нём было и почему
  не перенесено — в [журнале работ](work-log.md).

## Сводка PR

| PR | Ветка | Итоговый HEAD | Required CI | Squash в `master` | Содержание | Независимое ревью |
| --- | --- | --- | --- | --- | --- | --- |
| [#1](https://github.com/GrehBan/3d_shooter/pull/1) | m1a/step-4-hit-queue | `68958e0` | SUCCESS, [37993217439](https://github.com/GrehBan/3d_shooter/actions/runs/37993217439) | `b3c6d4a` | `Damageable`, `HitEventQueue` | координатор |
| [#2](https://github.com/GrehBan/3d_shooter/pull/2) | m1a/step-5-attack-context | `f4590fe` | SUCCESS, [38038254522](https://github.com/GrehBan/3d_shooter/actions/runs/38038254522) | `0c0a1a8` | `AttackContextPool`, `HandlePool` | координатор |
| [#3](https://github.com/GrehBan/3d_shooter/pull/3) | chore/canonical-project-godot | `62186d5` | SUCCESS, [38038469842](https://github.com/GrehBan/3d_shooter/actions/runs/38038469842) | `71d6d91` | канонический `project.godot`, тест частот | координатор |
| [#4](https://github.com/GrehBan/3d_shooter/pull/4) | m1a/step-6-effect-host | `6f0901b` | SUCCESS, [38038984453](https://github.com/GrehBan/3d_shooter/actions/runs/38038984453) | `522465c` | `EffectHost`, `EffectTrigger` | координатор |
| [#5](https://github.com/GrehBan/3d_shooter/pull/5) | m1a/step-7-movement-ability | `cee3d38` | SUCCESS, [38039525569](https://github.com/GrehBan/3d_shooter/actions/runs/38039525569) | `68bfeb4` | `MovementAbilities` | координатор |
| [#6](https://github.com/GrehBan/3d_shooter/pull/6) | fix/effecthost-stale-host | `e9fb331` | SUCCESS, [38039619922](https://github.com/GrehBan/3d_shooter/actions/runs/38039619922) | `0d62078` | устаревший handle хоста | координатор |
| [#7](https://github.com/GrehBan/3d_shooter/pull/7) | m1a/step-8-contracts | `97fca3b` | SUCCESS, [38040266177](https://github.com/GrehBan/3d_shooter/actions/runs/38040266177) | `36b171d` | `docs/contracts.md`, сквозной mock-тест, `LogicIsolationTest` | координатор |
| [#8](https://github.com/GrehBan/3d_shooter/pull/8) | codex/foundation-checkpoint | `3dfddbf` | SUCCESS, [38192398071](https://github.com/GrehBan/3d_shooter/actions/runs/38192398071) | `2b7623f` | долги M1a, Python-модели эталонов, `AGENTS.md` | полный checkpoint 20 файлов — PASS; свежий аудит исходников #8–#11 — PASS |
| [#9](https://github.com/GrehBan/3d_shooter/pull/9) | codex/buffer-overflow-contract | `a918115` | SUCCESS, [38465077469](https://github.com/GrehBan/3d_shooter/actions/runs/38465077469) | `1d9f9aa` | переполнение `DamagePayloadBuffer` | дельта переполнения 7 файлов — PASS; интеграция — PASS |
| [#10](https://github.com/GrehBan/3d_shooter/pull/10) | codex/m1-mobility | `570441c` | SUCCESS, [38465530744](https://github.com/GrehBan/3d_shooter/actions/runs/38465530744) | `23677e7` | M1 пакеты 1–2: FPS-контроллер, мобильность, падение | полный 32 файла и metadata — PASS; свежий аудит исходников — PASS; интеграция — отменена пользователем |
| [#11](https://github.com/GrehBan/3d_shooter/pull/11) | codex/m1-current-plan | `fefbd90` | SUCCESS, [38466505413](https://github.com/GrehBan/3d_shooter/actions/runs/38466505413) | `da9ee56` | M1 пакет 3: hitscan-дробовик | полный 36 файлов дробовика — PASS; закрывающие 6 MD — PASS; свежий аудит исходников — PASS; интеграция — отменена пользователем |
| [#12](https://github.com/GrehBan/3d_shooter/pull/12) | codex/m1-visual-pools | `4d09f59` | SUCCESS, [38467557300](https://github.com/GrehBan/3d_shooter/actions/runs/38467557300) | `cc63554` | M1 пакет 4: пулы VFX и декалей | точные 23 файла, архитектура и QA — PASS; закрывающие 6 MD — PASS; интеграция — отменена пользователем |
| [#13](https://github.com/GrehBan/3d_shooter/pull/13) | codex/m1-real-pipeline | `062534d` | SUCCESS, [38595049442](https://github.com/GrehBan/3d_shooter/actions/runs/38595049442) | `962741d` | M1 пакет 5: реальный бенчмарк, приёмка M1 | архитектура и QA 17 файлов — PASS, манифест SHA256 `208e98fa7c84d60c9204748386bb7b1ba020f227636fdcc1d832f1686a27f215` |
| [#14](https://github.com/GrehBan/3d_shooter/pull/14) | codex/m2-combat-plan | `bc18104` | SUCCESS, [38646433608](https://github.com/GrehBan/3d_shooter/actions/runs/38646433608) | `e00dff1` | M2.1: физический `DamagePipeline` | точный diff 18 файлов — PASS, манифест SHA256 `b16726e0ebb1052e4ddc1a59de41bb0df10151b62065b762df9d92120d327cb5` |
| [#15](https://github.com/GrehBan/3d_shooter/pull/15) | codex/m2-effect-runner | `9d309dd` | SUCCESS, [38720677226](https://github.com/GrehBan/3d_shooter/actions/runs/38720677226) | `3c94d6d` | M2.2: `EffectRunner` со счётчиками | точный diff 29 файлов — PASS |
| [#16](https://github.com/GrehBan/3d_shooter/pull/16) | claude/audit-docs | `338c910` | SUCCESS, [38730777852](https://github.com/GrehBan/3d_shooter/actions/runs/38730777852) | `628c9a4` | нормализация документов после аудита | координатор |
| [#17](https://github.com/GrehBan/3d_shooter/pull/17) | claude/process-manifest | `bfafbd5` | SUCCESS, [38735180723](https://github.com/GrehBan/3d_shooter/actions/runs/38735180723) | `8c69211` | нейтральный процесс в `CLAUDE.md`, исключения манифеста | координатор |
| [#18](https://github.com/GrehBan/3d_shooter/pull/18) | claude/sandbox-events | `b4b47d2` | SUCCESS, [38767193483](https://github.com/GrehBan/3d_shooter/actions/runs/38767193483) | `97770d7` | визуал смерти по событию убийства, `room_entered` при сбросе | координатор |
| [#19](https://github.com/GrehBan/3d_shooter/pull/19) | claude/room-combat | `4c50239` | SUCCESS, [38771165625](https://github.com/GrehBan/3d_shooter/actions/runs/38771165625) | `c3c176e` | `RoomCombat` владеет `StatBlock` комнаты | координатор |
| [#20](https://github.com/GrehBan/3d_shooter/pull/20) | claude/alloc-tests | `95d9069` | SUCCESS, [38773458582](https://github.com/GrehBan/3d_shooter/actions/runs/38773458582) | `11f6d67` | тесты аллокаций горячих путей пяти классов | координатор |
| [#21](https://github.com/GrehBan/3d_shooter/pull/21) | claude/fall-height-cap | `9288028` | SUCCESS, [38776091838](https://github.com/GrehBan/3d_shooter/actions/runs/38776091838) | `bcf75b9` | точный целочисленный предел высоты падения | координатор |
| [#22](https://github.com/GrehBan/3d_shooter/pull/22) | claude/check-scripts-abstract | `442ccdb` | SUCCESS, [38779840257](https://github.com/GrehBan/3d_shooter/actions/runs/38779840257) | `0489610` | `check_scripts` отвергает неудачную компиляцию | координатор |
| [#23](https://github.com/GrehBan/3d_shooter/pull/23) | claude/m1-frame-layer | `f165d0a` | SUCCESS, [38812964743](https://github.com/GrehBan/3d_shooter/actions/runs/38812964743) | `130dc3f` | M1: кадровый слой, покачивание оружия и камеры | координатор |
| [#24](https://github.com/GrehBan/3d_shooter/pull/24) | claude/pipeline-phase-budget | `ee2c783` | SUCCESS, [38818296806](https://github.com/GrehBan/3d_shooter/actions/runs/38818296806) | `1ece751` | замер логики по фазам и доли бюджета | координатор |
| [#25](https://github.com/GrehBan/3d_shooter/pull/25) | claude/m23-statuses | `72a88fe` | SUCCESS, [38894501891](https://github.com/GrehBan/3d_shooter/actions/runs/38894501891) | `141771b` | M2.3a: элементы и статусы | координатор |
| [#26](https://github.com/GrehBan/3d_shooter/pull/26) | claude/gdd-campaign-structure | `309cb6d` | SUCCESS, [38924325429](https://github.com/GrehBan/3d_shooter/actions/runs/38924325429) | `58eef19` | документы: забег / этап / кампания, баланс, сюжет | координатор |
| [#27](https://github.com/GrehBan/3d_shooter/pull/27) | claude/m23-reactions | `f34dea0` | SUCCESS, [39019050732](https://github.com/GrehBan/3d_shooter/actions/runs/39019050732) | `1ea0e52` | M2.3b: элементальные реакции | координатор |

Все слияния выполнены от учётной записи GrehBan: #1–#7 — по процессу координатора
(ревью координатора, зелёный CI), #8–#15 — в работе Codex по поручениям пользователя,
#16–#27 — после аудита по процессу координатора (ревью координатора, зелёный CI на точном
HEAD, squash).
Колонка CI — проверка точного итогового HEAD. Ревью субагента локально не равно
одобрению на GitHub; обязательных ревью на GitHub защита `master` не требует.

## Хронология

### 2026-10-09…10 — M0 и M1a (PR #1–#7)

M0 закрыт 2026-10-09: первый CI зелёный на Linux и Windows, `master` защищён
(required CI, strict, `enforce_admins`, без force-push и удаления). M1a закрыта
2026-10-10 слиянием #7: контракты описаны, mock-тесты и `LogicIsolationTest` есть.

### 2026-10-11…12 — долги M1a и переполнение буфера (PR #8, #9)

* Локально закрыты два долга M1a: строгая типизация и атомарный отказ
  `StatBlock.set_state()`, четыре независимые Python-модели существующих эталонов.
  Windows: 41 скрипт без ошибок, 138/138 тестов, бенчмарк PASS.
* Checkpoint из 20 файлов опубликован в `codex/foundation-checkpoint` (исходный коммит
  `eb2415b`), draft PR #8. Отдельное ревью упаковки пропущено по поручению пользователя.
  Итоговый HEAD `3dfddbf` прошёл required CI.
* Переполнение `DamagePayloadBuffer` приведено к общему контракту в
  `codex/buffer-overflow-contract`: однократное уведомление, счётчик каждого отказа,
  раздельные сбросы очереди и счётчика. Семь файлов получили независимый PASS,
  коммит `b297898`, draft PR #9; HEAD `4802c80` прошёл required CI
  ([run 38194634272](https://github.com/GrehBan/3d_shooter/actions/runs/38194634272)).

### 2026-10-12…13 — M1, пакеты 1–2 (PR #10)

* Пакет 1 (FPS-контроллер, мышь, прыжок, полигон) в `codex/m1-fps-controller`:
  P2 ревью (мировой basis движения) исправлен, повторный PASS девяти файлов,
  коммит `cf141eb`. Windows: 43 скрипта, 158/158 тестов в 22 suites, активное движение
  500.60 м с нулевыми дельтами объектов и static memory +1152 B.
* Пакет 2 (dash, slide, double jump, урон от падения) в `codex/m1-mobility` от базы
  `081d9ae`. Ревью нашло три P2 (сброс часов кулдауна, холодная валидация пресета,
  повторная привязка той же сущности), затем ещё два (abort Sandbox, prearm) и одно
  (потерянный физический тест кулдауна slide). Все закрыты; финальный PASS 32 файлов,
  коммит `499fbc2`, официальный source PASS архитектора, документы — `b73a4be`.
  Windows `all`: 50 скриптов, 199/199 тестов в 25 suites, активные 3900 тиков без
  аллокаций и потерь событий.
* Неблокирующий P3 точности предельной высоты падения вынесен в
  [follow-ups](follow-ups.md).

### 2026-10-13 — M1, пакеты 3–4 (PR #11, #12)

* Договор пакета 3 (ShotBatch, resolver, контексты атак) получил архитектурный PASS
  до кода. Реализация в `codex/m1-current-plan` от `b73a4be`; draft PR #11 с коммитом
  `9c88a7b`. Пользователь сначала остановил работу по лимитам, затем возобновил её.
  Итоговое ревью `b73a4be` → `9a4fead` и QA — PASS без блокеров, required CI
  `9a4fead` SUCCESS ([run 38421912445](https://github.com/GrehBan/3d_shooter/actions/runs/38421912445));
  закрывающие документы — `d9f1a53`, CI SUCCESS
  ([run 38424601880](https://github.com/GrehBan/3d_shooter/actions/runs/38424601880)).
  Windows `all`: 61 скрипт, 230/230 тестов в 31 suite, 120 выстрелов / 960 попаданий
  без аллокаций, golden дробовика 3770191677.
* Пакет 4 (пулы вспышек, попаданий и декалей) в `codex/m1-visual-pools` от `d9f1a53`.
  Windows `all`: 64 скрипта, 249/249 тестов в 32 suites; 120 вспышек, 960 попаданий,
  960 декалей, 2040 переиспользований без аллокаций. Native Forward+/D3D12 на RTX 4050
  Laptop, 1280×720: позы совпали, следы на полу и стенах появились и очищаются сбросом.
  Архитектурное и QA-ревью 23 файлов — PASS, коммит `ff26428`; PR #12 с HEAD
  `6a81bdc`, CI SUCCESS ([run 38464462181](https://github.com/GrehBan/3d_shooter/actions/runs/38464462181)).

### 2026-10-13 — последовательное слияние #8–#12

Пользователь поручил проверить и слить стек по порядку 8 → 9 → 10 → 11 → 12 squash-слиянием.
Интеграция #9 прошла независимое ревью; для #10–#12 пользователь явно отменил новые
интеграционные ревью, поэтому у этих слияний есть только прежние ревью исходников.
Каждый обновлённый HEAD проходил свежий required CI; прямых пушей в `master`,
force-push и rebase не было.

* #8 слит как есть → `2b7623f`.
* #9: обычный merge `master` в ветку, конфликты в четырёх MD разрешены вручную,
  runtime совпадает с исходным HEAD → HEAD `a918115` → `1d9f9aa`.
* #10: четыре конфликта MD, runtime совпадает с исходным HEAD → HEAD `570441c` → `23677e7`.
* #11: конфликты в пяти MD и четырёх runtime/test-файлах разрешены в пользу принятых
  версий пакета 3 → HEAD `fefbd90` → `da9ee56`.
* #12: семь runtime/test и шесть MD конфликтов восстановлены к принятому пакету 4 →
  HEAD `4d09f59` → `cc63554`.

### 2026-10-14 — M1, пакет 5 и приёмка M1 (PR #13)

Пакет 5 в `codex/m1-real-pipeline` от `cc63554`: настоящий Sandbox под нагрузкой,
отдельный шаг CI `real_pipeline` с проверкой утечки и неизвестной опции.
Windows `all`: 67 скриптов, 255/255 тестов в 33 suites, synthetic checksum 3032385286.
Native real-time на RTX 4050 Laptop, Forward+/D3D12: средний FPS 143.846,
p95/p99/худший кадр 7776/9449/11146 µs, медленных кадров 0, максимум логики 319 µs,
дельты мониторов 0. Пользователь вручную подтвердил плавность движения и мыши.
Архитектурное и QA-ревью 17 файлов — PASS (манифест файлов SHA256
`208e98fa7c84d60c9204748386bb7b1ba020f227636fdcc1d832f1686a27f215`); коммит `df32caa`, CI SUCCESS
([run 38556520650](https://github.com/GrehBan/3d_shooter/actions/runs/38556520650));
итоговый HEAD `062534d` → `962741d`. Этим M1 принята, кроме frame-слоя (см. roadmap).

### 2026-10-14…15 — M2.1 и M2.2 (PR #14, #15)

* M2.1 (физический `DamagePipeline`) в `codex/m2-combat-plan`: Windows `all` —
  70 скриптов, 265/265 тестов в 35 suites, golden 2671520872; native средний FPS 143.841,
  p99 9926 µs, максимум логики 356 µs. Независимое ревью 18 файлов — PASS, коммит
  `bc18104` → `e00dff1`.
* M2.2 (`EffectRunner` со счётчиками) в `codex/m2-effect-runner`: Windows `all` —
  75 скриптов, 280/280 тестов в 38 suites, golden 3633298175; native средний FPS 142.984,
  p99 7741 µs, максимум логики 431 µs. Ревью 29 файлов — PASS; принятый коммит `88aeb78`,
  перенесён без изменений содержимого в HEAD `9d309dd` → `3c94d6d`.
* 2026-10-15 пользователь разрешил публикацию и слияние M2 (тело PR #14).

### 2026-10-15 — аудит

Аудит работы после M1a: [отчёт](audit-2026-10-15.md). `master` `3c94d6d` прошёл
`ci/run_checks.sh all` (exit 0, 280/280 тестов). Найдены устаревшие статусы документов,
отступления от манифеста и блокеры снимка M2.3; решения координатора и порядок
исправлений записаны в отчёте и [журнале работ](work-log.md).

### 2026-10-15…17 — нормализация после аудита, M1 frame-слой, M2.3 (PR #16–#27)

* #16–#24 закрыли решения аудита: документы и процесс, владение `StatBlock` комнатой,
  события смерти в Sandbox, тесты аллокаций, предел высоты падения, проверка скриптов,
  frame-слой M1 и замер логики по фазам.
* #25 (M2.3a, статусы) и #27 (M2.3b, реакции) перенесли M2.3 из снимка Codex с переработкой
  по аудиту; #26 — документы структуры забега и сюжета. Подробности проверок и ревью — в
  [журнале работ](work-log.md).
