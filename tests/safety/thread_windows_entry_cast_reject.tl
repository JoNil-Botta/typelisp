;; `cast` is no route to an ordinary function value: it rejects every
;; function type, the entry included (#7742). Check-only; never executed.
(import stdlib.thread)

(define (main) : i64
  (let
    [entry : (-> i64 i64) (cast thread.thread-windows-entry : (-> i64 i64))]
    0))