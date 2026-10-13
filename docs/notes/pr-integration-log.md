# Pull Request Integration Log

## Audit and Order: 2026-10-13

After local acceptance of package 4, the user authorized auditing and merging
the stack in order **8 -> 9 -> 10 -> 11 -> 12**, using squash merges into `master`.
Each integrated HEAD requires independent review and fresh required Linux/Windows
CI; earlier-head success does not validate it. No direct master push, force push,
or rebase is authorized by this workflow.

The original audited source heads are:

| PR | Source HEAD | Independent Source Review | Original Required CI |
| --- | --- | --- | --- |
| [#8](https://github.com/GrehBan/3d_shooter/pull/8) | `3dfddbf0c50bbedcd1aaadaf2036f25236dd59f9` | Fresh full 20-file checkpoint PASS | Linux/Windows SUCCESS, [38192398071](https://github.com/GrehBan/3d_shooter/actions/runs/38192398071) |
| [#9](https://github.com/GrehBan/3d_shooter/pull/9) | `4802c805017b7593a4f1e37d2d1d9b83ee1743f8` | Fresh focused 7-file overflow delta PASS | Linux/Windows SUCCESS, [38194634272](https://github.com/GrehBan/3d_shooter/actions/runs/38194634272) |
| [#10](https://github.com/GrehBan/3d_shooter/pull/10) | `85d75baa01ba23ef2be0f27a1962ab7dac76e019` | Prior full 32-file/metadata PASS plus fresh source audit PASS | Linux/Windows SUCCESS, [38285534384](https://github.com/GrehBan/3d_shooter/actions/runs/38285534384) |
| [#11](https://github.com/GrehBan/3d_shooter/pull/11) | `d9f1a53175fe32176fac72df195eda27ee18a129` | Full 36-file shotgun PASS and closing 6-MD PASS | Linux/Windows SUCCESS, [38424601880](https://github.com/GrehBan/3d_shooter/actions/runs/38424601880) |
| [#12](https://github.com/GrehBan/3d_shooter/pull/12) | `6a81bdc50cc95c3c0c10d2398ae319971415f8d1` | Exact 23-file package 4 architecture/QA PASS and closing 6-MD PASS | Published; no final CI verdict recorded here |

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
Independent integration review, commit/publication, and new-HEAD CI are pending.
PR #9 is not merged; later PRs were untouched by this step.
