#!/usr/bin/env bash
# verify-stdlib-selfhost.sh — prove the canonical stdlib witness programs are
# accepted (or correctly rejected) by the SELFHOST compiler frontend
# (selfhost cli `check`: parse + typecheck via the selfhost
# parser/typechecker), complementing scripts/verify-stdlib.sh which drives the
# same witnesses through the full self-hosted compiler.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

HOST_OS=linux
HOST_TARGET=linux-x86_64
case "$(uname -s)" in
    Linux*)
        HOST_OS=linux
        HOST_TARGET=linux-x86_64
        ;;
    MINGW* | MSYS* | CYGWIN*)
        HOST_OS=windows
        HOST_TARGET=windows-x86_64
        ;;
esac
. "$ROOT/scripts/lib-gate.sh"
gate_compiler
case "$COMPILER" in
    *.exe) ;;
    *) [ "$HOST_OS" = windows ] && COMPILER="$COMPILER.exe" ;;
esac
gate_require_compiler
# Negative witnesses: the selfhost typechecker must REJECT these with the given
# diagnostic substring. Every other witness must be accepted (parse + typecheck
# clean). Keep this list in sync with the `expect-fail` rows of
# scripts/verify-stdlib.sh.
reject_diag() {
    case "$1" in
        stdlib/tests/crypto_aes128_gcm_clone_reject.tl)
            printf 'gen-clone: unsupported cleanup-owning type struct_stdlib.crypto_aes128_gcm/GcmKey at clone.deep' ;;
        stdlib/tests/crypto_aes128_gcm_format_reject.tl)
            printf 'format: unsupported nominal type' ;;
        stdlib/tests/crypto_aes128_gcm_key_reuse_reject.tl)
            printf 'use of moved value `key`' ;;
        stdlib/tests/crypto_aes128_gcm_tag_reject.tl)
            printf 'argument 5 type mismatch' ;;
        stdlib/tests/crypto_ghash_unsafe_reject.tl|stdlib/tests/crypto_aes128_gcm_unsafe_reject.tl)
            printf 'requires unsafe context' ;;
        stdlib/tests/net_tls_transcript_construct_reject.tl|stdlib/tests/net_tls_transcript_project_reject.tl)
            printf 'opaque type' ;;
        stdlib/tests/net_tls_transcript_escape_reject.tl)
            printf 'region-tagged value cannot escape with-arena' ;;
        stdlib/tests/string_raw_copy_function_value_reject.tl)
            printf 'is an unsafe callable and cannot be used as a plain function value' ;;
        stdlib/tests/string_raw_*_reject.tl|stdlib/tests/format_raw_fill_reject.tl|stdlib/tests/format_raw_copy_reject.tl|stdlib/tests/format_raw_debug_*_reject.tl)
            printf 'requires unsafe context' ;;
        stdlib/tests/arena_policy_escape_string.tl | stdlib/tests/arena_policy_escape_text_buf.tl)
            printf 'region-tagged value cannot escape with-arena' ;;
        stdlib/tests/arena_policy_escape_text_buf_borrowed.tl)
            printf 'typecheck: reference value would escape lexical scope' ;;
        stdlib/tests/comptime_string_literal_reject.tl)
            printf 'expr-string-value expects a string literal Expr' ;;
        stdlib/tests/concurrency_registry_unsafe_reject.tl)
            printf 'registry/concurrency-register requires unsafe context' ;;
        stdlib/tests/concurrency_registry_test_helpers_reject.tl)
            printf 'unbound name registry.concurrency-test-close-ok' ;;
        stdlib/tests/core_macros_cond_flat_reject.tl)
            printf 'typecheck: ExprClause macro operand expects bracket syntax' ;;
        stdlib/tests/core_macros_cond_missing_else.tl)
            printf 'cond requires a final [else ...] arm' ;;
        stdlib/tests/core_macros_cond_else_not_final.tl)
            printf 'cond allows [else ...] only as the final arm' ;;
        stdlib/tests/core_macros_cond_branch_mismatch.tl)
            printf 'typecheck: if branches must match' ;;
        stdlib/tests/core_macros_cond_non_bool.tl)
            printf 'typecheck: if condition must be bool' ;;
        stdlib/tests/core_macros_for_missing_protocol.tl)
            printf 'is missing protocol function into-iterator' ;;
        stdlib/tests/core_macros_for_offset_slots_reject.tl)
            printf 'is missing protocol function iterator' ;;
        stdlib/tests/core_macros_for_owned_dyn_array_reject.tl)
            printf 'sources must be borrowed: write (& source) or (&mut source)' ;;
        stdlib/tests/core_macros_any_missing_predicate.tl)
            printf 'any? expects one unannotated binding clause [name source] followed by one predicate' ;;
        stdlib/tests/crypto_sha512_unsafe_adapter_reject.tl)
            printf 'requires unsafe context' ;;
        stdlib/tests/crypto_sha1_git_unsafe_adapter_reject.tl)
            printf 'requires unsafe context' ;;
        stdlib/tests/crypto_sha256_unsafe_adapter_reject.tl)
            printf 'requires unsafe context' ;;
        stdlib/tests/crypto_aes_key_reuse_reject.tl)
            printf 'use of moved value `key`' ;;
        stdlib/tests/crypto_aes_variant_reject.tl)
            printf 'argument 1 type mismatch' ;;
        stdlib/tests/crypto_aes_clone_reject.tl)
            printf 'gen-clone: unsupported cleanup-owning type struct_stdlib.crypto_aes_core/Aes128Schedule at clone.deep' ;;
        stdlib/tests/crypto_aes_format_reject.tl)
            printf 'format: unsupported nominal type struct_stdlib.crypto_aes_core/Aes256Schedule' ;;
        stdlib/tests/crypto_aes_raw_reject.tl)
            printf 'cannot hold by value the opaque type stdlib.crypto_secret/SecretStorage' ;;
        stdlib/tests/crypto_aes_composed_reject.tl)
            printf 'encrypt-composed-128! requires unsafe context' ;;
        stdlib/tests/crypto_aes_rounds_reject.tl)
            printf 'encrypt-checked! requires unsafe context' ;;
        stdlib/tests/crypto_hkdf_sha256_construct_reject.tl|stdlib/tests/crypto_hkdf_sha256_consumer_reject.tl)
            printf 'construction of sealed handle type stdlib.crypto_hkdf_sha256/HkdfSha256Prk' ;;
        stdlib/tests/crypto_hkdf_sha256_okm_reject.tl)
            printf 'construction of sealed handle type stdlib.crypto_hkdf_sha256/HkdfSha256Okm' ;;
        stdlib/tests/crypto_hkdf_sha256_view_reject.tl|stdlib/tests/crypto_hkdf_sha256_okm_view_reject.tl)
            printf 'opaque type' ;;
        stdlib/tests/crypto_hkdf_sha256_clone_reject.tl)
            printf 'gen-clone: unsupported cleanup-owning type struct_stdlib.crypto_hkdf_sha256/HkdfSha256Prk at clone.deep' ;;
        stdlib/tests/crypto_hkdf_sha256_unsafe_reject.tl|stdlib/tests/crypto_hkdf_sha256_okm_unsafe_reject.tl)
            printf 'requires unsafe context' ;;
        stdlib/tests/crypto_hmac_sha256_storage_reject.tl)
            printf 'opaque type' ;;
        stdlib/tests/crypto_hmac_sha256_unsafe_reject.tl)
            printf 'requires unsafe context' ;;
        stdlib/tests/crypto_hmac_sha256_clone_reject.tl)
            printf 'gen-clone: unsupported cleanup-owning type struct_stdlib.crypto_hmac_sha256/HmacSha256State at clone.deep' ;;
        stdlib/tests/crypto_hmac_sha256_secret_tag_reject.tl)
            printf 'type mismatch' ;;
        stdlib/tests/crypto_secret_unsafe_accessor_reject.tl)
            printf 'crypto_secret/fixed-read-pointer requires unsafe context' ;;
        stdlib/tests/crypto_secret_storage_read_reject.tl)
            printf 'cannot hold by value the opaque type stdlib.crypto_secret/SecretStorage' ;;
        stdlib/tests/crypto_secret_clone_reject.tl)
            printf 'gen-clone: unsupported cleanup-owning type struct_stdlib.crypto_secret/SecretFixed at clone.deep' ;;
        stdlib/tests/crypto_secret_use_after_close_reject.tl)
            printf 'use of moved value `owner`' ;;
        stdlib/tests/env_nonmatching_count_unsafe_reject.tl)
            printf 'env/linux-nonmatching-count requires unsafe context' ;;
        stdlib/tests/env_rebuild_unsafe_reject.tl)
            printf 'env/linux-rebuild! requires unsafe context' ;;
        stdlib/tests/env_rebuild_alias_unsafe_reject.tl)
            printf 'e/linux-rebuild! requires unsafe context' ;;
        stdlib/tests/env_rebuild_function_value_reject.tl)
            printf 'env/linux-rebuild! is an unsafe callable and cannot be used as a plain function value' ;;
        stdlib/tests/env_unlock_unsafe_reject.tl)
            printf 'env/linux-unlock! requires unsafe context' ;;
        stdlib/tests/format_nonliteral_template_reject.tl)
            printf 'format: template must be a string literal' ;;
        stdlib/tests/format_println_nonliteral_template_reject.tl)
            printf 'format: template must be a string literal' ;;
        stdlib/tests/format_eprintln_nonliteral_template_reject.tl)
            printf 'format: template must be a string literal' ;;
        stdlib/tests/format_writeln_nonliteral_template_reject.tl)
            printf 'format: template must be a string literal' ;;
        stdlib/tests/format_writeln_missing_writer_reject.tl)
            printf 'macro call has too few arguments' ;;
        stdlib/tests/format_bare_capture_reject.tl)
            printf "format: bare '_' is not a captured identifier" ;;
        stdlib/tests/format_duplicate_named_reject.tl)
            printf 'format: duplicate named argument name' ;;
        stdlib/tests/format_debug_nominal_reject.tl)
            printf 'format: Debug is not implemented for nominal type' ;;
        stdlib/tests/format_debug_pointer_safe_reject.tl)
            printf 'requires unsafe context' ;;
        stdlib/tests/format_debug_tuple_reject.tl)
            printf 'format: Debug is not implemented for type tuple_' ;;
        stdlib/tests/format_debug_box_reject.tl)
            printf 'format: Debug is not implemented for type box_' ;;
        stdlib/tests/format_exponent_bool_reject.tl)
            printf "format: 'e' selector requires an integer or float argument; got bool" ;;
        stdlib/tests/format_exponent_char_reject.tl)
            printf "format: 'E' selector requires an integer or float argument; got char" ;;
        stdlib/tests/format_exponent_nominal_reject.tl | stdlib/tests/format_exponent_pointer_reject.tl)
            printf "format: 'e' selector requires an integer or float argument" ;;
        stdlib/tests/format_exponent_reference_reject.tl)
            printf "format: 'E' selector requires an integer or float argument" ;;
        stdlib/tests/format_exponent_string_reject.tl)
            printf "format: 'e' selector requires an integer or float argument; got String" ;;
        stdlib/tests/format_dynamic_precision_integer_type_reject.tl)
            printf 'format: dynamic precision argument must have exact type i64' ;;
        stdlib/tests/format_dynamic_precision_index_reject.tl)
            printf 'format: dynamic precision argument index is out of range: 2' ;;
        stdlib/tests/format_dynamic_precision_type_reject.tl)
            printf 'format: dynamic precision argument must have exact type i64' ;;
        stdlib/tests/format_dynamic_width_index_reject.tl)
            printf 'format: dynamic width argument index is out of range: 2' ;;
        stdlib/tests/format_dynamic_width_type_reject.tl)
            printf 'format: dynamic width argument must have exact type i64' ;;
        stdlib/tests/format_index_out_of_range_reject.tl)
            printf 'format: positional argument index is out of range: 2' ;;
        stdlib/tests/format_index_overflow_reject.tl)
            printf 'format: positional argument index overflow' ;;
        stdlib/tests/format_inner_whitespace_reject.tl)
            printf "format: whitespace is only allowed immediately before '}'" ;;
        stdlib/tests/format_malformed_capture_reject.tl)
            printf 'format: malformed captured argument identifier' ;;
        stdlib/tests/format_malformed_index_reject.tl)
            printf 'format: malformed positional argument index' ;;
        stdlib/tests/format_multibyte_fill_reject.tl)
            printf 'format: fill must be exactly one TypeLisp byte before alignment' ;;
        stdlib/tests/format_named_nonidentifier_reject.tl)
            printf 'format: named argument name must be an identifier' ;;
        stdlib/tests/format_non_ascii_whitespace_reject.tl)
            printf 'format: placeholder names and whitespace are ASCII-only' ;;
        stdlib/tests/format_owner_ambiguous_reject.tl)
            printf 'format: ambiguous owner hooks for' ;;
        stdlib/tests/format_owner_missing_reject.tl)
            printf 'format: unsupported nominal type' ;;
        stdlib/tests/format_owner_wrong_signature_reject.tl)
            printf 'format: owner hook has wrong signature for' ;;
        stdlib/tests/format_positional_after_named_reject.tl)
            printf 'format: positional argument follows named argument' ;;
        stdlib/tests/format_precision_duplicate_dollar_reject.tl)
            printf 'format: malformed, duplicated, or out-of-order format specifier' ;;
        stdlib/tests/format_precision_duplicate_star_reject.tl)
            printf 'format: malformed, duplicated, or out-of-order format specifier' ;;
        stdlib/tests/format_precision_missing_reject.tl)
            printf "format: precision requires a count or '*'" ;;
        stdlib/tests/format_precision_negative_literal_reject.tl)
            printf 'format: malformed precision count' ;;
        stdlib/tests/format_precision_overflow_reject.tl)
            printf 'format: precision integer overflow' ;;
        stdlib/tests/format_precision_unknown_capture_reject.tl)
            printf 'typecheck: unbound name missing' ;;
        stdlib/tests/format_plus_nonnumeric_reject.tl)
            printf "format: '+' sign requires a numeric argument" ;;
        stdlib/tests/format_radix_bool_reject.tl|\
        stdlib/tests/format_radix_char_reject.tl|\
        stdlib/tests/format_radix_f32_reject.tl|\
        stdlib/tests/format_radix_f64_reject.tl|\
        stdlib/tests/format_radix_nominal_reject.tl|\
        stdlib/tests/format_radix_pointer_reject.tl|\
        stdlib/tests/format_radix_reference_reject.tl|\
        stdlib/tests/format_radix_string_reject.tl)
            printf 'requires a fixed-width integer argument; got' ;;
        stdlib/tests/format_raw_capture_reject.tl)
            printf "format: Rust raw identifiers use the TypeLisp spelling without 'r#'" ;;
        stdlib/tests/format_specifier_order_reject.tl)
            printf 'format: malformed, duplicated, or out-of-order format specifier' ;;
        stdlib/tests/format_star_precision_too_few_reject.tl)
            printf 'format: not enough arguments for placeholders' ;;
        stdlib/tests/format_too_few_args_reject.tl)
            printf 'format: not enough arguments for placeholders' ;;
        stdlib/tests/format_too_many_args_reject.tl)
            printf 'format: not enough placeholders for arguments' ;;
        stdlib/tests/format_unknown_capture_reject.tl)
            printf 'typecheck: unbound name missing' ;;
        stdlib/tests/format_unused_named_reject.tl)
            printf 'format: unused named argument unused' ;;
        stdlib/tests/format_width_overflow_reject.tl)
            printf 'format: width integer overflow' ;;
        stdlib/tests/io_caller_result_escape.tl)
            printf 'typecheck: reference value would escape lexical scope' ;;
        stdlib/tests/local_ipc_forged_connection_reject.tl)
            printf 'construction of sealed handle type stdlib.local_ipc/LocalIpcConnection' ;;
        stdlib/tests/local_ipc_connection_copy_reject.tl)
            printf 'cleanup-required resource already has a cleanup owner' ;;
        stdlib/tests/local_ipc_raw_helper_reject.tl)
            printf 'local_ipc/io-once requires unsafe context' ;;
        stdlib/tests/net_owner_copy_reject.tl)
            printf 'cleanup-required resource already has a cleanup owner' ;;
        stdlib/tests/net_owner_forge_reject.tl)
            printf 'construction of sealed handle type stdlib.net/TcpStream' ;;
        stdlib/tests/net_raw_helper_reject.tl)
            printf 'net/publish requires unsafe context' ;;
        stdlib/tests/math_sqrt_non_float_reject.tl)
            printf 'math.sqrt: expected f64 or f32, found i64' ;;
        stdlib/tests/math_exp_non_float_reject.tl)
            printf 'math.exp: expected f64 or f32, found i64' ;;
        stdlib/tests/math_log_non_float_reject.tl)
            printf 'math.log: expected f64 or f32, found i64' ;;
        stdlib/tests/math_pow_non_float_reject.tl)
            printf 'math.pow: expected f64 or f32, found i64' ;;
        stdlib/tests/math_pow_mismatched_types_reject.tl)
            printf 'math.pow: exponent type must match base type f64, found f32' ;;
        stdlib/tests/math_mul_add_non_float_reject.tl)
            printf 'math.mul-add: expected f64 or f32, found i64' ;;
        stdlib/tests/math_mul_add_mismatched_types_reject.tl)
            printf 'math.mul-add: operand types must match f64, found f32' ;;
        stdlib/tests/hashmap_value_borrow_escape.tl)
            printf 'typecheck: reference value would escape lexical scope' ;;
        stdlib/tests/hashmap_value_borrow_insert_live.tl)
            printf 'typecheck: cannot mutably borrow borrowed place `m`' ;;
        stdlib/tests/hashmap_value_borrow_remove_live.tl)
            printf 'typecheck: cannot mutably borrow borrowed place `m`' ;;
        stdlib/tests/hashmap_value_borrow_put_live.tl)
            printf 'typecheck: cannot mutably borrow borrowed place `m`' ;;
        stdlib/tests/hashmap_value_borrow_resize_live.tl)
            printf 'typecheck: cannot mutably borrow borrowed place `m`' ;;
        stdlib/tests/hashmap_mut_borrow_insert_or_update_live.tl)
            printf 'typecheck: cannot mutably borrow borrowed place `m`' ;;
        stdlib/tests/hashmap_mut_entry_double_live.tl)
            printf 'typecheck: cannot mutably borrow borrowed place `m`' ;;
        stdlib/tests/hashmap_mut_entry_put_live.tl)
            printf 'typecheck: cannot mutably borrow borrowed place `m`' ;;
        stdlib/tests/hashmap_mut_entry_resize_live.tl)
            printf 'typecheck: cannot mutably borrow borrowed place `m`' ;;
        stdlib/tests/hashmap_mut_entry_value_borrow_live.tl)
            printf 'typecheck: cannot mutably borrow borrowed place `m`' ;;
        stdlib/tests/hashmap_macro_value_borrow_insert_live.tl)
            printf 'typecheck: cannot mutably borrow borrowed place `m`' ;;
        stdlib/tests/hashmap_macro_mut_entry_insert_live.tl)
            printf 'typecheck: cannot mutably borrow borrowed place `m`' ;;
        stdlib/tests/process_borrowed_escape.tl)
            printf 'typecheck: reference value would escape lexical scope' ;;
        stdlib/tests/queue_cleanup_element_reject.tl)
            printf 'queue.deque: cleanup-owning element type struct_QueueCleanupElement is unsupported' ;;
        stdlib/tests/string_caller_result_escape.tl)
            printf 'typecheck: reference value would escape lexical scope' ;;
        stdlib/tests/vector_native_slice_escape.tl)
            printf 'typecheck: reference value would escape lexical scope' ;;
        stdlib/tests/vector_native_slice_grow_live.tl)
            printf 'typecheck: cannot mutably borrow borrowed place `items`' ;;
        stdlib/tests/vector_native_slice_split_grow_live.tl)
            printf 'typecheck: cannot mutably borrow borrowed place `items`' ;;
        stdlib/tests/vector_native_slice_alias_reject.tl)
            printf 'typecheck: cannot immutably borrow mutably borrowed place `items`' ;;
        *) printf '' ;;
    esac
}

