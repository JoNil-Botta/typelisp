;; The dotted import establishes the source identity; the later path import
;; exposes the same declarations flat without creating a second nominal owner.
(import canonical_import_shared as shared)
(import "canonical_import_shared.tl")

(define (canonical-import-dotted-first-read
  [choice : shared.CanonicalImportChoice]) : i64
  (match choice
    [(shared.CanonicalImportChoice.Chosen item) (struct-get item value)]
    [(shared.CanonicalImportChoice.Missing) 0]))

(define (main) : i64
  (let
    [qualified-choice : shared.CanonicalImportChoice
      (shared.canonical-import-make)]
    [flat-value : CanonicalImportValue
      (CanonicalImportValue canonical-import-marker)]
    (+
      (canonical-import-dotted-first-read qualified-choice)
      (struct-get flat-value value))))