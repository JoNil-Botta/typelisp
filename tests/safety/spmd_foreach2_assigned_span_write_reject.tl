;: A span bound the body can assign (here from a foreach-active body) is not
;: stable across the domain, so it cannot prove a row-major write.
(define (fill [out : (&mut out (__tl_dyn-array i64))] [h : i64] [w : i64]) : unit
  (let
    [width : i64 w]
    (foreach
      ([y : i64 0 h] [x : i64 0 width])
      (begin
        (set! (array-ref out (+ (* y width) x)) 1)
        (foreach-active [lane : i64] (set! width 1))))))

(define (main) : i64
  0)