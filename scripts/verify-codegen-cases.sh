#!/usr/bin/env sh
set -eu

# verify-codegen-cases.sh - table-driven compile / run / assembly-shape and CLI
# transcript runner.
#
# usage: scripts/verify-codegen-cases.sh [--list | --list-fixtures] [--only CASE-GLOB] FILE.cases...
#
# Execution is performed by the native zero-dependency TypeLisp runner under
# tools/codegen-cases-runner/, built once per compiler/source/host key and
# cached under target/codegen-cases-runner/<key>/.
#
# --list and --list-fixtures run without a compiler (used by ci-affected map
# audits and app corpus discovery).

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
set -f

usage() {
    echo "usage: scripts/verify-codegen-cases.sh [--list | --list-fixtures] [--only CASE-GLOB] FILE.cases..." >&2
    exit 2
}

CC_LIST=0
CC_FIXTURES=0
CC_ONLY='*'
while [ "$#" -gt 0 ]; do
    case "$1" in
        --list) CC_LIST=1; shift ;;
        --list-fixtures) CC_LIST=1; CC_FIXTURES=1; shift ;;
        --only) [ "$#" -ge 2 ] || usage; CC_ONLY=$2; shift 2 ;;
        --) shift; break ;;
        -*) usage ;;
        *) break ;;
    esac
done
[ "$#" -gt 0 ] || usage

. "$ROOT/scripts/lib-linux-entry.sh"
. "$ROOT/scripts/lib-ci-timing.sh"
. "$ROOT/scripts/lib-gate.sh"
. "$ROOT/scripts/lib-ci-compiler-artifact.sh"
. "$ROOT/scripts/lib-bounded-pool.sh"

CC_HOST=linux
BIN_EXT=
case "$(uname -s)" in
    Linux*) CC_HOST=linux ;;
    MINGW* | MSYS* | CYGWIN*)
        CC_HOST=windows
        BIN_EXT=.exe
        ;;
    *) CC_HOST=unknown ;;
esac

cc_native_path() {
    if [ "$CC_HOST" = windows ] && command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        printf '%s\n' "$1"
    fi
}

# ---------------------------------------------------------------- front end (--list / --list-fixtures / stub-only)

