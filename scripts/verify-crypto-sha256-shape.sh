#!/usr/bin/env sh
set -eu

# Pin SHA-256's fixed public 64-round shape and cleanup loops at every
# supported optimization level. Runtime vectors prove semantics; this gate
# proves the compiled core keeps its schedule/state/digest volatile wipes and
# does not acquire a host-crypto dependency.

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

WORKDIR="$ROOT/target/crypto-sha256-shape"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

FIXTURE="$WORKDIR/fixture.tl"
cat > "$FIXTURE" <<'EOF'
(import stdlib.byte_buf)
(import stdlib.crypto_sha256)

(define (main) : i64
  (let
    [text : String "abc"]
    [state : crypto_sha256.Sha256State (crypto_sha256.new)]
    (match
      (crypto_sha256.update!
        (&mut state)
        (byte_buf.str-as-bytes (& text)))
      [(crypto_sha256.Sha256UpdateErr _) 1]
      [(crypto_sha256.Sha256UpdateOk)
        (match (crypto_sha256.finalize! (&mut state))
          [(crypto_sha256.Sha256FinalizeErr _) 1]
          [(crypto_sha256.Sha256FinalizeOk digest)
            (begin
              (crypto_sha256.wipe-state! (&mut state))
              (crypto_sha256.wipe-digest! (&mut digest))
              (if (and state.finalized
                       (= (cast
                            (crypto_sha256.digest-byte (& digest) 0)
                            : i64)
                          0))
                42
                1))])])))
EOF

fail() {
    echo "SHA-256 assembly-shape verification failed: $*" >&2
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
    grep -E '^[[:space:]]+movl %[a-z0-9]+, \(%[a-z0-9]+\)$' "$_body" >/dev/null ||
        fail "$_label lost its 32-bit volatile indirect zero store"
    _loops=$(count_backward_branches "$_body")
    if [ "$_loops" -lt "$_minimum_loops" ]; then
        fail "$_label expected at least $_minimum_loops loop(s), found $_loops"
    fi
}

if sed '/^[[:space:]]*;/d' stdlib/crypto_sha256.tl |
    grep -E '\(extern|\(import[[:space:]]+stdlib\.(ffi|runtime)' >/dev/null; then
    fail "core acquired an FFI, runtime, or extern dependency"
fi

SCHEDULE=_tl_stdlib_crypto_sha256_stdlib_crypto_sha256_wipe_schedule_pointer_bang
COMPRESS=_tl_stdlib_crypto_sha256_stdlib_crypto_sha256_compress_bang
STATE_PUBLIC=_tl_stdlib_crypto_sha256_stdlib_crypto_sha256_wipe_state_bang
DIGEST_PUBLIC=_tl_stdlib_crypto_sha256_stdlib_crypto_sha256_wipe_digest_bang

for level in 0 1 2; do
    assembly=$(compile_level "$level")
    verify_wipe_loop "$assembly" "$SCHEDULE" 64 1 "opt${level}-schedule"

    compress_body="$WORKDIR/opt${level}-compress.body"
    extract_function "$assembly" "$COMPRESS" "$compress_body"
    grep -F '$64' "$compress_body" >/dev/null ||
        fail "opt${level}-compress lost its fixed 64-round bound"
    compress_loops=$(count_backward_branches "$compress_body")
    [ "$compress_loops" -ge 3 ] ||
        fail "opt${level}-compress expected three public loops, found $compress_loops"
    grep -E "^[[:space:]]+(call|jmp) $SCHEDULE$" "$compress_body" >/dev/null ||
        fail "opt${level}-compress no longer wipes its owning schedule"

    # Single-call cleanup helpers may inline into main. Account for every
    # expected loop and repeated eight-word bound when that happens.
    inline_loops=0
    inline_eight_bounds=0
    if grep -Fx "$STATE_PUBLIC:" "$assembly" >/dev/null; then
        verify_wipe_loop "$assembly" "$STATE_PUBLIC" 8 2 "opt${level}-state"
        state_body="$WORKDIR/opt${level}-opt${level}-state.body"
    else
        inline_loops=$((inline_loops + 2))
        inline_eight_bounds=$((inline_eight_bounds + 1))
        state_body="$WORKDIR/opt${level}-main.body"
        extract_function "$assembly" main "$state_body"
    fi
    grep -F '$16' "$state_body" >/dev/null ||
        fail "opt${level}-state lost its 16-word partial-block wipe bound"
    grep -E '^[[:space:]]+movq %[a-z0-9]+, \(%[a-z0-9]+\)$' "$state_body" >/dev/null ||
        fail "opt${level}-state lost its 64-bit volatile scalar stores"

    if grep -Fx "$DIGEST_PUBLIC:" "$assembly" >/dev/null; then
        verify_wipe_loop "$assembly" "$DIGEST_PUBLIC" 8 1 "opt${level}-digest"
    else
        inline_loops=$((inline_loops + 1))
        inline_eight_bounds=$((inline_eight_bounds + 1))
    fi
    if [ "$inline_loops" -gt 0 ]; then
        verify_wipe_loop "$assembly" main 8 "$inline_loops" "opt${level}-inlined"
        inline_body="$WORKDIR/opt${level}-opt${level}-inlined.body"
        eight_bounds=$(grep -cE '^[[:space:]]+cmpq \$8,' "$inline_body" || true)
        zero_stores=$(grep -cE '^[[:space:]]+movl %[a-z0-9]+, \(%[a-z0-9]+\)$' "$inline_body" || true)
        [ "$eight_bounds" -ge "$inline_eight_bounds" ] ||
            fail "opt${level}-inlined lost a distinct eight-word wipe"
        [ "$zero_stores" -ge "$inline_loops" ] ||
            fail "opt${level}-inlined lost a distinct volatile store"
    fi
done

repeat=$(compile_level 2 -repeat)
cmp -s "$WORKDIR/opt2.s" "$repeat" ||
    fail "two opt2 compilations produced different assembly"

if command -v as >/dev/null 2>&1; then
    as "$WORKDIR/opt2.s" -o "$WORKDIR/opt2.o" ||
        fail "GNU as rejected opt2 assembly"
fi

echo "SHA-256 fixed-round and wipe assembly shape passed at opt0, opt1, and opt2"
