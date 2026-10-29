#!/usr/bin/env sh
# Canonical #6883 provenance primitives from #6909 (before #8118), extended
# as one versioned same-run envelope. POSIX shell and existing jq/coreutils.
# Schema 4 (#7767 slice 2) binds each CI lane: its job, its gate plan and a
# sealed receipt of that plan's results. No transported compiler is consumed;
# the lane aggregator compares the lanes' independently built compilers.

ci_compiler_artifact_error() {
    echo "[ci-compiler-artifact] $*" >&2
    return 1
}

# Set CI_COMPILER_ARTIFACT_SHA256 to FILE's digest: the first field of the
# tool's output line, as awk '{ print $1 }' read it.
ci_compiler_artifact_hash_file() {
    _cica_sha_file=$1
    CI_COMPILER_ARTIFACT_SHA256=
    if command -v sha256sum >/dev/null 2>&1; then
        _cica_sha_line=$(sha256sum "$_cica_sha_file") || return 1
    elif command -v shasum >/dev/null 2>&1; then
        _cica_sha_line=$(shasum -a 256 "$_cica_sha_file") || return 1
    else
        ci_compiler_artifact_error "sha256sum or shasum is required"
        return 1
    fi
    CI_COMPILER_ARTIFACT_SHA256=${_cica_sha_line%%[ 	]*}
}

ci_compiler_artifact_sha256_file() {
    ci_compiler_artifact_hash_file "$1" || return 1
    printf '%s\n' "$CI_COMPILER_ARTIFACT_SHA256"
}

ci_compiler_artifact_sha256_stdin() {
    if command -v sha256sum >/dev/null 2>&1; then
        _cica_sha_line=$(sha256sum) || return 1
    elif command -v shasum >/dev/null 2>&1; then
        _cica_sha_line=$(shasum -a 256) || return 1
    else
        ci_compiler_artifact_error "sha256sum or shasum is required"
        return 1
    fi
    printf '%s\n' "${_cica_sha_line%%[ 	]*}"
}

# A line-based grep never saw a newline inside the value; this check rejects
# it with every other control byte, since fields are one metadata line each.
ci_compiler_artifact_field_safe() {
    _cica_safe_name=$1
    _cica_safe_value=$2
    # Every control byte a C-locale [[:cntrl:]] matches, except NUL, which no
    # shell value can hold. DEL comes last, so the newline stays in the set.
    [ -n "${CI_COMPILER_ARTIFACT_CONTROL_BYTES:-}" ] ||
        CI_COMPILER_ARTIFACT_CONTROL_BYTES=$(printf '\001\002\003\004\005\006\007\010\011\012\013\014\015\016\017\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037\177')
    case "$_cica_safe_value" in
        *["$CI_COMPILER_ARTIFACT_CONTROL_BYTES"]*)
            ci_compiler_artifact_error \
                "$_cica_safe_name contains a control character"
            return 1
            ;;
    esac
    return 0
}

# True when $1 is exactly forty lowercase hex digits.
ci_compiler_artifact_is_identity() {
    case "$1" in
        '' | *[!0-9a-f]*) return 1 ;;
    esac
    [ "${#1}" -eq 40 ]
}

ci_compiler_artifact_key() {
    _cica_key_producer_sha=$1
    _cica_key_producer_identity=$2
    _cica_key_host=$3
    _cica_key_target=$4
    _cica_key_cwd=$5
    _cica_key_source_roots=$6
    _cica_key_stdlib_roots=$7
    _cica_key_cfg=$8
    _cica_key_opt=$9
    shift 9
    _cica_key_profile=$1
    _cica_key_environment=$2
    _cica_key_argv=$3
    _cica_key_source_digest=$4
    _cica_key_output_kind=$5
    {
        printf 'schema=1\n'
        printf 'producer_sha256=%s\n' "$_cica_key_producer_sha"
        printf 'producer_identity=%s\n' "$_cica_key_producer_identity"
        printf 'host=%s\n' "$_cica_key_host"
        printf 'target=%s\n' "$_cica_key_target"
        printf 'cwd=%s\n' "$_cica_key_cwd"
        printf 'source_roots=%s\n' "$_cica_key_source_roots"
        printf 'stdlib_roots=%s\n' "$_cica_key_stdlib_roots"
        printf 'cfg=%s\n' "$_cica_key_cfg"
        printf 'opt_level=%s\n' "$_cica_key_opt"
        printf 'profile=%s\n' "$_cica_key_profile"
        printf 'environment=%s\n' "$_cica_key_environment"
        printf 'argv=%s\n' "$_cica_key_argv"
        printf 'source_set_sha256=%s\n' "$_cica_key_source_digest"
        printf 'output_kind=%s\n' "$_cica_key_output_kind"
    } | ci_compiler_artifact_sha256_stdin
}

