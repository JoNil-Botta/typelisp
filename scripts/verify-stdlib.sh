#!/usr/bin/env sh
set -eu

# verify-stdlib.sh - verify canonical stdlib modules through --stdlib-root.
# refs #285, #863

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

# Linux verifies through the GNU `as`/`ld` pipeline; Windows (Git Bash / MSYS /
# Cygwin on the CI runner) verifies through the native `windows-x86_64` toolchain
# (`typelisp build` -> `clang`/`lld-link`), mirroring tests/windows_native.rs.
HOST_OS=linux
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    *)
        echo "stdlib verification is unsupported on this host" >&2
        exit 1
        ;;
esac

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    cargo build --release --quiet
    COMPILER="$ROOT/target/release/typelisp"
    [ "$HOST_OS" = windows ] && COMPILER="$COMPILER.exe"
fi

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

# Build a fixture .tl to a runnable binary and run it (host-aware) with the
# supplied stdin file, capturing the program exit code in `got` and writing
# program stdout/stderr to <stem>.stdout / <stem>.stderr. Linux uses GNU as/ld;
# Windows builds a native windows-x86_64 executable via clang/lld-link. Callers
# pass the same <stem> they use for their .stdout/.stderr assertion paths.
stdlib_build_run() {
    _src=$1
    _stem=$2
    _stdin=$3
    if [ "$HOST_OS" = windows ]; then
        "$COMPILER" build "$_src" --stdlib-root "$ROOT/stdlib" -o "$_stem.exe" \
            --target windows-x86_64
        set +e
        "$_stem.exe" < "$_stdin" > "$_stem.stdout" 2> "$_stem.stderr"
        got=$?
        set -e
    else
        "$COMPILER" compile "$_src" --stdlib-root "$ROOT/stdlib" -o "$_stem.s"
        as "$_stem.s" -o "$_stem.o"
        ld "$_stem.o" -o "$_stem"
        set +e
        "$_stem" < "$_stdin" > "$_stem.stdout" 2> "$_stem.stderr"
        got=$?
        set -e
    fi
}

# Every canonical stdlib module must be listed here. Keep this manifest in sync
# with stdlib/README.md so new modules land with an explicit verification
# decision. Fixture files under stdlib/tests/ are covered by stdlib_test_manifest.
stdlib_manifest() {
    cat <<'EOF'
io.tl
env.tl
fs.tl
json.tl
process.tl
random.tl
string.tl
test.tl
text_buf.tl
EOF
}

# Pipe-separated fixture manifest:
#   fixture-path|expected-exit|expected-stdout|expected-stderr|stdin
#
# Use "-" for an empty stream, "literal:<text>" for exact inline text without a
# trailing newline, "printf:<escapes>" for printf-style escapes, "host-line:<text>"
# for one line using the host executable's newline convention, or a
# repository-relative path for exact stream bytes. The stdin column is optional
# and defaults to "-".
stdlib_test_manifest() {
    cat <<'EOF'
stdlib/tests/string_edges.tl|42|-|-
stdlib/tests/json_helpers.tl|42|-|-
stdlib/tests/json_parse_stringify.tl|42|-|-
stdlib/tests/io_edges.tl|42|-|-
stdlib/tests/io_stdio_lines.tl|42|host-line:stdout-line|host-line:stderr-line|printf:alpha\n\nomega
stdlib/tests/io_stdio_bytes.tl|42|-|-|literal:abcdef
stdlib/tests/env_api.tl|42|-|-
stdlib/tests/fs_api.tl|42|-|-
stdlib/tests/process_api.tl|42|-|-
stdlib/tests/process_runtime.tl|42|-|-
stdlib/tests/random_api.tl|42|-|-
stdlib/tests/text_buf_api.tl|42|-|-
stdlib/tests/test_assert_success.tl|42|-|-
stdlib/tests/test_assert_failure.tl|134|-|literal:stdlib test failure message
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
TEST_EXPECTED="$WORKDIR/expected-stdlib-tests.txt"
TEST_ACTUAL="$WORKDIR/actual-stdlib-tests.txt"

stdlib_test_manifest > "$TEST_MANIFEST"
sed '/^#/d;/^$/d;s/|.*$//' "$TEST_MANIFEST" | sort > "$TEST_EXPECTED"
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

passed=0
while IFS='|' read -r fixture want stdout_spec stderr_spec stdin_spec extra; do
    case "$fixture" in
        '' | \#*) continue ;;
    esac

    if [ -n "${extra:-}" ]; then
        echo "FAIL: malformed stdlib test manifest row has too many fields: $fixture" >&2
        exit 1
    fi

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

    if [ "$got" -ne "$want" ]; then
        echo "FAIL: $fixture expected exit $want, got $got" >&2
        show_streams "$stdout" "$stderr"
        exit 1
    fi

    compare_stream "$fixture" stdout "$stdout_spec" "$stdout" "$stdout" "$stderr"
    compare_stream "$fixture" stderr "$stderr_spec" "$stderr" "$stdout" "$stderr"

    passed=$((passed + 1))
done < "$TEST_MANIFEST"

module_count=$(wc -l < "$EXPECTED" | tr -d ' ')

echo "stdlib verification passed for $module_count module(s), $passed fixture(s)"
