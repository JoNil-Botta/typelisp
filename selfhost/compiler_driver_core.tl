;; compiler_driver_core.tl - Import-aware selfhost compiler driver helpers.

(import "compiler_backend.tl")

(import "compiler_diagnostic.tl")

(import "compiler_load.tl")

(import "compiler_optimize.tl")

(defenum ResultCompilerDriver
  (OkCompilerDriver String)
  (ErrCompilerDriver CompilerDiagnostic))

(define (compiler-driver-emit-file [input-path : String]) : ResultCompilerDriver
  (match (compiler-load-file input-path (sym-i64-empty))
    [(OkCompilerLoad decls _)
      (match (lower-compiler-program-with-path input-path (AstProgram decls))
        ;; The lowering provenance side table (#605) is forwarded through
        ;; optimization (which preserves function names) into backend emission so
        ;; backend diagnostics report the real source line/column.
        [(OkCompilerLower program spans)
          (match (compiler-backend-emit-program-with-spans
            (optimize-program program)
            spans)
            [(OkCompilerBackend asm) (OkCompilerDriver asm)]
            [(ErrCompilerBackend diag)
              (ErrCompilerDriver
                (compiler-diagnostic-with-path diag input-path))])]
        [(ErrCompilerLower diag) (ErrCompilerDriver diag)])]
    [(ErrCompilerLoad diag) (ErrCompilerDriver diag)]))

(define (compiler-driver-compile-file
  [input-path : String]
  [output-path : String]) : i64
  (match (compiler-driver-emit-file input-path)
    [(OkCompilerDriver asm)
      (begin
        (write-file output-path asm)
        0)]
    [(ErrCompilerDriver diag)
      (begin
        (print-error (compiler-diagnostic-render diag))
        1)]))