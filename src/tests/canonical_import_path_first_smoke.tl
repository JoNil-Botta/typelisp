;; The path import establishes the source identity; the dotted alias must reuse it.
(module canonical.import.path_first)

(import "canonical_import_shared.tl")
(import canonical_import_shared as shared)

(define (canonical-import-path-first-read
  [choice : shared.CanonicalImportChoice]) : i64
  (match choice
    [(shared.CanonicalImportChoice.Chosen item) (struct-get item value)]
    [(shared.CanonicalImportChoice.Missing) 0]))

(define (main) : i64
  (let
    [qualified-value : shared.CanonicalImportValue
      (shared.CanonicalImportValue shared.canonical-import-marker)]
    [flat-choice : CanonicalImportChoice (canonical-import-make)]
    (+
      (struct-get qualified-value value)
      (canonical-import-path-first-read flat-choice))))