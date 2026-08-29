#!/usr/bin/env sh

# Provenance-keyed, same-run compiler artifact handoffs for ci-verify.sh.
#
# Source this file.  The functions are POSIX sh and deliberately keep the
# metadata human-readable: a consumer validates every input field, the
# provenance key, and the current producer/output digests before it runs.

ci_compiler_artifact_error() {
    echo "[ci-compiler-artifact] $*" >&2
    return 1
}

ci_compiler_artifact_host() {
    case "$(uname -s)" in
        Linux*) printf '%s\n' linux ;;
        MINGW* | MSYS* | CYGWIN*) printf '%s\n' windows ;;
        *) ci_compiler_artifact_error "unsupported host: $(uname -s)" ;;
    esac
}

ci_compiler_artifact_sha256_file() {
    _cica_sha_file=$1
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$_cica_sha_file" | awk '{ print $1 }'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$_cica_sha_file" | awk '{ print $1 }'
    else
        ci_compiler_artifact_error "sha256sum or shasum is required"
    fi
}

ci_compiler_artifact_sha256_stdin() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{ print $1 }'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | awk '{ print $1 }'
    else
        ci_compiler_artifact_error "sha256sum or shasum is required"
    fi
}

ci_compiler_artifact_field_safe() {
    _cica_safe_name=$1
    _cica_safe_value=$2
    if printf '%s' "$_cica_safe_value" | \
        LC_ALL=C grep -q '[[:cntrl:]]'; then
        ci_compiler_artifact_error \
            "$_cica_safe_name contains a control character"
        return 1
    fi
    return 0
}

