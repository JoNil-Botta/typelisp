;; compiler_backend_stack_args_fixture.tl - emit the stack-passed call
;; argument witness program's assembly for a target so the integration suite can
;; assemble, link, and RUN it, proving each spilled argument arrives correctly.
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.string)
(import compiler_backend_tests)
(import compiler_backend as backend)
(import compiler_diagnostic as diagnostic)

(define (compiler-backend-stack-args-fixture-for-name [target-name : String]) : backend.ResultCompilerBackend
  (if (string.eq target-name "linux-x86_64")
    (compiler_backend_tests.compiler-backend-stack-args-fixture-emit
      (backend.CompilerBackendTarget.Linux))
    (if (string.eq target-name "windows-x86_64")
      (compiler_backend_tests.compiler-backend-stack-args-fixture-emit
        (backend.CompilerBackendTarget.Windows))
      (backend.ResultCompilerBackend.Err
        (box
          (diagnostic.compiler-diagnostic-at-start
            ""
            "compiler-backend-stack-args-fixture: unknown target"))))))

(define (main) : i64
  (if (< (io.arg-count) 2)
    (begin
      (io.print-error
        "compiler-backend-stack-args-fixture: expected output path")
      1)
    (let
      [target-name : String
        (if (< (io.arg-count) 3)
          "linux-x86_64"
          (io.arg 2))]
      (match (compiler-backend-stack-args-fixture-for-name target-name)
        [(backend.ResultCompilerBackend.Ok asm)
          (begin
            (io.write-file (io.arg 1) (byte_buf.str-as-bytes (& asm)))
            0)]
        [(backend.ResultCompilerBackend.Err diag)
          (begin
            (io.print-error
              (diagnostic.compiler-diagnostic-render (__tl-box-place diag)))
            1)]))))