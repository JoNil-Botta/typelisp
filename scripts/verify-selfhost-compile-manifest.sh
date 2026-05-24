#!/usr/bin/env sh
set -eu

# verify-selfhost-compile-manifest.sh - no-Rust assembly smoke coverage.
#
# The manifest lists TypeLisp sources that must compile to assembly plus fixed
# string assertions on that assembly. It also records explicit coverage
# decisions for root selfhost/*.tl modules that are imported or covered by a
# different entry, so new selfhost modules cannot silently bypass the no-Rust
# compile manifest.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

MANIFEST=${SELFHOST_COMPILE_MANIFEST:-selfhost/COMPILE_MANIFEST.txt}

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    cargo build --release --quiet
    COMPILER="$ROOT/target/release/typelisp"
    case "$(uname -s)" in
        MINGW* | MSYS* | CYGWIN*) COMPILER="$COMPILER.exe" ;;
    esac
fi

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

if [ ! -f "$MANIFEST" ]; then
    echo "selfhost compile manifest not found: $MANIFEST" >&2
    exit 1
fi

WORKDIR="$ROOT/target/selfhost-compile-manifest"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

contains_fixed() {
    file=$1
    needle=$2
    grep -F -- "$needle" "$file" >/dev/null 2>&1
}

count_fixed() {
    file=$1
    needle=$2
    awk -v pat="$needle" '
        BEGIN { count = 0 }
        {
            rest = $0
            while ((pos = index(rest, pat)) > 0) {
                count += 1
                rest = substr(rest, pos + length(pat))
            }
        }
        END { print count }
    ' "$file"
}

check_selfhost_inventory() {
    expected=$WORKDIR/expected-selfhost-sources.txt
    actual=$WORKDIR/actual-selfhost-sources.txt

    while IFS='|' read -r kind name first _rest; do
        case "$kind" in
            entry)
                case "$first" in selfhost/*.tl) echo "$first" ;; esac
                ;;
            stage)
                case "$first" in selfhost/*.tl) echo "$first" ;; esac
                ;;
            decision)
                case "$name" in selfhost/*.tl) echo "$name" ;; esac
                ;;
        esac
    done < "$MANIFEST" | sort -u > "$expected"

    find selfhost -maxdepth 1 -type f -name '*.tl' | sed 's#^\./##' | sort > "$actual"

    if ! cmp -s "$expected" "$actual"; then
        echo "selfhost compile manifest inventory is out of date" >&2
        echo "manifest entries/decisions:" >&2
        sed 's/^/  /' "$expected" >&2
        echo "root selfhost/*.tl files:" >&2
        sed 's/^/  /' "$actual" >&2
        if command -v diff >/dev/null 2>&1; then
            diff -u "$expected" "$actual" >&2 || true
        fi
        exit 1
    fi
}

compile_entry() {
    name=$1
    source=$2
    mode=$3
    main_policy=$4

    [ "$mode" = assembly ] || fail "$name has unsupported output mode: $mode"
    [ -f "$source" ] || fail "$name source does not exist: $source"

    entry_dir="$WORKDIR/$name"
    mkdir -p "$entry_dir"
    asm="$entry_dir/$name.s"
    stdout="$entry_dir/$name.stdout"
    stderr="$entry_dir/$name.stderr"
    compile_source=$source

    has_stage=0
    while IFS='|' read -r kind stage_name stage_source stage_dest _rest; do
        [ "$kind" = stage ] || continue
        [ "$stage_name" = "$name" ] || continue
        has_stage=1
        [ -f "$stage_source" ] || fail "$name stage source does not exist: $stage_source"
        mkdir -p "$entry_dir/$(dirname "$stage_dest")"
        cp "$stage_source" "$entry_dir/$stage_dest"
    done < "$MANIFEST"

    if [ "$has_stage" -eq 1 ]; then
        entry_base=$(basename "$source")
        cp "$source" "$entry_dir/$entry_base"
        compile_source="$entry_dir/$entry_base"
    fi

    echo "[selfhost-compile] $name -> $asm"
    set +e
    "$COMPILER" compile "$compile_source" -o "$asm" > "$stdout" 2> "$stderr"
    status=$?
    set -e
    if [ "$status" -ne 0 ]; then
        echo "compile stdout:" >&2
        sed 's/^/  /' "$stdout" >&2
        echo "compile stderr:" >&2
        sed 's/^/  /' "$stderr" >&2
        fail "$name compile failed with exit $status"
    fi

    [ -f "$asm" ] || fail "$name did not emit assembly: $asm"

    if contains_fixed "$asm" "# TODO"; then
        fail "$name assembly still contains # TODO"
    fi

    main_count=$(grep -c '^main:$' "$asm" || true)
    case "$main_policy" in
        one-main)
            [ "$main_count" -eq 1 ] || fail "$name expected exactly one main:, found $main_count"
            ;;
        has-main)
            [ "$main_count" -ge 1 ] || fail "$name expected at least one main:"
            ;;
        any-main)
            ;;
        no-main)
            [ "$main_count" -eq 0 ] || fail "$name expected no main:, found $main_count"
            ;;
        *)
            fail "$name has unknown main policy: $main_policy"
            ;;
    esac

    while IFS='|' read -r kind assert_name first second _rest; do
        [ "$assert_name" = "$name" ] || continue
        case "$kind" in
            contains)
                contains_fixed "$asm" "$first" || fail "$name assembly is missing: $first"
                ;;
            not)
                if contains_fixed "$asm" "$first"; then
                    fail "$name assembly unexpectedly contains: $first"
                fi
                ;;
            min-count)
                got=$(count_fixed "$asm" "$first")
                [ "$got" -ge "$second" ] || fail "$name expected at least $second occurrence(s) of '$first', found $got"
                ;;
            exact-count)
                got=$(count_fixed "$asm" "$first")
                [ "$got" -eq "$second" ] || fail "$name expected exactly $second occurrence(s) of '$first', found $got"
                ;;
        esac
    done < "$MANIFEST"
}

check_selfhost_inventory

entry_count=0
while IFS='|' read -r kind name source mode main_policy _rest; do
    case "$kind" in
        "" | \#*) continue ;;
        entry)
            entry_count=$((entry_count + 1))
            compile_entry "$name" "$source" "$mode" "$main_policy"
            ;;
    esac
done < "$MANIFEST"

echo "selfhost compile manifest passed for $entry_count entry(s)"
