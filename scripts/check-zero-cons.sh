#!/usr/bin/env sh
set -eu

# Structural zero-cons gate.
#
# --fixtures is mergeable while the repository-wide migration umbrella is in
# progress: it enforces zero in examples, tests, src/*_tests.tl, src/tests, and
# every TypeLisp program embedded in a source string. The default --full mode
# scans every direct and embedded definition under all five source roots. CI
# switches to --full once the independently owned production families reach
# zero; neither mode has a cons-family allowlist.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

MODE=full
SELF_TEST=0

usage() {
    cat >&2 <<'EOF'
usage: scripts/check-zero-cons.sh [--full | --fixtures | --self-test]

--full       scan all direct and embedded TypeLisp definitions (default)
--fixtures   enforce zero in fixture files and all embedded TypeLisp programs
--self-test  run positive and negative structural-classifier tests
EOF
}

case "${1:-}" in
    "") ;;
    --full) MODE=full ;;
    --fixtures) MODE=fixtures ;;
    --self-test) SELF_TEST=1 ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        usage
        exit 2
        ;;
esac
if [ "$#" -gt 1 ]; then
    usage
    exit 2
fi

WORKDIR="$ROOT/target/zero-cons"
mkdir -p "$WORKDIR"

run_manifest() {
    _mode=$1
    _manifest=$2
    awk \
        -v mode="$_mode" \
        -v manifest="$_manifest" \
        -f "$ROOT/scripts/zero-cons-scan.awk"
}

write_self_test_tree() {
    _tree=$1
    rm -rf "$_tree"
    mkdir -p "$_tree"

    cat > "$_tree/positive.tl" <<'EOF'
(defenum PrefixChain
  (Done)
  (PrefixItem i64 (Box PrefixChain)))

(defenum Prefixed
  (Empty)
  (PrefixedCons i64 (Box Prefixed)))

(defenum Frames
  (:lifetimes owner)
  (Empty)
  (Frame i64 (Box (Frames owner))))

(defmacro (generated) : Decls
  `(defenum ,chain-name
    (End)
    (Items i64 (Box ,chain-name))))

(defenum Sexpr
  (Nil)
  (Cons (Box Sexpr) (Box Sexpr)))

(define embedded : String
  "(defenum Embedded
  (Stop)
  (Link i64 (Box Embedded)))")
EOF

    cat > "$_tree/negative.tl" <<'EOF'
(defenum AstDeclListStep
  (Nil)
  (Cons AstDecl AstDeclList))

(defenum Expr
  (Leaf i64)
  (Branch (Box Expr) (Box Expr)))

(defenum LocalOutcome
  (Value i64)
  (Nested (Box LocalOutcome)))

(defenum FormatCst
  (Atom String)
  (Prefix String (Box FormatCst)))

(defstruct DenseItems
  (slots (Array i64))
  (len i64))
EOF
}

self_test() {
    _tree="$WORKDIR/self-test"
    write_self_test_tree "$_tree"

    printf '%s\n' "$_tree/positive.tl" > "$_tree/positive.manifest"
    _positive_status=0
    run_manifest full "$_tree/positive.manifest" \
        > "$_tree/positive.out" 2>&1 || _positive_status=$?
    if [ "$_positive_status" -ne 1 ]; then
        echo "zero-cons self-test: positive fixture returned $_positive_status, expected 1" >&2
        cat "$_tree/positive.out" >&2
        return 1
    fi
    for _family in PrefixChain Prefixed Frames chain-name Sexpr Embedded; do
        if ! grep -F "$_family stores boxed self-tail storage" \
            "$_tree/positive.out" >/dev/null; then
            echo "zero-cons self-test: missing positive finding for $_family" >&2
            cat "$_tree/positive.out" >&2
            return 1
        fi
    done
    if ! grep -F '(embedded source line ' "$_tree/positive.out" >/dev/null; then
        echo "zero-cons self-test: embedded source location was not reported" >&2
        cat "$_tree/positive.out" >&2
        return 1
    fi

    printf '%s\n' "$_tree/negative.tl" > "$_tree/negative.manifest"
    run_manifest full "$_tree/negative.manifest" \
        > "$_tree/negative.out" 2>&1
    grep -F '0 findings' "$_tree/negative.out" >/dev/null

    printf '%s\n' "$_tree/missing.tl" > "$_tree/missing.manifest"
    _missing_status=0
    run_manifest full "$_tree/missing.manifest" \
        > "$_tree/missing.out" 2>&1 || _missing_status=$?
    if [ "$_missing_status" -ne 2 ]; then
        echo "zero-cons self-test: unreadable source returned $_missing_status, expected 2" >&2
        cat "$_tree/missing.out" >&2
        return 1
    fi
    grep -F 'zero-cons: cannot read source' "$_tree/missing.out" >/dev/null

    echo "zero-cons structural classifier self-tests passed"
}

if [ "$SELF_TEST" -eq 1 ]; then
    self_test
    exit 0
fi

MANIFEST="$WORKDIR/files.txt"
find src stdlib tools examples tests -type f -name '*.tl' -print |
    LC_ALL=C sort > "$MANIFEST"
if [ ! -s "$MANIFEST" ]; then
    echo "zero-cons: no TypeLisp files found under source roots" >&2
    exit 1
fi

run_manifest "$MODE" "$MANIFEST"
