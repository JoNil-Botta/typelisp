#!/usr/bin/env sh
set -eu

# Opt-in, pinned TypeLisp/ISPC correctness and static-codegen comparison.
# ISPC is deliberately optional; its absence is represented in support.tsv.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

CORPUS="$ROOT/benchmarks/ispc"
WORKDIR=${TYPELISP_ISPC_OUT:-$ROOT/target/ispc-spmd-report}
CASES=${TYPELISP_ISPC_CASES:-all}
MODES=${TYPELISP_ISPC_MODES:-scalar,avx2,avx512}
SKIP_CORRECTNESS=0
SELF_TEST=0
COMPILER_ARG=
TAB=$(printf '\t')
EXPECTED_HEADER='schema	case	mode	typelisp_status	typelisp_diagnostic	ispc_status	ispc_diagnostic	ispc_target	gang_width	lane_type	typelisp_source	typelisp_symbol	ispc_source	ispc_symbol	driver	arguments	repetitions	expected_exit	upstream_tag	upstream_commit	upstream_path	upstream_function	license'
SCALAR_DIAGNOSTIC='ISPC v1.31.0 has no width-1 CPU target; smallest generic target is generic-i32x4'
PINNED_COMMIT=c6adb4f86f5678ce6c41951b1e2b59f727455697
TL_FLAGS='--opt-level 2'
ISPC_FLAGS='-O2 --arch=x86-64'

usage() {
    cat <<'EOF'
usage: scripts/measure-ispc-spmd.sh [options] [typelisp-bin]

Options:
  --cases LIST          Comma-separated case names, or all (default: all)
  --modes LIST          Comma-separated scalar,avx2,avx512 modes
  --output DIR          Report and raw-artifact root
  --skip-correctness    Compile/analyze only; intended for harness development
  --self-test           Run fast metadata/report/analyzer mutation tests
  -h, --help            Show this help

Environment:
  TYPELISP_BIN          Compiler when no positional binary is supplied
  ISPC_BIN              Optional exact ISPC v1.31.0 binary
  TYPELISP_ISPC_CASES   Default --cases selection
  TYPELISP_ISPC_MODES   Default --modes selection
  TYPELISP_ISPC_OUT     Default --output directory

The normal run emits support.tsv, static.tsv, comparison.tsv, tools.tsv, and
raw compiler/assembly logs. Missing ISPC skips only ISPC rows. Dynamic retired-
instruction measurement remains with the host-keyed SPMD counter tools; those
tools do not yet accept arbitrary ISPC binaries.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --cases)
            [ "$#" -ge 2 ] || { echo "missing value for --cases" >&2; exit 2; }
            CASES=$2
            shift 2
            ;;
        --modes)
            [ "$#" -ge 2 ] || { echo "missing value for --modes" >&2; exit 2; }
            MODES=$2
            shift 2
            ;;
        --output)
            [ "$#" -ge 2 ] || { echo "missing value for --output" >&2; exit 2; }
            WORKDIR=$2
            shift 2
            ;;
        --skip-correctness)
            SKIP_CORRECTNESS=1
            shift
            ;;
        --self-test)
            SELF_TEST=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        -*)
            echo "unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            [ -z "$COMPILER_ARG" ] || {
                echo "only one typelisp binary may be supplied" >&2
                exit 2
            }
            COMPILER_ARG=$1
            shift
            ;;
    esac
done

fail() {
    echo "[ispc-spmd] $*" >&2
    exit 1
}

csv_contains() {
    case ",$1," in
        *,"$2",*) return 0 ;;
        *) return 1 ;;
    esac
}

