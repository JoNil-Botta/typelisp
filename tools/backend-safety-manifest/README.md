# Backend safety contract inventory

`main.tl` is a self-hosted, source-derived audit map for the current IR,
lowering/ABI classifications, register scratch roles, and structured object
emission. Run `scripts/verify-backend-safety-manifest.sh` to regenerate and
compare `docs/backend-safety-contract-manifest.tsv` and exercise drift
mutations. To refresh the checked artifact after an intentional change:

```sh
typelisp build tools/backend-safety-manifest/main.tl --stdlib-root stdlib -o target/backend-safety-manifest
target/backend-safety-manifest . tools/backend-safety-manifest/registries.tsv tools/backend-safety-manifest/catalog.tsv tools/backend-safety-manifest/contracts.tsv docs/backend-safety-contract-manifest.tsv
scripts/verify-backend-safety-manifest.sh
```

`registries.tsv` names production enums. The generator reads their declarations
and requires exactly one `catalog.tsv` identity for each variant, rejects stale
identities, and requires each catalog identity to name a `contracts.tsv` family.
It checks the actual IR optimizer-effect match arms, the owning backend IR
dispatcher, the assembly/ELF/COFF serializers for structured object records,
and representative source-anchored guards. The emitted `source_site` is a
stable symbolic path and enum identity, not a volatile line number. TSV row
order follows production registry/enum order; new or deleted variants require
an intentional regenerated artifact and contract review. `witness` points to
an existing executable test or gate; it does not by itself establish that all
cases of a family have been tested.

The columns describe required behavior, not a proof that every lowering path
obeys it. `memory` records read/write/unknown, `access` records width,
alignment, or class constraints, `provenance` names the capability assumption,
`ordering` names the required relative effects, and `failure` states abort or
rejection. `optimizer_effect` is mechanically compared with
`compiler-ir-instr-effect` only for `ir_instr` rows; `n/a` in subop/object/ABI
rows deliberately does not inherit a claim of optimizer purity. Volatile and
atomic operations that are represented in lowerer/backend helper families
rather than these production enums remain outside this enumerated slice.
Direct-object rows state current target applicability; they do not claim the
in-progress shared-machine migration is complete.

The `disposition` column distinguishes mapped current routes (`checked`),
explicit fail-closed boundaries, ELF-only raw bytes, the limited shared-machine
subset tracked by #7434, unresolved effect/abort classification tracked by
#7608, and the ELF rejection of PE-only `SymbolRva32` records tracked by
#7732. In particular, `CompilerIrInstr.BinOp` still reports `Pure` while
division/remainder/shift cases can abort. `checked` means this inventory's
structural checks pass, not that all semantic obligations have been formally
verified. The live language commitments are in `SPEC.md` (safe outcomes,
memory model, SPMD and ABI sections) and feature-local tests remain
authoritative. A future contract claiming a safe-code invalid memory access or
missed trap should fail closed and be fixed or linked to a focused issue.

This slice deliberately does not register every distributed lowerer helper,
frame rule, handwritten executable template, atomic/volatile route, or all
machine encodings. #7271 remains open until those routes and remaining
semantic probes are covered; use this map to add them without silently
interpreting absence as safety.
