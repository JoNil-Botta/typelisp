#!/usr/bin/env sh
# Job-owned C comparison records. Sourced by the existing instruction harness
# and checker; no measurements or baseline updates happen in this library.

c_provenance_hash() {
    if [ -f "$1" ]; then sha256sum "$1" | cut -c1-64; else echo unknown; fi
}

c_provenance_tool() {
    _cpt_path=$(command -v "$1")
    _cpt_path=$(realpath "$_cpt_path")
    jq -n --arg path "$_cpt_path" --arg sha256 "$(c_provenance_hash "$_cpt_path")" \
        --arg version "$("$1" --version 2>/dev/null)" \
        '{path:$path,sha256:$sha256,version:$version}'
}

c_provenance_init() {
    C_PROVENANCE="$WORKDIR/c-provenance.json"
    jq -n --argjson compiler "$(c_provenance_tool clang)" \
        --arg target "$(clang -dumpmachine)" \
        --argjson valgrind "$(c_provenance_tool valgrind)" \
        --argjson linker "$(c_provenance_tool ld)" \
        --arg libc "$(getconf GNU_LIBC_VERSION 2>/dev/null || echo unknown)" \
        --arg arch "$(uname -m)" --arg kernel "$(uname -r)" \
        --arg os_release "$(cat /etc/os-release 2>/dev/null || echo unknown)" \
        --arg wrapper "$(c_provenance_hash "$C_REGION_WRAPPER")" \
        --arg cwd "$ROOT" --arg image_os "${ImageOS:-unknown}" \
        --arg image_version "${ImageVersion:-unknown}" \
        --arg repository "${GITHUB_REPOSITORY:-local}" \
        --arg run_id "${GITHUB_RUN_ID:-local}" \
        --arg attempt "${GITHUB_RUN_ATTEMPT:-local}" \
        --arg workflow "${GITHUB_WORKFLOW_REF:-local}" \
        --arg job "${GITHUB_JOB:-local}" \
        --arg commit "$(git rev-parse HEAD)" \
        '{schema:1,status:"measured",complete:false,
          origin:{repository:$repository,run_id:$run_id,attempt:$attempt,
                  workflow:$workflow,job:$job,commit:$commit},
          environment:{compiler:($compiler + {target:$target}),
            valgrind:$valgrind,linker:$linker,libc_version:$libc,
            arch:$arch,os_release:$os_release,wrapper_sha256:$wrapper,cwd:$cwd,
            cachegrind_argv:["--quiet","--tool=cachegrind","--instr-at-start=no",
                             "--vex-guest-chase=no"],runtime_env:["LC_ALL=C"]},
          info:{kernel:$kernel,image_os:$image_os,image_version:$image_version},
          rows:{}}' > "$C_PROVENANCE"
}

# Capture argv as JSON arrays before shell globals used by measurement change.
c_provenance_build() {
    jq -n --args '$ARGS.positional' -- "$@" > "$WORKDIR/c-build-argv.json"
}

c_provenance_row() {
    _cpr_metric=$1
    _cpr_name=$2
    _cpr_bin=$3
    _cpr_source=$4
    _cpr_metadata=$5
    shift 5
    # Hash file arguments as well as their names (the compiler-derived corpus
    # is supplied as a runtime argument, rather than included in baseline.c).
    _cpr_inputs='{}'
    for _cpr_arg in "$@"; do
        [ -f "$_cpr_arg" ] || continue
        _cpr_inputs=$(printf '%s\n' "$_cpr_inputs" | jq --arg path "$_cpr_arg" \
            --arg hash "$(c_provenance_hash "$_cpr_arg")" '.[$path] = $hash')
    done
    _cpr_libc=$(ldd "$_cpr_bin" 2>/dev/null | awk '$1 == "libc.so.6" && $2 == "=>" {print $3; exit}')
    [ -n "$_cpr_libc" ] || _cpr_libc=unknown
    jq -n --slurpfile record "$C_PROVENANCE" --arg metric "$_cpr_metric/$_cpr_name" \
        --arg source "$(c_provenance_hash "$_cpr_source")" \
        --arg metadata "$(if [ -f "$_cpr_metadata" ]; then c_provenance_hash "$_cpr_metadata"; else echo absent; fi)" \
        --arg binary "$(c_provenance_hash "$_cpr_bin")" \
        --arg libc_path "$_cpr_libc" --arg libc_sha256 "$(c_provenance_hash "$_cpr_libc")" \
        --argjson ir "$first" --slurpfile build "$WORKDIR/c-build-argv.json" \
        --argjson inputs "$_cpr_inputs" \
        --args '$record[0] | .rows[$metric] = {ir_count:$ir,source_sha256:$source,
          metadata_sha256:$metadata,binary_sha256:$binary,
          libc:{path:$libc_path,sha256:$libc_sha256},
          inputs:$inputs,build_argv:$build[0],run_argv:$ARGS.positional}' \
        -- "$_cpr_bin" "$@" > "$C_PROVENANCE.tmp"
    mv "$C_PROVENANCE.tmp" "$C_PROVENANCE"
}

