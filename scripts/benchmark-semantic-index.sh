#!/usr/bin/env sh
set -eu

# Opt-in compiler-scale owned semantic-index benchmark.
#
# The selected compiler builds a small runner from the current checkout. Only
# the runner's index workload is measured, under run-memory-bounded.sh's
# fail-closed process-tree cap. No compiler is downloaded implicitly.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

WORKLOAD=owned-semantic-index
INPUT=src/compiler_typecheck_core.tl
DEFAULT_REPORT=target/semantic-index-benchmark/report.kv

usage() {
    cat >&2 <<'EOF'
usage: scripts/benchmark-semantic-index.sh --compiler PATH [options]
       scripts/benchmark-semantic-index.sh --self-test

Options:
  --compiler PATH       Existing TypeLisp compiler used to build the runner
  --limit-mib N         Process-tree memory cap in MiB (default 8192)
  --timeout-seconds N   Workload timeout in seconds (default 1800)
  --report PATH         Stable key/value report (default target/semantic-index-benchmark/report.kv)
  --self-test           Exercise report and bounded-termination behavior only

TYPELISP_BIN may provide --compiler. The script never downloads a compiler.
EOF
}

host_name() {
    case "$(uname -s)" in
        Linux*) printf '%s\n' linux ;;
        MINGW* | MSYS* | CYGWIN*) printf '%s\n' windows ;;
        *) printf '%s\n' unsupported ;;
    esac
}

report_field() {
    _report_file=$1
    _report_key=$2
    sed -n "s/^${_report_key}=//p" "$_report_file"
}

bounded_report_valid() {
    _bounded_report=$1
    [ -s "$_bounded_report" ] || return 1
    awk -F= '
        BEGIN {
            want["schema_version"] = 1
            want["host"] = 1
            want["backend"] = 1
            want["reason"] = 1
            want["exit_code"] = 1
            want["limit_bytes"] = 1
            want["peak_memory_bytes"] = 1
            want["wall_ms"] = 1
        }
        index($0, "=") == 0 { bad = 1; next }
        {
            key = $1
            if (!(key in want) || seen[key]++) bad = 1
        }
        END {
            for (key in want) if (!seen[key]) bad = 1
            if (NR != 8) bad = 1
            exit bad
        }
    ' "$_bounded_report" || return 1

    _schema=$(report_field "$_bounded_report" schema_version)
    _host=$(report_field "$_bounded_report" host)
    _backend=$(report_field "$_bounded_report" backend)
    _reason=$(report_field "$_bounded_report" reason)
    _exit_code=$(report_field "$_bounded_report" exit_code)
    _limit_bytes=$(report_field "$_bounded_report" limit_bytes)
    _peak_memory_bytes=$(report_field "$_bounded_report" peak_memory_bytes)
    _wall_ms=$(report_field "$_bounded_report" wall_ms)

    [ "$_schema" = 1 ] || return 1
    case "$_host" in linux | windows) ;; *) return 1 ;; esac
    case "$_backend" in '' | *[!A-Za-z0-9._-]*) return 1 ;; esac
    case "$_reason" in
        success | timeout | memory-limit | command-failure | wrapper-failure) ;;
        *) return 1 ;;
    esac
    case "$_exit_code" in '' | *[!0-9]*) return 1 ;; esac
    case "$_limit_bytes" in '' | *[!0-9]*) return 1 ;; esac
    case "$_peak_memory_bytes" in '' | *[!0-9]*) return 1 ;; esac
    case "$_wall_ms" in '' | *[!0-9]*) return 1 ;; esac
    [ "$_limit_bytes" -gt 0 ] || return 1
    case "$_reason:$_exit_code" in
        success:0 | timeout:124 | memory-limit:137 | wrapper-failure:2) ;;
        command-failure:0) return 1 ;;
        command-failure:*) ;;
        *) return 1 ;;
    esac
}

