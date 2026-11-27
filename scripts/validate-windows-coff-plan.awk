# Validate `compile --batch --windows-coff-plan` results against their inputs.
#
# Single-plan mode (default):
#   awk -f scripts/validate-windows-coff-plan.awk <batch-file> <plan-file>
# Multi-plan mode (`-v multi=1`):
#   awk -f scripts/validate-windows-coff-plan.awk -v multi=1 <plan-list-file>
#   where each non-empty line in <plan-list-file> is:
#     batch-file|plan-file[|label]
#
# Without `-v artifacts_out=...`, emits one normalized row per artifact:
#   source|kind|selected-path|reason|object-path|assembly-path|forced|archive
# where `archive` is `stdlib-archive` when the artifact links the sysroot
# libstdlib.a and `none` otherwise.
#
# With `-v artifacts_out=...`, additionally enforces validated case paths,
# per-case uniqueness across batches, on-disk artifact exclusivity, and forced
# assembly allow-listing, appending registered artifacts to `artifacts_out`,
# fallback reasons to `reasons_out`, and summary counts to `counts_out`.

function fail(message) {
    print message > "/dev/stderr"
    failed = 1
    exit 1
}

function file_nonempty(p,    rc, tmp) {
    rc = (getline tmp < p)
    close(p)
    return rc > 0
}

function file_exists(p,    rc, tmp) {
    rc = (getline tmp < p)
    close(p)
    return rc >= 0
}

function validate_pair(batch_file, plan_file, label,    prefix, src_in, obj_in, asm_in, frc_in, input_count, bline_no, brc, bline, bn, bf, plan_count, pline_no, prc, pline, pn, pf, psrc, pkind, psel, preason, parchive, pforced, tail, slash, cname, sel_abs, obj_abs, asm_abs) {
    prefix = (label != "" ? "FAIL: invalid Windows COFF result plan for batch " label ": " : "")

    input_count = 0
    bline_no = 0
    while ((brc = (getline bline < batch_file)) > 0) {
        bline_no++
        sub(/\r$/, "", bline)
        bn = split(bline, bf, "|")
        if (bn != 3 && bn != 4) {
            fail(prefix "Windows COFF batch input line " bline_no " must have 3 fields, or 4 with force-assembly")
        }
        if (bf[1] == "" || bf[2] == "" || bf[3] == "") {
            fail(prefix "Windows COFF batch input line " bline_no " has an empty required field")
        }
        if (bf[2] == bf[3]) {
            fail(prefix "Windows COFF batch input line " bline_no " reuses one path for object and assembly")
        }
        if (bn == 4 && bf[4] != "force-assembly") {
            fail(prefix "Windows COFF batch input line " bline_no " has an invalid fourth field: " bf[4])
        }

        input_count++
        src_in[input_count] = bf[1]
        obj_in[input_count] = bf[2]
        asm_in[input_count] = bf[3]
        frc_in[input_count] = (bn == 4 ? 1 : 0)
    }
    close(batch_file)
    if (brc < 0) {
        fail(prefix "Windows COFF batch input could not be read: " batch_file)
    }
    if (input_count == 0) {
        fail(prefix "Windows COFF batch input is empty")
    }

    plan_count = 0
    pline_no = 0
    while ((prc = (getline pline < plan_file)) > 0) {
        pline_no++
        sub(/\r$/, "", pline)
        plan_count++
        if (plan_count > input_count) {
            fail(prefix "Windows COFF plan has more rows than its batch input")
        }
        pn = split(pline, pf, "|")
        if (pn != 5) {
            fail(prefix "Windows COFF plan line " pline_no " must have 5 fields")
        }
        if (pf[5] != "stdlib-archive" && pf[5] != "none") {
            fail(prefix "Windows COFF plan line " pline_no " has an invalid archive requirement: " pf[5])
        }
        if (pf[1] != src_in[plan_count]) {
            fail(prefix "Windows COFF plan line " pline_no " source mismatch: expected " src_in[plan_count] ", got " pf[1])
        }

        psrc = pf[1]
        pkind = pf[2]
        psel = pf[3]
        preason = pf[4]
        parchive = pf[5]
        pforced = frc_in[plan_count]

        if (pkind == "coff-object") {
            if (pforced) {
                fail(prefix "Windows COFF plan line " pline_no " selected an object for a forced-assembly row")
            }
            if (psel != obj_in[plan_count]) {
                fail(prefix "Windows COFF plan line " pline_no " selected the wrong object path")
            }
            if (preason != "none") {
                fail(prefix "Windows COFF plan line " pline_no " object reason must be none")
            }
        } else if (pkind == "assembly") {
            if (psel != asm_in[plan_count]) {
                fail(prefix "Windows COFF plan line " pline_no " selected the wrong assembly path")
            }
            if (preason == "" || preason == "none") {
                fail(prefix "Windows COFF plan line " pline_no " assembly reason must be explicit")
            }
            if (pforced && preason != "forced-assembly") {
                fail(prefix "Windows COFF plan line " pline_no " lost its forced-assembly reason")
            }
            if (!pforced && preason == "forced-assembly") {
                fail(prefix "Windows COFF plan line " pline_no " reported forced-assembly for an automatic row")
            }
        } else {
            fail(prefix "Windows COFF plan line " pline_no " has an invalid artifact kind: " pkind)
        }

        if (artifacts_out != "") {
            if (substr(psrc, 1, length(expected_prefix)) != expected_prefix) {
                fail("FAIL: Windows COFF plan source is outside its validated case path: " psrc)
            }
            tail = substr(psrc, length(expected_prefix) + 1)
            slash = index(tail, "/")
            if (slash <= 1) {
                fail("FAIL: Windows COFF plan source is outside its validated case path: " psrc)
            }
            cname = substr(tail, 1, slash - 1)
            if (psrc != expected_prefix cname "/" cname ".tl") {
                fail("FAIL: Windows COFF plan source is outside its validated case path: " psrc)
            }
            if (seen_case[cname]++) {
                fail("FAIL: Windows COFF plan selected " cname " more than once")
            }

            sel_abs = root "/" psel
            obj_abs = root "/" obj_in[plan_count]
            asm_abs = root "/" asm_in[plan_count]
            if (pkind == "coff-object") {
                if (!file_nonempty(sel_abs)) {
                    fail("FAIL: Windows COFF plan omitted object for " cname ": " psel)
                }
                if (file_exists(asm_abs)) {
                    fail("FAIL: Windows COFF object row also wrote assembly for " cname)
                }
                direct_objects++
            } else {
                if (!file_nonempty(sel_abs)) {
                    fail("FAIL: Windows COFF plan omitted assembly for " cname ": " psel)
                }
                if (file_exists(obj_abs)) {
                    fail("FAIL: Windows COFF assembly row also wrote an object for " cname)
                }
                if (pforced) {
                    if (!(cname in forced_allowed)) {
                        fail("FAIL: Windows COFF plan forced unclassified assembly for " cname)
                    }
                    forced_assemblies++
                } else {
                    fallback_assemblies++
                    if (reasons_out != "") {
                        print preason >> reasons_out
                        reasons_opened = 1
                    }
                }
            }
            print cname "|" pkind "|" sel_abs "|" preason "|" parchive >> artifacts_out
            artifacts_opened = 1
            plan_rows++
        } else {
            print psrc, pkind, psel, preason, obj_in[plan_count], asm_in[plan_count], pforced, parchive
        }
    }
    close(plan_file)
    if (prc < 0) {
        fail(prefix "Windows COFF plan could not be read: " plan_file)
    }
    if (plan_count != input_count) {
        fail(prefix "Windows COFF plan row count mismatch: expected " input_count ", got " plan_count)
    }
}