c_provenance_complete() {
    jq '.complete = true' "$C_PROVENANCE" > "$C_PROVENANCE.tmp"
    mv "$C_PROVENANCE.tmp" "$C_PROVENANCE"
    c_provenance_validate "$C_PROVENANCE" measured
}

# Unknown historical producer identity is explicit, never filled from this host.
# Validation prevents partial/malformed records from being mistaken for a
# comparable environment. Unknown fields use the literal string "unknown".
c_provenance_validate() {
    [ -f "$1" ] || { echo "[c-provenance] missing record: $1" >&2; return 1; }
    jq -e -s --arg role "${2:-baseline}" '
      def text: type == "string" and length > 0;
      def hash: text and (. == "unknown" or test("^[0-9a-f]{64}$"));
      def argv: type == "array" and length > 0 and all(.[]; type == "string");
      def tool: type == "object" and (.path|text) and (.sha256|hash) and (.version|text);
      length == 1 and (.[0] | .schema == 1 and
      if .status == "unknown" then
        $role != "measured" and (keys == ["reason","schema","status"]) and (.reason|text)
      else
        .status == "measured" and .complete == true and
        (.origin | type == "object" and all(.repository,.run_id,.attempt,.workflow,.job,.commit; text)) and
        (.environment | type == "object" and
          (.compiler|tool) and (.compiler.target|text) and
          (.valgrind|tool) and (.linker|tool) and
          all(.libc_version,.arch,.os_release,.cwd; text) and
          (.wrapper_sha256|hash) and (.cachegrind_argv|argv) and (.runtime_env|argv)) and
        (.info|type == "object") and
        (.rows | type == "object" and length > 0 and all(to_entries[];
          . as $row |
          (.key|test("^benchmark/(c|c-scalar)/[A-Za-z0-9_.-]+$")) and
          (.value | (.ir_count|type == "number" and . > 0 and floor == .) and
            all(.source_sha256,.binary_sha256; hash) and
            (.metadata_sha256 | hash or . == "absent") and
            (.libc.path|text) and (.libc.sha256|hash) and
            (.inputs|type == "object" and all(.[]; hash)) and
            (.build_argv|argv) and (.run_argv|argv) and
            ((.build_argv|index("-fno-vectorize") != null) == ($row.key|startswith("benchmark/c-scalar/"))) and
            ((.build_argv|index("-fno-slp-vectorize") != null) == ($row.key|startswith("benchmark/c-scalar/"))))))
      end)' "$1" >/dev/null 2>&1 || {
        echo "[c-provenance] malformed or incomplete schema-1 record: $1" >&2
        return 1
    }
}

# Diagnostic only: the caller always retains the exact numerical verdict.
# Compare only affected C rows, so a TypeLisp change is never explained away.
c_provenance_diagnose() {
    _cpd_baseline=$1
    _cpd_current=$2
    _cpd_counts=$3
    _cpd_diff=$4
    c_provenance_validate "$_cpd_current" measured || return 1
    if c_provenance_validate "$_cpd_baseline"; then
        set -- --slurpfile baseline "$_cpd_baseline"
    else
        set -- --argjson baseline '[{"schema":1,"status":"unknown","reason":"missing or malformed baseline producer record"}]'
    fi
    jq -nr "$@" --slurpfile now "$_cpd_current" \
        --rawfile counts "$_cpd_counts" --rawfile diff "$_cpd_diff" '
      $baseline[0] as $b |
      $now[0] as $n |
      ($counts | split("\n") | map(split("\t")) |
         map(select(length == 2 and (.[0]|test("^benchmark/c(-scalar)?/")))) |
         map({key:.[0],value:(.[1]|tonumber)}) | from_entries) as $counts |
      $diff | split("\n")[] | split(" | ") |
      select(length == 6 and (.[0]|test("^benchmark/c(-scalar)?/")) and .[5] != "ok") |
      .[0] as $metric |
      "[c-provenance] affected row: \($metric)",
      "[c-provenance] recorded: \({status:$b.status,reason:$b.reason,environment:$b.environment,row:$b.rows[$metric]}|tojson)",
      "[c-provenance] measured: \({environment:$n.environment,row:$n.rows[$metric]}|tojson)",
      if $b.status == "unknown" or $b.rows[$metric] == null then
        "[c-provenance] unknown baseline environment: \($b.reason // "row has no producer record")"
      elif $b.rows[$metric].ir_count != $counts[$metric] then
        "[c-provenance] unknown baseline environment: recorded count does not bind this baseline row"
      elif $n.rows[$metric] == null then
        "[c-provenance] unknown measured environment: row has no producer record"
      else
        ({environment:$b.environment,row:($b.rows[$metric]|del(.ir_count))}) as $bi |
        ({environment:$n.environment,row:($n.rows[$metric]|del(.ir_count))}) as $ni |
        if ([$bi,$ni] | any(..; . == "unknown")) then
          "[c-provenance] unknown comparison environment: required identity is unavailable"
        elif $bi != $ni then
          "[c-provenance] incompatible C comparison environment (toolchain, commands or workload differ)"
        else
          "[c-provenance] same recorded C comparison identity; investigate the count change"
        end
      end,
      "[c-provenance] exact gate still FAILS; reproduce the recorded tools before considering a reviewed C change"
    '
}

