#!/usr/bin/env sh
set -eu

# check-bootstrap-fixpoint.sh - selfhost compiler stage2/stage3 fixpoint gate.
#
# The Rust stage0 compiler builds the TypeLisp selfhost compiler to stage1.
# stage1 then compiles the same selfhost source to stage2.s, stage2 repeats that
# compile to stage3.s, and the selfhost-emitted stage2/stage3 assembly must be
# byte-identical.
#
# Set TYPELISP_BOOTSTRAP_STAGE1_PATH_FILE to persist the stage1 compiler path for
# callers that want to reuse the freshly bootstrapped compiler. Set
# TYPELISP_BOOTSTRAP_STAGE1_ONLY=1 to stop after linking stage1; normal runs
# continue through the stage2/stage3 fixpoint.
#
# refs #47.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

case "$(uname -s)" in
    Linux*) ;;
    *)
        echo "bootstrap fixpoint check is Linux-only (requires as + ld)" >&2
        exit 0
        ;;
esac

command -v as >/dev/null 2>&1 || {
    echo "bootstrap fixpoint check requires 'as'" >&2
    exit 1
}
command -v ld >/dev/null 2>&1 || {
    echo "bootstrap fixpoint check requires 'ld'" >&2
    exit 1
}

if [ "$#" -gt 1 ]; then
    echo "usage: $0 [typelisp-binary]" >&2
    exit 2
fi

if [ "$#" -eq 1 ]; then
    COMPILER=$1
elif [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    # Fallback only for local development; CI should pass a fetched stage0
    # compiler through TYPELISP_BIN until #793/#795 remove Rust stage0.
    cargo build --release --quiet
    COMPILER="$ROOT/target/release/typelisp"
fi

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

HEARTBEAT_SECONDS=${TYPELISP_BOOTSTRAP_HEARTBEAT_SECONDS:-30}

run_with_heartbeat() {
    heartbeat_label=$1
    shift

    "$@" &
    heartbeat_cmd_pid=$!
    (
        while kill -0 "$heartbeat_cmd_pid" 2>/dev/null; do
            sleep "$HEARTBEAT_SECONDS"
            if kill -0 "$heartbeat_cmd_pid" 2>/dev/null; then
                echo "[bootstrap] ${heartbeat_label} still running"
            fi
        done
    ) &
    heartbeat_pid=$!

    heartbeat_status=0
    wait "$heartbeat_cmd_pid" || heartbeat_status=$?
    kill "$heartbeat_pid" 2>/dev/null || true
    wait "$heartbeat_pid" 2>/dev/null || true
    return "$heartbeat_status"
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

STAGE1_ASM="$WORKDIR/stage1.s"
STAGE1_OBJ="$WORKDIR/stage1.o"
STAGE1_BIN="$WORKDIR/stage1"
STAGE2_ASM="$WORKDIR/stage2.s"
STAGE2_OBJ="$WORKDIR/stage2.o"
STAGE2_BIN="$WORKDIR/stage2"
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

check_stage1_compile_cli() {
    echo "[bootstrap] stage1 compile CLI smoke"
    run_stage1_cli_capture \
        stage1-compile-command \
        "$STAGE1_BIN" compile "$STAGE1_CLI_SRC" \
        --target linux-x86_64 \
        --backend-mode scalar \
        --opt-level 0 \
        --stdlib-root "$ROOT/stdlib" \
        --stdlib-root "$ROOT/selfhost"
    [ -s "$STAGE1_CLI_ASM" ] || {
        echo "stage1 compile command did not write default assembly: $STAGE1_CLI_ASM" >&2
        exit 1
    }
    assert_contains "$STAGE1_CLI_ASM" "main:"

    run_stage1_cli_capture \
        stage1-compile-direct \
        "$STAGE1_BIN" "$STAGE1_CLI_SRC" -o "$STAGE1_CLI_DIRECT_ASM"
    [ -s "$STAGE1_CLI_DIRECT_ASM" ] || {
        echo "stage1 direct bootstrap form did not write assembly: $STAGE1_CLI_DIRECT_ASM" >&2
        exit 1
    }
    assert_contains "$STAGE1_CLI_DIRECT_ASM" "main:"

    run_stage1_cli_capture \
        stage1-compile-emit-ir \
        "$STAGE1_BIN" compile "$STAGE1_CLI_SRC" --emit-ir --stdlib-root "$ROOT/stdlib"
    [ -s "$STAGE1_CLI_IR" ] || {
        echo "stage1 compile --emit-ir did not write default IR: $STAGE1_CLI_IR" >&2
        exit 1
    }
    assert_contains "$STAGE1_CLI_IR" "typelisp-ir-summary v1"

    run_stage1_cli_capture stage1-help "$STAGE1_BIN" help
    assert_contains "$WORKDIR/stage1-help.stderr" "typelisp compile <file.tl>"

    run_stage1_cli_expect_failure stage1-missing-command "$STAGE1_BIN"
    assert_contains "$WORKDIR/stage1-missing-command.stderr" "typelisp: expected command"
    assert_contains "$WORKDIR/stage1-missing-command.stderr" "Usage:"

    run_stage1_cli_expect_failure stage1-missing-source "$STAGE1_BIN" compile
    assert_contains "$WORKDIR/stage1-missing-source.stderr" "compile: expected source path"

    run_stage1_cli_expect_failure stage1-unknown-command "$STAGE1_BIN" check "$STAGE1_CLI_SRC"
    assert_contains "$WORKDIR/stage1-unknown-command.stderr" "Unknown command: check"
    assert_contains "$WORKDIR/stage1-unknown-command.stderr" "Usage:"
}

echo "[bootstrap] stage0 -> stage1.s"
run_with_heartbeat "stage0 -> stage1.s" "$COMPILER" compile selfhost/compile.tl -o "$STAGE1_ASM"

echo "[bootstrap] link stage1"
as "$STAGE1_ASM" -o "$STAGE1_OBJ"
ld "$STAGE1_OBJ" -o "$STAGE1_BIN"

check_stage1_compile_cli

if [ "${TYPELISP_BOOTSTRAP_STAGE1_ONLY:-}" = 1 ]; then
    write_stage1_path
    echo "bootstrap stage1 build passed"
    exit 0
fi

echo "[bootstrap] stage1 -> stage2.s"
run_with_heartbeat "stage1 -> stage2.s" "$STAGE1_BIN" selfhost/compile.tl -o "$STAGE2_ASM"

echo "[bootstrap] link stage2"
as "$STAGE2_ASM" -o "$STAGE2_OBJ"
ld "$STAGE2_OBJ" -o "$STAGE2_BIN"

echo "[bootstrap] stage2 -> stage3.s"
run_with_heartbeat "stage2 -> stage3.s" "$STAGE2_BIN" selfhost/compile.tl -o "$STAGE3_ASM"

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
echo "bootstrap fixpoint check passed"
