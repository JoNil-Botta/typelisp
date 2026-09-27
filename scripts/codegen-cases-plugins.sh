# codegen-cases-plugins.sh - plugins for scripts/verify-codegen-cases.sh.
#
# Sourced by the runner. `check NAME ARGS...` calls plugin_NAME (hyphens become
# underscores) with the expanded ARGS; `setup NAME ARGS...` does the same before
# the case's action. A plugin prints why it failed to stderr and returns 1.
#
# Plugins see the variant's state: ROOT, COMPILER, CC_WORK (the case file's work
# directory), CV_DIR, CV_TARGET, CV_OPT, CV_MODE, CV_ASM, CV_SUBJECT (the current
# subject) and CC_ANALYZERS (scripts/codegen-cases-analyzers.awk).

# asm-equals OTHER-ASM SED-EXPR: the variant's assembly equals OTHER-ASM after
# SED-EXPR (e.g. a module-name rename).
plugin_asm_equals() {
    [ -f "$1" ] || {
        echo "  asm-equals: missing $1" >&2
        return 1
    }
    sed "$2" "$1" > "$CV_DIR/asm-equals.expected.s"
    cmp -s "$CV_DIR/asm-equals.expected.s" "$CV_ASM" && return 0
    diff -u "$CV_DIR/asm-equals.expected.s" "$CV_ASM" | sed -n '1,40p' >&2 || :
    return 1
}

