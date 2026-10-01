# Implicit linker-script fixtures

Real `lib*.so` link inputs that Linux distributions ship as GNU ld scripts
instead of ELF files. `src/linker_script_subset_tests.tl` reads each one with
the #8303 subset reader and checks the full command and file list.

Every file is a byte-for-byte copy of the installed file on Arch Linux
(x86_64), taken on 2026-10-01.

| fixture | installed as | package | SHA-256 |
| --- | --- | --- | --- |
| `arch-glibc-2.44-libc.so` | `/usr/lib/libc.so` | glibc 2.44+r24+g16be1518495f-1 | `362665345c2d0149815700776a1e3e1a7fff45ab16f32352dbe224c55d12c964` |
| `arch-glibc-2.44-libm.so` | `/usr/lib/libm.so` | glibc 2.44+r24+g16be1518495f-1 | `258e8802b225f70a439bbe23d6ecd468a33ce8875a02a52846a7bb5d21ff34c3` |
| `arch-libbsd-0.12.2-libbsd.so` | `/usr/lib/libbsd.so` | libbsd 0.12.2-2 | `acfb12c5b08508375ee08069889b2d3af3b0e516528b84fd2200b1e679800010` |
| `arch-binutils-2.47-libbfd.so` | `/usr/lib/libbfd.so` | binutils 2.47-4 | `b9dec3c289938f1bb2e5309548e411c49e35993def42bc7d1e3efaa1135936a5` |
| `arch-ncurses-6.6-libncurses.so` | `/usr/lib/libncurses.so` | ncurses 6.6-2 | `2636a8d99d2965f58e0f6e39915450f03df02d1fae2137f301073b2b8b247f74` |
| `arch-ncurses-6.6-libtinfo.so` | `/usr/lib/libtinfo.so` | ncurses 6.6-2 | `bbe26b1b934527c3e73c6cc5899b0bce0018c16e56131050fe99135f66727f1c` |
| `arch-ncurses-6.6-libncurses++.so` | `/usr/lib/libncurses++.so` | ncurses 6.6-2 | `d7a901ffd03bf06a22ac7d9bbdf1a45961ed529d81422d9ab75ca6f024c6c670` |

The scripts are short configuration statements that list library paths, not
creative works of the packages' authors. They are kept verbatim so the reader is
held to what profiles actually ship.
