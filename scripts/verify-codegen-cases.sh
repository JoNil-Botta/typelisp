#!/usr/bin/env sh
set -eu

# verify-codegen-cases.sh - table-driven compile / run / assembly-shape runner.
#
# usage: scripts/verify-codegen-cases.sh [--list] [--only CASE-GLOB] FILE.cases...
#
# The compiler under test is $TYPELISP_BIN (the published stage0 otherwise).
# It is only ever the program being tested: every expectation is evaluated here
# with POSIX sh, grep, sed and awk. Work files go to
# ${CODEGEN_CASES_WORKDIR:-target/codegen-cases}/<file-name>/.
#
# Case file format (see tests/codegen/*.cases). One directive per line; blank
# lines and lines starting with `#` are ignored; leading whitespace is ignored.
# A directive's text argument is everything after the single space that follows
# its fixed fields, so text and regular expressions may contain spaces.
# Directives before the first `case` are defaults for every case in the file.
#
#   case ID                 start a case (IDs are unique per file)
#   source PATH             program, relative to the repo root (or {{work}}/...)
#   target T...             --target values, `-` omits the flag (default linux-x86_64)
#   opt N...                --opt-level values, `-` omits the flag (default 2)
#   mode M...               --backend-mode values, `-` omits the flag (default -)
#   args ARGS...            extra compiler arguments (word-split)
#   do ACTION               compile (default): `typelisp compile` to assembly;
#                           build: `typelisp build` must produce an executable;
#                           build-run: build, then run the executable;
#                           link-run: compile, assemble and link with as/ld,
#                             then run (on Windows: compile, then `typelisp run`);
#                           tl-run: `typelisp run`; check: `typelisp check`;
#                           none: no compiler invocation (file checks only)
#   hosts H...              only run on these hosts (linux, windows)
#   assemble                assemble the assembly (as for Linux, clang for Windows)
#   repeatable              a second compile must produce identical assembly
#   setup PLUGIN ARGS...    run plugin_PLUGIN before the action
#   file NAME ... end-file  (file level) write the lines between to {{work}}/NAME
#
# Every case runs once per target x opt x mode variant. SIMD modes that the host
# cannot execute (scripts/detect-simd-isa.sh) still compile; their run step and
# the run-output rows (exit, in stdout, in stderr) are skipped.
#
# Expectations are evaluated in order against the current subject:
#
#   in asm | stdout | stderr        whole assembly, or the last step's output
#   in fn LABEL                     LABEL: up to the next column-0 .globl or a .size
#   in fn-globl LABEL               LABEL: up to the next (indented or not) .globl
#   in file PATH                    a repository file
#   narrow WINDOW[:ARG]             replace the subject by an analyzer window
#                                   (scripts/codegen-cases-analyzers.awk); an empty
#                                   window fails
#   exit N | nonzero | MODE=N...    exit status of the last step (default: 0);
#                                   MODE=N words pick by backend mode
#   contains TEXT / not-contains TEXT
#   match ERE / not-match ERE / match-i ERE / not-match-i ERE
#   count OP N ERE / count-fixed OP N TEXT     OP is =, >= or <=
#   after ERE + next-line ERE       the line after the first ERE match matches
#   empty / not-empty
#   metric NAME[:ARG] OP VALUE      analyzer result; OP = compares text
#   capture VAR ERE                 {{VAR}} := group 1 of the first line that the
#                                   whole-line ERE matches (none fails)
#   check PLUGIN ARGS...            plugin_PLUGIN (scripts/codegen-cases-plugins.sh);
#                                   a plugin returning 2 was skipped (optional tool)
#   if-fn LABEL | if-no-fn LABEL | if-mode M... ... [else ...] end-if
#
# Text arguments expand {{root}}, {{work}}, {{target}}, {{opt}}, {{mode}} and
# captured {{VAR}}s. The first failing row of a variant is reported with its
# file:line, the remaining rows of that variant are still evaluated, and the
# runner exits 1 if any row failed.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
# Arguments are word-split on purpose (args, plugin words); never glob them.
set -f

usage() {
    echo "usage: scripts/verify-codegen-cases.sh [--list] [--only CASE-GLOB] FILE.cases..." >&2
    exit 2
}

CC_LIST=0
CC_ONLY='*'
while [ "$#" -gt 0 ]; do
    case "$1" in
        --list) CC_LIST=1; shift ;;
        --only) [ "$#" -ge 2 ] || usage; CC_ONLY=$2; shift 2 ;;
        --) shift; break ;;
        -*) usage ;;
        *) break ;;
    esac
done
[ "$#" -gt 0 ] || usage

CC_ANALYZERS="$ROOT/scripts/codegen-cases-analyzers.awk"
. "$ROOT/scripts/codegen-cases-plugins.sh"
. "$ROOT/scripts/lib-linux-entry.sh"

