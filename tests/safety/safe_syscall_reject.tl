;: SPEC safe-code contract: raw host syscalls are not safe code.
(define (main) : i64
  (syscall 39))