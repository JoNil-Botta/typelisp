# lib-self-compile.sh - pure logic for the main-relative self_compile gate.
#
# Sourced by scripts/self-compile.sh. Nothing here measures, talks to the
# network or touches git; every decision the gate, the reference workflow and
# the ledger make is a function of record files and integers, so
# `scripts/self-compile.sh --self-test` can drive each rule from fixtures.
# perf/README.md (`self_compile`) describes the contract; #9307 and council
# decision D-C15-9307 define it.

SC_METRIC=self_compile/compile_cli_opt1
SC_RECORD_SCHEMA=typelisp-self-compile-record/1
SC_RESULT_SCHEMA=typelisp-self-compile-result/1
SC_ENTRY_SCHEMA=typelisp-self-compile-ledger-entry/1
SC_ACCOUNT_SCHEMA=typelisp-self-compile-account/2
SC_REFERENCE_WORKFLOW=.github/workflows/self-compile-reference.yml
SC_CI_WORKFLOW=.github/workflows/ci.yml
SC_REFERENCE_JOB_NAME="Self-compile reference (Linux)"
SC_LEDGER_JOB_NAME="Self-compile ledger"
SC_CI_JOB_NAME="Test + Integration"
SC_REFERENCE_ARTIFACT=self-compile-reference
SC_MEASUREMENT_ARTIFACT=self-compile-measurement
SC_LEDGER_ARTIFACT=self-compile-ledger
SC_DECLARATION_DIR=perf/self-compile-declarations
SC_RESOLUTIONS_FILE=perf/self-compile-ledger-resolutions.tsv
SC_CHECKPOINT_FILE=perf/self-compile-ledger-checkpoint.tsv

# The measured invocation. The output directory keeps the historical `-o`
# argument byte-for-byte (target/instruction-count-check/measure/...), so a
# value measured by this gate is directly comparable with the hosted values the
# retired checked row recorded: the -o path length changes the count.
SC_HARNESS_OUTPUT=target/instruction-count-check/measure
SC_HARNESS_LOG=self_compile-compile_cli_opt1-1.cachegrind.out
# The measurement procedure: the harness files that define the measured
# command, its environment, the Cachegrind flags and the Ir extraction. The
# measured argv, cwd and env are recorded separately. Build-recipe scripts are
# deliberately not part of it: they shape the compiler under test, so their
# effect is part of a PR's own cost, like a compiler source change.
SC_PROCEDURE_FILES="scripts/measure-instruction-counts.sh scripts/lib-benchmark.sh"

# Tolerance and bounds. TYPELISP_IR_SELF_COMPILE_TOLERANCE_PPM keeps its name
# and 5000 ppm default from the retired checked-row gate.
SC_TOLERANCE_PPM=${TYPELISP_IR_SELF_COMPILE_TOLERANCE_PPM:-5000}
SC_RUNNER_VARIATION_IR=1000
SC_CLASS_S_WARN_IR=1000
SC_CLASS_S_FAIL_IR=10000
SC_CLASS_M_WARN_IR=10000
SC_CLASS_M_FAIL_PPM=1000

# Reuse key and measurement identity: two measurements may be subtracted only
# when every one of these fields is equal (D-C15 amendment 4).
SC_COMPARABLE_KEYS="metric argv_normalized cwd env procedure key.image_os key.kernel key.valgrind key.as key.ld key.workspace key.arch"
SC_RECORD_REQUIRED_KEYS="schema metric ir_count commit tree role argv argv_normalized cwd env procedure compiler_sha256 compiler_commit key.image_os key.kernel key.valgrind key.as key.ld key.workspace key.arch info.image_version info.cpu authority"

sc_log() {
    printf '[self-compile] %s\n' "$*" >&2
}

# --- records --------------------------------------------------------------
# A record is a TSV of `key<TAB>value` lines. Values never contain tabs or
# newlines; sc_record_line enforces that when writing.

sc_record_get() {
    awk -F '\t' -v key="$2" '
        $1 == key { print substr($0, length($1) + 2); found = 1; exit }
        END { exit found ? 0 : 1 }
    ' "$1"
}

sc_record_line() {
    _srl_value=$(printf '%s' "$2" | tr '\t\r\n' '   ')
    printf '%s\t%s\n' "$1" "$_srl_value"
}

sc_is_sha() {
    case "$1" in
        "" | *[!0-9a-f]*) return 1 ;;
    esac
    [ "${#1}" -eq 40 ]
}

sc_is_count() {
    case "$1" in
        "" | *[!0-9]* | 0*) return 1 ;;
    esac
    [ "${#1}" -le 15 ]
}

# sc_record_validate FILE [ROLE...]
#   Structural validation; prints the first problem and fails.
sc_record_validate() {
    _srv_file=$1
    shift
    [ -f "$_srv_file" ] || { echo "missing record $_srv_file"; return 1; }
    for _srv_key in $SC_RECORD_REQUIRED_KEYS; do
        _srv_value=$(sc_record_get "$_srv_file" "$_srv_key") || {
            echo "record $_srv_file lacks $_srv_key"
            return 1
        }
        [ -n "$_srv_value" ] || { echo "record $_srv_file has an empty $_srv_key"; return 1; }
    done
    [ "$(sc_record_get "$_srv_file" schema)" = "$SC_RECORD_SCHEMA" ] || {
        echo "record $_srv_file has schema $(sc_record_get "$_srv_file" schema), expected $SC_RECORD_SCHEMA"
        return 1
    }
    [ "$(sc_record_get "$_srv_file" metric)" = "$SC_METRIC" ] || {
        echo "record $_srv_file measures $(sc_record_get "$_srv_file" metric), not $SC_METRIC"
        return 1
    }
    sc_is_count "$(sc_record_get "$_srv_file" ir_count)" || {
        echo "record $_srv_file has a malformed ir_count"
        return 1
    }
    sc_is_sha "$(sc_record_get "$_srv_file" commit)" || { echo "record $_srv_file has a malformed commit"; return 1; }
    sc_is_sha "$(sc_record_get "$_srv_file" tree)" || { echo "record $_srv_file has a malformed tree"; return 1; }
    [ "$(sc_record_get "$_srv_file" compiler_commit)" = "$(sc_record_get "$_srv_file" commit)" ] || {
        echo "record $_srv_file measured a compiler stamped $(sc_record_get "$_srv_file" compiler_commit), not its commit"
        return 1
    }
    if [ "$#" -gt 0 ]; then
        _srv_role=$(sc_record_get "$_srv_file" role)
        _srv_ok=1
        for _srv_want in "$@"; do
            [ "$_srv_role" = "$_srv_want" ] && _srv_ok=0
        done
        [ "$_srv_ok" -eq 0 ] || { echo "record $_srv_file has role $_srv_role, expected one of: $*"; return 1; }
    fi
}

