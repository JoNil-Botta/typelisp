# Address-taken local matrix (#8190)

Every `*.tl` here is compiled and run by `scripts/verify-addr-taken-matrix.sh`
(CI gate `stage2-addr-taken-matrix`) at `--opt-level 0`, `1` and `2`. A local
whose address is taken is memory, not a value: a store or call through the
exposed address redefines it without naming it, so no pass may forward a fact
about it. Each program isolates one optimizer shape that could otherwise
assume the local was immutable.

The oracle is `--opt-level 0`. Each program declares that result in its leading
comment block, and the gate fails when the three levels disagree or differ from
it:

```tl
;; Expected exit 6 at --opt-level 0, 1 and 2.
```

Programs take no arguments (`io.arg-count` is 1) and print nothing; `main`'s
value is the exit code. Add a program to this directory and give it that
header; do not add it to a list. A binding that exists only to take a local's
address and is never read is named `_p`, the lint convention for an
intentionally unused binding; adding a read or write through it would itself
invalidate the facts the program tests.

`pending/` holds the programs whose levels still disagree today. Their fixes
land in separate changes, and each moves its own file out of `pending/`; the
gate skips that directory, so `pending/README.md` is the current list.
