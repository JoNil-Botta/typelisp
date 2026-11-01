# AES generated-code regression boundary

The initial pins were reviewed with the fetched stage0 identified in the owner
evidence, for both x86-64 ABIs at opt1 and opt2. The required gate rebuilds them
with the branch bootstrap compiler. A pin is a complete instruction/label-body
hash, not a cryptographic timing proof. No source file, instruction count or
unused helper alone can satisfy this boundary.

The extractor selects every emitted `crypto_aes_core` function, the exported
`aes_audit_production_128`/`256` roots, their Windows `$typelisp` bridge bodies,
and the real ordinary-entry `main`. All four target/opt outputs must assemble.
Windows entry setup adds only its public argc/argv stores; every AES helper
and retained root is byte-identical to the reviewed library-context body.
It preserves opcodes, operands, memory addresses, local
labels, branch targets, constants and calls, omitting only assembler metadata
and comments. It starts extraction only at an actual selected function label, not a forward
`.globl` declaration, and rejects duplicate definitions and malformed pin rows.
It resets its symbol inventory on each invocation and compares
both the full inventory and hashes; missing, additional, changed or newly
inlined work requires renewed review. The fixture compiles twice identically.

## Public control and address inventory

- `xtime` has no conditional edge, data comparison, lookup or indirect call.
  At opt2 it is inlined into `gf-mul`; that containing body is checked instead.
- `gf-mul` has one eight-step public loop at opt1 and a fully unrolled,
  branch-free eight-step body at opt2. Its operands are secret bytes, but they
  feed only fixed shifts, masks, negations and XORs. It has no indexed memory.
- `sbox` has no conditional edge or indexed memory at either level. It uses
  the shared eleven-multiply x^254 chain and fixed affine rotations. Opt2
  inlines some multiply work into it and into actual round/expansion callers;
  all those containing bodies are pinned. No byte selects a table or branch.
- `add-round-key!` visits sixteen offsets; opt2 uses public two-byte unrolling
  with 14/16 guards. Indices derive from the byte counter and public round.
- `sub-bytes!` visits sixteen offsets. Its S-box may inline, but byte values
  remain arithmetic operands; its single public loop controls addresses.
- `shift-rows!` uses two sixteen-byte loops, or their public unrolled forms.
  The gather index is `row + 4*((column+row)%4)`, derived only from the public
  counter. The sixteen-byte copy scratch is wiped through `wipe-words!`.
- `mix-columns!` uses four public columns, fixed offsets 0..3, masks and XORs.
  At opt2 it inlines into the actual cipher. No column byte becomes an address.
- `expand!` copies exactly the public key length, then emits public four-byte
  words until 176/240. Its variant/remainder branches depend on the output
  counter and 16/32-byte key length. Division guards and cold abort edges also
  test only those public operands. AES-256's additional SubWord at byte offset
  16 modulo 32 is retained. Opt1 has twelve conditional edges, opt2 twenty-six
  including public unrolling and inlined eight-step GF loops. Its temporary
  word is wiped after the expansion.
- `cipher!` copies exactly sixteen bytes, applies initial AddRoundKey, uses
  the public 10/14 round bound, and has a separate final SubBytes/ShiftRows/
  AddRoundKey path with no MixColumns. Opt1 has three conditional loop edges;
  opt2 has thirteen including inlined byte/column loops and unrolling. All
  indexed operands derive from pointers plus public byte/row/column/round
  counters. Ciphertext is copied out only after the last round; the local
  state is then volatile-wiped. Inlined ShiftRows retains its separate wipe.
- Preflight/constructor edges use only public nullness, state/generation,
  lengths/capacities, result tags and backing addresses. The constructor calls
  storage allocation and length publication before `expand!`, then closes
  the raw key. Stale generations return before acquiring cleanup ownership.
  Block preflight reaches `cipher!` only after every metadata/overlap check.
- Typed roots pass literal schedule/round pairs 176/10 and 240/14 to the shared
  checked function. Real main uses both consuming constructors and repeated
  calls, including actual optimizer inlining. Windows exported roots have
  both their ABI thunk and `$typelisp` body in the inventory. Its main's public
  runtime initialization callback is also pinned; AES bodies have no indirect
  call or jump. No S-box/T-table/jump-table reference or data-selected address
  appears in the reviewed AES bodies.

All stack offsets and argument-register differences between ABIs are pinned
independently. The existing required `secret-*` rows separately retain the
volatile full-capacity owner/wipe implementation. Runtime vectors and ownership
checks establish semantics alongside this code-shape boundary. Paired test-only
source instrumentation establishes equal visited work sites for first/middle/
last-bit changes; it does not prove equal hardware timing.

When a compiler change alters these bodies, inspect the entire affected
retained/inlined production closure before replacing any pin. Do not accept a
missing helper by skipping its work, and do not bless generated hashes without
reviewing branch/address provenance, round completeness and final wipes.
