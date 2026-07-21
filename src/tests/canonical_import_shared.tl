(defstruct CanonicalImportValue
  (value i64))

(defenum CanonicalImportChoice
  (Chosen CanonicalImportValue)
  (Missing))

(define canonical-import-marker : i64
  21)

(define (canonical-import-make) : CanonicalImportChoice
  (CanonicalImportChoice.Chosen (CanonicalImportValue canonical-import-marker)))

(define (canonical-import-choice-countdown
  [choice : (& choice CanonicalImportChoice)]
  [remaining : i64]) : i64
  (if (<= remaining 0)
    0
    (+ 1 (canonical-import-choice-countdown choice (- remaining 1)))))
