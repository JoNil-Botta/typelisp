;: A body-local `w` is not the header bound the span proof compares against.
(define (fill [out : (&mut out (__tl_dyn-array i64))] [h : i64] [w : i64]) : unit
  (foreach
    ([y : i64 0 h] [x : i64 0 w])
    (let
      [w : i64 9]
      (set! (array-ref out (+ (* y w) x)) 1))))

(define (main) : i64
  0)