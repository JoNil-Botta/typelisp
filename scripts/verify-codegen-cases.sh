#!/usr/bin/env sh
set -eu

# verify-codegen-cases.sh - table-driven compile / run / assembly-shape and CLI
# transcript runner.
#
# usage: scripts/verify-codegen-cases.sh [--list | --list-fixtures] [--only CASE-GLOB] FILE_OR_DIR...
#        scripts/verify-codegen-cases.sh --self-test
#
# Execution is performed by the native zero-dependency TypeLisp runner under
# tools/codegen-cases-runner/, built once per compiler/source/host key and
# cached under target/codegen-cases-runner/<key>/.
#
# --list and --list-fixtures run without a compiler (used by ci-affected map
# audits and app corpus discovery). Passing a directory loads all *.cases files
# directly inside it in LC_ALL=C sorted order with isolated per-file defaults
# and pre-files and global unique case-ID enforcement.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
set -f

usage() {
    echo "usage: scripts/verify-codegen-cases.sh [--list | --list-fixtures] [--only CASE-GLOB] FILE_OR_DIR..." >&2
    echo "       scripts/verify-codegen-cases.sh --self-test" >&2
    exit 2
}

CC_LIST=0
CC_FIXTURES=0
CC_SELF_TEST=0
CC_ONLY='*'
while [ "$#" -gt 0 ]; do
    case "$1" in
        --list) CC_LIST=1; shift ;;
        --list-fixtures) CC_LIST=1; CC_FIXTURES=1; shift ;;
        --self-test) CC_SELF_TEST=1; shift ;;
        --only) [ "$#" -ge 2 ] || usage; CC_ONLY=$2; shift 2 ;;
        --) shift; break ;;
        -*) usage ;;
        *) break ;;
    esac
done
if [ "$CC_SELF_TEST" -eq 1 ]; then
    if [ "$CC_LIST" -ne 0 ] || [ "$CC_ONLY" != '*' ] || [ "$#" -ne 0 ]; then
        usage
    fi
else
    [ "$#" -gt 0 ] || usage
fi

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
    awk -v file="$1" -v fixtures="$CC_FIXTURES" -v root="${CODEGEN_CASES_FIXTURE_ROOT:-$ROOT}" '
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

