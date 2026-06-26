;; compiler_backend_raw_pointer_fixture.tl - emit the raw-pointer backend
;; witness program's assembly for a target so the integration suite can
;; assemble, link, and run it.
(import stdlib.io)
(import stdlib.string)
(import "../compiler_backend_tests.tl")

(define (compiler-backend-raw-pointer-fixture-for-name [target-name : String]) : ResultCompilerBackend
  (if (string.string-eq target-name "linux-x86_64")
    (compiler-backend-raw-pointer-fixture-emit (BackendTargetLinux))
    (if (string.string-eq target-name "windows-x86_64")
      (compiler-backend-raw-pointer-fixture-emit (BackendTargetWindows))
      (ErrCompilerBackend
        (box
          (compiler-diagnostic-at-start
            ""
            "compiler-backend-raw-pointer-fixture: unknown target"))))))

(define (main) : i64
  (if (< (arg-count) 2)
    (begin
      (io.print-error
        "compiler-backend-raw-pointer-fixture: expected output path")
      1)
    (let
      [target-name : String
        (if (< (arg-count) 3)
          "linux-x86_64"
          (io.arg 2))]
      (match (compiler-backend-raw-pointer-fixture-for-name target-name)
        [(OkCompilerBackend asm)
          (begin
            (io.write-file (io.arg 1) asm)
            0)]
        [(ErrCompilerBackend diag)
          (begin
            (io.print-error (compiler-diagnostic-render (box-get diag)))
            1)]))))