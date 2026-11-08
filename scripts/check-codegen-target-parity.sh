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
cpu_intrinsic_shadow tests/integration/cpu_intrinsic_shadow.tl
cpu_intrinsic_local_shadow tests/integration/cpu_intrinsic_local_shadow.tl
cpu_intrinsic_unshadowed tests/integration/cpu_intrinsic_unshadowed.tl
cpu_intrinsic_import_shadow tests/integration/cpu_intrinsic_import_shadow.tl
arena_caller_reference_store tests/integration/arena_caller_reference_store.tl
arena_caller_reference_store_contexts tests/integration/arena_caller_reference_store_contexts.tl
stdlib_net_parity tests/integration/stdlib_net_parity.tl
stdlib_net_owner_parity tests/integration/stdlib_net_owner_parity.tl
net_tls_transcript stdlib/tests/net_tls_transcript_parity.tl
crypto_hkdf_sha256 stdlib/tests/crypto_hkdf_sha256_parity.tl
crypto_hmac_sha256 stdlib/tests/crypto_hmac_sha256_parity.tl
crypto_aes128_gcm stdlib/tests/crypto_aes128_gcm_parity.tl
control_flow tests/integration/control_flow.tl
char_comparisons tests/integration/char_comparisons.tl
char_comparison_immediates tests/integration/char_comparison_immediates.tl
enum_match tests/integration/enum_match.tl
enum_constructor_owner_layout tests/integration/enum_constructor_owner_layout.tl
enum_constructor_owner_root tests/integration/enum_constructor_owner_root.tl
fixed_array tests/integration/fixed_array.tl
fixed_array_result_forward tests/golden/fixed_array_result_forward.tl
functions tests/integration/functions.tl
lambda_capture_struct_enum tests/integration/lambda_capture_struct_enum.tl
macro_body_sequence tests/integration/macro_body_sequence.tl
macro_dotted_global tests/integration/macro_dotted_global.tl
macro_dotted_global_inside tests/integration/macro_dotted_global_inside.tl
macro_dotted_global_matrix tests/integration/macro_dotted_global_matrix.tl
macro_struct_pattern tests/integration/macro_struct_pattern.tl
macro_struct_pattern_root tests/integration/macro_struct_pattern_root.tl
macro_dotted_root_borrow tests/integration/macro_dotted_root_borrow.tl
macro_dotted_root_layout tests/integration/macro_dotted_root_layout.tl
macro_dotted_root_mut_borrow tests/integration/macro_dotted_root_mut_borrow.tl
macro_dotted_root_nested tests/integration/macro_dotted_root_nested.tl
macro_dotted_root_nested_borrow tests/integration/macro_dotted_root_nested_borrow.tl
macro_dotted_root_ref_borrow tests/integration/macro_dotted_root_ref_borrow.tl
macro_dotted_root_same tests/integration/macro_dotted_root_same.tl
macro_dotted_root_scalar tests/integration/macro_dotted_root_scalar.tl
macro_dotted_root_small tests/integration/macro_dotted_root_small.tl
macro_dotted_root_narrow_borrow tests/integration/macro_dotted_root_narrow_borrow.tl
macro_dotted_root_wide_borrow tests/integration/macro_dotted_root_wide_borrow.tl
macro_dotted_root_write_borrow tests/integration/macro_dotted_root_write_borrow.tl
macro_dotted_root_scalar_borrow tests/integration/macro_dotted_root_scalar_borrow.tl
macro_dotted_root_noncall_borrow tests/integration/macro_dotted_root_noncall_borrow.tl
macro_dotted_root_replace tests/integration/macro_dotted_root_replace.tl
many_args tests/integration/many_args.tl
register_group_phi_return tests/integration/register_group_phi_return.tl
register_pair_struct tests/integration/register_pair_struct.tl
register_resident_enum tests/integration/register_resident_enum.tl
gep_large_displacement tests/integration/gep_large_displacement.tl
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
    if grep -nE 'BackendTarget|compiler-backend-target|target-windows|target-linux|windows-x86_64|linux-x86_64|lower-mode-windows|lower-mode-linux' src/compiler_optimize.tl; then
        echo "optimizer target parity violation: compiler_optimize.tl must stay target-independent" >&2
        exit 1
    fi
}

check_target_dispatch_boundary() {
    scripts/check-codegen-target-dispatch.sh --self-test
    scripts/check-codegen-target-dispatch.sh
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

# The crypto reclaim layout intentionally varies by target (D-C155). Preserve
# aggregate-IR parity for the cryptographic implementation with a no-op boundary
# double, while checking that the real source retains distinct target layouts.
# Native residue/mutant and complete-body shape gates cover the actual mechanism.
prepare_crypto_parity() {
    mkdir -p "$WORKDIR"
    CRYPTO_PARITY_ROOT=$(mktemp -d "$WORKDIR/crypto-target-neutral.XXXXXX")
    cp -R "$ROOT/stdlib" "$CRYPTO_PARITY_ROOT/stdlib"
    cp "$ROOT/stdlib/tests/crypto_aes128_gcm_parity.tl" "$CRYPTO_PARITY_ROOT/main.tl"
    cat > "$CRYPTO_PARITY_ROOT/stdlib/crypto_stack_scrub.tl" <<'EOF'
; Test double for aggregate-IR comparison only; never assembled or executed.
(define (block!) : unit unit)
(define (setup!) : unit unit)
(define (tree!) : unit unit)
EOF
    for crypto_target in linux-x86_64 windows-x86_64; do
        "$COMPILER" compile stdlib/tests/crypto_aes128_gcm_parity.tl \
            --emit-ir --target "$crypto_target" --opt-level 0 \
            --stdlib-root "$ROOT/stdlib" -o "$CRYPTO_PARITY_ROOT/$crypto_target.ir"
    done
    if cmp -s "$CRYPTO_PARITY_ROOT/linux-x86_64.ir" "$CRYPTO_PARITY_ROOT/windows-x86_64.ir"; then
        echo 'crypto reclaim target layout unexpectedly lost its cfg selection' >&2
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
    if [ "$name" = crypto_aes128_gcm ]; then
        # Compile inside the shadow source tree: the importing source tree has
        # precedence over explicit stdlib roots, including transitive imports.
        case "$COMPILER" in /* | [A-Za-z]:*) parity_compiler=$COMPILER ;; *) parity_compiler="$ROOT/$COMPILER" ;; esac
        case "$out" in /* | [A-Za-z]:*) parity_out=$out ;; *) parity_out="$ROOT/$out" ;; esac
        (cd "$CRYPTO_PARITY_ROOT" && "$parity_compiler" compile main.tl \
            --emit-ir --target "$target" --opt-level "$opt_level" \
            --stdlib-root stdlib -o "$parity_out")
        if [ "$opt_level" = 0 ] && cmp -s "$out" "$CRYPTO_PARITY_ROOT/$target.ir"; then
            echo "crypto reclaim test double was not selected for $target" >&2
            exit 1
        fi
    else
        "$COMPILER" compile "$source" \
            --emit-ir --target "$target" --opt-level "$opt_level" \
            --stdlib-root "$ROOT/stdlib" -o "$out"
    fi
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
check_target_dispatch_boundary
check_emit_ir_target_honored
prepare_crypto_parity

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
