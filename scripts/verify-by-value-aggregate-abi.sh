#!/usr/bin/env sh
set -eu

# verify-by-value-aggregate-abi.sh - pin the internal Tuple/Array ABI shapes.
#
# This gate deliberately compiles at opt0.  Optimisation can remove the small
# fixture helpers whose physical parameter/return boundaries are under test.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

command -v as >/dev/null 2>&1 || {
    echo "missing GNU assembler: as" >&2
    exit 1
}

TMP_ROOT=${TMPDIR:-/tmp}
WORKDIR=$(mktemp -d "$TMP_ROOT/typelisp-by-value-aggregate-abi.XXXXXX")
trap 'rm -rf "$WORKDIR"' EXIT HUP INT TERM

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

count_matches() {
    _file=$1
    _regex=$2
    grep -E "$_regex" "$_file" 2>/dev/null | wc -l | tr -d '[:space:]'
}

assert_matches() {
    _file=$1
    _regex=$2
    _label=$3
    if ! grep -E "$_regex" "$_file" >/dev/null 2>&1; then
        fail "$_label missing regex: $_regex"
    fi
}

assert_not_matches() {
    _file=$1
    _regex=$2
    _label=$3
    if grep -E "$_regex" "$_file" >/dev/null 2>&1; then
        fail "$_label contained forbidden regex: $_regex"
    fi
}

assert_count_eq() {
    _file=$1
    _regex=$2
    _want=$3
    _label=$4
    _got=$(count_matches "$_file" "$_regex")
    if [ "$_got" -ne "$_want" ]; then
        fail "$_label expected $_want match(es) for /$_regex/, got $_got"
    fi
}

