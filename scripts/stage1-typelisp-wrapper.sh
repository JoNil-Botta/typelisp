#!/usr/bin/env sh
set -eu

# stage1-typelisp-wrapper.sh - TYPELISP_BIN-compatible wrapper for a freshly
# bootstrapped selfhost compiler binary.
#
# TYPELISP_STAGE1_BIN must point at the stage1 compiler executable
# (`selfhost/compile.tl` compiled to native code). The raw stage1 compiler
# accepts `compile`; this wrapper adds the rest of the public command surface
# and executes private host-action plans without routing back through the Rust
# CLI.

STAGE1_BIN=${TYPELISP_STAGE1_BIN:-}
STAGE1_TEST_BIN=${TYPELISP_STAGE1_TEST_BIN:-}
STAGE1_DOC_BIN=${TYPELISP_STAGE1_DOC_BIN:-}
STAGE1_REPL_BIN=${TYPELISP_STAGE1_REPL_BIN:-}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

fail() {
    echo "$*" >&2
    exit 1
}

usage() {
    cat >&2 <<'EOF'
usage: typelisp <command> [args...]

stage1 wrapper commands:
  compile, check, build, run, test, fmt, doc, repl
  debug check, debug host-action
EOF
}

doc_usage() {
    cat >&2 <<'EOF'
Usage:
    typelisp doc <file.tl> [-o <out.md>] [--stdlib-root <dir>...]
    typelisp doc --test <file.tl> [--stdlib-root <dir>...]
EOF
}

test_usage() {
    cat >&2 <<'EOF'
Usage:
    typelisp test [--check] <file.tl> [--target <target>] [--opt-level <0|1|2|3>] [--stdlib-root <dir>...]
EOF
}

fmt_usage() {
    cat >&2 <<'EOF'
Usage:
    typelisp fmt [--check] <file.tl>... [--stdlib-root <dir>...]
EOF
}

fmt_missing_file_argument() {
    echo "Error: missing file argument" >&2
    fmt_usage
    exit 1
}

fmt_unknown_flag() {
    echo "Error: unknown fmt flag: $1" >&2
    fmt_usage
    exit 1
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
    "$STAGE1_BIN" compile "$@"
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

    require_stage1
    require_linux_host_action

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

heartbeat_log() {
    if [ "${TYPELISP_STAGE1_HEARTBEAT_FD:-}" = "3" ]; then
        echo "$*" >&3
    else
        echo "$*" >&2
    fi
}

run_with_heartbeat() {
    label=$1
    shift
    status_file=${TMPDIR:-/tmp}/typelisp-stage1-heartbeat-$$.status
    rm -f "$status_file"
    (
        set +e
        "$@"
        code=$?
        printf '%s\n' "$code" > "$status_file"
        exit "$code"
    ) &
    pid=$!
    elapsed=0
    while [ ! -f "$status_file" ]; do
        sleep 5
        elapsed=$((elapsed + 5))
        if [ $((elapsed % 30)) -eq 0 ]; then
            heartbeat_log "[$label] still running (${elapsed}s)"
        fi
    done
    wait "$pid" 2> /dev/null || true
    code=$(sed -n '1p' "$status_file")
    rm -f "$status_file"
    return "$code"
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
    roots="$workdir/stdlib.roots"
    : > "$roots"

    source=
    output=
    target=linux-x86_64
    mode=scalar
    opt_level=

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -o)
                shift
                [ "$#" -gt 0 ] || fail "build: -o requires a value"
                output=$1
                ;;
            --stdlib-root)
                shift
                [ "$#" -gt 0 ] || fail "build: --stdlib-root requires a value"
                append_file_line "$roots" "$1"
                ;;
            --target)
                shift
                [ "$#" -gt 0 ] || fail "build: --target requires a value"
                target=$1
                ;;
            --backend-mode)
                shift
                [ "$#" -gt 0 ] || fail "build: --backend-mode requires a value"
                mode=$1
                ;;
            --opt-level)
                shift
                [ "$#" -gt 0 ] || fail "build: --opt-level requires a value"
                opt_level=$1
                ;;
            --manifest-path)
                fail "build: --manifest-path is not supported by the stage1 wrapper yet"
                ;;
            -*)
                fail "build: unknown flag $1"
                ;;
            *)
                if [ -n "$source" ]; then
                    fail "build: accepts only one source file"
                fi
                source=$1
                ;;
        esac
        shift || break
    done

    [ -n "$source" ] || fail "build: expected source path"
    bin=$(compile_source_to_exe "$source" "$output" "$target" "$mode" "$opt_level" "$roots" "$workdir")
    echo "Generated: $bin"
}

