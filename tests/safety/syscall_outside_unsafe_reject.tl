;; #9944: Unshadowed `syscall` still requires an enclosing `unsafe` context.
(define (main) : i64
  (syscall 39))