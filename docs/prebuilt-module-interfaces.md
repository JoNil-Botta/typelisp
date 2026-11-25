# Prebuilt module interfaces

This record locks the artifacts that let a compiled program consume a
dependency without reading its source: the `.tli` binary module interface, the
`.tlci` macro CTFE companion, and the Stage 2 precompiled archive.
[Compiler architecture](compiler-architecture.md) places them in the pipeline;
[compiler invariants](compiler-invariants.md) own the surrounding contracts.

## Purpose and artifact split

| Artifact | Holds | Never holds |
| --- | --- | --- |
| `.tli` | Semantic exports: types with layout/cleanup/lifetimes, functions with ABI and effect summaries, values, macro handles, dispatch tables, import edges, interface digests. | Parsed, expanded, typechecked or lowered dependency bodies; source text; intern ids; pointers. |
| `.tlci` | The existing native macro CTFE image: macro entry points, their compiled transformers, the sorted macro identity catalog. | Types, layouts, effect summaries, import edges. |
| `.a` / `.lib` | Stage 2 precompiled code: one `.o` member per module, one section group per function (`--gc-sections` / `/OPT:REF`), plus module data and global-init symbols. | Any interface fact; those stay in `.tli`. |

A `.tli` reader consumes exports only: it never parses, typechecks, lowers or
re-verifies a dependency body, so consumer correctness rests on the recorded
digests and on the writer emitting them from checked facts.

A macro handle carries a deterministic `tlci_entry_index` and the companion's
`tlci_catalog_sha256`; the `.tlci` stays the executable image and the handle is
its only reference, so a missing or mismatched companion fails closed instead
of re-expanding source.

Stage 2 archives hold code only. Per-function `.text.<sym>` / `.rodata.<sym>`
sections (Win64: COMDAT) let `--gc-sections`, `/OPT:REF` and the internal
linker's section GC ([#8185](https://github.com/JoNil-Botta/typelisp/issues/8185))
drop unreferenced prebuilt functions, so a prebuilt stdlib does not bloat a
linked binary. Until that GC exists an archive consumer keeps whole module
members; the wire format above is unchanged.

