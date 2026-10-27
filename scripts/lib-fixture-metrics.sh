# Opt-in diagnostics for process-heavy shell gates. Clocks use the ordinary
# ci-timing artifact. Tool starts count direct external dispatches from this
# instrumented shell (including pipelines/substitutions), not shell subshells
# or descendants internal to git/jq/etc. No extra process wraps a tool.
. "${FIXTURE_METRICS_TOOLS:?}/lib-ci-timing.sh"

fixture_metrics_init() {
    ci_timing_enabled || return 0
    FIXTURE_METRICS_STARTS=$1/tool-starts
    : > "$FIXTURE_METRICS_STARTS"
    # Only wrap installed tools: command -v must retain its missing-tool verdict.
    for _fm_tool in awk basename bash cat chmod cmp cp cut dirname env find git grep head jq ln mkdir mktemp mv paste rm rmdir sed sh sort tail tr uname wc; do
        if command -v "$_fm_tool" >/dev/null 2>&1; then
            eval "$_fm_tool() { printf '%s\\n' $_fm_tool >> \"\$FIXTURE_METRICS_STARTS\"; command $_fm_tool \"\$@\"; }"
        fi
    done
    if [ -r /proc/cpuinfo ]; then
        _fm_cpu=$(command awk -F ': *' '/^model name/ { print $2; exit }' /proc/cpuinfo)
    elif command -v pwsh >/dev/null 2>&1; then
        _fm_cpu=$(pwsh -NoProfile -Command '(Get-CimInstance Win32_Processor).Name' | command tr -d '\r')
    else
        _fm_cpu=${PROCESSOR_IDENTIFIER:-unknown}
    fi
    printf '[fixture-metrics] cpu=%s; child scope=direct instrumented-shell tool starts; excludes shell subshells and tool-internal descendants\n' "$_fm_cpu" >&2
}

fixture_metrics_run() {
    if ! ci_timing_enabled; then
        shift
        "$@"
        return
    fi
    # Positional parameters isolate nested calls and the fixture's globals.
    ci_timing_set_now_ms
    set -- "$CI_TIMING_NOW_MS" "$(command wc -l < "$FIXTURE_METRICS_STARTS")" "$@"
    printf '[fixture-metrics] group=%s child-cpu-before (shell times: self user/sys; children user/sys):\n' "$3" >&2
    times >&2
    fixture_metrics_command "$@"
    set -- "$?" "$@"
    ci_timing_set_now_ms
    ci_timing_record_elapsed "$4" fixture-group "$((CI_TIMING_NOW_MS - $2))" "$1"
    printf '[fixture-metrics] group=%s child-process-starts=%s child-cpu-after:\n' "$4" \
        "$(( $(command wc -l < "$FIXTURE_METRICS_STARTS") - $3 ))" >&2
    times >&2
    return "$1"
}

fixture_metrics_command() {
    shift 3
    "$@"
}
