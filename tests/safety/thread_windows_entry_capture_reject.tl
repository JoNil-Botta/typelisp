;; A lambda that captures the entry and calls it outside `unsafe` is
;; rejected: capture keeps the effect (#7742). Check-only; never executed.
(import stdlib.thread)

(define (main) : i64
  (let
    [entry : (CFunc unsafe-non-null (-> i64 i64)) thread.thread-windows-entry]
    [call : (-> i64 i64)
      (lambda ([x : i64]) : i64
        (entry x))]
    (call 0)))