# sc_records_comparable A B
#   Succeeds when every identity key matches; otherwise prints one line per
#   differing key and fails. A hosted record never compares with a local one.
sc_records_comparable() {
    _src_status=0
    for _src_key in $SC_COMPARABLE_KEYS authority; do
        _src_a=$(sc_record_get "$1" "$_src_key" 2>/dev/null || printf '<missing>')
        _src_b=$(sc_record_get "$2" "$_src_key" 2>/dev/null || printf '<missing>')
        if [ "$_src_a" != "$_src_b" ] || [ "$_src_a" = unknown ] || [ "$_src_a" = '<missing>' ]; then
            printf '%s: %s | %s\n' "$_src_key" "$_src_a" "$_src_b"
            _src_status=1
        fi
    done
    return "$_src_status"
}

# sc_same_commit_binary A B  ->  two records of one commit built with the same
# assembler and linker at the same workspace must have measured byte-identical
# compilers. Prints a problem and fails; succeeds (silently) when the check
# does not apply.
sc_same_commit_binary() {
    [ "$(sc_record_get "$1" commit)" = "$(sc_record_get "$2" commit)" ] || return 0
    [ "$(sc_record_get "$1" key.as)" = "$(sc_record_get "$2" key.as)" ] || return 0
    [ "$(sc_record_get "$1" key.ld)" = "$(sc_record_get "$2" key.ld)" ] || return 0
    [ "$(sc_record_get "$1" key.workspace)" = "$(sc_record_get "$2" key.workspace)" ] || return 0
    [ "$(sc_record_get "$1" compiler_sha256)" = "$(sc_record_get "$2" compiler_sha256)" ] || {
        echo "commit $(sc_record_get "$1" commit) built with the same as/ld measured two different compilers: $(sc_record_get "$1" compiler_sha256) | $(sc_record_get "$2" compiler_sha256)"
        return 1
    }
}

# sc_records_same_compiler A B
#   Two measurements of one tree. The fixpoint compiler is stamped with its
#   source commit, and the stamp also reaches content-derived assembly labels
#   and the compressed embedded stdlib image, so builds of one tree from two
#   commits (a tested merge and its squash) never match byte for byte. Two
#   measurements of one commit must have measured byte-identical compilers.
#   Prints `identical` or `commit-stamped`; prints a problem and fails otherwise.
sc_records_same_compiler() {
    [ "$(sc_record_get "$1" tree)" = "$(sc_record_get "$2" tree)" ] || {
        echo "trees differ: $(sc_record_get "$1" tree) | $(sc_record_get "$2" tree)"
        return 1
    }
    if [ "$(sc_record_get "$1" commit)" != "$(sc_record_get "$2" commit)" ]; then
        echo commit-stamped
        return 0
    fi
    [ "$(sc_record_get "$1" compiler_sha256)" = "$(sc_record_get "$2" compiler_sha256)" ] || {
        echo "one commit, different compilers: $(sc_record_get "$1" compiler_sha256) | $(sc_record_get "$2" compiler_sha256)"
        return 1
    }
    echo identical
}

# --- exact integer arithmetic ---------------------------------------------
# Counts reach 1.2e11 and windows multiply them by 1e6 and by a declared ppm
# with decimals, past 64-bit shell arithmetic and double precision. Every
# boundary is decided on decimal strings instead.
SC_BN_AWK='
function bn_strip(a,    s) {
    s = ""
    if (substr(a, 1, 1) == "-") { s = "-"; a = substr(a, 2) }
    else if (substr(a, 1, 1) == "+") { a = substr(a, 2) }
    sub(/^0+/, "", a)
    if (a == "") return "0"
    return s a
}
function bn_neg(a) {
    a = bn_strip(a)
    if (a == "0") return a
    return substr(a, 1, 1) == "-" ? substr(a, 2) : "-" a
}
function bn_abs(a) {
    a = bn_strip(a)
    return substr(a, 1, 1) == "-" ? substr(a, 2) : a
}
function bn_cmp_mag(a, b) {
    if (length(a) != length(b)) return length(a) < length(b) ? -1 : 1
    if (a == b) return 0
    return a < b ? -1 : 1
}
function bn_cmp(a, b,    na, nb) {
    a = bn_strip(a); b = bn_strip(b)
    na = substr(a, 1, 1) == "-"; nb = substr(b, 1, 1) == "-"
    if (na && !nb) return -1
    if (!na && nb) return 1
    if (na) return -bn_cmp_mag(substr(a, 2), substr(b, 2))
    return bn_cmp_mag(a, b)
}
function bn_add_mag(a, b,    i, j, c, d, r) {
    r = ""; c = 0; i = length(a); j = length(b)
    while (i > 0 || j > 0 || c > 0) {
        d = c + (i > 0 ? substr(a, i, 1) + 0 : 0) + (j > 0 ? substr(b, j, 1) + 0 : 0)
        r = (d % 10) r; c = int(d / 10); i--; j--
    }
    return bn_strip(r)
}
function bn_sub_mag(a, b,    i, j, c, d, r) {
    r = ""; c = 0; i = length(a); j = length(b)
    while (i > 0) {
        d = substr(a, i, 1) - c - (j > 0 ? substr(b, j, 1) : 0)
        if (d < 0) { d += 10; c = 1 } else { c = 0 }
        r = d r; i--; j--
    }
    return bn_strip(r)
}
function bn_add(a, b,    na, nb, ma, mb, k, r) {
    a = bn_strip(a); b = bn_strip(b)
    na = substr(a, 1, 1) == "-"; nb = substr(b, 1, 1) == "-"
    ma = na ? substr(a, 2) : a; mb = nb ? substr(b, 2) : b
    if (na == nb) { r = bn_add_mag(ma, mb); return na ? bn_neg(r) : r }
    k = bn_cmp_mag(ma, mb)
    if (k == 0) return "0"
    if (k > 0) { r = bn_sub_mag(ma, mb); return na ? bn_neg(r) : r }
    r = bn_sub_mag(mb, ma); return nb ? bn_neg(r) : r
}
function bn_sub(a, b) { return bn_add(a, bn_neg(b)) }
function bn_mul(a, b,    na, nb, i, j, la, lb, res, k, c, r) {
    a = bn_strip(a); b = bn_strip(b)
    na = substr(a, 1, 1) == "-"; nb = substr(b, 1, 1) == "-"
    if (na) a = substr(a, 2)
    if (nb) b = substr(b, 2)
    la = length(a); lb = length(b)
    for (k = 0; k < la + lb; k++) res[k] = 0
    for (i = 0; i < la; i++)
        for (j = 0; j < lb; j++)
            res[i + j] += substr(a, la - i, 1) * substr(b, lb - j, 1)
    c = 0; r = ""
    for (k = 0; k < la + lb; k++) { res[k] += c; r = (res[k] % 10) r; c = int(res[k] / 10) }
    while (c > 0) { r = (c % 10) r; c = int(c / 10) }
    r = bn_strip(r)
    return (na != nb) ? bn_neg(r) : r
}
function bn_pow10(k,    r) { r = "1"; while (k-- > 0) r = r "0"; return r }
# A finite signed decimal into numerator and power-of-ten scale.
function dec_parse(s,    m) {
    if (s !~ /^[+-]?[0-9]+(\.[0-9]+)?$/) return 0
    dec_sign = substr(s, 1, 1) == "-" ? "-" : ""
    sub(/^[+-]/, "", s)
    if (index(s, ".") > 0) {
        dec_scale = length(s) - index(s, ".")
        sub(/\./, "", s)
    } else {
        dec_scale = 0
    }
    dec_num = bn_strip(dec_sign s)
    return 1
}
'

