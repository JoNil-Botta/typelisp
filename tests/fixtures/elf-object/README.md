# ELF64 relocatable reader fixtures

These raw `.in` files are checked input data, not linked images or generated
build outputs. Normal inline/native tests embed them and the `.expected`
structural projections without launching external tools. `producers.tsv`
records each producer, version/options, byte count and SHA256.

The 24 objects cover GCC 16.2.1 and Clang 22.1.8 at opt0/opt2, debug `-g` and
`-gz=zlib`, function/data sections, common/no-common, PIC, all four explicit
TLS models, GNU2 TLS descriptors, prioritized constructors/destructors,
preinit arrays, weak/common/hidden/protected symbols, CET properties, SFrame,
COMDAT/link-order/merge/string sections, GNU unique/IFUNC symbols, unknown
alloc/nonalloc sections and a vendor note. GNU assembler is binutils 2.47.
`probe.c.in`, `probe.s.in` and `probe.tl.in` are generation inputs only.

To regenerate with the pinned producer majors and a fresh TypeLisp compiler:

```sh
TYPELISP_BIN=/absolute/path/to/typelisp \
ELF_FIXTURE_GCC=gcc ELF_FIXTURE_CLANG=clang-22 \
scripts/generate-elf-object-fixtures.sh
```

Generation sets `SOURCE_DATE_EPOCH=0`, builds from the fixed `probe.c` basename
and maps the work directory to `/elf-fixture` in debug/file paths. Exact
per-row options are recorded in `producers.tsv`; generation additionally uses
`-ffile-prefix-map` and `-fdebug-prefix-map`. Clang/GCC GNU2 use
`-mtls-dialect=gnu2`. SFrame uses GCC `-Wa,--gsframe=yes`. The TypeLisp fixture
uses public `build --direct --target linux-x86_64 --backend-mode scalar
--opt-level 2` with `TYPELISP_LINUX_DIRECT_OBJECT=1`; an assembler stub fails,
and an ld wrapper captures the actual temporary object before delegating to
GNU ld. This verifies the direct writer rather than an assembler fallback.

Generation saves GNU `readelf -W -S -s -r -g -n` output and, where available,
LLVM JSON under `target/exp/elf-object-fixtures/`. `.expected` files are the
numeric LLVM projections normalized by `tools/elf-object-oracle/normalize.tl`:

```sh
# After building tools/elf-object-oracle/main.tl with --stdlib-root src:
llvm-readobj --elf-output-style=JSON --file-headers --sections --symbols \
  --relocations --section-groups --notes OBJECT > object.llvm.json
ORACLE --normalize object.llvm.json > OBJECT.expected
```

The normalizer reads only independent JSON, never ELF bytes. It preserves
64-bit integers exactly, converts LLVM's unsigned RELA addends to signed
values and removes LLVM's synthesized display name for unnamed section
symbols. The live GNU comparison retains every section/symbol/rela/group/
member/note, comparing fields GNU displays, including flags, values, sizes,
indexes, addends and names. LLVM additionally compares raw name indexes,
types/flags, table/entry provenance, symbol links and exact note spans.
`linker_elf_object_reader_test_dump.tl` also has a complete test-only dump with
caller identity, compressed fields, classifications and priorities, covered by
structural boundary tests. GNU/LLVM format adapters fail on unrecognized
fixture note formats; they do not silently omit records.

Run the independent oracle gate with a fresh compiler:

```sh
TYPELISP_BIN=/absolute/path/to/typelisp \
scripts/verify-elf-object-reader-oracle.sh
```

The required Linux gate uses all 24 recorded producer inputs even when a
particular producer is not installed. `llvm-readobj` is checked when available;
GNU readelf and the recorded LLVM projection are always checked. Regenerating
fixtures or projections is explicit and must be reviewed with their producer
manifest. The reader itself never runs a producer, linker or decompressor.

The format authority is the [generic ELF ABI](https://gabi.xinuos.com/elf/02-eheader.html),
[sections](https://gabi.xinuos.com/elf/03-sheader.html),
[symbols](https://gabi.xinuos.com/v42/elf/05-symtab.html),
[relocations](https://gabi.xinuos.com/elf/06-reloc.html), and
[x86-64 relocation ABI](https://gitlab.com/x86-psABIs/x86-64-ABI/-/raw/master/x86-64-ABI/object-files.tex).
This reader uses the low two visibility bits of the SYSV/GNU x86-64 profile;
Solaris visibility extensions and semantic section admission belong elsewhere.
