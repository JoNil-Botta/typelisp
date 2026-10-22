# Checked ELF shared-object inputs

These eleven ELF64/LSB/x86-64 inputs are data fixtures; tests never load or
execute them. Six small DSOs were built with GCC 16.2.1 and Clang 23.1.3,
GNU ld 2.47, and each of SysV-only, GNU-only and both hash styles. They define
default/non-default API versions, a weak definition, protected visibility,
TLS and IFUNC; they need libc.so.6 at GLIBC_2.2.5, and retain soname and loader
flags. This is the small glibc-style definition/need shape. Another input
removes only the section-table locator from the GCC/both image. The musl input
is actual musl 1.2.5 libc.so, built from its pinned upstream release.

The producer source and complete compiler/linker options are in
scripts/generate-elf-dso-fixtures.sh. Regeneration writes to target/exp by
default and does not replace these snapshots. Supply MUSL_LIBC pointing to
the separately built pinned musl image. producer.manifest records the source
hash, build configuration, tool versions and every input/golden digest.
COPYRIGHT.md retains musl's complete upstream copyright notices.

Each .expected file is generated independently from GNU readelf 2.47:
readelf -W -D -s --dynamic --version-info. It covers every dynamic entry,
symbol, Versym, Verdef/Verdaux parent and Verneed/Vernaux record that tool
exposes, preserving duplicate rows and physical symbol/version offsets.
scripts/verify-elf-dso-reader-oracle.sh normalizes the live tool output and
compares both the checked golden and the reader's projection. The required
Linux gate runs all eleven producers. The same checked bytes and goldens run
without external tools in inline and native opt0/1/2 tests on both hosts.

GNU readelf -V omits version records when section headers are absent, even
though -sD resolves symbol versions. That fixture's live projection compares
all dynamic entries and versioned symbols. The internal test additionally
checks every original/stripped byte outside the removed header fields, then
compares the stripped reader's complete version model with the sectionful
producer's independent golden.

The fixtures exercise wire syntax, not admission, provider selection,
relocation, execution or system-library search. Hash lookups are also checked
against an independent linear wire scan; malformed mutations, resource
boundaries and a complete minimal-file truncation corpus are generated in the
TypeLisp tests. The fixture sources are project-owned, except the musl image,
whose upstream notices are retained alongside it.

Two additional GCC DSOs contain only undefined dynamic symbols and an empty
GNU hash, with/without SysV hash. GNU symoffset is one despite six symbols.
The reader uses a checked SysV or section count; native tests also strip each
image. A sectionless GNU-only empty hash has no encoded total count and returns
UnsupportedMetadata at GNU-empty-symbol-count instead of guessing a boundary.

The GNU assembler/linker producer zero-dynstr places the dynamic string table
at virtual address zero. Its unallocated .strtab and .shstrtab also have zero
addresses and must remain unrelated. Tests accept those ordinary tables, then
mark each allocated and require a source-offset section disagreement.
