# DWARF inventory fixture corpus

Raw debug sections for `src/linker_dwarf_scan_core.tl` (#7763), taken from
real GCC, Clang and TypeLisp objects. Each directory holds one object's
`.debug_*` sections as `NN.debug_*.bin`, where `NN` is the ELF section index,
and a `sections.tsv` with one tab-separated row per section: index, name,
size, `relocatable` (`yes` for the `.o`, `no` for the `.dwo`), file and
SHA-256. `NAME-dwo` holds the split file that belongs to `NAME`.
`src/linker_dwarf_scan_core_tests.tl` embeds every file with `include-bin`
and checks each object's inventory against the numbers `llvm-dwarfdump`
reports.

`probe.c.in` and `probe.tl.in` are original TypeLisp test inputs: a struct,
a static, an inlined helper and a loop, so that optimized builds carry
location lists, ranges and inlined subroutines. The binary files are facts
extracted from tool output. No tool source is copied here. Every object was
built with its compile directory mapped to `/typelisp`, so no local path is
recorded.

## Producers

- GCC 16.2.1 20260810 and Clang 22.1.8, targeting x86-64 Linux.
- GNU as from binutils 2.47, for the TypeLisp output.
- `objcopy --decompress-debug-sections` from binutils 2.47, run before
  extraction.
- `llvm-dwarfdump` 22.1.8 and binutils 2.47 `readelf`, used only by the
  oracle.
- The TypeLisp compiler, called as
  `typelisp compile probe.tl -o probe.s --debug --target linux-x86_64 --cfg linux --cfg unix --cfg target-linux --cfg os-linux`
  and then `as --debug-prefix-map ROOT=/typelisp --debug-prefix-map DIR=/typelisp`.

Each C fixture is `CC FLAGS -fdebug-prefix-map=DIR=/typelisp -c probe.c`.

## Admission matrix

Every fixture is admitted. Counts are the scanner's inventory of the object,
and of its `.dwo` too for split DWARF. "refs" lists the non-zero reference
classes: unit-relative DIE, signature, `strp`, `line_strp`, string index,
address, address index, section offset (which includes each unit header's
`.debug_abbrev` offset), range-list index and location-list index.

| Fixture | Flags | Version | Unit types | Notable forms | DIEs | Attributes | Refs |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `gcc-dwarf4-O0` | `-gdwarf-4 -O0` | 4 | compile | `string`, `strp`, `exprloc`, `sec_offset` | 18 | 106 | unit 16, str 16, addr 6, secoff 2 |
| `gcc-dwarf5-O0` | `-gdwarf-5 -O0` | 5 | compile | `implicit_const`, `line_strp` | 18 | 108 | unit 16, str 14, lstr 2, addr 6, secoff 2 |
| `gcc-dwarf5-O2` | `-gdwarf-5 -O2` | 5 | compile | location and range lists by `sec_offset` | 23 | 112 | unit 22, str 14, lstr 2, addr 3, secoff 10 |
| `gcc-dwarf5-O2-function-sections` | `-gdwarf-5 -O2 -ffunction-sections` | 5 | compile | as above, with one text section per function | 23 | 112 | unit 22, str 14, lstr 2, addr 3, secoff 10 |
| `gcc-dwarf5-O2-split` (+`-dwo`) | `-gdwarf-5 -O2 -gsplit-dwarf` | 5 | skeleton, split_compile | `strx`, `addrx`, `rnglistx`, `loclistx` | 24 | 116 | unit 22, str 2, strx 16, addr 1, addrx 2, secoff 8, rngx 1, locx 3 |
| `gcc-dwarf4-O2-split` (+`-dwo`) | `-gdwarf-4 -O2 -gsplit-dwarf` | 4 | GNU skeleton and split compile units | `GNU_str_index`, `GNU_addr_index`, `DW_AT_GNU_dwo_id` | 24 | 117 | unit 22, str 2, strx 16, addr 1, addrx 2, secoff 13 |
| `gcc-dwarf4-O0-types` | `-gdwarf-4 -O0 -fdebug-types-section` | 4 | compile, `.debug_types` type | `ref_sig8` | 21 | 112 | unit 16, sig 1, str 17, addr 6, secoff 4 |
| `gcc-dwarf5-O0-types` | `-gdwarf-5 -O0 -fdebug-types-section` | 5 | compile, type | `ref_sig8` | 21 | 116 | unit 16, sig 1, str 15, lstr 2, addr 6, secoff 4 |
| `clang-dwarf4-O0` | `-gdwarf-4 -O0` | 4 | compile | `strp`, `exprloc` | 18 | 87 | unit 13, str 17, addr 6, secoff 2 |
| `clang-dwarf5-O0` | `-gdwarf-5 -O0` | 5 | compile | `strx1`, `addrx` | 18 | 89 | unit 13, strx 17, addrx 6, secoff 4 |
| `clang-dwarf5-O2` | `-gdwarf-5 -O2` | 5 | compile | `loclistx` | 16 | 77 | unit 11, strx 15, addrx 4, secoff 5, locx 1 |
| `clang-dwarf5-O2-function-sections` | `-gdwarf-5 -O2 -ffunction-sections` | 5 | compile | `rnglistx`, `loclistx` | 16 | 78 | unit 11, strx 15, addr 1, addrx 3, secoff 6, rngx 1, locx 1 |
| `clang-dwarf5-O2-split` (+`-dwo`) | `-gdwarf-5 -O2 -gsplit-dwarf` | 5 | skeleton, split_compile | `strx1`, `addrx`, `rnglistx`, `loclistx` | 17 | 77 | unit 11, strx 17, addrx 2, secoff 5, rngx 2, locx 1 |
| `clang-dwarf4-O2-split` (+`-dwo`) | `-gdwarf-4 -O2 -gsplit-dwarf` | 4 | GNU skeleton and split compile units | `GNU_str_index`, `GNU_addr_index` | 17 | 80 | unit 11, str 2, strx 15, addr 1, addrx 3, secoff 5 |
| `typelisp-debug` | TypeLisp `--debug` through GNU as | 3 | compile | `ref_udata`, `flag`, `data4` pointers | 58 | 287 | unit 56, str 59, addr 114, secoff 2 |

Decisions the corpus pins down:

- **Versions and unit types.** DWARF 3, 4 and 5 are admitted in the DWARF32
  format. DWARF 5 admits the unit types compile, type, partial, skeleton,
  split_compile and split_type. DWARF 4 admits `.debug_types` units and GNU
  split units, which are paired by `DW_AT_GNU_dwo_id`. DWARF64, version 2,
  version 6 and later, and unknown unit types are rejected.
- **DWARF 3 pointers.** GNU as writes DWARF 3, where `DW_AT_stmt_list`,
  `DW_AT_ranges`, `DW_AT_location`, `DW_AT_frame_base` and
  `DW_AT_macro_info` use `data4` or `data8` as section offsets. The scanner
  records them as section offsets, as `llvm-dwarfdump` does. A `block` form
  on one of these attributes is decoded as an expression.
- **Forms.** Every DWARF 5 form is admitted, and so are
  `DW_FORM_GNU_addr_index` and `DW_FORM_GNU_str_index`. The
  supplementary-file forms (`ref_sup4`, `ref_sup8`, `strp_sup`, and GNU
  `ref_alt` and `strp_alt`) are rejected. A DWARF 4 or 5 `block` on an
  expression attribute is also rejected, because its references could not
  be checked.
- **Operators.** Every DWARF 5 expression operator is admitted, plus the GNU
  operators GCC emits. `DW_OP_GNU_encoded_addr` and unknown operators are
  rejected.
- **Relocatable objects.** A `.o` stores zero in the address, string and
  section-offset fields that RELA relocations fill. The scanner records
  those fields without checking their values, and it skips index checks
  against a table whose base is such a placeholder. `readelf -r` shows that
  every `.rela.debug_info` entry in the corpus lands on a recorded
  reference of the same width.
- **Unwalked sections.** Sections the scanner does not parse go to the
  ledger. String tables are checked at every recorded offset. Offset and
  address tables are relocatable. Line programs, lists, aranges, macros and
  frames are opaque here.

The inline tests hand-assemble the rejected cases: truncation, DWARF64,
versions, unit types, bad abbreviation codes, duplicate codes, unknown
forms and operators, malformed LEB128, out-of-range references and indexes,
bad string offsets, inconsistent split ids, and every limit at its value and
one below.

## Work and memory

`tools/dwarf-inventory` prints each inventory's `work`, the amount charged
against the work limit. The scan charges one unit per byte of each
abbreviation table it parses, each unit it walks and each string it checks,
plus one per reference it checks. Line programs and lists are not walked, so
across the corpus the work is 0.32 to 0.69 per input byte. Peak RSS is under
8 MB for every fixture, which is the tool's startup floor.

The scan's storage grows by doubling, so memory is linear in the inventory.
The oracle also scans generated translation units of 1000 and 10000
functions, each under a 512 MiB cap. Peak memory is for the whole tool
process, including the input it reads.

| Object | Input bytes | Work | Peak memory |
| --- | --- | --- | --- |
| GCC, 1000 functions | 562931 | 270454 | 22 MiB |
| GCC, 10000 functions | 5701609 | 2709214 | 115 MiB |
| Clang, 1000 functions | 447475 | 165480 | 16 MiB |
| Clang, 10000 functions | 4631118 | 1689842 | 102 MiB |

| Fixture | Input bytes | Work |
| --- | --- | --- |
| `clang-dwarf4-O0` | 734 | 492 |
| `clang-dwarf4-O2-split` | 789 | 548 |
| `clang-dwarf5-O0` | 816 | 414 |
| `clang-dwarf5-O2` | 675 | 373 |
| `clang-dwarf5-O2-function-sections` | 730 | 385 |
| `clang-dwarf5-O2-split` | 875 | 531 |
| `gcc-dwarf4-O0` | 861 | 558 |
| `gcc-dwarf4-O0-types` | 945 | 624 |
| `gcc-dwarf4-O2-split` | 1458 | 850 |
| `gcc-dwarf5-O0` | 903 | 561 |
| `gcc-dwarf5-O0-types` | 1001 | 641 |
| `gcc-dwarf5-O2` | 1160 | 650 |
| `gcc-dwarf5-O2-function-sections` | 1180 | 650 |
| `gcc-dwarf5-O2-split` | 1469 | 814 |
| `typelisp-debug` | 5146 | 1663 |

## Regenerating and checking

```sh
TYPELISP_BIN=target/bootstrap-fixpoint/stage3 scripts/analyze-dwarf-corpus.sh
```

The script is an opt-in oracle and needs exactly the tool versions above.
It does the following:

- Rebuilds every C fixture in `target/dwarf-corpus` and requires
  byte-identical sections.
- Requires the scanner's summary of each object to equal the counts from
  `llvm-dwarfdump --debug-info --debug-types -v`.
- Requires every `.rela.debug_info` relocation to land on a recorded
  reference.
- Requires `src/linker_dwarf_scan_core_tests.tl` to expect every summary.
- Rebuilds the TypeLisp object with the given compiler and checks it the
  same way, then reports whether `typelisp-debug` still matches it. A new
  snapshot can be copied from `target/dwarf-corpus/typelisp-debug/sections`.
- Checks the two generated translation units the same way, and requires
  each scan to fit in 512 MiB and to charge at most one unit of work per
  input byte.

Every compiler, `llvm-dwarfdump` and scanner run goes through
`scripts/run-memory-bounded.sh`, so a runaway process fails the check
instead of exhausting the host.
