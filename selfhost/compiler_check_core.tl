;; compiler_check_core.tl - Shared selfhost check/typecheck helpers (#723).

(import "compiler_load.tl")

(import "compiler_typecheck.tl")

(defenum ResultCompilerCheck
  (OkCompilerCheck CompilerTypecheckSummary)
  (ErrCompilerCheck CompilerDiagnostic))

(define (compiler-check-program [path : String] [decls : AstDeclList]) : ResultCompilerCheck
  (match (typecheck-compiler-program (AstProgram decls))
    [(OkCompilerTypecheck summary) (OkCompilerCheck summary)]
    [(ErrCompilerTypecheck diag)
      (ErrCompilerCheck (compiler-diagnostic-with-path diag path))]))

(define (compiler-check-file [path : String]) : ResultCompilerCheck
  (match (compiler-load-file path (sym-i64-empty))
    [(OkCompilerLoad decls _) (compiler-check-program path decls)]
    [(ErrCompilerLoad diag) (ErrCompilerCheck diag)]))

(define (compiler-check-source [path : String] [source : String]) : ResultCompilerCheck
  (match (compiler-load-source path source (sym-i64-empty))
    [(OkCompilerLoad decls _) (compiler-check-program path decls)]
    [(ErrCompilerLoad diag) (ErrCompilerCheck diag)]))

(define (compiler-check-virtual-import-source) : String
  "(import \"compiler_ast_types.tl\")
(import \"compiler_ast_types.tl\")
(define selected : AstType (AstTyI64))
(define (main) : i64
  (match selected [(AstTyI64) 42] [_ 0]))")

(define (compiler-check-virtual-import-ok?) : bool
  (match (compiler-check-source
    "selfhost/virtual_entry.tl"
    (compiler-check-virtual-import-source))
    [(OkCompilerCheck summary) (> (compiler-typecheck-summary-score summary) 0)]
    [(ErrCompilerCheck _) false]))

(define (compiler-check-virtual-error-ok?) : bool
  (match (compiler-check-source
    "docs/examples/bad_type.tl"
    "(define (main) : i64 true)")
    [(OkCompilerCheck _) false]
    [(ErrCompilerCheck diag)
      (if (string-eq
        (compiler-diagnostic-path diag)
        "docs/examples/bad_type.tl")
        (if (= (compiler-diagnostic-line diag) 1)
          (string-eq
            (compiler-diagnostic-message diag)
            "typecheck: return type mismatch")
          false)
        false)]))

(define (compiler-check-seen-root-ok?) : bool
  (match (compiler-load-source
    "selfhost/already_loaded.tl"
    "(define answer : i64 1)"
    (sym-i64-bind (sym-i64-empty) "selfhost/already_loaded.tl" 1))
    [(OkCompilerLoad decls _)
      (match decls
        [(AstDeclNil) true]
        [_ false])]
    [(ErrCompilerLoad _) false]))

(define (compiler-check-self-test) : i64
  (if (compiler-check-virtual-import-ok?)
    (if (compiler-check-virtual-error-ok?)
      (if (compiler-check-seen-root-ok?)
        42
        (begin
          (panic "compiler-check: seen root smoke mismatch")
          0))
      (begin
        (panic "compiler-check: virtual diagnostic smoke mismatch")
        0))
    (begin
      (panic "compiler-check: virtual import smoke mismatch")
      0)))