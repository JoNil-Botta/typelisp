;; compiler_backend_windows_driver_fixture.tl - emit Windows driver primitive fixture assembly.
(import stdlib.byte_buf)
(import stdlib.io)
(import compiler_backend)
(import compiler_diagnostic as diagnostic)

(define (main) : i64
  (if (< (io.arg-count) 2)
    (begin
      (io.print-error
        "compiler-backend-windows-driver-fixture: expected output path")
      1)
    (match (compiler_backend.compiler-backend-emit-source-for-target
      (compiler_backend.compiler-backend-windows-driver-runtime-source)
      (compiler_backend.CompilerBackendTarget.Windows))
      [(compiler_backend.ResultCompilerBackend.Ok asm)
        (begin
          (io.write-file (io.arg 1) (byte_buf.str-as-bytes (& asm)))
          0)]
      [(compiler_backend.ResultCompilerBackend.Err diag)
        (begin
          (io.print-error
            (diagnostic.compiler-diagnostic-render (box-get diag)))
          1)])))