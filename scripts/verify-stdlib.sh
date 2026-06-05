#!/usr/bin/env sh
set -eu

# verify-stdlib.sh - verify canonical stdlib modules through --stdlib-root.
# refs #285, #814, #863

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

usage() {
    cat >&2 <<'EOF'
usage: scripts/verify-stdlib.sh [--borrowed-str-only]

Verifies canonical stdlib modules and fixtures through --stdlib-root.
Set TYPELISP_STDLIB_BORROWED_STR_BIN to route fixtures marked
requires-borrowed-str-capable through a compiler path that can parse/check
`(& lifetime str)` signatures, such as the Linux no-Rust bootstrapped stage1.
In full mode, marked rows run through TYPELISP_BIN unless this override is set.
EOF
}

BORROWED_STR_ONLY=0
case "$#" in
    0) ;;
    1)
        case "$1" in
            --borrowed-str-only) BORROWED_STR_ONLY=1 ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                usage
                exit 2
                ;;
        esac
        ;;
    *)
        usage
        exit 2
        ;;
esac

# Linux verifies through the GNU `as`/`ld` pipeline with libc linked for stdlib
# host FFI bindings; Windows (Git Bash / MSYS / Cygwin on the CI runner)
# verifies through the host-default native toolchain (`typelisp build` ->
# `clang`/`lld-link`), mirroring tests/windows_native.rs.
HOST_OS=linux
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    *)
        echo "stdlib verification is unsupported on this host" >&2
        exit 1
        ;;
esac

. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host
STDLIB_NATIVE_LINK_CONFIGURED=0
STDLIB_ORIGINAL_LIB_SET=0
STDLIB_ORIGINAL_INCLUDE_SET=0
STDLIB_ORIGINAL_LIB=
STDLIB_ORIGINAL_INCLUDE=
if [ "${LIB+x}" = x ]; then
    STDLIB_ORIGINAL_LIB_SET=1
    STDLIB_ORIGINAL_LIB=$LIB
fi
if [ "${INCLUDE+x}" = x ]; then
    STDLIB_ORIGINAL_INCLUDE_SET=1
    STDLIB_ORIGINAL_INCLUDE=$INCLUDE
fi

stdlib_configure_native_link() {
    if [ "$STDLIB_NATIVE_LINK_CONFIGURED" -eq 0 ]; then
        configure_toolchain
        STDLIB_NATIVE_LINK_CONFIGURED=1
    fi
}

stdlib_restore_fixture_tool_env() {
    if [ "$HOST_OS" = windows ]; then
        if [ "$STDLIB_ORIGINAL_LIB_SET" -eq 1 ]; then
            LIB=$STDLIB_ORIGINAL_LIB
            export LIB
        else
            unset LIB
        fi
        if [ "$STDLIB_ORIGINAL_INCLUDE_SET" -eq 1 ]; then
            INCLUDE=$STDLIB_ORIGINAL_INCLUDE
            export INCLUDE
        else
            unset INCLUDE
        fi
    fi
}

stdlib_run_fixture_binary() {
    _bin=$1
    _stdin=$2
    _stdout=$3
    _stderr=$4
    (
        stdlib_restore_fixture_tool_env
        "$_bin" < "$_stdin" > "$_stdout" 2> "$_stderr"
    )
}

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    # No-Rust fallback for local development: fetch the published
    # self-hosted stage0 (CI always passes a compiler via TYPELISP_BIN).
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi
BORROWED_STR_COMPILER=$COMPILER
BORROWED_STR_COMPILER_EXPLICIT=0
if [ -n "${TYPELISP_STDLIB_BORROWED_STR_BIN:-}" ]; then
    BORROWED_STR_COMPILER=$TYPELISP_STDLIB_BORROWED_STR_BIN
    BORROWED_STR_COMPILER_EXPLICIT=1
fi

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi
if { [ "$BORROWED_STR_COMPILER_EXPLICIT" -eq 1 ] || [ "$BORROWED_STR_ONLY" -eq 1 ]; } &&
    [ ! -x "$BORROWED_STR_COMPILER" ]; then
    echo "borrowed-str capable compiler is not executable: $BORROWED_STR_COMPILER" >&2
    exit 1
