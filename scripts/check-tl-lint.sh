#!/usr/bin/env sh
set -eu

# check-tl-lint.sh - repository TypeLisp lint gate.
#
# Local usage:
#   scripts/check-tl-lint.sh
#   TYPELISP_BIN=./target/stage0/typelisp scripts/check-tl-lint.sh
#
# The public `typelisp lint` command is warn-only by default so cleanup can
# happen in normal reviewable slices. This gate opts into enforcing mode.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-ci-timing.sh"

HOST_OS=linux
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    *)
        echo "TypeLisp lint check is unsupported on this host" >&2
        exit 1
        ;;
esac

. "$ROOT/scripts/lib-gate.sh"
gate_compiler
gate_compiler_absolute
gate_require_compiler
BOUNDED_POOL_LABEL=tl-lint
. "$ROOT/scripts/lib-bounded-pool.sh"

LINT_WORKERS=${TYPELISP_LINT_WORKERS:-4}
case "$LINT_WORKERS" in
    1 | 2 | 3 | 4 | 5 | 6 | 7 | 8) ;;
    *)
        echo "invalid TYPELISP_LINT_WORKERS: $LINT_WORKERS (expected 1-8)" >&2
        exit 2
        ;;
esac

WORKDIR="$ROOT/target/tl-lint-check"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

FILES="$WORKDIR/files.txt"
CURRENT_SYNTAX_FILES="$WORKDIR/current-syntax-files.txt"
FILTERED_FILES="$WORKDIR/files.filtered"
ACTUAL="$WORKDIR/findings.actual"
STDOUT="$WORKDIR/lint.stdout"
STDERR="$WORKDIR/lint.stderr"
NAME_CASE_PROBE="$WORKDIR/name-case-probe.tl"
NAME_CASE_PROBE_STDOUT="$WORKDIR/name-case-probe.stdout"
NAME_CASE_PROBE_STDERR="$WORKDIR/name-case-probe.stderr"

# A local scripts/ci-affected.sh --run whose change leaves src/, stdlib/ and
# scripts/ alone cannot introduce a compiler-abort violation in src/ and lints
# only the files it touches (scripts/lib-ci-local.sh).
. "$ROOT/scripts/lib-ci-local.sh"
TL_LINT_SCOPED=0
if ci_local_scope_active; then
    TL_LINT_SCOPED=1
fi

if [ "$TL_LINT_SCOPED" -eq 0 ]; then
    # Explicit compiler table failures must identify their operation. Scan tokens
    # rather than lines so comments, strings and a split call cannot fool the guard.
    # Extern declarations remain legal for test fixtures importing the old symbol.
    ABORT_GUARD="$WORKDIR/located-abort.awk"
    cat > "$ABORT_GUARD" <<'EOF'
function token(value) {
    if (value ~ /(^|\.)tl_oob_abort$/ &&
        !(previous == "(" && before_previous == "extern")) {
        print FILENAME ":" FNR ": compiler abort lacks table/caller identity"
        failed = 1
    }
    before_previous = previous
    previous = value
}
function flush() {
    if (word != "") token(word)
    word = ""
}
FNR == 1 {
    previous = before_previous = word = ""
    quoted = escaped = 0
}
{
    for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (quoted) {
            if (escaped) escaped = 0
            else if (c == "\\") escaped = 1
            else if (c == "\"") quoted = 0
        } else if (c == ";") {
            flush()
            break
        } else if (c == "\"") {
            flush()
            token("string")
            quoted = 1
        } else if (c ~ /[[:space:]()\[\]]/) {
            flush()
            if (c !~ /[[:space:]]/) token(c)
        } else word = word c
    }
    flush()
}
END { exit failed }
EOF
    ABORT_SOURCES="$WORKDIR/located-abort-sources.txt"
    git ls-files --cached --others --exclude-standard 'src/*.tl' \
        | grep -v '^src/tests/' | grep -v '_tests\.tl$' \
        | sort -u > "$ABORT_SOURCES"
    [ -s "$ABORT_SOURCES" ] || fail "compiler abort guard selected no sources"
    if ! xargs awk -f "$ABORT_GUARD" < "$ABORT_SOURCES"; then
        fail "Use compiler_abort with a table/caller message for compiler invariant failures."
    fi
    ABORT_PROBE="$WORKDIR/located-abort-probe.tl"
    cat > "$ABORT_PROBE" <<'EOF'
