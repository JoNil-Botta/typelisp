#!/usr/bin/env sh
# Required full-run gate metadata and sequential completion state. This library
# performs no I/O until called; listing must not initialize a compiler or trace.

ci_gate_ledger_error() {
    echo "CI gate ledger: $*" >&2
    return 1
}

ci_gate_ledger_load() {
    CI_GATE_LEDGER_LOADED=0
    CI_GATE_LEDGER_ACTIVE=
    CI_GATE_LEDGER_FAILED=1
    _ci_ledger_file=$1
    _ci_ledger_host=$2
    case "$_ci_ledger_host" in
        linux|windows) ;;
        *) ci_gate_ledger_error "unsupported host: $_ci_ledger_host (expected linux or windows)"; return 1 ;;
    esac
    if [ ! -s "$_ci_ledger_file" ]; then
        ci_gate_ledger_error "missing or empty catalog: $_ci_ledger_file"
        return 1
    fi
    if [ "$(tail -c 1 "$_ci_ledger_file" | od -An -tx1 | tr -d ' \n')" != 0a ]; then
        ci_gate_ledger_error "catalog must end with a newline: $_ci_ledger_file"
        return 1
    fi
    # Buffer the projection until every record/count is validated. A malformed
    # record for the other host must also fail without partial listing output.
    CI_GATE_LEDGER_ROWS=$(awk -F '\t' -v host="$_ci_ledger_host" '
        function fail(message) {
            print "CI gate ledger: line " NR ": " message > "/dev/stderr"
            invalid=1
            exit 1
        }
        { sub(/\r$/, "", $0) }
        NR == 1 { if ($0 != "# ci-gate-ledger-schema\t1") fail("expected schema version 1"); next }
        NR >= 2 && NR <= 4 {
            expected=(NR == 2 ? "all" : (NR == 3 ? "linux" : "windows"))
            if (NF != 3 || $1 != "# count" || $2 != expected || $3 !~ /^[1-9][0-9]*$/)
                fail("expected positive " expected " count")
            counts[expected]=$3
            next
        }
        NR == 5 { if ($0 != "id\thosts\tlabel") fail("expected id/hosts/label header"); next }
        {
            if (NF != 3 || $1 !~ /^[a-z][a-z0-9]*(-[a-z0-9]+)*$/)
                fail("expected three fields and a lowercase kebab-case ID")
            if ($2 != "all" && $2 != "linux" && $2 != "windows") fail("invalid host applicability")
            if ($3 == "" || $3 ~ /[[:cntrl:]]/ || $3 ~ /^ / || $3 ~ / $/) fail("invalid display label")
            if (ids[$1]++) fail("duplicate gate ID: " $1)
            if (labels[$3]++) fail("duplicate display label: " $3)
            total++
            if ($2 == "all" || $2 == "linux") linux++
            if ($2 == "all" || $2 == "windows") windows++
            if ($2 == "all" || $2 == host) output=output $0 "\n"
        }
        END {
            if (invalid) exit 1
            if (NR < 6 || total != counts["all"] || linux != counts["linux"] || windows != counts["windows"])
                fail("catalog counts do not match complete records")
            printf "%s", output
        }
    ' "$_ci_ledger_file") || return 1
    CI_GATE_LEDGER_TAB=$(printf '\t')
    CI_GATE_LEDGER_NEWLINE='
'
    CI_GATE_LEDGER_REMAINING=$CI_GATE_LEDGER_ROWS
    CI_GATE_LEDGER_ACTIVE=
    CI_GATE_LEDGER_FAILED=0
    CI_GATE_LEDGER_LOADED=1
}

