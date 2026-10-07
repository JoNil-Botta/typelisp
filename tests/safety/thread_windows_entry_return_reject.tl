;; Returning the entry as an ordinary function value is a type mismatch
;; (#7742). Check-only; never executed.
(import stdlib.thread)

(define (entry) : (-> i64 i64)
  thread.thread-windows-entry)

(define (main) : i64
  0)