write_report() {
    _final_report=$1
    _semantic_record_count=$2
    _host=$3
    _backend=$4
    _reason=$5
    _exit_code=$6
    _limit_bytes=$7
    _peak_memory_bytes=$8
    _wall_ms=$9
    _report_tmp="$_final_report.tmp"
    mkdir -p "$(dirname -- "$_final_report")"
    rm -f "$_report_tmp"
    cat > "$_report_tmp" <<EOF
schema_version=1
workload=$WORKLOAD
input=$INPUT
semantic_record_count=$_semantic_record_count
host=$_host
backend=$_backend
reason=$_reason
exit_code=$_exit_code
limit_bytes=$_limit_bytes
peak_memory_bytes=$_peak_memory_bytes
wall_ms=$_wall_ms
EOF
    mv "$_report_tmp" "$_final_report"
}

write_setup_failure_report() {
    _final_report=$1
    _limit_mib=$2
    _host=$(host_name)
    case "$_host" in linux | windows) ;; *) _host=unsupported ;; esac
    write_report \
        "$_final_report" unavailable "$_host" unavailable wrapper-failure 2 \
        "$((_limit_mib * 1024 * 1024))" 0 0
}

compose_bounded_report() {
    _bounded_report=$1
    _runner_stdout=$2
    _final_report=$3
    _bounded_status=$4
    _limit_mib=$5

    if ! bounded_report_valid "$_bounded_report"; then
        write_setup_failure_report "$_final_report" "$_limit_mib"
        return 2
    fi

    _host=$(report_field "$_bounded_report" host)
    _backend=$(report_field "$_bounded_report" backend)
    _reason=$(report_field "$_bounded_report" reason)
    _exit_code=$(report_field "$_bounded_report" exit_code)
    _limit_bytes=$(report_field "$_bounded_report" limit_bytes)
    _peak_memory_bytes=$(report_field "$_bounded_report" peak_memory_bytes)
    _wall_ms=$(report_field "$_bounded_report" wall_ms)
    _semantic_record_count=unavailable

    if [ "$_exit_code" -ne "$_bounded_status" ]; then
        _reason=wrapper-failure
        _exit_code=2
    elif [ "$_reason" = success ]; then
        _count_rows=$(sed -n '/^semantic_record_count=/p' "$_runner_stdout" | tr -d '\r')
        _count_row_count=$(printf '%s\n' "$_count_rows" | sed '/^$/d' | wc -l | tr -d ' ')
        _semantic_record_count=$(printf '%s\n' "$_count_rows" | sed -n 's/^semantic_record_count=//p')
        case "$_count_row_count:$_semantic_record_count" in
            1:[1-9] | 1:[1-9][0-9]*) ;;
            *)
                _semantic_record_count=unavailable
                _reason=wrapper-failure
                _exit_code=2
                ;;
        esac
        if [ "$_reason" = success ] \
            && [ "$(sed -n '/^semantic_record_count=/!p' "$_runner_stdout" | wc -c | tr -d ' ')" -ne 0 ]; then
            _semantic_record_count=unavailable
            _reason=wrapper-failure
            _exit_code=2
        fi
    fi

    write_report \
        "$_final_report" \
        "$_semantic_record_count" \
        "$_host" \
        "$_backend" \
        "$_reason" \
        "$_exit_code" \
        "$_limit_bytes" \
        "$_peak_memory_bytes" \
        "$_wall_ms"
    return "$_exit_code"
}

