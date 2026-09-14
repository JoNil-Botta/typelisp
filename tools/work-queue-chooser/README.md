# TypeLisp work-queue chooser

Fetch the complete open queue before applying eligibility filters:

```sh
mkdir -p target/exp/work-queue
sh scripts/fetch-work-queue.sh > target/exp/work-queue/raw.json &&
jq '.issues |= map(select(any(.labels[]; .name=="ready-for-implementation" or .name=="needs-research")))' \
  target/exp/work-queue/raw.json > target/exp/work-queue/eligible.json &&
typelisp run tools/work-queue-chooser/chooser.tl --stdlib-root stdlib \
  < target/exp/work-queue/eligible.json
```

The fetch wrapper requires authenticated `gh` and `jq`. Its optional argument
is an `OWNER/REPO` (default `JoNil-Botta/typelisp`). It emits one unfiltered
`{"prs":[...],"issues":[...]}` document only after both list requests succeed
and validate. PR records retain number, title, body, head/base branches, draft
state, labels and check rollups; issue records retain number, title and labels.
Claimed PRs and drafts remain in the raw queue. Keep the raw capture when
investigating selection; filtering first can hide dependencies or claims.

`gh list` paginates up to its requested limit. The wrapper starts at 1,000 PRs
and 10,000 issues, doubles a reached limit, and retries up to four requests per
lane. A still-reached limit fails with pagination guidance; it never certifies
that an exactly full result is complete. API errors, malformed records,
duplicate IDs and extra JSON documents also fail with no snapshot on stdout.
Do not invoke the chooser after a failed fetch. An empty repository is valid
fetch output; the current chooser's empty-queue behavior is described below.

These are two live GitHub list observations, not an atomic repository snapshot.
Recheck issue/PR activity immediately before claiming work. The wrapper does
not infer readiness, change labels, recover stale claims or implement the
remaining scheduling policy in #7768. The current chooser still needs caller
checks for review claims, draft-inclusive backpressure, blocked work and #8's
horizons. Repository fetch regression tests run without credentials or network:

```sh
sh scripts/test-fetch-work-queue.sh
```

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