Distribution keeps the artifacts apart: a compact `.tli` bundle (one file per
interface, or one stdlib bundle) beside an external sysroot archive
`<sysroot>/lib/<target>/libstdlib.a` and its `.tlci` companion. Neither archive
members nor `.tli` bytes are embedded in the stage0 image, so
`scripts/check-stage0-size.sh` keeps its ledger — the 10,000,000-byte target
rows and the 15,000,000-byte limit from
[#9440](https://github.com/JoNil-Botta/typelisp/issues/9440) — untouched.

## Core invariants and resource bounds

- **No dependencies, one integer encoding.** The reader imports nothing
  beyond `stdlib.byte_le`, `stdlib.byte_reader` and `stdlib.crypto_sha256`;
  every integer is little-endian, unsigned and fixed-width, and floats appear
  only as `f64` bit patterns.
- **Bounded reading.** All reads go through the checked cursor of
  [compiler_incremental_binary.tl](../src/compiler_incremental_binary.tl):
  work, owned bytes, string bytes, counts and recursion are capped before any
  allocation, and offsets/lengths pairs are subtraction-checked before use.
- **Cryptographic integrity.** `content_sha256`, `module_sha256`,
  `import_tli_sha256`, `source_sha256`, `cfg_fingerprint_sha256` and
  `tlci_catalog_sha256` are SHA-256 from `stdlib.crypto_sha256`. This replaces
  the `.tlci` image's non-cryptographic polynomial digest
  (`h = h * 131 + b mod 2^31 - 1`), which stays `.tlci`-internal.
- **Zero process-local identities.** Every name, path, symbol and lifetime is
  an index into one dense deduplicated UTF-8 string pool; index `0` is `""`
  and means "absent". Intern ids, pool ids and pointer keys never appear, so a
  fresh job decodes what the writer encoded.
- **Canonical order.** Modules are sorted by module name; inside a module the
  imports, types, functions, values, macros, dispatches and global-write rows
  are sorted deterministically (byte order for strings, then kind, then
  symbol). `global_inits` is the one order-significant table: it preserves
  startup order. A fixed writer is bit-identical on every host; a decoder
  verifies order instead of sorting.
- **Fail-closed decoding.** Magic, `schema_version`, flag bits, section
  offsets/lengths, string-pool references, UTF-8 validity, counts, list
  lengths, `TliType` tags, cleanup/repr/ABI tags, recursion depth `<= 64` and
  every digest mismatch return a structured `TliDecodeError` (`Magic`,
  `SchemaVersion`, `Flags`, `Truncated`, `OffsetOutOfRange`, `Overlap`,
  `Utf8`, `Limit`, `StringIdOutOfRange`, `UnknownTag`, `DigestMismatch`,
  `CfgFingerprintMismatch`, `CompilerBuildMismatch`, `TargetMismatch`,
  `TrailingBytes`). Nothing is left partially decoded into a useable state.
  `schema_version` is `3` and there is no compatibility reader, so a newer
  reader rejects an older version instead of guessing.
- **Lazy, job-scoped decoding.** The Module Directory alone answers
  `inspect`-style summaries. A record decodes on first use into the current
  job's scratch arena and is dropped with that job; only projected semantic names and types enter
  the interner and type pool; the wire bytes, string pool and decoded records
  stay in the job arena, so
  `scripts/verify-compile-profile.sh` keeps its `<= 1 MiB` post-emission pool
  release and `<= 4 MiB` batch-live drift bounds.

## `.tli` v3 wire format

Bytes are packed in this order with no padding and no gaps: header, string
pool, module directory, module records, compact IR. Offsets and lengths are
absolute from byte `0`.

### File header (144 bytes)

| Bytes | Field | Meaning |
| --- | --- | --- |
| `[0..4]` | `magic` | `"TLI\0"` (`0x00494C54`, little-endian) |
| `[4..8]` | `schema_version: u32` | `3` |
| `[8..12]` | `flags: u32` | bit0 `IS_STDLIB_BUNDLE`, bit1 `HAS_COMPACT_IR`, bit2 `HAS_TLCI_COMPANION`; other bits `0` |
| `[12..16]` | `module_count: u32` | directory entries |
| `[16..24]` | `total_byte_len: u64` | must equal the file length |
| `[24..32]`, `[32..40]` | `string_pool_offset`, `string_pool_len: u64` | must not overlap another section |
| `[40..48]`, `[48..56]` | `module_dir_offset`, `module_dir_len: u64` | must not overlap another section |
| `[56..64]`, `[64..72]` | `compact_ir_offset`, `compact_ir_len: u64` | both `0` when absent |
| `[72..76]` | `compiler_build_str_id: u32` | writer's build identity |
| `[76..80]` | `target_triple_str_id: u32` | writer's target |
| `[80..112]` | `content_sha256: [u8; 32]` | SHA-256 over `[0..80] || [112..total_byte_len]` |
| `[112..144]` | `index_sha256: [u8; 32]` | SHA-256 over `[0..80] || [144..module_dir_offset + module_dir_len]` |

The build and target ids gate layout and ABI: a mismatch fails closed.
Every open verifies `index_sha256`, so the header, string pool and module
directory a lazy open reads are tamper-evident before any record decodes; a
record is then checked against its `module_sha256` when it first decodes. A
full open (`inspect`, round trips) also verifies `content_sha256`.

### String pool

`u32 count`, then `u32 offsets[count + 1]`, then the text: entry `i` is the
UTF-8 bytes `[offsets[i]..offsets[i + 1])` of the text that follows the table.
`offsets[0]` and `offsets[1]` are `0` (index `0` is `""`) and
`offsets[count]` ends the section. The writer deduplicates and sorts by UTF-8
byte order, so the pool is canonical. A lazy open reads only the count and
the table's end points; an entry's two offsets, its bounds and its UTF-8 are
checked when a record first uses it, and a full open checks every entry and
the strict order.

### Module directory

`module_count` × 56-byte entries, sorted by module name:

```
u32 module_name_str_id
u32 module_flags        ; bit0 HAS_GLOBAL_INIT, bit1 HAS_MACROS, bit2 HAS_OPAQUE_TYPES,
                        ; bit3 HAS_EXTERN_LINKS, bit4 IS_PRELUDE
u64 record_offset
u64 record_len
u8  module_sha256[32]   ; SHA-256 over record bytes only
```

`record_offset`/`record_len` stay inside `total_byte_len` and overlap no other
section or record. The 56-byte entry is scanned eagerly; records decode lazily.

### Per-module record (`TliModuleRecord`)

```
u32 module_name_str_id
u32 source_path_str_id
u8  source_sha256[32]
u8  cfg_fingerprint_sha256[32]
u32 module_flags
list<import> list<s:global_init> list<type> list<fn>
list<value> list<macro> list<dispatch>
```

`list<T>` is `u32 count` plus `count` items. `s:x` is a string-pool id; `t` is a
nested `TliType`; `s:nominal` is the canonical nominal type name string id
matching `AstType.(Struct id)` / `AstType.(Enum id)` (portable across files
without cross-file table indices).

a) `imports`: `import = s:module u8:kind s:alias s:item sha256:import_tli_sha256`, where
   `kind` is the `AstImportKind` tag (0 `Module`, 1 `ModuleAll`,
   2 `ModuleItem`, 3 `Macro`, 4 `MacroDecls`). The digest pins the dependency
   interface; a change invalidates every fact cached across it. The binding
   alias preserves the defining module's scope for native macro hygiene.
   `item` is present only for `ModuleItem`. A module generated by an import
   macro has its own record with the originating source path and digest. The
   checked import pins its generated module record alongside any dependency
   on the macro provider.