cc_expand_inputs() {
    _ce_out=$1
    shift
    : > "$_ce_out"
    for _ce_arg do
        _ce_probe=$_ce_arg
        while :; do
            case "$_ce_probe" in
                / | [A-Za-z]:/) break ;;
                */) _ce_probe=${_ce_probe%/} ;;
                *) break ;;
            esac
        done
        if [ -L "$_ce_probe" ]; then
            echo "case input cannot be a symlink: $_ce_arg" >&2
            return 2
        fi
        if [ -d "$_ce_arg" ]; then
            _ce_dir=$_ce_probe
            _ce_entries=$(find "$_ce_dir" -print | LC_ALL=C sort) || return 2
            _ce_count=0
            while IFS= read -r _ce_entry; do
                [ -n "$_ce_entry" ] || continue
                [ "$_ce_entry" != "$_ce_dir" ] || continue
                if [ "$_ce_dir" = "/" ]; then
                    _ce_rel=${_ce_entry#/}
                else
                    _ce_rel=${_ce_entry#"$_ce_dir"/}
                fi
                case "$_ce_rel" in
                    */*)
                        echo "case directory $_ce_dir contains nested entry: $_ce_rel" >&2
                        return 2
                        ;;
                    .cases)
                        echo "case directory $_ce_dir contains invalid filename: $_ce_rel" >&2
                        return 2
                        ;;
                    *.cases) ;;
                    *)
                        echo "case directory $_ce_dir contains unexpected non-.cases entry: $_ce_rel" >&2
                        return 2
                        ;;
                esac
                if [ ! -f "$_ce_entry" ] || [ -L "$_ce_entry" ]; then
                    echo "case directory $_ce_dir contains non-regular entry: $_ce_rel" >&2
                    return 2
                fi
                printf '%s\n' "$_ce_entry" >> "$_ce_out"
                _ce_count=$((_ce_count + 1))
            done <<EOF
$_ce_entries
EOF
            if [ "$_ce_count" -eq 0 ]; then
                echo "case directory is empty (no *.cases files): $_ce_dir" >&2
                return 2
            fi
        elif [ -f "$_ce_arg" ]; then
            printf '%s\n' "$_ce_arg" >> "$_ce_out"
        else
            echo "missing case file: $_ce_arg" >&2
            return 2
        fi
    done
}

CC_WORK_ROOT=${CODEGEN_CASES_WORKDIR:-$ROOT/target/codegen-cases}
CC_WORK_SUFFIX=
if [ "$CC_ONLY" != '*' ]; then
    CC_WORK_SUFFIX=.only-$(printf '%s' "$CC_ONLY" | tr -c 'A-Za-z0-9._-' '_')
fi

if [ "$CC_LIST" -eq 1 ]; then
    mkdir -p "$CC_WORK_ROOT"
    CC_EXPANDED=$(mktemp "$CC_WORK_ROOT/.expanded.XXXXXX")
    CC_LIST_OUT=$(mktemp "$CC_WORK_ROOT/.list.XXXXXX")
    CC_SEEN_IDS=$(mktemp "$CC_WORK_ROOT/.seen-ids.XXXXXX")
    CC_SEEN_SRCS=$(mktemp "$CC_WORK_ROOT/.seen-srcs.XXXXXX")
    trap 'rm -f "$CC_EXPANDED" "$CC_LIST_OUT" "$CC_SEEN_IDS" "$CC_SEEN_SRCS"' EXIT
    cc_expand_inputs "$CC_EXPANDED" "$@" || exit 2
    while IFS= read -r CC_FILE; do
        [ -n "$CC_FILE" ] || continue
        if [ "$CC_FIXTURES" -eq 1 ]; then
            CC_FIX_TMP=$(mktemp "$CC_WORK_ROOT/.fix.XXXXXX")
            if ! cc_translate "$CC_FILE" > "$CC_FIX_TMP"; then
                rm -f "$CC_FIX_TMP"
                exit 2
            fi
            if ! awk -F '\t' -v file="$CC_FILE" '
                FILENAME == ARGV[1] { seen_id[$0] = 1; next }
                FILENAME == ARGV[2] { seen_src[$0] = 1; next }
                {
                    if ($1 in seen_id) {
                        printf "%s: duplicate case %s\n", file, $1 > "/dev/stderr"
                        bad = 1
                        exit 1
                    }
                    if ($2 in seen_src) {
                        printf "%s: duplicate fixture source: %s\n", file, $2 > "/dev/stderr"
                        bad = 1
                        exit 1
                    }
                    seen_id[$1] = 1
                    seen_src[$2] = 1
                }
                END { if (bad) exit 1 }
            ' "$CC_SEEN_IDS" "$CC_SEEN_SRCS" "$CC_FIX_TMP"; then
                rm -f "$CC_FIX_TMP"
                exit 2
            fi
            cut -f 1 "$CC_FIX_TMP" >> "$CC_SEEN_IDS"
            cut -f 2 "$CC_FIX_TMP" >> "$CC_SEEN_SRCS"
            cat "$CC_FIX_TMP" >> "$CC_LIST_OUT"
            rm -f "$CC_FIX_TMP"
            continue
        fi
        CC_NAME=$(basename "$CC_FILE" .cases)
        CC_WORK="$CC_WORK_ROOT/$CC_NAME$CC_WORK_SUFFIX"
        rm -rf "$CC_WORK"
        mkdir -p "$CC_WORK"
        cc_translate "$CC_FILE" > "$CC_WORK/plan.sh" || exit 2
        if ! awk -v file="$CC_FILE" '
            FILENAME == ARGV[1] { seen[$0] = 1; next }
            /^cc_case / {
                line = $2
                id = $3
                gsub(/\047/, "", id)
                if (id in seen) {
                    printf "%s:%s: duplicate case %s\n", file, line, id > "/dev/stderr"
                    bad = 1
                    exit 1
                }
                seen[id] = 1
            }
            END { if (bad) exit 1 }
        ' "$CC_SEEN_IDS" "$CC_WORK/plan.sh"; then
            exit 2
        fi
        awk '/^cc_case / { id = $3; gsub(/\047/, "", id); print id }' "$CC_WORK/plan.sh" >> "$CC_SEEN_IDS"
        awk -v file="$CC_FILE" '
            /^cc_case / { id = $3; gsub(/\047/, "", id); next }
            /^cc_variant / { v = $3 " " $4 " " $5 ($6 == "\047-\047" ? "" : " " $6); gsub(/\047/, "", v); printf "%s %s [%s]\n", file, id, v }
        ' "$CC_WORK/plan.sh" >> "$CC_LIST_OUT"
    done < "$CC_EXPANDED"
    cat "$CC_LIST_OUT"
    exit 0
fi

# ---------------------------------------------------------------- native runner build helper

cc_ensure_runner_bin() {
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
}

if [ "$CC_SELF_TEST" -eq 1 ]; then
    gate_compiler
    gate_compiler_absolute
    gate_require_compiler
    cc_ensure_runner_bin

    mkdir -p "$CC_WORK_ROOT"
    ST_DIR=$(mktemp -d "$CC_WORK_ROOT/self-test.XXXXXX")
    ST_ARG=$(cc_native_path "$ST_DIR")
    trap 'rm -rf -- "$ST_DIR"' EXIT

    # 1. Native runner built-in self-test (including directory loading & global uniqueness).
    "$RUNNER_BIN" --self-test

    # 2. Shell front-end vs native runner parity on directories (--list & --list-fixtures).
    mkdir -p "$ST_DIR/valid.d" "$ST_DIR/dup.d" "$ST_DIR/empty.d" "$ST_DIR/stray.d" "$ST_DIR/nested.d/sub" "$ST_DIR/symlink.d" "$ST_DIR/fix.d" "$ST_DIR/fix-dup.d"
    cat > "$ST_DIR/valid.d/02-second.cases" <<'EOF'
file local_b.tl
(define (main) : i64 2)
end-file
case case-b
source {{work}}/local_b.tl
EOF
    cat > "$ST_DIR/valid.d/01-first.cases" <<'EOF'
opt 1
file local_a.tl
(define (main) : i64 1)
end-file
case case-a
source {{work}}/local_a.tl
EOF
    CODEGEN_CASES_WORKDIR="$ST_DIR/w-sh" sh "$ROOT/scripts/verify-codegen-cases.sh" --list "$ST_ARG/valid.d" > "$ST_DIR/sh.list"
    "$RUNNER_BIN" --list "$ST_ARG/valid.d" > "$ST_DIR/bin.list"
    cmp -s "$ST_DIR/sh.list" "$ST_DIR/bin.list" || {
        echo "verify-codegen-cases --self-test: --list parity mismatch between shell and runner" >&2
        diff -u "$ST_DIR/sh.list" "$ST_DIR/bin.list" >&2 || true
        exit 1
    }
    printf '%s\n%s\n' \
        "$ST_ARG/valid.d/01-first.cases case-a [linux-x86_64 1 -]" \
        "$ST_ARG/valid.d/02-second.cases case-b [linux-x86_64 2 -]" > "$ST_DIR/want.list"
    cmp -s "$ST_DIR/sh.list" "$ST_DIR/want.list" || {
        echo "verify-codegen-cases --self-test: directory order or default isolation mismatch" >&2
        diff -u "$ST_DIR/want.list" "$ST_DIR/sh.list" >&2 || true
        exit 1
    }

    # --list-fixtures directory parity (using synthetic fixtures under $ST_DIR/fake-root).
    mkdir -p "$ST_DIR/fake-root/tests"
    printf '(define (main) : i64 0)\n' > "$ST_DIR/fake-root/tests/cc_selftest_a.tl"
    printf '(define (main) : i64 0)\n' > "$ST_DIR/fake-root/tests/cc_selftest_b.tl"
    cat > "$ST_DIR/fix.d/01-a.cases" <<'EOF'
do none
case fix-one
source tests/cc_selftest_a.tl
EOF
    cat > "$ST_DIR/fix.d/02-b.cases" <<'EOF'
do none
case fix-two
source tests/cc_selftest_b.tl
EOF
    CODEGEN_CASES_WORKDIR="$ST_DIR/w-sh" CODEGEN_CASES_FIXTURE_ROOT="$ST_ARG/fake-root" sh "$ROOT/scripts/verify-codegen-cases.sh" --list-fixtures "$ST_ARG/fix.d" > "$ST_DIR/sh.fix"
    TYPELISP_CODEGEN_CASES_ROOT="$ST_ARG/fake-root" "$RUNNER_BIN" --list-fixtures "$ST_ARG/fix.d" > "$ST_DIR/bin.fix"
    cmp -s "$ST_DIR/sh.fix" "$ST_DIR/bin.fix" || {
        echo "verify-codegen-cases --self-test: --list-fixtures parity mismatch between shell and runner" >&2
        diff -u "$ST_DIR/sh.fix" "$ST_DIR/bin.fix" >&2 || true
        exit 1
    }

    # Global duplicate case-ID, duplicate fixture-source, empty, stray, nested, and symlink rejection.
    printf 'case dup-id\nsource tests/cc_selftest_a.tl\n' > "$ST_DIR/dup.d/a.cases"
    printf 'case dup-id\nsource tests/cc_selftest_b.tl\n' > "$ST_DIR/dup.d/b.cases"
    printf 'case ok\nsource tests/cc_selftest_a.tl\n' > "$ST_DIR/stray.d/a.cases"
    printf 'stray\n' > "$ST_DIR/stray.d/notes.txt"
    printf 'case ok\nsource tests/cc_selftest_a.tl\n' > "$ST_DIR/nested.d/a.cases"
    ln -s "$ST_DIR/valid.d/01-first.cases" "$ST_DIR/symlink.d/link.cases" 2>/dev/null || true
    ln -s "$ST_DIR/valid.d" "$ST_DIR/valid-link.d" 2>/dev/null || true
    ln -s "$ST_DIR/valid.d/01-first.cases" "$ST_DIR/file-link.cases" 2>/dev/null || true
    printf 'do none\ncase fa\nsource tests/cc_selftest_a.tl\n' > "$ST_DIR/fix-dup.d/a.cases"
    printf 'do none\ncase fb\nsource tests/cc_selftest_a.tl\n' > "$ST_DIR/fix-dup.d/b.cases"

    for bad_dir in "$ST_ARG/dup.d" "$ST_ARG/empty.d" "$ST_ARG/stray.d" "$ST_ARG/nested.d"; do
        if CODEGEN_CASES_WORKDIR="$ST_DIR/w-sh" sh "$ROOT/scripts/verify-codegen-cases.sh" --list "$bad_dir" >/dev/null 2>&1; then
            echo "verify-codegen-cases --self-test: shell accepted invalid directory $bad_dir" >&2
            exit 1
        fi
        if "$RUNNER_BIN" --list "$bad_dir" >/dev/null 2>&1; then
            echo "verify-codegen-cases --self-test: runner accepted invalid directory $bad_dir" >&2
            exit 1
        fi
    done
    if [ -L "$ST_DIR/symlink.d/link.cases" ]; then
        if CODEGEN_CASES_WORKDIR="$ST_DIR/w-sh" sh "$ROOT/scripts/verify-codegen-cases.sh" --list "$ST_ARG/symlink.d" >/dev/null 2>&1; then
            echo "verify-codegen-cases --self-test: shell accepted symlink in directory" >&2
            exit 1
        fi
        if "$RUNNER_BIN" --list "$ST_ARG/symlink.d" >/dev/null 2>&1; then
            echo "verify-codegen-cases --self-test: runner accepted symlink in directory" >&2
            exit 1
        fi
    fi
    if [ -L "$ST_DIR/valid-link.d" ]; then
        for bad_link in "$ST_ARG/valid-link.d" "$ST_ARG/valid-link.d/"; do
            if CODEGEN_CASES_WORKDIR="$ST_DIR/w-sh" sh "$ROOT/scripts/verify-codegen-cases.sh" --list "$bad_link" >/dev/null 2>&1; then
                echo "verify-codegen-cases --self-test: shell accepted symlinked directory $bad_link" >&2
                exit 1
            fi
            if "$RUNNER_BIN" --list "$bad_link" >/dev/null 2>&1; then
                echo "verify-codegen-cases --self-test: runner accepted symlinked directory $bad_link" >&2
                exit 1
            fi
        done
    fi
    if [ -L "$ST_DIR/file-link.cases" ]; then
        if CODEGEN_CASES_WORKDIR="$ST_DIR/w-sh" sh "$ROOT/scripts/verify-codegen-cases.sh" --list "$ST_ARG/file-link.cases" >/dev/null 2>&1; then
            echo "verify-codegen-cases --self-test: shell accepted symlinked case file" >&2
            exit 1
        fi
        if "$RUNNER_BIN" --list "$ST_ARG/file-link.cases" >/dev/null 2>&1; then
            echo "verify-codegen-cases --self-test: runner accepted symlinked case file" >&2
            exit 1
        fi
    fi
    if CODEGEN_CASES_WORKDIR="$ST_DIR/w-sh" CODEGEN_CASES_FIXTURE_ROOT="$ST_ARG/fake-root" sh "$ROOT/scripts/verify-codegen-cases.sh" --list-fixtures "$ST_ARG/fix-dup.d" >/dev/null 2>&1; then
        echo "verify-codegen-cases --self-test: shell accepted duplicate fixture source across directory" >&2
        exit 1
    fi
    if TYPELISP_CODEGEN_CASES_ROOT="$ST_ARG/fake-root" "$RUNNER_BIN" --list-fixtures "$ST_ARG/fix-dup.d" >/dev/null 2>&1; then
        echo "verify-codegen-cases --self-test: runner accepted duplicate fixture source across directory" >&2
        exit 1
    fi

    echo "[verify-codegen-cases] self-test passed"
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
            -z noexecstack --gc-sections --start-group "$_cc_stdlib_archive" --end-group \
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
    mkdir -p "$CC_WORK_ROOT"
    CC_STUB_EXPANDED=$(mktemp "$CC_WORK_ROOT/.stub-expanded.XXXXXX")
    CC_STUB_SEEN=$(mktemp "$CC_WORK_ROOT/.stub-seen.XXXXXX")
    trap 'rm -f "$CC_STUB_EXPANDED" "$CC_STUB_SEEN"' EXIT
    cc_expand_inputs "$CC_STUB_EXPANDED" "$@" || exit 2
    while IFS= read -r CC_FILE; do
        [ -n "$CC_FILE" ] || continue
        CC_NAME=$(basename "$CC_FILE" .cases)
        CC_WORK="$CC_WORK_ROOT/$CC_NAME$CC_WORK_SUFFIX"
        CCV_work=$CC_WORK
        CCV_native_work=$(cc_native_path "$CC_WORK")
        rm -rf "$CC_WORK"
        mkdir -p "$CC_WORK"
        cc_translate "$CC_FILE" > "$CC_WORK/plan.sh" || exit 2
        if ! awk -v file="$CC_FILE" '
            FILENAME == ARGV[1] { seen[$0] = 1; next }
            /^cc_case / {
                line = $2; id = $3; gsub(/\047/, "", id)
                if (id in seen) {
                    printf "%s:%s: duplicate case %s\n", file, line, id > "/dev/stderr"
                    bad = 1; exit 1
                }
                seen[id] = 1
            }
            END { if (bad) exit 1 }
        ' "$CC_STUB_SEEN" "$CC_WORK/plan.sh"; then
            exit 2
        fi
        awk '/^cc_case / { id = $3; gsub(/\047/, "", id); print id }' "$CC_WORK/plan.sh" >> "$CC_STUB_SEEN"
        . "$CC_WORK/plan.sh"
    done < "$CC_STUB_EXPANDED"
    [ "$CC_FAILURES" -eq 0 ] || exit 1
    simd_execution_summary codegen-cases
    echo "[codegen-cases] passed: $CC_ROWS expectation(s) checked, $CC_SKIPPED skipped"
    exit 0
fi

# ---------------------------------------------------------------- native runner cache & exec

cc_ensure_runner_bin

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
