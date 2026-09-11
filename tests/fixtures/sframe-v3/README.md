# GNU SFrame v3 fixture corpus

Dialect: `gnu-sframe-v3-binutils-2.47-amd64-le-v1`

The fixtures are pinned to GNU binutils tag `binutils-2_47`, peeled commit
`6ce87bbc521cf46eaee9a1f7ef61cee2cdfb3e32`. They exercise two adjacent AMD64
functions, one row-only leaf and one function with SP/FP transitions. The raw
function start fields in the relocatable fixture remain zero; their
`R_X86_64_PC64` relocation pairing is intentionally not part of the codec.
The linked fixture proves GNU ld's sorted, field-PC-relative final form.

The assembly source in this directory is original test input for TypeLisp.
The hexadecimal files are uncopyrightable facts extracted from tool output;
GNU binutils itself is GPLv3-or-later. No binutils source is copied here.

Regenerate with GNU binutils 2.47:

```sh
as --64 -o basic.o binutils-2.47-amd64-le-v1-basic.s.in
objcopy --dump-section .sframe=basic.sframe basic.o
od -An -tx1 -v basic.sframe
readelf --sframe basic.o
sha256sum basic.sframe
ld -o basic basic.o
objcopy --dump-section .sframe=basic-linked.sframe basic
readelf --sframe basic
sha256sum basic-linked.sframe
```

Both sections are 88 bytes. Expected raw-section SHA-256 values:

- relocatable: `cee03053d626fd2eeb378ce7a8c0fda1532ac2df389456697d231d91cc33a9b6`
- linked: `67c5f5fa9c08b3f08e631d652a12412ba039d0376ac485e153356d43cea38bae`

The checked-in `.expected` hexadecimal bytes are decoded independently and
exercised by
`src/compiler_sframe_v3_tests.tl`; production constants and readers are not
used by that oracle. `scripts/verify-sframe-v3-corpus.sh` is the dedicated
bounded external oracle: it rejects any tool version other than GNU binutils
2.47 before regenerating and checking both byte streams and `readelf` facts.

Run `scripts/measure-sframe-v3-codec.sh --compiler PATH` for the separate
1k/10k/100k linearity, ownership, wall-time, output-size, and peak-RSS report.