# sc_bn OP A [B]  ->  add, sub, mul, cmp, abs, neg
sc_bn() {
    awk -v op="$1" -v a="$2" -v b="${3:-0}" "$SC_BN_AWK"'
        BEGIN {
            if (op == "add") print bn_add(a, b)
            else if (op == "sub") print bn_sub(a, b)
            else if (op == "mul") print bn_mul(a, b)
            else if (op == "cmp") print bn_cmp(a, b)
            else if (op == "abs") print bn_abs(a)
            else if (op == "neg") print bn_neg(a)
            else exit 2
        }'
}

# sc_window DELTA BASE DECLARED_PPM TOLERANCE_PPM
#   Prints `in` when |DELTA*1e6 - DECLARED*BASE| <= TOLERANCE*BASE, using exact
#   integers, else `out`. DECLARED is a finite signed decimal.
sc_window() {
    awk -v delta="$1" -v base="$2" -v declared="$3" -v tol="$4" "$SC_BN_AWK"'
        BEGIN {
            if (!dec_parse(declared)) { print "malformed"; exit 2 }
            scale = bn_pow10(dec_scale)
            lhs = bn_abs(bn_sub(bn_mul(bn_mul(delta, "1000000"), scale), bn_mul(dec_num, base)))
            rhs = bn_mul(bn_mul(tol, scale), base)
            print (bn_cmp(lhs, rhs) <= 0) ? "in" : "out"
        }'
}

# sc_ppm_exceeds VALUE BASE PPM  ->  `yes` when |VALUE|*1e6 > PPM*BASE.
sc_ppm_exceeds() {
    awk -v v="$1" -v base="$2" -v ppm="$3" "$SC_BN_AWK"'
        BEGIN {
            print (bn_cmp(bn_mul(bn_abs(v), "1000000"), bn_mul(ppm, base)) > 0) ? "yes" : "no"
        }'
}

# sc_abs_exceeds VALUE BOUND  ->  `yes` when |VALUE| > BOUND.
sc_abs_exceeds() {
    awk -v v="$1" -v bound="$2" "$SC_BN_AWK"'
        BEGIN { print (bn_cmp(bn_abs(v), bound) > 0) ? "yes" : "no" }'
}

# sc_decimal_cmp A B  ->  -1, 0 or 1 for two finite signed decimals.
sc_decimal_cmp() {
    awk -v a="$1" -v b="$2" "$SC_BN_AWK"'
        BEGIN {
            if (!dec_parse(a)) exit 2
            an = dec_num; as = dec_scale
            if (!dec_parse(b)) exit 2
            bnum = dec_num; bs = dec_scale
            print bn_cmp(bn_mul(an, bn_pow10(bs)), bn_mul(bnum, bn_pow10(as)))
        }'
}

# Display only: ppm of BASE with three decimals. Decisions never use it.
sc_ppm_display() {
    awk -v v="$1" -v base="$2" 'BEGIN { printf "%+.3f", (v * 1000000.0) / base }'
}

sc_signed() {
    case "$1" in
        -*) printf '%s' "$1" ;;
        0) printf '0' ;;
        *) printf '+%s' "$1" ;;
    esac
}

# --- declarations ----------------------------------------------------------

# sc_declaration_parse FILE  ->  prints the declared ppm, or a diagnostic and
# fails. Exactly one line: metric, finite signed decimal ppm, non-empty reason.
sc_declaration_parse() {
    awk -F '\t' -v metric="$SC_METRIC" '
        { sub(/\r$/, "") }
        NF == 0 || $0 == "" { blank++; next }
        { lines++; line = $0; fields = NF; f1 = $1; f2 = $2; f3 = $3 }
        END {
            if (lines != 1) { print "declaration must have exactly one non-empty line, found " lines; exit 1 }
            if (fields != 3) { print "declaration needs three tab-separated fields: metric, ppm, reason"; exit 1 }
            if (f1 != metric) { print "declaration names " f1 ", expected " metric; exit 1 }
            if (f2 !~ /^[+-]?[0-9]+(\.[0-9]+)?$/) { print "declared ppm is not a finite signed decimal: " f2; exit 1 }
            if (f3 ~ /^[[:space:]]*$/) { print "declaration has an empty reason"; exit 1 }
            print f2
        }
    ' "$1"
}

