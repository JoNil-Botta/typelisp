;; compiler_driver_core.tl - Import-aware selfhost compiler driver helpers.

(import "compiler_backend.tl")

(import "compiler_load.tl")

(import "compiler_diagnostic.tl")

(import "compiler_optimize.tl")

(defenum ResultCompilerDriverEmit
  (OkCompilerDriverEmit String)
  (ErrCompilerDriverEmit CompilerDiagnostic))

(define (compiler-driver-emit-file [input-path : String]) : ResultCompilerDriverEmit
  (match (compiler-load-file-diagnostic input-path (sym-i64-empty))
    [(OkCompilerLoadDiagnostic decls _)
      (match (lower-compiler-program (AstProgram decls))
        [(OkCompilerLower program)
          (match (compiler-backend-emit-program (optimize-program program))
            [(OkCompilerBackend asm) (OkCompilerDriverEmit asm)]
            [(ErrCompilerBackend message)
              (ErrCompilerDriverEmit
                (compiler-diagnostic-at-start input-path message))])]
        [(ErrCompilerLower message)
          (ErrCompilerDriverEmit
            (compiler-diagnostic-at-start input-path message))])]
    [(ErrCompilerLoadDiagnostic diag) (ErrCompilerDriverEmit diag)]))

(define (compiler-driver-compile-file
  [input-path : String]
  [output-path : String]) : i64
  (match (compiler-driver-emit-file input-path)
    [(OkCompilerDriverEmit asm)
      (begin
        (write-file output-path asm)
        0)]
    [(ErrCompilerDriverEmit diag)
      (begin
        (print-error (compiler-diagnostic-render diag))
        1)]))