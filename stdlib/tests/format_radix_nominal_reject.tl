(import stdlib.format)

(defstruct RadixNominal
  (value i64))

(define (main) : i64
  (format.format "{:o}" (RadixNominal 7))
  42)