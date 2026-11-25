#!/usr/bin/env sh
set -eu

# verify-safety-corpus.sh - safe-code contract corpus.
#
# The manifest pairs small TypeLisp fixtures with check/run expectations for the
# SPEC.md "Safe code: no undefined behavior" table.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-linux-entry.sh"
. "$ROOT/scripts/lib-source-location.sh"
. "$ROOT/scripts/lib-manifest.sh"
BOUNDED_POOL_LABEL=safety-corpus
. "$ROOT/scripts/lib-bounded-pool.sh"

HOST_OS=linux
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    *)
        echo "safety corpus verification is unsupported on this host" >&2
        exit 1
        ;;
esac

GATE_FAIL_PREFIX='FAIL: '
. "$ROOT/scripts/lib-gate.sh"

SELF_TEST_ONLY=false
case "${1:-}" in
    --self-test) SELF_TEST_ONLY=true; shift ;;
    "") ;;
    *) fail "usage: scripts/verify-safety-corpus.sh [--self-test]" ;;
esac
[ "$#" -eq 0 ] || fail "unexpected arguments"

SAFETY_WORKERS=${TYPELISP_SAFETY_WORKERS:-4}
case "$SAFETY_WORKERS" in
    1 | 2 | 3 | 4 | 5 | 6 | 7 | 8) ;;
    *) fail "invalid TYPELISP_SAFETY_WORKERS: $SAFETY_WORKERS (expected 1-8)" ;;
esac
SAFETY_CHECK_CHUNK_SIZE=${TYPELISP_SAFETY_CHECK_CHUNK_SIZE:-96}
SAFETY_RUN_CHUNK_SIZE=${TYPELISP_SAFETY_RUN_CHUNK_SIZE:-48}
SAFETY_JOB_CAP_MIB=384
SAFETY_POOL_BUDGET_MIB=$((SAFETY_WORKERS * SAFETY_JOB_CAP_MIB))

prepare_tools() {
    gate_compiler
    gate_compiler_absolute
    gate_require_compiler
    if [ "$HOST_OS" = linux ]; then
        command -v as >/dev/null 2>&1 || fail "missing assembler: as"
        command -v ld >/dev/null 2>&1 || fail "missing linker: ld"
    else
        command -v clang >/dev/null 2>&1 || fail "missing assembler: clang"
        command -v lld-link >/dev/null 2>&1 || fail "missing linker: lld-link"
    fi
}

MANIFEST=${TYPELISP_SAFETY_MANIFEST:-tests/safety/manifest.d}
if [ ! -d "$MANIFEST" ]; then
    echo "safety corpus manifest directory does not exist: $MANIFEST" >&2
    exit 1
fi

default_workdir=target/safety-corpus-verify
if [ "$SELF_TEST_ONLY" = true ]; then
    default_workdir=target/exp/safety-oracle-self-test
fi
WORKDIR=${TYPELISP_SAFETY_WORKDIR:-$default_workdir}
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
NORMALIZED_MANIFEST="$WORKDIR/manifest.normalized"
manifest_concat_dir "$MANIFEST" > "$NORMALIZED_MANIFEST"

BUILD_TARGET=linux-x86_64
TARGET_CFG_ARGS="--cfg linux --cfg unix --cfg target-linux --cfg os-linux"
if [ "$HOST_OS" = windows ]; then
    BUILD_TARGET=windows-x86_64
    TARGET_CFG_ARGS="--cfg windows --cfg target-windows --cfg os-windows"
fi