cc_translate() {
    awk -v file="$1" -v fixtures="$CC_FIXTURES" -v root="$ROOT" '
    function sq(s) { gsub(/\047/, "\047\\\047\047", s); return "\047" s "\047" }
    function die(msg) { printf "%s:%d: %s\n", file, NR, msg > "/dev/stderr"; bad = 1; exit 1 }
    function words(s, arr) { return split(s, arr, /[ \t]+/) }
    function set_default(key, value) { if (ncase == 0) dflt[key] = value; else cfg[key] = value }
    function shellify(s,   out, i, j, name) {
        out = ""
        while ((i = index(s, "{{")) > 0) {
            j = index(substr(s, i + 2), "}}")
            if (j == 0) break
            name = substr(s, i + 2, j - 1)
            if (name ~ /^[A-Za-z0-9_-]+$/) {
                gsub(/-/, "_", name)
                out = out substr(s, 1, i - 1) "${CCV_" name "}"
            } else out = out substr(s, 1, i + j + 2)
            s = substr(s, i + j + 3)
        }
        return out s
    }
    function alts(s,   n, P, i, out) {
        n = split(s, P, / \|\| /)
        out = ""
        for (i = 1; i <= n; i++) out = out " " sq(P[i])
        return out
    }
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
        step_open = 0
        pending_after = ""
    }
    function body(s) { nbody++; bodyl[nbody] = s }
    function close_step() {
        if (step_open && !step_exit) body("a_exit " step_line " 0")
        step_open = 0
    }
    function open_step(s) {
        close_step()
        body(s)
        step_open = 1
        step_exit = 0
        step_line = NR
        step_depth = depth
    }
    function close_block_step() { if (step_open && step_depth >= depth) close_step() }
    function finish_case(   i, nt, no, nm, ne, t, o, m, e, T, O, M, E, setup) {
        if (fixtures) {
            if (cfg["id"] !~ /^[A-Za-z0-9_-]+$/) die("invalid fixture label")
            s = cfg["source"]
            if (s !~ /^tests\/[A-Za-z0-9_.\/-]+\.tl$/ || s ~ /(^|\/)\.(\.|)(\/|$)/ || s ~ /\/\//)
                die("invalid fixture source: " s)
            if (cfg["do"] != "none") die("fixture inventory requires do none")
            if (s in fixture_sources) die("duplicate fixture source: " s)
            fixture_sources[s] = 1
            path = root "/" s
            status = (getline unused < path); close(path)
            if (status < 0) die("missing fixture source: " s)
            print cfg["id"] "\t" s
            return
        }
        if (pending_after != "") die("after without next-line")
        if (depth != 0) die("unclosed if-block in case " cfg["id"])
        close_step()
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
        ne = words(cfg["each"], E)
        for (t = 1; t <= nt; t++)
            for (o = 1; o <= no; o++)
                for (m = 1; m <= nm; m++)
                    for (e = 1; e <= ne; e++)
                        print "cc_variant " fn " " sq(T[t]) " " sq(O[o]) " " sq(M[m]) " " sq(E[e])
    }
    function row(kw, rest,   sp, op, n, text, var, s, i, W, P) {
        if (pending_after != "" && kw != "next-line") die("after must be followed by next-line")
        if (kw == "run") open_step("cc_run " NR " \"$COMPILER\" " shellify(rest))
        else if (kw == "exec") open_step("cc_run " NR " " shellify(rest))
        else if (kw == "sh") {
            body("if ! { " shellify(rest))
            body("}; then cc_fail " NR " " sq("sh failed: " rest) "; fi")
        } else if (kw == "cwd") body("cc_cwd " NR " " sq(rest))
        else if (kw == "step") {
            close_step()
            body("CV_STEP_ID=$(cc_expand " sq(rest) ")")
        }
        else if (kw == "test") body("CC_ROWS=$((CC_ROWS + 1)); [ " shellify(rest) " ] || cc_fail " NR " " sq("test failed: " rest))
        else if (kw == "same") body("cc_same " NR " " shellify(rest))
        else if ((kw == "stdout" || kw == "stderr") && rest != "") {
            body("a_in " NR " " kw)
            sp = index(rest, " ")
            if (sp) row(substr(rest, 1, sp - 1), substr(rest, sp + 1))
            else row(rest, "")
        } else if (kw == "in") {
            sp = index(rest, " ")
            if (sp) body("a_in " NR " " sq(substr(rest, 1, sp - 1)) " " sq(substr(rest, sp + 1)))
            else body("a_in " NR " " sq(rest))
        } else if (kw == "narrow") body("a_narrow " NR " " sq(rest))
        else if (kw == "exit") {
            if (step_open) step_exit = 1; else has_exit = 1
            body("a_exit " NR " " sq(rest))
        } else if (kw == "contains") body("a_contains " NR " " sq(rest))
        else if (kw == "is") body("a_is " NR " " sq(rest))
        else if (kw == "not-contains") body("a_not_contains " NR " " sq(rest))
        else if (kw == "contains-any") body("a_contains_any " NR alts(rest))
        else if (kw == "order") body("a_order " NR alts(rest))
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
            close_step()
            depth++
            body("if " (kw == "if-no-fn" ? "! " : "") "cc_fn_exists " sq(rest) "; then :")
        } else if (kw == "if-mode" || kw == "if-host" || kw == "if-isa") {
            close_step()
            depth++
            s = (kw == "if-mode" ? "cc_mode_is" : kw == "if-host" ? "cc_host_is" : "cc_isa_native")
            body("if " s " \"$(cc_expand " sq(rest) ")\"; then :")
        } else if (kw == "else") {
            if (depth == 0) die("else without if")
            close_block_step()
            body("else :")
        } else if (kw == "end-if") {
            if (depth == 0) die("end-if without if")
            close_block_step()
            depth--
            body("fi")
        } else die("unknown directive " kw)
    }
    BEGIN {
        dflt["target"] = "linux-x86_64"; dflt["opt"] = "2"; dflt["mode"] = "-"; dflt["each"] = "-"
        dflt["do"] = "compile"; dflt["hosts"] = "all"; dflt["args"] = ""; dflt["source"] = ""
        ncase = 0; infile = 0; nfile = 0
    }
    {
        raw = $0
        sub(/\r$/, "", raw)
        if (infile) {
            if (raw ~ /^[ \t]*end-file[ \t]*$/) {
                infile = 0
                if (ncase > 0) body("CC_EOF_FILE_" nfile); else print "CC_EOF_FILE_" nfile
                next
            }
            if (ncase > 0) body(raw); else print raw
            next
        }
        line = raw
        sub(/^[ \t]+/, "", line)
        if (line == "" || line ~ /^#/) next
        sp = index(line, " ")
        if (sp) { kw = substr(line, 1, sp - 1); rest = substr(line, sp + 1) } else { kw = line; rest = "" }
        if (fixtures && kw != "case" && kw != "source" && !(kw == "do" && rest == "none"))
            die("unsupported fixture inventory directive: " kw)
        if (kw == "file") {
            nfile++
            flags = "-"
            if (rest ~ /^-[nx]+ /) { flags = substr(rest, 2, index(rest, " ") - 2); rest = substr(rest, index(rest, " ") + 1) }
            s = "cc_file " NR " " sq(rest) " " flags
            s = s (ncase > 0 ? "" : " \"$CC_WORK\"") " <<\047CC_EOF_FILE_" nfile "\047"
            if (ncase > 0) body(s); else print s
            infile = 1
            next
        }
        if (kw == "case") { start_case(rest); next }
        if (kw == "source" || kw == "target" || kw == "opt" || kw == "mode" || kw == "each" || kw == "args" || kw == "do" || kw == "hosts") {
            set_default(kw, rest); next
        }
        if (kw == "assemble" || kw == "repeatable") { set_default(kw, 1); next }
        if (kw == "setup") {
            n = words(rest, W)
            s = W[1]
            gsub(/-/, "_", s)
            s = "plugin_" s
            for (i = 2; i <= n; i++) s = s " \"$(cc_expand " sq(W[i]) ")\""
            if (ncase == 0) {
                if ("setup" in dflt) dflt["setup"] = dflt["setup"] " && " s
                else dflt["setup"] = s
            } else {
                if ("setup" in cfg) cfg["setup"] = cfg["setup"] " && " s
                else cfg["setup"] = s
            }
            next
        }
        if (ncase == 0) die("expectation before the first case: " kw)
        row(kw, rest)
    }
    END {
        if (bad) exit 1
        if (fixtures && ncase == 0) die("empty fixture inventory")
        if (infile) { printf "%s: unterminated file block\n", file > "/dev/stderr"; exit 1 }
        if (ncase > 0) finish_case()
    }
    ' "$1"
}

