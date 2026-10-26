#!/usr/bin/env sh
set -eu

# self-compile.sh - the main-relative self_compile gate (#9307, D-C15-9307).
#
# self_compile/compile_cli_opt1 is the Cachegrind Ir of the fixpoint compiler
# compiling src/main.tl at opt1. Its absolute value depends on the host, so no
# checked row carries it. Instead:
#
#   measure    The `linux-self-compile-measurement` gate: measure the compiler
#              and write a record with the value and its full measurement
#              identity (argv, cwd, env, procedure hash, compiler hash and the
#              environment reuse key).
#   check      PR CI, after ci-verify: gate the PR's own cost
#              M(T) - M(B), T the tested merge and B its first parent, at
#              TYPELISP_IR_SELF_COMPILE_TOLERANCE_PPM (5000). M(B) is B's
#              main reference after API-verified provenance and an identical
#              identity, or B measured in place on this runner.
#   reference  Main push workflow: publish this commit's gate record.
#   ledger     Main push workflow: compare the landed merge with its PR's
#              report, classify it, and carry the cumulative account forward.
#   fallback   Internal: measure a base commit in place (run from a copy).
#
# perf/README.md (`self_compile`) is the user-facing contract.

SC_TOOL_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=${TYPELISP_SELF_COMPILE_ROOT:-$(CDPATH= cd -- "$SC_TOOL_DIR/.." && pwd)}
cd "$ROOT"
. "$SC_TOOL_DIR/lib-self-compile.sh"

SC_WAIT_SECONDS=${TYPELISP_SELF_COMPILE_WAIT_SECONDS:-1800}
SC_POLL_SECONDS=${TYPELISP_SELF_COMPILE_POLL_SECONDS:-60}
SC_WALK_LIMIT=${TYPELISP_SELF_COMPILE_WALK_LIMIT:-200}
SC_OUT=target/self-compile
SC_GATE_RECORD=$SC_OUT/measurement/record.tsv

usage() {
    cat <<'EOF'
usage:
  scripts/self-compile.sh measure --compiler PATH
  scripts/self-compile.sh check        (GitHub Actions pull_request, Linux)
  scripts/self-compile.sh reference    (GitHub Actions push or dry run, Linux)
  scripts/self-compile.sh ledger       (GitHub Actions push to main, Linux)
  scripts/self-compile.sh --self-test

measure runs the self_compile measurement on PATH (the bootstrap fixpoint
compiler) and writes target/self-compile/measurement/record.tsv. Outside
GitHub-hosted Actions the record is `local` and is never gated or reused:
compare two local trees with the same-host delta in perf/README.md.
EOF
}

sc_fail() {
    sc_log "$*"
    exit 1
}

sc_in_actions() {
    [ "${GITHUB_ACTIONS:-}" = true ]
}

sc_summary() {
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"
    fi
}

sc_annotate() {
    if sc_in_actions; then
        printf '::%s title=self_compile::%s\n' "$1" "$2"
    fi
}

sc_validate_seconds() {
    case "$2" in
        "" | *[!0-9]*) sc_fail "$1 must be a non-negative integer: $2" ;;
    esac
}

sc_validate_seconds TYPELISP_SELF_COMPILE_WAIT_SECONDS "$SC_WAIT_SECONDS"
sc_validate_seconds TYPELISP_SELF_COMPILE_POLL_SECONDS "$SC_POLL_SECONDS"
[ "$SC_WAIT_SECONDS" -le 1800 ] || sc_fail "TYPELISP_SELF_COMPILE_WAIT_SECONDS may not exceed 1800 (D-C15)"
case "$SC_TOLERANCE_PPM" in
    "" | *[!0-9]*) sc_fail "TYPELISP_IR_SELF_COMPILE_TOLERANCE_PPM must be a non-negative integer: $SC_TOLERANCE_PPM" ;;
esac

# --- identity ------------------------------------------------------------------

sc_first_line() {
    "$@" 2>/dev/null | sed -n '1{s/[[:space:]]*$//;p;}' || true
}

sc_procedure_hash() {
    for _sph_file in $SC_PROCEDURE_FILES; do
        [ -f "$_sph_file" ] || sc_fail "measurement procedure file missing: $_sph_file"
        printf '%s\t%s\n' "$_sph_file" "$(git hash-object -- "$_sph_file")"
    done | sha256sum | cut -c1-64
}

# The same hash for a commit's committed harness, from git objects.
sc_procedure_hash_at() {
    for _spha_file in $SC_PROCEDURE_FILES; do
        printf '%s\t%s\n' "$_spha_file" "$(git rev-parse "$1:$_spha_file" 2>/dev/null || echo missing)"
    done | sha256sum | cut -c1-64
}

sc_cpu_model() {
    if [ -r /proc/cpuinfo ]; then
        awk -F ': *' '/^model name/ { print $2; exit }' /proc/cpuinfo
    else
        echo unknown
    fi
}

sc_authority() {
    if sc_in_actions && [ "${RUNNER_ENVIRONMENT:-}" = github-hosted ]; then
        echo hosted
    else
        echo local
    fi
}

# The reuse key of this host, plus recorded-but-unbound information.
sc_identity_lines() {
    sc_record_line key.image_os "${ImageOS:-unknown}"
    sc_record_line key.kernel "$(uname -r)"
    sc_record_line key.valgrind "$(sc_first_line valgrind --version)"
    sc_record_line key.as "$(sc_first_line as --version)"
    sc_record_line key.ld "$(sc_first_line ld --version)"
    sc_record_line key.workspace "$(pwd -P)"
    sc_record_line key.arch "${RUNNER_ARCH:-$(uname -m)}"
    sc_record_line info.image_version "${ImageVersion:-unknown}"
    sc_record_line info.cpu "$(sc_cpu_model)"
    sc_record_line info.valgrind_package "$(dpkg-query -W -f='${Version}' valgrind 2>/dev/null || echo unknown)"
    sc_record_line info.runner_environment "${RUNNER_ENVIRONMENT:-local}"
    sc_record_line authority "$(sc_authority)"
}

sc_run_lines() {
    sc_record_line run.repository "${GITHUB_REPOSITORY:-local}"
    sc_record_line run.id "${GITHUB_RUN_ID:-local}"
    sc_record_line run.attempt "${GITHUB_RUN_ATTEMPT:-local}"
    sc_record_line run.workflow_ref "${GITHUB_WORKFLOW_REF:-local}"
    sc_record_line run.event "${GITHUB_EVENT_NAME:-local}"
    sc_record_line run.job "${GITHUB_JOB:-local}"
    sc_record_line run.sha "${GITHUB_SHA:-local}"
}

# --- measure -------------------------------------------------------------------

