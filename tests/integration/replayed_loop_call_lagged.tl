;; A replayed scalar prefix exposes parallel phi inputs on the back edge.
;; The old counter must survive its increment so `a` receives the old value.
(import stdlib.io)
(import stdlib.string)

(define (probe [values : (& values (__tl_dyn-array i64))] [bias : i64]) : i64
  (let
    [i : i64 0]
    [total : i64 bias]
    (begin
      (while (< i (array-length values))
        (begin
          (set! total (+ (* total 3) (array-ref values i)))
          (set! i (+ i 1))))
      total)))

(define (lagged [values : (& values (__tl_dyn-array i64))] [n : i64]) : i64
  (let
    [i : i64 0]
    [a : i64 100]
    [d : i64 0]
    [r : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! d (- d 1))
          (set! r (- a (probe values 0)))
          (set! a i)
          (set! i (+ i 1))))
      (io.println "r={} d={}" r d)
      0)))

(define (main) : i64
  (let
    [values : (__tl_dyn-array i64) (__tl_make-array i64 8)]
    (lagged (& values) (string.>int (io.arg 1)))))