# self-compile-self-test.sh - fixtures for scripts/self-compile.sh --self-test.
#
# Sourced by scripts/self-compile.sh. Drives every rule of the main-relative
# self_compile gate from fixtures: no compiler, valgrind, git history or
# network. The GitHub API and artifact downloads are replaced by fixture
# readers, so reference selection runs the same code CI runs.

st_failures=0
st_count=0

st_ok() {
    st_count=$((st_count + 1))
}

st_bad() {
    st_count=$((st_count + 1))
    st_failures=$((st_failures + 1))
    printf '[self-compile self-test] FAIL %s\n' "$*" >&2
}

st_eq() {
    if [ "$2" = "$3" ]; then
        st_ok
    else
        st_bad "$1: got '$2', want '$3'"
    fi
}

st_succeeds() {
    _sts_name=$1
    shift
    if "$@" >/dev/null 2>&1; then st_ok; else st_bad "$_sts_name: expected success"; fi
}

st_fails() {
    _stf_name=$1
    shift
    if "$@" >/dev/null 2>&1; then st_bad "$_stf_name: expected failure"; else st_ok; fi
}

ST_SHA_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
ST_SHA_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
ST_SHA_C=cccccccccccccccccccccccccccccccccccccccc
ST_SHA_D=dddddddddddddddddddddddddddddddddddddddd
ST_SHA_E=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
ST_SHA_F=ffffffffffffffffffffffffffffffffffffffff
ST_TREE_1=1111111111111111111111111111111111111111
ST_TREE_2=2222222222222222222222222222222222222222
ST_TREE_3=3333333333333333333333333333333333333333
ST_TREE_4=4444444444444444444444444444444444444444
ST_REPO=JoNil-Botta/typelisp
ST_REF_WORKFLOW_REF="$ST_REPO/.github/workflows/self-compile-reference.yml@refs/heads/main"

# st_record FILE [KEY=VALUE...]  ->  a valid hosted gate record with overrides.
st_record() {
    _str_file=$1
    shift
    {
        sc_record_line schema "$SC_RECORD_SCHEMA"
        sc_record_line metric "$SC_METRIC"
        sc_record_line ir_count 116113939859
        sc_record_line commit "$ST_SHA_A"
        sc_record_line tree "$ST_TREE_1"
        sc_record_line role gate
        sc_record_line argv "/home/runner/work/typelisp/typelisp/target/bootstrap-fixpoint/stage3 compile src/main.tl -o target/instruction-count-check/measure/bin/self-compile.opt1.s --target linux-x86_64 --stdlib-root stdlib --stdlib-root src --opt-level 1"
        sc_record_line argv_normalized "<compiler> compile src/main.tl -o target/instruction-count-check/measure/bin/self-compile.opt1.s --target linux-x86_64 --stdlib-root stdlib --stdlib-root src --opt-level 1"
        sc_record_line cwd /home/runner/work/typelisp/typelisp
        sc_record_line env LC_ALL=C
        sc_record_line procedure 9999999999999999999999999999999999999999999999999999999999999999
        sc_record_line compiler_sha256 7777777777777777777777777777777777777777777777777777777777777777
        sc_record_line compiler_commit "$ST_SHA_A"
        sc_record_line key.image_os ubuntu24
        sc_record_line key.kernel 6.11.0-1018-azure
        sc_record_line key.valgrind valgrind-3.22.0
        sc_record_line key.as "GNU assembler (GNU Binutils for Ubuntu) 2.42"
        sc_record_line key.ld "GNU ld (GNU Binutils for Ubuntu) 2.42"
        sc_record_line key.workspace /home/runner/work/typelisp/typelisp
        sc_record_line key.arch X64
        sc_record_line info.image_version 20261012.334.1
        sc_record_line info.cpu "AMD EPYC 7763 64-Core Processor"
        sc_record_line authority hosted
        sc_record_line run.repository "$ST_REPO"
        sc_record_line run.id 100
        sc_record_line run.attempt 1
        sc_record_line run.workflow_ref "$ST_REF_WORKFLOW_REF"
        sc_record_line run.event push
        sc_record_line run.job measure
        sc_record_line run.sha "$ST_SHA_A"
    } > "$_str_file.base"
    for _str_kv in "$@"; do
        _str_k=${_str_kv%%=*}
        _str_v=${_str_kv#*=}
        awk -F '\t' -v k="$_str_k" -v v="$_str_v" '
            BEGIN { OFS = "\t" }
            $1 == k { if (v != "<delete>") print k, v; done = 1; next }
            { print }
            END { if (!done && v != "<delete>") print k, v }
        ' "$_str_file.base" > "$_str_file.next"
        mv "$_str_file.next" "$_str_file.base"
    done
    # The compiler stamp follows the record's commit unless overridden.
    case " $* " in
        *" compiler_commit="*) ;;
        *)
            _str_commit=$(sc_record_get "$_str_file.base" commit)
            awk -F '\t' -v c="$_str_commit" 'BEGIN { OFS = "\t" } $1 == "compiler_commit" { $2 = c } { print }' \
                "$_str_file.base" > "$_str_file.next"
            mv "$_str_file.next" "$_str_file.base"
            ;;
    esac
    mv "$_str_file.base" "$_str_file"
}

