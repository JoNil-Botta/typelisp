;; compiler_ctfe_smoke.tl - Runnable CTFE smoke for compiler_ctfe.tl.
;; lint-allow: unused-import
(import stdlib.hashmap)
(import compiler_ctfe)

(define (main) : i64
  (compiler_ctfe.compiler-ctfe-self-test))