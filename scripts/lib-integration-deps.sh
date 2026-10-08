#!/usr/bin/env sh
# lib-integration-deps.sh - stage tests/integration/native.manifest
# dependencies the way scripts/verify-integration.sh stages its cases, for
# every gate that compiles manifest programs from a staged case directory.
#
# Sourced. Callers set ROOT and define `stage_plan_copy SOURCE DESTINATION`,
# which copies one file now or records it in a plan.

# Sets DEP_SOURCE_PATH to the file a manifest dependency names.
dep_source_path() {
    _dep=$1
    _source_dir=$2

    case "$_dep" in
        stdlib/* | benchmarks/*)
            DEP_SOURCE_PATH="$ROOT/$_dep"
            return
            ;;
        sym_i64_env_core.tl)
            DEP_SOURCE_PATH="$ROOT/src/sym_i64_env.tl"
            return
            ;;
    esac

    if [ -f "$_source_dir/$_dep" ]; then
        DEP_SOURCE_PATH="$_source_dir/$_dep"
    elif [ -f "$ROOT/src/$_dep" ]; then
        DEP_SOURCE_PATH="$ROOT/src/$_dep"
    elif [ -f "$ROOT/src/tests/$_dep" ]; then
        DEP_SOURCE_PATH="$ROOT/src/tests/$_dep"
    elif [ -f "$ROOT/tests/integration/$_dep" ]; then
        DEP_SOURCE_PATH="$ROOT/tests/integration/$_dep"
    else
        echo "missing integration dependency: $_dep" >&2
        return 1
    fi
}

copy_dep() {
    _dep=$1
    _source_dir=$2
    _case_dir=$3
    _stage_stdlib=${4:-1}
    # Stdlib modules resolve from the compiler's embedded payload by default,
    # so their staged copies are never read. Cases that exercise on-disk
    # stdlib layouts at runtime opt back in with the manifest `stage-stdlib`
    # extra (which also restores the on-disk stdlib compile root).
    case "$_dep" in
        stdlib/*)
            if [ "$_stage_stdlib" -eq 0 ]; then
                return 0
            fi
            ;;
    esac
    dep_source_path "$_dep" "$_source_dir" || return 1
    _src=$DEP_SOURCE_PATH
    # Case directories are absolute paths without a trailing slash, so
    # `${dir%/*}` is their parent.
    _case_parent=${_case_dir%/*}
    _case_grandparent=${_case_parent%/*}
    # src/ sources import `../stdlib/...`; src/tests/ smoke drivers import
    # `../src_module.tl` and `../../stdlib/...` so they stay directly runnable
    # from the repository root while staged integration copies keep the same
    # relative layout.
    case "$_dep" in
        stdlib/*)
            case "$_source_dir" in
                "$ROOT/src")
                    _dst="$_case_parent/$_dep"
                    ;;
                "$ROOT/src/tests")
                    _dst="$_case_grandparent/$_dep"
                    ;;
                *)
                    _dst="$_case_dir/$_dep"
                    ;;
            esac
            ;;
        *)
            if [ "$_source_dir" = "$ROOT/src/tests" ]; then
                case "$_src" in
                    "$ROOT/src/tests/"*)
                        _dst="$_case_dir/$_dep"
                        ;;
                    "$ROOT/src/"*)
                        _dst="$_case_parent/$_dep"
                        ;;
                    *)
                        _dst="$_case_dir/$_dep"
                        ;;
                esac
            else
                _dst="$_case_dir/$_dep"
            fi
            ;;
    esac
    stage_plan_copy "$_src" "$_dst" || return 1

    case "$_dep" in
        stdlib/core_macros.tl) ;;
        stdlib/*)
            case "$_source_dir" in
                "$ROOT/src")
                    _core_dst="$_case_parent/stdlib/core_macros.tl"
                    ;;
                "$ROOT/src/tests")
                    _core_dst="$_case_grandparent/stdlib/core_macros.tl"
                    ;;
                *)
                    _core_dst="$_case_dir/stdlib/core_macros.tl"
                    ;;
            esac
            stage_plan_copy "$ROOT/stdlib/core_macros.tl" "$_core_dst" || return 1
            ;;
    esac
}
