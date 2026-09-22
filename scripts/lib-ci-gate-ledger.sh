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
        NR == 1 { if ($0 != "# ci-gate-ledger-schema\t2") fail("expected schema version 2"); next }
        NR >= 2 && NR <= 4 {
            expected=(NR == 2 ? "all" : (NR == 3 ? "linux" : "windows"))
            if (NF != 3 || $1 != "# count" || $2 != expected || $3 !~ /^[1-9][0-9]*$/)
                fail("expected positive " expected " count")
            counts[expected]=$3
            next
        }
        NR == 5 { if ($0 != "id\thosts\tlabel\tneeds") fail("expected id/hosts/label/needs header"); next }
        {
            if (NF != 4 || $1 !~ /^[a-z][a-z0-9]*(-[a-z0-9]+)*$/)
                fail("expected four fields and a lowercase kebab-case ID")
            if ($2 != "all" && $2 != "linux" && $2 != "windows") fail("invalid host applicability")
            if ($3 == "" || $3 ~ /[[:cntrl:]]/ || $3 ~ /^ / || $3 ~ / $/) fail("invalid display label")
            if (ids[$1]++) fail("duplicate gate ID: " $1)
            if (labels[$3]++) fail("duplicate display label: " $3)
            total++
            if ($2 == "all" || $2 == "linux") linux++
            if ($2 == "all" || $2 == "windows") windows++
            # A need names an earlier gate whose published artifact or state this
            # gate consumes, optionally on one host only (`id@host`). `*` marks
            # the closing gate, which needs every gate that ran before it. The
            # ledger order is therefore a topological order by construction.
            gate_hosts[$1]=$2
            projected=""
            if ($4 == "") fail("empty needs field; write - for a gate that needs nothing: " $1)
            if ($4 == "*") {
                if (closing != "") fail("only the final gate may need every other gate: " closing)
                closing=$1
                closing_line=NR
                projected="*"
            } else if ($4 != "-") {
                need_count=split($4, need_list, ",")
                for (n=1; n<=need_count; n++) {
                    need=need_list[n]
                    need_host=""
                    at=index(need, "@")
                    if (at > 0) {
                        need_host=substr(need, at + 1)
                        need=substr(need, 1, at - 1)
                        if (need_host != "linux" && need_host != "windows") fail("invalid need host: " need_list[n])
                        if ($2 != "all" && $2 != need_host) fail("need host does not apply to gate " $1 ": " need_list[n])
                    }
                    if (need !~ /^[a-z][a-z0-9]*(-[a-z0-9]+)*$/) fail("invalid need: " need_list[n])
                    if (!(need in gate_hosts) || need == $1) fail("need must name an earlier gate: " $1 " needs " need)
                    if (seen_need[$1 SUBSEP need]++) fail("duplicate need: " $1 " needs " need)
                    producer=gate_hosts[need]
                    covered=(need_host != "" ? need_host : $2)
                    if (producer != "all" && producer != covered)
                        fail("needed gate does not run on the same hosts: " $1 " needs " need)
                    if (need_host == "" || need_host == host)
                        projected=(projected == "" ? need : projected "," need)
                }
            } else {
                projected="-"
            }
            if (projected == "") projected="-"
            if ($2 == "all" || $2 == host) output=output $1 "\t" $2 "\t" $3 "\t" projected "\n"
        }
        END {
            if (invalid) exit 1
            if (NR < 6 || total != counts["all"] || linux != counts["linux"] || windows != counts["windows"])
                fail("catalog counts do not match complete records")
            if (closing != "" && closing_line != NR) fail("only the final gate may need every other gate: " closing)
            # Without a closing gate nothing waits for the whole run, so a
            # scheduler reading this column could report completeness early.
            if (closing == "") fail("the final gate must need every other gate (*)")
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
    _ci_ledger_fields=${_ci_ledger_fields#*"$CI_GATE_LEDGER_TAB"}
    CI_GATE_LEDGER_LABEL=${_ci_ledger_fields%%"$CI_GATE_LEDGER_TAB"*}
    CI_GATE_LEDGER_NEEDS=${_ci_ledger_fields#*"$CI_GATE_LEDGER_TAB"}
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

# The needs column must describe the runner and the compiler-artifact inventory,
# not an independent opinion. Three rules, each checked in both directions:
#   1. Every gate after the converged-compiler producer needs it, because
#      `run_with_compiler` exports that compiler to every later gate; no earlier
#      gate needs anything, and no earlier binding names a produced compiler.
#   2. A gate needs another gate's artifact exactly when the inventory has a
#      consume record whose reuse group is produced by that other gate, on the
#      hosts of that record.
#   3. Only the closing gate needs every gate.
# Run in a subshell so validation cannot reset an active execution plan.
ci_gate_ledger_validate_needs() (
    _ci_needs_catalog=$1
    _ci_needs_source=$2
    _ci_needs_inventory=$3
    _ci_needs_compiler_gate=$4
    ci_gate_ledger_load "$_ci_needs_catalog" linux || exit 1
    [ -s "$_ci_needs_source" ] || { ci_gate_ledger_error "missing execution source: $_ci_needs_source"; exit 1; }
    [ -s "$_ci_needs_inventory" ] || { ci_gate_ledger_error "missing artifact inventory: $_ci_needs_inventory"; exit 1; }
    awk -F '\t' -v compiler_gate="$_ci_needs_compiler_gate" '
        function fail(message) {
            print "CI gate ledger: " message > "/dev/stderr"
            invalid=1
        }
        function declare(gate, need, need_host,    key) {
            key=gate SUBSEP need SUBSEP need_host
            declared[key]=1
        }
        function has_need(gate, need, need_host) {
            return ((gate SUBSEP need SUBSEP "") in declared) ||
                (need_host != "all" && ((gate SUBSEP need SUBSEP need_host) in declared))
        }
        { sub(/\r$/, "", $0) }
        FILENAME == ARGV[1] {
            if (FNR <= 5) next
            order[$1]=++gates
            id_of[$3]=$1
            needs_of[$1]=$4
            if ($4 == "-" || $4 == "*") next
            count=split($4, list, ",")
            for (n=1; n<=count; n++) {
                need=list[n]
                need_host=""
                at=index(need, "@")
                if (at > 0) { need_host=substr(need, at + 1); need=substr(need, 1, at - 1) }
                declare($1, need, need_host)
                if (need != compiler_gate) artifact_need[$1 SUBSEP need SUBSEP need_host]=1
            }
            next
        }
        FILENAME == ARGV[2] {
            line=continued $0
            if (line ~ /\\$/) { sub(/\\$/, "", line); continued=line " "; next }
            continued=""
            sub(/^[ \t]+/, "", line)
            if (line !~ /^(run_gate|run_with_compiler)[ \t]+/ || line == "run_gate \"$@\"") next
            split(line, words, /[ \t]+/)
            id=words[words[1] == "run_gate" ? 2 : 3]
            if (line ~ /\$\{?(STAGE2_BIN|COMPILE_PROFILE_BIN)/) uses_compiler[id]=1
            next
        }
        {
            if (FNR <= 2) next
            if ($5 == "produce") { if ($13 != "none") producer_label[$13]=$3; next }
            if ($5 == "consume") { consumers++; consume_label[consumers]=$3; consume_host[consumers]=$4; consume_group[consumers]=$13 }
        }
        END {
            if (!(compiler_gate in order)) fail("unknown converged-compiler gate: " compiler_gate)
            for (id in order) {
                if (order[id] <= order[compiler_gate]) {
                    if (needs_of[id] != "-") fail("gate runs before the converged compiler exists but declares needs: " id)
                    if (uses_compiler[id]) fail("binding names a produced compiler before it exists: " id)
                } else if (needs_of[id] != "*" && !has_need(id, compiler_gate, "all")) {
                    fail("gate runs with the converged compiler but does not need " compiler_gate ": " id)
                }
            }
            for (c=1; c<=consumers; c++) {
                group=consume_group[c]
                if (!(group in producer_label)) { fail("inventory consumer has no producer record: " group); continue }
                consumer=id_of[consume_label[c]]
                producer=id_of[producer_label[group]]
                if (consumer == "" || producer == "") { fail("inventory gate is not in the ledger: " consume_label[c] " / " producer_label[group]); continue }
                if (consumer == producer || producer == compiler_gate) continue
                if (!has_need(consumer, producer, consume_host[c]))
                    fail("artifact consumer does not need its producer: " consumer " needs " producer " (" consume_host[c] ")")
                justified[consumer SUBSEP producer]=1
            }
            for (key in artifact_need) {
                split(key, parts, SUBSEP)
                if (!((parts[1] SUBSEP parts[2]) in justified))
                    fail("need has no artifact inventory record: " parts[1] " needs " parts[2])
            }
            if (invalid) exit 1
        }
    ' "$_ci_needs_catalog" "$_ci_needs_source" "$_ci_needs_inventory"
)