validate_modes() {
    case "$MODES" in
        "" | ,* | *, | *,,* | *[!a-z0-9_,]*) fail "invalid mode list: $MODES" ;;
    esac
    _seen=,
    _old_ifs=$IFS
    IFS=,
    set -- $MODES
    IFS=$_old_ifs
    for _mode do
        case "$_mode" in scalar | avx2 | avx512) ;; *) fail "unknown mode: $_mode" ;; esac
        case "$_seen" in *,"$_mode",*) fail "duplicate mode: $_mode" ;; esac
        _seen="$_seen$_mode,"
    done
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        fail "sha256sum or shasum is required"
    fi
}

validate_metadata() {
    _metadata=$1
    _case=$2
    awk -F '\t' -v expected_header="$EXPECTED_HEADER" -v expected_case="$_case" \
        -v scalar_diagnostic="$SCALAR_DIAGNOSTIC" -v pinned_commit="$PINNED_COMMIT" '
        NR == 1 { if ($0 != expected_header) failed = 1; next }
        {
            key = $2 SUBSEP $3
            if (NF != 23 || $1 != "typelisp-ispc-case-v1" ||
                $2 != expected_case || seen[key]++ ||
                ($3 != "scalar" && $3 != "avx2" && $3 != "avx512") ||
                ($4 != "supported" && $4 != "unsupported") ||
                ($6 != "supported" && $6 != "unsupported") ||
                $10 != "f32" || $11 != "bench.tl" || $13 != "kernel.ispc" ||
                $15 != "driver.c" || $17 !~ /^[1-9][0-9]*$/ ||
                $18 !~ /^[0-9]+$/ || $19 != "v1.31.0" ||
                $20 != pinned_commit || $23 != "BSD-3-Clause" ||
                $12 !~ /^[A-Za-z0-9-]+$/ || $14 !~ /^[A-Za-z0-9_]+$/ ||
                $16 == "" || $21 == "" || $22 == "") failed = 1
            if (($4 == "supported" && $5 != "") ||
                ($4 == "unsupported" && $5 !~ /^lower: /)) failed = 1
            if (($6 == "supported" && $7 != "") ||
                ($6 == "unsupported" && $7 == "")) failed = 1
            if ($3 == "scalar" && ($6 != "unsupported" ||
                $7 != scalar_diagnostic || $8 != "none" || $9 != "1")) failed = 1
            if ($3 == "avx2" && ($6 != "supported" || $7 != "" ||
                $8 != "avx2-i32x8" || $9 != "8")) failed = 1
            if ($3 == "avx512" && ($6 != "supported" || $7 != "" ||
                $8 != "avx512skx-x16" || $9 != "16")) failed = 1
            modes[$3]++
            rows++
        }
        END {
            if (rows != 3 || modes["scalar"] != 1 || modes["avx2"] != 1 ||
                modes["avx512"] != 1) failed = 1
            exit failed ? 1 : 0
        }
    ' "$_metadata"
}

diagnostic_present() {
    _expected=$1
    _stderr=$2
    awk -v expected="$_expected" '
        $0 == expected ||
        (length($0) > length(expected) &&
            substr($0, length($0) - length(expected) + 1) == expected) {
            found = 1
        }
        END { exit found ? 0 : 1 }
    ' "$_stderr"
}

find_symbol_label() {
    _asm=$1
    _stem=$2
    _prefer_internal=$3
    awk -v stem="$_stem" -v prefer_internal="$_prefer_internal" '
        $1 == stem ":" { exact = $1 }
        index($1, stem "___") == 1 && substr($1, length($1), 1) == ":" && internal == "" {
            internal = $1
        }
        END {
            if (prefer_internal == "yes" && internal != "") print internal
            else if (exact != "") print exact
            else if (internal != "") print internal
            else exit 1
        }
    ' "$_asm"
}

extract_symbol() {
    _asm=$1
    _stem=$2
    _prefer_internal=$3
    _out=$4
    _label=$(find_symbol_label "$_asm" "$_stem" "$_prefer_internal") || return 1
    awk -v label="$_label" '
        $1 == label { active = 1 }
        active && $1 != label && /^[[:space:]]*\.globl[[:space:]]/ { exit }
        active { print }
        active && /#[[:space:]]*-- End function/ { exit }
        active && /^[[:space:]]*\.size[[:space:]]/ { exit }
    ' "$_asm" > "$_out"
    [ -s "$_out" ] || return 1
    printf '%s\n' "${_label%:}"
}

