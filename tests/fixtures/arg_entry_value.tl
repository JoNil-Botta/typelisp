(import stdlib.io)

(define (record [limit : i64] [value : (Array i64 1)]) : i64
  (if (<= limit 0)
    (array-ref value 0)
    (bit-xor (+ limit (array-ref value 0)) (record (- limit 1) value))))

(define (main) : i64
  (let
    [seed : i64 (io.arg-count)]
    [a : i64 (record seed (array 2))]
    [b : i64 (record seed (array 3))]
    (bit-and (+ seed (+ a b)) 127)))