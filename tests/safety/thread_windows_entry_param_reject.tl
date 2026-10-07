;; Passing the entry where an ordinary function parameter is expected is a
;; type mismatch (#7742). Check-only; never executed.
(import stdlib.thread)

(define (invoke [f : (-> i64 i64)]) : i64
  (f 0))

(define (main) : i64
  (invoke thread.thread-windows-entry))