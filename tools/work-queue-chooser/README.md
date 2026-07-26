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

Use the TypeLisp command directly:

```sh
typelisp run tools/work-queue-chooser/chooser.tl --stdlib-root stdlib
```

PowerShell workers use the same non-Rust invocation:

```powershell
typelisp run tools/work-queue-chooser/chooser.tl --stdlib-root stdlib
```

Produce the combined snapshot with review activity included:

```powershell
$prs = (gh pr list --repo JoNil-Botta/typelisp --state open --json number,title,headRefName,isDraft,statusCheckRollup,commits,reviews,comments | Out-String).Trim()
$issues = (gh issue list --repo JoNil-Botta/typelisp --state open --limit 300 --json number,title,labels | Out-String).Trim()
('{"prs":' + $prs + ',"issues":' + $issues + '}') | typelisp run tools/work-queue-chooser/chooser.tl --stdlib-root stdlib
```

The chooser compares the newest `commits[].committedDate` with the newest
`reviews[].submittedAt` or `comments[].createdAt`. A review/comment newer than
the head commit settles that PR until another commit is pushed. The three
activity arrays are optional during rollout: a producer using the old payload
shape keeps PRs eligible instead of silently dropping them.

The chooser always uses `system-seed`; if host entropy is unavailable,
the command exits with an error.

`fixtures/chooser-queue.json` is a normalized live-queue snapshot used by
`scripts/benchmark-cli-tools.sh` to benchmark chooser startup and selection.
