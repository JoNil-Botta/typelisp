;: SPEC safe-code contract: in-bounds collection access, checked aggregate
;: construction, race-free SPMD, and valid comptime values have defined results.
(import "stdlib/core_macros.tl" module stdlib.core_macros as core)

(import "stdlib/string.tl")

(defstruct Point
  (x i64)
  (y i64))

(defenum MaybeI64
  (Nope)
  (SomeI64 i64))

(define (fill [out : (Array i64)] [n : i64]) : unit
  (foreach ([i : i64 0 n]) (array-set! out i (+ i 1))))

(define (main) : i64
  (let
    [items : (Array i64) (make-array i64 3)]
    [p : Point (Point 20 22)]
    [m : MaybeI64 (SomeI64 7)]
    (begin
      (fill items 3)
      (core/cond
        (!= (array-ref items 2) 3)
        1
        (!= (string-length (substring "abcdef" 1 3)) 3)
        2
        (!= (+ (struct-get p x) (struct-get p y)) 42)
        3
        (!=
          (match m
            [(SomeI64 v) v]
            [Nope 0])
          7)
        4
        (!= (comptime (+ 40 2)) 42)
        5
        42))))