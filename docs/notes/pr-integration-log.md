# Pull Request Integration Log

## Current Status: 2026-10-14

PRs #8-#13 are merged. PR #13's final published HEAD
`062534d86352c45d4ff49d11f073d46cdbd8f752` passed both required Linux/Windows checks
([run38595049442](https://github.com/GrehBan/3d_shooter/actions/runs/38595049442))
before squash merge to `master` `962741d9fabc3aa599255126a03b5c2de6b54227`.
Package5 and the current M1 fixture were locally accepted after independent review,
Windows all, native measurements and the qualitative human movement/mouse check.
The earlier open/pending entries below are historical checkpoints.

The user then authorized starting M2. M2.1 physical DamagePipeline passed Windows
all/native gates and independent final-diff review, then was committed locally as
`bc1810450ffe150cd6ccea5930b6bc31a69b5bb2`. M2.2 counter foundation uses that agreed
dependent base in isolated `codex/m2-effect-runner`; it is implemented locally.
The work log identifies its exact checks and independent review status.
M2 is neither published nor merged; no M2 PR/publication/merge is authorized.
M1 measurements and CI are evidence for their tested source, not the new M2 diff.
See the [M2 plan](../m2-plan.md) and [work log](work-log.md).

## Audit and Order: 2026-10-13

After local acceptance of package 4, the user authorized auditing and merging
the stack in order **8 -> 9 -> 10 -> 11 -> 12**, using squash merges into `master`.
Integration #9 received independent review. The user's later explicit instruction
to merge without further review waives new integration reviews for #10-#12;
their earlier source reviews remain historical evidence, not new integration PASS.
Fresh required Linux/Windows CI still applies to every updated HEAD; earlier-head
success does not validate it. No direct master push, force push, or rebase is used.

The original audited source heads are:

| PR | Source HEAD | Independent Source Review | Original Required CI |
| --- | --- | --- | --- |
| [#8](https://github.com/GrehBan/3d_shooter/pull/8) | `3dfddbf0c50bbedcd1aaadaf2036f25236dd59f9` | Fresh full 20-file checkpoint PASS | Linux/Windows SUCCESS, [38192398071](https://github.com/GrehBan/3d_shooter/actions/runs/38192398071) |
| [#9](https://github.com/GrehBan/3d_shooter/pull/9) | `4802c805017b7593a4f1e37d2d1d9b83ee1743f8` | Fresh focused 7-file overflow delta PASS | Linux/Windows SUCCESS, [38194634272](https://github.com/GrehBan/3d_shooter/actions/runs/38194634272) |
| [#10](https://github.com/GrehBan/3d_shooter/pull/10) | `85d75baa01ba23ef2be0f27a1962ab7dac76e019` | Prior full 32-file/metadata PASS plus fresh source audit PASS | Linux/Windows SUCCESS, [38285534384](https://github.com/GrehBan/3d_shooter/actions/runs/38285534384) |
| [#11](https://github.com/GrehBan/3d_shooter/pull/11) | `d9f1a53175fe32176fac72df195eda27ee18a129` | Full 36-file shotgun PASS and closing 6-MD PASS | Linux/Windows SUCCESS, [38424601880](https://github.com/GrehBan/3d_shooter/actions/runs/38424601880) |
| [#12](https://github.com/GrehBan/3d_shooter/pull/12) | `6a81bdc50cc95c3c0c10d2398ae319971415f8d1` | Exact 23-file package 4 architecture/QA PASS and closing 6-MD PASS | Linux/Windows SUCCESS, [38464462181](https://github.com/GrehBan/3d_shooter/actions/runs/38464462181); not integration-HEAD CI |

Fresh independent source audit covered #8-#11; #12 had separate exact final review.
Local subagent PASS is not GitHub approval; draft-skipped automated review is not
counted. Package 5 and manual input/smoothness/FPS gates remain open.

## PR 8: Merged

After confirming both required checks on the table's exact #8 HEAD, the coordinator
squash-merged #8. Current `master` is `2b7623f77716a262e085323193ed4a64a7ddb406`.
This intermediate foundation lacks #9's overflow fix and is not completed M1.

## PR 9: Integration Prepared

In an isolated checkout at original #9 HEAD, ordinary
`git merge --no-commit --no-ff origin/master` imported the master above.
Conflicts in `docs/m1-plan.md`, `docs/notes/follow-ups.md`, `docs/notes/work-log.md`,
and `roadmap.md` were individually compared against both parents. Advanced #9
versions preserve foundation history and overflow updates, removing only the
resolved overflow debt. No runtime conflict occurred.

Only this log and its work-log entry add metadata. Runtime/tests/config/assets/CI
remain identical Git blobs to original #9 HEAD; Godot was not rerun.
This prepared state was followed by independent integration PASS and publication
of HEAD `a918115ebd3b6c718c3bf2c1577df88800935e3f`. Required Linux/Windows checks
succeeded for that exact HEAD ([run38465077469](https://github.com/GrehBan/3d_shooter/actions/runs/38465077469)).
The coordinator squash-merged #9 to master `1d9f9aa4ba1031af7d12bbc50cd4f78f5b0fdd27`.

## PR 10: Integration Prepared

Original #10 HEAD received an ordinary merge of the new master above. Four MD
conflicts were resolved using its advanced contracts/plan/roadmap/history after
individual comparison, retaining #9's new integration journal and work-log entry.
Runtime/tests/config/assets/CI remain identical blobs to original #10 HEAD.
Godot was not rerun; new integration review was explicitly waived, not passed.
The coordinator published integration HEAD `570441c5eb8d1172cac2b89c8a800fb5fb5ef739`;
both required checks succeeded ([run38465530744](https://github.com/GrehBan/3d_shooter/actions/runs/38465530744)).
PR #10 was squash-merged to master `23677e7fae434e656651b08cb981968329e905ae`.

## PR 11: Integration Prepared

Original #11 HEAD received an ordinary merge of that master. Individual conflicts
in five MD and four runtime/test files were resolved to the advanced accepted
shotgun versions; inherited integration facts from #9/#10 were preserved.
All non-MD blobs match original #11 HEAD exactly. New integration review was waived,
not passed. The coordinator published HEAD `fefbd9047b869a44ffa71fe0b85089d0f6431db1`;
required Linux/Windows checks succeeded ([run38466505413](https://github.com/GrehBan/3d_shooter/actions/runs/38466505413)).
PR #11 was squash-merged to master `da9ee56ed998d31c03c773ce5846291035beb89f`.

## PR 12: Integration Prepared

Original #12 HEAD received an ordinary merge of that master. Seven runtime/test
and six MD conflicts were individually restored to accepted package 4 versions,
preserving every incoming integration entry. All non-MD blobs match original #12
HEAD exactly. Only current-status clarification and integration metadata are new.
Godot was not rerun; further integration review is explicitly waived, not passed.
PR #12 awaits publication and fresh required CI of the updated HEAD; it is not
merged. Package 4 is locally accepted, but package 5 and overall M1 remain open.

## PR 12: Merged, 2026-10-14 Status

The coordinator published final integration HEAD `4d09f5943ca08a4aedde715066ebebca5d644255`; both required Linux/Windows
checks succeeded ([run38467557300](https://github.com/GrehBan/3d_shooter/actions/runs/38467557300)).
PR #12 was squash-merged to master `cc63554f9bf63d46737554fd9ecb430d7b02447e`.
The accepted package4 runtime remained unchanged; the earlier pending entry above
describes the state before publication. All PRs #8–#12 are merged.
Package5 uses this fresh master in isolated `codex/m1-real-pipeline`. Its new checks,
independent review and publication are separate evidence; prior CI does not validate
this new diff. The user has authorized a package5 PR, not its merge.

## PR 13: Published and Locally Accepted, 2026-10-14

Independent architecture and QA reviews passed the complete 17-file package5 snapshot
against base `cc63554f9bf63d46737554fd9ecb430d7b02447e`, verifying file-manifest SHA256
`208e98fa7c84d60c9204748386bb7b1ba020f227636fdcc1d832f1686a27f215`.
The coordinator accepted package5 and the current M1 fixture locally after the
Windows all, native frame/logic measurements and qualitative human movement/mouse
check documented in [the work log](work-log.md#локальная-приёмка-и-публикация-пакета5--2026-10-14).
Hardware and M3 workload limitations remain; M2 has not started.

Source commit `df32caaf670008a059cd1c15de2e79fff8172af9` is published on
`codex/m1-real-pipeline`; [PR #13](https://github.com/GrehBan/3d_shooter/pull/13)
is open, ready, and targets `master`. The coordinator freshly verified SUCCESS for
both required Linux/Windows checks on this exact source HEAD
([run38556520650](https://github.com/GrehBan/3d_shooter/actions/runs/38556520650),
jobs `115826933410`/`115826933053`). No merge has occurred or been authorized for this PR.

This two-file documentation closure awaits its own exact review before publication.
Runtime/config/assets/CI are unchanged and Godot was not rerun. The future closing-docs
HEAD requires fresh required checks; source-head CI cannot validate that later HEAD.
Earlier pre-review and unpublished checkpoints remain historical records.
