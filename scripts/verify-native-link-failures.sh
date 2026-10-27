#!/usr/bin/env sh
set -eu

# Shell-only forwarding fixtures, also run by integration-batch-observability.
# Use the real helpers/timer with planted tool leaves, not a compiler build.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/scripts/lib-native-link.sh"
. "$ROOT/scripts/lib-ci-timing.sh"
nl_real_tr=$(command -v tr)
nl_root=${1:-"$ROOT/target/exp/native-link-failure-self-test"}
mkdir -p "$nl_root"
printf 'case\tplan\ttiming\twant\tstatus\ttrace\n' > "$nl_root/results.tsv"
: > "$nl_root/trace.tsv"

nl_step() {
    printf '%s\t%s\n' "$nl_case" "$1" >> "$nl_root/trace.tsv"
    [ "$nl_failure" != "$1" ] || return "${nl_step_status:-23}"
}
as() { nl_step assemble; }
nl_clang() { nl_step assemble; }
ld() { nl_step link; }
nl_linker() { nl_step link; }
linux_entry_symbol_for_asm() { nl_step entry || return $?; printf '%s\n' _tl_start; }
to_windows_path() {
    case "$1" in
        fixture.obj) nl_step object-path || return $? ;;
        fixture.exe) nl_step binary-path || return $? ;;
    esac
    printf '%s\n' "$1"
}
to_unix_path() { nl_step unix-path || return $?; printf '%s\n' "$1"; }
short_windows_path() { nl_step short-path || return $?; printf '%s\n' "$1"; }
echo() {
    case "$*" in
        *'assemble fixture'*) nl_step assemble-notice ;;
        *'link fixture'*) nl_step link-notice ;;
        *'windows linker='*) nl_step linker-notice ;;
        *'windows assembler='*) nl_step clang-notice ;;
        *) printf '%s\n' "$*" ;;
    esac
}
# Discovery probes succeed, then their actual output/status can be planted.
# No host tool or Windows installation participates in either host plan.
command() {
    [ "$1" = -v ] || return 1
    if [ "${nl_real_helpers:-0}" -eq 1 ]; then
        case "$2" in
            clang.exe | clang) return 1 ;;
            cygpath | powershell.exe) return 0 ;;
        esac
    fi
    case "$2" in
        as | ld) return 0 ;;
        clang.exe | lld-link)
            if [ "$nl_probed" -eq 0 ]; then nl_probed=1; return 0; fi
            # A failed command may still print a plausible path. Do not let
            # an empty-string check stand in for forwarding its exit status.
            nl_discovery_status=0
            nl_step discovery || nl_discovery_status=$?
            printf '%s\n' "$2"
            return "$nl_discovery_status"
            ;;
        *) return 1 ;;
    esac
}

nl_flow() {
    case "$nl_route" in
        assemble) assemble_and_link fixture fixture.s fixture.obj fixture.exe || return $? ;;
        object) link_native_object fixture fixture.obj fixture.exe || return $? ;;
        toolchain) configure_toolchain || return $? ;;
        clang) configure_windows_clang_env || return $? ;;
        linker) configure_windows_linker || return $? ;;
        find) find_clang || return $? ;;
        real-entry)
            NL_HOST_OS=linux
            assemble_and_link fixture fixture.s fixture.obj fixture.exe || return $?
            ;;
        short-output)
            short_windows_path fixture-clang >&- || return $?
            configure_windows_linker || return $?
            ;;
        short-control)
            nl_path=$(short_windows_path fixture-clang) || return $?
            [ "$nl_path" = "$nl_expected_path" ] || return 24
            ;;
        powershell)
            NL_HOST_OS=windows
            configure_toolchain || return $?
            ;;
    esac
    nl_step continued
}
nl_check() {
    nl_route=$1 nl_failure=$2 nl_expected=$3
    nl_case="$nl_plan-$nl_timing-$nl_route-$nl_failure${4:-}"
    nl_mode=${5:-normal}
    nl_step_status=${6:-23}
    nl_want=$nl_step_status
    [ "$nl_failure" != success ] || nl_want=0
    nl_probed=0
    NL_HOST_OS=$nl_plan
    TYPELISP_WINDOWS_CLANG=nl_clang
    TYPELISP_WINDOWS_LINK=nl_linker
    TYPELISP_WINDOWS_CLANG_POSIX=nl_clang
    TYPELISP_WINDOWS_LINK_POSIX=nl_linker
    case "$nl_route" in
        find | clang | powershell) TYPELISP_WINDOWS_CLANG= ;;
        linker) [ "$nl_failure" != discovery ] || TYPELISP_WINDOWS_LINK= ;;
    esac
    nl_rc=0
    if [ "${4:-}" = -errexit ]; then
        # A background child keeps ordinary set -e semantics; wait's status
        # capture cannot disable errexit inside it. Four real call-shape checks.
        (set -e; ci_timing_run "$nl_case" native-link \
            assemble_and_link fixture fixture.s fixture.obj fixture.exe; nl_step continued) \
            >> "$nl_root/stdout" 2>> "$nl_root/stderr" &
        nl_pid=$!
        wait "$nl_pid" || nl_rc=$?
    else
        # Deliberately ignore errexit in both timer modes: explicit forwarding
        # must remain correct even when an enclosing caller tests its status.
        if ci_timing_run "$nl_case" native-link nl_flow \
                >> "$nl_root/stdout" 2>> "$nl_root/stderr"; then
            nl_rc=0
        else
            nl_rc=$?
        fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$nl_case" "$nl_plan" \
        "$nl_timing" "$nl_want" "$nl_rc" "$nl_expected" >> "$nl_root/results.tsv"
}

