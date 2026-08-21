;; compiler_backend_raw_pointer_fixture.tl - emit the raw-pointer backend
;; witness program's assembly for a target so the integration suite can
;; assemble, link, and run it.
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.string)
(import compiler_backend_tests)
(import compiler_backend as backend)
(import compiler_diagnostic as diagnostic)

(define (compiler-backend-raw-pointer-fixture-for-name [target-name : String]) : backend.ResultCompilerBackend
  (if (string.eq target-name "linux-x86_64")
    (compiler_backend_tests.compiler-backend-raw-pointer-fixture-emit
      (backend.CompilerBackendTarget.Linux))
    (if (string.eq target-name "windows-x86_64")
      (compiler_backend_tests.compiler-backend-raw-pointer-fixture-emit
        (backend.CompilerBackendTarget.Windows))
      (backend.ResultCompilerBackend.Err
        (box
          (diagnostic.compiler-diagnostic-at-start
            ""
            "compiler-backend-raw-pointer-fixture: unknown target"))))))

(define (main) : i64
  (if (< (io.arg-count) 2)
    (begin
      (io.print-error
        "compiler-backend-raw-pointer-fixture: expected output path")
      1)
    (let
      [target-name : String
        (if (< (io.arg-count) 3)
          "linux-x86_64"
          (io.arg 2))]
      (match (compiler-backend-raw-pointer-fixture-for-name target-name)
        [(backend.ResultCompilerBackend.Ok asm)
          (begin
            (io.write-file (io.arg 1) (byte_buf.str-as-bytes (& asm)))
            0)]
        [(backend.ResultCompilerBackend.Err diag)
          (begin
            (io.print-error
              (diagnostic.compiler-diagnostic-render
                (diagnostic.compiler-diagnostic-box-shared-view diag)))
            1)]))))