run_bounded_workload() {
    _final_report=$1
    _limit_mib=$2
    _timeout_seconds=$3
    shift 3
    _bounded_report="$_final_report.bounded"
    _runner_stdout="$_final_report.stdout"
    _runner_stderr="$_final_report.stderr"
    mkdir -p "$(dirname -- "$_final_report")"
    rm -f \
        "$_final_report" \
        "$_final_report.tmp" \
        "$_bounded_report" \
        "$_bounded_report.time" \
        "$_bounded_report.memory" \
        "$_runner_stdout" \
        "$_runner_stderr"

    _bounded_status=0
    "$ROOT/scripts/run-memory-bounded.sh" \
        --limit-mib "$_limit_mib" \
        --timeout-seconds "$_timeout_seconds" \
        --report "$_bounded_report" \
        --working-directory "$ROOT" \
        -- "$@" \
        > "$_runner_stdout" \
        2> "$_runner_stderr" || _bounded_status=$?

    _final_status=0
    compose_bounded_report \
        "$_bounded_report" \
        "$_runner_stdout" \
        "$_final_report" \
        "$_bounded_status" \
        "$_limit_mib" || _final_status=$?
    return "$_final_status"
}

assert_report() {
    _assert_report=$1
    _assert_reason=$2
    _assert_status=$3
    _assert_count=$4
    [ "$(wc -l < "$_assert_report" | tr -d ' ')" -eq 11 ] || {
        echo "semantic-index benchmark self-test: report field count mismatch" >&2
        return 1
    }
    [ "$(report_field "$_assert_report" schema_version)" = 1 ]
    [ "$(report_field "$_assert_report" workload)" = "$WORKLOAD" ]
    [ "$(report_field "$_assert_report" input)" = "$INPUT" ]
    [ "$(report_field "$_assert_report" semantic_record_count)" = "$_assert_count" ]
    [ "$(report_field "$_assert_report" reason)" = "$_assert_reason" ]
    [ "$(report_field "$_assert_report" exit_code)" = "$_assert_status" ]
}

