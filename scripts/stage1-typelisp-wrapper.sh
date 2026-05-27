#!/usr/bin/env sh
set -eu

# stage1-typelisp-wrapper.sh - TYPELISP_BIN-compatible wrapper for a freshly
# bootstrapped selfhost compiler binary.
#
# TYPELISP_STAGE1_BIN must point at the stage1 compiler executable
# (`selfhost/compile.tl` compiled to native code). The wrapper supplies the
# public `typelisp compile` spelling, routes Linux source build/run through the
# selfhost TypeLisp drivers, and executes private scratch host-action plans
# without routing back through the Rust CLI.

STAGE1_BIN=${TYPELISP_STAGE1_BIN:-}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

fail() {
    echo "$*" >&2
    exit 1
}

usage() {
    cat >&2 <<'EOF'
usage: typelisp <command> [args...]

stage1 wrapper commands:
  compile, check, build, run
  debug check, debug host-action
EOF
}

require_stage1() {
    if [ -z "$STAGE1_BIN" ]; then
        fail "stage1 wrapper requires TYPELISP_STAGE1_BIN"
    fi
    if [ ! -x "$STAGE1_BIN" ]; then
        fail "stage1 compiler is not executable: $STAGE1_BIN"
    fi
}

require_linux_host_action() {
    case "$(uname -s)" in
        Linux*) ;;
        *) fail "stage1 host-action wrapper is currently Linux-only" ;;
    esac
    command -v as >/dev/null 2>&1 || fail "stage1 host-action wrapper requires 'as'"
    command -v ld >/dev/null 2>&1 || fail "stage1 host-action wrapper requires 'ld'"
}

mkdir_parent() {
    parent=$(dirname -- "$1")
    if [ -n "$parent" ] && [ "$parent" != "." ]; then
        mkdir -p "$parent"
    fi
}

path_without_extension() {
    path=$1
    dir=$(dirname -- "$path")
    base=$(basename -- "$path")
    case "$base" in
        *.*) stem=${base%.*} ;;
        *) stem=$base ;;
    esac
    if [ "$dir" = "." ]; then
        printf '%s\n' "$stem"
    else
        printf '%s/%s\n' "$dir" "$stem"
    fi
}

default_compile_output() {
    source=$1
    extension=$2
    printf '%s%s\n' "$(path_without_extension "$source")" "$extension"
}

compile_output_path() {
    source=
    output=
    emit_ir=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -o)
                shift
                [ "$#" -gt 0 ] || break
                output=$1
                ;;
            --emit-ir)
                emit_ir=1
                ;;
            --target | --stdlib-root | --opt-level | --backend-mode)
                shift
                ;;
            -*)
                ;;
            *)
                if [ -z "$source" ]; then
                    source=$1
                fi
                ;;
        esac
        shift || break
    done

    if [ -n "$output" ]; then
        printf '%s\n' "$output"
    elif [ -n "$source" ] && [ "$emit_ir" -eq 1 ]; then
        default_compile_output "$source" ".ir"
    elif [ -n "$source" ]; then
        default_compile_output "$source" ".s"
    fi
}

compile_command() {
    require_stage1
    output=$(compile_output_path "$@")
    "$STAGE1_BIN" "$@"
    if [ -n "$output" ]; then
        echo "Generated: $output"
    fi
}

check_command() {
    require_stage1
    tmp=${TMPDIR:-/tmp}/typelisp-stage1-check-$$
    rm -rf "$tmp"
    mkdir -p "$tmp"
    trap 'rm -rf "$tmp"' EXIT HUP INT TERM
    "$STAGE1_BIN" "$@" -o "$tmp/check.s"
    echo "Type checking passed!"
}

link_asm() {
    asm=$1
    obj=$2
    bin=$3
    mkdir_parent "$obj"
    mkdir_parent "$bin"
    as "$asm" -o "$obj"
    ld "$obj" -o "$bin" -dynamic-linker /lib64/ld-linux-x86-64.so.2 -lc
}

