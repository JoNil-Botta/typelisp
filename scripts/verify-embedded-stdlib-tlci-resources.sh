#!/usr/bin/env bash
set -eu

# Enforce the cross-host embedded-TLCI build ceiling and emit paired,
# machine-readable resource evidence. Measurements are informational; output,
# routing, identity, and the 8 GiB process-tree cap are required assertions.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/scripts/verify-embedded-stdlib-tlci-resources.sh"
BOUNDED="$ROOT/scripts/run-memory-bounded.sh"
CAP_MIB=8192
CAP_BYTES=8589934592
TIMEOUT_SECONDS=1200

fail() {
    echo "[embedded-tlci-resources] $*" >&2
    exit 1
}

file_bytes() {
    wc -c < "$1" | tr -d ' '
}

producer_identity() {
    _identity_compiler=$1
    if _identity_value=$("$_identity_compiler" --producer-identity 2>/dev/null); then
        :
    else
        _identity_value=$("$_identity_compiler" --version 2>/dev/null |
            awk 'NR == 1 && $1 == "typelisp" { print $2 }')
    fi
    printf '%s\n' "$_identity_value" | tr -d '\r\n'
}

# On success, publish BOUND_* globals. Reject extra, duplicate, missing, or
# malformed fields so a wrapper regression cannot silently weaken the gate.
read_bounded_report() {
    _bounded_report=$1
    [ -s "$_bounded_report" ] || {
        echo "bounded report is missing or empty: $_bounded_report" >&2
        return 1
    }
    if ! awk -F= '
        BEGIN {
            expected["schema_version"] = 1
            expected["host"] = 1
            expected["backend"] = 1
            expected["reason"] = 1
            expected["exit_code"] = 1
            expected["limit_bytes"] = 1
            expected["peak_memory_bytes"] = 1
            expected["wall_ms"] = 1
        }
        NF < 2 || !($1 in expected) || seen[$1] { bad = 1 }
        { seen[$1] = 1; rows += 1 }
        END {
            for (key in expected) if (!seen[key]) bad = 1
            exit rows == 8 && !bad ? 0 : 1
        }
    ' "$_bounded_report"; then
        echo "bounded report violates schema v1: $_bounded_report" >&2
        return 1
    fi
    BOUND_SCHEMA=$(sed -n 's/^schema_version=//p' "$_bounded_report")
    BOUND_HOST=$(sed -n 's/^host=//p' "$_bounded_report")
    BOUND_BACKEND=$(sed -n 's/^backend=//p' "$_bounded_report")
    BOUND_REASON=$(sed -n 's/^reason=//p' "$_bounded_report")
    BOUND_EXIT=$(sed -n 's/^exit_code=//p' "$_bounded_report")
    BOUND_LIMIT=$(sed -n 's/^limit_bytes=//p' "$_bounded_report")
    BOUND_PEAK=$(sed -n 's/^peak_memory_bytes=//p' "$_bounded_report")
    BOUND_WALL=$(sed -n 's/^wall_ms=//p' "$_bounded_report")
    for _bounded_numeric in \
        "$BOUND_SCHEMA" "$BOUND_EXIT" "$BOUND_LIMIT" "$BOUND_PEAK" "$BOUND_WALL"; do
        case "$_bounded_numeric" in
            "" | *[!0-9]*)
                echo "bounded report has malformed numeric fields: $_bounded_report" >&2
                return 1
                ;;
        esac
    done
    [ "$BOUND_SCHEMA" = 1 ] || return 1
    case "$BOUND_HOST:$BOUND_BACKEND" in
        linux:systemd-user-cgroup | linux:rss-watchdog | linux:unavailable | windows:job-object) ;;
        *)
            echo "bounded report has unsupported host/backend: $BOUND_HOST/$BOUND_BACKEND" >&2
            return 1
            ;;
    esac
    case "$BOUND_REASON" in
        success | command-failure | memory-limit | timeout | wrapper-failure) ;;
        *)
            echo "bounded report has unknown reason: $BOUND_REASON" >&2
            return 1
            ;;
    esac
}

require_output() {
    _output_workload=$1
    _output_path=$2
    if [ ! -s "$_output_path" ]; then
        echo "[embedded-tlci-resources] missing-output: workload=$_output_workload path=$_output_path" >&2
        return 1
    fi
}

