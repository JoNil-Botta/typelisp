;; A `bool` branch and an integer literal branch do not join (#8590).
(define (main) : i64
  (if (<
    (if false
      true
      1)
    2)
    7
    9))