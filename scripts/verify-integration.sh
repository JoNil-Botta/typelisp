#!/usr/bin/env sh
set -eu

# verify-integration.sh - manifest-driven native integration runner.
# Linux is implemented first for the no-Rust CI transition (#847). Windows
# platform cases still need an equivalent host-aware wrapper around build/run.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

case "$(uname -s)" in
    Linux*) ;;
    *)
        echo "integration verification is currently implemented for Linux only (#847)" >&2
        exit 1
        ;;
esac

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    cargo build --release --quiet
    COMPILER="$ROOT/target/release/typelisp"
fi

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

command -v as >/dev/null 2>&1 || {
    echo "missing assembler: as" >&2
    exit 1
}
command -v ld >/dev/null 2>&1 || {
    echo "missing linker: ld" >&2
    exit 1
}

MANIFEST="$ROOT/tests/integration/native-linux.manifest"
WORKDIR="$ROOT/target/integration-verify"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

validate_manifest() {
    _cases="$WORKDIR/manifest-cases.txt"
    _known="$WORKDIR/manifest-known.txt"
    _dupes="$WORKDIR/manifest-dupes.txt"
    _actual="$WORKDIR/integration-sources.txt"
    _line_no=0
    : > "$_cases"
    : > "$_known"

    while IFS= read -r _line || [ -n "$_line" ]; do
        _line_no=$((_line_no + 1))
        case "$_line" in
            "" | \#*) continue ;;
        esac

        _fields=$(printf '%s\n' "$_line" | awk -F'|' '{ print NF }')
        if [ "$_fields" -ne 5 ]; then
            echo "manifest line $_line_no must have 5 fields: $_line" >&2
            exit 1
        fi

        IFS='|' read -r _name _want _stdout_esc _runtime_args _deps <<EOF
$_line
EOF

        case "$_name" in
            "" | *[!A-Za-z0-9_]*)
                echo "manifest line $_line_no has invalid case name: $_name" >&2
                exit 1
                ;;
        esac
        case "$_want" in
            "" | *[!0-9]*)
                echo "manifest line $_line_no has invalid exit code for $_name: $_want" >&2
                exit 1
                ;;
        esac
        if [ ! -f "$ROOT/tests/integration/$_name.tl" ]; then
            echo "manifest line $_line_no names missing integration source: $_name.tl" >&2
            exit 1
        fi

        printf '%s\n' "$_name" >> "$_cases"
        printf '%s\n' "$_name" >> "$_known"
        for _dep in $_deps; do
            case "$_dep" in
                stdlib/*) ;;
                *)
                    if [ -f "$ROOT/tests/integration/$_dep" ]; then
                        printf '%s\n' "${_dep%.tl}" >> "$_known"
                    fi
                    ;;
            esac
        done
    done < "$MANIFEST"

    sort "$_cases" | uniq -d > "$_dupes"
    if [ -s "$_dupes" ]; then
        echo "manifest has duplicate integration case(s):" >&2
        sed 's/^/  /' "$_dupes" >&2
        exit 1
    fi

    find tests/integration -maxdepth 1 -type f -name '*.tl' |
        sed 's#^tests/integration/##; s#\.tl$##' | sort > "$_actual"
    sort -u "$_known" > "$_known.sorted"
    if ! cmp -s "$_actual" "$_known.sorted"; then
        echo "integration manifest is out of date" >&2
        echo "every tests/integration/*.tl file must be a manifest case or declared dependency" >&2
        if command -v diff >/dev/null 2>&1; then
            diff -u "$_known.sorted" "$_actual" >&2 || true
        fi
        exit 1
    fi
}

copy_dep() {
    _dep=$1
    _case_dir=$2
    case "$_dep" in
        format_doc.tl | format_cst.tl | format_core.tl | format_rules.tl | format_tokens.tl)
            _src="$ROOT/selfhost/$_dep"
            _dst="$_case_dir/$_dep"
            ;;
        sym_i64_env_core.tl)
            _src="$ROOT/selfhost/sym_i64_env.tl"
            _dst="$_case_dir/$_dep"
            ;;
        text_buf_core.tl)
            _src="$ROOT/selfhost/text_buf.tl"
            _dst="$_case_dir/$_dep"
            ;;
        stdlib/*)
            _src="$ROOT/$_dep"
            _dst="$_case_dir/$_dep"
            ;;
        *)
            _src="$ROOT/tests/integration/$_dep"
            _dst="$_case_dir/$_dep"
            ;;
    esac

    if [ ! -f "$_src" ]; then
        echo "missing integration dependency: $_dep" >&2
        exit 1
    fi
    mkdir -p "$(dirname -- "$_dst")"
    cp "$_src" "$_dst"
}

validate_manifest

failed=0
ran=0

while IFS='|' read -r name want stdout_esc runtime_args deps || [ -n "$name" ]; do
    case "$name" in
        "" | \#*) continue ;;
    esac

    src="$ROOT/tests/integration/$name.tl"
    if [ ! -f "$src" ]; then
        echo "missing integration source: $src" >&2
        exit 1
    fi

    case_dir="$WORKDIR/$name"
    mkdir -p "$case_dir"
    work_src="$case_dir/$name.tl"
    cp "$src" "$work_src"

    for dep in $deps; do
        copy_dep "$dep" "$case_dir"
    done

    asm="$case_dir/$name.s"
    obj="$case_dir/$name.o"
    bin="$case_dir/$name"
    stdout="$case_dir/$name.stdout"
    stderr="$case_dir/$name.stderr"
    expected_stdout="$case_dir/$name.expected.stdout"

    echo "[$name] compile -> assemble -> link -> run"
    if ! "$COMPILER" compile "$work_src" -o "$asm"; then
        echo "FAIL: $name compile failed" >&2
        failed=$((failed + 1))
        continue
    fi
    if ! as "$asm" -o "$obj"; then
        echo "FAIL: $name assemble failed" >&2
        failed=$((failed + 1))
        continue
    fi
    if ! ld "$obj" -o "$bin" -dynamic-linker /lib64/ld-linux-x86-64.so.2 -lc; then
        echo "FAIL: $name link failed" >&2
        failed=$((failed + 1))
        continue
    fi

    set +e
    # shellcheck disable=SC2086
    "$bin" $runtime_args > "$stdout" 2> "$stderr"
    got=$?
    set -e

    printf '%b' "$stdout_esc" > "$expected_stdout"

    case_failed=0
    if [ "$got" -ne "$want" ]; then
        echo "FAIL: $name expected exit $want, got $got" >&2
        case_failed=1
    fi
    if ! cmp -s "$expected_stdout" "$stdout"; then
        echo "FAIL: $name stdout mismatch" >&2
        if command -v diff >/dev/null 2>&1; then
            diff -u "$expected_stdout" "$stdout" >&2 || true
        fi
        case_failed=1
    fi
    if [ -s "$stderr" ]; then
        echo "FAIL: $name wrote stderr" >&2
        sed 's/^/  /' "$stderr" >&2
        case_failed=1
    fi

    if [ "$case_failed" -eq 0 ]; then
        echo "PASS: $name"
    else
        failed=$((failed + 1))
    fi
    ran=$((ran + 1))
done < "$MANIFEST"

if [ "$failed" -gt 0 ]; then
    echo "$failed integration case(s) failed out of $ran" >&2
    exit 1
fi

echo "All $ran integration case(s) passed."
