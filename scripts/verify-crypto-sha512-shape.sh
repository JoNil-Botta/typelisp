#!/usr/bin/env sh
set -eu

# Prove SHA-512's explicit wipe loops survive every supported optimization
# level. Runtime tests pin the poisoned public values; this gate pins the
# volatile stores that erase the previous by-value snapshots and compression
# schedule after their last semantic use.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

WORKDIR="$ROOT/target/crypto-sha512-shape"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

FIXTURE="$WORKDIR/fixture.tl"
cat > "$FIXTURE" <<'EOF'
(import stdlib.byte_buf)
(import stdlib.crypto_sha512)

(define (main) : i64
  (let
    [text : String "abc"]
    [state : crypto_sha512.Sha512State (crypto_sha512.new)]
    (match
      (crypto_sha512.update!
        (&mut state)
        (byte_buf.str-as-bytes (& text)))
      [(crypto_sha512.Sha512UpdateErr _) 1]
      [(crypto_sha512.Sha512UpdateOk)
        (match (crypto_sha512.finalize! (&mut state))
          [(crypto_sha512.Sha512FinalizeErr _) 1]
          [(crypto_sha512.Sha512FinalizeOk digest)
            (begin
              (crypto_sha512.wipe-state! (&mut state))
              (crypto_sha512.wipe-digest! (&mut digest))
              (if (and state.finalized
                       (= (cast
                            (crypto_sha512.digest-byte (& digest) 0)
                            : i64)
                          0))
                42
                1))])])))
EOF

fail() {
    echo "SHA-512 assembly-shape verification failed: $*" >&2
    exit 1
}

compile_level() {
    _level=$1
    _suffix=${2:-}
    _assembly="$WORKDIR/opt${_level}${_suffix}.s"
    _stdout="$WORKDIR/opt${_level}${_suffix}.stdout"
    _stderr="$WORKDIR/opt${_level}${_suffix}.stderr"
    if ! "$COMPILER" compile "$FIXTURE" \
        --target linux-x86_64 \
        --opt-level "$_level" \
        --stdlib-root "$ROOT/stdlib" \
        --stdlib-root "$ROOT/src" \
        -o "$_assembly" > "$_stdout" 2> "$_stderr"; then
        sed 's/^/  /' "$_stdout" >&2 || true
        sed 's/^/  /' "$_stderr" >&2 || true
        fail "opt$_level compilation failed"
    fi
    printf '%s\n' "$_assembly"
}

extract_function() {
    _assembly=$1
    _symbol=$2
    _output=$3
    if ! awk -v label="$_symbol:" '
        $0 == label { in_function = 1; print; next }
        in_function && /^\.globl[[:space:]]/ { exit 0 }
        in_function && /^[[:space:]]*\.size[[:space:]]/ { print; exit 0 }
        in_function { print }
        END { if (!in_function) exit 2 }
    ' "$_assembly" > "$_output"; then
        fail "missing function $_symbol in $(basename "$_assembly")"
    fi
}

count_backward_branches() {
    awk '
        /^[^[:blank:]:]+:$/ {
            labels[substr($0, 1, length($0) - 1)] = 1
            next
        }
        /^[[:blank:]]+j[a-z]+[[:blank:]]+[^[:blank:]*%(,]+$/ {
            if ($2 in labels) count++
        }
        END { print count + 0 }
    ' "$1"
}

verify_wipe_loop() {
    _assembly=$1
    _symbol=$2
    _bound=$3
    _minimum_loops=$4
    _label=$5
    _body="$WORKDIR/$(basename "$_assembly" .s)-${_label}.body"
    extract_function "$_assembly" "$_symbol" "$_body"

    grep -F "\$$_bound" "$_body" >/dev/null ||
        fail "$_label lost its $_bound-word public loop bound"
    grep -E '^[[:space:]]+movq %[a-z0-9]+, \(%[a-z0-9]+\)$' "$_body" >/dev/null ||
        fail "$_label lost its volatile indirect zero store"
    _loops=$(count_backward_branches "$_body")
    if [ "$_loops" -lt "$_minimum_loops" ]; then
        fail "$_label expected at least $_minimum_loops wipe loop(s), found $_loops"
    fi
}

SCHEDULE=_tl_stdlib_crypto_sha512_stdlib_crypto_sha512_wipe_schedule_pointer_bang
COMPRESS=_tl_stdlib_crypto_sha512_stdlib_crypto_sha512_compress_bang
STATE_PUBLIC=_tl_stdlib_crypto_sha512_stdlib_crypto_sha512_wipe_state_bang
DIGEST_PUBLIC=_tl_stdlib_crypto_sha512_stdlib_crypto_sha512_wipe_digest_bang

for level in 0 1 2; do
    assembly=$(compile_level "$level")
    verify_wipe_loop "$assembly" "$SCHEDULE" 80 1 "opt${level}-schedule"
    compress_body="$WORKDIR/opt${level}-compress.body"
    extract_function "$assembly" "$COMPRESS" "$compress_body"
    grep -E "^[[:space:]]+(call|jmp) $SCHEDULE$" "$compress_body" >/dev/null ||
        fail "opt${level}-compress no longer wipes its owning schedule"

    verify_wipe_loop "$assembly" "$STATE_PUBLIC" 8 2 "opt${level}-state"
    state_body="$WORKDIR/opt${level}-opt${level}-state.body"
    grep -F '$16' "$state_body" >/dev/null ||
        fail "opt${level}-state lost its 16-word partial-block wipe bound"
    verify_wipe_loop "$assembly" "$DIGEST_PUBLIC" 8 1 "opt${level}-digest"
done

repeat=$(compile_level 2 -repeat)
cmp -s "$WORKDIR/opt2.s" "$repeat" ||
    fail "two opt2 compilations produced different assembly"

if command -v as >/dev/null 2>&1; then
    as "$WORKDIR/opt2.s" -o "$WORKDIR/opt2.o" ||
        fail "GNU as rejected opt2 assembly"
fi

echo "SHA-512 wipe assembly shape passed at opt0, opt1, and opt2"
