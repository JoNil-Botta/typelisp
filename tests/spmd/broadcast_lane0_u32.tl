;; SPMD broadcast corpus (#3006): u32 lane 0 broadcast is backend-observable.
;; n = 14 gives AVX2 a six-lane tail and AVX-512 one predicated tail gang.
(define (init [xs : (Array u32)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! xs i (cast (+ i 1) : u32))
        (set! i (+ i 1))))))

(define (fill [xs : (Array u32)] [out : (Array u32)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (spmd-broadcast (array-ref xs i) 0))))

(define (checksum [out : (Array u32)] [n : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc (cast (array-ref out i) : i64)))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [n : i64 14]
    [xs : (Array u32) (make-array u32 n)]
    [out : (Array u32) (make-array u32 n)]
    (begin
      (init xs n)
      (fill xs out n)
      (bit-and (checksum out n) 0xff))))