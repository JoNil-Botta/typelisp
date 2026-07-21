#!/usr/bin/env sh
set -eu

# check-bootstrap-fixpoint.sh - selfhost compiler bootstrap fixpoint gate.
#
# A seed TypeLisp compiler builds the full selfhost toolchain (src/main.tl) to
# stage1, and each stage recompiles the same source at --opt-level 2 into the
# next. The gate first compares stage2.s and stage3.s. It stops there when they
# are identical; only a mismatch builds stage4 and requires stage3.s and
# stage4.s to be byte-identical. The newest compiler in the proven fixpoint is
# reused by every downstream gate. Same compile flags as the stage0 publication
# build (build-stage0.sh).
#
# Set TYPELISP_BOOTSTRAP_STAGE1_PATH_FILE / TYPELISP_BOOTSTRAP_STAGE2_PATH_FILE
# to persist the stage1 / converged compiler paths for callers that reuse the
# freshly bootstrapped compilers.
#
# TYPELISP_BOOTSTRAP_CFG adds one cfg predicate to every compiler generation.
# TYPELISP_BOOTSTRAP_WORKDIR isolates a second bootstrap in the same job, and
# TYPELISP_BOOTSTRAP_SKIP_CLI_SMOKE=1 skips the redundant stage1 CLI surface
# checks for that second run. CI uses these together for the scratch-vreg
# self-hosting regression gate.
#
# refs #47.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

# Host toolchain discovery + assemble/link helpers are shared with the stage0
# self-build (scripts/build-stage0.sh). Sourcing sets HOST_OS / BOOTSTRAP_TARGET
# / OBJ_EXT / BIN_EXT and defines configure_toolchain, run_with_heartbeat, and
# assemble_and_link.
. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host
. "$ROOT/scripts/lib-bootstrap-ctfe.sh"
. "$ROOT/scripts/lib-bootstrap-fixpoint-control.sh"

if [ "$#" -gt 1 ]; then
    echo "usage: $0 [typelisp-binary]" >&2
    exit 2
fi

if [ "$#" -eq 1 ]; then
    COMPILER=$1
