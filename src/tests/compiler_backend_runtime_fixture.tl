;; compiler_backend_runtime_fixture.tl - emit runtime-helper backend fixture assembly.
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.string)
(import "../compiler_backend.tl")

(define (compiler-backend-runtime-fixture-emit [target-name : String]) : ResultCompilerBackend
  (cond
    [(string.eq target-name "linux-x86_64")
      (compiler-backend-emit-program-linux
        (compiler-backend-runtime-helper-program))]
    [(string.eq target-name "windows-x86_64")
      (compiler-backend-emit-program-for-target
        (compiler-backend-runtime-helper-program)
        (CompilerBackendTarget.Windows))]
    [(string.eq target-name "windows-driver-primitives")
      (compiler-backend-emit-source-for-target
        (compiler-backend-windows-driver-runtime-source)
        (CompilerBackendTarget.Windows))]
    [else
      (ResultCompilerBackend.Err
        (box
          (compiler-diagnostic-at-start
            ""
            "compiler-backend-runtime-fixture: unknown target")))]))

(define (main) : i64
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (if (< (arg-count) 2)
      (begin
        (io.print-error
          "compiler-backend-runtime-fixture: expected output path")
        1)
      (let
        [target-name : String
          (if (< (arg-count) 3)
            "linux-x86_64"
            (io.arg 2))]
        ;; Keep the driver source emit direct in main; this is the compile-heavy
        ;; fixture path and avoids an extra helper wrapper in the native smoke.
        (if (string.eq target-name "windows-driver-primitives")
          (match (compiler-backend-emit-source-for-target
            (compiler-backend-windows-driver-runtime-source)
            (CompilerBackendTarget.Windows))
            [(ResultCompilerBackend.Ok asm)
              (begin
                (io.write-file (io.arg 1) (byte_buf.str-as-bytes (& asm)))
                0)]
            [(ResultCompilerBackend.Err diag)
              (begin
                (io.print-error (compiler-diagnostic-render (box-get diag)))
                1)])
          (match (compiler-backend-runtime-fixture-emit target-name)
            [(ResultCompilerBackend.Ok asm)
              (begin
                (io.write-file (io.arg 1) (byte_buf.str-as-bytes (& asm)))
                0)]
            [(ResultCompilerBackend.Err diag)
              (begin
                (io.print-error (compiler-diagnostic-render (box-get diag)))
                1)]))))))