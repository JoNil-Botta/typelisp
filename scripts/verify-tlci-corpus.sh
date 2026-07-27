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

for name in \
    malformed-bad-magic \
    malformed-truncated-header \
    malformed-truncated-range \
    malformed-version \
    malformed-content-hash \
    malformed-metadata-alignment \
    malformed-metadata-overlap \
    malformed-metadata
do
    inspect_invalid "$name"
done

EMITTED_EMPTY="$WORKDIR/emitted-metadata-only.tlci"
EMITTED_SECTIONS="$WORKDIR/emitted-sections.tlci"
if ! "$COMPILER" run tests/tlci/corpus_emit.tl \
    --stdlib-root stdlib \
    --stdlib-root src \
    -- "$EMITTED_EMPTY" "$EMITTED_SECTIONS" \
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

echo "TLCI format corpus passed (2 valid, 8 malformed)."
