#!/usr/bin/env sh
set -eu

# verify-native-link-linux.sh - Linux native checks for the selfhost driver.
#
# Builds the selfhost driver (the `compile` subcommand of src/main.tl) with the
# compiler under test and links it with as/ld, then runs
# tests/codegen/native-link.cases with that driver as the compiler: the
# assembly it emits must assemble, link and run.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

case "$(uname -s)" in
    Linux*) ;;
    *)
        echo "selfhost native verification is Linux-only (requires as + ld)"
        exit 0
        ;;
esac

GATE_FAIL_PREFIX='FAIL: '
. "$ROOT/scripts/lib-gate.sh"
gate_compiler
gate_compiler_absolute
gate_require_compiler
for tool in as ld; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing tool: $tool"
done

WORKDIR="$ROOT/target/selfhost-native-verify"
DRIVER="$WORKDIR/compiler-driver"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

echo "[selfhost-native] compile src/main.tl"
# Relative --stdlib-root (cwd is $ROOT) so the implicit stdlib/runtime.tl
# prelude and resolved imports share one path spelling and dedup; an absolute
# root makes cli.tl's larger closure trip a duplicate-symbol error.
if ! "$COMPILER" compile src/main.tl --stdlib-root stdlib \
    --cfg compiler-build-identity -o "$DRIVER.s" \
    > "$DRIVER.compile.stdout" 2> "$DRIVER.compile.stderr"; then
    sed 's/^/  stdout: /' "$DRIVER.compile.stdout" >&2
    sed 's/^/  stderr: /' "$DRIVER.compile.stderr" >&2
    fail "src/main.tl compile failed"
fi
as "$DRIVER.s" -o "$DRIVER.o"
ld "$DRIVER.o" -o "$DRIVER" -static -e _tl_start
[ -x "$DRIVER" ] || fail "src/main.tl compile/link did not write executable"

exec env NATIVE_LINK_COMPILER="$COMPILER" TYPELISP_BIN="$DRIVER" \
    scripts/verify-codegen-cases.sh tests/codegen/native-link.cases
