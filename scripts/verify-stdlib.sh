#!/usr/bin/env sh
set -eu

# verify-stdlib.sh — Verify that stdlib modules import correctly via --stdlib-root.
# refs #285

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

case "$(uname -s)" in
    Linux*) ;;
    *)
        echo "stdlib verification is Linux-only (requires as + ld)" >&2
        exit 0
        ;;
esac

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    cargo build --release --quiet
    COMPILER="$ROOT/target/release/typelisp"
fi

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

# Manifest of expected stdlib modules and their verification details.
# Each entry: module_name expected_exit_code
# When adding a new stdlib module, append a line here and add a witness
# program in write_witness_for_module below.
manifest() {
    cat <<'EOF'
string 42
EOF
}

# Write a witness program for a stdlib module into the given file.
# The witness should exercise the module and exit with the expected code.
write_witness_for_module() {
    module=$1
    out=$2
    case "$module" in
        string)
            cat > "$out" <<'EOF'
(import "stdlib/string.tl")

(define (main) : i64
  (begin
    ;; trim behavior
    (print-string (string-trim-left "  hello"))
    (print-string "|")
    (print-newline)

    (print-string (string-trim-right "hello  "))
    (print-string "|")
    (print-newline)

    (print-string (string-trim "  hello  "))
    (print-string "|")
    (print-newline)

    ;; contains behavior
    (if (string-contains "hello" "ell")
        (print-string "contains")
        (print-string "missing"))
    (print-newline)

    ;; replace behavior
    (print-string (string-replace "hello" "ell" "ipp"))
    (print-newline)

    42))
EOF
            ;;
        *)
            echo "No witness program for stdlib module: $module" >&2
            exit 1
            ;;
    esac
}

# Expected stdout for each module witness.
expected_stdout() {
    case "$1" in
        string)
            printf 'hello|\nhello|\nhello|\ncontains\nhippo\n'
            ;;
        *)
            printf ''
            ;;
    esac
}

WORKDIR="$ROOT/target/stdlib-verify"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

failed=0

# Verify every module listed in the manifest.
manifest | while read -r module want; do
    [ -n "$module" ] || continue

    asm="$WORKDIR/$module.s"
    obj="$WORKDIR/$module.o"
    bin="$WORKDIR/$module"
    witness="$WORKDIR/$module.tl"

    echo "[$module] writing witness -> $witness"
    write_witness_for_module "$module" "$witness"

    echo "[$module] compiling with --stdlib-root"
    "$COMPILER" compile "$witness" \
        --stdlib-root "$ROOT/stdlib" \
        -o "$asm"

    as "$asm" -o "$obj"
    ld "$obj" -o "$bin" \
        -dynamic-linker /lib64/ld-linux-x86-64.so.2 \
        -lc

    echo "[$module] running -> expect exit $want"
    set +e
    stdout=$("$bin" 2>/dev/null)
    got=$?
    set -e

    if [ "$got" -ne "$want" ]; then
        echo "FAIL: $module expected exit $want, got $got" >&2
        failed=$((failed + 1))
    else
        want_stdout=$(expected_stdout "$module")
        if [ "$stdout" != "$want_stdout" ]; then
            echo "FAIL: $module stdout mismatch" >&2
            echo "  expected: $want_stdout" >&2
            echo "  got:      $stdout" >&2
            failed=$((failed + 1))
        else
            echo "PASS: $module exit=$got"
        fi
    fi
done

# Verify that every .tl file in stdlib/ is accounted for in the manifest.
# This prevents new stdlib modules from silently skipping CI coverage.
stdlib_unaccounted=0
for stdlib_file in "$ROOT/stdlib/"*.tl; do
    [ -f "$stdlib_file" ] || continue
    name=$(basename "$stdlib_file" .tl)
    if ! manifest | grep -q "^$name "; then
        echo "ERROR: stdlib module '$name' is not in the verification manifest" >&2
        stdlib_unaccounted=$((stdlib_unaccounted + 1))
    fi
done

if [ "$stdlib_unaccounted" -gt 0 ]; then
    echo "$stdlib_unaccounted stdlib module(s) missing from manifest — update scripts/verify-stdlib.sh" >&2
    exit 1
fi

if [ "$failed" -gt 0 ]; then
    echo "$failed stdlib verification(s) failed" >&2
    exit 1
fi

echo "All stdlib modules verified."
