# Ordinary archive reader fixtures

`producer.manifest` pins the archive bytes and producer versions. Fixtures
contain three ELF64/x86-64 objects and one opaque, odd-sized member. The first
and third objects have the same member name and both define `shared`.
`*.members.expected` records `llvm-ar tO`; its hexadecimal offsets point to
object content, after the member header and any BSD name prefix.
`*.symbols.expected` records `llvm-nm --print-armap`, including the individual
objects' symbols. These oracle commands run separately from the pure reader
tests, which use the captured member/name/order/target expectations without
running a compiler, archiver or symbol tool.

The producer host was Linux x86-64, Clang/LLVM 23.1.3 and GNU Binutils 2.47.
Create the object inputs in an empty directory:

```sh
mkdir first last
printf '.text\n.globl alpha, shared\nalpha:\nshared:\n.byte 1\n' | clang -x assembler -c - -o first/dup.o
printf '.text\n.globl beta\nbeta:\n.byte 2\n' | clang -x assembler -c - -o unusually-long-member-name.o
printf '.text\n.globl gamma, shared\ngamma:\nshared:\n.byte 3\n' | clang -x assembler -c - -o last/dup.o
printf x > odd
ar qcD gnu.in first/dup.o unusually-long-member-name.o last/dup.o odd
ranlib -D gnu.in
llvm-ar --format=gnu qcsD llvm-gnu.in first/dup.o unusually-long-member-name.o last/dup.o odd
SYM64_THRESHOLD=0 llvm-ar --format=gnu qcsD llvm-gnu64.in first/dup.o unusually-long-member-name.o last/dup.o odd
llvm-ar --format=bsd qcSD llvm-bsd.in first/dup.o unusually-long-member-name.o last/dup.o odd
llvm-ranlib -D llvm-bsd.in
llvm-ar --format=gnu qcSD no-index.in first/dup.o unusually-long-member-name.o last/dup.o odd
```

The GNU and LLVM GNU32 outputs are byte-identical; only `gnu.in` is retained.
`SYM64_THRESHOLD=0` is LLVM's archive-writer test hook for producing the real
`/SYM64/` encoding without a multi-gigabyte fixture. It changes the producer,
not the TypeLisp reader. Do not silently replace pinned fixture bytes when
updating the tools; check both oracle outputs and update the manifest explicitly.

`bsd-sorted.in` is a documented derivative of `llvm-bsd.in`, independently
accepted by the same `llvm-ar`/`llvm-nm` oracle commands. Its first header uses
`#1/20`, size 100, and a 20-byte name prefix (`__.SYMDEF SORTED` plus four NULs).
The original 80-byte ranlib payload is retained, with its five little-endian
`(string offset, member header offset)` pairs replaced, in order, by
`(0,168), (13,680), (18,1176), (6,168), (24,1176)`. The string table and its
padding are unchanged; every later member moves forward eight bytes. This
preserves both duplicate symbol hints while exercising the sorted-index form.

The inline tests additionally build small byte fixtures for empty names,
unsigned overflow, both BSD word sizes and byte orders, malformed structures,
and exact resource limits. They test all byte truncations and all candidate
header offsets. Synthetic names and index hints need not describe object
symbols: validating hint-versus-object content belongs to the later lazy-loader
adapter. The reader preserves physical identity and never extracts by name.