st_arithmetic() {
    st_eq "bn mul" "$(sc_bn mul 116113939859 1000000)" 116113939859000000
    st_eq "bn add signs" "$(sc_bn add -5 3)" -2
    st_eq "bn sub" "$(sc_bn sub 116113939859 116113939625)" 234
    st_eq "bn negative product" "$(sc_bn mul -12 12)" -144
    # 5000 ppm of 116113939859 is 580569699.295 Ir.
    st_eq "window +edge in" "$(sc_window 580569699 116113939859 0 5000)" in
    st_eq "window +edge out" "$(sc_window 580569700 116113939859 0 5000)" out
    st_eq "window -edge in" "$(sc_window -580569699 116113939859 0 5000)" in
    st_eq "window -edge out" "$(sc_window -580569700 116113939859 0 5000)" out
    st_eq "window exact boundary" "$(sc_window 5000 1000000 0 5000)" in
    st_eq "window one past" "$(sc_window 5001 1000000 0 5000)" out
    st_eq "declared decimal in" "$(sc_window 642000 1000000 637000.5 5000)" in
    st_eq "declared decimal out" "$(sc_window 642001 1000000 637000.5 5000)" out
    st_eq "declared negative in" "$(sc_window -12000 1000000 -7000 5000)" in
    st_eq "declared malformed" "$(sc_window 1 1000000 1e3 5000 2>/dev/null || true)" malformed
    st_eq "ppm exceeds" "$(sc_ppm_exceeds 1001 1000000 1000)" yes
    st_eq "ppm at bound" "$(sc_ppm_exceeds -1000 1000000 1000)" no
    st_eq "abs exceeds" "$(sc_abs_exceeds -10001 10000)" yes
    st_eq "abs at bound" "$(sc_abs_exceeds 10000 10000)" no
    st_eq "decimal cmp" "$(sc_decimal_cmp 5000.0001 5000)" 1
    st_eq "decimal cmp equal" "$(sc_decimal_cmp -5000 -5000.000)" 0
}

st_records() {
    _d=$1
    st_record "$_d/r.tsv"
    st_succeeds "valid record" sc_record_validate "$_d/r.tsv" gate
    st_fails "role mismatch" sc_record_validate "$_d/r.tsv" base-fallback
    st_record "$_d/r-nokernel.tsv" key.kernel='<delete>'
    st_fails "missing key" sc_record_validate "$_d/r-nokernel.tsv"
    st_record "$_d/r-schema.tsv" schema=typelisp-self-compile-record/0
    st_fails "old schema" sc_record_validate "$_d/r-schema.tsv"
    st_record "$_d/r-ir.tsv" ir_count=12x
    st_fails "malformed count" sc_record_validate "$_d/r-ir.tsv"
    st_record "$_d/r-commit.tsv" commit=abc
    st_fails "malformed commit" sc_record_validate "$_d/r-commit.tsv"
    st_record "$_d/r-metric.tsv" metric=self_compile/compile_cli_opt2
    st_fails "other metric" sc_record_validate "$_d/r-metric.tsv"

    st_record "$_d/same.tsv" commit="$ST_SHA_B" ir_count=1
    st_succeeds "comparable identity" sc_records_comparable "$_d/r.tsv" "$_d/same.tsv"
    for _k in $SC_COMPARABLE_KEYS; do
        st_record "$_d/diff.tsv" "$_k=changed"
        st_fails "cross-environment $_k" sc_records_comparable "$_d/r.tsv" "$_d/diff.tsv"
    done
    st_record "$_d/local.tsv" authority=local
    st_fails "local never compares with hosted" sc_records_comparable "$_d/r.tsv" "$_d/local.tsv"
    st_record "$_d/u1.tsv" key.image_os=unknown
    st_record "$_d/u2.tsv" key.image_os=unknown
    st_fails "unknown identity never compares" sc_records_comparable "$_d/u1.tsv" "$_d/u2.tsv"
    st_record "$_d/stamp.tsv" compiler_commit="$ST_SHA_B"
    st_fails "compiler stamped with another commit" sc_record_validate "$_d/stamp.tsv"
    st_record "$_d/same-tree.tsv" commit="$ST_SHA_B" compiler_commit="$ST_SHA_B" compiler_sha256=6666666666666666666666666666666666666666666666666666666666666666
    st_eq "one tree, two commits" "$(sc_records_same_compiler "$_d/r.tsv" "$_d/same-tree.tsv")" commit-stamped
    st_record "$_d/same-commit.tsv" ir_count=1
    st_eq "one commit, same compiler" "$(sc_records_same_compiler "$_d/r.tsv" "$_d/same-commit.tsv")" identical
    st_record "$_d/other-code.tsv" compiler_sha256=6666666666666666666666666666666666666666666666666666666666666666
    st_fails "one commit, different compilers" sc_records_same_compiler "$_d/r.tsv" "$_d/other-code.tsv"
    st_record "$_d/other-tree.tsv" tree="$ST_TREE_2"
    st_fails "different trees" sc_records_same_compiler "$_d/r.tsv" "$_d/other-tree.tsv"
}

st_gate() {
    _d=$1
    st_record "$_d/base.tsv" ir_count=116113939859
    _st_gate() {
        st_record "$_d/head.tsv" ir_count="$1"
        sc_gate_decide "$_d/head.tsv" "$_d/base.tsv" "$2" > "$_d/gate.tsv"
        printf '%s %s %s' "$(sc_record_get "$_d/gate.tsv" status)" \
            "$(sc_record_get "$_d/gate.tsv" routing)" \
            "$(sc_record_get "$_d/gate.tsv" within_runner_variation_bound)"
    }
    st_eq "own zero" "$(_st_gate 116113939859 none)" "ok routine yes"
    st_eq "own +1000 is the variation bound" "$(_st_gate 116113940859 none)" "ok routine yes"
    st_eq "own +1001" "$(_st_gate 116113940860 none)" "ok routine no"
    st_eq "own at +edge" "$(_st_gate 116694509558 none)" "ok routine no"
    st_eq "own past +edge" "$(_st_gate 116694509559 none)" "REGRESSION non-routine no"
    st_eq "own past -edge" "$(_st_gate 115533370159 none)" "IMPROVEMENT explain-improvement no"
    st_eq "own at -edge" "$(_st_gate 115533370160 none)" "ok routine no"
    # +63.7% declared as 637000 ppm: center 116113939859 * 1.637 = 190078519549.183
    st_eq "declared large cost" "$(_st_gate 190078519549 637000)" "declared-ok non-routine no"
    st_eq "declared mismatch" "$(_st_gate 190078519549 600000)" "DECLARATION-MISMATCH non-routine no"
    st_eq "declared improvement" "$(_st_gate 108113939859 -68900)" "declared-ok explain-improvement no"
    st_eq "small declaration" "$(_st_gate 116113939859 100)" "declared-ok routine yes"
    # The declared window's own boundary, at exact counts: base 1e6, declared
    # 1000 ppm, so own 6000 Ir is exactly 5000 ppm from the declaration.
    st_record "$_d/base.tsv" ir_count=1000000
    st_eq "declared window edge" "$(_st_gate 1006000 1000)" "declared-ok non-routine no"
    st_eq "declared window past the edge" "$(_st_gate 1006001 1000)" "DECLARATION-MISMATCH non-routine no"
    st_eq "declared window lower edge" "$(_st_gate 996000 1000)" "declared-ok routine no"
    st_eq "declared window past the lower edge" "$(_st_gate 995999 1000)" "DECLARATION-MISMATCH routine no"
}