run_self_test() {
    _self_dir="$ROOT/target/embedded-stdlib-tlci-resource-self-test"
    rm -rf "$_self_dir"
    mkdir -p "$_self_dir"
    _self_bash=$(command -v bash || true)
    [ -n "$_self_bash" ] || fail "resource verifier self-test requires bash"

    _self_report="$_self_dir/success.kv"
    "$BOUNDED" --limit-mib 512 --timeout-seconds 30 \
        --report "$_self_report" --working-directory "$ROOT" -- \
        "$_self_bash" -c 'printf "%s\n" bounded-ok > "$1"' \
        bash "$_self_dir/output.txt"
    read_bounded_report "$_self_report" || fail "success report rejected"
    [ "$BOUND_REASON:$BOUND_EXIT" = success:0 ] ||
        fail "success classification mismatch: $BOUND_REASON/$BOUND_EXIT"
    require_output self-test-success "$_self_dir/output.txt" || exit 1

    _self_status=0
    "$BOUNDED" --limit-mib 512 --timeout-seconds 30 \
        --report "$_self_dir/failure.kv" --working-directory "$ROOT" -- \
        "$_self_bash" -c 'exit 23' || _self_status=$?
    read_bounded_report "$_self_dir/failure.kv" || fail "failure report rejected"
    [ "$_self_status:$BOUND_REASON:$BOUND_EXIT" = 23:command-failure:23 ] ||
        fail "command failure classification mismatch: $_self_status/$BOUND_REASON/$BOUND_EXIT"

    _self_status=0
    "$BOUNDED" --limit-mib 512 --timeout-seconds 1 \
        --report "$_self_dir/timeout.kv" --working-directory "$ROOT" -- \
        "$_self_bash" -c 'sleep 30' || _self_status=$?
    read_bounded_report "$_self_dir/timeout.kv" || fail "timeout report rejected"
    [ "$_self_status:$BOUND_REASON:$BOUND_EXIT" = 124:timeout:124 ] ||
        fail "timeout classification mismatch: $_self_status/$BOUND_REASON/$BOUND_EXIT"

    _self_status=0
    "$BOUNDED" --limit-mib 512 --timeout-seconds 30 \
        --report "$_self_dir/wrapper.kv" --working-directory "$ROOT" -- \
        "$_self_dir/missing-command" || _self_status=$?
    read_bounded_report "$_self_dir/wrapper.kv" || fail "wrapper report rejected"
    [ "$_self_status:$BOUND_REASON:$BOUND_EXIT" = 2:wrapper-failure:2 ] ||
        fail "wrapper failure classification mismatch: $_self_status/$BOUND_REASON/$BOUND_EXIT"

    if require_output self-test-missing "$_self_dir/intentionally-missing" \
        2> "$_self_dir/missing.stderr"; then
        fail "missing output fixture unexpectedly passed"
    fi
    grep -F 'missing-output: workload=self-test-missing' \
        "$_self_dir/missing.stderr" >/dev/null ||
        fail "missing output diagnostic was not specific"

    printf 'schema_version=1\nhost=windows\n' > "$_self_dir/malformed.kv"
    if read_bounded_report "$_self_dir/malformed.kv" >/dev/null 2>&1; then
        fail "malformed bounded report unexpectedly passed"
    fi
    echo "Embedded stdlib TLCI resource verifier self-tests passed"
}

if [ "${1:-}" = --self-test ]; then
    [ "$#" -eq 1 ] || fail "usage: $0 --self-test"
    run_self_test
    exit 0
fi

# Internal modes run beneath the process-tree wrapper. Keeping compile + native
# assemble/link inside one child lets each build row describe the whole build.
if [ "${1:-}" = --internal-build-image ]; then
    [ "$#" -eq 5 ] || fail "malformed internal image-build invocation"
    mkdir -p "$5"
    TYPELISP_EMBEDDED_STDLIB_WORKDIR=$(CDPATH= cd -- "$5" && pwd)
    export TYPELISP_EMBEDDED_STDLIB_WORKDIR
    exec "$ROOT/scripts/build-embedded-stdlib-tlci.sh" "$2" "$4" "$3"
