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

The round state is eight local `u64` bit planes: plane j bit 4c+r holds bit j
of state[r,c], so only the low sixteen bits of each plane are live. Every
operation below is lane-uniform over those sixteen bits.

- `xtime` now only advances the public round constant. It has no conditional
  edge, data comparison, lookup or indirect call. At opt2 it is inlined into
  `expand!`.
- `transpose-8x8` is three fixed delta swaps (shift, XOR, immediate mask). At
  opt2 it is inlined into its callers. It has no edge, table or indexed memory.
- `absorb!` assembles two little-endian words from sixteen fixed byte offsets,
  transposes both, and XORs byte j of each into plane j under the public `keep`
  mask: 0 when loading, all ones for AddRoundKey. `squeeze!` is its exact
  inverse and writes sixteen fixed byte offsets. Neither has an edge or
  register-indexed address. At opt2 the compiler fuses the eight byte loads of
  a word into one 64-bit load at the same fixed public address.
- `sub-bytes!` is the Boyar-Peralta Boolean S-box circuit: 32 AND and 83 XOR
  gates, plus four XORs with the public lane mask 0xffff in place of NOT. It
  reads and writes planes 0..7 at fixed offsets and is straight-line at both
  levels, with no table, branch, call or indexed address. Register pressure
  spills circuit temporaries to its own stack frame (see the cleanup note).
- `shift-rows!` loops over the eight public plane indices. Each plane uses
  fixed shifts by 4/8/12 and the immediate masks 0x1111, 0x0222, 0x2000, 0x0044,
  0x4400, 0x0008 and 0x8880. Its only edge is the public plane-count loop.
- `mix-columns!` computes 2(a + a1) + a1 + (a2 + a3) per plane, where ak is
  the column rotated up k rows. It uses the fixed row rotations
  `rotate-rows-1`/`-2` (shifts and masks 0x7777/0x8888 and 0x3333/0xcccc), and
  folds plane 7 into planes 0/1/3/4 for multiplication by x. It is
  straight-line. At opt1 it makes direct calls to the two pure rotation
  helpers. No column value becomes an address.
- `add-round-key!` passes `schedule + 16*round` with the all-ones mask to
  `absorb!`, which opt2 inlines. The round is public.
- `sub-block!` clears the caller's planes through `absorb!` with mask 0, runs the
  circuit, and writes sixteen bytes back through `squeeze!`. It has no edge.
- `expand!` copies exactly the public key length, then emits public four-byte
  words until 176/240. Its variant/remainder branches depend on the output
  counter and 16/32-byte key length. Division guards and cold abort edges also
  test only those public operands. RotWord is four fixed byte moves. SubWord
  runs `sub-block!` on a sixteen-byte buffer whose first four lanes are the
  temporary word. AES-256's additional SubWord at byte offset 16 modulo 32 is
  retained. Opt1 has eleven conditional edges and opt2 seventeen, including
  public unrolling. The ten-word plane/buffer scratch is wiped after expansion.
- `cipher!` loads the sixteen source bytes into the zeroed plane scratch,
  applies the initial AddRoundKey, and uses the public 10/14 round bound. A
  separate final SubBytes/ShiftRows/AddRoundKey path has no MixColumns. Opt1 has
  one conditional loop edge. Opt2 has three: the round bound, its entry guard,
  and the inlined public eight-plane ShiftRows loop. Ciphertext is written to
  the destination only after the last round, and the eight plane words are then
  volatile-wiped.
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


## Generation-aware secret cleanup

The secret owners now contain one two-word `SecretHandle` field so that every
cleanup call receives both the storage pointer and its stamp. The renewed pins
retain the full inventory above. Cipher, expansion, field arithmetic, round
helpers and exported production block roots are unchanged at both levels and
on both targets. Changed bodies are the public metadata checks, constructors,
close wrappers and main. Their conditional-edge counts and call-target sets
are unchanged; argument passing and stack slots reflect the nested handle.
Constructor raw-key cleanup still follows expansion and all live rejection
paths, and stale rejection still precedes cleanup acquisition. Owner cleanup
now checks the stamp before poisoning and wiping, as separately checked by the
secret lifecycle and shape cases. No secret byte becomes a branch condition
or address in the changed production closure.


## Bitsliced table-free core (#9562)

The x^254 multiply chain and byte-wise round helpers are replaced by the
bit-plane representation above. `gf-mul` and the production byte `sbox` no
longer exist. The test-only `sbox` oracle runs one byte in lane zero through
the production `sub-block!` path. These bodies changed or are new: the
round/plane helpers, `expand!`, `add-round-key!` and `cipher!`. Each complete
body was inspected at all four target/opt cells before its pin was replaced.
Every conditional edge compares only the round count, the plane index, the
schedule word index, the key length, or division-guard operands. Every memory
operand is a base pointer plus a fixed or public counter-derived offset. No
RIP-relative data is referenced except the existing cold division-abort site
strings in `expand!`. The final ciphertext write precedes the `cipher!` plane
wipe, and `expand!` still wipes its scratch.

Preflight, constructor, close wrappers, typed roots and `main` are
byte-identical to their previous reviewed bodies once function-numbered local
labels (`.LfN_`) are normalized. Their pins changed only because the module
now has a different number of functions.

Like registers, compiler-managed stack spill slots are outside the
volatile-wipe guarantee; only the named scratch arrays are wiped. The stated
guarantee is unchanged, but the actual opt2 exposure is not, and this is a
disclosed adverse cost of the change.

- At opt1, both the previous and the new helpers keep secret locals in frame
  slots.
- At opt2, the previous `sbox`, `gf-mul` and `sub-bytes!` bodies made no stack
  stores on either target. Secret round values stayed in registers and the
  wiped scratch. The remaining `cipher!`/`expand!` frame stores held public
  values: lengths, pointers, `rcon` and callee-saved/argument homes.
- The new opt2 bodies spill circuit temporaries and plane values, and nothing
  wipes those dead slots. On Linux, `sub-bytes!` (200-byte frame) makes 49
  stack stores and `mix-columns!` 10. On Windows, `sub-bytes!` (440-byte frame)
  makes 50 and `mix-columns!` 13; those counts include callee-saved register
  saves.

Both callers of the circuit leave residue:

- Block encryption: the last round's values remain in dead stack after
  `cipher!` returns. Together with the public ciphertext, final-round S-box
  state would reveal the last round key, from which AES-128's key schedule can
  be inverted.
- Schedule construction: `expand!` runs every SubWord through `sub-block!` and
  the same spilling `sub-bytes!`. Temporaries derived only from key-schedule
  words (for AES-128, the SubWord of w[39]) therefore remain in dead stack
  after `new-128`/`new-256` return.

A best-effort scrub of the dead stack region after both the block call and
schedule construction is a possible follow-up. It depends on frame layout, so
it would not be a guarantee.