vector_opcode_census() {
    awk '
        /^[[:space:]]+[A-Za-z][A-Za-z0-9.]*/ &&
        (/%[xyz]mm[0-9]+/ || tolower($1) ~ /(gather|scatter)/) {
            print tolower($1)
        }
    ' "$1" | sort | uniq -c | awk '
        {
            if (count++) printf ";"
            printf "%s=%d", $2, $1
        }
        END { if (!count) printf "-"; printf "\n" }
    '
}

record_static() {
    _case=$1
    _mode=$2
    _implementation=$3
    _asm=$4
    _stem=$5
    _prefer_internal=$6
    _flags=$7
    _tool_sha=$8
    _body="$WORKDIR/raw/$_case/$_mode/$_implementation.kernel.s"
    mkdir -p "$(dirname -- "$_body")"
    _symbol=$(extract_symbol "$_asm" "$_stem" "$_prefer_internal" "$_body") ||
        fail "$_case/$_mode: missing $_implementation symbol $_stem"
    _hash=$(sha256_file "$_body")
    _bytes=$(wc -c < "$_body" | tr -d ' ')
    _counts=$(awk -f "$ROOT/tools/ispc-spmd-report/analyze.awk" "$_body")
    _opcodes=$(vector_opcode_census "$_body")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$_case" "$_mode" "$_implementation" "$_symbol" "$_hash" "$_bytes" \
        "$_counts" "$_opcodes" "$_flags" "$_tool_sha" >> "$STATIC"
}

write_comparison() {
    _rows=$1
    _static=$2
    _output=$3
    awk -F '\t' '
        NR == FNR {
            key = $2 SUBSEP $3
            if (!ordered[key]++) order[++order_count] = key
            next
        }
        FNR == 1 { next }
        {
            key = $1 SUBSEP $2
            impl = $3
            value[key, impl, "asm_bytes"] = $6
            value[key, impl, "instructions"] = $7
            value[key, impl, "branches"] = $8
            value[key, impl, "calls"] = $9
            value[key, impl, "spill_candidates"] = $10
            value[key, impl, "gpr_registers"] = $11
            value[key, impl, "vector_registers"] = $12
            value[key, impl, "mask_registers"] = $13
            value[key, impl, "xmm_instructions"] = $14
            value[key, impl, "ymm_instructions"] = $15
            value[key, impl, "zmm_instructions"] = $16
            value[key, impl, "gathers"] = $17
            value[key, impl, "scatters"] = $18
            value[key, impl, "stack_accesses"] = $19
        }
        BEGIN {
            metric_count = split("asm_bytes instructions branches calls spill_candidates gpr_registers vector_registers mask_registers xmm_instructions ymm_instructions zmm_instructions gathers scatters stack_accesses", metrics, " ")
            print "case\tmode\tmetric\ttypelisp\tispc\ttypelisp_over_ispc\tgeomean_pair_count"
        }
        END {
            for (i = 1; i <= order_count; i++) {
                split(order[i], parts, SUBSEP)
                for (m = 1; m <= metric_count; m++) {
                    metric = metrics[m]
                    left = value[order[i], "typelisp", metric]
                    right = value[order[i], "ispc", metric]
                    if (left == "" || right == "") continue
                    ratio = "na"
                    if ((left + 0) > 0 && (right + 0) > 0) {
                        numeric_ratio = (left + 0) / (right + 0)
                        ratio = sprintf("%.6f", numeric_ratio)
                        log_sum[metric] += log(numeric_ratio)
                        pair_count[metric]++
                    }
                    printf "%s\t%s\t%s\t%s\t%s\t%s\t\n", parts[1], parts[2], metric, left, right, ratio
                }
            }
            for (m = 1; m <= metric_count; m++) {
                metric = metrics[m]
                if (pair_count[metric] > 0)
                    printf "__geomean__\tall\t%s\t\t\t%.6f\t%d\n", metric, exp(log_sum[metric] / pair_count[metric]), pair_count[metric]
            }
        }
    ' "$_rows" "$_static" > "$_output"
}