fi

if [ "${1:-}" = --internal-build-compiler ]; then
    [ "$#" -eq 4 ] || fail "malformed internal compiler-build invocation"
    _build_compiler=$2
    _build_opt=$3
    _build_dir=$4
    case "$_build_opt" in 1 | 2) ;; *) fail "invalid internal opt level: $_build_opt" ;; esac
    . "$ROOT/scripts/lib-native-link.sh"
    native_link_detect_host
    configure_toolchain
    mkdir -p "$_build_dir"
    _build_asm="$_build_dir/typelisp.s"
    _build_obj="$_build_dir/typelisp.$NL_OBJ_EXT"
    _build_bin="$_build_dir/typelisp$NL_BIN_EXT"
    "$_build_compiler" compile "$ROOT/src/main.tl" \
        -o "$_build_asm" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) \
        --backend-mode scalar \
        --opt-level "$_build_opt" \
        --stdlib-root "$ROOT/stdlib" \
        --stdlib-root "$ROOT/src" \
        --cfg compiler-build-identity \
        --cfg compile-profile \
        --cfg embedded-stdlib-tlci
    assemble_and_link "resource opt$_build_opt compiler" \
        "$_build_asm" "$_build_obj" "$_build_bin"
    [ -s "$_build_bin" ] || fail "internal opt$_build_opt build emitted no compiler"
    exit 0
fi

internal_expand() {
    _expand_compiler=$1
    _expand_route=$2
    _expand_source=$3
    _expand_output=$4
    _expand_native_cwd=$5
    _expand_source_root=$6
    _expand_cachegrind=${7:-}
    _expand_valgrind_log=${8:-}
    . "$ROOT/scripts/lib-native-link.sh"
    native_link_detect_host
    if [ "$_expand_route" = native ]; then
        cd "$_expand_native_cwd"
        set -- "$_expand_compiler" compile "$_expand_source" \
            -o "$_expand_output" --target "$NL_BOOTSTRAP_TARGET" \
            $(native_target_cfg_args) --backend-mode scalar --opt-level 2
    elif [ "$_expand_route" = source ]; then
        cd "$_expand_source_root"
        set -- "$_expand_compiler" compile "$_expand_source" \
            -o "$_expand_output" --target "$NL_BOOTSTRAP_TARGET" \
            $(native_target_cfg_args) --backend-mode scalar --opt-level 2 \
            --stdlib-root stdlib
    else
        fail "invalid internal expansion route: $_expand_route"
    fi
    if [ -n "$_expand_cachegrind" ]; then
        exec valgrind --tool=cachegrind --cache-sim=no --branch-sim=no \
            --cachegrind-out-file="$_expand_cachegrind" \
            --log-file="$_expand_valgrind_log" "$@"
    fi
    exec "$@"
}

if [ "${1:-}" = --internal-expand ]; then
    [ "$#" -eq 7 ] || fail "malformed internal expansion invocation"
    internal_expand "$2" "$3" "$4" "$5" "$6" "$7"
fi

if [ "${1:-}" = --internal-instructions ]; then
    [ "$#" -eq 9 ] || fail "malformed internal instruction invocation"
    internal_expand "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9"
fi

[ "$#" -eq 0 ] || fail "usage: $0 [--self-test]"
[ -x "$BOUNDED" ] || fail "bounded runner is not executable: $BOUNDED"

. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host
configure_toolchain

if [ -z "${TYPELISP_BIN:-}" ]; then
    fail "normal resource verification requires TYPELISP_BIN"
