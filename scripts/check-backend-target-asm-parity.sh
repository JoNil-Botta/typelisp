#!/usr/bin/env sh
set -eu

usage() {
    echo "usage: $0 [--self-test] [typelisp-binary]" >&2
}

self_test=0
compiler_arg=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --self-test)
            self_test=1
            ;;
        -*)
            usage
            exit 2
            ;;
        *)
            if [ -n "$compiler_arg" ]; then
                usage
                exit 2
            fi
            compiler_arg=$1
            ;;
    esac
    shift
done

case "$(uname -s)" in
    Linux* | MINGW* | MSYS* | CYGWIN*) ;;
    *)
        echo "backend target assembly parity check is unsupported on this host" >&2
        exit 1
        ;;
esac

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

WORKDIR=${BACKEND_TARGET_ASM_PARITY_DIR:-target/backend-target-asm-parity}
LINUX_ASM_DIR="$WORKDIR/linux-asm"
WINDOWS_ASM_DIR="$WORKDIR/windows-asm"
LINUX_NORM_DIR="$WORKDIR/linux-norm"
WINDOWS_NORM_DIR="$WORKDIR/windows-norm"

if [ -n "$compiler_arg" ]; then
    COMPILER=$compiler_arg
elif [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

corpus() {
    # Named user/helper bodies whose ABI prologues can be stripped without
    # hiding target-owned call setup, runtime, entry, or object-format details.
    cat <<'EOF'
functions tests/integration/functions.tl _tl_functions_add3
lambda_capture_struct_enum tests/integration/lambda_capture_struct_enum.tl _tl___tl_lambda_lambda_capture_struct_enum_make_x_reader_0,_tl___tl_lambda_lambda_capture_struct_enum_make_area_0
many_args tests/integration/many_args.tl _tl_many_args_sum8
register_group_phi_return tests/integration/register_group_phi_return.tl _tl_register_group_phi_return_pick_address_taken
register_resident_enum tests/integration/register_resident_enum.tl _tl_register_resident_enum_turn_right,_tl_register_resident_enum_code
EOF
}

opt_levels() {
    printf '%s\n' 0 1 2
}

compile_asm() {
    target=$1
    opt_level=$2
    name=$3
    source=$4
    out_dir=$5

    out="$out_dir/opt${opt_level}_$name.s"
    echo "[$target opt$opt_level] $source -> $out"
    "$COMPILER" compile "$source" \
        --target "$target" \
        --opt-level "$opt_level" \
        --stdlib-root "$ROOT/stdlib" \
        -o "$out"
}

compile_all() {
    out_dir=$1
    target=$2

    mkdir -p "$out_dir"
    opt_levels | while read -r opt_level; do
        corpus | while read -r name source symbols; do
            [ -n "$name" ] || continue
            if [ ! -f "$source" ]; then
                echo "corpus file not found: $source" >&2
                exit 1
            fi
            compile_asm "$target" "$opt_level" "$name" "$source" "$out_dir"
        done
    done
}

normalize_asm() {
    asm=$1
    out=$2
    symbols=$3

    awk -v symbols="$symbols" '
        function trim(s) {
            gsub(/^[ \t\r]+/, "", s)
            gsub(/[ \t\r]+$/, "", s)
            return s
        }
        function stop_func() {
            active = 0
            current = ""
            skip_prologue = 0
        }
        BEGIN {
            wanted_count = split(symbols, symbol_order, ",")
            for (i = 1; i <= wanted_count; i++) {
                wanted[symbol_order[i]] = 1
                seen[symbol_order[i]] = 0
                entry_seen[symbol_order[i]] = 0
            }
            active = 0
            pending = ""
        }
        {
            line = trim($0)

            if (line ~ /^\.globl[ \t]+/) {
                split(line, parts, /[ \t]+/)
                if (active) {
                    stop_func()
                }
                pending = (parts[2] in wanted) ? parts[2] : ""
                next
            }

            if (pending != "" && line == pending ":") {
                current = pending
                seen[current]++
                active = 1
                skip_prologue = 1
                pending = ""
                print "FUNC " current
                next
            }

            if (!active) {
                next
            }

            if (line == "" || line ~ /^#/ || line ~ /^\.seh_/) {
                next
            }

            if (line ~ /^\.section[ \t]/ || line ~ /^\.text$/ ||
                    line ~ /^\.data$/ || line ~ /^\.bss$/ ||
                    line ~ /^\.tbss[ \t]/ || line ~ /^\.rdata[ \t]/) {
                stop_func()
                next
            }

            if (skip_prologue) {
                if (line ~ /^\.Lf[0-9]+_entry:$/) {
                    print "ENTRY"
                    entry_seen[current] = 1
                    skip_prologue = 0
                }
                next
            }

            gsub(/\.Lf[0-9]+/, ".LfN", line)
            gsub(/\.Ltmp[0-9]+/, ".LtmpN", line)
            print line
        }
        END {
            missing = 0
            for (i = 1; i <= wanted_count; i++) {
                symbol = symbol_order[i]
                if (seen[symbol] != 1) {
                    printf("expected exactly one normalized symbol %s, saw %d\n", symbol, seen[symbol]) > "/dev/stderr"
                    missing = 1
                }
                if (entry_seen[symbol] != 1) {
                    printf("normalized symbol %s did not reach its body entry label\n", symbol) > "/dev/stderr"
                    missing = 1
                }
            }
            exit missing
        }
    ' "$asm" > "$out"
}

normalize_all() {
    asm_dir=$1
    norm_dir=$2

    mkdir -p "$norm_dir"
    opt_levels | while read -r opt_level; do
        corpus | while read -r name _source symbols; do
            [ -n "$name" ] || continue
            normalize_asm \
                "$asm_dir/opt${opt_level}_$name.s" \
                "$norm_dir/opt${opt_level}_$name.norm" \
                "$symbols"
        done
    done
}

compare_outputs() {
    failed_marker="$WORKDIR/.backend-target-asm-parity-failed"
    rm -f "$failed_marker"

    opt_levels | while read -r opt_level; do
        corpus | while read -r name _source _symbols; do
            [ -n "$name" ] || continue
            left="$LINUX_NORM_DIR/opt${opt_level}_$name.norm"
            right="$WINDOWS_NORM_DIR/opt${opt_level}_$name.norm"

            if ! cmp -s "$left" "$right"; then
                echo "backend target assembly mismatch: opt$opt_level $name" >&2
                echo "  linux normalized:   $left" >&2
                echo "  windows normalized: $right" >&2
                if command -v diff >/dev/null 2>&1; then
                    diff -u "$left" "$right" || true
                else
                    cmp -l "$left" "$right" | sed -n '1,40p' || true
                fi
                : > "$failed_marker"
            fi
        done
    done

    [ ! -f "$failed_marker" ]
}

rm -rf "$LINUX_ASM_DIR" "$WINDOWS_ASM_DIR" "$LINUX_NORM_DIR" "$WINDOWS_NORM_DIR"
mkdir -p "$LINUX_ASM_DIR" "$WINDOWS_ASM_DIR" "$LINUX_NORM_DIR" "$WINDOWS_NORM_DIR"

compile_all "$LINUX_ASM_DIR" linux-x86_64
compile_all "$WINDOWS_ASM_DIR" windows-x86_64
normalize_all "$LINUX_ASM_DIR" "$LINUX_NORM_DIR"
normalize_all "$WINDOWS_ASM_DIR" "$WINDOWS_NORM_DIR"

if [ "$self_test" -eq 1 ]; then
    if ! compare_outputs; then
        echo "--self-test setup failed: fresh normalized backend assembly already differs" >&2
        exit 1
    fi

    first_name=$(corpus | sed -n '1s/ .*//p')
    printf '\n# backend-target-asm-parity self-test mutation\n' >> "$WINDOWS_NORM_DIR/opt0_$first_name.norm"
    if compare_outputs; then
        echo "--self-test failed: mutated normalized backend assembly was not detected" >&2
        exit 1
    fi
    echo "--self-test passed: mutated normalized backend assembly was detected"
    exit 0
fi

if ! compare_outputs; then
    exit 1
fi

case_count=$(corpus | wc -l | tr -d ' ')
echo "backend target assembly parity check passed for $case_count files across 3 opt levels"
