;: SPEC safe-code contract: in-bounds collection access, checked aggregate
;: construction, race-free SPMD, and valid comptime values have defined results.
(import stdlib.array)
(import "stdlib/string.tl")
(import "stdlib/option.tl")
(import (option i64) as option_i64)

(defstruct Point
  (x i64)
  (y i64))

(define (fill [out : (Array i64)] [n : i64]) : unit
  (foreach ([i : i64 0 n]) (array.array-set! out i (+ i 1))))

(define (main) : i64
  (let
    [items : (Array i64) (array.make-array i64 3)]
    [p : Point (Point 20 22)]
    [m : option_i64.Option (option_i64.Some 7)]
    (begin
      (fill items 3)
      (cond
        [(!= (array.array-ref items 2) 3) 1]
        [(!= (string-length (substring "abcdef" 1 3)) 3) 2]
        [(!= (+ (struct-get p x) (struct-get p y)) 42) 3]
        [(!=
            (match m
              [(option_i64.Some v) v]
              [(option_i64.None) 0])
            7)
          4]
        [(!= (comptime (+ 40 2)) 42) 5]
        [else 42]))))