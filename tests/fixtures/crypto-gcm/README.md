# AES-128-GCM regression inputs

The implementation follows [NIST SP 800-38D](https://doi.org/10.6028/NIST.SP.800-38D)
and the exact [RFC 5116 profile](https://www.rfc-editor.org/rfc/rfc5116.html#section-5.1),
with P_MAX corrected to 2^36−32 bytes as recorded by erratum 5219. Nonce
uniqueness and protocol usage/rekey limits belong to the consuming adapter.
No test result is CAVP validation, certification or a completed side-channel audit.

## Vector provenance

[NIST GCM CAVP archive](https://csrc.nist.gov/CSRC/media/Projects/Cryptographic-Algorithm-Validation-Program/documents/mac/gcmtestvectors.zip),
SHA-256 `f9fc479e134cde2980b3bb7cddbcb567b2cd96fd753835243ed067699f26a023`.
The exact unmodified CRLF source files are pinned in [sources.sha256](sources.sha256).
The subset selects only 128-bit keys/tags and 96-bit IVs. For each of the 25
plaintext/AAD length pairs it takes the first encryption case, the first
successful decrypt and the first failing decrypt: 75 cases total. Plaintext
lengths are 0, 104, 128, 256, 408 bits; AAD lengths are 0, 128, 160, 384, 720 bits.
The generated corpus first reruns the FIPS AES-128 vector through the linked
shared typed AES core. There is no CI download or external crypto execution.

Offline regeneration from the extracted official archive:

```sh
scripts/regenerate-crypto-gcm-kat.sh path/to/extracted/rsp-files
scripts/regenerate-crypto-gcm-kat.sh --check path/to/extracted/rsp-files
```

The hash check fixes the input format and contents; regeneration enforces the
75-case count, formats the generated TypeLisp and optionally compares it exactly.
The test support imports public fixture material into secret owners and
compares public outputs only after successful completion.

## Semantic boundaries

The component suite independently multiplies public coefficient arrays and
reduces a degree-254 polynomial, rather than reproducing the production
shift recurrence. It checks all 36 combinations of AAD/ciphertext lengths
0, 1, 15, 16, 17 and 32, including separate zero padding and the length block.
Every multiplication contributes exactly 128 instrumented production steps.

Further tests cover all tag-byte mutations, wrong key/nonce/AAD/ciphertext,
every ciphertext-prefix truncation, nonce/tag lengths 0..19, huge arithmetic
boundaries, exact J0/final-counter encoding, key transfer and nested cleanup,
stale generations, malformed H, first/middle/last key bits and allocation
growth. Failed authentication leaves the payload-AES seam unchanged. The
consumer fixtures impose TLS/SSH size/usage admission separately and show
that these smaller transport limits do not constrain the generic primitive.

## Assembly regression boundary

The required `gcm-*` rows compile [audit.tl](audit.tl) twice at opt1/opt2 for
Linux and Windows x86-64 and assemble every result. Complete instruction,
label, operand and symbol-inventory hashes cover all emitted shared AES,
GHASH and GCM bodies, the real exported seal/open callers (including Windows
bridges), `crypto_secret` comparison/wiping when retained, and ordinary main.
Only assembler metadata and comments are omitted. Missing, added, changed or
newly inlined work fails closed and needs renewed review. Existing `aes-*`
and `secret-*` gates remain required and unchanged in coverage.

The multiplier has two public loops bounded by 2 and 64. Its only indexed
secret-memory access selects the public half of X; V/Z use fixed offsets.
Secret bits feed only masks, XORs and fixed shifts. It ends by wiping all six
scratch words. Region/tail load/store and counter encoding use only public
length/index conditions and addresses. GHASH's outer accumulator/encoded
scratch is wiped after tag combination. AES uses its own reviewed table-free
typed core, with no copied round/schedule implementation in GCM.

GCM preflight branches inspect public lengths, owner generations, capacities
and result discriminants. GCTR indices/counters depend only on the validated
payload length; no operation uses a block after 0xffffffff. Open's sole
content-dependent decision is the final authentication result after the full
16-byte `crypto_secret.difference-bits` loop. The rejected path has no GCTR
call or plaintext write. Output storage is preallocated before keyed work;
it contains no decrypted bytes on refusal. Both paths close their fixed secret
scratch. Payload processing has no allocation or recoverable result after
the validated AES(J0) seam; an unreachable AES invariant failure is fatal.
The complete containing bodies pin inlining and these control/address facts;
retaining an unused helper alone cannot satisfy the gate.

Local secret-memory payload peaks are 304 bytes for key setup (raw key,
schedule, preallocated H/zero blocks and expansion planes), 320 bytes for seal and
304 bytes for open (context plus operation scratch and GHASH locals).
These are source-level secret storage bounds, excluding compiler spills,
registers and allocator metadata; assembly frame sizes and runtime allocator
measurements are separate evidence. Allocation storage remains arena-owned
after wiping. No cancellation checkpoint occurs inside synchronous crypto.

## Compiler spill exposure (D-C132)

Explicit local scratch and secret owners are wiped; compiler spill slots are
outside that guarantee. Opt2 is the default release profile, so its exposure
applies to ordinary release builds. GHASH opt1 leaves copies of H-derived
limbs, masks and accumulators in dead stack slots after returning. Recovery
of H or an expected-tag mask can undermine GCM authentication. The linked
AES core has its own separately disclosed block/key-expansion residue.
This implementation makes no stronger erasure or side-channel claim.

The following counts are static instruction sites per emitted frame, not
dynamic stores per message. `reserve` is the `sub rsp` reservation, excluding
pushes. `mov` counts direct mov-to-stack stores; `RMW` counts direct stack
read-modify-write sites; pushes include callee-saved register saves. These
conservative totals include public arguments, pointers and loop counters,
so they are not counts of exclusively secret stores. Explicit local-array
stores through a scratch pointer are excluded: those arrays have final
volatile wipes. Inlined helpers are counted in the containing body.

| target/opt | GHASH frame | reserve B | mov | RMW | pushes |
|---|---|---:|---:|---:|---:|
| Linux 1 | load-be | 0 (red zone) | 10 | 0 | 0 |
| Linux 1 | store-be! | 0 (red zone) | 6 | 1 | 0 |
| Linux 1 | multiply! | 408 | 38 | 0 | 0 |
| Linux 1 | absorb! | 120 | 13 | 0 | 0 |
| Linux 1 | region! | 88 | 9 | 0 | 0 |
| Linux 1 | authenticate! | 328 | 24 | 1 | 0 |
| Windows 1 | load-be | 104 | 10 | 0 | 0 |
| Windows 1 | store-be! | 88 | 6 | 1 | 0 |
| Windows 1 | multiply! | 440 | 38 | 0 | 0 |
| Windows 1 | absorb! | 152 | 13 | 0 | 0 |
| Windows 1 | region! | 120 | 9 | 0 | 0 |
| Windows 1 | authenticate! | 360 | 24 | 1 | 0 |
| Linux 2 | store-be! | 0 | 0 | 0 | 0 |
| Linux 2 | multiply! | 112 | 0 | 0 | 1 |
| Linux 2 | absorb! | 0 | 0 | 0 | 1 |
| Linux 2 | region! | 0 | 0 | 0 | 5 |
| Linux 2 | authenticate! | 184 | 1 | 0 | 6 |
| Windows 2 | store-be! | 0 | 0 | 0 | 0 |
| Windows 2 | multiply! | 400 | 1 | 0 | 1 |
| Windows 2 | absorb! | 96 | 0 | 0 | 1 |
| Windows 2 | region! | 112 | 0 | 0 | 5 |
| Windows 2 | authenticate! | 216 | 1 | 0 | 6 |

At opt2 `load-be` is inlined. The direct `authenticate!` store holds the
ciphertext pointer; Windows `multiply!` spills the accumulator pointer. The
table still counts them and the pushes rather than treating them as erased
storage. It does not establish an all-callers absence of secret residue.
The P1 best-effort scrub follow-up is [#9648](https://github.com/JoNil-Botta/typelisp/issues/9648).
Per D-C132 it does not gate GCM; this module will reuse that shared work rather
than introducing a separate scrub or a compiler-level erasure claim.

The pins and spill table were requalified against the actual landed bitsliced
AES closure at main `b3a7c356bbeadf791b44f0b9e17509c7463e4267`, including
the large-function SSA optimizer from PR #9652. GHASH and GCM bulk work reproduce
their prior instruction/operand/control shapes after normalizing local
function-numbered labels. GCTR's unreachable invariant-failure path now calls
the existing runtime-fatal ABI through `checked_size`, avoiding platform I/O;
the pure parity witness exercises real seal, successful open and bad-tag open.
The linked shared AES bodies are covered by the
current main's independent `aes-*` gate as well as these GCM closure pins.
Every GHASH frame/store/RMW/push count in the table is unchanged. This records
no new spill exposure from composition and does not retire the disclosed risk.