st_declarations() {
    _d=$1
    printf 'self_compile/compile_cli_opt1\t+637000.25\townership checking (#8449)\n' > "$_d/ok.tsv"
    st_eq "declaration parse" "$(sc_declaration_parse "$_d/ok.tsv")" +637000.25
    printf 'self_compile/compile_cli_opt1\t-12\treason\r\n' > "$_d/crlf.tsv"
    st_eq "declaration crlf" "$(sc_declaration_parse "$_d/crlf.tsv")" -12
    printf 'self_compile/compile_cli_opt1\t1\ta\nself_compile/compile_cli_opt1\t2\tb\n' > "$_d/two.tsv"
    st_fails "two declarations" sc_declaration_parse "$_d/two.tsv"
    for _v in 1e3 nan inf +-5 5. .5 0x10 ''; do
        printf 'self_compile/compile_cli_opt1\t%s\treason\n' "$_v" > "$_d/bad.tsv"
        st_fails "malformed ppm '$_v'" sc_declaration_parse "$_d/bad.tsv"
    done
    printf 'self_compile/compile_cli_opt1\t5\t   \n' > "$_d/noreason.tsv"
    st_fails "empty reason" sc_declaration_parse "$_d/noreason.tsv"
    printf 'self_compile/compile_cli_opt1\t5\n' > "$_d/twofields.tsv"
    st_fails "missing reason" sc_declaration_parse "$_d/twofields.tsv"
    printf 'self_compile/compile_cli_opt2\t5\treason\n' > "$_d/metric.tsv"
    st_fails "other metric" sc_declaration_parse "$_d/metric.tsv"
    : > "$_d/empty.tsv"
    st_fails "empty declaration" sc_declaration_parse "$_d/empty.tsv"

    _dir=$SC_DECLARATION_DIR
    : > "$_d/none.diff"
    st_succeeds "no declaration change" sc_declaration_diff_check 42 "$_d/none.diff" no
    printf 'A\t%s/pr-42.tsv\n' "$_dir" > "$_d/own.diff"
    st_succeeds "own new declaration" sc_declaration_diff_check 42 "$_d/own.diff" no
    st_fails "own declaration already in B" sc_declaration_diff_check 42 "$_d/own.diff" yes
    printf 'A\t%s/pr-43.tsv\n' "$_dir" > "$_d/squat.diff"
    st_fails "squatting another PR's declaration" sc_declaration_diff_check 42 "$_d/squat.diff" no
    printf 'M\t%s/pr-7.tsv\n' "$_dir" > "$_d/mutate.diff"
    st_fails "mutating a merged declaration" sc_declaration_diff_check 42 "$_d/mutate.diff" no
    printf 'D\t%s/pr-7.tsv\n' "$_dir" > "$_d/delete.diff"
    st_fails "deleting a merged declaration" sc_declaration_diff_check 42 "$_d/delete.diff" no
    printf 'R100\t%s/pr-7.tsv\t%s/pr-42.tsv\n' "$_dir" "$_dir" > "$_d/rename.diff"
    st_fails "renaming a merged declaration onto this PR" sc_declaration_diff_check 42 "$_d/rename.diff" no
}

st_runs_json() {
    cat <<EOF
{"workflow_runs": [
 {"id": 900, "run_number": 90, "run_attempt": 1, "event": "pull_request", "head_branch": "t3/x", "head_sha": "$ST_SHA_B", "path": ".github/workflows/self-compile-reference.yml", "status": "completed", "conclusion": "success", "repository": {"full_name": "$ST_REPO"}, "head_repository": {"full_name": "$ST_REPO"}},
 {"id": 901, "run_number": 91, "run_attempt": 1, "event": "push", "head_branch": "feature", "head_sha": "$ST_SHA_B", "path": ".github/workflows/self-compile-reference.yml", "status": "completed", "conclusion": "success", "repository": {"full_name": "$ST_REPO"}, "head_repository": {"full_name": "$ST_REPO"}},
 {"id": 902, "run_number": 92, "run_attempt": 1, "event": "push", "head_branch": "main", "head_sha": "$ST_SHA_B", "path": ".github/workflows/ci.yml", "status": "completed", "conclusion": "success", "repository": {"full_name": "$ST_REPO"}, "head_repository": {"full_name": "$ST_REPO"}},
 {"id": 903, "run_number": 93, "run_attempt": 1, "event": "push", "head_branch": "main", "head_sha": "$ST_SHA_B", "path": ".github/workflows/self-compile-reference.yml", "status": "completed", "conclusion": "success", "repository": {"full_name": "$ST_REPO"}, "head_repository": {"full_name": "someone/typelisp"}},
 {"id": 904, "run_number": 94, "run_attempt": 1, "event": "push", "head_branch": "main", "head_sha": "$ST_SHA_C", "path": ".github/workflows/self-compile-reference.yml", "status": "completed", "conclusion": "success", "repository": {"full_name": "$ST_REPO"}, "head_repository": {"full_name": "$ST_REPO"}},
 {"id": 800, "run_number": 80, "run_attempt": 2, "event": "push", "head_branch": "main", "head_sha": "$ST_SHA_B", "path": ".github/workflows/self-compile-reference.yml", "status": "completed", "conclusion": "failure", "repository": {"full_name": "$ST_REPO"}, "head_repository": {"full_name": "$ST_REPO"}},
 {"id": 850, "run_number": 85, "run_attempt": 1, "event": "push", "head_branch": "main", "head_sha": "$ST_SHA_B", "path": ".github/workflows/self-compile-reference.yml", "status": "completed", "conclusion": "success", "repository": {"full_name": "$ST_REPO"}, "head_repository": {"full_name": "$ST_REPO"}}
]}
EOF
}