fi

# Build a fixture .tl to a runnable binary (host-aware). Linux uses GNU as/ld;
# Windows builds a native executable via clang/lld-link. Build/link output is
# captured to <stem>.build.out / <stem>.build.err and `build_status` is set.
stdlib_build_fixture() {
    _src=$1
    _stem=$2
    build_status=0
    : > "$_stem.build.err"
    stdlib_configure_native_link
    set +e
    "$COMPILER" compile "$_src" --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) \
        --stdlib-root "$ROOT/stdlib" -o "$_stem.s" \
        > "$_stem.build.out" 2> "$_stem.build.err"
    build_status=$?
    if [ "$build_status" -eq 0 ]; then
        assemble_and_link "$_src" "$_stem.s" "$_stem.$NL_OBJ_EXT" "$_stem$NL_BIN_EXT" \
            >> "$_stem.build.out" 2>> "$_stem.build.err"
        build_status=$?
    fi
    set -e
}

# Build a fixture .tl to a runnable binary and run it with the supplied stdin
# file, capturing the program exit code in `got` and writing program
# stdout/stderr to <stem>.stdout / <stem>.stderr.
stdlib_build_run() {
    _src=$1
    _stem=$2
    _stdin=$3
    stdlib_build_fixture "$_src" "$_stem"
    if [ "$build_status" -eq 0 ]; then
        set +e
        stdlib_run_fixture_binary "$_stem$NL_BIN_EXT" "$_stdin" "$_stem.stdout" "$_stem.stderr"
        got=$?
        set -e
    fi
}

stdlib_runtime_gap_applies() {
    _gap_host=$1
    _host=$2
    [ "$_gap_host" = all ] || [ "$_gap_host" = "$_host" ]
}

should_skip_staged() {
    _symbols=$1
    shift
    [ -n "$_symbols" ] || return 1
    for _symbol in $(printf '%s\n' "$_symbols" | tr ',' ' '); do
        for _stream in "$@"; do
            grep -qF "$_symbol" "$_stream" && return 0
        done
    done
    return 1
}

# Every canonical stdlib module must be listed here. Keep this manifest in sync
# with stdlib/README.md so new modules land with an explicit verification
# decision. Fixture files under stdlib/tests/ are covered by stdlib_test_manifest
# or stdlib_check_manifest.
stdlib_manifest() {
    cat <<'EOF'
arena.tl
io.tl
env.tl
cpu.tl
fs.tl
ffi.tl
hash.tl
hashmap.tl
json.tl
list.tl
msvc.tl
process.tl
queue.tl
random.tl
string.tl
test.tl
text_buf.tl
vector.tl
windows_registry.tl
windows_sdk.tl
windows_setup.tl
EOF
}