run_command() {
    [ "$#" -gt 0 ] || fail "run: expected source path"
    case "$1" in
        -*) fail "run: expected source path before flags" ;;
    esac

    source=$1
    shift
    workdir=${TMPDIR:-/tmp}/typelisp-stage1-run-$$
    rm -rf "$workdir"
    mkdir -p "$workdir"
    roots="$workdir/stdlib.roots"
    runtime_args="$workdir/runtime.args"
    : > "$roots"
    : > "$runtime_args"

    target=linux-x86_64
    mode=scalar
    opt_level=

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --)
                shift
                while [ "$#" -gt 0 ]; do
                    append_file_line "$runtime_args" "$1"
                    shift
                done
                break
                ;;
            --stdlib-root)
                shift
                [ "$#" -gt 0 ] || fail "run: --stdlib-root requires a value"
                append_file_line "$roots" "$1"
                ;;
            --target)
                shift
                [ "$#" -gt 0 ] || fail "run: --target requires a value"
                target=$1
                ;;
            --backend-mode)
                shift
                [ "$#" -gt 0 ] || fail "run: --backend-mode requires a value"
                mode=$1
                ;;
            --opt-level)
                shift
                [ "$#" -gt 0 ] || fail "run: --opt-level requires a value"
                opt_level=$1
                ;;
            -*)
                fail "run: unknown flag $1"
                ;;
            *)
                while [ "$#" -gt 0 ]; do
                    append_file_line "$runtime_args" "$1"
                    shift
                done
                break
                ;;
        esac
        shift || break
    done

    bin=$(compile_source_to_exe "$source" "" "$target" "$mode" "$opt_level" "$roots" "$workdir")
    run_executable_with_args "$bin" "$runtime_args"
}

test_args_have_check() {
    while [ "$#" -gt 0 ]; do
        if [ "$1" = "--check" ]; then
            return 0
        fi
        shift
    done
    return 1
}

selfhost_test_driver() {
    require_stage1
    require_linux_host_action

    if [ -n "$STAGE1_TEST_BIN" ]; then
        if [ ! -x "$STAGE1_TEST_BIN" ]; then
            fail "stage1 test driver is not executable: $STAGE1_TEST_BIN"
        fi
        printf '%s\n' "$STAGE1_TEST_BIN"
        return
    fi

    cache_dir=${TYPELISP_STAGE1_DRIVER_CACHE_DIR:-"$ROOT/target/stage1-wrapper-cache"}
    driver="$cache_dir/selfhost-test"
    marker="$cache_dir/stage1-bin.path"
    build_dir="$cache_dir/build"
    roots="$build_dir/stdlib.roots"
    source="$ROOT/selfhost/test.tl"

    rebuild=0
    if [ ! -x "$driver" ]; then
        rebuild=1
    elif [ ! -f "$marker" ]; then
        rebuild=1
    elif [ "$(sed -n '1p' "$marker")" != "$STAGE1_BIN" ]; then
        rebuild=1
    elif [ "$STAGE1_BIN" -nt "$driver" ]; then
        rebuild=1
    elif [ "$source" -nt "$driver" ]; then
        rebuild=1
    fi

    if [ "$rebuild" -eq 1 ]; then
        rm -rf "$build_dir"
        mkdir -p "$build_dir"
        : > "$roots"
        heartbeat_log "[stage1-wrapper] building selfhost test driver"
        run_with_heartbeat \
            "stage1-wrapper selfhost/test.tl compile" \
            compile_source_to_exe \
            "$source" \
            "$driver.tmp" \
            linux-x86_64 \
            scalar \
            "" \
            "$roots" \
            "$build_dir" > /dev/null
        mv "$driver.tmp" "$driver"
        printf '%s\n' "$STAGE1_BIN" > "$marker"
    fi

    printf '%s\n' "$driver"
}

selfhost_doc_driver() {
    require_stage1
    require_linux_host_action

    if [ -n "$STAGE1_DOC_BIN" ]; then
        if [ ! -x "$STAGE1_DOC_BIN" ]; then
            fail "stage1 doc driver is not executable: $STAGE1_DOC_BIN"
        fi
        printf '%s\n' "$STAGE1_DOC_BIN"
        return
    fi

    cache_dir=${TYPELISP_STAGE1_DRIVER_CACHE_DIR:-"$ROOT/target/stage1-wrapper-cache"}
    driver="$cache_dir/selfhost-doc"
    marker="$cache_dir/stage1-bin.path"
    build_dir="$cache_dir/doc-build"
    roots="$build_dir/stdlib.roots"
    source="$ROOT/selfhost/doc.tl"

    rebuild=0
    if [ ! -x "$driver" ]; then
        rebuild=1
    elif [ ! -f "$marker" ]; then
        rebuild=1
    elif [ "$(sed -n '1p' "$marker")" != "$STAGE1_BIN" ]; then
        rebuild=1
    elif [ "$STAGE1_BIN" -nt "$driver" ]; then
        rebuild=1
    elif [ "$source" -nt "$driver" ]; then
        rebuild=1
    fi

    if [ "$rebuild" -eq 1 ]; then
        rm -rf "$build_dir"
        mkdir -p "$build_dir"
        : > "$roots"
        heartbeat_log "[stage1-wrapper] building selfhost doc driver"
        run_with_heartbeat \
            "stage1-wrapper selfhost/doc.tl compile" \
            compile_source_to_exe \
            "$source" \
            "$driver.tmp" \
            linux-x86_64 \
            scalar \
            "" \
            "$roots" \
            "$build_dir" > /dev/null
        mv "$driver.tmp" "$driver"
        printf '%s\n' "$STAGE1_BIN" > "$marker"
    fi

    printf '%s\n' "$driver"
}

