# Linux short copies

The Linux runtime used `rep movsq` followed by `rep movsb` for every forward
`tl_memcpy`/`tl_memcpy_fresh`, including zero-length and one-byte copies. Their
startup cost dominates workloads that build many short strings.

Copies of 1–64 bytes now use bounded scalar or SSE loads and stores. Every
source load precedes every destination store, including the overlapping
head/tail windows, so `tl_memcpy` keeps its memmove semantics in both overlap
directions. A zero count touches neither pointer. The one-byte entry avoids
size dispatch for byte-at-a-time text-buffer appends. Larger copies and the
separate forward-loop propagation helpers keep their existing copy cores.
Windows already has a different small-copy implementation and is unchanged.
The executable-template catalog pins the new bytes and ordered branch/return
events; its construction census and tests are updated with it.

Measured on Ryzen 9 9950X, Linux, against main `d519df5c7`, with Clang `-O2`.
No benchmark source or iteration count was changed in the checked-in suite.

| Workload | Main Ir | Candidate Ir | Difference |
| --- | ---: | ---: | ---: |
| `asm_render` | 748,623,392 | 747,711,723 | −0.122% |
| `opt_runtime_string_ops` | 32,461,438 | 32,341,438 | −0.370% |
| `peephole_lines` | 421,805,259 | 421,805,253 | −6 |

All three candidate counts were identical across three runs. For a longer
string-operations run (600,000 rounds), 15 rotated CPU-14 samples gave medians
of **56.301 ms main, 20.738 ms candidate, and 26.104 ms Clang**, with identical
stdout `64200000` and exit status. This is one workload, not general LLVM
parity. A seven-round run at the suite's normal length gave 1.988 ms candidate
and 2.674 ms Clang. The string-operations executable gains **179 text bytes**
(8,680 → 8,859); the small-copy dispatch is a deliberate size/speed tradeoff.

Correctness checks include a committed runtime fixture at opt0/1/2: 75,140
copy/overlap/alignment cases at lengths 0–129, plus 1,040 protected-page cases
on Linux. Each case verifies untouched bytes as well as the copied range.
Zero-length calls also use inaccessible pointers. An independent C oracle
against libc `memmove`/`memcpy`, linked to the emitted runtime assembly, passed
2,643,984 cases at lengths 0–257, including protected pages at either end of
both source and destination. The forward-copy propagation fixture is retained
and runs as part of integration validation.

The instruction ratchet also refreshes the already-lower current-main CRC32
count (323,300,350 → 323,240,350). No baseline is raised. Hosted C baselines
are preserved: the local Clang build produces different absolute counts.
