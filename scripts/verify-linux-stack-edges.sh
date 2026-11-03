#!/usr/bin/env sh
# Sourced by verify-linux-stack-protection.sh after its bounded matrix.
# GDB is a test-only observer and re-delivers the original fatal signal.
: "${ROOT:?}" "${WORK:?}" "${COMPILER:?}"
compile_edge() {
    edge=$1
    source=$2
    shift 2
    fixture_inventory_require "$WORK/fixtures.tsv" "$source"
    bounded "$edge-compile" 512 "$COMPILER" compile "$source" \
        --stdlib-root stdlib --stdlib-root src --opt-level 2 "$@" -o "$WORK/$edge.s"
    as "$WORK/$edge.s" -o "$WORK/$edge.o"
    ld -e _tl_start "$WORK/$edge.o" -o "$WORK/$edge"
}
cat > "$WORK/worker-failure.gdb" <<'STACK_EOF'
set pagination off
set confirm off
set debuginfod enabled off
set disable-randomization off
break *main
run
 delete breakpoints
set $entry = 1
catch syscall mmap mprotect clone munmap
commands
silent
if $entry
  if $orig_rax == 11
    printf "UNMAP=%ld\n", $rsi
  end
  if ($kind == 0 && $orig_rax == 9 && $rsi == 4096) || ($kind == 1 && $orig_rax == 9 && $rsi == 1114112) || ($kind == 2 && $orig_rax == 10 && $rsi == 1048576) || ($kind == 3 && $orig_rax == 56)
    printf "INJECTED=%d\n", $kind
    set $orig_rax = -1
  end
end
set $entry = !$entry
continue
end
continue
STACK_EOF
cat > "$WORK/main-failure.gdb" <<'STACK_EOF'
set pagination off
set confirm off
set debuginfod enabled off
set disable-randomization off
set $entry = 1
catch syscall mmap mprotect munmap
commands
silent
if $entry
  if $orig_rax == 11
    printf "UNMAP=%ld\n", $rsi
  end
  if ($kind == 0 && $orig_rax == 9 && $rsi == 1073807360) || ($kind == 1 && $orig_rax == 10 && $rsi == 1073741824)
    printf "INJECTED=%d\n", $kind
    set $orig_rax = -1
  end
end
set $entry = !$entry
continue
end
run
STACK_EOF
cat > "$WORK/worker-observer.gdb" <<'STACK_EOF'
set pagination off
set confirm off
set debuginfod enabled off
set disable-randomization off
set follow-fork-mode child
set detach-on-fork on
handle SIGSEGV stop print pass
break *stack_worker_dive
commands
silent
set $body_before = *(long*)&_tl_linux_stack_canary_body_count
continue
end
run
set $base = *(unsigned long*)&_tl_linux_stack_canary_stack_base
set $heap = *(unsigned long*)&_tl_linux_stack_canary_heap_sentinel
set $fault = (unsigned long)$_siginfo._sifields._sigfault.si_addr
printf "WORKER_GUARD=%d\n", $fault >= $base + 4096 && $fault < $base + 4096 + 65536
printf "BODY_UNCHANGED=%d\n", *(long*)&_tl_linux_stack_canary_body_count == $body_before
set $canary_ok = 1
set $heap_ok = 1
set $i = 0
while $i < 512
  if *(unsigned long*)($base + $i * 8) != 0x1234567812345678
    set $canary_ok = 0
  end
  if *(unsigned long*)($heap + $i * 8) != 0x1234567812345678
    set $heap_ok = 0
  end
  set $i = $i + 1
end
printf "CANARY=%d HEAP=%d\n", $canary_ok, $heap_ok
info proc mappings
x/4i $pc
continue
STACK_EOF
cat > "$WORK/foreign-copy.s" <<'STACK_EOF'
.text
.globl tl_memcpy
tl_memcpy:
    movq %rdi, %rax
    movq %rdx, %rcx
    rep movsb
    ret
.section .note.GNU-stack,"",@progbits
STACK_EOF
cat > "$WORK/foreign-host.s" <<'STACK_EOF'
.text
.globl _start
_start:
    movq $0x1003, %rdi
    leaq fs_before(%rip), %rsi
    movq $158, %rax
    syscall
    xorq %rdi, %rdi
    movq $65536, %rsi
    movq $3, %rdx
    movq $0x22, %r10
    movq $-1, %r8
    xorq %r9, %r9
    movq $9, %rax
    syscall
    movq %rax, %r12
