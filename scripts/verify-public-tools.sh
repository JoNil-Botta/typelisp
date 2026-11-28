#!/usr/bin/env sh
set -eu

# verify-public-tools.sh - parts of the public CLI surface of TYPELISP_BIN.
# scripts/ci-gates.d/*.tsv runs each part as its own gate, so the pool schedules
# them side by side instead of one 35+ minute gate:
#
#   affected-map       the tests/cli/ci-affected map audit (Linux)
#   cli-transcripts-1  the tests/cli/public-*.cases transcripts, groups 1 to 3;
#   cli-transcripts-2  together they cover every public-*.cases file exactly
#   cli-transcripts-3  once (cli_transcripts_inventory)
#   corpora            package artifact freshness, the LSP and REPL corpora of
#                      tests/public-tools, and the SPEC.md metadata examples
#
# A crash is a compiler bug: every invocation runs once (no retries).

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

usage() {
    cat >&2 <<'EOF'
usage: scripts/verify-public-tools.sh PART
PART is one of the gate parts of scripts/ci-gates.d/*.tsv: affected-map,
cli-transcripts-1, cli-transcripts-2, cli-transcripts-3 or corpora.
EOF
    exit 2
}

[ "$#" -eq 1 ] || usage
PART=$1

GATE_FAIL_PREFIX='FAIL: '
. "$ROOT/scripts/lib-gate.sh"

# Every part but affected-map runs the compiler under test as TYPELISP_BIN;
# affected-map reads scripts/ and the inventory tables only, so its gate names
# no compiler and starts beside the bootstrap.
require_compiler() {
    gate_compiler
    gate_compiler_absolute
    gate_require_compiler
    export TYPELISP_BIN="$COMPILER"
}

# Audit every Linux PR, including changes outside the selector's own inputs.
verify_affected_map() {
    case "$(uname -s)" in
        Linux*)
            echo "[public-tools] ci-affected map freshness"
            scripts/ci-affected.sh --self-test
            ;;
    esac
}

# The transcript groups, cut by measured cost. The runner keeps one work
# directory per case file under target/codegen-cases/, so no two groups share
# one and the parts need no lock.
cli_transcripts_files() {
    case "$1" in
        1)
            printf '%s\n' \
                tests/cli/public-test.cases \
                tests/cli/public-test-selected-import.cases \
                tests/cli/public-arena-early-exits.cases \
                tests/cli/public-arena-end-operator.cases \
                tests/cli/public-git.cases \
                tests/cli/public-inline-dispatch.cases \
                tests/cli/public-package-dispatch.cases \
                tests/cli/public-matrix.cases \
                tests/cli/public-dispatch-library.cases
            ;;
        2)
            printf '%s\n' \
                tests/cli/public-package.cases \
                tests/cli/public-package-tli.cases \
                tests/cli/public-package-opaque-provider.cases \
                tests/cli/public-cond-diagnostics.cases
            ;;
        3)
            printf '%s\n' \
                tests/cli/public-check.cases \
                tests/cli/public-root-read.cases \
                tests/cli/public-fmt-doc.cases \
                tests/cli/public-lint.cases \
                tests/cli/public-help.cases \
                tests/cli/public-prebuilt-stdlib.cases \
                tests/cli/public-lsp.cases \
                tests/cli/public-expand.cases \
                tests/cli/public-test-name.cases
            ;;
        *) usage ;;
    esac
}

# The groups replaced one tests/cli/public-*.cases glob, so a transcript file
# that joins no group must fail here instead of leaving CI silently.
cli_transcripts_inventory() {
    for _cli_file in tests/cli/public-*.cases; do
        _cli_parts=$({ cli_transcripts_files 1; cli_transcripts_files 2; cli_transcripts_files 3; } |
            grep -cxF "$_cli_file" || true)
        [ "$_cli_parts" = 1 ] ||
            fail "$_cli_file belongs to $_cli_parts transcript groups; a public-*.cases file belongs to exactly one cli-transcripts part"
    done
}

verify_cli_transcripts() {
    cli_transcripts_inventory
    require_compiler
    set -f
    # shellcheck disable=SC2046
    scripts/verify-codegen-cases.sh $(cli_transcripts_files "$1")
    set +f
}

if [ "$PART" != corpora ]; then
    case "$PART" in
        affected-map) verify_affected_map ;;
        cli-transcripts-1 | cli-transcripts-2 | cli-transcripts-3)
            verify_cli_transcripts "${PART#cli-transcripts-}" ;;
        *) usage ;;
    esac
    echo "public tool verification passed"
    exit 0
fi

# The corpora part is the series below: everything the single gate ran after
# its transcripts, unchanged and in the same order.
BOUNDED_POOL_LABEL=spec-corpus
. "$ROOT/scripts/lib-bounded-pool.sh"

SPEC_CORPUS_WORKERS=${TYPELISP_SPEC_CORPUS_WORKERS:-4}
case "$SPEC_CORPUS_WORKERS" in
    1 | 2 | 3 | 4 | 5 | 6 | 7 | 8) ;;
    *)
        echo "invalid TYPELISP_SPEC_CORPUS_WORKERS: $SPEC_CORPUS_WORKERS (expected 1-8)" >&2
        exit 2
        ;;
esac

SPEC_IS_WINDOWS=0
case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*) SPEC_IS_WINDOWS=1 ;;
esac

require_compiler

echo "[public-tools] package artifact freshness"
sh scripts/verify-package-artifact-freshness.sh
echo "[public-tools] LSP transcript batch manifest contract"
sh scripts/verify-lsp-transcript-batch.sh
echo "[public-tools] corpus result-check self-test"
sh tests/public-tools/test-result-checks.sh
echo "[public-tools] LSP corpus"
sh tests/public-tools/run-corpus.sh lsp
echo "[public-tools] REPL corpus"
sh tests/public-tools/run-corpus.sh repl

echo "[public-tools] SPEC metadata examples"
SPEC_WORK="$ROOT/target/public-tool-verify/spec"
rm -rf "$SPEC_WORK"
mkdir -p "$SPEC_WORK"
SPEC_MANIFEST="$SPEC_WORK/manifest.txt"
awk -v out="$SPEC_WORK" '
function die(msg) {
    print msg > "/dev/stderr"
    exit 1
}
function is_key_char(ch) {
    return ch ~ /^[A-Za-z0-9_-]$/
}
function clear_meta(    key) {
    for (key in meta) {
        delete meta[key]
    }
}
function parse_meta(text, line,    i, n, ch, key, value, closed, esc) {
    clear_meta()
    i = 1
    n = length(text)
    while (i <= n) {
        ch = substr(text, i, 1)
        while (i <= n && ch ~ /^[ \t]$/) {
            i++
            ch = substr(text, i, 1)
        }
        if (i > n) {
            break
        }

        key = ""
        while (i <= n && is_key_char(substr(text, i, 1))) {
            key = key substr(text, i, 1)
            i++
        }
        if (key == "") {
            die("SPEC.md:" line " has malformed metadata near `" substr(text, i) "`")
        }
        if (substr(text, i, 1) != "=") {
            die("SPEC.md:" line " metadata key `" key "` must be followed by `=`")
        }
        i++

        if (substr(text, i, 1) == "\"") {
            i++
            value = ""
            closed = 0
            while (i <= n) {
                ch = substr(text, i, 1)
                if (ch == "\"") {
                    i++
                    closed = 1
                    break
                }
                if (ch == "\\") {
                    i++
                    if (i > n) {
                        die("SPEC.md:" line " has a trailing escape in metadata")
                    }
                    esc = substr(text, i, 1)
                    if (esc == "n") {
                        value = value "\n"
                    } else if (esc == "r") {
                        value = value "\r"
                    } else if (esc == "t") {
                        value = value "\t"
                    } else if (esc == "\"") {
                        value = value "\""
                    } else if (esc == "\\") {
                        value = value "\\"
                    } else {
                        die("SPEC.md:" line " has unsupported metadata escape `\\" esc "`")
                    }
                    i++
                    continue
                }
                value = value ch
                i++
            }
            if (!closed) {
                die("SPEC.md:" line " has an unterminated quoted metadata value")
            }
        } else {
            value = ""
            while (i <= n && substr(text, i, 1) !~ /^[ \t]$/) {
                value = value substr(text, i, 1)
                i++
            }
            if (value == "") {
                die("SPEC.md:" line " metadata key `" key "` has no value")
            }
        }

        if (key in meta) {
            die("SPEC.md:" line " has duplicate metadata key `" key "`")
        }
        meta[key] = value
    }
}
function required(line, example, key,    value) {
    if (!(key in meta)) {
        if (example == "") {
            die("SPEC.md:" line " lisp fence is missing metadata `" key "`")
        }
        die("SPEC.md:" line " example `" example "` is missing required metadata `" key "`")
    }
    value = meta[key]
    delete meta[key]
    return value
}
function reject_remaining(line, name,    key) {
    for (key in meta) {
        die("SPEC.md:" line " example `" name "` has unsupported metadata key `" key "`")
    }
}
function validate_name(line, name) {
    if (name == "" || name !~ /^[A-Za-z0-9_-]+$/) {
        die("SPEC.md:" line " example `" name "` must use only ASCII letters, digits, `-`, or `_`")
    }
}
function finish_example(    mode, name, reason, exit_code, stdout_file, source_file) {
    mode = required(opening_line, "", "test")
    name = required(opening_line, mode, "name")
    validate_name(opening_line, name)
    if (name in seen) {
        die("SPEC.md:" opening_line " example `" name "` duplicates a previous name")
    }
    seen[name] = 1

    if (mode == "ignore") {
        reason = required(opening_line, name, "reason")
        if (reason ~ /^[ \t]*$/) {
            die("SPEC.md:" opening_line " example `" name "` has an empty ignore reason")
        }
        reject_remaining(opening_line, name)
        print name "|ignore|"
        return
    }

    source_file = out "/" name ".tl"
    printf "%s", source > source_file
    close(source_file)

    if (mode == "check" || mode == "compile") {
        reject_remaining(opening_line, name)
        print name "|" mode "|"
        return
    }

    if (mode == "run") {
        exit_code = required(opening_line, name, "exit")
        if (exit_code !~ /^-?[0-9]+$/) {
            die("SPEC.md:" opening_line " example `" name "` has invalid exit code `" exit_code "`")
        }
        stdout_file = out "/" name ".stdout"
        printf "%s", required(opening_line, name, "stdout") > stdout_file
        close(stdout_file)
        reject_remaining(opening_line, name)
        print name "|run|" exit_code
        return
    }

    die("SPEC.md:" opening_line " example `" name "` has unknown test mode `" mode "`")
}
BEGIN {
    in_fence = 0
    in_other_fence = 0
    count = 0
}
{
    trimmed = $0
    sub(/^[ \t]*/, "", trimmed)

    if (in_fence) {
        if (trimmed ~ /^```/) {
            finish_example()
            in_fence = 0
            source = ""
            next
        }
        source = source $0 "\n"
        next
    }

    if (in_other_fence) {
        if (trimmed ~ /^```/) {
            in_other_fence = 0
        }
        next
    }

    if (trimmed ~ /^```lisp([ \t].*)?$/) {
        info = trimmed
        sub(/^```lisp[ \t]*/, "", info)
        if (info == "") {
            die("SPEC.md:" NR " lisp fence is missing test= metadata")
        }
        parse_meta(info, NR)
        opening_line = NR
        source = ""
        in_fence = 1
        count++
        next
    }

    if (trimmed ~ /^```/) {
        in_other_fence = 1
    }
}
END {
    if (in_fence) {
        die("SPEC.md:" opening_line " has an unclosed Markdown fence")
    }
    if (count == 0) {
        die("SPEC.md should contain metadata-bearing lisp examples")
    }
}
' SPEC.md > "$SPEC_MANIFEST"

SPEC_POOL_DIR="$SPEC_WORK/pool"
SPEC_POOL_JOBS="$SPEC_WORK/pool-jobs"
SPEC_POOL_QUEUE="$SPEC_WORK/pool.queue"
mkdir -p "$SPEC_POOL_JOBS"
: > "$SPEC_POOL_QUEUE"

spec_active_count=0
spec_ignored_count=0
while IFS='|' read -r spec_name spec_mode spec_value; do
    [ -n "$spec_name" ] || continue
    case "$spec_mode" in
        ignore)
            spec_ignored_count=$((spec_ignored_count + 1))
            continue
            ;;
        check | compile | run) ;;
        *) fail "unknown SPEC manifest mode for $spec_name: $spec_mode" ;;
    esac
    spec_active_count=$((spec_active_count + 1))
    job_id=$(printf 'spec-%03d' "$spec_active_count")
    printf '%s|%s|%s\n' "$spec_name" "$spec_mode" "$spec_value" > "$SPEC_POOL_JOBS/$job_id.row"
    printf '%s|1\n' "$job_id" >> "$SPEC_POOL_QUEUE"
done < "$SPEC_MANIFEST"

run_spec_example_job() {
    _job=$1
    _job_err="$SPEC_POOL_JOBS/$_job.err"
    : > "$_job_err"
    IFS='|' read -r spec_name spec_mode spec_value < "$SPEC_POOL_JOBS/$_job.row"
    out="$SPEC_WORK/$spec_name.out"
    err="$SPEC_WORK/$spec_name.err"
    case "$spec_mode" in
        check) set -- check "$SPEC_WORK/$spec_name.tl"; spec_value=0 ;;
        compile) set -- compile "$SPEC_WORK/$spec_name.tl" -o "$SPEC_WORK/$spec_name.s"; spec_value=0 ;;
        run) set -- run "$SPEC_WORK/$spec_name.tl" ;;
        *)
            echo "FAIL: unknown SPEC manifest mode for $spec_name: $spec_mode" > "$_job_err"
            return 1
            ;;
    esac
    set +e
    "$COMPILER" "$@" > "$out" 2> "$err"
    code=$?
    set -e
    if [ "$code" -ne "$spec_value" ]; then
        {
            sed 's/^/  /' "$out" "$err" || true
            echo "FAIL: spec-$spec_name expected exit $spec_value, got $code"
        } > "$_job_err"
        return 1
    fi
    [ "$spec_mode" = run ] || return 0
    cp "$SPEC_WORK/$spec_name.stdout" "$out.expected"
    if [ "$SPEC_IS_WINDOWS" -eq 1 ]; then
        tr -d '\r' < "$out" > "$out.lf" && mv "$out.lf" "$out"
        tr -d '\r' < "$SPEC_WORK/$spec_name.stdout" > "$out.expected"
    fi
    if ! cmp -s "$out" "$out.expected"; then
        echo "FAIL: spec-$spec_name produced unexpected stdout" > "$_job_err"
        return 1
    fi
    if [ -s "$err" ]; then
        echo "FAIL: spec-$spec_name wrote unexpected stderr: $(cat "$err")" > "$_job_err"
        return 1
    fi
    return 0
}

bounded_pool_run_job() {
    _bp_job=$1
    _job_rc=0
    run_spec_example_job "$_bp_job" || _job_rc=$?
    printf '%s\n' "$_job_rc" > "$SPEC_POOL_JOBS/$_bp_job.status"
    return "$_job_rc"
}

if [ "$spec_active_count" -gt 0 ]; then
    echo "[public-tools] running $spec_active_count SPEC example(s) ($spec_ignored_count ignored) with $SPEC_CORPUS_WORKERS worker(s)"
    bounded_pool_init "$SPEC_POOL_DIR" "$SPEC_CORPUS_WORKERS" "$SPEC_POOL_QUEUE" || exit 1
    bounded_pool_start "$SPEC_POOL_DIR" "$SPEC_CORPUS_WORKERS"
    spec_pool_status=0
    bounded_pool_join "$SPEC_POOL_DIR" || spec_pool_status=$?

    spec_passed=0
    replay_idx=0
    while [ "$replay_idx" -lt "$spec_active_count" ]; do
        replay_idx=$((replay_idx + 1))
        job_id=$(printf 'spec-%03d' "$replay_idx")
        [ ! -s "$SPEC_POOL_JOBS/$job_id.err" ] || cat "$SPEC_POOL_JOBS/$job_id.err" >&2
        if [ -f "$SPEC_POOL_JOBS/$job_id.status" ]; then
            read -r _rc < "$SPEC_POOL_JOBS/$job_id.status"
            [ "$_rc" -eq 0 ] || exit 1
            spec_passed=$((spec_passed + 1))
        fi
    done

    if [ "$spec_pool_status" -ne 0 ] || [ "$spec_passed" -ne "$spec_active_count" ]; then
        fail "SPEC metadata worker pool did not complete all examples ($spec_passed/$spec_active_count)"
    fi
fi

echo "public tool verification passed"