;; A comment mentioning (tl_oob_abort) is not a call.
(extern (tl_oob_abort) : never)
(define (message) : String "(tl_oob_abort)")
EOF
    awk -f "$ABORT_GUARD" "$ABORT_PROBE" \
        || fail "compiler abort guard rejected a comment, string or declaration"
    cat >> "$ABORT_PROBE" <<'EOF'
(define (bad) : never (ci.tl_oob_abort
))
EOF
    if awk -f "$ABORT_GUARD" "$ABORT_PROBE" \
        > "$WORKDIR/located-abort-probe.stdout"; then
        fail "compiler abort guard missed the split-call rejection probe"
    fi
    grep -F ': compiler abort lacks table/caller identity' \
        "$WORKDIR/located-abort-probe.stdout" >/dev/null \
        || fail "compiler abort guard rejection probe returned the wrong diagnostic"
fi

# Lint every git-tracked TypeLisp source that is expected to parse as a source
# unit. The excluded paths are fixture harness inputs rather than direct source
# units:
#   - tests/format_golden/ intentionally preserves formatter fixture text.
#   - tests/safety/ includes intentional check-fail/runtime-trap corpus inputs.
git ls-files '*.tl' \
    | grep -v '^tests/format_golden/' \
    | grep -v '^tests/safety/' \
    | sort > "$FILES"

if [ "$TL_LINT_SCOPED" -eq 1 ]; then
    ci_local_scope_filter "$FILES" "$FILTERED_FILES"
    ci_local_scope_report tl-lint "$FILTERED_FILES" "$FILES"
    mv "$FILTERED_FILES" "$FILES"
    if [ ! -s "$FILES" ]; then
        echo "TypeLisp lint check passed: the local change touches no linted TypeLisp source."
        exit 0
    fi
fi

: > "$CURRENT_SYNTAX_FILES"

# Some integration fixtures intentionally land in the same PR as parser support
# for their source syntax. The seed lint pass runs before the branch compiler is
# built; defer those files only when the selected compiler cannot parse the new
# syntax. The later fresh-selfhost lint pass uses the branch compiler and covers
# them normally.
if grep -F -x 'tests/integration/struct_field_set.tl' "$FILES" >/dev/null 2>&1; then
    printf '%s\n' 'tests/integration/struct_field_set.tl' >> "$CURRENT_SYNTAX_FILES"
fi

compiler_supports_struct_field_set_lint() {
    probe="$WORKDIR/struct-field-set-probe.tl"
    cat > "$probe" <<'EOF'
(defstruct Pair
  (x i64)
  (y i64))

(define (main) : i64
  (let
    [p : Pair (Pair 1 2)]
    (begin
      (set! p.x 3)
      p.x)))
EOF
    "$COMPILER" lint "$probe" > "$WORKDIR/struct-field-set-probe.stdout" 2> "$WORKDIR/struct-field-set-probe.stderr"
}

if [ -s "$CURRENT_SYNTAX_FILES" ] && ! compiler_supports_struct_field_set_lint; then
    grep -F -x -v -f "$CURRENT_SYNTAX_FILES" "$FILES" > "$FILTERED_FILES"
    mv "$FILTERED_FILES" "$FILES"
    deferred_count=$(wc -l < "$CURRENT_SYNTAX_FILES" | tr -d ' ')
    echo "Deferring TypeLisp lint for $deferred_count current-syntax file(s) until the fresh selfhost lint pass."
fi

if [ ! -s "$FILES" ]; then
    echo "no TypeLisp source files selected for lint check" >&2
    exit 1
fi

# The published seed temporarily carries the former global SCREAMING-KEBAB
# interpretation. Detect that exact bootstrap skew so local seed checks can
# proceed; CI's fresh selfhost compiler must recognize a kebab-case global and
# enables the enforced rule below.
cat > "$NAME_CASE_PROBE" <<'EOF'
(define name-case-probe : i64 0)
EOF

if ! "$COMPILER" lint --format flat --name-case "$NAME_CASE_PROBE" \
    > "$NAME_CASE_PROBE_STDOUT" 2> "$NAME_CASE_PROBE_STDERR"; then
    echo "TypeLisp name-case capability probe failed:" >&2
    cat "$NAME_CASE_PROBE_STDERR" >&2
    cat "$NAME_CASE_PROBE_STDOUT" >&2
    exit 1