st_jobs_json() {
    # st_jobs_json NAME ATTEMPT STATUS CONCLUSION [ATTEMPT STATUS CONCLUSION...]
    _stj_name=$1
    shift
    printf '{"jobs": ['
    _stj_sep=
    while [ "$#" -ge 3 ]; do
        printf '%s{"name": "%s", "run_attempt": %s, "status": "%s", "conclusion": %s}' \
            "$_stj_sep" "$_stj_name" "$1" "$2" "$( [ -n "$3" ] && printf '"%s"' "$3" || printf null)"
        _stj_sep=,
        shift 3
    done
    printf '{"name": "other", "run_attempt": 1, "status": "completed", "conclusion": "success"}' |
        sed "s/^/${_stj_sep:-}/"
    printf ']}\n'
}

st_selection() {
    _d=$1
    st_runs_json > "$_d/runs.json"
    st_eq "newest valid push-to-main run" "$(sc_select_reference_run "$_d/runs.json" "$ST_REPO" "$ST_SHA_B")" \
        "$(printf '850\t1\tcompleted\tsuccess')"
    printf '{"workflow_runs": []}\n' > "$_d/empty.json"
    st_eq "no run" "$(sc_select_reference_run "$_d/empty.json" "$ST_REPO" "$ST_SHA_B")" ""
    st_jobs_json "$SC_REFERENCE_JOB_NAME" 1 completed success 2 completed failure > "$_d/jobs.json"
    st_eq "latest job attempt" "$(sc_job_latest "$_d/jobs.json" "$SC_REFERENCE_JOB_NAME")" "$(printf '2\tcompleted\tfailure')"
    st_jobs_json "$SC_REFERENCE_JOB_NAME" 1 completed success > "$_d/partial.json"
    st_eq "partial re-run keeps the producing attempt" "$(sc_job_latest "$_d/partial.json" "$SC_REFERENCE_JOB_NAME")" \
        "$(printf '1\tcompleted\tsuccess')"

    st_record "$_d/head.tsv" commit="$ST_SHA_D" run.event=pull_request run.workflow_ref="$ST_REPO/.github/workflows/ci.yml@refs/pull/9/merge"
    st_record "$_d/ref.tsv" commit="$ST_SHA_B" run.id=850 run.attempt=1
    _st_check() {
        sc_reference_record_check "$_d/$1" "$_d/head.tsv" "$ST_REPO" 850 1 "$ST_SHA_B" gate
    }
    st_succeeds "verified reference" _st_check ref.tsv
    st_record "$_d/x.tsv" commit="$ST_SHA_C" run.id=850 run.attempt=1
    st_fails "reference for another commit" _st_check x.tsv
    st_record "$_d/x.tsv" commit="$ST_SHA_B" run.id=851 run.attempt=1
    st_fails "reference from another run" _st_check x.tsv
    st_record "$_d/x.tsv" commit="$ST_SHA_B" run.id=850 run.attempt=2
    st_fails "mismatched run attempt" _st_check x.tsv
    st_record "$_d/x.tsv" commit="$ST_SHA_B" run.id=850 run.attempt=1 run.event=pull_request
    st_fails "dry-run record" _st_check x.tsv
    st_record "$_d/x.tsv" commit="$ST_SHA_B" run.id=850 run.attempt=1 run.workflow_ref="$ST_REPO/.github/workflows/ci.yml@refs/heads/main"
    st_fails "record from another workflow" _st_check x.tsv
    st_record "$_d/x.tsv" commit="$ST_SHA_B" run.id=850 run.attempt=1 run.repository=someone/typelisp
    st_fails "record from a fork" _st_check x.tsv
    st_record "$_d/x.tsv" commit="$ST_SHA_B" run.id=850 run.attempt=1 authority=local
    st_fails "local record" _st_check x.tsv
    st_record "$_d/x.tsv" commit="$ST_SHA_B" run.id=850 run.attempt=1 key.kernel=6.8.0-1036-azure
    st_fails "reference from another kernel" _st_check x.tsv
    st_record "$_d/x.tsv" commit="$ST_SHA_B" run.id=850 run.attempt=1 procedure=5555555555555555555555555555555555555555555555555555555555555555
    st_fails "reference measured by another procedure" _st_check x.tsv
    st_record "$_d/x.tsv" commit="$ST_SHA_B" run.id=850 run.attempt=1 role=base-fallback
    st_fails "fallback record offered as a reference" _st_check x.tsv
}

# Fixture API: endpoints map to files under $ST_API; a missing file is an
# API error. Artifacts are directories under $ST_ART/<run>/<name>.
st_api_file() {
    printf '%s' "$1" | tr '/?&=' '____'
}

