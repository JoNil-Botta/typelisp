;; Integer-to-pointer conversion must not be a safe declaration.
(import stdlib.thread)

(define (main) : i64
  (let
    [_ptr : (MutPtr i64) (thread.addr->mut-i64 0)]
    0))