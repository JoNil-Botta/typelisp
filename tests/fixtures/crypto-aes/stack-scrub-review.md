# Best-effort stack reclamation review (D-C132 / D-C150 / D-C155)

The shared `crypto_stack_scrub` mechanism reuses retired stack addresses with a
fixed local array and volatile word stores. This is a layout-dependent reduction
of residue, not an erasure guarantee or side-channel certification. Registers,
SIMD registers, caches, dumps, fatal exits and arbitrary caller-owned live frames
remain excluded. Opt2 is the default and still emits secret spills. Surviving
last-round state plus public ciphertext can conditionally reveal the AES-128 key;
opt1 GHASH residue can reveal H and undermine authentication.

## Boundaries and call routing

Public `encrypt-128!` / `encrypt-256!` use the same checked implementation and
cipher as composed modes. Their public selector reclaims arithmetic-helper frames
after the existing eight-word plane wipe. Rejected metadata/overlap checks read
no secret bytes. The selector, key size, round count and reclaim trip counts are
public. The cipher's scalar computation and all named scratch wipes remain.

GCM H, J0 and GCTR use the internal unsafe `encrypt-composed-128!` seam with the
same validation and the public selector false. Key construction, seal and open
finish their original structured operation and owner cleanup before a final tree
reclaim. Authentication refusal reaches that same reclaim without running GCTR.
Public AES constructors finish raw-key cleanup and then reclaim their setup tree.
The native fixture counts exactly eight visits: each variant's constructor and
block, GCM key/seal, successful open and authentication failure. Thus GCM does not
pay a public block reclaim inside its payload loop. Future stdlib compositions
use the internal seam and one final tree boundary, with their own coverage proof.

## Actual emitted intervals

Intervals below are half-open byte coordinates relative to rsp immediately before
the reclaim call. The interval is derived from the emitted array address, the
complete prologue/epilogue (including probes/saves), and the return-address word;
it is not inferred from a source array length alone. The native gate recomputes
these values and conservative callee-chain bounds on every run and checks both
target optimization levels. Complete instruction pins also retain the actual
inlined production roots. Function-number labels are immaterial to addresses.

| target/opt | block interval | AES setup interval | GCM tree interval |
|---|---|---|---|
| Linux 1 | [-760,-24) | [-2968,-24) | [-5912,-24) |
| Linux 2 | [-752,-16) | [-2960,-16) | [-5904,-16) |
| Windows 1 | [-840,-24) | [-3288,-24) | [-6552,-24) |
| Windows 2 | [-832,-16) | [-3280,-16) | [-6544,-16) |

The gate follows direct calls and restored-frame tail calls, reservations,
red-zone destinations and callee-saved copies. It conservatively includes frame
padding and public slots. The opt1 block chains reach 728 B Linux / 816 B Windows
(`absorb! -> transpose-8x8`). At opt2 the `sub-bytes!` frame plus saves reaches
256 / 496 B. Public setup wrappers reach 2184 / 2400 B at opt1. GCM key setup
reaches 2744 / 2992 B, seal 5224 / 5472 B, and open 4792 / 5040 B at opt1.
The D-C155 setup/block/record floors are enforced even in a shallower opt2 cell.
These bounds include the extra containing frames introduced by the exit wrappers.

The reclaim arrays contain 92 / 102 words per public block, 368 / 408 words for
standalone setup, and 736 / 816 words for GCM. Target selection uses `cfg windows`;
there is no optimization-level cfg. One shared positive-chunk loop writes
92 / 102 words per iteration with existing volatile stores. Public blocks execute
exactly one iteration. The Windows opt2 static bound includes the entire block
entry, one complete wipe body and the caller's call instruction (435 instructions,
including a conservatively counted branch that may not execute). Linux's measured
complete per-call delta is approximately 405 Ir: 4.25% AES-128 / 3.10% AES-256.
Composed stdlib modes use one tree scrub per operation. Not an erasure guarantee;
registers/caches/dumps excluded; no timing/side-channel certification.

## Stack destination classes and secret provenance

Every analyzed direct stack destination is retained in the gate's
`stack-destinations.tsv`, classified as spill store, read-modify-write or
callee-saved copy, with its emitted symbol and line. These are instruction sites,
not counts of secret bytes or dynamic stores. Explicit arrays accessed through
scratch pointers are separate regions with their original named volatile wipes.
The conservative coverage interval does not assume that all pointer/index spills
are secret or that all callee saves are harmless.

- AES opt1 arithmetic spills include loaded key/state bytes, bit planes and
  Boolean intermediates. `shift-rows!` also has a stack RMW. Expansion's SubWord
  chain spills key-derived values. These retired frames are inside the block or
  setup windows; the live named plane/temp arrays retain their final wipes.
- At opt2 `sub-bytes!` retains 49 mov stores on Linux, and 50 mov plus one stack
  RMW on Windows; its six callee-saved pushes are counted separately.
  `mix-columns!` and the Windows SubWord/output helpers retain the separately
  disclosed copies. A read-modify-write destination is a write even when its
  source register is not the secret's original producer.
