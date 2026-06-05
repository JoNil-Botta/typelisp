#!/usr/bin/env sh
set -eu

# benchmark-compile-cli.sh - benchmark the optimized selfhost CLI self-build.
#
# The primary measured operation is the real optimized stage2 CLI compiling
# selfhost/cli.tl into stage3.s. The measured stage3 assembly must be
# byte-identical to stage2.s. A profile-enabled compile driver, compiled by
# stage2 with --cfg compile-profile, provides phase timing and allocator
# peak-live counters while reusing the normal compiler driver pipeline.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

TYPELISP_WINDOWS_LINK_REPRO=${TYPELISP_WINDOWS_LINK_REPRO:-1}
export TYPELISP_WINDOWS_LINK_REPRO

. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host

if [ "$#" -gt 1 ]; then
    echo "usage: $0 [typelisp-seed]" >&2
    exit 2
fi

if [ "$#" -eq 1 ]; then
    SEED=$1
elif [ -n "${TYPELISP_BIN:-}" ]; then
    SEED=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    SEED=$(resolve_stage0_compiler "$ROOT") || exit 1
fi

if [ ! -x "$SEED" ]; then
    echo "typelisp seed is not executable: $SEED" >&2
    exit 1
fi

WORKDIR=${TYPELISP_COMPILE_BENCH_OUT:-"$ROOT/target/compile-cli-benchmark"}
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
configure_toolchain

STAGE1_ASM="$WORKDIR/stage1.s"
STAGE1_OBJ="$WORKDIR/stage1.$NL_OBJ_EXT"
STAGE1_BIN="$WORKDIR/stage1$NL_BIN_EXT"
STAGE2_ASM="$WORKDIR/stage2.s"
STAGE2_OBJ="$WORKDIR/stage2.$NL_OBJ_EXT"
STAGE2_BIN="$WORKDIR/stage2$NL_BIN_EXT"
STAGE3_ASM="$WORKDIR/stage3.s"
PROFILE_ASM="$WORKDIR/compile_profile.s"
PROFILE_OBJ="$WORKDIR/compile_profile.$NL_OBJ_EXT"
PROFILE_BIN="$WORKDIR/compile_profile$NL_BIN_EXT"
PROFILE_CLI_ASM="$WORKDIR/profile-cli.s"
TIMINGS="$WORKDIR/timings.tsv"
PROFILE_TSV="$WORKDIR/profile.tsv"

now_ms() {
    value=$(date +%s%3N 2>/dev/null || true)
    case "$value" in
        *[!0-9]* | "") ;;
        *) printf '%s\n' "$value"; return 0 ;;
    esac
    perl -MTime::HiRes=time -e 'printf "%d\n", time() * 1000'
}

sha_files() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$@" >&2 || true
    fi
}

compile_cli_to_asm() {
    label=$1
    compiler=$2
    asm=$3
    stdout="$WORKDIR/$label.stdout"
    stderr="$WORKDIR/$label.stderr"
    echo "[compile-bench] $label"
    if ! run_with_heartbeat "$label" \
        "$compiler" compile selfhost/cli.tl -o "$asm" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) \
        --stdlib-root stdlib \
        --stdlib-root selfhost \
        --opt-level 2 \
        >"$stdout" 2>"$stderr"; then
        echo "[compile-bench] $label failed" >&2
        sed 's/^/  /' "$stdout" >&2 || true
        sed 's/^/  /' "$stderr" >&2 || true
        exit 1
    fi
    [ -s "$asm" ] || {
        echo "[compile-bench] $label did not produce assembly: $asm" >&2
        exit 1
    }
}

measure_compile_cli_to_asm() {
    label=$1
    compiler=$2
    asm=$3
    stdout="$WORKDIR/$label.stdout"
    stderr="$WORKDIR/$label.stderr"
    echo "[compile-bench] measure $label"
    start=$(now_ms)
    if ! run_with_heartbeat "$label" \
        "$compiler" compile selfhost/cli.tl -o "$asm" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) \
        --stdlib-root stdlib \
        --stdlib-root selfhost \
        --opt-level 2 \
        >"$stdout" 2>"$stderr"; then
        echo "[compile-bench] $label failed" >&2
        sed 's/^/  /' "$stdout" >&2 || true
        sed 's/^/  /' "$stderr" >&2 || true
        exit 1
    fi
    end=$(now_ms)
    [ -s "$asm" ] || {
        echo "[compile-bench] $label did not produce assembly: $asm" >&2
        exit 1
    }
    printf '%s\t%s\n' "$label" "$((end - start))" >> "$TIMINGS"
}

