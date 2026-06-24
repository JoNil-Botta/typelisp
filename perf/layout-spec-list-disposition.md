# Layout/Spec List Disposition

Measurement slice for #3612. This records the current residual cost of the
typechecker layout/spec metadata list families after the inline aggregate layout
cache, without changing storage representation.

## Harness

Profile rows are emitted by a compiler built with `--cfg compile-profile`.
`scripts/verify-compile-profile.sh` now checks that every
`typecheck.layout.*` row is present. A branch-built Linux compiler was measured
with the existing cachegrind harness:

```sh
bash scripts/verify-compile-profile.sh
wsl bash -lc 'cd /mnt/c/dev/typelisp && \
  mkdir -p target/3612-linux && \
  tools/stage0-linux/typelisp build src/main.tl \
    -o target/3612-linux/typelisp \
    --stdlib-root stdlib --stdlib-root src && \
  scripts/measure-instruction-counts.sh \
    --runs 1 --self-compile-only \
    --output target/3612-ir-branch \
    target/3612-linux/typelisp'
```

The profiled Windows self-compile used:

```powershell
target\compile-profile-verify\windows\typelisp-profile.exe compile src\main.tl `
  -o target\3612\self-profile.s `
  --target windows-x86_64 `
  --stdlib-root stdlib `
  --stdlib-root src
```

## Results

Self-compile profile total: `16,049 ms` (`16,241 ms` host elapsed).

Cachegrind self-compile for the branch-built Linux compiler:

| row | baseline Ir | measured Ir | delta |
| --- | ---: | ---: | ---: |
| `self_compile/compile_cli_opt1` | 107,680,565,264 | 107,775,098,231 | +94,532,967 (+0.0878%) |

The instruction-count delta is inside the documented 0.5% self-compile
tolerance. This change only adds profile-gated counters plus one small fixture;
normal builds do not execute the counter increments.

Self-compile `typecheck.layout.*` counters:

| counter | value |
| --- | ---: |
| `repr_c_field_builds` | 0 |
| `repr_c_field_visits` | 0 |
| `inline_field_builds` | 105 |
| `inline_field_visits` | 0 |
| `inline_payload_builds` | 630 |
| `inline_payload_visits` | 0 |
| `inline_variant_builds` | 467 |
| `inline_variant_visits` | 0 |
| `stdlib_field_spec_builds` | 0 |
| `stdlib_field_spec_visits` | 0 |
| `stdlib_variant_spec_builds` | 0 |
| `stdlib_variant_spec_visits` | 0 |
| `cache_hits` | 942 |
| `cache_misses` | 168 |
| `cache_bypasses` | 0 |

The existing inline aggregate layout cache is effective on the self-compile
path: it sees 942 hits and 168 misses, and the residual typecheck footer has no
measured inline field/payload/variant traversal visits.

## Family Disposition

| family | disposition | rationale |
| --- | --- | --- |
| `TcReprCFieldLayoutList` | Defer migration | The typecheck self-compile profile shows no repr-C field builds or visits. Repr-C layout still matters for C ABI lowering and existing C ABI smoke tests, but this typecheck slice does not justify dense storage. |
| `TcInlineFieldLayoutList` | Keep cons list for now | Only 105 field layout nodes are built in the self-compile, and residual visit counters are 0 after cache hits. Dense storage would add migration risk without measured payoff. |
| `TcInlinePayloadLayoutList` | Keep cons list for now | 630 payload nodes are built, but no residual visits are measured at the typecheck footer. Revisit only if later counters show hot payload scans or generated vectors make conversion nearly free. |
| `TcInlineVariantLayoutList` | Keep cons list for now | 467 variant nodes are built, with no residual visits measured. The cached layout object already amortizes repeated enum queries. |
| `TcStdlibFieldSpecList` | Keep cons list | The stdlib field spec tables are tiny expected-shape lists and do not register in self-compile counters. Migration would be churn unless generated-vector adoption makes it free. |
| `TcStdlibVariantSpecList` | Keep cons list | Same as field specs: fixed, tiny, and not a measured self-compile cost. |

No focused storage-migration follow-up is justified by this measurement slice.
Keep the counters so future work can see when a later feature changes the cost
profile.
