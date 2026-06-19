;; Backend-observable SPMD lane identity fixture (#2761).
;;
;; n = 13 gives AVX2 a one-lane scalar tail and AVX-512 a five-lane masked
;; tail. Each active lane writes `program-count * 10 + program-index`.
(define (fill [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (* (program-count) 10) (program-index)))))

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
    [n : i64 13]
    [out : (Array i64) (make-array i64 n)]
    (begin
      (fill out n)
      (bit-and (checksum out n) 0xff))))