strip_if_needed() {
    bin=$1
    if [ "$NL_HOST_OS" = linux ] && command -v strip >/dev/null 2>&1; then
        strip "$bin"
    fi
}

compare_text() {
    label=$1
    left=$2
    right=$3
    echo "[compile-bench] compare $label"
    if ! cmp -s "$left" "$right"; then
        echo "[compile-bench] mismatch: $label" >&2
        sha_files "$left" "$right"
        wc -l "$left" "$right" >&2 || true
        if command -v diff >/dev/null 2>&1; then
            diff -u "$left" "$right" | sed -n '1,200p' >&2 || true
        fi
        exit 1
    fi
}

: > "$TIMINGS"
printf 'phase\telapsed_ms\talloc_delta_bytes\tlive_delta_bytes\tpeak_live_delta_bytes\n' > "$PROFILE_TSV"

compile_cli_to_asm "seed-to-stage1" "$SEED" "$STAGE1_ASM"
assemble_and_link "stage1" "$STAGE1_ASM" "$STAGE1_OBJ" "$STAGE1_BIN"
strip_if_needed "$STAGE1_BIN"

compile_cli_to_asm "stage1-to-stage2" "$STAGE1_BIN" "$STAGE2_ASM"
assemble_and_link "stage2" "$STAGE2_ASM" "$STAGE2_OBJ" "$STAGE2_BIN"
strip_if_needed "$STAGE2_BIN"

measure_compile_cli_to_asm "stage2-to-stage3-cli" "$STAGE2_BIN" "$STAGE3_ASM"
compare_text "stage2.s vs measured stage3.s" "$STAGE2_ASM" "$STAGE3_ASM"

echo "[compile-bench] build profile-enabled compile driver with stage2"
if ! run_with_heartbeat "stage2 -> profile compile driver" \
    "$STAGE2_BIN" compile selfhost/compile.tl -o "$PROFILE_ASM" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --stdlib-root stdlib \
    --stdlib-root selfhost \
    --opt-level 2 \
    --cfg compile-profile \
    >"$WORKDIR/compile_profile-build.stdout" \
    2>"$WORKDIR/compile_profile-build.stderr"; then
    echo "[compile-bench] profile compile driver build failed" >&2
    sed 's/^/  /' "$WORKDIR/compile_profile-build.stdout" >&2 || true
    sed 's/^/  /' "$WORKDIR/compile_profile-build.stderr" >&2 || true
    exit 1
fi
assemble_and_link "compile-profile" "$PROFILE_ASM" "$PROFILE_OBJ" "$PROFILE_BIN"
strip_if_needed "$PROFILE_BIN"

echo "[compile-bench] run profiled phase breakdown"
if ! "$PROFILE_BIN" compile selfhost/cli.tl -o "$PROFILE_CLI_ASM" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --stdlib-root stdlib \
    --stdlib-root selfhost \
    --opt-level 2 \
    >"$WORKDIR/profile-run.stdout" \
    2>"$WORKDIR/profile-run.stderr"; then
    echo "[compile-bench] profiled compile failed" >&2
    sed 's/^/  /' "$WORKDIR/profile-run.stdout" >&2 || true
    sed 's/^/  /' "$WORKDIR/profile-run.stderr" >&2 || true
    exit 1
fi
grep '^compile-profile|' "$WORKDIR/profile-run.stderr" \
    | awk -F'|' 'NR > 1 { printf "%s\t%s\t%s\t%s\t%s\n", $2, $3, $4, $5, $6 }' \
    >> "$PROFILE_TSV"
compare_text "profiled cli asm vs measured stage3.s" "$STAGE3_ASM" "$PROFILE_CLI_ASM"

echo "[compile-bench] timings: $TIMINGS"
cat "$TIMINGS"
echo "[compile-bench] profile: $PROFILE_TSV"
cat "$PROFILE_TSV"
echo "[compile-bench] artifacts: $WORKDIR"