# Host-independent mutations exercise the production validator/diagnostic.
# The surrounding comparison self-test also asserts nonzero exact-count
# verdicts in both directions; these diagnostics cannot change that verdict.
c_provenance_self_test() (
    _cpst_dir=$1
    _cpst_hash=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    jq -n --arg h "$_cpst_hash" '
      {path:"/tool",sha256:$h,version:"test version"} as $tool |
      {ir_count:10,source_sha256:$h,metadata_sha256:$h,binary_sha256:$h,
       libc:{path:"/libc",sha256:$h},inputs:{},
       build_argv:["clang","-O2","baseline.c","wrapper.c","-o","bin"],
       run_argv:["bin"]} as $row |
      {schema:1,status:"measured",complete:true,
       origin:{repository:"test/repo",run_id:"1",attempt:"1",workflow:"ci",job:"ci",commit:$h},
       environment:{compiler:($tool+{target:"x86_64-linux-gnu"}),
         valgrind:$tool,linker:$tool,libc_version:"glibc test",arch:"x86_64",
         os_release:"test",wrapper_sha256:$h,cwd:"/workspace",
         cachegrind_argv:["--tool=cachegrind"],runtime_env:["LC_ALL=C"]},info:{},
       rows:{"benchmark/c/a":$row,"benchmark/c-scalar/a":($row |
         .build_argv += ["-fno-vectorize","-fno-slp-vectorize"])}}' > "$_cpst_dir/producer.json"
    printf 'benchmark/c/a\t10\nbenchmark/c-scalar/a\t10\n' > "$_cpst_dir/c-counts.tsv"
    printf 'benchmark/c/a | 10 | 11 | +1 | +10%% | REGRESSION\nbenchmark/c-scalar/a | 10 | 9 | -1 | -10%% | IMPROVEMENT\n' > "$_cpst_dir/c-diff.txt"
    c_provenance_validate "$_cpst_dir/producer.json" || return 1
    _cpst_base="$_cpst_dir/producer.json"
    _cpst_current="$_cpst_dir/current.json"
    for _cpst_mutation in same compiler flags source input wrapper libc mode scalar-mode missing-field missing-row incomplete schema unavailable; do
        _cpst_want='incompatible C comparison environment'
        _cpst_valid=1
        case "$_cpst_mutation" in
            same) _cpst_filter='.'; _cpst_want='same recorded C comparison identity' ;;
            compiler) _cpst_filter='.environment.compiler.version = "changed"' ;;
            flags) _cpst_filter='.rows["benchmark/c/a"].build_argv += ["-g"]' ;;
            source) _cpst_filter='.rows["benchmark/c/a"].source_sha256 = ("b" * 64)' ;;
            input) _cpst_filter='.rows["benchmark/c/a"].inputs["corpus"] = ("b" * 64)' ;;
            wrapper) _cpst_filter='.environment.wrapper_sha256 = ("b" * 64)' ;;
            libc) _cpst_filter='.rows["benchmark/c/a"].libc.sha256 = ("b" * 64)' ;;
            mode) _cpst_filter='.rows["benchmark/c/a"].build_argv += ["-fno-vectorize"]'; _cpst_valid=0 ;;
            scalar-mode) _cpst_filter='.rows["benchmark/c-scalar/a"].build_argv = ["clang","-O2"]'; _cpst_valid=0 ;;
            missing-field) _cpst_filter='del(.environment.compiler.sha256)'; _cpst_valid=0 ;;
            missing-row) _cpst_filter='del(.rows["benchmark/c/a"])'; _cpst_want='unknown measured environment: row has no producer record' ;;
            incomplete) _cpst_filter='.complete = false'; _cpst_valid=0 ;;
            schema) _cpst_filter='.schema = 2'; _cpst_valid=0 ;;
            unavailable) _cpst_filter='.environment.compiler.version = "unknown"'; _cpst_want='unknown comparison environment' ;;
        esac
        jq "$_cpst_filter" "$_cpst_base" > "$_cpst_current"
        if [ "$_cpst_valid" -eq 0 ]; then
            if c_provenance_validate "$_cpst_current" 2>/dev/null; then
                echo "provenance self-test accepted $_cpst_mutation" >&2; return 1
            fi
        else
            _cpst_out=$(c_provenance_diagnose "$_cpst_base" "$_cpst_current" \
                "$_cpst_dir/c-counts.tsv" "$_cpst_dir/c-diff.txt") || return 1
            case "$_cpst_out" in *"$_cpst_want"*) ;; *) echo "provenance self-test: $_cpst_mutation: $_cpst_out" >&2; return 1 ;; esac
        fi
    done
    # jq -e alone checks only the last output. A record must be exactly one
    # JSON document, including when an invalid/incomplete record comes first.
    for _cpst_first in '{}' '{"schema":2}' '{"schema":1,"complete":false}'; do
        printf '%s\n' "$_cpst_first" > "$_cpst_dir/concatenated.json"
        cat "$_cpst_dir/producer.json" >> "$_cpst_dir/concatenated.json"
        if c_provenance_validate "$_cpst_dir/concatenated.json" 2>/dev/null; then
            echo 'provenance self-test accepted invalid-first concatenated JSON' >&2; return 1
        fi
    done
    cat "$_cpst_dir/producer.json" "$_cpst_dir/producer.json" > "$_cpst_dir/concatenated.json"
    if c_provenance_validate "$_cpst_dir/concatenated.json" 2>/dev/null; then
        echo 'provenance self-test accepted two valid JSON documents' >&2; return 1
    fi
    jq '.complete = false' "$_cpst_dir/producer.json" > "$_cpst_dir/concatenated.json"
    cat "$_cpst_dir/producer.json" >> "$_cpst_dir/concatenated.json"
    if c_provenance_diagnose "$_cpst_dir/producer.json" "$_cpst_dir/concatenated.json" \
        "$_cpst_dir/c-counts.tsv" "$_cpst_dir/c-diff.txt" >/dev/null 2>&1; then
        echo 'provenance self-test diagnosed an incomplete-first concatenated record' >&2; return 1
    fi
    for _cpst_unknown in absent unknown malformed unbound; do
        _cpst_base="$_cpst_dir/$_cpst_unknown.json"
        case "$_cpst_unknown" in
            absent) ;;
            unknown) printf '{"schema":1,"status":"unknown","reason":"historical producer unavailable"}\n' > "$_cpst_base" ;;
            malformed) printf '{broken\n' > "$_cpst_base" ;;
            unbound) jq '.rows[].ir_count = 99' "$_cpst_dir/producer.json" > "$_cpst_base" ;;
        esac
        _cpst_out=$(c_provenance_diagnose "$_cpst_base" "$_cpst_dir/producer.json" \
            "$_cpst_dir/c-counts.tsv" "$_cpst_dir/c-diff.txt" 2>/dev/null) || return 1
        case "$_cpst_out" in *'unknown baseline environment'*) ;; *) echo "provenance self-test: $_cpst_unknown" >&2; return 1 ;; esac
    done
    if c_provenance_validate "$_cpst_dir/unknown.json" measured 2>/dev/null; then
        echo 'provenance self-test accepted a historical unknown as a measurement' >&2; return 1
    fi
    # A complete promoted sidecar must be read from a file, even when larger
    # than the host's per-argument limit. Extra info is not comparison identity.
    jq '.info.padding = ("x" * 262144)' "$_cpst_dir/producer.json" > "$_cpst_dir/large.json"
    _cpst_out=$(c_provenance_diagnose "$_cpst_dir/large.json" "$_cpst_dir/producer.json" \
        "$_cpst_dir/c-counts.tsv" "$_cpst_dir/c-diff.txt") || return 1
    case "$_cpst_out" in *'same recorded C comparison identity'*) ;; *) echo 'provenance self-test rejected a large sidecar' >&2; return 1 ;; esac
    printf 'benchmark/typelisp/a | 10 | 11 | +1 | +10%% | REGRESSION\n' > "$_cpst_dir/tl-diff.txt"
    _cpst_out=$(c_provenance_diagnose "$_cpst_dir/producer.json" "$_cpst_dir/producer.json" \
        "$_cpst_dir/c-counts.tsv" "$_cpst_dir/tl-diff.txt") || return 1
    [ -z "$_cpst_out" ] || { echo 'provenance self-test explained away a TypeLisp change' >&2; return 1; }
    echo 'C comparison provenance self-test passed'
)
