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
#
# refs #1164.

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

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    # Local-development fallback: fetch the published
    # self-hosted stage0 (CI always passes a compiler via TYPELISP_BIN).
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

WORKDIR="$ROOT/target/tl-lint-check"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

LEGACY_PATH_IMPORT_ALLOWLIST="$ROOT/scripts/legacy-path-import-allowlist.tsv"
LEGACY_PATH_IMPORT_EXEMPTIONS="$ROOT/scripts/legacy-path-import-exemptions.tsv"
LEGACY_PATH_IMPORT_RAW="$WORKDIR/legacy-path-imports.raw"
LEGACY_PATH_IMPORT_ACTUAL_UNSORTED="$WORKDIR/legacy-path-imports.actual.unsorted.tsv"
LEGACY_PATH_IMPORT_ACTUAL="$WORKDIR/legacy-path-imports.actual.tsv"
LEGACY_PATH_IMPORT_EXPECTED_UNSORTED="$WORKDIR/legacy-path-imports.expected.unsorted.tsv"
LEGACY_PATH_IMPORT_EXPECTED="$WORKDIR/legacy-path-imports.expected.tsv"

if [ ! -f "$LEGACY_PATH_IMPORT_ALLOWLIST" ]; then
    echo "missing legacy path import allowlist: $LEGACY_PATH_IMPORT_ALLOWLIST" >&2
    exit 1
fi
if [ ! -f "$LEGACY_PATH_IMPORT_EXEMPTIONS" ]; then
    echo "missing legacy path import exemptions: $LEGACY_PATH_IMPORT_EXEMPTIONS" >&2
    exit 1
fi

set +e
git grep -n -E '^[[:space:]]*\(import[[:space:]]+"' -- '*.tl' \
    > "$LEGACY_PATH_IMPORT_RAW"
legacy_scan_status=$?
set -e
if [ "$legacy_scan_status" -ne 0 ] && [ "$legacy_scan_status" -ne 1 ]; then
    echo "legacy path import audit could not scan tracked TypeLisp files" >&2
    exit "$legacy_scan_status"
fi

if ! awk -F '\t' '
    NR == FNR {
        if ($0 !~ /^#/ && NF > 0) {
            if (NF < 2 || $1 == "" || $2 == "") {
                print "invalid legacy path import exemption row: " $0 > "/dev/stderr"
                invalid = 1
            } else {
                exempt[$1] = 1
            }
        }
        next
    }
    {
        split($0, fields, ":")
        path = fields[1]
        seen[path] += 1
        if (!(path in exempt)) {
            count[path] += 1
        }
    }
    END {
        if (invalid) {
            exit 1
        }
        stale = 0
        for (path in exempt) {
            if (!(path in seen)) {
                print "stale legacy path import exemption: " path > "/dev/stderr"
                stale = 1
            }
        }
        if (stale) {
            exit 1
        }
        for (path in count) {
            print path "\t" count[path]
        }
    }
' "$LEGACY_PATH_IMPORT_EXEMPTIONS" "$LEGACY_PATH_IMPORT_RAW" \
    > "$LEGACY_PATH_IMPORT_ACTUAL_UNSORTED"; then
    exit 1
fi
LC_ALL=C sort "$LEGACY_PATH_IMPORT_ACTUAL_UNSORTED" \
    > "$LEGACY_PATH_IMPORT_ACTUAL"

awk -F '\t' '
    $0 !~ /^#/ && NF > 0 {
        if (NF != 2 || $1 == "" || $2 !~ /^[1-9][0-9]*$/) {
            print "invalid legacy path import allowlist row: " $0 > "/dev/stderr"
            invalid = 1
        } else {
            print $1 "\t" $2
        }
    }
    END {
        if (invalid) {
            exit 1
        }
    }
' "$LEGACY_PATH_IMPORT_ALLOWLIST" \
    > "$LEGACY_PATH_IMPORT_EXPECTED_UNSORTED"
LC_ALL=C sort "$LEGACY_PATH_IMPORT_EXPECTED_UNSORTED" \
    > "$LEGACY_PATH_IMPORT_EXPECTED"

