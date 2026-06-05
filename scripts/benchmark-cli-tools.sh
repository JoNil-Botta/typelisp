#!/usr/bin/env sh
set -eu

# benchmark-cli-tools.sh - benchmark non-compile CLI tools on the compiler corpus.
#
# This mirrors scripts/benchmark-compile-cli.sh's staged setup enough to resolve
# a seed and build one fresh selfhost CLI, then runs the measured tool commands
# through that binary. The default corpus is the compiler/tool implementation
# under selfhost/, excluding smoke/fixture/test snippet files.
#
# The script writes deterministic outputs under target/cli-tool-benchmark/run
# and compares their fingerprints against the previous successful full run under
# target/cli-tool-benchmark/baseline. Timings are reported but intentionally not
# included in the regression fingerprint.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

TYPELISP_WINDOWS_LINK_REPRO=${TYPELISP_WINDOWS_LINK_REPRO:-1}
export TYPELISP_WINDOWS_LINK_REPRO

. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host

usage() {
    cat <<'EOF'
usage: scripts/benchmark-cli-tools.sh [typelisp-seed]

Environment:
  TYPELISP_BIN                         Seed compiler when no argument is given.
  TYPELISP_TOOL_BENCH_OUT              Output root (default target/cli-tool-benchmark).
  TYPELISP_TOOL_BENCH_CORPUS_FILE      Newline-separated corpus manifest override.
  TYPELISP_TOOL_BENCH_FILTER           Substring filter for case labels; skips baseline compare.
  TYPELISP_TOOL_BENCH_RUNS             Timed repetitions per case (default 1).
  TYPELISP_TOOL_BENCH_OPT_LEVEL        Compile optimization level for rebuilt tools (default 2).
  TYPELISP_TOOL_BENCH_UPDATE_BASELINE  Force baseline refresh after a successful full run.
  TYPELISP_TOOL_BENCH_STRICT_BASELINE  Fail instead of refreshing when the corpus changed.
EOF
}

if [ "$#" -gt 1 ]; then
    usage >&2
    exit 2
fi
if [ "$#" -eq 1 ]; then
    case "$1" in
        -h | --help)
            usage
            exit 0
            ;;
    esac
fi

if [ "$#" -eq 1 ]; then
    SEED=$1
elif [ -n "${TYPELISP_BIN:-}" ]; then
    SEED=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    SEED=$(resolve_stage0_compiler "$ROOT") || exit 1
fi

