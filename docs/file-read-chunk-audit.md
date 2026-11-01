# `file-read-chunk` caller audit

Issue [#9541](https://github.com/JoNil-Botta/typelisp/issues/9541).
Audited main: `4c1920ef971c0560aca8cc6a8c23f90f325ae2b8` (2026-11-01),
including the bounded resolver reader from
[PR #9540](https://github.com/JoNil-Botta/typelisp/pull/9540).

`file-read-chunk` allocates the full positive request before host I/O. Short
reads expose only the live prefix and leave the backing allocation in its
arena. See the [stdlib streaming allocation guidance](../stdlib/README.md#streaming-file-read-allocation)
for the fixed outer buffer and per-iteration scratch pattern.

## Scope and method

Search every source under `stdlib/`, `src/`, and `tools/`, including references
used as function values rather than direct calls:

```sh
rg -n 'file-read-chunk' stdlib/ src/ tools/
```

Follow the resolver's function-valued reader through `read-open-source` and
`read-step!`. Separate the public wrapper's own primitive calls from its
callers, and inspect test-source strings as well as executable code. No other
alias or function-valued reference to `file-read-chunk` occurs in these trees.

## Callers and loop bounds

| Caller | Calls and loops | Retention assessment |
| --- | --- | --- |
| [`src/build_cli_core.tl`](../src/build_cli_core.tl), `build-package-tool-file-digest`, first sample | One `file-read-chunk handle sample-size`, with `sample-size = 65536`. No read loop. | At most one 65,536-byte request. Request and call count are independent of file size and short-read behavior. |
| Same function, tail sample | At most one more 65,536-byte read after a seek, only if the first operation succeeded and file size exceeds the sample size. No read loop or short-read retry. | At most two fixed-size requests for the whole invocation. Existing sample copying and digest construction are outside this request-retention hazard. |
| [`stdlib/net/resolver_config_linux.tl`](../stdlib/net/resolver_config_linux.tl), `read-source-path` passing `io.file-read-chunk` to `read-open-source` | The `while (not done)` loop calls `read-step!`, which requests `min(8192, 1048577 - out.len)` inside a fresh lexical `with-arena scratch`. | Bounded: one fixed 1,048,577-byte outer buffer; temporary requests are reclaimed each iteration. Only live bytes are copied into preallocated outer slots. Scalar progress/error facts escape scratch. EOF, oversized input, read failure and zero progress terminate; the common exit closes exactly once. |
| [`stdlib/io.tl`](../stdlib/io.tl), `exercise-linux-file-handles` | Nine sequential reads on the read handle or an invalid handle, requesting `-1`, `0`, `2`, `3`, `10`, `10`, `10`, `1`, `1`; one write-only-handle read requesting `1`. No read loop. | Finite constant requests, maximum 10 bytes. Negative, zero, closed, invalid and write-only cases do not enter the positive host-read allocation path. |
| Same module, Windows branch of `io-file-handle-api` | One read requesting `1` through a handle not opened by the test. No read loop. | Fixed request and finite call count, exercising an unsupported-handle result. |
| [`src/tests/compiler_typecheck_tests.tl`](../src/tests/compiler_typecheck_tests.tl), `compiler-typecheck-with-fs-source` and IO/FS signature tests | Test-source declarations and three source-string calls to unsafe `file-read-chunk-status`, `file-read-chunk-bytes`, and `file-read-chunk-eof?`. No streaming loop. | Typechecking fixtures, not executed reads; no retained host-read requests. |
| [`src/compiler_backend_tests.tl`](../src/compiler_backend_tests.tl), `compiler-backend-private-io-fs-runtime-source` | Test-source extern declarations and one call each to private runtime read status, bytes and EOF symbols; request is `8`. No read loop. | Assembly-generation assertions for both targets, not executed streaming I/O. The fixture checks that these private-looking external symbols remain externs. |
| `tools/` | No references. | No caller to repair. |

The calls to `file-read-chunk-status`, `file-read-chunk-bytes`, and
`file-read-chunk-eof?` inside the public `stdlib/io.tl` wrapper implement one
read; they do not introduce another loop. The underlying `platform-read` is
called once per positive request.

## Resolver short-read regression

The merged #9540 test is
[`stdlib/tests/net_resolver_config_api.tl`](../stdlib/tests/net_resolver_config_api.tl),
`short-read-checks`. Its injected `one-byte-read` allocates the full requested
capacity and returns one byte per call for 256 bytes, then EOF. The assertions
check all 256 byte values, one close, retained memory at most 2 MiB, and peak
growth at most 4 MiB under `compile-profile`. Additional cases reject zero
progress, read failure and close failure without returning partial bytes, and
check exactly one close on each path.

This exercises the same `read-open-source` / `read-step!` loop used by
`io.file-read-chunk`, rather than a separate test-only reader algorithm. A
remaining-capacity allocation in the outer arena would exceed those bounds
under this short-read source. The canonical stdlib fixture gate runs the
fixture; profiling enables its allocation accounting assertions.

## Disposition

No unbounded request-retaining reader remains in the audited trees. The only
streaming loop is already repaired and covered by #9540. The other callers
have finite, constant request bounds or are compiler fixtures. This audit
therefore requires no production reader change, new public API, ABI change,
or dependency on another unmerged PR. Future readers should follow the
bounded scratch pattern and add a controlled short-read retention regression.
