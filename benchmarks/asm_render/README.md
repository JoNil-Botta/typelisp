# asm_render

Backend assembly text emission over the compiler's own emitted assembly.

`bench.tl` and `baseline.c` run the TypeLisp backend's line renderer: the small
operand helpers that build `%eax`, `$-1`, `-1904(%rbp)`, `(%rdi,%r11,8)` and
`SYM(%rip)` as fresh arena `String`s, the `str_cat.str-cat` and
`compiler-backend-asm-append*` spellings that turn a head plus its operands into
one line, the per-function `CompilerBackendAsmBuf` those lines are copied into,
and the `stdlib.text_buf` chunk list every finished function body is handed to
before the module text is rendered once. It runs over the token stream of a
contiguous slice of the assembly the stage0 compiler emitted for
`src/compiler_load.tl` — the text the backend itself produced.

The re-rendered text is compared with the original: the unrotated round folds a
64-bit FNV-1a over every output byte and aborts unless the fold and the byte
count equal the values the exporter recorded for the slice. One equality proves
every operand helper, every head, and every separator at once.

## Mirrored compiler functions

| Compiler function | What the kernel replicates |
|---|---|
| `compiler-backend-asm-buf-with-capacity` (`src/compiler_backend.tl`) | the per-function body buffer, sized `compiler-backend-asm-bytes-per-instr` (64) × lines, floor 16 |
| `compiler-backend-asm-buf-grow!` / `-reserve!` | grow to `max(2 × cap, needed)` with a word-then-tail copy of the live prefix, checked once per append |
| `compiler-backend-asm-copy-part!` | the inlined per-part move loop: whole 8-byte words, then the tail bytes |
| `compiler-backend-asm-append` / `-append2` / `-append4` / `-append5` | the one-, two-, four- and five-part appends, including the `n == 0` early out in `-append` and the `off`/`ob`/`oc`/`od`/`oe` offset chain |
| `compiler-backend-asm-buf-finish` | the finished body handed out as a `String` aliasing the buffer's storage |
| `compiler-backend-append-located-instr` | the finished body appended to the module-level `text_buf.TextBuf` |
| `compiler-backend-reg-part` / `-reg-part-by-size` | the fifteen-arm `string.eq` chain over 64-bit register spellings and the four-way size select of the literal part |
| `compiler-backend-address-add-byte-offset` | `disp == 0` returns the address unchanged; otherwise `int->string`, then the `addr[0] == '('` test choosing `disp(addr)` over `disp+addr` |
| `compiler-backend-frame-offset-render` / `compiler-backend-slot-with-backend-state` / `-stack-memory-operand` | a memory operand as `str-cat` of the decimal displacement and the parenthesised base, including a displacement that is spelled `0` |
| the `movq` / `leaq` / `cmpq` / `jmp` / `call` emitters (`"    movq " src ", " dst "\n"`, `"    jmp " target "\n"`, `compiler-backend-emit-load-var-with-plan-into`, `compiler-backend-abort-site-load-arg0`, the `.globl` / `.quad` / `.type` / `.size` directive emitters) | the exact part structure of each line: a head carrying the indent and the trailing space, operands separated by `", "`, a final `"\n"` |
| `str_cat.str-cat` → `str-cat-scoped` (`stdlib/str_cat_runtime.tl`) | called, not reimplemented: two to five operands expand to `string.concat3/4/5(-borrowed)`, six or more to `str-cat-pack-new` + `str-cat-pack-part!` + `str-cat-concat-packed` |
| `string.concat3-borrowed` / `-concat5-borrowed` / `concat-all` (`stdlib/string.tl`) | sum the lengths, return `""` when the total is zero, one bump allocation, one word-then-tail copy per part |
| `string.int->string`, `-negative-digit-count`, `-write-negative-digits!` | the comparison ladder for the digit count and the negative-value digit loop (`next = cursor / 10`, `digit = next * 10 - cursor`), ported byte for byte into C — no `snprintf` |
| `string.eq` | length, then pointer identity, then whole words and the tail |
| `text_buf.append` / `chunk-cons` / `text-buf-owned-store-commit!` / `text-buf-store-copy-and-commit` (`stdlib/text_buf.tl`, `stdlib/text_buf_family.tl`) | nil → inline chunk → dense store of 32 slots, in-place commit while the store has room, otherwise a doubling reallocation with a prefix copy; an empty chunk is dropped |
| `text_buf.render` / `render-chunks` / `fill-rev-into` / `copy-chunk-into` | one zeroed allocation of the total length, chunks walked last to first, chunks of 16 bytes or fewer copied byte-wise and longer ones word-wise |
| `arena` discipline (`compiler-backend-state-lazy-table-arena-ensure!`, `in-arena`) | every operand `String`, line `String`, body buffer and rendered text is allocated in a round-scoped arena that is reset, not freed, once per round |

## Fidelity

