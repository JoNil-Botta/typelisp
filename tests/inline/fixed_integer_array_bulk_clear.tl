(import stdlib.iterator)
(import stdlib.test)

(define (clear-and-read [dirty? : bool]) : i64
  (let
    [words : (Array u16 35) (make-array u16 35)]
    [sum : i64 0]
    (for [i (iterator.range 0 35)]
      (when dirty? (set! (array-ref words i) (cast (+ i 1) : u16)))
      (+= sum (cast (array-ref words i) : i64)))
    sum))

(test
  fixed-integer-array-bulk-clear
  (test.assert-i64-eq (clear-and-read true) 630 "write the whole fixed array")
  (test.assert-i64-eq
    (clear-and-read false)
    0
    "clear full words and trailing elements"))