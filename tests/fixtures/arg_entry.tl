(import stdlib.io)

(define total : i64
  0)

(define (record [value : i64] [limit : i64]) : i64
  (let
    [i : i64 0]
    (while (< i limit)
      (set! total (+ total (bit-xor value i)))
      (+= i 1))
    total))

(define (single [value : i64] [limit : i64]) : i64
  (let
    [i : i64 0]
    (while (< i limit)
      (set! total (bit-xor total (+ value i)))
      (+= i 1))
    total))

(define (apply-one [f : (-> i64 i64 i64)] [seed : i64]) : i64
  (let
    [a : i64 (record seed 2)]
    [b : i64 (f seed 4)]
    (+ a (+ b seed))))

(define (main) : i64
  (let
    [seed : i64 (io.arg-count)]
    [other : i64 (bit-xor seed 25)]
    [a : i64 (record seed 2)]
    [b : i64 (record seed 3)]
    [c : i64 (record other 4)]
    [d : i64 (single seed 7)]
    [e : i64
      (apply-one
        (if (= seed 1)
          record
          single)
        seed)]
    (bit-and (+ a (+ b (+ c (+ d e)))) 127)))