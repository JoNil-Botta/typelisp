# .eh_frame fixture corpus

Profile: DWARF32 `.eh_frame`, CIE version 1 `zR`, FDE pointer encoding
`DW_EH_PE_pcrel | DW_EH_PE_sdata4`, version-1 `.eh_frame_hdr` (#7388's initial
admitted profile).

| Fixture | Producer | Content |
| --- | --- | --- |
| `basic.eh_frame.expected` | GNU as 2.47 from `basic.s.in` | One CIE, a leaf FDE and an FDE with a remembered state; ends at section EOF without a terminator |
| `basic-linked.eh_frame.expected` | GNU ld 2.47 `--eh-frame-hdr -e leaf` | The same records relocated: `.text` at 0x401000, `.eh_frame` at 0x402020 |
| `basic-linked.eh_frame_hdr.expected` | same link | Version-1 header at 0x402000 with two rows |
| `gcc-O2.eh_frame.expected` | GCC 16.2.1 `-O2 -c` of `probe.c.in` | Three FDEs with `advance_loc1`, `restore` and state push/pop; `R_X86_64_PC32` fields at 0x20, 0x34, 0x64 |
| `clang-O2.eh_frame.expected` | Clang 22.1.8 `-O2 -c` of `probe.c.in` | Three FDEs; `R_X86_64_PC32` fields at 0x20, 0x34, 0x6c |

The relocatable fixtures store zero in every FDE initial-location field; the
addend lives in `.rela.eh_frame`, whose pairing belongs to the linker (#7388),
not the codec.

`basic.s.in` and `probe.c.in` are original test inputs for TypeLisp. The
hexadecimal files are uncopyrightable facts extracted from tool output; no
binutils, GCC or LLVM source is copied here.

`src/compiler_eh_frame_tests.tl` embeds each fixture's hex verbatim.
`scripts/analyze-eh-frame-corpus.sh` regenerates every fixture with the exact
tool versions above, compares bytes and SHA-256 values, checks that the tests
embed the same hex, and cross-checks record boundaries, ranges and relocation
fields with `readelf --debug-dump=frames`, `readelf -r` and
`llvm-dwarfdump --eh-frame`. It fails, rather than skipping, when a pinned tool
is missing or has another version.

Regenerate by hand:

```sh
as --64 -o basic.o basic.s.in
objcopy --dump-section .eh_frame=basic.eh basic.o
ld --eh-frame-hdr -e leaf -o basic basic.o
objcopy --dump-section .eh_frame=basic-linked.eh \
    --dump-section .eh_frame_hdr=basic-linked.hdr basic
gcc -O2 -c -o gcc.o -x c probe.c.in && objcopy --dump-section .eh_frame=gcc.eh gcc.o
clang -O2 -c -o clang.o -x c probe.c.in && objcopy --dump-section .eh_frame=clang.eh clang.o
od -An -tx1 -v basic.eh
readelf --debug-dump=frames basic.o
```