case "$WORKDIR" in
    /*) WORKDIR_ABS=$WORKDIR ;;
    *) WORKDIR_ABS=$ROOT/$WORKDIR ;;
esac

host_path() {
    if [ "$HOST_OS" = windows ] && command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        printf '%s\n' "$1"
    fi
}

assert_contains() {
    file=$1
    needle=$2
    if ! grep -F -- "$needle" "$file" >/dev/null; then
        echo "expected substring: $needle" >&2
        echo "actual output:" >&2
        sed 's/^/  /' "$file" >&2 || true
        return 1
    fi
}

assert_empty() {
    file=$1
    if [ -s "$file" ]; then
        echo "expected empty output, got:" >&2
        sed 's/^/  /' "$file" >&2 || true
        return 1
    fi
}

# An expected rejection is a normal checker exit with a structured diagnostic
# for the intended operation. In particular, a diagnostic followed by a signal
# is a compiler failure, not evidence that the checker rejected safely.
classify_check_status() {
    case "$1" in
        0|1) echo normal ;;
        124|125|126|127|130|137|143) echo infrastructure-resource-failure ;;
        *)
            if [ "$1" -gt 128 ]; then
                echo compiler-crash
            else
                echo infrastructure-resource-failure
            fi ;;
    esac
}

# Single-pass CRLF-safe classifier for one `typelisp check --batch` stream.
# Meta rows are `row_order|case_id|mode|source|diagnostic_source|stderr_contains`.
# Each entry in BATCH_OUT is framed by line counts:
#   CHECK_BATCH_ENTRY|<index>|<status>|<out_lines>|<err_lines>|<path>
# followed by exact <out_lines> stdout lines and <err_lines> stderr lines,
# terminated by `CHECK_BATCH_END|<count>`.
classify_check_batch_stream() {
    _ccb_meta=$1
    _ccb_out=$2
    _ccb_err=$3
    _ccb_rc=$4
    _ccb_route=$5
    _ccb_rej=$6
    _ccb_label=$7

    _ccb_status=$(classify_check_status "$_ccb_rc")
    if [ "$_ccb_status" != normal ]; then
        show_stream_if_nonempty stderr "$_ccb_err"
        echo "FAIL: batch chunk $_ccb_label $_ccb_status (exit $_ccb_rc)" >&2
        return 1
    fi
    if [ "$_ccb_rc" -ne 0 ]; then
        show_stream_if_nonempty stdout "$_ccb_out"
        show_stream_if_nonempty stderr "$_ccb_err"
        echo "FAIL: batch chunk $_ccb_label check --batch failed with exit $_ccb_rc" >&2
        return 1
    fi
    if [ -s "$_ccb_err" ]; then
        show_stream_if_nonempty stderr "$_ccb_err"
        echo "FAIL: batch chunk $_ccb_label emitted unexpected batch stderr" >&2
        return 1
    fi

    : > "$_ccb_rej"
    awk -v meta_file="$_ccb_meta" \
        -v route="$_ccb_route" \
        -v rej_file="$_ccb_rej" \
        -v label="$_ccb_label" '
        function fail_entry(msg, out_n, err_n,    k) {
            if (rej_file != "") close(rej_file)
            if (out_n > 0) {
                print "stdout:" > "/dev/stderr"
                for (k = 1; k <= out_n; k++) print "  " out_buf[k] > "/dev/stderr"
            }
            if (err_n > 0) {
                print "stderr:" > "/dev/stderr"
                for (k = 1; k <= err_n; k++) print "  " err_buf[k] > "/dev/stderr"
            }
            print "FAIL: " msg > "/dev/stderr"
            failed = 1
            exit 1
        }
        function classify_status(c) {
            if (c == 0 || c == 1) return "normal"
            if (c == 124 || c == 125 || c == 126 || c == 127 || c == 130 || c == 137 || c == 143)
                return "infrastructure-resource-failure"
            if (c > 128) return "compiler-crash"
            return "infrastructure-resource-failure"
        }
        function same_path(actual, expected) {
            return actual == expected ||
                (length(actual) > length(expected) &&
                 substr(actual, length(actual) - length(expected)) == "/" expected)
        }
        function diag_finish() {
            if (d_is_error && !d_primary) d_malformed = 1
            if (d_is_error && d_intended && d_located) d_matched = 1
        }
        function classify_rejection(code, out_n, err_n, diag_src, needle,    k, line, loc, path, st) {
            st = classify_status(code)
            if (st != "normal") return st
            if (code == 0) return "accepted-invalid"
            if (out_n > 0) return "malformed-output"
            d_header = 0
            d_is_error = 0
            d_primary = 0
            d_located = 0
            d_intended = 0
            d_matched = 0
            d_malformed = 0
            d_wrong = 0
            for (k = 1; k <= err_n; k++) {
                line = err_buf[k]
                if (index(line, "__tl_tc_") > 0) d_wrong = 1
                if (line ~ /^(error|warning|note)(\[[A-Z][0-9]+\])?: /) {
                    diag_finish()
                    d_header = 1
                    d_is_error = (line ~ /^error(\[E[0-9][0-9][0-9][0-9]\])?: /)
                    if (line ~ /^error/ && !d_is_error) d_malformed = 1
                    d_primary = 0
                    d_located = 0
                    d_intended = (index(line, needle) > 0)
                    if (line ~ /^error\[E0200\]: /) d_wrong = 1
                } else if (line ~ /^  --> /) {
                    if (!d_header) d_malformed = 1
                    loc = substr(line, 7)
                    gsub(/\\/, "/", loc)
                    if (loc !~ /:[1-9][0-9]*:[1-9][0-9]*$/) d_malformed = 1
                    if (d_primary && needle ~ /:[1-9][0-9]*:[1-9][0-9]*$/ && same_path(loc, needle))
                        d_intended = 1
                    if (!d_primary) {
                        d_primary = 1
                        path = loc
                        if (diag_src !~ /:[1-9][0-9]*:[1-9][0-9]*$/)
                            sub(/:[0-9]+:[0-9]+$/, "", path)
                        d_located = same_path(path, diag_src)
                    }
                } else if (line ~ /^   = (help|note|label): /) {
                    if (!d_header) d_malformed = 1
                    if (index(line, needle) > 0) d_intended = 1
                } else if (line ~ /^ *([0-9]+ )?\|/) {
                    if (!d_header) d_malformed = 1
                } else if (line ~ /^$/) {
                    continue
                } else {
                    d_malformed = 1
                }
            }
            diag_finish()
            if (d_malformed) return "malformed-output"
            if (d_wrong || !d_matched) return "wrong-diagnostic"
            return "rejected-invalid"
        }
        function check_decoded(case_label, err_n, out_n,    k) {
            for (k = 1; k <= err_n; k++) {
                if (index(err_buf[k], "error[E0200]") > 0)
                    fail_entry(case_label " regressed to generic E0200; assign a specific code or update the taxonomy", out_n, err_n)
                if (index(err_buf[k], "__tl_tc_") > 0)
                    fail_entry(case_label " rendered an internal typecheck error transport instead of decoding it", out_n, err_n)
            }
        }
        BEGIN {
            total = 0
            while ((getline mline < meta_file) > 0) {
                sub(/\r$/, "", mline)
                n = split(mline, f, "|")
                if (n < 6) {
                    print "FAIL: malformed batch meta row in " label > "/dev/stderr"
                    failed = 1
                    exit 1
                }
                m_order[total] = f[1]
                m_id[total] = f[2]
                m_mode[total] = f[3]
                m_src[total] = f[4]
                m_diag[total] = f[5]
                gsub(/\\/, "/", m_diag[total])
                # Reconstruct field 6 verbatim (in case stderr needle ever had more fields)
                needle_text = f[6]
                for (j = 7; j <= n; j++) needle_text = needle_text "|" f[j]
                m_needle[total] = needle_text
                total++
            }
            close(meta_file)
            if (total == 0) {
                print "FAIL: empty batch meta in " label > "/dev/stderr"
                failed = 1
                exit 1
            }

            for (i = 0; i < total; i++) {
                if ((getline hdr) <= 0)
                    fail_entry(label " truncated before entry " i " (" m_id[i] ")", 0, 0)
                sub(/\r$/, "", hdr)
                if (hdr !~ /^CHECK_BATCH_ENTRY\|[0-9]+\|[0-9]+\|[0-9]+\|[0-9]+\|/)
                    fail_entry(label " malformed batch header at entry " i ": " hdr, 0, 0)
                split(hdr, hf, "|")
                if ((hf[2] + 0) != i)
                    fail_entry(label " entry index mismatch: expected " i ", got " hf[2], 0, 0)
                code = hf[3] + 0
                out_n = hf[4] + 0
                err_n = hf[5] + 0
                delete out_buf
                delete err_buf
                for (k = 1; k <= out_n; k++) {
                    if ((getline line) <= 0)
                        fail_entry(m_id[i] " truncated batch stdout", k - 1, 0)
                    sub(/\r$/, "", line)
                    out_buf[k] = line
                }
                for (k = 1; k <= err_n; k++) {
                    if ((getline line) <= 0)
                        fail_entry(m_id[i] " truncated batch stderr", out_n, k - 1)
                    sub(/\r$/, "", line)
                    err_buf[k] = line
                }

                cid = m_id[i]
                mode = m_mode[i]
                if (mode == "check-ok") {
                    obs = classify_status(code)
                    if (obs != "normal")
                        fail_entry(cid " " obs " (exit " code ")", out_n, err_n)
                    if (code != 0)
                        fail_entry(cid " rejected-valid (exit " code ")", out_n, err_n)
                    if (err_n != 0)
                        fail_entry(cid " expected empty check stderr", out_n, err_n)
                    if (out_n != 1 || out_buf[1] != "Type checking passed!")
                        fail_entry(cid " malformed-output: missing check success record", out_n, err_n)
                } else if (mode == "check-fail") {
                    obs = classify_rejection(code, out_n, err_n, m_diag[i], m_needle[i])
                    printf "%s\t%s\t%d\t%s\n", m_order[i], cid, code, obs >> rej_file
                    if (obs != "rejected-invalid")
                        fail_entry(cid " " obs " (exit " code "; expected located diagnostic: " m_needle[i] ")", out_n, err_n)
                    check_decoded(cid, err_n, out_n)
                } else if (mode == "check-ok-windows") {
                    if (code != 0)
                        fail_entry(cid " expected Windows-target check success (" route " stdlib), got " code, out_n, err_n)
                    if (err_n != 0)
                        fail_entry(cid " expected empty Windows-target check stderr (" route " stdlib)", out_n, err_n)
                } else if (mode == "check-fail-windows") {
                    if (code == 0)
                        fail_entry(cid " expected Windows-target check failure (" route " stdlib)", out_n, err_n)
                    found_needle = 0
                    for (k = 1; k <= err_n; k++) {
                        if (index(err_buf[k], m_needle[i]) > 0) {
                            found_needle = 1
                            break
                        }
                    }
                    if (!found_needle)
                        fail_entry(cid " Windows-target stderr did not match expectation (" route " stdlib): " m_needle[i], out_n, err_n)
                    check_decoded(cid " (" route " stdlib)", err_n, out_n)
                } else {
                    fail_entry(cid " unexpected mode in check batch: " mode, out_n, err_n)
                }
            }

            if ((getline end_line) <= 0)
                fail_entry(label " missing CHECK_BATCH_END sentinel", 0, 0)
            sub(/\r$/, "", end_line)
            if (end_line != "CHECK_BATCH_END|" total)
                fail_entry(label " unexpected CHECK_BATCH_END sentinel: " end_line " (expected " total ")", 0, 0)
            if ((getline trailing) > 0)
                fail_entry(label " unexpected trailing line after CHECK_BATCH_END: " trailing, 0, 0)
            close(rej_file)
            exit 0
        }
    ' < "$_ccb_out"
}

run_case() {
    out=$1
    err=$2
    shift 2
    # Run the case once. A crash is a real bug, not a flake — do not retry it.
    set +e
    "$@" < /dev/null > "$out" 2> "$err"
    code=$?
    set -e
}

# Assemble (clang) + link (lld-link) a Windows .s into an .exe. The compile-only
# bootstrapped stage1 has no `build` host action, so the corpus drives the Windows
# toolchain by hand (mirrors verify-integration.sh's assemble_link_windows).
assemble_link_windows() {
    _asm=$1
    _obj=$2
    _bin=$3
    _label=$4
    _out=$5
    _err=$6
    if ! clang --target=x86_64-pc-windows-msvc -c "$_asm" -o "$_obj" \
        < /dev/null >> "$_out" 2>> "$_err"; then
        show_stream_if_nonempty stderr "$_err"
        fail "$_label assemble failed"
    fi
    _win_stdlib=$(windows_stdlib_archive_for_asm "$_asm" "${COMPILER:-}")
    if [ -n "$_win_stdlib" ]; then
        if ! lld-link -NOLOGO "$(cygpath -aw "$_obj")" "$(cygpath -aw "$_win_stdlib")" -OPT:REF \
            "-OUT:$(cygpath -aw "$_bin")" \
            -SUBSYSTEM:CONSOLE -STACK:268435456 -ENTRY:_tl_start -NODEFAULTLIB kernel32.lib ntdll.lib \
            < /dev/null >> "$_out" 2>> "$_err"; then
            show_stream_if_nonempty stderr "$_err"
            fail "$_label link failed"
        fi
    else
        if ! lld-link -NOLOGO "$(cygpath -aw "$_obj")" "-OUT:$(cygpath -aw "$_bin")" \
            -SUBSYSTEM:CONSOLE -STACK:268435456 -ENTRY:_tl_start -NODEFAULTLIB kernel32.lib ntdll.lib \
            < /dev/null >> "$_out" 2>> "$_err"; then
            show_stream_if_nonempty stderr "$_err"
            fail "$_label link failed"
        fi
    fi
}

show_stream_if_nonempty() {
    label=$1
    file=$2
    if [ -s "$file" ]; then
        echo "$label:" >&2
        sed 's/^/  /' "$file" >&2 || true
    fi
}

# Drive every rejection oracle mutation directly through the production
# `classify_check_batch_stream` classifier using single-entry framed probes.
rejection_oracle_self_test() {
    oracle_dir="$WORKDIR/oracle-self-test"
    mkdir -p "$oracle_dir"
    oracle_out="$oracle_dir/oracle.out"
    oracle_err="$oracle_dir/oracle.err"
    oracle_meta="$oracle_dir/oracle.meta"
    oracle_stream="$oracle_dir/oracle.stream"
    oracle_batch_err="$oracle_dir/oracle.batch.err"
    oracle_rej="$oracle_dir/oracle.rej"
    : > "$oracle_out"
    : > "$oracle_batch_err"
    oracle_count=0
    oracle_probe() {
        _op_name=$1
        _op_code=$2
        _op_want=$3
        _op_source=$4
        _op_needle=$5
        _op_out_n=$(wc -l < "$oracle_out" | tr -d ' ')
        _op_err_n=$(wc -l < "$oracle_err" | tr -d ' ')
        printf '1|%s|check-fail|fixture.tl|%s|%s\n' \
            "$_op_name" "$_op_source" "$_op_needle" > "$oracle_meta"
        {
            printf 'CHECK_BATCH_ENTRY|0|%s|%s|%s|fixture.tl\n' \
                "$_op_code" "$_op_out_n" "$_op_err_n"
            cat "$oracle_out"
            cat "$oracle_err"
            printf 'CHECK_BATCH_END|1\n'
        } > "$oracle_stream"
        set +e
        classify_check_batch_stream \
            "$oracle_meta" "$oracle_stream" "$oracle_batch_err" 0 host \
            "$oracle_rej" "oracle-$_op_name" 2>/dev/null
        _op_rc=$?
        set -e
        _op_actual=$(awk -F '\t' 'NR == 1 { print $4 }' "$oracle_rej")
        [ "$_op_actual" = "$_op_want" ] || fail "oracle $_op_name: expected $_op_want, got $_op_actual"
        if [ "$_op_want" = rejected-invalid ]; then
            [ "$_op_rc" -eq 0 ] || fail "oracle $_op_name: production batch classifier rejected valid probe (exit $_op_rc)"
        else
            [ "$_op_rc" -ne 0 ] || fail "oracle $_op_name: production batch classifier accepted $_op_want probe"
        fi
        oracle_count=$((oracle_count + 1))
    }
    oracle_expect() {
        oracle_probe "$1" "$2" "$3" "${4:-fixture.tl}" 'intended move'
    }
    oracle_expect_needle() {
        oracle_probe "$1" "$2" "$3" fixture.tl "$4"
    }
    oracle_diagnostic() {
        printf 'error[E0214]: intended move\n  --> %s\n   |\n 3 | (consume value)\n   | ^\n' "$1" > "$oracle_err"
    }
    oracle_diagnostic fixture.tl:3:1
    oracle_expect located 1 rejected-invalid
    printf '  --> provider.tl:8:9\n   |\n   = label: expanded here\n' >> "$oracle_err"
    oracle_expect expansion-label 1 rejected-invalid
    printf 'error: intended move\n  --> fixture.tl:3:1\n' > "$oracle_err"
    oracle_expect macro-diagnostic-without-code 1 rejected-invalid
    oracle_diagnostic fixture.tl:3:1
    oracle_expect exact-location 1 rejected-invalid fixture.tl:3:1
    oracle_expect wrong-operation-location 1 wrong-diagnostic fixture.tl:4:1
    oracle_expect accepted 0 accepted-invalid
    oracle_expect diagnostic-then-segv 139 compiler-crash
    oracle_expect diagnostic-then-abort 134 compiler-crash
    oracle_expect timed-out 124 infrastructure-resource-failure
    oracle_expect killed 137 infrastructure-resource-failure
    oracle_expect not-executed 127 infrastructure-resource-failure
    oracle_expect unsupported-exit 2 infrastructure-resource-failure
    printf 'Segmentation fault\n' >> "$oracle_err"
    oracle_expect crash-text-with-exit-one 1 malformed-output
    oracle_diagnostic fixture.tl:3:1
    printf 'Type checking passed!\n' > "$oracle_out"
    oracle_expect contradictory-success 1 malformed-output
    : > "$oracle_out"
    oracle_diagnostic unrelated.tl:3:1
    oracle_expect wrong-source 1 wrong-diagnostic
    printf '  --> fixture.tl:3:1\n' >> "$oracle_err"
    oracle_expect secondary-is-not-primary 1 wrong-diagnostic
    oracle_diagnostic fixture.tl:0:0
    oracle_expect unlocated 1 malformed-output
    printf 'error[E0214]: intended move\n' > "$oracle_err"
    oracle_expect truncated 1 malformed-output
    printf 'error[E0100]: parse error\n  --> fixture.tl:3:1\n 3 | intended move\n' > "$oracle_err"
    oracle_expect source-echo-is-not-diagnostic 1 wrong-diagnostic
    printf 'error[E0100]: unrelated error\n  --> intended move.tl:3:1\n' > "$oracle_err"
    oracle_expect location-is-not-diagnostic 1 wrong-diagnostic 'intended move.tl'
    printf 'error[E0100]: unrelated error\n  --> fixture.tl:3:1\n  --> fixture.tl:9:2\n   |\n   = label: declared here\n' > "$oracle_err"
    oracle_expect_needle related-location 1 rejected-invalid fixture.tl:9:2
    oracle_expect_needle primary-location-is-not-diagnostic 1 wrong-diagnostic fixture.tl:3:1
    printf 'error[E0100]: one\n  --> fixture.tl:3:1\nerror[E0100]: two\n  --> other.tl:1:1\n  --> fixture.tl:9:2\n' > "$oracle_err"
    oracle_expect_needle related-location-other-diagnostic 1 wrong-diagnostic fixture.tl:9:2
    printf 'error[E0100]: parse error\n  --> fixture.tl:3:1\nerror[E0214]: intended move\n  --> other.tl:1:1\n' > "$oracle_err"
    oracle_expect mismatched-diagnostic-blocks 1 wrong-diagnostic
    printf 'error[E0200]: intended move\n  --> fixture.tl:3:1\n' > "$oracle_err"
    oracle_expect generic-taxonomy 1 wrong-diagnostic
    printf 'error[E0214]: intended move __tl_tc_transport\n  --> fixture.tl:3:1\n' > "$oracle_err"
    oracle_expect undecoded-transport 1 wrong-diagnostic
    : > "$oracle_err"
    oracle_expect empty 1 wrong-diagnostic
    oracle_diagnostic /absolute/root/fixture.tl:3:1
    oracle_expect absolute-path 1 rejected-invalid
    oracle_diagnostic 'C:\root\fixture.tl:3:1'
    oracle_expect windows-path 1 rejected-invalid
    # Exercise the actual subprocess status/stream capture as well as planted
    # observations. Disable core dumps for the deliberately aborted child.
    run_case "$oracle_out" "$oracle_err" sh -c '
        ulimit -c 0
        printf "error[E0214]: intended move\n  --> fixture.tl:3:1\n" >&2
        kill -ABRT $$
    ' 2> "$WORKDIR/oracle-subprocess-driver.err"
    oracle_expect subprocess-diagnostic-then-abort "$code" compiler-crash
    # Every converted production-source row retains its exact primary span.
    # Plant the expected diagnostic, then alter only its line or column.
    while IFS='|' read -r anchor_id anchor_mode anchor_source anchor_location anchor_needle; do
        case "$anchor_location" in @loc\{*) ;; *) continue ;; esac
        anchor_expected=$(resolve_source_locations "$anchor_location") || fail "$anchor_id invalid source anchor"
        anchor_column=${anchor_expected##*:}
        anchor_prefix=${anchor_expected%:*}
        anchor_line=${anchor_prefix##*:}
        anchor_path=${anchor_prefix%:*}
        for anchor_mutation in correct wrong-line wrong-column; do
            anchor_actual=$anchor_expected
            case "$anchor_mutation" in
                wrong-line) anchor_actual=$anchor_path:$((anchor_line + 1)):$anchor_column ;;
                wrong-column) anchor_actual=$anchor_path:$anchor_line:$((anchor_column + 1)) ;;
            esac
            printf 'error[E0206]: %s\n  --> %s\n' "$anchor_needle" "$anchor_actual" > "$oracle_err"
            anchor_want=wrong-diagnostic
            [ "$anchor_mutation" != correct ] || anchor_want=rejected-invalid
            oracle_probe "${anchor_id}_${anchor_mutation}" 1 "$anchor_want" "$anchor_expected" "$anchor_needle"
        done
    done < "$NORMALIZED_MANIFEST"
    echo "safety rejection oracle passed $oracle_count mutation/control cases"
}

# Verify CRLF-safe line-count framing and fail-closed batch mutations.
batch_framing_self_test() {
    bf_dir="$WORKDIR/batch-framing-self-test"
    mkdir -p "$bf_dir"
    bf_meta="$bf_dir/meta"
    bf_out="$bf_dir/out"
    bf_err="$bf_dir/err"
    bf_rej="$bf_dir/rej"
    : > "$bf_err"

    # Control: mixed check-ok + check-fail with CRLF line endings and a spoofed
    # header inside echoed source code (must be consumed as payload, not header).
    printf '1|ok_case|check-ok|ok.tl|ok.tl|-\n2|fail_case|check-fail|fail.tl|fail.tl:3:1|intended move\n' > "$bf_meta"
    printf 'CHECK_BATCH_ENTRY|0|0|1|0|ok.tl\r\nType checking passed!\r\nCHECK_BATCH_ENTRY|1|1|0|4|fail.tl\r\nerror[E0214]: intended move\r\n  --> C:\\repo\\fail.tl:3:1\r\n 3 | CHECK_BATCH_ENTRY|0|0|0|0|spoof.tl\r\n   | ^\r\nCHECK_BATCH_END|2\r\n' > "$bf_out"
    classify_check_batch_stream "$bf_meta" "$bf_out" "$bf_err" 0 host "$bf_rej" "self-test-crlf" ||
        fail "batch framing self-test rejected valid CRLF framed stream"
    grep -Fq 'fail_case	1	rejected-invalid' "$bf_rej" ||
        fail "batch framing self-test did not record rejection row"

    # Mutation 1: missing CHECK_BATCH_END sentinel must fail.
    sed '$d' "$bf_out" > "$bf_dir/missing-end.out"
    if classify_check_batch_stream "$bf_meta" "$bf_dir/missing-end.out" "$bf_err" 0 host "$bf_rej" "self-test-missing-end" 2>/dev/null; then
        fail "batch framing self-test accepted stream without CHECK_BATCH_END"
    fi

    # Mutation 2: non-empty batch stderr must fail.
    printf 'unexpected noise\n' > "$bf_dir/noisy.err"
    if classify_check_batch_stream "$bf_meta" "$bf_out" "$bf_dir/noisy.err" 0 host "$bf_rej" "self-test-stderr" 2>/dev/null; then
        fail "batch framing self-test accepted non-empty batch stderr"
    fi

    # Mutation 3: compiler crash exit status must fail even if stream looks valid.
    if classify_check_batch_stream "$bf_meta" "$bf_out" "$bf_err" 139 host "$bf_rej" "self-test-crash" 2>/dev/null; then
        fail "batch framing self-test accepted crashed batch process"
    fi

    # Mutation 4: check-fail with contradictory stdout must fail.
    printf 'CHECK_BATCH_ENTRY|0|0|1|0|ok.tl\r\nType checking passed!\r\nCHECK_BATCH_ENTRY|1|1|1|2|fail.tl\r\nType checking passed!\r\nerror[E0214]: intended move\r\n  --> fail.tl:3:1\r\nCHECK_BATCH_END|2\r\n' > "$bf_dir/contradictory.out"
    if classify_check_batch_stream "$bf_meta" "$bf_dir/contradictory.out" "$bf_err" 0 host "$bf_rej" "self-test-contradictory" 2>/dev/null; then
        fail "batch framing self-test accepted check-fail with stdout"
    fi

    # Mutation 5: a valid file with a framed doctest advisory keeps batch stderr
    # empty and attributes the warning to that specific entry.
    printf '1|ok_doctest|check-ok|ok_doctest.tl|ok_doctest.tl|-\n' > "$bf_dir/adv.meta"
    printf 'CHECK_BATCH_ENTRY|0|0|1|2|ok_doctest.tl\nType checking passed!\nwarning: unnecessary unsafe block\n  --> ok_doctest.tl.doctest.0:1:22\nCHECK_BATCH_END|1\n' > "$bf_dir/adv.out"
    if classify_check_batch_stream "$bf_dir/adv.meta" "$bf_dir/adv.out" "$bf_err" 0 host "$bf_rej" "self-test-doctest-advisory" 2> "$bf_dir/adv.diag"; then
        fail "batch framing self-test accepted check-ok entry with framed advisory stderr"
    fi
    grep -Fq 'ok_doctest expected empty check stderr' "$bf_dir/adv.diag" ||
        fail "batch framing self-test did not attribute framed doctest advisory to ok_doctest"
    grep -Fq 'warning: unnecessary unsafe block' "$bf_dir/adv.diag" ||
        fail "batch framing self-test did not preserve framed doctest advisory text"

    echo "safety batch framing self-test passed (CRLF + 5 mutations)"
}

count_and_validate_manifest() {
    awk -F '|' '
        !/^#/ && NF {
            if (NF != 5 || $1 == "" || seen[$1]++) invalid = 1
            count++
        }
        END { if (invalid) exit 1; print count + 0 }
    ' "$1"
}

# Verify fragment-directory loading fails closed on missing/empty/stray/nested/
# invalid/symlink entries, preserves LC_ALL=C order and LF normalization, and
# rejects cross-fragment duplicate IDs or malformed rows.
manifest_dir_self_test() {
    md_dir="$WORKDIR/manifest-dir-self-test"
    mkdir -p "$md_dir"
    md_out="$md_dir/out.manifest"
    md_err="$md_dir/err.txt"

    expect_md_fail() {
        _md_label=$1
        _md_target=$2
        _md_expected=$3
        if manifest_concat_dir "$_md_target" > "$md_out" 2> "$md_err"; then
            fail "manifest-dir self-test unexpectedly passed: $_md_label"
        fi
        if [ -s "$md_out" ]; then
            fail "manifest-dir self-test emitted stdout on failure: $_md_label"
        fi
        assert_contains "$md_err" "$_md_expected" ||
            fail "manifest-dir self-test wrong diagnostic for $_md_label"
    }

    expect_md_fail missing-dir "$md_dir/does-not-exist" "manifest directory does not exist"

    mkdir -p "$md_dir/empty.d"
    expect_md_fail empty-dir "$md_dir/empty.d" "manifest directory is empty"

    mkdir -p "$md_dir/stray.d"
    printf 'ok_a|check-ok|fixture_a.tl|-|-\n' > "$md_dir/stray.d/a.manifest"
    printf 'stray\n' > "$md_dir/stray.d/README.txt"
    expect_md_fail stray-file "$md_dir/stray.d" "unexpected non-.manifest entry"

    mkdir -p "$md_dir/nested.d/sub"
    printf 'ok_a|check-ok|fixture_a.tl|-|-\n' > "$md_dir/nested.d/a.manifest"
    printf 'ok_b|check-ok|fixture_b.tl|-|-\n' > "$md_dir/nested.d/sub/b.manifest"
    expect_md_fail nested-dir "$md_dir/nested.d" "unexpected non-.manifest entry"

    mkdir -p "$md_dir/dot.d"
    printf 'ok_a|check-ok|fixture_a.tl|-|-\n' > "$md_dir/dot.d/.manifest"
    expect_md_fail dot-manifest "$md_dir/dot.d" "invalid manifest filename"

    if [ "$HOST_OS" = linux ]; then
        mkdir -p "$md_dir/symlink.d"
        ln -s "$md_dir/stray.d/a.manifest" "$md_dir/symlink.d/link.manifest"
        expect_md_fail symlink-entry "$md_dir/symlink.d" "non-regular entry"
    fi

    # Ordered concatenation, CRLF stripping, and missing trailing newline safety.
    mkdir -p "$md_dir/ordered.d"
    printf 'second|check-ok|fixture_b.tl|-|-\r\n' > "$md_dir/ordered.d/b.manifest"
    printf 'first|check-ok|fixture_a.tl|-|-' > "$md_dir/ordered.d/a.manifest"
    manifest_concat_dir "$md_dir/ordered.d" > "$md_dir/ordered.combined"
    printf 'first|check-ok|fixture_a.tl|-|-\nsecond|check-ok|fixture_b.tl|-|-\n' > "$md_dir/ordered.expected"
    cmp "$md_dir/ordered.combined" "$md_dir/ordered.expected" ||
        fail "manifest-dir self-test ordering or LF normalization mismatch"
    md_count=$(count_and_validate_manifest "$md_dir/ordered.combined") ||
        fail "manifest-dir self-test rejected valid combined fragments"
    [ "$md_count" -eq 2 ] || fail "manifest-dir self-test counted $md_count of 2 rows"

    # Cross-fragment duplicate IDs must fail validation.
    mkdir -p "$md_dir/dup.d"
    printf 'dup_id|check-ok|fixture_a.tl|-|-\n' > "$md_dir/dup.d/a.manifest"
    printf 'dup_id|check-ok|fixture_b.tl|-|-\n' > "$md_dir/dup.d/b.manifest"
    manifest_concat_dir "$md_dir/dup.d" > "$md_dir/dup.combined"
    if count_and_validate_manifest "$md_dir/dup.combined" >/dev/null; then
        fail "manifest-dir self-test accepted cross-fragment duplicate case ID"
    fi

    # Malformed field count must fail validation.
    mkdir -p "$md_dir/bad-nf.d"
    printf 'bad_row|check-ok|fixture_a.tl|-\n' > "$md_dir/bad-nf.d/a.manifest"
    manifest_concat_dir "$md_dir/bad-nf.d" > "$md_dir/bad-nf.combined"
    if count_and_validate_manifest "$md_dir/bad-nf.combined" >/dev/null; then
        fail "manifest-dir self-test accepted row with NF != 5"
    fi

    # Validate the live safety manifest directory rows as well.
    md_live_count=$(count_and_validate_manifest "$NORMALIZED_MANIFEST") ||
        fail "manifest-dir self-test found malformed or duplicate row in $MANIFEST"
    [ "$md_live_count" -gt 0 ] || fail "manifest-dir self-test found 0 rows in $MANIFEST"
    echo "safety manifest directory self-test passed ($md_live_count live rows)"
}

# Plan all manifest cases into parallel pool jobs:
#   - check-depth-NN: the 3 slow depth-255..257 fixtures, queued first so they
#     never tail-straggle
#   - run-compile-NN -> run-exec-NN: compile --batch + assemble/link/exec chunks
#   - check-win-src-01 / check-win-emb-01: Windows-target source & embedded routes
#   - check-host-NN: remaining check-ok / check-fail chunks
plan_safety_pool() {
    JOBS_DIR="$WORKDIR/jobs"
    RUN_DIR="$WORKDIR/run"
    mkdir -p "$JOBS_DIR" "$RUN_DIR" "$WORKDIR_ABS/embedded-stdlib-cwd"
    POOL_QUEUE="$JOBS_DIR/pool.queue"
    : > "$POOL_QUEUE"

    # Pass 1: validate every manifest row, resolve any @loc{...} anchors, verify
    # source files exist, and emit one resolved manifest for deterministic chunking.
    RESOLVED_MANIFEST="$WORKDIR/manifest.resolved"
    : > "$RESOLVED_MANIFEST"
    row_order=0
    while IFS='|' read -r case_id mode source expected_code stderr_contains || [ -n "$case_id" ]; do
        case "$case_id" in
            "" | \#*) continue ;;
        esac
        [ -n "$mode" ] || fail "$case_id missing mode"
        [ -n "$source" ] || fail "$case_id missing source"
        [ -f "$source" ] || fail "$case_id source does not exist: $source"
        case "$mode" in
            check-ok | check-ok-windows)
                diagnostic_source=$source
                ;;
            check-fail)
                [ -n "$stderr_contains" ] && [ "$stderr_contains" != "-" ] ||
                    fail "$case_id check-fail missing stderr expectation"
                diagnostic_source=$source
                if [ "$expected_code" != "-" ]; then
                    diagnostic_source=$expected_code
                    case "$diagnostic_source" in
                        *'@loc{'*)
                            diagnostic_source=$(resolve_source_locations "$diagnostic_source") ||
                                fail "$case_id invalid diagnostic location"
                            ;;
                    esac
                fi
                ;;
            check-fail-windows)
                [ -n "$stderr_contains" ] && [ "$stderr_contains" != "-" ] ||
                    fail "$case_id check-fail-windows missing stderr expectation"
                diagnostic_source=$source
                ;;
            run-exit)
                diagnostic_source=$expected_code
                ;;
            run-trap)
                [ -n "$stderr_contains" ] && [ "$stderr_contains" != "-" ] ||
                    fail "$case_id run-trap missing stderr expectation"
                diagnostic_source=$expected_code
                ;;
            *)
                fail "$case_id has unknown safety corpus mode: $mode"
                ;;
        esac
        row_order=$((row_order + 1))
        printf '%s|%s|%s|%s|%s|%s\n' \
            "$row_order" "$case_id" "$mode" "$source" "$diagnostic_source" "$stderr_contains" \
            >> "$RESOLVED_MANIFEST"
    done < "$NORMALIZED_MANIFEST"

    ROOT_HOST=$(host_path "$ROOT")
    RUN_DIR_HOST=$(host_path "$WORKDIR_ABS/run")

    awk -F '|' \
        -v jobs_dir="$JOBS_DIR" \
        -v root_host="$ROOT_HOST" \
        -v run_dir_host="$RUN_DIR_HOST" \
        -v check_chunk_size="$SAFETY_CHECK_CHUNK_SIZE" \
        -v run_chunk_size="$SAFETY_RUN_CHUNK_SIZE" \
        -v cap="$SAFETY_JOB_CAP_MIB" \
        -v queue="$POOL_QUEUE" '
        function safe_name(s,    out) {
            out = s
            gsub(/[/\\:]/, "_", out)
            return out
        }
        function emit_job(name, needs) {
            if (needs == "") needs = "-"
            print name "|" cap "|" needs >> queue
        }
        {
            order = $1
            cid = $2
            mode = $3
            src = $4
            diag = $5
            needle = $6
            if (mode == "check-ok" || mode == "check-fail") {
                if (cid == "region_type_depth_255_loan_reject" ||
                    cid == "lifetime_shape_depth_256_check" ||
                    cid == "lifetime_shape_depth_257_reject") {
                    depth_n++
                    depth_rows[depth_n] = $0
                    depth_srcs[depth_n] = src
                } else {
                    host_n++
                    host_rows[host_n] = $0
                    host_srcs[host_n] = src
                }
            } else if (mode == "check-ok-windows" || mode == "check-fail-windows") {
                win_n++
                win_rows[win_n] = $0
                win_srcs[win_n] = src
            } else if (mode == "run-exit" || mode == "run-trap") {
                run_n++
                run_rows[run_n] = $0
                run_ids[run_n] = cid
                run_modes[run_n] = mode
                run_srcs[run_n] = src
                run_codes[run_n] = diag
                run_needles[run_n] = needle
            }
        }
        END {
            # 1. Slow depth-255..257 fixtures first (one per job).
            for (i = 1; i <= depth_n; i++) {
                job = sprintf("check-depth-%02d", i)
                print depth_rows[i] > (jobs_dir "/" job ".meta")
                print depth_srcs[i] > (jobs_dir "/" job ".list")
                close(jobs_dir "/" job ".meta")
                close(jobs_dir "/" job ".list")
                emit_job(job, "-")
            }

            # 2. Run compile --batch + assemble/link/exec chunks.
            run_chunks = int((run_n + run_chunk_size - 1) / run_chunk_size)
            for (c = 1; c <= run_chunks; c++) {
                cjob = sprintf("run-compile-%02d", c)
                ejob = sprintf("run-exec-%02d", c)
                start = (c - 1) * run_chunk_size + 1
                end = c * run_chunk_size
                if (end > run_n) end = run_n
                for (i = start; i <= end; i++) {
                    sname = safe_name(run_ids[i])
                    print run_srcs[i] "|" run_dir_host "/" sname ".s" > (jobs_dir "/" cjob ".list")
                    print run_ids[i] "|" run_modes[i] "|" sname "|" run_codes[i] "|" run_needles[i] > (jobs_dir "/" ejob ".meta")
                }
                close(jobs_dir "/" cjob ".list")
                close(jobs_dir "/" ejob ".meta")
                emit_job(cjob, "-")
                emit_job(ejob, cjob)
            }

            # 3. Windows-target source and embedded stdlib check batches.
            if (win_n > 0) {
                sjob = "check-win-src-01"
                ejob = "check-win-emb-01"
                for (i = 1; i <= win_n; i++) {
                    print win_rows[i] > (jobs_dir "/" sjob ".meta")
                    print win_srcs[i] > (jobs_dir "/" sjob ".list")
                    print win_rows[i] > (jobs_dir "/" ejob ".meta")
                    print root_host "/" win_srcs[i] > (jobs_dir "/" ejob ".list")
                }
                close(jobs_dir "/" sjob ".meta")
                close(jobs_dir "/" sjob ".list")
                close(jobs_dir "/" ejob ".meta")
                close(jobs_dir "/" ejob ".list")
                emit_job(sjob, "-")
                emit_job(ejob, "-")
            }

            # 4. Remaining host check-ok / check-fail chunks.
            host_chunks = int((host_n + check_chunk_size - 1) / check_chunk_size)
            for (c = 1; c <= host_chunks; c++) {
                job = sprintf("check-host-%02d", c)
                start = (c - 1) * check_chunk_size + 1
                end = c * check_chunk_size
                if (end > host_n) end = host_n
                for (i = start; i <= end; i++) {
                    print host_rows[i] > (jobs_dir "/" job ".meta")
                    print host_srcs[i] > (jobs_dir "/" job ".list")
                }
                close(jobs_dir "/" job ".meta")
                close(jobs_dir "/" job ".list")
                emit_job(job, "-")
            }

            printf "%d|%d|%d\n", depth_n + host_n, win_n, run_n > (jobs_dir "/plan.counts")
            close(jobs_dir "/plan.counts")
        }
    ' "$RESOLVED_MANIFEST"
}

run_check_batch_job() {
    _job=$1
    _route=$2
    _list="$WORKDIR_ABS/jobs/$_job.list"
    _meta="$JOBS_DIR/$_job.meta"
    _out="$JOBS_DIR/$_job.stdout"
    _err="$JOBS_DIR/$_job.stderr"
    _rej="$JOBS_DIR/$_job.rejections.tsv"
    _list_host=$(host_path "$_list")
    _rc=0
    set +e
    case "$_route" in
        host)
            "$COMPILER" check --batch "$_list_host" \
                --stdlib-root "$ROOT/stdlib" \
                --stdlib-root "$ROOT/src" \
                --stdlib-root "$ROOT/tests/integration" \
                < /dev/null > "$_out" 2> "$_err"
            _rc=$?
            ;;
        source)
            "$COMPILER" check --batch "$_list_host" \
                --target windows-x86_64 \
                --stdlib-root "$ROOT/stdlib" \
                --stdlib-root "$ROOT/src" \
                --stdlib-root "$ROOT/tests/integration" \
                < /dev/null > "$_out" 2> "$_err"
            _rc=$?
            ;;
        embedded)
            (
                cd "$WORKDIR_ABS/embedded-stdlib-cwd" &&
                exec "$COMPILER" check --batch "$_list_host" \
                    --target windows-x86_64
            ) < /dev/null > "$_out" 2> "$_err"
            _rc=$?
            ;;
        *)
            echo "FAIL: unknown check batch route: $_route" >&2
            return 1
            ;;
    esac
    set -e
    classify_check_batch_stream "$_meta" "$_out" "$_err" "$_rc" "$_route" "$_rej" "$_job" || return 1
    _count=$(wc -l < "$_meta" | tr -d ' ')
    printf '%s\n' "$_count" > "$JOBS_DIR/$_job.checked"
}

run_compile_batch_job() {
    _job=$1
    _list="$JOBS_DIR/$_job.list"
    _out="$JOBS_DIR/$_job.stdout"
    _err="$JOBS_DIR/$_job.stderr"
    _list_host=$(host_path "$_list")
    set +e
    # shellcheck disable=SC2086
    "$COMPILER" compile --batch "$_list_host" \
        --target "$BUILD_TARGET" \
        $TARGET_CFG_ARGS \
        --stdlib-root "$ROOT/stdlib" \
        --stdlib-root "$ROOT/src" \
        --stdlib-root "$ROOT/tests/integration" \
        --stdlib-root "$ROOT/tests/safety" \
        < /dev/null > "$_out" 2> "$_err"
    _rc=$?
    set -e
    if [ "$_rc" -ne 0 ]; then
        show_stream_if_nonempty stdout "$_out"
        show_stream_if_nonempty stderr "$_err"
        echo "FAIL: $_job compile --batch failed with exit $_rc" >&2
        return 1
    fi
}

run_exec_chunk_job() {
    _job=$1
    _meta="$JOBS_DIR/$_job.meta"
    _done=0
    while IFS='|' read -r case_id _mode _sname _expected_code _stderr_contains || [ -n "$case_id" ]; do
        [ -n "$case_id" ] || continue
        asm="$RUN_DIR/$_sname.s"
        build_out="$RUN_DIR/$_sname.build.out"
        build_err="$RUN_DIR/$_sname.build.err"
        _out="$RUN_DIR/$_sname.out"
        _err="$RUN_DIR/$_sname.err"
        : > "$build_out"
        : > "$build_err"
        if [ "$HOST_OS" = windows ]; then
            obj="$RUN_DIR/$_sname.obj"
            program="$RUN_DIR/$_sname.exe"
            assemble_link_windows "$asm" "$obj" "$program" "$case_id" "$build_out" "$build_err"
        else
            obj="$RUN_DIR/$_sname.o"
            program="$RUN_DIR/$_sname"
            if ! as "$asm" -o "$obj" < /dev/null >> "$build_out" 2>> "$build_err"; then
                show_stream_if_nonempty stdout "$build_out"
                show_stream_if_nonempty stderr "$build_err"
                fail "$case_id assemble failed"
            fi
            entry=$(linux_entry_symbol_for_asm "$asm") || return $?
            stdlib_archive=$(linux_stdlib_archive_for_asm "$asm" "${COMPILER:-}")
            stdlib_link_args=""
            if [ -n "$stdlib_archive" ]; then
                stdlib_link_args="-z noexecstack --gc-sections --start-group $stdlib_archive --end-group"
            fi
            # shellcheck disable=SC2086
            if ! ld "$obj" -o "$program" -static $stdlib_link_args -e "$entry" \
                < /dev/null >> "$build_out" 2>> "$build_err"; then
                show_stream_if_nonempty stdout "$build_out"
                show_stream_if_nonempty stderr "$build_err"
                fail "$case_id link failed"
            fi
        fi
        run_case "$_out" "$_err" "$program"
        case "$_mode" in
            run-exit)
                if [ "$code" -ne "$_expected_code" ]; then
                    show_stream_if_nonempty stdout "$_out"
                    show_stream_if_nonempty stderr "$_err"
                    fail "$case_id expected run exit $_expected_code, got $code"
                fi
                assert_empty "$_err" || fail "$case_id expected empty stderr"
                ;;
            run-trap)
                if [ "$code" -ne "$_expected_code" ]; then
                    show_stream_if_nonempty stdout "$_out"
                    show_stream_if_nonempty stderr "$_err"
                    fail "$case_id expected trap exit $_expected_code, got $code"
                fi
                assert_contains "$_err" "$_stderr_contains" ||
                    fail "$case_id trap stderr did not match expectation"
                ;;
            *)
                fail "$case_id unexpected mode in run-exec chunk: $_mode"
                ;;
        esac
        _done=$((_done + 1))
    done < "$_meta"
    printf '%s\n' "$_done" > "$JOBS_DIR/$_job.checked"
}

bounded_pool_run_job() {
    _bp_job=$1
    case "$_bp_job" in
        check-depth-* | check-host-*)
            run_check_batch_job "$_bp_job" host
            ;;
        check-win-src-*)
            run_check_batch_job "$_bp_job" source
            ;;
        check-win-emb-*)
            run_check_batch_job "$_bp_job" embedded
            ;;
        run-compile-*)
            run_compile_batch_job "$_bp_job"
            ;;
        run-exec-*)
            run_exec_chunk_job "$_bp_job"
            ;;
        *)
            echo "FAIL: unknown safety pool job: $_bp_job" >&2
            return 1
            ;;
    esac
}

source_location_self_test "$WORKDIR/source-location-self-test"
rejection_oracle_self_test
batch_framing_self_test
manifest_dir_self_test
if [ "$SELF_TEST_ONLY" = true ]; then
    exit 0
fi
prepare_tools
# wide_struct_literal_reject imports the generated wide-struct declarations.
awk -f tests/integration/wide_struct_literal_decls.awk > "$WORKDIR/wide_struct_literal_decls.tl"
mv "$WORKDIR/wide_struct_literal_decls.tl" tests/integration/wide_struct_literal_decls.tl
expected_cases=$(count_and_validate_manifest "$NORMALIZED_MANIFEST") || fail "infrastructure-resource-failure: malformed or duplicate manifest row"
[ "$expected_cases" -gt 0 ] || fail "infrastructure-resource-failure: manifest contains no cases"

# A local scripts/ci-affected.sh --run whose change is only tests/safety/*.tl
# fixtures runs the cases whose source is, or names, a changed fixture
# (scripts/lib-ci-local.sh). Any other change keeps the whole manifest.
. "$ROOT/scripts/lib-ci-local.sh"
if ci_local_scope_active &&
    ! grep -v -E '^tests/safety/[^/]+[.]tl$' "$TYPELISP_CI_LOCAL_SCOPE_PATHS" > /dev/null; then
    awk -F '|' '!/^#/ && NF { print $3 }' "$NORMALIZED_MANIFEST" | LC_ALL=C sort -u > "$WORKDIR/scope.sources"
    ci_local_scope_filter "$WORKDIR/scope.sources" "$WORKDIR/scope.selected"
    awk -F '|' 'NR == FNR { keep[$0] = 1; next } /^#/ || !NF || ($3 in keep)' \
        "$WORKDIR/scope.selected" "$NORMALIZED_MANIFEST" > "$WORKDIR/manifest.scoped"
    mv "$WORKDIR/manifest.scoped" "$NORMALIZED_MANIFEST"
    scoped_cases=$(count_and_validate_manifest "$NORMALIZED_MANIFEST") ||
        fail "infrastructure-resource-failure: malformed scoped manifest"
    echo "[safety-corpus] local changed-file scope: $scoped_cases of $expected_cases case(s); hosted CI runs the whole manifest"
    expected_cases=$scoped_cases
    if [ "$expected_cases" -eq 0 ]; then
        echo "safety corpus verification passed: the local change touches no safety case"
        exit 0
    fi
fi

plan_safety_pool
POOL_DIR="$WORKDIR/pool"
bounded_pool_init "$POOL_DIR" "$SAFETY_POOL_BUDGET_MIB" "$POOL_QUEUE" ||
    fail "infrastructure-resource-failure: failed to initialize safety worker pool"
job_count=$(wc -l < "$POOL_QUEUE" | tr -d ' ')
echo "[safety-corpus] pool: $job_count job(s), $SAFETY_WORKERS worker(s), $expected_cases case(s)"
bounded_pool_start "$POOL_DIR" "$SAFETY_WORKERS" ||
    fail "infrastructure-resource-failure: failed to start safety worker pool"
bounded_pool_join "$POOL_DIR" ||
    fail "safety corpus worker pool failed"

# Merge deterministic manifest-ordered rejections.tsv from all check chunks.
: > "$WORKDIR/rejections.tsv"
if ls "$JOBS_DIR"/*.rejections.tsv >/dev/null 2>&1; then
    cat "$JOBS_DIR"/*.rejections.tsv | LC_ALL=C sort -n -k1,1 | cut -f2- > "$WORKDIR/rejections.tsv"
fi

# Verify exact accounting across host checks, Windows-target source+embedded routes, and runs.
checked=0
win_src_checked=0
win_emb_checked=0
while IFS='|' read -r _qjob _qcap _qneeds; do
    case "$_qjob" in
        check-depth-* | check-host-* | run-exec-*)
            [ -s "$JOBS_DIR/$_qjob.checked" ] || fail "infrastructure-resource-failure: missing count for $_qjob"
            checked=$((checked + $(cat "$JOBS_DIR/$_qjob.checked")))
            ;;
        check-win-src-*)
            [ -s "$JOBS_DIR/$_qjob.checked" ] || fail "infrastructure-resource-failure: missing count for $_qjob"
            _n=$(cat "$JOBS_DIR/$_qjob.checked")
            win_src_checked=$((win_src_checked + _n))
            checked=$((checked + _n))
            ;;
        check-win-emb-*)
            [ -s "$JOBS_DIR/$_qjob.checked" ] || fail "infrastructure-resource-failure: missing count for $_qjob"
            win_emb_checked=$((win_emb_checked + $(cat "$JOBS_DIR/$_qjob.checked")))
            ;;
    esac
done < "$POOL_QUEUE"

[ "$win_src_checked" -eq "$win_emb_checked" ] ||
    fail "infrastructure-resource-failure: Windows source/embedded route count mismatch ($win_src_checked vs $win_emb_checked)"
[ "$checked" -eq "$expected_cases" ] ||
    fail "infrastructure-resource-failure: executed $checked of $expected_cases cases"

echo "safety corpus verification passed for $checked case(s)"
