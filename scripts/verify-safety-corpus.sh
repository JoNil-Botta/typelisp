#!/usr/bin/env sh
set -eu

# verify-safety-corpus.sh - safe-code contract corpus.
#
# The manifest pairs small TypeLisp fixtures with check/run expectations for the
# SPEC.md "Safe code: no undefined behavior" table.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-linux-entry.sh"
. "$ROOT/scripts/lib-source-location.sh"

HOST_OS=linux
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    *)
        echo "safety corpus verification is unsupported on this host" >&2
        exit 1
        ;;
esac

GATE_FAIL_PREFIX='FAIL: '
. "$ROOT/scripts/lib-gate.sh"

SELF_TEST_ONLY=false
case "${1:-}" in
    --self-test) SELF_TEST_ONLY=true; shift ;;
    "") ;;
    *) fail "usage: scripts/verify-safety-corpus.sh [--self-test]" ;;
esac
[ "$#" -eq 0 ] || fail "unexpected arguments"

prepare_tools() {
    gate_compiler
    gate_compiler_absolute
    gate_require_compiler
    if [ "$HOST_OS" = linux ]; then
        command -v as >/dev/null 2>&1 || fail "missing assembler: as"
        command -v ld >/dev/null 2>&1 || fail "missing linker: ld"
    else
        command -v clang >/dev/null 2>&1 || fail "missing assembler: clang"
        command -v lld-link >/dev/null 2>&1 || fail "missing linker: lld-link"
    fi
}

MANIFEST=${TYPELISP_SAFETY_MANIFEST:-tests/safety/manifest.txt}
if [ ! -f "$MANIFEST" ]; then
    echo "safety corpus manifest does not exist: $MANIFEST" >&2
    exit 1
fi

default_workdir=target/safety-corpus-verify
if [ "$SELF_TEST_ONLY" = true ]; then
    default_workdir=target/exp/safety-oracle-self-test
fi
WORKDIR=${TYPELISP_SAFETY_WORKDIR:-$default_workdir}
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
NORMALIZED_MANIFEST="$WORKDIR/manifest.normalized"
tr -d '\r' < "$MANIFEST" > "$NORMALIZED_MANIFEST"

BUILD_TARGET=linux-x86_64
CHECK_BIN="$WORKDIR/selfhost-check"
TARGET_CFG_ARGS="--cfg linux --cfg unix --cfg target-linux --cfg os-linux"
if [ "$HOST_OS" = windows ]; then
    BUILD_TARGET=windows-x86_64
    CHECK_BIN="$WORKDIR/selfhost-check.exe"
    TARGET_CFG_ARGS="--cfg windows --cfg target-windows --cfg os-windows"
fi

