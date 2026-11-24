#!/usr/bin/env sh
# lib-ci-gates.sh - POSIX helpers for CI fragment-directory tables:
#   - scripts/ci-gates.d/<id>.tsv (unified gate, lane, and input-class metadata)
#   - scripts/ci-affected-paths.d/*.tsv (reviewed path-to-gate mapping fragments)
#
# Sourced by ci-verify.sh, ci-lane.sh, ci-affected.sh, test-ci-affected.sh,
# lib-ci-compiler-artifact.sh, and verify-ci-compiler-artifacts.sh.
# File lists stream over stdin into a single awk process so Windows MSYS2
# never spawns per-file subshells or hits ARG_MAX.

# ci_tsv_list_dir DIR LABEL
# Validate DIR and print each DIR/*.tsv regular file in LC_ALL=C sorted order.
# Atomic on error: emits nothing to stdout if any entry is invalid or DIR is empty.
ci_tsv_list_dir() {
    _ct_dir=${1:-}
    _ct_label=${2:-tsv-dir}
    if [ -z "$_ct_dir" ]; then
        echo "${_ct_label}: directory argument required" >&2
        return 1
    fi
    case "$_ct_dir" in
        /) ;;
        */) _ct_dir=${_ct_dir%/} ;;
    esac
    if [ ! -d "$_ct_dir" ] || [ -L "$_ct_dir" ]; then
        echo "${_ct_label}: directory does not exist or is a symlink: $_ct_dir" >&2
        return 1
    fi
    _ct_entries=$(find "$_ct_dir" -print | LC_ALL=C sort) || return 1
    _ct_count=0
    while IFS= read -r _ct_entry; do
        [ -n "$_ct_entry" ] || continue
        [ "$_ct_entry" != "$_ct_dir" ] || continue
        _ct_rel=${_ct_entry#"$_ct_dir"/}
        case "$_ct_rel" in
            */*)
                echo "${_ct_label}: directory $_ct_dir contains nested entry: $_ct_rel" >&2
                return 1
                ;;
            .*)
                echo "${_ct_label}: directory $_ct_dir contains hidden entry: $_ct_rel" >&2
                return 1
                ;;
            *.tsv) ;;
            *)
                echo "${_ct_label}: directory $_ct_dir contains unexpected non-.tsv entry: $_ct_rel" >&2
                return 1
                ;;
        esac
        if [ ! -f "$_ct_entry" ] || [ -L "$_ct_entry" ]; then
            echo "${_ct_label}: directory $_ct_dir contains non-regular entry: $_ct_rel" >&2
            return 1
        fi
        _ct_count=$((_ct_count + 1))
    done <<EOF
$_ct_entries
EOF
    if [ "$_ct_count" -eq 0 ]; then
        echo "${_ct_label}: directory is empty (no *.tsv files): $_ct_dir" >&2
        return 1
    fi
    while IFS= read -r _ct_entry; do
        [ -n "$_ct_entry" ] || continue
        [ "$_ct_entry" != "$_ct_dir" ] || continue
        printf '%s\n' "$_ct_entry"
    done <<EOF
$_ct_entries
EOF
}

ci_gates_list_dir() {
    ci_tsv_list_dir "${1:-}" "ci-gates.d"
}

ci_affected_paths_list_dir() {
    ci_tsv_list_dir "${1:-}" "ci-affected-paths.d"
}

# ci_gates_load DIR
# Validate all DIR/*.tsv gate fragments, check cross-gate needs, compiler-need
# rules, lanes, input classes, and cycle freedom, then emit all validated 13-col
# gate rows (without header) in deterministic Kahn topological order
# (priority desc, id asc).
ci_gates_load() {
    _cg_dir=${1:-}
    _cg_files=$(ci_gates_list_dir "$_cg_dir") || return 1
    LC_ALL=C awk '
        function fail(message) {
            print "ci-gates.d: " message > "/dev/stderr"
            invalid = 1
            exit 1
        }
        BEGIN {
            expected_header = "id\tpriority\thosts\tlabel\tneeds\tcompiler\tmemory\tlocks\tcommand\tlinux_lane\twindows_lane\tinput_classes\tinput_reason"
            max_lanes = 2
        }
        {
            path = $0
            if (path == "") next
            base = path
            sub(/^.*\//, "", base)
            stem = base
            sub(/\.tsv$/, "", stem)
            header_seen = 0
            row_seen = 0
            lineno = 0
            while ((st = (getline line < path)) > 0) {
                lineno++
                sub(/\r$/, "", line)
                if (line ~ /^#/) continue
                if (!header_seen) {
                    if (line != expected_header)
                        fail(base ":" lineno ": expected 13-column gate header")
                    header_seen = 1
                    continue
                }
                row_seen++
                if (row_seen > 1)
                    fail(base ":" lineno ": expected exactly one gate row per file")
                nf = split(line, f, "\t")
                if (nf != 13)
                    fail(base ":" lineno ": expected 13 tab-separated fields, got " nf)
                id = f[1]
                prio = f[2]
                hosts = f[3]
                label = f[4]
                needs = f[5]
                compiler = f[6]
                memory = f[7]
                locks = f[8]
                command = f[9]
                linux_lane = f[10]
                windows_lane = f[11]
                input_classes = f[12]
                input_reason = f[13]

                if (id !~ /^[a-z][a-z0-9]*(-[a-z0-9]+)*$/)
                    fail(base ":" lineno ": invalid lowercase kebab-case gate ID: " id)
                if (id != stem)
                    fail(base ":" lineno ": filename stem (" stem ") does not match gate ID (" id ")")
                if (id in seen_id)
                    fail(base ":" lineno ": duplicate gate ID: " id)
                seen_id[id] = 1
                all_ids[++total] = id
                file_of[id] = base

                if (prio !~ /^(0|-?[1-9][0-9]*)$/)
                    fail(base ":" lineno ": invalid priority integer: " prio)
                if (hosts != "all" && hosts != "linux" && hosts != "windows")
                    fail(base ":" lineno ": invalid hosts: " hosts)
                if (label == "")
                    fail(base ":" lineno ": empty label")
                if (hosts == "all" || hosts == "linux") {
                    if (labels["linux", label]++)
                        fail(base ":" lineno ": duplicate linux gate label: " label)
                }
                if (hosts == "all" || hosts == "windows") {
                    if (labels["windows", label]++)
                        fail(base ":" lineno ": duplicate windows gate label: " label)
                }
                if (needs == "")
                    fail(base ":" lineno ": empty needs field")
                if (compiler != "-" && compiler != "stage2" && compiler != "profile")
                    fail(base ":" lineno ": invalid compiler: " compiler)
                if (memory !~ /^[1-9][0-9]*$/)
                    fail(base ":" lineno ": memory must be a positive MiB count: " memory)
                if (locks != "-" && locks !~ /^[a-z][a-z0-9-]*(,[a-z][a-z0-9-]*)*$/)
                    fail(base ":" lineno ": invalid locks: " locks)
                if (command == "")
                    fail(base ":" lineno ": empty command")

                # Validate linux_lane and windows_lane.
                for (h = 1; h <= 2; h++) {
                    host = (h == 1 ? "linux" : "windows")
                    cell = (h == 1 ? linux_lane : windows_lane)
                    runs = (hosts == "all" || hosts == host)
                    if (cell == "")
                        fail(base ":" lineno ": empty " host "_lane")
                    if (cell == "-") {
                        if (runs)
                            fail(base ":" lineno ": " id " runs on " host " but no lane owns it")
                        continue
                    }
                    if (!runs)
                        fail(base ":" lineno ": " id " does not run on " host ": " cell)
                    np = split(cell, part, "+")
                    for (k = 1; k <= np; k++) {
                        tok = part[k]
                        rep = 0
                        if (substr(tok, length(tok)) == "!") {
                            rep = 1
                            tok = substr(tok, 1, length(tok) - 1)
                        }
                        if (tok !~ ("^" host "-[1-9]$"))
                            fail(base ":" lineno ": invalid " host " lane: " part[k])
                        if (lane_used[id, host, tok]++)
                            fail(base ":" lineno ": " id " names lane " tok " twice")
                        if (k == 1) {
                            if (rep)
                                fail(base ":" lineno ": " id " marks its owning lane as a repeat")
                            lane_owns[host, tok] = 1
                        }
                        if (!((host, tok) in lane_seen)) {
                            lane_seen[host, tok] = 1
                            lane_count[host]++
                        }
                    }
                }

                # Validate input_classes and input_reason.
                if (input_classes == "" || input_reason == "")
                    fail(base ":" lineno ": empty input_classes or input_reason")
                if (input_classes != "-") {
                    nc = split(input_classes, cls, ",")
                    for (k = 1; k <= nc; k++) {
                        if (cls[k] !~ /^(compiler|stdlib|corpus|docs)$/)
                            fail(base ":" lineno ": unknown input class: " cls[k])
                        if (cls_seen[id, cls[k]]++)
                            fail(base ":" lineno ": duplicate input class: " cls[k])
                    }
                }
                if (compiler != "-" && (!cls_seen[id, "compiler"] || !cls_seen[id, "stdlib"] || !cls_seen[id, "corpus"]))
                    fail(base ":" lineno ": produced compiler consumer missing source class: " id)

                gate_prio[id] = prio + 0
                gate_hosts[id] = hosts
                gate_needs[id] = needs
                gate_compiler[id] = compiler
                gate_row[id] = line
            }
            if (st < 0)
                fail("failed to read " path)
            close(path)
            if (!header_seen)
                fail(base ": missing 13-column gate header")
            if (row_seen != 1)
                fail(base ": missing gate row")
        }
        END {
            if (invalid) exit 1
            if (total == 0) fail("no gate fragments loaded")

            for (h = 1; h <= 2; h++) {
                host = (h == 1 ? "linux" : "windows")
                if (lane_count[host] > max_lanes)
                    fail("more than " max_lanes " " host " lanes")
            }
            for (key in lane_seen) {
                split(key, lp, SUBSEP)
                if (!lane_owns[lp[1], lp[2]])
                    fail("lane " lp[2] " owns no gate")
            }

            # Validate needs graph and compiler-need rules.
            for (i = 1; i <= total; i++) {
                id = all_ids[i]
                base = file_of[id]
                if (gate_needs[id] != "-") {
                    nn = split(gate_needs[id], nlist, ",")
                    for (n = 1; n <= nn; n++) {
                        entry = nlist[n]
                        if (entry == "")
                            fail(base ": " id " has empty need entry")
                        need = entry
                        need_host = ""
                        at = index(need, "@")
                        if (at > 0) {
                            need_host = substr(need, at + 1)
                            need = substr(need, 1, at - 1)
                            if (need_host != "linux" && need_host != "windows")
                                fail(base ": invalid need host: " entry)
                            if (gate_hosts[id] != "all" && gate_hosts[id] != need_host)
                                fail(base ": " id " restricts need to non-matching host: " entry)
                        }
                        if (!(need in seen_id) || need == id)
                            fail(base ": " id " needs an unknown or self gate: " need)
                        if (need_edge_seen[id, entry]++)
                            fail(base ": " id " lists duplicate need: " entry)
                        covered = (need_host != "" ? need_host : gate_hosts[id])
                        if (gate_hosts[need] != "all" && gate_hosts[need] != covered)
                            fail(base ": " id " needs a gate that does not run on its hosts: " need)
                        if (need_host == "")
                            direct[id, need] = 1
                        if (!dag_edge[need, id]++) {
                            adj[need, ++adj_n[need]] = id
                            indeg[id]++
                        }
                    }
                }
                if (gate_compiler[id] == "stage2" && !direct[id, "bootstrap-compiler"])
                    fail(base ": " id " runs the stage2 compiler without needing bootstrap-compiler")
                if (gate_compiler[id] == "profile" && !direct[id, "stage2-compile-profile-verifier"])
                    fail(base ": " id " runs the profile compiler without needing stage2-compile-profile-verifier")
            }

            # Kahn topological sort ordered by (priority desc, id asc).
            for (step = 1; step <= total; step++) {
                best = ""
                for (i = 1; i <= total; i++) {
                    g = all_ids[i]
                    if (emitted[g] || indeg[g] + 0 != 0) continue
                    if (best == "" || gate_prio[g] > gate_prio[best] || (gate_prio[g] == gate_prio[best] && g < best))
                        best = g
                }
                if (best == "") {
                    cyc = ""
                    for (i = 1; i <= total; i++) {
                        g = all_ids[i]
                        if (!emitted[g]) cyc = (cyc == "" ? g : cyc ", " g)
                    }
                    fail("dependency cycle involving: " cyc)
                }
                emitted[best] = 1
                sorted[step] = best
                for (e = 1; e <= adj_n[best]; e++)
                    indeg[adj[best, e]]--
            }

            for (step = 1; step <= total; step++)
                print gate_row[sorted[step]]
        }
    ' <<EOF
$_cg_files
EOF
}

# ci_gates_plan_dir DIR HOST [ID,...]
# Validate the gate table, project onto HOST (linux|windows), and print the
# 8-column plan rows (id, hosts, label, projected needs, compiler, memory,
# locks, command), or only the requested gates plus their needs closure, in
# Kahn topological (priority desc, id asc) order.
ci_gates_plan_dir() {
    _cgp_dir=${1:-}
    _cgp_host=${2:-}
    _cgp_req=${3:-}
    _cgp_all=$(ci_gates_load "$_cgp_dir") || return 1
    LC_ALL=C awk -F '\t' -v host="$_cgp_host" -v request="$_cgp_req" '
        function fail(message) {
            print "ci-gates.d: " message > "/dev/stderr"
            invalid = 1
            exit 1
        }
        {
            id = $1
            hosts = $3
            label = $4
            needs_raw = $5
            compiler = $6
            memory = $7
            locks = $8
            command = $9
            gate_hosts[id] = hosts
            if (hosts != "all" && hosts != host) next
            projected = ""
            if (needs_raw != "-") {
                nn = split(needs_raw, nlist, ",")
                for (n = 1; n <= nn; n++) {
                    need = nlist[n]
                    need_host = ""
                    at = index(need, "@")
                    if (at > 0) {
                        need_host = substr(need, at + 1)
                        need = substr(need, 1, at - 1)
                    }
                    if (need_host == "" || need_host == host)
                        projected = (projected == "" ? need : projected "," need)
                }
            }
            rows++
            row[rows] = id "\t" hosts "\t" label "\t" (projected == "" ? "-" : projected) "\t" compiler "\t" memory "\t" locks "\t" command
            needs[rows] = projected
            position[id] = rows
        }
        END {
            if (invalid) exit 1
            if (!rows) fail("no gates for " host)
            if (request == "") {
                for (k = 1; k <= rows; k++) print row[k]
                exit 0
            }
            count = split(request, requested, ",")
            for (r = 1; r <= count; r++) {
                id = requested[r]
                if (id == "") fail("empty gate ID in selection: " request)
                if (seen[id]++) fail("duplicate gate in selection: " id)
                if (!(id in position)) {
                    if (id in gate_hosts) fail("gate does not run on " host " (" gate_hosts[id] "): " id)
                    fail("unknown gate in selection: " id)
                }
                selected[position[id]] = 1
            }
            # Loaded rows are topologically sorted, so one reverse pass closes needs.
            for (k = rows; k >= 1; k--) {
                if (!selected[k] || needs[k] == "") continue
                count = split(needs[k], list, ",")
                for (n = 1; n <= count; n++) selected[position[list[n]]] = 1
            }
            for (k = 1; k <= rows; k++) if (selected[k]) print row[k]
        }
    ' <<EOF
$_cgp_all
EOF
}

# ci_affected_paths_load DIR
# Validate all DIR/*.tsv affected-path fragments in a single awk process
# (exact header, 4 nonempty fields, no catch-all or bad paths, globally unique
# path across all fragments, standalone -/* markers, @always required) and
# emit the validated 4-column rows (without header).
ci_affected_paths_load() {
    _cap_dir=${1:-}
    _cap_files=$(ci_affected_paths_list_dir "$_cap_dir") || return 1
    LC_ALL=C awk '
        function fail(message) {
            print "ci-affected-paths.d: " message > "/dev/stderr"
            invalid = 1
            exit 1
        }
        BEGIN {
            expected_header = "path\trequired\tadvisory\treason"
        }
        {
            path = $0
            if (path == "") next
            base = path
            sub(/^.*\//, "", base)
            header_seen = 0
            file_rows = 0
            lineno = 0
            while ((st = (getline line < path)) > 0) {
                lineno++
                sub(/\r$/, "", line)
                if (line ~ /^#/) continue
                if (!header_seen) {
                    if (line != expected_header)
                        fail(base ":" lineno ": expected path/required/advisory/reason header")
                    header_seen = 1
                    continue
                }
                nf = split(line, f, "\t")
                if (nf != 4 || f[1] == "" || f[2] == "" || f[3] == "" || f[4] == "")
                    fail(base ":" lineno ": expected four nonempty fields")
                if (f[1] != "@always" && (f[1] !~ /^[A-Za-z0-9_.*\/-]+$/ || f[1] ~ /^\// || f[1] ~ /(^|\/)\.\.(\/|$)/ || f[1] ~ /^\*/))
                    fail(base ":" lineno ": invalid or catch-all path: " f[1])
                if (seen[f[1]]++)
                    fail(base ":" lineno ": duplicate path: " f[1])
                for (col = 2; col <= 3; col++) {
                    if (f[col] != "-" && f[col] != "*" && f[col] ~ /(^|,)(-|\*)(,|$)/)
                        fail(base ":" lineno ": empty/full marker must stand alone")
                }
                rows[++total] = line
                file_rows++
            }
            if (st < 0)
                fail("failed to read " path)
            close(path)
            if (!header_seen)
                fail(base ": missing path/required/advisory/reason header")
            if (file_rows == 0)
                fail(base ": contains no path rows")
        }
        END {
            if (invalid) exit 1
            if (!seen["@always"]) fail("missing @always hygiene row")
            for (i = 1; i <= total; i++) print rows[i]
        }
    ' <<EOF
$_cap_files
EOF
}