# Pipe-separated fixture manifest:
#   fixture-path|expected-exit|expected-stdout|expected-stderr|stdin|optional-capability
#
# Use "-" for an empty stream, "literal:<text>" for exact inline text without a
# trailing newline, "printf:<escapes>" for printf-style escapes, "host-line:<text>"
# for one line using the host executable's newline convention, or a
# repository-relative path for exact stream bytes. The stdin and capability
# columns are optional; stdin defaults to "-". A runnable row may use
# `requires-stage0-symbol:<name>[,<name>...]` or
# `requires-runtime-gap:<host>:#NNNN:<stderr-substring>` only as metadata. These
# markers do not make failures pass; CI must run the row and fail on regression.
# `<host>` is `linux`, `windows`, or `all`.
stdlib_test_manifest() {
    cat <<'EOF'
stdlib/tests/arena_api.tl|42|-|-
stdlib/tests/string_edges.tl|42|-|-
stdlib/tests/json_helpers.tl|42|-|-
stdlib/tests/json_parse_stringify.tl|42|-|-
stdlib/tests/io_edges.tl|42|-|-|-|requires-stage0-symbol:file-read-chunk-status,file-write-status,file-flush-status,append-file-status
stdlib/tests/io_file_handle.tl|42|-|-|-|requires-stage0-symbol:file-read-chunk-status,file-write-status,file-flush-status,append-file-status,fs-file-kind-status,fs-file-size-status,fs-file-size
stdlib/tests/io_stdio_lines.tl|42|host-line:stdout-line|host-line:stderr-line|printf:alpha\n\nomega|requires-stage0-symbol:file-read-chunk-status,file-write-status,file-flush-status,append-file-status
stdlib/tests/io_stdio_bytes.tl|42|-|-|literal:abcdef|requires-stage0-symbol:file-read-chunk-status,file-write-status,file-flush-status,append-file-status
stdlib/tests/env_api.tl|42|-|-
stdlib/tests/ffi_api.tl|42|-|-
stdlib/tests/cpu_api.tl|42|-|-
stdlib/tests/fs_api.tl|42|-|-|-|requires-stage0-symbol:file-read-chunk-status,file-write-status,file-flush-status,append-file-status,fs-rename-status,fs-read-dir-status,fs-read-dir,fs-file-kind-status,fs-file-size-status,fs-file-size
stdlib/tests/hash_api.tl|42|-|-
stdlib/tests/hashmap_api.tl|42|-|-
stdlib/tests/list_api.tl|42|-|-
stdlib/tests/process_api.tl|42|-|-|-|requires-stage0-symbol:tl_process_start,tl_process_wait
stdlib/tests/process_runtime.tl|42|-|-
stdlib/tests/queue_api.tl|42|-|-
stdlib/tests/random_api.tl|42|-|-|-|requires-stage0-symbol:tl_random_system_seed
stdlib/tests/text_buf_api.tl|42|-|-
stdlib/tests/vector_api.tl|42|-|-
stdlib/tests/visual_studio_api.tl|42|-|-
stdlib/tests/test_assert_success.tl|42|-|-
stdlib/tests/test_assert_failure.tl|134|-|literal:stdlib test failure message
stdlib/tests/windows_registry_api.tl|42|-|-|-|requires-stage0-symbol:tl_windows_sdk_registry_install
stdlib/tests/windows_sdk_api.tl|42|-|-|-|requires-stage0-symbol:file-read-chunk-status,file-write-status,file-flush-status,append-file-status,tl_windows_sdk_registry_install
stdlib/tests/msvc_api.tl|42|-|-|-|requires-stage0-symbol:file-read-chunk-status,file-write-status,file-flush-status,append-file-status,fs-file-kind-status,fs-file-size-status,fs-file-size,tl_windows_sdk_registry_install
EOF
}

# Pipe-separated check-only fixture manifest:
#   fixture-path|expected-status|expected-stderr-snippet|optional-capability
#
# Use these for stdlib fixtures that only need the typechecker, including
# platform-independent with-arena policy tests. The expected status is `fail`
# or `pass`; failure rows must include a diagnostic substring that should
# appear on stderr. Pass rows may use "-" for the diagnostic field. A row marked
# `requires-borrowed-str-capable` runs through TYPELISP_STDLIB_BORROWED_STR_BIN
# when it is set, allowing no-Rust gates to use the bootstrapped stage1 for source
# that the published seed compiler cannot parse yet.
stdlib_check_manifest() {
    cat <<'EOF'
stdlib/tests/arena_policy.tl|pass|-
stdlib/tests/arena_policy_escape_string.tl|fail|cannot escape with-arena 'inner'
stdlib/tests/arena_policy_escape_text_buf.tl|fail|cannot escape with-arena 'inner'
stdlib/tests/io_stdio_pipe_short_read.tl|pass|-
stdlib/tests/borrowed_str_gate.tl|pass|-|requires-borrowed-str-capable
EOF
}

WORKDIR="$ROOT/target/stdlib-verify"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

EXPECTED="$WORKDIR/expected-stdlib-files.txt"
ACTUAL="$WORKDIR/actual-stdlib-files.txt"

stdlib_manifest | sort > "$EXPECTED"
find stdlib -type f -name '*.tl' ! -path 'stdlib/tests/*' |
    sed 's#^stdlib/##' |
    sort > "$ACTUAL"

