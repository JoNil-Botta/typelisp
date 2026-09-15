# Native test-entry memory measurements

Run the unchanged heavy Windows-parameter fixture and an alternating heavy/light
batch for 4, 16 and 32 entries. The driver shares its workload implementation
with the small `test_cli_entry_memory_smoke.tl` regression in normal CI. Every
child test must pass; no reporting occurs between retained-memory checkpoints.

From the repository root, with a current native compiler:

```sh
scripts/measure-test-entry-memory.sh tools/stage0/typelisp target/exp/entry-memory/run-1
```

On native Windows Git Bash, use `tools/stage0/typelisp.exe`. The runner enforces
a 4 GiB Windows Job Object cap or a hard 6 GiB Linux user-cgroup cap for building,
linking and each measured process tree. Missing enforcement fails closed.
Use a new output directory for each run; prior evidence is never overwritten.

To measure another checkout with exactly the same harness, append
`--baseline-root /path/to/baseline`. Baseline mode records growth without
accepting it as a candidate result. Candidate mode requires zero retained
growth after the first four entries in all six runs. The referenced bytes and
parent inputs retain their normal ownership; the harness adds no scratch arena
around the entry API.

`results.tsv` records retained bytes, process-tree peak and wall time for each
workload/count. `provenance.tsv` records the source commit and content digest,
harness digest, seed identity/hash and newly built executable hash. Logs,
bounded reports and the exact harness sources remain beside them. Source and
harness digests must remain unchanged through the run. The seed emits a fresh
native test driver containing the selected checkout's compiler modules;
ordinary CI independently validates the compiler's bootstrap/fixpoints.

The **Test Entry Memory** workflow runs baseline and candidate measurements on
native Windows in parallel with normal CI for affected PRs. It can also be
dispatched on a branch with an explicit baseline ref. These resource results
complement the complete CI matrix and compiler/generated-code performance
protocol. Different hosted runners do not establish a paired speed comparison.
