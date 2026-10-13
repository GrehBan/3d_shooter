# Pull Request Integration Log

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
