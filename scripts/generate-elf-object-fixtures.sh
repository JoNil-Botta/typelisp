#!/usr/bin/env sh
set -eu
# Oracle-only generation. Normal reader tests embed the recorded .in bytes.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FIXTURES="$ROOT/tests/fixtures/elf-object"
WORK=${TYPELISP_ELF_FIXTURE_WORK:-"$ROOT/target/exp/elf-object-fixtures"}
GCC=${ELF_FIXTURE_GCC:-gcc}
CLANG=${ELF_FIXTURE_CLANG:-clang-22}
AS=${ELF_FIXTURE_AS:-as}
COMPILER=${TYPELISP_BIN:?set TYPELISP_BIN to the current compiler}
mkdir -p "$WORK"
gcc_version=$("$GCC" -dumpfullversion)
clang_version=$("$CLANG" -dumpversion)
case "$gcc_version" in 16.*) ;; *) echo "ELF fixtures require GCC 16" >&2; exit 1 ;; esac
case "$clang_version" in 22.*) ;; *) echo "ELF fixtures require Clang 22" >&2; exit 1 ;; esac
cp "$FIXTURES/probe.c.in" "$WORK/probe.c"
cp "$FIXTURES/probe.s.in" "$WORK/probe.s"
export SOURCE_DATE_EPOCH=0
printf 'fixture\tproducer\tversion\toptions\tbytes\tsha256\n' > "$FIXTURES/producers.tsv"
record() {
    name=$1 producer=$2 version=$3 options=$4
    cp "$WORK/$name.o" "$FIXTURES/$name.in"
    bytes=$(wc -c < "$FIXTURES/$name.in" | tr -d ' ')
    digest=$(sha256sum "$FIXTURES/$name.in" | cut -d ' ' -f 1)
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$producer" "$version" "$options" "$bytes" "$digest" >> "$FIXTURES/producers.tsv"
    readelf -W -S -s -r -g -n "$FIXTURES/$name.in" > "$WORK/$name.readelf"
    if command -v llvm-readobj >/dev/null 2>&1; then
        llvm-readobj --elf-output-style=JSON --file-headers --sections --symbols --relocations --section-groups --notes \
            "$FIXTURES/$name.in" > "$WORK/$name.llvm.json"
    fi
}
for producer in gcc clang; do
    if [ "$producer" = gcc ]; then cc=$GCC; version=$gcc_version; else cc=$CLANG; version=$clang_version; fi
    for opt in 0 2; do
        for debug in g gz; do
            for common in common no-common; do
                name="$producer-O$opt-$debug-$common"
                if [ "$debug" = gz ]; then compress=-gz=zlib; else compress=; fi
                options="-O$opt -g $compress -ffunction-sections -fdata-sections -f$common -fPIC -fcf-protection=full"
                (cd "$WORK" && "$cc" -O"$opt" -g ${compress:+"$compress"} \
                    -ffunction-sections -fdata-sections -f"$common" -fPIC -fcf-protection=full \
                    -ffile-prefix-map="$WORK"=/elf-fixture -fdebug-prefix-map="$WORK"=/elf-fixture \
                    -c probe.c -o "$name.o")
                record "$name" "$producer" "$version" "$options"
            done
        done
        name="$producer-O$opt-tlsdesc"
        dialect=gnu2
        (cd "$WORK" && "$cc" -O"$opt" -g -fPIC -fcf-protection=full \
            -mtls-dialect="$dialect" -ffile-prefix-map="$WORK"=/elf-fixture \
            -fdebug-prefix-map="$WORK"=/elf-fixture -c probe.c -o "$name.o")
        record "$name" "$producer" "$version" "-O$opt -g -fPIC -fcf-protection=full -mtls-dialect=$dialect"
    done
done
for opt in 0 2; do
    name="gcc-O$opt-sframe"
    (cd "$WORK" && "$GCC" -O"$opt" -g -fPIC -Wa,--gsframe=yes \
        -ffile-prefix-map="$WORK"=/elf-fixture -fdebug-prefix-map="$WORK"=/elf-fixture \
        -c probe.c -o "$name.o")
    record "$name" gcc "$gcc_version" "-O$opt -g -fPIC -Wa,--gsframe=yes"
done
"$AS" "$WORK/probe.s" -o "$WORK/gnu-as-groups.o"
record gnu-as-groups as "$("$AS" --version | head -n 1)" "probe.s"

# Capture the successful public direct-object route, while making assembler
# fallback fail. The CLI owns and removes its temporary link input.
cp "$FIXTURES/probe.tl.in" "$WORK/probe.tl"
mkdir -p "$WORK/capture-bin"
real_ld=$(command -v ld)
cat > "$WORK/capture-bin/as" <<'NO_ASSEMBLER'
#!/usr/bin/env sh
exit 79
NO_ASSEMBLER
cat > "$WORK/capture-bin/ld" <<'CAPTURE_OBJECT'
#!/usr/bin/env sh
set -eu
for argument do
    case "$argument" in *.o) cp "$argument" "$ELF_FIXTURE_CAPTURE" ;; esac
done
exec "$ELF_FIXTURE_REAL_LD" "$@"
CAPTURE_OBJECT
chmod +x "$WORK/capture-bin/as" "$WORK/capture-bin/ld"
PATH="$WORK/capture-bin:$PATH" ELF_FIXTURE_REAL_LD="$real_ld" \
    ELF_FIXTURE_CAPTURE="$WORK/typelisp-direct.o" TYPELISP_LINUX_DIRECT_OBJECT=1 \
    "$COMPILER" build --direct "$WORK/probe.tl" --target linux-x86_64 \
    --backend-mode scalar --opt-level 2 --stdlib-root "$ROOT/stdlib" -o "$WORK/typelisp-main"
[ -s "$WORK/typelisp-direct.o" ]
record typelisp-direct typelisp "$(sha256sum "$COMPILER" | cut -d ' ' -f 1)" \
    "build --direct --target linux-x86_64 --backend-mode scalar --opt-level 2; assembler denied"