self_test() {
    _self_host=$(host_name)
    case "$_self_host" in
        linux | windows) ;;
        *)
            echo "semantic-index benchmark self-test unsupported on $(uname -s)" >&2
            return 1
            ;;
    esac
    _self_dir="$ROOT/target/semantic-index-benchmark-self-test"
    rm -rf "$_self_dir"
    mkdir -p "$_self_dir"

    _malformed_status=0
    sh "$ROOT/scripts/benchmark-semantic-index.sh" --limit-mib nope \
        > "$_self_dir/malformed.stdout" \
        2> "$_self_dir/malformed.stderr" || _malformed_status=$?
    [ "$_malformed_status" -eq 2 ] || {
        echo "semantic-index benchmark self-test: malformed invocation returned $_malformed_status" >&2
        return 1
    }

    _success_report="$_self_dir/replaced.kv"
    printf '%s\n' stale > "$_success_report"
    printf '%s\n' stale > "$_success_report.bounded"
    printf '%s\n' stale > "$_success_report.stdout"
    printf '%s\n' stale > "$_success_report.stderr"
    if [ "$_self_host" = linux ]; then
        run_bounded_workload "$_success_report" 128 30 \
            sh -c 'printf "%s\n" semantic_record_count=17; sleep 0.2'
    else
        run_bounded_workload "$_success_report" 256 30 \
            powershell.exe -NoProfile -Command \
            'Write-Output semantic_record_count=17; exit 0'
    fi
    assert_report "$_success_report" success 0 17
    if grep -R -F stale "$_success_report"* >/dev/null 2>&1; then
        echo "semantic-index benchmark self-test: stale report artifacts survived" >&2
        return 1
    fi

    if [ "$_self_host" = linux ]; then
        run_bounded_workload "$_success_report" 128 30 \
            sh -c 'printf "%s\n" semantic_record_count=19; sleep 0.2'
    else
        run_bounded_workload "$_success_report" 256 30 \
            powershell.exe -NoProfile -Command \
            'Write-Output semantic_record_count=19; exit 0'
    fi
    assert_report "$_success_report" success 0 19
    if grep -F 'semantic_record_count=17' "$_success_report" >/dev/null 2>&1; then
        echo "semantic-index benchmark self-test: replacement retained old record count" >&2
        return 1
    fi

    _output_report="$_self_dir/malformed-output.kv"
    _output_status=0
    if [ "$_self_host" = linux ]; then
        run_bounded_workload "$_output_report" 128 30 \
            sh -c 'printf "%s\n" not-a-record-count; sleep 0.2' \
            || _output_status=$?
    else
        run_bounded_workload "$_output_report" 256 30 \
            powershell.exe -NoProfile -Command \
            'Write-Output not-a-record-count; exit 0' \
            || _output_status=$?
    fi
    [ "$_output_status" -eq 2 ]
    assert_report "$_output_report" wrapper-failure 2 unavailable

    _failure_report="$_self_dir/command-failure.kv"
    _failure_status=0
    if [ "$_self_host" = linux ]; then
        run_bounded_workload "$_failure_report" 128 30 \
            sh -c 'sleep 0.2; exit 23' || _failure_status=$?
    else
        run_bounded_workload "$_failure_report" 256 30 \
            powershell.exe -NoProfile -Command \
            'Start-Sleep -Milliseconds 200; exit 23' || _failure_status=$?
    fi
    [ "$_failure_status" -eq 23 ]
    assert_report "$_failure_report" command-failure 23 unavailable

    _timeout_report="$_self_dir/timeout.kv"
    _timeout_status=0
    if [ "$_self_host" = linux ]; then
        run_bounded_workload "$_timeout_report" 128 1 sh -c 'sleep 30' \
            || _timeout_status=$?
    else
        run_bounded_workload "$_timeout_report" 256 1 \
            powershell.exe -NoProfile -Command 'Start-Sleep -Seconds 30' \
            || _timeout_status=$?
    fi
    [ "$_timeout_status" -eq 124 ]
    assert_report "$_timeout_report" timeout 124 unavailable

    _memory_report="$_self_dir/memory.kv"
    _memory_status=0
    if [ "$_self_host" = linux ]; then
        run_bounded_workload "$_memory_report" 32 30 sh -c \
            'awk '\''BEGIN { chunk = sprintf("%1048576s", "x"); for (i = 0; i < 96; i++) values[i] = chunk i; system("sleep 30") }'\''' \
            || _memory_status=$?
    else
        run_bounded_workload "$_memory_report" 96 30 \
            powershell.exe -NoProfile -Command \
            '$chunks=@(); while($true){$x=New-Object byte[] (8MB); for($i=0;$i-lt$x.Length;$i+=4096){$x[$i]=1}; $chunks+=$x}' \
            || _memory_status=$?
    fi
    [ "$_memory_status" -eq 137 ]
    assert_report "$_memory_report" memory-limit 137 unavailable
    [ "$(report_field "$_memory_report" peak_memory_bytes)" -gt 0 ]

    _wrapper_report="$_self_dir/wrapper.kv"
    _wrapper_status=0
    run_bounded_workload "$_wrapper_report" 128 30 \
        "$_self_dir/missing-command" || _wrapper_status=$?
    [ "$_wrapper_status" -eq 2 ]
    assert_report "$_wrapper_report" wrapper-failure 2 unavailable

    echo "semantic-index benchmark report/termination self-tests passed ($_self_host)"
}

COMPILER=${TYPELISP_BIN:-}
LIMIT_MIB=8192
TIMEOUT_SECONDS=1800
REPORT=$DEFAULT_REPORT
SELF_TEST=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --compiler)
            [ "$#" -ge 2 ] || { usage; exit 2; }
            COMPILER=$2
            shift 2
            ;;
        --limit-mib)
            [ "$#" -ge 2 ] || { usage; exit 2; }
            LIMIT_MIB=$2
            shift 2
            ;;
        --timeout-seconds)
            [ "$#" -ge 2 ] || { usage; exit 2; }
            TIMEOUT_SECONDS=$2
            shift 2
            ;;
        --report)
            [ "$#" -ge 2 ] || { usage; exit 2; }
            REPORT=$2
            shift 2
            ;;
        --self-test)
            SELF_TEST=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