# sc_declaration_diff_check PR NAME_STATUS_FILE B_HAS_OWN
#   NAME_STATUS_FILE is `git diff --name-status -M B T -- perf/self-compile-declarations`.
#   Prints one violation per line and fails when there is any: a PR may add only
#   its own pr-<PR>.tsv, and only when B lacks it; it may never add another PR's
#   declaration or modify, delete or rename one already present in B.
sc_declaration_diff_check() {
    awk -F '\t' -v pr="$1" -v b_has_own="$3" -v dir="$SC_DECLARATION_DIR" '
        { sub(/\r$/, "") }
        NF == 0 { next }
        {
            status = substr($1, 1, 1)
            own = dir "/pr-" pr ".tsv"
            if (status == "A") {
                if ($2 != own) { print "adds a declaration that is not this PR'"'"'s (" own "): " $2; bad = 1 }
            } else if (status == "M" || status == "T") {
                print "modifies a merged declaration: " $2; bad = 1
            } else if (status == "D") {
                print "deletes a merged declaration: " $2; bad = 1
            } else if (status == "R" || status == "C") {
                print "renames or copies a declaration: " $2 " -> " $3; bad = 1
            } else {
                print "unexpected change " $1 ": " $2; bad = 1
            }
        }
        END {
            if (b_has_own == "yes") { print "the base already carries " dir "/pr-" pr ".tsv"; bad = 1 }
            exit bad ? 1 : 0
        }
    ' "$2"
}

# --- PR gate -------------------------------------------------------------------

# sc_gate_decide HEAD_REC BASE_REC DECLARED  ->  writes key/value lines:
# own, ppm, status, routing. DECLARED is `none` or a finite signed decimal.
sc_gate_decide() {
    _sgd_now=$(sc_record_get "$1" ir_count)
    _sgd_base=$(sc_record_get "$2" ir_count)
    _sgd_own=$(sc_bn sub "$_sgd_now" "$_sgd_base")
    _sgd_declared=$3
    _sgd_d=$_sgd_declared
    [ "$_sgd_d" = none ] && _sgd_d=0
    _sgd_window=$(sc_window "$_sgd_own" "$_sgd_base" "$_sgd_d" "$SC_TOLERANCE_PPM")
    if [ "$_sgd_window" = in ]; then
        _sgd_status=ok
        [ "$_sgd_declared" != none ] && _sgd_status=declared-ok
    elif [ "$_sgd_declared" != none ]; then
        _sgd_status=DECLARATION-MISMATCH
    elif [ "$(sc_bn cmp "$_sgd_own" 0)" -gt 0 ]; then
        _sgd_status=REGRESSION
    else
        _sgd_status=IMPROVEMENT
    fi
    # D-C15 amendment 10: a cost beyond +5000 ppm, declared or measured, is
    # non-routine; an improvement beyond -5000 ppm needs both reviewers to
    # explain its source.
    _sgd_routing=routine
    if [ "$(sc_ppm_exceeds "$_sgd_own" "$_sgd_base" 5000)" = yes ]; then
        if [ "$(sc_bn cmp "$_sgd_own" 0)" -gt 0 ]; then
            _sgd_routing=non-routine
        else
            _sgd_routing=explain-improvement
        fi
    fi
    if [ "$_sgd_declared" != none ]; then
        if [ "$(sc_decimal_cmp "$_sgd_declared" 5000)" -gt 0 ]; then
            _sgd_routing=non-routine
        elif [ "$(sc_decimal_cmp "$_sgd_declared" -5000)" -lt 0 ] && [ "$_sgd_routing" = routine ]; then
            _sgd_routing=explain-improvement
        fi
    fi
    _sgd_variation=no
    if [ "$(sc_abs_exceeds "$_sgd_own" "$SC_RUNNER_VARIATION_IR")" = no ]; then
        _sgd_variation=yes
    fi
    sc_record_line own "$_sgd_own"
    sc_record_line own_ppm "$(sc_ppm_display "$_sgd_own" "$_sgd_base")"
    sc_record_line declared_ppm "$_sgd_declared"
    sc_record_line tolerance_ppm "$SC_TOLERANCE_PPM"
    sc_record_line status "$_sgd_status"
    sc_record_line routing "$_sgd_routing"
    sc_record_line within_runner_variation_bound "$_sgd_variation"
}

# --- reference selection ------------------------------------------------------

# sc_select_reference_run RUNS_JSON REPO COMMIT
#   RUNS_JSON is the reference workflow's runs list for head_sha=COMMIT. Prints
#   `id<TAB>attempt<TAB>status<TAB>conclusion` of the newest run that is a push
#   to main of the reviewed workflow in this repository, or nothing.
sc_select_reference_run() {
    jq -r --arg repo "$2" --arg sha "$3" --arg path "$SC_REFERENCE_WORKFLOW" '
        [.workflow_runs[]
         | select(.event == "push"
                  and .head_branch == "main"
                  and .head_sha == $sha
                  and .path == $path
                  and .repository.full_name == $repo
                  and .head_repository.full_name == $repo)]
        | sort_by(.run_number, .id) | last // empty
        | [(.id | tostring), (.run_attempt | tostring), .status, (.conclusion // "")]
        | @tsv' "$1" | tr -d '\r'
}

# sc_job_latest JOBS_JSON NAME  ->  `attempt<TAB>status<TAB>conclusion` of the
# named job's latest executed instance in a run's all-attempts job list, or
# nothing. "Re-run failed jobs" copies every job it does not re-run into the
# new attempt, with that attempt's number but the original runner, start and
# completion; such a copy uploaded nothing, so it resolves to the instance it
# copies. A later instance that really ran (pending, failed or succeeded)
# replaces earlier ones.
sc_job_latest() {
    jq -r --arg name "$2" '
        def executed(j):
            if (j | length) > 1
               and j[-1].started_at != null
               and j[-1].started_at == j[-2].started_at
               and j[-1].completed_at == j[-2].completed_at
               and j[-1].runner_name == j[-2].runner_name
            then executed(j[:-1]) else j[-1] end;
        [.jobs[] | select(.name == $name)] | sort_by(.run_attempt)
        | if length == 0 then empty else executed(.) end
        | [(.run_attempt | tostring), .status, (.conclusion // "")] | @tsv' "$1" | tr -d '\r'
}

# sc_select_pr_run RUNS_JSON REPO HEAD  ->  the id of the newest successful
# pull_request CI run of this repository's ci.yml for HEAD, or nothing.
sc_select_pr_run() {
    jq -r --arg repo "$2" --arg h "$3" --arg path "$SC_CI_WORKFLOW" '
        [.workflow_runs[]
         | select(.event == "pull_request" and .head_sha == $h and .path == $path
                  and .repository.full_name == $repo
                  and .status == "completed" and .conclusion == "success")]
        | sort_by(.run_number, .id) | last // empty | .id | tostring' "$1" | tr -d '\r'
}

# sc_reference_record_check REF HEAD REPO RUN_ID ATTEMPT COMMIT EXPECT_ROLE
#   Binds a downloaded record to the run that produced it and to the commit it
#   claims, then requires a comparable measurement identity with HEAD. Prints
#   every problem; fails on any.
sc_reference_record_check() {
    _srrc_ref=$1
    _srrc_status=0
    _srrc_msg=$(sc_record_validate "$_srrc_ref" "$7") || { echo "$_srrc_msg"; return 1; }
    [ "$(sc_record_get "$_srrc_ref" commit)" = "$6" ] || {
        echo "record commit $(sc_record_get "$_srrc_ref" commit) is not $6"
        _srrc_status=1
    }
    [ "$(sc_record_get "$_srrc_ref" authority)" = hosted ] || {
        echo "record authority is $(sc_record_get "$_srrc_ref" authority), not hosted"
        _srrc_status=1
    }
    [ "$(sc_record_get "$_srrc_ref" run.repository 2>/dev/null || true)" = "$3" ] || {
        echo "record repository $(sc_record_get "$_srrc_ref" run.repository 2>/dev/null || true) is not $3"
        _srrc_status=1
    }
    [ "$(sc_record_get "$_srrc_ref" run.id 2>/dev/null || true)" = "$4" ] || {
        echo "record run $(sc_record_get "$_srrc_ref" run.id 2>/dev/null || true) is not producer run $4"
        _srrc_status=1
    }
    [ "$(sc_record_get "$_srrc_ref" run.attempt 2>/dev/null || true)" = "$5" ] || {
        echo "record attempt $(sc_record_get "$_srrc_ref" run.attempt 2>/dev/null || true) is not the producer's latest attempt $5"
        _srrc_status=1
    }
    [ "$(sc_record_get "$_srrc_ref" run.event 2>/dev/null || true)" = push ] || {
        echo "record event $(sc_record_get "$_srrc_ref" run.event 2>/dev/null || true) is not push"
        _srrc_status=1
    }
    case "$(sc_record_get "$_srrc_ref" run.workflow_ref 2>/dev/null || true)" in
        "$3/$SC_REFERENCE_WORKFLOW@refs/heads/main") ;;
        *)
            echo "record workflow $(sc_record_get "$_srrc_ref" run.workflow_ref 2>/dev/null || true) is not $3/$SC_REFERENCE_WORKFLOW@refs/heads/main"
            _srrc_status=1
            ;;
    esac
    if ! _srrc_diff=$(sc_records_comparable "$2" "$_srrc_ref"); then
        printf '%s\n' "$_srrc_diff" | sed 's/^/identity differs: /'
        _srrc_status=1
    fi
    return "$_srrc_status"
}

# --- ledger -------------------------------------------------------------------

# sc_ledger_entry INPUT_DIR  ->  writes an entry (key/value lines) on stdout.
# INPUT_DIR holds:
#   commit, parent              the merge c and its first parent p
#   tree.commit, tree.parent    their trees
#   parent.tsv, landed.tsv      a comparable measurement pair of p and c
#   pr.tsv                      optional: the merged PR's result, with
#   pr-head.tsv, pr-base.tsv    its own head (T) and base (B) records
#   rep-head.tsv, rep-base.tsv  optional: T and B reproduced in the landed
#                               pair's identity when the PR's differs
#   merges-between              optional: the B..p merges, one per line
#   binary-problem              optional: a same-commit compiler mismatch
# The entry is classified S (the landed tree is the tested tree) or M, with
# exact bounds, the landed gate window, and every failure named.
sc_ledger_entry() {
    _sle_dir=$1
    _sle_c=$(cat "$_sle_dir/commit")
    _sle_p=$(cat "$_sle_dir/parent")
    _sle_tc=$(cat "$_sle_dir/tree.commit")
    _sle_tp=$(cat "$_sle_dir/tree.parent")
    _sle_failures=
    _sle_warnings=
    sc_record_line schema "$SC_ENTRY_SCHEMA"
    sc_record_line commit "$_sle_c"
    sc_record_line parent "$_sle_p"

    # The step must subtract a comparable pair of p and c.
    _sle_pair_ok=yes
    if ! _sle_m=$(sc_record_validate "$_sle_dir/landed.tsv") ||
        ! _sle_m2=$(sc_record_validate "$_sle_dir/parent.tsv"); then
        _sle_pair_ok=no
        sc_record_line pair_problem "${_sle_m:-}${_sle_m2:-}"
    elif [ "$(sc_record_get "$_sle_dir/landed.tsv" commit)" != "$_sle_c" ] ||
        [ "$(sc_record_get "$_sle_dir/parent.tsv" commit)" != "$_sle_p" ] ||
        [ "$(sc_record_get "$_sle_dir/landed.tsv" tree)" != "$_sle_tc" ] ||
        [ "$(sc_record_get "$_sle_dir/parent.tsv" tree)" != "$_sle_tp" ]; then
        _sle_pair_ok=no
        sc_record_line pair_problem "pair records do not measure commit $_sle_c and parent $_sle_p"
    elif ! _sle_d=$(sc_records_comparable "$_sle_dir/parent.tsv" "$_sle_dir/landed.tsv"); then
        _sle_pair_ok=no
        sc_record_line pair_problem "$(printf '%s' "$_sle_d" | tr '\n' ';')"
    fi
    if [ "$_sle_pair_ok" != yes ]; then
        sc_record_line class none
        sc_ledger_finish comparability ""
        return 0
    fi
    _sle_mc=$(sc_record_get "$_sle_dir/landed.tsv" ir_count)
    _sle_mp=$(sc_record_get "$_sle_dir/parent.tsv" ir_count)
    _sle_step=$(sc_bn sub "$_sle_mc" "$_sle_mp")
    sc_record_line m_parent "$_sle_mp"
    sc_record_line m_commit "$_sle_mc"
    sc_record_line step "$_sle_step"
    sc_record_line step_ppm "$(sc_ppm_display "$_sle_step" "$_sle_mp")"
    # Two measurements of one commit with the same as/ld that measured
    # different compilers: the measured values are not trusted as one identity.
    if [ -s "$_sle_dir/binary-problem" ]; then
        sc_record_line binary_problem "$(tr '\n' ';' < "$_sle_dir/binary-problem")"
        _sle_failures="$_sle_failures comparability"
    fi
    sc_record_line pair_identity "$(sc_record_get "$_sle_dir/landed.tsv" key.kernel)|$(sc_record_get "$_sle_dir/landed.tsv" key.valgrind)|$(sc_record_get "$_sle_dir/landed.tsv" key.as)|$(sc_record_get "$_sle_dir/landed.tsv" procedure)"

    # Landed gate window, for every merge with a step: the merge as it landed
    # against its parent, with the PR's honoured declaration or 0.
    _sle_declared=none
    if [ -f "$_sle_dir/pr.tsv" ]; then
        _sle_declared=$(sc_record_get "$_sle_dir/pr.tsv" declared_ppm 2>/dev/null || echo none)
    fi
    _sle_d=$_sle_declared
    [ "$_sle_d" = none ] && _sle_d=0
    if [ "$(sc_window "$_sle_step" "$_sle_mp" "$_sle_d" "$SC_TOLERANCE_PPM")" != in ]; then
        _sle_failures="$_sle_failures landed-gate-window"
    fi
    if [ "$(sc_ppm_exceeds "$_sle_step" "$_sle_mp" 5000)" = yes ]; then
        if [ "$(sc_bn cmp "$_sle_step" 0)" -gt 0 ]; then
            sc_record_line routing non-routine
        else
            sc_record_line routing explain-improvement
        fi
    fi

    # Attribution: the merged PR's own CI result.
    if [ ! -f "$_sle_dir/pr.tsv" ] || [ ! -f "$_sle_dir/pr-head.tsv" ] || [ ! -f "$_sle_dir/pr-base.tsv" ]; then
        sc_record_line class none
        sc_record_line attribution missing
        sc_ledger_finish "$_sle_failures attribution" "$_sle_warnings"
        return 0
    fi
    _sle_own_original=$(sc_record_get "$_sle_dir/pr.tsv" own)
    sc_record_line pr "$(sc_record_get "$_sle_dir/pr.tsv" pr)"
    sc_record_line pr_head "$(sc_record_get "$_sle_dir/pr.tsv" head)"
    sc_record_line pr_tested_merge "$(sc_record_get "$_sle_dir/pr.tsv" merge)"
    sc_record_line pr_tested_base "$(sc_record_get "$_sle_dir/pr.tsv" base)"
    sc_record_line declared_ppm "$_sle_declared"
    sc_record_line own_original "$_sle_own_original"

    # The PR's T and B must be comparable with the landed pair: its own report
    # when its identity matches, else its comparison reproduced in the landed
    # pair's identity (rep-head.tsv, rep-base.tsv), with the original kept.
    _sle_th=
    _sle_tbr=
    if ! _sle_pdiff=$(sc_records_comparable "$_sle_dir/pr-head.tsv" "$_sle_dir/landed.tsv"); then
        sc_record_line pr_identity_differences "$(printf '%s' "$_sle_pdiff" | tr '\n' ';')"
    fi
    if sc_records_comparable "$_sle_dir/pr-head.tsv" "$_sle_dir/landed.tsv" >/dev/null &&
        sc_records_comparable "$_sle_dir/pr-base.tsv" "$_sle_dir/landed.tsv" >/dev/null; then
        _sle_th=$_sle_dir/pr-head.tsv
        _sle_tbr=$_sle_dir/pr-base.tsv
        sc_record_line own_source "PR report"
    elif [ -f "$_sle_dir/rep-head.tsv" ] && [ -f "$_sle_dir/rep-base.tsv" ] &&
        sc_record_validate "$_sle_dir/rep-head.tsv" >/dev/null &&
        sc_record_validate "$_sle_dir/rep-base.tsv" >/dev/null &&
        [ "$(sc_record_get "$_sle_dir/rep-head.tsv" tree)" = "$(sc_record_get "$_sle_dir/pr-head.tsv" tree)" ] &&
        [ "$(sc_record_get "$_sle_dir/rep-base.tsv" tree)" = "$(sc_record_get "$_sle_dir/pr-base.tsv" tree)" ] &&
        sc_records_comparable "$_sle_dir/rep-head.tsv" "$_sle_dir/landed.tsv" >/dev/null &&
        sc_records_comparable "$_sle_dir/rep-base.tsv" "$_sle_dir/landed.tsv" >/dev/null; then
        _sle_th=$_sle_dir/rep-head.tsv
        _sle_tbr=$_sle_dir/rep-base.tsv
        sc_record_line own_source "reproduced in the landed pair's identity"
    else
        sc_record_line class none
        sc_record_line detail "the PR's measurement identity differs from the landed pair and was not reproduced"
        sc_ledger_finish "$_sle_failures comparability" "$_sle_warnings"
        return 0
    fi
    _sle_tt=$(sc_record_get "$_sle_th" tree)
    _sle_tb=$(sc_record_get "$_sle_tbr" tree)
    _sle_mt=$(sc_record_get "$_sle_th" ir_count)
    _sle_own=$(sc_bn sub "$_sle_mt" "$(sc_record_get "$_sle_tbr" ir_count)")
    _sle_a=$(sc_bn sub "$_sle_step" "$_sle_own")
    sc_record_line own "$_sle_own"
    sc_record_line a "$_sle_a"
    sc_record_line a_ppm "$(sc_ppm_display "$_sle_a" "$_sle_mp")"

    if [ "$_sle_tt" = "$_sle_tc" ]; then
        _sle_class=S
        # Reproduction residual: the landed tree against the measurement of the
        # same tree in the same identity.
        if _sle_y=$(sc_records_same_compiler "$_sle_th" "$_sle_dir/landed.tsv"); then
            _sle_r=$(sc_bn sub "$_sle_mc" "$_sle_mt")
            sc_record_line r "$_sle_r"
            sc_record_line r_compiler "$_sle_y"
            if [ "$(sc_abs_exceeds "$_sle_r" "$SC_CLASS_S_FAIL_IR")" = yes ]; then
                _sle_failures="$_sle_failures class-s"
            elif [ "$(sc_abs_exceeds "$_sle_r" "$SC_CLASS_S_WARN_IR")" = yes ]; then
                _sle_warnings="$_sle_warnings class-s"
            fi
        else
            sc_record_line r_problem "$_sle_y"
            _sle_failures="$_sle_failures comparability"
        fi
        if [ "$_sle_tb" = "$_sle_tp" ]; then
            sc_record_line a_class S
            if [ "$(sc_abs_exceeds "$_sle_a" "$SC_CLASS_S_FAIL_IR")" = yes ]; then
                _sle_failures="$_sle_failures class-s-attribution"
            elif [ "$(sc_abs_exceeds "$_sle_a" "$SC_CLASS_S_WARN_IR")" = yes ]; then
                _sle_warnings="$_sle_warnings class-s-attribution"
            fi
        else
            sc_record_line a_class M
        fi
    else
        _sle_class=M
        sc_record_line a_class M
    fi
    sc_record_line class "$_sle_class"
    if [ "$_sle_class" = M ] || [ "$_sle_tb" != "$_sle_tp" ]; then
        if [ -f "$_sle_dir/merges-between" ]; then
            sc_record_line merges_between "$(tr '\n' ' ' < "$_sle_dir/merges-between" | sed 's/ *$//')"
        fi
        if [ "$(sc_ppm_exceeds "$_sle_a" "$_sle_mp" "$SC_CLASS_M_FAIL_PPM")" = yes ]; then
            _sle_failures="$_sle_failures class-m"
        elif [ "$(sc_abs_exceeds "$_sle_a" "$SC_CLASS_M_WARN_IR")" = yes ]; then
            _sle_warnings="$_sle_warnings class-m"
        fi
    fi

    sc_ledger_finish "$_sle_failures" "$_sle_warnings"
}

# sc_ledger_finish FAILURES WARNINGS  ->  the failure, warning and outcome
# lines of an entry. The outcome names every failure class present, joined by
# `+` (comparability, attribution, numerical), so a resolution must name all
# of them; otherwise it is `warning` or `ok`.
sc_ledger_finish() {
    _slf_failures=$(printf '%s' "$1" | sed 's/^ *//; s/  */ /g')
    _slf_warnings=$(printf '%s' "$2" | sed 's/^ *//; s/  */ /g')
    sc_record_line failures "${_slf_failures:--}"
    sc_record_line warnings "${_slf_warnings:--}"
    _slf_outcome=
    case " $_slf_failures " in
        *" comparability "*) _slf_outcome=comparability-failure ;;
    esac
    case " $_slf_failures " in
        *" attribution "*) _slf_outcome="${_slf_outcome:+$_slf_outcome+}attribution-failure" ;;
    esac
    case " $_slf_failures " in
        *" class-s "* | *" class-s-attribution "* | *" class-m "* | *" landed-gate-window "*)
            _slf_outcome="${_slf_outcome:+$_slf_outcome+}numerical-failure"
            ;;
    esac
    if [ -z "$_slf_outcome" ]; then
        if [ -n "$_slf_warnings" ]; then _slf_outcome=warning; else _slf_outcome=ok; fi
    fi
    sc_record_line outcome "$_slf_outcome"
}