build_selfhost_tool() {
    tool=$1
    workdir=$2
    asm="$workdir/$tool.s"
    obj="$workdir/$tool.o"
    bin="$workdir/$tool"
    "$STAGE1_BIN" "$ROOT/selfhost/$tool.tl" -o "$asm" --stdlib-root "$ROOT/stdlib"
    link_asm "$asm" "$obj" "$bin"
    printf '%s\n' "$bin"
}

append_file_line() {
    file=$1
    value=$2
    printf '%s\n' "$value" >> "$file"
}

parse_netline_value() {
    key=$1
    line=$2
    rest=${line#"$key "}
    len=${rest%%:*}
    value=${rest#*:}
    case "$len" in
        "" | *[!0-9]*)
            fail "Error: invalid host-action plan: directive '$key' expected a netstring length"
            ;;
    esac
    if [ "${#value}" -ne "$len" ]; then
        fail "Error: invalid host-action plan: directive '$key' netstring length mismatch"
    fi
    printf '%s\n' "$value"
}

plan_word_value() {
    key=$1
    line=$2
    printf '%s\n' "${line#"$key "}"
}

compile_source_to_exe() {
    source=$1
    output=$2
    target=$3
    mode=$4
    opt_level=$5
    roots_file=$6
    workdir=$7

    case "$target" in
        linux-x86_64 | linux_x86_64) ;;
        *) fail "Error: stage1 host-action wrapper supports linux-x86_64 only, got $target" ;;
    esac
    case "$mode" in
        scalar) ;;
        *) fail "Error: stage1 host-action wrapper supports scalar backend mode only, got $mode" ;;
    esac

    if [ -n "$output" ]; then
        bin=$output
        asm="$workdir/build.s"
        obj="$workdir/build.o"
    else
        bin=$(path_without_extension "$source")
        asm=$(default_compile_output "$source" ".s")
        obj=$(default_compile_output "$source" ".o")
    fi

    set -- "$source" -o "$asm" --target "$target" --backend-mode "$mode"
    if [ -n "$opt_level" ]; then
        set -- "$@" --opt-level "$opt_level"
    fi
    if [ -f "$roots_file" ]; then
        while IFS= read -r root || [ -n "$root" ]; do
            set -- "$@" --stdlib-root "$root"
        done < "$roots_file"
    fi

    "$STAGE1_BIN" "$@"
    link_asm "$asm" "$obj" "$bin"
    printf '%s\n' "$bin"
}

run_executable_with_args() {
    bin=$1
    args_file=$2
    shift 2
    set -- "$bin"
    if [ -f "$args_file" ]; then
        while IFS= read -r arg || [ -n "$arg" ]; do
            set -- "$@" "$arg"
        done < "$args_file"
    fi
    "$@"
}

