# AES core regression inputs

These are public algorithm fixtures, not a supported ECB mode or CAVP validation.
CI executes checked-in TypeLisp fixtures without network access or host crypto.

## CAVP provenance and regeneration

[NIST's AES KAT archive](https://csrc.nist.gov/CSRC/media/Projects/Cryptographic-Algorithm-Validation-Program/documents/aes/KAT_AES.zip)
is 726,299 bytes, SHA-256
`a203b16c9246b2ebae31dee5de21a606be80cf78ceabaca37150236fa098eb60`.
The eight source hashes are pinned in [sources.sha256](sources.sha256).
Only their `[ENCRYPT]` sections are imported: GFSbox 7/5, KeySbox 21/16,
VarKey 128/256 and VarTxt 128/128 for AES-128/AES-256, totaling 689 cases.
The file names use ECB because the KAT format supplies individual forward
blocks; the library exposes no ECB encryption mode.

To regenerate from an already-downloaded, extracted archive:

```sh
scripts/regenerate-crypto-aes-kat.sh path/to/extracted/rsp-files
scripts/regenerate-crypto-aes-kat.sh --check path/to/extracted/rsp-files
```

The wrapper verifies every source hash; the TypeLisp generator validates field
order, exact lowercase hex widths, sequential COUNT values and all eight case
counts. The generated fixture imports one shared public-vector driver for
both typed variants. A check regenerates into scratch and compares exact bytes.

## FIPS and maintained examples

[The FIPS 197 update](https://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.197-upd1.pdf),
SHA-256 `62c86eb567f13edb8f71826e985da870b04ef6381634f303cdb16e84d47becd1`,
supplies the complete 44/60-word schedules in Appendices A.1/A.3, the 256-byte
public S-box oracle in Table 4, and Appendix B's column-major intermediate
states. Schedule and state assertions import expected public vectors into
secret storage and return only fixed-work pass/fail comparisons; no readable
schedule getter is added. The final-round fixture deliberately omits MixColumns.

Appendix C points to [maintained NIST examples](https://csrc.nist.gov/projects/cryptographic-standards-and-guidelines/example-values).
The four forward examples for each required key size are imported from:

- AES_Core128.pdf: SHA-256 `59df07938ee3a0ea139268f99ad7da6d3ae9e833a521a63f56c80c116ac7c210`.
- AES_Core256.pdf: SHA-256 `8caf33781b8d4b9564c7e95a7690e491ca1d95efe9a31cdea2977deaf4c7b4ce`.

The classic incrementing-key example is retained for both variants as well.
The NIST documents remain algorithm examples, not side-channel or certification
claims about this implementation.

## Ownership, fixed work and shape

The lifecycle corpus checks exact size boundaries, stale generations, public
metadata mutations (fixed seed `0x7360`, 64 cases per variant), exact/partial
backing overlap, failure atomicity, immediate raw-key wiping, whole-capacity
schedule cleanup, and allocation counts. Compile-fail witnesses reject key
reuse, cross-variant schedules, clone, format, raw reads and public round choice.

The test-only `source-work` tally counts visited arithmetic/byte-work sites in
production helpers: each site adds its source operators plus memory reads and
writes. The Boyar-Peralta circuit contributes 135 units (119 gates and sixteen
plane accesses), ShiftRows 21 per plane, MixColumns 124, the 8x8 bit transpose
18, plane loading/XOR 114 and plane output 91 besides their two transposes.
Key expansion adds 26 per schedule word, 11 per RotWord/round constant and five
per `xtime`. Totals are 5,352/6,073 setup/block units for AES-128 and
6,884/8,381 for AES-256.
The tally is a reproducible source instrumentation metric, not machine
instructions, cycle counts or a universal count of all language operations.
It vanishes without `cfg test`. Key and state inputs differing in first,
middle and last bits must preserve both setup and per-block counts. Steady-state
throughput is measured separately without this instrumentation.

The required `aes-*` codegen rows compile both target ABIs at opt1/opt2, retain
explicit production roots plus ordinary-entry callers, require reproducible
assembly accepted by the native/target assembler, and compare the
complete AES instruction/label bodies against reviewed SHA-256 pins. They
include actual inlined callers and the Windows ABI bridge bodies. See
[shape-review.md](shape-review.md) for the public branch/address/wipe inventory.
A missing body, extra helper or changed instruction/address/branch fails closed.
There is no automatic pin-update mode. Compiler code-shape changes require
renewed review; an inlined helper is inspected in its actual containing body.

These checks are regression boundaries, not a timing proof or completed
side-channel review. Fatal OOM/panic/abort can bypass cleanup. Volatile memory
wipes make no promise about registers, caches, core dumps or swap.
