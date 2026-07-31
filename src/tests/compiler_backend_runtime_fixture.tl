;; compiler_backend_runtime_fixture.tl - emit runtime-helper backend fixture assembly.
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.string)
(import compiler_backend)
(import compiler_builtin_ids as cbi)
(import compiler_diagnostic as diagnostic)

(define (compiler-backend-runtime-fixture-emit [target-name : String]) : compiler_backend.ResultCompilerBackend
  (cond
    [(string.eq target-name "linux-x86_64")
      (compiler_backend.compiler-backend-emit-program-linux
        (compiler_backend.compiler-backend-runtime-helper-program))]
    [(string.eq target-name "windows-x86_64")
      (compiler_backend.compiler-backend-emit-program-for-target
        (compiler_backend.compiler-backend-runtime-helper-program)
        (compiler_backend.CompilerBackendTarget.Windows))]
    [(string.eq target-name "windows-driver-primitives")
      (compiler_backend.compiler-backend-emit-source-for-target
        (compiler_backend.compiler-backend-windows-driver-runtime-source)
        (compiler_backend.CompilerBackendTarget.Windows))]
    [else
      (compiler_backend.ResultCompilerBackend.Err
        (box
          (diagnostic.compiler-diagnostic-at-start
            ""
            "compiler-backend-runtime-fixture: unknown target")))]))

(define (main) : i64
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (if (< (io.arg-count) 2)
      (begin
        (io.print-error
          "compiler-backend-runtime-fixture: expected output path")
        1)
      (let
        [target-name : String
          (if (< (io.arg-count) 3)
            "linux-x86_64"
            (io.arg 2))]
        ;; Keep the driver source emit direct in main; this is the compile-heavy
        ;; fixture path and avoids an extra helper wrapper in the native smoke.
        (if (string.eq target-name "windows-driver-primitives")
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
                1)])
          (match (compiler-backend-runtime-fixture-emit target-name)
            [(compiler_backend.ResultCompilerBackend.Ok asm)
              (begin
                (io.write-file (io.arg 1) (byte_buf.str-as-bytes (& asm)))
                0)]
            [(compiler_backend.ResultCompilerBackend.Err diag)
              (begin
                (io.print-error
                  (diagnostic.compiler-diagnostic-render (box-get diag)))
                1)]))))))