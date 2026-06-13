;; SPMD broadcast corpus (#2883): lane 1 traps in scalar mode but is valid for
;; full AVX2/AVX-512 gangs over n = 8.
(define (init [xs : (Array i64)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! xs i (+ i 1))
        (set! i (+ i 1))))))

(define (fill [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (spmd-broadcast (array-ref xs i) 1))))

(define (checksum [out : (Array i64)] [n : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc (array-ref out i)))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [n : i64 8]
    [xs : (Array i64) (make-array i64 n)]
    [out : (Array i64) (make-array i64 n)]
    (begin
      (init xs n)
      (fill xs out n)
      (bit-and (checksum out n) 0xff))))