fi

NAME_CASE_CURRENT=1
if grep -q 'top-level value bindings use SCREAMING-KEBAB-CASE' \
    "$NAME_CASE_PROBE_STDOUT"; then
    NAME_CASE_CURRENT=0
    echo "Deferring name-case enforcement until the fresh selfhost lint pass."
elif ! grep -q '^lint: 0 finding(s)$' "$NAME_CASE_PROBE_STDOUT"; then
    echo "TypeLisp name-case capability probe returned an unexpected result:" >&2
    cat "$NAME_CASE_PROBE_STDERR" >&2
    cat "$NAME_CASE_PROBE_STDOUT" >&2
    exit 1
fi

count=$(wc -l < "$FILES" | tr -d ' ')
LINT_BATCH_SIZE=${TYPELISP_LINT_BATCH_SIZE-32}
case "$LINT_BATCH_SIZE" in
    '' | *[!0-9]*)
        echo "TYPELISP_LINT_BATCH_SIZE must be a positive integer" >&2
        exit 2 ;;
esac
if ! [ "$LINT_BATCH_SIZE" -gt 0 ] 2>/dev/null; then
    echo "TYPELISP_LINT_BATCH_SIZE must be a positive integer" >&2
    exit 2
fi
src_concat_count=$(awk '/^src\// { count++ } END { print count + 0 }' "$FILES")
if [ "$src_concat_count" -eq 0 ] && [ "$TL_LINT_SCOPED" -eq 0 ]; then
    echo "src deprecated-concat lint selected no tracked TypeLisp files" >&2
    exit 1
fi
echo "Linting TypeLisp sources for $count file(s) in batches of $LINT_BATCH_SIZE."

# Keep lint processes bounded. The lint command checks each explicit source
# independently, so chunking preserves coverage while releasing compiler heap
# state between batches on memory-constrained CI hosts. Materialize the same
# ordered chunks so opt-in timing can attribute individual outliers. Split at
# src/ boundaries as well as the size bound: compiler sources receive the union
# of normal, deprecated-concat and redundant-begin rules in one parse/traversal,
# while the other source units retain their existing opt-in rule scope.
# Compiler importers outside src/ need the same import root as their builds.
LINT_CHUNK_DIR="$WORKDIR/chunks"
rm -rf "$LINT_CHUNK_DIR"
mkdir -p "$LINT_CHUNK_DIR"
awk -v outdir="$LINT_CHUNK_DIR" -v size="$LINT_BATCH_SIZE" -v test_files="$GATE_STDLIB_TEST_CFG_FILES" '
    BEGIN {
        n = split(test_files, paths, " ")
        for (i = 1; i <= n; i++) test_cfg_files[paths[i]] = 1
    }
    {
        source_rules = ($0 ~ /^src\//)
        compiler_consumer = ($0 == "tools/embedded-stdlib-tli/roundtrip.tl" || $0 == "tools/build-stdlib-sysroot/main.tl" || $0 == "tests/integration/compiler_arena_debug.tl")
        test_cfg = ($0 in test_cfg_files)
        if (count == 0 || count == size || source_rules != previous_rules ||
            compiler_consumer != previous_consumer || test_cfg != previous_test_cfg) {
            if (count != 0) close(path)
            chunk++
            count = 0
            path = sprintf("%s/lint.%04d.txt", outdir, chunk)
        }
        print $0 >> path
        count++
        previous_rules = source_rules
        previous_consumer = compiler_consumer
        previous_test_cfg = test_cfg
    }
' "$FILES"

: > "$STDOUT"
: > "$STDERR"

LINT_POOL_DIR="$WORKDIR/pool"
LINT_POOL_QUEUE="$WORKDIR/pool.queue"
LINT_POOL_SRC_QUEUE="$WORKDIR/pool-src.queue"
LINT_POOL_OTHER_QUEUE="$WORKDIR/pool-other.queue"
: > "$LINT_POOL_SRC_QUEUE"
: > "$LINT_POOL_OTHER_QUEUE"

# Schedule src/ chunks first (LPT) so heavier compiler-source chunks start
# immediately while lighter stdlib/test/tool chunks pack around them. Each src/
# chunk reserves half of a 2048 MiB nominal budget (1024) while non-src chunks
# reserve 256 so at most 2 src/ chunks run concurrently when budget is 2048.
LINT_POOL_BUDGET_MIB=${TYPELISP_LINT_BUDGET_MIB:-2048}
case "$LINT_POOL_BUDGET_MIB" in
    '' | *[!0-9]* | 0*)
        echo "TYPELISP_LINT_BUDGET_MIB must be a positive integer" >&2
        exit 2
        ;;
