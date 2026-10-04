# GNU ELF version-section fixtures

These are raw little-endian section bytes, extracted with GNU `objcopy` from
x86-64 DSOs produced by GNU ld 2.47, lld 22.1.8 and lld 23.1.2. Their C and
version-map inputs live in `scripts/generate-elf-version-fixtures.sh`; generated
source, objects, DSOs and `readelf --version-info` receipts stay under `target/exp`.

The `a` DSO defines its BASE, V1, V2 inheriting V1, and an empty WEAK_VER
inheriting V2. `.symver` provides `api@V1` and `api@@V2`, including a hidden
Versym. GNU ld records the parent Verdaux names and the empty node's WEAK flag;
lld emits one Verdaux per definition and omits these inheritance/weak flags.
The `use` DSO needs V2 from liba.so and B1 from libb.so. GNU ld interleaves each
Verneed with its Vernaux; lld places both headers before both auxiliaries.
The `client` DSO additionally defines BASE and CLIENT_1, exercising a shared
namespace of definition and need indices.

The `lld23-use` bytes contain a non-weak V2 and a WEAK B1 requirement. Its only
B1 reference is a weak undefined `beta`. GNU ld 2.47 and lld 22.1.8 emit a zero
Vernaux flag for the same reference. The weak fixture is actual lld 23 output,
not a patched golden. The source change introducing this behavior is
[LLVM #176673](https://github.com/llvm/llvm-project/pull/176673).

To reproduce without installing a toolchain or changing checked-in fixtures:

```sh
TYPELISP_LINUX_MEMORY_LIMIT_BACKEND=systemd-user-cgroup \
LLD_WEAK_LINKER=/path/to/ld.lld-23 \
scripts/run-memory-bounded.sh --limit-mib 1024 \
  --report target/exp/elf-version-fixtures-memory.txt -- \
  sh scripts/generate-elf-version-fixtures.sh
```

If a separate lld needs shared libraries, supply its `LD_LIBRARY_PATH` explicitly.
The wrapper writes new `.expected` files and provenance receipts in
`target/exp/elf-version-fixtures`; compare those bytes with this directory.
The static goldens are exercised on Linux and Windows by the existing inline
suite; fixture regeneration needs Linux producer tools and is a manual oracle.