if ! cmp -s "$EXPECTED" "$ACTUAL"; then
    echo "stdlib verification manifest is out of date" >&2
    echo "expected modules:" >&2
    sed 's/^/  /' "$EXPECTED" >&2
    echo "actual modules:" >&2
    sed 's/^/  /' "$ACTUAL" >&2
    if command -v diff >/dev/null 2>&1; then
        diff -u "$EXPECTED" "$ACTUAL" >&2 || true
    fi
    exit 1
fi

TEST_MANIFEST="$WORKDIR/stdlib-test-manifest.psv"
CHECK_MANIFEST="$WORKDIR/stdlib-check-manifest.psv"
TEST_EXPECTED="$WORKDIR/expected-stdlib-tests.txt"
TEST_ACTUAL="$WORKDIR/actual-stdlib-tests.txt"

stdlib_test_manifest > "$TEST_MANIFEST"
stdlib_check_manifest > "$CHECK_MANIFEST"
{
    sed '/^#/d;/^$/d;s/|.*$//' "$TEST_MANIFEST"
    sed '/^#/d;/^$/d;s/|.*$//' "$CHECK_MANIFEST"
} | sort > "$TEST_EXPECTED"
find stdlib/tests -type f -name '*.tl' | sort > "$TEST_ACTUAL"

if ! cmp -s "$TEST_EXPECTED" "$TEST_ACTUAL"; then
    echo "stdlib test manifest is out of date" >&2
    echo "expected fixtures:" >&2
    sed 's/^/  /' "$TEST_EXPECTED" >&2
    echo "actual fixtures:" >&2
    sed 's/^/  /' "$TEST_ACTUAL" >&2
    if command -v diff >/dev/null 2>&1; then
        diff -u "$TEST_EXPECTED" "$TEST_ACTUAL" >&2 || true
    fi
    exit 1
fi

show_streams() {
    _stdout=$1
    _stderr=$2
    if [ -s "$_stdout" ]; then
        echo "stdout:" >&2
        sed 's/^/  /' "$_stdout" >&2
    fi
    if [ -s "$_stderr" ]; then
        echo "stderr:" >&2
        sed 's/^/  /' "$_stderr" >&2
    fi
}

compare_stream() {
    _case=$1
    _kind=$2
    _spec=$3
    _actual=$4
    _stdout=$5
    _stderr=$6

    if [ "$_spec" = "-" ]; then
        if [ -s "$_actual" ]; then
            echo "FAIL: $_case wrote unexpected $_kind" >&2
            show_streams "$_stdout" "$_stderr"
            exit 1
        fi
        return
    fi

    case "$_spec" in
        literal:*)
            _expected_literal=${_spec#literal:}
            if ! printf '%s' "$_expected_literal" | cmp -s - "$_actual"; then
                echo "FAIL: $_case $_kind differed from inline literal expectation" >&2
                show_streams "$_stdout" "$_stderr"
                exit 1
            fi
            return
            ;;
        printf:*)
            _expected_printf=${_spec#printf:}
            if ! printf '%b' "$_expected_printf" | cmp -s - "$_actual"; then
                echo "FAIL: $_case $_kind differed from inline printf expectation" >&2
                show_streams "$_stdout" "$_stderr"
                exit 1
            fi
            return
            ;;
        host-line:*)
            _expected_line=${_spec#host-line:}
            if [ "$HOST_OS" = windows ]; then
                if ! printf '%s\r\n' "$_expected_line" | cmp -s - "$_actual"; then
                    echo "FAIL: $_case $_kind differed from host-line expectation" >&2
                    show_streams "$_stdout" "$_stderr"
                    exit 1
                fi
            else
                if ! printf '%s\n' "$_expected_line" | cmp -s - "$_actual"; then
                    echo "FAIL: $_case $_kind differed from host-line expectation" >&2
                    show_streams "$_stdout" "$_stderr"
                    exit 1
                fi
            fi
            return
            ;;
    esac

    _expected="$ROOT/$_spec"
    if [ ! -f "$_expected" ]; then
        echo "FAIL: $_case expected $_kind fixture is missing: $_spec" >&2
        exit 1
    fi

    if ! cmp -s "$_expected" "$_actual"; then
        echo "FAIL: $_case $_kind differed from $_spec" >&2
        if command -v diff >/dev/null 2>&1; then
            diff -u "$_expected" "$_actual" >&2 || true
        else
            show_streams "$_stdout" "$_stderr"
        fi
        exit 1
    fi
}

