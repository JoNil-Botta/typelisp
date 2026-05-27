;; compiler_backend_windows_driver_fixture.tl - emit Windows driver primitive fixture assembly.
(import "compiler_backend.tl")

(define (main) : i64
  (if (< (arg-count) 2)
    (begin
      (print-error
        "compiler-backend-windows-driver-fixture: expected output path")
      1)
    (match (compiler-backend-emit-source-for-target
      (compiler-backend-windows-driver-runtime-source)
      (BackendTargetWindows))
      [(OkCompilerBackend asm)
        (begin
          (write-file (arg 1) asm)
          0)]
      [(ErrCompilerBackend diag)
        (begin
          (print-error (compiler-diagnostic-render diag))
          1)])))