# --- cumulative account ----------------------------------------------------------
# The account carried from ledger run to ledger run is the anchor plus one
# line per merge since it, with tab-separated fields (no value holds a tab):
#   entry  commit class a_class outcome step own a r pair_identity failures
# where a missing quantity is `-`, and the reviewed resolutions applied so far:
#   resolved  commit outcome reference
# Every sum and count is re-folded from those lines (sc_account_summary), so a
# repaired entry replaces its line and every later total follows, and nothing
# is summed from a value that was never measured.

# sc_account_seed ANCHOR_COMMIT ANCHOR_PARENT PARENT_IR  ->  an empty account.
sc_account_seed() {
    sc_record_line schema "$SC_ACCOUNT_SCHEMA"
    sc_record_line anchor.commit "$1"
    sc_record_line anchor.parent "$2"
    sc_record_line anchor.parent_ir "$3"
    sc_record_line last.commit "$2"
}

# sc_account_entry_line ENTRY  ->  the tab-separated fields of an `entry` line.
sc_account_entry_line() {
    for _sael_key in commit class a_class outcome step own a r pair_identity failures; do
        _sael_value=$(sc_record_get "$1" "$_sael_key" 2>/dev/null || printf -- -)
        [ -n "$_sael_value" ] || _sael_value=-
        printf '%s\n' "$_sael_value" | tr '\t' ' '
    done | paste -s -d '\t' -
}

