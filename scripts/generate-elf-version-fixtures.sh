#!/bin/sh
# Regenerate independent GNU ld/lld section oracles, without changing goldens.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=${1:-"$ROOT/target/exp/elf-version-fixtures"}
mkdir -p "$OUT"
cat > "$OUT/a.c" <<'SOURCE'
int old_api(int x) { return x + 1; }
int new_api(int x) { return x + 2; }
int old_only(void) { return 11; }
__asm__(".symver old_api,api@V1");
__asm__(".symver new_api,api@@V2");
SOURCE
cat > "$OUT/b.c" <<'SOURCE'
int beta(void) { return 17; }
SOURCE
cat > "$OUT/use.c" <<'SOURCE'
extern int api(int);
extern int beta(void) __attribute__((weak));
extern int WEAK_VER;
int consume(int x) { return api(x) + beta() + (int)(long)&WEAK_VER; }
SOURCE
cat > "$OUT/many.c" <<'SOURCE'
extern int api(int);
extern int legacy(int);
extern int beta(void) __attribute__((weak));
__asm__(".symver legacy,api@V1");
int many(int x) { return api(x) + legacy(x) + beta(); }
SOURCE
cat > "$OUT/a.map" <<'MAP'
V1 { global: api; old_only; local: *; };
V2 { global: api; } V1;
WEAK_VER { } V2;
MAP
printf '%s\n' 'B1 { global: beta; local: *; };' > "$OUT/b.map"
printf '%s\n' 'CLIENT_1 { global: consume; local: *; };' > "$OUT/client.map"
for source in a b use many; do
    "${CC:-clang}" -fPIC -ffreestanding -fno-builtin -O2 -c "$OUT/$source.c" -o "$OUT/$source.o"
done
extract() {
    prefix=$1
    file=$2
    shift 2
    for section in "$@"; do
        objcopy --dump-section "$section=$OUT/$prefix$section.expected" "$file"
    done
    readelf --version-info "$file" > "$OUT/$prefix.versions"
}
for producer in ld ld.lld; do
    mkdir -p "$OUT/$producer"
    "$producer" --version > "$OUT/$producer.version"
    "$producer" -shared --soname=liba.so --version-script="$OUT/a.map" "$OUT/a.o" -o "$OUT/$producer/liba.so"
    "$producer" -shared --soname=libb.so --version-script="$OUT/b.map" "$OUT/b.o" -o "$OUT/$producer/libb.so"
    "$producer" -shared --soname=libuse.so "$OUT/use.o" "$OUT/$producer/liba.so" "$OUT/$producer/libb.so" -o "$OUT/$producer/libuse.so"
    "$producer" -shared --soname=libclient.so --version-script="$OUT/client.map" "$OUT/use.o" "$OUT/$producer/liba.so" "$OUT/$producer/libb.so" -o "$OUT/$producer/libclient.so"
    "$producer" -shared --soname=libmany.so "$OUT/many.o" "$OUT/$producer/liba.so" "$OUT/$producer/libb.so" -o "$OUT/$producer/libmany.so"
    extract "$producer-a" "$OUT/$producer/liba.so" .dynstr .gnu.version .gnu.version_d
    extract "$producer-use" "$OUT/$producer/libuse.so" .dynstr .gnu.version .gnu.version_r
    extract "$producer-client" "$OUT/$producer/libclient.so" .dynstr .gnu.version .gnu.version_d .gnu.version_r
    extract "$producer-many" "$OUT/$producer/libmany.so" .dynstr .gnu.version .gnu.version_r
done
# LLD 23 adds VER_FLG_WEAK for all-weak references; earlier versions emit zero.
# An explicit executable avoids installing or silently substituting a toolchain.
if [ -n "${LLD_WEAK_LINKER:-}" ]; then
    "$LLD_WEAK_LINKER" --version > "$OUT/lld23.version"
    "$LLD_WEAK_LINKER" -shared --soname=libuse.so "$OUT/use.o" "$OUT/ld.lld/liba.so" "$OUT/ld.lld/libb.so" -o "$OUT/ld.lld/libuse23.so"
    extract lld23-use "$OUT/ld.lld/libuse23.so" .dynstr .gnu.version .gnu.version_r
fi