**Kept.** The whole rendering path, byte for byte: the token stream feeding it
is the backend's own pre-render operand structure, and the output is the
compiler's own assembly text — the corpus is not a model of the input, it is the
input recovered from the output, and the self-check proves it.

- Both emission spellings the backend currently uses are present, each where the
  backend uses it. Instruction lines with one or two operands are written
  straight into the body buffer by `-asm-append4` / `-asm-append5`, which is
  what `compiler-backend-emit-load-var-with-plan-into` and its neighbours do
  today (the `compiler-backend-asm-copy-part!` comment records exactly why those
  call sites stopped allocating a line `String`). Directive lines, three-operand
  instruction lines and label lines go through `str_cat.str-cat` and one
  `-asm-append`, which is what every emitter that still returns a `String` does
  (`compiler-backend-emit-function-entry-fpo`,
  `compiler-backend-abort-site-descriptor-after-call`, the `"    jmp "` and
  `"    call "` sites). Operands are `str-cat`ed in both.
- Every operand helper allocates, exactly once, the way the backend's does: one
  `String` per immediate, per decimal, per rip-relative symbol, per memory
  address, plus one more for a displaced address. Register parts and plain
  symbols are literals and table entries, so they allocate nothing — again as in
  the backend.
- `str-cat`'s two expansions are both exercised: three- and five-part lines take
  the direct `concat3`/`concat5` helpers, while a `disp(base,index,scale)`
  address (seven parts) and a three-operand line (seven parts) take the packed
  path through `str-cat-pack-new` and `concat-all`.

**Dropped, and why the kept part is what is measured.**

1. **The operand-string caches are dropped.**
   `compiler-backend-slot-with-backend-state` and
   `compiler-backend-frame-offset-render` memoize the first 8-byte-aligned slot
   spellings in an epoch-stamped table, so a repeated `-1904(%rbp)` costs a
   lookup rather than a render. Keeping the cache would measure an array probe;
   the packet's subject is the render, so every operand is rendered every time —
   which is exactly what the uncached arm of both functions does (and the only
   arm for offsets past the cache capacity). Both languages skip the cache
   identically.
2. **No `CompilerBackendState` and no interning.** The backend reaches symbols,
   labels and register spellings through the state's tables
   (`compiler-abi-register-spelling`, `compiler-ir-label-text`,
   `compiler-backend-global-shared-view`); here they are ids into one name table
   read as a shared view, which is the same one-load access those accessors
   compile to. Nothing about the rendered bytes changes.
3. **Emission decisions are not re-made.** Instruction selection, the register
   allocator and the peephole already ran — their results *are* the corpus. This
   benchmark is the text stage only, which is where the ~62 MB a stage1
   self-compile writes is actually produced.
4. **Registers outside `compiler-backend-reg-part`'s table** (`%rsp`, `%xmm*`,
   `%fs:...`) are plain symbol operands, because that is how they reach the text
   in the compiler too: `compiler-backend-reg-part` panics on them and
   `compiler-abi-register-spelling` hands them over as literal names.
5. **A line whose operands do not fit the operand grammar is kept verbatim**
   (70 of 105,164 lines: `.string` payloads, `.byte` runs, `.set X, . - Y`,
   `0(,%rbp,1)`). They are appended with `-asm-append2`, which is a real emitter
   spelling, and they keep the re-render byte-exact. Lines with more than three
   operands would be kept verbatim too; the slice has none.
6. **The `.loc` / `.cv_loc` prefix of `compiler-backend-append-located-instr` is
   not present**, because the corpus was compiled without debug line tables. The
   function's other half — the finished body appended into the module TextBuf —
   is kept.
7. **`compiler-backend-asm-buf-splice!`** (the emergency-spill wrap that shifts
   a live tail right) is not exercised: nothing in the corpus records where the
   register allocator wanted one. It is a rare cold path off the append cursor.

## Corpus

`data/asm-tape.txt` — 2,013,577 bytes; `data/asm-names.txt` — 875,925 bytes;
2,889,502 bytes together. 2,091 function chunks, 105,164 lines, 22,222 names.

The slice they encode is 3,444,536 bytes of assembly with FNV-1a
`-4053354006740075984` (unsigned `14393390066969475632`) — the two numbers the
kernels assert.

Line kinds: 80,471 instructions, 16,397 labels, 6,287 directives, 2,085 blank,
70 verbatim. Instruction and directive arities: 57,658 two-operand, 25,404
one-operand, 3,386 zero-operand, 310 three-operand. Mnemonic mix (108 distinct):
`movq` 29,442, `call` 6,427, `cmpq` 4,417, `leaq` 4,296, `movups` 3,418, `ret`
3,362, `popq` 2,700, `jmp` 2,569, `pushq` 2,552, `addq` 2,312, `testq` 2,256,
`movl` 2,154, then a tail of jumps, `.globl`/`.type`/`.size`, SSE moves and
setcc. Operand kinds: 67,037 register, 33,445 plain symbol, 25,824 memory,
11,617 immediate, 3,719 rip-relative, 8 bare decimal.

