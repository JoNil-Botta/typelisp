;; Scalar-reference rank-2 `foreach` semantics (#7190). Every bound runs once,
;; in binding order, before the domain; an empty dimension runs nothing and
;; dominates overflow; otherwise span and domain-product overflow trap before
;; the first body effect; the domain runs lexicographically, the last binding
;; fastest. Each row of native.manifest runs one case, chosen by argv[1].
(import stdlib.io)
(import stdlib.string)

(define (bound [tag : (& tag str)] [value : i64]) : i64
  (begin
    (io.println "{}={}" tag value)
    value))

;; Logs every (y, x) instance in execution order through a serialized body.
(define (run [y0 : i64] [y1 : i64] [x0 : i64] [x1 : i64]) : unit
  (let
    [count : i64 0]
    (begin
      (foreach
        ([y : i64 (bound "y0" y0) (bound "y1" y1)]
          [x : i64 (bound "x0" x0) (bound "x1" x1)])
        (foreach-active
          [lane : i64]
          (io.println "({} {})" (lane-value y) (lane-value x))
          (set! count (+ count 1))))
      (io.println "count={}" count))))

;; Canonical row-major writes with nonzero lower bounds and a uniform base.
(define (row-major) : unit
  (let
    [out : (Array i64 10) (make-array i64 10)]
    [base : i64 1]
    [y0 : i64 -1]
    [y1 : i64 2]
    [x0 : i64 3]
    [x1 : i64 6]
    (begin
      (foreach
        ([y : i64 y0 y1] [x : i64 x0 x1])
        (set!
          (array-ref out (+ base (+ (* (- y y0) (- x1 x0)) (- x x0))))
          (+ (* y 10) x)))
      (io.println
        "{} {} {} {} {} {} {} {} {} {}"
        (array-ref out 0)
        (array-ref out 1)
        (array-ref out 2)
        (array-ref out 3)
        (array-ref out 4)
        (array-ref out 5)
        (array-ref out 6)
        (array-ref out 7)
        (array-ref out 8)
        (array-ref out 9)))))

(define (main) : i64
  (let
    [mode : i64 (string.>int (io.arg 1))]
    [min : i64 (- -9223372036854775807 1)]
    [max : i64 9223372036854775807]
    (begin
      (cond
        [(= mode 1) (run 2 4 -1 2)]
        [(= mode 2) (row-major)]
        [(= mode 3)
          (begin
            (run 3 3 min max)
            (run min max 5 5)
            (run 5 2 0 4)
            (run 0 1 7 -7))]
        [(= mode 4) (run min max 0 1)]
        [(= mode 5) (run 0 1 min max)]
        [(= mode 6) (run 0 4294967296 0 2147483648)]
        [else (run 0 1 0 1)])
      0)))