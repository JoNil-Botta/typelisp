;; compiler_backend_runtime_fixture.tl - emit runtime-helper backend fixture assembly.

(import "compiler_backend.tl")

(define (main) : i64
  (if (< (arg-count) 2)
    (begin
      (print-error "compiler-backend-runtime-fixture: expected output path")
      1)
    (match (compiler-backend-emit-program
      (compiler-backend-runtime-helper-program))
      [(OkCompilerBackend asm)
        (begin
          (write-file (arg 1) asm)
          0)]
      [(ErrCompilerBackend diag)
        (begin
          (print-error (compiler-diagnostic-render diag))
          1)])))