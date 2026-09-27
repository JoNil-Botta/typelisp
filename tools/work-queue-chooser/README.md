# TypeLisp work-queue chooser

Capture the open queue with authenticated `gh` and `jq`, filter only the
issues, and pipe the combined document into the chooser:

```sh
prs=$(gh pr list --repo JoNil-Botta/typelisp --state open --limit 1000 \
  --json number,title,body,headRefName,baseRefName,isDraft,labels,statusCheckRollup) &&
issues=$(gh issue list --repo JoNil-Botta/typelisp --state open --limit 10000 \
  --json number,title,labels) &&
printf '{"prs":%s,"issues":%s}' "$prs" "$issues" |
  jq '.issues |= map(select(any(.labels[]; .name=="ready-for-implementation" or .name=="needs-research")))' |
  typelisp run tools/work-queue-chooser/chooser.tl --stdlib-root stdlib
```

`gh ... list` returns at most `--limit` records: if a list returns exactly its
limit, raise the limit and fetch again. Keep claimed PRs and drafts in the PR
array; filtering them first hides claims and backlog. The two lists are
separate live observations, not an atomic repository snapshot, so recheck
issue/PR activity immediately before claiming work. The chooser does not infer
readiness, change labels, recover stale claims or implement the remaining
scheduling policy in #7768; callers still check review claims, draft-inclusive
backpressure, blocked work and #8's horizons.

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
wait: queue saturated; review: N PRs in flight; implement: M ready issues held back; research/triage: C claimed
```

Malformed input and a genuinely empty `{"prs":[],"issues":[]}` snapshot remain
errors. Missing or wrongly typed top-level `prs` and `issues` arrays are
reported as invalid input.

PR objects should include `baseRefName`. An explicit base other than `main` is
treated as a stacked PR and is excluded from review; omitting the field retains
compatibility with older queue snapshots.

Live PR snapshots must include `labels`, as the capture command above
requests. `labels` is an array of objects with string `name` fields. The exact
decoded name `review-claimed` excludes a PR from review. Other labels, including case
or whitespace variants, do not affect eligibility. Empty arrays are unclaimed;
an absent field remains unclaimed for legacy snapshots. Explicit `null`, a
non-array field, or an entry without a string `name` is an input error naming
the PR array index. Every PR's labels are validated, even if it is a draft,
targets another base, has pending checks, or has an earlier claim label.

Claimed PRs still reserve issues linked by their title/branch and contribute to
the existing non-draft backlog count. The separate draft-recovery/backlog work
in [#7768](https://github.com/JoNil-Botta/typelisp/issues/7768) retains its scope;
workers must continue enforcing their stricter total-PR cap, including drafts.

When claims leave no eligible work, the chooser exits successfully with a
stable wait line, without requesting entropy:

```text
wait: review claims; review-claimed: 1; recheck when PR labels, checks, draft/base state, or issue readiness change
```

Above the existing backlog cap, the same claim count and recheck trigger are
appended to the queue-saturation line. Other eligible review, implementation,
or triage work is still selected under the existing rules. Removing the label
restores eligibility when the PR's other requirements pass.

The chooser only reads a snapshot: it does not acquire/release labels, infer
that a claim is stale, or guarantee atomic exclusion. Workers still recheck
the live tag before adding their own claim, skip tagged PRs, and confirm a
reviewer has stopped before reclaiming work. Keep claimed PRs in future inputs.

The invocation is the same under PowerShell:

```powershell
typelisp run tools/work-queue-chooser/chooser.tl --stdlib-root stdlib
```

Candidate selection uses `system-seed`; if host entropy is unavailable,
the command exits with an error. Deterministic waits do not select a candidate.

Weights preserve work lanes before ordinary issue priority:

| candidate lane | base | `p0` bonus | `p1` bonus |
| --- | ---: | ---: | ---: |
| PR review | 45 | — | — |
| ready-for-implementation | 10 | 50 | 3 |
| research/triage | 1 | 6 | 3 |

Thus a ready `p0` can intentionally preempt PR review, while every triage issue
stays below review and removing `ready-for-implementation` strictly lowers the
issue at the same priority.

`fixtures/chooser-queue.json` is an unchanged normalized historical snapshot
used by `scripts/benchmark-cli-tools.sh` to benchmark chooser startup and
selection; its missing PR labels exercise legacy compatibility. The claimed
wait and malformed-label fixtures exercise the live payload contract through
`tests/cli/selfhost-build-run.cases` (gate
`stage2-cli-build-run-and-chooser-smoke`) on Linux and Windows.
