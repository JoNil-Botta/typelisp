#!/usr/bin/env sh
set -eu

# check-instruction-counts.sh - Linux Cachegrind instruction-count gate.
#
# Per-benchmark checked-in files under `perf/benchmarks/<case>.tsv` hold suite
# membership and exact C reference counts (`benchmark/c-scalar/<case>`, plus
# optional `benchmark/c/<case>`), paired with per-case C provenance under
# `perf/benchmarks/<case>.provenance.json`.
#
# TypeLisp `Ir` counts are never checked into git. `.github/workflows/self-compile-reference.yml`
# publishes `insn-exec-reference` on every push to `main`. PR CI compares each
# TypeLisp benchmark against the tested merge's base parent (`HEAD^1`):
#   - `head <= base` passes and auto-ratchets on merge;
#   - `head > base` (even +1 Ir) fails closed unless declared in
#     `perf/insn-exec-declarations/pr-<N>.tsv` (subject to the same diff
#     immutability guard as `perf/self-compile-declarations/`).
#
# self_compile is not part of benchmark manifests; see `scripts/self-compile.sh`.

INSN_TOOL_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=${TYPELISP_INSN_EXEC_ROOT:-$(CDPATH= cd -- "$INSN_TOOL_DIR/.." && pwd)}
cd "$ROOT"
. "$INSN_TOOL_DIR/lib-gate.sh"
. "$INSN_TOOL_DIR/lib-benchmark.sh"
. "$INSN_TOOL_DIR/lib-c-provenance.sh"
. "$INSN_TOOL_DIR/lib-self-compile.sh"

INSN_REF_SCHEMA=typelisp-insn-exec-reference/1
INSN_REF_ARTIFACT=insn-exec-reference
INSN_DECL_DIR=perf/insn-exec-declarations
INSN_COMPARABLE_KEYS="procedure key.image_os key.valgrind key.as key.ld key.arch authority"
INSN_REF_REQUIRED_KEYS="schema commit tree role authority procedure compiler_sha256 compiler_commit key.image_os key.valgrind key.as key.ld key.arch info.image_version info.cpu"
INSN_WAIT_SECONDS=${TYPELISP_INSN_EXEC_WAIT_SECONDS:-1800}
INSN_POLL_SECONDS=${TYPELISP_INSN_EXEC_POLL_SECONDS:-60}
INSN_API_ATTEMPTS=3

insn_log() {
    printf '[ir-check] %s\n' "$*" >&2
}

insn_fail() {
    insn_log "$*"
    exit 1
}

insn_in_actions() {
    [ "${GITHUB_ACTIONS:-}" = true ]
}

insn_summary() {
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"
    fi
}

insn_decimal() {
    _id=${1#"${1%%[!0]*}"}
    printf '%s\n' "${_id:-0}"
}

case "$INSN_WAIT_SECONDS" in "" | *[!0-9]*) insn_fail "TYPELISP_INSN_EXEC_WAIT_SECONDS must be a non-negative integer: $INSN_WAIT_SECONDS" ;; esac
case "$INSN_POLL_SECONDS" in "" | *[!0-9]*) insn_fail "TYPELISP_INSN_EXEC_POLL_SECONDS must be a non-negative integer: $INSN_POLL_SECONDS" ;; esac
INSN_WAIT_SECONDS=$(insn_decimal "$INSN_WAIT_SECONDS")
INSN_POLL_SECONDS=$(insn_decimal "$INSN_POLL_SECONDS")

usage() {
    cat <<'EOF'
usage:
  scripts/check-instruction-counts.sh [options] [typelisp-seed]
  scripts/check-instruction-counts.sh reference --compiler PATH [--jobs N] [--output DIR]
  scripts/check-instruction-counts.sh finalize-ci
  scripts/check-instruction-counts.sh main-check [--prepare]
  scripts/check-instruction-counts.sh --self-test

Options (default check mode):
  --suite SUITE          Benchmark suite: instruction-main (default) or instruction-heavy
  --benchmarks LIST      Explicit comma-separated benchmark names (overrides --suite)
  --runs N               Cachegrind runs per metric (default: 1)
  --jobs N               Parallel benchmark workers (default: 1)
  --cycles               Also report native cycles (requires Linux perf)
  --output DIR           Work directory (default: target/instruction-count-check)
  --cached-base-only     In GitHub Actions PR CI, check base once and defer to finalize-ci
                         if the base reference is pending or unavailable
  --base-ref FILE        Compare TypeLisp Ir locally against a reference TSV (<= base)
  --write-reference FILE Measure selected cases and write a local TypeLisp reference TSV
  --update-c-baseline    Rewrite ONLY C rows in perf/benchmarks/<case>.tsv and
                         perf/benchmarks/<case>.provenance.json (never writes TypeLisp Ir)
  --benchmarks-only      Accepted for compatibility
  --self-test            Run host-independent comparison, manifest, declaration, cutover,
                         and provenance fixture tests and exit
  -h, --help             Show this help

Environment:
  TYPELISP_BIN                  Seed compiler when no argument is given
  TYPELISP_IR_CHECK_COMPILER    Prebuilt stage2 compiler (skips internal stage2 build)
  TYPELISP_IR_CHECK_RUNS        Default --runs
  TYPELISP_IR_CHECK_JOBS        Default --jobs
  TYPELISP_IR_CHECK_BENCHMARKS  Default --benchmarks
  TYPELISP_IR_CHECK_OUT         Default --output
EOF
}

# --- identity helpers -------------------------------------------------------

insn_first_line() {
    "$@" 2>/dev/null | sed -n '1{s/[[:space:]]*$//;p;}' || true
}

insn_procedure_hash() {
    for _iph_file in $SC_PROCEDURE_FILES; do
        [ -f "$ROOT/$_iph_file" ] || insn_fail "measurement procedure file missing: $_iph_file"
        printf '%s\t%s\n' "$_iph_file" "$(git hash-object -- "$ROOT/$_iph_file")"
    done | sha256sum | cut -c1-64
}

insn_cpu_model() {
    if [ -r /proc/cpuinfo ]; then
        awk -F ': *' '/^model name/ { print $2; exit }' /proc/cpuinfo
    else
        echo unknown
    fi
}

insn_authority() {
    if insn_in_actions && [ "${RUNNER_ENVIRONMENT:-}" = github-hosted ]; then
        echo hosted
    else
        echo local
    fi
}

