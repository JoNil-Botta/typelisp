# Application workflow corpus

Small, useful TypeLisp projects driven end to end through the public CLI, the
way a user works on them (#7772). Feature tests stay authoritative for each
behavior; this corpus shows that the behaviors compose on real projects, on
Linux and Windows.

## Layout

- `<app>/`: a project with its own `typelisp.pkg`. A root `typelisp test`
  skips it, because it is a separate package. Fixed inputs live in `data/`
  and exact expected outputs in `expected/`.
- `<app>.cases`: its workflows, in the transcript format of
  `scripts/verify-codegen-cases.sh` (documented at the top of that script).
  Each case is one scenario.
- `scenarios.tsv`: every scenario, the app it belongs to, the hosts where it
  must pass, the workflows it chains, and the gates that own those behaviors
  individually.

| App | What it is | Workflows |
| --- | --- | --- |
| `csvstat` | Summarizes the columns of a CSV file from a path or stdin. It reports malformed input as `PATH:LINE:COL: error: ...`. | check, fmt, lint, inline tests, doctests, docs site, build, file, stdin and CRLF input, `run --`, bad-input diagnostics and exit codes, no-op rebuild, clean, byte-identical rebuild from clean, edit and rebuild, type-error recovery, paths with spaces |

## Running

```sh
TYPELISP_BIN=target/release/typelisp scripts/verify-app-corpus.sh
```

The gate `stage2-app-workflow-corpus` runs the same command with the
bootstrapped compiler on both hosts.

The runner:

- checks that `scenarios.tsv` and the case files name the same scenarios,
  each exactly once;
- runs each scenario declared for the host in its own directory outside the
  checkout, with no `TYPELISP_STDLIB_ROOT`, under a 1 GiB process-tree cap;
- requires exactly one pass per scenario.

It writes to `target/app-corpus/`:

- `results.tsv`: one row per scenario with its status, wall time and peak
  memory;
- `identity.tsv`: the compiler, its `--version`, the corpus commit and the
  toolchain;
- a `.log` and a `.memory` report for each scenario.

A failing scenario keeps its work directory and prints the command that
replays it. To replay one scenario by hand:

```sh
TYPELISP_BIN=target/release/typelisp sh scripts/verify-codegen-cases.sh \
    --only csvstat-build-run tests/apps/csvstat.cases
```

### Release smoke

The same corpus runs against a published compiler. `identity.tsv` then
records that compiler's version next to the corpus commit:

```sh
scripts/fetch-stage0.sh stage0-latest target/release-smoke
TYPELISP_BIN=target/release-smoke/typelisp scripts/verify-app-corpus.sh
```

## Extending the corpus

A feature owner adds a scenario when the feature lands:

1. Add a case to the app's `.cases` file. Start it from a fresh copy of the
   project:

   ```
   sh cp -R "{{root}}/tests/apps/<app>" "{{dir}}/<app>"
   sh rm -rf "{{dir}}/<app>/target"
   cwd <app>
   ```

   Then check public outputs, exit statuses and artifacts, not only that a
   command succeeded. Compare full outputs against files in `expected/` with
   `same`.
2. Two limits of the runner apply. It resolves redirections in its own
   directory, so give them absolute `{{dir}}` paths. It does not keep
   pipelines intact, so write input to a file with `sh` first.
3. Add the row to `scenarios.tsv`. A scenario that cannot run on a host is
   declared for the other host only; nothing is skipped at run time.
4. If the scenario exposes a compiler or tool defect, file the defect and fix
   it on its own. A scenario never passes by expecting the wrong output.

A new app is a new `<app>/` project, `<app>.cases` file and set of rows. Keep
each app a small, understandable example with fixed correctness oracles.

## Workload identities

Each app and its inputs, at a given corpus commit, is a fixed workload
(`apps/<app>`). The performance scorecard (#7851) can compile and run these
workloads, and `results.tsv` supplies their first wall-time and peak-memory
observations for each scenario.