case "$SEED" in
    /* | [A-Za-z]:[/\\]*) ;;
    *) SEED="$ROOT/$SEED" ;;
esac

if [ ! -x "$SEED" ]; then
    echo "typelisp seed is not executable: $SEED" >&2
    exit 1
fi

RUNS=${TYPELISP_TOOL_BENCH_RUNS:-1}
case "$RUNS" in
    "" | *[!0-9]* | 0)
        echo "TYPELISP_TOOL_BENCH_RUNS must be a positive integer" >&2
        exit 2
        ;;
esac

OPT_LEVEL=${TYPELISP_TOOL_BENCH_OPT_LEVEL:-2}
case "$OPT_LEVEL" in
    0 | 1 | 2 | 3) ;;
    *)
        echo "TYPELISP_TOOL_BENCH_OPT_LEVEL must be 0, 1, 2, or 3" >&2
        exit 2
        ;;
esac

FILTER=${TYPELISP_TOOL_BENCH_FILTER:-}
WORKROOT=${TYPELISP_TOOL_BENCH_OUT:-"$ROOT/target/cli-tool-benchmark"}
RUNDIR="$WORKROOT/run"
BASELINE_DIR="$WORKROOT/baseline"
BUILDDIR="$RUNDIR/build"
OUTPUTS="$RUNDIR/outputs"
ARTIFACTS="$RUNDIR/artifacts"
TMPDIR_BENCH="$RUNDIR/tmp"
TIMINGS="$RUNDIR/timings.tsv"
CORPUS_MANIFEST="$RUNDIR/compiler-corpus.txt"
CORPUS_SIG="$RUNDIR/corpus.sha256"
FINGERPRINTS="$RUNDIR/fingerprints.tsv"
CASE_LIST="$RUNDIR/cases.txt"
CHOOSER_QUEUE_FIXTURE="$ROOT/benchmarks/cli-tools/chooser-queue.json"
TOTAL_MS=0

rm -rf "$RUNDIR"
mkdir -p "$BUILDDIR" "$OUTPUTS" "$ARTIFACTS" "$TMPDIR_BENCH" "$BASELINE_DIR"
configure_toolchain

CLI_ASM="$BUILDDIR/cli.s"
CLI_OBJ="$BUILDDIR/cli.$NL_OBJ_EXT"
CLI_BIN="$BUILDDIR/cli$NL_BIN_EXT"
CHOOSER_ASM="$BUILDDIR/chooser.s"
CHOOSER_OBJ="$BUILDDIR/chooser.$NL_OBJ_EXT"
CHOOSER_BIN="$BUILDDIR/chooser$NL_BIN_EXT"

now_ms() {
    value=$(date +%s%3N 2>/dev/null || true)
    case "$value" in
        *[!0-9]* | "") ;;
        *) printf '%s\n' "$value"; return 0 ;;
    esac
    perl -MTime::HiRes=time -e 'printf "%d\n", time() * 1000'
}

record_timing() {
    step=$1
    iteration=$2
    elapsed=$3
    printf '%s\t%s\t%s\n' "$step" "$iteration" "$elapsed" >> "$TIMINGS"
    TOTAL_MS=$((TOTAL_MS + elapsed))
}

record_timing_no_total() {
    step=$1
    iteration=$2
    elapsed=$3
    printf '%s\t%s\t%s\n' "$step" "$iteration" "$elapsed" >> "$TIMINGS"
}

fail() {
    echo "[tool-bench] $*" >&2
    exit 1
}

sha_files() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$@" >&2 || true
    fi
}

strip_if_needed() {
    bin=$1
    if [ "$NL_HOST_OS" = linux ] && command -v strip >/dev/null 2>&1; then
        strip "$bin"
    fi
}

show_failure_logs() {
    stdout=$1
    stderr=$2
    if [ -s "$stdout" ]; then
        echo "stdout:" >&2
        sed 's/^/  /' "$stdout" >&2 || true
    fi
    if [ -s "$stderr" ]; then
        echo "stderr:" >&2
        sed 's/^/  /' "$stderr" >&2 || true
    fi
}

compile_cli_to_asm() {
    label=$1
    compiler=$2
    asm=$3
    stdout="$BUILDDIR/$label.stdout"
    stderr="$BUILDDIR/$label.stderr"
    echo "[tool-bench] $label"
    start=$(now_ms)
    if ! run_with_heartbeat "$label" \
        "$compiler" compile selfhost/cli.tl -o "$asm" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) \
        --stdlib-root stdlib \
        --stdlib-root selfhost \
        --opt-level "$OPT_LEVEL" \
        >"$stdout" 2>"$stderr"; then
        echo "[tool-bench] $label failed" >&2
        show_failure_logs "$stdout" "$stderr"
        exit 1
    fi
    end=$(now_ms)
    record_timing_no_total "$label" compile "$((end - start))"
    [ -s "$asm" ] || fail "$label did not produce assembly: $asm"
}

compile_tool_to_asm() {
    label=$1
    source=$2
    asm=$3
    stdout="$BUILDDIR/$label.stdout"
    stderr="$BUILDDIR/$label.stderr"
    echo "[tool-bench] $label"
    start=$(now_ms)
    if ! run_with_heartbeat "$label" \
        "$CLI_BIN" compile "$source" -o "$asm" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) \
        --stdlib-root stdlib \
        --opt-level "$OPT_LEVEL" \
        >"$stdout" 2>"$stderr"; then
        echo "[tool-bench] $label failed" >&2
        show_failure_logs "$stdout" "$stderr"
        exit 1
    fi
    end=$(now_ms)
    record_timing "$label" compile "$((end - start))"
    [ -s "$asm" ] || fail "$label did not produce assembly: $asm"
}

measure_step() {
    step_label=$1
    shift
    echo "[tool-bench] $step_label"
    start=$(now_ms)
    if ! "$@"; then
        fail "$step_label failed"
    fi
    end=$(now_ms)
    record_timing "$step_label" step "$((end - start))"
}

measure_setup_step_no_total() {
    step_label=$1
    shift
    echo "[tool-bench] $step_label"
    start=$(now_ms)
    if ! "$@"; then
        fail "$step_label failed"
    fi
    end=$(now_ms)
    record_timing_no_total "$step_label" step "$((end - start))"
}

compare_text() {
    label=$1
    left=$2
    right=$3
    if ! cmp -s "$left" "$right"; then
        echo "[tool-bench] mismatch: $label" >&2
        sha_files "$left" "$right"
        if command -v diff >/dev/null 2>&1; then
            diff -u "$left" "$right" | sed -n '1,200p' >&2 || true
        fi
        exit 1
    fi
}

compiler_corpus_manifest() {
    if [ -n "${TYPELISP_TOOL_BENCH_CORPUS_FILE:-}" ]; then
        grep -v '^[[:space:]]*$' "$TYPELISP_TOOL_BENCH_CORPUS_FILE" | sort
        return
    fi

    git ls-files 'selfhost/*.tl' \
        | grep -v '^selfhost/tests/' \
        | grep -vE '(_fixture|_smoke|_tests|_test)\.tl$' \
        | sort
}

write_corpus_signature() {
    manifest=$1
    output=$2
    : > "$output"
    while IFS= read -r file || [ -n "$file" ]; do
        [ -n "$file" ] || continue
        [ -f "$file" ] || fail "corpus file does not exist: $file"
        hash=$(sha256sum "$file" | awk '{ print $1 }')
        printf '%s\t%s\n' "$file" "$hash" >> "$output"
    done < "$manifest"
}

should_run_case() {
    label=$1
    if [ -z "$FILTER" ]; then
        return 0
    fi
    case "$label" in
        *"$FILTER"*) return 0 ;;
        *) return 1 ;;
    esac
}

record_case() {
    label=$1
    printf '%s\n' "$label" >> "$CASE_LIST"
}

measure_case() {
    label=$1
    shift
    if ! should_run_case "$label"; then
        return 0
    fi

    record_case "$label"
    run=1
    while [ "$run" -le "$RUNS" ]; do
        stdout="$OUTPUTS/$label.$run.stdout"
        stderr="$OUTPUTS/$label.$run.stderr"
        echo "[tool-bench] measure $label run $run/$RUNS"
        start=$(now_ms)
        if ! run_with_heartbeat "$label" "$@" >"$stdout" 2>"$stderr"; then
            echo "[tool-bench] $label failed on run $run" >&2
            show_failure_logs "$stdout" "$stderr"
            exit 1
        fi
        end=$(now_ms)
        record_timing "$label" "$run" "$((end - start))"

        if [ "$run" -gt 1 ]; then
            compare_text "$label stdout run 1 vs $run" "$OUTPUTS/$label.1.stdout" "$stdout"
            compare_text "$label stderr run 1 vs $run" "$OUTPUTS/$label.1.stderr" "$stderr"
        fi
        run=$((run + 1))
    done
}

measure_case_unstable_stdout() {
    label=$1
    shift
    if ! should_run_case "$label"; then
        return 0
    fi

    record_case "$label"
    run=1
    while [ "$run" -le "$RUNS" ]; do
        stdout="$OUTPUTS/$label.$run.stdout"
        stderr="$OUTPUTS/$label.$run.stderr"
        echo "[tool-bench] measure $label run $run/$RUNS"
        start=$(now_ms)
        if ! run_with_heartbeat "$label" "$@" >"$stdout" 2>"$stderr"; then
            echo "[tool-bench] $label failed on run $run" >&2
            show_failure_logs "$stdout" "$stderr"
            exit 1
        fi
        end=$(now_ms)
        record_timing "$label" "$run" "$((end - start))"

        if [ "$run" -gt 1 ]; then
            compare_text "$label stderr run 1 vs $run" "$OUTPUTS/$label.1.stderr" "$stderr"
        fi
        run=$((run + 1))
    done
}

copy_corpus_to() {
    dest=$1
    manifest=$2
    mkdir -p "$dest"
    while IFS= read -r file || [ -n "$file" ]; do
        [ -n "$file" ] || continue
        mkdir -p "$dest/$(dirname -- "$file")"
        cp "$file" "$dest/$file"
    done < "$manifest"
}

verify_formatter_no_mutation() {
    if ! should_run_case "fmt-check"; then
        return 0
    fi

    scratch="$TMPDIR_BENCH/fmt-scratch"
    scratch_manifest="$TMPDIR_BENCH/fmt-scratch-files.txt"
    copy_corpus_to "$scratch" "$CORPUS_MANIFEST"
    sed "s#^#$scratch/#" "$CORPUS_MANIFEST" > "$scratch_manifest"

    echo "[tool-bench] verify formatter output matches compiler corpus"
    start=$(now_ms)
    if ! xargs "$CLI_BIN" fmt < "$scratch_manifest" \
        >"$OUTPUTS/fmt-verify.stdout" 2>"$OUTPUTS/fmt-verify.stderr"; then
        echo "[tool-bench] formatter mutation verification failed" >&2
        show_failure_logs "$OUTPUTS/fmt-verify.stdout" "$OUTPUTS/fmt-verify.stderr"
        exit 1
    fi
    end=$(now_ms)
    record_timing "fmt-verify" step "$((end - start))"

    while IFS= read -r file || [ -n "$file" ]; do
        [ -n "$file" ] || continue
        if ! cmp -s "$file" "$scratch/$file"; then
            echo "[tool-bench] formatter changed compiler corpus file: $file" >&2
            if command -v diff >/dev/null 2>&1; then
                diff -u "$file" "$scratch/$file" | sed -n '1,200p' >&2 || true
            fi
            exit 1
        fi
    done < "$CORPUS_MANIFEST"
}

write_lint_runner() {
    cat > "$TMPDIR_BENCH/run-lint-corpus.sh" <<'EOF'
#!/usr/bin/env sh
set -eu
cli=$1
manifest=$2
xargs "$cli" lint --check --stdlib-root stdlib --stdlib-root selfhost < "$manifest"
EOF
    chmod +x "$TMPDIR_BENCH/run-lint-corpus.sh"
}

write_fmt_runner() {
    cat > "$TMPDIR_BENCH/run-fmt-check-corpus.sh" <<'EOF'
#!/usr/bin/env sh
set -eu
cli=$1
manifest=$2
xargs "$cli" fmt --check < "$manifest"
EOF
    chmod +x "$TMPDIR_BENCH/run-fmt-check-corpus.sh"
}

write_one_file_runner() {
    runner=$1
    command_name=$2
    subcommand=${3:-}
    cat > "$runner" <<EOF
#!/usr/bin/env sh
set -eu
cli=\$1
manifest=\$2
while IFS= read -r file || [ -n "\$file" ]; do
    [ -n "\$file" ] || continue
    printf '%s\n' "--- \$file"
    if [ -n "$subcommand" ]; then
        "\$cli" "$command_name" "$subcommand" "\$file" --stdlib-root stdlib --stdlib-root selfhost
    else
        "\$cli" "$command_name" "\$file" --stdlib-root stdlib --stdlib-root selfhost
    fi
done < "\$manifest"
EOF
    chmod +x "$runner"
}

write_doc_test_runner() {
    cat > "$TMPDIR_BENCH/run-doc-test-corpus.sh" <<'EOF'
#!/usr/bin/env sh
set -eu
cli=$1
manifest=$2
xargs "$cli" doc --test --stdlib-root stdlib --stdlib-root selfhost < "$manifest"
EOF
    chmod +x "$TMPDIR_BENCH/run-doc-test-corpus.sh"
}

json_escape_file() {
    awk '
function escape_json(s,    i, ch, out) {
    out = ""
    for (i = 1; i <= length(s); i++) {
        ch = substr(s, i, 1)
        if (ch == "\\") {
            out = out "\\\\"
        } else if (ch == "\"") {
            out = out "\\\""
        } else if (ch == "\t") {
            out = out "\\t"
        } else {
            out = out ch
        }
    }
    return out
}
BEGIN { first = 1; printf "\"" }
{
    if (!first) {
        printf "\\n"
    }
    first = 0
    printf "%s", escape_json($0)
}
END { printf "\"" }
' "$1"
}

copy_chooser_input() {
    output=$1
    [ -f "$CHOOSER_QUEUE_FIXTURE" ] || fail "missing chooser queue fixture: $CHOOSER_QUEUE_FIXTURE"
    cp "$CHOOSER_QUEUE_FIXTURE" "$output"
}

frame_append() {
    frame_file=$1
    frame_body=$2
    frame_len=$(printf '%s' "$frame_body" | wc -c | tr -d ' ')
    {
        printf 'Content-Length: %s\r\n\r\n' "$frame_len"
        printf '%s' "$frame_body"
    } >> "$frame_file"
}

write_lsp_input() {
    output=$1
    : > "$output"
    source_json=$(json_escape_file selfhost/cli.tl)
    uri="file://selfhost/cli.tl"
    frame_append "$output" '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}'
    frame_append "$output" '{"jsonrpc":"2.0","method":"initialized","params":{}}'
    did_open=$(printf '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"%s","languageId":"typelisp","version":1,"text":%s}}}' "$uri" "$source_json")
    frame_append "$output" "$did_open"
    frame_append "$output" '{"jsonrpc":"2.0","id":2,"method":"shutdown","params":null}'
    frame_append "$output" '{"jsonrpc":"2.0","method":"exit","params":null}'
}

write_lsp_runner() {
    cat > "$TMPDIR_BENCH/run-lsp-compiler.sh" <<'EOF'
#!/usr/bin/env sh
set -eu
cli=$1
input=$2
"$cli" lsp --stdlib-root stdlib --stdlib-root selfhost < "$input"
EOF
    chmod +x "$TMPDIR_BENCH/run-lsp-compiler.sh"
}

write_chooser_runner() {
    cat > "$TMPDIR_BENCH/run-chooser-corpus.sh" <<'EOF'
#!/usr/bin/env sh
set -eu
chooser=$1
input=$2
"$chooser" < "$input"
EOF
    chmod +x "$TMPDIR_BENCH/run-chooser-corpus.sh"
}

verify_chooser_output() {
    if ! should_run_case "chooser-corpus"; then
        return 0
    fi

    run=1
    while [ "$run" -le "$RUNS" ]; do
        stdout="$OUTPUTS/chooser-corpus.$run.stdout"
        stderr="$OUTPUTS/chooser-corpus.$run.stderr"
        [ ! -s "$stderr" ] || fail "chooser-corpus wrote stderr on run $run"
        line=$(tr -d '\r' < "$stdout")
        case "$line" in
            "review pr #"*": "* | "implement issue #"*": "* | "research/triage issue #"*": "*) ;;
            *) fail "chooser-corpus produced unexpected output on run $run: $line" ;;
        esac
        run=$((run + 1))
    done
}

fingerprint_outputs() {
    {
        printf 'path\tbytes\tsha256\n'
        find "$OUTPUTS" "$ARTIFACTS" -type f | sort | while IFS= read -r file; do
            rel=${file#"$RUNDIR/"}
            case "$rel" in
                outputs/chooser-corpus.*.stdout) continue ;;
                outputs/*.1.stdout | outputs/*.1.stderr | outputs/fmt-verify.stdout | outputs/fmt-verify.stderr | artifacts/*) ;;
                *) continue ;;
            esac
            bytes=$(wc -c < "$file" | tr -d '[:space:]')
            hash=$(sha256sum "$file" | awk '{ print $1 }')
            printf '%s\t%s\t%s\n' "$rel" "$bytes" "$hash"
        done
    } > "$FINGERPRINTS"
}

refresh_baseline() {
    rm -rf "$BASELINE_DIR"
    mkdir -p "$BASELINE_DIR"
    cp "$CORPUS_SIG" "$BASELINE_DIR/corpus.sha256"
    cp "$FINGERPRINTS" "$BASELINE_DIR/fingerprints.tsv"
    mkdir -p "$BASELINE_DIR/outputs" "$BASELINE_DIR/artifacts"
    cp -R "$OUTPUTS/." "$BASELINE_DIR/outputs/"
    cp -R "$ARTIFACTS/." "$BASELINE_DIR/artifacts/"
    echo "[tool-bench] baseline refreshed: $BASELINE_DIR"
}

verify_previous_run() {
    if [ -n "$FILTER" ]; then
        echo "[tool-bench] filtered run; skipping previous-run baseline compare"
        return 0
    fi

    if [ "${TYPELISP_TOOL_BENCH_UPDATE_BASELINE:-}" = 1 ]; then
        refresh_baseline
        return 0
    fi

    if [ ! -f "$BASELINE_DIR/fingerprints.tsv" ] || [ ! -f "$BASELINE_DIR/corpus.sha256" ]; then
        echo "[tool-bench] no previous full-run baseline; creating one"
        refresh_baseline
        return 0
    fi

    if ! cmp -s "$BASELINE_DIR/corpus.sha256" "$CORPUS_SIG"; then
        if [ "${TYPELISP_TOOL_BENCH_STRICT_BASELINE:-}" = 1 ]; then
            echo "[tool-bench] compiler corpus changed since previous run" >&2
            diff -u "$BASELINE_DIR/corpus.sha256" "$CORPUS_SIG" | sed -n '1,200p' >&2 || true
            exit 1
        fi
        echo "[tool-bench] compiler corpus changed; previous output baseline is not comparable"
        refresh_baseline
        return 0
    fi

    if ! cmp -s "$BASELINE_DIR/fingerprints.tsv" "$FINGERPRINTS"; then
        echo "[tool-bench] output fingerprint changed since previous full run" >&2
        diff -u "$BASELINE_DIR/fingerprints.tsv" "$FINGERPRINTS" | sed -n '1,200p' >&2 || true
        echo "[tool-bench] inspect $RUNDIR and $BASELINE_DIR; set TYPELISP_TOOL_BENCH_UPDATE_BASELINE=1 to accept intentional changes" >&2
        exit 1
    fi

    echo "[tool-bench] output fingerprints match previous full run"
}

printf 'step\titeration\telapsed_ms\n' > "$TIMINGS"
: > "$CASE_LIST"

compiler_corpus_manifest > "$CORPUS_MANIFEST"
[ -s "$CORPUS_MANIFEST" ] || fail "compiler corpus is empty"
write_corpus_signature "$CORPUS_MANIFEST" "$CORPUS_SIG"
corpus_count=$(wc -l < "$CORPUS_MANIFEST" | tr -d '[:space:]')
echo "[tool-bench] compiler corpus: $corpus_count file(s)"

compile_cli_to_asm "build-cli" "$SEED" "$CLI_ASM"
measure_setup_step_no_total "cli-link" assemble_and_link "cli" "$CLI_ASM" "$CLI_OBJ" "$CLI_BIN"
strip_if_needed "$CLI_BIN"

write_fmt_runner
write_lint_runner
write_doc_test_runner
write_lsp_input "$TMPDIR_BENCH/lsp-compiler.in"
write_lsp_runner
copy_chooser_input "$TMPDIR_BENCH/chooser-corpus.json"
write_chooser_runner

compile_tool_to_asm "build-chooser" tools/work-queue-chooser/chooser.tl "$CHOOSER_ASM"
measure_step "chooser-link" assemble_and_link "chooser" "$CHOOSER_ASM" "$CHOOSER_OBJ" "$CHOOSER_BIN"
strip_if_needed "$CHOOSER_BIN"

measure_case "fmt-check" "$TMPDIR_BENCH/run-fmt-check-corpus.sh" "$CLI_BIN" "$CORPUS_MANIFEST"
verify_formatter_no_mutation
measure_case "lint-check-corpus" "$TMPDIR_BENCH/run-lint-corpus.sh" "$CLI_BIN" "$CORPUS_MANIFEST"
measure_case "doc-markdown-cli-graph" "$CLI_BIN" doc selfhost/cli.tl -o "$ARTIFACTS/compiler.md" --stdlib-root stdlib --stdlib-root selfhost
measure_case "doc-html-cli" "$CLI_BIN" doc --html selfhost/cli.tl "$ARTIFACTS/compiler.html"
measure_case "doc-test-corpus" "$TMPDIR_BENCH/run-doc-test-corpus.sh" "$CLI_BIN" "$CORPUS_MANIFEST"
measure_case "lsp-diagnostics-cli" "$TMPDIR_BENCH/run-lsp-compiler.sh" "$CLI_BIN" "$TMPDIR_BENCH/lsp-compiler.in"
measure_case_unstable_stdout "chooser-corpus" "$TMPDIR_BENCH/run-chooser-corpus.sh" "$CHOOSER_BIN" "$TMPDIR_BENCH/chooser-corpus.json"
verify_chooser_output

[ -s "$CASE_LIST" ] || fail "no benchmark cases matched filter: $FILTER"

printf 'total\tall\t%s\n' "$TOTAL_MS" >> "$TIMINGS"
fingerprint_outputs
verify_previous_run

echo "[tool-bench] timings: $TIMINGS"
cat "$TIMINGS"
echo "[tool-bench] fingerprints: $FINGERPRINTS"
cat "$FINGERPRINTS"
echo "[tool-bench] artifacts: $RUNDIR"
