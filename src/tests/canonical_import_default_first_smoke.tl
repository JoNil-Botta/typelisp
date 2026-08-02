;; A default alias and an explicit alias must reuse one canonical source identity.
(module canonical.import.default_first)

(import canonical_import_shared)
(import canonical_import_shared as shared)

(define (canonical-import-default-first-read
  [choice : shared.CanonicalImportChoice]) : i64
  (match choice
    [(shared.CanonicalImportChoice.Chosen item) (struct-get item value)]
    [(shared.CanonicalImportChoice.Missing) 0]))

(define (main) : i64
  (let
    [qualified-value : shared.CanonicalImportValue
      (shared.CanonicalImportValue shared.canonical-import-marker)]
    [flat-choice : canonical_import_shared.CanonicalImportChoice
      (canonical_import_shared.canonical-import-make)]
    (+
      (struct-get qualified-value value)
      (canonical-import-default-first-read flat-choice))))