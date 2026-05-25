;; compiler_backend_runtime_fixture.tl - emit runtime-helper backend fixture assembly.
(import "compiler_backend.tl")

(define (compiler-backend-runtime-fixture-emit [target-name : String]) : ResultCompilerBackend
  (if (string-eq target-name "linux-x86_64")
    (compiler-backend-emit-program (compiler-backend-runtime-helper-program))
    (if (string-eq target-name "windows-x86_64")
      (compiler-backend-emit-program-for-target
        (compiler-backend-runtime-helper-program)
        (BackendTargetWindows))
      (if (string-eq target-name "windows-driver-primitives")
        (compiler-backend-emit-source-for-target
          (compiler-backend-windows-driver-runtime-source)
          (BackendTargetWindows))
        (ErrCompilerBackend
          (compiler-diagnostic-at-start
            ""
            "compiler-backend-runtime-fixture: unknown target"))))))

(define (main) : i64
  (if (< (arg-count) 2)
    (begin
      (print-error "compiler-backend-runtime-fixture: expected output path")
      1)
    (let ([target-name : String
      (if (< (arg-count) 3)
        "linux-x86_64"
        (arg 2))])
      (match (compiler-backend-runtime-fixture-emit target-name)
        [(OkCompilerBackend asm)
          (begin
            (write-file (arg 1) asm)
            0)]
        [(ErrCompilerBackend diag)
          (begin
            (print-error (compiler-diagnostic-render diag))
            1)]))))