selfhost_repl_driver() {
    require_stage1
    require_linux_host_action

    if [ -n "$STAGE1_REPL_BIN" ]; then
        if [ ! -x "$STAGE1_REPL_BIN" ]; then
            fail "stage1 repl driver is not executable: $STAGE1_REPL_BIN"
        fi
        printf '%s\n' "$STAGE1_REPL_BIN"
        return
    fi

    cache_dir=${TYPELISP_STAGE1_DRIVER_CACHE_DIR:-"$ROOT/target/stage1-wrapper-cache"}
    driver="$cache_dir/selfhost-repl"
    marker="$cache_dir/stage1-bin.path"
    build_dir="$cache_dir/repl-build"
    roots="$build_dir/stdlib.roots"
    source="$ROOT/selfhost/repl.tl"

    rebuild=0
    if [ ! -x "$driver" ]; then
        rebuild=1
    elif [ ! -f "$marker" ]; then
        rebuild=1
    elif [ "$(sed -n '1p' "$marker")" != "$STAGE1_BIN" ]; then
        rebuild=1
    elif [ "$STAGE1_BIN" -nt "$driver" ]; then
        rebuild=1
    elif [ "$source" -nt "$driver" ]; then
        rebuild=1
    fi

    if [ "$rebuild" -eq 1 ]; then
        rm -rf "$build_dir"
        mkdir -p "$build_dir"
        : > "$roots"
        heartbeat_log "[stage1-wrapper] building selfhost repl driver"
        run_with_heartbeat \
            "stage1-wrapper selfhost/repl.tl compile" \
            compile_source_to_exe \
            "$source" \
            "$driver.tmp" \
            linux-x86_64 \
            scalar \
            "" \
            "$roots" \
            "$build_dir" > /dev/null
        mv "$driver.tmp" "$driver"
        printf '%s\n' "$STAGE1_BIN" > "$marker"
    fi

    printf '%s\n' "$driver"
}

emit_file() {
    path=$1
    if [ -s "$path" ]; then
        cat "$path"
    fi
}

emit_file_stderr() {
    path=$1
    if [ -s "$path" ]; then
        cat "$path" >&2
    fi
}

stderr_ends_with_newline() {
    path=$1
    if [ ! -s "$path" ]; then
        return 0
    fi
    last=$(tail -c 1 "$path" | od -An -tx1 | tr -d ' \n')
    [ "$last" = "0a" ] || [ "$last" = "0d" ]
}

test_command() {
    if [ "$#" -eq 0 ]; then
        echo "Error: missing file argument" >&2
        test_usage
        exit 1
    fi
    case "$1" in
        help | --help | -h)
            test_usage
            return
            ;;
    esac

    driver=$(selfhost_test_driver)
    workdir=${TMPDIR:-/tmp}/typelisp-stage1-test-$$
    rm -rf "$workdir"
    mkdir -p "$workdir"
    trap 'rm -rf "$workdir"' EXIT HUP INT TERM

    plan="$workdir/test.plan"
    driver_stderr="$workdir/test-driver.stderr"

    set +e
    "$driver" "$@" > "$plan" 2> "$driver_stderr"
    driver_status=$?
    set -e

    if test_args_have_check "$@"; then
        emit_file "$plan"
        emit_file_stderr "$driver_stderr"
        exit "$driver_status"
    fi

    if [ "$driver_status" -ne 0 ]; then
        emit_file "$plan"
        emit_file_stderr "$driver_stderr"
        exit "$driver_status"
    fi

    run_stdout="$workdir/test-run.stdout"
    run_stderr="$workdir/test-run.stderr"
    set +e
    execute_plan_file "$plan" > "$run_stdout" 2> "$run_stderr"
    run_status=$?
    set -e

    emit_file "$run_stdout"
    emit_file_stderr "$run_stderr"
    if [ "$run_status" -ne 0 ]; then
        if grep -q '^Error: ' "$run_stderr"; then
            exit "$run_status"
        fi
        if ! stderr_ends_with_newline "$run_stderr"; then
            printf '\n' >&2
        fi
        echo "typelisp test: test executable exited with exit status: $run_status" >&2
        exit "$run_status"
    fi
}

