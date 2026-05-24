;; compiler_driver_core.tl - Import-aware selfhost compiler driver helpers.

(import "compiler_backend.tl")

(import "compiler_diagnostic.tl")

(import "compiler_load.tl")

(import "compiler_optimize.tl")

(defenum ResultCompilerDriver
  (OkCompilerDriver String)
  (ErrCompilerDriver CompilerDiagnostic))

(define (compiler-driver-emit-lowered
  [input-path : String]
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [target : CompilerBackendTarget]
  [has-target : bool]) : ResultCompilerDriver
  (match (if has-target
    (compiler-backend-emit-program-with-spans-for-target
      (optimize-program program)
      spans
      target)
    (compiler-backend-emit-program-with-spans (optimize-program program) spans))
    [(OkCompilerBackend asm) (OkCompilerDriver asm)]
    [(ErrCompilerBackend diag)
      (ErrCompilerDriver (compiler-diagnostic-with-path diag input-path))]))

(define (compiler-driver-emit-file-with-target
  [input-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]) : ResultCompilerDriver
  (match (compiler-load-file input-path (sym-i64-empty))
    [(OkCompilerLoad decls _)
      (match (lower-compiler-program-with-path input-path (AstProgram decls))
        ;; The lowering provenance side table (#605) is forwarded through
        ;; optimization (which preserves function names) into backend emission so
        ;; backend diagnostics report the real source line/column.
        [(OkCompilerLower program spans)
          (compiler-driver-emit-lowered
            input-path
            program
            spans
            target
            has-target)]
        [(ErrCompilerLower diag) (ErrCompilerDriver diag)])]
    [(ErrCompilerLoad diag) (ErrCompilerDriver diag)]))

(define (compiler-driver-emit-file [input-path : String]) : ResultCompilerDriver
  (compiler-driver-emit-file-with-target input-path (BackendTargetLinux) false))

(define (compiler-driver-emit-file-for-target
  [input-path : String]
  [target : CompilerBackendTarget]) : ResultCompilerDriver
  (compiler-driver-emit-file-with-target input-path target true))

(define (compiler-driver-write-result
  [result : ResultCompilerDriver]
  [output-path : String]) : i64
  (match result
    [(OkCompilerDriver asm)
      (begin
        (write-file output-path asm)
        0)]
    [(ErrCompilerDriver diag)
      (begin
        (print-error (compiler-diagnostic-render diag))
        1)]))

(define (compiler-driver-compile-file
  [input-path : String]
  [output-path : String]) : i64
  (compiler-driver-write-result
    (compiler-driver-emit-file input-path)
    output-path))

(define (compiler-driver-compile-file-for-target
  [input-path : String]
  [output-path : String]
  [target : CompilerBackendTarget]) : i64
  (compiler-driver-write-result
    (compiler-driver-emit-file-for-target input-path target)
    output-path))