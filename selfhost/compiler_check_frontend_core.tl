;; compiler_check_frontend_core.tl - Lightweight check helpers for parse+typecheck.
(import "compiler_load.tl")

(import "compiler_typecheck_core.tl")

(defenum ResultCompilerCheck
  (OkCompilerCheck CompilerTypecheckSummary)
  (ErrCompilerCheck CompilerDiagnostic))

(define (compiler-check-diagnostic-with-fallback-path
  [diag : CompilerDiagnostic]
  [path : String]) : CompilerDiagnostic
  (if (string-eq (compiler-diagnostic-path diag) "")
    (compiler-diagnostic-with-path diag path)
    diag))

(define (compiler-check-program-with-paths
  [path : String]
  [decls : AstDeclList]
  [paths : AstDeclPathList]) : ResultCompilerCheck
  (match (typecheck-compiler-specialized-program-with-paths
    (AstProgram decls)
    paths)
    [(OkCompilerTypecheck summary) (OkCompilerCheck summary)]
    [(ErrCompilerTypecheck diag)
      (ErrCompilerCheck
        (compiler-check-diagnostic-with-fallback-path diag path))]))

(define (compiler-check-file [path : String]) : ResultCompilerCheck
  (match (compiler-load-file-with-paths path (sym-i64-empty))
    [(OkCompilerLoadWithPaths decls paths _ _)
      (compiler-check-program-with-paths path decls paths)]
    [(ErrCompilerLoadWithPaths diag) (ErrCompilerCheck diag)]))

(define (compiler-check-file-with-roots
  [path : String]
  [stdlib-roots : CompilerLoadRootList]) : ResultCompilerCheck
  (match (compiler-load-file-with-paths-and-roots
    path
    (sym-i64-empty)
    stdlib-roots)
    [(OkCompilerLoadWithPaths decls paths _ _)
      (compiler-check-program-with-paths path decls paths)]
    [(ErrCompilerLoadWithPaths diag) (ErrCompilerCheck diag)]))