CC_WORK_ROOT=${CODEGEN_CASES_WORKDIR:-$ROOT/target/codegen-cases}
CC_WORK_SUFFIX=
if [ "$CC_ONLY" != '*' ]; then
    CC_WORK_SUFFIX=.only-$(printf '%s' "$CC_ONLY" | tr -c 'A-Za-z0-9._-' '_')
fi

if [ "$CC_LIST" -eq 1 ]; then
    for CC_FILE do
        [ -f "$CC_FILE" ] || {
            echo "missing case file: $CC_FILE" >&2
            exit 2
        }
        if [ "$CC_FIXTURES" -eq 1 ]; then
            cc_translate "$CC_FILE" || exit 2
            continue
        fi
        CC_NAME=$(basename "$CC_FILE" .cases)
        CC_WORK="$CC_WORK_ROOT/$CC_NAME$CC_WORK_SUFFIX"
        rm -rf "$CC_WORK"
        mkdir -p "$CC_WORK"
        cc_translate "$CC_FILE" > "$CC_WORK/plan.sh" || exit 2
        awk -v file="$CC_FILE" '
            /^cc_case / { id = $3; gsub(/\047/, "", id); next }
            /^cc_variant / { v = $3 " " $4 " " $5 ($6 == "\047-\047" ? "" : " " $6); gsub(/\047/, "", v); printf "%s %s [%s]\n", file, id, v }
        ' "$CC_WORK/plan.sh"
    done
    exit 0