# Require one correlated 24-byte shallow copy. Counting an offset-16 load by
# itself is not stable: an unrelated stack home can legitimately land at
# 16(%rsp). Tie the vector and final-word instructions to the same source and
# destination bases instead.
assert_copy24_sequence_once() {
    _file=$1
    _label=$2
    _got=$(awk '
        function bare_reg(text) {
            gsub(/[,()]/, "", text)
            return text
        }
        function offset_base(text) {
            text = bare_reg(text)
            sub(/^16/, "", text)
            return text
        }
        $1 == "movups" && $2 ~ /^\(%r[a-z0-9]+\),$/ && $3 ~ /^%xmm[0-9]+$/ {
            source = bare_reg($2)
            vector = $3
            state = 1
            next
        }
        state == 1 && $1 == "movups" && $2 ~ /^%xmm[0-9]+,$/ && $3 ~ /^\(%r[a-z0-9]+\)$/ {
            if (bare_reg($2) == vector) {
                destination = bare_reg($3)
                state = 2
                next
            }
            state = 0
        }
        state == 2 && $1 == "movq" && $2 ~ /^16\(%r[a-z0-9]+\),$/ && $3 ~ /^%r[a-z0-9]+$/ {
            if (offset_base($2) == source) {
                word = $3
                state = 3
                next
            }
            state = 0
        }
        state == 3 && $1 == "movq" && $2 ~ /^%r[a-z0-9]+,$/ && $3 ~ /^16\(%r[a-z0-9]+\)$/ {
            if (bare_reg($2) == word && offset_base($3) == destination) {
                copies++
            }
            state = 0
        }
        END { print copies + 0 }
    ' "$_file")
    if [ "$_got" -ne 1 ]; then
        fail "$_label expected one correlated 24-byte copy, got $_got"
    fi
}

compile_target() {
    _target=$1
    _suffix=$2
    _asm="$WORKDIR/by_value_aggregate_abi.$_suffix.s"
    _stdout="$WORKDIR/by_value_aggregate_abi.$_suffix.stdout"
    _stderr="$WORKDIR/by_value_aggregate_abi.$_suffix.stderr"
    echo "[by-value-aggregate-abi] compile $_target (opt0)" >&2
    if ! "$COMPILER" compile "$ROOT/tests/integration/by_value_aggregate_abi.tl" \
        --target "$_target" \
        --opt-level 0 \
        --stdlib-root "$ROOT/stdlib" \
        -o "$_asm" >"$_stdout" 2>"$_stderr"; then
        echo "compile stdout:" >&2
        sed 's/^/  /' "$_stdout" >&2 || true
        echo "compile stderr:" >&2
        sed 's/^/  /' "$_stderr" >&2 || true
        fail "$_target compile failed"
    fi
    [ -s "$_asm" ] || fail "$_target compiler emitted no assembly"
    printf '%s\n' "$_asm"
}

# Extract only one global function.  In particular, do not let a helper later
# in the file satisfy a shape assertion for the selected function.
extract_function() {
    _asm=$1
    _label=$2
    _out=$3
    if ! awk -v label="$_label:" '
        $0 == label { found = 1; print; next }
        found && $0 ~ /^[[:space:]]*\.globl[[:space:]]/ { exit 0 }
        found { print }
        END { if (!found) exit 2 }
    ' "$_asm" >"$_out"; then
        fail "missing function label $_label in $_asm"
    fi
    [ "$(wc -l <"$_out" | tr -d '[:space:]')" -gt 1 ] ||
        fail "function $_label has no body in $_asm"
}

function_body() {
    _asm=$1
    _label=$2
    _safe_label=$(printf '%s' "$_label" | tr -c 'A-Za-z0-9_' '_')
    _body="$WORKDIR/$(basename "$_asm" .s).$_safe_label.body"
    extract_function "$_asm" "$_label" "$_body"
    printf '%s\n' "$_body"
}

extract_call_arg_tail() {
    _body=$1
    _symbol=$2
    _out=$3
    if ! awk -v needle="call $_symbol" '
        {
            lines[NR] = $0
            if ($0 ~ /^[[:space:]]+movq[[:space:]]+[^,]+,[[:space:]]*%rdi$/) {
                start = NR
            }
            if (index($0, needle)) {
                if (!start) exit 2
                for (i = start; i <= NR; i++) print lines[i]
                found = 1
                exit 0
            }
        }
        END { if (!found) exit 2 }
    ' "$_body" >"$_out"; then
        fail "missing scalar argument setup for call $_symbol in $_body"
    fi
}

check_no_invalid_float_moves() {
    _asm=$1
    # A GPR source is never legal for movsd/movss/movups (or the analogous
    # packed move spellings).  Keep this whole-file check independent of the
    # selected helper bodies so a malformed instruction in any emitted global
    # cannot slip through a local assertion.
    assert_not_matches "$_asm" \
        '^[[:space:]]+mov(s[sd]|ss|ups|dqa|dqu)[[:space:]]+%r[a-z0-9]+,[[:space:]]*%xmm[0-9]+$' \
        "$(basename "$_asm") invalid GPR-to-XMM move"
}

check_linux_register_helpers() {
    _asm=$1
    _indirect=$(function_body "$_asm" _tl_by_value_aggregate_abi_abi_indirect_roundtrip)
    _mixed=$(function_body "$_asm" _tl_by_value_aggregate_abi_abi_mixed_tuple_roundtrip)

    # Tuple (i64, i64): two INTEGER eightbytes use rdi/rsi and return in
    # rax/rdx.  No floating-bank instruction may appear in this helper.
    assert_matches "$_indirect" '^[[:space:]]+movq[[:space:]]+%rdi,' linux-indirect-parameter-rdi
    assert_matches "$_indirect" '^[[:space:]]+movq[[:space:]]+%rsi,' linux-indirect-parameter-rsi
    assert_matches "$_indirect" '^[[:space:]]+movq[[:space:]]+[^,]+,[[:space:]]*%rax$' linux-indirect-return-rax
    assert_matches "$_indirect" '^[[:space:]]+movq[[:space:]]+[^,]+,[[:space:]]*%rdx$' linux-indirect-return-rdx
    assert_not_matches "$_indirect" '%xmm' linux-indirect-no-floating-bank

    # Tuple (i64, f64): INTEGER/SSE banks are independent, returning rax/xmm0.
    assert_matches "$_mixed" '^[[:space:]]+movq[[:space:]]+%rdi,' linux-mixed-parameter-rdi
    assert_matches "$_mixed" '^[[:space:]]+movsd[[:space:]]+%xmm0,' linux-mixed-parameter-xmm0
    assert_matches "$_mixed" '^[[:space:]]+movq[[:space:]]+[^,]+,[[:space:]]*%rax$' linux-mixed-return-rax
    assert_matches "$_mixed" '^[[:space:]]+movsd[[:space:]]+[^,]+,[[:space:]]*%xmm0$' linux-mixed-return-xmm0
}

check_linux_pressure_call() {
    _asm=$1
    _main=$(function_body "$_asm" main)
    _window="$WORKDIR/$(basename "$_asm" .s).pressure-call.args"
    extract_call_arg_tail "$_main" _tl_by_value_aggregate_abi_abi_pressure "$_window"

    # Five scalar arguments fill rdi/rsi/rdx/rcx/r8.  The two INTEGER
    # eightbytes of the Tuple must then roll back as a unit and use consecutive
    # stack slots 0 and 8; those paired stores prove the aggregate was not
    # split between a register and the stack.
    for _reg in rdi rsi rdx rcx r8; do
        assert_matches "$_window" \
            "^[[:space:]]+movq[[:space:]]+[^,]+,[[:space:]]*%$_reg$" \
            "linux-pressure-$_reg"
    done
    assert_matches "$_window" '^[[:space:]]+movq[[:space:]]+%r[a-z0-9]+,[[:space:]]*0\(%rsp\)$' linux-pressure-stack-word0
    assert_matches "$_window" '^[[:space:]]+movq[[:space:]]+%r[a-z0-9]+,[[:space:]]*8\(%rsp\)$' linux-pressure-stack-word8
}

check_memory_array() {
    _asm=$1
    _label=$2
    _name=$3
    _target=$4
    _body=$(function_body "$_asm" "$_label")

    case "$_target" in
        linux)
            assert_matches "$_body" '^[[:space:]]+movq[[:space:]]+%rdi,' "$_name sret-rdi"
            # The >16-byte SysV parameter is in the incoming stack area.  Do
            # not pin its incidental offset; just require a positive rsp-based
            # incoming reference in this helper.
            assert_matches "$_body" '^[[:space:]]+(leaq|movq)[[:space:]]+[1-9][0-9]*\(%rsp\)' "$_name stack-parameter"
            ;;
        windows)
            assert_matches "$_body" '^[[:space:]]+movq[[:space:]]+%rcx,' "$_name sret-rcx"
            assert_matches "$_body" '^[[:space:]]+movq[[:space:]]+%rdx,' "$_name byref-rdx"
            ;;
        *)
            fail "unknown memory-array target: $_target"
            ;;
    esac

    # The 24-byte representation is copied once, in place, after the fixture's
    # bounds check.  Register/stack home choices may vary, but the copy shape
    # and its final word are ABI invariants.
    assert_count_eq "$_body" '^[[:space:]]+movups[[:space:]]+\([^)]*\),[[:space:]]*%xmm[0-9]+$' 1 "$_name 16-byte load"
    assert_count_eq "$_body" '^[[:space:]]+movups[[:space:]]+%xmm[0-9]+,[[:space:]]*\([^)]*\)$' 1 "$_name 16-byte store"
    assert_copy24_sequence_once "$_body" "$_name copy shape"
    assert_matches "$_body" '^[[:space:]]+movq[[:space:]]+[^,]+,[[:space:]]*%rax$' "$_name return-pointer"
    assert_not_matches "$_body" '^[[:space:]]+call[[:space:]].*(clone|memcpy)' "$_name no clone/memcpy helper"
}