if ! diff -u "$LEGACY_PATH_IMPORT_EXPECTED" "$LEGACY_PATH_IMPORT_ACTUAL"; then
    echo "legacy path import counts changed: reject increases/new files and lower the allowlist after reductions" >&2
    exit 1
fi

legacy_path_import_count=$(awk -F '\t' '{ total += $2 } END { print total + 0 }' \
    "$LEGACY_PATH_IMPORT_ACTUAL")
legacy_path_import_file_count=$(wc -l < "$LEGACY_PATH_IMPORT_ACTUAL" | tr -d ' ')
legacy_path_import_exemption_count=$(grep -v '^#' "$LEGACY_PATH_IMPORT_EXEMPTIONS" \
    | grep -c -v '^$' || true)
echo "Legacy path import ratchet passed: $legacy_path_import_count site(s) in $legacy_path_import_file_count file(s); $legacy_path_import_exemption_count named fixture exemption(s)."

FILES="$WORKDIR/files.txt"
CURRENT_SYNTAX_FILES="$WORKDIR/current-syntax-files.txt"
FILTERED_FILES="$WORKDIR/files.filtered"
ACTUAL="$WORKDIR/findings.actual"
STDOUT="$WORKDIR/lint.stdout"
STDERR="$WORKDIR/lint.stderr"
NAME_CASE_PROBE="$WORKDIR/name-case-probe.tl"
NAME_CASE_PROBE_STDOUT="$WORKDIR/name-case-probe.stdout"
NAME_CASE_PROBE_STDERR="$WORKDIR/name-case-probe.stderr"

# Lint every git-tracked TypeLisp source that is expected to parse as a source
# unit. The excluded paths are fixture harness inputs rather than direct source
# units:
#   - tests/format_golden/ intentionally preserves formatter fixture text.
#   - tests/safety/ includes intentional check-fail/runtime-trap corpus inputs.
git ls-files '*.tl' \
    | grep -v '^tests/format_golden/' \
    | grep -v '^tests/safety/' \
    | sort > "$FILES"

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
      (set! (struct-get p x) 3)
      (struct-get p x))))
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

if ! "$COMPILER" lint --name-case "$NAME_CASE_PROBE" \
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
LINT_BATCH_SIZE=${TYPELISP_LINT_BATCH_SIZE:-32}
echo "Linting TypeLisp sources for $count file(s) in batches of $LINT_BATCH_SIZE."

# Keep lint processes bounded. The lint command checks each explicit source
# independently, so chunking preserves coverage while releasing compiler heap
# state between batches on memory-constrained CI hosts. Materialize the same
# ordered xargs-style chunks so opt-in timing can attribute individual outliers.
LINT_CHUNK_DIR="$WORKDIR/chunks"
rm -rf "$LINT_CHUNK_DIR"
mkdir -p "$LINT_CHUNK_DIR"
awk -v outdir="$LINT_CHUNK_DIR" -v size="$LINT_BATCH_SIZE" '
    {
        chunk = int((NR - 1) / size) + 1
        path = sprintf("%s/lint.%04d.txt", outdir, chunk)
        print $0 >> path
        if (NR % size == 0) close(path)
    }
' "$FILES"

: > "$STDOUT"
: > "$STDERR"
lint_status=0
lint_chunk_index=0
for lint_chunk in "$LINT_CHUNK_DIR"/lint.*.txt; do
    [ -f "$lint_chunk" ] || continue
    lint_chunk_index=$((lint_chunk_index + 1))
    set --
    while IFS= read -r lint_source; do
        [ -n "$lint_source" ] || continue
        set -- "$@" "$lint_source"
    done < "$lint_chunk"
    if [ "$NAME_CASE_CURRENT" -eq 1 ]; then
        set -- --name-case "$@"
    fi
    if ci_timing_run "chunk-$lint_chunk_index" lint \
        "$COMPILER" lint --check "$@" >> "$STDOUT" 2>> "$STDERR"; then
        :
    else
        chunk_status=$?
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
