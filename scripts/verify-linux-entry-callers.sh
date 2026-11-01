#!/usr/bin/env sh
set -eu

# Exercise the live caller blocks with the real entry helper. These block
# controls plant grep/link leaves; no compiler is built or invoked. Integration
# retains its C-dependency step, so a helper error must precede that work too.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/scripts/lib-ci-timing.sh"
entry_root=${1:-"$ROOT/target/exp/linux-entry-callers"}
mkdir -p "$entry_root"
entry_work=$(mktemp -d "$entry_root/run.XXXXXX")
entry_grep=$(command -v grep)
export ROOT entry_grep
printf 'caller\tcontrol\ttiming\twant\tstatus\n' > "$entry_work/results.tsv"

# Keep the exit-139 row tied to the actual corpus contract. An entry-selection
# failure must never reach the runtime assertion that could accept that crash.
awk -F '|' '$1 == "arena_poison_stale_array_trap" && $2 == "linux" && $5 == 139 && $6 == "-" && $7 == "-" {found++}
    END {exit found != 1}' "$ROOT/tests/integration/native.manifest"

for entry_spec in ci-verify:1 verify-integration:1 verify-codegen-cases:1 \
        verify-doc-site:1 verify-spmd-simd:1 verify-safety-corpus:1 \
        verify-safety-corpus:2 verify-spmd-runtime-dispatch:1 run-optimization-benchmarks:1; do
    entry_script=${entry_spec%:*}
    entry_index=${entry_spec##*:}
    entry_fixture="$entry_work/$entry_script-$entry_index.sh"
    cat > "$entry_fixture" <<'EOF'
#!/usr/bin/env sh
set -eu
. "$ROOT/scripts/lib-linux-entry.sh"
. "$ROOT/scripts/lib-ci-timing.sh"
grep() {
    printf '%s\n' "grep:$2" >> "$entry_case/trace"
    case "$entry_control:$2" in
        first-error:'^_tl_start:$') return 2 ;;
        second-error:'^_start:$') return 2 ;;
        tool-status:'^_tl_start:$') return 23 ;;
    esac
    "$entry_grep" "$@"
}
ld() {
    while [ "$#" -gt 0 ] && [ "$1" != -e ]; do shift; done
    [ "$#" -eq 2 ] || return 24
    printf 'link:%s\n' "$2" >> "$entry_case/trace"
    [ "$2" = "$entry_expected" ] || return 24
    [ "$entry_control" != link-error ] || return 29
}
compile_linux_c_deps() { printf 'c-deps\n' >> "$entry_case/trace"; }
show_build_streams() { :; }
show_stream_if_nonempty() { :; }
fail() { exit 1; }
cc_run_step() { shift; CV_EXIT=0; "$@" || CV_EXIT=$?; }
cc_require_step() { [ "$CV_EXIT" -eq 0 ]; }
run_linux_manifest_program() { printf 'run:139\n' >> "$entry_case/trace"; return 139; }
deps_or_empty() { :; }
assert_manifest_assembly_requirements() { printf 'assert:139\n' >> "$entry_case/trace"; }
write_expected_stream() { [ "$1" = - ] && : > "$2"; }
normalized_stream() { cp "$1" "$2"; }
EOF
    if [ "$entry_script" = verify-integration ]; then
        # Use the real exit/stream assertion, not a surrogate that merely
        # assumes an exit-139 row would pass after a bogus empty-entry link.
        awk '/^assert_manifest_case\(\)/ {copying=1} copying {print; if ($0 == "}") {complete=1; exit}}
            END {if (!complete) exit 1}' "$ROOT/scripts/verify-integration.sh" >> "$entry_fixture"
    fi
    cat >> "$entry_fixture" <<'EOF'
