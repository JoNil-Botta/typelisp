;; The backend thread entry has an unsafe call effect: a safe direct call
;; is rejected (#7742). Check-only; never executed.
(import stdlib.thread)

(define (main) : i64
  (thread.thread-windows-entry 0))