;; compiler_ctfe_smoke.tl - Runnable CTFE smoke for inline Rust migration (#1043).
;; lint-allow: unused-import
(import stdlib.hashmap)
(import "../compiler_ctfe.tl")

(define (main) : i64
  (compiler-ctfe-self-test))