fi

# ---------------------------------------------------------------- compiler & SIMD init

gate_compiler
gate_compiler_absolute
gate_require_compiler
. "$ROOT/scripts/lib-simd-execution.sh"
simd_execution_init

# Linux entry-selection contract hook exercised by scripts/verify-linux-entry-callers.sh.
cc_linux_link_asm() {
    CV_ENTRY=$(linux_entry_symbol_for_asm "$CV_ASM") || exit $?
    _cc_stdlib_archive=$(linux_stdlib_archive_for_asm "$CV_ASM" "${COMPILER:-}")
    if [ -n "$_cc_stdlib_archive" ]; then
        cc_run_step link ld "$CV_DIR/out.o" -o "$CV_DIR/program" -static \
            --gc-sections --start-group "$_cc_stdlib_archive" --end-group \
            -e "$CV_ENTRY"
    else
        cc_run_step link ld "$CV_DIR/out.o" -o "$CV_DIR/program" -static \
            -e "$CV_ENTRY"
    fi
    cc_require_step "GNU ld" || return 1
}

# Compiler-less shell stub mode for scripts/verify-linux-entry-transcripts.sh,
# which supplies a #!/usr/bin/env sh fake compiler that must never be invoked.
cc_compiler_is_script_stub() {
    _hdr=$(LC_ALL=C dd if="$1" bs=2 count=1 2>/dev/null || true)
    [ "$_hdr" = '#!' ]
}

