;: Raw host syscalls are accepted only in an explicit unsafe context.
(define (main) : i64
  (unsafe
    (syscall 39)))