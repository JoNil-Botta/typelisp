(import compiler_backend_tests as backend_tests)

(define (main) : i64
  (if (backend_tests.compiler-backend-simd-copy-diagnostics-ok?)
    42
    1))