ci_compiler_artifact_absolute_path() {
    _cica_abs_root=$1
    _cica_abs_path=$2
    case "$_cica_abs_path" in
        /* | [A-Za-z]:[/\\]*) printf '%s\n' "$_cica_abs_path" ;;
        *) printf '%s/%s\n' "$_cica_abs_root" "$_cica_abs_path" ;;
    esac
}

ci_compiler_artifact_normalized_path() {
    _cica_norm_root=$(printf '%s' "$1" | tr '\\' '/')
    _cica_norm_path=$(printf '%s' "$2" | tr '\\' '/')
    case "$_cica_norm_path" in
        "$_cica_norm_root") printf '%s\n' '{root}' ;;
        "$_cica_norm_root"/*)
            printf '{root}/%s\n' "${_cica_norm_path#"$_cica_norm_root"/}"
            ;;
        *) printf '%s\n' "$_cica_norm_path" ;;
    esac
}

ci_compiler_artifact_producer_identity() {
    _cica_identity_compiler=$1
    _cica_identity=$(
        "$_cica_identity_compiler" --producer-identity 2>/dev/null || true
    )
    if ! printf '%s\n' "$_cica_identity" | grep -Eq '^[0-9a-f]{40}$'; then
        _cica_identity=$(
            "$_cica_identity_compiler" --version 2>/dev/null |
                awk 'NR == 1 && $1 == "typelisp" { print $2 }' || true
        )
    fi
    if ! printf '%s\n' "$_cica_identity" | grep -Eq '^[0-9a-f]{40}$'; then
        ci_compiler_artifact_error \
            "producer reported a malformed identity: $_cica_identity_compiler"
        return 1
    fi
    printf '%s\n' "$_cica_identity"
}

# Hash a conservative source-set superset.  PATHS is a comma-separated list of
# files/directories relative to ROOT (absolute paths are accepted for isolated
# mutation fixtures).  File names and content hashes are both covered.
ci_compiler_artifact_source_set_digest() {
    _cica_source_root=$1
    _cica_source_paths=$2
    _cica_source_tmp=$(mktemp -d "${TMPDIR:-/tmp}/typelisp-ci-artifact.XXXXXX") ||
        return 1
    _cica_source_list="$_cica_source_tmp/files"
    _cica_source_hashes="$_cica_source_tmp/hashes"
    _cica_source_manifest="$_cica_source_tmp/manifest"
    : > "$_cica_source_list"

    # GitHub's Windows runner pays tens of milliseconds for every Git Bash
    # process launch.  Hashing a compiler source tree one file at a time can
    # therefore take more than a minute.  GNU/Git coreutils can hash the same
    # sorted NUL-delimited list in a bounded number of processes while keeping
    # the byte-for-byte manifest shape used by the portable fallback below.
    _cica_source_batch=0
    if command -v sha256sum >/dev/null 2>&1 &&
        sort -z </dev/null >/dev/null 2>&1 &&
        xargs -0 printf '' </dev/null >/dev/null 2>&1; then
        _cica_source_batch=1
    fi

    _cica_source_old_ifs=$IFS
    IFS=,
    for _cica_source_entry in $_cica_source_paths; do
        IFS=$_cica_source_old_ifs
        if [ -z "$_cica_source_entry" ]; then
            rm -rf "$_cica_source_tmp"
            ci_compiler_artifact_error "source-set path list contains an empty entry"
            return 1
        fi
        _cica_source_abs=$(ci_compiler_artifact_absolute_path \
            "$_cica_source_root" "$_cica_source_entry") || {
            rm -rf "$_cica_source_tmp"
            return 1
        }
        if [ -d "$_cica_source_abs" ]; then
            if [ "$_cica_source_batch" -eq 1 ]; then
                find "$_cica_source_abs" -type f -print0 \
                    >> "$_cica_source_list"
            else
                find "$_cica_source_abs" -type f -print \
                    >> "$_cica_source_list"
            fi
        elif [ -f "$_cica_source_abs" ]; then
            if [ "$_cica_source_batch" -eq 1 ]; then
                printf '%s\0' "$_cica_source_abs" >> "$_cica_source_list"
            else
                printf '%s\n' "$_cica_source_abs" >> "$_cica_source_list"
            fi
        else
            rm -rf "$_cica_source_tmp"
            ci_compiler_artifact_error \
                "source-set input is missing: $_cica_source_entry"
            return 1
        fi
        IFS=,
    done
    IFS=$_cica_source_old_ifs

    : > "$_cica_source_manifest"
    if [ "$_cica_source_batch" -eq 1 ]; then
        LC_ALL=C sort -zu "$_cica_source_list" -o "$_cica_source_list"
        if [ -s "$_cica_source_list" ]; then
            xargs -0 sha256sum < "$_cica_source_list" \
                > "$_cica_source_hashes" || {
                rm -rf "$_cica_source_tmp"
                return 1
            }
        else
            : > "$_cica_source_hashes"
        fi
        _cica_source_normalized_root=$(printf '%s' "$_cica_source_root" | \
            tr '\\' '/')
        awk -v root="$_cica_source_normalized_root" '
        {
            hash = substr($0, 1, 64)
            path = substr($0, 67)
            gsub(/\\/, "/", path)
            if (path == root) path = "{root}"
            else if (index(path, root "/") == 1)
                path = "{root}/" substr(path, length(root) + 2)
            print hash "  " path
        }
        ' "$_cica_source_hashes" > "$_cica_source_manifest" || {
            rm -rf "$_cica_source_tmp"
            return 1
        }
    else
        LC_ALL=C sort -u "$_cica_source_list" -o "$_cica_source_list"
        while IFS= read -r _cica_source_file; do
            _cica_source_name=$(ci_compiler_artifact_normalized_path \
                "$_cica_source_root" "$_cica_source_file") || {
                rm -rf "$_cica_source_tmp"
                return 1
            }
            _cica_source_hash=$(ci_compiler_artifact_sha256_file \
                "$_cica_source_file") || {
                rm -rf "$_cica_source_tmp"
                return 1
            }
            printf '%s  %s\n' "$_cica_source_hash" "$_cica_source_name" \
                >> "$_cica_source_manifest"
        done < "$_cica_source_list"
    fi

    _cica_source_digest=$(ci_compiler_artifact_sha256_file \
        "$_cica_source_manifest") || {
        rm -rf "$_cica_source_tmp"
        return 1
    }
    rm -rf "$_cica_source_tmp"
    printf '%s\n' "$_cica_source_digest"
}

ci_compiler_artifact_write_sha256_manifest() {
    _cica_manifest_root=$1
    _cica_manifest_tree=$2
    _cica_manifest_output=$3
    [ -d "$_cica_manifest_tree" ] || {
        ci_compiler_artifact_error \
            "artifact tree is missing: $_cica_manifest_tree"
        return 1
    }
    mkdir -p "$(dirname -- "$_cica_manifest_output")"
    _cica_manifest_list="$_cica_manifest_output.files.$$"
    _cica_manifest_tmp="$_cica_manifest_output.tmp.$$"
    find "$_cica_manifest_tree" -type f -name '*.s' -print | \
        LC_ALL=C sort > "$_cica_manifest_list"
    [ -s "$_cica_manifest_list" ] || {
        rm -f "$_cica_manifest_list"
        ci_compiler_artifact_error \
            "artifact tree contains no assembly: $_cica_manifest_tree"
        return 1
    }
    : > "$_cica_manifest_tmp"
    while IFS= read -r _cica_manifest_file; do
        _cica_manifest_hash=$(ci_compiler_artifact_sha256_file \
            "$_cica_manifest_file") || {
            rm -f "$_cica_manifest_list" "$_cica_manifest_tmp"
            return 1
        }
        _cica_manifest_path=$(ci_compiler_artifact_normalized_path \
            "$_cica_manifest_root" "$_cica_manifest_file") || {
            rm -f "$_cica_manifest_list" "$_cica_manifest_tmp"
            return 1
        }
        printf '%s  %s\n' "$_cica_manifest_hash" "$_cica_manifest_path" \
            >> "$_cica_manifest_tmp"
    done < "$_cica_manifest_list"
    rm -f "$_cica_manifest_list"
    mv "$_cica_manifest_tmp" "$_cica_manifest_output"
}

ci_compiler_artifact_write_files_manifest() {
    _cica_files_root=$1
    _cica_files_output=$2
    shift 2
    [ "$#" -gt 0 ] || {
        ci_compiler_artifact_error "artifact file manifest has no inputs"
        return 1
    }
    mkdir -p "$(dirname -- "$_cica_files_output")"
    _cica_files_tmp="$_cica_files_output.tmp.$$"
    : > "$_cica_files_tmp"
    for _cica_files_file in "$@"; do
        [ -s "$_cica_files_file" ] || {
            rm -f "$_cica_files_tmp"
            ci_compiler_artifact_error \
                "manifest artifact is missing or empty: $_cica_files_file"
            return 1
        }
        _cica_files_hash=$(ci_compiler_artifact_sha256_file \
            "$_cica_files_file") || {
            rm -f "$_cica_files_tmp"
            return 1
        }
        _cica_files_path=$(ci_compiler_artifact_normalized_path \
            "$_cica_files_root" "$_cica_files_file") || {
            rm -f "$_cica_files_tmp"
            return 1
        }
        printf '%s  %s\n' "$_cica_files_hash" "$_cica_files_path" \
            >> "$_cica_files_tmp"
    done
    LC_ALL=C sort -u "$_cica_files_tmp" -o "$_cica_files_tmp"
    mv "$_cica_files_tmp" "$_cica_files_output"
}

ci_compiler_artifact_verify_sha256_manifest() {
    _cica_verify_root=$1
    _cica_verify_manifest=$2
    [ -s "$_cica_verify_manifest" ] || {
        ci_compiler_artifact_error \
            "artifact digest manifest is missing or empty: $_cica_verify_manifest"
        return 1
    }
    _cica_verify_failed=0
    while IFS='  ' read -r _cica_verify_hash _cica_verify_path; do
        [ -n "$_cica_verify_hash" ] && [ -n "$_cica_verify_path" ] || {
            ci_compiler_artifact_error \
                "malformed artifact digest manifest: $_cica_verify_manifest"
            return 1
        }
        case "$_cica_verify_path" in
            '{root}') _cica_verify_file=$_cica_verify_root ;;
            '{root}/'*)
                _cica_verify_file="$_cica_verify_root/${_cica_verify_path#'{root}/'}"
                ;;
            *) _cica_verify_file=$_cica_verify_path ;;
        esac
        if [ ! -s "$_cica_verify_file" ]; then
            ci_compiler_artifact_error \
                "manifest artifact is missing or empty: $_cica_verify_path"
            _cica_verify_failed=1
            continue
        fi
        _cica_verify_actual=$(ci_compiler_artifact_sha256_file \
            "$_cica_verify_file") || return 1
        if [ "$_cica_verify_actual" != "$_cica_verify_hash" ]; then
            ci_compiler_artifact_error \
                "manifest artifact digest mismatch: $_cica_verify_path"
            _cica_verify_failed=1
        fi
    done < "$_cica_verify_manifest"
    [ "$_cica_verify_failed" -eq 0 ]
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

ci_compiler_artifact_trace_init() {
    _cica_trace_file=$1
    mkdir -p "$(dirname -- "$_cica_trace_file")"
    printf '%s\n' \
        'schema	role	record_id	provenance_key	producer_identity	producer_sha256	host	target	cwd	source_roots	stdlib_roots	cfg	opt_level	profile	environment	argv	source_set_sha256	output_kind	output_path	output_sha256' \
        > "$_cica_trace_file"
}

ci_compiler_artifact_trace_append() {
    _cica_trace_file=$1
    _cica_trace_role=$2
    _cica_trace_record_id=$3
    shift 3
    [ -n "$_cica_trace_file" ] || return 0
    if [ ! -f "$_cica_trace_file" ]; then
        ci_compiler_artifact_trace_init "$_cica_trace_file" || return 1
    fi
    case "$_cica_trace_role" in
        produce | consume) ;;
        *)
            ci_compiler_artifact_error \
                "invalid trace role: $_cica_trace_role"
            return 1
            ;;
    esac
    [ -n "$_cica_trace_record_id" ] || {
        ci_compiler_artifact_error "trace record ID is empty"
        return 1
    }
    for _cica_trace_value in \
        "$_cica_trace_role" "$_cica_trace_record_id" "$@"; do
        ci_compiler_artifact_field_safe trace "$_cica_trace_value" || return 1
    done
    printf '2\t%s\t%s' "$_cica_trace_role" "$_cica_trace_record_id" \
        >> "$_cica_trace_file"
    for _cica_trace_value in "$@"; do
        printf '\t%s' "$_cica_trace_value" >> "$_cica_trace_file"
    done
    printf '\n' >> "$_cica_trace_file"
}

# A producer script can keep its standalone build path by publishing only when
# both path and metadata destinations are supplied.  A half-configured handoff
# is always an error rather than silently falling back.
ci_compiler_artifact_handoff_requested() {
    _cica_requested_path=${1:-}
    _cica_requested_metadata=${2:-}
    if [ -z "$_cica_requested_path" ] && [ -z "$_cica_requested_metadata" ]; then
        return 1
    fi
    if [ -z "$_cica_requested_path" ] || [ -z "$_cica_requested_metadata" ]; then
        ci_compiler_artifact_error \
            "handoff path and metadata destinations must be supplied together"
        return 2
    fi
    return 0
}

# publish ROOT METADATA PATH_FILE LABEL PRODUCER TARGET CFG OPT PROFILE
#         SOURCE_ROOTS STDLIB_ROOTS ENVIRONMENT OUTPUT_KIND OUTPUT ARGV
ci_compiler_artifact_publish() {
    if [ "$#" -ne 15 ]; then
        ci_compiler_artifact_error "publish expects 15 arguments, got $#"
        return 2
    fi
    _cica_pub_root=$1
    _cica_pub_metadata=$2
    _cica_pub_path_file=$3
    _cica_pub_label=$4
    _cica_pub_producer=$5
    _cica_pub_target=$6
    _cica_pub_cfg=$7
    _cica_pub_opt=$8
    _cica_pub_profile=$9
    shift 9
    _cica_pub_source_roots=$1
    _cica_pub_stdlib_roots=$2
    _cica_pub_environment=$3
    _cica_pub_output_kind=$4
    _cica_pub_output=$5
    _cica_pub_argv=$6

    _cica_pub_run_token=${TYPELISP_CI_COMPILER_ARTIFACT_RUN_TOKEN:-}
    [ -n "$_cica_pub_run_token" ] || {
        ci_compiler_artifact_error "same-run token is unset"
        return 2
    }
    for _cica_pub_pair in \
        "label:$_cica_pub_label" \
        "target:$_cica_pub_target" \
        "cfg:$_cica_pub_cfg" \
        "opt_level:$_cica_pub_opt" \
        "profile:$_cica_pub_profile" \
        "source_roots:$_cica_pub_source_roots" \
        "stdlib_roots:$_cica_pub_stdlib_roots" \
        "environment:$_cica_pub_environment" \
        "output_kind:$_cica_pub_output_kind" \
        "argv:$_cica_pub_argv" \
        "run_token:$_cica_pub_run_token"; do
        _cica_pub_name=${_cica_pub_pair%%:*}
        _cica_pub_value=${_cica_pub_pair#*:}
        [ -n "$_cica_pub_value" ] || {
            ci_compiler_artifact_error "$_cica_pub_name is empty"
            return 2
        }
        ci_compiler_artifact_field_safe \
            "$_cica_pub_name" "$_cica_pub_value" || return 2
    done
    [ -x "$_cica_pub_producer" ] || {
        ci_compiler_artifact_error \
            "producer is missing or not executable: $_cica_pub_producer"
        return 1
    }
    [ -s "$_cica_pub_output" ] || {
        ci_compiler_artifact_error \
            "producer output is missing or empty: $_cica_pub_output"
        return 1
    }

    _cica_pub_host=$(ci_compiler_artifact_host) || return 1
    _cica_pub_producer_sha=$(ci_compiler_artifact_sha256_file \
        "$_cica_pub_producer") || return 1
    _cica_pub_producer_identity=$(ci_compiler_artifact_producer_identity \
        "$_cica_pub_producer") || return 1
    _cica_pub_source_digest=$(ci_compiler_artifact_source_set_digest \
        "$_cica_pub_root" "$_cica_pub_source_roots") || return 1
    _cica_pub_cwd=$(ci_compiler_artifact_normalized_path \
        "$_cica_pub_root" "$_cica_pub_root") || return 1
    _cica_pub_producer_path=$(ci_compiler_artifact_normalized_path \
        "$_cica_pub_root" "$_cica_pub_producer") || return 1
    _cica_pub_output_path=$(ci_compiler_artifact_normalized_path \
        "$_cica_pub_root" "$_cica_pub_output") || return 1
    _cica_pub_output_sha=$(ci_compiler_artifact_sha256_file \
        "$_cica_pub_output") || return 1
    _cica_pub_key=$(ci_compiler_artifact_key \
        "$_cica_pub_producer_sha" "$_cica_pub_producer_identity" \
        "$_cica_pub_host" "$_cica_pub_target" "$_cica_pub_cwd" \
        "$_cica_pub_source_roots" "$_cica_pub_stdlib_roots" \
        "$_cica_pub_cfg" "$_cica_pub_opt" "$_cica_pub_profile" \
        "$_cica_pub_environment" "$_cica_pub_argv" \
        "$_cica_pub_source_digest" "$_cica_pub_output_kind") || return 1

    mkdir -p "$(dirname -- "$_cica_pub_metadata")" \
        "$(dirname -- "$_cica_pub_path_file")"
    _cica_pub_metadata_tmp="$_cica_pub_metadata.tmp.$$"
    _cica_pub_path_tmp="$_cica_pub_path_file.tmp.$$"
    {
        printf 'schema=1\n'
        printf 'label=%s\n' "$_cica_pub_label"
        printf 'run_token=%s\n' "$_cica_pub_run_token"
        printf 'provenance_key=%s\n' "$_cica_pub_key"
        printf 'producer_path=%s\n' "$_cica_pub_producer_path"
        printf 'producer_identity=%s\n' "$_cica_pub_producer_identity"
        printf 'producer_sha256=%s\n' "$_cica_pub_producer_sha"
        printf 'host=%s\n' "$_cica_pub_host"
        printf 'target=%s\n' "$_cica_pub_target"
        printf 'cwd=%s\n' "$_cica_pub_cwd"
        printf 'source_roots=%s\n' "$_cica_pub_source_roots"
        printf 'stdlib_roots=%s\n' "$_cica_pub_stdlib_roots"
        printf 'cfg=%s\n' "$_cica_pub_cfg"
        printf 'opt_level=%s\n' "$_cica_pub_opt"
        printf 'profile=%s\n' "$_cica_pub_profile"
        printf 'environment=%s\n' "$_cica_pub_environment"
        printf 'argv=%s\n' "$_cica_pub_argv"
        printf 'source_set_sha256=%s\n' "$_cica_pub_source_digest"
        printf 'output_kind=%s\n' "$_cica_pub_output_kind"
        printf 'output_path=%s\n' "$_cica_pub_output_path"
        printf 'output_sha256=%s\n' "$_cica_pub_output_sha"
    } > "$_cica_pub_metadata_tmp"
    printf '%s\n' "$_cica_pub_output" > "$_cica_pub_path_tmp"
    # Metadata is the commit marker for the two-file handoff.  Removing an old
    # marker and publishing it last ensures an interrupted update leaves either
    # the prior pair (before this block) or an unusable path-only half-pair.
    rm -f "$_cica_pub_metadata"
    mv "$_cica_pub_path_tmp" "$_cica_pub_path_file"
    mv "$_cica_pub_metadata_tmp" "$_cica_pub_metadata"

    ci_compiler_artifact_trace_append \
        "${TYPELISP_CI_COMPILER_ARTIFACT_TRACE:-}" \
        produce "$_cica_pub_label" "$_cica_pub_key" \
        "$_cica_pub_producer_identity" "$_cica_pub_producer_sha" \
        "$_cica_pub_host" "$_cica_pub_target" "$_cica_pub_cwd" \
        "$_cica_pub_source_roots" "$_cica_pub_stdlib_roots" \
        "$_cica_pub_cfg" "$_cica_pub_opt" "$_cica_pub_profile" \
        "$_cica_pub_environment" "$_cica_pub_argv" \
        "$_cica_pub_source_digest" "$_cica_pub_output_kind" \
        "$_cica_pub_output_path" "$_cica_pub_output_sha"
}

ci_compiler_artifact_read_field() {
    _cica_read_file=$1
    _cica_read_key=$2
    _cica_read_count=$(awk -F= -v key="$_cica_read_key" '$1 == key { count++ } END { print count + 0 }' \
        "$_cica_read_file")
    if [ "$_cica_read_count" -ne 1 ]; then
        ci_compiler_artifact_error \
            "metadata field $_cica_read_key occurs $_cica_read_count times"
        return 1
    fi
    awk -v key="$_cica_read_key=" \
        'index($0, key) == 1 { print substr($0, length(key) + 1) }' \
        "$_cica_read_file"
}

ci_compiler_artifact_expect_field() {
    _cica_expect_file=$1
    _cica_expect_name=$2
    _cica_expect_value=$3
    _cica_expect_actual=$(ci_compiler_artifact_read_field \
        "$_cica_expect_file" "$_cica_expect_name") || return 1
    if [ "$_cica_expect_actual" != "$_cica_expect_value" ]; then
        ci_compiler_artifact_error \
            "$_cica_expect_name mismatch: expected $_cica_expect_value, got $_cica_expect_actual"
        return 1
    fi
}

# require adds a consumer record ID after LABEL to the 15 publish arguments.
# OUTPUT is ignored in favor of the path file and may be written as '-'. The
# consumer ID is trace-only; every provenance input retains the publish shape.
ci_compiler_artifact_require() {
    if [ "$#" -ne 16 ]; then
        ci_compiler_artifact_error "require expects 16 arguments, got $#"
        return 2
    fi
    _cica_req_root=$1
    _cica_req_metadata=$2
    _cica_req_path_file=$3
    _cica_req_label=$4
    _cica_req_consumer_record_id=$5
    _cica_req_producer=$6
    _cica_req_target=$7
    _cica_req_cfg=$8
    _cica_req_opt=$9
    shift 9
    _cica_req_profile=$1
    _cica_req_source_roots=$2
    _cica_req_stdlib_roots=$3
    _cica_req_environment=$4
    _cica_req_output_kind=$5
    _cica_req_ignored_output=$6
    _cica_req_argv=$7
    : "$_cica_req_ignored_output"

    [ -s "$_cica_req_metadata" ] || {
        ci_compiler_artifact_error \
            "handoff metadata is missing or empty: $_cica_req_metadata"
        return 1
    }
    [ -s "$_cica_req_path_file" ] || {
        ci_compiler_artifact_error \
            "handoff path file is missing or empty: $_cica_req_path_file"
        return 1
    }
    if [ "$(wc -l < "$_cica_req_path_file" | tr -d ' ')" -ne 1 ]; then
        ci_compiler_artifact_error \
            "handoff path file must contain exactly one path: $_cica_req_path_file"
        return 1
    fi
    _cica_req_output=$(sed -n '1p' "$_cica_req_path_file")
    [ -s "$_cica_req_output" ] || {
        ci_compiler_artifact_error \
            "handoff artifact is missing or empty: $_cica_req_output"
        return 1
    }
    [ -x "$_cica_req_producer" ] || {
        ci_compiler_artifact_error \
            "producer is missing or not executable: $_cica_req_producer"
        return 1
    }

    _cica_req_run_token=${TYPELISP_CI_COMPILER_ARTIFACT_RUN_TOKEN:-}
    [ -n "$_cica_req_run_token" ] || {
        ci_compiler_artifact_error "same-run token is unset"
        return 2
    }
    _cica_req_host=$(ci_compiler_artifact_host) || return 1
    _cica_req_producer_sha=$(ci_compiler_artifact_sha256_file \
        "$_cica_req_producer") || return 1
    _cica_req_producer_identity=$(ci_compiler_artifact_producer_identity \
        "$_cica_req_producer") || return 1
    _cica_req_source_digest=$(ci_compiler_artifact_source_set_digest \
        "$_cica_req_root" "$_cica_req_source_roots") || return 1
    _cica_req_cwd=$(ci_compiler_artifact_normalized_path \
        "$_cica_req_root" "$_cica_req_root") || return 1
    _cica_req_producer_path=$(ci_compiler_artifact_normalized_path \
        "$_cica_req_root" "$_cica_req_producer") || return 1
    _cica_req_output_path=$(ci_compiler_artifact_normalized_path \
        "$_cica_req_root" "$_cica_req_output") || return 1
    _cica_req_output_sha=$(ci_compiler_artifact_sha256_file \
        "$_cica_req_output") || return 1
    _cica_req_key=$(ci_compiler_artifact_key \
        "$_cica_req_producer_sha" "$_cica_req_producer_identity" \
        "$_cica_req_host" "$_cica_req_target" "$_cica_req_cwd" \
        "$_cica_req_source_roots" "$_cica_req_stdlib_roots" \
        "$_cica_req_cfg" "$_cica_req_opt" "$_cica_req_profile" \
        "$_cica_req_environment" "$_cica_req_argv" \
        "$_cica_req_source_digest" "$_cica_req_output_kind") || return 1

    ci_compiler_artifact_expect_field "$_cica_req_metadata" schema 1 || return 1
    ci_compiler_artifact_expect_field \
        "$_cica_req_metadata" label "$_cica_req_label" || return 1
    ci_compiler_artifact_expect_field \
        "$_cica_req_metadata" run_token "$_cica_req_run_token" || return 1
    ci_compiler_artifact_expect_field \
        "$_cica_req_metadata" host "$_cica_req_host" || return 1
    ci_compiler_artifact_expect_field \
        "$_cica_req_metadata" target "$_cica_req_target" || return 1
    ci_compiler_artifact_expect_field \
        "$_cica_req_metadata" cfg "$_cica_req_cfg" || return 1
    ci_compiler_artifact_expect_field \
        "$_cica_req_metadata" opt_level "$_cica_req_opt" || return 1
    ci_compiler_artifact_expect_field \
        "$_cica_req_metadata" profile "$_cica_req_profile" || return 1
    ci_compiler_artifact_expect_field \
        "$_cica_req_metadata" cwd "$_cica_req_cwd" || return 1
    ci_compiler_artifact_expect_field \
        "$_cica_req_metadata" source_roots "$_cica_req_source_roots" || return 1
    ci_compiler_artifact_expect_field \
        "$_cica_req_metadata" stdlib_roots "$_cica_req_stdlib_roots" || return 1
    ci_compiler_artifact_expect_field \
        "$_cica_req_metadata" environment "$_cica_req_environment" || return 1
    ci_compiler_artifact_expect_field \
        "$_cica_req_metadata" argv "$_cica_req_argv" || return 1
    ci_compiler_artifact_expect_field \
        "$_cica_req_metadata" output_kind "$_cica_req_output_kind" || return 1
    ci_compiler_artifact_expect_field \
        "$_cica_req_metadata" producer_path "$_cica_req_producer_path" || return 1
    ci_compiler_artifact_expect_field \
        "$_cica_req_metadata" producer_identity \
        "$_cica_req_producer_identity" || return 1
    ci_compiler_artifact_expect_field \
        "$_cica_req_metadata" producer_sha256 "$_cica_req_producer_sha" || return 1
    ci_compiler_artifact_expect_field \
        "$_cica_req_metadata" source_set_sha256 \
        "$_cica_req_source_digest" || return 1
    ci_compiler_artifact_expect_field \
        "$_cica_req_metadata" output_path "$_cica_req_output_path" || return 1
    ci_compiler_artifact_expect_field \
        "$_cica_req_metadata" output_sha256 "$_cica_req_output_sha" || return 1
    ci_compiler_artifact_expect_field \
        "$_cica_req_metadata" provenance_key "$_cica_req_key" || return 1

    _cica_req_lines=$(wc -l < "$_cica_req_metadata" | tr -d ' ')
    if [ "$_cica_req_lines" -ne 21 ]; then
        ci_compiler_artifact_error \
            "handoff metadata has $_cica_req_lines lines; expected 21"
        return 1
    fi
    ci_compiler_artifact_trace_append \
        "${TYPELISP_CI_COMPILER_ARTIFACT_TRACE:-}" \
        consume "$_cica_req_consumer_record_id" "$_cica_req_key" \
        "$_cica_req_producer_identity" "$_cica_req_producer_sha" \
        "$_cica_req_host" "$_cica_req_target" "$_cica_req_cwd" \
        "$_cica_req_source_roots" "$_cica_req_stdlib_roots" \
        "$_cica_req_cfg" "$_cica_req_opt" "$_cica_req_profile" \
        "$_cica_req_environment" "$_cica_req_argv" \
        "$_cica_req_source_digest" "$_cica_req_output_kind" \
        "$_cica_req_output_path" "$_cica_req_output_sha" || return 1
    CI_COMPILER_ARTIFACT_PATH=$_cica_req_output
    export CI_COMPILER_ARTIFACT_PATH
}
