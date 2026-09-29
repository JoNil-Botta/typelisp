#!/usr/bin/env sh
set -eu

# verify-win64-seh-unwind.sh - Windows unwind descriptions of rbp-framed
# prologues (#7564). Needs a Windows host with clang, lld-link and
# llvm-readobj.
#
# 1. Savereg oracle. src/tests/compiler_backend_seh_savereg_fixture.tl emits
#    framed prologues through the backend's own entry and save splice. The
#    unwind rows the assembler encodes (near and far GP saves, XMM saves, a
#    probed allocation, no frame register) must equal
#    tests/fixtures/win64-seh/savereg-oracle.expected.
# 2. Virtual unwind. tests/fixtures/win64-seh/win64_seh_unwind.tl at
#    --opt-level 2 must keep seh-victim-framed as a described rbp frame and
#    seh-victim-fpo as a push prologue. Linked with driver.s.in, its probe
#    unwinds through each victim with RtlVirtualUnwind and must recover every
#    nonvolatile register the driver seeded, and the driver's %rsp and %rip.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-gate.sh"

case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*) ;;
    *) fail "win64 SEH unwind verification needs a Windows host" ;;
esac

gate_compiler
gate_compiler_absolute
gate_require_compiler

for tool in clang lld-link llvm-readobj cygpath; do
    command -v "$tool" >/dev/null 2>&1 \
        || fail "win64 SEH unwind verification requires $tool"
done

FIXTURES="$ROOT/tests/fixtures/win64-seh"
WORK="$ROOT/target/win64-seh-unwind-verify"
rm -rf "$WORK"
mkdir -p "$WORK"

# Each function's name, then its frame register and unwind codes.
unwind_rows() {
    llvm-readobj --unwind "$1" | tr -d '\r' | sed -n \
        -e 's/^ *StartAddress: \([^ ]*\).*/\1/p' \
        -e 's/^ *\(FrameRegister: .*\)/\1/p' \
        -e 's/^ *\(0x[0-9A-F]*: .*\)/\1/p'
}

# The rows of function $2 in rows file $1.
function_rows() {
    awk -v name="$2" '
        /^0x/ || /^FrameRegister:/ { if (on) print; next }
        { on = ($0 == name) }
    ' "$1"
}

count_rows() {
    printf '%s\n' "$1" | grep -c "$2" || true
}

"$COMPILER" run src/tests/compiler_backend_seh_savereg_fixture.tl \
    --stdlib-root "$ROOT/stdlib" \
    --stdlib-root "$ROOT/src" \
    -- "$WORK/oracle.s"
clang --target=x86_64-pc-windows-msvc -c "$WORK/oracle.s" -o "$WORK/oracle.obj"
unwind_rows "$WORK/oracle.obj" > "$WORK/oracle.rows"
# A Windows checkout may give the expected file CRLF line endings.
tr -d '\r' < "$FIXTURES/savereg-oracle.expected" > "$WORK/oracle.expected"
diff -u "$WORK/oracle.expected" "$WORK/oracle.rows" \
    || fail "win64 SEH savereg oracle rows differ from tests/fixtures/win64-seh/savereg-oracle.expected"
echo "win64 SEH savereg oracle rows match"

"$COMPILER" compile "$FIXTURES/win64_seh_unwind.tl" \
    --target windows-x86_64 \
    --opt-level 2 \
    --stdlib-root "$ROOT/stdlib" \
    -o "$WORK/fixture.s"
cp "$FIXTURES/driver.s.in" "$WORK/driver.s"
clang --target=x86_64-pc-windows-msvc -c "$WORK/fixture.s" -o "$WORK/fixture.obj"
clang --target=x86_64-pc-windows-msvc -c "$WORK/driver.s" -o "$WORK/driver.obj"
unwind_rows "$WORK/fixture.obj" > "$WORK/fixture.rows"

framed=$(function_rows "$WORK/fixture.rows" _tl_win64_seh_unwind_seh_victim_framed)
fpo=$(function_rows "$WORK/fixture.rows" _tl_win64_seh_unwind_seh_victim_fpo)
printf 'seh-victim-framed:\n%s\nseh-victim-fpo:\n%s\n' "$framed" "$fpo"
[ "$(count_rows "$framed" '^FrameRegister: -$')" -eq 1 ] \
    && [ "$(count_rows "$framed" 'SET_FPREG')" -eq 0 ] \
    && [ "$(count_rows "$framed" 'PUSH_NONVOL reg=RBP$')" -eq 1 ] \
    && [ "$(count_rows "$framed" 'SAVE_NONVOL reg=')" -ge 2 ] \
    && [ "$(count_rows "$framed" 'SAVE_XMM128 reg=XMM6,')" -eq 1 ] \
    || fail "seh-victim-framed is not a described rbp frame with GP and XMM saves"
[ "$(count_rows "$fpo" '^FrameRegister: -$')" -eq 1 ] \
    && [ "$(count_rows "$fpo" 'PUSH_NONVOL reg=')" -ge 1 ] \
    && [ "$(count_rows "$fpo" 'SAVE_NONVOL')" -eq 0 ] \
    && [ "$(count_rows "$fpo" 'SET_FPREG')" -eq 0 ] \
    || fail "seh-victim-fpo is not a push prologue"

lld-link -NOLOGO \
    "$(cygpath -aw "$WORK/fixture.obj")" \
    "$(cygpath -aw "$WORK/driver.obj")" \
    "-OUT:$(cygpath -aw "$WORK/fixture.exe")" \
    -SUBSYSTEM:CONSOLE -ENTRY:_tl_start -NODEFAULTLIB kernel32.lib ntdll.lib
status=0
"$WORK/fixture.exe" < /dev/null > "$WORK/run.out" 2>&1 || status=$?
cat "$WORK/run.out"
[ "$status" -eq 0 ] \
    && grep -q '^framed mismatch=0 ' "$WORK/run.out" \
    && grep -q '^fpo mismatch=0 ' "$WORK/run.out" \
    || fail "virtual unwind through the win64 SEH fixture did not recover the seeded registers (exit $status)"
echo "win64 SEH virtual unwind recovered every seeded register"
