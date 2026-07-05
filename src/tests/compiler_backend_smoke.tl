;; compiler_backend_smoke.tl - Runnable smoke for compiler_backend.tl.
(import "../compiler_backend_tests.tl")

(define (main) : i64
  (compiler-backend-self-test))