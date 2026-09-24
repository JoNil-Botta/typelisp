# Literal argument in a repeated read-only call

The helper sums 64 runtime-initialized words and adds a literal bias. Before
SSA, lowering gives that literal its own `Mov` temporary inside the caller's
loop. The temporary has one definition and always holds the same value, so it
must not prevent caching the read-only helper's result after its first call.

The caller folds the result and its changing iteration index into a wrapping
checksum. This preserves an observable outer-loop recurrence while allowing
both compilers to eliminate redundant helper work. The C implementation uses
`uint64_t` arithmetic so every overflow is defined identically.

Default arguments: `13 1000000`. Zero and negative round counts perform no call.
The case is registered once in `instruction-main`, which checks opt2 output
parity and exact TypeLisp/scalar-C instruction counts.