esac
LINT_SRC_CAP_MIB=1024
if [ "$LINT_SRC_CAP_MIB" -gt "$LINT_POOL_BUDGET_MIB" ]; then
    LINT_SRC_CAP_MIB=$LINT_POOL_BUDGET_MIB
fi
LINT_OTHER_CAP_MIB=256
if [ "$LINT_OTHER_CAP_MIB" -gt "$LINT_POOL_BUDGET_MIB" ]; then
    LINT_OTHER_CAP_MIB=$LINT_POOL_BUDGET_MIB
fi

lint_chunk_index=0
src_concat_chunk_index=0
for lint_chunk in "$LINT_CHUNK_DIR"/lint.*.txt; do
    [ -f "$lint_chunk" ] || continue
    lint_chunk_index=$((lint_chunk_index + 1))
    chunk_id=$(basename "$lint_chunk" .txt)
    chunk_is_src=0
    while IFS= read -r lint_source; do
        [ -n "$lint_source" ] || continue
        case "$lint_source" in
            src/*) chunk_is_src=1; break ;;
        esac
    done < "$lint_chunk"
    if [ "$chunk_is_src" -eq 1 ]; then
        src_concat_chunk_index=$((src_concat_chunk_index + 1))
        printf '%s|%s\n' "$chunk_id" "$LINT_SRC_CAP_MIB" >> "$LINT_POOL_SRC_QUEUE"
    else
        printf '%s|%s\n' "$chunk_id" "$LINT_OTHER_CAP_MIB" >> "$LINT_POOL_OTHER_QUEUE"
    fi
done
cat "$LINT_POOL_SRC_QUEUE" "$LINT_POOL_OTHER_QUEUE" > "$LINT_POOL_QUEUE"

bounded_pool_run_job() {
    _chunk_id=$1
    _lint_chunk="$LINT_CHUNK_DIR/$_chunk_id.txt"
    _chunk_out="$LINT_CHUNK_DIR/$_chunk_id.stdout"
    _chunk_err="$LINT_CHUNK_DIR/$_chunk_id.stderr"
    _chunk_status_file="$LINT_CHUNK_DIR/$_chunk_id.status"
    set --
    _src_rules=0
    _compiler_consumer=0
    _test_cfg=0
    while IFS= read -r _lint_source; do
        [ -n "$_lint_source" ] || continue
        set -- "$@" "$_lint_source"
        case "$_lint_source" in
            src/*) _src_rules=1 ;;
            tools/embedded-stdlib-tli/roundtrip.tl | tools/build-stdlib-sysroot/main.tl | tests/integration/compiler_arena_debug.tl) _compiler_consumer=1 ;;
        esac
        if gate_stdlib_needs_test_cfg "$_lint_source"; then
            _test_cfg=1
        fi
    done < "$_lint_chunk"
    if [ "$_src_rules" -eq 1 ]; then
        set -- --deprecated-string-concat --redundant-begin --stdlib-root "$ROOT/stdlib" --stdlib-root "$ROOT/src" "$@"
    elif [ "$_compiler_consumer" -eq 1 ]; then
        set -- --stdlib-root "$ROOT/src" "$@"
    fi
    if [ "$NAME_CASE_CURRENT" -eq 1 ]; then
        set -- --name-case "$@"
    fi
    if [ "$_test_cfg" -eq 1 ]; then
        set -- --cfg test "$@"
    fi
    _chunk_status=0
    ci_timing_run "$_chunk_id" lint \
        "$COMPILER" lint --format flat --check --redundant-function-name "$@" \
            > "$_chunk_out" 2> "$_chunk_err" || _chunk_status=$?
    printf '%s\n' "$_chunk_status" > "$_chunk_status_file"
    # Always return 0 so every chunk runs and all findings across the corpus are collected.
    return 0
}

bounded_pool_init "$LINT_POOL_DIR" "$LINT_POOL_BUDGET_MIB" "$LINT_POOL_QUEUE" || exit 1
bounded_pool_start "$LINT_POOL_DIR" "$LINT_WORKERS"
bounded_pool_join "$LINT_POOL_DIR" || exit 1

lint_status=0
for lint_chunk in "$LINT_CHUNK_DIR"/lint.*.txt; do
    [ -f "$lint_chunk" ] || continue
    chunk_id=$(basename "$lint_chunk" .txt)
    [ ! -s "$LINT_CHUNK_DIR/$chunk_id.stdout" ] || cat "$LINT_CHUNK_DIR/$chunk_id.stdout" >> "$STDOUT"
    [ ! -s "$LINT_CHUNK_DIR/$chunk_id.stderr" ] || cat "$LINT_CHUNK_DIR/$chunk_id.stderr" >> "$STDERR"
    read -r chunk_status < "$LINT_CHUNK_DIR/$chunk_id.status"
    if [ "$chunk_status" -ne 0 ]; then
        [ "$lint_status" -ne 0 ] || lint_status=$chunk_status
    fi
done

if [ "$lint_status" -ne 0 ]; then
    if [ ! -s "$STDERR" ] && grep -q '^lint: [1-9][0-9]* finding(s)$' "$STDOUT"; then
        awk '
            /^--- / { next }
            /^lint: [0-9][0-9]* finding\(s\)$/ { next }
            NF { print }
        ' "$STDOUT" | LC_ALL=C sort > "$ACTUAL"

        if [ -s "$ACTUAL" ]; then
            echo "TypeLisp lint found finding(s):" >&2
            cat "$ACTUAL" >&2
            exit 1
        fi
    fi

    echo "TypeLisp lint failed for the batched source set:" >&2
    if [ -s "$STDERR" ]; then
        echo "stderr:" >&2
        sed 's/^/  /' "$STDERR" >&2 || true
    fi
    if [ -s "$STDOUT" ]; then
        echo "stdout:" >&2
        sed 's/^/  /' "$STDOUT" >&2 || true
    fi
    exit 1
fi

echo "TypeLisp lint check passed for $count file(s); 0 finding(s)."

if [ "$TL_LINT_SCOPED" -eq 1 ] && [ "$src_concat_count" -eq 0 ]; then
    exit 0
fi

# The source pass above includes the concat rule. Keep its independent negative
# control so a dropped opt-in flag cannot make a clean corpus falsely pass.
SRC_CONCAT_PROBE="$WORKDIR/src-concat-probe.tl"
SRC_CONCAT_PROBE_STDOUT="$WORKDIR/src-concat-probe.stdout"
SRC_CONCAT_PROBE_STDERR="$WORKDIR/src-concat-probe.stderr"

# Exercise the complete opt-in command so an accidentally dropped flag cannot
# turn the zero-finding source corpus into a false-green gate.
cat > "$SRC_CONCAT_PROBE" <<'EOF'
(define (main) : String
  (string.append "left" "right"))
EOF
set +e
"$COMPILER" lint \
    --format flat \
    --check \
    --deprecated-string-concat \
    --stdlib-root "$ROOT/stdlib" \
    "$SRC_CONCAT_PROBE" > "$SRC_CONCAT_PROBE_STDOUT" 2> "$SRC_CONCAT_PROBE_STDERR"
src_concat_probe_status=$?
set -e
if [ "$src_concat_probe_status" -eq 0 ]; then
    echo "src deprecated-concat lint regression: primitive probe unexpectedly passed" >&2
    exit 1
fi
if ! grep -F 'deprecated string concatenation primitive' \
    "$SRC_CONCAT_PROBE_STDOUT" >/dev/null 2>&1; then
    echo "src deprecated-concat lint regression returned the wrong diagnostic" >&2
    if [ -s "$SRC_CONCAT_PROBE_STDOUT" ]; then
        echo "stdout:" >&2
        sed 's/^/  /' "$SRC_CONCAT_PROBE_STDOUT" >&2
    fi
    if [ -s "$SRC_CONCAT_PROBE_STDERR" ]; then
        echo "stderr:" >&2
        sed 's/^/  /' "$SRC_CONCAT_PROBE_STDERR" >&2
    fi
    exit 1
fi

echo "TypeLisp src deprecated-concat lint passed for $src_concat_count file(s) in $src_concat_chunk_index batch(es); 0 finding(s); rejection probe passed."