case "$WORKDIR" in
    /*) WORKDIR_ABS=$WORKDIR ;;
    *) WORKDIR_ABS=$ROOT/$WORKDIR ;;
esac
CHECK_BIN_ABS="$WORKDIR_ABS/$(basename "$CHECK_BIN")"

# Windows-target check-only rows run from either host and never execute. Each
# fixture is checked against the source stdlib roots, and again from a
# directory without `stdlib/`, where imports resolve from the compiler's
# embedded stdlib; both routes must give the expected result.
windows_target_check() {
    _out=$1
    _err=$2
    _source=$3
    _route=$4
    if [ "$_route" = source ]; then
        run_case "$_out" "$_err" - \
            "$CHECK_BIN" check "$_source" --target windows-x86_64 \
            --stdlib-root "$ROOT/stdlib" \
            --stdlib-root "$ROOT/src" \
            --stdlib-root "$ROOT/tests/integration"
    else
        mkdir -p "$WORKDIR_ABS/embedded-stdlib-cwd"
        run_case "$_out" "$_err" - \
            sh -c 'cd "$1" && shift && exec "$@"' windows-embedded-check \
            "$WORKDIR_ABS/embedded-stdlib-cwd" \
            "$CHECK_BIN_ABS" check "$ROOT/$_source" \
            --target windows-x86_64
    fi
}

# A failing check must report a specific diagnostic code and a decoded message.
assert_check_failure_decoded() {
    _decoded_case=$1
    _decoded_err=$2
    if grep -Fq 'error[E0200]' "$_decoded_err"; then
        fail "$_decoded_case regressed to generic E0200; assign a specific code or update the taxonomy"
    fi
    if grep -Fq '__tl_tc_' "$_decoded_err"; then
        fail "$_decoded_case rendered an internal typecheck error transport instead of decoding it"
    fi
}

assert_contains() {
    file=$1
    needle=$2
    if ! grep -F -- "$needle" "$file" >/dev/null; then
        echo "expected substring: $needle" >&2
        echo "actual output:" >&2
        sed 's/^/  /' "$file" >&2 || true
        return 1
    fi
}

assert_empty() {
    file=$1
    if [ -s "$file" ]; then
        echo "expected empty output, got:" >&2
        sed 's/^/  /' "$file" >&2 || true
        return 1
    fi
}

# An expected rejection is a normal checker exit with a structured diagnostic
# for the intended operation. In particular, a diagnostic followed by a signal
# is a compiler failure, not evidence that the checker rejected safely.
# The fourth manifest field may pin another source, or source:line:column;
# '-' requires a primary location in the fixture itself.
classify_check_status() {
    case "$1" in
        0|1) echo normal ;;
        124|125|126|127|130|137|143) echo infrastructure-resource-failure ;;
        *)
            if [ "$1" -gt 128 ]; then
                echo compiler-crash
            else
                echo infrastructure-resource-failure
            fi ;;
    esac
}

classify_check_rejection() {
    rejection_code=$1
    rejection_out=$2
    rejection_err=$3
    rejection_source=$4
    rejection_needle=$5
    rejection_status=$(classify_check_status "$rejection_code")
    if [ "$rejection_status" != normal ]; then
        echo "$rejection_status"
        return
    fi
    if [ "$rejection_code" -eq 0 ]; then
        echo accepted-invalid
        return
    fi
    if [ -s "$rejection_out" ]; then
        echo malformed-output
        return
    fi
    # Match messages and diagnostic metadata, never the echoed source snippet.
    # Keep the location and message in the same diagnostic, and require its
    # primary span: a related label in the desired file is insufficient.
    SAFETY_DIAGNOSTIC_SOURCE=$rejection_source SAFETY_DIAGNOSTIC_NEEDLE=$rejection_needle \
    awk '
        function finish() {
            if (is_error && !primary) malformed = 1
            if (is_error && intended && located) matched = 1
        }
        function same_path(actual, expected) {
            return actual == expected ||
                (length(actual) > length(expected) &&
                 substr(actual, length(actual) - length(expected)) == "/" expected)
        }
        BEGIN {
            source = ENVIRON["SAFETY_DIAGNOSTIC_SOURCE"]
            needle = ENVIRON["SAFETY_DIAGNOSTIC_NEEDLE"]
            gsub(/\\/, "/", source)
        }
        { sub(/\r$/, ""); if (/__tl_tc_/) wrong = 1 }
        /^(error|warning|note)(\[[A-Z][0-9]+\])?: / {
            finish()
            header = 1
            is_error = /^error(\[E[0-9][0-9][0-9][0-9]\])?: /
            if (/^error/ && !is_error) malformed = 1
            primary = located = 0
            intended = index($0, needle) > 0
            if (/^error\[E0200\]: /) wrong = 1
            next
        }
        /^  --> / {
            if (!header) malformed = 1
            location = substr($0, 7)
            gsub(/\\/, "/", location)
            if (location !~ /:[1-9][0-9]*:[1-9][0-9]*$/) malformed = 1
            # A needle that is a whole path:line:column may name a RELATED
            # span of this diagnostic, such as a declared-here label; it
            # never matches the primary span, which must still be located.
            if (primary && needle ~ /:[1-9][0-9]*:[1-9][0-9]*$/ && same_path(location, needle))
                intended = 1
            if (!primary) {
                primary = 1
                path = location
                if (source !~ /:[1-9][0-9]*:[1-9][0-9]*$/)
                    sub(/:[0-9]+:[0-9]+$/, "", path)
                located = same_path(path, source)
            }
            next
        }
        /^   = (help|note|label): / {
            if (!header) malformed = 1
            if (index($0, needle)) intended = 1
            next
        }
        /^ *([0-9]+ )?\|/ { if (!header) malformed = 1; next }
        /^$/ { next }
        { malformed = 1 }
        END {
            finish()
            if (malformed) print "malformed-output"
            else if (wrong || !matched) print "wrong-diagnostic"
            else print "rejected-invalid"
        }
    ' "$rejection_err"
}

run_case() {
    out=$1
    err=$2
    expected_terminal_code=$3
    shift 3
    : "$expected_terminal_code"   # accepted for call-site compatibility; unused
    # Run the case once. A crash is a real bug, not a flake — do not retry it.
    set +e
    "$@" < /dev/null > "$out" 2> "$err"
    code=$?
    set -e
}

# Assemble (clang) + link (lld-link) a Windows .s into an .exe. The compile-only
# bootstrapped stage1 has no `build` host action, so the corpus drives the Windows
# toolchain by hand (mirrors verify-integration.sh's assemble_link_windows).
assemble_link_windows() {
    _asm=$1
    _obj=$2
    _bin=$3
    _label=$4
    _out=$5
    _err=$6
    if ! clang --target=x86_64-pc-windows-msvc -c "$_asm" -o "$_obj" \
        < /dev/null >> "$_out" 2>> "$_err"; then
        show_stream_if_nonempty stderr "$_err"
        fail "$_label assemble failed"
    fi
    if ! lld-link -NOLOGO "$(cygpath -aw "$_obj")" "-OUT:$(cygpath -aw "$_bin")" \
        -SUBSYSTEM:CONSOLE -STACK:268435456 -ENTRY:_tl_start -NODEFAULTLIB kernel32.lib ntdll.lib \
        < /dev/null >> "$_out" 2>> "$_err"; then
        show_stream_if_nonempty stderr "$_err"
        fail "$_label link failed"
    fi
}

build_selfhost_checker() {
    out="$WORKDIR/selfhost-check.build.out"
    err="$WORKDIR/selfhost-check.build.err"
    if [ "$HOST_OS" = windows ]; then
        asm="$WORKDIR/selfhost-check.s"
        obj="$WORKDIR/selfhost-check.obj"
        run_case "$out" "$err" 0 \
            "$COMPILER" compile src/main.tl \
            --target "$BUILD_TARGET" \
            $TARGET_CFG_ARGS \
            --stdlib-root stdlib \
            -o "$asm"
        if [ "$code" -ne 0 ]; then
            echo "stdout:" >&2
            sed 's/^/  /' "$out" >&2 || true
            echo "stderr:" >&2
            sed 's/^/  /' "$err" >&2 || true
            fail "src/main.tl compile failed with exit $code"
        fi
        assemble_link_windows "$asm" "$obj" "$CHECK_BIN" "src/main.tl" "$out" "$err"
    else
        # The compile-only bootstrapped stage1 has `compile`/`check` but not the
        # `build` host action, so assemble + link the checker by hand (mirrors
        # build_case_program's Linux path).
        asm="$WORKDIR/selfhost-check.s"
        obj="$WORKDIR/selfhost-check.o"
        run_case "$out" "$err" 0 \
            "$COMPILER" compile src/main.tl \
            --target "$BUILD_TARGET" \
            $TARGET_CFG_ARGS \
            --stdlib-root stdlib \
            -o "$asm"
        if [ "$code" -ne 0 ]; then
            echo "stdout:" >&2
            sed 's/^/  /' "$out" >&2 || true
            echo "stderr:" >&2
            sed 's/^/  /' "$err" >&2 || true
            fail "src/main.tl compile failed with exit $code"
        fi
        if ! as "$asm" -o "$obj" < /dev/null >> "$out" 2>> "$err"; then
            show_stream_if_nonempty stderr "$err"
            fail "src/main.tl assemble failed"
        fi
        entry=$(linux_entry_symbol_for_asm "$asm") || exit $?
        if ! ld "$obj" -o "$CHECK_BIN" -static -e "$entry" \
            < /dev/null >> "$out" 2>> "$err"; then
            show_stream_if_nonempty stderr "$err"
            fail "src/main.tl link failed"
        fi
    fi
}

safe_name() {
    safe_name_rest=$1
    case_name=
    while :; do
        case "$safe_name_rest" in
            *[/\\:]*)
                case_name=$case_name${safe_name_rest%%[/\\:]*}_
                safe_name_rest=${safe_name_rest#*[/\\:]}
                ;;
            *) case_name=$case_name$safe_name_rest; break ;;
        esac
    done
}

show_stream_if_nonempty() {
    label=$1
    file=$2
    if [ -s "$file" ]; then
        echo "$label:" >&2
        sed 's/^/  /' "$file" >&2 || true
    fi
}

build_case_program() {
    case_id=$1
    case_name=$2
    source=$3
    case_dir="$WORKDIR/$case_name"
    mkdir -p "$case_dir"
    build_out="$case_dir/build.out"
    build_err="$case_dir/build.err"

    if [ "$HOST_OS" = windows ]; then
        case_source="$case_dir/$(basename "$source")"
        cp "$source" "$case_source"
        # The copy no longer sits beside the fixture's sibling modules (e.g.
        # `foreign_global_dep.tl`), which Linux resolves by compiling the source
        # in place. Name the fixture's own directory as the last root so those
        # imports resolve here too without shadowing stdlib or compiler modules.
        source_dir=$(CDPATH= cd -- "$(dirname -- "$source")" && pwd)
        asm="$case_dir/$case_name.s"
        obj="$case_dir/$case_name.obj"
        program="$case_dir/$case_name.exe"
        run_case "$build_out" "$build_err" 0 \
            "$COMPILER" compile "$case_source" \
            --target "$BUILD_TARGET" \
            $TARGET_CFG_ARGS \
            --stdlib-root "$ROOT/stdlib" \
            --stdlib-root "$ROOT/src" \
            --stdlib-root "$ROOT/tests/integration" \
            --stdlib-root "$source_dir" \
            -o "$asm"
        if [ "$code" -ne 0 ]; then
            show_stream_if_nonempty stdout "$build_out"
            show_stream_if_nonempty stderr "$build_err"
            fail "$case_id compile failed with exit $code"
        fi
        assemble_link_windows "$asm" "$obj" "$program" "$case_id" "$build_out" "$build_err"
    else
        asm="$case_dir/$case_name.s"
        obj="$case_dir/$case_name.o"
        program="$case_dir/$case_name"
        run_case "$build_out" "$build_err" 0 \
            "$COMPILER" compile "$source" \
            --target "$BUILD_TARGET" \
            $TARGET_CFG_ARGS \
            --stdlib-root "$ROOT/stdlib" \
            --stdlib-root "$ROOT/src" \
            --stdlib-root "$ROOT/tests/integration" \
            -o "$asm"
        if [ "$code" -ne 0 ]; then
            show_stream_if_nonempty stdout "$build_out"
            show_stream_if_nonempty stderr "$build_err"
            fail "$case_id compile failed with exit $code"
        fi
        if ! as "$asm" -o "$obj" < /dev/null >> "$build_out" 2>> "$build_err"; then
            show_stream_if_nonempty stdout "$build_out"
            show_stream_if_nonempty stderr "$build_err"
            fail "$case_id assemble failed"
        fi
        entry=$(linux_entry_symbol_for_asm "$asm") || exit $?
        if ! ld "$obj" -o "$program" -static -e "$entry" \
            < /dev/null >> "$build_out" 2>> "$build_err"; then
            show_stream_if_nonempty stdout "$build_out"
            show_stream_if_nonempty stderr "$build_err"
            fail "$case_id link failed"
        fi
    fi
}

run_program_case() {
    case_id=$1
    case_name=$2
    source=$3
    out=$4
    err=$5
    expected_code=$6
    build_case_program "$case_id" "$case_name" "$source"
    run_case "$out" "$err" "$expected_code" "$program"
}

checked=0
run_manifest_case() {
    case_id=$1
    mode=$2
    source=$3
    expected_code=$4
    stderr_contains=$5

    case "$case_id" in
        "" | \#*) return ;;
    esac
    [ -n "$mode" ] || fail "$case_id missing mode"
    [ -n "$source" ] || fail "$case_id missing source"
    [ -f "$source" ] || fail "$case_id source does not exist: $source"

    safe_name "$case_id"
    out="$WORKDIR/$case_name.out"
    err="$WORKDIR/$case_name.err"

    case "$mode" in
        check-ok)
            echo "[safety-corpus] check-ok $case_id"
            run_case "$out" "$err" 0 \
                "$CHECK_BIN" check "$source" \
                --stdlib-root "$ROOT/stdlib" \
                --stdlib-root "$ROOT/src" \
                --stdlib-root "$ROOT/tests/integration"
            observation=$(classify_check_status "$code")
            [ "$observation" = normal ] || fail "$case_id $observation (exit $code)"
            [ "$code" -eq 0 ] || fail "$case_id rejected-valid (exit $code)"
            assert_empty "$err" || fail "$case_id expected empty check stderr"
            [ "$(cat "$out")" = 'Type checking passed!' ] || fail "$case_id malformed-output: missing check success record"
            ;;
        check-fail)
            echo "[safety-corpus] check-fail $case_id"
            run_case "$out" "$err" - \
                "$CHECK_BIN" check "$source" \
                --stdlib-root "$ROOT/stdlib" \
                --stdlib-root "$ROOT/src" \
                --stdlib-root "$ROOT/tests/integration"
            [ -n "$stderr_contains" ] && [ "$stderr_contains" != "-" ] || fail "$case_id check-fail missing stderr expectation"
            diagnostic_source=$source
            if [ "$expected_code" != "-" ]; then
                diagnostic_source=$expected_code
                case "$diagnostic_source" in
                    *'@loc{'*) diagnostic_source=$(resolve_source_locations "$diagnostic_source") || fail "$case_id invalid diagnostic location" ;;
                esac
            fi
            observation=$(classify_check_rejection "$code" "$out" "$err" \
                "$diagnostic_source" "$stderr_contains")
            printf '%s\t%s\t%s\n' "$case_id" "$code" "$observation" >> "$WORKDIR/rejections.tsv"
            if [ "$observation" != rejected-invalid ]; then
                show_stream_if_nonempty stdout "$out"
                show_stream_if_nonempty stderr "$err"
                fail "$case_id $observation (exit $code; expected located diagnostic: $stderr_contains)"
            fi
            assert_check_failure_decoded "$case_id" "$err"
            ;;
        check-ok-windows)
            for route in source embedded; do
                echo "[safety-corpus] check-ok-windows $case_id ($route stdlib)"
                windows_target_check "$out" "$err" "$source" "$route"
                [ "$code" -eq 0 ] || fail "$case_id expected Windows-target check success ($route stdlib), got $code"
                assert_empty "$err" || fail "$case_id expected empty Windows-target check stderr ($route stdlib)"
            done
            ;;
        check-fail-windows)
            [ "$stderr_contains" != "-" ] || fail "$case_id check-fail-windows missing stderr expectation"
            for route in source embedded; do
                echo "[safety-corpus] check-fail-windows $case_id ($route stdlib)"
                windows_target_check "$out" "$err" "$source" "$route"
                [ "$code" -ne 0 ] || fail "$case_id expected Windows-target check failure ($route stdlib)"
                assert_contains "$err" "$stderr_contains" || fail "$case_id Windows-target stderr did not match expectation ($route stdlib)"
                assert_check_failure_decoded "$case_id ($route stdlib)" "$err"
            done
            ;;
        run-exit)
            echo "[safety-corpus] run-exit $case_id"
            run_program_case "$case_id" "$case_name" "$source" "$out" "$err" "$expected_code"
            [ "$code" -eq "$expected_code" ] || fail "$case_id expected run exit $expected_code, got $code"
            assert_empty "$err" || fail "$case_id expected empty stderr"
            ;;
        run-trap)
            echo "[safety-corpus] run-trap $case_id"
            run_program_case "$case_id" "$case_name" "$source" "$out" "$err" "$expected_code"
            [ "$code" -eq "$expected_code" ] || fail "$case_id expected trap exit $expected_code, got $code"
            [ "$stderr_contains" != "-" ] || fail "$case_id run-trap missing stderr expectation"
            assert_contains "$err" "$stderr_contains" || fail "$case_id trap stderr did not match expectation"
            ;;
        *)
            fail "$case_id has unknown safety corpus mode: $mode"
            ;;
    esac
    checked=$((checked + 1))
}

# Invoke the callback in this shell so its counters/state remain visible, but
# replace stdin for the whole callback. This protects the manifest reader from
# every compiler, build tool, and generated program launched by a case, even if
# a future call site forgets the explicit run_case redirection.
for_each_manifest_case() {
    manifest=$1
    callback=$2
    while IFS='|' read -r field1 field2 field3 field4 field5 || [ -n "$field1" ]; do
        "$callback" "$field1" "$field2" "$field3" "$field4" "$field5" \
            < /dev/null
    done < "$manifest"
}

# Focused runner regression: the callback deliberately drains stdin. Without
# the callback redirection, it consumes the second manifest row and count is 1.
manifest_runner_self_test() {
    self_test_manifest="$WORKDIR/manifest-stdin-self-test.txt"
    printf 'first||||\nsecond||||' > "$self_test_manifest"
    self_test_count=0
    manifest_runner_stdin_consumer() {
        cat > /dev/null
        self_test_count=$((self_test_count + 1))
    }
    for_each_manifest_case "$self_test_manifest" manifest_runner_stdin_consumer
    [ "$self_test_count" -eq 2 ] || \
        fail "manifest stdin isolation self-test processed $self_test_count of 2 cases"

    # Output basenames preserve every byte except the three path separators.
    safe_name 'plain-123_Å [*] "quote"'
    [ "$case_name" = 'plain-123_Å [*] "quote"' ] || fail "ordinary safety case name changed"
    safe_name '/a\b:c//\:'
    [ "$case_name" = '_a_b_c____' ] || fail "safety case separators were not translated"
    safe_name ''
    [ -z "$case_name" ] || fail "empty safety case name changed"
}

rejection_oracle_self_test() {
    oracle_out="$WORKDIR/oracle.out"
    oracle_err="$WORKDIR/oracle.err"
    : > "$oracle_out"
    oracle_count=0
    oracle_expect() {
        oracle_actual=$(classify_check_rejection "$2" "$oracle_out" "$oracle_err" \
            "${4:-fixture.tl}" 'intended move')
        [ "$oracle_actual" = "$3" ] || fail "oracle $1: expected $3, got $oracle_actual"
        oracle_count=$((oracle_count + 1))
    }
    oracle_expect_needle() {
        oracle_actual=$(classify_check_rejection "$2" "$oracle_out" "$oracle_err" \
            fixture.tl "$4")
        [ "$oracle_actual" = "$3" ] || fail "oracle $1: expected $3, got $oracle_actual"
        oracle_count=$((oracle_count + 1))
    }
    oracle_diagnostic() {
        printf 'error[E0214]: intended move\n  --> %s\n   |\n 3 | (consume value)\n   | ^\n' "$1" > "$oracle_err"
    }
    oracle_diagnostic fixture.tl:3:1
    oracle_expect located 1 rejected-invalid
    printf '  --> provider.tl:8:9\n   |\n   = label: expanded here\n' >> "$oracle_err"
    oracle_expect expansion-label 1 rejected-invalid
    printf 'error: intended move\n  --> fixture.tl:3:1\n' > "$oracle_err"
    oracle_expect macro-diagnostic-without-code 1 rejected-invalid
    oracle_diagnostic fixture.tl:3:1
    oracle_expect exact-location 1 rejected-invalid fixture.tl:3:1
    oracle_expect wrong-operation-location 1 wrong-diagnostic fixture.tl:4:1
    oracle_expect accepted 0 accepted-invalid
    oracle_expect diagnostic-then-segv 139 compiler-crash
    oracle_expect diagnostic-then-abort 134 compiler-crash
    oracle_expect timed-out 124 infrastructure-resource-failure
    oracle_expect killed 137 infrastructure-resource-failure
    oracle_expect not-executed 127 infrastructure-resource-failure
    oracle_expect unsupported-exit 2 infrastructure-resource-failure
    printf 'Segmentation fault\n' >> "$oracle_err"
    oracle_expect crash-text-with-exit-one 1 malformed-output
    oracle_diagnostic fixture.tl:3:1
    printf 'Type checking passed!\n' > "$oracle_out"
    oracle_expect contradictory-success 1 malformed-output
    : > "$oracle_out"
    oracle_diagnostic unrelated.tl:3:1
    oracle_expect wrong-source 1 wrong-diagnostic
    printf '  --> fixture.tl:3:1\n' >> "$oracle_err"
    oracle_expect secondary-is-not-primary 1 wrong-diagnostic
    oracle_diagnostic fixture.tl:0:0
    oracle_expect unlocated 1 malformed-output
    printf 'error[E0214]: intended move\n' > "$oracle_err"
    oracle_expect truncated 1 malformed-output
    printf 'error[E0100]: parse error\n  --> fixture.tl:3:1\n 3 | intended move\n' > "$oracle_err"
    oracle_expect source-echo-is-not-diagnostic 1 wrong-diagnostic
    printf 'error[E0100]: unrelated error\n  --> intended move.tl:3:1\n' > "$oracle_err"
    oracle_expect location-is-not-diagnostic 1 wrong-diagnostic 'intended move.tl'
    printf 'error[E0100]: unrelated error\n  --> fixture.tl:3:1\n  --> fixture.tl:9:2\n   |\n   = label: declared here\n' > "$oracle_err"
    oracle_expect_needle related-location 1 rejected-invalid fixture.tl:9:2
    oracle_expect_needle primary-location-is-not-diagnostic 1 wrong-diagnostic fixture.tl:3:1
    printf 'error[E0100]: one\n  --> fixture.tl:3:1\nerror[E0100]: two\n  --> other.tl:1:1\n  --> fixture.tl:9:2\n' > "$oracle_err"
    oracle_expect_needle related-location-other-diagnostic 1 wrong-diagnostic fixture.tl:9:2
    printf 'error[E0100]: parse error\n  --> fixture.tl:3:1\nerror[E0214]: intended move\n  --> other.tl:1:1\n' > "$oracle_err"
    oracle_expect mismatched-diagnostic-blocks 1 wrong-diagnostic
    printf 'error[E0200]: intended move\n  --> fixture.tl:3:1\n' > "$oracle_err"
    oracle_expect generic-taxonomy 1 wrong-diagnostic
    printf 'error[E0214]: intended move __tl_tc_transport\n  --> fixture.tl:3:1\n' > "$oracle_err"
    oracle_expect undecoded-transport 1 wrong-diagnostic
    : > "$oracle_err"
    oracle_expect empty 1 wrong-diagnostic
    oracle_diagnostic /absolute/root/fixture.tl:3:1
    oracle_expect absolute-path 1 rejected-invalid
    oracle_diagnostic 'C:\root\fixture.tl:3:1'
    oracle_expect windows-path 1 rejected-invalid
    # Exercise the actual subprocess status/stream capture as well as planted
    # observations. Disable core dumps for the deliberately aborted child.
    run_case "$oracle_out" "$oracle_err" - sh -c '
        ulimit -c 0
        printf "error[E0214]: intended move\n  --> fixture.tl:3:1\n" >&2
        kill -ABRT $$
    ' 2> "$WORKDIR/oracle-subprocess-driver.err"
    oracle_expect subprocess-diagnostic-then-abort "$code" compiler-crash
    # Every converted production-source row retains its exact primary span.
    # Plant the expected diagnostic, then alter only its line or column.
    while IFS='|' read -r anchor_id anchor_mode anchor_source anchor_location anchor_needle; do
        case "$anchor_location" in @loc\{*) ;; *) continue ;; esac
        anchor_expected=$(resolve_source_locations "$anchor_location") || fail "$anchor_id invalid source anchor"
        anchor_column=${anchor_expected##*:}
        anchor_prefix=${anchor_expected%:*}
        anchor_line=${anchor_prefix##*:}
        anchor_path=${anchor_prefix%:*}
        for anchor_mutation in correct wrong-line wrong-column; do
            anchor_actual=$anchor_expected
            case "$anchor_mutation" in
                wrong-line) anchor_actual=$anchor_path:$((anchor_line + 1)):$anchor_column ;;
                wrong-column) anchor_actual=$anchor_path:$anchor_line:$((anchor_column + 1)) ;;
            esac
            printf 'error[E0206]: %s\n  --> %s\n' "$anchor_needle" "$anchor_actual" > "$oracle_err"
            anchor_observation=$(classify_check_rejection 1 "$oracle_out" "$oracle_err" "$anchor_expected" "$anchor_needle")
            anchor_want=wrong-diagnostic
            [ "$anchor_mutation" != correct ] || anchor_want=rejected-invalid
            [ "$anchor_observation" = "$anchor_want" ] || fail "$anchor_id $anchor_mutation: $anchor_observation"
            oracle_count=$((oracle_count + 1))
        done
    done < "$NORMALIZED_MANIFEST"
    echo "safety rejection oracle passed $oracle_count mutation/control cases"
}

manifest_runner_self_test
source_location_self_test "$WORKDIR/source-location-self-test"
rejection_oracle_self_test
if [ "$SELF_TEST_ONLY" = true ]; then
    exit 0
fi
prepare_tools
# wide_struct_literal_reject imports the generated wide-struct declarations.
awk -f tests/integration/wide_struct_literal_decls.awk > "$WORKDIR/wide_struct_literal_decls.tl"
mv "$WORKDIR/wide_struct_literal_decls.tl" tests/integration/wide_struct_literal_decls.tl
expected_cases=$(awk -F '|' '
    !/^#/ && NF {
        if (NF != 5 || $1 == "" || seen[$1]++) invalid = 1
        count++
    }
    END { if (invalid) exit 1; print count + 0 }
' "$NORMALIZED_MANIFEST") || fail "infrastructure-resource-failure: malformed or duplicate manifest row"
[ "$expected_cases" -gt 0 ] || fail "infrastructure-resource-failure: manifest contains no cases"
build_selfhost_checker
for_each_manifest_case "$NORMALIZED_MANIFEST" run_manifest_case
[ "$checked" -eq "$expected_cases" ] || fail "infrastructure-resource-failure: executed $checked of $expected_cases cases"

echo "safety corpus verification passed for $checked case(s)"
