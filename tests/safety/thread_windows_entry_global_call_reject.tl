;; A global of the entry's exact type keeps the unsafe effect, so a safe
;; call through it is rejected (#7742). Check-only; never executed.
(import stdlib.thread)

(define saved : (CFunc unsafe-non-null (-> i64 i64))
  thread.thread-windows-entry)

(define (main) : i64
  (saved 0))