#!/usr/bin/env sh

# Shared opt-in timing rows for the serial CI verification flow.
#
# Callers set TYPELISP_CI_TIMING=1 and initialize one artifact with
# ci_timing_init. Child gates inherit TYPELISP_CI_TIMING_FILE,
# TYPELISP_CI_TIMING_HOST, and TYPELISP_CI_TIMING_GATE, then append compact
# rows through ci_timing_run/ci_timing_record_elapsed. Labels are deliberately
# caller-provided metadata; command lines and source contents are never stored.

ci_timing_enabled() {
    [ "${TYPELISP_CI_TIMING:-0}" = 1 ] && [ -n "${TYPELISP_CI_TIMING_FILE:-}" ]
}

ci_timing_set_now_ms() {
    if [ -r /proc/uptime ]; then
        # Linux and Git Bash expose monotonic uptime with two fractional
        # digits. Parse it with shell builtins so each detailed row does not
        # pay for two helper-process launches.
        IFS=' ' read -r _ci_timing_uptime _ci_timing_idle < /proc/uptime
        _ci_timing_seconds=${_ci_timing_uptime%.*}
        _ci_timing_centis=${_ci_timing_uptime#*.}
        _ci_timing_centis=${_ci_timing_centis#0}
        [ -n "$_ci_timing_centis" ] || _ci_timing_centis=0
        CI_TIMING_NOW_MS=$((_ci_timing_seconds * 1000 + _ci_timing_centis * 10))
        return
    fi
    if command -v perl >/dev/null 2>&1; then
        CI_TIMING_NOW_MS=$(perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e \
            'printf "%.0f\n", clock_gettime(CLOCK_MONOTONIC) * 1000')
        return
    fi
    if command -v powershell.exe >/dev/null 2>&1; then
        CI_TIMING_NOW_MS=$(powershell.exe -NoProfile -Command \
            '[Environment]::TickCount64' | tr -d '\r')
        return
    fi
    echo "TYPELISP_CI_TIMING=1 requires a monotonic clock (perl Time::HiRes, /proc/uptime, or PowerShell TickCount64)" >&2
    return 1
}

ci_timing_now_ms() {
    ci_timing_set_now_ms
    printf '%s\n' "$CI_TIMING_NOW_MS"
}

ci_timing_init() {
    _ci_timing_file=$1
    _ci_timing_host=$2
    TYPELISP_CI_TIMING_FILE=$_ci_timing_file
    TYPELISP_CI_TIMING_HOST=$_ci_timing_host
    export TYPELISP_CI_TIMING_FILE TYPELISP_CI_TIMING_HOST

    if ! ci_timing_enabled; then
        return 0
    fi
    ci_timing_now_ms >/dev/null
    mkdir -p "$(dirname -- "$TYPELISP_CI_TIMING_FILE")"
    printf 'gate\tcase_or_chunk\tphase\telapsed_ms\texit\thost\n' \
        > "$TYPELISP_CI_TIMING_FILE"
}

ci_timing_metadata_valid() {
    case "$1" in
        *'	'* | *'
'*) return 1 ;;
        *) return 0 ;;
    esac
}

ci_timing_record_elapsed() {
    _ci_timing_case=$1
    _ci_timing_phase=$2
    _ci_timing_elapsed=$3
    _ci_timing_exit=$4
    if ! ci_timing_enabled; then
        return 0
    fi
    _ci_timing_gate=${TYPELISP_CI_TIMING_GATE:-ungated}
    _ci_timing_host=${TYPELISP_CI_TIMING_HOST:-unknown}
    ci_timing_metadata_valid "$_ci_timing_gate" || return 2
    ci_timing_metadata_valid "$_ci_timing_case" || return 2
    ci_timing_metadata_valid "$_ci_timing_phase" || return 2
    ci_timing_metadata_valid "$_ci_timing_host" || return 2
    case "$_ci_timing_elapsed" in
        "" | *[!0-9]*) return 2 ;;
    esac
    case "$_ci_timing_exit" in
        "" | *[!0-9-]*) return 2 ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$_ci_timing_gate" \
        "$_ci_timing_case" \
        "$_ci_timing_phase" \
        "$_ci_timing_elapsed" \
        "$_ci_timing_exit" \
        "$_ci_timing_host" >> "$TYPELISP_CI_TIMING_FILE"
}

ci_timing_run() {
    _ci_timing_case=$1
    _ci_timing_phase=$2
    shift 2
    if ! ci_timing_enabled; then
        "$@"
        return $?
    fi

    ci_timing_set_now_ms
    _ci_timing_started=$CI_TIMING_NOW_MS
    case $- in
        *e*) _ci_timing_had_errexit=1 ;;
        *) _ci_timing_had_errexit=0 ;;
    esac
    set +e
    "$@"
    _ci_timing_status=$?
    if [ "$_ci_timing_had_errexit" -eq 1 ]; then
        set -e
    fi
    ci_timing_set_now_ms
    _ci_timing_finished=$CI_TIMING_NOW_MS
    _ci_timing_elapsed=$((_ci_timing_finished - _ci_timing_started))
    ci_timing_record_elapsed \
        "$_ci_timing_case" \
        "$_ci_timing_phase" \
        "$_ci_timing_elapsed" \
        "$_ci_timing_status"
    return "$_ci_timing_status"
}

ci_timing_summary() {
    _ci_timing_summary_file=${1:-${TYPELISP_CI_TIMING_FILE:-}}
    _ci_timing_top_n=${2:-10}
    if [ -z "$_ci_timing_summary_file" ] || [ ! -s "$_ci_timing_summary_file" ]; then
        return 0
    fi

    echo
    echo "[ci-timing] aggregate phase totals (top 8):"
    awk -F '\t' 'NR > 1 { total[$3] += $4; count[$3] += 1 }
        END { for (phase in total) printf "%s\t%.0f\t%d\n", phase, total[phase], count[phase] }' \
        "$_ci_timing_summary_file" \
        | sort -t "$(printf '\t')" -k2,2nr \
        | sed -n '1,8{s/^/[ci-timing]   /; p;}' || true
    echo "[ci-timing] slowest ${_ci_timing_top_n} rows:"
    awk -F '\t' 'NR > 1 { print }' "$_ci_timing_summary_file" \
        | sort -t "$(printf '\t')" -k4,4nr \
        | sed -n "1,${_ci_timing_top_n}{s/^/[ci-timing]   /; p;}" || true
    _ci_timing_rows=$(awk 'END { print (NR > 0 ? NR - 1 : 0) }' "$_ci_timing_summary_file")
    echo "[ci-timing] artifact=$_ci_timing_summary_file rows=$_ci_timing_rows"
}