b) `global_inits`: ordered `s:symbol` startup entries. A module with runtime
   global initializers records its single `() -> unit` archive wrapper,
   `__tl_mod_init_<module-name>`. The wrapper runs the module's initializers
   and stores their results. Hydration orders dependencies before importers.
c) `types` (`TliTypeDecl`): `u8 kind` (0 `Struct`, 1 `Enum`), `s:name`,
   `s:module`, `u32 flags` (bit0 `MUST_USE`, bit1 `OPAQUE`, bit2 `COMPTIME_ONLY`,
   bit3 `IS_UNSAFE`, bit4 `HAS_CLEANUP`), `u64 layout_size`, `u64 layout_align`
   (the checked `TcLayoutInfo`), `u8 repr_kind` (0 `Default`, 1 `C`),
   `u64 repr_align`, `cleanup_tag cleanup`, `list<s:lifetime>`, then Struct
   `list<field>` or Enum `list<variant>`, where
   `field = s:name t:type cleanup_tag cleanup u64 byte_offset u64 explicit_align`
   and `variant = s:name list<payload>` with
   `payload = t:type cleanup_tag cleanup`. `cleanup_tag` is `AstFieldCleanup`
   verbatim: 0 `No`, 1 `Fn` + `s:cleanup_fn`, 2 `Owned` (tag 2 is valid only on
   struct fields and enum payloads; type-level `AstStructCleanup` /
   `AstEnumCleanup` allow only 0 and 1). `explicit_align` is `0` for a field that declares
   none, matching `AstFieldAligns`. An opaque type keeps layout, cleanup and
   lifetimes so its ABI stays exact, while callers obey the opaque construction
   and field-access gates of
   [#8733](https://github.com/JoNil-Botta/typelisp/issues/8733) and
   [#8735](https://github.com/JoNil-Botta/typelisp/issues/8735).
d) `functions` (`TliFnDecl`): `s:name`, `s:module`, `s:link_symbol`, `u8 abi`
   (0 `TypeLisp`, 1 `C`, 2 `CVarargsOpen`, 3 `CVarargsTyped`), `u8 fn_meta_kind`
   (0 `No`, 1 `Export`, 2 `SpmdCallable`), `s:export_symbol`, `u8 is_extern`,
   `u64 extern_flags`, `list<(u8 kind, s:name)> extern_link_inputs`,
   `list<(s:name, t:type, u8 is_mut)> params`, `t:return_type`, then
   `TliFnSummary`: `u32 effect_flags` (bit0 `UNSAFE`, bit1 `COMPTIME`,
   bit2 `PURE` for a checked comptime declaration or a runtime function that
   returns, writes no global, makes no indirect call and reaches no unsafe,
   extern or comptime-purity-rejected declaration; hydrated references in
   macro and comptime bodies require it, bit3 `NEVER_RETURNS`, bit4 `STORES_AMBIENT_ARENA_GLOBAL`,
   bit5 `HAS_INDIRECT_EFFECTS`, bit6 `HAS_INLINE_IR`, bit7 `MUST_USE`,
   bit8 `STORES_AMBIENT_ARENA_ARG` for writes of ambient-arena values through
   an argument),
   `u64 arena_arg_store_mask` (params 0..63),
   `list<u32> arena_arg_store_extra` (params >= 64),
   `list<(s:global_symbol, u8 write_flags)> global_writes` (from
   `TcGlobalCallEffects.graph`), `u64 inline_ir_offset`, `u32 inline_ir_len`.
   The ABI byte is wire identity, not `AstExternAbi`'s declaration order: `0`
   is the `TypeLisp` convention of
   [#8485](https://github.com/JoNil-Botta/typelisp/issues/8485), and
   `arena_arg_store_*` records which of the function's own parameters it calls
   inside an arena scope, as described in
   [#8681](https://github.com/JoNil-Botta/typelisp/issues/8681).
e) `values` (`TliValueDecl`): `s:name`, `s:module`, `s:link_symbol`,
   `t:value_type`, `u32 flags` (bit0 `COMPTIME`, bit1 `IS_UNSAFE`, bit2
   `HAS_GLOBAL_INIT`, bit3 `HAS_CONST_VALUE`), `u8 is_extern`,
   `list<(u8 kind, s:name)> extern_link_inputs`, then `u8 const_kind` and payload:
   0 `None` —, 1 `I64` `u64`, 2 `U64` `u64`, 3 `F64Bits` `u64`, 4 `Bool` `u8`,
   5 `String` `u32 len + utf8`, 6 `Bytes` `u32 len + bytes`. Only extern
   values may carry link inputs. The link-input tags are 0 `Lib`, 1
   `Search`, and 2 `Arg`, as for functions.
f) `macros` (`TliMacroHandle`): `s:name`, `s:module`, `s:macro_identity`,
   `u32 flags` (bit0 `HAS_NATIVE_TLCI`, bit1 `IS_SHELL_TLCI`, bit2
   `COMPTIME_ONLY`, bit3 `EMITS_DECLS`, bit4 `USES_EXPR_TYPE`), `u8 result_kind` (0 expression,
   1 `Decls`, 2 `Module`), `list<macro_param> params`,
   `i64 tlci_entry_index` (`-1` when absent), `tlci_catalog_sha256[32]`.
   `macro_param` matches `AstMacroParam.Param` verbatim:
   `(s:param_name, t:param_type, u8 is_by_ref, list<u8> type_kinds)`.
   `tlci_entry_index` is the zero-based registration table index returned by
   the native loader for this identity. `tlci_catalog_sha256` hashes the
   exact, decoded TLCI image that owns that registration table. An embedded
   macro resolves in its independently loadable native image. Shell records
   keep the image digest and carry entry index `-1`. An absent companion
   uses a zero digest and entry index `-1`.
g) `dispatches` (`TliDispatchDecl`): `s:name`, `s:module`, `s:link_symbol`,
   `u32 flags` (reserved, `0` in v3).