# Each witness is checked once in a single `check --batch` stream (each entry
# tears down its own arena and resets compiler state). A crash is a real
# compiler bug, not a flake — do not retry it (see the no-retry policy in
# scripts/ci-verify.sh).

WORKDIR="$ROOT/target/stdlib-selfhost-verify"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

BATCH_LIST="$WORKDIR/witnesses.list"
BATCH_META="$WORKDIR/witnesses.meta"
BATCH_OUT="$WORKDIR/batch.stdout"
BATCH_ERR="$WORKDIR/batch.stderr"
: > "$BATCH_LIST"
: > "$BATCH_META"

checked=0
for witness in stdlib/tests/*.tl; do
    checked=$((checked + 1))
    expect="$(reject_diag "$witness")"
    printf '%s\n' "$witness" >> "$BATCH_LIST"
    printf '%s\t%s\n' "$witness" "$expect" >> "$BATCH_META"
done

if [ "$checked" -eq 0 ]; then
    echo "verify-stdlib-selfhost: no stdlib/tests/*.tl witnesses found" >&2
    exit 1
fi

batch_list_host="$BATCH_LIST"
if [ "$HOST_OS" = windows ] && command -v cygpath >/dev/null 2>&1; then
    batch_list_host="$(cygpath -m "$BATCH_LIST")"
fi

if "$COMPILER" check --batch "$batch_list_host" \
    --target "$HOST_TARGET" \
    --stdlib-root stdlib \
    < /dev/null > "$BATCH_OUT" 2> "$BATCH_ERR"; then
    batch_rc=0
else
    batch_rc=$?
fi

if [ "$batch_rc" -ne 0 ] || [ -s "$BATCH_ERR" ]; then
    echo "verify-stdlib-selfhost: check --batch failed (rc=$batch_rc)" >&2
    if [ -s "$BATCH_ERR" ]; then
        sed 's/^/  /' "$BATCH_ERR" >&2 || true
    fi
    echo "verify-stdlib-selfhost: FAILED" >&2
    exit 1
fi

fail=0
if ! awk -F '\t' -v meta_file="$BATCH_META" -v batch_file="$BATCH_OUT" '
    BEGIN {
        total = 0
        while ((getline mline < meta_file) > 0) {
            sub(/\r$/, "", mline)
            tab = index(mline, "\t")
            if (tab == 0) {
                print "FAIL: malformed witness meta row: " mline > "/dev/stderr"
                exit 1
            }
            m_wit[total] = substr(mline, 1, tab - 1)
            m_exp[total] = substr(mline, tab + 1)
            total++
        }
        close(meta_file)
        if (total == 0) {
            print "FAIL: empty witness list" > "/dev/stderr"
            exit 1
        }
        failed = 0
        for (i = 0; i < total; i++) {
            if ((getline hdr < batch_file) <= 0) {
                print "FAIL: batch stream truncated before entry " i " (" m_wit[i] ")" > "/dev/stderr"
                exit 1
            }
            sub(/\r$/, "", hdr)
            if (hdr !~ /^CHECK_BATCH_ENTRY\|[0-9]+\|[0-9]+\|[0-9]+\|[0-9]+\|/) {
                print "FAIL: malformed batch header at entry " i ": " hdr > "/dev/stderr"
                exit 1
            }
            split(hdr, hf, "|")
            if ((hf[2] + 0) != i) {
                print "FAIL: batch entry index mismatch: expected " i ", got " hf[2] > "/dev/stderr"
                exit 1
            }
            code = hf[3] + 0
            out_n = hf[4] + 0
            err_n = hf[5] + 0
            combined = ""
            for (k = 1; k <= out_n; k++) {
                if ((getline line < batch_file) <= 0) {
                    print "FAIL: " m_wit[i] " truncated batch stdout" > "/dev/stderr"
                    exit 1
                }
                sub(/\r$/, "", line)
                combined = (combined == "" ? line : combined "\n" line)
            }
            for (k = 1; k <= err_n; k++) {
                if ((getline line < batch_file) <= 0) {
                    print "FAIL: " m_wit[i] " truncated batch stderr" > "/dev/stderr"
                    exit 1
                }
                sub(/\r$/, "", line)
                combined = (combined == "" ? line : combined "\n" line)
            }
            wit = m_wit[i]
            expect = m_exp[i]
            if (expect != "") {
                if (code != 0 && index(combined, expect) > 0) {
                    print "  ok (reject): " wit
                } else {
                    if (code == 0) {
                        print "FAIL: " wit " expected selfhost rejection but it passed" > "/dev/stderr"
                    } else {
                        print "FAIL: " wit " rejected without expected diagnostic '\''" expect "'\''" > "/dev/stderr"
                    }
                    printf "  got: %s\n", combined > "/dev/stderr"
                    failed = 1
                }
            } else if (code == 0) {
                print "  ok: " wit
            } else {
                print "FAIL: " wit " expected to pass the selfhost frontend but was rejected (rc=" code ")" > "/dev/stderr"
                printf "  got: %s\n", combined > "/dev/stderr"
                failed = 1
            }
        }
        if ((getline end_hdr < batch_file) <= 0) {
            print "FAIL: missing CHECK_BATCH_END trailer" > "/dev/stderr"
            exit 1
        }
        sub(/\r$/, "", end_hdr)
        if (end_hdr != ("CHECK_BATCH_END|" total)) {
            print "FAIL: bad CHECK_BATCH_END trailer: " end_hdr > "/dev/stderr"
            exit 1
        }
        if ((getline extra_line < batch_file) > 0) {
            print "FAIL: unexpected trailing batch output: " extra_line > "/dev/stderr"
            exit 1
        }
        close(batch_file)
        if (failed) exit 1
    }
'; then
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "verify-stdlib-selfhost: FAILED" >&2
    exit 1
fi
echo "verify-stdlib-selfhost: $checked stdlib witnesses verified through the selfhost frontend"
