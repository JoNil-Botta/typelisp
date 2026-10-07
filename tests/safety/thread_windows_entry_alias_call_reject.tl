;; A local alias keeps the entry's unsafe call effect, so calling it
;; from safe code is rejected (#7742). Check-only; never executed.
(import stdlib.thread)

(define (main) : i64
  (let
    [entry : (CFunc unsafe-non-null (-> i64 i64)) thread.thread-windows-entry]
    (entry 0)))