(import stdlib.string)

;; Forcing test for the Linux syscall argument-register parallel move (audit #95).
;;
;; The kernel syscall arg registers (%rax,%rdi,%rsi,%rdx,%r10,%r8,%r9) are now
;; allocator-pooled, and -- unlike call args -- syscall operand vars are left
;; register-eligible (compiler-reg-call-arg-vars-instr-seq-scalar does not block
;; them). So a syscall operand can live in a kernel arg register that a DIFFERENT
;; operand must be moved INTO. A naive in-order emitter loads each kernel arg in
;; ascending order; an earlier load can clobber a source a later operand still
;; needs -> the later kernel arg gets the wrong value -> silent miscompile. This
;; is the same overwrite hazard the call arg-shuffle fixed (#43/#47/#48); the
;; sound fix routes the setup through the parallel-move solver, which orders the
;; moves so no source is clobbered before it is read (breaking true cycles with a
;; scavenged temp).
;;
;; `(syscall 1 fd buf count)` is `write(fd, buf, count)`. With the operands homed
;; in registers (fd in %rax, buf in %rdi, count in %rsi) the moves form a chain:
;; kernel arg1 %rdi <- fd(%rax), kernel arg2 %rsi <- buf(%rdi), kernel arg3
;; %rdx <- count(%rsi). The naive ascending emitter does %rdi<-fd FIRST (clobbers
;; buf's home %rdi), then %rsi<-%rdi reads the just-written fd (buf := fd), then
;; %rdx<-%rsi reads the just-written buf (count := fd) -- so write gets a bogus
;; buf and count and faults (-EFAULT). The sound parallel move emits the chain in
;; safe order (count, then buf, then fd), so write(1, buf, 9) writes the 9 bytes
;; and returns 9.
;;
;; `count`/`fd` come from `string-length` (a runtime field load the optimizer does
;; not fold) and `count/count`, so the operands are genuinely register-homed and
;; the conflict is real -- not constant-folded into immediates. Observed via
;; write's return value AND its stdout effect. Mirrors arg_register_swap_cycle.tl.
(define (main) : i64
  (let
    [msg : String "ABCDEFGHI"]
    [count : i64 (string.string-length msg)]
    [buf : i64
      (unsafe
        (cast (ptr->int (string-data msg)) : i64))]
    ;; count/count == 1 (== stdout), but opaque, so it pins a real division and
    ;; leaves fd/buf/count register-homed in a conflicting arrangement.
    [fd : i64 (/ count count)]
    [r : i64
      (unsafe
        (syscall 1 fd buf count))]
    (if (= r 9)
      42
      1)))