.if MODE != 0
    xorq %rdi, %rdi
    movq $327680, %rsi
    xorq %rdx, %rdx
    movq $9, %rax
    syscall
    movq %rax, %r13
    leaq 65536(%rax), %rdi
    movq $262144, %rsi
    movq $3, %rdx
    movq $10, %rax
    syscall
.if MODE == 1
    leaq 327680(%r13), %rsp
.else
    leaq 98304(%r13), %rsp
.endif
.endif
    movq %r12, %rdi
    xorq %rsi, %rsi
    call stack_foreign_probe
    movq %rax, %r12
    movq $0x1003, %rdi
    leaq fs_after(%rip), %rsi
    movq $158, %rax
    syscall
    movq fs_before(%rip), %rax
    cmpq fs_after(%rip), %rax
    je 1f
    movq $126, %r12
1:  movq %r12, %rdi
    movq $231, %rax
    syscall
.bss
.balign 8
fs_before: .zero 8
fs_after: .zero 8
.section .note.GNU-stack,"",@progbits
STACK_EOF
cat > "$WORK/foreign-negative.gdb" <<'STACK_EOF'
set pagination off
set confirm off
set debuginfod enabled off
set disable-randomization off
handle SIGSEGV stop print pass
break *stack_foreign_probe
run
set $low = (unsigned long)$r13 + 65536
delete breakpoints
continue
set $fault = (unsigned long)$_siginfo._sifields._sigfault.si_addr
printf "FOREIGN_GUARD=%d\n", $fault >= $low - 65536 && $fault < $low
info proc mappings
x/4i $pc
continue
STACK_EOF
compile_edge setup-failure tests/fixtures/linux_stack_setup_failure.tl
for kind in 0 1 2 3; do
    log="$WORK/worker-failure-$kind.log"
    bounded "worker-failure-$kind" 512 gdb -q -nx -batch -ex "set \$kind = $kind" \
        -x "$WORK/worker-failure.gdb" --args "$WORK/setup-failure" > "$log" 2>&1
    grep -F "INJECTED=$kind" "$log" >/dev/null || fail "worker failure $kind not injected"
    grep -F 'exited with code 052' "$log" >/dev/null || fail "worker failure $kind did not return its error"
    case "$kind" in 0) expected=0 ;; 1) expected=1 ;; *) expected=2 ;; esac
    actual=$(grep -c '^UNMAP=' "$log" || true)
    [ "$actual" -eq "$expected" ] || fail "worker failure $kind cleanup count $actual"
    if [ "$kind" -ge 2 ]; then
        grep -x 'UNMAP=1114112' "$log" >/dev/null || fail "worker stack cleanup missing"
    fi
    if [ "$kind" -ge 1 ]; then
        grep -x 'UNMAP=4096' "$log" >/dev/null || fail "worker control cleanup missing"
    fi
done
compile_edge initializer tests/fixtures/linux_stack_initializer.tl
for route in initializer object-small-o2; do
    for kind in 0 1; do
        log="$WORK/$route-failure-$kind.log"
        bounded "$route-failure-$kind" 512 gdb -q -nx -batch -ex "set \$kind = $kind" \
            -x "$WORK/main-failure.gdb" --args "$WORK/$route" > "$log" 2>&1
        grep -F "INJECTED=$kind" "$log" >/dev/null || fail "main failure not injected"
        grep -F 'typelisp runtime: main-stack reservation failed' "$log" >/dev/null || fail "main diagnostic missing"
        grep -F 'exited with code 0206' "$log" >/dev/null || fail "main failure did not exit 134"
        if grep -F USER-INIT "$log" >/dev/null; then fail "initializer ran before protection"; fi
        if [ "$kind" -eq 1 ]; then
            grep -x 'UNMAP=1073807360' "$log" >/dev/null || fail "main reservation cleanup missing"
        fi
    done
done
for variant in small large; do
    case "$variant" in
        small) compile_edge worker-observed-small tests/fixtures/linux_stack_canary.tl ;;
        large) compile_edge worker-observed-large tests/fixtures/linux_stack_canary.tl --cfg linux-stack-large ;;
    esac
    observer="$WORK/worker-$variant.gdb"
    if [ "$variant" = small ]; then
        sed '/^break /,/^end$/d; /BODY_UNCHANGED/d' "$WORK/worker-observer.gdb" > "$observer"
    else
        cp "$WORK/worker-observer.gdb" "$observer"
    fi
    log="$WORK/worker-observed-$variant.log"
    bounded "worker-observed-$variant" 2048 gdb -q -nx -batch -x "$observer" \
        --args "$WORK/worker-observed-$variant" > "$log" 2>&1
    for proof in WORKER_GUARD=1 'CANARY=1 HEAP=1' 'terminated with signal SIGSEGV'; do
        grep -F "$proof" "$log" >/dev/null || fail "worker $variant missed $proof"
    done
    if [ "$variant" = large ]; then
        grep -F BODY_UNCHANGED=1 "$log" >/dev/null || fail "large worker entered its body"
    fi