materialize_stream() {
    _case=$1
    _kind=$2
    _spec=$3
    _output=$4

    if [ "$_spec" = "-" ]; then
        : > "$_output"
        return
    fi

    case "$_spec" in
        literal:*)
            printf '%s' "${_spec#literal:}" > "$_output"
            return
            ;;
        printf:*)
            printf '%b' "${_spec#printf:}" > "$_output"
            return
            ;;
        host-line:*)
            if [ "$HOST_OS" = windows ]; then
                printf '%s\r\n' "${_spec#host-line:}" > "$_output"
            else
                printf '%s\n' "${_spec#host-line:}" > "$_output"
            fi
            return
            ;;
    esac

    _source="$ROOT/$_spec"
    if [ ! -f "$_source" ]; then
        echo "FAIL: $_case $_kind fixture is missing: $_spec" >&2
        exit 1
    fi
    cp "$_source" "$_output"
}

TEST_COPY_ROOT="$WORKDIR/fixtures"
RUN_ROOT="$WORKDIR/run"
mkdir -p "$TEST_COPY_ROOT" "$RUN_ROOT"

PATH_SEP=:
[ "$HOST_OS" = windows ] && PATH_SEP=';'
export TYPELISP_STDLIB_TEST_EMPTY=
export TYPELISP_STDLIB_TEST_VALUE=env-value-854
export TYPELISP_STDLIB_TEST_PATH="one${PATH_SEP}two${PATH_SEP}three"

SDK_ROOT_POSIX="$WORKDIR/fake-windows-sdk"
SDK_VERSION=10.0.99999.0
mkdir -p \
    "$SDK_ROOT_POSIX/Include/$SDK_VERSION/ucrt" \
    "$SDK_ROOT_POSIX/Include/$SDK_VERSION/um" \
    "$SDK_ROOT_POSIX/Include/$SDK_VERSION/shared" \
    "$SDK_ROOT_POSIX/Lib/$SDK_VERSION/ucrt/x64" \
    "$SDK_ROOT_POSIX/Lib/$SDK_VERSION/um/x64" \
    "$SDK_ROOT_POSIX/bin/$SDK_VERSION/x64"
if [ "$HOST_OS" = windows ] && command -v cygpath >/dev/null 2>&1; then
    export WindowsSdkDir="$(cygpath -m "$SDK_ROOT_POSIX")"
else
    export WindowsSdkDir="$SDK_ROOT_POSIX"
fi
export WindowsSDKVersion="$SDK_VERSION"