execute_plan_file() {
    plan_file=$1
    require_stage1
    require_linux_host_action

    first=$(sed -n '1p' "$plan_file")
    if [ "$first" != "typelisp-host-plan v1" ]; then
        fail "Error: invalid host-action plan: host-action plan must start with \"typelisp-host-plan v1\""
    fi

    workdir=${TMPDIR:-/tmp}/typelisp-stage1-host-action-$$
    rm -rf "$workdir"
    mkdir -p "$workdir"
    runtime_args="$workdir/runtime.args"
    stdlib_roots="$workdir/stdlib.roots"
    assembly_file="$workdir/inline.s"
    : > "$runtime_args"
    : > "$stdlib_roots"

    action=
    source=
    output=
    target=linux-x86_64
    mode=scalar
    opt_level=
    scratch_assembly_path=
    saw_end=0
    line_no=0

    while IFS= read -r line || [ -n "$line" ]; do
        line_no=$((line_no + 1))
        if [ "$line_no" -eq 1 ]; then
            continue
        fi
        case "$line" in
            end)
                saw_end=1
                break
                ;;
            action\ *) action=$(plan_word_value action "$line") ;;
            target\ *) target=$(plan_word_value target "$line") ;;
            backend-mode\ *) mode=$(plan_word_value backend-mode "$line") ;;
            opt-level\ *) opt_level=$(plan_word_value opt-level "$line") ;;
            source\ *) source=$(parse_netline_value source "$line") ;;
            output\ *) output=$(parse_netline_value output "$line") ;;
            assembly\ *) parse_netline_value assembly "$line" > "$assembly_file" ;;
            scratch-assembly-path\ *) scratch_assembly_path=$(parse_netline_value scratch-assembly-path "$line") ;;
            runtime-arg\ *) append_file_line "$runtime_args" "$(parse_netline_value runtime-arg "$line")" ;;
            stdlib-root\ *) append_file_line "$stdlib_roots" "$(parse_netline_value stdlib-root "$line")" ;;
            "") fail "Error: invalid host-action plan: host-action plan has an empty directive line" ;;
            *) fail "Error: invalid host-action plan: unknown host-action directive '${line%% *}'" ;;
        esac
    done < "$plan_file"

    if [ "$saw_end" -ne 1 ]; then
        fail "Error: invalid host-action plan: host-action plan ended before its 'end' directive"
    fi
    if [ -z "$action" ]; then
        fail "Error: invalid host-action plan: host-action plan is missing 'action'"
    fi

    case "$action" in
        build-source)
            [ -n "$source" ] || fail "Error: invalid host-action plan: host-action plan is missing 'source'"
            bin=$(compile_source_to_exe "$source" "$output" "$target" "$mode" "$opt_level" "$stdlib_roots" "$workdir")
            echo "Generated: $bin"
            ;;
        run-source)
            [ -n "$source" ] || fail "Error: invalid host-action plan: host-action plan is missing 'source'"
            bin=$(compile_source_to_exe "$source" "" "$target" "$mode" "$opt_level" "$stdlib_roots" "$workdir")
            run_executable_with_args "$bin" "$runtime_args"
            ;;
        run-assembly)
            link_asm "$assembly_file" "$workdir/inline.o" "$workdir/inline"
            run_executable_with_args "$workdir/inline" "$runtime_args"
            ;;
        run-scratch-assembly)
            [ -n "$scratch_assembly_path" ] || fail "Error: invalid host-action plan: host-action plan is missing 'scratch-assembly-path'"
            cp "$scratch_assembly_path" "$assembly_file"
            rm -f "$scratch_assembly_path"
            link_asm "$assembly_file" "$workdir/inline.o" "$workdir/inline"
            run_executable_with_args "$workdir/inline" "$runtime_args"
            ;;
        *)
            fail "Error: invalid host-action plan: unknown host-action action '$action'"
            ;;
    esac
}

build_command() {
    workdir=${TMPDIR:-/tmp}/typelisp-stage1-build-$$
    rm -rf "$workdir"
    mkdir -p "$workdir"
    tool=$(build_selfhost_tool build "$workdir")
    "$tool" "$@"
}

run_command() {
    workdir=${TMPDIR:-/tmp}/typelisp-stage1-run-$$
    rm -rf "$workdir"
    mkdir -p "$workdir"
    tool=$(build_selfhost_tool run "$workdir")
    "$tool" "$@"
}

debug_command() {
    [ "$#" -gt 0 ] || fail "Error: missing debug subcommand"
    case "$1" in
        host-action)
            plan=${TMPDIR:-/tmp}/typelisp-stage1-host-action-input-$$
            cat > "$plan"
            execute_plan_file "$plan"
            ;;
        check)
            shift
            check_command "$@"
            ;;
        help | --help | -h)
            usage
            ;;
        *)
            fail "Unknown debug command: $1"
            ;;
    esac
}

if [ "$#" -eq 0 ]; then
    usage
    exit 2
fi

command=$1
shift

case "$command" in
    compile) compile_command "$@" ;;
    check) check_command "$@" ;;
    build) build_command "$@" ;;
    run) run_command "$@" ;;
    test | fmt | lint | doc | tokenize | parse)
        fail "stage1 wrapper does not support '$command' yet; use the seed compiler for this gate"
        ;;
    debug) debug_command "$@" ;;
    help | --help | -h) usage ;;
    *)
        fail "Unknown command: $command"
        ;;
esac