Layout: `names chunks lines slice-bytes slice-fnv`, then per chunk a line count
followed by that many rows. A row is `kind` plus its payload — blank, verbatim
(name id), label (name id), or directive/instruction (head id, operand count,
operands). An operand is `okind` plus its fields: register (64-bit spelling id,
byte size), immediate (value), decimal (value), memory (base id, index id or
-1, scale, displacement, displacement-present), rip-relative (symbol id), plain
symbol (name id). `#` starts a comment to end of line. The full grammar and the
rendering rule are documented at the top of `tools/export_asm_tape.py`.

`data/asm-names.txt` has two `#` header lines and then exactly `names` lines,
one name per line in id order; the kernel reads them once into a `String` array
and the tape refers to them by id. Heads carry their indent and trailing space
(`"    movq "`, `".globl "`), so a name may end in a space.

Provenance: `target/bench6-dumps/compiler_load.opt2.s`, the 15.6 MB `.s` the
stage0 compiler writes for `src/compiler_load.tl` at `--opt-level 2`. A chunk
starts at a line whose first non-space bytes are `.globl` and runs to just
before the next one, the same chunking
`benchmarks/peephole_lines/tools/export_asm_slice.py` uses. The kept range is
the contiguous run of chunks 1151..3241: chunk 1151 is the runtime's data and
bss block (`.section`, `.balign`, `.zero`, `.byte`, `.set`, `.quad`, `.data`,
`.text`), chunk 1153 is `main`, and the run continues through whole functions
until the byte budget is reached. Starting there skips the 1,150-chunk `.quad`
prologue of module globals and the single 58,168-line rodata blob that
precedes it, either of which would have filled the budget with data directives
instead of instructions.

`data/.gitattributes` pins both files to LF: the names file is split on LF, so a
CRLF checkout would append `\r` to every head and symbol and the byte-identity
self-check would abort.

### Regeneration

This corpus needs no `--dump-ir`; it is plain `compile` output. (`--dump-ir` of
a compiler module currently segfaults on main in every available compiler build
— the orchestrator tracks that; the other bench6 corpora use the 2026-08-25
snapshot compiler at commit `98bdc6f5` under `target/bench6-dumps/aug25/` for
their IR dumps.)

```sh
# 1. the compiler's own emitted assembly for one of its modules
systemd-run --user --scope -q -p MemoryMax=8G -p MemorySwapMax=0 \
    target/stage0/typelisp compile src/compiler_load.tl \
    -o target/bench6-dumps/compiler_load.opt2.s \
    --stdlib-root stdlib --stdlib-root src --opt-level 2

# 2. export (the byte budget and the start chunk are part of the corpus
#    identity; the exporter re-renders its own tape and fails if the result is
#    not byte-identical to the slice)
python3 benchmarks/asm_render/tools/export_asm_tape.py \
    benchmarks/asm_render/data/asm-tape.txt \
    benchmarks/asm_render/data/asm-names.txt \
    2900000 1151 target/bench6-dumps/compiler_load.opt2.s
```

The exporter prints the slice's byte count and FNV-1a, the line-kind counts, the
arity histogram, the mnemonic mix and the operand-kind histogram on stderr.

## Design parameters

| Parameter | Value | Why |
|---|---|---|
| corpus path | argument 1 | runtime-opaque; the corpus is fixed. The names file is the sibling `asm-names.txt` in the same directory, derived identically on both sides |
| rounds | argument 2, `10` in `optimization.tsv` | tunes TypeLisp Ir to 0.88 G and C to 0.63 G |
| round rotation | starting function chunk advances by one per round | a chunk is the backend's own emission unit, so rotating them is faithful; the output is a permutation of the same bytes, so every round's FNV differs while the byte count does not. The round index and the rotation index are folded too |
| self-check | round 0 (rotation 0) asserts `length == 3444536` and `FNV == -4053354006740075984` | the re-rendered text is the corpus slice byte for byte; a mismatch aborts with a message |
| body buffer | `64 × lines` per function chunk, floor 16, doubling growth | `compiler-backend-asm-bytes-per-instr` and `compiler-backend-asm-buf-grow!` |
| chunk store | first capacity 32, doubling with a prefix copy; render copies chunks of 16 bytes or fewer byte-wise | `text-buf-store-new`, `text-buf-store-copy-and-commit`, `render-small-chunk-limit` |
| arena | one round-scoped arena, reset per round | the backend's operand storage arena is reset per function/per compile; nothing rendered outlives its round |
| checksum | 64-bit FNV-1a, no division | identical bits in TypeLisp i64 and C `uint64_t`; no `%` on a live loop-carried dividend (#5982) |
| folded per round | round index, rotation index, output length, FNV of the whole output, and the line count of each of the five line kinds | the required quantities |
