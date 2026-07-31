# TypeLisp work-queue chooser

`chooser.tl` reads a combined GitHub queue payload from stdin:

```json
{"prs":[...],"issues":[...]}
```

It prints exactly one selected action:

```text
review pr #N: Title
implement issue #N: Title
research/triage issue #N: Title
```

When more than three non-draft PRs hold back implementation work and every
remaining lane is empty, the chooser exits successfully with one stable
back-pressure line instead:

```text
wait: queue saturated; review: N PRs in flight; implement: M ready issues held back; research/triage: B blocked, C claimed
```

Malformed input and a genuinely empty `{"prs":[],"issues":[]}` snapshot remain
errors. Missing or wrongly typed top-level `prs` and `issues` arrays are
reported as invalid input.

PR objects should include `baseRefName`. An explicit base other than `main` is
treated as a stacked PR and is excluded from review; omitting the field retains
compatibility with older queue snapshots.

Use the TypeLisp command directly:

```sh
typelisp run tools/work-queue-chooser/chooser.tl --stdlib-root stdlib
```

PowerShell workers use the same non-Rust invocation:

```powershell
typelisp run tools/work-queue-chooser/chooser.tl --stdlib-root stdlib
```

The chooser always uses `system-seed`; if host entropy is unavailable,
the command exits with an error.

Weights preserve work lanes before ordinary issue priority:

| candidate lane | base | `p0` bonus | `p1` bonus |
| --- | ---: | ---: | ---: |
| PR review | 45 | — | — |
| ready-for-implementation | 10 | 50 | 3 |
| research/triage | 1 | 6 | 3 |

Thus a ready `p0` can intentionally preempt PR review, while every triage issue
stays below review and removing `ready-for-implementation` strictly lowers the
issue at the same priority.

`fixtures/chooser-queue.json` is a normalized live-queue snapshot used by
`scripts/benchmark-cli-tools.sh` to benchmark chooser startup and selection.
