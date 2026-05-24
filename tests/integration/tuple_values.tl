;; Tuple local construction and tuple-ref reads (#313).
(define (main) : i64
  (let ([t : (Tuple bool i64) (tuple true 42)])
    (if (tuple-ref t 0)
      (tuple-ref t 1)
      0)))