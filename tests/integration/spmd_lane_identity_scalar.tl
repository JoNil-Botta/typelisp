;; Scalar lane identity semantics for foreach and spmd-reduce (#2761).
(define (foreach-checksum [n : i64]) : i64
  (let
    [out : (Array i64) (make-array i64 n)]
    [i : i64 0]
    [acc : i64 0]
    (begin
      (foreach
        ([lane : i64 0 n])
        (array-set! out lane (+ (* (program-count) 10) (program-index))))
      (while (< i n)
        (begin
          (set! acc (+ acc (array-ref out i)))
          (set! i (+ i 1))))
      acc)))

(define (reduce-checksum [n : i64]) : i64
  (spmd-reduce sum ([i : i64 0 n]) 0 (+ (program-count) (program-index))))

(define (main) : i64
  (if (and (= (foreach-checksum 5) 50) (= (reduce-checksum 7) 7))
    42
    1))