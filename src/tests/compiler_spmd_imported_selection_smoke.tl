;; compiler_spmd_imported_selection_smoke.tl - imported package metadata matching.
(import "../compiler_lower.tl")

(define (main) : i64
  (if (compiler-lower-imported-spmd-selection-smoke-ok?)
    42
    1))