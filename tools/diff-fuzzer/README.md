# TypeLisp differential fuzzer and optional rustc borrow oracle

`main.tl` is a seeded, reproducible TypeLisp program generator for compiler
differential testing. `rustc_oracle.tl` is an optional dev-only paired
ownership/borrow generator that emits matching `.tl` and `.rs` files for local
cross-checking against `rustc`.

## Differential fuzzer

Run the default 500-seed campaign via the thin POSIX wrapper:

```sh
scripts/run-diff-fuzzer.sh --seeds 500
```

Options:
- `--seeds N` (default `500`)
- `--seed-start N` (default `1`)
- `--compiler <path>` (default `target/stage0/typelisp`)
- `--jobs N` (parallel workers; auto-detected by default)
- `--verify-ir` / `--no-verify-ir` (IR verification enabled by default)
- `--out-dir <dir>` (default `target/exp/diff-fuzzer`)

Each seed checks:
1. `typelisp check` vs `typelisp build` accept/reject agreement.
2. `typelisp compile --verify-ir` across optimization levels 0, 1, and 2 (when enabled).
3. Exact exit-code and stdout parity across `--opt-level 0`, `1`, and `2`.
4. Exact `--backend-mode scalar` vs `--backend-mode avx2` parity on SPMD seeds (when the host CPU supports AVX2).
5. Active `tl_arena_poison_enable` execution without traps/crashes on arena seeds.

Generated profiles cover arithmetic/casts/match, nested `while`/`for` with
multi-latch `continue`/`break`, `Box`, `__tl_dyn-array`
(`array-ref`/`set!`/`array-length`/`__tl_array-push!`), structs, `&`/`&mut`
borrows, scoped `with-arena`/`with-scratch`, and SPMD `foreach`/`spmd-reduce`
kernels.

## Optional local rustc differential oracle

`rustc` is never a build dependency. When `rustc` is installed locally, run:

```sh
scripts/run-rustc-oracle.sh --seeds 100
```

If `rustc` is absent from `PATH`, the script skips cleanly with exit code 0.
When `rustc` is available, it compares `typelisp check` against
`rustc --crate-type lib` accept/reject verdicts across 8 paired ownership and
borrow categories and reports the exact agreement rate.