st_resolve() {
    _d=$1
    ST_API=$_d/api
    ST_ART=$_d/art
    mkdir -p "$ST_API" "$ST_ART"
    sc_api() {
        _f="$ST_API/$(st_api_file "$1")"
        [ -f "$_f" ] || return 1
        cat "$_f"
    }
    sc_download_artifact() {
        [ -d "$ST_ART/$1/$2" ] || return 1
        mkdir -p "$3"
        cp "$ST_ART/$1/$2/"* "$3/"
    }
    sc_commit_tree() {
        printf '%s\n' "$ST_TREE_1"
    }
    GITHUB_REPOSITORY=$ST_REPO
    _runs="repos/$ST_REPO/actions/workflows/self-compile-reference.yml/runs?event=push&branch=main&head_sha=$ST_SHA_B&per_page=50"
    _jobs="repos/$ST_REPO/actions/runs/850/jobs?filter=all&per_page=100"
    _arts="repos/$ST_REPO/actions/runs/850/artifacts?name=$SC_REFERENCE_ARTIFACT&per_page=100"
    st_record "$_d/head.tsv" commit="$ST_SHA_D" run.event=pull_request
    _st_n=0
    _st_scenario() {
        _st_n=$((_st_n + 1))
        sc_resolve_reference "$ST_SHA_B" "$_d/head.tsv" "$_d/out-$_st_n"
        printf '%s' "$SC_REF_STATUS"
    }
    st_eq "api error" "$(_st_scenario)" api-error
    st_runs_json > "$ST_API/$(st_api_file "$_runs")"
    st_eq "jobs api error" "$(_st_scenario)" api-error
    st_jobs_json "$SC_REFERENCE_JOB_NAME" 1 in_progress "" > "$ST_API/$(st_api_file "$_jobs")"
    st_eq "pending reference" "$(_st_scenario)" pending
    st_jobs_json "$SC_REFERENCE_JOB_NAME" 1 completed failure > "$ST_API/$(st_api_file "$_jobs")"
    printf '{"artifacts": []}\n' > "$ST_API/$(st_api_file "$_arts")"
    st_eq "failed producing job" "$(_st_scenario)" rejected
    st_jobs_json "$SC_REFERENCE_JOB_NAME" 1 completed success > "$ST_API/$(st_api_file "$_jobs")"
    st_eq "missing artifact" "$(_st_scenario)" rejected
    printf '{"artifacts": [{"name": "%s", "expired": true, "workflow_run": {"id": 850}}]}\n' \
        "$SC_REFERENCE_ARTIFACT" > "$ST_API/$(st_api_file "$_arts")"
    st_eq "expired artifact" "$(_st_scenario)" rejected
    printf '{"artifacts": [{"name": "%s", "expired": false, "workflow_run": {"id": 850}}]}\n' \
        "$SC_REFERENCE_ARTIFACT" > "$ST_API/$(st_api_file "$_arts")"
    st_eq "download failure" "$(_st_scenario)" api-error
    mkdir -p "$ST_ART/850/$SC_REFERENCE_ARTIFACT"
    st_record "$ST_ART/850/$SC_REFERENCE_ARTIFACT/record.tsv" commit="$ST_SHA_B" run.id=850 run.attempt=1
    st_eq "verified reference" "$(_st_scenario)" ok
    st_jobs_json "$SC_REFERENCE_JOB_NAME" 1 completed success 2 completed success > "$ST_API/$(st_api_file "$_jobs")"
    st_eq "artifact from an older attempt" "$(_st_scenario)" rejected
    st_jobs_json "$SC_REFERENCE_JOB_NAME" 1 completed success > "$ST_API/$(st_api_file "$_jobs")"
    st_record "$ST_ART/850/$SC_REFERENCE_ARTIFACT/record.tsv" commit="$ST_SHA_B" run.id=850 run.attempt=1 tree="$ST_TREE_2"
    st_eq "record tree is not the commit's" "$(_st_scenario)" rejected
    st_record "$ST_ART/850/$SC_REFERENCE_ARTIFACT/record.tsv" commit="$ST_SHA_B" run.id=850 run.attempt=1 key.valgrind=valgrind-3.24.0
    st_eq "separate-job environment mismatch" "$(_st_scenario)" rejected

    # PR artifact binding.
    mkdir -p "$_d/pr"
    {
        sc_record_line schema "$SC_RESULT_SCHEMA"
        sc_record_line pr 42
        sc_record_line head "$ST_SHA_E"
        sc_record_line merge "$ST_SHA_D"
        sc_record_line base "$ST_SHA_B"
        sc_record_line run.repository "$ST_REPO"
        sc_record_line run.id 700
        sc_record_line run.attempt 2
        sc_record_line run.event pull_request
    } > "$_d/pr/result.tsv"
    st_record "$_d/pr/head.tsv" commit="$ST_SHA_D" run.id=700 run.attempt=2 run.event=pull_request
    st_record "$_d/pr/base.tsv" commit="$ST_SHA_B"
    st_succeeds "PR attribution binds H, T and B" sc_pr_record_binding "$_d/pr" 42 "$ST_SHA_E" 700 2 "$ST_REPO"
    st_fails "PR record for another head" sc_pr_record_binding "$_d/pr" 42 "$ST_SHA_F" 700 2 "$ST_REPO"
    st_fails "PR record from a stale attempt" sc_pr_record_binding "$_d/pr" 42 "$ST_SHA_E" 700 3 "$ST_REPO"
    st_fails "PR record for another PR" sc_pr_record_binding "$_d/pr" 43 "$ST_SHA_E" 700 2 "$ST_REPO"
    st_record "$_d/pr/base.tsv" commit="$ST_SHA_C"
    st_fails "PR base record of another commit" sc_pr_record_binding "$_d/pr" 42 "$ST_SHA_E" 700 2 "$ST_REPO"

    unset ST_API ST_ART
}

