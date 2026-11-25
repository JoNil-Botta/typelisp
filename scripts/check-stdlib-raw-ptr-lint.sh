#!/usr/bin/env sh
set -eu

# Stdlib safe-boundary lint.
#
# Two zero-count invariants over every git-tracked non-test stdlib source
# (`stdlib/**/*.tl` outside `stdlib/tests/`):
#
# 1. No safe function takes a raw pointer. A `(define (f ...) ...)` whose
#    parameter list mentions `Ptr` or `MutPtr` anywhere must be the single
#    declaration of an `(unsafe (define ...))` wrapper, the only form the parser
#    accepts as an unsafe function. This covers top-level definitions, those
#    nested under `(cfg ...)` (which must be `(cfg p (unsafe (define ...)))`)
#    and those a macro emits through a quasiquote template. A raw-pointer
#    return type or an `(unsafe ...)` body does not make a function unsafe to
#    call and is not flagged.
# 2. No `define` or `defmacro` names a `*-shared-view` helper (#9257).
#
# The scanner is a paren-, string-, character-literal- and comment-aware
# POSIX awk reader (GNU awk, mawk and MSYS2 awk alike); no compiler is built
# or run.
#
# usage: scripts/check-stdlib-raw-ptr-lint.sh [--self-test]

usage() {
    cat >&2 <<'EOF'
usage: scripts/check-stdlib-raw-ptr-lint.sh
       scripts/check-stdlib-raw-ptr-lint.sh --self-test

Fail when a git-tracked non-test stdlib/**/*.tl file defines a safe function
with a Ptr/MutPtr parameter or a *-shared-view define/defmacro. --self-test
runs the scanner's own tests.
EOF
}

SELF_TEST=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --self-test)
            [ "$SELF_TEST" -eq 0 ] || { usage; exit 2; }
            SELF_TEST=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

SCRIPT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/$(basename -- "$0")
FIXTURE_METRICS_TOOLS=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=${STDLIB_RAW_PTR_LINT_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}

# The tracked non-test stdlib sources, one repository-relative path per line.
source_files() {
    git -C "$1" ls-files -- 'stdlib/*.tl' |
        LC_ALL=C awk '!/^stdlib\/tests\//' |
        LC_ALL=C sort
}