elif [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    # Local-development fallback: fetch the published self-hosted
    # stage0 (CI passes a fetched/bootstrapped compiler via TYPELISP_BIN).
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

# The seed is invoked from a scratch directory when it needs the legacy
# prelude, so normalize a caller-provided relative path while we are at ROOT.
case "$COMPILER" in
    /* | [A-Za-z]:[\\/]*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac

BOOTSTRAP_CFG=${TYPELISP_BOOTSTRAP_CFG:-}
case "$BOOTSTRAP_CFG" in
    "") ;;
    *[!A-Za-z0-9_-]*)
        echo "invalid TYPELISP_BOOTSTRAP_CFG: $BOOTSTRAP_CFG" >&2
        exit 2
        ;;
esac
BOOTSTRAP_SKIP_CLI_SMOKE=${TYPELISP_BOOTSTRAP_SKIP_CLI_SMOKE:-0}
case "$BOOTSTRAP_SKIP_CLI_SMOKE" in
    0 | 1) ;;
    *)
        echo "TYPELISP_BOOTSTRAP_SKIP_CLI_SMOKE must be 0 or 1" >&2
        exit 2
        ;;
esac

bootstrap_extra_cfg_args() {
    if [ -n "$BOOTSTRAP_CFG" ]; then
        printf '%s\n' --cfg "$BOOTSTRAP_CFG"
    fi
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

assemble_and_link_stage2() {
    stdout="$WORKDIR/stage2-link.stdout"
    stderr="$WORKDIR/stage2-link.stderr"
    set +e
    assemble_and_link "stage2" "$STAGE2_ASM" "$STAGE2_OBJ" "$STAGE2_BIN" \
        > "$stdout" 2> "$stderr"
    status=$?
    set -e
    sed 's/^/  /' "$stdout" || true
    if [ "$status" -eq 0 ]; then
        [ ! -s "$stderr" ] || sed 's/^/  /' "$stderr" >&2 || true
        return 0
    fi

    sed 's/^/  /' "$stderr" >&2 || true
    exit "$status"
}

run_stage1_cli_expect_failure() {
    label=$1
    shift
    stdout="$WORKDIR/$label.stdout"
    stderr="$WORKDIR/$label.stderr"
    set +e
    "$@" > "$stdout" 2> "$stderr"
    status=$?
    set -e
    if [ "$status" -eq 0 ]; then
        echo "stage1 CLI command unexpectedly succeeded: $label" >&2
        echo "stdout:" >&2
        sed 's/^/  /' "$stdout" >&2 || true
        echo "stderr:" >&2
        sed 's/^/  /' "$stderr" >&2 || true
        exit 1
    fi
}

run_stage1_cli_capture() {
    label=$1
    shift
    stdout="$WORKDIR/$label.stdout"
    stderr="$WORKDIR/$label.stderr"
    if ! "$@" > "$stdout" 2> "$stderr"; then
        echo "stage1 CLI command failed: $label" >&2
        echo "stdout:" >&2
        sed 's/^/  /' "$stdout" >&2 || true
        echo "stderr:" >&2
        sed 's/^/  /' "$stderr" >&2 || true
        exit 1
    fi
}

WORKDIR=${TYPELISP_BOOTSTRAP_WORKDIR:-$ROOT/target/bootstrap-fixpoint}
case "$WORKDIR" in
    /* | [A-Za-z]:[\\/]*) ;;
    *) WORKDIR="$ROOT/$WORKDIR" ;;
esac
case "$WORKDIR" in
    "$ROOT"/target/*) ;;
    *)
        echo "TYPELISP_BOOTSTRAP_WORKDIR must stay below $ROOT/target" >&2
        exit 2
        ;;
esac
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
configure_toolchain

SEED_CTFE_COMPAT_STDLIB=$(bootstrap_seed_ctfe_macro_builders_legacy_stdlib "$ROOT" "$COMPILER" "$WORKDIR")
if [ -n "$SEED_CTFE_COMPAT_STDLIB" ]; then
    echo "[bootstrap] seed lacks current CTFE macro builders; using the legacy prelude for stage0 -> stage1"
else
    echo "[bootstrap] seed supports current CTFE macro builders; using iterative core macros"
fi

STAGE1_ASM="$WORKDIR/stage1.s"
STAGE1_OBJ="$WORKDIR/stage1.$OBJ_EXT"
STAGE1_BIN="$WORKDIR/stage1$BIN_EXT"
STAGE2_ASM="$WORKDIR/stage2.s"
STAGE2_OBJ="$WORKDIR/stage2.$OBJ_EXT"
STAGE2_BIN="$WORKDIR/stage2$BIN_EXT"
STAGE3_ASM="$WORKDIR/stage3.s"
STAGE3_OBJ="$WORKDIR/stage3.$OBJ_EXT"
STAGE3_BIN="$WORKDIR/stage3$BIN_EXT"
STAGE4_ASM="$WORKDIR/stage4.s"
STAGE4_OBJ="$WORKDIR/stage4.$OBJ_EXT"
STAGE4_BIN="$WORKDIR/stage4$BIN_EXT"
STAGE1_CLI_SRC="$WORKDIR/stage1_cli_smoke.tl"
STAGE1_CLI_ASM="$WORKDIR/stage1_cli_smoke.s"
STAGE1_CLI_DIRECT_ASM="$WORKDIR/stage1_cli_direct.s"
STAGE1_CLI_IR="$WORKDIR/stage1_cli_smoke.ir"

cat > "$STAGE1_CLI_SRC" <<'EOF'
(define (main) : i64 42)
EOF

write_stage1_path() {
    if [ -n "${TYPELISP_BOOTSTRAP_STAGE1_PATH_FILE:-}" ]; then
        STAGE1_PATH_DIR=$(dirname -- "$TYPELISP_BOOTSTRAP_STAGE1_PATH_FILE")
        mkdir -p "$STAGE1_PATH_DIR"
        printf '%s\n' "$STAGE1_BIN" > "$TYPELISP_BOOTSTRAP_STAGE1_PATH_FILE"
        echo "[bootstrap] stage1 compiler: $STAGE1_BIN"
    fi
}

# Hand every downstream gate the newest compiler that participated in the
# proven fixpoint: stage3 for an early stage2.s == stage3.s fixpoint, otherwise
# stage4 after the fallback stage3.s == stage4.s proof. The env var name is
# retained for compatibility with ci-verify.sh.
write_bootstrap_compiler_path() {
    if [ -n "${TYPELISP_BOOTSTRAP_STAGE2_PATH_FILE:-}" ]; then
        STAGE2_PATH_DIR=$(dirname -- "$TYPELISP_BOOTSTRAP_STAGE2_PATH_FILE")
        mkdir -p "$STAGE2_PATH_DIR"
        printf '%s\n' "$BOOTSTRAP_COMPILER_BIN" > "$TYPELISP_BOOTSTRAP_STAGE2_PATH_FILE"
        echo "[bootstrap] bootstrapped compiler handed to gates ($BOOTSTRAP_COMPILER_STAGE): $BOOTSTRAP_COMPILER_BIN"
    fi
}

check_stage1_compile_cli() {
    echo "[bootstrap] stage1 compile CLI smoke"
    run_stage1_cli_capture \
        stage1-compile-command \
        "$STAGE1_BIN" compile "$STAGE1_CLI_SRC" \
        --target "$BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) \
        --backend-mode scalar \
        --opt-level 0 \
        --stdlib-root "$ROOT/stdlib" \
        --stdlib-root "$ROOT/src"
    [ -s "$STAGE1_CLI_ASM" ] || {
        echo "stage1 compile command did not write default assembly: $STAGE1_CLI_ASM" >&2
        exit 1
    }
    assert_contains "$STAGE1_CLI_ASM" "main:"

    run_stage1_cli_capture \
        stage1-compile-emit-ir \
        "$STAGE1_BIN" compile "$STAGE1_CLI_SRC" --emit-ir --target "$BOOTSTRAP_TARGET" $(native_target_cfg_args) --stdlib-root "$ROOT/stdlib"
    [ -s "$STAGE1_CLI_IR" ] || {
        echo "stage1 compile --emit-ir did not write default IR: $STAGE1_CLI_IR" >&2
        exit 1
    }
    assert_contains "$STAGE1_CLI_IR" "typelisp-ir-summary v1"

    run_stage1_cli_capture stage1-help "$STAGE1_BIN" help
    assert_contains "$WORKDIR/stage1-help.stderr" "Usage:"
    assert_contains "$WORKDIR/stage1-help.stderr" "typelisp compile"

    run_stage1_cli_expect_failure stage1-missing-command "$STAGE1_BIN"
    assert_contains "$WORKDIR/stage1-missing-command.stderr" "Usage:"

    run_stage1_cli_expect_failure stage1-missing-source "$STAGE1_BIN" compile
    assert_contains "$WORKDIR/stage1-missing-source.stderr" "compile: expected source path"

    run_stage1_cli_capture stage1-check "$STAGE1_BIN" check "$STAGE1_CLI_SRC" --stdlib-root "$ROOT/stdlib"
    assert_contains "$WORKDIR/stage1-check.stdout" "Type checking passed!"

    run_stage1_cli_expect_failure stage1-unknown-command "$STAGE1_BIN" definitely-not-a-command
    assert_contains "$WORKDIR/stage1-unknown-command.stderr" "typelisp: unknown subcommand definitely-not-a-command"
    assert_contains "$WORKDIR/stage1-unknown-command.stderr" "Usage:"
}

check_stage2_embedded_stdlib() {
    echo "[bootstrap] stage2 embedded stdlib smoke"
    run_stage1_cli_capture \
        stage2-inspect-embedded-stdlib-tlci \
        "$STAGE2_BIN" inspect embedded:stdlib.tlci
    assert_contains \
        "$WORKDIR/stage2-inspect-embedded-stdlib-tlci.stdout" \
        "embedded-loader-macro-count: 102"
    assert_contains \
        "$WORKDIR/stage2-inspect-embedded-stdlib-tlci.stdout" \
        "package-name: stdlib"

    NO_ROOT_DIR="$WORKDIR/stage2-no-root-stdlib"
    mkdir -p "$NO_ROOT_DIR"
    cat > "$NO_ROOT_DIR/main.tl" <<'EOF'
(import "stdlib/string.tl")
(define (main) : i64 (string-length "abc"))
EOF
    (
        cd "$NO_ROOT_DIR"
        unset TYPELISP_STDLIB_ROOT
        run_stage1_cli_capture stage2-check-embedded-stdlib "$STAGE2_BIN" check main.tl
    )
    assert_contains "$WORKDIR/stage2-check-embedded-stdlib.stdout" "Type checking passed!"

    ENV_ROOT="$WORKDIR/stage2-env-stdlib"
    mkdir -p "$ENV_ROOT"
    cat > "$ENV_ROOT/string.tl" <<'EOF'
(define (custom-root-sentinel) : i64 7)
EOF
    cat > "$NO_ROOT_DIR/env-root.tl" <<'EOF'
(import "stdlib/string.tl")
(define (main) : i64 (custom-root-sentinel))
EOF
    (
        cd "$NO_ROOT_DIR"
        TYPELISP_STDLIB_ROOT="$ENV_ROOT"
        export TYPELISP_STDLIB_ROOT
        run_stage1_cli_capture stage2-check-env-stdlib-root "$STAGE2_BIN" check env-root.tl
    )
    assert_contains "$WORKDIR/stage2-check-env-stdlib-root.stdout" "Type checking passed!"

    CLI_ROOT="$WORKDIR/stage2-cli-stdlib"
    mkdir -p "$CLI_ROOT"
    cat > "$CLI_ROOT/string.tl" <<'EOF'
(define (cli-root-sentinel) : i64 11)
EOF
    cat > "$NO_ROOT_DIR/cli-over-env.tl" <<'EOF'
(import "stdlib/string.tl")
(define (main) : i64 (cli-root-sentinel))
EOF
    (
        cd "$NO_ROOT_DIR"
        TYPELISP_STDLIB_ROOT="$ENV_ROOT"
        export TYPELISP_STDLIB_ROOT
        run_stage1_cli_capture \
            stage2-check-cli-stdlib-root-over-env \
            "$STAGE2_BIN" check cli-over-env.tl --stdlib-root "$CLI_ROOT"
    )
    assert_contains "$WORKDIR/stage2-check-cli-stdlib-root-over-env.stdout" "Type checking passed!"

    LOCAL_SHADOW_DIR="$WORKDIR/stage2-local-stdlib-shadow"
    mkdir -p "$LOCAL_SHADOW_DIR/stdlib"
    cat > "$LOCAL_SHADOW_DIR/stdlib/string.tl" <<'EOF'
(define (local-root-sentinel) : i64 13)
EOF
    cat > "$LOCAL_SHADOW_DIR/main.tl" <<'EOF'
(import "stdlib/string.tl")
(define (main) : i64 (local-root-sentinel))
EOF
    (
        cd "$LOCAL_SHADOW_DIR"
        TYPELISP_STDLIB_ROOT="$ENV_ROOT"
        export TYPELISP_STDLIB_ROOT
        run_stage1_cli_capture \
            stage2-check-local-stdlib-shadow \
            "$STAGE2_BIN" check main.tl --stdlib-root "$CLI_ROOT"
    )
    assert_contains "$WORKDIR/stage2-check-local-stdlib-shadow.stdout" "Type checking passed!"
}

# Bootstrap the full toolchain entry with the same flags as the stage0
# publication build (scripts/build-stage0.sh), so the converged compiler here is
# the branch-built equivalent of a published stage0 and CI can run every
# downstream gate on it.
BOOTSTRAP_SRC=src/main.tl

# opt2 bootstrap. First test the common stage2.s == stage3.s fixpoint. A backend
# codegen fix can take another self-host round to propagate from an unconverged
# seed, so build stage4 only as a fallback and then require stage3.s == stage4.s.
echo "[bootstrap] stage0 -> stage1.s"
if [ -n "$SEED_CTFE_COMPAT_STDLIB" ]; then
    SEED_BOOTSTRAP_CWD="$WORKDIR/seed-bootstrap-cwd"
    mkdir -p "$SEED_BOOTSTRAP_CWD"
    (
        cd "$SEED_BOOTSTRAP_CWD"
        run_with_heartbeat "stage0 -> stage1.s" "$COMPILER" compile "$ROOT/$BOOTSTRAP_SRC" -o "$STAGE1_ASM" --target "$BOOTSTRAP_TARGET" $(native_target_cfg_args) $(bootstrap_extra_cfg_args) --cfg stage0-seed-bootstrap --stdlib-root "$SEED_CTFE_COMPAT_STDLIB" --stdlib-root "$ROOT/stdlib" --stdlib-root "$ROOT/src" --opt-level 2
    )
else
    run_with_heartbeat "stage0 -> stage1.s" "$COMPILER" compile "$BOOTSTRAP_SRC" -o "$STAGE1_ASM" --target "$BOOTSTRAP_TARGET" $(native_target_cfg_args) $(bootstrap_extra_cfg_args) --cfg stage0-seed-bootstrap --stdlib-root stdlib --stdlib-root src --opt-level 2
fi

assemble_and_link "stage1" "$STAGE1_ASM" "$STAGE1_OBJ" "$STAGE1_BIN"

if [ "$BOOTSTRAP_SKIP_CLI_SMOKE" -eq 0 ]; then
    check_stage1_compile_cli
fi

scripts/build-embedded-stdlib-tlci.sh \
    "$STAGE1_BIN" target/embedded-stdlib-tlci/stdlib.tlci "$HOST_OS"

echo "[bootstrap] stage1 -> stage2.s"
run_with_heartbeat "stage1 -> stage2.s" "$STAGE1_BIN" compile "$BOOTSTRAP_SRC" -o "$STAGE2_ASM" --target "$BOOTSTRAP_TARGET" $(native_target_cfg_args) $(bootstrap_extra_cfg_args) --cfg embedded-stdlib-tlci --stdlib-root stdlib --stdlib-root src --opt-level 2

assemble_and_link_stage2

if [ "$BOOTSTRAP_SKIP_CLI_SMOKE" -eq 0 ]; then
    check_stage2_embedded_stdlib
fi

scripts/build-embedded-stdlib-tlci.sh \
    "$STAGE2_BIN" target/embedded-stdlib-tlci/stdlib.tlci "$HOST_OS"

echo "[bootstrap] stage2 -> stage3.s"
run_with_heartbeat "stage2 -> stage3.s" "$STAGE2_BIN" compile "$BOOTSTRAP_SRC" -o "$STAGE3_ASM" --target "$BOOTSTRAP_TARGET" $(native_target_cfg_args) $(bootstrap_extra_cfg_args) --cfg embedded-stdlib-tlci --stdlib-root stdlib --stdlib-root src --opt-level 2

assemble_and_link "stage3" "$STAGE3_ASM" "$STAGE3_OBJ" "$STAGE3_BIN"

bootstrap_build_stage4() {
    scripts/build-embedded-stdlib-tlci.sh \
        "$STAGE3_BIN" target/embedded-stdlib-tlci/stdlib.tlci "$HOST_OS"
    echo "[bootstrap] stage3 -> stage4.s"
    run_with_heartbeat "stage3 -> stage4.s" "$STAGE3_BIN" compile "$BOOTSTRAP_SRC" -o "$STAGE4_ASM" --target "$BOOTSTRAP_TARGET" $(native_target_cfg_args) $(bootstrap_extra_cfg_args) --cfg embedded-stdlib-tlci --stdlib-root stdlib --stdlib-root src --opt-level 2
    assemble_and_link "stage4" "$STAGE4_ASM" "$STAGE4_OBJ" "$STAGE4_BIN"
}

bootstrap_resolve_fixpoint
write_stage1_path
write_bootstrap_compiler_path
echo "bootstrap fixpoint check passed"