# st_entry DIR PARENT_IR COMMIT_IR [OPTIONS]  ->  ledger entry inputs.
# Options: tc= tp= tt= tb= mt= mb= own= declared= nopr pkey= ckey= tkey= tcode=
st_entry() {
    _ste=$1
    [ ! -e "$_ste" ] || sc_fail "self-test entry directory exists: $_ste"
    mkdir -p "$_ste"
    _ste_mp=$2
    _ste_mc=$3
    shift 3
    _ste_tc=$ST_TREE_2
    _ste_tp=$ST_TREE_1
    _ste_tt=$ST_TREE_2
    _ste_tb=$ST_TREE_1
    _ste_mt=$_ste_mc
    _ste_mb=$_ste_mp
    _ste_own=
    _ste_declared=none
    _ste_pr=yes
    _ste_pkey=6.11.0-1018-azure
    _ste_ckey=6.11.0-1018-azure
    _ste_tkey=6.11.0-1018-azure
    _ste_tcode=8888888888888888888888888888888888888888888888888888888888888888
    for _ste_o in "$@"; do
        case "$_ste_o" in
            tc=*) _ste_tc=${_ste_o#tc=} ;;
            tp=*) _ste_tp=${_ste_o#tp=} ;;
            tt=*) _ste_tt=${_ste_o#tt=} ;;
            tb=*) _ste_tb=${_ste_o#tb=} ;;
            mt=*) _ste_mt=${_ste_o#mt=} ;;
            mb=*) _ste_mb=${_ste_o#mb=} ;;
            own=*) _ste_own=${_ste_o#own=} ;;
            declared=*) _ste_declared=${_ste_o#declared=} ;;
            nopr) _ste_pr=no ;;
            pkey=*) _ste_pkey=${_ste_o#pkey=} ;;
            ckey=*) _ste_ckey=${_ste_o#ckey=} ;;
            tkey=*) _ste_tkey=${_ste_o#tkey=} ;;
            tcode=*) _ste_tcode=${_ste_o#tcode=} ;;
        esac
    done
    [ -n "$_ste_own" ] || _ste_own=$(sc_bn sub "$_ste_mt" "$_ste_mb")
    printf '%s\n' "$ST_SHA_C" > "$_ste/commit"
    printf '%s\n' "$ST_SHA_B" > "$_ste/parent"
    printf '%s\n' "$_ste_tc" > "$_ste/tree.commit"
    printf '%s\n' "$_ste_tp" > "$_ste/tree.parent"
    st_record "$_ste/parent.tsv" commit="$ST_SHA_B" tree="$_ste_tp" ir_count="$_ste_mp" key.kernel="$_ste_pkey"
    st_record "$_ste/landed.tsv" commit="$ST_SHA_C" tree="$_ste_tc" ir_count="$_ste_mc" key.kernel="$_ste_ckey"
    if [ "$_ste_pr" = yes ]; then
        {
            sc_record_line schema "$SC_RESULT_SCHEMA"
            sc_record_line pr 42
            sc_record_line head "$ST_SHA_E"
            sc_record_line merge "$ST_SHA_D"
            sc_record_line base "$ST_SHA_F"
            sc_record_line own "$_ste_own"
            sc_record_line declared_ppm "$_ste_declared"
        } > "$_ste/pr.tsv"
        st_record "$_ste/pr-head.tsv" commit="$ST_SHA_D" tree="$_ste_tt" ir_count="$_ste_mt" key.kernel="$_ste_tkey" \
            compiler_sha256="$_ste_tcode" run.event=pull_request
        st_record "$_ste/pr-base.tsv" commit="$ST_SHA_F" tree="$_ste_tb" ir_count="$_ste_mb" key.kernel="$_ste_tkey" \
            role=base-fallback run.event=pull_request
        printf '%s\n%s\n' "$ST_SHA_A" "$ST_SHA_F" > "$_ste/merges-between"
    fi
}

st_entry_says() {
    sc_ledger_entry "$1" > "$1/entry.tsv"
    printf '%s %s %s' "$(sc_record_get "$1/entry.tsv" class)" "$(sc_record_get "$1/entry.tsv" outcome)" \
        "$(sc_record_get "$1/entry.tsv" failures 2>/dev/null || printf -)"
}

