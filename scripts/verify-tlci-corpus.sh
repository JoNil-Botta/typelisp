#!/usr/bin/env sh
set -eu

# Verify immutable TLCI v2 bytes and public inspector output on every CI host.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

case "$(uname -s)" in
    Linux* | MINGW* | MSYS* | CYGWIN*) ;;
    *)
        echo "TLCI v2 corpus verification is unsupported on this host" >&2
        exit 1
        ;;
esac

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi

case "$COMPILER" in
    /* | [A-Za-z]:[/\\]*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

CORPUS=tests/tlci/corpus
WORKDIR=target/tlci-v2-corpus
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

(cd "$CORPUS" && sha256sum -c SHA256SUMS >/dev/null)

fail() {
    echo "TLCI v2 corpus: $*" >&2
    exit 1
}

compare_file() {
    expected=$1
    actual=$2
    label=$3
    if ! cmp -s "$expected" "$actual"; then
        echo "TLCI v2 corpus: $label mismatch" >&2
        diff -u "$expected" "$actual" >&2 || true
        exit 1
    fi
}

inspect_valid() {
    name=$1
    fixture="$CORPUS/$name.tlci"
    stdout="$WORKDIR/$name.stdout"
    stderr="$WORKDIR/$name.stderr"
    if ! "$COMPILER" inspect "$fixture" >"$stdout" 2>"$stderr"; then
        sed 's/^/  /' "$stderr" >&2 || true
        fail "$name was rejected"
    fi
    [ ! -s "$stderr" ] || fail "$name wrote unexpected stderr"
    compare_file "$CORPUS/$name.stdout" "$stdout" "$name stdout"
}

inspect_invalid() {
    name=$1
    fixture="$CORPUS/$name.tlci"
    stdout="$WORKDIR/$name.stdout"
    stderr="$WORKDIR/$name.stderr"
    set +e
    "$COMPILER" inspect "$fixture" >"$stdout" 2>"$stderr"
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail "$name was unexpectedly accepted"
    [ ! -s "$stdout" ] || fail "$name wrote unexpected stdout"
    compare_file "$CORPUS/$name.stderr" "$stderr" "$name stderr"
}

inspect_valid valid-metadata-only
inspect_valid valid-sections
inspect_valid valid-imports
inspect_valid valid-platform-linux-metadata
inspect_valid valid-platform-windows-metadata
inspect_valid valid-platform-linux-code
inspect_valid valid-platform-windows-code

for name in \
    malformed-bad-magic \
    malformed-truncated-header \
    malformed-truncated-range \
    malformed-version \
    malformed-content-hash \
    malformed-metadata-alignment \
    malformed-metadata-overlap \
    malformed-metadata \
    malformed-platform-unknown
do
    inspect_invalid "$name"
done

EMITTED_EMPTY="$WORKDIR/emitted-metadata-only.tlci"
EMITTED_SECTIONS="$WORKDIR/emitted-sections.tlci"
EMITTED_IMPORTS="$WORKDIR/emitted-imports.tlci"
if ! "$COMPILER" run tests/tlci/corpus_emit.tl \
    --stdlib-root stdlib \
    --stdlib-root src \
    -- "$EMITTED_EMPTY" "$EMITTED_SECTIONS" "$EMITTED_IMPORTS" \
    >"$WORKDIR/emitter.stdout" 2>"$WORKDIR/emitter.stderr"; then
    sed 's/^/  /' "$WORKDIR/emitter.stderr" >&2 || true
    fail "emitter witness failed"
fi
[ ! -s "$WORKDIR/emitter.stdout" ] || fail "emitter witness wrote stdout"
[ ! -s "$WORKDIR/emitter.stderr" ] || fail "emitter witness wrote stderr"
compare_file "$CORPUS/valid-metadata-only.tlci" "$EMITTED_EMPTY" \
    "metadata-only emitter bytes"
compare_file "$CORPUS/valid-sections.tlci" "$EMITTED_SECTIONS" \
    "section-bearing emitter bytes"
compare_file "$CORPUS/valid-imports.tlci" "$EMITTED_IMPORTS" \
    "import-bearing emitter bytes"

EMITTED_PLATFORM_LINUX_METADATA="$WORKDIR/emitted-platform-linux-metadata.tlci"
EMITTED_PLATFORM_WINDOWS_METADATA="$WORKDIR/emitted-platform-windows-metadata.tlci"
EMITTED_PLATFORM_LINUX_CODE="$WORKDIR/emitted-platform-linux-code.tlci"
EMITTED_PLATFORM_WINDOWS_CODE="$WORKDIR/emitted-platform-windows-code.tlci"
EMITTED_PLATFORM_UNKNOWN="$WORKDIR/emitted-platform-unknown.tlci"
if ! "$COMPILER" run tests/tlci/platform_corpus_emit.tl \
    --stdlib-root stdlib \
    --stdlib-root src \
    -- \
    "$EMITTED_PLATFORM_LINUX_METADATA" \
    "$EMITTED_PLATFORM_WINDOWS_METADATA" \
    "$EMITTED_PLATFORM_LINUX_CODE" \
    "$EMITTED_PLATFORM_WINDOWS_CODE" \
    "$EMITTED_PLATFORM_UNKNOWN" \
    >"$WORKDIR/platform-emitter.stdout" \
    2>"$WORKDIR/platform-emitter.stderr"; then
    sed 's/^/  /' "$WORKDIR/platform-emitter.stderr" >&2 || true
    fail "platform emitter witness failed"
fi
[ ! -s "$WORKDIR/platform-emitter.stdout" ] || \
    fail "platform emitter witness wrote stdout"
[ ! -s "$WORKDIR/platform-emitter.stderr" ] || \
    fail "platform emitter witness wrote stderr"
compare_file "$CORPUS/valid-platform-linux-metadata.tlci" \
    "$EMITTED_PLATFORM_LINUX_METADATA" "Linux metadata platform emitter bytes"
compare_file "$CORPUS/valid-platform-windows-metadata.tlci" \
    "$EMITTED_PLATFORM_WINDOWS_METADATA" "Windows metadata platform emitter bytes"
compare_file "$CORPUS/valid-platform-linux-code.tlci" \
    "$EMITTED_PLATFORM_LINUX_CODE" "Linux code platform emitter bytes"
compare_file "$CORPUS/valid-platform-windows-code.tlci" \
    "$EMITTED_PLATFORM_WINDOWS_CODE" "Windows code platform emitter bytes"
compare_file "$CORPUS/malformed-platform-unknown.tlci" \
    "$EMITTED_PLATFORM_UNKNOWN" "unknown platform emitter bytes"

assert_platform_only_delta() {
    linux_image=$1
    windows_image=$2
    label=$3
    delta=$(cmp -l "$linux_image" "$windows_image" | \
        awk '{ printf "%s%s", sep, $1; sep=" " } END { print "" }')
    [ "$delta" = "17 49 50 51 52" ] || \
        fail "$label changed bytes outside platform field and content hash: $delta"
}
assert_platform_only_delta \
    "$CORPUS/valid-platform-linux-metadata.tlci" \
    "$CORPUS/valid-platform-windows-metadata.tlci" \
    "metadata platform pair"
assert_platform_only_delta \
    "$CORPUS/valid-platform-linux-code.tlci" \
    "$CORPUS/valid-platform-windows-code.tlci" \
    "code platform pair"

echo "TLCI format corpus passed (7 valid, 9 malformed)."
