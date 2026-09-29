;; A mutex handle is a move-only checked authority, not a copyable record:
;; `share` issues another handle, and reusing a moved one is rejected (#7755).
(import stdlib.sync)
(import (sync.mutex i64) as mutex_i64)

(define (keep [mutex : mutex_i64.Mutex]) : unit
  (mutex_i64.release mutex))

(define (bad [mutex : mutex_i64.Mutex]) : unit
  (begin
    (keep mutex)
    (keep mutex)))

(define (main) : i64
  0)