entry_caller() {
    asm="$entry_case/input.s" _asm="$entry_case/input.s" ASM="$entry_case/input.s"
    CV_ASM="$asm" _tl_asm="$asm"
    obj=fixture.o _obj=fixture.o OBJ=fixture.o _tl_obj=fixture.o
    bin=fixture _bin=fixture BIN=fixture _tl_bin=fixture CHECK_BIN=fixture program=fixture
    CV_DIR="$entry_case" case_dir="$entry_case" probe_dir="$entry_case"
    build_stdout="$entry_case/build.out" build_stderr="$entry_case/build.err"
    _out="$build_stdout" _err="$build_stderr" out="$build_stdout" err="$build_stderr"
    build_out="$build_stdout" build_err="$build_stderr" mode_out="$build_stdout" mode_err="$build_stderr"
    RUN_OUT="$build_stdout" RUN_ERR="$build_stderr"
    name=arena_poison_stale_array_trap deps=- failed=0 ran=0 mode_code=0
    HOST_OS=linux want=139 stdout_spec=- expected_stderr_spec=- runtime_args=- case_timed_out=0
    stdout="$entry_case/run.out" stderr="$entry_case/run.err" run_shell_stderr="$entry_case/run.shell.err"
    : > "$stdout"; : > "$stderr"; : > "$run_shell_stderr"
    _label=fixture _source=fixture case_id=fixture
    for entry_once in one; do
EOF
    # Extract the assignment/guard and its actual dependent link handling.
    # Exact inventory and endpoint checks make removals fail rather than
    # silently reducing coverage. No copy of a production guard lives here.
    awk -v wanted="$entry_index" -v script="$entry_script" '
        /^[[:space:]]*[A-Za-z_][A-Za-z_0-9]*=\$\(.*(linux_entry_symbol_for_asm|ci_timing_run.*entry-selection)/ {
            if (++seen == wanted) copying=1
        }
        copying {
            print
            if ($0 ~ /(^|[[:space:]])ld[[:space:]]/) linked=1
            if (linked && ((script == "run-optimization-benchmarks" && $0 !~ /\\$/) ||
                (script == "verify-codegen-cases" && /cc_require_step "GNU ld"/) ||
                (script != "run-optimization-benchmarks" && script != "verify-codegen-cases" && /^[[:space:]]*fi$/))) {
                complete=1; exit
            }
        }
        END {if (!complete) exit 1}
    ' "$ROOT/scripts/$entry_script.sh" >> "$entry_fixture"
    if [ "$entry_script" = verify-integration ]; then
        # Retain the actual Linux runtime/timing path and assertion call after
        # the link block; omit only the enclosing platform branch terminator.
        awk '
            /ld "\$obj".*-e "\$entry"/ {linked=1}
            linked && /^        set \+e$/ {copying=1}
            copying && /^    fi$/ {copying=0; runtime=1; next}
            runtime && /^    assert_manifest_case / {copying=1}
            copying && /^done </ {complete=1; exit}
            copying {print}
            END {if (!complete) exit 1}
        ' "$ROOT/scripts/verify-integration.sh" >> "$entry_fixture"
    fi
    cat >> "$entry_fixture" <<'EOF'
        [ "$mode_code" -eq 0 ] || return 1
        printf 'dependent\n' >> "$entry_case/trace"
    done
    [ "$failed" -eq 0 ]
}
# Helper-error controls deliberately disable errexit. The explicit caller
# guard must retain the status even in an enclosing status-tested context.
case "$entry_control" in first-error | second-error | tool-status) set +e ;; esac
entry_caller
entry_result=$?
[ "$entry_result" -eq 0 ] || exit "$entry_result"
[ "$mode_code" -eq 0 ] || exit 1
EOF
    for entry_control in modern legacy fallback first-error second-error tool-status link-error; do
        for entry_timing in 0 1; do
            entry_case="$entry_work/$entry_script-$entry_index-$entry_control-$entry_timing"
            mkdir -p "$entry_case"
            : > "$entry_case/trace"
            entry_expected=_tl_start
            case "$entry_control" in
                legacy | second-error) printf '_start:\n' > "$entry_case/input.s"; entry_expected=_start ;;
                fallback) : > "$entry_case/input.s" ;;
                *) printf '_tl_start:\n' > "$entry_case/input.s" ;;
            esac
            entry_want=0
            case "$entry_control" in
                first-error | second-error) entry_want=2 ;;
                tool-status) entry_want=23 ;;
                link-error)
                    entry_want=1
                    [ "$entry_script" != run-optimization-benchmarks ] || entry_want=29
                    ;;
            esac
            export entry_case entry_control entry_expected
            TYPELISP_CI_TIMING=$entry_timing
            TYPELISP_CI_TIMING_GATE=linux-entry-callers
            export TYPELISP_CI_TIMING TYPELISP_CI_TIMING_GATE
            ci_timing_init "$entry_case/timing.tsv" linux
            entry_status=0
            ci_timing_run "$entry_spec-$entry_control" caller sh "$entry_fixture" \
                > "$entry_case/stdout" 2> "$entry_case/stderr" || entry_status=$?
            printf '%s\t%s\t%s\t%s\t%s\n' "$entry_spec" "$entry_control" \
                "$entry_timing" "$entry_want" "$entry_status" >> "$entry_work/results.tsv"
            [ "$entry_status" -eq "$entry_want" ] || {
                cat "$entry_case/stderr" >&2
                echo "FAIL: $entry_case expected $entry_want, got $entry_status" >&2
                exit 1
            }
            printf 'grep:^_tl_start:$\n' > "$entry_case/expected"
            case "$entry_control" in
                legacy | fallback | second-error) printf 'grep:^_start:$\n' >> "$entry_case/expected" ;;
            esac
            case "$entry_control" in
                first-error | second-error | tool-status) ;;
                *)
                    [ "$entry_script" != verify-integration ] || printf 'c-deps\n' >> "$entry_case/expected"
                    printf 'link:%s\n' "$entry_expected" >> "$entry_case/expected"
                    if [ "$entry_control" != link-error ]; then
                        [ "$entry_script" != verify-integration ] || printf 'run:139\nassert:139\n' >> "$entry_case/expected"
                        printf 'dependent\n' >> "$entry_case/expected"
                    fi
                    ;;
            esac
            cmp "$entry_case/trace" "$entry_case/expected"
            if [ "$entry_timing" -eq 0 ]; then
                [ ! -e "$entry_case/timing.tsv" ]
            else
                awk -F '\t' -v want="$entry_want" -v id="$entry_spec-$entry_control" \
                    -v integration="$entry_script" -v control="$entry_control" '
                    NR == 1 {next}
                    $2 == id && $3 == "caller" {outer++; if ($5 != want) bad=1; next}
                    $2 != "arena_poison_stale_array_trap" {bad=1}
                    $3 == "entry-selection" {selection++; if ($5 != (control == "link-error" ? 0 : want)) bad=1; next}
                    $3 == "link" {link++; if ($5 != (control == "link-error" ? 29 : 0)) bad=1; next}
                    $3 == "run" {run++; if ($5 != 139) bad=1; next}
                    $3 == "assert" {assertion++; if ($5 != 0) bad=1; next}
                    {bad=1}
                    END {
                        is_integration=(integration == "verify-integration")
                        error=(control == "first-error" || control == "second-error" || control == "tool-status")
                        executed=(is_integration && !error && control != "link-error")
                        exit bad || outer != 1 || selection != is_integration || link != (is_integration && !error) ||
                            run != executed || assertion != executed
                    }
                ' "$entry_case/timing.tsv"
            fi
        done
    done
done
[ "$(wc -l < "$entry_work/results.tsv")" -eq 127 ]
echo "Linux entry caller self-test passed (9 callers, 126 status/trace/timing controls; $entry_work)"
sh "$ROOT/scripts/verify-linux-entry-transcripts.sh" "$entry_work/transcripts"