case "$LIMIT_MIB" in
    '' | *[!0-9]* | 0)
        echo "semantic-index benchmark limit must be a positive MiB count: $LIMIT_MIB" >&2
        exit 2
        ;;
esac
case "$TIMEOUT_SECONDS" in
    '' | *[!0-9]* | 0)
        echo "semantic-index benchmark timeout must be a positive second count: $TIMEOUT_SECONDS" >&2
        exit 2
        ;;
esac

if [ "$SELF_TEST" -eq 1 ]; then
    self_test
    exit 0
fi

case "$REPORT" in
    /* | [A-Za-z]:[/\\]*) ;;
    *) REPORT="$ROOT/$REPORT" ;;
esac

if [ -z "$COMPILER" ]; then
    echo "semantic-index benchmark requires --compiler PATH or TYPELISP_BIN" >&2
    write_setup_failure_report "$REPORT" "$LIMIT_MIB"
    cat "$REPORT"
    exit 2
fi
case "$COMPILER" in
    /* | [A-Za-z]:[/\\]*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac
if [ ! -x "$COMPILER" ] && [ ! -f "$COMPILER" ]; then
    echo "semantic-index benchmark compiler is unavailable: $COMPILER" >&2
    write_setup_failure_report "$REPORT" "$LIMIT_MIB"
    cat "$REPORT"
    exit 2
fi
if [ ! -f "$ROOT/$INPUT" ]; then
    echo "semantic-index benchmark input is unavailable: $INPUT" >&2
    write_setup_failure_report "$REPORT" "$LIMIT_MIB"
    cat "$REPORT"
    exit 2
fi

_host=$(host_name)
case "$_host" in
    linux) _exe= ;;
    windows) _exe=.exe ;;
    *)
        echo "semantic-index benchmark unsupported on $(uname -s)" >&2
        write_setup_failure_report "$REPORT" "$LIMIT_MIB"
        cat "$REPORT"
        exit 2
        ;;
esac

WORKDIR="$ROOT/target/semantic-index-benchmark"
RUNNER="$WORKDIR/semantic-index-bench$_exe"
BUILD_STDOUT="$WORKDIR/build.stdout"
BUILD_STDERR="$WORKDIR/build.stderr"
mkdir -p "$WORKDIR"
rm -f "$RUNNER" "$BUILD_STDOUT" "$BUILD_STDERR"

echo "[semantic-index-bench] build runner with $COMPILER" >&2
if ! "$COMPILER" build tools/semantic-index-bench/main.tl \
    -o "$RUNNER" \
    --opt-level 2 \
    --stdlib-root "$ROOT/stdlib" \
    --stdlib-root "$ROOT/src" \
    > "$BUILD_STDOUT" \
    2> "$BUILD_STDERR"; then
    echo "semantic-index benchmark runner build failed; see $BUILD_STDERR" >&2
    write_setup_failure_report "$REPORT" "$LIMIT_MIB"
    cat "$REPORT"
    exit 2
fi
if [ ! -x "$RUNNER" ] && [ ! -f "$RUNNER" ]; then
    echo "semantic-index benchmark runner build produced no executable: $RUNNER" >&2
    write_setup_failure_report "$REPORT" "$LIMIT_MIB"
    cat "$REPORT"
    exit 2
fi

echo "[semantic-index-bench] run $INPUT cap=${LIMIT_MIB}MiB timeout=${TIMEOUT_SECONDS}s" >&2
STATUS=0
run_bounded_workload \
    "$REPORT" \
    "$LIMIT_MIB" \
    "$TIMEOUT_SECONDS" \
    "$RUNNER" \
    "$INPUT" \
    "$ROOT/stdlib" \
    "$ROOT/src" || STATUS=$?
cat "$REPORT"
if [ "$STATUS" -ne 0 ]; then
    echo "[semantic-index-bench] workload did not complete; see $REPORT.stderr" >&2
fi
exit "$STATUS"
