;; Control: function parameter passed as `with` cleanup inside a scoped arena
;; accepts a caller passing a non-leaking callback.
(define (noop [_x : i64]) : unit
  unit)

(define (run-with [cb : (-> i64 unit)]) : i64
  (with-arena r (with ([x 1 cb]) 42)))

(define (main) : i64
  (run-with noop))