check_windows_small_and_indirect() {
    _asm=$1
    _array8=$(function_body "$_asm" _tl_by_value_aggregate_abi_abi_array_u8_8)
    _array16=$(function_body "$_asm" _tl_by_value_aggregate_abi_abi_array_u8_16)

    # Win64 8-byte arrays use integer value transport in rcx and rax.
    assert_matches "$_array8" '^[[:space:]]+movq[[:space:]]+%rcx,' windows-array-u8-8-parameter-rcx
    assert_matches "$_array8" '^[[:space:]]+movq[[:space:]]+[^,]+,[[:space:]]*%rax$' windows-array-u8-8-return-rax

    # Win64 16-byte arrays use caller sret rcx plus a private byref temporary
    # in rdx, and one shallow 16-byte copy.
    assert_matches "$_array16" '^[[:space:]]+movq[[:space:]]+%rcx,' windows-array-u8-16-sret-rcx
    assert_matches "$_array16" '^[[:space:]]+movq[[:space:]]+%rdx,' windows-array-u8-16-byref-rdx
    assert_count_eq "$_array16" '^[[:space:]]+movups[[:space:]]+\([^)]*\),[[:space:]]*%xmm[0-9]+$' 1 windows-array-u8-16-load
    assert_count_eq "$_array16" '^[[:space:]]+movups[[:space:]]+%xmm[0-9]+,[[:space:]]*\([^)]*\)$' 1 windows-array-u8-16-store
    assert_matches "$_array16" '^[[:space:]]+movq[[:space:]]+[^,]+,[[:space:]]*%rax$' windows-array-u8-16-return-rax
}