# Envelope paths are literal checkout-relative paths, never evaluated text.
cica_fail() { ci_compiler_artifact_error "$*"; exit 1; }
# Native jq.exe otherwise translates LF to CRLF under Git Bash. The canonical
# metadata and schema-1 key framing are LF on both hosts.
cica_jq() { command jq -b "$@"; }
cica_sha() { ci_compiler_artifact_sha256_file "$1"; }
cica_rel() {
    ci_compiler_artifact_field_safe path "$1" || return 1
    case "$1" in '' | /* | *\\* | *:* | . | .. | ./* | ../* | */./* | */../* | */. | */.. | *//*) return 1 ;; esac
}
cica_file() {
    # Keep these names separate from callers. This check is deliberately
    # fork-free: source closures contain thousands of paths on Git Bash.
    _cf_base=$1 _cf_rel=$2
    cica_rel "$_cf_rel" || cica_fail 'unsafe relative path'
    _cf_path=$_cf_base
    while :; do
        _cf_part=${_cf_rel%%/*}
        _cf_path=$_cf_path/$_cf_part
        [ ! -L "$_cf_path" ] || cica_fail "symlink path: $_cf_path"
        case "$_cf_rel" in */*) _cf_rel=${_cf_rel#*/} ;; *) break ;; esac
    done
    [ "${3:-}" != regular ] || [ -f "$_cf_path" ] || cica_fail "not a regular file: $_cf_path"
    printf '%s\n' "$_cf_path"
}
cica_hash_line() {
    CICA_PARSED_HASH=${1%% *}
    [ "${#CICA_PARSED_HASH}" -eq 64 ] || cica_fail 'unsafe digest line'
    case "$CICA_PARSED_HASH" in *[!0-9a-f]*) cica_fail 'unsafe digest' ;; esac
    _hl_tail=${1#"$CICA_PARSED_HASH"}
    # GNU coreutils use either text (two spaces) or binary (space + star).
    # MSYS/Cygwin default to binary mode; both hash the exact file bytes.
    case "$_hl_tail" in '  '* | ' *'*) CICA_PARSED_PATH=${_hl_tail#??} ;; *) cica_fail 'unsafe digest marker' ;; esac
}

cica_owned() {
    case "$2" in "$1"/target/*) cica_file "$1" "${2#"$1"/}" >/dev/null ;; *) cica_fail 'envelope path must be inside owned target/' ;; esac
}
cica_json() {
    [ -f "$1" ] && [ ! -L "$1" ] || cica_fail 'missing regular JSON'
    [ "$(wc -c < "$1")" -le 4194304 ] || cica_fail 'oversized JSON'
    cica_jq -S . "$1" > "$CICA_SCRATCH/json-check"
    cmp -s "$1" "$CICA_SCRATCH/json-check" || cica_fail 'noncanonical or duplicate JSON fields'
}
# A CI lane is HOST-N (scripts/ci-lanes.tsv) and its job is "CI lane HOST-N".
# A producer reads its lane from TYPELISP_CI_LANE and its attempt from Actions.
# A verifier passes the lane it expects and the attempt in which that lane's
# job actually ran (scripts/ci-lane.sh), so a "Re-run failed jobs" copy binds
# to the attempt that executed it.
cica_lane_valid() {
    case "$1" in "$CICA_HOST"-[1-9]) return 0 ;; *) return 1 ;; esac
}
cica_context() (
    _commit=$(git -C "$CICA_ROOT" rev-parse HEAD)
    _tree=$(git -C "$CICA_ROOT" rev-parse 'HEAD^{tree}')
    if [ "$1" = local ]; then
        [ "${GITHUB_ACTIONS:-}" != true ] || cica_fail 'local mode forbidden in CI'
        _lane=${2:-${TYPELISP_CI_LANE:-local}}
        [ "$_lane" = local ] || cica_lane_valid "$_lane" || cica_fail 'invalid local lane'
        cica_jq -nS --arg c "$_commit" --arg t "$_tree" --arg h "$CICA_HOST" --arg l "$_lane" \
          '{scope:"local",repository:"local",run_id:"local",attempt:0,commit:$c,tree:$t,head:$c,workflow_ref:"local",workflow_sha:$c,host:$h,lane:$l,job:"local"}'
        exit
    fi
    [ "${GITHUB_ACTIONS:-}" = true ] && [ "${GITHUB_EVENT_NAME:-}" = pull_request ] || cica_fail 'required PR workflow context missing'
    [ "${GITHUB_SHA:-}" = "$_commit" ] || cica_fail 'checkout differs from trusted event'
    git -C "$CICA_ROOT" diff --quiet HEAD || cica_fail 'dirty tracked checkout'
    cica_jq -en --arg n "${GITHUB_RUN_ID:-}" --arg a "${GITHUB_RUN_ATTEMPT:-}" --arg s "${GITHUB_WORKFLOW_SHA:-}" \
      '$n|test("^[0-9]+$")' >/dev/null
    cica_jq -en --arg a "$GITHUB_RUN_ATTEMPT" --arg s "$GITHUB_WORKFLOW_SHA" \
      '($a|test("^[1-9][0-9]*$")) and ($s|test("^[0-9a-f]{40}$"))' >/dev/null || cica_fail 'run attempt/workflow SHA missing'
    case "$GITHUB_WORKFLOW_REF" in "$GITHUB_REPOSITORY"/.github/workflows/ci.yml@*) ;; *) cica_fail 'wrong workflow' ;; esac
    cica_jq -e --arg r "$GITHUB_REPOSITORY" '.repository.full_name==$r and (.pull_request.head.sha|test("^[0-9a-f]{40}$"))' "$GITHUB_EVENT_PATH" >/dev/null || cica_fail 'event repository/head mismatch'
    _lane=${2:-${TYPELISP_CI_LANE:-}}
    cica_lane_valid "$_lane" || cica_fail 'missing or wrong-host CI lane'
    _attempt=${3:-$GITHUB_RUN_ATTEMPT}
    case "$_attempt" in '' | 0* | *[!0-9]*) cica_fail 'invalid lane attempt' ;; esac
    [ "$_attempt" -le "$GITHUB_RUN_ATTEMPT" ] || cica_fail 'lane attempt is later than this run attempt'
    cica_jq -nS --arg c "$_commit" --arg t "$_tree" --arg h "$CICA_HOST" --arg r "$GITHUB_REPOSITORY" \
      --arg id "$GITHUB_RUN_ID" --argjson a "$_attempt" --arg w "$GITHUB_WORKFLOW_REF" --arg s "$GITHUB_WORKFLOW_SHA" \
      --arg head "$(cica_jq -r .pull_request.head.sha "$GITHUB_EVENT_PATH")" --arg l "$_lane" \
      '{scope:"github",repository:$r,run_id:$id,attempt:$a,commit:$c,tree:$t,head:$head,workflow_ref:$w,workflow_sha:$s,host:$h,lane:$l,job:("CI lane "+$l)}'
)
cica_state() {
    cica_file "$CICA_ROOT" "${CICA_WORK#"$CICA_ROOT"/}/draft/context.json" regular >/dev/null
    cica_json "$CICA_WORK/draft/context.json"
    _scope=$(cica_jq -r .scope "$CICA_WORK/draft/context.json")
    cica_context "$_scope" > "$CICA_SCRATCH/context.json"
    cmp -s "$CICA_SCRATCH/context.json" "$CICA_WORK/draft/context.json" || cica_fail 'producer context changed'
}
cica_sources() (
    # Preserve #6883's raw-byte manifest framing. Batch hashing avoids one
    # Git Bash process per source on Windows. Only tracked source inputs enter
    # the closure; generated inputs are bound separately after bootstrap.
    cd "$CICA_ROOT"
    git ls-files -z -- src stdlib tests > "$CICA_SCRATCH/source-paths.z"
    git -c core.quotePath=false ls-files --stage -- src stdlib tests > "$CICA_SCRATCH/source-modes"
    awk '$1!="100644" && $1!="100755" {exit 1}' "$CICA_SCRATCH/source-modes" || cica_fail 'special tracked source input'
    xargs -0 sha256sum -- < "$CICA_SCRATCH/source-paths.z" > "$CICA_SCRATCH/source-hashes"
    [ -s "$CICA_SCRATCH/source-hashes" ] || cica_fail 'empty source closure'
    while IFS= read -r _line; do
        cica_hash_line "$_line"
        cica_file "$CICA_ROOT" "$CICA_PARSED_PATH" regular >/dev/null || exit 1
        printf '%s  {root}/%s\n' "$CICA_PARSED_HASH" "$CICA_PARSED_PATH"
    done < "$CICA_SCRATCH/source-hashes" > "$CICA_SCRATCH/source-manifest"
    LC_ALL=C sort -k2 "$CICA_SCRATCH/source-manifest"
)
cica_hash_map() (
    cd "$CICA_ROOT"
    while IFS= read -r _hm_path; do
        cica_file "$CICA_ROOT" "$_hm_path" regular >/dev/null || exit 1
        printf '%s\0' "$_hm_path"
    done > "$CICA_SCRATCH/hash-map-paths.z"
    [ -s "$CICA_SCRATCH/hash-map-paths.z" ] || cica_fail 'empty hash inventory'
    xargs -0 sha256sum -- < "$CICA_SCRATCH/hash-map-paths.z" > "$CICA_SCRATCH/hash-map-raw" || cica_fail 'inventory hashing failed'
    while IFS= read -r _hm_line; do
        cica_hash_line "$_hm_line"
        cica_rel "$CICA_PARSED_PATH" || cica_fail 'unsafe inventory path'
        printf '%s\t%s\n' "$CICA_PARSED_PATH" "$CICA_PARSED_HASH"
    done < "$CICA_SCRATCH/hash-map-raw" > "$CICA_SCRATCH/hash-map-entries"
    cica_jq -RsS 'split("\n")[:-1]|map(split("\t")|{key:.[0],value:.[1]})|from_entries' "$CICA_SCRATCH/hash-map-entries"
)
cica_inventory() {
    cica_hash_map <<'PATHS'
scripts/ci-gates.tsv
scripts/ci-lanes.tsv
scripts/ci-compiler-artifacts.tsv
scripts/expand-integration-manifest.awk
tests/integration/native.manifest
PATHS
}
cica_recipes() {
    cica_hash_map <<'PATHS'
scripts/ci-verify.sh
scripts/check-bootstrap-fixpoint.sh
scripts/lib-native-link.sh
scripts/lib-linux-entry.sh
scripts/lib-build-provenance.sh
scripts/check-build-invariance.sh
scripts/lib-build-invariance-batch.sh
scripts/lib-bounded-pool.sh
scripts/run-memory-bounded.sh
scripts/lib-linux-memory-limit.sh
scripts/run-bounded-process.ps1
scripts/ci-compiler-artifact.sh
scripts/lib-ci-compiler-artifact.sh
scripts/ci-lane.sh
PATHS
}

cica_generated() {
    printf '%s\n' target/build-stage0/git-hash.txt target/build-stage0/tree-hash.txt \
      target/embedded-stdlib-tlci/stdlib.tlci target/embedded-stdlib-tlci/stdlib.tlci.tlch \
      target/embedded-stdlib-tlci/source-hash.txt target/embedded-stdlib-tlci/modules.txt \
      "target/embedded-stdlib-tlci/prelude-surface-$CICA_HOST.rodata"
}
cica_corpus() {
    printf '%s\n' 'selfhost_main_opt1|src/main.tl|1' 'selfhost_main_opt2|src/main.tl|2'
    awk -v host=linux -f "$CICA_ROOT/scripts/expand-integration-manifest.awk" "$CICA_ROOT/tests/integration/native.manifest" > "$CICA_SCRATCH/expanded"
    awk -F'|' 'NF>=2 {print "integration_" $1 "|" $2 "|2"; next} {exit 1}' "$CICA_SCRATCH/expanded"
}
# cica_roles PLAN: the roles (scripts/ci-compiler-artifacts.tsv) whose
# producer gate is in this plan, one gate ID per line, on this host.
cica_roles() {
    awk -F '\t' -v host="$CICA_HOST" '
        { sub(/\r$/, "") }
        FNR == NR { if ($0 !~ /^[a-z][a-z0-9-]*$/) exit 1; plan[$0] = 1; next }
        /^#/ { next }
        NF != 6 || $1 != 4 || ($2 != "bootstrap-converged" && $2 != "build-invariance-opt1-reference") ||
            ($3 != "all" && $3 != "linux" && $3 != "windows") { bad = 1; exit 1 }
        ($3 == "all" || $3 == host) && ($4 in plan) { print $2 }
        END { if (bad) exit 1 }
    ' "$1" "$CICA_ROOT/scripts/ci-compiler-artifacts.tsv" || cica_fail 'invalid plan or role inventory'
}
cica_files() (
    _fi_base=$1
    cd "$_fi_base"
    find . -type l -print > "$CICA_SCRATCH/symlinks" || cica_fail 'symlink enumeration failed'
    [ ! -s "$CICA_SCRATCH/symlinks" ] || cica_fail 'symlink in envelope'
    find . ! -type d ! -type f -print > "$CICA_SCRATCH/special" || cica_fail 'special-file enumeration failed'
    [ ! -s "$CICA_SCRATCH/special" ] || cica_fail 'special file in envelope'
    find . -type f -print0 > "$CICA_SCRATCH/files.z" || cica_fail 'file enumeration failed'
    if [ -s "$CICA_SCRATCH/files.z" ]; then
        xargs -0 sha256sum -- < "$CICA_SCRATCH/files.z" > "$CICA_SCRATCH/file-hashes" || cica_fail 'file hashing failed'
    else : > "$CICA_SCRATCH/file-hashes"; fi
    _fi_count=0
    while IFS= read -r _fi_line; do
        _fi_count=$((_fi_count+1))
        [ "$_fi_count" -le 10000 ] || cica_fail 'too many envelope files'
        cica_hash_line "$_fi_line"
        case "$CICA_PARSED_PATH" in ./*) _fi_rel=${CICA_PARSED_PATH#./} ;; *) cica_fail 'nonrelative file enumeration' ;; esac
        cica_file "$_fi_base" "$_fi_rel" regular >/dev/null || exit 1
        [ "$_fi_rel" != bundle.json ] || continue
        printf '%s\t%s\n' "$CICA_PARSED_HASH" "$_fi_rel"
    done < "$CICA_SCRATCH/file-hashes" > "$CICA_SCRATCH/file-entries"
    # GNU wc can stat the same NUL-delimited inventory in one process. No
    # per-file shell, hash, size or jq process is needed on Windows.
    wc -c --files0-from="$CICA_SCRATCH/files.z" > "$CICA_SCRATCH/file-sizes" || cica_fail 'file sizing failed'
    cica_jq -nS --rawfile hashes "$CICA_SCRATCH/file-entries" --rawfile sizes "$CICA_SCRATCH/file-sizes" '
      ($sizes|split("\n")|map(select(length>0)|capture("^ *(?<n>[0-9]+) (?<p>.*)$"))|
        map(select(.p|startswith("./"))|{key:.p[2:],value:(.n|tonumber)})|from_entries) as $size |
      ($hashes|split("\n")[:-1]|map(split("\t")|{key:.[1],value:{sha256:.[0],bytes:$size[.[1]]}})|from_entries) |
      if all(.[]; .bytes|type=="number" and .>=0) then . else error("file size missing") end'
)

cica_copy() (
    _src=$1 _dest=$2
    case "$_src" in "$CICA_ROOT"/*) cica_file "$CICA_ROOT" "${_src#"$CICA_ROOT"/}" regular >/dev/null ;; *) cica_fail 'external payload path' ;; esac
    [ ! -e "$_dest" ] && [ ! -L "$_dest" ] || cica_fail 'snapshot destination exists'
    _before=$(cica_sha "$_src")
    [ -s "$_src" ] || cica_fail 'empty snapshot input'
    mkdir -p "$(dirname -- "$_dest")"
    cp -p "$_src" "$_dest"
    [ "$_before" = "$(cica_sha "$_dest")" ] && [ "$_before" = "$(cica_sha "$_src")" ] || cica_fail 'input changed during copy'
)
cica_identity() (
    _id=$("$1" --producer-identity | tr -d '\r\n')
    ci_compiler_artifact_is_identity "$_id" || cica_fail 'malformed producer identity'
    printf '%s\n' "$_id"
)
cica_environment() {
    # NUL records and JSON preserve value boundaries, including newlines. Only
    # the digest leaves this pipeline; no secret-bearing environment file is
    # retained. Root normalization matches the canonical argv convention.
    env -0 | cica_jq -Rsc --arg r "$CICA_ROOT" '
      split("\u0000")[:-1] | map(index("=") as $i | {key:.[0:$i],value:.[($i+1):]}) |
      map(select(.key|test("^TYPELISP_|^(CC|CFLAGS|LDFLAGS|LANG|LC_ALL)$"))) |
      map(.value|= (split($r)|join("{root}"))) | from_entries' | ci_compiler_artifact_sha256_stdin
}
cica_binary() (
    _magic=$(od -An -tx1 -N4 "$1" | tr -d ' \r\n')
    if [ "$CICA_HOST" = linux ]; then
        [ "$_magic" = 7f454c46 ] && [ "$(od -An -tx1 -j4 -N1 "$1" | tr -d ' \r\n')" = 02 ] && \
          [ "$(od -An -tx1 -j18 -N2 "$1" | tr -d ' \r\n')" = 3e00 ] || cica_fail 'wrong ELF target'
    else
        case "$_magic" in 4d5a*) ;; *) cica_fail 'wrong PE target' ;; esac
        _offset=$(od -An -tu4 -j60 -N4 "$1" | tr -d ' \r\n')
        case "$_offset" in '' | *[!0-9]*) cica_fail 'missing PE offset' ;; esac
        [ "$_offset" -ge 64 ] && [ "$_offset" -le "$(wc -c < "$1")" ] || cica_fail 'invalid PE offset'
        [ "$(od -An -tx1 -j"$_offset" -N6 "$1" | tr -d ' \r\n')" = 504500006486 ] || cica_fail 'wrong PE architecture'
    fi
)
cica_record() {
    _label=$1; shift
    cica_state
    _wrapper='[]'
    case "$1" in */run-memory-bounded.sh)
        : > "$CICA_SCRATCH/wrapper-args"
        while [ "$1" != -- ]; do printf '%s\n' "$1" >> "$CICA_SCRATCH/wrapper-args"; shift; done
        shift
        _wrapper=$(cica_jq -Rs --arg r "$CICA_ROOT" 'split("\n")[:-1]|map(split($r)|join("{root}"))' "$CICA_SCRATCH/wrapper-args") ;;
    esac
    [ "$2" = compile ] || cica_fail 'compiler invocation missing'
    _producer=$1
    _argv=$(cica_jq -cn --arg r "$CICA_ROOT" '$ARGS.positional|map(if .==$r then "{root}" elif startswith($r+"/") then "{root}/"+.[($r|length)+1:] else . end)' --args -- "$@")
    _version=$("$_producer" --version | tr -d '\r')
    ci_compiler_artifact_field_safe version "$_version" || cica_fail 'malformed version'
    _id=$(cica_identity "$_producer")
    _environment_sha=$(cica_environment)
    _output=null _batch=null
    if [ "$_label" = reference ]; then
        _batch_path=$(printf '%s\n' "$_argv" | cica_jq -er '.[index("--batch")+1]')
        _batch_path=$CICA_ROOT/${_batch_path#'{root}/'}
        [ "$(wc -l < "$_batch_path")" -eq 1 ] || cica_fail 'reference batch not singleton'
        _batch=$(cica_jq -Rs --arg r "$CICA_ROOT" 'split($r)|join("{root}")' "$_batch_path")
        printf '%s\n' "$_batch" | cica_jq -er 'test("^src/main[.]tl[|]\\{root\\}/target/build-invariance/compare/opt2-built/selfhost_main_opt1[.]s\n$")' >/dev/null || cica_fail 'wrong reference entry'
    else
        case "$_label" in stage1 | stage2 | stage3 | stage4) ;; *) cica_fail 'unexpected bootstrap record' ;; esac
        _out=$(printf '%s\n' "$_argv" | cica_jq -er '.[index("-o")+1]')
        [ "$_out" = "{root}/target/bootstrap-fixpoint/$_label.s" ] || cica_fail 'wrong recorded output'
        _file=$CICA_ROOT/${_out#'{root}/'}
        _output=$(cica_jq -cn --arg p "$_out" --arg h "$(cica_sha "$_file")" --argjson n "$(wc -c < "$_file")" '{path:$p,sha256:$h,bytes:$n}')
    fi
    _record=$CICA_WORK/draft/records/$_label.json
    cica_file "$CICA_ROOT" "${_record#"$CICA_ROOT"/}" >/dev/null
    [ ! -e "$_record" ] && [ ! -L "$_record" ] || cica_fail 'duplicate producer record'
    mkdir -p "$CICA_WORK/draft/records"
    cica_jq -nS --argjson a "$_argv" --argjson w "$_wrapper" --arg v "$_version" --arg h "$(cica_sha "$_producer")" --arg i "$_id" --argjson o "$_output" --argjson b "$_batch" --arg e "$_environment_sha" \
      '{argv:$a,wrapper:$w,producer_version:$v,producer_sha256:$h,producer_identity:$i,compiled_output:$o,batch_manifest:$b,variables_sha256:$e}' > "$_record"
}
cica_flags() {
    cica_jq -e --arg h "$CICA_HOST" --arg role "$1" '
      . as $m | .argv as $a |
      (if $h=="linux" then ["linux","unix","target-linux","os-linux"] else ["windows","target-windows","os-windows"] end) as $native |
      ($native + (if $role=="bootstrap-converged" then ["compiler-build-identity","embedded-stdlib-tlci"] else [] end)) as $cfg |
      ($a[0]|capture("^\\{root\\}/target/bootstrap-fixpoint/stage(?<n>[234])(?<ext>[.]exe)?$")) as $producer |
      (if $h=="windows" then ".exe" else "" end) as $ext |
      if $role=="bootstrap-converged" then
        (($producer.n|tonumber)+1) as $stage |
        ($stage==3 or $stage==4) and (($producer.ext//"")==$ext) and
        $a==([$a[0],"compile","src/main.tl","-o","{root}/target/bootstrap-fixpoint/stage"+($stage|tostring)+".s","--target",$h+"-x86_64"] +
          [$cfg[]|"--cfg",.] + ["--stdlib-root","{root}/src","--opt-level","2"])
      else
        (($producer.ext//"")==$ext) and ($a[3]|test("^\\{root\\}/target/build-invariance/batches/opt2-built/opt1/chunks/entries[.][0-9]+[.]txt$")) and
        $a==([$a[0],"compile","--batch",$a[3],"--target","linux-x86_64"] + [$cfg[]|"--cfg",.] + ["--backend-mode","scalar","--opt-level","1","--stdlib-root","stdlib","--stdlib-root","src"])
      end' "$2" >/dev/null || cica_fail 'invocation flags substituted'
}
cica_key_json() (
    _f=$1
    # Exactly the historical fourteen fields, in its original order/framing.
    cica_jq -er '[.producer_sha256,.producer_identity,.host,.target,.cwd,
      .source_roots,.stdlib_roots,.cfg,.opt_level,.profile,.environment,.argv,
      .source_set_sha256,.output_kind] |
      if all(.[]; type=="string" and length>0 and (test("[\\x00-\\x1f\\x7f]")|not))
      then .[] else error("unsafe provenance fields") end' "$_f" > "$CICA_SCRATCH/key-fields" || cica_fail 'unsafe provenance fields'
    { printf 'schema=1\n'; paste -d= - "$CICA_SCRATCH/key-fields" <<'FIELDS'
producer_sha256
producer_identity
host
target
cwd
source_roots
stdlib_roots
cfg
opt_level
profile
environment
argv
source_set_sha256
output_kind
FIELDS
    } | ci_compiler_artifact_sha256_stdin
)

cica_publish() {
    _role=$1; shift
    cica_state
    cica_roles "$CICA_WORK/draft/lane/plan.txt" > "$CICA_SCRATCH/expected-roles"
    grep -qxF "$_role" "$CICA_SCRATCH/expected-roles" || cica_fail 'wrong host role'
    _started=$(date +%s%3N)
    _draft=$CICA_WORK/draft _dir=$CICA_WORK/draft/roles/$_role.publishing
    cica_file "$CICA_ROOT" "${_dir#"$CICA_ROOT"/}" >/dev/null
    cica_file "$CICA_ROOT" "${_draft#"$CICA_ROOT"/}/roles/$_role" >/dev/null
    [ ! -e "$_dir" ] && [ ! -e "$_draft/roles/$_role" ] || cica_fail 'partial/duplicate role publication'
    mkdir -p "$_dir"
    _commit=$(cica_jq -r .commit "$_draft/context.json") _tree=$(cica_jq -r .tree "$_draft/context.json")
    if [ "$_role" = bootstrap-converged ]; then
        _selected=$1 _seed=$2 _previous=$3
        case "$_selected" in
          "$CICA_ROOT"/target/bootstrap-fixpoint/stage3 | "$CICA_ROOT"/target/bootstrap-fixpoint/stage3.exe) _stage=stage3 _input=stage2 _pair='["stage2.s","stage3.s"]' ;;
          "$CICA_ROOT"/target/bootstrap-fixpoint/stage4 | "$CICA_ROOT"/target/bootstrap-fixpoint/stage4.exe) _stage=stage4 _input=stage3 _pair='["stage3.s","stage4.s"]' ;;
          *) cica_fail 'unexpected converged compiler path' ;;
        esac
        _ext=; [ "$CICA_HOST" != windows ] || _ext=.exe
        _producer=$CICA_ROOT/target/bootstrap-fixpoint/$_input$_ext
        _rec=$_draft/records/$_stage.json
        cica_json "$_rec"
        [ "$(cica_identity "$_producer")" = "$_tree" ] && \
          [ "$(cica_sha "$_producer")" = "$(cica_jq -r .producer_sha256 "$_rec")" ] || cica_fail 'bootstrap producer changed'
        [ "$(cica_identity "$_selected")" = "$_tree" ] && [ "$(cica_identity "$_previous")" = "$_tree" ] || cica_fail 'output identity changed'
        cica_binary "$_selected"; cica_binary "$_previous"
        cica_copy "$_selected" "$_dir/payload/compiler"
        cica_copy "$_previous" "$_dir/payload/previous-stage"
        for _name in stage3.s stage3-embedded.s "$_input.s" "$_stage.s"; do
            cica_jq -cn --arg p "$_name" --arg h "$(cica_sha "$CICA_ROOT/target/bootstrap-fixpoint/$_name")" \
              --argjson n "$(wc -c < "$CICA_ROOT/target/bootstrap-fixpoint/$_name")" '{key:$p,value:{sha256:$h,bytes:$n}}'
        done > "$CICA_SCRATCH/proofs"
        cica_jq -sS from_entries "$CICA_SCRATCH/proofs" > "$CICA_SCRATCH/proof-base.json"
        cica_generated > "$CICA_SCRATCH/generated-paths"
        while IFS= read -r _p; do cica_copy "$CICA_ROOT/$_p" "$_dir/generated/$_p"; done < "$CICA_SCRATCH/generated-paths"
        [ "$(cat "$_dir/generated/target/build-stage0/git-hash.txt")" = "$_commit" ] && \
          [ "$(cat "$_dir/generated/target/build-stage0/tree-hash.txt")" = "$_tree" ] || cica_fail 'generated stamp changed'
        cica_jq -S --arg stage "$_stage" --argjson pair "$_pair" --arg out "$_tree" --arg seed "$(cica_sha "$_seed")" \
          --arg si "$(cica_identity "$_seed")" --slurpfile r "$_rec" \
          '.+{selected_stage:$stage,fixpoint_pair:$pair,output_identity:$out,seed:{sha256:$seed,identity:$si},compile_receipt:$r[0].compiled_output,input_producer_sha256:$r[0].producer_sha256}' \
          "$CICA_SCRATCH/proof-base.json" > "$CICA_SCRATCH/proof.json"
    else
        _reference=$1 _producer=$2 _rec=$_draft/records/reference.json
        cica_json "$_rec"
        [ "$_reference" = "$CICA_ROOT/target/build-invariance/compare/opt2-built/selfhost_main_opt1.s" ] || cica_fail 'unexpected reference path'
        [ "$(cica_identity "$_producer")" = "$_tree" ] && [ "$(cica_sha "$_producer")" = "$(cica_jq -r .producer_sha256 "$_rec")" ] || cica_fail 'reference producer changed'
        _boot=$_draft/roles/bootstrap-converged/manifest.json
        [ "$(cica_sha "$_producer")" = "$(cica_jq -r '.files["payload/compiler"].sha256' "$_boot")" ] || cica_fail 'reference producer role changed'
        cmp -s "$_reference" "$CICA_ROOT/target/build-invariance/compare/opt1-built/selfhost_main_opt1.s" || cica_fail 'reference comparison missing'
        cica_copy "$_reference" "$_dir/payload/reference.s"
        cica_copy "$CICA_ROOT/target/build-invariance/corpus.txt" "$_dir/inventory/corpus.txt"
        cica_corpus > "$CICA_SCRATCH/corpus"
        cmp -s "$CICA_SCRATCH/corpus" "$_dir/inventory/corpus.txt" || cica_fail 'reference corpus incomplete'
        cica_jq -nS --arg hash "$(cica_sha "$_reference")" --slurpfile r "$_rec" --slurpfile b "$_boot" \
          '{compared_output_sha256:$hash,input_producer_sha256:$r[0].producer_sha256,batch_manifest:$r[0].batch_manifest,seed:$b[0].proof.seed,parent_provenance_key:$b[0].provenance_key}' > "$CICA_SCRATCH/proof.json"
    fi
    cica_jq -e --arg v "typelisp $_commit built unknown" --arg t "$_tree" '.producer_version==$v and .producer_identity==$t' "$_rec" >/dev/null || cica_fail 'producer version/identity changed'
    cica_flags "$_role" "$_rec"
    cica_jq -S --slurpfile r "$_rec" '.invocation_record=$r[0]' "$CICA_SCRATCH/proof.json" > "$CICA_SCRATCH/proof-record.json"
    mv "$CICA_SCRATCH/proof-record.json" "$CICA_SCRATCH/proof.json"
    cp "$_draft/source-set.sha256" "$_dir/source-set.sha256"
    cica_files "$_dir" > "$CICA_SCRATCH/snapshot-files.json"
    cica_jq -S 'del(."source-set.sha256")' "$CICA_SCRATCH/snapshot-files.json" > "$CICA_SCRATCH/files.json"
    cica_recipes > "$CICA_SCRATCH/recipes.json"
    # Use the actual successful invocation's environment, not the later
    # publisher's environment. Values stay hashed; recipes bind defaults.
    _environment_sha=$(cica_jq -r .variables_sha256 "$_rec")
    cica_jq -cnS --arg c "$_commit" --arg e "$_environment_sha" --slurpfile r "$_rec" \
      --slurpfile t "$_draft/toolchain.json" --slurpfile p "$CICA_SCRATCH/proof.json" \
      --slurpfile f "$CICA_SCRATCH/files.json" --slurpfile recipes "$CICA_SCRATCH/recipes.json" \
      '{producer_commit:$c,producer_version:$r[0].producer_version,toolchain:$t[0],seed:$p[0].seed,recipes:$recipes[0],variables_sha256:$e,resource_wrapper:$r[0].wrapper,generated_inputs:($f[0]|with_entries(select(.key|startswith("generated/"))))}' > "$CICA_SCRATCH/environment.json"
    cica_jq -nS --arg role "$_role" --arg host "$CICA_HOST" --arg source "$(cica_sha "$_dir/source-set.sha256")" \
      --arg env "$(cat "$CICA_SCRATCH/environment.json")" --slurpfile r "$_rec" '
      ($r[0].argv) as $a |
      {producer_sha256:$r[0].producer_sha256,producer_identity:$r[0].producer_identity,host:$host,target:($host+"-x86_64"),cwd:"{root}",
       source_roots:"src,stdlib,tests",stdlib_roots:(if $role=="bootstrap-converged" then "{root}/src" else "stdlib,src" end),
       cfg:([range(0;$a|length) as $i | select($a[$i]=="--cfg")|$a[$i+1]]|join(",")),opt_level:(if $role=="bootstrap-converged" then "2" else "1" end),
       profile:"none",environment:$env,argv:($a|tojson),source_set_sha256:$source,output_kind:(if $role=="bootstrap-converged" then "compiler-binary" else "compiler-assembly" end)}' > "$CICA_SCRATCH/fields.json"
    cica_inventory > "$CICA_SCRATCH/inventory.json"
    cica_jq -nS --arg role "$_role" --arg key "$(cica_key_json "$CICA_SCRATCH/fields.json")" --argjson ms "$(($(date +%s%3N)-_started))" \
      --slurpfile c "$_draft/context.json" --slurpfile f "$CICA_SCRATCH/fields.json" --slurpfile files "$CICA_SCRATCH/files.json" \
      --slurpfile p "$CICA_SCRATCH/proof.json" --slurpfile i "$CICA_SCRATCH/inventory.json" \
      '{schema:4,contract:"ci-compiler-artifact",role:$role,context:$c[0],fields:$f[0],provenance_key:$key,files:$files[0],proof:$p[0],inventory:$i[0],packaging_ms:$ms}' > "$_dir/manifest.json"
    mv "$_dir" "$_draft/roles/$_role"
    printf '[ci-compiler-artifact] snapshot %s %sms\n' "$_role" "$(($(date +%s%3N)-_started))" >&2
}
# cica_init SCOPE PLAN [REQUEST]: PLAN is ci-verify.sh's plan (gate IDs
# first) and REQUEST its --gates selection, empty for the whole host table.
cica_init() {
    [ ! -e "$CICA_WORK" ] || cica_fail 'envelope root is not fresh'
    cica_owned_file "${2:-}" plan
    mkdir -p "$CICA_WORK/draft/lane"
    cica_context "$1" > "$CICA_WORK/draft/context.json"
    cut -f 1 "$2" | tr -d '\r' > "$CICA_WORK/draft/lane/plan.txt"
    printf '%s\n' "${3:-}" | tr ',' '\n' | sed '/^$/d' | LC_ALL=C sort -u > "$CICA_WORK/draft/lane/requested.txt"
    [ -s "$CICA_WORK/draft/lane/plan.txt" ] && cica_lane_ids_ok "$CICA_WORK/draft/lane" || cica_fail 'unsafe or empty lane plan'
    cica_sources > "$CICA_WORK/draft/source-set.sha256"
    case "$CICA_HOST" in linux) _tools='as ld' ;; windows) _tools='clang lld-link' ;; esac
    for _tool in $_tools; do
        _exe=$(command -v "$_tool")
        case "$_tool" in clang) _exe=${TYPELISP_WINDOWS_CLANG:-$_exe} ;; lld-link) _exe=${TYPELISP_WINDOWS_LINK:-$_exe} ;; esac
        if command -v cygpath >/dev/null 2>&1; then _exe=$(cygpath -u "$_exe"); fi
        cica_jq -cn --arg k "$_tool" --arg h "$(cica_sha "$_exe")" --arg v "$("$_exe" --version)" '{key:$k,value:{sha256:$h,version:$v}}'
    done > "$CICA_SCRATCH/tools"
    cica_jq -sS from_entries "$CICA_SCRATCH/tools" > "$CICA_WORK/draft/toolchain.json"
}
# The lane receipt: the plan and request recorded at init, every planned
# gate's result (each must have passed), the timing rows and the produced
# compilers' hashes. Its files enter the bundle index like every other file.
cica_lane_ids_ok() {
    awk '!/^[a-z][a-z0-9]*(-[a-z0-9]+)*$/ { exit 1 }' "$1/plan.txt" "$1/requested.txt" &&
        LC_ALL=C sort "$1/plan.txt" > "$CICA_SCRATCH/plan-sorted" &&
        [ -z "$(LC_ALL=C sort -u "$1/plan.txt" | cmp - "$CICA_SCRATCH/plan-sorted" 2>&1)" ] &&
        [ -z "$(LC_ALL=C comm -23 "$1/requested.txt" "$CICA_SCRATCH/plan-sorted")" ]
}
cica_lane_results_ok() {
    awk -F '\t' '
        FNR == NR { plan[++n] = $0; next }
        FNR == 1 { if ($0 != "id\tstatus\telapsed_s") exit 1; next }
        { k++; if (NF != 3 || $1 != plan[k] || $2 != "0" || $3 !~ /^[0-9]+$/) exit 1 }
        END { if (k != n) exit 1 }' "$1/plan.txt" "$1/results.tsv" || cica_fail 'lane receipt does not prove every planned gate passed'
}
cica_owned_file() {
    case "$1" in
        "$CICA_ROOT"/target/*) cica_file "$CICA_ROOT" "${1#"$CICA_ROOT"/}" regular >/dev/null ;;
        *) cica_fail "$2 must be a regular file inside owned target/" ;;
    esac
}
cica_lane_handoff() {
    cica_owned_file "$2" 'handoff path file'
    read -r _lh_path < "$2" || true
    cica_owned_file "$_lh_path" "$1 handoff"
    printf '%s\t%s\n' "$1" "$(cica_sha "$_lh_path")" >> "$CICA_WORK/draft/lane/handoffs.tsv"
}
cica_checkout_ok() {
    ci_compiler_artifact_field_safe checkout "$1" || return 1
    case "$1" in /*) return 0 ;; *) return 1 ;; esac
}
cica_lane_receipt() {
    _lr=$CICA_WORK/draft/lane
    [ ! -e "$_lr/results.tsv" ] && [ ! -e "$_lr/handoffs.tsv" ] || cica_fail 'duplicate lane receipt'
    [ -s "$_lr/plan.txt" ] && cica_lane_ids_ok "$_lr" || cica_fail 'unsafe or empty lane plan'
    cica_owned_file "$1" results
    tr -d '\r' < "$1" > "$_lr/results.tsv"
    cica_lane_results_ok "$_lr"
    if [ "$2" != - ]; then
        cica_owned_file "$2" timing
        tr -d '\r' < "$2" > "$_lr/timing.tsv"
        [ "$(sed -n 1p "$_lr/timing.tsv")" = "$(printf 'gate\tcase_or_chunk\tphase\telapsed_ms\texit\thost')" ] || cica_fail 'timing header changed'
    fi
    # The converged compiler embeds the checkout path (its stdlib image
    # records it), so the aggregator requires one path for a host's lanes.
    cica_checkout_ok "$CICA_ROOT" || cica_fail 'unsafe checkout path'
    printf '%s\n' "$CICA_ROOT" > "$_lr/checkout.txt"
    : > "$_lr/handoffs.tsv"
    if grep -qxF bootstrap-fixpoint "$_lr/plan.txt"; then
        cica_lane_handoff previous-stage "$CICA_ROOT/target/ci-verify-stage1.path"
        cica_lane_handoff converged "$CICA_ROOT/target/ci-verify-stage2.path"
    fi
    if grep -qxF stage2-compile-profile-verifier "$_lr/plan.txt"; then
        cica_lane_handoff compile-profile "$CICA_ROOT/target/ci-verify-compile-profile-cli.path"
    fi
}
# cica_seal RESULTS TIMING|-: seal after ci-verify.sh returned success.
cica_seal() {
    cica_state
    _started=$(date +%s%3N)
    _d=$CICA_WORK/draft
    cica_lane_receipt "$1" "$2"
    cica_roles "$_d/lane/plan.txt" | LC_ALL=C sort > "$CICA_SCRATCH/roles"
    find "$_d/roles" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | LC_ALL=C sort > "$CICA_SCRATCH/actual-roles"
    cmp -s "$CICA_SCRATCH/roles" "$CICA_SCRATCH/actual-roles" || cica_fail 'missing/extra/partial roles'
    while IFS= read -r _role; do
        cica_json "$_d/roles/$_role/manifest.json"
        cica_jq -e --arg role "$_role" '.role==$role' "$_d/roles/$_role/manifest.json" >/dev/null || cica_fail 'wrong completed role'
        cica_jq -cn --arg role "$_role" --arg h "$(cica_sha "$_d/roles/$_role/manifest.json")" '{key:$role,value:$h}'
    done < "$CICA_SCRATCH/roles" > "$CICA_SCRATCH/role-hashes"
    cica_jq -sS from_entries "$CICA_SCRATCH/role-hashes" > "$CICA_SCRATCH/roles.json"
    cica_files "$_d" > "$CICA_SCRATCH/files.json"
    cica_file "$CICA_ROOT" "${CICA_WORK#"$CICA_ROOT"/}/complete" >/dev/null
    [ ! -e "$_d/bundle.json" ] && [ ! -e "$CICA_WORK/complete" ] || cica_fail 'duplicate bundle publication'
    cica_jq -nS --slurpfile c "$_d/context.json" --slurpfile r "$CICA_SCRATCH/roles.json" --slurpfile f "$CICA_SCRATCH/files.json" \
      '{schema:4,contract:"ci-compiler-artifact",context:$c[0],roles:$r[0],files:$f[0]}' > "$_d/bundle.json"
    _digest=$(cica_sha "$_d/bundle.json")
    mv "$_d" "$CICA_WORK/complete"
    printf '[ci-compiler-artifact] seal %sms\n' "$(($(date +%s%3N)-_started))" >&2
    printf 'envelope_sha=%s\n' "$_digest"
}

# JOBS lists every attempt's jobs of the run. The lane job's latest executed
# instance must be the context's attempt: a later attempt's instance counts
# only as a "Re-run failed jobs" copy (same start, completion and runner).
cica_verify_transport() {
    cica_jq -en --slurpfile c "$CICA_SCRATCH/context.json" --slurpfile jobs "$1" --slurpfile arts "$2" '
      def executed(j):
        if (j|length) > 1 and j[-1].started_at != null and j[-1].started_at == j[-2].started_at and
           j[-1].completed_at == j[-2].completed_at and j[-1].runner_name == j[-2].runner_name
        then executed(j[:-1]) else j[-1] end;
      $c[0] as $c |
      ([$jobs[0].jobs[]|select(.name==$c.job)]|sort_by(.run_attempt)) as $js |
      ("ci-stage-envelope-"+$c.lane+"-r"+$c.run_id+"-a"+($c.attempt|tostring)) as $artifact |
      [$arts[0].artifacts[]|select(.name==$artifact and .expired==false)] as $as |
      ($js|length)>=1 and ([$js[].run_attempt]|unique|length)==($js|length) and ($as|length)==1 and
      (executed($js) as $j | $as[0] as $a |
        $j.run_id==($c.run_id|tonumber) and $j.run_attempt==$c.attempt and $j.head_sha==$c.head and $j.status=="completed" and $j.conclusion=="success" and
        $a.workflow_run.id==($c.run_id|tonumber) and $a.workflow_run.head_sha==$c.head and ($a.digest|test("^sha256:[0-9a-f]{64}$")) and
        ($a.created_at|fromdateiso8601)>=($j.started_at|fromdateiso8601) and ($a.created_at|fromdateiso8601)<=($j.completed_at|fromdateiso8601))' >/dev/null || cica_fail 'producer/artifact attempt binding failed'
}
# The sealed lane receipt: exact file set, a valid plan and request, every
# planned gate passed, the timing header, and handoff hashes that equal the
# published compiler payloads.
cica_lane_verify() {
    _lv=$CICA_WORK/lane
    { printf '%s\n' checkout.txt handoffs.tsv plan.txt requested.txt results.tsv
      if [ "$1" = github ] || [ -f "$_lv/timing.tsv" ]; then printf '%s\n' timing.tsv; fi; } | LC_ALL=C sort > "$CICA_SCRATCH/lane-expected"
    (cd "$_lv" && find . -type f -print) | sed 's|^[.]/||' | LC_ALL=C sort > "$CICA_SCRATCH/lane-actual" || cica_fail 'lane receipt missing'
    cmp -s "$CICA_SCRATCH/lane-expected" "$CICA_SCRATCH/lane-actual" || cica_fail 'lane receipt file set changed'
    [ "$(wc -l < "$_lv/checkout.txt")" -eq 1 ] && cica_checkout_ok "$(cat "$_lv/checkout.txt")" || cica_fail 'malformed checkout path receipt'
    cica_lane_ids_ok "$_lv" || cica_fail 'unsafe lane plan or request outside the plan'
    cica_lane_results_ok "$_lv"
    [ ! -f "$_lv/timing.tsv" ] || [ "$(sed -n 1p "$_lv/timing.tsv")" = "$(printf 'gate\tcase_or_chunk\tphase\telapsed_ms\texit\thost')" ] || cica_fail 'timing header changed'
    { if grep -qxF bootstrap-fixpoint "$_lv/plan.txt"; then printf '%s\n' converged previous-stage; fi
      if grep -qxF stage2-compile-profile-verifier "$_lv/plan.txt"; then printf '%s\n' compile-profile; fi; } | LC_ALL=C sort > "$CICA_SCRATCH/handoffs-expected"
    awk -F '\t' 'NF != 2 || length($2) != 64 || $2 ~ /[^0-9a-f]/ || seen[$1]++ { exit 1 } { print $1 }' \
      "$_lv/handoffs.tsv" > "$CICA_SCRATCH/handoffs-names" || cica_fail 'malformed handoff receipt'
    LC_ALL=C sort "$CICA_SCRATCH/handoffs-names" > "$CICA_SCRATCH/handoffs-actual"
    cmp -s "$CICA_SCRATCH/handoffs-expected" "$CICA_SCRATCH/handoffs-actual" || cica_fail 'handoff receipt set changed'
    if grep -qxF bootstrap-fixpoint "$_lv/plan.txt"; then
        for _lv_pair in converged:compiler previous-stage:previous-stage; do
            _lv_name=${_lv_pair%%:*} _lv_payload=$CICA_WORK/roles/bootstrap-converged/payload/${_lv_pair#*:}
            [ -f "$_lv_payload" ] || cica_fail 'handoff payload missing'
            awk -F '\t' -v n="$_lv_name" -v h="$(cica_sha "$_lv_payload")" \
              '$1 == n { found = 1; if ($2 != h) bad = 1 } END { exit found && !bad ? 0 : 1 }' "$_lv/handoffs.tsv" ||
                cica_fail "$_lv_name handoff differs from its published payload"
        done
    fi
}
# cica_verify DIGEST MODE [JOBS ARTIFACTS LANE ATTEMPT]
cica_verify() {
    _readback_started=$(date +%s%3N)
    _expected=$1 _mode=$2; shift 2
    case "$_expected" in '' | *[!0-9a-f]*) cica_fail 'trusted bundle digest missing' ;; esac
    [ "${#_expected}" -eq 64 ] && [ "$(cica_sha "$CICA_WORK/bundle.json")" = "$_expected" ] || cica_fail 'bundle differs from producer job output'
    if [ "$_mode" = github ]; then
        [ "$#" -eq 4 ] || cica_fail 'github readback needs jobs, artifacts, lane and attempt'
        cica_context github "$3" "$4" > "$CICA_SCRATCH/context.json"
    else
        cica_context local > "$CICA_SCRATCH/context.json"
    fi
    cica_json "$CICA_WORK/bundle.json"
    cica_jq -e --slurpfile c "$CICA_SCRATCH/context.json" '.schema==4 and .contract=="ci-compiler-artifact" and .context==$c[0]' "$CICA_WORK/bundle.json" >/dev/null || cica_fail 'trusted workflow context mismatch'
    cica_files "$CICA_WORK" > "$CICA_SCRATCH/files.json"
    cica_jq -e --slurpfile f "$CICA_SCRATCH/files.json" '.files==$f[0]' "$CICA_WORK/bundle.json" >/dev/null || cica_fail 'missing/extra/corrupt bundle files'
    cica_lane_verify "$_mode"
    cica_roles "$CICA_WORK/lane/plan.txt" | LC_ALL=C sort > "$CICA_SCRATCH/roles"
    cica_jq -r '.roles|keys[]' "$CICA_WORK/bundle.json" | LC_ALL=C sort > "$CICA_SCRATCH/actual-roles"
    cmp -s "$CICA_SCRATCH/roles" "$CICA_SCRATCH/actual-roles" || cica_fail 'missing/extra roles'
    cica_sources > "$CICA_SCRATCH/source-set.sha256"
    cica_inventory > "$CICA_SCRATCH/inventory.json"
    cica_recipes > "$CICA_SCRATCH/recipes.json"
    while IFS= read -r _role; do
        _base=$CICA_WORK/roles/$_role _m=$CICA_WORK/roles/$_role/manifest.json
        cica_json "$_m"
        [ "$(cica_sha "$_m")" = "$(cica_jq -r --arg r "$_role" '.roles[$r]' "$CICA_WORK/bundle.json")" ] || cica_fail 'role manifest mismatch'
        cica_jq -S .fields "$_m" > "$CICA_SCRATCH/fields.json"
        [ "$(cica_key_json "$CICA_SCRATCH/fields.json")" = "$(cica_jq -r .provenance_key "$_m")" ] || cica_fail 'provenance key mismatch'
        cmp -s "$CICA_SCRATCH/source-set.sha256" "$_base/source-set.sha256" || cica_fail 'source-set substitution'
        cica_jq -e --slurpfile c "$CICA_SCRATCH/context.json" --slurpfile i "$CICA_SCRATCH/inventory.json" \
          --arg r "$_role" --arg h "$CICA_HOST" --arg s "$(cica_sha "$CICA_SCRATCH/source-set.sha256")" '
          .schema==4 and .contract=="ci-compiler-artifact" and .role==$r and .context==$c[0] and .inventory==$i[0] and
          .fields.producer_identity==$c[0].tree and (.fields.producer_sha256|test("^[0-9a-f]{64}$")) and .proof.input_producer_sha256==.fields.producer_sha256 and
          .fields.host==$h and .fields.target==$h+"-x86_64" and .fields.cwd=="{root}" and .fields.source_roots=="src,stdlib,tests" and
          .fields.source_set_sha256==$s and .fields.profile=="none" and
          .fields.stdlib_roots==(if $r=="bootstrap-converged" then "{root}/src" else "stdlib,src" end) and
          .fields.opt_level==(if $r=="bootstrap-converged" then "2" else "1" end) and
          .fields.output_kind==(if $r=="bootstrap-converged" then "compiler-binary" else "compiler-assembly" end)' "$_m" >/dev/null || cica_fail 'role/source/identity field substitution'
        cica_jq -nS --argjson a "$(cica_jq -r '.fields.argv' "$_m")" '{argv:$a}' > "$CICA_SCRATCH/argv.json"
        cica_flags "$_role" "$CICA_SCRATCH/argv.json"
        cica_jq -e '(.fields.argv|fromjson) as $a | .fields.cfg==([range(0;$a|length) as $i|select($a[$i]=="--cfg")|$a[$i+1]]|join(","))' "$_m" >/dev/null || cica_fail 'cfg field substitution'
        # The role index is exact, and the independently bound bundle index
        # already checked every hash and size. Recompute role-local entries too.
        cica_files "$_base" > "$CICA_SCRATCH/role-files-all.json"
        cica_jq -S 'del(."manifest.json",."source-set.sha256")' "$CICA_SCRATCH/role-files-all.json" > "$CICA_SCRATCH/role-files.json"
        cica_jq -e --slurpfile f "$CICA_SCRATCH/role-files.json" '.files==$f[0]' "$_m" >/dev/null || cica_fail 'role payload corrupt'
        if [ "$_role" = bootstrap-converged ]; then
            { printf '%s\n' payload/compiler payload/previous-stage; cica_generated | sed 's|^|generated/|'; } | LC_ALL=C sort > "$CICA_SCRATCH/role-paths"
        else printf '%s\n' inventory/corpus.txt payload/reference.s > "$CICA_SCRATCH/role-paths"; fi
        cica_jq -r '.files|keys[]' "$_m" | LC_ALL=C sort > "$CICA_SCRATCH/actual-role-paths"
        cmp -s "$CICA_SCRATCH/role-paths" "$CICA_SCRATCH/actual-role-paths" || cica_fail 'role payload set changed'
        cica_jq -e --slurpfile c "$CICA_SCRATCH/context.json" --slurpfile recipes "$CICA_SCRATCH/recipes.json" --slurpfile tools "$CICA_WORK/toolchain.json" '
          (.fields.environment|fromjson) as $e |
          $e.producer_commit==$c[0].commit and $e.producer_version==("typelisp "+$c[0].commit+" built unknown") and
          $e.recipes==$recipes[0] and $e.toolchain==$tools[0] and $e.seed==.proof.seed and
          ($e.variables_sha256|test("^[0-9a-f]{64}$")) and ($e.resource_wrapper|type)=="array" and
          $e.generated_inputs==(.files|with_entries(select(.key|startswith("generated/")))) and
          (.proof.invocation_record as $r | $r.argv==(.fields.argv|fromjson) and $r.producer_sha256==.fields.producer_sha256 and $r.producer_identity==.fields.producer_identity and
           $r.producer_version==$e.producer_version and $r.variables_sha256==$e.variables_sha256 and $r.wrapper==$e.resource_wrapper)' "$_m" >/dev/null || cica_fail 'environment/generated/recipe substitution'
        if [ "$_role" = bootstrap-converged ]; then
            cica_binary "$_base/payload/compiler"; cica_binary "$_base/payload/previous-stage"
            cica_jq -e --slurpfile c "$CICA_SCRATCH/context.json" '
              def assembly_proof: type=="object" and (.sha256|type=="string" and test("^[0-9a-f]{64}$")) and (.bytes|type=="number" and .>0 and floor==.);
              .proof as $p |
              ($p.selected_stage=="stage3" or $p.selected_stage=="stage4") and $p.output_identity==$c[0].tree and
              ($p.seed.sha256|test("^[0-9a-f]{64}$")) and ($p.seed.identity|test("^[0-9a-f]{40}$")) and
              $p.fixpoint_pair==(if $p.selected_stage=="stage3" then ["stage2.s","stage3.s"] else ["stage3.s","stage4.s"] end) and
              ([$p.fixpoint_pair[],"stage3.s","stage3-embedded.s"]|all(.[]; $p[.]|assembly_proof)) and
              ($p.compile_receipt|assembly_proof) and $p.compile_receipt==$p.invocation_record.compiled_output and
              $p[$p.fixpoint_pair[0]].sha256==$p[$p.fixpoint_pair[1]].sha256 and $p["stage3.s"].sha256==$p["stage3-embedded.s"].sha256 and
              $p.compile_receipt.sha256==$p[$p.selected_stage+".s"].sha256 and $p.compile_receipt.bytes==$p[$p.selected_stage+".s"].bytes and
              $p.compile_receipt.path==("{root}/target/bootstrap-fixpoint/"+$p.selected_stage+".s")' "$_m" >/dev/null || cica_fail 'fixpoint/parity proof incomplete'
            [ "$(cat "$_base/generated/target/build-stage0/git-hash.txt")" = "$(cica_jq -r .commit "$CICA_SCRATCH/context.json")" ] && \
              [ "$(cat "$_base/generated/target/build-stage0/tree-hash.txt")" = "$(cica_jq -r .tree "$CICA_SCRATCH/context.json")" ] || cica_fail 'generated stamps differ'
        else
            cica_corpus > "$CICA_SCRATCH/corpus"
            cmp -s "$CICA_SCRATCH/corpus" "$_base/inventory/corpus.txt" || cica_fail 'reference inventory incomplete'
            cica_jq -e --slurpfile b "$CICA_WORK/roles/bootstrap-converged/manifest.json" '
              .proof.compared_output_sha256==.files["payload/reference.s"].sha256 and
              .fields.producer_sha256==$b[0].files["payload/compiler"].sha256 and .proof.seed==$b[0].proof.seed and
              .proof.parent_provenance_key==$b[0].provenance_key and
              .proof.batch_manifest=="src/main.tl|{root}/target/build-invariance/compare/opt2-built/selfhost_main_opt1.s\n"' "$_m" >/dev/null || cica_fail 'reference producer/comparison proof substituted'
        fi
    done < "$CICA_SCRATCH/roles"
    [ "$_mode" != github ] || cica_verify_transport "$1" "$2"
    cica_jq -nS --arg h "$CICA_HOST" --arg d "$_expected" --argjson ms "$(($(date +%s%3N)-_readback_started))" --slurpfile c "$CICA_SCRATCH/context.json" '{schema:4,host:$h,lane:$c[0].lane,context:$c[0],bundle_sha256:$d,readback_ms:$ms,status:"ok"}'
}
ci_compiler_artifact() (
    set -eu
    _operation=$1; shift
    if [ "$_operation" = key ]; then ci_compiler_artifact_key "$@"; exit; fi
    CICA_ROOT=$1 CICA_WORK=$2; shift 2
    case "$1" in linux | Linux) CICA_HOST=linux ;; windows | Windows) CICA_HOST=windows ;; *) cica_fail 'unsupported host' ;; esac
    shift
    CICA_ROOT=$(CDPATH= cd -- "$CICA_ROOT" && pwd -P)
    cd "$CICA_ROOT"
    cica_owned "$CICA_ROOT" "$CICA_WORK"
    mkdir -p "$CICA_ROOT/target/exp"
    cica_file "$CICA_ROOT" target/exp >/dev/null
    CICA_SCRATCH=$(mktemp -d "$CICA_ROOT/target/exp/ci-compiler-envelope.XXXXXX")
    case "$_operation" in
      init) cica_init github "$@" ;;
      init-local) cica_init local "$@" ;;
      record) cica_record "$@" ;;
      publish) cica_publish "$@" ;;
      seal) [ "$#" -eq 2 ] || cica_fail 'seal needs results and timing (or -)'; cica_seal "$@" ;;
      verify) [ "$#" -eq 5 ] || cica_fail 'verify needs digest, jobs, artifacts, lane and attempt'; cica_verify "$1" github "$2" "$3" "$4" "$5" ;;
      verify-local) cica_verify "$1" local ;;
      *) cica_fail 'unknown envelope operation' ;;
    esac
)