run_correctness_command() {
    sh "$1"
}

discover_ispc() {
    if [ -n "${ISPC_BIN:-}" ]; then
        [ -x "$ISPC_BIN" ] || fail "ISPC_BIN is not executable: $ISPC_BIN"
        printf '%s\n' "$ISPC_BIN"
    else
        command -v ispc 2>/dev/null || true
    fi
}

self_test() {
    _test_root="$ROOT/target/ispc-spmd-self-test"
    rm -rf "$_test_root"
    mkdir -p "$_test_root"

    validate_metadata "$CORPUS/point_transform/case.tsv" point_transform ||
        fail "self-test: checked metadata rejected"
    awk -F '\t' -v OFS='\t' 'NR == 3 { $9 = 4 } { print }' \
        "$CORPUS/point_transform/case.tsv" > "$_test_root/bad-width.tsv"
    if validate_metadata "$_test_root/bad-width.tsv" point_transform; then
        fail "self-test: target/width mutation accepted"
    fi

    cat > "$_test_root/fixture.s" <<'EOF'
.globl kernel
kernel:
        movq %rax, -8(%rsp)
        vaddps %ymm1, %ymm2, %ymm3
        vgatherdps (%rax,%ymm1,4), %ymm2
        jne .L1
        callq helper
        retq
.size kernel, .-kernel
EOF
    _label=$(extract_symbol "$_test_root/fixture.s" kernel no "$_test_root/kernel.s") ||
        fail "self-test: symbol extraction failed"
    [ "$_label" = kernel ] || fail "self-test: wrong extracted symbol: $_label"
    _counts=$(awk -f "$ROOT/tools/ispc-spmd-report/analyze.awk" "$_test_root/kernel.s")
    [ "$_counts" = "6${TAB}1${TAB}1${TAB}1${TAB}2${TAB}3${TAB}0${TAB}0${TAB}2${TAB}0${TAB}1${TAB}0${TAB}1" ] ||
        fail "self-test: assembly census mismatch: $_counts"
    _opcodes=$(vector_opcode_census "$_test_root/kernel.s")
    [ "$_opcodes" = 'vaddps=1;vgatherdps=1' ] ||
        fail "self-test: vector opcode census mismatch: $_opcodes"

    if (PATH=/definitely-missing ISPC_BIN= discover_ispc) | grep -q .; then
        fail "self-test: missing ISPC was not represented as absent"
    fi
    printf '%s\n' '#!/usr/bin/env sh' 'exit 7' > "$_test_root/fail-parity.sh"
    chmod +x "$_test_root/fail-parity.sh"
    if run_correctness_command "$_test_root/fail-parity.sh"; then
        fail "self-test: parity failure was accepted"
    fi
    printf '%s\n' "$SCALAR_DIAGNOSTIC" > "$_test_root/diagnostic.stderr"
    diagnostic_present "$SCALAR_DIAGNOSTIC" "$_test_root/diagnostic.stderr" ||
        fail "self-test: exact unsupported diagnostic rejected"
    if diagnostic_present 'different diagnostic' "$_test_root/diagnostic.stderr"; then
        fail "self-test: wrong unsupported diagnostic accepted"
    fi

    printf 'schema\tcase\tmode\nrow\tcase_a\tavx2\nrow\tcase_b\tavx2\n' > "$_test_root/rows.tsv"
    printf 'case\tmode\timplementation\tsymbol\tasm_sha256\tasm_bytes\tinstructions\tbranches\tcalls\tspill_candidates\tgpr_registers\tvector_registers\tmask_registers\txmm_instructions\tymm_instructions\tzmm_instructions\tgathers\tscatters\tstack_accesses\tvector_opcode_census\tflags\ttool_sha256\n' > "$_test_root/static.tsv"
    printf 'case_a\tavx2\ttypelisp\tt\th\t20\t40\t2\t0\t0\t4\t3\t0\t0\t2\t0\t0\t0\t1\tvaddps=2\tf\tt\n' >> "$_test_root/static.tsv"
    printf 'case_a\tavx2\tispc\ti\th\t10\t20\t1\t0\t0\t2\t3\t0\t0\t2\t0\t0\t0\t1\tvaddps=2\tf\ti\n' >> "$_test_root/static.tsv"
    printf 'case_b\tavx2\ttypelisp\tt\th\t99\t99\t0\t0\t0\t1\t1\t0\t0\t1\t0\t0\t0\t0\tvaddps=1\tf\tt\n' >> "$_test_root/static.tsv"
    write_comparison "$_test_root/rows.tsv" "$_test_root/static.tsv" "$_test_root/comparison.tsv"
    grep -Fqx "__geomean__${TAB}all${TAB}instructions${TAB}${TAB}${TAB}2.000000${TAB}1" \
        "$_test_root/comparison.tsv" || fail "self-test: geomean exclusion failed"

    echo "ISPC SPMD harness self-tests passed"
}

