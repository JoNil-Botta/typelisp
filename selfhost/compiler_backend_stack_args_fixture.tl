;; compiler_backend_stack_args_fixture.tl - emit the #750 stack-passed call

;; argument witness program's assembly for a target so the integration suite can

;; assemble, link, and RUN it, proving each spilled argument arrives correctly.

(import "compiler_backend.tl")

(define (compiler-backend-stack-args-fixture-for-name [target-name : String]) : ResultCompilerBackend
  (if (string-eq target-name "linux-x86_64")
    (compiler-backend-stack-args-fixture-emit (BackendTargetLinux))
    (if (string-eq target-name "windows-x86_64")
      (compiler-backend-stack-args-fixture-emit (BackendTargetWindows))
      (ErrCompilerBackend
        (compiler-diagnostic-at-start
          ""
          "compiler-backend-stack-args-fixture: unknown target")))))

(define (main) : i64
  (if (< (arg-count) 2)
    (begin
      (print-error "compiler-backend-stack-args-fixture: expected output path")
      1)
    (let ([target-name
        :
        String
        (if (< (arg-count) 3)
          "linux-x86_64"
          (arg 2))])
      (match (compiler-backend-stack-args-fixture-for-name target-name)
        [(OkCompilerBackend asm)
          (begin
            (write-file (arg 1) asm)
            0)]
        [(ErrCompilerBackend diag)
          (begin
            (print-error (compiler-diagnostic-render diag))
            1)]))))