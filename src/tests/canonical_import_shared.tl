(defstruct CanonicalImportValue
  (value i64))

(defenum CanonicalImportChoice
  (Chosen CanonicalImportValue)
  (Missing))

(define canonical-import-marker : i64
  21)

(define (canonical-import-make) : CanonicalImportChoice
  (CanonicalImportChoice.Chosen (CanonicalImportValue canonical-import-marker)))