for nl_plan in linux windows; do
    for nl_timing in 0 1; do
        TYPELISP_CI_TIMING=$nl_timing
        TYPELISP_CI_TIMING_GATE=native-link-failure-self-test
        ci_timing_init "$nl_root/timing-$nl_plan-$nl_timing.tsv" "$nl_plan"
        nl_prefix='assemble-notice assemble'
        nl_tail='link-notice link continued'
        if [ "$nl_plan" = windows ]; then
            nl_middle='object-path binary-path'
            nl_check assemble object-path "$nl_prefix object-path"
            nl_check assemble binary-path "$nl_prefix object-path binary-path"
            nl_check object object-path object-path
            nl_check object binary-path 'object-path binary-path'
            nl_check toolchain unix-path unix-path
            nl_check toolchain success 'unix-path unix-path linker-notice continued'
        else
            nl_middle=entry
            nl_check assemble entry "$nl_prefix entry"
            nl_check toolchain success continued
        fi
        nl_check assemble success "$nl_prefix $nl_middle $nl_tail"
        nl_check assemble assemble-notice assemble-notice
        nl_check assemble assemble "$nl_prefix"
        nl_check assemble assemble "$nl_prefix" -errexit
        nl_check assemble link-notice "$nl_prefix $nl_middle link-notice"
        nl_check assemble link "$nl_prefix $nl_middle link-notice link"
        nl_object_prefix=
        [ "$nl_plan" != windows ] || nl_object_prefix='object-path binary-path '
        nl_check object success "$nl_object_prefix$nl_tail"
        nl_check object link "${nl_object_prefix}link-notice link"
        # Sibling setup helpers run regardless of the physical host.
        nl_check linker unix-path unix-path
        nl_check linker linker-notice 'unix-path linker-notice'
        nl_check linker discovery discovery
        nl_check clang discovery discovery
        nl_check clang short-path 'discovery short-path'
        nl_check clang success 'discovery short-path clang-notice continued'
        nl_check find discovery discovery
        if [ "$nl_timing" -eq 0 ] && [ -e "$nl_root/timing-$nl_plan-0.tsv" ]; then
            printf 'FAIL: timing-off native-link fixture wrote timing rows\n' >&2
            exit 1
        fi
    done
done

