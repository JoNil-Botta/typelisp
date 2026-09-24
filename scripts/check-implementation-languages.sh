#!/usr/bin/env sh
set -eu

# Baseline gate for the implementation language policy in CONTRIBUTING.md.
# The Rust stage0 was removed in #795. The baseline should stay empty except
# for documented temporary implementation-language exceptions; new non-allowed
# implementation-language files fail.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

BASELINE="$ROOT/scripts/implementation-language-baseline.txt"
WORKDIR="$ROOT/target/implementation-language-check"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

CURRENT="$WORKDIR/current.txt"
BASELINE_SORTED="$WORKDIR/baseline.txt"
NEW="$WORKDIR/new.txt"
EXISTING="$WORKDIR/existing.txt"
RETIRED="$WORKDIR/retired.txt"

is_exception_path() {
    case "$1" in
        benchmarks/*.c | benchmarks/*.h | tools/vs-code-extension/*) return 0 ;;
        scripts/*.sh | tests/public-tools/*.sh | scripts/*.ps1) return 0 ;;
        *) return 1 ;;
    esac
}

is_forbidden_file() {
    case "$1" in
        Cargo.toml | Cargo.lock | */Cargo.toml | */Cargo.lock) return 0 ;;
        *.rs | *.c | *.h | *.cc | *.cpp | *.cxx | *.hpp) return 0 ;;
        *.sh | *.py | *.ps1 | *.psm1 | *.js | *.ts | *.mjs | *.cjs) return 0 ;;
        *.rb | *.pl | *.lua | *.go | *.java | *.kt | *.swift | *.cs) return 0 ;;
        *) return 1 ;;
    esac
}

: > "$CURRENT"
git ls-files --cached --others --exclude-standard |
while IFS= read -r path || [ -n "$path" ]; do
    [ -f "$path" ] || continue
    if is_exception_path "$path"; then
        continue
    fi
    if is_forbidden_file "$path"; then
        printf '%s\n' "$path"
    fi
done | sort -u > "$CURRENT"

if [ -f "$BASELINE" ]; then
    sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' "$BASELINE" | sort -u > "$BASELINE_SORTED"
else
    : > "$BASELINE_SORTED"
fi

comm -23 "$CURRENT" "$BASELINE_SORTED" > "$NEW"
comm -12 "$CURRENT" "$BASELINE_SORTED" > "$EXISTING"
comm -13 "$CURRENT" "$BASELINE_SORTED" > "$RETIRED"

if [ -s "$EXISTING" ]; then
    echo "implementation language gate: baselined temporary files remain:"
    sed 's/^/  - /' "$EXISTING"
fi

if [ -s "$RETIRED" ]; then
    echo "implementation language gate: baseline entries no longer exist; remove them from scripts/implementation-language-baseline.txt:"
    sed 's/^/  - /' "$RETIRED"
fi

if [ -s "$NEW" ]; then
    echo "implementation language gate: forbidden implementation-language files outside the baseline:" >&2
    sed 's/^/  - /' "$NEW" >&2
    echo "Allowed implementation language is TypeLisp." >&2
    echo "Path exceptions: scripts/*.sh, tests/public-tools/*.sh, scripts/*.ps1, benchmarks/**/*.c, benchmarks/**/*.h, and tools/vs-code-extension/**." >&2
    exit 1
fi

echo "implementation language gate: no unbaselined forbidden files"
