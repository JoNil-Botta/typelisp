;; compiler_check_smoke.tl - Runnable smoke for virtual-source check helpers.
(import "../compiler_check_core.tl")
(import compiler_builtin_ids as cbi)

(define (main) : i64
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (compiler-check-self-test)))