# Opt-in diagnostics for process-heavy shell gates. Clocks use the ordinary
# ci-timing artifact. Tool starts count direct external dispatches from this
# instrumented shell (including pipelines/substitutions), not shell subshells
# or descendants internal to git/jq/etc. No extra wrapper executable is launched,
# but a shell may fork for a function in a pipeline or command substitution.
. "${FIXTURE_METRICS_TOOLS:?}/lib-ci-timing.sh"

fixture_metrics_init() {
    ci_timing_enabled || return 0
    FIXTURE_METRICS_STARTS=$1/tool-starts
    : > "$FIXTURE_METRICS_STARTS"
    # Only wrap installed tools: command -v must retain its missing-tool verdict.
    for _fm_tool in awk basename bash cat chmod cmp cp cut date dirname env find gh git grep head jq ln mkdir mktemp mv paste perl pwsh rm rmdir sed sh sha256sum sleep sort tail tr uname unzip valgrind wc; do
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

# A separate shell keeps the control's forced instrumentation and counters out
# of the surrounding gate. Exercise a pipeline inside a command substitution:
# printf is builtin, while sha256sum and cut must each contribute one start.
fixture_metrics_self_test() (
    TYPELISP_CI_TIMING=1
    TYPELISP_CI_TIMING_FILE=$1/timing.tsv
    fixture_metrics_init "$1"
    _fm_before=$(command wc -l < "$FIXTURE_METRICS_STARTS")
    _fm_hash=$(printf 'fixture\n' | sha256sum | cut -c1-64)
    _fm_after=$(command wc -l < "$FIXTURE_METRICS_STARTS")
    [ "${#_fm_hash}" -eq 64 ] || exit 1
    [ "$((_fm_after - _fm_before))" -eq 2 ] || exit 1
    _fm_before=$_fm_after
    _fm_text=$(printf 'fixture\n' | cat)
    _fm_after=$(command wc -l < "$FIXTURE_METRICS_STARTS")
    [ "$_fm_text" = fixture ] || exit 1
    [ "$((_fm_after - _fm_before))" -eq 1 ] || exit 1
)

fixture_metrics_disabled_self_test() (
    TYPELISP_CI_TIMING=0
    _fm_definition=$(command -V awk)
    fixture_metrics_init "$1"
    [ "$(command -V awk)" = "$_fm_definition" ] || exit 1
    [ ! -e "$1/tool-starts" ] || exit 1
)

# A bounded matched launch sample measures the counter's incremental overhead
# on each CI host. Both paths launch the same tools; command bypasses the
# function wrappers. These rows are a sample, not a full-gate overhead estimate.
fixture_metrics_launch_sample() {
    for _fm_iteration in 1 2 3 4 5 6 7 8; do
        case "$1" in
            direct) _fm_text=$(command awk 'BEGIN { print "fixture" }' | command cat) ;;
            counted) _fm_text=$(awk 'BEGIN { print "fixture" }' | cat) ;;
        esac
        [ "$_fm_text" = fixture ] || return 1
    done
}

fixture_metrics_overhead_sample() {
    ci_timing_enabled || return 0
    for _fm_repeat in 1 2 3; do
        fixture_metrics_run "counter-bypassed-$_fm_repeat" fixture_metrics_launch_sample direct
        fixture_metrics_run "counter-wrapped-$_fm_repeat" fixture_metrics_launch_sample counted
    done
}