ci_gate_ledger_enter() {
    if [ "${CI_GATE_LEDGER_LOADED:-0}" != 1 ] || [ "${CI_GATE_LEDGER_FAILED:-0}" != 0 ]; then
        ci_gate_ledger_error "catalog is not loaded or an earlier gate failed"
        return 1
    fi
    if [ -n "$CI_GATE_LEDGER_ACTIVE" ]; then
        CI_GATE_LEDGER_FAILED=1
        ci_gate_ledger_error "gate has not completed: $CI_GATE_LEDGER_ACTIVE"
        return 1
    fi
    _ci_ledger_row=${CI_GATE_LEDGER_REMAINING%%"$CI_GATE_LEDGER_NEWLINE"*}
    _ci_ledger_expected=${_ci_ledger_row%%"$CI_GATE_LEDGER_TAB"*}
    if [ -z "$_ci_ledger_expected" ] || [ "$1" != "$_ci_ledger_expected" ]; then
        CI_GATE_LEDGER_FAILED=1
        ci_gate_ledger_error "unexpected gate $1; expected ${_ci_ledger_expected:-end of inventory} (missing, duplicate, out-of-order or wrong-host gate)"
        return 1
    fi
    _ci_ledger_fields=${_ci_ledger_row#*"$CI_GATE_LEDGER_TAB"}
    CI_GATE_LEDGER_LABEL=${_ci_ledger_fields#*"$CI_GATE_LEDGER_TAB"}
    CI_GATE_LEDGER_ACTIVE=$1
}

ci_gate_ledger_leave() {
    if [ -z "${CI_GATE_LEDGER_ACTIVE:-}" ]; then
        CI_GATE_LEDGER_FAILED=1
        ci_gate_ledger_error "completion without an active gate"
        return 1
    fi
    case "$1" in
        0) ;;
        *) CI_GATE_LEDGER_FAILED=1; return "$1" ;;
    esac
    case "$CI_GATE_LEDGER_REMAINING" in
        *"$CI_GATE_LEDGER_NEWLINE"*) CI_GATE_LEDGER_REMAINING=${CI_GATE_LEDGER_REMAINING#*"$CI_GATE_LEDGER_NEWLINE"} ;;
        *) CI_GATE_LEDGER_REMAINING= ;;
    esac
    CI_GATE_LEDGER_ACTIVE=
}

ci_gate_ledger_finish() {
    if [ "${CI_GATE_LEDGER_LOADED:-0}" != 1 ] ||
        [ "${CI_GATE_LEDGER_FAILED:-0}" != 0 ] ||
        [ -n "${CI_GATE_LEDGER_ACTIVE:-}" ] ||
        [ -n "${CI_GATE_LEDGER_REMAINING:-}" ]; then
        ci_gate_ledger_error "required inventory is incomplete or failed; verification cannot succeed"
        return 1
    fi
}

# Gate bindings deliberately use literal IDs, one command per logical line.
# This is a check of that narrow convention, not a general shell interpreter.
# Run in a subshell so validation cannot reset an active execution plan.
ci_gate_ledger_validate_bindings() (
    _ci_binding_catalog=$1
    _ci_binding_source=$2
    ci_gate_ledger_load "$_ci_binding_catalog" linux || exit 1
    awk -F '\t' '
        function fail(message) {
            print "CI gate ledger: " message > "/dev/stderr"
            invalid=1
        }
        { sub(/\r$/, "", $0) }
        FNR == NR {
            if (FNR > 5) ids[$1]=1
            next
        }
        {
            line=continued $0
            if (line ~ /\\$/) {
                sub(/\\$/, "", line)
                continued=line " "
                next
            }
            continued=""
            sub(/^[ \t]+/, "", line)
            if (line !~ /^(run_gate|run_with_compiler)[ \t]+/) next
            if (line == "run_gate \"$@\"") next
            count=split(line, words, /[ \t]+/)
            position=(words[1] == "run_gate" ? 2 : 3)
            id=words[position]
            if (!(id in ids)) fail("unknown or nonliteral execution binding: " id)
            else if (count <= position) fail("execution binding has no command: " id)
            else bound[id]++
        }
        END {
            if (continued != "") fail("unterminated execution source continuation")
            for (id in ids) if (!bound[id]) fail("missing execution binding: " id)
            if (invalid) exit 1
        }
    ' "$_ci_binding_catalog" "$_ci_binding_source"
)
