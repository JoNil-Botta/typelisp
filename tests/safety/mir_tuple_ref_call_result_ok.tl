;; An element read from a call's tuple result holds the tuple in a temporary,
;; as a field read from a call's struct result does (#8449 M5).
(define (pair [n : i64]) : (Tuple bool i64)
  (tuple (> n 0) n))

(define (main) : i64
  (if (tuple-ref (pair 42) 0)
    (tuple-ref (pair 42) 1)
    1))