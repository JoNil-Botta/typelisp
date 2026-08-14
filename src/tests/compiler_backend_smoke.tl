;; compiler_backend_smoke.tl - Runnable smoke for compiler_backend.tl.
(import compiler_backend_tests)
(import compiler_builtin_ids as cbi)

(define (main) : i64
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (cfg
      scratch-vreg
      (compiler_backend_tests.compiler-backend-scratch-vreg-self-test)
      (compiler_backend_tests.compiler-backend-self-test))))