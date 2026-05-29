#!/usr/bin/env sh
set -eu

# verify-windows-selfhost-msvc-link.sh - Windows no-Rust selfhost build/run
# smoke for the MSVC link.exe path (#860).

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

HOST_OS=linux
case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    Linux*) HOST_OS=linux ;;
    *)
        echo "windows selfhost MSVC link smoke is unsupported on this host: $(uname -s)" >&2
        exit 1
        ;;
esac

if [ "$HOST_OS" != windows ]; then
    echo "windows selfhost MSVC link smoke is Windows-only"
    exit 0
fi

COMPILER=${TYPELISP_BIN:-}
if [ -z "$COMPILER" ]; then
    echo "windows selfhost MSVC link smoke requires TYPELISP_BIN" >&2
    exit 1
fi
if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

WORKDIR="$ROOT/target/windows-selfhost-msvc-link"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

SRC="$WORKDIR/tiny.tl"
BIN="$WORKDIR/tiny.exe"

cat > "$SRC" <<'EOF'
(define (main) : i64
  42)
EOF

fail() {
    echo "$*" >&2
    exit 1
}

to_unix_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -u "$1"
    else
        printf '%s\n' "$1"
    fi
}

to_windows_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$1"
    else
        printf '%s\n' "$1"
    fi
}

short_windows_path() {
    win_path=$(to_windows_path "$1")
    if command -v cmd.exe >/dev/null 2>&1; then
        short_path=$(TYPELISP_SHORT_PATH_INPUT="$win_path" MSYS2_ARG_CONV_EXCL='*' \
            cmd.exe /C 'for %I in ("%TYPELISP_SHORT_PATH_INPUT%") do @echo %~sI' |
            tr -d '\r' |
            sed -n '1p')
        if [ -n "$short_path" ]; then
            printf '%s\n' "$short_path"
            return 0
        fi
    fi
    printf '%s\n' "$win_path"
}

find_clang() {
    if command -v clang.exe >/dev/null 2>&1; then
        command -v clang.exe
        return 0
    fi
    if command -v clang >/dev/null 2>&1; then
        command -v clang
        return 0
    fi

    for candidate_dir in \
        "/c/Program Files/LLVM/bin" \
        "/c/Program Files/Microsoft Visual Studio/2022/Enterprise/VC/Tools/Llvm/x64/bin" \
        "/c/Program Files/Microsoft Visual Studio/2022/Professional/VC/Tools/Llvm/x64/bin" \
        "/c/Program Files/Microsoft Visual Studio/2022/Community/VC/Tools/Llvm/x64/bin" \
        "/c/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/VC/Tools/Llvm/x64/bin"; do
        if [ -x "$candidate_dir/clang.exe" ]; then
            printf '%s\n' "$candidate_dir/clang.exe"
            return 0
        fi
    done

    if command -v powershell.exe >/dev/null 2>&1; then
        ps_clang=$(powershell.exe -NoProfile -Command '$cmd = Get-Command clang.exe -ErrorAction SilentlyContinue; if ($cmd) { $cmd.Source }' |
            tr -d '\r' |
            sed -n '1p')
        if [ -n "$ps_clang" ]; then
            to_unix_path "$ps_clang"
            return 0
        fi
    fi

    return 1
}

assert_empty() {
    file=$1
    [ ! -s "$file" ] || {
        echo "expected empty file: $file" >&2
        sed 's/^/  /' "$file" >&2 || true
        exit 1
    }
}

assert_contains() {
    file=$1
    needle=$2
    if ! grep -qF "$needle" "$file"; then
        echo "expected '$needle' in $file" >&2
        sed 's/^/  /' "$file" >&2 || true
        exit 1
    fi
}

if [ -z "${TYPELISP_WINDOWS_CLANG:-}" ]; then
    CLANG_PATH=$(find_clang || true)
    if [ -z "$CLANG_PATH" ]; then
        fail "missing assembler: clang"
    fi
    TYPELISP_WINDOWS_CLANG=$(short_windows_path "$CLANG_PATH")
fi
case "$TYPELISP_WINDOWS_CLANG" in
    *" "*) fail "assembler path contains spaces after short-path conversion: $TYPELISP_WINDOWS_CLANG" ;;
esac
export TYPELISP_WINDOWS_CLANG
echo "[windows-selfhost-msvc] assembler=$TYPELISP_WINDOWS_CLANG"

echo "[windows-selfhost-msvc] build --direct"
if ! "$COMPILER" run "$ROOT/selfhost/build.tl" --stdlib-root "$ROOT/stdlib" -- \
    --direct "$SRC" --target windows-x86_64 -o "$BIN" --stdlib-root "$ROOT/stdlib" \
    > "$WORKDIR/build.stdout" 2> "$WORKDIR/build.stderr"; then
    sed 's/^/  /' "$WORKDIR/build.stdout" >&2 || true
    sed 's/^/  /' "$WORKDIR/build.stderr" >&2 || true
    fail "selfhost build --direct failed"
fi
assert_contains "$WORKDIR/build.stdout" "Generated: $BIN"
assert_empty "$WORKDIR/build.stderr"
[ -x "$BIN" ] || fail "selfhost build did not write executable $BIN"

set +e
"$BIN" > "$WORKDIR/built.stdout" 2> "$WORKDIR/built.stderr"
built_status=$?
set -e
if [ "$built_status" -ne 42 ]; then
    sed 's/^/  /' "$WORKDIR/built.stdout" >&2 || true
    sed 's/^/  /' "$WORKDIR/built.stderr" >&2 || true
    fail "built executable expected exit 42, got $built_status"
fi
assert_empty "$WORKDIR/built.stdout"
assert_empty "$WORKDIR/built.stderr"

echo "[windows-selfhost-msvc] run --direct"
set +e
"$COMPILER" run "$ROOT/selfhost/run.tl" --stdlib-root "$ROOT/stdlib" -- \
    --direct "$SRC" --target windows-x86_64 --stdlib-root "$ROOT/stdlib" \
    > "$WORKDIR/run.stdout" 2> "$WORKDIR/run.stderr"
run_status=$?
set -e
if [ "$run_status" -ne 42 ]; then
    sed 's/^/  /' "$WORKDIR/run.stdout" >&2 || true
    sed 's/^/  /' "$WORKDIR/run.stderr" >&2 || true
    fail "selfhost run --direct expected exit 42, got $run_status"
fi
assert_empty "$WORKDIR/run.stdout"
assert_empty "$WORKDIR/run.stderr"

echo "windows selfhost MSVC link smoke passed"