insn_write_meta() {
    _iwm_compiler=$1
    _iwm_role=$2
    _iwm_out=$3
    _iwm_commit=$(git rev-parse HEAD)
    _iwm_tree=$(git rev-parse 'HEAD^{tree}')
    _iwm_stamp=$("$_iwm_compiler" --version 2>/dev/null | awk 'NR == 1 && $1 == "typelisp" { print $2 }')
    if [ -z "$_iwm_stamp" ]; then
        if insn_in_actions; then
            insn_fail "measured compiler reports no build commit (--version): $_iwm_compiler"
        fi
        _iwm_stamp=$_iwm_commit
    elif insn_in_actions && [ "$_iwm_stamp" != "$_iwm_commit" ]; then
        insn_fail "measured compiler was built from $_iwm_stamp, not checkout $_iwm_commit"
    fi
    mkdir -p "$(dirname -- "$_iwm_out")"
    {
        sc_record_line schema "$INSN_REF_SCHEMA"
        sc_record_line commit "$_iwm_commit"
        sc_record_line tree "$_iwm_tree"
        sc_record_line role "$_iwm_role"
        sc_record_line authority "$(insn_authority)"
        sc_record_line procedure "$(insn_procedure_hash)"
        sc_record_line compiler_sha256 "$(sha256sum "$_iwm_compiler" | cut -c1-64)"
        sc_record_line compiler_commit "$_iwm_stamp"
        sc_record_line key.image_os "${ImageOS:-unknown}"
        sc_record_line key.valgrind "$(insn_first_line valgrind --version)"
        sc_record_line key.as "$(insn_first_line as --version)"
        sc_record_line key.ld "$(insn_first_line ld --version)"
        sc_record_line key.arch "${RUNNER_ARCH:-$(uname -m)}"
        sc_record_line info.image_version "${ImageVersion:-unknown}"
        sc_record_line info.cpu "$(insn_cpu_model)"
        sc_record_line info.kernel "$(uname -r)"
        sc_record_line info.valgrind_package "$(dpkg-query -W -f='${Version}' valgrind 2>/dev/null || echo unknown)"
        sc_record_line info.runner_environment "${RUNNER_ENVIRONMENT:-local}"
        sc_record_line run.repository "${GITHUB_REPOSITORY:-local}"
        sc_record_line run.id "${GITHUB_RUN_ID:-local}"
        sc_record_line run.attempt "${GITHUB_RUN_ATTEMPT:-local}"
        sc_record_line run.workflow_ref "${GITHUB_WORKFLOW_REF:-local}"
        sc_record_line run.event "${GITHUB_EVENT_NAME:-local}"
        sc_record_line run.job "${GITHUB_JOB:-local}"
        sc_record_line run.sha "${GITHUB_SHA:-local}"
        sc_record_line measured_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$_iwm_out"
}

# --- pure validation & comparison functions ---------------------------------

# insn_declaration_parse FILE [VALID_CASES_CSV]
#   Parse `perf/insn-exec-declarations/pr-<N>.tsv`. Each non-empty line must
#   have three tab-separated fields:
#     benchmark/typelisp/<case>  +<max_delta_ir>  <non-empty reason>
#   No duplicate metrics; at least one row. Prints `metric\tmax_delta_ir`
#   (unsigned positive integer) on stdout, or a diagnostic and fails.
insn_declaration_parse() {
    _idp_file=$1
    _idp_valid_cases=${2:-}
    [ ! -L "$_idp_file" ] || { echo "declaration file must not be a symlink: $_idp_file"; return 1; }
    [ -f "$_idp_file" ] || { echo "missing declaration file: $_idp_file"; return 1; }
    awk -F '\t' -v valid_cases="$_idp_valid_cases" '
        BEGIN {
            if (valid_cases != "") {
                n = split(valid_cases, arr, ",")
                for (i = 1; i <= n; i++) if (arr[i] != "") known[arr[i]] = 1
                check_known = 1
            }
        }
        { sub(/\r$/, "") }
        $0 == "" { next }
        {
            lines++
            if (NF != 3) {
                print "line " NR ": declaration needs three tab-separated fields: metric, max_delta_ir, reason"
                bad = 1
                next
            }
            if ($1 !~ /^benchmark\/typelisp\/[A-Za-z0-9_.-]+$/) {
                print "line " NR ": invalid metric (expected benchmark/typelisp/<case>): " $1
                bad = 1
                next
            }
            if (seen[$1]++) {
                print "line " NR ": duplicate metric in declaration: " $1
                bad = 1
                next
            }
            if (check_known) {
                cname = substr($1, length("benchmark/typelisp/") + 1)
                if (!(cname in known)) {
                    print "line " NR ": declaration names unknown instruction benchmark: " $1
                    bad = 1
                    next
                }
            }
            val = $2
            sub(/^\+/, "", val)
            if (val !~ /^[1-9][0-9]*$/ || length(val) > 15) {
                print "line " NR ": max_delta_ir must be a positive integer (e.g. +500): " $2
                bad = 1
                next
            }
            if ($3 ~ /^[[:space:]]*$/) {
                print "line " NR ": declaration has an empty reason"
                bad = 1
                next
            }
            out_metric[lines] = $1
            out_val[lines] = val
        }
        END {
            if (lines == 0) {
                print "declaration file has no rows"
                exit 1
            }
            if (bad) exit 1
            for (i = 1; i <= lines; i++) {
                printf "%s\t%s\n", out_metric[i], out_val[i]
            }
        }
    ' "$_idp_file"
}

# insn_declaration_diff_check PR NAME_STATUS_FILE B_HAS_OWN
#   Enforce per-PR immutability on `perf/insn-exec-declarations/`: a PR may only
#   add its own `pr-<PR>.tsv` (and only when B lacks it), never add another PR's
#   declaration or modify, delete, or rename any existing declaration.
insn_declaration_diff_check() {
    awk -F '\t' -v pr="$1" -v b_has_own="$3" -v dir="$INSN_DECL_DIR" '
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

# insn_record_validate FILE [ROLE...]
#   Structural validation of an `insn-exec-reference` record.
insn_record_validate() {
    [ -f "$1" ] || { echo "missing record $1"; return 1; }
    awk -F '\t' -v required="$INSN_REF_REQUIRED_KEYS" -v schema="$INSN_REF_SCHEMA" '
        function problem(message) { print "record " ARGV[1] " " message; exit 1 }
        BEGIN {
            while ((getline line < ARGV[1]) > 0) {
                sub(/\r$/, "", line)
                if (line == "") continue
                pos = index(line, "\t")
                key = pos ? substr(line, 1, pos - 1) : line
                val = pos ? substr(line, pos + 1) : ""
                if (key ~ /^self_compile\//) problem("carries forbidden self_compile row " key)
                if (key ~ /^benchmark\/typelisp\//) {
                    if (seen_bench[key]++) problem("has duplicate row " key)
                    if (val !~ /^[1-9][0-9]*$/ || length(val) > 15) problem("has malformed ir_count for " key)
                    bench_count++
                } else if (!(key in rec)) {
                    rec[key] = "x" val
                }
            }
            close(ARGV[1])
            n = split(required, keys, " ")
            for (i = 1; i <= n; i++) {
                k = keys[i]
                if (!(k in rec)) problem("lacks " k)
                if (length(substr(rec[k], 2)) == 0) problem("has an empty " k)
            }
            if (rec["schema"] != "x" schema) problem("has schema " substr(rec["schema"], 2) ", expected " schema)
            for (i = 1; i <= 2; i++) {
                k = i == 1 ? "commit" : "tree"
                sha = substr(rec[k], 2)
                if (length(sha) != 40 || sha ~ /[^0-9a-f]/) problem("has malformed " k)
            }
            if (rec["compiler_commit"] != rec["commit"]) {
                problem("measured compiler stamped " substr(rec["compiler_commit"], 2) ", not its commit")
            }
            if (bench_count == 0) problem("has no benchmark/typelisp rows")
            if (ARGC > 2) {
                wants = ""
                for (i = 2; i < ARGC; i++) {
                    if (rec["role"] == "x" ARGV[i]) ok = 1
                    wants = wants (i == 2 ? "" : " ") ARGV[i]
                }
                if (!ok) problem("has role " substr(rec["role"], 2) ", expected one of: " wants)
            }
            exit 0
        }
    ' "$@"
}

insn_records_comparable() {
    awk -v keys="$INSN_COMPARABLE_KEYS" "$SC_RECORD_AWK"'
        BEGIN {
            record_read(ARGV[1], 1)
            record_read(ARGV[2], 2)
            n = split(keys, names, " ")
            for (i = 1; i <= n; i++) {
                key = names[i]
                a = ((1 SUBSEP key) in rec) ? rec[1, key] : "x<missing>"
                b = ((2 SUBSEP key) in rec) ? rec[2, key] : "x<missing>"
                if (a != b || a == "xunknown" || a == "x<missing>") {
                    print key ": " substr(a, 2) " | " substr(b, 2)
                    bad = 1
                }
            }
            exit bad ? 1 : 0
        }' "$1" "$2"
}

# insn_reference_record_check REF HEAD_META REPO RUN_ID ATTEMPT COMMIT EXPECT_ROLE
insn_reference_record_check() {
    _irrc_ref=$1
    _irrc_status=0
    _irrc_msg=$(insn_record_validate "$_irrc_ref" "$7") || { echo "$_irrc_msg"; return 1; }
    [ "$(sc_record_get "$_irrc_ref" commit)" = "$6" ] || {
        echo "record commit $(sc_record_get "$_irrc_ref" commit) is not $6"
        _irrc_status=1
    }
    [ "$(sc_record_get "$_irrc_ref" authority)" = hosted ] || {
        echo "record authority is $(sc_record_get "$_irrc_ref" authority), not hosted"
        _irrc_status=1
    }
    [ "$(sc_record_get "$_irrc_ref" run.repository 2>/dev/null || true)" = "$3" ] || {
        echo "record repository $(sc_record_get "$_irrc_ref" run.repository 2>/dev/null || true) is not $3"
        _irrc_status=1
    }
    [ "$(sc_record_get "$_irrc_ref" run.id 2>/dev/null || true)" = "$4" ] || {
        echo "record run $(sc_record_get "$_irrc_ref" run.id 2>/dev/null || true) is not producer run $4"
        _irrc_status=1
    }
    [ "$(sc_record_get "$_irrc_ref" run.attempt 2>/dev/null || true)" = "$5" ] || {
        echo "record attempt $(sc_record_get "$_irrc_ref" run.attempt 2>/dev/null || true) is not producer attempt $5"
        _irrc_status=1
    }
    [ "$(sc_record_get "$_irrc_ref" run.event 2>/dev/null || true)" = push ] || {
        echo "record event $(sc_record_get "$_irrc_ref" run.event 2>/dev/null || true) is not push"
        _irrc_status=1
    }
    case "$(sc_record_get "$_irrc_ref" run.workflow_ref 2>/dev/null || true)" in
        "$3/$SC_REFERENCE_WORKFLOW@refs/heads/main") ;;
        *)
            echo "record workflow $(sc_record_get "$_irrc_ref" run.workflow_ref 2>/dev/null || true) is not $3/$SC_REFERENCE_WORKFLOW@refs/heads/main"
            _irrc_status=1
            ;;
    esac
    if ! _irrc_diff=$(insn_records_comparable "$2" "$_irrc_ref"); then
        printf '%s\n' "$_irrc_diff" | sed 's/^/identity differs: /'
        _irrc_status=1
    fi
    return "$_irrc_status"
}

# Exact comparison for C rows (`benchmark/c-scalar/*` and optional `benchmark/c/*`).
# Fails on any delta != 0 (both directions), missing, or extra row.
INSN_C_COMPARE_AWK='
function benchmark_case(name,    part, count) {
    count = split(name, part, "/")
    if (count == 3 && part[1] == "benchmark" && (part[2] == "c" || part[2] == "c-scalar")) {
        return part[3]
    }
    return ""
}
function selected_metric(name,    case_name) {
    case_name = benchmark_case(name)
    return case_name != "" && (benchmarks == "" || (case_name in selected_benchmark))
}
function signed(n,    s) {
    s = sprintf("%.0f", n)
    if (n > 0) return "+" s
    return s
}
function pct(delta, base) {
    if (base == 0) return "n/a"
    return sprintf("%+.6f%%", (delta * 100.0) / base)
}
BEGIN {
    selected_count = split(benchmarks, selected_name, ",")
    for (selected_i = 1; selected_i <= selected_count; selected_i++) {
        if (selected_name[selected_i] != "") selected_benchmark[selected_name[selected_i]] = 1
    }
    print "metric | baseline | current | delta | pct | status"
}
NR == FNR {
    sub(/\r$/, "")
    if ((FNR == 1 && $1 == "name") || NF < 2) next
    if (!selected_metric($1)) next
    baseline[$1] = $2
    baseline_order[++baseline_count] = $1
    next
}
{
    sub(/\r$/, "")
    if ((FNR == 1 && $1 == "name") || NF < 2) next
    if (!selected_metric($1)) next
    current[$1] = $2
    current_order[++current_count] = $1
}
END {
    failed = 0
    for (i = 1; i <= baseline_count; i++) {
        name = baseline_order[i]
        base = baseline[name]
        if (!(name in current)) {
            print name " | " base " | <missing> | n/a | n/a | missing-current"
            failed = 1
            continue
        }
        now = current[name]
        delta = (now + 0) - (base + 0)
        status = "ok"
        if (delta > 0) { status = "REGRESSION"; failed = 1 }
        else if (delta < 0) { status = "IMPROVEMENT"; failed = 1 }
        print name " | " base " | " now " | " signed(delta) " | " pct(delta, base + 0) " | " status
        if (result_out != "") {
            printf "%s\t%s\t%s\t%s\t%s\t%s\t-\t%s\t%s\t%s\tperf/benchmarks/%s.tsv\n", \
                name, base, now, signed(delta), pct(delta, base + 0), status, \
                suite, base_commit, head_commit, benchmark_case(name) >> result_out
        }
    }
    for (i = 1; i <= current_count; i++) {
        name = current_order[i]
        if (!(name in baseline)) {
            print name " | <missing> | " current[name] " | n/a | n/a | extra-current"
            failed = 1
        }
    }
    if (result_out != "") close(result_out)
    exit failed ? 1 : 0
}
'

compare_c_counts() {
    _ccc_base=$1
    _ccc_cur=$2
    _ccc_cases=$3
    _ccc_res=${4:-}
    _ccc_suite=${5:-}
    _ccc_bsha=${6:-local}
    _ccc_hsha=${7:-local}
    awk -F '	' \
        -v benchmarks="$_ccc_cases" \
        -v result_out="$_ccc_res" \
        -v suite="$_ccc_suite" \
        -v base_commit="$_ccc_bsha" \
        -v head_commit="$_ccc_hsha" \
        "$INSN_C_COMPARE_AWK" "$_ccc_base" "$_ccc_cur"
}

# TypeLisp comparison (`benchmark/typelisp/<case>`):
#   - now == base: ok (PASS)
#   - now <  base: IMPROVEMENT (PASS, auto-ratchets on merge)
#   - now >  base: declared-ok if declared with delta <= max_delta_ir;
#                  DECLARATION-EXCEEDED or REGRESSION (FAIL CLOSED) otherwise.
#   - missing in base: new-benchmark (PASS) iff case is in new_cases, else missing-base (FAIL).
INSN_TL_COMPARE_AWK="$SC_BN_AWK"'
function pct_str(delta, base) {
    if ((base + 0) == 0) return "n/a"
    return sprintf("%+.6f%%", ((delta + 0.0) * 100.0) / (base + 0.0))
}
function signed_bn(v) {
    v = bn_strip(v)
    if (v == "0" || substr(v, 1, 1) == "-") return v
    return "+" v
}
BEGIN {
    ns = split(benchmarks, sarr, ",")
    for (i = 1; i <= ns; i++) {
        if (sarr[i] != "" && !seen_sel[sarr[i]]++) {
            sel_order[++sel_count] = sarr[i]
            selected[sarr[i]] = 1
        }
    }
    nn = split(new_cases, narr, ",")
    for (i = 1; i <= nn; i++) {
        if (narr[i] != "") is_new[narr[i]] = 1
    }
}
{
    sub(/\r$/, "")
    if ($0 == "" || NF < 2) next
    if (FILENAME == ARGV[1]) {
        if ($1 ~ /^benchmark\/typelisp\//) base[$1] = $2
    } else if (FILENAME == ARGV[2]) {
        if ($1 ~ /^benchmark\/typelisp\//) {
            cur[$1] = $2
            cur_order[++cur_count] = $1
        }
    } else if (FILENAME == ARGV[3]) {
        if ($1 ~ /^benchmark\/typelisp\//) decl[$1] = $2
    }
}
END {
    print "metric | baseline | current | delta | pct | status"
    failed = 0
    for (i = 1; i <= sel_count; i++) {
        cname = sel_order[i]
        m = "benchmark/typelisp/" cname
        dmax = (m in decl) ? decl[m] : "-"
        if (!(m in cur)) {
            print m " | " ((m in base) ? base[m] : "<missing>") " | <missing> | n/a | n/a | missing-current"
            if (result_out != "") {
                printf "%s\t%s\t<missing>\tn/a\tn/a\tmissing-current\t%s\t%s\t%s\t%s\t%s\n", \
                    m, ((m in base) ? base[m] : "<missing>"), dmax, suite, base_commit, head_commit, base_source >> result_out
            }
            failed = 1
            continue
        }
        now = cur[m]
        if (!(m in base)) {
            if (cname in is_new) {
                print m " | <new> | " now " | n/a | n/a | new-benchmark"
                if (result_out != "") {
                    printf "%s\t<new>\t%s\tn/a\tn/a\tnew-benchmark\t%s\t%s\t%s\t%s\t%s\n", \
                        m, now, dmax, suite, base_commit, head_commit, base_source >> result_out
                }
            } else {
                print m " | <missing> | " now " | n/a | n/a | missing-base"
                if (result_out != "") {
                    printf "%s\t<missing>\t%s\tn/a\tn/a\tmissing-base\t%s\t%s\t%s\t%s\t%s\n", \
                        m, now, dmax, suite, base_commit, head_commit, base_source >> result_out
                }
                failed = 1
            }
            continue
        }
        b = base[m]
        delta = bn_sub(now, b)
        cmp = bn_cmp(delta, "0")
        if (cmp == 0) {
            status = "ok"
        } else if (cmp < 0) {
            status = "IMPROVEMENT"
        } else {
            if (m in decl) {
                if (bn_cmp(delta, decl[m]) <= 0) {
                    status = "declared-ok"
                } else {
                    status = "DECLARATION-EXCEEDED"
                    failed = 1
                }
            } else {
                status = "REGRESSION"
                failed = 1
            }
        }
        sdelta = signed_bn(delta)
        spct = pct_str(delta, b)
        print m " | " b " | " now " | " sdelta " | " spct " | " status
        if (result_out != "") {
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
                m, b, now, sdelta, spct, status, dmax, suite, base_commit, head_commit, base_source >> result_out
        }
    }
    for (i = 1; i <= cur_count; i++) {
        m = cur_order[i]
        cname = substr(m, length("benchmark/typelisp/") + 1)
        if (!(cname in selected)) {
            print m " | <missing> | " cur[m] " | n/a | n/a | extra-current"
            failed = 1
        }
    }
    if (result_out != "") close(result_out)
    exit failed ? 1 : 0
}
'

compare_tl_counts() {
    _ctc_base=$1
    _ctc_cur=$2
    _ctc_decl=$3
    _ctc_cases=$4
    _ctc_new=$5
    _ctc_res=${6:-}
    _ctc_suite=${7:-}
    _ctc_bsha=${8:-local}
    _ctc_hsha=${9:-local}
    _ctc_src=${10:-local}
    awk -F '	' \
        -v benchmarks="$_ctc_cases" \
        -v new_cases="$_ctc_new" \
        -v result_out="$_ctc_res" \
        -v suite="$_ctc_suite" \
        -v base_commit="$_ctc_bsha" \
        -v head_commit="$_ctc_hsha" \
        -v base_source="$_ctc_src" \
        "$INSN_TL_COMPARE_AWK" "$_ctc_base" "$_ctc_cur" "$_ctc_decl"
}

# --- git / cutover helpers --------------------------------------------------

# extract_legacy_tl_baseline COMMIT OUT_FILE
#   Pre-cutover fallback: when COMMIT predates `perf/benchmarks/` (still carries
#   `perf/insn-exec-baseline.tsv`), extract its TypeLisp Ir rows from git objects.
extract_legacy_tl_baseline() {
    _eltb_commit=$1
    _eltb_out=$2
    git cat-file -e "$_eltb_commit:perf/insn-exec-baseline.tsv" 2>/dev/null || return 1
    {
        git show "$_eltb_commit:perf/insn-exec-baseline.tsv"
        if git cat-file -e "$_eltb_commit:perf/insn-exec-heavy-baseline.tsv" 2>/dev/null; then
            git show "$_eltb_commit:perf/insn-exec-heavy-baseline.tsv"
        fi
    } | awk -F '\t' '
        { sub(/\r$/, "") }
        $1 ~ /^self_compile\// { print "legacy baseline carries self_compile row: " $1 > "/dev/stderr"; bad = 1 }
        $1 ~ /^benchmark\/typelisp\// && $2 ~ /^[1-9][0-9]*$/ {
            if (!seen[$1]++) printf "%s\t%s\n", $1, $2
        }
        END { exit (bad || !length(seen)) ? 1 : 0 }
    ' > "$_eltb_out"
}

# commit_instruction_cases COMMIT
#   Print newline-separated benchmark cases gated in instruction-main or
#   instruction-heavy at COMMIT (works both pre-cutover and post-cutover).
commit_instruction_cases() {
    _cic_commit=$1
    if git cat-file -e "$_cic_commit:perf/insn-exec-baseline.tsv" 2>/dev/null; then
        {
            git show "$_cic_commit:perf/insn-exec-baseline.tsv"
            if git cat-file -e "$_cic_commit:perf/insn-exec-heavy-baseline.tsv" 2>/dev/null; then
                git show "$_cic_commit:perf/insn-exec-heavy-baseline.tsv"
            fi
        } | awk -F '\t' '
            { sub(/\r$/, "") }
            $1 ~ /^benchmark\/typelisp\// {
                c = substr($1, length("benchmark/typelisp/") + 1)
                if (!seen[c]++) print c
            }
        '
        return 0
    fi
    for _cic_path in $(git ls-tree --name-only "$_cic_commit" perf/benchmarks/ 2>/dev/null | LC_ALL=C sort); do
        case "$_cic_path" in *.tsv) ;; *) continue ;; esac
        _cic_suites=$(git show "$_cic_commit:$_cic_path" | awk -F '\t' '$1 == "suites" { sub(/\r$/, "", $2); print $2; exit }')
        case ",$_cic_suites," in
            *,instruction-main,* | *,instruction-heavy,*)
                _cic_case=${_cic_path#perf/benchmarks/}
                printf '%s\n' "${_cic_case%.tsv}"
                ;;
        esac
    done
}

# new_cases_between BASE_COMMIT CASES_CSV
#   Print comma-separated cases from CASES_CSV that were not instruction-gated
#   in BASE_COMMIT.
new_cases_between() {
    _ncb_base=$1
    _ncb_cases=$2
    commit_instruction_cases "$_ncb_base" | awk -v cases="$_ncb_cases" '
        { old[$0] = 1 }
        END {
            n = split(cases, arr, ",")
            for (i = 1; i <= n; i++) {
                c = arr[i]
                if (c != "" && !(c in old) && !seen[c]++) {
                    out = (out == "" ? c : out "," c)
                }
            }
            print out
        }
    '
}

# insn_filter_base_cases BASE_COMMIT CASES_CSV
#   Print comma-separated cases from CASES_CSV that were instruction-gated in
#   BASE_COMMIT (matching commit_instruction_cases and new_cases_between).
insn_filter_base_cases() {
    _ifbc_base=$1
    _ifbc_cases=$2
    commit_instruction_cases "$_ifbc_base" | awk -v cases="$_ifbc_cases" '
        { old[$0] = 1 }
        END {
            n = split(cases, arr, ",")
            for (i = 1; i <= n; i++) {
                c = arr[i]
                if (c != "" && (c in old) && !seen[c]++) {
                    out = (out == "" ? c : out "," c)
                }
            }
            print out
        }
    '
}

all_instruction_cases_csv() {
    _aic_main=$(benchmark_ci_case_csv "$ROOT" instruction-main) || return 1
    _aic_heavy=$(benchmark_ci_case_csv "$ROOT" instruction-heavy) || return 1
    printf '%s,%s\n' "$_aic_main" "$_aic_heavy" | tr ',' '\n' | LC_ALL=C sort -u | paste -sd, -
}

# --- GitHub API helpers (overridable by --self-test) ------------------------

insn_api() {
    _ia_try=1
    while :; do
        if gh api -H 'Accept: application/vnd.github+json' "$1" > "$2.attempt-$_ia_try" \
            2> "$2.attempt-$_ia_try.stderr" &&
            jq -e . "$2.attempt-$_ia_try" >/dev/null 2>&1; then
            cp "$2.attempt-$_ia_try" "$2"
            return 0
        fi
        [ "$_ia_try" -lt "$INSN_API_ATTEMPTS" ] || return 1
        _ia_try=$((_ia_try + 1))
        sleep 10
    done
}

insn_download_artifact() {
    mkdir -p "$2" || return 1
    gh api -H 'Accept: application/vnd.github+json' \
        "repos/$GITHUB_REPOSITORY/actions/artifacts/$1/zip" > "$2.zip" 2> "$2.zip.stderr" &&
        unzip -q -o "$2.zip" -d "$2"
}