BEGIN {
    FS = "|"
    OFS = "|"
    plan_rows = 0
    direct_objects = 0
    fallback_assemblies = 0
    forced_assemblies = 0
    pairs_seen = 0
    artifacts_opened = 0
    reasons_opened = 0

    if (artifacts_out != "") {
        nf = split(forced_list, farr, /[[:space:]]+/)
        for (i = 1; i <= nf; i++) {
            if (farr[i] != "") forced_allowed[farr[i]] = 1
        }
        if (file_exists(artifacts_out)) {
            while ((getline aline < artifacts_out) > 0) {
                sub(/\r$/, "", aline)
                if (aline == "") continue
                split(aline, af, "|")
                if (af[1] != "") seen_case[af[1]] = 1
            }
            close(artifacts_out)
        }
    }

    if (!multi) {
        if (ARGC != 3) {
            fail("Windows COFF plan validator requires batch and plan files")
        }
        validate_pair(ARGV[1], ARGV[2], "")
        exit 0
    }
}

{
    sub(/\r$/, "")
    if ($0 == "") next
    if ((NF != 2 && NF != 3) || $1 == "" || $2 == "") {
        fail("Windows COFF plan list line " FNR " must have batch and plan paths")
    }
    pairs_seen++
    validate_pair($1, $2, (NF == 3 ? $3 : ""))
}

END {
    if (failed) {
        exit 1
    }
    if (multi && pairs_seen == 0) {
        fail("Windows COFF plan list is empty")
    }
    if (artifacts_opened && close(artifacts_out) != 0) {
        exit 1
    }
    if (reasons_opened && close(reasons_out) != 0) {
        exit 1
    }
    if (counts_out != "") {
        print plan_rows "|" direct_objects "|" fallback_assemblies "|" forced_assemblies > counts_out
        if (close(counts_out) != 0) {
            exit 1
        }
    }
}
