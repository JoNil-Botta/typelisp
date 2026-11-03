#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
. "$ROOT/scripts/lib-gate.sh"
gate_compiler
gate_compiler_absolute
gate_require_compiler
[ "$(uname -s)" = Linux ] || fail "Linux stack verification requires Linux"
for tool in as ld objcopy objdump gdb; do
    command -v "$tool" >/dev/null || fail "Linux stack verification requires $tool"
done
WORK=${TYPELISP_STACK_PROTECTION_WORK:-"$ROOT/target/linux-stack-protection"}
mkdir -p "$WORK"
. "$ROOT/scripts/lib-fixture-inventory.sh"
fixture_inventory_load tests/fixtures/linux-stack-protection.fixtures.cases "$WORK/fixtures.tsv"
ulimit -c 0
bounded() {
    name=$1
    cap=$2
    shift 2
    env -u BASH_ENV "$ROOT/scripts/run-memory-bounded.sh" \
        --limit-mib "$cap" --timeout-seconds 120 --report "$WORK/$name.memory" \
        -- env -u BASH_ENV "$@"
}
bounded oracle-build 6144 "$COMPILER" build tools/linux-stack-protection/main.tl \
    --stdlib-root stdlib --stdlib-root src --opt-level 1 -o "$WORK/oracle"
for size in 0 128 4080 4096 4104 8192 8200 32760 32768 32776 65536 262144 1048576 1073741808 1073741824; do
    for kind in plan transient; do
        bounded "$kind-$size" 512 "$WORK/oracle" "$kind" "$size" "$WORK/$kind-$size.s" "$WORK/$kind-$size.bytes"
        as "$WORK/$kind-$size.s" -o "$WORK/$kind-$size.o"
        objcopy -O binary --only-section=.text "$WORK/$kind-$size.o" "$WORK/$kind-$size.assembled"
        cmp "$WORK/$kind-$size.bytes" "$WORK/$kind-$size.assembled"
        objdump -dr "$WORK/$kind-$size.o" > "$WORK/$kind-$size.dump"
    done
done
. "$ROOT/scripts/verify-linux-stack-combinations.sh"
"$WORK/oracle" generate 0 "$WORK/small.tl"
"$WORK/oracle" generate 2304 "$WORK/large-object.tl"
fixture_inventory_require "$WORK/fixtures.tsv" tests/fixtures/linux_stack_large.tl
cp tests/fixtures/linux_stack_large.tl "$WORK/pic.tl"
bounded pic-large-compile 512 "$COMPILER" compile "$WORK/pic.tl" \
    --pic --opt-level 0 --stdlib-root stdlib --stdlib-root src -o "$WORK/pic.s"
grep -x '997:' "$WORK/pic.s" >/dev/null || fail "PIC finalizer omitted large-frame probes"
cat > "$WORK/overflow.gdb" <<'EOF'
set pagination off
set confirm off
set debuginfod enabled off
set disable-randomization off
handle SIGSEGV stop print pass
break *main
run
set $stack_low = (unsigned long)$rsp + 8 - 1073741824
delete breakpoints
continue
set $fault = (unsigned long)$_siginfo._sifields._sigfault.si_addr
printf "GUARD_FAULT=%d\n", $fault >= $stack_low - 65536 && $fault < $stack_low
printf "FAULT=%p LOW=%p PC=%p\n", $fault, $stack_low, $pc
info proc mappings
x/4i $pc
continue
EOF
observe_overflow() {
    cell=$1
    bounded "$cell-run" 2048 gdb -q -nx -batch -x "$WORK/overflow.gdb" --args "$WORK/$cell" \
        > "$WORK/$cell.gdb.log" 2>&1
    grep -F 'GUARD_FAULT=1' "$WORK/$cell.gdb.log" >/dev/null || fail "$cell missed its guard"
    grep -F 'terminated with signal SIGSEGV' "$WORK/$cell.gdb.log" >/dev/null || fail "$cell did not terminate through SIGSEGV"
    case "$cell" in
        *-large-*)
            grep -E '^=>.*testb.*\(%rsp\)' "$WORK/$cell.gdb.log" >/dev/null || fail "$cell faulted after its probe prologue"
            ;;
    esac
}
require_recursion() {
    awk '
        /<stack_dive>:/ {inside=1; next}
        inside && /^[[:xdigit:]]+ <[[:alpha:]_]/ {inside=0}
        inside && /call.*<stack_dive>/ {found=1}
        END {exit !found}
    ' "$1" || fail "missing recursive call inside stack_dive: $1"
}
for opt in 0 1 2; do
    for size in small large; do
        case "$size" in
            small) source="$WORK/small.tl" ;;
            large) source=tests/fixtures/linux_stack_large.tl ;;
        esac
        case "$source" in tests/*) fixture_inventory_require "$WORK/fixtures.tsv" "$source" ;; esac
        cell="text-$size-o$opt"
        bounded "$cell-compile" 512 "$COMPILER" compile "$source" \
            --stdlib-root stdlib --stdlib-root src --opt-level "$opt" -o "$WORK/$cell.s"
        as "$WORK/$cell.s" -o "$WORK/$cell.o"
        ld -e _tl_start "$WORK/$cell.o" -o "$WORK/$cell"
        objdump -dr "$WORK/$cell" > "$WORK/$cell.dump"
        require_recursion "$WORK/$cell.dump"
        if [ "$size" = large ]; then
            grep -x '997:' "$WORK/$cell.s" >/dev/null || fail "$cell lacks a probe loop"
        fi
        observe_overflow "$cell"
        case "$size" in
            small) source="$WORK/small.tl" ;;
            large) source="$WORK/large-object.tl" ;;
        esac
        cell="object-$size-o$opt"
        bounded "$cell-compile" 512 "$WORK/oracle" object "$source" "$opt" "$WORK/$cell.o"
        ld -e _tl_start "$WORK/$cell.o" -o "$WORK/$cell"
        objdump -dr "$WORK/$cell" > "$WORK/$cell.dump"
        require_recursion "$WORK/$cell.dump"
        observe_overflow "$cell"
    done
done
for fixture in lifetime canary observations; do
    cell="worker-$fixture"
    fixture_inventory_require "$WORK/fixtures.tsv" "tests/fixtures/linux_stack_$fixture.tl"
    bounded "$cell-compile" 512 "$COMPILER" compile "tests/fixtures/linux_stack_$fixture.tl" \
        --stdlib-root stdlib --stdlib-root src --opt-level 2 -o "$WORK/$cell.s"
    as "$WORK/$cell.s" -o "$WORK/$cell.o"
    ld -e _tl_start "$WORK/$cell.o" -o "$WORK/$cell"
    status=0
    bounded "$cell-run" 2048 "$WORK/$cell" || status=$?
    [ "$status" -eq 42 ] || fail "$cell returned $status, expected 42"
done
. "$ROOT/scripts/verify-linux-stack-edges.sh"
echo "Linux stack protection: encoding boundaries, 12 full-size overflow cells, worker lifetime and edge witnesses passed"