# Read the manifest of paths on stdin (relative to $1) and print one
# `path:line: message` row per violation. Every frame records its head atom,
# its element count and the line of its open paren; a list that is the second
# element of a `define`/`defmacro` frame is its signature, and a `Ptr`/`MutPtr`
# atom inside a signature after the name marks the definition. A marked
# `define` is sealed only when its enclosing frame is headed `unsafe`.
# getline/close preserves individual lines even without a final LF, and a
# string or `;` comment never yields a token.
scan() {
    LC_ALL=C awk -v root="$1" '
        function open_frame(bracket,    template) {
            template = prefixed
            element()
            depth++
            head[depth] = ""
            count[depth] = 0
            opened[depth] = lineno
            pointer[depth] = 0
            name[depth] = ""
            signature[depth] = 0
            quoted[depth] = template
            if (!bracket && depth > 1 && count[depth - 1] == 2 &&
                (head[depth - 1] == "define" || head[depth - 1] == "defmacro")) {
                signature[depth] = 1
            }
            insig[depth] = signature[depth] ? depth : insig[depth - 1]
        }
        function close_frame() {
            if (depth == 0) return
            if (head[depth] == "define" && pointer[depth] &&
                !(depth > 1 && head[depth - 1] == "unsafe" && count[depth - 1] == 2 && !quoted[depth])) {
                print path ":" opened[depth] ": safe function `" name[depth] \
                    "` takes a raw-pointer (Ptr/MutPtr) parameter; seal it as (unsafe (define ...)) or borrow with &/&mut"
            }
            if ((head[depth] == "define" || head[depth] == "defmacro") && name[depth] ~ /-shared-view/) {
                print path ":" opened[depth] ": `" head[depth] " " name[depth] \
                    "` defines a *-shared-view helper; borrow with (& x)/(&mut x) instead (#9257)"
            }
            depth--
        }
        # Count one element of the innermost frame; a definition frame takes
        # the name of its second element (a value name or its signature head).
        function element() {
            prefixed = 0
            if (depth == 0) return
            count[depth]++
        }
        function atom(text) {
            prefixed = 0
            if (depth == 0) return
            element()
            if (count[depth] == 1) {
                head[depth] = text
                if (signature[depth]) name[depth - 1] = text
            } else if (count[depth] == 2 &&
                (head[depth] == "define" || head[depth] == "defmacro")) {
                name[depth] = text
            }
            if (insig[depth] && (text == "Ptr" || text == "MutPtr") &&
                !(depth == insig[depth] && count[depth] == 1)) {
                pointer[insig[depth] - 1] = 1
            }
        }
        function scan_line(text) {
            rest = text
            while (rest != "") {
                if (instring) {
                    if (match(rest, /^([^"\\]|\\.)*"/)) {
                        rest = substr(rest, RLENGTH + 1)
                        instring = 0
                        continue
                    }
                    return
                }
                if (match(rest, /^[ \t\r]+/)) {
                    rest = substr(rest, RLENGTH + 1)
                    continue
                }
                c = substr(rest, 1, 1)
                if (c == ";") return
                if (c == "\"") {
                    element()
                    instring = 1
                    rest = substr(rest, 2)
                    continue
                }
                if (c == "(" || c == "[") {
                    open_frame(c == "[")
                    rest = substr(rest, 2)
                    continue
                }
                if (c == ")" || c == "]") {
                    close_frame()
                    rest = substr(rest, 2)
                    continue
                }
                if (c == "\047") {
                    # A character literal is one element; any other apostrophe
                    # is a quote prefix.
                    if (substr(rest, 2, 1) == "\\" && substr(rest, 4, 1) == "\047") {
                        element()
                        rest = substr(rest, 5)
                    } else if (length(rest) >= 3 && substr(rest, 2, 1) != "\047" &&
                        substr(rest, 3, 1) == "\047") {
                        element()
                        rest = substr(rest, 4)
                    } else {
                        rest = substr(rest, 2)
                        prefixed = 1
                    }
                    continue
                }
                if (c == "`" || c == ",") {
                    rest = substr(rest, 2)
                    if (c == "," && substr(rest, 1, 1) == "@") rest = substr(rest, 2)
                    prefixed = 1
                    continue
                }
                if (match(rest, /^[^][ \t\r()";`,]+/)) {
                    atom(substr(rest, 1, RLENGTH))
                    rest = substr(rest, RLENGTH + 1)
                    continue
                }
                rest = substr(rest, 2)
            }
        }
        {
            path = $0
            file = root "/" path
            depth = 0
            instring = 0
            prefixed = 0
            lineno = 0
            insig[0] = 0
            while ((getline line < file) > 0) {
                lineno++
                scan_line(line)
            }
            close(file)
        }'
}

run_check() {
    _rc_manifest=$METRICS_WORK/manifest
    _rc_report=$METRICS_WORK/violations
    source_files "$ROOT" > "$_rc_manifest"
    _rc_files=$(LC_ALL=C awk 'END { print NR }' "$_rc_manifest")
    if [ "$_rc_files" -eq 0 ]; then
        echo "check-stdlib-raw-ptr-lint: no tracked stdlib/**/*.tl sources under $ROOT" >&2
        exit 1
    fi
    scan "$ROOT" < "$_rc_manifest" > "$_rc_report"
    _rc_violations=$(LC_ALL=C awk 'END { print NR }' "$_rc_report")
    if [ "$_rc_violations" -ne 0 ]; then
        cat "$_rc_report" >&2
        echo "check-stdlib-raw-ptr-lint: $_rc_violations violation(s) in $_rc_files stdlib sources" >&2
        exit 1
    fi
    echo "check-stdlib-raw-ptr-lint: 0 violations in $_rc_files stdlib sources"
}

st_git() {
    _stg_repo=$1
    shift
    git -C "$_stg_repo" \
        -c user.name=self-test \
        -c user.email=self-test@example.invalid \
        -c commit.gpgsign=false \
        -c core.autocrlf=false \
        "$@"
}

st_run() {
    env STDLIB_RAW_PTR_LINT_ROOT="$1" TYPELISP_CI_TIMING=0 sh "$SCRIPT"
}

# Plant one probe file in a fresh tracked repository and expect the gate to
# reject it (naming each listed line) or accept it.
st_probe() {
    _stp_label=$1
    _stp_expect=$2
    _stp_lines=$3
    _stp_repo=$METRICS_WORK/tree/$_stp_label
    mkdir -p "$_stp_repo/stdlib/sub"
    st_git "$_stp_repo" init -q
    cat > "$_stp_repo/stdlib/sub/probe.tl"
    st_git "$_stp_repo" add stdlib
    if st_run "$_stp_repo" > "$_stp_repo/out" 2>&1; then
        _stp_status=accept
    else
        _stp_status=reject
    fi
    if [ "$_stp_status" != "$_stp_expect" ]; then
        echo "self-test: $_stp_label: expected $_stp_expect, got $_stp_status" >&2
        cat "$_stp_repo/out" >&2
        exit 1
    fi
    for _stp_line in $_stp_lines; do
        grep -q "^stdlib/sub/probe.tl:$_stp_line: " "$_stp_repo/out" || {
            echo "self-test: $_stp_label: no violation reported at line $_stp_line" >&2
            cat "$_stp_repo/out" >&2
            exit 1
        }
    done
    if [ "$_stp_expect" = reject ]; then
        _stp_count=$(grep -c '^stdlib/sub/probe.tl:' "$_stp_repo/out" || :)
        _stp_want=$(printf '%s\n' $_stp_lines | LC_ALL=C awk 'END { print NR }')
        [ "$_stp_count" -eq "$_stp_want" ] || {
            echo "self-test: $_stp_label: expected $_stp_want violation(s), got $_stp_count" >&2
            cat "$_stp_repo/out" >&2
            exit 1
        }
    fi
}

run_self_test() {
    st_probe top-level-ptr reject 1 <<'EOF'
(define (peek [p : (Ptr u8)]) : u8
  (unsafe (ptr-read p)))
EOF
    st_probe top-level-mutptr reject 3 <<'EOF'
;; A raw-pointer parameter after other parameters, on its own line.
(define (fill [count : i64]) : unit ())
(define (poke!
  [count : i64]
  [p : (MutPtr u8)]) : unit
  (unsafe (ptr-write! p 0)))
EOF
    st_probe cfg-nested-ptr reject 2 <<'EOF'
(cfg windows
  (define (peek [p : (Ptr u8)]) : u8
    (unsafe (ptr-read p))))
EOF
    st_probe cfg-nested-mutptr reject 3 <<'EOF'
(cfg (not windows)
  (begin
    (define (poke! [p : (MutPtr i64)] [v : i64]) : unit
      (unsafe (ptr-write! p v)))))
EOF
    st_probe macro-emitted-ptr reject 3 <<'EOF'
(defmacro (define-peek [function-name : Expr] [T : Expr]) : Expr
  (unsafe
    `(define (,function-name [p : (Ptr ,T)]) : ,T
      (unsafe (ptr-read p)))))
EOF
    st_probe macro-emitted-mutptr reject 2 <<'EOF'
(defmacro (define-poke [T : Expr]) : Expr
  `(begin (define (poke! [p : (MutPtr ,T)] [v : ,T]) : unit
    (unsafe (ptr-write! p v)))))
EOF
    st_probe unsafe-body-is-not-unsafe-function reject 1 <<'EOF'
(define (peek [p : (Ptr u8)]) : u8 (unsafe (ptr-read p)))
EOF
    # Only the single declaration of an unsafe wrapper is sealed.
    st_probe nested-under-unsafe-block reject 3 <<'EOF'
(unsafe
  (begin
    (define (also [p : (Ptr u8)]) : u8 0)))
EOF
    st_probe shared-view-define reject 1 <<'EOF'
(define (thing-shared-view [x : (& Thing)]) : Thing (deref x))
EOF
    st_probe shared-view-defmacro reject '1 2' <<'EOF'
(defmacro (local-shared-view [x : Expr]) : Expr x)
(define cached-shared-view : i64 0)
EOF
    st_probe sealed-ptr accept '' <<'EOF'
(unsafe
  (define (peek [p : (Ptr u8)]) : u8
    (unsafe (ptr-read p))))
(cfg windows
  (unsafe
    (define (poke! [p : (MutPtr u8)]) : unit
      (unsafe (ptr-write! p 0)))))
(defmacro (define-peek [function-name : Expr] [T : Expr]) : Expr
  `(unsafe
    (define (,function-name [p : (Ptr ,T)]) : ,T
      (unsafe (ptr-read p)))))
EOF
    st_probe safe-without-pointer-parameters accept '' <<'EOF'
(define (data [view : (& source bytes)]) : (Ptr u8)
  (unsafe (bytes-data view)))
(define table : (MutPtr i64)
  (unsafe (make-table 4)))
(define (call [f : (-> i64 i64)] [x : i64]) : i64
  (unsafe (f x)))
(defmacro (peek-macro [p : Expr]) : Expr
  `(unsafe (ptr-read (ptr-cast ,p : (Ptr u8)))))
(define (Ptr-name [x : i64]) : i64 x)
(define (view [items : (& Slice u8)]) : i64 (length items))
EOF
    st_probe comments-strings-and-chars accept '' <<'EOF'
;; (define (peek [p : (Ptr u8)]) : u8 0)
;; (define (thing-shared-view [x : i64]) : i64 x)
(define (describe [x : i64]) : String
  "(define (peek [p : (Ptr u8)]) : u8 0) \" (MutPtr u8)
spans a line (define (poke [p : (MutPtr u8)]) : unit ())"
  ) ; [p : (Ptr u8)]
(define (paren-chars [c : char]) : bool
  (or (= c '(') (= c ')') (= c '\'') (= c '"') (= c '[') (= c ';')))
(define (after-chars [x : i64]) : i64 x)
EOF
    # Only tracked non-test stdlib sources are read.
    _st_scope=$METRICS_WORK/tree/scope
    mkdir -p "$_st_scope/stdlib/tests" "$_st_scope/src"
    st_git "$_st_scope" init -q
    printf '(define (ok [x : i64]) : i64 x)\n' > "$_st_scope/stdlib/ok.tl"
    printf '(define (peek [p : (Ptr u8)]) : u8 0)\n' > "$_st_scope/stdlib/tests/witness.tl"
    printf '(define (peek [p : (Ptr u8)]) : u8 0)\n' > "$_st_scope/src/compiler.tl"
    st_git "$_st_scope" add stdlib src
    printf '(define (peek [p : (Ptr u8)]) : u8 0)\n' > "$_st_scope/stdlib/untracked.tl"
    _st_out=$(st_run "$_st_scope" 2>&1) || {
        echo "self-test: tests/, src/ or untracked sources were scanned: $_st_out" >&2
        exit 1
    }
    case "$_st_out" in
        *"0 violations in 1 stdlib sources"*) ;;
        *)
            echo "self-test: scope probe miscounted sources: $_st_out" >&2
            exit 1
            ;;
    esac
    echo "check-stdlib-raw-ptr-lint: self-test passed"
}

mkdir -p "$ROOT/target/exp"
METRICS_WORK=$(mktemp -d "$ROOT/target/exp/stdlib-raw-ptr-lint.XXXXXX")
case "$METRICS_WORK" in "$ROOT/target/exp/stdlib-raw-ptr-lint."??????) ;; *) exit 1 ;; esac
cleanup() {
    _status=$?
    trap - EXIT
    if [ "$SELF_TEST" -eq 0 ] || [ "$_status" -eq 0 ]; then
        rm -rf -- "${METRICS_WORK:?}"
    fi
    exit "$_status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
. "$FIXTURE_METRICS_TOOLS/lib-fixture-metrics.sh"
fixture_metrics_init "$METRICS_WORK"
if [ "$SELF_TEST" -eq 1 ]; then
    fixture_metrics_run self-test run_self_test
else
    fixture_metrics_run scan run_check
fi