# same-metric OTHER-ASM LABEL ANALYZER: ANALYZER over function LABEL gives the
# same value in this variant's assembly and in OTHER-ASM.
plugin_same_metric() {
    _psm_mine=$(awk -v label="$2:" '
        $0 == label { f = 1; print; next }
        f && /^\.globl[[:space:]]/ { exit }
        f && /^[[:space:]]*\.size[[:space:]]/ { exit }
        f { print }
    ' "$CV_ASM" | awk -v analyzer="$3" -f "$CC_ANALYZERS")
    _psm_other=$(awk -v label="$2:" '
        $0 == label { f = 1; print; next }
        f && /^\.globl[[:space:]]/ { exit }
        f && /^[[:space:]]*\.size[[:space:]]/ { exit }
        f { print }
    ' "$1" | awk -v analyzer="$3" -f "$CC_ANALYZERS")
    [ "$_psm_mine" = "$_psm_other" ] && return 0
    echo "  same-metric $3 of $2: $_psm_mine here, $_psm_other in $1" >&2
    return 1
}

# git-grep-absent ERE PATH...: no tracked file under PATH matches ERE.
plugin_git_grep_absent() {
    _pgg_re=$1
    shift
    if git -C "$ROOT" grep -n -E "$_pgg_re" -- "$@" >/dev/null 2>&1; then
        git -C "$ROOT" grep -n -E "$_pgg_re" -- "$@" >&2 || :
        return 1
    fi
    return 0
}

# for-copy-mutation DIR: copy the scalar `for` source transformer from
# stdlib/core_macros.tl into DIR/for_copy_macros.tl, renamed `for-copy` with its
# body byte-for-byte identical. Only the declaration is copied: loading the
# whole implicit-prelude module twice would test module identity instead.
plugin_for_copy_mutation() {
    mkdir -p "$1"
    {
        printf '%s\n\n' '(import stdlib.comptime)'
        awk '
            /^\(defmacro \(for / { copying = 1 }
            copying && /^\(cfg$/ { exit }
            copying { print }
        ' "$ROOT/stdlib/core_macros.tl" |
            sed '0,/(defmacro (for /s//(defmacro (for-copy /'
    } > "$1/for_copy_macros.tl"
}

# files-exist DIR NAME...: every DIR/NAME is a regular file.
plugin_files_exist() {
    _pfe_dir=$1
    shift
    _pfe_status=0
    for _pfe_name do
        [ -f "$ROOT/$_pfe_dir/$_pfe_name" ] || {
            echo "  missing $_pfe_dir/$_pfe_name" >&2
            _pfe_status=1
        }
    done
    return "$_pfe_status"
}

# ispc-case-tsv FILE CASE LANE TL-SYMBOL ISPC-SYMBOL ARGUMENTS REPETITIONS
#               EXITS UPSTREAM-PATH UPSTREAM-FUNCTION
# The typelisp-ispc-case-v1 metadata (benchmarks/ispc/README.md): the exact
# header and exactly one scalar, avx2 and avx512 row, every field pinned.
# EXITS is the scalar,avx2,avx512 expected exit codes.
plugin_ispc_case_tsv() {
    CC_ISPC_CASE=$2 CC_ISPC_LANE=$3 CC_ISPC_TL_SYMBOL=$4 CC_ISPC_SYMBOL=$5 \
        CC_ISPC_ARGS=$6 CC_ISPC_REPS=$7 CC_ISPC_EXITS=$8 CC_ISPC_PATH=$9 \
        CC_ISPC_FUNCTION=${10} awk -F '\t' '
        BEGIN {
            header = "schema\tcase\tmode\ttypelisp_status\ttypelisp_diagnostic\tispc_status\tispc_diagnostic\tispc_target\tgang_width\tlane_type\ttypelisp_source\ttypelisp_symbol\tispc_source\tispc_symbol\tdriver\targuments\trepetitions\texpected_exit\tupstream_tag\tupstream_commit\tupstream_path\tupstream_function\tlicense"
            scalar_diag = "ISPC v1.31.0 has no width-1 CPU target; smallest generic target is generic-i32x4"
            commit = "c6adb4f86f5678ce6c41951b1e2b59f727455697"
            split(ENVIRON["CC_ISPC_EXITS"], exits, ",")
            want["scalar"] = "unsupported\t" scalar_diag "\tnone\t1\t" exits[1]
            want["avx2"] = "supported\t\tavx2-i32x8\t8\t" exits[2]
            want["avx512"] = "supported\t\tavx512skx-x16\t16\t" exits[3]
        }
        NR == 1 {
            if ($0 != header) { print "  invalid case.tsv header" > "/dev/stderr"; bad = 1 }
            next
        }
        {
            if (NF != 23 || $1 != "typelisp-ispc-case-v1" || $2 != ENVIRON["CC_ISPC_CASE"] ||
                $4 != "supported" || $5 != "" || $10 != ENVIRON["CC_ISPC_LANE"] ||
                $11 != "bench.tl" || $12 != ENVIRON["CC_ISPC_TL_SYMBOL"] ||
                $13 != "kernel.ispc" || $14 != ENVIRON["CC_ISPC_SYMBOL"] ||
                $15 != "driver.c" || $16 != ENVIRON["CC_ISPC_ARGS"] ||
                $17 != ENVIRON["CC_ISPC_REPS"] || $19 != "v1.31.0" || $20 != commit ||
                $21 != ENVIRON["CC_ISPC_PATH"] || $22 != ENVIRON["CC_ISPC_FUNCTION"] ||
                $23 != "BSD-3-Clause") {
                print "  invalid case.tsv row " NR > "/dev/stderr"
                bad = 1
            }
            if (($3 in want) && ($6 "\t" $7 "\t" $8 "\t" $9 "\t" $18) != want[$3]) {
                print "  invalid " $3 " target, width or exit in case.tsv row " NR > "/dev/stderr"
                bad = 1
            }
            seen[$3]++
        }
        END {
            if (NR != 4 || seen["scalar"] != 1 || seen["avx2"] != 1 || seen["avx512"] != 1) {
                print "  case.tsv needs exactly one scalar, avx2 and avx512 row" > "/dev/stderr"
                bad = 1
            }
            exit bad
        }
    ' "$ROOT/$1"
}

# c-oracle DRIVER EXPECTED-EXIT CFLAGS: build the case's C driver alone with
# ${CC:-clang} and comma-separated CFLAGS; it must exit EXPECTED-EXIT silently.
plugin_c_oracle() {
    _pco_cc=${CC:-clang}
    command -v "$_pco_cc" >/dev/null 2>&1 || {
        echo "  C compiler not found: $_pco_cc" >&2
        return 1
    }
    # shellcheck disable=SC2046
    "$_pco_cc" $(printf '%s' "$3" | tr , ' ') "$ROOT/$1" -o "$CV_DIR/c-oracle" \
        > "$CV_DIR/c-oracle.cc.stdout" 2> "$CV_DIR/c-oracle.cc.stderr" || {
        sed 's/^/    /' "$CV_DIR/c-oracle.cc.stderr" >&2
        return 1
    }
    _pco_status=0
    "$CV_DIR/c-oracle" > "$CV_DIR/c-oracle.stdout" 2> "$CV_DIR/c-oracle.stderr" || _pco_status=$?
    if [ "$_pco_status" -ne "$2" ] || [ -s "$CV_DIR/c-oracle.stdout" ] || [ -s "$CV_DIR/c-oracle.stderr" ]; then
        echo "  C oracle exited $_pco_status (expected $2, silent)" >&2
        sed 's/^/    /' "$CV_DIR/c-oracle.stderr" >&2
        return 1
    fi
}

# ispc-driver CASE-DIR ISPC-TARGET GATE EXPECTED-EXIT CFLAGS SYMBOL
# Optional real-ISPC correctness, skipped (status 2) when neither $ISPC_BIN
# nor `ispc` exists; any ISPC other than v1.31.0 fails. Compiles
# CASE-DIR/kernel.ispc for ISPC-TARGET, links CASE-DIR/driver.c with the
# comma-separated CFLAGS, and requires EXPECTED-EXIT with empty output. GATE is
# `always`, `isa:ISA` (skipped when the host cannot run ISA) or `env:VAR:ISA`
# (runs only with VAR=1, and then the host must run ISA). SYMBOL is `-`,
# `nm:PREFIX` (a defined object symbol) or `asm:PREFIX` (a label of the
# --emit-asm output) naming ISPC's internal kernel.
plugin_ispc_driver() {
    _pid_ispc=${ISPC_BIN:-}
    [ -n "$_pid_ispc" ] || _pid_ispc=$(command -v ispc 2>/dev/null || true)
    if [ -z "$_pid_ispc" ]; then
        echo "[codegen-cases] optional ISPC $2 check skipped (set ISPC_BIN to ISPC v1.31.0)"
        return 2
    fi
    case "$("$_pid_ispc" --version 2>&1 | sed -n '1p')" in
        *1.31.0*) ;;
        *)
            echo "  ISPC v1.31.0 required: $_pid_ispc" >&2
            return 1
            ;;
    esac
    case "$3" in
        isa:*)
            if ! printf '%s\n' "$CC_ISAS" | grep -qx "${3#isa:}"; then
                echo "[codegen-cases] optional ISPC $2 check skipped (host lacks ${3#isa:})"
                return 2
            fi
            ;;
        env:*)
            _pid_var=${3#env:}
            _pid_isa=${_pid_var#*:}
            _pid_var=${_pid_var%%:*}
            eval "_pid_on=\${$_pid_var:-0}"
            [ "$_pid_on" = 1 ] || return 2
            printf '%s\n' "$CC_ISAS" | grep -qx "$_pid_isa" || {
                echo "  $_pid_var=1 requested ISPC $2 but the host cannot run $_pid_isa" >&2
                return 1
            }
            ;;
    esac
    _pid_cc=${CC:-clang}
    command -v "$_pid_cc" >/dev/null 2>&1 || {
        echo "  C compiler not found: $_pid_cc" >&2
        return 1
    }
    _pid_out="$CV_DIR/ispc-$2"
    mkdir -p "$_pid_out"
    "$_pid_ispc" "$ROOT/$1/kernel.ispc" -O2 --arch=x86-64 --target="$2" \
        -o "$_pid_out/kernel.o" --header-outfile="$_pid_out/kernel_ispc.h" \
        > "$_pid_out/ispc.stdout" 2> "$_pid_out/ispc.stderr" || {
        sed 's/^/    /' "$_pid_out/ispc.stderr" >&2
        return 1
    }
    # shellcheck disable=SC2046
    "$_pid_cc" $(printf '%s' "$5" | tr , ' ') -I"$_pid_out" "$ROOT/$1/driver.c" \
        "$_pid_out/kernel.o" -o "$_pid_out/driver" \
        > "$_pid_out/cc.stdout" 2> "$_pid_out/cc.stderr" || {
        sed 's/^/    /' "$_pid_out/cc.stderr" >&2
        return 1
    }
    _pid_status=0
    "$_pid_out/driver" > "$_pid_out/run.stdout" 2> "$_pid_out/run.stderr" || _pid_status=$?
    if [ "$_pid_status" -ne "$4" ] || [ -s "$_pid_out/run.stdout" ] || [ -s "$_pid_out/run.stderr" ]; then
        echo "  ISPC $2 driver exited $_pid_status (expected $4, silent)" >&2
        sed 's/^/    /' "$_pid_out/run.stderr" >&2
        return 1
    fi
    case "$6" in
        nm:*)
            nm --defined-only "$_pid_out/kernel.o" |
                awk -v p="${6#nm:}" 'index($3, p) == 1 { f = 1 } END { exit !f }' || {
                echo "  ISPC $2 internal kernel symbol ${6#nm:}* missing" >&2
                return 1
            }
            ;;
        asm:*)
            "$_pid_ispc" "$ROOT/$1/kernel.ispc" -O2 --arch=x86-64 --target="$2" \
                --emit-asm -o "$_pid_out/kernel.s" \
                > "$_pid_out/ispc-s.stdout" 2> "$_pid_out/ispc-s.stderr" || return 1
            grep -E "^${6#asm:}[A-Za-z0-9_]*:" "$_pid_out/kernel.s" >/dev/null || {
                echo "  ISPC $2 internal kernel label ${6#asm:}* missing" >&2
                return 1
            }
            ;;
    esac
    echo "[codegen-cases] ISPC $2 driver passed"
}

# cc_dir_link LINK TARGET / cc_dir_unlink LINK: a directory symlink (a junction
# on Windows), for `sh` rows.
cc_dir_link() {
    if [ "$CC_HOST" = windows ]; then
        TYPELISP_TEST_JUNCTION_LINK=$(cygpath -aw "$1") \
            TYPELISP_TEST_JUNCTION_TARGET=$(cygpath -aw "$2") \
            powershell.exe -NoLogo -NoProfile -NonInteractive -Command \
            '$null = New-Item -ItemType Junction -Path $env:TYPELISP_TEST_JUNCTION_LINK -Target $env:TYPELISP_TEST_JUNCTION_TARGET' > /dev/null
    else
        ln -s "$2" "$1"
    fi
}

cc_dir_unlink() {
    if [ "$CC_HOST" = windows ]; then
        TYPELISP_TEST_JUNCTION_LINK=$(cygpath -aw "$1") \
            powershell.exe -NoLogo -NoProfile -NonInteractive -Command \
            '[System.IO.Directory]::Delete($env:TYPELISP_TEST_JUNCTION_LINK)' > /dev/null
    else
        rm "$1"
    fi
}