# insn_resolve_reference COMMIT HEAD_META DEST
#   Locate the push-to-main `insn-exec-reference` artifact for COMMIT from
#   `.github/workflows/self-compile-reference.yml`.
#   Sets INSN_REF_STATUS to ok, pending, absent, rejected, or api-error,
#   and INSN_REF_RUN / INSN_REF_ATTEMPT.
insn_resolve_reference() {
    _irr_commit=$1
    _irr_head_meta=$2
    _irr_dest=$3
    mkdir -p "$_irr_dest"
    : > "$_irr_dest/reasons"
    INSN_REF_RUN=
    INSN_REF_ATTEMPT=
    if ! insn_api "repos/$GITHUB_REPOSITORY/actions/workflows/$(basename "$SC_REFERENCE_WORKFLOW")/runs?event=push&branch=main&head_sha=$_irr_commit&per_page=50" \
        "$_irr_dest/runs.json"; then
        INSN_REF_STATUS=api-error
        echo "reference: listing runs for $_irr_commit failed" >> "$_irr_dest/reasons"
        return 0
    fi
    if ! _irr_sel=$(sc_select_reference_run "$_irr_dest/runs.json" "$GITHUB_REPOSITORY" "$_irr_commit"); then
        INSN_REF_STATUS=api-error
        echo "reference: invalid runs JSON for $_irr_commit" >> "$_irr_dest/reasons"
        return 0
    fi
    if [ -z "$_irr_sel" ]; then
        INSN_REF_STATUS=absent
        echo "reference: no push-to-main run of $SC_REFERENCE_WORKFLOW for $_irr_commit" >> "$_irr_dest/reasons"
        return 0
    fi
    INSN_REF_RUN=$(printf '%s' "$_irr_sel" | cut -f1)
    _irr_runstatus=$(printf '%s' "$_irr_sel" | cut -f3)
    if ! insn_api "repos/$GITHUB_REPOSITORY/actions/runs/$INSN_REF_RUN/jobs?filter=all&per_page=100" \
        "$_irr_dest/jobs.json"; then
        INSN_REF_STATUS=api-error
        echo "reference: listing jobs of run $INSN_REF_RUN failed" >> "$_irr_dest/reasons"
        return 0
    fi
    if ! _irr_jobstate=$(sc_job_latest "$_irr_dest/jobs.json" "$SC_REFERENCE_JOB_NAME"); then
        INSN_REF_STATUS=api-error
        echo "reference: invalid jobs JSON for run $INSN_REF_RUN" >> "$_irr_dest/reasons"
        return 0
    fi
    INSN_REF_ATTEMPT=$(printf '%s' "$_irr_jobstate" | cut -f1)
    _irr_jobstatus=$(printf '%s' "$_irr_jobstate" | cut -f2)
    _irr_jobconc=$(printf '%s' "$_irr_jobstate" | cut -f3)
    if [ -z "$_irr_jobstate" ] && [ "$_irr_runstatus" = completed ]; then
        INSN_REF_STATUS=rejected
        echo "reference: completed run $INSN_REF_RUN lacks job '$SC_REFERENCE_JOB_NAME'" >> "$_irr_dest/reasons"
        return 0
    fi
    if [ -z "$_irr_jobstate" ] || [ "$_irr_jobstatus" != completed ]; then
        INSN_REF_STATUS=pending
        echo "reference: job '$SC_REFERENCE_JOB_NAME' of run $INSN_REF_RUN is ${_irr_jobstatus:-not started}" >> "$_irr_dest/reasons"
        return 0
    fi
    if [ "$_irr_jobconc" != success ]; then
        INSN_REF_STATUS=rejected
        echo "reference: job '$SC_REFERENCE_JOB_NAME' concluded $_irr_jobconc" >> "$_irr_dest/reasons"
        return 0
    fi
    if ! insn_api "repos/$GITHUB_REPOSITORY/actions/runs/$INSN_REF_RUN/artifacts?name=$INSN_REF_ARTIFACT&per_page=100" \
        "$_irr_dest/artifacts.json"; then
        INSN_REF_STATUS=api-error
        echo "reference: listing artifacts of run $INSN_REF_RUN failed" >> "$_irr_dest/reasons"
        return 0
    fi
    _irr_id=$(sc_select_artifact "$_irr_dest/artifacts.json" "$INSN_REF_ARTIFACT" "$INSN_REF_RUN")
    if [ -z "$_irr_id" ]; then
        INSN_REF_STATUS=absent
        echo "reference: run $INSN_REF_RUN has no unexpired $INSN_REF_ARTIFACT artifact" >> "$_irr_dest/reasons"
        return 0
    fi
    if ! insn_download_artifact "$_irr_id" "$_irr_dest/artifact"; then
        INSN_REF_STATUS=api-error
        echo "reference: downloading $INSN_REF_ARTIFACT from run $INSN_REF_RUN failed" >> "$_irr_dest/reasons"
        return 0
    fi
    if ! _irr_probs=$(insn_reference_record_check "$_irr_dest/artifact/record.tsv" "$_irr_head_meta" \
        "$GITHUB_REPOSITORY" "$INSN_REF_RUN" "$INSN_REF_ATTEMPT" "$_irr_commit" reference); then
        INSN_REF_STATUS=rejected
        printf '%s\n' "$_irr_probs" | sed 's/^/reference: /' >> "$_irr_dest/reasons"
        return 0
    fi
    if [ "$(sc_record_get "$_irr_dest/artifact/record.tsv" tree)" != "$(git rev-parse "$_irr_commit^{tree}")" ]; then
        INSN_REF_STATUS=rejected
        echo "reference: record tree is not the tree of $_irr_commit" >> "$_irr_dest/reasons"
        return 0
    fi
    cp "$_irr_dest/artifact/record.tsv" "$_irr_dest/record.tsv"
    INSN_REF_STATUS=ok
}

# --- in-place base fallback (post-cutover when reference is unavailable) ----