fmt_command() {
    workdir=${TMPDIR:-/tmp}/typelisp-stage1-fmt-$$
    rm -rf "$workdir"
    mkdir -p "$workdir"
    roots="$workdir/stdlib.roots"
    files="$workdir/files.args"
    runtime_args="$workdir/runtime.args"
    : > "$roots"
    : > "$files"

    check=0
    saw_file=0

    while [ "$#" -gt 0 ]; do
        case "$1" in
            help)
                if [ "$saw_file" -eq 0 ]; then
                    fmt_usage
                    return 0
                fi
                append_file_line "$files" "$1"
                saw_file=1
                ;;
            --help | -h)
                if [ "$saw_file" -eq 0 ]; then
                    fmt_usage
                    return 0
                fi
                fmt_unknown_flag "$1"
                ;;
            --check)
                check=1
                ;;
            --stdlib-root)
                shift
                [ "$#" -gt 0 ] || fail "Error: --stdlib-root requires a value"
                append_file_line "$roots" "$1"
                ;;
            -*)
                fmt_unknown_flag "$1"
                ;;
            *)
                append_file_line "$files" "$1"
                saw_file=1
                ;;
        esac
        shift || break
    done

    [ "$saw_file" -ne 0 ] || fmt_missing_file_argument

    : > "$runtime_args"
    if [ "$check" -eq 1 ]; then
        append_file_line "$runtime_args" "--check"
    fi
    cat "$files" >> "$runtime_args"

    bin=$(compile_source_to_exe "$ROOT/selfhost/format.tl" "$workdir/format-bin" linux-x86_64 scalar "" "$roots" "$workdir")
    run_executable_with_args "$bin" "$runtime_args"
}

doc_command() {
    if [ "$#" -eq 0 ]; then
        echo "Error: missing doc subcommand or file argument" >&2
        doc_usage
        exit 1
    fi
    case "$1" in
        help | --help | -h)
            doc_usage
            return
            ;;
    esac

    case "$1" in
        --test | test)
            shift
            if [ "$#" -eq 0 ]; then
                echo "Error: missing file argument" >&2
                doc_usage
                exit 1
            fi
            source=$1
            shift
            workdir=${TMPDIR:-/tmp}/typelisp-stage1-doc-test-$$
            rm -rf "$workdir"
            mkdir -p "$workdir"
            roots="$workdir/stdlib.roots"
            : > "$roots"

            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --stdlib-root)
                        shift
                        [ "$#" -gt 0 ] || fail "Error: --stdlib-root requires a value"
                        append_file_line "$roots" "$1"
                        ;;
                    *)
                        echo "Warning: unknown flag: $1" >&2
                        ;;
                esac
                shift || break
            done

            set -- --test "$source"
            while IFS= read -r root || [ -n "$root" ]; do
                set -- "$@" --stdlib-root "$root"
            done < "$roots"
            driver=$(selfhost_doc_driver)
            "$driver" "$@"
            ;;
        *)
            source=$1
            shift
            output=$(default_compile_output "$source" ".md")
            workdir=${TMPDIR:-/tmp}/typelisp-stage1-doc-$$
            rm -rf "$workdir"
            mkdir -p "$workdir"
            roots="$workdir/stdlib.roots"
            : > "$roots"

            while [ "$#" -gt 0 ]; do
                case "$1" in
                    -o)
                        shift
                        [ "$#" -gt 0 ] || fail "Error: -o requires a value"
                        output=$1
                        ;;
                    --stdlib-root)
                        shift
                        [ "$#" -gt 0 ] || fail "Error: --stdlib-root requires a value"
                        append_file_line "$roots" "$1"
                        ;;
                    *)
                        echo "Warning: unknown flag: $1" >&2
                        ;;
                esac
                shift || break
            done

            set -- --load "$source" "$output"
            while IFS= read -r root || [ -n "$root" ]; do
                set -- "$@" --stdlib-root "$root"
            done < "$roots"
            driver=$(selfhost_doc_driver)
            "$driver" "$@"
            echo "Generated: $output"
            ;;
    esac
}

repl_command() {
    if [ "$#" -ne 0 ]; then
        echo "Error: repl does not accept arguments" >&2
        usage
        exit 1
    fi

    driver=$(selfhost_repl_driver)
    "$driver"
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
    test) test_command "$@" ;;
    fmt) fmt_command "$@" ;;
    doc) doc_command "$@" ;;
    repl) repl_command "$@" ;;
    lint | tokenize | parse)
        fail "stage1 wrapper does not support '$command' yet; use the seed compiler for this gate"
        ;;
    debug) debug_command "$@" ;;
    help | --help | -h) usage ;;
    *)
        fail "Unknown command: $command"
        ;;
esac