fi
COMPILER=$TYPELISP_BIN
case "$COMPILER" in
    /* | [A-Za-z]:[/\\]*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac
[ -x "$COMPILER" ] || fail "compiler is not executable: $COMPILER"
BASH_EXE=$(command -v bash || true)
[ -n "$BASH_EXE" ] || fail "resource verification requires bash"

WORKDIR="$ROOT/target/embedded-stdlib-tlci-resources/$NL_HOST_OS"
case "$WORKDIR" in "$ROOT"/target/*) ;; *) fail "unsafe resource workdir: $WORKDIR" ;; esac
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR/reports" "$WORKDIR/logs"
REPORT="$WORKDIR/report.tsv"
ASSERTIONS="$WORKDIR/assertions.tsv"
METADATA="$WORKDIR/metadata.tsv"
COMMANDS="$WORKDIR/commands.tsv"
printf 'schema_version\thost\tworkload\troute\topt_level\tstatus\treason\texit_code\tlimit_bytes\tpeak_memory_bytes\twall_ms\tinstruction_count\tinstruction_source\toutput_bytes\traw_image_bytes\tcompressed_image_bytes\tnative_dispatches\tsource_interpreted\tcompiler_identity\tsource_identity\tbackend\n' > "$REPORT"
printf 'schema_version\tassertion\tclass\tstatus\tdetail\n' > "$ASSERTIONS"
printf 'schema_version\tkey\tvalue\n' > "$METADATA"
printf 'schema_version\tworkload\tcommand\n' > "$COMMANDS"

metadata_add() {
    _metadata_value=$(printf '%s' "$3" | tr '\t\r\n' '   ')
    printf '1\t%s\t%s\n' "$2" "$_metadata_value" >> "$1"
}

assertion_add() {
    _assert_detail=$(printf '%s' "$4" | tr '\t\r\n' '   ')
    printf '1\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$_assert_detail" >> "$ASSERTIONS"
}

command_add() {
    _command_name=$1
    shift
    _command_text=$(printf '%s ' "$@" | tr '\t\r\n' '   ')
    printf '1\t%s\t%s\n' "$_command_name" "$_command_text" >> "$COMMANDS"
}

show_logs() {
    _show_name=$1
    echo "[embedded-tlci-resources] $_show_name stdout:" >&2
    sed 's/^/  /' "$WORKDIR/logs/$_show_name.stdout" >&2 || true
    echo "[embedded-tlci-resources] $_show_name stderr:" >&2
    sed 's/^/  /' "$WORKDIR/logs/$_show_name.stderr" >&2 || true
}

run_bounded() {
    _run_requirement=$1
    _run_name=$2
    shift 2
    _run_report="$WORKDIR/reports/$_run_name.kv"
    command_add "$_run_name" "$BOUNDED" --limit-mib "$CAP_MIB" \
        --timeout-seconds "$TIMEOUT_SECONDS" --report "$_run_report" -- "$@"
    _run_status=0
    "$BOUNDED" --limit-mib "$CAP_MIB" \
        --timeout-seconds "$TIMEOUT_SECONDS" \
        --report "$_run_report" \
        --working-directory "$ROOT" -- "$@" \
        > "$WORKDIR/logs/$_run_name.stdout" \
        2> "$WORKDIR/logs/$_run_name.stderr" || _run_status=$?
    if ! read_bounded_report "$_run_report"; then
        show_logs "$_run_name"
        [ "$_run_requirement" = optional ] && return 1
        fail "wrapper-failure: invalid report for workload=$_run_name"
    fi
    if [ "$_run_status" -ne 0 ] || [ "$BOUND_REASON" != success ] || [ "$BOUND_EXIT" -ne 0 ]; then
        show_logs "$_run_name"
        if [ "$_run_requirement" = optional ]; then
            return 1
        fi
        fail "workload=$_run_name reason=$BOUND_REASON exit=$BOUND_EXIT wrapper-exit=$_run_status"
    fi
    [ "$BOUND_LIMIT" -eq "$CAP_BYTES" ] ||
        fail "workload=$_run_name reported cap $BOUND_LIMIT, expected $CAP_BYTES"
}

append_measurement() {
    printf '1\t%s\t%s\t%s\t%s\tpass\tsuccess\t0\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$NL_HOST_OS" "$1" "$2" "$3" "$CAP_BYTES" \
        "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" \
        "${12}" "$COMPILER_IDENTITY" "$SOURCE_IDENTITY" "${13}" >> "$REPORT"
}

cd "$ROOT"
SOURCE_IDENTITY=$(git rev-parse --verify HEAD 2>/dev/null || true)
COMPILER_IDENTITY=$(producer_identity "$COMPILER")
for _identity in "$SOURCE_IDENTITY" "$COMPILER_IDENTITY"; do
    printf '%s\n' "$_identity" | grep -Eq '^[0-9a-f]{40}$' ||
        fail "malformed source/compiler identity: $_identity"
done
[ "$SOURCE_IDENTITY" = "$COMPILER_IDENTITY" ] ||
    fail "compiler identity $COMPILER_IDENTITY does not match source $SOURCE_IDENTITY"

mkdir -p "$ROOT/target/build-stage0"
printf '%s' "$SOURCE_IDENTITY" > "$ROOT/target/build-stage0/git-hash.txt"

metadata_add "$METADATA" host "$NL_HOST_OS"
metadata_add "$METADATA" source_identity "$SOURCE_IDENTITY"
metadata_add "$METADATA" producer_identity "$COMPILER_IDENTITY"
metadata_add "$METADATA" producer_path "$COMPILER"
metadata_add "$METADATA" producer_bytes "$(file_bytes "$COMPILER")"
metadata_add "$METADATA" memory_limit_mib "$CAP_MIB"
metadata_add "$METADATA" timeout_seconds "$TIMEOUT_SECONDS"
metadata_add "$METADATA" memory_semantics "linux=process-tree resident RSS/cgroup; windows=Job Object committed process/job memory"
metadata_add "$METADATA" compiler_cfg "compiler-build-identity,compile-profile,embedded-stdlib-tlci"
metadata_add "$METADATA" uname "$(uname -a)"
metadata_add "$METADATA" bash "$($BASH_EXE --version | sed -n '1p')"
if [ "$NL_HOST_OS" = linux ]; then
    metadata_add "$METADATA" native_tool "$(as --version | sed -n '1p')"
else
    metadata_add "$METADATA" native_tool "$("$TYPELISP_WINDOWS_CLANG_POSIX" --version | sed -n '1p')"
fi

assertion_add memory-cap required pass "all production workloads use $CAP_BYTES bytes"
assertion_add producer-source-identity required pass "$SOURCE_IDENTITY"

RAW_IMAGE="$ROOT/target/embedded-stdlib-tlci/stdlib.tlci"
COMPRESSED_IMAGE="$RAW_IMAGE.tlch"
# Keep the exact production layout: compiler_embedded_stdlib_tlci_payload.tl
# includes the image, source hash, and surface files from this directory.
IMAGE_WORKDIR="$ROOT/target/embedded-stdlib-tlci"
run_bounded required embedded-image-build \
    "$BASH_EXE" "$SCRIPT" --internal-build-image \
    "$COMPILER" "$NL_HOST_OS" "$RAW_IMAGE" "$IMAGE_WORKDIR"
IMAGE_PEAK=$BOUND_PEAK
IMAGE_WALL=$BOUND_WALL
IMAGE_BACKEND=$BOUND_BACKEND
require_output embedded-image-build "$RAW_IMAGE" || exit 1
require_output embedded-image-build "$COMPRESSED_IMAGE" || exit 1
RAW_BYTES=$(file_bytes "$RAW_IMAGE")
COMPRESSED_BYTES=$(file_bytes "$COMPRESSED_IMAGE")
append_measurement embedded-image-build shared - \
    "$IMAGE_PEAK" "$IMAGE_WALL" - not-applicable 0 \
    "$RAW_BYTES" "$COMPRESSED_BYTES" 0 0 "$IMAGE_BACKEND"
assertion_add embedded-image-output required pass "raw=$RAW_BYTES compressed=$COMPRESSED_BYTES"

OPT1_DIR="$WORKDIR/opt1"
OPT2_DIR="$WORKDIR/opt2"
OPT1_BIN="$OPT1_DIR/typelisp$NL_BIN_EXT"
OPT2_BIN="$OPT2_DIR/typelisp$NL_BIN_EXT"

run_bounded required compiler-build-opt1 \
    "$BASH_EXE" "$SCRIPT" --internal-build-compiler "$COMPILER" 1 "$OPT1_DIR"
OPT1_PEAK=$BOUND_PEAK
OPT1_WALL=$BOUND_WALL
OPT1_BACKEND=$BOUND_BACKEND
require_output compiler-build-opt1 "$OPT1_BIN" || exit 1
OPT1_BYTES=$(file_bytes "$OPT1_BIN")
OPT1_IDENTITY=$(producer_identity "$OPT1_BIN")
[ "$OPT1_IDENTITY" = "$SOURCE_IDENTITY" ] ||
    fail "opt1 compiler identity $OPT1_IDENTITY does not match source"

run_bounded required compiler-build-opt2 \
    "$BASH_EXE" "$SCRIPT" --internal-build-compiler "$COMPILER" 2 "$OPT2_DIR"
OPT2_PEAK=$BOUND_PEAK
OPT2_WALL=$BOUND_WALL
OPT2_BACKEND=$BOUND_BACKEND
require_output compiler-build-opt2 "$OPT2_BIN" || exit 1
OPT2_BYTES=$(file_bytes "$OPT2_BIN")
OPT2_IDENTITY=$(producer_identity "$OPT2_BIN")
[ "$OPT2_IDENTITY" = "$SOURCE_IDENTITY" ] ||
    fail "opt2 compiler identity $OPT2_IDENTITY does not match source"

append_measurement compiler-build shared 1 "$OPT1_PEAK" "$OPT1_WALL" \
    - not-applicable "$OPT1_BYTES" "$RAW_BYTES" "$COMPRESSED_BYTES" 0 0 "$OPT1_BACKEND"
append_measurement compiler-build shared 2 "$OPT2_PEAK" "$OPT2_WALL" \
    - not-applicable "$OPT2_BYTES" "$RAW_BYTES" "$COMPRESSED_BYTES" 0 0 "$OPT2_BACKEND"
assertion_add opt1-compiler-output required pass "identity=$OPT1_IDENTITY bytes=$OPT1_BYTES"
assertion_add opt2-compiler-output required pass "identity=$OPT2_IDENTITY bytes=$OPT2_BYTES"

for _startup_opt in 1 2; do
    if [ "$_startup_opt" -eq 1 ]; then
        _startup_bin=$OPT1_BIN
    else
        _startup_bin=$OPT2_BIN
    fi
    run_bounded required "cold-startup-opt$_startup_opt" \
        "$_startup_bin" --producer-identity
    _startup_peak=$BOUND_PEAK
    _startup_wall=$BOUND_WALL
    _startup_backend=$BOUND_BACKEND
    _startup_value=$(tr -d '\r\n' < "$WORKDIR/logs/cold-startup-opt$_startup_opt.stdout")
    [ "$_startup_value" = "$SOURCE_IDENTITY" ] ||
        fail "cold opt$_startup_opt startup returned unexpected identity: $_startup_value"
    append_measurement cold-startup shared "$_startup_opt" \
        "$_startup_peak" "$_startup_wall" - not-applicable 0 \
        "$RAW_BYTES" "$COMPRESSED_BYTES" 0 0 "$_startup_backend"
done
assertion_add cold-startup required pass "opt1 and opt2 identities exact"

NATIVE_CWD="$WORKDIR/native-cwd"
SOURCE_ROOT="$WORKDIR/source-root"
mkdir -p "$NATIVE_CWD" "$SOURCE_ROOT/stdlib"
for _stdlib_source in "$ROOT"/stdlib/*.tl; do
    {
        sed -n '1,$p' "$_stdlib_source"
        echo ';; embedded-tlci-resource-forced-source'
    } > "$SOURCE_ROOT/stdlib/$(basename "$_stdlib_source")"
done

FIXTURE="$WORKDIR/representative-expansion.tl"
{
    cat <<'EOF'
(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    (begin
      (set! (array-ref items 0) 7)
EOF
    _fixture_index=0
    while [ "$_fixture_index" -lt 512 ]; do
        case $((_fixture_index % 4)) in
            0) echo '      (__tl-box-place (box 7))' ;;
            1) echo '      (and true true)' ;;
            2) echo '      (or false true)' ;;
            3) echo '      (unless false unit)' ;;
        esac
        _fixture_index=$((_fixture_index + 1))
    done
    cat <<'EOF'
      (if (= (array-ref items 0) 7) 42 1))))
EOF
} > "$FIXTURE"

NATIVE_ASM="$WORKDIR/native.s"
SOURCE_ASM="$WORKDIR/source.s"
run_bounded required expansion-native \
    "$BASH_EXE" "$SCRIPT" --internal-expand "$OPT2_BIN" native \
    "$FIXTURE" "$NATIVE_ASM" "$NATIVE_CWD" "$SOURCE_ROOT"
NATIVE_PEAK=$BOUND_PEAK
NATIVE_WALL=$BOUND_WALL
NATIVE_BACKEND=$BOUND_BACKEND
require_output expansion-native "$NATIVE_ASM" || exit 1

run_bounded required expansion-source \
    "$BASH_EXE" "$SCRIPT" --internal-expand "$OPT2_BIN" source \
    "$FIXTURE" "$SOURCE_ASM" "$NATIVE_CWD" "$SOURCE_ROOT"
SOURCE_PEAK=$BOUND_PEAK
SOURCE_WALL=$BOUND_WALL
SOURCE_BACKEND=$BOUND_BACKEND
require_output expansion-source "$SOURCE_ASM" || exit 1
cmp -s "$NATIVE_ASM" "$SOURCE_ASM" || fail "native/source expansion assembly differs"

profile_sum() {
    _profile_name=$1
    _profile_file=$2
    awk -F'|' -v phase="typecheck.macro.$_profile_name" \
        '$1 == "compile-profile" && $2 == phase { total += $3 } END { print total + 0 }' \
        "$_profile_file"
}

NATIVE_DISPATCHES=$(profile_sum stdlib_tlci_native_dispatches "$WORKDIR/logs/expansion-native.stderr")
NATIVE_FALLBACKS=$(profile_sum stdlib_tlci_interpreted_fallbacks "$WORKDIR/logs/expansion-native.stderr")
SOURCE_DISPATCHES=$(profile_sum stdlib_tlci_native_dispatches "$WORKDIR/logs/expansion-source.stderr")
SOURCE_INTERPRETED=$(profile_sum stdlib_source_interpreted "$WORKDIR/logs/expansion-source.stderr")
[ "$NATIVE_DISPATCHES" -gt 0 ] || fail "native expansion route counter is vacuous"
[ "$NATIVE_FALLBACKS" -eq 0 ] || fail "native expansion used $NATIVE_FALLBACKS interpreted fallback(s)"
[ "$SOURCE_DISPATCHES" -eq 0 ] || fail "forced-source expansion used $SOURCE_DISPATCHES native dispatch(es)"
[ "$SOURCE_INTERPRETED" -gt 0 ] || fail "forced-source expansion counter is vacuous"

NATIVE_INSTRUCTIONS=-
SOURCE_INSTRUCTIONS=-
INSTRUCTION_SOURCE=unavailable
if [ "$NL_HOST_OS" = linux ] && command -v valgrind >/dev/null 2>&1; then
    metadata_add "$METADATA" valgrind "$(valgrind --version | sed -n '1p')"
    NATIVE_CACHEGRIND="$WORKDIR/native.cachegrind"
    SOURCE_CACHEGRIND="$WORKDIR/source.cachegrind"
    run_bounded required expansion-native-instructions \
        "$BASH_EXE" "$SCRIPT" --internal-instructions "$OPT2_BIN" native \
        "$FIXTURE" "$WORKDIR/native.instructions.s" "$NATIVE_CWD" "$SOURCE_ROOT" \
        "$NATIVE_CACHEGRIND" "$WORKDIR/native.valgrind.log"
    run_bounded required expansion-source-instructions \
        "$BASH_EXE" "$SCRIPT" --internal-instructions "$OPT2_BIN" source \
        "$FIXTURE" "$WORKDIR/source.instructions.s" "$NATIVE_CWD" "$SOURCE_ROOT" \
        "$SOURCE_CACHEGRIND" "$WORKDIR/source.valgrind.log"
    for _instruction_output in \
        "$NATIVE_CACHEGRIND" "$SOURCE_CACHEGRIND" \
        "$WORKDIR/native.instructions.s" "$WORKDIR/source.instructions.s"; do
        require_output expansion-instructions "$_instruction_output" || exit 1
    done
    cmp -s "$NATIVE_ASM" "$WORKDIR/native.instructions.s" ||
        fail "Cachegrind changed native expansion output"
    cmp -s "$SOURCE_ASM" "$WORKDIR/source.instructions.s" ||
        fail "Cachegrind changed source expansion output"
    NATIVE_INSTRUCTIONS=$(awk '$1 == "summary:" { print $2; exit }' "$NATIVE_CACHEGRIND")
    SOURCE_INSTRUCTIONS=$(awk '$1 == "summary:" { print $2; exit }' "$SOURCE_CACHEGRIND")
    for _instruction_count in "$NATIVE_INSTRUCTIONS" "$SOURCE_INSTRUCTIONS"; do
        case "$_instruction_count" in
            "" | *[!0-9]* | 0) fail "Cachegrind emitted malformed instruction count: $_instruction_count" ;;
        esac
    done
    INSTRUCTION_SOURCE=cachegrind
else
    metadata_add "$METADATA" valgrind unavailable
fi

append_measurement representative-expansion native 2 \
    "$NATIVE_PEAK" "$NATIVE_WALL" "$NATIVE_INSTRUCTIONS" "$INSTRUCTION_SOURCE" \
    "$(file_bytes "$NATIVE_ASM")" "$RAW_BYTES" "$COMPRESSED_BYTES" \
    "$NATIVE_DISPATCHES" 0 "$NATIVE_BACKEND"
append_measurement representative-expansion forced-source 2 \
    "$SOURCE_PEAK" "$SOURCE_WALL" "$SOURCE_INSTRUCTIONS" "$INSTRUCTION_SOURCE" \
    "$(file_bytes "$SOURCE_ASM")" "$RAW_BYTES" "$COMPRESSED_BYTES" \
    0 "$SOURCE_INTERPRETED" "$SOURCE_BACKEND"

assertion_add expansion-output-parity required pass "assembly byte-identical"
assertion_add native-route-counter required pass "dispatches=$NATIVE_DISPATCHES fallbacks=$NATIVE_FALLBACKS"
assertion_add source-route-counter required pass "native-dispatches=$SOURCE_DISPATCHES interpreted=$SOURCE_INTERPRETED"
if [ "$INSTRUCTION_SOURCE" = cachegrind ]; then
    assertion_add expansion-instructions informational pass \
        "native=$NATIVE_INSTRUCTIONS source=$SOURCE_INSTRUCTIONS source=cachegrind"
else
    assertion_add expansion-instructions informational unavailable \
        "runner-owned instruction source unavailable or failed"
fi

if [ "$OPT1_PEAK" -le 314572800 ]; then _opt1_goal=met; else _opt1_goal=above; fi
if [ "$OPT2_PEAK" -le 629145600 ]; then _opt2_goal=met; else _opt2_goal=above; fi
assertion_add opt1-300mib-long-term-goal informational "$_opt1_goal" "peak=$OPT1_PEAK goal=314572800"
assertion_add opt2-600mib-long-term-goal informational "$_opt2_goal" "peak=$OPT2_PEAK goal=629145600"

cat > "$WORKDIR/reproduce.txt" <<EOF
source_identity=$SOURCE_IDENTITY
compiler=$COMPILER
command=TYPELISP_BIN=$COMPILER scripts/verify-embedded-stdlib-tlci-resources.sh
memory_limit_mib=$CAP_MIB
timeout_seconds=$TIMEOUT_SECONDS
EOF

echo "[embedded-tlci-resources] required assertions passed under ${CAP_MIB} MiB cap"
echo "[embedded-tlci-resources] opt1 build: peak=$OPT1_PEAK bytes wall=${OPT1_WALL}ms compiler=$OPT1_BYTES bytes"
echo "[embedded-tlci-resources] opt2 build: peak=$OPT2_PEAK bytes wall=${OPT2_WALL}ms compiler=$OPT2_BYTES bytes"
echo "[embedded-tlci-resources] image: raw=$RAW_BYTES bytes compressed=$COMPRESSED_BYTES bytes"
echo "[embedded-tlci-resources] expansion native/source: peak=$NATIVE_PEAK/$SOURCE_PEAK bytes wall=$NATIVE_WALL/${SOURCE_WALL}ms instructions=$NATIVE_INSTRUCTIONS/$SOURCE_INSTRUCTIONS"
echo "[embedded-tlci-resources] report: $REPORT"
