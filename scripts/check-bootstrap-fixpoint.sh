#!/usr/bin/env sh
set -eu

# check-bootstrap-fixpoint.sh - selfhost compiler stage2/stage3 fixpoint gate.
#
# A seed TypeLisp compiler builds the full selfhost toolchain (src/cli.tl)
# to stage1. stage1 then compiles the same source to stage2.s, stage2 repeats
# that compile to stage3.s, and the selfhost-emitted stage2/stage3 assembly must
# be byte-identical. The stages use the same compile flags as the stage0
# publication build (scripts/build-stage0.sh), so the stage2 binary is the
# branch-built full CLI and CI reuses it for every downstream gate.
#
# Set TYPELISP_BOOTSTRAP_STAGE1_PATH_FILE / TYPELISP_BOOTSTRAP_STAGE2_PATH_FILE
# to persist the stage1/stage2 compiler paths for callers that want to reuse the
# freshly bootstrapped compilers. Normal CI runs must continue through the
# stage2/stage3 fixpoint.
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

WORKDIR="$ROOT/target/bootstrap-fixpoint"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
configure_toolchain

STAGE1_ASM="$WORKDIR/stage1.s"
STAGE1_OBJ="$WORKDIR/stage1.$OBJ_EXT"
STAGE1_BIN="$WORKDIR/stage1$BIN_EXT"
STAGE2_ASM="$WORKDIR/stage2.s"
STAGE2_OBJ="$WORKDIR/stage2.$OBJ_EXT"
STAGE2_BIN="$WORKDIR/stage2$BIN_EXT"
STAGE3_ASM="$WORKDIR/stage3.s"
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

write_stage2_path() {
    if [ -n "${TYPELISP_BOOTSTRAP_STAGE2_PATH_FILE:-}" ]; then
        STAGE2_PATH_DIR=$(dirname -- "$TYPELISP_BOOTSTRAP_STAGE2_PATH_FILE")
        mkdir -p "$STAGE2_PATH_DIR"
        printf '%s\n' "$STAGE2_BIN" > "$TYPELISP_BOOTSTRAP_STAGE2_PATH_FILE"
        echo "[bootstrap] stage2 compiler: $STAGE2_BIN"
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

    NO_ROOT_DIR="$WORKDIR/stage1-no-root-stdlib"
    mkdir -p "$NO_ROOT_DIR"
    cat > "$NO_ROOT_DIR/main.tl" <<'EOF'
(import "stdlib/string.tl")
(define (main) : i64 (string-length "abc"))
EOF
    (
        cd "$NO_ROOT_DIR"
        unset TYPELISP_STDLIB_ROOT
        run_stage1_cli_capture stage1-check-embedded-stdlib "$STAGE1_BIN" check main.tl
    )
    assert_contains "$WORKDIR/stage1-check-embedded-stdlib.stdout" "Type checking passed!"

    ENV_ROOT="$WORKDIR/stage1-env-stdlib"
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
        run_stage1_cli_capture stage1-check-env-stdlib-root "$STAGE1_BIN" check env-root.tl
    )
    assert_contains "$WORKDIR/stage1-check-env-stdlib-root.stdout" "Type checking passed!"

    CLI_ROOT="$WORKDIR/stage1-cli-stdlib"
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
            stage1-check-cli-stdlib-root-over-env \
            "$STAGE1_BIN" check cli-over-env.tl --stdlib-root "$CLI_ROOT"
    )
    assert_contains "$WORKDIR/stage1-check-cli-stdlib-root-over-env.stdout" "Type checking passed!"

    LOCAL_SHADOW_DIR="$WORKDIR/stage1-local-stdlib-shadow"
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
            stage1-check-local-stdlib-shadow \
            "$STAGE1_BIN" check main.tl --stdlib-root "$CLI_ROOT"
    )
    assert_contains "$WORKDIR/stage1-check-local-stdlib-shadow.stdout" "Type checking passed!"

    run_stage1_cli_expect_failure stage1-unknown-command "$STAGE1_BIN" definitely-not-a-command
    assert_contains "$WORKDIR/stage1-unknown-command.stderr" "typelisp: unknown subcommand definitely-not-a-command"
    assert_contains "$WORKDIR/stage1-unknown-command.stderr" "Usage:"
}

# Bootstrap the full toolchain entry with the same flags as the stage0
# publication build (scripts/build-stage0.sh), so the stage2 produced here is
# the branch-built equivalent of a published stage0 and CI can run every
# downstream gate on it.
BOOTSTRAP_SRC=src/cli.tl

echo "[bootstrap] stage0 -> stage1.s"
run_with_heartbeat "stage0 -> stage1.s" "$COMPILER" compile "$BOOTSTRAP_SRC" -o "$STAGE1_ASM" --target "$BOOTSTRAP_TARGET" $(native_target_cfg_args) --stdlib-root stdlib --stdlib-root src --opt-level 1

assemble_and_link "stage1" "$STAGE1_ASM" "$STAGE1_OBJ" "$STAGE1_BIN"

check_stage1_compile_cli

echo "[bootstrap] stage1 -> stage2.s"
run_with_heartbeat "stage1 -> stage2.s" "$STAGE1_BIN" compile "$BOOTSTRAP_SRC" -o "$STAGE2_ASM" --target "$BOOTSTRAP_TARGET" $(native_target_cfg_args) --stdlib-root stdlib --stdlib-root src --opt-level 1

assemble_and_link_stage2

echo "[bootstrap] stage2 -> stage3.s"
run_with_heartbeat "stage2 -> stage3.s" "$STAGE2_BIN" compile "$BOOTSTRAP_SRC" -o "$STAGE3_ASM" --target "$BOOTSTRAP_TARGET" $(native_target_cfg_args) --stdlib-root stdlib --stdlib-root src --opt-level 1

echo "[bootstrap] compare stage2.s and stage3.s"
if ! cmp -s "$STAGE2_ASM" "$STAGE3_ASM"; then
    echo "bootstrap fixpoint mismatch: stage2.s and stage3.s differ" >&2
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$STAGE2_ASM" "$STAGE3_ASM" >&2 || true
    fi
    wc -l "$STAGE2_ASM" "$STAGE3_ASM" >&2 || true
    if command -v diff >/dev/null 2>&1; then
        diff -u "$STAGE2_ASM" "$STAGE3_ASM" | sed -n '1,200p' >&2 || true
    else
        cmp -l "$STAGE2_ASM" "$STAGE3_ASM" | sed -n '1,80p' >&2 || true
    fi
    exit 1
fi

wc -l "$STAGE2_ASM" "$STAGE3_ASM"
write_stage1_path
write_stage2_path
echo "bootstrap fixpoint check passed"
