#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi

case "$COMPILER" in
    /* | [A-Za-z]:[/\\]*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac

HOST_OS=linux
OBJ_SUFFIX=.o
EXE_SUFFIX=
LIB_PREFIX=lib
LIB_SUFFIX=.a
case "$(uname -s)" in
    Linux*) ;;
    MINGW* | MSYS* | CYGWIN*)
        HOST_OS=windows
        OBJ_SUFFIX=.obj
        EXE_SUFFIX=.exe
        LIB_PREFIX=
        LIB_SUFFIX=.lib
        ;;
    *)
        echo "package artifact freshness verification is unsupported on this host" >&2
        exit 1
        ;;
esac

WORK="$ROOT/target/package-artifact-freshness"
rm -rf "$WORK"
mkdir -p "$WORK/pkg/src" "$WORK/pkg/vendor/dep/src" "$WORK/serial/src"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_contains() {
    file=$1
    text=$2
    grep -F -- "$text" "$file" >/dev/null || fail "$file missing: $text"
}

assert_artifact_role() {
    file=$1
    role=$2
    basename=$3
    grep -F -- "$role " "$file" | grep -F -- "$basename" >/dev/null || \
        fail "$file missing $role status for $basename"
}

snapshot() {
    output=$1
    shift
    : > "$output"
    for path in "$@"; do
        [ -f "$path" ] || fail "missing package artifact $path"
        cksum "$path" >> "$output"
        stat -c '%y' "$path" >> "$output"
    done
}

assert_same() {
    left=$1
    right=$2
    cmp -s "$left" "$right" || fail "package artifact snapshot changed: $left vs $right"
}

assert_different() {
    left=$1
    right=$2
    cmp -s "$left" "$right" && fail "package artifact snapshot did not change: $left vs $right"
    return 0
}

cat > "$WORK/pkg/typelisp.pkg" <<'EOF'
(package
  (name "fresh_root")
  (version "0.1.0")
  (kind "bin")
  (entry "src/main.tl")
  (dependencies
    (dep "vendor/dep")))
EOF

cat > "$WORK/pkg/src/main.tl" <<'EOF'
(import dep.src.lib as dep)
(defmacro (unused-transform [value : Expr]) : Expr
  `(+ ,value 1))
(define (main) : i64 (dep.add-one 41))
EOF

cat > "$WORK/pkg/vendor/dep/typelisp.pkg" <<'EOF'
(package
  (name "fresh_dep")
  (version "0.1.0")
  (kind "lib")
  (entry "src/lib.tl"))
EOF

cat > "$WORK/pkg/vendor/dep/src/lib.tl" <<'EOF'
(define (add-one [value : i64]) : i64 (+ value 1))
EOF

cat > "$WORK/serial/typelisp.pkg" <<'EOF'
(package
  (name "fresh_serial")
  (version "0.1.0")
  (kind "lib")
  (entry "src/lib.tl"))
EOF

cat > "$WORK/serial/src/lib.tl" <<'EOF'
(define (serial-value) : i64 7)
EOF

MODE=
run_graph() {
    tag=$1
    out="$WORK/$tag.out"
    err="$WORK/$tag.err"
    set +e
    if [ -n "$MODE" ]; then
        "$COMPILER" build --manifest-path "$WORK/pkg/typelisp.pkg" --backend-mode "$MODE" >"$out" 2>"$err"
    else
        "$COMPILER" build --manifest-path "$WORK/pkg/typelisp.pkg" >"$out" 2>"$err"
    fi
    code=$?
    set -e
}

run_serial() {
    tag=$1
    out="$WORK/$tag.out"
    err="$WORK/$tag.err"
    set +e
    "$COMPILER" build --package-worker --manifest-path "$WORK/serial/typelisp.pkg" >"$out" 2>"$err"
    code=$?
    set -e
}

ROOT_OUT="$WORK/pkg/target/release"
DEP_OUT="$WORK/pkg/vendor/dep/target/release"
ROOT_ASM="$ROOT_OUT/fresh_root.s"
ROOT_OBJ="$ROOT_OUT/fresh_root$OBJ_SUFFIX"
ROOT_RUNTIME="$ROOT_OUT/fresh_root$EXE_SUFFIX"
ROOT_TLCI="$ROOT_OUT/fresh_root.tlci"
ROOT_INPUTS="$ROOT_RUNTIME.runtime-inputs"
DEP_ASM="$DEP_OUT/fresh_dep.s"
DEP_OBJ="$DEP_OUT/fresh_dep$OBJ_SUFFIX"
DEP_RUNTIME="$DEP_OUT/${LIB_PREFIX}fresh_dep$LIB_SUFFIX"
DEP_TLCI="$DEP_OUT/fresh_dep.tlci"
DEP_INPUTS="$DEP_RUNTIME.runtime-inputs"

run_graph initial
[ "$code" -eq 0 ] || fail "initial package build failed: $(cat "$err")"
[ ! -s "$err" ] || fail "initial package build wrote stderr: $(cat "$err")"
assert_artifact_role "$out" Built "fresh_root$EXE_SUFFIX"
assert_artifact_role "$out" Built "fresh_root.tlci"

snapshot "$WORK/noop.before" \
    "$ROOT_ASM" "$ROOT_OBJ" "$ROOT_RUNTIME" "$ROOT_TLCI" "$ROOT_INPUTS" \
    "$DEP_ASM" "$DEP_OBJ" "$DEP_RUNTIME" "$DEP_TLCI" "$DEP_INPUTS"
sleep 1
run_graph noop
[ "$code" -eq 0 ] || fail "no-op package build failed: $(cat "$err")"
[ ! -s "$err" ] || fail "no-op package build wrote stderr: $(cat "$err")"
assert_artifact_role "$out" Fresh "fresh_root$EXE_SUFFIX"
assert_artifact_role "$out" Fresh "fresh_root.tlci"
assert_artifact_role "$out" Fresh "${LIB_PREFIX}fresh_dep$LIB_SUFFIX"
assert_artifact_role "$out" Fresh "fresh_dep.tlci"
snapshot "$WORK/noop.after" \
    "$ROOT_ASM" "$ROOT_OBJ" "$ROOT_RUNTIME" "$ROOT_TLCI" "$ROOT_INPUTS" \
    "$DEP_ASM" "$DEP_OBJ" "$DEP_RUNTIME" "$DEP_TLCI" "$DEP_INPUTS"
assert_same "$WORK/noop.before" "$WORK/noop.after"

if [ "$HOST_OS" = linux ]; then
    WRAP="$WORK/tool-wrappers"
    TOOL_LOG="$WORK/tool-invocations.log"
    ORIGINAL_PATH=$PATH
    mkdir -p "$WRAP"
    : > "$TOOL_LOG"
    export TOOL_LOG
    for tool in as ar ld cc; do
        real=$(PATH=$ORIGINAL_PATH command -v "$tool") || fail "missing $tool for wrapper coverage"
        {
            echo '#!/usr/bin/env sh'
            printf 'printf "%%s\\n" %s >> "$TOOL_LOG"\n' "$tool"
            printf 'exec %s "$@"\n' "$real"
        } > "$WRAP/$tool"
        chmod +x "$WRAP/$tool"
    done
    PATH="$WRAP:$ORIGINAL_PATH"
    export PATH
    MODE=avx2
    run_graph wrapper-seed
    [ "$code" -eq 0 ] || fail "tool-wrapper seed build failed: $(cat "$err")"
    [ ! -s "$err" ] || fail "tool-wrapper seed build wrote stderr: $(cat "$err")"
    assert_contains "$TOOL_LOG" as
    assert_contains "$TOOL_LOG" ar
    assert_contains "$TOOL_LOG" cc
    wrapper_calls=$(wc -l < "$TOOL_LOG" | tr -d ' ')
    [ "$wrapper_calls" -gt 0 ] || fail "tool-wrapper seed recorded no native tools"
    sleep 1
    run_graph wrapper-noop
    [ "$code" -eq 0 ] || fail "tool-wrapper no-op build failed: $(cat "$err")"
    assert_artifact_role "$out" Fresh "fresh_root$EXE_SUFFIX"
    assert_artifact_role "$out" Fresh "${LIB_PREFIX}fresh_dep$LIB_SUFFIX"
    after_calls=$(wc -l < "$TOOL_LOG" | tr -d ' ')
    [ "$after_calls" -eq "$wrapper_calls" ] || fail "no-op package build invoked native tools"

    printf '\n# tool identity change\n' >> "$WRAP/as"
    run_graph tool-identity
    [ "$code" -eq 0 ] || fail "tool-identity rebuild failed: $(cat "$err")"
    assert_artifact_role "$out" Built "fresh_root$EXE_SUFFIX"
    assert_artifact_role "$out" Built "${LIB_PREFIX}fresh_dep$LIB_SUFFIX"
    assert_artifact_role "$out" Fresh "fresh_root.tlci"
    assert_artifact_role "$out" Fresh "fresh_dep.tlci"
    identity_calls=$(wc -l < "$TOOL_LOG" | tr -d ' ')
    [ "$identity_calls" -gt "$after_calls" ] || fail "tool identity change did not invoke native tools"
fi

snapshot "$WORK/comptime-runtime.before" \
    "$ROOT_ASM" "$ROOT_OBJ" "$ROOT_RUNTIME" "$ROOT_INPUTS"
snapshot "$WORK/comptime-tlci.before" "$ROOT_TLCI"
if [ "$HOST_OS" = linux ]; then
    tool_calls_before=$(wc -l < "$TOOL_LOG" | tr -d ' ')
fi
sed 's/`(+ ,value 1)/`(+ ,value 2)/' "$WORK/pkg/src/main.tl" > "$WORK/main.next"
mv "$WORK/main.next" "$WORK/pkg/src/main.tl"
sleep 1
run_graph comptime-only
[ "$code" -eq 0 ] || fail "comptime-only rebuild failed: $(cat "$err")"
assert_artifact_role "$out" Fresh "fresh_root$EXE_SUFFIX"
assert_artifact_role "$out" Built "fresh_root.tlci"
snapshot "$WORK/comptime-runtime.after" \
    "$ROOT_ASM" "$ROOT_OBJ" "$ROOT_RUNTIME" "$ROOT_INPUTS"
snapshot "$WORK/comptime-tlci.after" "$ROOT_TLCI"
assert_same "$WORK/comptime-runtime.before" "$WORK/comptime-runtime.after"
assert_different "$WORK/comptime-tlci.before" "$WORK/comptime-tlci.after"
if [ "$HOST_OS" = linux ]; then
    tool_calls_after=$(wc -l < "$TOOL_LOG" | tr -d ' ')
    [ "$tool_calls_after" -eq "$tool_calls_before" ] || fail "comptime-only edit invoked native tools"
fi

sed 's/dep.add-one 41/dep.add-one 42/' "$WORK/pkg/src/main.tl" > "$WORK/main.next"
mv "$WORK/main.next" "$WORK/pkg/src/main.tl"
run_graph runtime-edit
[ "$code" -eq 0 ] || fail "runtime rebuild failed: $(cat "$err")"
assert_artifact_role "$out" Built "fresh_root$EXE_SUFFIX"
assert_artifact_role "$out" Built "fresh_root.tlci"

sed 's/+ value 1/+ value 2/' "$WORK/pkg/vendor/dep/src/lib.tl" > "$WORK/dep.next"
mv "$WORK/dep.next" "$WORK/pkg/vendor/dep/src/lib.tl"
run_graph dependency-edit
[ "$code" -eq 0 ] || fail "dependency rebuild failed: $(cat "$err")"
assert_artifact_role "$out" Built "${LIB_PREFIX}fresh_dep$LIB_SUFFIX"
assert_artifact_role "$out" Built "fresh_dep.tlci"
assert_artifact_role "$out" Built "fresh_root$EXE_SUFFIX"

run_serial serial-initial
[ "$code" -eq 0 ] || fail "serial worker build failed: $(cat "$err")"
SERIAL_OUT="$WORK/serial/target/release"
SERIAL_RUNTIME="$SERIAL_OUT/${LIB_PREFIX}fresh_serial$LIB_SUFFIX"
snapshot "$WORK/serial.before" \
    "$SERIAL_OUT/fresh_serial.s" \
    "$SERIAL_OUT/fresh_serial$OBJ_SUFFIX" \
    "$SERIAL_RUNTIME" \
    "$SERIAL_OUT/fresh_serial.tlci" \
    "$SERIAL_RUNTIME.runtime-inputs"
sleep 1
run_serial serial-noop
[ "$code" -eq 0 ] || fail "serial worker no-op failed: $(cat "$err")"
assert_artifact_role "$out" Fresh "${LIB_PREFIX}fresh_serial$LIB_SUFFIX"
assert_artifact_role "$out" Fresh "fresh_serial.tlci"
snapshot "$WORK/serial.after" \
    "$SERIAL_OUT/fresh_serial.s" \
    "$SERIAL_OUT/fresh_serial$OBJ_SUFFIX" \
    "$SERIAL_RUNTIME" \
    "$SERIAL_OUT/fresh_serial.tlci" \
    "$SERIAL_RUNTIME.runtime-inputs"
assert_same "$WORK/serial.before" "$WORK/serial.after"

snapshot "$WORK/failure.before" \
    "$ROOT_ASM" "$ROOT_OBJ" "$ROOT_RUNTIME" "$ROOT_TLCI" "$ROOT_INPUTS"
sed 's/dep.add-one 42/dep.add-one 43/' "$WORK/pkg/src/main.tl" > "$WORK/main.next"
mv "$WORK/main.next" "$WORK/pkg/src/main.tl"
if [ "$HOST_OS" = linux ]; then
    FAIL_LINK="$WORK/fail-link"
    cat > "$FAIL_LINK" <<'EOF'
#!/usr/bin/env sh
exit 97
EOF
    chmod +x "$FAIL_LINK"
    TYPELISP_LINUX_CC=$FAIL_LINK
    export TYPELISP_LINUX_CC
    run_graph failed-link
    unset TYPELISP_LINUX_CC
else
    TYPELISP_WINDOWS_LINK=where.exe
    export TYPELISP_WINDOWS_LINK
    run_graph failed-link
    unset TYPELISP_WINDOWS_LINK
fi
[ "$code" -ne 0 ] || fail "failing linker package build unexpectedly succeeded"
snapshot "$WORK/failure.after" \
    "$ROOT_ASM" "$ROOT_OBJ" "$ROOT_RUNTIME" "$ROOT_TLCI" "$ROOT_INPUTS"
assert_same "$WORK/failure.before" "$WORK/failure.after"

echo "package artifact freshness verification passed ($HOST_OS)"
