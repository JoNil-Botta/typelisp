;; compiler_backend_windows_driver_fixture.tl - emit Windows driver primitive fixture assembly.
(import stdlib.io as io_mod)

(import "../compiler_backend.tl")

(define (main) : i64
  (if (< (io_mod.arg-count) 2)
    (begin
      (io_mod.print-error
        "compiler-backend-windows-driver-fixture: expected output path")
      1)
    (match (compiler-backend-emit-source-for-target
      (compiler-backend-windows-driver-runtime-source)
      (BackendTargetWindows))
      [(OkCompilerBackend asm)
        (begin
          (io_mod.write-file (io_mod.arg 1) asm)
          0)]
      [(ErrCompilerBackend diag)
        (begin
          (io_mod.print-error (compiler-diagnostic-render diag))
          1)])))