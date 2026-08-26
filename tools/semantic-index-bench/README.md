# Semantic-index benchmark

This opt-in benchmark constructs a complete owned semantic index for
`src/compiler_typecheck_core.tl`, reports its record count, and releases the
index before exiting. The workload is intentionally compiler-scale and is not
part of the ordinary test suite.

Run it with an explicitly selected, already available TypeLisp compiler:

```sh
scripts/benchmark-semantic-index.sh --compiler target/bootstrap-fixpoint/stage3
```

A published seed can be selected explicitly instead:

```sh
scripts/fetch-stage0.sh stage0-latest tools/stage0
scripts/benchmark-semantic-index.sh --compiler tools/stage0/typelisp
```

The benchmark script never downloads a compiler. It builds this runner from
the current checkout at optimization level 2, then executes the runner under
the fail-closed cross-host process-tree cap in
`scripts/run-memory-bounded.sh`. Defaults are an 8 GiB cap and a 30-minute
timeout; use `--limit-mib`, `--timeout-seconds`, and `--report` to override
them.

The machine-readable report defaults to
`target/semantic-index-benchmark/report.kv`. Its fixed schema (with
illustrative observation values) is:

```text
schema_version=1
workload=owned-semantic-index
input=src/compiler_typecheck_core.tl
semantic_record_count=354341
host=linux
backend=systemd-user-cgroup
reason=success
exit_code=0
limit_bytes=8589934592
peak_memory_bytes=1679663104
wall_ms=870116
```

`host`, `backend`, timing, and memory values are observations. `reason` is one
of `success`, `timeout`, `memory-limit`, `command-failure`, or
`wrapper-failure`. A non-success report uses
`semantic_record_count=unavailable`; it never turns a partial or terminated
index into a fabricated count. The report is replaced atomically on every run,
and raw logs remain under `target/semantic-index-benchmark/` for diagnosis.

Run the bounded-wrapper and report-schema regression cases without compiling
or indexing the compiler corpus:

```sh
scripts/benchmark-semantic-index.sh --self-test
```
