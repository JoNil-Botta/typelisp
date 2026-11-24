;; Implicit-cleanup arena escape: function parameter passed as `with` cleanup
;; inside a scoped arena must reject callers passing a leaking callback.
(import stdlib.string)

(define g : String
  "init")

(define (leak [_x : i64]) : unit
  (set! g (string.append "hello" "world")))

(define (run-with [cb : (-> i64 unit)]) : i64
  (with-arena r (with ([x 1 cb]) 0)))

(define (main) : i64
  (run-with leak)
  (if (string.eq (& g) "helloworld")
    42
    7))