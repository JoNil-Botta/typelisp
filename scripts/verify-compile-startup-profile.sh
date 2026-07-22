#!/usr/bin/env sh
set -eu

# verify-compile-startup-profile.sh - profile marker and parity smoke.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host
configure_toolchain

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
    echo "compile-startup-profile compiler is not executable: $COMPILER" >&2
    exit 1
}

WORKDIR="$ROOT/target/compile-startup-profile-verify/$NL_HOST_OS"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

PROFILE_ASM="$WORKDIR/typelisp-startup-profile.s"
PROFILE_OBJ="$WORKDIR/typelisp-startup-profile.$NL_OBJ_EXT"
PROFILE_BIN="$WORKDIR/typelisp-startup-profile$NL_BIN_EXT"
INPUT="$WORKDIR/empty.tl"
PROFILE_OUTPUT="$WORKDIR/profile-output.s"
CONTROL_OUTPUT="$WORKDIR/control-output.s"
PROFILE_STDERR="$WORKDIR/profile.stderr"
CONTROL_STDERR="$WORKDIR/control.stderr"

printf '%s\n' '(define (main) : i64 0)' >"$INPUT"

echo "[compile-startup-profile] build profiling compiler"
"$COMPILER" compile src/main.tl -o "$PROFILE_ASM" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --cfg compile-startup-profile \
    --stdlib-root stdlib \
    --stdlib-root src \
    --opt-level 1
assemble_and_link \
    "compile-startup-profile" \
    "$PROFILE_ASM" "$PROFILE_OBJ" "$PROFILE_BIN"

echo "[compile-startup-profile] compile marker smoke"
"$PROFILE_BIN" compile "$INPUT" -o "$PROFILE_OUTPUT" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --stdlib-root stdlib \
    --stdlib-root src \
    --opt-level 0 \
    2>"$PROFILE_STDERR"

"$COMPILER" compile "$INPUT" -o "$CONTROL_OUTPUT" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --stdlib-root stdlib \
    --stdlib-root src \
    --opt-level 0 \
    2>"$CONTROL_STDERR"

cmp "$PROFILE_OUTPUT" "$CONTROL_OUTPUT" >/dev/null || {
    echo "compile-startup-profile changed generated assembly" >&2
    exit 1
}
if grep '^compile-startup-profile|' "$CONTROL_STDERR" >/dev/null 2>&1; then
    echo "normal compiler unexpectedly emitted startup profile rows" >&2
    exit 1
fi

awk -F'|' '
BEGIN {
    split("globals.start main.entry cli.compile_action driver_state.begin driver_state.end preflight.begin preflight.end file_state_reset.end compile_driver.start prelude.begin prelude.end user_entry.start", order, " ")
    wanted = 12
}
$1 == "compile-startup-profile" && $2 != "marker" {
    if (($3 + 0) <= 0 || ($4 + 0) <= 0) {
        print "invalid startup profile row: " $0 > "/dev/stderr"
        exit 2
    }
    tick[$2] = $3 + 0
    seen[$2]++
}
END {
    previous = 0
    for (i = 1; i <= wanted; i++) {
        marker = order[i]
        if (seen[marker] != 1) {
            print "missing or duplicate startup marker: " marker > "/dev/stderr"
            exit 3
        }
        if (tick[marker] < previous) {
            print "non-monotonic startup marker: " marker > "/dev/stderr"
            exit 4
        }
        previous = tick[marker]
    }
}
' "$PROFILE_STDERR"

echo "compile-startup-profile marker and parity smoke passed."
