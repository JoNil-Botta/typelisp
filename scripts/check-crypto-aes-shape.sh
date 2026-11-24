#!/usr/bin/env sh
set -eu
# Extract complete retained/inlined AES/GCM bodies and verify structural
# constant-time, completeness, wipe, and verify-before-decrypt contracts.
# Invariant to benign backend shifts (spill offsets, registers, .L labels,
# tail-merge unconditional jmps, abort-stub forms, and __tl_arg_entry ordinals)
# while failing closed on any symbol, branch, table, wipe, or call-order drift.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

usage() {
    echo 'usage: check-crypto-aes-shape.sh --self-test' >&2
    echo '       check-crypto-aes-shape.sh <assembly> <fresh-output-dir> <target> <opt> [aes|gcm]' >&2
    exit 2
}

verify_shape() {
    v_assembly=$1
    v_work=$2
    v_target=$3
    v_opt=$4
    v_family=$5

    case "$v_target" in linux-x86_64|windows-x86_64) ;; *) echo "unknown crypto audit target: $v_target" >&2; return 2 ;; esac
    case "$v_opt" in 1|2) ;; *) echo "unknown crypto audit opt level: $v_opt" >&2; return 2 ;; esac
    case "$v_family" in aes|gcm) ;; *) echo "unknown crypto audit family: $v_family" >&2; return 2 ;; esac
    [ -f "$v_assembly" ] || { echo "missing assembly file: $v_assembly" >&2; return 1; }

    mkdir -p "$v_work"
    : > "$v_work/symbols"
    : > "$v_work/arg-entries"

    # Extract all audited function bodies and validate private argument-copy
    # entry stubs. CR normalization makes the same target host-independent.
    awk -v output="$v_work" -v family="$v_family" '
    function selected(name) {
        if (family == "gcm") {
            return name ~ /^_tl_stdlib_crypto_(aes_core|aes128_gcm|ghash_core|stack_scrub)_/ \
                || name ~ /^gcm_audit_(seal|open)(\$typelisp)?$/ \
                || name ~ /^_tl_stdlib_crypto_secret_stdlib_crypto_secret_(difference_bits|wipe_words_bang)$/ \
                || name == "main"
        }
        return name ~ /^_tl_stdlib_crypto_(aes_core|stack_scrub)_/ \
            || name ~ /^aes_audit_production_(128|256)(\$typelisp)?$/ \
            || name == "main"
    }
    function valid_stub_insn(line) {
        if (line ~ /^[[:space:]]*(#.*|;.*)?$/) return 1
        if (line ~ /^[[:space:]]*nop[[:space:]]*$/) return 1
        if (line ~ /^[[:space:]]*mov[bwlq]?[[:space:]]+%[a-z0-9]+,[[:space:]]*%[a-z0-9]+[[:space:]]*$/) return 1
        return 0
    }
    { sub(/\r$/, "") }
    /^[[:space:]]*\.globl[[:space:]]+/ {
        name = $2
        pending = selected(name) ? name : ""
        active = 0
        next
    }
    /^"__tl_arg_entry:[0-9]+":$/ {
        entry = substr($0, 2, length($0) - 3)
        if (entry in entry_body) {
            print "duplicate arg entry stub: " entry > "/dev/stderr"
            exit 1
        }
        entry_body[entry] = $0
        entry_bad[entry] = ""
        next
    }
    entry != "" && !entry_target {
        if ($0 == "    .size \"" entry "\", . - \"" entry "\"") {
            entry_target = 1
            next
        }
        if (!valid_stub_insn($0) && entry_bad[entry] == "") {
            entry_bad[entry] = $0
        }
        entry_body[entry] = entry_body[entry] "\n" $0
        next
    }
    entry_target {
        if ($0 !~ /^[A-Za-z0-9_.$]+:$/) {
            print "malformed arg entry target after " entry ": " $0 > "/dev/stderr"
            exit 1
        }
        callee = substr($0, 1, length($0) - 1)
        entry_body[entry] = entry_body[entry] "\n" $0
        entry_callee[entry] = callee
        if (selected(callee)) entry_needed[entry] = 1
        entry = ""
        entry_target = 0
    }
    /^[A-Za-z0-9_$]+:$/ && $0 == pending ":" {
        name = pending
        if (defined[name]++) {
            print "duplicate audited function definition: " name > "/dev/stderr"
            exit 1
        }
        file = output "/" name ".body"
        print name > (output "/symbols")
        pending = ""
        active = 1
    }
    /^[[:space:]]*\.(size|section)[[:space:]]/ { active = 0; next }
    active {
        if ($0 ~ /^[[:space:]]*\./ && $0 !~ /^[^[:space:]]+:$/) next
        if ($0 ~ /^[[:space:]]*(#|;|$)/) next
        if ($0 ~ /^[[:space:]]*(callq?|jmpq?)[[:space:]]+"__tl_arg_entry:[0-9]+"$/) {
            entry_needed[substr($2, 2, length($2) - 2)] = 1
        }
        print > file
    }
    END {
        if (entry != "") {
            print "unterminated arg entry stub: " entry > "/dev/stderr"
            exit 1
        }
        for (key in entry_needed) {
            if (!(key in entry_callee)) {
                print "unresolved arg entry stub: " key > "/dev/stderr"
                exit 1
            }
            if (entry_bad[key] != "") {
                print "disallowed instruction in arg entry stub " key ": " entry_bad[key] > "/dev/stderr"
                exit 1
            }
            print "\"" key "\"", entry_callee[key] > (output "/arg-entries")
        }
    }
    ' "$v_assembly" || return 1

    [ -s "$v_work/symbols" ] || { echo 'missing crypto audit roots' >&2; return 1; }
    LC_ALL=C sort "$v_work/symbols" > "$v_work/sorted-symbols" || return 1

    # Resolve private __tl_arg_entry calls in every audited body.
    while IFS= read -r v_symbol; do
        awk '
            { sub(/\r$/, "") }
            FILENAME == ARGV[1] { callee[$1] = $2; next }
            ($1 ~ /^(callq?|jmpq?)$/) && ($2 in callee) {
                $2 = callee[$2]
                print "    " $1 " " $2
                next
            }
            { print }
        ' "$v_work/arg-entries" "$v_work/$v_symbol.body" > "$v_work/$v_symbol.resolved" || return 1
    done < "$v_work/sorted-symbols"

    # Enforce exact structural constant-time, completeness, wipe, and call-order contracts.
    awk -v work="$v_work" -v target="$v_target" -v opt="$v_opt" -v family="$v_family" '
    function fail(msg) {
        print "crypto shape contract violation (" family "/" target "/opt" opt "): " msg > "/dev/stderr"
        failed = 1
    }
    function add_spec(sym, max_jcc, min_back, max_jmp_local, max_setcc, max_divs, max_vshift, max_ind, rip_rule, max_idx_mem, max_idx_lea, req_calls, opt_calls) {
        expected[sym] = 1
        s_max_jcc[sym] = max_jcc
        s_min_back[sym] = min_back
        s_max_jmp_local[sym] = max_jmp_local
        s_max_setcc[sym] = max_setcc
        s_max_divs[sym] = max_divs
        s_max_vshift[sym] = max_vshift
        s_max_ind[sym] = max_ind
        s_rip_rule[sym] = rip_rule
        s_max_idx_mem[sym] = max_idx_mem
        s_max_idx_lea[sym] = max_idx_lea
        s_req_calls[sym] = req_calls
        s_opt_calls[sym] = opt_calls
    }
    function norm_call(callee) {
        if (callee == ".L_tl_abort_tl_div_abort_at" || callee == "tl_div_abort" || callee == "tl_div_abort_at") return "@abort:div"
        if (callee == ".L_tl_abort_tl_oob_abort_at" || callee == "tl_oob_abort" || callee == "tl_oob_abort_at") return "@abort:oob"
        if (callee == ".L_tl_abort_tl_shift_abort_at" || callee == "tl_shift_abort" || callee == "tl_shift_abort_at") return "@abort:shift"
        return callee
    }
    function split_operands(ops, out,   i, n, len, depth, in_q, ch, cur) {
        delete out
        len = length(ops)
        if (len == 0) return 0
        n = 0
        depth = 0
        in_q = 0
        cur = ""
        for (i = 1; i <= len; i++) {
            ch = substr(ops, i, 1)
            if (ch == "\"") {
                in_q = !in_q
                cur = cur ch
            } else if (!in_q && ch == "(") {
                depth++
                cur = cur ch
            } else if (!in_q && ch == ")") {
                if (depth > 0) depth--
                cur = cur ch
            } else if (!in_q && depth == 0 && ch == ",") {
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", cur)
                out[++n] = cur
                cur = ""
            } else {
                cur = cur ch
            }
        }
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", cur)
        out[++n] = cur
        return n
    }
    function rip_allowed(sym, rule, op, operand,   open_idx, prefix) {
        if (rule == "none") return 0
        if (rule == "gen") {
            return operand ~ /^_tl_stdlib_crypto_secret_stdlib_crypto_secret_secret_generation\([[:space:]]*%rip[[:space:]]*\)$/
        }
        if (rule == "str") {
            if (op ~ /^lea[lq]?$/ && operand ~ /^\.L_tl_str_[A-Za-z0-9_]+\([[:space:]]*%rip[[:space:]]*\)$/) return 1
            return op ~ /^mov(l|q|absq)?$/ && operand ~ /^\$\.L_tl_str_[A-Za-z0-9_]+$/
        }
        if (rule == "win_main") {
            return operand ~ /^\.L_tl_(argc|argv)\([[:space:]]*%rip[[:space:]]*\)$/
        }
        if (rule == "win_main_str") {
            if (operand ~ /^\.L_tl_(argc|argv)\([[:space:]]*%rip[[:space:]]*\)$/) return 1
            if (op ~ /^lea[lq]?$/ && operand ~ /^\.L_tl_str_[A-Za-z0-9_]+\([[:space:]]*%rip[[:space:]]*\)$/) return 1
            return op ~ /^mov(l|q|absq)?$/ && operand ~ /^\$\.L_tl_str_[A-Za-z0-9_]+$/
        }
        if (rule == "c_entry") {
            if (op !~ /^lea[lq]?$/ || operand !~ /\([[:space:]]*%rip[[:space:]]*\)$/) return 0
            open_idx = index(operand, "(")
            prefix = substr(operand, 1, open_idx - 1)
            return prefix == (sym "$typelisp")
        }
        return 0
    }
    function init_specs(   A, G, H, S, K, B, is_win, is_opt1) {
        A = "_tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_"
        G = "_tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_"
        H = "_tl_stdlib_crypto_ghash_core_stdlib_crypto_ghash_core_"
        S = "_tl_stdlib_crypto_secret_stdlib_crypto_secret_"
        K = "_tl_stdlib_crypto_stack_scrub_stdlib_crypto_stack_scrub_"
        B = "_tl_stdlib_byte_buf_stdlib_byte_buf_"
        is_win = (target == "windows-x86_64")
        is_opt1 = (opt == "1")

        # --- Shared AES core + stack scrub (present in both AES and GCM) ---
        if (is_opt1) {
            # Straight-line AES primitives (strictly 0 branches, 0 set/cmov, 0 div/vshift, 0 rip, 0 idx)
            add_spec(A "absorb_bang", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, A "transpose_8x8", "")
            add_spec(A "add_round_key_bang", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, A "absorb_bang", "")
            add_spec(A "mix_columns_bang", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, A "rotate_rows_1," A "rotate_rows_2", "")
            add_spec(A "rotate_rows_1", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, "", "")
            add_spec(A "rotate_rows_2", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, "", "")
            add_spec(A "squeeze_bang", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, A "transpose_8x8", "")
            add_spec(A "sub_block_bang", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, A "absorb_bang," A "sub_bytes_bang," A "squeeze_bang", "")
            add_spec(A "sub_bytes_bang", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, "", "")
            add_spec(A "transpose_8x8", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, "", "")
            add_spec(A "xtime", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, "", "")

            # Audited AES loops and preflight
            add_spec(A "shift_rows_bang", 1, 1, -1, 0, 0, 0, 0, "none", 1, 1, "", "")
            add_spec(A "cipher_bang", 2, 1, -1, 0, 0, 0, 0, "none", 0, 0,
                A "absorb_bang," A "add_round_key_bang," A "mix_columns_bang," A "shift_rows_bang," A "squeeze_bang," A "sub_bytes_bang," K "block_bang," S "wipe_words_bang", "")
            add_spec(A "expand_bang", 11, 4, -1, 7, 1, 0, 0, "str", 4, 0,
                A "sub_block_bang," A "xtime," S "wipe_words_bang", "@abort:div")
            add_spec(A "check_fixed", 4, 0, -1, 2, 0, 0, 0, "none", 0, 0,
                S "fixed_length," S "live_capacity," S "storage_live_question", "")
            add_spec(A "overlap_question", 1, 0, -1, 3, 0, 0, 0, "none", 0, 0, "", "")
            add_spec(A "encrypt_checked_bang", 11, 0, -1, 5, 0, 0, 0, "none", 0, 0,
                A "check_fixed," A "cipher_bang," A "overlap_question," S "bytes_capacity," S "bytes_length," S "storage_live_question", "")
            add_spec(A "construct_schedule", 4, 0, -1, 3, 0, 0, 0, "none", 0, 0,
                A "check_fixed," A "expand_bang," S "bytes_new," S "bytes_set_length_bang," S "close_bytes," S "close_fixed," S "storage_live_question", "")
            add_spec(A "close_128", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, S "close_bytes", "")
            add_spec(A "construct_128", 1, 0, -1, 0, 0, 0, 0, "none", 0, 0, A "construct_schedule", "")
        } else {
            # Straight-line AES primitives at opt2 (pure helpers inlined)
            add_spec(A "add_round_key_bang", 0, 0, 0, 0, 0, 0, 0, "none", 0, 1, "", "")
            add_spec(A "mix_columns_bang", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, "", "")
            add_spec(A "squeeze_bang", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, "", "")
            add_spec(A "sub_block_bang", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, A "sub_bytes_bang", "")
            add_spec(A "sub_bytes_bang", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, "", "")

            # Audited AES loops and preflight at opt2
            add_spec(A "shift_rows_bang", 1, 1, -1, 0, 0, 0, 0, "none", 2, 0, "", "")
            add_spec(A "cipher_bang", 4, 2, -1, 0, 0, 0, 0, "none", 2, 1,
                A "add_round_key_bang," A "mix_columns_bang," A "shift_rows_bang," A "squeeze_bang," A "sub_bytes_bang," K "block_bang," S "wipe_words_bang", "")
            add_spec(A "expand_bang", 17, 7, -1, 0, 1, 0, 0, "str", 21, 3,
                A "sub_block_bang," S "wipe_words_bang", "@abort:div")
            add_spec(A "check_fixed", 6, 0, -1, 0, 0, 0, 0, "none", 0, 0,
                S "fixed_length," S "live_capacity", "")
            add_spec(A "overlap_question", 1, 0, -1, 2, 0, 0, 0, "none", 0, 0, "", "")
            add_spec(A "encrypt_checked_bang", 18, 0, -1, 0, 0, 0, 0, "none", 0, 0,
                A "check_fixed," A "cipher_bang," A "overlap_question", "")
        }

        add_spec(K "block_bang", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, K "wipe_chunks_bang", "")
        add_spec(K "wipe_chunks_bang", 1, 1, -1, 0, 0, 0, 0, "none", 0, 1, "", "")

        if (family == "aes") {
            add_spec(K "setup_bang", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, K "wipe_chunks_bang", is_win ? "__chkstk" : "")
            if (is_opt1) {
                add_spec(A "close_256", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, S "close_bytes", "")
                add_spec(A "construct_256", 1, 0, -1, 0, 0, 0, 0, "none", 0, 0, A "construct_schedule", "")
                add_spec(A "construct_public_128", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, A "construct_128," K "setup_bang", "")
                add_spec(A "construct_public_256", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, A "construct_256," K "setup_bang", "")
                add_spec(A "encrypt_128_bang", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, A "encrypt_checked_bang", "")
                add_spec(A "encrypt_256_bang", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, A "encrypt_checked_bang", "")
                if (is_win) {
                    add_spec("aes_audit_production_128", 0, 0, 0, 0, 0, 0, 0, "c_entry", 0, 0, "__tl$c_entry", "")
                    add_spec("aes_audit_production_128$typelisp", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, A "encrypt_128_bang", "")
                    add_spec("aes_audit_production_256", 0, 0, 0, 0, 0, 0, 0, "c_entry", 0, 0, "__tl$c_entry", "")
                    add_spec("aes_audit_production_256$typelisp", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, A "encrypt_256_bang", "")
                    add_spec("main", 7, 2, -1, 0, 0, 0, 1, "win_main", 0, 0,
                        A "close_128," A "close_256," A "construct_public_128," A "construct_public_256,aes_audit_production_128$typelisp,aes_audit_production_256$typelisp," S "close_fixed," S "fixed_zero", "")
                } else {
                    add_spec("aes_audit_production_128", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, A "encrypt_128_bang", "")
                    add_spec("aes_audit_production_256", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, A "encrypt_256_bang", "")
                    add_spec("main", 7, 2, -1, 0, 0, 0, 0, "none", 0, 0,
                        A "close_128," A "close_256," A "construct_public_128," A "construct_public_256,aes_audit_production_128,aes_audit_production_256," S "close_fixed," S "fixed_zero", "")
                }
            } else {
                add_spec(A "construct_schedule", 5, 0, -1, 0, 0, 0, 0, "gen", 0, 0,
                    A "check_fixed," A "expand_bang," S "bytes_set_length_bang," S "storage_close," S "storage_live_question," S "storage_new", "")
                if (is_win) {
                    add_spec("aes_audit_production_128", 0, 0, 0, 0, 0, 0, 0, "c_entry", 0, 0, "__tl$c_entry", "")
                    add_spec("aes_audit_production_128$typelisp", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, A "encrypt_checked_bang", "")
                    add_spec("aes_audit_production_256", 0, 0, 0, 0, 0, 0, 0, "c_entry", 0, 0, "__tl$c_entry", "")
                    add_spec("aes_audit_production_256$typelisp", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, A "encrypt_checked_bang", "")
                    add_spec("main", 9, 2, -1, 0, 0, 0, 1, "win_main", 0, 0,
                        A "construct_schedule," A "encrypt_checked_bang," K "setup_bang," S "fixed_zero," S "storage_close", "")
                } else {
                    add_spec("aes_audit_production_128", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, A "encrypt_checked_bang", "")
                    add_spec("aes_audit_production_256", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, A "encrypt_checked_bang", "")
                    add_spec("main", 9, 2, -1, 0, 0, 0, 0, "none", 0, 0,
                        A "construct_schedule," A "encrypt_checked_bang," K "setup_bang," S "fixed_zero," S "storage_close", "")
                }
            }
        } else {
            # --- GCM + GHASH + Secret primitives ---
            add_spec(K "tree_bang", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, K "wipe_chunks_bang", is_win ? "__chkstk" : "")
            add_spec(G "construct_key", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, G "construct_key_operation," K "tree_bang", "")
            add_spec(G "seal", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, G "seal_operation," K "tree_bang", "")
            if (is_opt1) {
                add_spec(A "close_raw_key", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, S "close_fixed", "")
                add_spec(A "encrypt_composed_128_bang", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, A "encrypt_checked_bang", "")
                add_spec(G "close", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, A "close_128," S "close_fixed", "")
                add_spec(G "construct_key_operation", 3, 0, -1, 0, 0, 0, 0, "none", 0, 0,
                    A "check_fixed," A "close_128," A "close_raw_key," A "construct_128," A "encrypt_composed_128_bang," S "close_fixed," S "fixed_zero", "")
                add_spec(G "counter_bang", 4, 2, -1, 0, 0, 1, 0, "str", 1, 1, "", "@abort:oob,@abort:shift")
                add_spec(G "gctr_bang", 4, 2, -1, 0, 0, 0, 0, "str", 2, 0,
                    A "encrypt_composed_128_bang," G "counter_bang,tl_abort_string", "")
                add_spec(G "open", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, G "open_operation," K "tree_bang", "")
                add_spec(G "open_operation", 3, 0, -1, 0, 0, 0, 0, "none", 0, 0,
                    B "with_capacity," G "gctr_bang," G "prepare_bang," G "validate_lengths," H "authenticate_bang," S "close_fixed," S "difference_bits," S "fixed_zero", "")
                add_spec(G "prepare_bang", 2, 0, -1, 0, 0, 0, 0, "none", 0, 0,
                    A "check_fixed," A "encrypt_composed_128_bang," G "counter_bang", "")
                add_spec(G "seal_operation", 5, 2, -1, 0, 0, 0, 0, "str", 3, 0,
                    B "with_capacity," G "gctr_bang," G "prepare_bang," G "validate_lengths," H "authenticate_bang," S "close_fixed," S "fixed_zero", "@abort:oob")
                add_spec(G "validate_lengths", 6, 0, -1, 4, 0, 0, 0, "none", 0, 0, "", "")

                add_spec(H "absorb_bang", 2, 0, -1, 0, 0, 0, 0, "none", 0, 0, H "load_be," H "multiply_bang", "")
                add_spec(H "authenticate_bang", 1, 1, -1, 0, 0, 0, 0, "none", 2, 0,
                    H "multiply_bang," H "region_bang," H "store_be_bang," S "wipe_words_bang", "")
                add_spec(H "load_be", 2, 2, -1, 0, 0, 0, 0, "none", 1, 0, "", "")
                add_spec(H "multiply_bang", 2, 2, -1, 0, 0, 0, 0, "none", 2, 1, H "load_be," S "wipe_words_bang", "")
                add_spec(H "region_bang", 2, 1, -1, 0, 0, 0, 0, "none", 0, 0, H "absorb_bang", "")
                add_spec(H "store_be_bang", 1, 1, -1, 0, 0, 0, 0, "none", 0, 0, "", "")
                add_spec(S "difference_bits", 1, 1, -1, 0, 0, 0, 0, "none", 2, 0, "", "")
                add_spec(S "wipe_words_bang", 1, 1, -1, 0, 0, 0, 0, "none", 0, 1, "", "")

                if (is_win) {
                    add_spec("gcm_audit_open", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, "gcm_audit_open$typelisp", "")
                    add_spec("gcm_audit_open$typelisp", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, G "open", "")
                    add_spec("gcm_audit_seal", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, "gcm_audit_seal$typelisp", "")
                    add_spec("gcm_audit_seal$typelisp", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, G "seal", "")
                    add_spec("main", 4, 0, -1, 0, 0, 0, 1, "win_main_str", 0, 0,
                        B "as_bytes," G "close," G "construct_key,gcm_audit_open$typelisp,gcm_audit_seal$typelisp," S "fixed_zero", "")
                } else {
                    add_spec("gcm_audit_open", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, G "open", "")
                    add_spec("gcm_audit_seal", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, G "seal", "")
                    add_spec("main", 4, 0, -1, 0, 0, 0, 0, "str", 0, 0,
                        B "as_bytes," G "close," G "construct_key,gcm_audit_open,gcm_audit_seal," S "fixed_zero", "")
                }
            } else {
                add_spec(G "close", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, S "storage_close", "")
                add_spec(G "construct_key_operation", 7, 0, -1, 0, 0, 0, 0, "gen", 0, 0,
                    A "check_fixed," A "encrypt_checked_bang," A "expand_bang," S "bytes_set_length_bang," S "fixed_zero," S "storage_close," S "storage_live_question," S "storage_new", "")
                add_spec(G "gctr_bang", 13, 6, -1, 0, 0, 1, 0, "str", 16, 4,
                    A "encrypt_checked_bang,tl_abort_string", "@abort:shift,@abort:oob")
                add_spec(G "prepare_bang", 6, 3, -1, 0, 0, 1, 0, "str", 7, 0,
                    A "check_fixed," A "encrypt_checked_bang", "@abort:shift,@abort:oob")
                add_spec(G "seal_operation", 6, 4, -1, 0, 0, 0, 0, "none", 12, 0,
                    B "with_capacity," G "gctr_bang," G "prepare_bang," G "validate_lengths," H "authenticate_bang," S "fixed_zero," S "storage_close", "@abort:oob")
                add_spec(G "validate_lengths", 3, 0, -1, 0, 0, 0, 0, "none", 0, 0, "", "")

                add_spec(H "absorb_bang", 26, 11, -1, 0, 0, 0, 0, "none", 42, 0, H "multiply_bang", "")
                add_spec(H "authenticate_bang", 2, 2, -1, 0, 0, 0, 0, "none", 9, 2,
                    H "multiply_bang," H "region_bang," H "store_be_bang," S "wipe_words_bang", "")
                add_spec(H "multiply_bang", 2, 2, -1, 0, 0, 0, 0, "none", 3, 0, S "wipe_words_bang", "")
                add_spec(H "region_bang", 2, 1, -1, 0, 0, 0, 0, "none", 0, 2, H "multiply_bang," H "absorb_bang", "")
                add_spec(H "store_be_bang", 1, 1, -1, 0, 0, 0, 0, "none", 1, 0, "", "")
                add_spec(S "wipe_words_bang", 2, 1, -1, 0, 0, 0, 0, "none", 0, 1, "", "")

                if (is_win) {
                    add_spec("gcm_audit_open", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, "gcm_audit_open$typelisp", "")
                    add_spec("gcm_audit_open$typelisp", 4, 1, -1, 0, 0, 0, 0, "none", 2, 0,
                        B "with_capacity," G "gctr_bang," G "prepare_bang," G "validate_lengths," H "authenticate_bang," K "tree_bang," S "fixed_zero," S "storage_close", "")
                    add_spec("gcm_audit_seal", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, "gcm_audit_seal$typelisp", "")
                    add_spec("gcm_audit_seal$typelisp", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, G "seal", "")
                    add_spec("main", 10, 1, -1, 0, 0, 0, 1, "win_main_str", 2, 0,
                        B "with_capacity," G "close," G "construct_key," G "gctr_bang," G "prepare_bang," G "seal," G "validate_lengths," H "authenticate_bang," K "tree_bang," S "fixed_zero," S "storage_close", "@abort:oob")
                } else {
                    add_spec("gcm_audit_open", 4, 1, -1, 0, 0, 0, 0, "none", 2, 0,
                        B "with_capacity," G "gctr_bang," G "prepare_bang," G "validate_lengths," H "authenticate_bang," K "tree_bang," S "fixed_zero," S "storage_close", "")
                    add_spec("gcm_audit_seal", 0, 0, 0, 0, 0, 0, 0, "none", 0, 0, G "seal", "")
                    add_spec("main", 10, 1, -1, 0, 0, 0, 0, "str", 2, 0,
                        B "with_capacity," G "close," G "construct_key," G "gctr_bang," G "prepare_bang," G "seal," G "validate_lengths," H "authenticate_bang," K "tree_bang," S "fixed_zero," S "storage_close", "@abort:oob")
                }
            }
        }
    }
    function check_order(sym, seq, seq_len, targets_csv,   want, nwant, wi, si, found, prev_max, cur_min, cur_max) {
        nwant = split(targets_csv, want, ",")
        prev_max = 0
        for (wi = 1; wi <= nwant; wi++) {
            found = 0
            cur_min = 0
            cur_max = 0
            for (si = 1; si <= seq_len; si++) {
                if (seq[si] == want[wi]) {
                    if (!found) cur_min = si
                    cur_max = si
                    found = 1
                }
            }
            if (!found) {
                fail(sym ": required call order violated at " want[wi] " (expected sequence " targets_csv ")")
                return 0
            }
            if (wi > 1 && cur_min <= prev_max) {
                fail(sym ": required call order violated at " want[wi] " (expected all " want[wi - 1] " before all " want[wi] " in " targets_csv ")")
                return 0
            }
            prev_max = cur_max
        }
        return 1
    }
    function audit_function(sym,   path, line, lbl, op, ops, rest, target_lbl, norm_t,
                            op_arr, op_n, oi, operand, is_direct_ctrl,
                            jcc, jmp_local, back_br, loops, setcc, cmov, divs, vshift, ind_ctrl, bcmp,
                            rip_bad, idx_mem, idx_lea, idx_scale0_mem, bad_mul_idx,
                            has_vol_store, has_imm_63, has_imm_64,
                            in_open_tag_win, open_tag_cmp16, open_tag_back, open_tag_early_jcc,
                            seen_lbl, open_tag_lbl, calls_seen, call_seq, call_n,
                            allowed, req_arr, opt_arr, n, i, c, status, A, G, H, S, K, B,
                            is_open_opt2) {
        A = "_tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_"
        G = "_tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_"
        H = "_tl_stdlib_crypto_ghash_core_stdlib_crypto_ghash_core_"
        S = "_tl_stdlib_crypto_secret_stdlib_crypto_secret_"
        K = "_tl_stdlib_crypto_stack_scrub_stdlib_crypto_stack_scrub_"
        B = "_tl_stdlib_byte_buf_stdlib_byte_buf_"

        is_open_opt2 = (family == "gcm" && opt == "2" && ((target == "linux-x86_64" && sym == "gcm_audit_open") || (target == "windows-x86_64" && sym == "gcm_audit_open$typelisp")))

        path = work "/" sym ".resolved"
        jcc = 0; jmp_local = 0; back_br = 0; loops = 0; setcc = 0; cmov = 0
        divs = 0; vshift = 0; ind_ctrl = 0; bcmp = 0
        rip_bad = 0; idx_mem = 0; idx_lea = 0; idx_scale0_mem = 0; bad_mul_idx = 0
        has_vol_store = 0; has_imm_63 = 0; has_imm_64 = 0
        in_open_tag_win = 0; open_tag_cmp16 = 0; open_tag_back = 0; open_tag_early_jcc = 0
        call_n = 0
        delete seen_lbl
        delete open_tag_lbl
        delete calls_seen
        delete call_seq

        while ((status = getline line < path) > 0) {
            sub(/\r$/, "", line)
            if (line ~ /^[^[:space:]]+:$/) {
                lbl = substr(line, 1, length(line) - 1)
                seen_lbl[lbl] = 1
                if (in_open_tag_win) open_tag_lbl[lbl] = 1
                continue
            }
            if (line !~ /^[[:space:]]+[A-Za-z]/) continue
            rest = line
            sub(/^[[:space:]]+/, "", rest)
            op = rest
            sub(/[[:space:]].*$/, "", op)
            ops = rest
            if (index(ops, " ") > 0 || index(ops, "\t") > 0) {
                sub(/^[^[:space:]]+[[:space:]]+/, "", ops)
                sub(/[[:space:]]+$/, "", ops)
            } else {
                ops = ""
            }

            if (op ~ /^jmpq?$/) {
                if (ops ~ /^\*/) {
                    ind_ctrl++
                    fail(sym ": disallowed indirect jmp: " line)
                } else if (ops ~ /^\./ && ops !~ /^\.L_tl_abort_/) {
                    jmp_local++
                    if (ops in seen_lbl) {
                        back_br++
                        if (in_open_tag_win && (ops in open_tag_lbl)) open_tag_back++
                    }
                } else {
                    norm_t = norm_call(ops)
                    calls_seen[norm_t] = 1
                    call_seq[++call_n] = norm_t
                    if (is_open_opt2) {
                        if (norm_t == H "authenticate_bang") in_open_tag_win = 1
                        else if (norm_t == G "gctr_bang") in_open_tag_win = 0
                    }
                }
            } else if (op ~ /^j[a-z]+$/) {
                jcc++
                if (ops in seen_lbl) {
                    back_br++
                    if (in_open_tag_win && (ops in open_tag_lbl)) {
                        open_tag_back++
                    } else if (in_open_tag_win && open_tag_back == 0) {
                        open_tag_early_jcc++
                    }
                } else if (in_open_tag_win && open_tag_back == 0) {
                    open_tag_early_jcc++
                }
            } else if (op ~ /^loop[a-z]*$/) {
                loops++
            } else if (op ~ /^set[a-z]+$/) {
                setcc++
            } else if (op ~ /^cmov[a-z]+$/) {
                cmov++
            } else if (op ~ /^i?div[bwlq]?$/) {
                divs++
            } else if ((op ~ /^(sh[lr]|sa[lr]|ro[lr]|sh[lr]d)[bwlq]?$/ && ops ~ /^%cl([[:space:]]*,|$)/) \
                    || op ~ /^(sh[lr]x|sarx)[lq]?$/) {
                vshift++
            } else if (op ~ /^callq?$/) {
                if (ops ~ /^\*/) {
                    ind_ctrl++
                } else {
                    norm_t = norm_call(ops)
                    calls_seen[norm_t] = 1
                    call_seq[++call_n] = norm_t
                    if (is_open_opt2) {
                        if (norm_t == H "authenticate_bang") in_open_tag_win = 1
                        else if (norm_t == G "gctr_bang") in_open_tag_win = 0
                    }
                }
            }

            if (op == "cmpb" || op == "testb") bcmp++

            is_direct_ctrl = (op ~ /^(callq?|jmpq?|j[a-z]+|loop[a-z]*)$/ && ops !~ /^\*/)
            if (!is_direct_ctrl && ops != "") {
                op_n = split_operands(ops, op_arr)
                for (oi = 1; oi <= op_n; oi++) {
                    operand = op_arr[oi]
                    if (op ~ /^(callq?|jmpq?)$/ && operand ~ /^\*/) {
                        sub(/^\*[[:space:]]*/, "", operand)
                    }
                    if (operand ~ /\([[:space:]]*%rip[[:space:]]*\)/) {
                        if (!rip_allowed(sym, s_rip_rule[sym], op, operand)) {
                            rip_bad++
                            fail(sym ": disallowed RIP-relative operand: " line)
                        }
                    } else if (operand ~ /^\$/) {
                        if (operand !~ /^\$[-+]?(0[xXbB][0-9A-Fa-f]+|[0-9]+)$/) {
                            if (!rip_allowed(sym, s_rip_rule[sym], op, operand)) {
                                rip_bad++
                                fail(sym ": disallowed static symbol immediate: " line)
                            }
                        }
                    } else if (operand ~ /\(/) {
                        if (operand !~ /^(%[a-z0-9]+:)?[-+]?(0[xXbB][0-9A-Fa-f]+|[0-9]+)?\(/) {
                            if (!rip_allowed(sym, s_rip_rule[sym], op, operand)) {
                                rip_bad++
                                fail(sym ": disallowed symbol-prefixed memory operand: " line)
                            }
                        }
                    } else if (operand !~ /^%/ && operand !~ /^[-+]?(0[xXbB][0-9A-Fa-f]+|[0-9]+)$/ && op !~ /^(rep|repe|repz|repne|repnz|lock)$/) {
                        if (!rip_allowed(sym, s_rip_rule[sym], op, operand)) {
                            rip_bad++
                            fail(sym ": disallowed static symbol operand: " line)
                        }
                    }

                    if (operand ~ /\([[:space:]]*,[[:space:]]*%/) {
                        if (op ~ /^lea[lq]?$/) {
                            idx_lea++
                        } else {
                            idx_scale0_mem++
                            idx_mem++
                            fail(sym ": disallowed scaled-index table operand: " line)
                        }
                    } else if (operand ~ /\([[:space:]]*%[a-z0-9]+[[:space:]]*,[[:space:]]*%/) {
                        if (op ~ /^lea[lq]?$/) {
                            idx_lea++
                        } else {
                            idx_mem++
                        }
                        if (sym == H "multiply_bang" && operand !~ /\([[:space:]]*%[a-z0-9]+[[:space:]]*,[[:space:]]*%[a-z0-9]+[[:space:]]*,[[:space:]]*8[[:space:]]*\)/) {
                            bad_mul_idx++
                        }
                    }
                }
            }

            if (op == "movq" && ops ~ /^%[a-z0-9]+,[[:space:]]*\([[:space:]]*%[a-z0-9]+([[:space:]]*,[[:space:]]*%[a-z0-9]+[[:space:]]*,[[:space:]]*8)?[[:space:]]*\)$/ && ops !~ /\([[:space:]]*%rsp|\([[:space:]]*%rbp/) {
                has_vol_store = 1
            }
            if (ops ~ /\$63([[:space:],]|$)/) has_imm_63 = 1
            if (ops ~ /\$64([[:space:],]|$)/) has_imm_64 = 1
            if (in_open_tag_win && open_tag_back == 0 && op ~ /^cmp[lq]?$/ && ops ~ /\$16([[:space:],]|$)/) {
                open_tag_cmp16 = 1
            }
        }
        close(path)
        if (status < 0) {
            fail(sym ": cannot read resolved body")
            return
        }

        if (loops > 0) fail(sym ": disallowed loop instruction count=" loops)
        if (cmov > 0) fail(sym ": disallowed cmov instruction count=" cmov)
        if (bcmp > 0) fail(sym ": disallowed cmpb/testb instruction count=" bcmp)
        if (jcc > s_max_jcc[sym]) fail(sym ": conditional branches " jcc " exceed contract bound " s_max_jcc[sym])
        if (back_br < s_min_back[sym]) fail(sym ": backward branches " back_br " below required loop count " s_min_back[sym])
        if (s_max_jmp_local[sym] >= 0 && jmp_local > s_max_jmp_local[sym]) fail(sym ": internal jumps " jmp_local " exceed straight-line bound " s_max_jmp_local[sym])
        if (setcc > s_max_setcc[sym]) fail(sym ": setcc count " setcc " exceeds contract bound " s_max_setcc[sym])
        if (divs > s_max_divs[sym]) fail(sym ": div/idiv count " divs " exceeds contract bound " s_max_divs[sym])
        if (vshift > s_max_vshift[sym]) fail(sym ": variable shift count " vshift " exceeds contract bound " s_max_vshift[sym])
        if (ind_ctrl > s_max_ind[sym]) fail(sym ": indirect call/jmp count " ind_ctrl " exceeds contract bound " s_max_ind[sym])
        if (idx_mem > s_max_idx_mem[sym]) fail(sym ": indexed memory operands " idx_mem " exceed contract bound " s_max_idx_mem[sym])
        if (idx_lea > s_max_idx_lea[sym]) fail(sym ": indexed lea operands " idx_lea " exceed contract bound " s_max_idx_lea[sym])
        if (bad_mul_idx > 0) fail(sym ": ghash multiply has non-word-indexed memory operand")

        # Validate call-target closure: every emitted call must be allowed, every required call must occur.
        delete allowed
        if (s_req_calls[sym] != "") {
            n = split(s_req_calls[sym], req_arr, ",")
            for (i = 1; i <= n; i++) {
                allowed[req_arr[i]] = 1
                if (!(req_arr[i] in calls_seen)) {
                    fail(sym ": missing required call target " req_arr[i])
                }
            }
        }
        if (s_opt_calls[sym] != "") {
            n = split(s_opt_calls[sym], opt_arr, ",")
            for (i = 1; i <= n; i++) allowed[opt_arr[i]] = 1
        }
        for (c in calls_seen) {
            if (!(c in allowed)) {
                fail(sym ": unauthorized call target " c)
            }
        }

        # Mandatory wipe, loop-bound, and verify-before-decrypt ordering checks.
        if (sym == A "cipher_bang") {
            check_order(sym, call_seq, call_n, A "sub_bytes_bang," A "squeeze_bang," S "wipe_words_bang," K "block_bang")
        }
        if (sym == A "expand_bang") {
            check_order(sym, call_seq, call_n, A "sub_block_bang," S "wipe_words_bang")
        }
        if (sym == H "multiply_bang") {
            if (!has_imm_63 || !has_imm_64) {
                fail(sym ": missing fixed 64-bit GHASH loop constants ($63/$64)")
            }
        }
        if (sym == H "authenticate_bang") {
            check_order(sym, call_seq, call_n, H "region_bang," H "multiply_bang," H "store_be_bang," S "wipe_words_bang")
        }
        if (sym == S "wipe_words_bang" || sym == K "wipe_chunks_bang") {
            if (!has_vol_store) {
                fail(sym ": missing volatile indirect word store")
            }
        }
        if (sym == G "seal_operation") {
            if (opt == "1") {
                check_order(sym, call_seq, call_n, B "with_capacity," G "prepare_bang," G "gctr_bang," H "authenticate_bang," S "close_fixed")
            } else {
                check_order(sym, call_seq, call_n, B "with_capacity," G "prepare_bang," G "gctr_bang," H "authenticate_bang," S "storage_close")
            }
        }
        if (sym == G "open") {
            check_order(sym, call_seq, call_n, G "open_operation," K "tree_bang")
        }
        if (sym == G "open_operation") {
            check_order(sym, call_seq, call_n, B "with_capacity," G "prepare_bang," H "authenticate_bang," S "difference_bits," G "gctr_bang," S "close_fixed")
        }
        if (is_open_opt2) {
            check_order(sym, call_seq, call_n, B "with_capacity," G "prepare_bang," H "authenticate_bang," G "gctr_bang," S "storage_close," K "tree_bang")
            if (!open_tag_cmp16 || open_tag_back < 1) {
                fail(sym ": missing inlined 16-byte constant-time tag comparison loop between authenticate_bang and gctr_bang")
            }
            if (open_tag_early_jcc > 0) {
                fail(sym ": disallowed conditional branch inside opt2 tag-compare loop before backward edge count=" open_tag_early_jcc)
            }
        }
    }
    BEGIN {
        failed = 0
        init_specs()
    }
    {
        sub(/\r$/, "")
        if ($0 == "") next
        actual[$0] = 1
    }
    END {
        for (sym in expected) {
            if (!(sym in actual)) fail("missing audited symbol: " sym)
        }
        for (sym in actual) {
            if (!(sym in expected)) fail("unexpected audited symbol: " sym)
        }
        for (sym in actual) {
            if (sym in expected) audit_function(sym)
        }
        exit failed
    }
    ' "$v_work/sorted-symbols"
}

emit_synth_aes_linux_opt2() {
    cat <<'EOF'
    .text
    .globl _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_add_round_key_bang
_tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_add_round_key_bang:
    leaq (%rsi,%rax,1), %rax
    movq (%rax), %r8
    xorq %r8, (%rdi)
    ret
    .size _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_add_round_key_bang, . - _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_add_round_key_bang
    .globl _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_check_fixed
_tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_check_fixed:
    call _tl_stdlib_crypto_secret_stdlib_crypto_secret_fixed_length
    call _tl_stdlib_crypto_secret_stdlib_crypto_secret_live_capacity
    cmpq %rax, %rdi
    jne .L_chk_bad
.L_chk_bad:
    ret
    .size _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_check_fixed, . - _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_check_fixed
    .globl _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_cipher_bang
_tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_cipher_bang:
    movq %rdi, 16(%rsp)
.L_cip_loop:
    call "__tl_arg_entry:36"
.L_cip_sr:
    movq (%r12,%rsi,8), %rax
    movq %rax, (%r12,%rsi,8)
    jl .L_cip_sr
    call _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_mix_columns_bang
    jl .L_cip_loop
    call _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_shift_rows_bang
    call _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_add_round_key_bang
    call _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_squeeze_bang
    call _tl_stdlib_crypto_secret_stdlib_crypto_secret_wipe_words_bang
    call _tl_stdlib_crypto_stack_scrub_stdlib_crypto_stack_scrub_block_bang
    ret
    .size _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_cipher_bang, . - _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_cipher_bang
    .globl _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_construct_schedule
_tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_construct_schedule:
    addq $1, _tl_stdlib_crypto_secret_stdlib_crypto_secret_secret_generation(%rip)
    call _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_check_fixed
    call _tl_stdlib_crypto_secret_stdlib_crypto_secret_storage_new
    call _tl_stdlib_crypto_secret_stdlib_crypto_secret_bytes_set_length_bang
    call _tl_stdlib_crypto_secret_stdlib_crypto_secret_storage_live_question
    call _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_expand_bang
    call _tl_stdlib_crypto_secret_stdlib_crypto_secret_storage_close
    ret
    .size _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_construct_schedule, . - _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_construct_schedule
    .globl _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_encrypt_checked_bang
_tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_encrypt_checked_bang:
    call _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_check_fixed
    call _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_overlap_question
    call _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_cipher_bang
    ret
    .size _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_encrypt_checked_bang, . - _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_encrypt_checked_bang
    .globl _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_expand_bang
_tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_expand_bang:
    idivq %rcx
.L_exp_1:
    jl .L_exp_1
.L_exp_2:
    jl .L_exp_2
.L_exp_3:
    jl .L_exp_3
.L_exp_4:
    jl .L_exp_4
.L_exp_5:
    jl .L_exp_5
.L_exp_6:
    jl .L_exp_6
.L_exp_7:
    jl .L_exp_7
    call _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_sub_block_bang
    call _tl_stdlib_crypto_secret_stdlib_crypto_secret_wipe_words_bang
    call .L_tl_abort_tl_div_abort_at
    ret
    .size _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_expand_bang, . - _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_expand_bang
    .globl _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_mix_columns_bang
_tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_mix_columns_bang:
    xorq %r8, %r9
    ret
    .size _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_mix_columns_bang, . - _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_mix_columns_bang
    .globl _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_overlap_question
_tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_overlap_question:
    setb %al
    ret
    .size _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_overlap_question, . - _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_overlap_question
    .globl _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_shift_rows_bang
_tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_shift_rows_bang:
.L_sr_loop:
    movq (%rdi,%rsi,8), %rax
    jl .L_sr_loop
    ret
    .size _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_shift_rows_bang, . - _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_shift_rows_bang
    .globl _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_squeeze_bang
_tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_squeeze_bang:
    movq (%rdi), %rax
    movq %rax, (%rsi)
    ret
    .size _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_squeeze_bang, . - _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_squeeze_bang
    .globl _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_sub_block_bang
_tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_sub_block_bang:
    call "__tl_arg_entry:36"
    ret
    .size _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_sub_block_bang, . - _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_sub_block_bang
    .globl _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_sub_bytes_bang
"__tl_arg_entry:36":
    movq %r12, %rdi
    .size "__tl_arg_entry:36", . - "__tl_arg_entry:36"
_tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_sub_bytes_bang:
    xorq %r8, %r9
    andq %r9, %r10
    ret
    .size _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_sub_bytes_bang, . - _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_sub_bytes_bang
    .globl _tl_stdlib_crypto_stack_scrub_stdlib_crypto_stack_scrub_block_bang
_tl_stdlib_crypto_stack_scrub_stdlib_crypto_stack_scrub_block_bang:
    call _tl_stdlib_crypto_stack_scrub_stdlib_crypto_stack_scrub_wipe_chunks_bang
    ret
    .size _tl_stdlib_crypto_stack_scrub_stdlib_crypto_stack_scrub_block_bang, . - _tl_stdlib_crypto_stack_scrub_stdlib_crypto_stack_scrub_block_bang
    .globl _tl_stdlib_crypto_stack_scrub_stdlib_crypto_stack_scrub_setup_bang
_tl_stdlib_crypto_stack_scrub_stdlib_crypto_stack_scrub_setup_bang:
    call _tl_stdlib_crypto_stack_scrub_stdlib_crypto_stack_scrub_wipe_chunks_bang
    ret
    .size _tl_stdlib_crypto_stack_scrub_stdlib_crypto_stack_scrub_setup_bang, . - _tl_stdlib_crypto_stack_scrub_stdlib_crypto_stack_scrub_setup_bang
    .globl _tl_stdlib_crypto_stack_scrub_stdlib_crypto_stack_scrub_wipe_chunks_bang
_tl_stdlib_crypto_stack_scrub_stdlib_crypto_stack_scrub_wipe_chunks_bang:
.L_wc_loop:
    movq %rsi, (%rdi)
    jl .L_wc_loop
    ret
    .size _tl_stdlib_crypto_stack_scrub_stdlib_crypto_stack_scrub_wipe_chunks_bang, . - _tl_stdlib_crypto_stack_scrub_stdlib_crypto_stack_scrub_wipe_chunks_bang
    .globl aes_audit_production_128
aes_audit_production_128:
    call _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_encrypt_checked_bang
    ret
    .size aes_audit_production_128, . - aes_audit_production_128
    .globl aes_audit_production_256
aes_audit_production_256:
    call _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_encrypt_checked_bang
    ret
    .size aes_audit_production_256, . - aes_audit_production_256
    .globl main
main:
.L_m_1:
    jl .L_m_1
.L_m_2:
    jl .L_m_2
    call _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_construct_schedule
    call _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_encrypt_checked_bang
    call _tl_stdlib_crypto_stack_scrub_stdlib_crypto_stack_scrub_setup_bang
    call _tl_stdlib_crypto_secret_stdlib_crypto_secret_fixed_zero
    call _tl_stdlib_crypto_secret_stdlib_crypto_secret_storage_close
    ret
    .size main, . - main
EOF
}

emit_synth_gcm_linux_opt2() {
    # Reuse the shared AES core bodies (excluding AES-only roots/setup/construct_schedule)
    # and append GCM + GHASH + secret wipe bodies.
    emit_synth_aes_linux_opt2 | awk '
        /^[[:space:]]*\.globl (_tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_construct_schedule|_tl_stdlib_crypto_stack_scrub_stdlib_crypto_stack_scrub_setup_bang|aes_audit_production_128|aes_audit_production_256|main)$/ { skip = 1; next }
        skip && /^[[:space:]]*\.size / { skip = 0; next }
        !skip { print }
    '
    cat <<'EOF'
    .globl _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_close
_tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_close:
    call _tl_stdlib_crypto_secret_stdlib_crypto_secret_storage_close
    ret
    .size _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_close, . - _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_close
    .globl _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_construct_key
_tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_construct_key:
    call _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_construct_key_operation
    call _tl_stdlib_crypto_stack_scrub_stdlib_crypto_stack_scrub_tree_bang
    ret
    .size _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_construct_key, . - _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_construct_key
    .globl _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_construct_key_operation
_tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_construct_key_operation:
    movq _tl_stdlib_crypto_secret_stdlib_crypto_secret_secret_generation(%rip), %r8
    call _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_check_fixed
    call _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_encrypt_checked_bang
    call _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_expand_bang
    call _tl_stdlib_crypto_secret_stdlib_crypto_secret_bytes_set_length_bang
    call _tl_stdlib_crypto_secret_stdlib_crypto_secret_fixed_zero
    call _tl_stdlib_crypto_secret_stdlib_crypto_secret_storage_close
    call _tl_stdlib_crypto_secret_stdlib_crypto_secret_storage_live_question
    call _tl_stdlib_crypto_secret_stdlib_crypto_secret_storage_new
    ret
    .size _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_construct_key_operation, . - _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_construct_key_operation
    .globl _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_gctr_bang
_tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_gctr_bang:
    leaq .L_tl_str_l28_874630466_516989515(%rip), %rdi
    shrl %cl, %edx
.L_gctr_1:
    jl .L_gctr_1
.L_gctr_2:
    jl .L_gctr_2
.L_gctr_3:
    jl .L_gctr_3
.L_gctr_4:
    jl .L_gctr_4
.L_gctr_5:
    jl .L_gctr_5
.L_gctr_6:
    jl .L_gctr_6
    call _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_encrypt_checked_bang
    call tl_abort_string
    ret
    .size _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_gctr_bang, . - _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_gctr_bang
    .globl _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_prepare_bang
_tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_prepare_bang:
    shrl %cl, %edx
.L_prep_1:
    jl .L_prep_1
.L_prep_2:
    jl .L_prep_2
.L_prep_3:
    jl .L_prep_3
    call _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_check_fixed
    call _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_encrypt_checked_bang
    ret
    .size _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_prepare_bang, . - _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_prepare_bang
    .globl _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_seal
_tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_seal:
    call _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_seal_operation
    call _tl_stdlib_crypto_stack_scrub_stdlib_crypto_stack_scrub_tree_bang
    ret
    .size _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_seal, . - _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_seal
    .globl _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_seal_operation
_tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_seal_operation:
    call _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_validate_lengths
    call _tl_stdlib_byte_buf_stdlib_byte_buf_with_capacity
    call _tl_stdlib_crypto_secret_stdlib_crypto_secret_fixed_zero
    call _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_prepare_bang
.L_seal_1:
    jl .L_seal_1
.L_seal_2:
    jl .L_seal_2
.L_seal_3:
    jl .L_seal_3
.L_seal_4:
    jl .L_seal_4
    call _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_gctr_bang
    call _tl_stdlib_crypto_ghash_core_stdlib_crypto_ghash_core_authenticate_bang
    call _tl_stdlib_crypto_secret_stdlib_crypto_secret_storage_close
    ret
    .size _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_seal_operation, . - _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_seal_operation
    .globl _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_validate_lengths
_tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_validate_lengths:
    cmpq %rsi, %rdi
    jbe .L_vl_ok
.L_vl_ok:
    ret
    .size _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_validate_lengths, . - _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_validate_lengths
    .globl _tl_stdlib_crypto_ghash_core_stdlib_crypto_ghash_core_absorb_bang
_tl_stdlib_crypto_ghash_core_stdlib_crypto_ghash_core_absorb_bang:
.L_ga_1:
    jl .L_ga_1
.L_ga_2:
    jl .L_ga_2
.L_ga_3:
    jl .L_ga_3
.L_ga_4:
    jl .L_ga_4
.L_ga_5:
    jl .L_ga_5
.L_ga_6:
    jl .L_ga_6
.L_ga_7:
    jl .L_ga_7
.L_ga_8:
    jl .L_ga_8
.L_ga_9:
    jl .L_ga_9
.L_ga_10:
    jl .L_ga_10
.L_ga_11:
    jl .L_ga_11
    jmp _tl_stdlib_crypto_ghash_core_stdlib_crypto_ghash_core_multiply_bang
    .size _tl_stdlib_crypto_ghash_core_stdlib_crypto_ghash_core_absorb_bang, . - _tl_stdlib_crypto_ghash_core_stdlib_crypto_ghash_core_absorb_bang
    .globl _tl_stdlib_crypto_ghash_core_stdlib_crypto_ghash_core_authenticate_bang
_tl_stdlib_crypto_ghash_core_stdlib_crypto_ghash_core_authenticate_bang:
    leaq (,%rbx,8), %rbx
    call _tl_stdlib_crypto_ghash_core_stdlib_crypto_ghash_core_region_bang
    call _tl_stdlib_crypto_ghash_core_stdlib_crypto_ghash_core_multiply_bang
    call _tl_stdlib_crypto_ghash_core_stdlib_crypto_ghash_core_store_be_bang
.L_au_1:
    jl .L_au_1
.L_au_2:
    jl .L_au_2
    call _tl_stdlib_crypto_secret_stdlib_crypto_secret_wipe_words_bang
    ret
    .size _tl_stdlib_crypto_ghash_core_stdlib_crypto_ghash_core_authenticate_bang, . - _tl_stdlib_crypto_ghash_core_stdlib_crypto_ghash_core_authenticate_bang
    .globl _tl_stdlib_crypto_ghash_core_stdlib_crypto_ghash_core_multiply_bang
_tl_stdlib_crypto_ghash_core_stdlib_crypto_ghash_core_multiply_bang:
.L_mul_outer:
    movq (%rax,%rsi,8), %r9
.L_mul_inner:
    shrq $63, %r9
    cmpq $64, %rdx
    jl .L_mul_inner
    cmpq $2, %rsi
    jl .L_mul_outer
    call _tl_stdlib_crypto_secret_stdlib_crypto_secret_wipe_words_bang
    ret
    .size _tl_stdlib_crypto_ghash_core_stdlib_crypto_ghash_core_multiply_bang, . - _tl_stdlib_crypto_ghash_core_stdlib_crypto_ghash_core_multiply_bang
    .globl _tl_stdlib_crypto_ghash_core_stdlib_crypto_ghash_core_region_bang
_tl_stdlib_crypto_ghash_core_stdlib_crypto_ghash_core_region_bang:
.L_reg_loop:
    call _tl_stdlib_crypto_ghash_core_stdlib_crypto_ghash_core_multiply_bang
    jl .L_reg_loop
    jmp _tl_stdlib_crypto_ghash_core_stdlib_crypto_ghash_core_absorb_bang
    .size _tl_stdlib_crypto_ghash_core_stdlib_crypto_ghash_core_region_bang, . - _tl_stdlib_crypto_ghash_core_stdlib_crypto_ghash_core_region_bang
    .globl _tl_stdlib_crypto_ghash_core_stdlib_crypto_ghash_core_store_be_bang
_tl_stdlib_crypto_ghash_core_stdlib_crypto_ghash_core_store_be_bang:
.L_sb_loop:
    movb %r9b, (%rdi,%rax,1)
    jl .L_sb_loop
    ret
    .size _tl_stdlib_crypto_ghash_core_stdlib_crypto_ghash_core_store_be_bang, . - _tl_stdlib_crypto_ghash_core_stdlib_crypto_ghash_core_store_be_bang
    .globl _tl_stdlib_crypto_secret_stdlib_crypto_secret_wipe_words_bang
_tl_stdlib_crypto_secret_stdlib_crypto_secret_wipe_words_bang:
.L_ww_loop:
    movq %rsi, (%rdi)
    jl .L_ww_loop
    ret
    .size _tl_stdlib_crypto_secret_stdlib_crypto_secret_wipe_words_bang, . - _tl_stdlib_crypto_secret_stdlib_crypto_secret_wipe_words_bang
    .globl _tl_stdlib_crypto_stack_scrub_stdlib_crypto_stack_scrub_tree_bang
_tl_stdlib_crypto_stack_scrub_stdlib_crypto_stack_scrub_tree_bang:
    call _tl_stdlib_crypto_stack_scrub_stdlib_crypto_stack_scrub_wipe_chunks_bang
    ret
    .size _tl_stdlib_crypto_stack_scrub_stdlib_crypto_stack_scrub_tree_bang, . - _tl_stdlib_crypto_stack_scrub_stdlib_crypto_stack_scrub_tree_bang
    .globl gcm_audit_open
gcm_audit_open:
    call _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_validate_lengths
    call _tl_stdlib_byte_buf_stdlib_byte_buf_with_capacity
    call _tl_stdlib_crypto_secret_stdlib_crypto_secret_fixed_zero
    call _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_prepare_bang
    call _tl_stdlib_crypto_ghash_core_stdlib_crypto_ghash_core_authenticate_bang
.L_open_tag:
    movzbl (%rbx,%rax,1), %edi
    movzbl (%rcx,%rax,1), %r9d
    xorb %r9b, %dil
    orq %rdi, %rsi
    addq $1, %rax
    cmpq $16, %rax
    jl .L_open_tag
    testq %rsi, %rsi
    je .L_open_ok
    jmp .L_open_done
.L_open_ok:
    call _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_gctr_bang
.L_open_done:
    call _tl_stdlib_crypto_secret_stdlib_crypto_secret_storage_close
    call _tl_stdlib_crypto_stack_scrub_stdlib_crypto_stack_scrub_tree_bang
    ret
    .size gcm_audit_open, . - gcm_audit_open
    .globl gcm_audit_seal
gcm_audit_seal:
    call _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_seal
    ret
    .size gcm_audit_seal, . - gcm_audit_seal
    .globl main
main:
    leaq .L_tl_str_l17_892197212_524576675(%rip), %rax
    call _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_construct_key
    call _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_seal
    call _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_validate_lengths
    call _tl_stdlib_byte_buf_stdlib_byte_buf_with_capacity
    call _tl_stdlib_crypto_secret_stdlib_crypto_secret_fixed_zero
    call _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_prepare_bang
    call _tl_stdlib_crypto_ghash_core_stdlib_crypto_ghash_core_authenticate_bang
.L_gm_tag:
    jl .L_gm_tag
    call _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_gctr_bang
    call _tl_stdlib_crypto_secret_stdlib_crypto_secret_storage_close
    call _tl_stdlib_crypto_stack_scrub_stdlib_crypto_stack_scrub_tree_bang
    call _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_close
    ret
    .size main, . - main
EOF
}

run_self_test() {
    base=${CRYPTO_SHAPE_SELFTEST_WORKDIR:-"$ROOT/target/exp/crypto-shape-self-test"}
    mkdir -p "$base"
    work=$(mktemp -d "$base/run.XXXXXX")
    fail_st() { echo "crypto-shape self-test FAILED: $* (evidence: $work)" >&2; exit 1; }

    emit_synth_aes_linux_opt2 > "$work/aes.s"
    emit_synth_gcm_linux_opt2 > "$work/gcm.s"

    # Positive controls (LF and CRLF)
    verify_shape "$work/aes.s" "$work/pos-aes" linux-x86_64 2 aes || fail_st "positive AES control rejected"
    verify_shape "$work/gcm.s" "$work/pos-gcm" linux-x86_64 2 gcm || fail_st "positive GCM control rejected"
    awk '{ printf "%s\r\n", $0 }' "$work/aes.s" > "$work/aes-crlf.s"
    verify_shape "$work/aes-crlf.s" "$work/pos-aes-crlf" linux-x86_64 2 aes || fail_st "CRLF positive AES control rejected"

    # Benign backend mutations (#9935 spill offset, #9926 tail-merge jmp, #9903 reg rename, #9877 abort stub, arg_entry ordinal + callq)
    awk '
        { gsub(/16\(%rsp\)/, "248(%rsp)"); gsub(/%r9/, "%r11"); gsub(/call "__tl_arg_entry:36"/, "callq \"__tl_arg_entry:999\""); gsub(/__tl_arg_entry:36/, "__tl_arg_entry:999"); gsub(/\.L_tl_abort_tl_div_abort_at/, "tl_div_abort_at") }
        /^_tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_construct_schedule:$/ { print; print "    jmp .L_tail_merge_benign"; print ".L_tail_merge_benign:"; next }
        { print }
    ' "$work/aes.s" > "$work/benign-aes.s"
    verify_shape "$work/benign-aes.s" "$work/pos-benign" linux-x86_64 2 aes || fail_st "benign backend mutation rejected"

    expect_reject() {
        name=$1
        fam=$2
        asm=$3
        expected_err=$4
        if ( verify_shape "$asm" "$work/neg-$name" linux-x86_64 2 "$fam" ) > "$work/neg-$name.out" 2> "$work/neg-$name.err"; then
            fail_st "planted violation accepted: $name"
        fi
        if ! grep -Fq -- "$expected_err" "$work/neg-$name.err"; then
            fail_st "planted violation $name rejected with unexpected stderr (expected '$expected_err'): $(cat "$work/neg-$name.err")"
        fi
    }

    # 1. Missing required crypto symbol
    awk '
        /\.globl _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_mix_columns_bang$/ { skip=1; next }
        skip && /\.size _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_mix_columns_bang,/ { skip=0; next }
        !skip { print }
    ' "$work/aes.s" > "$work/m-missing-sym.s"
    expect_reject missing-required-symbol aes "$work/m-missing-sym.s" "missing audited symbol: _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_mix_columns_bang"

    # 2. Missing production root
    awk '
        /\.globl aes_audit_production_128$/ { skip=1; next }
        skip && /\.size aes_audit_production_128,/ { skip=0; next }
        !skip { print }
    ' "$work/aes.s" > "$work/m-missing-root.s"
    expect_reject missing-production-root aes "$work/m-missing-root.s" "missing audited symbol: aes_audit_production_128"

    # 3. Unexpected extra crypto symbol
    cat "$work/aes.s" > "$work/m-extra-sym.s"
    cat >> "$work/m-extra-sym.s" <<'EOF'
    .globl _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_rogue_helper
_tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_rogue_helper:
    ret
    .size _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_rogue_helper, . - _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_rogue_helper
EOF
    expect_reject unexpected-extra-symbol aes "$work/m-extra-sym.s" "unexpected audited symbol: _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_rogue_helper"

    # 4. Planted conditional branch in straight-line primitive
    awk '/^_tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_sub_bytes_bang:$/ { print; print "    je .L_rogue"; print ".L_rogue:"; next } { print }' "$work/aes.s" > "$work/m-branch.s"
    expect_reject planted-branch-straight-line aes "$work/m-branch.s" "sub_bytes_bang: conditional branches 1 exceed contract bound 0"

    # 5. Planted unconditional local jmp in straight-line primitive
    awk '/^_tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_mix_columns_bang:$/ { print; print "    jmp .L_rogue_jmp"; print ".L_rogue_jmp:"; next } { print }' "$work/aes.s" > "$work/m-jmp.s"
    expect_reject planted-jmp-straight-line aes "$work/m-jmp.s" "mix_columns_bang: internal jumps 1 exceed straight-line bound 0"

    # 6. Planted cmov*
    awk '/^_tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_sub_bytes_bang:$/ { print; print "    cmoveq %rax, %rbx"; next } { print }' "$work/aes.s" > "$work/m-cmov.s"
    expect_reject planted-cmov aes "$work/m-cmov.s" "sub_bytes_bang: disallowed cmov instruction count=1"

    # 7. Planted set* in straight-line primitive
    awk '/^_tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_squeeze_bang:$/ { print; print "    sete %al"; next } { print }' "$work/aes.s" > "$work/m-setcc.s"
    expect_reject planted-setcc aes "$work/m-setcc.s" "squeeze_bang: setcc count 1 exceeds contract bound 0"

    # 8. Planted div/idiv in cipher
    awk '/^_tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_cipher_bang:$/ { print; print "    idivq %rcx"; next } { print }' "$work/aes.s" > "$work/m-div.s"
    expect_reject planted-div aes "$work/m-div.s" "cipher_bang: div/idiv count 1 exceeds contract bound 0"

    # 9. Planted variable %cl shift in straight-line primitive
    awk '/^_tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_sub_bytes_bang:$/ { print; print "    shrq %cl, %rax"; next } { print }' "$work/aes.s" > "$work/m-vshift.s"
    expect_reject planted-variable-shift aes "$work/m-vshift.s" "sub_bytes_bang: variable shift count 1 exceeds contract bound 0"

    # 10. Planted indirect call
    awk '/^_tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_cipher_bang:$/ { print; print "    call *%rax"; next } { print }' "$work/aes.s" > "$work/m-ind-call.s"
    expect_reject planted-indirect-call aes "$work/m-ind-call.s" "cipher_bang: indirect call/jmp count 1 exceeds contract bound 0"

    # 11. Planted RIP-relative table load
    awk '/^_tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_sub_bytes_bang:$/ { print; print "    movzbl sbox_table(%rip), %eax"; next } { print }' "$work/aes.s" > "$work/m-rip.s"
    expect_reject planted-rip-table aes "$work/m-rip.s" "sub_bytes_bang: disallowed RIP-relative operand:"

    # 12. Planted indexed lookup in straight-line primitive
    awk '/^_tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_sub_bytes_bang:$/ { print; print "    movzbl (%rdi,%rax,1), %eax"; next } { print }' "$work/aes.s" > "$work/m-idx.s"
    expect_reject planted-indexed-load aes "$work/m-idx.s" "sub_bytes_bang: indexed memory operands 1 exceed contract bound 0"

    # 13. Planted cmpb in GHASH multiply
    awk '/^_tl_stdlib_crypto_ghash_core_stdlib_crypto_ghash_core_multiply_bang:$/ { print; print "    cmpb %al, %bl"; next } { print }' "$work/gcm.s" > "$work/m-cmpb.s"
    expect_reject planted-cmpb-ghash gcm "$work/m-cmpb.s" "multiply_bang: disallowed cmpb/testb instruction count=1"

    # 14. Removed wipe_words_bang in cipher_bang
    awk '/_tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_cipher_bang:$/ { in_fn=1 } /\.size _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_cipher_bang,/ { in_fn=0 } in_fn && /wipe_words_bang/ { next } { print }' "$work/aes.s" > "$work/m-no-cipher-wipe.s"
    expect_reject removed-cipher-wipe aes "$work/m-no-cipher-wipe.s" "cipher_bang: missing required call target _tl_stdlib_crypto_secret_stdlib_crypto_secret_wipe_words_bang"

    # 15. Removed wipe_words_bang in ghash multiply_bang
    awk '/_tl_stdlib_crypto_ghash_core_stdlib_crypto_ghash_core_multiply_bang:$/ { in_fn=1 } /\.size _tl_stdlib_crypto_ghash_core_stdlib_crypto_ghash_core_multiply_bang,/ { in_fn=0 } in_fn && /wipe_words_bang/ { next } { print }' "$work/gcm.s" > "$work/m-no-ghash-wipe.s"
    expect_reject removed-ghash-wipe gcm "$work/m-no-ghash-wipe.s" "multiply_bang: missing required call target _tl_stdlib_crypto_secret_stdlib_crypto_secret_wipe_words_bang"

    # 16. Swapped squeeze / wipe order in cipher_bang (scoped to cipher_bang)
    awk '
        /^_tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_cipher_bang:$/ { in_fn=1 }
        /\.size _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_cipher_bang,/ { in_fn=0 }
        in_fn && /call _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_squeeze_bang/ { print "    call _tl_stdlib_crypto_secret_stdlib_crypto_secret_wipe_words_bang"; next }
        in_fn && /call _tl_stdlib_crypto_secret_stdlib_crypto_secret_wipe_words_bang/ { print "    call _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_squeeze_bang"; next }
        { print }
    ' "$work/aes.s" > "$work/m-cipher-order.s"
    expect_reject swapped-cipher-wipe-order aes "$work/m-cipher-order.s" "cipher_bang: required call order violated at _tl_stdlib_crypto_secret_stdlib_crypto_secret_wipe_words_bang"

    # 17. Swapped verify-before-decrypt order in GCM open
    awk '
        /^gcm_audit_open:$/ { in_fn=1 }
        /\.size gcm_audit_open,/ { in_fn=0 }
        in_fn && /call _tl_stdlib_crypto_ghash_core_stdlib_crypto_ghash_core_authenticate_bang/ { print "    call _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_gctr_bang"; next }
        in_fn && /call _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_gctr_bang/ { print "    call _tl_stdlib_crypto_ghash_core_stdlib_crypto_ghash_core_authenticate_bang"; next }
        { print }
    ' "$work/gcm.s" > "$work/m-open-order.s"
    expect_reject swapped-gcm-open-order gcm "$work/m-open-order.s" "gcm_audit_open: required call order violated at _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_gctr_bang"

    # 18. Unauthorized external call target
    awk '/^_tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_cipher_bang:$/ { print; print "    call memcpy"; next } { print }' "$work/aes.s" > "$work/m-ext-call.s"
    expect_reject unauthorized-external-call aes "$work/m-ext-call.s" "cipher_bang: unauthorized call target memcpy"

    # 19. Conditional branch bound exceeded
    awk '/^_tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_cipher_bang:$/ { print; print "    je .L_b1"; print "    je .L_b2"; print "    je .L_b3"; print ".L_b1:"; print ".L_b2:"; print ".L_b3:"; next } { print }' "$work/aes.s" > "$work/m-jcc-overflow.s"
    expect_reject branch-bound-exceeded aes "$work/m-jcc-overflow.s" "cipher_bang: conditional branches 5 exceed contract bound 4"

    # 20. Tampered __tl_arg_entry stub
    awk '/^"__tl_arg_entry:36":$/ { print; print "    je .L_bad_stub"; next } { print }' "$work/aes.s" > "$work/m-bad-stub.s"
    expect_reject tampered-arg-entry-stub aes "$work/m-bad-stub.s" "disallowed instruction in arg entry stub __tl_arg_entry:36"

    # 21. Removed volatile zero store in wipe_words_bang
    awk '/^_tl_stdlib_crypto_secret_stdlib_crypto_secret_wipe_words_bang:$/ { in_fn=1 } /\.size _tl_stdlib_crypto_secret_stdlib_crypto_secret_wipe_words_bang,/ { in_fn=0 } in_fn && /movq %rsi, \(%rdi\)/ { next } { print }' "$work/gcm.s" > "$work/m-no-vol-store.s"
    expect_reject removed-volatile-wipe-store gcm "$work/m-no-vol-store.s" "wipe_words_bang: missing volatile indirect word store"

    # 22. Removed inlined 16-byte tag compare loop in opt2 gcm_audit_open
    awk '/^gcm_audit_open:$/ { in_fn=1 } /\.size gcm_audit_open,/ { in_fn=0 } in_fn && /cmpq \$16, %rax/ { next } { print }' "$work/gcm.s" > "$work/m-no-open-tag-loop.s"
    expect_reject removed-open-tag-loop gcm "$work/m-no-open-tag-loop.s" "gcm_audit_open: missing inlined 16-byte constant-time tag comparison loop"

    # 23. Non-RIP closed-ELF literal load ($sym immediate, even in str-permitted function)
    awk '/^_tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_expand_bang:$/ { print; print "    movl $.L_tl_bytes_sbox, %eax"; next } { print }' "$work/aes.s" > "$work/m-imm-sym.s"
    expect_reject planted-imm-symbol-load aes "$work/m-imm-sym.s" "expand_bang: disallowed static symbol immediate:"

    # 24. Symbol-prefixed memory load (non-RIP table base)
    awk '/^_tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_sub_bytes_bang:$/ { print; print "    movzbl sbox_table(%rax), %eax"; next } { print }' "$work/aes.s" > "$work/m-sym-mem.s"
    expect_reject planted-symbol-prefixed-load aes "$work/m-sym-mem.s" "sub_bytes_bang: disallowed symbol-prefixed memory operand:"

    # 25. Symbol-prefixed indexed lea even where max_idx_lea > 0
    awk '
        /^_tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_add_round_key_bang:$/ { in_fn=1 }
        /\.size _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_add_round_key_bang,/ { in_fn=0 }
        in_fn && /leaq \(%rsi,%rax,1\), %rax/ { print "    leaq sbox_table(,%rax,1), %rax"; next }
        { print }
    ' "$work/aes.s" > "$work/m-sym-lea.s"
    expect_reject planted-symbol-prefixed-lea aes "$work/m-sym-lea.s" "add_round_key_bang: disallowed symbol-prefixed memory operand:"

    # 26. Spaced indexed operand
    awk '/^_tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_sub_bytes_bang:$/ { print; print "    movzbl (%rdi, %rax, 1), %eax"; next } { print }' "$work/aes.s" > "$work/m-spaced-idx.s"
    expect_reject planted-spaced-indexed-load aes "$work/m-spaced-idx.s" "sub_bytes_bang: indexed memory operands 1 exceed contract bound 0"

    # 27. Spaced scaled-index table operand
    awk '/^_tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_sub_bytes_bang:$/ { print; print "    movzbl (, %rax, 1), %eax"; next } { print }' "$work/aes.s" > "$work/m-spaced-scale0.s"
    expect_reject planted-spaced-scaled-index aes "$work/m-spaced-scale0.s" "sub_bytes_bang: disallowed scaled-index table operand:"

    # 28. Indirect callq
    awk '/^_tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_cipher_bang:$/ { print; print "    callq *%rax"; next } { print }' "$work/aes.s" > "$work/m-callq-ind.s"
    expect_reject planted-indirect-callq aes "$work/m-callq-ind.s" "cipher_bang: indirect call/jmp count 1 exceeds contract bound 0"

    # 29. Unauthorized external callq
    awk '/^_tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_cipher_bang:$/ { print; print "    callq memcpy"; next } { print }' "$work/aes.s" > "$work/m-callq-ext.s"
    expect_reject unauthorized-external-callq aes "$work/m-callq-ext.s" "cipher_bang: unauthorized call target memcpy"

    # 30. Indirect jmpq (must be caught as indirect jmp, not jcc)
    awk '/^_tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_cipher_bang:$/ { print; print "    jmpq *%rax"; next } { print }' "$work/aes.s" > "$work/m-jmpq-ind.s"
    expect_reject planted-indirect-jmpq aes "$work/m-jmpq-ind.s" "cipher_bang: disallowed indirect jmp:"

    # 31. Unauthorized tail-call jmpq (must be caught as unauthorized call target, not jcc)
    awk '/^_tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_cipher_bang:$/ { print; print "    jmpq memcpy"; next } { print }' "$work/aes.s" > "$work/m-jmpq-ext.s"
    expect_reject unauthorized-external-jmpq aes "$work/m-jmpq-ext.s" "cipher_bang: unauthorized call target memcpy"

    # 32. Extra gctr_bang before authenticate_bang while keeping the later gctr_bang
    awk '
        /^gcm_audit_open:$/ { in_fn=1 }
        /\.size gcm_audit_open,/ { in_fn=0 }
        in_fn && /call _tl_stdlib_crypto_ghash_core_stdlib_crypto_ghash_core_authenticate_bang/ {
            print "    call _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_gctr_bang"
        }
        { print }
    ' "$work/gcm.s" > "$work/m-early-gctr.s"
    expect_reject early-gctr-before-authenticate gcm "$work/m-early-gctr.s" "gcm_audit_open: required call order violated at _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_gctr_bang"

    # 33. Extra sub_bytes_bang after wipe_words_bang in cipher_bang
    awk '
        /^_tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_cipher_bang:$/ { in_fn=1 }
        /\.size _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_cipher_bang,/ { in_fn=0 }
        in_fn && /call _tl_stdlib_crypto_secret_stdlib_crypto_secret_wipe_words_bang/ {
            print
            print "    call _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_sub_bytes_bang"
            next
        }
        { print }
    ' "$work/aes.s" > "$work/m-late-sub-bytes.s"
    expect_reject late-sub-bytes-after-wipe aes "$work/m-late-sub-bytes.s" "cipher_bang: required call order violated at _tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_squeeze_bang"

    # 34. Tail-jmp gctr_bang closes opt2 tag-compare window (loop moved after jmp gctr_bang)
    awk '
        /^gcm_audit_open:$/ { in_fn=1 }
        /\.size gcm_audit_open,/ { in_fn=0 }
        in_fn && /call _tl_stdlib_crypto_ghash_core_stdlib_crypto_ghash_core_authenticate_bang/ {
            print
            print "    jmp _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_gctr_bang"
            next
        }
        in_fn && /call _tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_gctr_bang/ { next }
        { print }
    ' "$work/gcm.s" > "$work/m-jmp-gctr-window.s"
    expect_reject jmp-gctr-closes-tag-window gcm "$work/m-jmp-gctr-window.s" "gcm_audit_open: missing inlined 16-byte constant-time tag comparison loop"

    # 35. Early-exit conditional branch inside opt2 tag-compare loop
    awk '
        /^gcm_audit_open:$/ { in_fn=1 }
        /\.size gcm_audit_open,/ { in_fn=0 }
        in_fn && /xorb %r9b, %dil/ { print "    cmpl %r9d, %edi"; print "    jne .L_open_done"; next }
        in_fn && /orq %rdi, %rsi/ { next }
        { print }
    ' "$work/gcm.s" > "$work/m-open-tag-early-exit.s"
    expect_reject early-exit-open-tag-loop gcm "$work/m-open-tag-early-exit.s" "gcm_audit_open: disallowed conditional branch inside opt2 tag-compare loop before backward edge count=1"

    # 36. Planted BMI2 variable shift in straight-line primitive
    awk '/^_tl_stdlib_crypto_aes_core_stdlib_crypto_aes_core_sub_bytes_bang:$/ { print; print "    shrxq %rcx, %rax, %rdx"; next } { print }' "$work/aes.s" > "$work/m-bmi2-shift.s"
    expect_reject planted-bmi2-variable-shift aes "$work/m-bmi2-shift.s" "sub_bytes_bang: variable shift count 1 exceeds contract bound 0"

    rm -rf -- "${work:?}"
    echo 'crypto-shape self-test passed (4 positive/benign controls + 36 fail-closed mutations)'
}

if [ "$#" -eq 1 ] && [ "$1" = --self-test ]; then
    run_self_test
    exit 0
fi

[ "$#" -eq 4 ] || [ "$#" -eq 5 ] || usage
verify_shape "$1" "$2" "$3" "$4" "${5:-aes}"
