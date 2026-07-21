;; Provider for mixed legacy-path and dotted enum identity coverage.
(defenum LegacyDottedEnum
  (Value i64))

(defstruct LegacyDottedStruct
  (value i64))

(define (legacy-dotted-enum-countdown
  [value : (& value LegacyDottedStruct)]
  [remaining : i64]) : i64
  (if (<= remaining 0)
    0
    (+ 1 (legacy-dotted-enum-countdown value (- remaining 1)))))