# Exercise the real entry, short-path and PowerShell helpers below the caller
# guards too. Only their file/tool leaves are planted. Explicit test -x in
# discovery makes its directory lookup leaf independent of installed Windows
# candidates; all other shell predicates keep their real builtin semantics.
. "$ROOT/scripts/lib-native-link.sh"
nl_real_helpers=1
test() { [ "$#" -eq 2 ] && [ "$1" = -x ] || return 2; return 1; }
grep() {
    case "$2" in
        '^_tl_start:$')
            nl_step entry-first || return $?
            [ "$nl_mode" = normal ]
            ;;
        '^_start:$')
            nl_step entry-second || return $?
            [ "$nl_mode" = legacy ]
            ;;
        *) return 2 ;;
    esac
}
ld() {
    nl_step link || return $?
    nl_expected_entry=_tl_start
    [ "$nl_mode" != legacy ] || nl_expected_entry=_start
    [ "$3" = "$nl_expected_entry" ]
}
cygpath() {
    case "$1" in
        -d)
            nl_step short-probe || return $?
            printf '%s\n' fixture-short
            [ "$nl_mode" != fallback ]
            ;;
        -w) nl_step windows-path || return $?; printf '%s\n' fixture-long ;;
        -u)
            nl_step unix-path || return $?
            case "$2" in fixture-clang | nl_linker) ;; *) return 24 ;; esac
            printf '%s\n' "$2"
            ;;
        *) return 2 ;;
    esac
}
powershell.exe() {
    nl_status=0
    nl_step powershell || nl_status=$?
    printf 'fixture-clang\r\nignored\r\n'
    return "$nl_status"
}
tr() {
    nl_status=0
    nl_step normalize || nl_status=$?
    if [ "$nl_status" -eq 0 ]; then
        "$nl_real_tr" "$@"
        return $?
    fi
    printf 'fixture-clang\nignored\n'
    return "$nl_status"
}
for nl_plan in linux windows; do
    for nl_timing in 0 1; do
        TYPELISP_CI_TIMING=$nl_timing
        TYPELISP_CI_TIMING_HOST=$nl_plan
        TYPELISP_CI_TIMING_FILE="$nl_root/timing-$nl_plan-$nl_timing.tsv"
        nl_prefix='assemble-notice assemble entry-first'
        nl_check real-entry entry-first "$nl_prefix" '' normal 2
        nl_check real-entry entry-second "$nl_prefix entry-second" '' legacy 2
        nl_check real-entry success "$nl_prefix link-notice link continued"
        nl_check real-entry success "$nl_prefix entry-second link-notice link continued" -legacy legacy
        nl_check real-entry success "$nl_prefix entry-second link-notice link continued" -fallback fallback
        nl_check short-output output short-probe '' normal 1
        nl_expected_path=fixture-short
        nl_check short-control success 'short-probe continued'
        nl_expected_path=fixture-long
        nl_check short-control success 'short-probe windows-path continued' -fallback fallback
        nl_check powershell powershell powershell
        nl_check powershell normalize 'powershell normalize'
        nl_check powershell success 'powershell normalize unix-path short-probe clang-notice unix-path linker-notice continued'
    done
done

# One assertion process for all cases/traces/rows, rather than cmp/grep/awk
# per case (expensive on Windows). Exact inventories reject missing work too.
awk -F '\t' '
    FILENAME == ARGV[1] {
        if (FNR == 1) next
        if (want[$1]++ || $4 != $5) {
            print "FAIL: native-link fixture " $1 ": expected status " $4 " got " $5 > "/dev/stderr"
            bad = 1
        }
        status[$1] = $4; timing[$1] = $3; plan[$1] = $2; expected[$1] = $6
        cases++
        next
    }
    FILENAME == ARGV[2] {
        actual[$1] = actual[$1] (actual[$1] == "" ? "" : " ") $2
        if (!($1 in want)) bad = 1
        next
    }
    FNR == 1 { if ($0 != "gate\tcase_or_chunk\tphase\telapsed_ms\texit\thost") bad = 1; next }
    {
        if (NF != 6 || $1 != "native-link-failure-self-test" || !($2 in want) ||
            timing[$2] != 1 || $3 != "native-link" || $4 !~ /^[0-9]+$/ ||
            $5 != status[$2] || $6 != plan[$2] || rows[$2]++) bad = 1
    }
    END {
        if (cases != 120) bad = 1
        for (id in want) {
            if (actual[id] != expected[id] || rows[id] != timing[id]) {
                print "FAIL: native-link fixture " id ": expected [" expected[id] "] got [" actual[id] "]" > "/dev/stderr"
                bad = 1
            }
        }
        if (bad) { print "FAIL: native-link status/trace/timing integrity" > "/dev/stderr"; exit 1 }
        printf "native-link failure self-test passed (%d host/timing/control cases)\n", cases
    }
' "$nl_root/results.tsv" "$nl_root/trace.tsv" "$nl_root/timing-linux-1.tsv" "$nl_root/timing-windows-1.tsv"
