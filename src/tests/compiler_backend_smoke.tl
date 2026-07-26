;; compiler_backend_smoke.tl - Runnable smoke for compiler_backend.tl.
(import "../compiler_backend_tests.tl")
(import "../compiler_builtin_ids.tl" as cbi)

(define (main) : i64
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (compiler-backend-self-test)))