if cc_compiler_is_script_stub "$COMPILER"; then
    CC_FAILURES=0
    CC_ROWS=0
    CC_SKIPPED=0
    CC_SELECTED=0
    CCV_root=$ROOT
    CCV_native_root=$(cc_native_path "$ROOT")
    CCV_compiler=$COMPILER
    CCV_host=$CC_HOST
    CCV_host_target=$CC_HOST-x86_64
    cc_expand() {
        _cx_in=$1
        case "$_cx_in" in *'{{'*'}}'*) ;; *) printf '%s' "$_cx_in"; return 0 ;; esac
        _cx_out=
        while :; do
            case "$_cx_in" in *'{{'*'}}'*) ;; *) break ;; esac
            _cx_out=$_cx_out${_cx_in%%'{{'*}
            _cx_in=${_cx_in#*'{{'}
            _cx_name=${_cx_in%%'}}'*}
            _cx_in=${_cx_in#*'}}'}
            case "$_cx_name" in
                *[!A-Za-z0-9_-]* | '') _cx_val='' ;;
                *) eval "_cx_val=\${CCV_$(printf '%s' "$_cx_name" | tr - _)-}" ;;
            esac
            _cx_out=$_cx_out$_cx_val
        done
        printf '%s' "$_cx_out$_cx_in"
    }
    cc_resolve_path() {
        _rp=$(cc_expand "$1")
        case "$_rp" in /* | [A-Za-z]:[\\/]*) printf '%s' "$_rp" ;; *) printf '%s' "${2:-$ROOT}/$_rp" ;; esac
    }
    cc_file() {
        _cf_path=$(cc_resolve_path "$2" "${4:-$CV_DIR}")
        mkdir -p "$(dirname -- "$_cf_path")"
        cat > "$_cf_path"
    }
    cc_fail() { CC_FAILURES=$((CC_FAILURES + 1)); CV_FAILED=1; printf 'FAIL %s:%s %s: %s\n' "$CC_FILE" "$1" "$CC_CASE" "$2" >&2; }
    cc_case() { CC_LINE=$1; CC_CASE=$2; CC_DO=$3; CC_ACTIVE=1; CC_SELECTED=$((CC_SELECTED + 1)); }
    cc_variant() {
        CV_DIR="$CC_WORK/$CC_CASE"
        rm -rf "$CV_DIR"
        mkdir -p "$CV_DIR"
        CCV_dir=$CV_DIR
        CCV_native_dir=$(cc_native_path "$CV_DIR")
        CV_FAILED=0
        "$1"
        [ "$CV_FAILED" -ne 0 ] || echo "[codegen-cases] PASS $CC_CASE [default]"
    }
    for CC_FILE do
        [ -f "$CC_FILE" ] || { echo "missing case file: $CC_FILE" >&2; exit 2; }
        CC_NAME=$(basename "$CC_FILE" .cases)
        CC_WORK="$CC_WORK_ROOT/$CC_NAME$CC_WORK_SUFFIX"
        CCV_work=$CC_WORK
        CCV_native_work=$(cc_native_path "$CC_WORK")
        rm -rf "$CC_WORK"
        mkdir -p "$CC_WORK"
        cc_translate "$CC_FILE" > "$CC_WORK/plan.sh" || exit 2
        . "$CC_WORK/plan.sh"
    done
    [ "$CC_FAILURES" -eq 0 ] || exit 1
    simd_execution_summary codegen-cases
    echo "[codegen-cases] passed: $CC_ROWS expectation(s) checked, $CC_SKIPPED skipped"
    exit 0
fi

# ---------------------------------------------------------------- native runner cache & exec

RUNNER_SOURCE_DIR="tools/codegen-cases-runner"
RUNNER_STDLIB_ROOT="stdlib"
RUNNER_SOURCE_HASHES=$(
    find -L "$RUNNER_SOURCE_DIR" "$RUNNER_STDLIB_ROOT" -type f -exec sha256sum -- {} +
)
RUNNER_SOURCE_HASH=$(printf '%s\n' "$RUNNER_SOURCE_HASHES" | LC_ALL=C sort | ci_compiler_artifact_sha256_stdin)
COMPILER_HASH=$(ci_compiler_artifact_sha256_stdin < "$COMPILER")
RUNNER_KEY=$(printf '%s\n' "$COMPILER_HASH" "$RUNNER_SOURCE_HASH" "$CC_HOST" "opt1" |
    ci_compiler_artifact_sha256_stdin)
RUNNER_CACHE="$ROOT/target/codegen-cases-runner/$RUNNER_KEY"
RUNNER_BIN="$RUNNER_CACHE/runner$BIN_EXT"

if [ ! -x "$RUNNER_BIN" ]; then
    (
        mkdir -p "$RUNNER_CACHE/build-lock"
        bounded_pool_lock "$RUNNER_CACHE/build-lock"
        RUNNER_TEMP=
        trap '[ -z "$RUNNER_TEMP" ] || rm -rf -- "$RUNNER_TEMP"; bounded_pool_unlock "$RUNNER_CACHE/build-lock"' EXIT
        trap 'exit 1' HUP INT TERM
        if [ ! -x "$RUNNER_BIN" ]; then
            RUNNER_TEMP=$(mktemp -d "$RUNNER_CACHE/.build.XXXXXX")
            "$COMPILER" build "$RUNNER_SOURCE_DIR/main.tl" \
                --stdlib-root "$RUNNER_STDLIB_ROOT" \
                --stdlib-root "$RUNNER_SOURCE_DIR" \
                --opt-level 1 \
                -o "$RUNNER_TEMP/runner$BIN_EXT" >&2
            [ -s "$RUNNER_TEMP/runner$BIN_EXT" ] && [ -x "$RUNNER_TEMP/runner$BIN_EXT" ] || {
                echo "codegen-cases-runner build emitted no executable" >&2
                exit 1
            }
            mv -- "$RUNNER_TEMP/runner$BIN_EXT" "$RUNNER_BIN"
        fi
    )
fi

CC_NATIVE_ROOT=$(cc_native_path "$ROOT")
CC_RUNNER_ROOT=$ROOT
CC_RUNNER_COMPILER=$COMPILER
CC_RUNNER_WORK_ROOT=$CC_WORK_ROOT
CC_RUNNER_SH=$(command -v sh || printf '%s' sh)
CC_RUNNER_SDE=${TYPELISP_SDE_BIN:-}
CC_RUNNER_TIMING_FILE=${TYPELISP_CI_TIMING_FILE:-}
CC_RUNNER_MSYS_TMP=
CC_RUNNER_MSYS_ROOT=

if [ "$CC_HOST" = windows ]; then
    CC_RUNNER_ROOT=$CC_NATIVE_ROOT
    CC_RUNNER_COMPILER=$(cc_native_path "$COMPILER")
    CC_RUNNER_WORK_ROOT=$(cc_native_path "$CC_WORK_ROOT")
    CC_RUNNER_SH=$(cc_native_path "$CC_RUNNER_SH")
    [ -z "$CC_RUNNER_SDE" ] || CC_RUNNER_SDE=$(cc_native_path "$CC_RUNNER_SDE")
    [ -z "$CC_RUNNER_TIMING_FILE" ] || CC_RUNNER_TIMING_FILE=$(cc_native_path "$CC_RUNNER_TIMING_FILE")
    CC_RUNNER_MSYS_TMP=$(cc_native_path /tmp)
    CC_RUNNER_MSYS_TMP=${CC_RUNNER_MSYS_TMP%/}
    CC_RUNNER_MSYS_ROOT=$(cc_native_path /)
    CC_RUNNER_MSYS_ROOT=${CC_RUNNER_MSYS_ROOT%/}
    TMPDIR=$(cc_native_path "${TMPDIR:-/tmp}")
    export TMPDIR
fi

TYPELISP_CODEGEN_CASES_ROOT=$CC_RUNNER_ROOT
TYPELISP_CODEGEN_CASES_NATIVE_ROOT=$CC_NATIVE_ROOT
TYPELISP_CODEGEN_CASES_COMPILER=$CC_RUNNER_COMPILER
TYPELISP_CODEGEN_CASES_HOST=$CC_HOST
TYPELISP_CODEGEN_CASES_NATIVE_ISAS=$(printf '%s' "$SIMDEX_NATIVE_ISAS" | tr '\n' ' ')
TYPELISP_CODEGEN_CASES_SH=$CC_RUNNER_SH
TYPELISP_CODEGEN_CASES_MSYS_TMP=$CC_RUNNER_MSYS_TMP
TYPELISP_CODEGEN_CASES_MSYS_ROOT=$CC_RUNNER_MSYS_ROOT
CODEGEN_CASES_WORKDIR=$CC_RUNNER_WORK_ROOT
TYPELISP_SDE_BIN=$CC_RUNNER_SDE
TYPELISP_CI_TIMING_FILE=$CC_RUNNER_TIMING_FILE
export TYPELISP_CODEGEN_CASES_ROOT TYPELISP_CODEGEN_CASES_NATIVE_ROOT \
    TYPELISP_CODEGEN_CASES_COMPILER TYPELISP_CODEGEN_CASES_HOST \
    TYPELISP_CODEGEN_CASES_NATIVE_ISAS TYPELISP_CODEGEN_CASES_SH \
    TYPELISP_CODEGEN_CASES_MSYS_TMP TYPELISP_CODEGEN_CASES_MSYS_ROOT \
    CODEGEN_CASES_WORKDIR TYPELISP_SDE_BIN TYPELISP_CI_TIMING_FILE

if [ "$CC_ONLY" != '*' ]; then
    exec "$RUNNER_BIN" --only "$CC_ONLY" -- "$@"
fi
exec "$RUNNER_BIN" -- "$@"