check_windows_three_byte() {
    _asm=$1
    _body=$(function_body "$_asm" _tl_by_value_aggregate_abi_abi_array_u8_3)

    # Three bytes are not a Win64 register return size: rcx is sret, rdx is a
    # pointer to the private caller temporary, and the body copies exactly a
    # two-byte word plus the remaining byte.
    assert_matches "$_body" '^[[:space:]]+movq[[:space:]]+%rcx,' windows-array-u8-3-sret-rcx
    assert_matches "$_body" '^[[:space:]]+movq[[:space:]]+%rdx,' windows-array-u8-3-byref-rdx
    assert_count_eq "$_body" '^[[:space:]]+movzwq[[:space:]]+\([^)]*\),[[:space:]]*%r[a-z0-9]+$' 1 windows-array-u8-3-word-load
    assert_count_eq "$_body" '^[[:space:]]+movw[[:space:]]+%r[a-z0-9]+w,[[:space:]]*\([^)]*\)$' 1 windows-array-u8-3-word-store
    assert_count_eq "$_body" '^[[:space:]]+movzbq[[:space:]]+2\(%r[a-z0-9]+\),[[:space:]]*%r[a-z0-9]+$' 1 windows-array-u8-3-byte-load
    assert_count_eq "$_body" '^[[:space:]]+movb[[:space:]]+%r[a-z0-9]+b,[[:space:]]*2\(%r[a-z0-9]+\)$' 1 windows-array-u8-3-byte-store
    assert_matches "$_body" '^[[:space:]]+movq[[:space:]]+[^,]+,[[:space:]]*%rax$' windows-array-u8-3-return-rax
}

LINUX_ASM=$(compile_target linux-x86_64 linux)
WINDOWS_ASM=$(compile_target windows-x86_64 windows)

echo "[by-value-aggregate-abi] assemble Linux output with GNU as" >&2
if ! as "$LINUX_ASM" -o "$WORKDIR/by_value_aggregate_abi.linux.o" \
    >"$WORKDIR/as.stdout" 2>"$WORKDIR/as.stderr"; then
    sed 's/^/  /' "$WORKDIR/as.stderr" >&2 || true
    fail "GNU as rejected Linux assembly"
fi

check_no_invalid_float_moves "$LINUX_ASM"
check_no_invalid_float_moves "$WINDOWS_ASM"
check_linux_register_helpers "$LINUX_ASM"
check_linux_pressure_call "$LINUX_ASM"
check_memory_array "$LINUX_ASM" \
    _tl_by_value_aggregate_abi_abi_memory_array_roundtrip linux-memory-array linux
check_memory_array "$WINDOWS_ASM" \
    _tl_by_value_aggregate_abi_abi_memory_array_roundtrip windows-memory-array windows
check_windows_small_and_indirect "$WINDOWS_ASM"
check_windows_three_byte "$WINDOWS_ASM"

echo "[by-value-aggregate-abi] PASS" >&2