# sc_measure_into COMPILER RECORD ROLE
#   Measure the checkout's workload with COMPILER using the harness in the
#   working tree, then write RECORD. Shared by the gate and the fallback.
sc_measure_into() {
    _smi_compiler=$1
    _smi_record=$2
    _smi_role=$3
    case "$(uname -s)" in
        Linux*) ;;
        *) sc_fail "self_compile is measured on Linux only" ;;
    esac
    command -v valgrind >/dev/null 2>&1 ||
        sc_fail "valgrind is required to measure self_compile; install it (scripts/ci-host-tools.tsv)"
    case "$_smi_compiler" in
        /*) ;;
        *) _smi_compiler="$ROOT/$_smi_compiler" ;;
    esac
    [ -x "$_smi_compiler" ] || sc_fail "compiler is not executable: $_smi_compiler"
    # The harness clears the environment of the measured process itself; this
    # env -i only keeps the harness from inheriting CI variables.
    grep -F 'env -i LC_ALL=C "$VALGRIND"' scripts/measure-instruction-counts.sh >/dev/null ||
        sc_fail "the harness no longer runs Cachegrind under env -i LC_ALL=C; update the recorded env"
    env -i PATH="$PATH" HOME="${HOME:-}" LC_ALL=C \
        scripts/measure-instruction-counts.sh \
        --runs 1 \
        --self-compile-only \
        --opt-level 1 \
        --output "$SC_HARNESS_OUTPUT" \
        "$_smi_compiler" ||
        sc_fail "self_compile measurement failed"
    _smi_ir=$(awk -F '\t' '$1 == "self_compile" && $2 == "compile_cli_opt1" { print $3 }' \
        "$SC_HARNESS_OUTPUT/summary.tsv")
    sc_is_count "$_smi_ir" || sc_fail "no self_compile count in $SC_HARNESS_OUTPUT/summary.tsv"
    _smi_cg="$SC_HARNESS_OUTPUT/logs/$SC_HARNESS_LOG"
    [ -s "$_smi_cg" ] || sc_fail "missing Cachegrind output $_smi_cg"
    _smi_argv=$(sed -n 's/^cmd: //p' "$_smi_cg" | sed -n 1p)
    # Keep the Cachegrind output beside the record: the benchmark gate resets
    # the shared harness directory after this gate.
    mkdir -p "$(dirname -- "$_smi_record")"
    cp "$_smi_cg" "$(dirname -- "$_smi_record")/$_smi_role.cachegrind.out"
    [ -n "$_smi_argv" ] || sc_fail "no cmd: line in $_smi_cg"
    # argv[0] is the compiler path; its length does not affect the count
    # (perf/README.md) while the fixpoint may converge at stage3 or stage4.
    _smi_argv_normalized=$(printf '%s\n' "$_smi_argv" | awk '{ $1 = "<compiler>"; print }')
    _smi_commit=$(git rev-parse HEAD)
    _smi_tree=$(git rev-parse 'HEAD^{tree}')
    # The fixpoint compiler is stamped with its source commit; the record
    # binds that stamp to the measured commit.
    _smi_stamp=$("$_smi_compiler" --version 2>/dev/null | awk 'NR == 1 && $1 == "typelisp" { print $2 }')
    sc_is_sha "$_smi_stamp" || sc_fail "the measured compiler reports no build commit (--version)"
    [ "$_smi_stamp" = "$_smi_commit" ] ||
        sc_fail "the measured compiler was built from $_smi_stamp, not the checkout $_smi_commit"
    mkdir -p "$(dirname -- "$_smi_record")"
    {
        sc_record_line schema "$SC_RECORD_SCHEMA"
        sc_record_line metric "$SC_METRIC"
        sc_record_line ir_count "$_smi_ir"
        sc_record_line commit "$_smi_commit"
        sc_record_line tree "$_smi_tree"
        sc_record_line role "$_smi_role"
        sc_record_line argv "$_smi_argv"
        sc_record_line argv_normalized "$_smi_argv_normalized"
        sc_record_line cwd "$(pwd -P)"
        sc_record_line env LC_ALL=C
        sc_record_line procedure "$(sc_procedure_hash)"
        sc_record_line compiler_sha256 "$(sha256sum "$_smi_compiler" | cut -c1-64)"
        sc_record_line compiler_commit "$_smi_stamp"
        sc_identity_lines
        sc_run_lines
        sc_record_line measured_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$_smi_record"
    sc_log "measured $SC_METRIC $_smi_ir for $_smi_commit ($_smi_role) -> $_smi_record"
}

sc_cmd_measure() {
    _scm_compiler=
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --compiler)
                [ "$#" -ge 2 ] || sc_fail "missing value for --compiler"
                _scm_compiler=$2
                shift 2
                ;;
            *) usage >&2; exit 2 ;;
        esac
    done
    [ -n "$_scm_compiler" ] || { usage >&2; exit 2; }
    sc_measure_into "$_scm_compiler" "$SC_GATE_RECORD" gate
    if [ "$(sc_record_get "$SC_GATE_RECORD" authority)" != hosted ]; then
        sc_log "this record is local-absolute-unverified: absolute counts are"
        sc_log "environment-specific and only GitHub-hosted records are gated or"
        sc_log "reused. Measure base and branch back to back on this host and"
        sc_log "compare their delta instead (perf/README.md)."
    fi
    cat "$SC_GATE_RECORD"
}

# --- GitHub API ----------------------------------------------------------------
# Every call goes through these two functions; --self-test replaces them with
# fixture readers.

# sc_json_ok FILE  ->  succeeds when FILE holds one valid JSON document.
sc_json_ok() {
    jq -e . "$1" >/dev/null 2>&1
}

# sc_api ENDPOINT OUT  ->  the response body in OUT, from the first of three
# attempts that succeeds. Each attempt writes its own OUT.attempt-N.
sc_api() {
    _sa_try=1
    while :; do
        if gh api -H 'Accept: application/vnd.github+json' "$1" > "$2.attempt-$_sa_try" \
            2> "$2.attempt-$_sa_try.stderr" &&
            sc_json_ok "$2.attempt-$_sa_try"; then
            cp "$2.attempt-$_sa_try" "$2"
            return 0
        fi
        [ "$_sa_try" -lt 3 ] || return 1
        _sa_try=$((_sa_try + 1))
        sleep 10
    done
}

# sc_download_artifact ID DEST  ->  the artifact with that id, unpacked in DEST.
sc_download_artifact() {
    mkdir -p "$2" || return 1
    gh api -H 'Accept: application/vnd.github+json' \
        "repos/$GITHUB_REPOSITORY/actions/artifacts/$1/zip" > "$2.zip" 2> "$2.zip.stderr" &&
        unzip -q -o "$2.zip" -d "$2"
}

# sc_fetch_run_artifact KIND COMMIT JOB ARTIFACT DEST
#   Locate the newest push-to-main run of the reference workflow for COMMIT,
#   require JOB (in that run's latest attempt) to be completed, and download
#   ARTIFACT. Sets SC_RUN_STATUS to ok, pending, absent, rejected or
#   api-error, SC_RUN_ID and SC_RUN_ATTEMPT, SC_JOB_CONCLUSION, and appends
#   reasons to DEST/reasons.
sc_fetch_run_artifact() {
    _sfra_kind=$1
    _sfra_commit=$2
    _sfra_job=$3
    _sfra_artifact=$4
    _sfra_dest=$5
    mkdir -p "$_sfra_dest"
    : > "$_sfra_dest/reasons"
    SC_RUN_ID=
    SC_RUN_ATTEMPT=
    SC_JOB_CONCLUSION=
    if ! sc_api "repos/$GITHUB_REPOSITORY/actions/workflows/$(basename "$SC_REFERENCE_WORKFLOW")/runs?event=push&branch=main&head_sha=$_sfra_commit&per_page=50" \
        "$_sfra_dest/runs.json"; then
        SC_RUN_STATUS=api-error
        echo "$_sfra_kind: listing reference runs for $_sfra_commit failed" >> "$_sfra_dest/reasons"
        return 0
    fi
    if ! _sfra_sel=$(sc_select_reference_run "$_sfra_dest/runs.json" "$GITHUB_REPOSITORY" "$_sfra_commit"); then
        SC_RUN_STATUS=api-error
        echo "$_sfra_kind: the reference runs listing for $_sfra_commit is not valid JSON" >> "$_sfra_dest/reasons"
        return 0
    fi
    if [ -z "$_sfra_sel" ]; then
        SC_RUN_STATUS=absent
        echo "$_sfra_kind: no push-to-main run of $SC_REFERENCE_WORKFLOW for $_sfra_commit" >> "$_sfra_dest/reasons"
        return 0
    fi
    SC_RUN_ID=$(printf '%s' "$_sfra_sel" | cut -f1)
    _sfra_runstatus=$(printf '%s' "$_sfra_sel" | cut -f3)
    if ! sc_api "repos/$GITHUB_REPOSITORY/actions/runs/$SC_RUN_ID/jobs?filter=all&per_page=100" \
        "$_sfra_dest/jobs.json"; then
        SC_RUN_STATUS=api-error
        echo "$_sfra_kind: listing jobs of run $SC_RUN_ID failed" >> "$_sfra_dest/reasons"
        return 0
    fi
    if ! _sfra_jobstate=$(sc_job_latest "$_sfra_dest/jobs.json" "$_sfra_job"); then
        SC_RUN_STATUS=api-error
        echo "$_sfra_kind: the jobs listing of run $SC_RUN_ID is not valid JSON" >> "$_sfra_dest/reasons"
        return 0
    fi
    SC_RUN_ATTEMPT=$(printf '%s' "$_sfra_jobstate" | cut -f1)
    _sfra_jobstatus=$(printf '%s' "$_sfra_jobstate" | cut -f2)
    SC_JOB_CONCLUSION=$(printf '%s' "$_sfra_jobstate" | cut -f3)
    if [ -z "$_sfra_jobstate" ] && [ "$_sfra_runstatus" = completed ]; then
        SC_RUN_STATUS=rejected
        echo "$_sfra_kind: completed run $SC_RUN_ID has no job '$_sfra_job'" >> "$_sfra_dest/reasons"
        return 0
    fi
    if [ -z "$_sfra_jobstate" ] || [ "$_sfra_jobstatus" != completed ]; then
        SC_RUN_STATUS=pending
        echo "$_sfra_kind: job '$_sfra_job' of run $SC_RUN_ID is ${_sfra_jobstatus:-not started}" >> "$_sfra_dest/reasons"
        return 0
    fi
    if ! sc_api "repos/$GITHUB_REPOSITORY/actions/runs/$SC_RUN_ID/artifacts?name=$_sfra_artifact&per_page=100" \
        "$_sfra_dest/artifacts.json"; then
        SC_RUN_STATUS=api-error
        echo "$_sfra_kind: listing artifacts of run $SC_RUN_ID failed" >> "$_sfra_dest/reasons"
        return 0
    fi
    if ! jq -e '.artifacts | type == "array"' "$_sfra_dest/artifacts.json" >/dev/null 2>&1; then
        SC_RUN_STATUS=api-error
        echo "$_sfra_kind: the artifacts listing of run $SC_RUN_ID is not valid JSON" >> "$_sfra_dest/reasons"
        return 0
    fi
    _sfra_id=$(sc_select_artifact "$_sfra_dest/artifacts.json" "$_sfra_artifact" "$SC_RUN_ID")
    if [ -z "$_sfra_id" ]; then
        SC_RUN_STATUS=rejected
        echo "$_sfra_kind: run $SC_RUN_ID has no unexpired $_sfra_artifact artifact" >> "$_sfra_dest/reasons"
        return 0
    fi
    if ! sc_download_artifact "$_sfra_id" "$_sfra_dest/artifact"; then
        SC_RUN_STATUS=api-error
        echo "$_sfra_kind: downloading $_sfra_artifact from run $SC_RUN_ID failed" >> "$_sfra_dest/reasons"
        return 0
    fi
    SC_RUN_STATUS=ok
}

# sc_resolve_reference COMMIT HEAD_RECORD DEST
#   SC_REF_STATUS: ok (DEST/record.tsv is a verified comparable reference),
#   pending, absent, rejected or api-error, with DEST/reasons.
sc_resolve_reference() {
    sc_fetch_run_artifact reference "$1" "$SC_REFERENCE_JOB_NAME" "$SC_REFERENCE_ARTIFACT" "$3"
    SC_REF_STATUS=$SC_RUN_STATUS
    SC_REF_RUN=$SC_RUN_ID
    SC_REF_ATTEMPT=$SC_RUN_ATTEMPT
    [ "$SC_REF_STATUS" = ok ] || return 0
    if [ "$SC_JOB_CONCLUSION" != success ]; then
        SC_REF_STATUS=rejected
        echo "reference: job '$SC_REFERENCE_JOB_NAME' concluded $SC_JOB_CONCLUSION" >> "$3/reasons"
        return 0
    fi
    if ! _srr_problems=$(sc_reference_record_check "$3/artifact/record.tsv" "$2" \
        "$GITHUB_REPOSITORY" "$SC_REF_RUN" "$SC_REF_ATTEMPT" "$1" gate); then
        SC_REF_STATUS=rejected
        printf '%s\n' "$_srr_problems" | sed 's/^/reference: /' >> "$3/reasons"
        return 0
    fi
    if [ "$(sc_record_get "$3/artifact/record.tsv" tree)" != "$(sc_commit_tree "$1")" ]; then
        SC_REF_STATUS=rejected
        echo "reference: record tree is not the tree of $1" >> "$3/reasons"
        return 0
    fi
    cp "$3/artifact/record.tsv" "$3/record.tsv"
}

sc_commit_tree() {
    git rev-parse "$1^{tree}"
}

sc_fetch_commit() {
    git cat-file -e "$1^{commit}" 2>/dev/null ||
        git fetch --no-tags --depth=1 origin "$1" >/dev/null 2>&1 ||
        sc_fail "cannot fetch commit $1"
}

# --- in-place fallback -----------------------------------------------------------

# Run `fallback` from a copy of this tool: the checkout under it changes.
sc_run_fallback() {
    _srf_base=$1
    _srf_head=$2
    _srf_record=$3
    _srf_role=$4
    _srf_tool=$(mktemp -d "${RUNNER_TEMP:-/tmp}/self-compile-tool.XXXXXX") ||
        sc_fail "cannot create a directory for the fallback tool copy"
    cp "$SC_TOOL_DIR/self-compile.sh" "$SC_TOOL_DIR/lib-self-compile.sh" \
        "$SC_TOOL_DIR/self-compile-self-test.sh" "$_srf_tool/"
    TYPELISP_SELF_COMPILE_ROOT=$ROOT sh "$_srf_tool/self-compile.sh" fallback \
        "$_srf_base" "$_srf_head" "$ROOT/$_srf_record" "$_srf_role"
}

# fallback BASE HEAD RECORD ROLE
#   Measure BASE on this runner at this path: set HEAD's target/ aside,
#   check out BASE, overlay HEAD's measurement harness (explicit in the
#   record's procedure), build BASE's own fixpoint compiler with BASE's
#   ci-verify and fetched seed, measure it, and restore HEAD and its target/.
sc_cmd_fallback() {
    [ "$#" -eq 4 ] || { usage >&2; exit 2; }
    _scf_base=$1
    _scf_head=$2
    _scf_record=$3
    _scf_role=$4
    sc_is_sha "$_scf_base" || sc_fail "fallback base is not a commit id: $_scf_base"
    sc_is_sha "$_scf_head" || sc_fail "fallback head is not a commit id: $_scf_head"
    [ "$(git rev-parse HEAD)" = "$_scf_head" ] || sc_fail "checkout is not at $_scf_head"
    git diff --quiet && git diff --cached --quiet ||
        sc_fail "tracked files changed during CI; refusing to switch the checkout"
    sc_fetch_commit "$_scf_base"
    _scf_hold=$(mktemp -d "${RUNNER_TEMP:-/tmp}/self-compile-hold.XXXXXX") ||
        sc_fail "cannot create a directory to hold the head's target/"
    _scf_status=0
    _scf_at_base=0
    _scf_moved=0
    _scf_restored=0
    # Restore the head checkout and its target/ whatever happens, including
    # termination: undo the harness overlay so the base checkout is clean,
    # return to the head, and put the head's target/ back.
    sc_fallback_restore() {
        [ "$_scf_restored" -eq 0 ] || return 0
        _scf_restored=1
        if [ "$_scf_at_base" -eq 1 ]; then
            # shellcheck disable=SC2086
            git checkout --quiet "$_scf_base" -- $SC_PROCEDURE_FILES ||
                sc_log "could not undo the harness overlay on $_scf_base"
        fi
        git -c advice.detachedHead=false checkout --quiet --detach "$_scf_head" || {
            sc_log "could not restore $_scf_head after the fallback"
            return 1
        }
        if [ "$_scf_moved" -eq 1 ]; then
            if [ -d target ]; then
                mv target "$_scf_hold/base-target"
            fi
            mv "$_scf_hold/head-target" target
        fi
    }
    trap 'sc_fallback_restore; exit 1' INT TERM HUP
    trap 'sc_fallback_restore' EXIT
    if [ -d target ]; then
        mv target "$_scf_hold/head-target"
        _scf_moved=1
    fi
    sc_log "fallback: measuring $_scf_base in place ($_scf_role), harness from $_scf_head"
    if git -c advice.detachedHead=false checkout --quiet --detach "$_scf_base"; then
        _scf_at_base=1
    else
        _scf_status=1
    fi
    if [ "$_scf_status" -eq 0 ]; then
        env -u TYPELISP_BIN -u TYPELISP_CI_TIMING sh scripts/ci-verify.sh --gates bootstrap-fixpoint ||
            _scf_status=1
    fi
    # Overlay the head's harness after the base's own bootstrap, so the base
    # compiler is built entirely by the base's scripts.
    if [ "$_scf_status" -eq 0 ]; then
        # shellcheck disable=SC2086
        git checkout --quiet "$_scf_head" -- $SC_PROCEDURE_FILES || _scf_status=1
    fi
    if [ "$_scf_status" -eq 0 ]; then
        _scf_stage2=$(cat target/ci-verify-stage2.path 2>/dev/null || true)
        [ -n "$_scf_stage2" ] || _scf_status=1
    fi
    if [ "$_scf_status" -eq 0 ]; then
        ( sc_measure_into "$_scf_stage2" "$_scf_hold/record.tsv" "$_scf_role" ) || _scf_status=1
    fi
    sc_fallback_restore || sc_fail "could not restore the head checkout after the fallback"
    trap - INT TERM HUP EXIT
    [ "$_scf_status" -eq 0 ] || sc_fail "fallback measurement of $_scf_base failed; see the log above"
    _scf_msg=$(sc_record_validate "$_scf_hold/record.tsv" "$_scf_role") ||
        sc_fail "the fallback record is invalid: $_scf_msg"
    [ "$(sc_record_get "$_scf_hold/record.tsv" commit)" = "$_scf_base" ] ||
        sc_fail "the fallback measured $(sc_record_get "$_scf_hold/record.tsv" commit), not $_scf_base"
    mkdir -p "$(dirname -- "$_scf_record")"
    cp "$_scf_hold/record.tsv" "$_scf_record"
    if [ -s "$_scf_hold/base-target/instruction-count-check/measure/logs/$SC_HARNESS_LOG" ]; then
        cp "$_scf_hold/base-target/instruction-count-check/measure/logs/$SC_HARNESS_LOG" \
            "$(dirname -- "$_scf_record")/$_scf_role.cachegrind.out"
    fi
}

# --- PR check ----------------------------------------------------------------------

sc_require_actions() {
    sc_in_actions || sc_fail "$1 runs in GitHub Actions only; locally, compare base and branch on one host (perf/README.md)"
    case "$(uname -s)" in
        Linux*) ;;
        *) sc_fail "$1 runs on Linux only" ;;
    esac
    [ -n "${GITHUB_REPOSITORY:-}" ] || sc_fail "GITHUB_REPOSITORY is not set"
}

sc_cmd_check() {
    sc_require_actions check
    _scc_pr=${TYPELISP_SELF_COMPILE_PR_NUMBER:-}
    _scc_event_head=${TYPELISP_SELF_COMPILE_PR_HEAD:-}
    case "$_scc_pr" in
        "" | *[!0-9]*) sc_fail "TYPELISP_SELF_COMPILE_PR_NUMBER is not a PR number: $_scc_pr" ;;
    esac
    sc_is_sha "$_scc_event_head" || sc_fail "TYPELISP_SELF_COMPILE_PR_HEAD is not a commit id"
    _scc_out=$SC_OUT/pr
    [ ! -e "$_scc_out" ] || sc_fail "$_scc_out already exists"
    mkdir -p "$_scc_out"

    _scc_t=$(git rev-parse HEAD)
    [ "$_scc_t" = "${GITHUB_SHA:-}" ] || sc_fail "checkout $_scc_t is not GITHUB_SHA ${GITHUB_SHA:-}"
    _scc_parents=$(git cat-file -p HEAD | sed -n 's/^parent //p')
    [ "$(printf '%s\n' "$_scc_parents" | wc -l)" -eq 2 ] ||
        sc_fail "the tested commit $_scc_t is not a two-parent merge"
    _scc_b=$(printf '%s\n' "$_scc_parents" | sed -n 1p)
    _scc_h=$(printf '%s\n' "$_scc_parents" | sed -n 2p)
    [ "$_scc_h" = "$_scc_event_head" ] ||
        sc_fail "the tested merge's head parent $_scc_h is not the PR head $_scc_event_head"

    _scc_msg=$(sc_record_validate "$SC_GATE_RECORD" gate) ||
        sc_fail "no valid self_compile gate record: $_scc_msg (did linux-self-compile-measurement run?)"
    [ "$(sc_record_get "$SC_GATE_RECORD" commit)" = "$_scc_t" ] ||
        sc_fail "the gate record measured $(sc_record_get "$SC_GATE_RECORD" commit), not $_scc_t"
    [ "$(sc_record_get "$SC_GATE_RECORD" tree)" = "$(git rev-parse 'HEAD^{tree}')" ] ||
        sc_fail "the gate record's tree is not the tested tree"
    [ "$(sc_record_get "$SC_GATE_RECORD" authority)" = hosted ] ||
        sc_fail "the gate record is not from a GitHub-hosted runner"
    cp "$SC_GATE_RECORD" "$_scc_out/head.tsv"
    sc_fetch_commit "$_scc_b"

    # Declarations.
    _scc_own="$SC_DECLARATION_DIR/pr-$_scc_pr.tsv"
    git diff --name-status -M "$_scc_b" "$_scc_t" -- "$SC_DECLARATION_DIR" > "$_scc_out/declarations.diff"
    _scc_b_has_own=no
    git cat-file -e "$_scc_b:$_scc_own" 2>/dev/null && _scc_b_has_own=yes
    _scc_decl_problems=$(sc_declaration_diff_check "$_scc_pr" "$_scc_out/declarations.diff" "$_scc_b_has_own") ||
        true
    _scc_declared=none
    if [ -z "$_scc_decl_problems" ] && [ -f "$_scc_own" ]; then
        if ! _scc_declared=$(sc_declaration_parse "$_scc_own"); then
            _scc_decl_problems="malformed $_scc_own: $_scc_declared"
            _scc_declared=none
        fi
    fi

    # M(B): the verified reference, waiting for a pending one.
    _scc_waited=0
    while :; do
        _scc_refdir="$_scc_out/reference-$_scc_waited"
        sc_resolve_reference "$_scc_b" "$_scc_out/head.tsv" "$_scc_refdir"
        [ "$SC_REF_STATUS" = pending ] || break
        [ "$_scc_waited" -lt "$SC_WAIT_SECONDS" ] || break
        sc_log "reference for $_scc_b is pending; waiting"
        sleep "$SC_POLL_SECONDS"
        _scc_waited=$((_scc_waited + SC_POLL_SECONDS))
    done
    if [ "$SC_REF_STATUS" = ok ]; then
        cp "$_scc_refdir/record.tsv" "$_scc_out/base.tsv"
        _scc_source="reference run $SC_REF_RUN attempt $SC_REF_ATTEMPT"
    else
        sc_log "no usable reference for $_scc_b ($SC_REF_STATUS):"
        sed 's/^/  /' "$_scc_refdir/reasons" >&2
        if [ -f "$_scc_refdir/artifact/record.tsv" ]; then
            cp "$_scc_refdir/artifact/record.tsv" "$_scc_out/reference-rejected.tsv"
        fi
        sc_run_fallback "$_scc_b" "$_scc_t" "$_scc_out/base.tsv" base-fallback
        _scc_source="in-place fallback on this runner (reference $SC_REF_STATUS)"
    fi
    # Whatever its source, M(B) must be a valid record of B's commit and tree,
    # measured with a compiler stamped with B, comparable with M(T).
    _scc_msg=$(sc_record_validate "$_scc_out/base.tsv" gate base-fallback) ||
        sc_fail "invalid base measurement: $_scc_msg"
    [ "$(sc_record_get "$_scc_out/base.tsv" commit)" = "$_scc_b" ] ||
        sc_fail "the base measurement is not of $_scc_b"
    [ "$(sc_record_get "$_scc_out/base.tsv" tree)" = "$(sc_commit_tree "$_scc_b")" ] ||
        sc_fail "the base measurement's tree is not the tree of $_scc_b"
    [ "$(sc_record_get "$_scc_out/base.tsv" authority)" = hosted ] ||
        sc_fail "the base measurement is not from a GitHub-hosted runner"
    if [ -f "$_scc_out/reference-rejected.tsv" ] &&
        sc_record_validate "$_scc_out/reference-rejected.tsv" >/dev/null 2>&1 &&
        [ "$(sc_record_get "$_scc_out/reference-rejected.tsv" key.workspace)" = "$(sc_record_get "$_scc_out/base.tsv" key.workspace)" ]; then
        _scc_msg=$(sc_same_commit_binary "$_scc_out/reference-rejected.tsv" "$_scc_out/base.tsv") ||
            sc_fail "comparability failure: $_scc_msg"
    fi
    if ! _scc_diff=$(sc_records_comparable "$_scc_out/head.tsv" "$_scc_out/base.tsv"); then
        printf '%s\n' "$_scc_diff" >&2
        sc_fail "comparability failure: M(T) and M(B) have different measurement identities"
    fi

    # A harness change is explicit: B was measured with this PR's harness.
    _scc_procedure_change=no
    if [ "$(sc_procedure_hash_at "$_scc_b")" != "$(sc_record_get "$_scc_out/head.tsv" procedure)" ]; then
        _scc_procedure_change=yes
    fi

    sc_gate_decide "$_scc_out/head.tsv" "$_scc_out/base.tsv" "$_scc_declared" > "$_scc_out/gate.tsv"
    _scc_status=$(sc_record_get "$_scc_out/gate.tsv" status)
    {
        sc_record_line schema "$SC_RESULT_SCHEMA"
        sc_record_line pr "$_scc_pr"
        sc_record_line head "$_scc_h"
        sc_record_line merge "$_scc_t"
        sc_record_line base "$_scc_b"
        sc_record_line m_merge "$(sc_record_get "$_scc_out/head.tsv" ir_count)"
        sc_record_line m_base "$(sc_record_get "$_scc_out/base.tsv" ir_count)"
        sc_record_line base_source "$_scc_source"
        sc_record_line reference_status "$SC_REF_STATUS"
        sc_record_line procedure_change "$_scc_procedure_change"
        cat "$_scc_out/gate.tsv"
        sc_record_line declaration_problems "${_scc_decl_problems:--}"
        sc_run_lines
    } > "$_scc_out/result.tsv"

    _scc_own_ir=$(sc_record_get "$_scc_out/gate.tsv" own)
    _scc_ppm=$(sc_record_get "$_scc_out/gate.tsv" own_ppm)
    _scc_routing=$(sc_record_get "$_scc_out/gate.tsv" routing)
    echo "[self-compile] $SC_METRIC main-relative check"
    echo "[self-compile]   tested merge T $_scc_t = base B $_scc_b + head H $_scc_h"
    echo "[self-compile]   M(T) $(sc_record_get "$_scc_out/head.tsv" ir_count)"
    echo "[self-compile]   M(B) $(sc_record_get "$_scc_out/base.tsv" ir_count) from $_scc_source"
    echo "[self-compile]   own cost $(sc_signed "$_scc_own_ir") Ir ($_scc_ppm ppm); declared $_scc_declared; tolerance $SC_TOLERANCE_PPM ppm"
    echo "[self-compile]   status $_scc_status; routing $_scc_routing"
    [ -f "$_scc_out/reference-rejected.tsv" ] &&
        echo "[self-compile]   rejected reference value, for comparison: $(sc_record_get "$_scc_out/reference-rejected.tsv" ir_count)"
    sc_summary "### self_compile own cost"
    sc_summary ""
    sc_summary "| | |"
    sc_summary "|---|---|"
    sc_summary "| tested merge T | \`$_scc_t\` (B \`$_scc_b\` + H \`$_scc_h\`) |"
    sc_summary "| M(T) | $(sc_record_get "$_scc_out/head.tsv" ir_count) |"
    sc_summary "| M(B) | $(sc_record_get "$_scc_out/base.tsv" ir_count), $_scc_source |"
    sc_summary "| own cost | $(sc_signed "$_scc_own_ir") Ir, $_scc_ppm ppm |"
    sc_summary "| declared | $_scc_declared |"
    sc_summary "| status | $_scc_status (tolerance $SC_TOLERANCE_PPM ppm) |"
    sc_summary "| routing | $_scc_routing |"
    sc_summary "| harness change | $_scc_procedure_change |"
    if [ "$_scc_procedure_change" = yes ]; then
        echo "[self-compile]   this PR changes the measurement harness; M(B) was measured with it"
        sc_annotate warning "this PR changes the self_compile measurement harness (${SC_PROCEDURE_FILES}); reviewers assess the procedure change"
    fi
    _scc_rc=0
    if [ -n "$_scc_decl_problems" ]; then
        printf '%s\n' "$_scc_decl_problems" | sed 's/^/[self-compile] declaration: /' >&2
        sc_annotate error "declaration problems: $(printf '%s' "$_scc_decl_problems" | tr '\n' ';')"
        _scc_rc=1
    fi
    case "$_scc_status" in
        ok | declared-ok) ;;
        *)
            sc_annotate error "$_scc_status: own cost $(sc_signed "$_scc_own_ir") Ir ($_scc_ppm ppm) against $SC_TOLERANCE_PPM ppm"
            _scc_rc=1
            ;;
    esac
    case "$_scc_routing" in
        non-routine) sc_annotate warning "own or declared cost above +5000 ppm: non-routine, needs a council disposition" ;;
        explain-improvement) sc_annotate warning "improvement beyond -5000 ppm: both reviewers must explain its source" ;;
    esac
    return "$_scc_rc"
}

# --- reference ---------------------------------------------------------------------

sc_cmd_reference() {
    sc_require_actions reference
    _scr_out=$SC_OUT/reference
    _scr_msg=$(sc_record_validate "$SC_GATE_RECORD" gate) ||
        sc_fail "no valid self_compile gate record: $_scr_msg"
    [ "$(sc_record_get "$SC_GATE_RECORD" commit)" = "$(git rev-parse HEAD)" ] ||
        sc_fail "the gate record is not of the checkout"
    [ "$(sc_record_get "$SC_GATE_RECORD" authority)" = hosted ] ||
        sc_fail "a reference must come from a GitHub-hosted runner"
    mkdir -p "$_scr_out"
    cp "$SC_GATE_RECORD" "$_scr_out/record.tsv"
    if [ "${GITHUB_EVENT_NAME:-}" = push ]; then
        # Publish only what a consumer will accept from this job.
        _scr_problems=$(sc_reference_record_check "$_scr_out/record.tsv" "$_scr_out/record.tsv" \
            "$GITHUB_REPOSITORY" "${GITHUB_RUN_ID:-}" "${GITHUB_RUN_ATTEMPT:-}" \
            "$(git rev-parse HEAD)" gate) ||
            sc_fail "this push record would be rejected by consumers: $_scr_problems"
    else
        # A dry run publishes nothing a consumer accepts; prove that here.
        if sc_reference_record_check "$_scr_out/record.tsv" "$_scr_out/record.tsv" \
            "$GITHUB_REPOSITORY" "${GITHUB_RUN_ID:-}" "${GITHUB_RUN_ATTEMPT:-}" \
            "$(git rev-parse HEAD)" gate > "$_scr_out/dry-run-rejection.txt"; then
            sc_fail "a $GITHUB_EVENT_NAME record would be accepted as a reference"
        fi
        sc_log "dry run ($GITHUB_EVENT_NAME): consumers reject this record:"
        sed 's/^/  /' "$_scr_out/dry-run-rejection.txt" >&2
    fi
    sc_summary "### self_compile reference"
    sc_summary ""
    sc_summary "\`$(git rev-parse HEAD)\`: $(sc_record_get "$_scr_out/record.tsv" ir_count) Ir ($GITHUB_EVENT_NAME)"
    cat "$_scr_out/record.tsv"
}

# --- ledger ------------------------------------------------------------------------

# sc_fetch_pr_record COMMIT DEST
#   The merged PR's own CI result for COMMIT: its PR, final head H, that head's
#   latest successful CI run, and the run's self-compile-measurement artifact,
#   bound to each other. Writes DEST/pr.tsv, pr-head.tsv, pr-base.tsv, or
#   DEST/attribution-problem and fails.
sc_fetch_pr_record() {
    _sfpr_c=$1
    _sfpr_dest=$2
    mkdir -p "$_sfpr_dest/api"
    _sfpr_problem() {
        echo "$*" > "$_sfpr_dest/attribution-problem"
        return 1
    }
    sc_api "repos/$GITHUB_REPOSITORY/commits/$_sfpr_c/pulls" "$_sfpr_dest/api/pulls.json" ||
        { SC_LEDGER_INFRA="listing PRs of $_sfpr_c failed"; _sfpr_problem "API error listing PRs of $_sfpr_c"; return 1; }
    _sfpr_sel=$(jq -r --arg c "$_sfpr_c" '
        [.[] | select(.merge_commit_sha == $c and .merged_at != null and .base.ref == "main")]
        | if length == 1 then .[0] | [(.number | tostring), .head.sha] | @tsv else empty end' \
        "$_sfpr_dest/api/pulls.json" | tr -d '\r')
    [ -n "$_sfpr_sel" ] || { _sfpr_problem "no single merged PR has merge commit $_sfpr_c"; return 1; }
    _sfpr_pr=$(printf '%s' "$_sfpr_sel" | cut -f1)
    _sfpr_h=$(printf '%s' "$_sfpr_sel" | cut -f2)
    sc_api "repos/$GITHUB_REPOSITORY/actions/workflows/$(basename "$SC_CI_WORKFLOW")/runs?event=pull_request&head_sha=$_sfpr_h&per_page=50" \
        "$_sfpr_dest/api/runs.json" ||
        { SC_LEDGER_INFRA="listing CI runs of $_sfpr_h failed"; _sfpr_problem "API error listing CI runs of $_sfpr_h"; return 1; }
    _sfpr_id=$(sc_select_pr_run "$_sfpr_dest/api/runs.json" "$GITHUB_REPOSITORY" "$_sfpr_h")
    [ -n "$_sfpr_id" ] || { _sfpr_problem "PR #$_sfpr_pr head $_sfpr_h has no successful CI run"; return 1; }
    sc_api "repos/$GITHUB_REPOSITORY/actions/runs/$_sfpr_id/jobs?filter=all&per_page=100" \
        "$_sfpr_dest/api/jobs.json" ||
        { SC_LEDGER_INFRA="listing jobs of CI run $_sfpr_id failed"; _sfpr_problem "API error listing jobs of run $_sfpr_id"; return 1; }
    _sfpr_job=$(sc_job_latest "$_sfpr_dest/api/jobs.json" "$SC_CI_JOB_NAME")
    _sfpr_attempt=$(printf '%s' "$_sfpr_job" | cut -f1)
    [ "$(printf '%s' "$_sfpr_job" | cut -f2-3)" = "$(printf 'completed\tsuccess')" ] ||
        { _sfpr_problem "CI run $_sfpr_id: '$SC_CI_JOB_NAME' did not succeed in its latest attempt"; return 1; }
    sc_api "repos/$GITHUB_REPOSITORY/actions/runs/$_sfpr_id/artifacts?name=$SC_MEASUREMENT_ARTIFACT&per_page=100" \
        "$_sfpr_dest/api/artifacts.json" ||
        { SC_LEDGER_INFRA="listing artifacts of CI run $_sfpr_id failed"; _sfpr_problem "API error listing artifacts of run $_sfpr_id"; return 1; }
    _sfpr_art=$(sc_select_artifact "$_sfpr_dest/api/artifacts.json" "$SC_MEASUREMENT_ARTIFACT" "$_sfpr_id")
    [ -n "$_sfpr_art" ] ||
        { _sfpr_problem "CI run $_sfpr_id has no unexpired $SC_MEASUREMENT_ARTIFACT artifact"; return 1; }
    sc_download_artifact "$_sfpr_art" "$_sfpr_dest/artifact" ||
        { SC_LEDGER_INFRA="downloading $SC_MEASUREMENT_ARTIFACT from run $_sfpr_id failed"; _sfpr_problem "download failed"; return 1; }
    _sfpr_a=$_sfpr_dest/artifact
    for _sfpr_f in result.tsv head.tsv base.tsv; do
        [ -f "$_sfpr_a/$_sfpr_f" ] || { _sfpr_problem "the PR artifact lacks $_sfpr_f"; return 1; }
    done
    _sfpr_bind_problems=$(sc_pr_record_binding "$_sfpr_a" "$_sfpr_pr" "$_sfpr_h" "$_sfpr_id" "$_sfpr_attempt" "$GITHUB_REPOSITORY") ||
        { _sfpr_problem "$_sfpr_bind_problems"; return 1; }
    cp "$_sfpr_a/result.tsv" "$_sfpr_dest/pr.tsv"
    cp "$_sfpr_a/head.tsv" "$_sfpr_dest/pr-head.tsv"
    cp "$_sfpr_a/base.tsv" "$_sfpr_dest/pr-base.tsv"
}

# sc_pr_record_binding DIR PR HEAD RUN ATTEMPT REPO
#   The PR artifact must describe that PR's final head, be produced by that
#   run attempt, and its records must measure its tested merge and base.
sc_pr_record_binding() {
    _sprb=$1
    _sprb_status=0
    _sprb_check() {
        if [ "$(sc_record_get "$_sprb/$1" "$2" 2>/dev/null || true)" != "$3" ]; then
            echo "$1 $2 is '$(sc_record_get "$_sprb/$1" "$2" 2>/dev/null || true)', expected '$3'"
            _sprb_status=1
        fi
    }
    _sprb_check result.tsv schema "$SC_RESULT_SCHEMA"
    _sprb_check result.tsv pr "$2"
    _sprb_check result.tsv head "$3"
    _sprb_check result.tsv run.id "$4"
    _sprb_check result.tsv run.attempt "$5"
    _sprb_check result.tsv run.repository "$6"
    _sprb_check result.tsv run.event pull_request
    _sprb_check head.tsv commit "$(sc_record_get "$_sprb/result.tsv" merge 2>/dev/null || true)"
    _sprb_check base.tsv commit "$(sc_record_get "$_sprb/result.tsv" base 2>/dev/null || true)"
    _sprb_check head.tsv run.id "$4"
    _sprb_check head.tsv run.attempt "$5"
    if ! _sprb_m=$(sc_record_validate "$_sprb/head.tsv" gate); then echo "$_sprb_m"; _sprb_status=1; fi
    if ! _sprb_m=$(sc_record_validate "$_sprb/base.tsv"); then echo "$_sprb_m"; _sprb_status=1; fi
    return "$_sprb_status"
}

# sc_this_runner_record DEST LIKE  ->  the identity a measurement taken on
# this runner of the checkout would have, with LIKE's measured argv.
sc_this_runner_record() {
    {
        sc_record_line schema "$SC_RECORD_SCHEMA"
        sc_record_line metric "$SC_METRIC"
        sc_record_line argv_normalized "$(sc_record_get "$2" argv_normalized)"
        sc_record_line cwd "$(pwd -P)"
        sc_record_line env LC_ALL=C
        sc_record_line procedure "$(sc_procedure_hash)"
        sc_identity_lines
    } > "$1"
}

# sc_ledger_measure_pair_here C P DEST
#   Measure C (the checkout) and P on this runner, keeping the records they
#   replace as *-reference.tsv. Returns 3 on a measurement failure.
sc_ledger_measure_pair_here() {
    if [ -f "$3/landed.tsv" ]; then
        cp "$3/landed.tsv" "$3/landed-reference.tsv"
    fi
    if [ -f "$3/parent.tsv" ]; then
        cp "$3/parent.tsv" "$3/parent-reference.tsv"
    fi
    env -u TYPELISP_BIN sh scripts/ci-verify.sh --gates linux-self-compile-measurement ||
        { echo "measuring $1 on the ledger runner failed" > "$3/measurement-problem"; return 3; }
    cp "$SC_GATE_RECORD" "$3/landed.tsv"
    sc_run_fallback "$2" "$1" "$3/parent.tsv" parent-fallback ||
        { echo "measuring $2 on the ledger runner failed" > "$3/measurement-problem"; return 3; }
}

# sc_ledger_pair C P DEST WORK
#   A comparable measurement pair of P and C in DEST/parent.tsv and
#   DEST/landed.tsv: C's reference from this run, with P's reference when
#   comparable; otherwise P measured on this runner, and C as well when C's
#   reference is not comparable with this runner. Downloads go to WORK.
#   Sets SC_PAIR_SOURCE. Returns 1 for an infrastructure failure, 2 for a
#   provenance failure, 3 for a measurement failure.
sc_ledger_pair() {
    _slp_c=$1
    _slp_p=$2
    _slp_dest=$3
    _slp_work=$4
    mkdir -p "$_slp_dest" "$_slp_work"
    sc_api "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/artifacts?name=$SC_REFERENCE_ARTIFACT&per_page=100" \
        "$_slp_work/this-run-artifacts.json" ||
        { SC_LEDGER_INFRA="listing this run's artifacts failed"; return 1; }
    _slp_art=$(sc_select_artifact "$_slp_work/this-run-artifacts.json" "$SC_REFERENCE_ARTIFACT" "$GITHUB_RUN_ID")
    [ -n "$_slp_art" ] ||
        { echo "this run has no $SC_REFERENCE_ARTIFACT artifact" > "$_slp_dest/provenance-problem"; return 2; }
    sc_download_artifact "$_slp_art" "$_slp_work/this-run" ||
        { SC_LEDGER_INFRA="downloading this run's reference failed"; return 1; }
    sc_api "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/jobs?filter=all&per_page=100" \
        "$_slp_work/this-run-jobs.json" ||
        { SC_LEDGER_INFRA="listing this run's jobs failed"; return 1; }
    _slp_job=$(sc_job_latest "$_slp_work/this-run-jobs.json" "$SC_REFERENCE_JOB_NAME")
    [ "$(printf '%s' "$_slp_job" | cut -f2-3)" = "$(printf 'completed\tsuccess')" ] ||
        { echo "this run's '$SC_REFERENCE_JOB_NAME' job did not succeed" > "$_slp_dest/provenance-problem"; return 2; }
    _slp_msg=$(sc_reference_record_check "$_slp_work/this-run/record.tsv" "$_slp_work/this-run/record.tsv" \
        "$GITHUB_REPOSITORY" "$GITHUB_RUN_ID" "$(printf '%s' "$_slp_job" | cut -f1)" "$_slp_c" gate) ||
        { echo "$_slp_msg" > "$_slp_dest/provenance-problem"; return 2; }
    cp "$_slp_work/this-run/record.tsv" "$_slp_dest/landed.tsv"
    _slp_waited=0
    while :; do
        sc_resolve_reference "$_slp_p" "$_slp_dest/landed.tsv" "$_slp_work/parent-reference-$_slp_waited"
        [ "$SC_REF_STATUS" = pending ] || break
        [ "$_slp_waited" -lt "$SC_WAIT_SECONDS" ] || break
        sleep "$SC_POLL_SECONDS"
        _slp_waited=$((_slp_waited + SC_POLL_SECONDS))
    done
    if [ "$SC_REF_STATUS" = ok ]; then
        cp "$_slp_work/parent-reference-$_slp_waited/record.tsv" "$_slp_dest/parent.tsv"
        SC_PAIR_SOURCE="references (parent run $SC_REF_RUN)"
        return 0
    fi
    if [ "$SC_REF_STATUS" = api-error ]; then
        SC_LEDGER_INFRA="resolving the parent reference failed"
        return 1
    fi
    sc_this_runner_record "$_slp_work/this-runner.tsv" "$_slp_dest/landed.tsv"
    if sc_records_comparable "$_slp_dest/landed.tsv" "$_slp_work/this-runner.tsv" > "$_slp_work/runner-differences"; then
        sc_run_fallback "$_slp_p" "$_slp_c" "$_slp_dest/parent.tsv" parent-fallback ||
            { echo "measuring $_slp_p on the ledger runner failed" > "$_slp_dest/measurement-problem"; return 3; }
        SC_PAIR_SOURCE="parent measured on the ledger runner (parent reference $SC_REF_STATUS)"
    else
        sc_ledger_measure_pair_here "$_slp_c" "$_slp_p" "$_slp_dest" || return 3
        SC_PAIR_SOURCE="parent and commit measured on the ledger runner (reference not comparable here)"
    fi
}

# sc_ledger_reproduce C DEST WORK
#   The merged PR's T and B were measured in an identity that differs from the
#   landed pair's. Reproduce them on this runner in one identity with the pair
#   (re-measuring the pair here first when it is not of this runner): B in
#   place, and T as the landed commit when the trees are equal, otherwise
#   rebuilt with git merge-tree from B and the PR head and checked against the
#   recorded tested tree. Writes DEST/rep-head.tsv and DEST/rep-base.tsv, or
#   DEST/reproduction-problem and fails.
sc_ledger_reproduce() {
    _slr_c=$1
    _slr_dest=$2
    _slr_work=$3
    _slr_problem() {
        echo "$*" > "$_slr_dest/reproduction-problem"
        return 1
    }
    mkdir -p "$_slr_work" ||
        { _slr_problem "cannot create the reproduction work directory"; return 1; }
    sc_this_runner_record "$_slr_work/reproduce-runner.tsv" "$_slr_dest/landed.tsv" ||
        { _slr_problem "cannot describe this runner's identity"; return 1; }
    if ! sc_records_comparable "$_slr_dest/landed.tsv" "$_slr_work/reproduce-runner.tsv" >/dev/null; then
        sc_ledger_measure_pair_here "$_slr_c" "$(cat "$_slr_dest/parent")" "$_slr_dest" ||
            { _slr_problem "measuring the pair on the ledger runner failed"; return 1; }
        SC_PAIR_SOURCE="parent and commit measured on the ledger runner (to reproduce the PR comparison)"
        if sc_records_comparable "$_slr_dest/pr-head.tsv" "$_slr_dest/landed.tsv" >/dev/null &&
            sc_records_comparable "$_slr_dest/pr-base.tsv" "$_slr_dest/landed.tsv" >/dev/null; then
            return 0
        fi
    fi
    _slr_b=$(sc_record_get "$_slr_dest/pr.tsv" base)
    _slr_h=$(sc_record_get "$_slr_dest/pr.tsv" head)
    _slr_tt=$(sc_record_get "$_slr_dest/pr-head.tsv" tree)
    sc_is_sha "$_slr_b" && sc_is_sha "$_slr_h" && sc_is_sha "$_slr_tt" ||
        { _slr_problem "the PR record lacks its tested base, head or tree"; return 1; }
    sc_run_fallback "$_slr_b" "$_slr_c" "$_slr_dest/rep-base.tsv" base-fallback ||
        { _slr_problem "measuring the tested base $_slr_b on the ledger runner failed"; return 1; }
    if [ "$_slr_tt" = "$(sc_commit_tree "$_slr_c")" ]; then
        cp "$_slr_dest/landed.tsv" "$_slr_dest/rep-head.tsv"
        sc_record_line reproduction "T measured as the landed commit (same tree)" >> "$_slr_dest/reproduction"
        return 0
    fi
    git cat-file -e "$_slr_h^{commit}" 2>/dev/null ||
        git fetch --no-tags origin "$_slr_h" >/dev/null 2>&1 ||
        { _slr_problem "cannot fetch the PR head $_slr_h"; return 1; }
    _slr_tree=$(git merge-tree --write-tree "$_slr_b" "$_slr_h" 2>/dev/null | sed -n 1p) ||
        { _slr_problem "the tested merge of $_slr_b and $_slr_h does not rebuild cleanly"; return 1; }
    [ "$_slr_tree" = "$_slr_tt" ] ||
        { _slr_problem "the rebuilt merge tree $_slr_tree is not the tested tree $_slr_tt"; return 1; }
    _slr_t=$(GIT_AUTHOR_NAME=self-compile GIT_AUTHOR_EMAIL=self-compile@invalid \
        GIT_COMMITTER_NAME=self-compile GIT_COMMITTER_EMAIL=self-compile@invalid \
        git commit-tree "$_slr_tree" -p "$_slr_b" -p "$_slr_h" -m "self-compile ledger: rebuilt tested merge") ||
        { _slr_problem "could not record the rebuilt tested merge"; return 1; }
    sc_run_fallback "$_slr_t" "$_slr_c" "$_slr_dest/rep-head.tsv" head-reproduction ||
        { _slr_problem "measuring the rebuilt tested merge on the ledger runner failed"; return 1; }
    sc_record_line reproduction "T rebuilt as $_slr_t (tree $_slr_tree)" >> "$_slr_dest/reproduction"
}

# sc_ledger_walk_line COMMIT WORK  ->  one sc_chain_plan line for an ancestor,
# downloading its ledger artifact into WORK when there is one.
sc_ledger_walk_line() {
    _slwl_x=$1
    _slwl_dest=$2
    if ! git cat-file -e "$_slwl_x:$SC_REFERENCE_WORKFLOW" 2>/dev/null; then
        printf '%s\tno\tnone\tnone\tno\n' "$_slwl_x"
        return 0
    fi
    _slwl_checkpoint=no
    if [ -f "$SC_CHECKPOINT_FILE" ] && sc_account_valid "$SC_CHECKPOINT_FILE" "$_slwl_x"; then
        _slwl_checkpoint=yes
    fi
    sc_fetch_run_artifact ledger "$_slwl_x" "$SC_LEDGER_JOB_NAME" "$SC_LEDGER_ARTIFACT" "$_slwl_dest"
    _slwl_account=none
    _slwl_entry=missing
    case "$SC_RUN_STATUS" in
        pending) _slwl_entry=pending ;;
        api-error) echo "reading the ledger of $_slwl_x failed" > "$_slwl_dest/api-error" ;;
        ok)
            _slwl_a=$_slwl_dest/artifact
            if [ "$(sc_record_get "$_slwl_a/producer.tsv" commit 2>/dev/null || true)" = "$_slwl_x" ] &&
                [ "$(sc_record_get "$_slwl_a/producer.tsv" run.id 2>/dev/null || true)" = "$SC_RUN_ID" ] &&
                [ "$(sc_record_get "$_slwl_a/producer.tsv" run.attempt 2>/dev/null || true)" = "$SC_RUN_ATTEMPT" ]; then
                if [ "$(sc_record_get "$_slwl_a/entry.tsv" commit 2>/dev/null || true)" = "$_slwl_x" ]; then
                    _slwl_entry=present
                fi
                if [ -f "$_slwl_a/account.tsv" ] && sc_account_valid "$_slwl_a/account.tsv" "$_slwl_x"; then
                    _slwl_account=complete
                fi
            fi
            ;;
    esac
    printf '%s\tyes\t%s\t%s\t%s\n' "$_slwl_x" "$_slwl_account" "$_slwl_entry" "$_slwl_checkpoint"
}

# sc_ledger_repair_entries ACCOUNT WORK OUT
#   An entry without an accounted step is replaced when its commit's ledger has
#   since been re-run and produced a complete entry.
sc_ledger_repair_entries() {
    cp "$1" "$3"
    for _slre_c in $(awk -F '\t' '$1 == "entry" && ($6 == "-" || $7 == "-") { print $2 }' "$1"); do
        _slre_dir=$2/repair-$_slre_c
        sc_fetch_run_artifact ledger "$_slre_c" "$SC_LEDGER_JOB_NAME" "$SC_LEDGER_ARTIFACT" "$_slre_dir"
        [ "$SC_RUN_STATUS" = ok ] || continue
        [ "$(sc_record_get "$_slre_dir/artifact/producer.tsv" run.id 2>/dev/null || true)" = "$SC_RUN_ID" ] || continue
        [ "$(sc_record_get "$_slre_dir/artifact/producer.tsv" run.attempt 2>/dev/null || true)" = "$SC_RUN_ATTEMPT" ] || continue
        [ "$(sc_record_get "$_slre_dir/artifact/entry.tsv" commit 2>/dev/null || true)" = "$_slre_c" ] || continue
        sc_record_get "$_slre_dir/artifact/entry.tsv" step >/dev/null 2>&1 || continue
        sc_record_get "$_slre_dir/artifact/entry.tsv" own >/dev/null 2>&1 || continue
        sc_account_apply "$3" "$_slre_dir/artifact/entry.tsv" > "$3.next"
        mv "$3.next" "$3"
        sc_log "repaired the ledger entry of $_slre_c from its re-run"
    done
}

sc_cmd_ledger() {
    sc_require_actions ledger
    [ "${GITHUB_EVENT_NAME:-}" = push ] || sc_fail "the ledger runs on pushes to main"
    _scl_c=$(git rev-parse HEAD)
    [ "$_scl_c" = "${GITHUB_SHA:-}" ] || sc_fail "checkout is not GITHUB_SHA"
    _scl_p=$(git rev-parse HEAD^1)
    # The uploaded ledger holds only compact records; downloads stay in work.
    _scl_out=$SC_OUT/ledger
    _scl_work=$SC_OUT/ledger-work
    [ ! -e "$_scl_out" ] || sc_fail "$_scl_out already exists"
    [ ! -e "$_scl_work" ] || sc_fail "$_scl_work already exists"
    mkdir -p "$_scl_out/entry-inputs" "$_scl_work/walk"
    SC_LEDGER_INFRA=
    {
        sc_record_line commit "$_scl_c"
        sc_run_lines
    } > "$_scl_out/producer.tsv"

    # 1. This merge's entry.
    _scl_in=$_scl_out/entry-inputs
    printf '%s\n' "$_scl_c" > "$_scl_in/commit"
    printf '%s\n' "$_scl_p" > "$_scl_in/parent"
    git rev-parse "$_scl_c^{tree}" > "$_scl_in/tree.commit"
    git rev-parse "$_scl_p^{tree}" > "$_scl_in/tree.parent"
    _scl_outcome=
    _scl_detail=
    _scl_pair_rc=0
    sc_ledger_pair "$_scl_c" "$_scl_p" "$_scl_in" "$_scl_work/pair" || _scl_pair_rc=$?
    case "$_scl_pair_rc" in
        0) ;;
        1) _scl_outcome=infrastructure-failure; _scl_detail=$SC_LEDGER_INFRA ;;
        2) _scl_outcome=provenance-failure; _scl_detail=$(cat "$_scl_in/provenance-problem") ;;
        *) _scl_outcome=measurement-failure; _scl_detail=$(cat "$_scl_in/measurement-problem" 2>/dev/null || echo "pair measurement failed") ;;
    esac
    if [ -z "$_scl_outcome" ]; then
        if sc_fetch_pr_record "$_scl_c" "$_scl_work/pr"; then
            cp "$_scl_work/pr/pr.tsv" "$_scl_work/pr/pr-head.tsv" "$_scl_work/pr/pr-base.tsv" "$_scl_in/"
            _scl_b=$(sc_record_get "$_scl_in/pr.tsv" base)
            if git merge-base --is-ancestor "$_scl_b" "$_scl_p" 2>/dev/null; then
                git log --first-parent --format=%H "$_scl_b..$_scl_p" > "$_scl_in/merges-between"
            fi
            if ! sc_records_comparable "$_scl_in/pr-head.tsv" "$_scl_in/landed.tsv" >/dev/null ||
                ! sc_records_comparable "$_scl_in/pr-base.tsv" "$_scl_in/landed.tsv" >/dev/null; then
                sc_ledger_reproduce "$_scl_c" "$_scl_in" "$_scl_work/reproduce" ||
                    sc_log "could not reproduce the PR comparison: $(cat "$_scl_in/reproduction-problem" 2>/dev/null)"
            fi
        elif [ -n "$SC_LEDGER_INFRA" ]; then
            _scl_outcome=infrastructure-failure
            _scl_detail=$SC_LEDGER_INFRA
        else
            cp "$_scl_work/pr/attribution-problem" "$_scl_in/attribution-problem" 2>/dev/null || true
        fi
    fi
    if [ -z "$_scl_outcome" ]; then
        # After every re-measurement: one commit measured twice with the same
        # as/ld must have measured the same compiler bytes.
        # Every pair of records held; sc_same_commit_binary applies only to
        # one commit built with the same as/ld at the same workspace.
        _scl_records=
        for _scl_kind in landed-reference landed parent-reference parent pr-head pr-base rep-head rep-base; do
            [ -f "$_scl_in/$_scl_kind.tsv" ] && _scl_records="$_scl_records $_scl_kind"
        done
        _scl_rest=$_scl_records
        for _scl_one in $_scl_records; do
            _scl_rest=${_scl_rest# }
            _scl_rest=${_scl_rest#"$_scl_one"}
            for _scl_two in $_scl_rest; do
                if ! _scl_msg=$(sc_same_commit_binary "$_scl_in/$_scl_one.tsv" "$_scl_in/$_scl_two.tsv"); then
                    echo "$_scl_one/$_scl_two: $_scl_msg" >> "$_scl_in/binary-problem"
                fi
            done
        done
        sc_ledger_entry "$_scl_in" > "$_scl_out/entry.tsv"
        sc_record_line pair_source "$SC_PAIR_SOURCE" >> "$_scl_out/entry.tsv"
        if [ -f "$_scl_in/attribution-problem" ]; then
            sc_record_line attribution_problem "$(cat "$_scl_in/attribution-problem")" >> "$_scl_out/entry.tsv"
        fi
        if [ -f "$_scl_in/reproduction-problem" ]; then
            sc_record_line reproduction_problem "$(cat "$_scl_in/reproduction-problem")" >> "$_scl_out/entry.tsv"
        fi
        # A reconciliation stays explicit: c re-measured on this runner.
        if [ -f "$_scl_in/landed-reference.tsv" ]; then
            sc_record_line reconciliation \
                "M(c) reference $(sc_record_get "$_scl_in/landed-reference.tsv" ir_count), ledger runner $(sc_record_get "$_scl_in/landed.tsv" ir_count)" \
                >> "$_scl_out/entry.tsv"
        fi
        _scl_outcome=$(sc_record_get "$_scl_out/entry.tsv" outcome)
    else
        {
            sc_record_line schema "$SC_ENTRY_SCHEMA"
            sc_record_line commit "$_scl_c"
            sc_record_line parent "$_scl_p"
            sc_record_line outcome "$_scl_outcome"
            sc_record_line failures "$_scl_outcome"
            sc_record_line detail "$_scl_detail"
        } > "$_scl_out/entry.tsv"
    fi

    # 2. The cumulative account, from the nearest verified account, checkpoint
    #    or the anchor, through every merge since.
    _scl_chain=complete
    _scl_account_outcome=pending
    printf '%s\tyes\tself\tpresent\tno\n' "$_scl_c" > "$_scl_out/walk.tsv"
    _scl_i=0
    _scl_x=$_scl_p
    _scl_plan=
    while [ "$_scl_i" -lt "$SC_WALK_LIMIT" ]; do
        _scl_i=$((_scl_i + 1))
        _scl_line=$(sc_ledger_walk_line "$_scl_x" "$_scl_work/walk/$_scl_x-0")
        _scl_waited=0
        # The parent's ledger usually finishes first; wait for it briefly.
        while [ "$_scl_i" -eq 1 ] && [ "$(printf '%s' "$_scl_line" | cut -f4)" = pending ] &&
            [ "$_scl_waited" -lt "$SC_WAIT_SECONDS" ]; do
            sleep "$SC_POLL_SECONDS"
            _scl_waited=$((_scl_waited + SC_POLL_SECONDS))
            _scl_line=$(sc_ledger_walk_line "$_scl_x" "$_scl_work/walk/$_scl_x-$_scl_waited")
        done
        if [ -d "$_scl_work/walk/$_scl_x-$_scl_waited" ]; then
            mv "$_scl_work/walk/$_scl_x-$_scl_waited" "$_scl_work/walk/$_scl_x"
        fi
        printf '%s\n' "$_scl_line" >> "$_scl_out/walk.tsv"
        _scl_plan=$(sc_chain_plan "$_scl_out/walk.tsv")
        case "$_scl_plan" in
            *"no account, checkpoint or anchor"*) ;;
            *) break ;;
        esac
        _scl_x=$(git rev-parse "$_scl_x^1" 2>/dev/null) || break
    done
    printf '%s\n' "$_scl_plan" > "$_scl_out/plan.tsv"
    _scl_plan_outcome=$(awk -F '\t' '$1 == "outcome" { print $2 ": " $3 }' "$_scl_out/plan.tsv")
    for _scl_marker in "$_scl_work"/walk/*/api-error; do
        [ -f "$_scl_marker" ] || continue
        case "$_scl_plan_outcome" in
            continuity-failure*)
                _scl_plan_outcome="infrastructure-failure: $(cat "$_scl_marker")"
                ;;
        esac
    done
    if [ -z "$_scl_plan_outcome" ]; then
        _scl_kind=$(awk -F '\t' '$1 == "base" { print $2 }' "$_scl_out/plan.tsv")
        _scl_base=$(awk -F '\t' '$1 == "base" { print $3 }' "$_scl_out/plan.tsv")
        case "$_scl_kind" in
            account) cp "$_scl_work/walk/$_scl_base/artifact/account.tsv" "$_scl_work/account-base.tsv" ;;
            checkpoint) cp "$SC_CHECKPOINT_FILE" "$_scl_work/account-base.tsv" ;;
            anchor)
                _scl_c0=$(awk -F '\t' '$1 == "gap" { print $2; exit }' "$_scl_out/plan.tsv")
                if [ "$_scl_c0" = "$_scl_c" ]; then
                    _scl_c0_entry=$_scl_out/entry.tsv
                else
                    _scl_c0_entry=$_scl_work/walk/$_scl_c0/artifact/entry.tsv
                fi
                _scl_p0_ir=$(sc_record_get "$_scl_c0_entry" m_parent 2>/dev/null || true)
                if sc_is_count "$_scl_p0_ir"; then
                    sc_account_seed "$_scl_c0" "$_scl_base" "$_scl_p0_ir" > "$_scl_work/account-base.tsv"
                else
                    _scl_plan_outcome="continuity-failure: the anchor entry for $_scl_c0 has no seeded M(p0)"
                fi
                ;;
        esac
    fi
    if [ -z "$_scl_plan_outcome" ]; then
        mkdir -p "$_scl_work/account-steps" "$_scl_work/repair"
        sc_ledger_repair_entries "$_scl_work/account-base.tsv" "$_scl_work/repair" "$_scl_work/account-steps/0.tsv"
        _scl_n=0
        for _scl_g in $(awk -F '\t' '$1 == "gap" { print $2 }' "$_scl_out/plan.tsv"); do
            if [ "$_scl_g" = "$_scl_c" ]; then
                _scl_e=$_scl_out/entry.tsv
            else
                _scl_e=$_scl_work/walk/$_scl_g/artifact/entry.tsv
            fi
            sc_account_apply "$_scl_work/account-steps/$_scl_n.tsv" "$_scl_e" \
                > "$_scl_work/account-steps/$((_scl_n + 1)).tsv"
            _scl_n=$((_scl_n + 1))
        done
        sc_account_resolve "$_scl_work/account-steps/$_scl_n.tsv" "$SC_RESOLUTIONS_FILE" \
            > "$_scl_out/account.tsv"
        sc_account_summary "$_scl_out/account.tsv" > "$_scl_out/summary.tsv"
        _scl_account_outcome=$(sc_account_outcome "$_scl_out/account.tsv")
    else
        _scl_chain=$_scl_plan_outcome
    fi

    # 3. Outcome for D2: pending, ok, warning or a named failure class.
    case "$_scl_chain" in
        pending*) case "$_scl_outcome" in ok | warning) _scl_outcome=pending ;; esac ;;
        continuity-failure*) case "$_scl_outcome" in ok | warning) _scl_outcome=continuity-failure ;; esac ;;
        infrastructure-failure*) case "$_scl_outcome" in ok | warning) _scl_outcome=infrastructure-failure ;; esac ;;
    esac
    _scl_complete=no
    if [ "$_scl_chain" = complete ] &&
        [ "$(sc_record_get "$_scl_out/summary.tsv" complete 2>/dev/null || true)" = yes ]; then
        _scl_complete=yes
    fi
    {
        sc_record_line commit "$_scl_c"
        sc_record_line outcome "$_scl_outcome"
        sc_record_line complete "$_scl_complete"
        sc_record_line chain "$_scl_chain"
        sc_record_line account "$_scl_account_outcome"
        sc_record_line detail "${_scl_detail:--}"
    } > "$_scl_out/outcome.tsv"
    cat "$_scl_out/entry.tsv"
    if [ -f "$_scl_out/summary.tsv" ]; then
        cat "$_scl_out/summary.tsv"
    fi
    cat "$_scl_out/outcome.tsv"
    sc_summary "### self_compile ledger: \`$_scl_c\`"
    sc_summary ""
    sc_summary "outcome **$_scl_outcome**, complete $_scl_complete, account $_scl_account_outcome, chain $_scl_chain"
    sc_summary ""
    sc_summary '```'
    sc_summary "$(cat "$_scl_out/entry.tsv")"
    if [ -f "$_scl_out/summary.tsv" ]; then
        sc_summary "$(cat "$_scl_out/summary.tsv")"
    fi
    sc_summary '```'
    case "$_scl_outcome" in
        ok | pending) ;;
        warning) sc_annotate warning "ledger warning for $_scl_c: $(sc_record_get "$_scl_out/entry.tsv" warnings 2>/dev/null || true)" ;;
        *) sc_annotate error "ledger $_scl_outcome for $_scl_c"; return 1 ;;
    esac
    if [ "$_scl_account_outcome" = unresolved ]; then
        sc_annotate error "the cumulative account carries unresolved ledger failures"
        return 1
    fi
}

# --- self-test ---------------------------------------------------------------------

. "$SC_TOOL_DIR/self-compile-self-test.sh"

case "${1:-}" in
    measure) shift; sc_cmd_measure "$@" ;;
    check) shift; sc_cmd_check "$@" ;;
    reference) shift; sc_cmd_reference "$@" ;;
    ledger) shift; sc_cmd_ledger "$@" ;;
    fallback) shift; sc_cmd_fallback "$@" ;;
    --self-test) sc_self_test ;;
    -h | --help) usage ;;
    *) usage >&2; exit 2 ;;
esac