passed=0
skipped=0
if [ "$BORROWED_STR_ONLY" -eq 0 ]; then
while IFS='|' read -r fixture want stdout_spec stderr_spec stdin_spec extra; do
    case "$fixture" in
        '' | \#*) continue ;;
    esac

    requires_symbol=
    runtime_gap_host=
    runtime_gap_issue=
    runtime_gap_stderr=
    case "${extra:-}" in
        '') ;;
        requires-stage0-symbol:*) requires_symbol=${extra#requires-stage0-symbol:} ;;
        requires-runtime-gap:*:#*:*)
            runtime_gap=${extra#requires-runtime-gap:}
            runtime_gap_host=${runtime_gap%%:*}
            runtime_gap_rest=${runtime_gap#*:}
            runtime_gap_issue=${runtime_gap_rest%%:*}
            runtime_gap_stderr=${runtime_gap_rest#*:}
            case "$runtime_gap_host" in
                linux | windows | all) ;;
                *)
                    echo "FAIL: malformed stdlib runtime gap host for $fixture: $extra" >&2
                    exit 1
                    ;;
            esac
            ;;
        requires-runtime-gap:*)
            echo "FAIL: malformed stdlib runtime gap marker for $fixture: $extra" >&2
            exit 1
            ;;
        *)
            echo "FAIL: malformed stdlib test manifest row has too many fields: $fixture" >&2
            exit 1
            ;;
    esac

    if [ -z "${stdin_spec:-}" ]; then
        stdin_spec=-
    fi

    if [ -z "$want" ] || [ -z "$stdout_spec" ] || [ -z "$stderr_spec" ]; then
        echo "FAIL: malformed stdlib test manifest row: $fixture" >&2
        exit 1
    fi

    case "$fixture" in
        stdlib/tests/*.tl) ;;
        *)
            echo "FAIL: stdlib test fixture must live under stdlib/tests/: $fixture" >&2
            exit 1
            ;;
    esac

    if [ ! -f "$fixture" ]; then
        echo "FAIL: stdlib test fixture is missing: $fixture" >&2
        exit 1
    fi

    case_id=$(printf '%s' "$fixture" | sed 's#/#_#g;s#\.tl$##')
    copied="$TEST_COPY_ROOT/$fixture"
    mkdir -p "$(dirname "$copied")"
    cp "$fixture" "$copied"

    stem="$RUN_ROOT/$case_id"
    stdout="$stem.stdout"
    stderr="$stem.stderr"
    stdin="$stem.stdin"
    materialize_stream "$fixture" stdin "$stdin_spec" "$stdin"

    echo "[stdlib] building+running $fixture (--stdlib-root)"
    stdlib_build_run "$copied" "$stem" "$stdin"

    if [ "$build_status" -ne 0 ]; then
        if should_skip_staged "$requires_symbol" "$stem.build.err" "$stem.build.out"; then
            echo "[stdlib] SKIP $fixture (awaiting no-Rust compiler support for '$requires_symbol')"
            skipped=$((skipped + 1))
            continue
        fi
        echo "FAIL: $fixture failed to build" >&2
        sed 's/^/  /' "$stem.build.err" >&2 || true
        exit 1
    fi

    if [ -n "$requires_symbol" ]; then
        echo "[stdlib] NOTE: $fixture built with the current compiler; once the no-Rust compiler path provides '$requires_symbol', drop the requires-stage0-symbol marker" >&2
    fi

    if [ "$got" -ne "$want" ]; then
        echo "FAIL: $fixture expected exit $want, got $got" >&2
        show_streams "$stdout" "$stderr"
        exit 1
    fi

    compare_stream "$fixture" stdout "$stdout_spec" "$stdout" "$stdout" "$stderr"
    compare_stream "$fixture" stderr "$stderr_spec" "$stderr" "$stdout" "$stderr"
    if [ -n "$runtime_gap_issue" ] && stdlib_runtime_gap_applies "$runtime_gap_host" "$HOST_OS"; then
        echo "[stdlib] NOTE: $fixture passed with known runtime gap marker $runtime_gap_issue; remove the requires-runtime-gap marker" >&2
    fi

    passed=$((passed + 1))
done < "$TEST_MANIFEST"
fi

pipe_regressions=0
if [ "$BORROWED_STR_ONLY" -eq 0 ]; then
    fixture=stdlib/tests/io_stdio_pipe_short_read.tl
    copied="$TEST_COPY_ROOT/$fixture"
    stem="$RUN_ROOT/stdlib_tests_io_stdio_pipe_short_read.pipe"
    stdout="$stem.stdout"
    stderr="$stem.stderr"

    mkdir -p "$(dirname "$copied")"
    cp "$fixture" "$copied"

    echo "[stdlib] building+running $fixture through native pipe (--stdlib-root)"
    stdlib_build_fixture "$copied" "$stem"
    if [ "$build_status" -ne 0 ]; then
        echo "FAIL: $fixture pipe regression failed to build" >&2
        sed 's/^/  /' "$stem.build.err" >&2 || true
        exit 1
    fi

    set +e
    dd if=/dev/zero bs=4096 count=512 2>/dev/null |
        tr '\000' x |
        (
            stdlib_restore_fixture_tool_env
            "$stem$NL_BIN_EXT" > "$stdout" 2> "$stderr"
        )
    got=$?
    set -e

    if [ "$got" -ne 42 ]; then
        echo "FAIL: $fixture pipe regression expected exit 42, got $got" >&2
        show_streams "$stdout" "$stderr"
        exit 1
    fi
    compare_stream "$fixture pipe regression" stdout "-" "$stdout" "$stdout" "$stderr"
    compare_stream "$fixture pipe regression" stderr "-" "$stderr" "$stdout" "$stderr"
    pipe_regressions=1
fi

checked=0
while IFS='|' read -r fixture want stderr_snippet extra; do
    case "$fixture" in
        '' | \#*) continue ;;
    esac

    if [ -z "$want" ] || [ -z "$stderr_snippet" ]; then
        echo "FAIL: malformed stdlib check manifest row: $fixture" >&2
        exit 1
    fi

    case "$want" in
        pass) ;;
        fail)
            if [ "$stderr_snippet" = "-" ]; then
                echo "FAIL: failing stdlib check fixture needs a diagnostic: $fixture" >&2
                exit 1
            fi
            ;;
        *)
            echo "FAIL: stdlib check status must be pass or fail: $fixture" >&2
            exit 1
            ;;
    esac

    check_compiler=$COMPILER
    check_label=--stdlib-root
    borrowed_str_row=0
    case "${extra:-}" in
        '')
            ;;
        requires-borrowed-str-capable)
            check_compiler=$BORROWED_STR_COMPILER
            check_label="--stdlib-root, borrowed-str-capable"
            borrowed_str_row=1
            ;;
        *)
            echo "FAIL: malformed stdlib check manifest capability for $fixture: $extra" >&2
            exit 1
            ;;
    esac

    if [ "$BORROWED_STR_ONLY" -eq 1 ] && [ "$borrowed_str_row" -eq 0 ]; then
        continue
    fi
    case "$fixture" in
        stdlib/tests/*.tl) ;;
        *)
            echo "FAIL: stdlib check fixture must live under stdlib/tests/: $fixture" >&2
            exit 1
            ;;
    esac

    if [ ! -f "$fixture" ]; then
        echo "FAIL: stdlib check fixture is missing: $fixture" >&2
        exit 1
    fi

    case_id=$(printf '%s' "$fixture" | sed 's#/#_#g;s#\.tl$##')
    copied="$TEST_COPY_ROOT/$fixture"
    mkdir -p "$(dirname "$copied")"
    cp "$fixture" "$copied"

    stem="$RUN_ROOT/$case_id.check"
    stdout="$stem.stdout"
    stderr="$stem.stderr"

    echo "[stdlib] checking $fixture ($check_label)"
    set +e
    "$check_compiler" check "$copied" --stdlib-root "$ROOT/stdlib" \
        > "$stdout" 2> "$stderr"
    got=$?
    set -e

    if [ "$want" = pass ]; then
        if [ "$got" -ne 0 ]; then
            echo "FAIL: $fixture expected check success, got exit $got" >&2
            show_streams "$stdout" "$stderr"
            exit 1
        fi
    else
        if [ "$got" -eq 0 ]; then
            echo "FAIL: $fixture expected check failure, got success" >&2
            show_streams "$stdout" "$stderr"
            exit 1
        fi
        if ! grep -F "$stderr_snippet" "$stderr" >/dev/null 2>&1; then
            echo "FAIL: $fixture stderr did not contain expected diagnostic" >&2
            echo "expected substring: $stderr_snippet" >&2
            show_streams "$stdout" "$stderr"
            exit 1
        fi
    fi

    checked=$((checked + 1))
done < "$CHECK_MANIFEST"

if [ "$BORROWED_STR_ONLY" -eq 1 ]; then
    if [ "$checked" -eq 0 ]; then
        echo "stdlib borrowed-str verification did not run any fixture" >&2
        exit 1
    fi
    echo "stdlib borrowed-str verification passed for $checked check fixture(s)"
    exit 0
fi

module_count=$(wc -l < "$EXPECTED" | tr -d ' ')

echo "stdlib verification passed for $module_count module(s), $passed runnable fixture(s), $skipped staged fixture(s) skipped, $checked check fixture(s), $pipe_regressions pipe regression(s)"
