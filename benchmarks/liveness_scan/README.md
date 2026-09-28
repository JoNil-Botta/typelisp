# liveness_scan

The compiler's backward liveness fixpoint, over real per-function CFGs.

`bench.tl` and `baseline.c` implement both entries of
`src/compiler_liveness.tl`: the ordinary backward pass (`compiler-live-fixpoint`
reached from `compiler-live-analyze-function`) and the edge-precise pass
(`compiler-live-fixpoint-ep` reached from
`compiler-live-analyze-blocks-edge-precise`, which drops phi operands from block
uses and unions each block's `phi-out` set into its live-out). The worklist, the
pick order, the predecessor re-enqueue, the change test, and the
thirty-two-bits-per-i64-word packing are all the compiler's. See the header
comment of either file for the function-by-function correspondence and for what
is deliberately out of scope.

One deliberate departure: the checksum's population count clears the lowest set
bit instead of testing all thirty-two bit positions the way
`compiler-live-set-word-count-bits` does. Both spell the same value, but the
compiler's spelling would make the checksum dominate the row, turning it into a
measurement of the checksum rather than of the dataflow.

Each round runs both entries over every function of the corpus.

## Input

`data/cfgs.txt` is captured from the compiler compiling itself, without
modifying the compiler: `typelisp compile src/compiler_liveness.tl --dump-ir`
writes the final optimized IR -- the same IR the liveness pass consumes -- and
a Python exporter converted it into a compact all-integer corpus.

| property                          | value        |
|-----------------------------------|--------------|
| source module                     | `src/compiler_liveness.tl` (plus every module it imports) |
| bytes                             | 437,362      |
| functions                         | 2,087        |
| blocks                            | 12,172       |
| successor edges                   | 12,251       |
| bitset words min / median / p90 / max | 1 / 1 / 3 / 4088 |
| sum of `blocks * words`           | 990,731      |

Blocks appear in dump order, which is the lowering's deterministic reverse
postorder -- the order `compiler-live-worklist-pick!` walks backwards.

Function parameters are deliberately not treated as defs, because the compiler
derives defs only from instructions; a parameter read therefore stays in the
entry block's use set exactly as it does in `src/compiler_liveness.tl`.

### Corpus format

Whitespace-separated non-negative decimal integers, and nothing else, so both
implementations parse it with the same trivial scanner:

```
1                      format version
F                      function count
repeated F times:
  vars nblocks
  repeated nblocks times:
    nsucc  succ...     block indices inside this function
    nuse   var...      compiler-live-block-use-def-seq (phi operands included)
    nnophi var...      compiler-live-block-use-def-nophi-seq-from
    ndef   var...      compiler-live-instr-defs, unioned over the block
    nphi   var...      compiler-live-phi-out-add-inputs!
```

## Regenerating the corpus

Exported at `5fce734af` (#5989) from the compiler's `--dump-ir` output; function
names in this README refer to that commit. See
[Compiler-derived kernels](../README.md#compiler-derived-kernels).