# sc_account_apply ACCOUNT ENTRY  ->  the account with ENTRY's line, replacing
# an earlier line for the same commit (a repaired entry), and last.commit
# advanced when the entry is a new merge.
sc_account_apply() {
    _saa_line=$(sc_account_entry_line "$2")
    awk -F '\t' -v line="$_saa_line" '
        BEGIN { split(line, f, "\t"); commit = f[1] }
        {
            if ($1 == "entry" && $2 == commit) { out[++n] = "entry\t" line; replaced = 1; next }
            out[++n] = $0
        }
        END {
            for (i = 1; i <= n; i++) {
                if (!replaced && out[i] ~ /^last\.commit\t/) { print "last.commit\t" commit; continue }
                print out[i]
            }
            if (!replaced) print "entry\t" line
        }
    ' "$1"
}

# sc_account_resolve ACCOUNT RESOLUTIONS  ->  the account with each reviewed
# resolution (`commit<TAB>outcome<TAB>reference`) that names a failing entry
# whose quantities are complete. A resolution for an entry without its step or
# its attribution is refused: that needs a repaired entry first.
sc_account_resolve() {
    if [ ! -s "$2" ]; then
        cat "$1"
        return 0
    fi
    awk -F '\t' -v resolutions="$2" '
        BEGIN { OFS = "\t" }
        FILENAME == resolutions {
            sub(/\r$/, "")
            if ($0 ~ /^#/ || NF < 3) next
            want[$1 SUBSEP $2] = $3
            order[++n] = $1 SUBSEP $2
            next
        }
        $1 == "resolved" { have[$2 SUBSEP $3] = 1 }
        $1 == "entry" { outcome[$2] = $5; step[$2] = $6; own[$2] = $7 }
        { print }
        END {
            for (i = 1; i <= n; i++) {
                key = order[i]
                if (key in have) continue
                split(key, k, SUBSEP)
                if (!(k[1] in outcome) || outcome[k[1]] != k[2]) continue
                if (step[k[1]] == "-" || own[k[1]] == "-") {
                    print "resolution_refused", k[1], k[2], "incomplete quantities; repair the entry first"
                    continue
                }
                print "resolved", k[1], k[2], want[key]
            }
        }
    ' "$2" "$1"
}

# sc_account_summary ACCOUNT  ->  the totals, re-folded from the entry lines.
# An entry is unresolved while it fails without a resolution, or while its
# step or attribution is missing (which no resolution clears).
sc_account_summary() {
    awk -F '\t' "$SC_BN_AWK"'
        BEGIN { OFS = "\t"; sstep = "0"; sown = "0"; sa = "0"; srs = "0"; sam = "0" }
        $1 == "anchor.commit" { anchor = $2 }
        $1 == "last.commit" { last = $2 }
        $1 == "resolved" { resolved[$2 SUBSEP $3] = 1 }
        $1 == "entry" { order[++n] = $0 }
        END {
            prev = ""
            for (i = 1; i <= n; i++) {
                split(order[i], e, "\t")
                commit = e[2]; class = e[3]; aclass = e[4]; outcome = e[5]
                step = e[6]; own = e[7]; a = e[8]; r = e[9]; pid = e[10]; failures = e[11]
                merges++
                if (step == "-") missing_steps++; else sstep = bn_add(sstep, step)
                if (own == "-") unattributed++; else sown = bn_add(sown, own)
                if (a != "-") sa = bn_add(sa, a)
                if (class == "S") { cs++; if (r != "-") srs = bn_add(srs, r) }
                if (class == "M") cm++
                if (aclass == "M" && a != "-") sam = bn_add(sam, a)
                if (outcome == "warning") warnings++
                failing = (outcome != "ok" && outcome != "warning")
                if (failing) failures_n++
                incomplete = (step == "-" || own == "-")
                if (incomplete || (failing && !((commit SUBSEP outcome) in resolved)))
                    unresolved[++u] = commit "\t" outcome "\t" failures
                if (pid != "-" && pid != prev) segments++
                if (pid != "-") prev = pid
            }
            print "anchor.commit", anchor
            print "last.commit", last
            print "merges", merges + 0
            print "sum.step", sstep
            print "sum.own", sown
            print "sum.a", sa
            print "sum.r_s", srs
            print "sum.a_m", sam
            print "count.s", cs + 0
            print "count.m", cm + 0
            print "count.warnings", warnings + 0
            print "count.failures", failures_n + 0
            print "count.missing_steps", missing_steps + 0
            print "count.unattributed", unattributed + 0
            print "segments", segments + 0
            print "complete", (missing_steps + unattributed == 0) ? "yes" : "no"
            print "count.unresolved", u + 0
            for (i = 1; i <= u; i++) print "unresolved", unresolved[i]
        }
    ' "$1"
}

# sc_account_outcome ACCOUNT  ->  `clean` or `unresolved`.
sc_account_outcome() {
    if [ "$(sc_account_summary "$1" | awk -F '\t' '$1 == "count.unresolved" { print $2 }')" = 0 ]; then
        echo clean
    else
        echo unresolved
    fi
}

# sc_account_valid ACCOUNT COMMIT  ->  succeeds for a well-formed account whose
# last merge is COMMIT.
sc_account_valid() {
    [ "$(sc_record_get "$1" schema 2>/dev/null || true)" = "$SC_ACCOUNT_SCHEMA" ] &&
        [ "$(sc_record_get "$1" last.commit 2>/dev/null || true)" = "$2" ] &&
        sc_is_sha "$(sc_record_get "$1" anchor.commit 2>/dev/null || true)"
}

# sc_chain_plan WALK  ->  how the ledger reaches a complete account for c.
# WALK lists c and then its first-parent ancestors, newest first, one per line:
#   commit<TAB>workflow<TAB>account<TAB>entry<TAB>checkpoint
# workflow: yes when the commit's tree carries the reference workflow.
# account:  complete when its ledger run produced a verified complete account.
# entry:    present, pending (its runs are still going) or missing.
# checkpoint: yes when the reviewed checkpoint file names this commit.
# Prints `base<TAB>anchor|account|checkpoint<TAB>commit` followed by one
# `gap<TAB>commit` per merge to apply, oldest first; or
# `outcome<TAB>pending|continuity-failure<TAB>detail`. The first commit lacking
# the workflow is p0, the anchor's parent: earlier history is not reconstructed.
sc_chain_plan() {
    awk -F '\t' '
        { sub(/\r$/, "") }
        NF < 5 { next }
        {
            n++
            commit[n] = $1; workflow[n] = $2; account[n] = $3; entry[n] = $4; checkpoint[n] = $5
        }
        END {
            if (n == 0) { print "outcome\tcontinuity-failure\tempty walk"; exit }
            pending = ""
            for (i = 1; i <= n; i++) {
                if (i > 1) {
                    kind = ""
                    if (workflow[i] != "yes") kind = "anchor"
                    else if (account[i] == "complete") kind = "account"
                    else if (checkpoint[i] == "yes") kind = "checkpoint"
                    if (kind != "") {
                        if (kind == "anchor" && i == 2 && workflow[1] != "yes") {
                            print "outcome\tcontinuity-failure\t" commit[1] " lacks the reference workflow"
                            exit
                        }
                        if (pending != "") { print "outcome\tpending\t" pending; exit }
                        print "base\t" kind "\t" commit[i]
                        for (j = i - 1; j >= 1; j--) print "gap\t" commit[j]
                        exit
                    }
                }
                if (entry[i] == "pending") {
                    if (pending == "") pending = commit[i] " ledger entry is pending"
                } else if (entry[i] != "present") {
                    print "outcome\tcontinuity-failure\t" commit[i] " has no ledger entry"
                    exit
                }
            }
            print "outcome\tcontinuity-failure\tno account, checkpoint or anchor within " n " commits"
        }
    ' "$1"
}
