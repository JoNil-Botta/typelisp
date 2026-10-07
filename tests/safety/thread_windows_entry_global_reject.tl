;; A global of ordinary function type cannot hold the entry (#7742).
;; Check-only; never executed.
(import stdlib.thread)

(define saved : (-> i64 i64)
  thread.thread-windows-entry)

(define (main) : i64
  0)