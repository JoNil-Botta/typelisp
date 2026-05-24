;; compiler_driver_core.tl - Import-aware selfhost compiler driver helpers.

(import "compiler_backend.tl")

(import "compiler_load.tl")

(import "compiler_optimize.tl")

(define (compiler-driver-emit-file [input-path : String]) : ResultCompilerBackend
  (match (compiler-load-file input-path (sym-i64-empty))
    [(OkCompilerLoad decls _)
      (match (lower-compiler-program (AstProgram decls))
        [(OkCompilerLower program)
          (compiler-backend-emit-program (optimize-program program))]
        [(ErrCompilerLower message) (ErrCompilerBackend message)])]
    [(ErrCompilerLoad message) (ErrCompilerBackend message)]))

(define (compiler-driver-compile-file
  [input-path : String]
  [output-path : String]) : i64
  (match (compiler-driver-emit-file input-path)
    [(OkCompilerBackend asm)
      (begin
        (write-file output-path asm)
        0)]
    [(ErrCompilerBackend message)
      (begin
        (print-error message)
        1)]))