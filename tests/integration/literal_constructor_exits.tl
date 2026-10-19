(import stdlib.test)

(define trace : i64
  0)

(define (mark [digit : i64]) : i64
  (set! trace (+ (* trace 10) digit))
  digit)

(define (box-return) : (Box i64)
  (box
    (begin
      (mark 1)
      (return (box 42)))))

(define (tuple-return) : (Tuple i64 i64 i64)
  (tuple (mark 1) (return (tuple 10 20 12)) (mark 9)))

(define (nested-return) : (Tuple (Tuple i64 i64) i64)
  (tuple (tuple (mark 1) (return (tuple (tuple 10 20) 12))) (mark 9)))

(define (zero-return) : unit
  (tuple
    unit
    (begin
      (mark 1)
      (return unit))
    (mark 9))
  (mark 9)
  unit)

(define (conditional-box [leave : bool]) : (Box i64)
  (box
    (if leave
      (return (box 42))
      7)))

(define (conditional-tuple [leave : bool]) : (Tuple i64 i64)
  (tuple
    (mark 1)
    (if leave
      (return (tuple 20 22))
      (mark 2))))

(define (loop-exits [boxed : bool] [continuing : bool]) : i64
  (let
    [i : i64 0]
    [n : i64 2]
    (while (< i 3)
      (+= i 1)
      (if boxed
        (begin
          (box
            (begin
              (+= n 10)
              (if continuing
                (continue)
                (break))
              (mark 9)))
          unit)
        (begin
          (tuple
            (begin
              (+= n 10)
              (if continuing
                (continue)
                (break))
              (mark 9))
            (mark 9))
          unit))
      (set! n 0))
    (+ n 1)))

(define (main) : i64
  (set! trace 0)
  (test.assert-i64-eq (deref (box-return)) 42 "box return")
  (test.assert-i64-eq trace 1 "box evaluates once before exit")
  (set! trace 0)
  (let
    [p : (Tuple i64 i64 i64) (tuple-return)]
    (test.assert-i64-eq
      (+ (tuple-ref p 0) (+ (tuple-ref p 1) (tuple-ref p 2)))
      42
      "memory-class tuple return"))
  (test.assert-i64-eq trace 1 "tuple skips later elements")
  (set! trace 0)
  (let
    [p : (Tuple (Tuple i64 i64) i64) (nested-return)]
    (test.assert-i64-eq
      (+
        (tuple-ref (tuple-ref p 0) 0)
        (+ (tuple-ref (tuple-ref p 0) 1) (tuple-ref p 1)))
      42
      "nested tuple return"))
  (test.assert-i64-eq trace 1 "nested literal skips outer tail")
  (set! trace 0)
  (zero-return)
  (test.assert-i64-eq trace 1 "zero-sized element exits")
  (test.assert-i64-eq (deref (conditional-box true)) 42 "box conditional exit")
  (test.assert-i64-eq (deref (conditional-box false)) 7 "box fallthrough")
  (set! trace 0)
  (let
    [p : (Tuple i64 i64) (conditional-tuple true)]
    (test.assert-i64-eq
      (+ (tuple-ref p 0) (tuple-ref p 1))
      42
      "tuple conditional exit"))
  (test.assert-i64-eq trace 1 "conditional exit skips element tail")
  (set! trace 0)
  (let
    [p : (Tuple i64 i64) (conditional-tuple false)]
    (test.assert-i64-eq
      (+ (tuple-ref p 0) (tuple-ref p 1))
      3
      "tuple fallthrough"))
  (test.assert-i64-eq trace 12 "fallthrough evaluates left to right")
  (set! trace 0)
  (test.assert-i64-eq (loop-exits false true) 33 "tuple continue")
  (test.assert-i64-eq (loop-exits false false) 13 "tuple break")
  (test.assert-i64-eq (loop-exits true true) 33 "box continue")
  (test.assert-i64-eq (loop-exits true false) 13 "box break")
  (test.assert-i64-eq trace 0 "loop exits skip later operands")
  42)