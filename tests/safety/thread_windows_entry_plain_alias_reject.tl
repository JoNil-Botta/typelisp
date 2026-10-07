;; The entry cannot be bound as an ordinary function value, which would
;; erase its unsafe call effect (#7742). Check-only; never executed.
(import stdlib.thread)

(define (main) : i64
  (let
    [entry : (-> i64 i64) thread.thread-windows-entry]
    (entry 0)))