st_ledger() {
    _d=$1
    # M(p) = 1e11 keeps the ppm thresholds readable: 1000 ppm = 1e8 Ir.
    _P=100000000000
    st_entry "$_d/s-ok" "$_P" 100000050000 mt=100000049700
    st_eq "class S within bounds" "$(st_entry_says "$_d/s-ok")" "S ok -"
    st_eq "class S residual" "$(sc_record_get "$_d/s-ok/entry.tsv" r)" 300
    st_eq "class S direct" "$(sc_record_get "$_d/s-ok/entry.tsv" r_method)" direct
    st_entry "$_d/s-warn" "$_P" 100000050000 mt=100000048999
    st_eq "class S warning" "$(st_entry_says "$_d/s-warn")" "S warning -"
    st_entry "$_d/s-fail" "$_P" 100000050000 mt=100000039999
    st_eq "class S failure" "$(st_entry_says "$_d/s-fail")" "S numerical-failure class-s class-s-attribution"
    st_entry "$_d/s-xenv" "$_P" 100000050000 mt=100100049800 mb=100100000000 tkey=6.8.0-1036-azure
    st_eq "class S cross-environment paired delta" "$(st_entry_says "$_d/s-xenv")" "S ok -"
    st_eq "class S paired-delta method" "$(sc_record_get "$_d/s-xenv/entry.tsv" r_method)" paired-delta
    st_eq "class S paired-delta residual" "$(sc_record_get "$_d/s-xenv/entry.tsv" r)" 200
    st_entry "$_d/s-xenv-moved" "$_P" 100000050000 mt=100100049800 mb=100100000000 tkey=6.8.0-1036-azure tb="$ST_TREE_3"
    st_eq "class S cross-environment with another base" "$(st_entry_says "$_d/s-xenv-moved")" "S comparability-failure comparability"
    st_entry "$_d/s-code" "$_P" 100000050000 tcode=6666666666666666666666666666666666666666666666666666666666666666
    st_eq "class S across commit-stamped builds" "$(st_entry_says "$_d/s-code")" "S ok -"
    st_eq "class S notes the commit stamp" "$(sc_record_get "$_d/s-code/entry.tsv" r_compiler)" commit-stamped
    # Equal final trees, different parents: reproduction is class S, attribution class M.
    st_entry "$_d/s-moved" "$_P" 100000050000 mt=100000050100 tb="$ST_TREE_3" mb=99999990000
    st_eq "equal final trees, different parents" "$(st_entry_says "$_d/s-moved")" "S warning -"
    st_eq "equal final trees, different parents warns" "$(sc_record_get "$_d/s-moved/entry.tsv" warnings)" class-m
    st_eq "equal final trees attribute under M" "$(sc_record_get "$_d/s-moved/entry.tsv" a_class)" M
    st_eq "equal final trees list the B..p merges" "$(sc_record_get "$_d/s-moved/entry.tsv" merges_between)" "$ST_SHA_A $ST_SHA_F"
    st_entry "$_d/m-ok" "$_P" 100000050000 tt="$ST_TREE_3" tb="$ST_TREE_4" own=45000
    st_eq "class M within bounds" "$(st_entry_says "$_d/m-ok")" "M ok -"
    st_entry "$_d/m-warn" "$_P" 100000050000 tt="$ST_TREE_3" tb="$ST_TREE_4" own=39999
    st_eq "class M warning" "$(st_entry_says "$_d/m-warn")" "M warning -"
    st_eq "class M warning warns" "$(sc_record_get "$_d/m-warn/entry.tsv" warnings)" class-m
    st_entry "$_d/m-edge" "$_P" 100100050000 tt="$ST_TREE_3" tb="$ST_TREE_4" own=50000
    st_eq "class M at 1000 ppm" "$(st_entry_says "$_d/m-edge")" "M warning -"
    st_eq "class M at 1000 ppm warns" "$(sc_record_get "$_d/m-edge/entry.tsv" warnings)" class-m
    st_entry "$_d/m-fail" "$_P" 100100050001 tt="$ST_TREE_3" tb="$ST_TREE_4" own=50000
    st_eq "class M failure" "$(st_entry_says "$_d/m-fail")" "M numerical-failure class-m"
    st_entry "$_d/m-xenv" "$_P" 100000050000 tt="$ST_TREE_3" tb="$ST_TREE_4" own=50000 tkey=6.8.0-1036-azure
    st_eq "class M cross-environment PR report" "$(st_entry_says "$_d/m-xenv")" "M ok -"
    st_entry "$_d/pair-xenv" "$_P" 100000050000 pkey=6.8.0-1036-azure
    st_eq "incomparable pair" "$(st_entry_says "$_d/pair-xenv")" "none comparability-failure comparability"
    st_entry "$_d/window" "$_P" 100500000001 mt=100500000001 mb="$_P"
    st_eq "landed gate window breach" "$(st_entry_says "$_d/window")" "S numerical-failure landed-gate-window"
    st_eq "landed cost above +5000 ppm is non-routine" "$(sc_record_get "$_d/window/entry.tsv" routing)" non-routine
    st_entry "$_d/window-declared" "$_P" 100700000000 mt=100700000000 mb="$_P" declared=7000
    st_eq "declared landed cost within its window" "$(st_entry_says "$_d/window-declared")" "S ok -"
    st_entry "$_d/nopr" "$_P" 100000050000 nopr
    st_eq "missing attribution" "$(st_entry_says "$_d/nopr")" "none attribution-failure attribution"
}

