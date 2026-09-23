# Remove dead shifts with valid literal counts

Dead-code elimination previously retained every scalar shift because invalid
counts must abort, even when its result is unused. Prove the narrower case:
when the count is an integer literal in the shifted operand's width, an unused
shift cannot abort and can be removed. Both the map and array DCE paths use the
same predicate. The count keeps its independent IR type; unknown, negative,
width-equal and too-large counts retain their trap. Other passes keep the
existing conservative operator-only predicate.

The array sweep checks whether the result is live before doing the extra count
proof. This keeps its common live-instruction path from paying for a proof it
cannot use. Removing
a dead shift drops its operand uses through the existing backwards DCE sweep;
side-effecting instructions that produced those operands remain.

## Evidence

Base: upstream `547c5072`, which includes the global-initializer fix merged while
this work was in progress. Compilers built at opt 2. Measurements use Linux on
an AMD Ryzen 9 9950X, Clang 22.1.8 and Valgrind 3.25.1, on a shared host.

The `discard-valid` function in the regression fixture has four discarded,
valid shifts whose input producers mutate a counter. Base emits all four shifts
and three staging moves; the candidate removes those seven instructions and
keeps all four mutations. Function text shrinks from 74 to 49 bytes (-33.8%).
Both binaries preserve the final counter and return 42.

The 44 paired opt 2 benchmarks pass exact output/status comparison (three timing
rounds). All twelve compiler-kernel TypeLisp instruction counts are unchanged.
This is an improvement to dead code removal, not a demonstrated wall-time gain
in that corpus. No instruction baseline is refreshed. Local C-row drift remains
specific to the host Clang version.

Compiling `src/compiler_liveness.tl` at opt 2 executes 32,581,369,434 instructions
versus base's 32,582,795,722 (-0.0044%), effectively flat. This is not a claimed
wall-time compiler speedup or evidence of general LLVM parity.

## Validation

- 141 optimizer inline tests pass, including a new matrix over eight integer
  operand types, both shift directions, independent signed/unsigned count types,
  count zero, width-minus-one, width, negative and unknown counts, and live
  results. It exercises both map and array DCE. Optimizer smoke exits 42.
- The runtime fixture preserves side effects while removing valid dead shifts
  at opt 1/2; opt 0 also returns the same result. Dynamic valid counts still run,
  and dynamic invalid counts retain exact diagnostics and exit 129.
- The existing signed negative, width-invalid and unsigned-high-count trap
  fixtures gain explicit opt 2 rows on Linux and Windows, so DCE cannot silently
  suppress those aborts.
- All 676 Linux integration cases pass. Windows execution remains for CI.
- Opt 2 bootstrap reaches byte-identical stage2/stage3 assembly.
- Linux/Windows IR parity (14 sources x three levels) and assembly parity (six
  sources x three levels, existing allowlist) pass.
- Changed TypeLisp files pass format/lint; implementation-language policy and
  diff checks pass.

Artifacts: `target/exp/dead-shifts/`, including the base/candidate fixture
assembly and objects, `full-bench/`, `counts/`, `*-liveness.cg`, and test,
integration, parity and bootstrap logs.
