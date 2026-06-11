#!/usr/bin/env sh
set -eu

usage() {
    echo "usage: $0 [--self-test] [typelisp-binary]" >&2
}

self_test=0
compiler_arg=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --self-test)
            self_test=1
            ;;
        -*)
            usage
            exit 2
            ;;
        *)
            if [ -n "$compiler_arg" ]; then
                usage
                exit 2
            fi
            compiler_arg=$1
            ;;
    esac
    shift
done

case "$(uname -s)" in
    Linux* | MINGW* | MSYS* | CYGWIN*) ;;
    *)
        echo "codegen target parity check is unsupported on this host" >&2
        exit 1
        ;;
esac

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

WORKDIR=${CODEGEN_TARGET_PARITY_DIR:-target/codegen-target-parity}
LINUX_DIR="$WORKDIR/linux"
WINDOWS_DIR="$WORKDIR/windows"

if [ -n "$compiler_arg" ]; then
    COMPILER=$compiler_arg
elif [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

corpus() {
    cat <<'EOF'
arithmetic tests/integration/arithmetic.tl
control_flow tests/integration/control_flow.tl
enum_match tests/integration/enum_match.tl
fixed_array tests/integration/fixed_array.tl
functions tests/integration/functions.tl
lambda_capture_struct_enum tests/integration/lambda_capture_struct_enum.tl
many_args tests/integration/many_args.tl
register_group_phi_return tests/integration/register_group_phi_return.tl
register_pair_struct tests/integration/register_pair_struct.tl
register_resident_enum tests/integration/register_resident_enum.tl
tail_direct_stack_args tests/integration/tail_direct_stack_args.tl
tree tests/integration/tree.tl
tuple_values tests/integration/tuple_values.tl
unit_functions tests/integration/unit_functions.tl
EOF
}

opt_levels() {
    printf '%s\n' 0 1 2
}

check_optimizer_target_free() {
    if grep -nE 'BackendTarget|compiler-backend-target|target-windows|target-linux|windows-x86_64|linux-x86_64|lower-mode-windows|lower-mode-linux' selfhost/compiler_optimize.tl; then
        echo "optimizer target parity violation: compiler_optimize.tl must stay target-independent" >&2
        exit 1
    fi
}

check_emit_ir_target_honored() {
    probe_dir="$WORKDIR/target-cfg-probe"
    rm -rf "$probe_dir"
    mkdir -p "$probe_dir"
    probe="$probe_dir/main.tl"
    cat > "$probe" <<'EOF'
(cfg target-linux
  (define (target-shape) : i64 1))
(cfg target-windows
  (define (target-shape) : i64 (+ 1 2)))
(define (main) : i64 (target-shape))
EOF

    "$COMPILER" compile "$probe" \
        --emit-ir \
        --target linux-x86_64 \
        --opt-level 0 \
        --stdlib-root "$ROOT/stdlib" \
        -o "$probe_dir/linux.ir"
    "$COMPILER" compile "$probe" \
        --emit-ir \
        --target windows-x86_64 \
        --opt-level 0 \
        --stdlib-root "$ROOT/stdlib" \
        -o "$probe_dir/windows.ir"

    if cmp -s "$probe_dir/linux.ir" "$probe_dir/windows.ir"; then
        echo "compile --emit-ir --target did not affect target cfg lowering" >&2
        exit 1
    fi
}

compile_ir() {
    target=$1
    opt_level=$2
    name=$3
    source=$4
    out_dir=$5

    out="$out_dir/opt${opt_level}_$name.ir"
    echo "[$target opt$opt_level] $source -> $out"
    "$COMPILER" compile "$source" \
        --emit-ir \
        --target "$target" \
        --opt-level "$opt_level" \
        --stdlib-root "$ROOT/stdlib" \
        -o "$out"
}

compile_all() {
    out_dir=$1
    target=$2

    mkdir -p "$out_dir"
    opt_levels | while read -r opt_level; do
        corpus | while read -r name source; do
            [ -n "$name" ] || continue
            if [ ! -f "$source" ]; then
                echo "corpus file not found: $source" >&2
                exit 1
            fi
            compile_ir "$target" "$opt_level" "$name" "$source" "$out_dir"
        done
    done
}

compare_outputs() {
    failed_marker="$WORKDIR/.codegen-target-parity-failed"
    rm -f "$failed_marker"

    opt_levels | while read -r opt_level; do
        corpus | while read -r name _source; do
            [ -n "$name" ] || continue
            left="$LINUX_DIR/opt${opt_level}_$name.ir"
            right="$WINDOWS_DIR/opt${opt_level}_$name.ir"

            if ! cmp -s "$left" "$right"; then
                echo "cross-target IR mismatch: opt$opt_level $name" >&2
                if command -v diff >/dev/null 2>&1; then
                    diff -u "$left" "$right" || true
                else
                    cmp -l "$left" "$right" | sed -n '1,40p' || true
                fi
                : > "$failed_marker"
            fi
        done
    done

    [ ! -f "$failed_marker" ]
}

check_optimizer_target_free
check_emit_ir_target_honored

rm -rf "$LINUX_DIR" "$WINDOWS_DIR"
mkdir -p "$LINUX_DIR" "$WINDOWS_DIR"

compile_all "$LINUX_DIR" linux-x86_64
compile_all "$WINDOWS_DIR" windows-x86_64

if [ "$self_test" -eq 1 ]; then
    if ! compare_outputs; then
        echo "--self-test setup failed: fresh target IR outputs already differ" >&2
        exit 1
    fi

    first_name=$(corpus | sed -n '1s/ .*//p')
    printf '\n# codegen-target-parity self-test mutation\n' >> "$WINDOWS_DIR/opt0_$first_name.ir"
    if compare_outputs; then
        echo "--self-test failed: mutated target IR output was not detected" >&2
        exit 1
    fi
    echo "--self-test passed: mutated target IR output was detected"
    exit 0
fi

if ! compare_outputs; then
    exit 1
fi

case_count=$(corpus | wc -l | tr -d ' ')
echo "codegen target parity check passed for $case_count files across 3 opt levels"
