# lib-retry.sh — shared POSIX-sh run helper for CI verify-* scripts.
#
# HISTORY / POLICY (#1204): these helpers used to retry a `typelisp` invocation
# up to 6 times when it crashed (segfault / Windows access violation), on the
# theory that #1204 crashes are "transient" infra flake. They are not. The
# crashes are a real compiler memory-safety bug — an access violation reading a
# small integer as a pointer (see target/dumps minidumps: all 0xC0000005 reads
# of a near-null pointer at a stable instruction). Retrying masked that bug and
# let it accumulate behind green CI runs for months.
#
# The retry has been removed: every verify-* gate now defaults to a single
# attempt (VERIFY_*_ATTEMPTS=1), so a #1204 crash fails CI loudly and forces a
# root-cause fix instead of being hidden. The ATTEMPTS knob and the helpers
# below are kept only as an explicit, opt-in local override (set the env var
# >1); CI must run with the default of 1.
#
# Source it (not exec): `. "$ROOT/scripts/lib-retry.sh"`. POSIX sh only — no
# `local`, arrays, or bashisms.

# run_with_retry OUT_FILE ERR_FILE ATTEMPTS CMD...
#   Run CMD up to ATTEMPTS times, sending stdout->OUT_FILE and stderr->ERR_FILE.
#   Returns 0 as soon as an attempt exits 0; otherwise returns the last attempt's
#   non-zero exit code after exhausting ATTEMPTS. Retries log to stderr.
#   NOTE: callers pass ATTEMPTS=1 by default (no retry) — see the policy note
#   above. ATTEMPTS>1 is a deliberate, opt-in local override only.
run_with_retry() {
    _rwr_out=$1
    _rwr_err=$2
    _rwr_attempts=$3
    shift 3
    _rwr_i=0
    _rwr_rc=0
    while [ "$_rwr_i" -lt "$_rwr_attempts" ]; do
        _rwr_i=$((_rwr_i + 1))
        # `if cmd; then ... else _rc=$?; fi` captures the command's real exit code
        # (in the else branch `$?` is the failed command's status) and is
        # `set -e`-safe (a command in an if-condition does not abort the script).
        if "$@" > "$_rwr_out" 2> "$_rwr_err"; then
            _rwr_rc=0
        else
            _rwr_rc=$?
        fi
        if [ "$_rwr_rc" -eq 0 ]; then
            return 0
        fi
        if [ "$_rwr_i" -lt "$_rwr_attempts" ]; then
            echo "  retry ($_rwr_i/$_rwr_attempts): exit $_rwr_rc — likely transient (#1204)" >&2
        fi
    done
    return "$_rwr_rc"
}

# is_crash_code CODE
#   True when CODE is a crash/signal exit — the shape of the #1204 segfault.
#   As reported by bash/MSYS (128 + signal): SIGILL=132, SIGABRT=134,
#   SIGSEGV=139. On Windows a native-exe crash is captured by PowerShell as the
#   raw NTSTATUS exit code (e.g. verify-integration.sh's run_windows_program
#   records the program's ExitCode), so the crash surfaces as 0xC0000005 access
#   violation (-1073741819, or 3221225477 unsigned) or 0xC000001D illegal
#   instruction (-1073741795, or 3221225501 unsigned) rather than a 128+signal
#   value.
#   Retained for the opt-in ATTEMPTS>1 override; with the default ATTEMPTS=1 the
#   crash-gated retry loops in the verify-* scripts run exactly once.
is_crash_code() {
    case "$1" in
        132 | 134 | 139) return 0 ;;
        -1073741819 | 3221225477) return 0 ;;
        -1073741795 | 3221225501) return 0 ;;
        *) return 1 ;;
    esac
}
