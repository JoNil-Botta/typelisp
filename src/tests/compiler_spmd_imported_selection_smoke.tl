;; compiler_spmd_imported_selection_smoke.tl - imported package metadata matching.
(import compiler_lower_tests)

(define (main) : i64
  (if (compiler_lower_tests.compiler-lower-imported-spmd-selection-smoke-ok?)
    42
    1))