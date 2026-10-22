#!/bin/sh
# Producer-only fixture regeneration; never invoked by the reader or its tests.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=${1:-"$ROOT/target/exp/elf-dso-fixtures"}
mkdir -p "$OUT"
cat > "$OUT/fixture.c" <<'C'
extern int puts(const char *);
int old_api(int x) { return x + 1; }
int new_api(int x) { return puts("fixture") + x; }
__asm__(".symver old_api,api@TL_1");
__asm__(".symver new_api,api@@TL_2");
__attribute__((weak)) int weak_api(void) { return 17; }
__attribute__((visibility("protected"))) int protected_api(void) { return 19; }
__thread int tls_slot = 23;
static int selected(void) { return 29; }
static void *resolve(void) { return (void *)&selected; }
int ifunc_api(void) __attribute__((ifunc("resolve")));
C
cat > "$OUT/fixture.map" <<'MAP'
TL_1 { global: api; weak_api; protected_api; tls_slot; ifunc_api; local: *; };
TL_2 { global: api; } TL_1;
MAP
for producer in gcc clang; do
    "$producer" --version > "$OUT/$producer.version"
    for hash in sysv gnu both; do
        "$producer" -fPIC -shared -O2 -g0 -Wl,--build-id=none \
            -Wl,--hash-style="$hash",--soname=libfixture.so,-z,now,-z,nodelete \
            -Wl,--version-script="$OUT/fixture.map" "$OUT/fixture.c" \
            -o "$OUT/$producer-$hash.in"
    done
done
cp "$OUT/gcc-both.in" "$OUT/no-sections.in"
dd if=/dev/zero of="$OUT/no-sections.in" bs=1 seek=40 count=8 conv=notrunc 2>/dev/null
dd if=/dev/zero of="$OUT/no-sections.in" bs=1 seek=58 count=6 conv=notrunc 2>/dev/null
if [ -n "${MUSL_LIBC:-}" ]; then
    cp "$MUSL_LIBC" "$OUT/musl-1.2.5.in"
fi
readelf --version > "$OUT/readelf.version"
ld --version > "$OUT/ld.version"
for fixture in "$OUT"/*.in; do
    readelf -W --use-dynamic --dyn-syms --dynamic --version-info "$fixture" > "$fixture.readelf"
    sha256sum "$fixture"
done