done
fixture_inventory_require "$WORK/fixtures.tsv" tests/fixtures/linux_stack_foreign.tl
bounded foreign-compile 512 "$COMPILER" compile tests/fixtures/linux_stack_foreign.tl \
    --no-entry --stdlib-root stdlib --opt-level 2 -o "$WORK/foreign.s"
as "$WORK/foreign.s" -o "$WORK/foreign.o"
as "$WORK/foreign-copy.s" -o "$WORK/foreign-copy.o"
cc -no-pie "$WORK/foreign.o" "$WORK/foreign-copy.o" -o "$WORK/foreign-crt"
status=0
bounded foreign-crt 512 "$WORK/foreign-crt" || status=$?
[ "$status" -eq 42 ] || fail "CRT entry returned $status"
for mode in 0 1 2; do
    as --defsym "MODE=$mode" "$WORK/foreign-host.s" -o "$WORK/foreign-host-$mode.o"
    ld -e _start "$WORK/foreign-host-$mode.o" "$WORK/foreign.o" "$WORK/foreign-copy.o" -o "$WORK/foreign-host-$mode"
    if [ "$mode" -lt 2 ]; then
        status=0
        bounded "foreign-host-$mode" 512 "$WORK/foreign-host-$mode" || status=$?
        [ "$status" -eq 42 ] || fail "foreign entry $mode returned $status or changed FS"
    fi
done
bounded foreign-negative 512 gdb -q -nx -batch -x "$WORK/foreign-negative.gdb" \
    --args "$WORK/foreign-host-2" > "$WORK/foreign-negative.log" 2>&1
grep -F FOREIGN_GUARD=1 "$WORK/foreign-negative.log" >/dev/null || fail "foreign guard missed"
grep -F 'terminated with signal SIGSEGV' "$WORK/foreign-negative.log" >/dev/null || fail "foreign signal missing"
compile_edge debug-frame tests/fixtures/linux_stack_large.tl --debug
objdump -d "$WORK/debug-frame" > "$WORK/debug-frame.dump"
objdump --dwarf=frames "$WORK/debug-frame" > "$WORK/debug-frame.frames"
awk '/<stack_dive>:/ {inside=1; next}
    inside && /testb.*\(%rsp\)/ {gsub(/:/,"",$1); print $1; if (++n==2) exit}
' "$WORK/debug-frame.dump" > "$WORK/probe-pcs.txt"
[ "$(wc -l < "$WORK/probe-pcs.txt")" -eq 2 ] || fail "debug probe PCs missing"
loop=$(sed -n '1p' "$WORK/probe-pcs.txt")
tail=$(sed -n '2p' "$WORK/probe-pcs.txt")
cat > "$WORK/probe-cfi.gdb" <<STACK_EOF
set pagination off
set confirm off
set debuginfod enabled off
set disable-randomization off
break *stack_dive
run
set \$return_pc = *(unsigned long*)\$rsp
set \$caller_sp = (unsigned long)\$rsp + 8
delete breakpoints
break *0x$loop
continue
info frame
up
printf "LOOP_UNWIND=%d\n", \$pc == \$return_pc && \$sp == \$caller_sp
down
delete breakpoints
break *0x$tail
continue
info frame
up
printf "REMAINDER_UNWIND=%d\n", \$pc == \$return_pc && \$sp == \$caller_sp
down
kill
STACK_EOF
bounded probe-cfi 512 gdb -q -nx -batch -x "$WORK/probe-cfi.gdb" \
    --args "$WORK/debug-frame" > "$WORK/probe-cfi.log" 2>&1
grep -F LOOP_UNWIND=1 "$WORK/probe-cfi.log" >/dev/null || fail "loop CFA/return recovery failed"
grep -F REMAINDER_UNWIND=1 "$WORK/probe-cfi.log" >/dev/null || fail "remainder CFA/return recovery failed"
echo "Linux stack edges: setup cleanup, heap sentinels, worker faults, foreign stacks and probe CFI passed"
