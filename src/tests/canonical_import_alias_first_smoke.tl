;; An explicit alias followed by the default alias must not duplicate ownership.
(import canonical_import_shared as shared)
(import canonical_import_shared)

(define (canonical-import-alias-first-read
  [choice : shared.CanonicalImportChoice]) : i64
  (match choice
    [(shared.CanonicalImportChoice.Chosen item) (struct-get item value)]
    [(shared.CanonicalImportChoice.Missing) 0]))

(define (main) : i64
  (let
    [qualified-choice : shared.CanonicalImportChoice
      (shared.canonical-import-make)]
    [flat-value : canonical_import_shared.CanonicalImportValue
      (canonical_import_shared.CanonicalImportValue
        canonical_import_shared.canonical-import-marker)]
    (+
      (canonical-import-alias-first-read qualified-choice)
      (struct-get flat-value value))))