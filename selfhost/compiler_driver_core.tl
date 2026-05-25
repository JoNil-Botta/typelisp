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
  (compiler-driver-emit-lowered-with-level
    input-path
    program
    spans
    target
    has-target
    (compiler-optimize-default-level)))

(define (compiler-driver-emit-lowered-with-level
  [input-path : String]
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [opt-level : i64]) : ResultCompilerDriver
  (let
    [optimized : CompilerIrProgram
      (optimize-program-with-level program opt-level)]
    (match (if has-target
      (compiler-backend-emit-program-with-spans-for-target
        optimized
        spans
        target)
      (compiler-backend-emit-program-with-spans optimized spans))
      [(OkCompilerBackend asm) (OkCompilerDriver asm)]
      [(ErrCompilerBackend diag)
        (ErrCompilerDriver (compiler-diagnostic-with-path diag input-path))])))

(define (compiler-driver-emit-file-with-target
  [input-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]) : ResultCompilerDriver
  (compiler-driver-emit-file-with-target-and-roots
    input-path
    target
    has-target
    CompilerLoadRootNil))

(define (compiler-driver-emit-file-with-target-and-roots
  [input-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : CompilerLoadRootList]) : ResultCompilerDriver
  (compiler-driver-emit-file-with-target-roots-and-level
    input-path
    target
    has-target
    stdlib-roots
    (compiler-optimize-default-level)))

(define (compiler-driver-emit-file-with-target-roots-and-level
  [input-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : CompilerLoadRootList]
  [opt-level : i64]) : ResultCompilerDriver
  (match (compiler-load-file-with-paths-and-roots
    input-path
    (sym-i64-empty)
    stdlib-roots)
    [(OkCompilerLoadWithPaths decls paths _ _)
      (match (lower-compiler-program-with-decl-paths
        input-path
        (AstProgram decls)
        paths)
        ;; The lowering provenance side table (#605) is forwarded through
        ;; optimization (which preserves function names) into backend emission so
        ;; backend diagnostics report the real source line/column.
        [(OkCompilerLower program spans)
          (compiler-driver-emit-lowered-with-level
            input-path
            program
            spans
            target
            has-target
            opt-level)]
        [(ErrCompilerLower diag) (ErrCompilerDriver diag)])]
    [(ErrCompilerLoadWithPaths diag) (ErrCompilerDriver diag)]))

(define (compiler-driver-emit-file [input-path : String]) : ResultCompilerDriver
  (compiler-driver-emit-file-with-target input-path (BackendTargetLinux) false))

(define (compiler-driver-emit-file-with-roots
  [input-path : String]
  [stdlib-roots : CompilerLoadRootList]) : ResultCompilerDriver
  (compiler-driver-emit-file-with-target-and-roots
    input-path
    (BackendTargetLinux)
    false
    stdlib-roots))

(define (compiler-driver-emit-file-with-roots-and-level
  [input-path : String]
  [stdlib-roots : CompilerLoadRootList]
  [opt-level : i64]) : ResultCompilerDriver
  (compiler-driver-emit-file-with-target-roots-and-level
    input-path
    (BackendTargetLinux)
    false
    stdlib-roots
    opt-level))

(define (compiler-driver-emit-file-for-target
  [input-path : String]
  [target : CompilerBackendTarget]) : ResultCompilerDriver
  (compiler-driver-emit-file-with-target input-path target true))

(define (compiler-driver-emit-file-for-target-with-roots
  [input-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : CompilerLoadRootList]) : ResultCompilerDriver
  (compiler-driver-emit-file-with-target-and-roots
    input-path
    target
    true
    stdlib-roots))

(define (compiler-driver-emit-file-for-target-with-roots-and-level
  [input-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : CompilerLoadRootList]
  [opt-level : i64]) : ResultCompilerDriver
  (compiler-driver-emit-file-with-target-roots-and-level
    input-path
    target
    true
    stdlib-roots
    opt-level))

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

(define (compiler-driver-compile-file-with-roots
  [input-path : String]
  [output-path : String]
  [stdlib-roots : CompilerLoadRootList]) : i64
  (compiler-driver-write-result
    (compiler-driver-emit-file-with-roots input-path stdlib-roots)
    output-path))

(define (compiler-driver-compile-file-with-roots-and-level
  [input-path : String]
  [output-path : String]
  [stdlib-roots : CompilerLoadRootList]
  [opt-level : i64]) : i64
  (compiler-driver-write-result
    (compiler-driver-emit-file-with-roots-and-level
      input-path
      stdlib-roots
      opt-level)
    output-path))

(define (compiler-driver-compile-file-for-target
  [input-path : String]
  [output-path : String]
  [target : CompilerBackendTarget]) : i64
  (compiler-driver-write-result
    (compiler-driver-emit-file-for-target input-path target)
    output-path))

(define (compiler-driver-compile-file-for-target-with-roots
  [input-path : String]
  [output-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : CompilerLoadRootList]) : i64
  (compiler-driver-write-result
    (compiler-driver-emit-file-for-target-with-roots
      input-path
      target
      stdlib-roots)
    output-path))

(define (compiler-driver-compile-file-for-target-with-roots-and-level
  [input-path : String]
  [output-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : CompilerLoadRootList]
  [opt-level : i64]) : i64
  (compiler-driver-write-result
    (compiler-driver-emit-file-for-target-with-roots-and-level
      input-path
      target
      stdlib-roots
      opt-level)
    output-path))