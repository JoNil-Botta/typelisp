(import "stdlib/core_macros.tl" module stdlib.core_macros as core)

(define (apply1 [f : (-> i64 i64)] [x : i64]) : i64
  (f x))

(define (case-immediate) : bool
  (let
    [n : i64 10]
    (=
      ((lambda ([x : i64]) : i64
          (+ x n))
        32)
      42)))

(define (case-passed-as-arg) : bool
  (let
    [n : i64 10]
    (=
      (apply1
        (lambda ([x : i64]) : i64
          (+ x n))
        32)
      42)))

(define (case-mixed-scalars) : bool
  (let
    [n : i64 32]
    [ok : bool true]
    [ch : char #A']
    [scale : f64 2.5]
    (=
      ((lambda ([x : i64]) : i64
          (if ok
            (if (= ch #A')
              (if (= scale 2.5)
                (+ x n)
                0)
              0)
            0))
        10)
      42)))

(define (case-function-capture) : bool
  (let
    [inc : (-> i64 i64)
      (lambda ([x : i64]) : i64
        (+ x 1))]
    [n : i64 9]
    (=
      ((lambda ([x : i64]) : i64
          (inc (+ x n)))
        32)
      42)))

(define (case-snapshot) : bool
  (let
    [n : i64 10]
    [f : (-> i64 i64)
      (lambda ([x : i64]) : i64
        (+ x n))]
    (begin
      (set! n 100)
      (= (f 32) 42))))

(define (case-nested) : bool
  (let
    [outer : i64 7]
    [make : (-> i64 (-> i64 i64))
      (lambda ([add : i64]) : (-> i64 i64)
        (lambda ([x : i64]) : i64
          (+ x (+ outer add))))]
    (= ((make 3) 32) 42)))

(define (case-shadowed-capture) : bool
  (let
    [n : i64 10]
    (=
      ((lambda ([x : i64]) : i64
          (+
            n
            (let
              [n : i64 100]
              (+ x n))))
        32)
      142)))

(define (main) : i64
  (begin
    (core/unless (case-immediate) (return 1))
    (core/unless (case-passed-as-arg) (return 2))
    (core/unless (case-mixed-scalars) (return 3))
    (core/unless (case-function-capture) (return 4))
    (core/unless (case-snapshot) (return 5))
    (core/unless (case-nested) (return 6))
    (core/unless (case-shadowed-capture) (return 7))
    42))