insn_run_fallback() {
    _irf_base=$1
    _irf_head=$2
    _irf_cases=$3
    _irf_record=$4
    _irf_role=$5
    case "$_irf_record" in
        /*) _irf_rec_path=$_irf_record ;;
        *) _irf_rec_path=$ROOT/$_irf_record ;;
    esac
    _irf_tool=$(mktemp -d "${RUNNER_TEMP:-/tmp}/insn-exec-tool.XXXXXX") ||
        insn_fail "cannot create directory for fallback tool copy"
    for _irf_f in check-instruction-counts.sh measure-instruction-counts.sh \
        lib-benchmark.sh lib-c-provenance.sh lib-gate.sh lib-native-link.sh \
        lib-linux-entry.sh lib-self-compile.sh lib-stage0.sh fetch-stage0.sh; do
        cp "$INSN_TOOL_DIR/$_irf_f" "$_irf_tool/"
    done
    TYPELISP_INSN_EXEC_ROOT=$ROOT sh "$_irf_tool/check-instruction-counts.sh" fallback \
        "$_irf_base" "$_irf_head" "$_irf_cases" "$_irf_rec_path" "$_irf_role"
    rm -rf -- "$_irf_tool"
}

insn_cmd_fallback() {
    [ "$#" -eq 5 ] || { usage >&2; exit 2; }
    _icf_base=$1
    _icf_head=$2
    _icf_cases=$3
    _icf_record=$4
    _icf_role=$5
    sc_is_sha "$_icf_base" || insn_fail "fallback base is not a commit id: $_icf_base"
    sc_is_sha "$_icf_head" || insn_fail "fallback head is not a commit id: $_icf_head"
    [ "$(git rev-parse HEAD)" = "$_icf_head" ] || insn_fail "checkout is not at $_icf_head"
    git diff --quiet && git diff --cached --quiet ||
        insn_fail "tracked files changed during CI; refusing to switch checkout"
    git cat-file -e "$_icf_base^{commit}" 2>/dev/null ||
        git fetch --no-tags --depth=1 origin "$_icf_base" >/dev/null 2>&1 ||
        insn_fail "cannot fetch base commit $_icf_base"
    _icf_hold=$(mktemp -d "${RUNNER_TEMP:-/tmp}/insn-exec-hold.XXXXXX") ||
        insn_fail "cannot create directory to hold head target/"
    _icf_status=0
    _icf_at_base=0
    _icf_moved=0
    _icf_restored=0
    insn_fallback_restore() {
        [ "$_icf_restored" -eq 0 ] || return 0
        _icf_restored=1
        if [ "$_icf_at_base" -eq 1 ]; then
            # shellcheck disable=SC2086
            git checkout --quiet "$_icf_base" -- $SC_PROCEDURE_FILES ||
                insn_log "could not undo harness overlay on $_icf_base"
        fi
        git -c advice.detachedHead=false checkout --quiet --detach "$_icf_head" || {
            insn_log "could not restore $_icf_head after fallback"
            return 1
        }
        if [ "$_icf_moved" -eq 1 ]; then
            [ -d target ] && rm -rf target
            mv "$_icf_hold/head-target" target
        fi
    }
    trap 'insn_fallback_restore; exit 1' INT TERM HUP
    trap 'insn_fallback_restore' EXIT
    if [ -d target ]; then
        mv target "$_icf_hold/head-target"
        _icf_moved=1
    fi
    insn_log "fallback: measuring $_icf_base in place ($_icf_role) for cases: $_icf_cases"
    if git -c advice.detachedHead=false checkout --quiet --detach "$_icf_base"; then
        _icf_at_base=1
    else
        _icf_status=1
    fi
    if [ "$_icf_status" -eq 0 ]; then
        _icf_seed=$ROOT/target/stage0/typelisp
        sh "$INSN_TOOL_DIR/fetch-stage0.sh" --at-commit "$_icf_base" "$ROOT/target/stage0" || _icf_status=1
    fi
    if [ "$_icf_status" -eq 0 ]; then
        env -u TYPELISP_CI_TIMING TYPELISP_BIN="$_icf_seed" sh scripts/ci-verify.sh --gates bootstrap-fixpoint ||
            _icf_status=1
    fi
    if [ "$_icf_status" -eq 0 ]; then
        # shellcheck disable=SC2086
        git checkout --quiet "$_icf_head" -- $SC_PROCEDURE_FILES || _icf_status=1
    fi
    if [ "$_icf_status" -eq 0 ]; then
        _icf_stage2=$(cat target/ci-verify-stage2.path 2>/dev/null || true)
        [ -x "$_icf_stage2" ] || _icf_status=1
    fi
    # Filter cases to those instruction-gated in BASE (matching commit_instruction_cases).
    if [ "$_icf_status" -eq 0 ]; then
        _icf_base_cases=$(insn_filter_base_cases "$_icf_base" "$_icf_cases")
        if [ -n "$_icf_base_cases" ]; then
            env -i PATH="$PATH" HOME="${HOME:-}" LC_ALL=C \
                GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-local}" GITHUB_RUN_ID="${GITHUB_RUN_ID:-local}" \
                GITHUB_RUN_ATTEMPT="${GITHUB_RUN_ATTEMPT:-local}" GITHUB_WORKFLOW_REF="${GITHUB_WORKFLOW_REF:-local}" \
                GITHUB_JOB="${GITHUB_JOB:-local}" ImageOS="${ImageOS:-unknown}" ImageVersion="${ImageVersion:-unknown}" \
                scripts/measure-instruction-counts.sh \
                --runs 1 \
                --jobs 4 \
                --cases "$_icf_base_cases" \
                --output target/insn-exec-fallback-measure \
                --benchmarks-only \
                --c-scalar \
                "$_icf_stage2" || _icf_status=1
        fi
    fi
    if [ "$_icf_status" -eq 0 ]; then
        insn_write_meta "$_icf_stage2" "$_icf_role" "$_icf_hold/record.tsv" || _icf_status=1
    fi
    if [ "$_icf_status" -eq 0 ] && [ -f target/insn-exec-fallback-measure/summary.tsv ]; then
        awk -F '\t' 'BEGIN { OFS = "\t" } NR > 1 && $1 == "benchmark/typelisp" { print $1 "/" $2, $3 }' \
            target/insn-exec-fallback-measure/summary.tsv >> "$_icf_hold/record.tsv"
    fi
    insn_fallback_restore || insn_fail "could not restore head checkout after fallback"
    trap - INT TERM HUP EXIT
    [ "$_icf_status" -eq 0 ] || { rm -rf -- "$_icf_hold"; insn_fail "fallback measurement of $_icf_base failed"; }
    mkdir -p "$(dirname -- "$_icf_record")"
    cp "$_icf_hold/record.tsv" "$_icf_record"
    rm -rf -- "$_icf_hold"
}

# --- subcommand: reference (self-compile-reference.yml measure job) ---------

insn_cmd_reference() {
    _icr_compiler=
    _icr_jobs=4
    _icr_out=target/insn-exec/reference
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --compiler) [ "$#" -ge 2 ] || insn_fail "missing value for --compiler"; _icr_compiler=$2; shift 2 ;;
            --jobs) [ "$#" -ge 2 ] || insn_fail "missing value for --jobs"; _icr_jobs=$2; shift 2 ;;
            --output) [ "$#" -ge 2 ] || insn_fail "missing value for --output"; _icr_out=$2; shift 2 ;;
            -h | --help) usage; exit 0 ;;
            *) insn_fail "unknown reference option: $1" ;;
        esac
    done
    [ -n "$_icr_compiler" ] || insn_fail "reference requires --compiler PATH"
    case "$_icr_compiler" in /*) ;; *) _icr_compiler="$ROOT/$_icr_compiler" ;; esac
    [ -x "$_icr_compiler" ] || insn_fail "compiler is not executable: $_icr_compiler"
    case "$(realpath -m -- "$_icr_out")" in
        "$(realpath -m -- "$ROOT")/target/"*) ;;
        *) insn_fail "--output must be inside this checkout's target/ scratch root: $_icr_out" ;;
    esac

    _icr_cases=$(all_instruction_cases_csv) || exit 1
    rm -rf -- "${_icr_out:?}"
    mkdir -p "$_icr_out"

    _icr_c_base="$_icr_out/c-baseline.tsv"
    benchmark_manifest_c_rows "$(benchmark_manifest_dir "$ROOT")" "$_icr_cases" "$_icr_c_base" || exit 1
    for _icr_c in $(printf '%s' "$_icr_cases" | tr ',' ' '); do
        _icr_p="$ROOT/perf/benchmarks/$_icr_c.provenance.json"
        [ -f "$_icr_p" ] || insn_fail "missing per-case C provenance file: $_icr_p"
        c_provenance_validate_case "$_icr_p" "$_icr_c" || exit 1
    done

    insn_log "reference: measuring all instruction-gated cases ($_icr_jobs workers)"
    env -i PATH="$PATH" HOME="${HOME:-}" LC_ALL=C \
        GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-local}" GITHUB_RUN_ID="${GITHUB_RUN_ID:-local}" \
        GITHUB_RUN_ATTEMPT="${GITHUB_RUN_ATTEMPT:-local}" GITHUB_WORKFLOW_REF="${GITHUB_WORKFLOW_REF:-local}" \
        GITHUB_JOB="${GITHUB_JOB:-local}" ImageOS="${ImageOS:-unknown}" ImageVersion="${ImageVersion:-unknown}" \
        scripts/measure-instruction-counts.sh \
        --runs 1 \
        --jobs "$_icr_jobs" \
        --cases "$_icr_cases" \
        --output "$_icr_out/measure" \
        --benchmarks-only \
        --c-scalar \
        "$_icr_compiler"

    c_provenance_validate "$_icr_out/measure/c-provenance.json" measured || exit 1

    # Filter measured C rows to the gated C rows for each case, then assert exact C equality.
    awk -F '\t' '
        BEGIN { OFS = "\t" }
        NR == FNR {
            if (NR > 1 && NF >= 2) gated[$1] = 1
            next
        }
        NR == 1 { next }
        {
            metric = $1 "/" $2
            if ($1 == "benchmark/c-scalar" || ($1 == "benchmark/c" && (metric in gated))) {
                print metric, $3
            }
        }
    ' "$_icr_c_base" "$_icr_out/measure/summary.tsv" > "$_icr_out/current-c.tsv"

    if ! compare_c_counts "$_icr_c_base" "$_icr_out/current-c.tsv" "$_icr_cases" > "$_icr_out/c-diff.txt"; then
        cat "$_icr_out/c-diff.txt" >&2
        c_provenance_diagnose_dir "$(benchmark_manifest_dir "$ROOT")" \
            "$_icr_out/measure/c-provenance.json" "$_icr_c_base" "$_icr_out/c-diff.txt" >&2
        insn_fail "reference C counts do not match perf/benchmarks/*.tsv"
    fi

    insn_write_meta "$_icr_compiler" reference "$_icr_out/record.tsv"
    awk -F '\t' '
        BEGIN { OFS = "\t" }
        NR > 1 && $1 == "benchmark/typelisp" { print $1 "/" $2, $3 }
    ' "$_icr_out/measure/summary.tsv" | LC_ALL=C sort >> "$_icr_out/record.tsv"

    _icr_vmsg=$(insn_record_validate "$_icr_out/record.tsv" reference) || insn_fail "$_icr_vmsg"

    if insn_in_actions; then
        if [ "${GITHUB_EVENT_NAME:-}" = push ]; then
            _icr_probs=$(insn_reference_record_check "$_icr_out/record.tsv" "$_icr_out/record.tsv" \
                "$GITHUB_REPOSITORY" "${GITHUB_RUN_ID:-}" "${GITHUB_RUN_ATTEMPT:-}" \
                "$(git rev-parse HEAD)" reference) ||
                insn_fail "this push record would be rejected by consumers: $_icr_probs"
        else
            if insn_reference_record_check "$_icr_out/record.tsv" "$_icr_out/record.tsv" \
                "$GITHUB_REPOSITORY" "${GITHUB_RUN_ID:-}" "${GITHUB_RUN_ATTEMPT:-}" \
                "$(git rev-parse HEAD)" reference > "$_icr_out/dry-run-rejection.txt"; then
                insn_fail "a $GITHUB_EVENT_NAME record would be accepted as a reference"
            fi
            insn_log "dry run ($GITHUB_EVENT_NAME): consumers reject this record:"
            sed 's/^/  /' "$_icr_out/dry-run-rejection.txt" >&2
        fi
    fi

    _icr_count=$(awk -F '\t' '$1 ~ /^benchmark\/typelisp\// { c++ } END { print c + 0 }' "$_icr_out/record.tsv")
    insn_summary "### insn-exec reference"
    insn_summary ""
    insn_summary "\`$(git rev-parse HEAD)\`: $_icr_count TypeLisp benchmarks recorded (${GITHUB_EVENT_NAME:-local})"
    insn_log "published $_icr_count TypeLisp benchmark counts -> $_icr_out/record.tsv"
}

# --- PR check shared evaluator ----------------------------------------------

# insn_evaluate_pr_suite WORKDIR SUITE CASES_CSV BASE_COMMIT HEAD_COMMIT PR_NUM BASE_TL_FILE BASE_SOURCE DECL_PROBLEMS DECL_PARSED
insn_evaluate_pr_suite() {
    _ieps_dir=$1
    _ieps_suite=$2
    _ieps_cases=$3
    _ieps_base=$4
    _ieps_head=$5
    _ieps_pr=$6
    _ieps_base_tl=$7
    _ieps_base_src=$8
    _ieps_decl_probs=$9
    _ieps_decl_parsed=${10}

    _ieps_new=$(new_cases_between "$_ieps_base" "$_ieps_cases")
    _ieps_res="$_ieps_dir/result.tsv"
    printf 'metric\tbase_ir\thead_ir\tdelta\tpct\tstatus\tdeclared_max_ir\tsuite\tbase_commit\thead_commit\tbase_source\n' > "$_ieps_res"

    _ieps_rc=0
    # Re-emit C rows into result.tsv (already checked fail-fast during measurement).
    if ! compare_c_counts "$_ieps_dir/c-baseline.tsv" "$_ieps_dir/current-c.tsv" "$_ieps_cases" \
        "$_ieps_res" "$_ieps_suite" "$_ieps_base" "$_ieps_head" > "$_ieps_dir/c-diff.txt"; then
        _ieps_rc=1
    fi

    if ! compare_tl_counts "$_ieps_base_tl" "$_ieps_dir/current-tl.tsv" "$_ieps_decl_parsed" \
        "$_ieps_cases" "$_ieps_new" "$_ieps_res" "$_ieps_suite" "$_ieps_base" "$_ieps_head" "$_ieps_base_src" \
        > "$_ieps_dir/tl-diff.txt"; then
        _ieps_rc=1
    fi

    {
        cat "$_ieps_dir/c-diff.txt"
        awk 'NR > 1' "$_ieps_dir/tl-diff.txt"
    } > "$_ieps_dir/diff.txt"

    if [ -n "$_ieps_decl_probs" ]; then
        printf '%s\n' "$_ieps_decl_probs" | sed 's/^/[ir-check] declaration: /' >&2
        _ieps_rc=1
    fi

    if [ "$_ieps_rc" -eq 0 ]; then
        cat "$_ieps_dir/diff.txt"
        insn_log "$_ieps_suite passed against $_ieps_base ($_ieps_base_src)"
    else
        cat "$_ieps_dir/diff.txt" >&2
        insn_log "$_ieps_suite FAILED against $_ieps_base ($_ieps_base_src)"
        if awk -F ' \\| ' '$1 ~ /^benchmark\/typelisp\// && ($6 == "REGRESSION" || $6 == "DECLARATION-EXCEEDED") { found = 1 } END { exit found ? 0 : 1 }' "$_ieps_dir/tl-diff.txt"; then
            insn_log "if a TypeLisp regression is intentional and reviewed, declare it in $INSN_DECL_DIR/pr-${_ieps_pr}.tsv:"
            insn_log "  benchmark/typelisp/<case><TAB>+<max_delta_ir><TAB><reason>"
        fi
    fi

    _ieps_changed=$(awk -F '\t' 'NR > 1 && $6 != "ok" { c++ } END { print c + 0 }' "$_ieps_res")
    insn_summary "### insn-exec ($_ieps_suite)"
    insn_summary ""
    insn_summary "Base: \`$_ieps_base\` ($_ieps_base_src); non-identical rows: $_ieps_changed"
    if [ "$_ieps_changed" -gt 0 ]; then
        insn_summary ""
        insn_summary "| metric | base | head | delta | pct | status |"
        insn_summary "|---|---:|---:|---:|---:|---|"
        awk -F '\t' 'NR > 1 && $6 != "ok" { printf "| `%s` | %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5, $6 }' "$_ieps_res" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
    fi
    return "$_ieps_rc"
}

insn_check_pr_declarations() {
    _icpd_base=$1
    _icpd_head=$2
    _icpd_pr=$3
    _icpd_out_dir=$4
    _icpd_valid_cases=$5
    INSN_DECL_PROBLEMS=
    INSN_DECL_PARSED="$_icpd_out_dir/decl-parsed.tsv"
    : > "$INSN_DECL_PARSED"
    _icpd_own="$INSN_DECL_DIR/pr-$_icpd_pr.tsv"
    git diff --name-status -M "$_icpd_base" "$_icpd_head" -- "$INSN_DECL_DIR" > "$_icpd_out_dir/declarations.diff"
    _icpd_b_has_own=no
    git cat-file -e "$_icpd_base:$_icpd_own" 2>/dev/null && _icpd_b_has_own=yes
    INSN_DECL_PROBLEMS=$(insn_declaration_diff_check "$_icpd_pr" "$_icpd_out_dir/declarations.diff" "$_icpd_b_has_own") || true
    if [ -z "$INSN_DECL_PROBLEMS" ] && [ -L "$_icpd_own" ]; then
        INSN_DECL_PROBLEMS="declaration file must not be a symlink: $_icpd_own"
    elif [ -z "$INSN_DECL_PROBLEMS" ] && [ -f "$_icpd_own" ]; then
        if ! _icpd_parsed=$(insn_declaration_parse "$_icpd_own" "$_icpd_valid_cases"); then
            INSN_DECL_PROBLEMS="malformed $_icpd_own: $_icpd_parsed"
        else
            printf '%s\n' "$_icpd_parsed" > "$INSN_DECL_PARSED"
        fi
    fi
}

insn_require_pr_env() {
    _irpe_pr=${TYPELISP_SELF_COMPILE_PR_NUMBER:-}
    _irpe_head=${TYPELISP_SELF_COMPILE_PR_HEAD:-}
    case "$_irpe_pr" in "" | *[!0-9]*) insn_fail "TYPELISP_SELF_COMPILE_PR_NUMBER is not a PR number: $_irpe_pr" ;; esac
    sc_is_sha "$_irpe_head" || insn_fail "TYPELISP_SELF_COMPILE_PR_HEAD is not a commit id"
    [ -n "${GH_TOKEN:-}" ] || insn_fail "GH_TOKEN is required for GitHub Actions PR instruction-count check"
}

# insn_result_tsv_passed FILE
#   Verify a completed result.tsv has at least one data row (NR > 1), exact `ok`
#   on every `benchmark/c*` row, and only passing statuses on `benchmark/typelisp/*`.
insn_result_tsv_passed() {
    [ -f "$1" ] || return 1
    awk -F '\t' '
        { sub(/\r$/, "") }
        NR == 1 {
            if ($1 != "metric" || $6 != "status") bad = 1
            next
        }
        $0 == "" { next }
        {
            rows++
            if ($1 ~ /^benchmark\/c/) {
                if ($6 != "ok") bad = 1
            } else if ($1 ~ /^benchmark\/typelisp\//) {
                if ($6 != "ok" && $6 != "IMPROVEMENT" && $6 != "declared-ok" && $6 != "new-benchmark") bad = 1
            } else {
                bad = 1
            }
        }
        END { exit (bad || rows == 0) ? 1 : 0 }
    ' "$1"
}

# --- subcommand: finalize-ci (ci.yml post-ci-verify step) -------------------

insn_cmd_finalize_ci() {
    insn_in_actions || insn_fail "finalize-ci runs in GitHub Actions only"
    insn_require_pr_env
    _icfc_pr=$TYPELISP_SELF_COMPILE_PR_NUMBER
    _icfc_event_head=$TYPELISP_SELF_COMPILE_PR_HEAD

    _icfc_deferred_dirs=
    _icfc_all_cases=
    _icfc_head_meta=
    _icfc_any=0
    for _icfc_dir in target/instruction-count-check target/instruction-count-heavy; do
        if [ -f "$_icfc_dir/deferred.tsv" ]; then
            _icfc_any=1
            _icfc_deferred_dirs="$_icfc_deferred_dirs $_icfc_dir"
            _icfc_dc=$(sc_record_get "$_icfc_dir/deferred.tsv" benchmarks)
            _icfc_all_cases="${_icfc_all_cases:+$_icfc_all_cases,}$_icfc_dc"
            [ -n "$_icfc_head_meta" ] || _icfc_head_meta="$_icfc_dir/head-meta.tsv"
        elif [ -f "$_icfc_dir/result.tsv" ]; then
            _icfc_any=1
            insn_log "reusing completed instruction-count check in $_icfc_dir/result.tsv"
            if ! insn_result_tsv_passed "$_icfc_dir/result.tsv"; then
                insn_fail "completed check in $_icfc_dir/result.tsv did not pass"
            fi
        fi
    done

    if [ "$_icfc_any" -eq 0 ]; then
        insn_log "finalize-ci: no instruction-count suites ran in this lane"
        return 0
    fi
    if [ -z "$_icfc_deferred_dirs" ]; then
        return 0
    fi

    _icfc_t=$(git rev-parse HEAD)
    [ "$_icfc_t" = "${GITHUB_SHA:-}" ] || insn_fail "checkout $_icfc_t is not GITHUB_SHA ${GITHUB_SHA:-}"
    _icfc_parents=$(git cat-file -p HEAD | sed -n 's/^parent //p')
    [ "$(printf '%s\n' "$_icfc_parents" | wc -l)" -eq 2 ] ||
        insn_fail "tested commit $_icfc_t is not a two-parent merge"
    _icfc_b=$(printf '%s\n' "$_icfc_parents" | sed -n 1p)
    _icfc_h=$(printf '%s\n' "$_icfc_parents" | sed -n 2p)
    [ "$_icfc_h" = "$_icfc_event_head" ] ||
        insn_fail "tested merge head parent $_icfc_h is not PR head $_icfc_event_head"

    git cat-file -e "$_icfc_b^{commit}" 2>/dev/null ||
        git fetch --no-tags --depth=1 origin "$_icfc_b" >/dev/null 2>&1 ||
        insn_fail "cannot fetch base commit $_icfc_b"

    _icfc_work=target/insn-exec/finalize
    mkdir -p "$_icfc_work"
    _icfc_valid_cases=$(all_instruction_cases_csv) || exit 1
    insn_check_pr_declarations "$_icfc_b" "$_icfc_t" "$_icfc_pr" "$_icfc_work" "$_icfc_valid_cases"

    _icfc_waited=0
    while :; do
        _icfc_refdir="$_icfc_work/reference-$_icfc_waited"
        insn_resolve_reference "$_icfc_b" "$_icfc_head_meta" "$_icfc_refdir"
        if [ "$INSN_REF_STATUS" = ok ]; then break; fi
        if git cat-file -e "$_icfc_b:perf/insn-exec-baseline.tsv" 2>/dev/null; then break; fi
        [ "$INSN_REF_STATUS" = pending ] || break
        [ "$_icfc_waited" -lt "$INSN_WAIT_SECONDS" ] || break
        insn_log "insn-exec reference for $_icfc_b is pending; waiting ${INSN_POLL_SECONDS}s"
        sleep "$INSN_POLL_SECONDS"
        _icfc_waited=$((_icfc_waited + INSN_POLL_SECONDS))
    done

    _icfc_base_tl="$_icfc_work/base-tl.tsv"
    if [ "$INSN_REF_STATUS" = ok ]; then
        cp "$_icfc_refdir/record.tsv" "$_icfc_base_tl"
        _icfc_base_src="reference run $INSN_REF_RUN attempt $INSN_REF_ATTEMPT"
    elif extract_legacy_tl_baseline "$_icfc_b" "$_icfc_base_tl"; then
        _icfc_base_src="pre-cutover legacy baseline at $_icfc_b"
        insn_log "using pre-cutover legacy TypeLisp baseline at $_icfc_b"
    else
        insn_log "no usable insn-exec reference for $_icfc_b ($INSN_REF_STATUS):"
        sed 's/^/  /' "$_icfc_refdir/reasons" >&2
        _icfc_dedup_cases=$(printf '%s\n' "$_icfc_all_cases" | tr ',' '\n' | LC_ALL=C sort -u | paste -sd, -)
        insn_run_fallback "$_icfc_b" "$_icfc_t" "$_icfc_dedup_cases" "$_icfc_base_tl" base-fallback
        _icfc_base_src="in-place fallback on this runner (reference $INSN_REF_STATUS)"
    fi

    _icfc_rc=0
    for _icfc_dir in $_icfc_deferred_dirs; do
        _icfc_suite=$(sc_record_get "$_icfc_dir/deferred.tsv" suite)
        _icfc_cases=$(sc_record_get "$_icfc_dir/deferred.tsv" benchmarks)
        rm -f "$_icfc_dir/deferred.tsv"
        if ! insn_evaluate_pr_suite "$_icfc_dir" "$_icfc_suite" "$_icfc_cases" \
            "$_icfc_b" "$_icfc_t" "$_icfc_pr" "$_icfc_base_tl" "$_icfc_base_src" \
            "$INSN_DECL_PROBLEMS" "$INSN_DECL_PARSED"; then
            _icfc_rc=1
        fi
    done
    return "$_icfc_rc"
}

# --- subcommand: main-check (self-compile-reference.yml ledger job) ---------

insn_fetch_head_reference() {
    _ifhr_c=$1
    _ifhr_out=$2
    INSN_HEAD_REC=
    INSN_HEAD_ERR=
    if ! insn_api "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/artifacts?name=$INSN_REF_ARTIFACT&per_page=100" \
        "$_ifhr_out/head-artifacts.json"; then
        INSN_HEAD_ERR="failed to list artifacts for run $GITHUB_RUN_ID"
        return 1
    fi
    _ifhr_hid=$(sc_select_artifact "$_ifhr_out/head-artifacts.json" "$INSN_REF_ARTIFACT" "$GITHUB_RUN_ID")
    if [ -z "$_ifhr_hid" ]; then
        INSN_HEAD_ERR="run $GITHUB_RUN_ID has no $INSN_REF_ARTIFACT artifact"
        return 1
    fi
    if ! insn_download_artifact "$_ifhr_hid" "$_ifhr_out/head-artifact"; then
        INSN_HEAD_ERR="failed to download HEAD $INSN_REF_ARTIFACT"
        return 1
    fi
    _ifhr_rec="$_ifhr_out/head-artifact/record.tsv"
    if ! _ifhr_vmsg=$(insn_record_validate "$_ifhr_rec" reference); then
        INSN_HEAD_ERR="invalid HEAD record: $_ifhr_vmsg"
        return 1
    fi
    if [ "$(sc_record_get "$_ifhr_rec" commit)" != "$_ifhr_c" ]; then
        INSN_HEAD_ERR="HEAD record commit does not match $_ifhr_c"
        return 1
    fi
    INSN_HEAD_REC=$_ifhr_rec
}

insn_cmd_main_check_prepare() {
    insn_in_actions || insn_fail "main-check --prepare runs in GitHub Actions only"
    _icmp_c=$(git rev-parse HEAD)
    _icmp_p=$(git rev-parse HEAD^1 2>/dev/null || true)
    _icmp_tools=no
    _icmp_reason="root commit"
    if [ -n "$_icmp_p" ]; then
        _icmp_out=target/insn-exec/main-check-prepare
        rm -rf -- "$_icmp_out"
        mkdir -p "$_icmp_out"
        if extract_legacy_tl_baseline "$_icmp_p" "$_icmp_out/legacy-tl.tsv" 2>/dev/null; then
            _icmp_tools=no
            _icmp_reason="pre-cutover legacy baseline at $_icmp_p"
        elif ! insn_fetch_head_reference "$_icmp_c" "$_icmp_out"; then
            _icmp_tools=yes
            _icmp_reason="HEAD reference unavailable during prepare ($INSN_HEAD_ERR)"
        else
            insn_resolve_reference "$_icmp_p" "$INSN_HEAD_REC" "$_icmp_out/parent"
            if [ "$INSN_REF_STATUS" = ok ]; then
                _icmp_tools=no
                _icmp_reason="parent reference ready (run $INSN_REF_RUN)"
            else
                _icmp_tools=yes
                _icmp_reason="parent reference $INSN_REF_STATUS"
            fi
        fi
    fi
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        printf 'needs-tools=%s\n' "$_icmp_tools" >> "$GITHUB_OUTPUT"
    fi
    insn_log "main-check --prepare: needs-tools=$_icmp_tools ($_icmp_reason)"
}

insn_cmd_main_check() {
    insn_in_actions || insn_fail "main-check runs in GitHub Actions only"
    _icmc_c=$(git rev-parse HEAD)
    _icmc_p=$(git rev-parse HEAD^1 2>/dev/null || true)
    if [ -z "$_icmc_p" ]; then
        insn_log "main-check: root commit $_icmc_c has no parent; skipping"
        return 0
    fi
    _icmc_out=target/insn-exec/main-check
    rm -rf -- "$_icmc_out"
    mkdir -p "$_icmc_out"

    # Fetch HEAD's own insn-exec-reference from this run's `measure` job.
    insn_fetch_head_reference "$_icmc_c" "$_icmc_out" || insn_fail "main-check: $INSN_HEAD_ERR"
    _icmc_head_rec=$INSN_HEAD_REC

    # Resolve parent P's TypeLisp reference (wait if pending; allow pre-cutover legacy baseline).
    _icmc_waited=0
    while :; do
        _icmc_pdir="$_icmc_out/parent-$_icmc_waited"
        insn_resolve_reference "$_icmc_p" "$_icmc_head_rec" "$_icmc_pdir"
        if [ "$INSN_REF_STATUS" = ok ]; then break; fi
        if git cat-file -e "$_icmc_p:perf/insn-exec-baseline.tsv" 2>/dev/null; then break; fi
        [ "$INSN_REF_STATUS" = pending ] || break
        [ "$_icmc_waited" -lt "$INSN_WAIT_SECONDS" ] || break
        insn_log "main-check: parent $_icmc_p insn-exec reference is pending; waiting ${INSN_POLL_SECONDS}s"
        sleep "$INSN_POLL_SECONDS"
        _icmc_waited=$((_icmc_waited + INSN_POLL_SECONDS))
    done

    _icmc_valid_cases=$(all_instruction_cases_csv) || exit 1
    _icmc_base_tl="$_icmc_out/parent-tl.tsv"
    if [ "$INSN_REF_STATUS" = ok ]; then
        cp "$_icmc_pdir/record.tsv" "$_icmc_base_tl"
        _icmc_base_src="reference run $INSN_REF_RUN attempt $INSN_REF_ATTEMPT"
    elif extract_legacy_tl_baseline "$_icmc_p" "$_icmc_base_tl"; then
        _icmc_base_src="pre-cutover legacy baseline at $_icmc_p"
        insn_log "main-check: using pre-cutover legacy TypeLisp baseline at $_icmc_p"
    elif [ "$INSN_REF_STATUS" = rejected ] || [ "$INSN_REF_STATUS" = absent ]; then
        insn_log "main-check: no usable parent insn-exec reference for $_icmc_p ($INSN_REF_STATUS):"
        sed 's/^/  /' "$_icmc_pdir/reasons" >&2
        [ "${TYPELISP_SELF_COMPILE_TOOLS_READY:-}" = true ] ||
            insn_fail "main-check: fallback measurement requires Linux instruction-count tools (TYPELISP_SELF_COMPILE_TOOLS_READY=true)"
        insn_run_fallback "$_icmc_p" "$_icmc_c" "$_icmc_valid_cases" "$_icmc_base_tl" parent-fallback
        if ! insn_records_comparable "$_icmc_head_rec" "$_icmc_base_tl" >/dev/null 2>&1; then
            insn_log "main-check: ledger runner identity differs from measure job; measuring $_icmc_c in place for comparability"
            _icmc_head_rec="$_icmc_out/head-fallback.tsv"
            insn_run_fallback "$_icmc_c" "$_icmc_c" "$_icmc_valid_cases" "$_icmc_head_rec" head-fallback
            _icmc_base_src="in-place fallback pair on ledger runner (parent reference $INSN_REF_STATUS)"
        else
            _icmc_base_src="in-place fallback on ledger runner (parent reference $INSN_REF_STATUS)"
        fi
    else
        sed 's/^/  /' "$_icmc_pdir/reasons" >&2
        insn_fail "main-check: no usable parent insn-exec reference for $_icmc_p ($INSN_REF_STATUS)"
    fi

    # Check declarations added by this merge commit.
    _icmc_decl_parsed="$_icmc_out/decl-parsed.tsv"
    : > "$_icmc_decl_parsed"
    _icmc_decl_probs=
    git diff --name-status -M "$_icmc_p" "$_icmc_c" -- "$INSN_DECL_DIR" > "$_icmc_out/declarations.diff"

    if [ -s "$_icmc_out/declarations.diff" ]; then
        _icmc_pr=
        _icmc_sel=
        if insn_api "repos/$GITHUB_REPOSITORY/commits/$_icmc_c/pulls" "$_icmc_out/pulls.json"; then
            _icmc_sel=$(sc_merged_prs "$_icmc_out/pulls.json" "$_icmc_c")
        fi
        if [ -z "$_icmc_sel" ] && insn_api "repos/$GITHUB_REPOSITORY/pulls?state=closed&base=main&sort=updated&direction=desc&per_page=100" "$_icmc_out/closed-pulls.json"; then
            _icmc_sel=$(sc_merged_prs "$_icmc_out/closed-pulls.json" "$_icmc_c")
        fi
        if [ -n "$_icmc_sel" ] && [ "$(printf '%s\n' "$_icmc_sel" | wc -l | tr -d ' ')" -eq 1 ]; then
            _icmc_pr=$(printf '%s' "$_icmc_sel" | cut -f1)
        fi
        if [ -z "$_icmc_pr" ]; then
            # Fail closed: require GitHub PR attribution rather than trusting the filename alone.
            _icmc_decl_probs="cannot attribute $INSN_DECL_DIR change on $_icmc_c to a single merged PR"
        else
            _icmc_own="$INSN_DECL_DIR/pr-$_icmc_pr.tsv"
            _icmc_b_has_own=no
            git cat-file -e "$_icmc_p:$_icmc_own" 2>/dev/null && _icmc_b_has_own=yes
            _icmc_decl_probs=$(insn_declaration_diff_check "$_icmc_pr" "$_icmc_out/declarations.diff" "$_icmc_b_has_own") || true
            if [ -z "$_icmc_decl_probs" ] && [ -L "$_icmc_own" ]; then
                _icmc_decl_probs="declaration file must not be a symlink: $_icmc_own"
            elif [ -z "$_icmc_decl_probs" ] && [ -f "$_icmc_own" ]; then
                if ! _icmc_parsed=$(insn_declaration_parse "$_icmc_own" "$_icmc_valid_cases"); then
                    _icmc_decl_probs="malformed $_icmc_own: $_icmc_parsed"
                else
                    printf '%s\n' "$_icmc_parsed" > "$_icmc_decl_parsed"
                fi
            fi
        fi
    fi

    _icmc_new=$(new_cases_between "$_icmc_p" "$_icmc_valid_cases")
    _icmc_res="$_icmc_out/result.tsv"
    printf 'metric\tbase_ir\thead_ir\tdelta\tpct\tstatus\tdeclared_max_ir\tsuite\tbase_commit\thead_commit\tbase_source\n' > "$_icmc_res"

    _icmc_rc=0
    if ! compare_tl_counts "$_icmc_base_tl" "$_icmc_head_rec" "$_icmc_decl_parsed" \
        "$_icmc_valid_cases" "$_icmc_new" "$_icmc_res" all "$_icmc_p" "$_icmc_c" "$_icmc_base_src" \
        > "$_icmc_out/diff.txt"; then
        _icmc_rc=1
    fi
    if [ -n "$_icmc_decl_probs" ]; then
        printf '%s\n' "$_icmc_decl_probs" | sed 's/^/[ir-check] declaration: /' >&2
        _icmc_rc=1
    fi

    cat "$_icmc_out/diff.txt"
    insn_summary "### insn-exec main vs main^1"
    insn_summary ""
    insn_summary "Comparing \`$_icmc_c\` against \`$_icmc_p\` ($_icmc_base_src)"
    if [ "$_icmc_rc" -eq 0 ]; then
        insn_log "main-check passed: $_icmc_c vs $_icmc_p"
    else
        insn_log "main-check FAILED: $_icmc_c regressed vs $_icmc_p"
    fi
    return "$_icmc_rc"
}

# --- host-independent self-tests --------------------------------------------

self_test_c_case() {
    _stcc_name=$1
    _stcc_base=$2
    _stcc_cur=$3
    _stcc_cases=$4
    _stcc_want_status=$5
    _stcc_want_exit=$6

    set +e
    _stcc_out=$(compare_c_counts "$_stcc_base" "$_stcc_cur" "$_stcc_cases" 2>&1)
    _stcc_exit=$?
    set -e

    if [ "$_stcc_exit" -ne "$_stcc_want_exit" ]; then
        echo "self-test c/$_stcc_name: exit $_stcc_exit, want $_stcc_want_exit" >&2
        echo "$_stcc_out" >&2
        return 1
    fi
    case "$_stcc_out" in
        *"$_stcc_want_status"*) ;;
        *)
            echo "self-test c/$_stcc_name: missing status '$_stcc_want_status'" >&2
            echo "$_stcc_out" >&2
            return 1
            ;;
    esac
}

self_test_tl_case() {
    _sttc_name=$1
    _sttc_base=$2
    _sttc_cur=$3
    _sttc_decl=$4
    _sttc_cases=$5
    _sttc_new=$6
    _sttc_want_status=$7
    _sttc_want_exit=$8

    set +e
    _sttc_out=$(compare_tl_counts "$_sttc_base" "$_sttc_cur" "$_sttc_decl" "$_sttc_cases" "$_sttc_new" 2>&1)
    _sttc_exit=$?
    set -e

    if [ "$_sttc_exit" -ne "$_sttc_want_exit" ]; then
        echo "self-test tl/$_sttc_name: exit $_sttc_exit, want $_sttc_want_exit" >&2
        echo "$_sttc_out" >&2
        return 1
    fi
    case "$_sttc_out" in
        *"$_sttc_want_status"*) ;;
        *)
            echo "self-test tl/$_sttc_name: missing status '$_sttc_want_status'" >&2
            echo "$_sttc_out" >&2
            return 1
            ;;
    esac
}

self_test() {
    mkdir -p "$ROOT/target/exp/ir-check-self-test"
    SELF_TEST_DIR=$(mktemp -d "$ROOT/target/exp/ir-check-self-test/run.XXXXXX")
    _st_status=0

    # 1. Exact C comparison (fails in BOTH directions, missing, extra).
    printf 'name\tir_count\nbenchmark/c-scalar/arith_loop\t500001469\n' > "$SELF_TEST_DIR/c-base.tsv"
    printf 'benchmark/c-scalar/arith_loop\t500001469\n' > "$SELF_TEST_DIR/c-exact.tsv"
    printf 'benchmark/c-scalar/arith_loop\t500001470\n' > "$SELF_TEST_DIR/c-regressed.tsv"
    printf 'benchmark/c-scalar/arith_loop\t500001468\n' > "$SELF_TEST_DIR/c-improved.tsv"
    : > "$SELF_TEST_DIR/c-missing.tsv"
    printf 'benchmark/c-scalar/arith_loop\t500001469\nbenchmark/c/arith_loop\t1\n' > "$SELF_TEST_DIR/c-extra.tsv"
    self_test_c_case exact "$SELF_TEST_DIR/c-base.tsv" "$SELF_TEST_DIR/c-exact.tsv" arith_loop "| ok" 0 || _st_status=1
    self_test_c_case regressed "$SELF_TEST_DIR/c-base.tsv" "$SELF_TEST_DIR/c-regressed.tsv" arith_loop "| REGRESSION" 1 || _st_status=1
    self_test_c_case improved "$SELF_TEST_DIR/c-base.tsv" "$SELF_TEST_DIR/c-improved.tsv" arith_loop "| IMPROVEMENT" 1 || _st_status=1
    self_test_c_case missing "$SELF_TEST_DIR/c-base.tsv" "$SELF_TEST_DIR/c-missing.tsv" arith_loop "missing-current" 1 || _st_status=1
    self_test_c_case extra "$SELF_TEST_DIR/c-base.tsv" "$SELF_TEST_DIR/c-extra.tsv" arith_loop "extra-current" 1 || _st_status=1

    # 2. TypeLisp main-relative comparison: <= base passes, +1 Ir fails unless declared.
    : > "$SELF_TEST_DIR/empty.decl"
    printf 'benchmark/typelisp/arith_loop\t437500077\n' > "$SELF_TEST_DIR/tl-base.tsv"
    printf 'benchmark/typelisp/arith_loop\t437500077\n' > "$SELF_TEST_DIR/tl-exact.tsv"
    printf 'benchmark/typelisp/arith_loop\t437500076\n' > "$SELF_TEST_DIR/tl-improved.tsv"
    printf 'benchmark/typelisp/arith_loop\t437500078\n' > "$SELF_TEST_DIR/tl-plus1.tsv"
    printf 'benchmark/typelisp/arith_loop\t437500177\n' > "$SELF_TEST_DIR/tl-plus100.tsv"
    printf 'benchmark/typelisp/arith_loop\t10\n' > "$SELF_TEST_DIR/tl-decl10.tsv"
    printf 'benchmark/typelisp/arith_loop\t437500077\nbenchmark/typelisp/new_case\t999\n' > "$SELF_TEST_DIR/tl-with-new.tsv"

    self_test_tl_case exact "$SELF_TEST_DIR/tl-base.tsv" "$SELF_TEST_DIR/tl-exact.tsv" "$SELF_TEST_DIR/empty.decl" arith_loop "" "| ok" 0 || _st_status=1
    self_test_tl_case improved "$SELF_TEST_DIR/tl-base.tsv" "$SELF_TEST_DIR/tl-improved.tsv" "$SELF_TEST_DIR/empty.decl" arith_loop "" "| IMPROVEMENT" 0 || _st_status=1
    self_test_tl_case plus1-undeclared "$SELF_TEST_DIR/tl-base.tsv" "$SELF_TEST_DIR/tl-plus1.tsv" "$SELF_TEST_DIR/empty.decl" arith_loop "" "| REGRESSION" 1 || _st_status=1
    self_test_tl_case plus1-declared "$SELF_TEST_DIR/tl-base.tsv" "$SELF_TEST_DIR/tl-plus1.tsv" "$SELF_TEST_DIR/tl-decl10.tsv" arith_loop "" "| declared-ok" 0 || _st_status=1
    self_test_tl_case exceeded-decl "$SELF_TEST_DIR/tl-base.tsv" "$SELF_TEST_DIR/tl-plus100.tsv" "$SELF_TEST_DIR/tl-decl10.tsv" arith_loop "" "| DECLARATION-EXCEEDED" 1 || _st_status=1
    self_test_tl_case new-allowed "$SELF_TEST_DIR/tl-base.tsv" "$SELF_TEST_DIR/tl-with-new.tsv" "$SELF_TEST_DIR/empty.decl" "arith_loop,new_case" "new_case" "| new-benchmark" 0 || _st_status=1
    self_test_tl_case missing-base-fail "$SELF_TEST_DIR/tl-base.tsv" "$SELF_TEST_DIR/tl-with-new.tsv" "$SELF_TEST_DIR/empty.decl" "arith_loop,new_case" "" "| missing-base" 1 || _st_status=1
    self_test_tl_case missing-current-fail "$SELF_TEST_DIR/tl-base.tsv" "$SELF_TEST_DIR/c-missing.tsv" "$SELF_TEST_DIR/empty.decl" arith_loop "" "| missing-current" 1 || _st_status=1
    self_test_tl_case extra-current-fail "$SELF_TEST_DIR/tl-base.tsv" "$SELF_TEST_DIR/tl-with-new.tsv" "$SELF_TEST_DIR/empty.decl" arith_loop "" "| extra-current" 1 || _st_status=1

    # 3. Declaration parser & diff immutability guard.
    printf 'benchmark/typelisp/arith_loop\t+500\tintentional bounds check\n' > "$SELF_TEST_DIR/good.decl"
    if [ "$(insn_declaration_parse "$SELF_TEST_DIR/good.decl" "arith_loop")" != "$(printf 'benchmark/typelisp/arith_loop\t500')" ]; then
        echo "self-test decl-parse: valid declaration failed" >&2; _st_status=1
    fi
    printf 'benchmark/typelisp/arith_loop\t0\tzero not allowed\n' > "$SELF_TEST_DIR/zero.decl"
    printf 'benchmark/typelisp/arith_loop\t-5\tneg not allowed\n' > "$SELF_TEST_DIR/neg.decl"
    printf 'benchmark/typelisp/arith_loop\t+5\t   \n' > "$SELF_TEST_DIR/blank-reason.decl"
    printf 'benchmark/typelisp/unknown_case\t+5\tbad case\n' > "$SELF_TEST_DIR/unknown-case.decl"
    printf 'benchmark/typelisp/arith_loop\t+5\tr1\nbenchmark/typelisp/arith_loop\t+6\tr2\n' > "$SELF_TEST_DIR/dup.decl"
    for _st_bad in zero neg blank-reason unknown-case dup; do
        if insn_declaration_parse "$SELF_TEST_DIR/$_st_bad.decl" "arith_loop" >/dev/null 2>&1; then
            echo "self-test decl-parse: accepted malformed $_st_bad" >&2; _st_status=1
        fi
    done

    : > "$SELF_TEST_DIR/d-none.diff"
    printf 'A\t%s/pr-42.tsv\n' "$INSN_DECL_DIR" > "$SELF_TEST_DIR/d-own.diff"
    printf 'A\t%s/pr-99.tsv\n' "$INSN_DECL_DIR" > "$SELF_TEST_DIR/d-squat.diff"
    printf 'M\t%s/pr-7.tsv\n' "$INSN_DECL_DIR" > "$SELF_TEST_DIR/d-mut.diff"
    printf 'D\t%s/pr-7.tsv\n' "$INSN_DECL_DIR" > "$SELF_TEST_DIR/d-del.diff"
    printf 'R100\t%s/pr-7.tsv\t%s/pr-42.tsv\n' "$INSN_DECL_DIR" "$INSN_DECL_DIR" > "$SELF_TEST_DIR/d-ren.diff"
    insn_declaration_diff_check 42 "$SELF_TEST_DIR/d-none.diff" no >/dev/null || { echo "self-test decl-diff: none failed" >&2; _st_status=1; }
    insn_declaration_diff_check 42 "$SELF_TEST_DIR/d-own.diff" no >/dev/null || { echo "self-test decl-diff: own failed" >&2; _st_status=1; }
    insn_declaration_diff_check 42 "$SELF_TEST_DIR/d-own.diff" yes >/dev/null 2>&1 && { echo "self-test decl-diff: accepted existing own" >&2; _st_status=1; }
    for _st_dd in d-squat d-mut d-del d-ren; do
        if insn_declaration_diff_check 42 "$SELF_TEST_DIR/$_st_dd.diff" no >/dev/null 2>&1; then
            echo "self-test decl-diff: accepted $_st_dd" >&2; _st_status=1
        fi
    done

    # 4. Reference record validation and push-only consumer guard.
    _st_sha=1111111111111111111111111111111111111111
    _st_hash=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    {
        printf 'schema\t%s\n' "$INSN_REF_SCHEMA"
        printf 'commit\t%s\n' "$_st_sha"
        printf 'tree\t%s\n' "$_st_sha"
        printf 'role\treference\n'
        printf 'authority\thosted\n'
        printf 'procedure\t%s\n' "$_st_hash"
        printf 'compiler_sha256\t%s\n' "$_st_hash"
        printf 'compiler_commit\t%s\n' "$_st_sha"
        printf 'key.image_os\tubuntu24\n'
        printf 'key.valgrind\tvalgrind-3.22.0\n'
        printf 'key.as\tGNU assembler\n'
        printf 'key.ld\tGNU ld\n'
        printf 'key.arch\tx86_64\n'
        printf 'info.image_version\t1.0\n'
        printf 'info.cpu\tx86\n'
        printf 'run.repository\ttest/repo\n'
        printf 'run.id\t100\n'
        printf 'run.attempt\t1\n'
        printf 'run.workflow_ref\ttest/repo/%s@refs/heads/main\n' "$SC_REFERENCE_WORKFLOW"
        printf 'run.event\tpush\n'
        printf 'benchmark/typelisp/arith_loop\t312500081\n'
    } > "$SELF_TEST_DIR/ref-good.tsv"
    insn_reference_record_check "$SELF_TEST_DIR/ref-good.tsv" "$SELF_TEST_DIR/ref-good.tsv" \
        "test/repo" 100 1 "$_st_sha" reference >/dev/null || { echo "self-test ref-good failed" >&2; _st_status=1; }
    sed 's/^run\.event\tpush$/run.event\tpull_request/' "$SELF_TEST_DIR/ref-good.tsv" > "$SELF_TEST_DIR/ref-pr.tsv"
    if insn_reference_record_check "$SELF_TEST_DIR/ref-pr.tsv" "$SELF_TEST_DIR/ref-good.tsv" \
        "test/repo" 100 1 "$_st_sha" reference >/dev/null 2>&1; then
        echo "self-test ref-pr: accepted pull_request record" >&2; _st_status=1
    fi
    sed 's/^key\.valgrind\tvalgrind-3\.22\.0$/key.valgrind\tvalgrind-3.23.0/' "$SELF_TEST_DIR/ref-good.tsv" > "$SELF_TEST_DIR/ref-vg.tsv"
    if insn_reference_record_check "$SELF_TEST_DIR/ref-vg.tsv" "$SELF_TEST_DIR/ref-good.tsv" \
        "test/repo" 100 1 "$_st_sha" reference >/dev/null 2>&1; then
        echo "self-test ref-vg: accepted mismatched valgrind" >&2; _st_status=1
    fi

    # 5. Per-benchmark manifest invariants (fixtures + committed perf/benchmarks/).
    mkdir -p "$SELF_TEST_DIR/manifests-ok" "$SELF_TEST_DIR/manifests-tl" "$SELF_TEST_DIR/manifests-nosc" "$SELF_TEST_DIR/manifests-both" "$SELF_TEST_DIR/manifests-hb"
    printf 'suites\tbenchmark,instruction-main,realistic-kernel\nbenchmark/c-scalar/a\t10\n' > "$SELF_TEST_DIR/manifests-ok/a.tsv"
    printf 'suites\tinstruction-heavy\nbenchmark/c/h\t20\nbenchmark/c-scalar/h\t30\n' > "$SELF_TEST_DIR/manifests-ok/h.tsv"
    [ "$(benchmark_manifest_read "$SELF_TEST_DIR/manifests-ok" instruction-main)" = "a" ] || { echo "self-test manifest-ok main failed" >&2; _st_status=1; }
    [ "$(benchmark_manifest_read "$SELF_TEST_DIR/manifests-ok" instruction-heavy)" = "h" ] || { echo "self-test manifest-ok heavy failed" >&2; _st_status=1; }
    benchmark_manifest_c_rows "$SELF_TEST_DIR/manifests-ok" "a,h" "$SELF_TEST_DIR/m-crows.tsv" || { echo "self-test manifest-c-rows failed" >&2; _st_status=1; }

    printf 'suites\tinstruction-main\nbenchmark/typelisp/a\t5\nbenchmark/c-scalar/a\t10\n' > "$SELF_TEST_DIR/manifests-tl/a.tsv"
    benchmark_manifest_read "$SELF_TEST_DIR/manifests-tl" instruction-main >/dev/null 2>&1 && { echo "self-test manifest-tl: accepted checked-in typelisp row" >&2; _st_status=1; }
    printf 'suites\tinstruction-main\n' > "$SELF_TEST_DIR/manifests-nosc/a.tsv"
    benchmark_manifest_read "$SELF_TEST_DIR/manifests-nosc" instruction-main >/dev/null 2>&1 && { echo "self-test manifest-nosc: accepted missing c-scalar row" >&2; _st_status=1; }
    printf 'suites\tinstruction-main,instruction-heavy\nbenchmark/c-scalar/a\t10\n' > "$SELF_TEST_DIR/manifests-both/a.tsv"
    benchmark_manifest_read "$SELF_TEST_DIR/manifests-both" instruction-main >/dev/null 2>&1 && { echo "self-test manifest-both: accepted dual instruction suites" >&2; _st_status=1; }
    printf 'suites\tbenchmark,instruction-heavy\nbenchmark/c-scalar/a\t10\n' > "$SELF_TEST_DIR/manifests-hb/a.tsv"
    benchmark_manifest_read "$SELF_TEST_DIR/manifests-hb" instruction-heavy >/dev/null 2>&1 && { echo "self-test manifest-hb: accepted heavy+benchmark" >&2; _st_status=1; }

    # Validate the real committed perf/benchmarks/ directory & per-case provenance!
    _st_real_main=$(benchmark_ci_case_csv "$ROOT" instruction-main) || _st_status=1
    _st_real_heavy=$(benchmark_ci_case_csv "$ROOT" instruction-heavy) || _st_status=1
    benchmark_ci_case_csv "$ROOT" benchmark >/dev/null || _st_status=1
    benchmark_ci_case_csv "$ROOT" optimization-opt2 >/dev/null || _st_status=1
    benchmark_ci_case_csv "$ROOT" realistic-kernel >/dev/null || _st_status=1
    for _st_c in $(printf '%s,%s' "$_st_real_main" "$_st_real_heavy" | tr ',' ' '); do
        _st_p="$ROOT/perf/benchmarks/$_st_c.provenance.json"
        if ! c_provenance_validate_case "$_st_p" "$_st_c" >/dev/null 2>&1; then
            echo "self-test committed-provenance: invalid or missing $_st_p" >&2
            _st_status=1
        fi
    done
    # Ensure zero retired monolithic files remain.
    for _st_old in perf/insn-exec-baseline.tsv perf/insn-exec-baseline.tsv.provenance.json \
        perf/insn-exec-heavy-baseline.tsv perf/insn-exec-heavy-baseline.tsv.provenance.json \
        perf/benchmark-ci-cases.tsv; do
        if [ -e "$ROOT/$_st_old" ]; then
            echo "self-test monolithic-removed: retired file still exists: $_st_old" >&2
            _st_status=1
        fi
    done
    if (sh "$ROOT/scripts/check-instruction-counts.sh" --self-compile-only) >/dev/null 2>&1; then
        echo "self-test self-compile-only: retired mode still runs" >&2
        _st_status=1
    fi

    # 6. Pre-cutover legacy baseline extraction & new-case detection + C-only update.
    benchmark_manifest_update_c "$SELF_TEST_DIR/manifests-ok" a 99 || { echo "self-test update-c failed" >&2; _st_status=1; }
    if ! grep -qxF "$(printf 'benchmark/c-scalar/a\t99')" "$SELF_TEST_DIR/manifests-ok/a.tsv" ||
        ! grep -qxF "$(printf 'suites\tbenchmark,instruction-main,realistic-kernel')" "$SELF_TEST_DIR/manifests-ok/a.tsv"; then
        echo "self-test update-c: manifest not updated properly" >&2; _st_status=1
    fi
    _st_repo="$SELF_TEST_DIR/cutover-repo"
    mkdir -p "$_st_repo/perf"
    (
        cd "$_st_repo"
        git init -q
        git config user.email test@example.com
        git config user.name test
        printf 'name\tir_count\nbenchmark/typelisp/a\t100\nbenchmark/c-scalar/a\t200\n' > perf/insn-exec-baseline.tsv
        printf 'name\tir_count\nbenchmark/typelisp/h\t300\nbenchmark/c/h\t400\nbenchmark/c-scalar/h\t500\n' > perf/insn-exec-heavy-baseline.tsv
        git add perf/
        git commit -q -m "pre-cutover"
        _c0=$(git rev-parse HEAD)
        extract_legacy_tl_baseline "$_c0" "$_st_repo/legacy-tl.tsv" || exit 1
        grep -qxF "$(printf 'benchmark/typelisp/a\t100')" "$_st_repo/legacy-tl.tsv" || exit 1
        grep -qxF "$(printf 'benchmark/typelisp/h\t300')" "$_st_repo/legacy-tl.tsv" || exit 1
        [ "$(new_cases_between "$_c0" "a,h,brand_new")" = "brand_new" ] || exit 1
    ) || { echo "self-test pre-cutover git extraction failed" >&2; _st_status=1; }

    # 7. Symlink rejection at perf/insn-exec-declarations/pr-<N>.tsv.
    ln -s "$SELF_TEST_DIR/good.decl" "$SELF_TEST_DIR/link.decl"
    ln -s "$SELF_TEST_DIR/nonexistent.decl" "$SELF_TEST_DIR/dangling.decl"
    if insn_declaration_parse "$SELF_TEST_DIR/link.decl" "arith_loop" >/dev/null 2>&1; then
        echo "self-test decl-symlink: accepted live symlink" >&2; _st_status=1
    fi
    if insn_declaration_parse "$SELF_TEST_DIR/dangling.decl" "arith_loop" >/dev/null 2>&1; then
        echo "self-test decl-symlink: accepted dangling symlink" >&2; _st_status=1
    fi
    _st_symrepo="$SELF_TEST_DIR/symlink-repo"
    mkdir -p "$_st_symrepo/$INSN_DECL_DIR" "$_st_symrepo/out"
    (
        cd "$_st_symrepo"
        git init -q
        git config user.email test@example.com
        git config user.name test
        printf 'benchmark/typelisp/arith_loop\t+50\tlegit\n' > target.tsv
        git add target.tsv
        git commit -q -m "base"
        _sb=$(git rev-parse HEAD)
        ln -s ../../target.tsv "$INSN_DECL_DIR/pr-42.tsv"
        git add "$INSN_DECL_DIR/pr-42.tsv"
        git commit -q -m "add symlink decl"
        _sh=$(git rev-parse HEAD)
        insn_check_pr_declarations "$_sb" "$_sh" 42 "$_st_symrepo/out" "arith_loop"
        [ -n "$INSN_DECL_PROBLEMS" ] || { echo "accepted symlink in insn_check_pr_declarations" >&2; exit 1; }
    ) || { echo "self-test decl-symlink repo check failed" >&2; _st_status=1; }

    # 8. Fallback base case filtering uses commit_instruction_cases (not bench.tl/baseline.c presence).
    _st_fbrepo="$SELF_TEST_DIR/fallback-filter-repo"
    mkdir -p "$_st_fbrepo/perf/benchmarks" "$_st_fbrepo/benchmarks/a" "$_st_fbrepo/benchmarks/spmd_scan"
    (
        cd "$_st_fbrepo"
        git init -q
        git config user.email test@example.com
        git config user.name test
        printf 'fn main() {}\n' > benchmarks/a/bench.tl
        printf 'int main(void) { return 0; }\n' > benchmarks/a/baseline.c
        printf 'fn main() {}\n' > benchmarks/spmd_scan/bench.tl
        printf 'int main(void) { return 0; }\n' > benchmarks/spmd_scan/baseline.c
        printf 'suites\tinstruction-main\nbenchmark/c-scalar/a\t10\n' > perf/benchmarks/a.tsv
        printf 'suites\tbenchmark\n' > perf/benchmarks/spmd_scan.tsv
        git add benchmarks/ perf/
        git commit -q -m "base with non-instruction spmd_scan"
        _fb_base=$(git rev-parse HEAD)
        [ "$(insn_filter_base_cases "$_fb_base" "a,spmd_scan")" = "a" ] || {
            echo "expected base cases 'a', got '$(insn_filter_base_cases "$_fb_base" "a,spmd_scan")'" >&2
            exit 1
        }
        [ "$(new_cases_between "$_fb_base" "a,spmd_scan")" = "spmd_scan" ] || {
            echo "expected new cases 'spmd_scan', got '$(new_cases_between "$_fb_base" "a,spmd_scan")'" >&2
            exit 1
        }
    ) || { echo "self-test fallback base case filter failed" >&2; _st_status=1; }

    # 9. Fail closed on missing Actions PR/token env vars & tighten finalize-ci result.tsv checks.
    _st_good_sha=2222222222222222222222222222222222222222
    if (env -u TYPELISP_SELF_COMPILE_PR_NUMBER GITHUB_ACTIONS=true \
        TYPELISP_SELF_COMPILE_PR_HEAD="$_st_good_sha" GH_TOKEN=tok \
        sh "$ROOT/scripts/check-instruction-counts.sh" --cached-base-only) >/dev/null 2>&1; then
        echo "self-test actions-env: accepted missing PR number" >&2; _st_status=1
    fi
    if (env -u TYPELISP_SELF_COMPILE_PR_HEAD GITHUB_ACTIONS=true \
        TYPELISP_SELF_COMPILE_PR_NUMBER=42 GH_TOKEN=tok \
        sh "$ROOT/scripts/check-instruction-counts.sh" --cached-base-only) >/dev/null 2>&1; then
        echo "self-test actions-env: accepted missing PR head" >&2; _st_status=1
    fi
    if (env -u GH_TOKEN GITHUB_ACTIONS=true \
        TYPELISP_SELF_COMPILE_PR_NUMBER=42 TYPELISP_SELF_COMPILE_PR_HEAD="$_st_good_sha" \
        sh "$ROOT/scripts/check-instruction-counts.sh" --cached-base-only) >/dev/null 2>&1; then
        echo "self-test actions-env: accepted missing GH_TOKEN" >&2; _st_status=1
    fi

    _st_res_hdr='metric	base_ir	head_ir	delta	pct	status	declared_max_ir	suite	base_commit	head_commit	base_source'
    printf '%s\n' "$_st_res_hdr" > "$SELF_TEST_DIR/res-empty.tsv"
    printf '%s\nbenchmark/c-scalar/a\t10\t9\t-1\t-10.000000%%\tIMPROVEMENT\t-\tinstruction-main\tb\th\ts\n' "$_st_res_hdr" > "$SELF_TEST_DIR/res-c-imp.tsv"
    printf '%s\nbenchmark/c/a\t10\t9\t-1\t-10.000000%%\tIMPROVEMENT\t-\tinstruction-main\tb\th\ts\n' "$_st_res_hdr" > "$SELF_TEST_DIR/res-cauto-imp.tsv"
    printf '%s\nbenchmark/c-scalar/a\t10\t10\t0\t+0.000000%%\tok\t-\tinstruction-main\tb\th\ts\nbenchmark/typelisp/a\t20\t18\t-2\t-10.000000%%\tIMPROVEMENT\t-\tinstruction-main\tb\th\ts\n' "$_st_res_hdr" > "$SELF_TEST_DIR/res-ok.tsv"
    printf '%s\nbenchmark/c-scalar/a\t10\t10\t0\t+0.000000%%\tok\t-\tinstruction-main\tb\th\ts\nbenchmark/typelisp/a\t20\t21\t+1\t+5.000000%%\tREGRESSION\t-\tinstruction-main\tb\th\ts\n' "$_st_res_hdr" > "$SELF_TEST_DIR/res-tl-reg.tsv"

    for _st_badres in res-empty res-c-imp res-cauto-imp res-tl-reg; do
        if insn_result_tsv_passed "$SELF_TEST_DIR/$_st_badres.tsv"; then
            echo "self-test finalize-ci: accepted $_st_badres" >&2; _st_status=1
        fi
    done
    insn_result_tsv_passed "$SELF_TEST_DIR/res-ok.tsv" || { echo "self-test finalize-ci: rejected res-ok" >&2; _st_status=1; }

    _st_fcrepo="$SELF_TEST_DIR/finalize-ci-repo"
    mkdir -p "$_st_fcrepo/target/instruction-count-check"
    (
        cd "$_st_fcrepo"
        GITHUB_ACTIONS=true
        TYPELISP_SELF_COMPILE_PR_NUMBER=42
        TYPELISP_SELF_COMPILE_PR_HEAD=$_st_good_sha
        GH_TOKEN=tok
        cp "$SELF_TEST_DIR/res-empty.tsv" target/instruction-count-check/result.tsv
        if (insn_cmd_finalize_ci) >/dev/null 2>&1; then
            echo "finalize-ci accepted header-only result.tsv" >&2; exit 1
        fi
        cp "$SELF_TEST_DIR/res-c-imp.tsv" target/instruction-count-check/result.tsv
        if (insn_cmd_finalize_ci) >/dev/null 2>&1; then
            echo "finalize-ci accepted IMPROVEMENT on benchmark/c-scalar" >&2; exit 1
        fi
        cp "$SELF_TEST_DIR/res-ok.tsv" target/instruction-count-check/result.tsv
        (insn_cmd_finalize_ci) >/dev/null 2>&1 || {
            echo "finalize-ci rejected valid completed result.tsv" >&2; exit 1
        }
    ) || { echo "self-test finalize-ci end-to-end failed" >&2; _st_status=1; }

    # 10. Post-merge main-check --prepare and main-check fallback paths.
    _st_mcrepo="$SELF_TEST_DIR/main-check-repo"
    mkdir -p "$_st_mcrepo/perf"
    (
        cd "$_st_mcrepo"
        git init -q
        git config user.email test@example.com
        git config user.name test
        printf 'name\tir_count\nbenchmark/typelisp/a\t100\nbenchmark/c-scalar/a\t200\n' > perf/insn-exec-baseline.tsv
        git add perf/
        git commit -q -m "pre-cutover"
        _mc_pre=$(git rev-parse HEAD)
        git rm -q perf/insn-exec-baseline.tsv
        mkdir -p perf/benchmarks
        printf 'suites\tinstruction-main\nbenchmark/c-scalar/a\t200\n' > perf/benchmarks/a.tsv
        printf 'suites\tinstruction-heavy\nbenchmark/c-scalar/h\t300\n' > perf/benchmarks/h.tsv
        git add perf/
        git commit -q -m "post-cutover parent"
        _mc_p=$(git rev-parse HEAD)
        printf 'suites\tinstruction-main\nbenchmark/c-scalar/a\t200\n' > perf/benchmarks/a.tsv
        printf 'x\n' > note.txt
        git add note.txt
        git commit -q -m "post-cutover head"
        _mc_c=$(git rev-parse HEAD)
        _mc_ptree=$(git rev-parse "$_mc_p^{tree}")
        _mc_ctree=$(git rev-parse "$_mc_c^{tree}")

        _st_write_rec() {
            _swr_out=$1; _swr_sha=$2; _swr_tree=$3; _swr_run=$4; _swr_vg=$5; _swr_a=$6; _swr_h=$7; _swr_role=${8:-reference}
            {
                printf 'schema\t%s\n' "$INSN_REF_SCHEMA"
                printf 'commit\t%s\n' "$_swr_sha"
                printf 'tree\t%s\n' "$_swr_tree"
                printf 'role\t%s\n' "$_swr_role"
                printf 'authority\thosted\n'
                printf 'procedure\t%s\n' "$_st_hash"
                printf 'compiler_sha256\t%s\n' "$_st_hash"
                printf 'compiler_commit\t%s\n' "$_swr_sha"
                printf 'key.image_os\tubuntu24\n'
                printf 'key.valgrind\t%s\n' "$_swr_vg"
                printf 'key.as\tGNU assembler\n'
                printf 'key.ld\tGNU ld\n'
                printf 'key.arch\tx86_64\n'
                printf 'info.image_version\t1.0\n'
                printf 'info.cpu\tx86\n'
                printf 'run.repository\ttest/repo\n'
                printf 'run.id\t%s\n' "$_swr_run"
                printf 'run.attempt\t1\n'
                printf 'run.workflow_ref\ttest/repo/%s@refs/heads/main\n' "$SC_REFERENCE_WORKFLOW"
                printf 'run.event\tpush\n'
                printf 'benchmark/typelisp/a\t%s\n' "$_swr_a"
                printf 'benchmark/typelisp/h\t%s\n' "$_swr_h"
            } > "$_swr_out"
        }

        ROOT=$_st_mcrepo
        GITHUB_ACTIONS=true
        GITHUB_REPOSITORY=test/repo
        GITHUB_RUN_ID=200
        GITHUB_RUN_ATTEMPT=1
        INSN_WAIT_SECONDS=0
        INSN_POLL_SECONDS=0
        _mc_mode=ok
        _mc_head_a=100
        _mc_fb_calls=0

        insn_api() {
            case "$1" in
                "repos/test/repo/actions/runs/200/artifacts"*)
                    printf '{"artifacts":[{"id":201,"name":"%s","expired":false,"workflow_run":{"id":200}}]}\n' "$INSN_REF_ARTIFACT" > "$2"
                    return 0
                    ;;
                "repos/test/repo/actions/workflows/"*"head_sha=$_mc_p"*)
                    case "$_mc_mode" in
                        absent) printf '{"workflow_runs":[]}\n' > "$2"; return 0 ;;
                        api-error) return 1 ;;
                        *)
                            printf '{"workflow_runs":[{"id":100,"run_number":1,"run_attempt":1,"status":"completed","conclusion":"success","event":"push","head_branch":"main","head_sha":"%s","path":"%s","repository":{"full_name":"test/repo"},"head_repository":{"full_name":"test/repo"}}]}\n' "$_mc_p" "$SC_REFERENCE_WORKFLOW" > "$2"
                            return 0
                            ;;
                    esac
                    ;;
                "repos/test/repo/actions/runs/100/jobs"*)
                    printf '{"jobs":[{"run_attempt":1,"name":"%s","status":"completed","conclusion":"success"}]}\n' "$SC_REFERENCE_JOB_NAME" > "$2"
                    return 0
                    ;;
                "repos/test/repo/actions/runs/100/artifacts"*)
                    printf '{"artifacts":[{"id":101,"name":"%s","expired":false,"workflow_run":{"id":100}}]}\n' "$INSN_REF_ARTIFACT" > "$2"
                    return 0
                    ;;
            esac
            return 1
        }
        insn_download_artifact() {
            mkdir -p "$2"
            if [ "$1" = 201 ]; then
                _st_write_rec "$2/record.tsv" "$_mc_c" "$_mc_ctree" 200 "valgrind-3.23.0" "$_mc_head_a" 500
            elif [ "$1" = 101 ]; then
                if [ "$_mc_mode" = rejected ]; then
                    _st_write_rec "$2/record.tsv" "$_mc_p" "$_mc_ptree" 100 "valgrind-3.22.0" 100 500
                else
                    _st_write_rec "$2/record.tsv" "$_mc_p" "$_mc_ptree" 100 "valgrind-3.23.0" 100 500
                fi
            else
                return 1
            fi
        }
        insn_run_fallback() {
            _mc_fb_calls=$((_mc_fb_calls + 1))
            printf '%s\n' "$_mc_fb_calls" > "$SELF_TEST_DIR/mc-fb-calls"
            mkdir -p "$(dirname -- "$4")"
            _st_write_rec "$4" "$1" "$_mc_ptree" 200 "valgrind-3.23.0" 100 500 "$5"
        }

        # 10a. --prepare: parent ok -> needs-tools=no
        GITHUB_OUTPUT="$SELF_TEST_DIR/mc-out-ok"
        : > "$GITHUB_OUTPUT"
        _mc_mode=ok
        insn_cmd_main_check_prepare >/dev/null 2>&1 || exit 1
        grep -qxF 'needs-tools=no' "$GITHUB_OUTPUT" || { echo "prepare ok wanted needs-tools=no" >&2; exit 1; }

        # 10b. --prepare: parent rejected -> needs-tools=yes
        GITHUB_OUTPUT="$SELF_TEST_DIR/mc-out-rej"
        : > "$GITHUB_OUTPUT"
        _mc_mode=rejected
        insn_cmd_main_check_prepare >/dev/null 2>&1 || exit 1
        grep -qxF 'needs-tools=yes' "$GITHUB_OUTPUT" || { echo "prepare rejected wanted needs-tools=yes" >&2; exit 1; }

        # 10c. --prepare: parent absent -> needs-tools=yes
        GITHUB_OUTPUT="$SELF_TEST_DIR/mc-out-abs"
        : > "$GITHUB_OUTPUT"
        _mc_mode=absent
        insn_cmd_main_check_prepare >/dev/null 2>&1 || exit 1
        grep -qxF 'needs-tools=yes' "$GITHUB_OUTPUT" || { echo "prepare absent wanted needs-tools=yes" >&2; exit 1; }

        # 10d. main-check: rejected without tools ready -> fail closed
        _mc_mode=rejected
        TYPELISP_SELF_COMPILE_TOOLS_READY=false
        if (insn_cmd_main_check) >/dev/null 2>&1; then
            echo "main-check ran fallback without TYPELISP_SELF_COMPILE_TOOLS_READY=true" >&2; exit 1
        fi

        # 10e. main-check: rejected with tools ready -> runs fallback and passes
        _mc_mode=rejected
        _mc_head_a=100
        TYPELISP_SELF_COMPILE_TOOLS_READY=true
        rm -f "$SELF_TEST_DIR/mc-fb-calls"
        (insn_cmd_main_check) >/dev/null 2>&1 || { echo "main-check fallback on rejected failed" >&2; exit 1; }
        [ "$(cat "$SELF_TEST_DIR/mc-fb-calls" 2>/dev/null || echo 0)" = 1 ] || { echo "main-check did not invoke fallback on rejected" >&2; exit 1; }

        # 10f. main-check: rejected with tools ready + regression -> fails
        _mc_head_a=101
        if (insn_cmd_main_check) >/dev/null 2>&1; then
            echo "main-check fallback missed +1 Ir regression" >&2; exit 1
        fi

        # 10g. main-check: absent with tools ready -> runs fallback and passes
        _mc_mode=absent
        _mc_head_a=100
        rm -f "$SELF_TEST_DIR/mc-fb-calls"
        (insn_cmd_main_check) >/dev/null 2>&1 || { echo "main-check fallback on absent failed" >&2; exit 1; }
        [ "$(cat "$SELF_TEST_DIR/mc-fb-calls" 2>/dev/null || echo 0)" = 1 ] || { echo "main-check did not invoke fallback on absent" >&2; exit 1; }

        # 10h. main-check: api-error -> fails closed without running fallback
        _mc_mode=api-error
        rm -f "$SELF_TEST_DIR/mc-fb-calls"
        if (insn_cmd_main_check) >/dev/null 2>&1; then
            echo "main-check passed on api-error" >&2; exit 1
        fi
        [ ! -f "$SELF_TEST_DIR/mc-fb-calls" ] || { echo "main-check invoked fallback on api-error" >&2; exit 1; }

        # 10i. --prepare on pre-cutover parent -> needs-tools=no
        git -c advice.detachedHead=false checkout -q "$_mc_p"
        GITHUB_OUTPUT="$SELF_TEST_DIR/mc-out-pre"
        : > "$GITHUB_OUTPUT"
        insn_cmd_main_check_prepare >/dev/null 2>&1 || exit 1
        grep -qxF 'needs-tools=no' "$GITHUB_OUTPUT" || { echo "prepare pre-cutover wanted needs-tools=no" >&2; exit 1; }
    ) || { echo "self-test main-check prepare/fallback failed" >&2; _st_status=1; }

    c_provenance_self_test "$SELF_TEST_DIR" || _st_status=1
    rm -rf -- "$SELF_TEST_DIR"
    if [ "$_st_status" -ne 0 ]; then
        return 1
    fi
    echo "instruction-count comparison self-test passed"
}

# --- CLI dispatch -----------------------------------------------------------

case "${1:-}" in
    reference)
        shift
        insn_cmd_reference "$@"
        exit $?
        ;;
    finalize-ci)
        shift
        insn_cmd_finalize_ci "$@"
        exit $?
        ;;
    main-check)
        shift
        case "${1:-}" in
            --prepare)
                [ "$#" -eq 1 ] || { usage >&2; exit 2; }
                insn_cmd_main_check_prepare
                exit $?
                ;;
            "")
                insn_cmd_main_check
                exit $?
                ;;
            *)
                usage >&2
                exit 2
                ;;
        esac
        ;;
    fallback)
        shift
        insn_cmd_fallback "$@"
        exit $?
        ;;
esac

SUITE=instruction-main
BENCHMARKS=${TYPELISP_IR_CHECK_BENCHMARKS:-}
RUNS=${TYPELISP_IR_CHECK_RUNS:-1}
JOBS=${TYPELISP_IR_CHECK_JOBS:-1}
CYCLES=0
WORKDIR=${TYPELISP_IR_CHECK_OUT:-target/instruction-count-check}
CACHED_BASE_ONLY=0
BASE_REF=
WRITE_REF=
UPDATE_C_BASELINE=0
SELF_TEST=0
SEED_ARG=

while [ "$#" -gt 0 ]; do
    case "$1" in
        --suite)
            [ "$#" -ge 2 ] || { echo "missing value for --suite" >&2; exit 2; }
            SUITE=$2
            shift 2
            ;;
        --benchmarks)
            [ "$#" -ge 2 ] || { echo "missing value for --benchmarks" >&2; exit 2; }
            BENCHMARKS=$2
            shift 2
            ;;
        --runs)
            [ "$#" -ge 2 ] || { echo "missing value for --runs" >&2; exit 2; }
            RUNS=$2
            shift 2
            ;;
        --jobs)
            [ "$#" -ge 2 ] || { echo "missing value for --jobs" >&2; exit 2; }
            JOBS=$2
            shift 2
            ;;
        --cycles)
            CYCLES=1
            shift
            ;;
        --output)
            [ "$#" -ge 2 ] || { echo "missing value for --output" >&2; exit 2; }
            WORKDIR=$2
            shift 2
            ;;
        --cached-base-only)
            CACHED_BASE_ONLY=1
            shift
            ;;
        --base-ref)
            [ "$#" -ge 2 ] || { echo "missing value for --base-ref" >&2; exit 2; }
            BASE_REF=$2
            shift 2
            ;;
        --write-reference)
            [ "$#" -ge 2 ] || { echo "missing value for --write-reference" >&2; exit 2; }
            WRITE_REF=$2
            shift 2
            ;;
        --update-c-baseline)
            UPDATE_C_BASELINE=1
            shift
            ;;
        --update-baseline | --baseline)
            echo "monolithic baselines were retired; TypeLisp Ir auto-ratchets via CI insn-exec-reference" >&2
            echo "use --update-c-baseline for C-only changes, or perf/insn-exec-declarations/pr-<N>.tsv for reviewed TypeLisp regressions" >&2
            exit 2
            ;;
        --benchmarks-only)
            shift
            ;;
        --self-compile-only)
            echo "self_compile is no longer a checked baseline row (#9307):" >&2
            echo "measure it with scripts/self-compile.sh measure; CI gates each" >&2
            echo "PR's own cost against main (perf/README.md)" >&2
            exit 2
            ;;
        --self-test)
            SELF_TEST=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        -*)
            echo "unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            if [ -n "$SEED_ARG" ]; then
                echo "only one typelisp seed may be provided" >&2
                exit 2
            fi
            SEED_ARG=$1
            shift
            ;;
    esac
done

if [ "$SELF_TEST" -eq 1 ]; then
    self_test
    exit 0
fi

case "$SUITE" in
    instruction-main | instruction-heavy) ;;
    *) echo "--suite must be instruction-main or instruction-heavy: $SUITE" >&2; exit 2 ;;
esac
case "$RUNS" in "" | *[!0-9]* | 0) echo "--runs must be a positive integer: $RUNS" >&2; exit 2 ;; esac
case "$JOBS" in "" | *[!0-9]* | 0) echo "--jobs must be a positive integer: $JOBS" >&2; exit 2 ;; esac

if [ -z "$BENCHMARKS" ]; then
    BENCHMARKS=$(benchmark_ci_case_csv "$ROOT" "$SUITE") || exit 1
fi
case "$BENCHMARKS" in
    "" | *[!A-Za-z0-9_.,-]*)
        echo "--benchmarks must be comma-separated benchmark names: $BENCHMARKS" >&2
        exit 2
        ;;
esac
case "$WORKDIR" in "" | / | . | ..) echo "unsafe --output path: $WORKDIR" >&2; exit 2 ;; esac

if insn_in_actions && [ "$CACHED_BASE_ONLY" -eq 1 ] && [ -z "$BASE_REF" ] && [ "$UPDATE_C_BASELINE" -eq 0 ]; then
    insn_require_pr_env
fi

case "$(uname -s)" in
    Linux*) ;;
    *)
        if insn_in_actions; then
            echo "[ir-check] instruction-count baseline is Linux-only; a GitHub Actions run on $(uname -s) cannot pass it" >&2
            exit 1
        fi
        echo "[ir-check] instruction-count baseline is Linux-only; skipping on $(uname -s)"
        exit 0
        ;;
esac

if ! command -v valgrind >/dev/null 2>&1; then
    if insn_in_actions; then
        echo "[ir-check] valgrind not found: GitHub Actions never passes the instruction-count gate without it" >&2
        exit 1
    fi
    echo "[ir-check] valgrind not found; skipping instruction-count baseline"
    exit 0
fi

case "$(realpath -m -- "$WORKDIR")" in
    "$(realpath -m -- "$ROOT")/target/"*) ;;
    *) fail "--output must be inside this checkout's target/ scratch root: $WORKDIR" ;;
esac
rm -rf -- "${WORKDIR:?}"
mkdir -p "$WORKDIR"

bench_compiler "$SEED_ARG"

PREBUILT_COMPILER=${TYPELISP_IR_CHECK_COMPILER:-}
if [ -n "$PREBUILT_COMPILER" ]; then
    case "$PREBUILT_COMPILER" in /*) ;; *) PREBUILT_COMPILER="$ROOT/$PREBUILT_COMPILER" ;; esac
    [ -x "$PREBUILT_COMPILER" ] || insn_fail "TYPELISP_IR_CHECK_COMPILER is not executable: $PREBUILT_COMPILER"
    CHECK_COMPILER=$PREBUILT_COMPILER
    insn_log "measure with prebuilt stage2 compiler: $CHECK_COMPILER"
else
    . "$INSN_TOOL_DIR/lib-stage0.sh"
    build_selfhost_stage2 "$ROOT" "$COMPILER" "$WORKDIR/compiler" || exit 1
    CHECK_COMPILER=$(selfhost_stage2_path "$WORKDIR/compiler")
fi

MANIFEST_DIR=$(benchmark_manifest_dir "$ROOT")
C_BASELINE="$WORKDIR/c-baseline.tsv"
benchmark_manifest_c_rows "$MANIFEST_DIR" "$BENCHMARKS" "$C_BASELINE" || exit 1

MEASURE_OUT="$WORKDIR/measure"
CURRENT="$WORKDIR/current.tsv"
CURRENT_C="$WORKDIR/current-c.tsv"
CURRENT_TL="$WORKDIR/current-tl.tsv"
DIFF_OUT="$WORKDIR/diff.txt"

insn_log "measure $SUITE ($BENCHMARKS)"
set --
if [ "$CYCLES" -eq 1 ]; then set -- --cycles; fi
env -i PATH="$PATH" HOME="${HOME:-}" LC_ALL=C \
    GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-local}" GITHUB_RUN_ID="${GITHUB_RUN_ID:-local}" \
    GITHUB_RUN_ATTEMPT="${GITHUB_RUN_ATTEMPT:-local}" GITHUB_WORKFLOW_REF="${GITHUB_WORKFLOW_REF:-local}" \
    GITHUB_JOB="${GITHUB_JOB:-local}" ImageOS="${ImageOS:-unknown}" ImageVersion="${ImageVersion:-unknown}" \
    scripts/measure-instruction-counts.sh \
    --runs "$RUNS" \
    --jobs "$JOBS" \
    --cases "$BENCHMARKS" \
    --output "$MEASURE_OUT" \
    --benchmarks-only \
    --c-scalar \
    "$@" \
    "$CHECK_COMPILER"

# Split measured rows: gated C rows and TypeLisp rows.
awk -F '\t' '
    BEGIN { OFS = "\t" }
    NR == FNR {
        if (NR > 1 && NF >= 2) gated[$1] = 1
        next
    }
    NR == 1 { next }
    {
        metric = $1 "/" $2
        if ($1 == "benchmark/typelisp" || $1 == "benchmark/c-scalar" || ($1 == "benchmark/c" && (metric in gated))) {
            print metric, $3
        }
    }
' "$C_BASELINE" "$MEASURE_OUT/summary.tsv" > "$CURRENT"

awk -F '\t' '$1 ~ /^benchmark\/c(-scalar)?\//' "$CURRENT" > "$CURRENT_C"
awk -F '\t' '$1 ~ /^benchmark\/typelisp\//' "$CURRENT" > "$CURRENT_TL"

c_provenance_validate "$MEASURE_OUT/c-provenance.json" measured || exit 1

if [ "$UPDATE_C_BASELINE" -eq 1 ]; then
    for _ucb_c in $(printf '%s' "$BENCHMARKS" | tr ',' ' '); do
        _ucb_sc=$(awk -F '\t' -v k="benchmark/c-scalar/$_ucb_c" '$1 == k { print $2; exit }' "$CURRENT_C")
        _ucb_au=$(awk -F '\t' -v k="benchmark/c/$_ucb_c" '$1 == k { print $2; exit }' "$CURRENT_C")
        [ -n "$_ucb_sc" ] || insn_fail "missing measured benchmark/c-scalar/$_ucb_c"
        benchmark_manifest_update_c "$MANIFEST_DIR" "$_ucb_c" "$_ucb_sc" "$_ucb_au" || exit 1
        c_provenance_extract_case "$MEASURE_OUT/c-provenance.json" "$_ucb_c" \
            "$MANIFEST_DIR/$_ucb_c.provenance.json" || exit 1
    done
    insn_log "updated C baselines and per-case provenance for: $BENCHMARKS"
    exit 0
fi

if [ -n "$WRITE_REF" ]; then
    insn_write_meta "$CHECK_COMPILER" local "$WRITE_REF"
    cat "$CURRENT_TL" >> "$WRITE_REF"
    insn_log "wrote local TypeLisp reference: $WRITE_REF"
fi

# 1. Exact C equality check + per-case C provenance validation (always fail fast!).
for _p_c in $(printf '%s' "$BENCHMARKS" | tr ',' ' '); do
    _p_file="$MANIFEST_DIR/$_p_c.provenance.json"
    [ -f "$_p_file" ] || insn_fail "missing per-case C provenance record: $_p_file"
    c_provenance_validate_case "$_p_file" "$_p_c" || exit 1
done

if ! compare_c_counts "$C_BASELINE" "$CURRENT_C" "$BENCHMARKS" > "$WORKDIR/c-diff.txt"; then
    cat "$WORKDIR/c-diff.txt" >&2
    insn_log "C instruction counts differ from perf/benchmarks/*.tsv"
    c_provenance_diagnose_dir "$MANIFEST_DIR" "$MEASURE_OUT/c-provenance.json" \
        "$C_BASELINE" "$WORKDIR/c-diff.txt" >&2
    insn_log "keep C rows unchanged; reproduce the recorded comparison environment (perf/README.md)"
    exit 1
fi

# 2. TypeLisp Ir check.
#    - Explicit --base-ref: compare locally against FILE (<= base + optional local decl).
#    - GitHub Actions pull_request (with GH_TOKEN + PR metadata): compare against HEAD^1
#      `insn-exec-reference` (or pre-cutover legacy baseline), or defer to `finalize-ci`
#      when --cached-base-only is set and the base reference is not yet ready.
#    - Local without --base-ref: report C exact-match + TypeLisp Ir table.
if [ -n "$BASE_REF" ]; then
    [ -f "$BASE_REF" ] || insn_fail "missing --base-ref file: $BASE_REF"
    _br_decl="$WORKDIR/empty.decl"
    : > "$_br_decl"
    _br_res="$WORKDIR/result.tsv"
    printf 'metric\tbase_ir\thead_ir\tdelta\tpct\tstatus\tdeclared_max_ir\tsuite\tbase_commit\thead_commit\tbase_source\n' > "$_br_res"
    compare_c_counts "$C_BASELINE" "$CURRENT_C" "$BENCHMARKS" "$_br_res" "$SUITE" local local >/dev/null
    if compare_tl_counts "$BASE_REF" "$CURRENT_TL" "$_br_decl" "$BENCHMARKS" "" "$_br_res" "$SUITE" local local "$BASE_REF" > "$WORKDIR/tl-diff.txt"; then
        { cat "$WORKDIR/c-diff.txt"; awk 'NR > 1' "$WORKDIR/tl-diff.txt"; } > "$DIFF_OUT"
        cat "$DIFF_OUT"
        insn_log "instruction counts passed against $BASE_REF"
        exit 0
    else
        { cat "$WORKDIR/c-diff.txt"; awk 'NR > 1' "$WORKDIR/tl-diff.txt"; } > "$DIFF_OUT"
        cat "$DIFF_OUT" >&2
        insn_fail "TypeLisp instruction counts regressed against $BASE_REF"
    fi
fi

if insn_in_actions && {
    [ "$CACHED_BASE_ONLY" -eq 1 ] ||
    { [ -n "${TYPELISP_SELF_COMPILE_PR_NUMBER:-}" ] && [ -n "${GH_TOKEN:-}" ]; }
}; then
    insn_require_pr_env
    _pr_num=$TYPELISP_SELF_COMPILE_PR_NUMBER
    _pr_head=$TYPELISP_SELF_COMPILE_PR_HEAD
    _pr_t=$(git rev-parse HEAD)
    [ "$_pr_t" = "${GITHUB_SHA:-}" ] || insn_fail "checkout $_pr_t is not GITHUB_SHA ${GITHUB_SHA:-}"
    _pr_parents=$(git cat-file -p HEAD | sed -n 's/^parent //p')
    [ "$(printf '%s\n' "$_pr_parents" | wc -l)" -eq 2 ] || insn_fail "tested commit $_pr_t is not a two-parent merge"
    _pr_b=$(printf '%s\n' "$_pr_parents" | sed -n 1p)
    _pr_h=$(printf '%s\n' "$_pr_parents" | sed -n 2p)
    [ "$_pr_h" = "$_pr_head" ] || insn_fail "tested merge head parent $_pr_h is not PR head $_pr_head"

    insn_write_meta "$CHECK_COMPILER" pr-head "$WORKDIR/head-meta.tsv"

    if ! git cat-file -e "$_pr_b^{commit}" 2>/dev/null; then
        if [ "$CACHED_BASE_ONLY" -eq 1 ]; then
            {
                sc_record_line suite "$SUITE"
                sc_record_line base "$_pr_b"
                sc_record_line reference_status base-commit-unavailable
                sc_record_line benchmarks "$BENCHMARKS"
            } > "$WORKDIR/deferred.tsv"
            cat "$WORKDIR/c-diff.txt"
            insn_log "C rows match; deferring TypeLisp check for $_pr_b (base-commit-unavailable)"
            exit 0
        fi
        git fetch --no-tags --depth=1 origin "$_pr_b" >/dev/null 2>&1 || insn_fail "cannot fetch base commit $_pr_b"
    fi

    _pr_valid_cases=$(all_instruction_cases_csv) || exit 1
    insn_check_pr_declarations "$_pr_b" "$_pr_t" "$_pr_num" "$WORKDIR" "$_pr_valid_cases"
    if [ -n "$INSN_DECL_PROBLEMS" ]; then
        printf '%s\n' "$INSN_DECL_PROBLEMS" | sed 's/^/[ir-check] declaration: /' >&2
        exit 1
    fi

    if [ "$CACHED_BASE_ONLY" -eq 1 ]; then
        INSN_API_ATTEMPTS=1
    fi
    insn_resolve_reference "$_pr_b" "$WORKDIR/head-meta.tsv" "$WORKDIR/reference-cached"
    _pr_base_tl="$WORKDIR/base-tl.tsv"
    if [ "$INSN_REF_STATUS" = ok ]; then
        cp "$WORKDIR/reference-cached/record.tsv" "$_pr_base_tl"
        _pr_base_src="reference run $INSN_REF_RUN attempt $INSN_REF_ATTEMPT"
    elif extract_legacy_tl_baseline "$_pr_b" "$_pr_base_tl"; then
        _pr_base_src="pre-cutover legacy baseline at $_pr_b"
        insn_log "using pre-cutover legacy TypeLisp baseline at $_pr_b"
    elif [ "$CACHED_BASE_ONLY" -eq 1 ]; then
        {
            sc_record_line suite "$SUITE"
            sc_record_line base "$_pr_b"
            sc_record_line reference_status "$INSN_REF_STATUS"
            sc_record_line benchmarks "$BENCHMARKS"
        } > "$WORKDIR/deferred.tsv"
        cat "$WORKDIR/c-diff.txt"
        insn_log "C rows match; deferring TypeLisp check for $_pr_b ($INSN_REF_STATUS) to finalize-ci"
        exit 0
    else
        sed 's/^/  /' "$WORKDIR/reference-cached/reasons" >&2
        insn_fail "no usable insn-exec reference for $_pr_b ($INSN_REF_STATUS); run via finalize-ci for wait/fallback"
    fi

    insn_evaluate_pr_suite "$WORKDIR" "$SUITE" "$BENCHMARKS" "$_pr_b" "$_pr_t" "$_pr_num" \
        "$_pr_base_tl" "$_pr_base_src" "$INSN_DECL_PROBLEMS" "$INSN_DECL_PARSED"
    exit $?
fi

# Local run without --base-ref: C rows already verified exact; print TypeLisp table.
cat "$WORKDIR/c-diff.txt"
echo ""
echo "TypeLisp measured Ir (pass --write-reference FILE on base and --base-ref FILE on branch to diff locally):"
awk -F '\t' '{ printf "%s | %s\n", $1, $2 }' "$CURRENT_TL"
cp "$WORKDIR/c-diff.txt" "$DIFF_OUT"
insn_log "C baselines match perf/benchmarks/*.tsv ($SUITE)"