### `TliType` tags

`TliType` is `u8 tag` plus its operands, covering every `AstType` variant with
the same meanings: a child `AstType` id becomes a nested `TliType`, a
`Box AstTypeList` a counted list, a `Box AstLifetimeList` a
`list<s:lifetime>`, and a nominal id an `s:nominal`.

| Tag | Variant | Operands |
| --- | --- | --- |
| 0–16 | `I64`(0), `I32`(1), `I16`(2), `I8`(3), `U64`(4), `U32`(5), `U16`(6), `U8`(7), `F64`(8), `F32`(9), `Bool`(10), `Char`(11), `String`(12), `Str`(13), `Bytes`(14), `Unit`(15), `Never`(16) | — |
| 17 | `Expr` | — |
| 18 | `ExprList` | — |
| 19 | `Func` | `list<t> params, t ret` |
| 20 | `Tuple` | `list<t> items` |
| 21 | `Array` | `t elem, u64 len` |
| 22 | `DynArray` | `t elem` |
| 23 | `Box` | `t elem` |
| 24 | `Region` | `s:lifetime, t inner` |
| 25 | `Ref` | `s:lifetime, t inner` |
| 26 | `MutRef` | `s:lifetime, t inner` |
| 27 | `Enum` | `s:nominal` |
| 28 | `EnumArgs` | `s:nominal, list<s:lifetime>` |
| 29 | `Struct` | `s:nominal` |
| 30 | `StructArgs` | `s:nominal, list<s:lifetime>` |
| 31 | `Var` | `s:type_var` |
| 32 | `VarArgs` | `s:type_var, list<s:lifetime>` |
| 33 | `Ptr` | `t elem` |
| 34 | `MutPtr` | `t elem` |
| 35 | `Slice` | `t elem` |
| 36 | `CFunc` | `t signature, u8 mode` (0 `Nullable`, 1 `NonNull`, 2 `UnsafeNullable`, 3 `UnsafeNonNull`) |
| 37 | `Invalidate` | `s:lifetime, t inner` |