CC_HOST=linux
case "$(uname -s)" in
    Linux*) CC_HOST=linux ;;
    MINGW* | MSYS* | CYGWIN*) CC_HOST=windows ;;
    *) CC_HOST=unknown ;;
esac

if [ "$CC_LIST" -eq 0 ]; then
    if [ -n "${TYPELISP_BIN:-}" ]; then
        COMPILER=$TYPELISP_BIN
    else
        . "$ROOT/scripts/lib-stage0.sh"
        COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
    fi
    case "$COMPILER" in
        /* | [A-Za-z]:[\\/]*) ;;
        *) COMPILER="$ROOT/$COMPILER" ;;
    esac
    [ -x "$COMPILER" ] || {
        echo "typelisp compiler is not executable: $COMPILER" >&2
        exit 1
    }
    CC_ISAS=$(sh "$ROOT/scripts/detect-simd-isa.sh" 2>/dev/null || true)
fi

CC_FAILURES=0
CC_ROWS=0
CC_SKIPPED=0
CC_SELECTED=0

# ---------------------------------------------------------------- helpers

cc_quote_lines() {
    sed 's/^/    /' "$1" >&2 || true
}

# Expand {{name}} placeholders in $1.
CC_OPEN='{{'
CC_CLOSE='}}'
cc_expand() {
    _cx_in=$1
    case "$_cx_in" in
        *"$CC_OPEN"*"$CC_CLOSE"*) ;;
        *) printf '%s' "$_cx_in"; return 0 ;;
    esac
    _cx_out=
    while :; do
        case "$_cx_in" in
            *"$CC_OPEN"*"$CC_CLOSE"*) ;;
            *) break ;;
        esac
        _cx_out=$_cx_out${_cx_in%%"$CC_OPEN"*}
        _cx_in=${_cx_in#*"$CC_OPEN"}
        _cx_name=${_cx_in%%"$CC_CLOSE"*}
        _cx_in=${_cx_in#*"$CC_CLOSE"}
        case "$_cx_name" in
            root) _cx_out=$_cx_out$ROOT ;;
            work) _cx_out=$_cx_out$CC_WORK ;;
            target) _cx_out=$_cx_out$CV_TARGET ;;
            opt) _cx_out=$_cx_out$CV_OPT ;;
            mode) _cx_out=$_cx_out$CV_MODE ;;
            *)
                case "$_cx_name" in
                    *[!A-Za-z0-9_]* | '') _cx_val='' ;;
                    *) eval "_cx_val=\${CC_VAR_$_cx_name-}" ;;
                esac
                _cx_out=$_cx_out$_cx_val
                ;;
        esac
    done
    printf '%s' "$_cx_out$_cx_in"
}

cc_resolve_path() {
    _rp=$(cc_expand "$1")
    case "$_rp" in
        /* | [A-Za-z]:[\\/]*) printf '%s' "$_rp" ;;
        *) printf '%s' "$ROOT/$_rp" ;;
    esac
}

cc_variant_name() {
    _vn=
    [ "$CV_TARGET" = - ] || _vn=$CV_TARGET
    [ "$CV_OPT" = - ] || _vn="${_vn:+$_vn-}o$CV_OPT"
    [ "$CV_MODE" = - ] || _vn="${_vn:+$_vn-}$CV_MODE"
    printf '%s' "${_vn:-default}"
}

# Record a failed row. $1 = line, $2 = message.
cc_fail() {
    CC_FAILURES=$((CC_FAILURES + 1))
    CV_FAILED=1
    printf 'FAIL %s:%s %s [%s]: %s\n' "$CC_FILE" "$1" "$CC_CASE" "$(cc_variant_name)" "$2" >&2
}

cc_skip() {
    CC_SKIPPED=$((CC_SKIPPED + 1))
}

cc_isa_runnable() {
    case "$1" in
        - | scalar) return 0 ;;
    esac
    printf '%s\n' "$CC_ISAS" | grep -qx "$1"
}

# ---------------------------------------------------------------- actions

cc_flags() {
    # CV_FLAGS: the variant's --target/--opt-level/--backend-mode plus the
    # case's args, word-split where they are used.
    CV_FLAGS=
    [ "$CV_TARGET" = - ] || CV_FLAGS="$CV_FLAGS --target $CV_TARGET"
    [ "$CV_OPT" = - ] || CV_FLAGS="$CV_FLAGS --opt-level $CV_OPT"
    [ "$CV_MODE" = - ] || CV_FLAGS="$CV_FLAGS --backend-mode $CV_MODE"
    CV_FLAGS="$CV_FLAGS $(cc_expand "$CC_ARGS")"
}

cc_run_step() {
    # $1 = step name; rest = command. Captures CV_OUT/CV_ERR/CV_EXIT.
    _rs_name=$1
    shift
    CV_OUT="$CV_DIR/$_rs_name.stdout"
    CV_ERR="$CV_DIR/$_rs_name.stderr"
    set +e
    "$@" > "$CV_OUT" 2> "$CV_ERR"
    CV_EXIT=$?
    set -e
}

cc_require_step() {
    # $1 = what; succeeds when CV_EXIT is 0, otherwise reports the output.
    [ "$CV_EXIT" -eq 0 ] && return 0
    cc_fail "$CC_LINE" "$1 failed (exit $CV_EXIT)"
    echo "  stdout:" >&2
    cc_quote_lines "$CV_OUT"
    echo "  stderr:" >&2
    cc_quote_lines "$CV_ERR"
    return 1
}

cc_compile() {
    CV_ASM="$CV_DIR/out.s"
    _cc_key=$(printf '%s|%s|%s' "$CV_SOURCE" "$CV_FLAGS" "$1" | cksum | tr ' ' '-')
    if [ -f "$CC_WORK/.cache/$_cc_key.s" ]; then
        cp "$CC_WORK/.cache/$_cc_key.s" "$CV_ASM"
        cp "$CC_WORK/.cache/$_cc_key.stdout" "$CV_DIR/compile.stdout"
        cp "$CC_WORK/.cache/$_cc_key.stderr" "$CV_DIR/compile.stderr"
        CV_OUT="$CV_DIR/compile.stdout"
        CV_ERR="$CV_DIR/compile.stderr"
        CV_EXIT=0
        return 0
    fi
    echo "[codegen-cases] compile $CC_CASE [$(cc_variant_name)]" >&2
    # shellcheck disable=SC2086
    cc_run_step "compile$1" "$COMPILER" compile "$CV_SOURCE" $CV_FLAGS -o "$CV_ASM"
    if [ "$CV_EXIT" -eq 0 ] && [ -z "$1" ]; then
        mkdir -p "$CC_WORK/.cache"
        cp "$CV_ASM" "$CC_WORK/.cache/$_cc_key.s"
        cp "$CV_OUT" "$CC_WORK/.cache/$_cc_key.stdout"
        cp "$CV_ERR" "$CC_WORK/.cache/$_cc_key.stderr"
    fi
}

cc_assemble() {
    _as_target=$CV_TARGET
    [ "$_as_target" != - ] || _as_target=$CC_HOST-x86_64
    case "$CC_HOST:$_as_target" in
        linux:linux-x86_64)
            cc_run_step assemble as "$CV_ASM" -o "$CV_DIR/out.o"
            cc_require_step "GNU as" || return 1
            ;;
        linux:windows-x86_64)
            command -v clang >/dev/null 2>&1 || return 0
            cc_run_step assemble clang --target=x86_64-pc-windows-msvc -c "$CV_ASM" -o "$CV_DIR/out.obj"
            cc_require_step "clang (Windows assembly)" || return 1
            ;;
        windows:*)
            command -v clang >/dev/null 2>&1 || {
                cc_fail "$CC_LINE" "clang is required to assemble on Windows"
                return 1
            }
            case "$_as_target" in
                linux-x86_64) _as_triple=x86_64-unknown-linux-gnu ;;
                *) _as_triple=x86_64-pc-windows-msvc ;;
            esac
            cc_run_step assemble clang --target=$_as_triple -c "$CV_ASM" -o "$CV_DIR/out.obj"
            cc_require_step "clang ($_as_target assembly)" || return 1
            ;;
    esac
}

cc_do_action() {
    CV_RAN=1
    case "$CC_DO" in
        none)
            CV_EXIT=0
            ;;
        compile)
            cc_compile ''
            if [ "$CC_HAS_EXIT" -eq 0 ] || [ "$CV_EXIT" -eq 0 ]; then
                cc_require_step compile || return 1
                [ "$CC_ASSEMBLE" -eq 0 ] || cc_assemble || return 1
                if [ "$CC_REPEATABLE" -eq 1 ]; then
                    mv "$CV_ASM" "$CV_DIR/first.s"
                    cc_compile repeat
                    cc_require_step "repeat compile" || return 1
                    cmp -s "$CV_DIR/first.s" "$CV_ASM" || {
                        cc_fail "$CC_LINE" "two compilations produced different assembly"
                        return 1
                    }
                fi
                # Rows about stdout/stderr read the compiler's own output.
                CV_OUT="$CV_DIR/compile.stdout"
                CV_ERR="$CV_DIR/compile.stderr"
                CV_EXIT=0
            fi
            ;;
        check)
            # shellcheck disable=SC2086
            cc_run_step check "$COMPILER" check "$CV_SOURCE" $(cc_expand "$CC_ARGS")
            ;;
        tl-run)
            if ! cc_isa_runnable "$CV_MODE"; then
                CV_RAN=0
                return 0
            fi
            # shellcheck disable=SC2086
            cc_run_step run "$COMPILER" run "$CV_SOURCE" $CV_FLAGS
            ;;
        build | build-run)
            CV_BIN="$CV_DIR/program"
            echo "[codegen-cases] build $CC_CASE [$(cc_variant_name)]" >&2
            # shellcheck disable=SC2086
            cc_run_step build "$COMPILER" build "$CV_SOURCE" $CV_FLAGS -o "$CV_BIN"
            cc_require_step build || return 1
            [ -x "$CV_BIN" ] || [ -x "$CV_BIN.exe" ] || {
                cc_fail "$CC_LINE" "build produced no executable"
                return 1
            }
            [ "$CC_DO" = build-run ] || return 0
            if ! cc_isa_runnable "$CV_MODE"; then
                CV_RAN=0
                return 0
            fi
            [ -x "$CV_BIN" ] || CV_BIN="$CV_BIN.exe"
            cc_run_step run "$CV_BIN"
            ;;
        link-run)
            cc_compile ''
            cc_require_step compile || return 1
            if ! cc_isa_runnable "$CV_MODE"; then
                CV_RAN=0
                return 0
            fi
            if [ "$CC_HOST" = linux ]; then
                cc_run_step assemble as "$CV_ASM" -o "$CV_DIR/out.o"
                cc_require_step "GNU as" || return 1
                cc_run_step link ld "$CV_DIR/out.o" -o "$CV_DIR/program" -static \
                    -e "$(linux_entry_symbol_for_asm "$CV_ASM")"
                cc_require_step "GNU ld" || return 1
                cc_run_step run "$CV_DIR/program"
            else
                # shellcheck disable=SC2086
                cc_run_step run "$COMPILER" run "$CV_SOURCE" $CV_FLAGS
            fi
            ;;
        *)
            cc_fail "$CC_LINE" "unknown action: $CC_DO"
            return 1
            ;;
    esac
    return 0
}

# ---------------------------------------------------------------- cases

# cc_case LINE ID DO SOURCE ARGS HOSTS ASSEMBLE REPEATABLE HAS_EXIT
cc_case() {
    CC_LINE=$1
    CC_CASE=$2
    CC_DO=$3
    CC_SOURCE=$4
    CC_ARGS=$5
    CC_HOSTS=$6
    CC_ASSEMBLE=$7
    CC_REPEATABLE=$8
    CC_HAS_EXIT=$9
    CC_ACTIVE=1
    case "$CC_CASE" in
        $CC_ONLY) CC_SELECTED=$((CC_SELECTED + 1)) ;;
        *) CC_ACTIVE=0; return 0 ;;
    esac
    case " $CC_HOSTS " in
        *" all "* | *" $CC_HOST "*) ;;
        *)
            echo "[codegen-cases] skip $CC_CASE (hosts: $CC_HOSTS)"
            CC_ACTIVE=0
            ;;
    esac
}

# cc_variant FUNCTION TARGET OPT MODE
cc_variant() {
    [ "$CC_ACTIVE" -eq 1 ] || return 0
    CV_TARGET=$2
    CV_OPT=$3
    CV_MODE=$4
    CV_DIR="$CC_WORK/$CC_CASE/$(cc_variant_name)"
    rm -rf "$CV_DIR"
    mkdir -p "$CV_DIR"
    CV_FAILED=0
    CV_SUBJECT=
    CV_BAD_SUBJECT=0
    CV_ASM=
    CV_OUT="$CV_DIR/none.stdout"
    CV_ERR="$CV_DIR/none.stderr"
    : > "$CV_OUT"
    : > "$CV_ERR"
    CV_EXIT=0
    CV_RAN=1
    CV_N=0
    if [ -n "$CC_SOURCE" ]; then
        CV_SOURCE=$(cc_resolve_path "$CC_SOURCE")
    else
        CV_SOURCE=
    fi
    cc_flags
    if [ "$CC_SETUP" != : ]; then
        eval "$CC_SETUP" || {
            cc_fail "$CC_LINE" "setup failed"
            return 0
        }
    fi
    if cc_do_action; then
        if [ "$CC_HAS_EXIT" -eq 0 ] && [ "$CV_RAN" -eq 1 ] && [ "$CV_EXIT" -ne 0 ]; then
            cc_fail "$CC_LINE" "$CC_DO exited $CV_EXIT, expected 0"
            echo "  stderr:" >&2
            cc_quote_lines "$CV_ERR"
            return 0
        fi
        "$1"
    fi
    if [ "$CV_FAILED" -eq 0 ]; then
        if [ "$CV_RAN" -eq 1 ]; then
            echo "[codegen-cases] PASS $CC_CASE [$(cc_variant_name)]"
        else
            echo "[codegen-cases] PASS $CC_CASE [$(cc_variant_name)] (run skipped: host cannot execute $CV_MODE)"
        fi
    fi
}

# ---------------------------------------------------------------- rows

cc_row() {
    case "$CV_BAD_SUBJECT" in
        0)
            CC_ROWS=$((CC_ROWS + 1))
            return 0
            ;;
        2) cc_skip ;;
    esac
    return 1
}

cc_need_subject() {
    [ -n "$CV_SUBJECT" ] && return 0
    CV_SUBJECT=$CV_ASM
    [ -n "$CV_SUBJECT" ] && return 0
    cc_fail "$1" "no subject selected"
    return 1
}

cc_run_output_row() {
    # Rows that read the run step are skipped when the run was skipped.
    [ "$CV_RAN" -eq 1 ] && return 0
    cc_skip
    return 1
}

# Subject rows (in, narrow) select what the next rows read; they fail when the
# subject does not exist but are not counted as expectations.
a_in() {
    _ai_line=$1
    _ai_kind=$2
    _ai_arg=$(cc_expand "${3-}")
    CV_BAD_SUBJECT=0
    CV_N=$((CV_N + 1))
    case "$_ai_kind" in
        asm)
            CV_SUBJECT=$CV_ASM
            if [ -z "$CV_SUBJECT" ] || [ ! -f "$CV_SUBJECT" ]; then
                cc_fail "$_ai_line" "no assembly for this action"
                CV_BAD_SUBJECT=1
            fi
            ;;
        stdout | stderr)
            if [ "$CV_RAN" -eq 0 ]; then
                CV_BAD_SUBJECT=2
                return 0
            fi
            if [ "$_ai_kind" = stdout ]; then CV_SUBJECT=$CV_OUT; else CV_SUBJECT=$CV_ERR; fi
            ;;
        file)
            CV_SUBJECT=$(cc_resolve_path "$_ai_arg")
            if [ ! -f "$CV_SUBJECT" ]; then
                cc_fail "$_ai_line" "missing file $_ai_arg"
                CV_BAD_SUBJECT=1
            fi
            ;;
        fn | fn-globl)
            CV_SUBJECT="$CV_DIR/subject.$CV_N"
            if [ -z "$CV_ASM" ] || ! awk -v label="$_ai_arg:" -v kind="$_ai_kind" '
                $0 == label { in_fn = 1; print; next }
                in_fn && kind == "fn" && /^\.globl[[:space:]]/ { exit 0 }
                in_fn && kind == "fn" && /^[[:space:]]*\.size[[:space:]]/ { exit 0 }
                in_fn && kind == "fn-globl" && /^[[:space:]]*\.globl[[:space:]]/ { exit 0 }
                in_fn { print }
                END { if (!in_fn) exit 2 }
            ' "$CV_ASM" > "$CV_SUBJECT"; then
                cc_fail "$_ai_line" "missing function label $_ai_arg"
                CV_BAD_SUBJECT=1
            fi
            ;;
        *)
            cc_fail "$_ai_line" "unknown subject: $_ai_kind"
            CV_BAD_SUBJECT=1
            ;;
    esac
}

a_narrow() {
    [ "$CV_BAD_SUBJECT" -eq 0 ] || return 0
    _an_line=$1
    _an_spec=$(cc_expand "$2")
    cc_need_subject "$_an_line" || return 0
    _an_name=${_an_spec%%:*}
    _an_arg=
    case "$_an_spec" in *:*) _an_arg=${_an_spec#*:} ;; esac
    CV_N=$((CV_N + 1))
    _an_out="$CV_DIR/subject.$CV_N"
    CC_ARG=$_an_arg awk -v analyzer="window-$_an_name" -f "$CC_ANALYZERS" "$CV_SUBJECT" > "$_an_out" || {
        cc_fail "$_an_line" "window $_an_spec failed"
        CV_BAD_SUBJECT=1
        return 0
    }
    CV_SUBJECT=$_an_out
    if [ ! -s "$CV_SUBJECT" ]; then
        cc_fail "$_an_line" "window $_an_spec is empty"
        CV_BAD_SUBJECT=1
    fi
}

a_exit() {
    cc_run_output_row || return 0
    CC_ROWS=$((CC_ROWS + 1))
    _ex_want=$2
    case "$_ex_want" in
        *=*)
            # MODE=STATUS words: the expectation of the variant's backend mode.
            _ex_pick=
            for _ex_word in $_ex_want; do
                case "$_ex_word" in
                    "$CV_MODE="*) _ex_pick=${_ex_word#*=} ;;
                esac
            done
            [ -n "$_ex_pick" ] || {
                cc_fail "$1" "no expected exit status for mode $CV_MODE"
                return 0
            }
            _ex_want=$_ex_pick
            ;;
    esac
    case "$_ex_want" in
        nonzero)
            [ "$CV_EXIT" -ne 0 ] || cc_fail "$1" "exited 0, expected a nonzero status"
            ;;
        *)
            [ "$CV_EXIT" -eq "$_ex_want" ] || {
                cc_fail "$1" "exited $CV_EXIT, expected $_ex_want"
                echo "  stderr:" >&2
                cc_quote_lines "$CV_ERR"
            }
            ;;
    esac
}

a_contains() {
    cc_row || return 0
    cc_need_subject "$1" || return 0
    _ac=$(cc_expand "$2")
    grep -F -- "$_ac" "$CV_SUBJECT" >/dev/null 2>&1 || cc_fail "$1" "missing text: $_ac"
}

a_not_contains() {
    cc_row || return 0
    cc_need_subject "$1" || return 0
    _ac=$(cc_expand "$2")
    if grep -F -- "$_ac" "$CV_SUBJECT" >/dev/null 2>&1; then
        cc_fail "$1" "contains forbidden text: $_ac"
    fi
}

a_match() {
    cc_row || return 0
    cc_need_subject "$1" || return 0
    _am=$(cc_expand "$3")
    grep -E $2 -- "$_am" "$CV_SUBJECT" >/dev/null 2>&1 || cc_fail "$1" "missing regex: $_am"
}

a_not_match() {
    cc_row || return 0
    cc_need_subject "$1" || return 0
    _am=$(cc_expand "$3")
    if grep -E $2 -- "$_am" "$CV_SUBJECT" >/dev/null 2>&1; then
        cc_fail "$1" "contains forbidden regex: $_am"
    fi
}

cc_compare() {
    # cc_compare GOT OP WANT: numeric for >= and <=, text for =.
    case "$2" in
        =) [ "$1" = "$3" ] ;;
        '>=' | '<=')
            case "$1" in '' | *[!0-9]*) return 1 ;; esac
            if [ "$2" = '>=' ]; then [ "$1" -ge "$3" ]; else [ "$1" -le "$3" ]; fi
            ;;
        *) return 1 ;;
    esac
}

a_count() {
    cc_row || return 0
    cc_need_subject "$1" || return 0
    _ak=$(cc_expand "$5")
    _got=$(grep $2 -- "$_ak" "$CV_SUBJECT" 2>/dev/null | wc -l | tr -d '[:space:]')
    cc_compare "$_got" "$3" "$4" || cc_fail "$1" "expected $3 $4 match(es) of [$_ak], got $_got"
}

a_next_line() {
    cc_row || return 0
    cc_need_subject "$1" || return 0
    _nl_first=$(cc_expand "$2")
    _nl_next=$(cc_expand "$3")
    if ! CC_PAT=$_nl_first CC_NEXT=$_nl_next awk '
        BEGIN { pat = ENVIRON["CC_PAT"]; nxt = ENVIRON["CC_NEXT"] }
        found { exit ($0 ~ nxt) ? 0 : 1 }
        $0 ~ pat { found = 1 }
        END { if (!found) exit 2 }
    ' "$CV_SUBJECT"; then
        cc_fail "$1" "expected /$_nl_next/ on the line after /$_nl_first/"
    fi
}

a_empty() {
    cc_row || return 0
    cc_need_subject "$1" || return 0
    if [ "$2" = empty ]; then
        [ ! -s "$CV_SUBJECT" ] || {
            cc_fail "$1" "expected empty output"
            cc_quote_lines "$CV_SUBJECT"
        }
    else
        [ -s "$CV_SUBJECT" ] || cc_fail "$1" "expected non-empty output"
    fi
}

a_metric() {
    cc_row || return 0
    cc_need_subject "$1" || return 0
    _mt_spec=$(cc_expand "$2")
    _mt_name=${_mt_spec%%:*}
    _mt_arg=
    case "$_mt_spec" in *:*) _mt_arg=${_mt_spec#*:} ;; esac
    _mt_want=$(cc_expand "$4")
    _got=$(CC_ARG=$_mt_arg awk -v analyzer="$_mt_name" -f "$CC_ANALYZERS" "$CV_SUBJECT") || _got="analyzer-error"
    cc_compare "$_got" "$3" "$_mt_want" || cc_fail "$1" "metric $_mt_spec: expected $3 $_mt_want, got $_got"
}

a_capture() {
    cc_row || return 0
    cc_need_subject "$1" || return 0
    _cp_re=$(cc_expand "$3")
    _cp_sep=$(printf '\001')
    _cp_val=$(grep -E -- "$_cp_re" "$CV_SUBJECT" 2>/dev/null |
        sed -n -E "1s$_cp_sep$_cp_re$_cp_sep\\1${_cp_sep}p" || true)
    eval "CC_VAR_$2=\$_cp_val"
    [ -n "$_cp_val" ] || cc_fail "$1" "capture $2: no line matches $_cp_re"
}

a_check() {
    cc_row || return 0
    _ck_line=$1
    _ck_name=$2
    shift 2
    _ck_n=$#
    while [ "$_ck_n" -gt 0 ]; do
        _ck_word=$1
        shift
        set -- "$@" "$(cc_expand "$_ck_word")"
        _ck_n=$((_ck_n - 1))
    done
    _ck_status=0
    "plugin_$(printf '%s' "$_ck_name" | tr - _)" "$@" || _ck_status=$?
    case "$_ck_status" in
        0) ;;
        2)
            # The plugin's optional tool is absent: skipped, not checked.
            CC_ROWS=$((CC_ROWS - 1))
            cc_skip
            ;;
        *) cc_fail "$_ck_line" "check $_ck_name failed" ;;
    esac
}

cc_fn_exists() {
    [ -n "$CV_ASM" ] && grep -Fx -- "$(cc_expand "$1"):" "$CV_ASM" >/dev/null 2>&1
}

cc_mode_is() {
    case " $1 " in
        *" $CV_MODE "*) return 0 ;;
    esac
    return 1
}

# ---------------------------------------------------------------- front end

# Translate one case file to shell. Rows become calls of the a_* functions
# above; every case becomes one function run once per variant.
cc_translate() {
    awk -v file="$1" '
    function sq(s) { gsub(/\047/, "\047\\\047\047", s); return "\047" s "\047" }
    function die(msg) { printf "%s:%d: %s\n", file, NR, msg > "/dev/stderr"; bad = 1; exit 1 }
    function words(s, arr) { return split(s, arr, /[ \t]+/) }
    function set_default(key, value) { if (ncase == 0) dflt[key] = value; else cfg[key] = value }
    function start_case(id) {
        if (ncase > 0) finish_case()
        if (id in seen) die("duplicate case " id)
        seen[id] = 1
        ncase++
        for (k in cfg) delete cfg[k]
        for (k in dflt) cfg[k] = dflt[k]
        cfg["id"] = id
        cfg["line"] = NR
        nbody = 0
        depth = 0
        has_exit = 0
        pending_after = ""
    }
    function body(s) { nbody++; bodyl[nbody] = s }
    function finish_case(   i, nt, no, nm, t, o, m, T, O, M, setup) {
        if (pending_after != "") die("after without next-line")
        if (depth != 0) die("unclosed if-fn in case " cfg["id"])
        fn = "cc_case_" ncase
        print fn "() {"
        print ":"
        for (i = 1; i <= nbody; i++) print bodyl[i]
        print "}"
        setup = (("setup" in cfg) ? cfg["setup"] : ":")
        print "CC_SETUP=" sq(setup)
        print "cc_case " cfg["line"] " " sq(cfg["id"]) " " sq(cfg["do"]) " " sq(cfg["source"]) " " \
            sq(cfg["args"]) " " sq(cfg["hosts"]) " " (cfg["assemble"] + 0) " " (cfg["repeatable"] + 0) " " has_exit
        nt = words(cfg["target"], T)
        no = words(cfg["opt"], O)
        nm = words(cfg["mode"], M)
        for (t = 1; t <= nt; t++)
            for (o = 1; o <= no; o++)
                for (m = 1; m <= nm; m++)
                    print "cc_variant " fn " " sq(T[t]) " " sq(O[o]) " " sq(M[m])
    }
    BEGIN {
        dflt["target"] = "linux-x86_64"; dflt["opt"] = "2"; dflt["mode"] = "-"
        dflt["do"] = "compile"; dflt["hosts"] = "all"; dflt["args"] = ""; dflt["source"] = ""
        ncase = 0; infile = 0; nfile = 0
    }
    {
        raw = $0
        sub(/\r$/, "", raw)
        if (infile) {
            if (raw ~ /^[ \t]*end-file[ \t]*$/) { infile = 0; print "CC_EOF_FILE_" nfile; next }
            print raw
            next
        }
        line = raw
        sub(/^[ \t]+/, "", line)
        if (line == "" || line ~ /^#/) next
        sp = index(line, " ")
        if (sp) { kw = substr(line, 1, sp - 1); rest = substr(line, sp + 1) } else { kw = line; rest = "" }
        if (kw == "file") {
            if (ncase > 0) die("file must come before the first case")
            nfile++
            print "cat > \"$CC_WORK/" rest "\" <<\047CC_EOF_FILE_" nfile "\047"
            infile = 1
            next
        }
        if (kw == "case") { start_case(rest); next }
        if (kw == "source" || kw == "target" || kw == "opt" || kw == "mode" || kw == "args" || kw == "do" || kw == "hosts") {
            set_default(kw, rest); next
        }
        if (kw == "assemble" || kw == "repeatable") { set_default(kw, 1); next }
        if (kw == "setup") {
            n = words(rest, W)
            s = W[1]
            gsub(/-/, "_", s)
            s = "plugin_" s
            for (i = 2; i <= n; i++) s = s " \"$(cc_expand " sq(W[i]) ")\""
            if (ncase == 0) dflt["setup"] = (("setup" in dflt) ? dflt["setup"] " && " : "") s
            else cfg["setup"] = (("setup" in cfg) ? cfg["setup"] " && " : "") s
            next
        }
        if (ncase == 0) die("expectation before the first case: " kw)
        if (pending_after != "" && kw != "next-line") die("after must be followed by next-line")
        if (kw == "in") {
            sp = index(rest, " ")
            if (sp) body("a_in " NR " " sq(substr(rest, 1, sp - 1)) " " sq(substr(rest, sp + 1)))
            else body("a_in " NR " " sq(rest))
        } else if (kw == "narrow") body("a_narrow " NR " " sq(rest))
        else if (kw == "exit") { has_exit = 1; body("a_exit " NR " " sq(rest)) }
        else if (kw == "contains") body("a_contains " NR " " sq(rest))
        else if (kw == "not-contains") body("a_not_contains " NR " " sq(rest))
        else if (kw == "match") body("a_match " NR " \"\" " sq(rest))
        else if (kw == "match-i") body("a_match " NR " -i " sq(rest))
        else if (kw == "not-match") body("a_not_match " NR " \"\" " sq(rest))
        else if (kw == "not-match-i") body("a_not_match " NR " -i " sq(rest))
        else if (kw == "count" || kw == "count-fixed") {
            if (split(rest, P, " ") < 3) die(kw " needs OP N TEXT")
            op = P[1]; n = P[2]
            if (op != "=" && op != ">=" && op != "<=") die("bad operator " op)
            if (n !~ /^[0-9]+$/) die("bad count " n)
            text = substr(rest, length(op) + length(n) + 3)
            body("a_count " NR " " (kw == "count" ? "-E" : "-F") " " sq(op) " " n " " sq(text))
        } else if (kw == "after") pending_after = rest
        else if (kw == "next-line") {
            if (pending_after == "") die("next-line without after")
            body("a_next_line " NR " " sq(pending_after) " " sq(rest))
            pending_after = ""
        } else if (kw == "empty" || kw == "not-empty") body("a_empty " NR " " kw)
        else if (kw == "metric") {
            if (split(rest, P, " ") < 3) die("metric needs NAME OP VALUE")
            if (P[2] != "=" && P[2] != ">=" && P[2] != "<=") die("bad operator " P[2])
            body("a_metric " NR " " sq(P[1]) " " sq(P[2]) " " sq(substr(rest, length(P[1]) + length(P[2]) + 3)))
        } else if (kw == "capture") {
            sp = index(rest, " ")
            if (!sp) die("capture needs VAR ERE")
            var = substr(rest, 1, sp - 1)
            if (var !~ /^[A-Za-z_][A-Za-z0-9_]*$/) die("bad capture name " var)
            body("a_capture " NR " " var " " sq(substr(rest, sp + 1)))
        } else if (kw == "check") {
            n = words(rest, W)
            s = "a_check " NR
            for (i = 1; i <= n; i++) s = s " " sq(W[i])
            body(s)
        } else if (kw == "if-fn" || kw == "if-no-fn") {
            depth++
            body("if " (kw == "if-no-fn" ? "! " : "") "cc_fn_exists " sq(rest) "; then :")
        } else if (kw == "if-mode") {
            depth++
            body("if cc_mode_is " sq(rest) "; then :")
        } else if (kw == "else") {
            if (depth == 0) die("else without if")
            body("else :")
        } else if (kw == "end-if") {
            if (depth == 0) die("end-if without if")
            depth--
            body("fi")
        } else die("unknown directive " kw)
    }
    END {
        if (bad) exit 1
        if (infile) { printf "%s: unterminated file block\n", file > "/dev/stderr"; exit 1 }
        if (ncase > 0) finish_case()
    }
    ' "$1"
}

# ---------------------------------------------------------------- main

CC_WORK_ROOT=${CODEGEN_CASES_WORKDIR:-$ROOT/target/codegen-cases}

for CC_FILE do
    [ -f "$CC_FILE" ] || {
        echo "missing case file: $CC_FILE" >&2
        exit 2
    }
    CC_NAME=$(basename "$CC_FILE" .cases)
    CC_WORK="$CC_WORK_ROOT/$CC_NAME"
    rm -rf "$CC_WORK"
    mkdir -p "$CC_WORK"
    cc_translate "$CC_FILE" > "$CC_WORK/plan.sh" || exit 2
    if [ "$CC_LIST" -eq 1 ]; then
        awk -v file="$CC_FILE" '
            /^cc_case / { id = $3; gsub(/\047/, "", id); next }
            /^cc_variant / { v = $3 " " $4 " " $5; gsub(/\047/, "", v); printf "%s %s [%s]\n", file, id, v }
        ' "$CC_WORK/plan.sh"
        continue
    fi
    echo "[codegen-cases] $CC_FILE"
    . "$CC_WORK/plan.sh"
done

[ "$CC_LIST" -eq 0 ] || exit 0

if [ "$CC_SELECTED" -eq 0 ]; then
    echo "[codegen-cases] no case matches --only $CC_ONLY" >&2
    exit 1
fi
if [ "$CC_FAILURES" -ne 0 ]; then
    echo "[codegen-cases] FAILED: $CC_FAILURES failure(s); $CC_ROWS expectation(s) checked, $CC_SKIPPED skipped" >&2
    exit 1
fi
echo "[codegen-cases] passed: $CC_ROWS expectation(s) checked, $CC_SKIPPED skipped"