- The top excluded words are the live call return address and public ABI homes
  or saved context. For public block reclamation, the cipher assigns r12 to its
  plane-array address, r13 to the public round, r14 to the schedule address, r15
  to the round bound, rbx to the output address and rbp to the public selector.
  Consequently the first saved r12 at the top of a called helper is an address,
  not a state limb. At opt1 the top arithmetic argument home holds its state/data
  pointer; the next secret plane destination is covered. Deeper saved copies and
  red-zone temporaries are included in the checked interval.
- Constructor wrappers' top homes hold the input handle/result address or public
  result discriminant; schedule/key content is read in the deeper expansion
  chain. GCM's outer homes contain owner/input/output pointers and lengths;
  expected tags stay in wiped secret storage. A completed seal tag and ciphertext
  are intentionally public outputs. The upper ABI exclusions do not assert that
  arbitrary application registers contain no other secrets.
- GHASH opt1 stores H-derived limbs/masks/accumulators. GCTR opt1 stores its last
  keystream/input/output bytes. The final GCM reclaim covers both frames and all
  descendants, including authentication-refusal descendants. In opt2 the GHASH
  multiplier's H-derived state remains in registers and the wiped 48 B local;
  GCTR's direct stack stores contain public call/loop metadata.
- New reclaim frames themselves carry only zero values, addresses, public chunk
  counts/indices and ABI saves of that context. The volatile loop's stack saves
  lie below its caller's reclaim array. It does not read retired secrets into a
  new ordinary secret value. Its positive chunk-count precondition is met by
  each fixed internal call; this is not a supported arbitrary-buffer API.

## Fresh D-C150 analysis of GCTR's changed target

GCTR now reaches `encrypt-checked!` through the composed seam. Its inner byte loop,
public counter/length controls and output mutation are unchanged. Opt1 remains at
31 direct mov-to-stack sites on both targets. GHASH multiply remains at 38 opt1
stores, with the complete 48 B wipe and no new opt2 secret slot; its complete body
is unchanged modulo function-number labels.

At opt2 GCTR has 6 direct stores on Linux and 12 on Windows (previously 5 / 11).
The added outgoing slot is the **status-result pointer**, not a secret byte and
not the false selector itself. Linux forms `lea 80(%rsp), r10` and stores that
pointer at `0(%rsp)`; Windows forms `lea 104(%rsp), r10` and stores it at
`32(%rsp)`. The selector travels as zero in r9 / rdi respectively. Other direct
stores remain key/nonce/source/destination/counter/stream references, public
length/loop metadata, and saved caller registers. The result contains public
status/error metadata. No input byte, keystream byte, H limb or tag mask is moved
into a new opt2 slot. The native gate additionally enforces the opt1 count ceilings;
complete body pins require renewed review for any future operand/control change.

## Residue-sensitive gate and pinned mutants

`stage2-crypto-stack-residue` compiles `stack-residue.tl` with the actual production
stdlib. Before each imminent reclaim call the test-only assembly instrumenter
writes a nonzero marker at every word of the required retired interval, then lets
the original reclaim run and checks for zero at those exact addresses. It uses
caller-clobbered temporary registers and never seeds the active caller frame or
return/save exclusions. Word writes descend in address order across stack pages.
Public phase/hit counters prove that each of the eight intended boundaries ran
exactly once. The original cryptographic/status assertions remain unchanged.
Markers and pass/fail metadata are public; no real key or secret result is printed.

The SHA256-pinned mutant manifest removes each boundary call independently, then
independently replaces it with a 64-byte zero window below the measured depth.
The retained marker must produce exit 1, with no diagnostic output, rather than
an unrelated crash. Each positive must return 42. Both native opt levels therefore
run two positives and 32 negatives per host. Keeping an unused helper cannot pass;
removing a wrapper's authentication-failure reclaim cannot hide behind the success
path. The compiler and exact generated input identities are recorded per run.

The ordinary full AES/GCM body pins now include every emitted shared reclaim
function and actual caller. They preserve branch/address/round/scratch coverage.
Windows runtime execution is required in hosted CI; Linux cross-assembly alone is
not credited as Windows runtime evidence.

## Target parity and limits of evidence

The existing parity harness compares aggregate IR summaries. The authorized
`cfg windows` reclaim sizes intentionally change those summaries. Its GCM case
first verifies that the **actual** target-layout summaries differ, then compares
the unchanged cryptographic closure using a narrowly scoped no-op reclaim module
for aggregate-IR comparison only. That temporary module is never assembled or
executed. The real reclaim body is independently pinned and tested by the native
residue/mutant gate on both targets; no cryptographic corpus case is removed.

Passing vectors, shape pins, residue probes and cost limits is regression evidence,
not a proof about every application/toolchain, a completed side-channel audit, or
compiler-level erasure. The separate compiler-erasure proposal remains unimplemented.