st_account() {
    _d=$1
    sc_account_seed "$ST_SHA_D" "$ST_SHA_F" 100000000000 > "$_d/acc0.tsv"
    _st_entry_file() {
        {
            sc_record_line commit "$1"
            sc_record_line class S
            sc_record_line a_class S
            sc_record_line step "$2"
            sc_record_line own "$3"
            sc_record_line a "$(sc_bn sub "$2" "$3")"
            sc_record_line r "$4"
            sc_record_line outcome "$5"
            sc_record_line failures "$6"
            sc_record_line warnings -
            sc_record_line pair_identity "$7"
        } > "$_d/e-$1.tsv"
    }
    _st_entry_file "$ST_SHA_A" 1500 1000 500 ok - k1
    _st_entry_file "$ST_SHA_B" 1500 1000 500 ok - k1
    _st_entry_file "$ST_SHA_C" 1500 1000 500 ok - k2
    sc_account_apply "$_d/acc0.tsv" "$_d/e-$ST_SHA_A.tsv" > "$_d/acc1.tsv"
    sc_account_apply "$_d/acc1.tsv" "$_d/e-$ST_SHA_B.tsv" > "$_d/acc2.tsv"
    sc_account_apply "$_d/acc2.tsv" "$_d/e-$ST_SHA_C.tsv" > "$_d/acc3.tsv"
    st_eq "subthreshold steps accumulate" "$(sc_record_get "$_d/acc3.tsv" sum.step)" 4500
    st_eq "subthreshold reported costs accumulate" "$(sc_record_get "$_d/acc3.tsv" sum.own)" 3000
    st_eq "subthreshold A accumulates" "$(sc_record_get "$_d/acc3.tsv" sum.a)" 1500
    st_eq "subthreshold class S residuals accumulate" "$(sc_record_get "$_d/acc3.tsv" sum.r_s)" 1500
    st_eq "merge count" "$(sc_record_get "$_d/acc3.tsv" merges)" 3
    st_eq "identity segments" "$(sc_record_get "$_d/acc3.tsv" segments)" 2
    st_eq "clean account" "$(sc_account_outcome "$_d/acc3.tsv")" clean
    _st_entry_file "$ST_SHA_E" 20000 1000 19000 numerical-failure class-s k2
    sc_account_apply "$_d/acc3.tsv" "$_d/e-$ST_SHA_E.tsv" > "$_d/acc4.tsv"
    st_eq "failure is unresolved" "$(sc_account_outcome "$_d/acc4.tsv")" unresolved
    _st_entry_file "$ST_SHA_F" 100 100 0 ok - k2
    sc_account_apply "$_d/acc4.tsv" "$_d/e-$ST_SHA_F.tsv" > "$_d/acc5.tsv"
    st_eq "a later clean merge clears nothing" "$(sc_account_outcome "$_d/acc5.tsv")" unresolved
    st_eq "failures count" "$(sc_record_get "$_d/acc5.tsv" count.failures)" 1
    printf '%s\tnumerical-failure\thttps://example.invalid/diagnosis\n' "$ST_SHA_A" > "$_d/resolutions-other.tsv"
    st_eq "a resolution for another merge clears nothing" \
        "$(sc_account_resolve "$_d/acc5.tsv" "$_d/resolutions-other.tsv" > "$_d/acc6.tsv"; sc_account_outcome "$_d/acc6.tsv")" unresolved
    printf '# commit\toutcome\treference\n%s\tnumerical-failure\thttps://example.invalid/diagnosis\n' "$ST_SHA_E" > "$_d/resolutions.tsv"
    sc_account_resolve "$_d/acc5.tsv" "$_d/resolutions.tsv" > "$_d/acc7.tsv"
    st_eq "reviewed resolution" "$(sc_account_outcome "$_d/acc7.tsv")" clean
    st_eq "resolution stays on record" "$(sc_record_get "$_d/acc7.tsv" resolved | cut -d'|' -f1)" "$ST_SHA_E"
    {
        sc_record_line commit "$ST_SHA_A"
        sc_record_line outcome comparability-failure
        sc_record_line failures comparability
    } > "$_d/e-nostep.tsv"
    sc_account_apply "$_d/acc7.tsv" "$_d/e-nostep.tsv" > "$_d/acc8.tsv"
    st_eq "a merge without a comparable step is counted" "$(sc_record_get "$_d/acc8.tsv" count.missing_steps)" 1
}

st_chain() {
    _d=$1
    _st_plan() {
        printf '%b' "$1" > "$_d/walk.tsv"
        sc_chain_plan "$_d/walk.tsv" | tr '\t\n' ' |'
    }
    _c="$ST_SHA_C\tyes\tself\tpresent\tno\n"
    st_eq "anchor" "$(_st_plan "$_c$ST_SHA_B\tno\tnone\tnone\tno\n")" "base anchor $ST_SHA_B|gap $ST_SHA_C|"
    st_eq "anchor with a gap" "$(_st_plan "$_c$ST_SHA_A\tyes\tnone\tpresent\tno\n$ST_SHA_B\tno\tnone\tnone\tno\n")" \
        "base anchor $ST_SHA_B|gap $ST_SHA_A|gap $ST_SHA_C|"
    st_eq "parent account" "$(_st_plan "$_c$ST_SHA_B\tyes\tcomplete\tpresent\tno\n")" "base account $ST_SHA_B|gap $ST_SHA_C|"
    st_eq "bridged gap" "$(_st_plan "$_c$ST_SHA_A\tyes\tnone\tpresent\tno\n$ST_SHA_B\tyes\tcomplete\tpresent\tno\n")" \
        "base account $ST_SHA_B|gap $ST_SHA_A|gap $ST_SHA_C|"
    st_eq "continuity gap" "$(_st_plan "$_c$ST_SHA_A\tyes\tnone\tmissing\tno\n$ST_SHA_B\tyes\tcomplete\tpresent\tno\n")" \
        "outcome continuity-failure $ST_SHA_A has no ledger entry|"
    st_eq "pending predecessor" "$(_st_plan "$_c$ST_SHA_A\tyes\tnone\tpending\tno\n$ST_SHA_B\tyes\tcomplete\tpresent\tno\n")" \
        "outcome pending $ST_SHA_A ledger entry is pending|"
    st_eq "expired chain without a checkpoint" "$(_st_plan "$_c$ST_SHA_A\tyes\tnone\tpresent\tno\n$ST_SHA_B\tyes\tnone\tmissing\tno\n")" \
        "outcome continuity-failure $ST_SHA_B has no ledger entry|"
    st_eq "checkpoint recovery past retention" "$(_st_plan "$_c$ST_SHA_A\tyes\tnone\tpresent\tno\n$ST_SHA_B\tyes\tnone\tmissing\tyes\n")" \
        "base checkpoint $ST_SHA_B|gap $ST_SHA_A|gap $ST_SHA_C|"
    st_eq "no base within the walk" "$(_st_plan "$_c$ST_SHA_A\tyes\tnone\tpresent\tno\n")" \
        "outcome continuity-failure no account, checkpoint or anchor within 2 commits|"
}

sc_self_test() {
    [ -f "$ROOT/scripts/self-compile.sh" ] || sc_fail "self-test root is not the repository: $ROOT"
    command -v jq >/dev/null 2>&1 || sc_fail "the self-test requires jq (scripts/ci-host-tools.tsv)"
    _st_root="${ROOT:?}/target/self-compile-self-test"
    rm -rf -- "${_st_root:?}"
    for _st_part in arithmetic records gate declarations selection resolve ledger account chain; do
        mkdir -p "$_st_root/$_st_part"
        "st_$_st_part" "$_st_root/$_st_part"
    done
    if [ "$st_failures" -ne 0 ]; then
        echo "[self-compile self-test] $st_failures of $st_count checks failed" >&2
        exit 1
    fi
    echo "[self-compile self-test] all $st_count checks passed"
}