Tag values are frozen: a new `AstType` variant appends tag 38 and bumps
`schema_version`. `Expr` and `ExprList` appear only under a `COMPTIME_ONLY`
declaration or macro parameter type; nesting depth is the checked recursion
bound (`<= 64`), so no hostile file can exhaust the stack.

### Compact IR section (optional)

`compact_ir_offset`/`compact_ir_len` reserve a section for Stage 2/3 typed
three-address post-lower IR of small hot functions (for example `<= 32`
instructions), keyed by function index, so `--opt-level 2` inlines across
module boundaries without AST bodies. It is reserved in v3: with
`HAS_COMPACT_IR` clear both offsets are `0`, and a reader rejects a set bit
until that section's grammar is locked.

## Sysroot discovery

`typelisp inspect sysroot` discovers the stdlib interface for the selected
`--target` (the host target by default). `--sysroot <dir>` takes precedence
over `TYPELISP_SYSROOT`. Both select `<dir>/lib/<target-triple>/stdlib.tli`.
With neither set, discovery checks the running executable's directory and
then its parent for `lib/<target-triple>/stdlib.tli`. The executable path
comes from the operating system. `--no-prebuilt-stdlib` disables discovery,
and `TYPELISP_SYSROOT=none` disables it when no explicit path is supplied.
`typelisp build` accepts the same selection options and checks the selected
bundle's envelope before source compilation. Inspect validates the selected
bundle's compiler build and target and prints
the directory with no record decoding. Hydration validates the configuration
fingerprint and module and import digests as each closure is loaded.

A compile job keeps the source stdlib, with no prebuilt interface, at
`--opt-level 2`, when a stdlib root overrides the embedded stdlib, and when the
entry program spells a `(foreach` form: SPMD `foreach` inlines stdlib helper
bodies such as `math.f64-clamp`, which `stdlib.tli` omits. The `foreach`
condition retires once the compact IR section carries vectorizable helper
bodies.

## Staged delivery and retirement conditions

1. **Stage 1 — format and codec.** This document, a standalone `.tli`
   writer/reader (bounded, digest-checked, `TliDecodeError`-returning),
   `typelisp inspect` support, and a stdlib emit/read round-trip whose
   re-emitted bytes are bit-identical; no consumer changes semantics yet.
2. **Stage 2 — prebuilt stdlib.** Per-function section GC and
   `<sysroot>/lib/<target>/libstdlib.a`, a `stdlib.tli` loader that typechecks
   and lowers against the interface, and the opt2 compact-IR path; stdlib
   consumers stop loading source.
3. **Stage 3 — packages and incrementality.** `kind "lib"` packages publish a
   `.tli`, and the incremental identity of
   [#7023](https://github.com/JoNil-Botta/typelisp/issues/7023) keys on these
   module digests. This retires whole-body `SurfaceAstHydration`
   ([compiler_surface_ast.tl](../src/compiler_surface_ast.tl)) carried as
   `.tlci` aux kind 2 (`tlci-aux-kind-frontend-ast`).

Every stage lands its reader and writer together: no read-old-write-new window.
