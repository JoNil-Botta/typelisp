# Dense optimizer value-source counts

GVN, LICM, bounds elimination, and call-memory analysis query how many
definitions a function-local value has. These IDs are dense; hashing them adds
work without providing a useful sparse representation. `OptValueSources` uses
one zero-initialized counter per ID, grows geometrically, and reserves slot zero
for the existing expression-candidate count. Parameter definitions and repeated
instruction destinations still contribute separately: only count one is stable.

The inventory lives in its caller's optimizer scratch arena. No process-global
cache or cross-function state is introduced. The change does not alter optimizer
decisions or the supported language.

## Same-host measurement

Linux x86-64, Valgrind 3.25.1, opt2-built compilers; upstream production sources
at `b01f4b32` (identical to `4cc4b755` apart from CI scripts and testing docs):

| Workload | Upstream instructions | Dense counts | Reduction |
| --- | ---: | ---: | ---: |
| Compile `src/compiler_liveness.tl` at opt2 | 32,495,594,520 | 32,411,090,886 | 0.260% |

Both compilers emitted byte-identical assembly. This is a local compiler-work
measurement, not an LLVM parity claim or a replacement for the CI-owned
`self_compile` baseline. Wall-clock samples on the shared host were noisy.

Three alternating pairs compiling the same branch `src/main.tl` at opt2 took
29.222 / 35.712 / 28.061 seconds with upstream and
26.653 / 26.742 / 27.507 seconds with dense counts. Medians are 29.222 and
26.742 seconds (8.49% lower), but the host was shared with other work, so these
timings are supporting evidence rather than a deterministic gate.

Compiler SHA-256 identities:

- Upstream: `589e7fd523cf5057ac5d2aeff6299f4e670b49c7237ca2a285245980db3c9ed1`
- Dense counts: `215d7b70e9bdeba90f52eb96444caf997ef8bd66d1cb1fdb7840a753e92fb464`

Build each checkout's `src/main.tl` at opt2 with the same seed, then run each
compiler from the same source directory, using separate output names:

```sh
valgrind --tool=cachegrind --cache-sim=no --branch-sim=no \
  --vex-guest-chase=no --cachegrind-out-file=target/exp/value-sources/run.cg \
  "$COMPILER" compile src/compiler_liveness.tl \
  -o target/exp/value-sources/run.s \
  --stdlib-root stdlib --stdlib-root src --opt-level 2
```

## Validation

- 141 optimizer inline tests and the optimizer smoke suite pass at opt2.
- All 44 existing TypeLisp/C benchmark pairs agree on stdout, stderr, and exit
  status; their opt2 assembly is byte-identical to upstream's output.
- Successive self-compilations produce identical opt2 assembly.
- Focused coverage checks counter growth, duplicate definitions, absent IDs,
  the candidate sentinel, maximum-i64 lookup, and independent inventories.
- Changed TypeLisp sources pass formatting and lint checks.
