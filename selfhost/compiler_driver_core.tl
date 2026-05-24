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
      (match (lower-compiler-program (AstProgram decls))
        [(OkCompilerLower program)
          (match (compiler-backend-emit-program (optimize-program program))
            [(OkCompilerBackend asm) (OkCompilerDriver asm)]
            [(ErrCompilerBackend message)
              (ErrCompilerDriver
                (compiler-diagnostic-at-start input-path message))])]
        [(ErrCompilerLower message)
          (ErrCompilerDriver (compiler-diagnostic-at-start input-path message))])]
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