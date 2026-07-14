#!/usr/bin/env sh
set -eu

# verify-allocation-profile.sh - public compiler allocation-profile smoke test.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi
case "$COMPILER" in
    /* | [A-Za-z]:[/\\]*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac
[ -x "$COMPILER" ] || {
    echo "allocation-profile compiler is not executable: $COMPILER" >&2
    exit 1
}

WORKDIR="$ROOT/target/allocation-profile-verify/$NL_HOST_OS"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

INPUT=tests/integration/arithmetic.tl
NORMAL_ASM="$WORKDIR/normal.s"
PROFILE_ASM="$WORKDIR/profile.s"
NORMAL_STDOUT="$WORKDIR/normal.stdout"
NORMAL_STDERR="$WORKDIR/normal.stderr"
PROFILE_STDOUT="$WORKDIR/profile.stdout"
PROFILE_STDERR="$WORKDIR/profile.stderr"
BATCH_NORMAL_LIST="$WORKDIR/batch-normal.txt"
BATCH_PROFILE_LIST="$WORKDIR/batch-profile.txt"
BATCH_NORMAL_ARITH="$WORKDIR/batch-normal-arithmetic.s"
BATCH_NORMAL_FUNCTIONS="$WORKDIR/batch-normal-functions.s"
BATCH_PROFILE_ARITH="$WORKDIR/batch-profile-arithmetic.s"
BATCH_PROFILE_FUNCTIONS="$WORKDIR/batch-profile-functions.s"
BATCH_NORMAL_STDOUT="$WORKDIR/batch-normal.stdout"
BATCH_NORMAL_STDERR="$WORKDIR/batch-normal.stderr"
BATCH_PROFILE_STDOUT="$WORKDIR/batch-profile.stdout"
BATCH_PROFILE_STDERR="$WORKDIR/batch-profile.stderr"

batch_path() {
    if [ "$NL_HOST_OS" = windows ] && command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        printf '%s\n' "$1"
    fi
}

compile_case() {
    output=$1
    stdout=$2
    stderr=$3
    shift 3
    "$COMPILER" compile "$INPUT" -o "$output" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) \
        --stdlib-root stdlib \
        --stdlib-root src \
        --opt-level 1 \
        "$@" \
        >"$stdout" 2>"$stderr"
}

echo "[allocation-profile] compile normal control"
compile_case "$NORMAL_ASM" "$NORMAL_STDOUT" "$NORMAL_STDERR"
if grep '^compile-allocation-profile|' "$NORMAL_STDERR" >/dev/null 2>&1; then
    echo "normal compile unexpectedly emitted allocation profile rows" >&2
    exit 1
fi

echo "[allocation-profile] compile profiled case"
compile_case \
    "$PROFILE_ASM" \
    "$PROFILE_STDOUT" \
    "$PROFILE_STDERR" \
    --profile-allocations

cmp "$NORMAL_ASM" "$PROFILE_ASM" >/dev/null || {
    echo "--profile-allocations changed generated assembly" >&2
    exit 1
}

validate_profile() {
    profile_file=$1
    expected_entries=$2
    awk -F'|' -v expected_entries="$expected_entries" '
    BEGIN {
        required["start/active"] = 0
        required["load/active"] = 0
        required["load/source-pools"] = 0
        required["lower/lower-scratch"] = 0
        required["optimize/optimizer-scratch"] = 0
        required["backend/active"] = 0
        required["write/active"] = 0
        required["complete/active"] = 0
    }
    $1 == "compile-allocation-profile" && $2 == "phase" {
        if (NF != 8 || $3 != "owner" || $4 != "arena_root" ||
            $5 != "bump_bytes" || $6 != "committed_bytes" ||
            $7 != "reserved_bytes" || $8 != "segments") {
            print "invalid allocation-profile header" > "/dev/stderr"
            exit 1
        }
        headers++
        next
    }
    $1 == "compile-allocation-profile" {
        if (NF != 8) {
            print "invalid allocation-profile field count: " $0 > "/dev/stderr"
            exit 1
        }
        for (i = 4; i <= 8; i++) {
            if ($i !~ /^[0-9]+$/) {
                print "non-numeric allocation-profile field: " $0 > "/dev/stderr"
                exit 1
            }
        }
        if (($4 == 0 && ($5 != 0 || $6 != 0 || $7 != 0 || $8 != 0)) ||
            $5 > $6 || $6 > $7) {
            print "inconsistent allocation-profile sizes: " $0 > "/dev/stderr"
            exit 1
        }
        key = $2 "/" $3
        if (key in required) required[key]++
        rows++
    }
    END {
        if (headers != 1 || rows == 0) exit 1
        for (key in required) {
            if (required[key] == 0) {
                print "missing allocation-profile row: " key > "/dev/stderr"
                exit 1
            }
        }
        if (required["start/active"] != 1 ||
            required["load/active"] != expected_entries ||
            required["write/active"] != expected_entries ||
            required["complete/active"] != 1) {
            print "unexpected allocation-profile entry phase counts" > "/dev/stderr"
            exit 1
        }
    }
' "$profile_file"
}

validate_profile "$PROFILE_STDERR" 1

printf '%s|%s\n%s|%s\n' \
    "$(batch_path "$ROOT/tests/integration/arithmetic.tl")" \
    "$(batch_path "$BATCH_NORMAL_ARITH")" \
    "$(batch_path "$ROOT/tests/integration/functions.tl")" \
    "$(batch_path "$BATCH_NORMAL_FUNCTIONS")" > "$BATCH_NORMAL_LIST"
printf '%s|%s\n%s|%s\n' \
    "$(batch_path "$ROOT/tests/integration/arithmetic.tl")" \
    "$(batch_path "$BATCH_PROFILE_ARITH")" \
    "$(batch_path "$ROOT/tests/integration/functions.tl")" \
    "$(batch_path "$BATCH_PROFILE_FUNCTIONS")" > "$BATCH_PROFILE_LIST"

echo "[allocation-profile] compile batch normal control"
"$COMPILER" compile --batch "$BATCH_NORMAL_LIST" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --stdlib-root stdlib \
    --stdlib-root src \
    --opt-level 1 \
    >"$BATCH_NORMAL_STDOUT" 2>"$BATCH_NORMAL_STDERR"
if grep '^compile-allocation-profile|' "$BATCH_NORMAL_STDERR" >/dev/null 2>&1; then
    echo "normal batch compile unexpectedly emitted allocation profile rows" >&2
    exit 1
fi

echo "[allocation-profile] compile batch profiled case"
"$COMPILER" compile --batch "$BATCH_PROFILE_LIST" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --stdlib-root stdlib \
    --stdlib-root src \
    --opt-level 1 \
    --profile-allocations \
    >"$BATCH_PROFILE_STDOUT" 2>"$BATCH_PROFILE_STDERR"

cmp "$BATCH_NORMAL_ARITH" "$BATCH_PROFILE_ARITH" >/dev/null || {
    echo "--profile-allocations changed batch arithmetic assembly" >&2
    exit 1
}
cmp "$BATCH_NORMAL_FUNCTIONS" "$BATCH_PROFILE_FUNCTIONS" >/dev/null || {
    echo "--profile-allocations changed batch functions assembly" >&2
    exit 1
}
validate_profile "$BATCH_PROFILE_STDERR" 2

echo "[allocation-profile] output invariant and owner schema passed"