if [ "$SELF_TEST" -eq 1 ]; then
    self_test
    exit 0
fi

validate_modes
case "$CASES" in
    all) ;;
    "" | ,* | *, | *,,* | *[!A-Za-z0-9_,]*) fail "invalid case list: $CASES" ;;
esac

if [ -n "$COMPILER_ARG" ]; then
    COMPILER=$COMPILER_ARG
elif [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi
case "$COMPILER" in /* | [A-Za-z]:[\\/]*) ;; *) COMPILER="$ROOT/$COMPILER" ;; esac
[ -x "$COMPILER" ] || fail "TypeLisp compiler is not executable: $COMPILER"

ISPC=$(discover_ispc)
if [ -n "$ISPC" ]; then
    ISPC_VERSION=$("$ISPC" --version 2>&1 | sed -n '1p')
    case "$ISPC_VERSION" in *1.31.0*) ;; *) fail "ISPC v1.31.0 required: $ISPC_VERSION" ;; esac
    ISPC_SHA=$(sha256_file "$ISPC")
else
    ISPC_VERSION=missing
    ISPC_SHA=missing
fi
TL_VERSION=$("$COMPILER" --version 2>&1 | sed -n '1p')
TL_SHA=$(sha256_file "$COMPILER")

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR/raw"
CORRECTNESS_PATH=$PATH
if ! command -v nm >/dev/null 2>&1 && command -v llvm-nm >/dev/null 2>&1; then
    mkdir -p "$WORKDIR/tool-shims"
    printf '%s\n' '#!/usr/bin/env sh' 'exec llvm-nm "$@"' > "$WORKDIR/tool-shims/nm"
    chmod +x "$WORKDIR/tool-shims/nm"
    CORRECTNESS_PATH="$WORKDIR/tool-shims:$PATH"
fi
ROWS="$WORKDIR/metadata.rows.tsv"
SUPPORT="$WORKDIR/support.tsv"
STATIC="$WORKDIR/static.tsv"
COMPARISON="$WORKDIR/comparison.tsv"
TOOLS="$WORKDIR/tools.tsv"
: > "$ROWS"
printf 'case\tmode\timplementation\tdeclared_status\tobserved_status\tdiagnostic\ttarget\tgang_width\tlane_type\n' > "$SUPPORT"
printf 'case\tmode\timplementation\tsymbol\tasm_sha256\tasm_bytes\tinstructions\tbranches\tcalls\tspill_candidates\tgpr_registers\tvector_registers\tmask_registers\txmm_instructions\tymm_instructions\tzmm_instructions\tgathers\tscatters\tstack_accesses\tvector_opcode_census\tflags\ttool_sha256\n' > "$STATIC"
printf 'implementation\tversion\tbinary_sha256\tflags\n' > "$TOOLS"
printf 'typelisp\t%s\t%s\t%s\n' "$TL_VERSION" "$TL_SHA" "$TL_FLAGS" >> "$TOOLS"
printf 'ispc\t%s\t%s\t%s\n' "$ISPC_VERSION" "$ISPC_SHA" "$ISPC_FLAGS" >> "$TOOLS"

_selected=0
for _metadata in $(find "$CORPUS" -mindepth 2 -maxdepth 2 -name case.tsv | sort); do
    _case=$(basename "$(dirname "$_metadata")")
    if [ "$CASES" != all ] && ! csv_contains "$CASES" "$_case"; then continue; fi
    validate_metadata "$_metadata" "$_case" || fail "invalid metadata: $_metadata"
    for _required in bench.tl kernel.ispc driver.c LICENSE.BSD-3-Clause; do
        [ -f "$(dirname "$_metadata")/$_required" ] || fail "$_case: missing $_required"
    done
    tail -n +2 "$_metadata" >> "$ROWS"
    _selected=$((_selected + 1))
done
[ "$_selected" -gt 0 ] || fail "no cases selected"

if [ "$CASES" != all ]; then
    _old_ifs=$IFS
    IFS=,
    set -- $CASES
    IFS=$_old_ifs
    for _wanted do
        grep -q "${TAB}${_wanted}${TAB}" "$ROWS" || fail "unknown case: $_wanted"
    done
fi

if [ "$SKIP_CORRECTNESS" -eq 0 ]; then
    cut -f 2 "$ROWS" | awk '!seen[$0]++' | while IFS= read -r _case; do
        _script_case=$(printf '%s' "$_case" | tr '_' '-')
        _verify="$ROOT/scripts/verify-ispc-$_script_case.sh"
        [ -f "$_verify" ] || fail "$_case: missing correctness script $_verify"
        echo "[ispc-spmd] correctness $_case"
        if ! PATH="$CORRECTNESS_PATH" TYPELISP_BIN="$COMPILER" ISPC_BIN="$ISPC" \
            run_correctness_command "$_verify" \
            > "$WORKDIR/raw/$_case.correctness.stdout" \
            2> "$WORKDIR/raw/$_case.correctness.stderr"; then
            sed 's/^/  /' "$WORKDIR/raw/$_case.correctness.stderr" >&2 || true
            fail "$_case: correctness/parity failed"
        fi
    done
fi

while IFS= read -r _row; do
    _case=$(printf '%s\n' "$_row" | cut -f 2)
    _mode=$(printf '%s\n' "$_row" | cut -f 3)
    csv_contains "$MODES" "$_mode" || continue
    _tl_status=$(printf '%s\n' "$_row" | cut -f 4)
    _tl_diagnostic=$(printf '%s\n' "$_row" | cut -f 5)
    _ispc_status=$(printf '%s\n' "$_row" | cut -f 6)
    _ispc_diagnostic=$(printf '%s\n' "$_row" | cut -f 7)
    _ispc_target=$(printf '%s\n' "$_row" | cut -f 8)
    _gang_width=$(printf '%s\n' "$_row" | cut -f 9)
    _lane_type=$(printf '%s\n' "$_row" | cut -f 10)
    _tl_source=$(printf '%s\n' "$_row" | cut -f 11)
    _tl_symbol=$(printf '%s\n' "$_row" | cut -f 12)
    _ispc_source=$(printf '%s\n' "$_row" | cut -f 13)
    _ispc_symbol=$(printf '%s\n' "$_row" | cut -f 14)
    _case_dir="$CORPUS/$_case"
    _raw="$WORKDIR/raw/$_case/$_mode"
    mkdir -p "$_raw"

    _tl_asm="$_raw/typelisp.s"
    set +e
    "$COMPILER" compile "$_case_dir/$_tl_source" --backend-mode "$_mode" \
        --opt-level 2 --stdlib-root "$ROOT/stdlib" -o "$_tl_asm" \
        > "$_raw/typelisp.compile.stdout" 2> "$_raw/typelisp.compile.stderr"
    _tl_exit=$?
    set -e
    if [ "$_tl_status" = unsupported ]; then
        [ "$_tl_exit" -ne 0 ] || fail "$_case/$_mode: TypeLisp unexpectedly compiled"
        diagnostic_present "$_tl_diagnostic" "$_raw/typelisp.compile.stderr" ||
            fail "$_case/$_mode: TypeLisp unsupported diagnostic mismatch"
        printf '%s\t%s\ttypelisp\tunsupported\tunsupported\t%s\tnone\t%s\t%s\n' \
            "$_case" "$_mode" "$_tl_diagnostic" "$_gang_width" "$_lane_type" >> "$SUPPORT"
    else
        [ "$_tl_exit" -eq 0 ] || {
            sed 's/^/  /' "$_raw/typelisp.compile.stderr" >&2 || true
            fail "$_case/$_mode: TypeLisp compile failed"
        }
        _normalized=$(printf '%s' "$_tl_symbol" | tr '-' '_')
        record_static "$_case" "$_mode" typelisp "$_tl_asm" \
            "_tl_bench_$_normalized" no "$TL_FLAGS --backend-mode $_mode" "$TL_SHA"
        printf '%s\t%s\ttypelisp\tsupported\tmeasured\t\tnone\t%s\t%s\n' \
            "$_case" "$_mode" "$_gang_width" "$_lane_type" >> "$SUPPORT"
    fi

    if [ "$_ispc_status" = unsupported ]; then
        printf '%s\t%s\tispc\tunsupported\tunsupported\t%s\t%s\t%s\t%s\n' \
            "$_case" "$_mode" "$_ispc_diagnostic" "$_ispc_target" \
            "$_gang_width" "$_lane_type" >> "$SUPPORT"
    elif [ -z "$ISPC" ]; then
        printf '%s\t%s\tispc\tsupported\ttool-missing\tISPC v1.31.0 not found\t%s\t%s\t%s\n' \
            "$_case" "$_mode" "$_ispc_target" "$_gang_width" "$_lane_type" >> "$SUPPORT"
    else
        _ispc_asm="$_raw/ispc.s"
        if ! "$ISPC" "$_case_dir/$_ispc_source" -O2 --arch=x86-64 \
            --target="$_ispc_target" --emit-asm -o "$_ispc_asm" \
            > "$_raw/ispc.compile.stdout" 2> "$_raw/ispc.compile.stderr"; then
            sed 's/^/  /' "$_raw/ispc.compile.stderr" >&2 || true
            fail "$_case/$_mode: ISPC compile failed"
        fi
        record_static "$_case" "$_mode" ispc "$_ispc_asm" \
            "$_ispc_symbol" yes "$ISPC_FLAGS --target=$_ispc_target" "$ISPC_SHA"
        printf '%s\t%s\tispc\tsupported\tmeasured\t\t%s\t%s\t%s\n' \
            "$_case" "$_mode" "$_ispc_target" "$_gang_width" "$_lane_type" >> "$SUPPORT"
    fi
done < "$ROWS"

write_comparison "$ROWS" "$STATIC" "$COMPARISON"
echo "[ispc-spmd] support: $SUPPORT"
echo "[ispc-spmd] static: $STATIC"
echo "[ispc-spmd] comparison: $COMPARISON"
echo "[ispc-spmd] tools: $TOOLS"
