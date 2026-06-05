;; compiler_check_core.tl - Shared selfhost check/typecheck helpers (#723).
(import "../stdlib/io.tl")

(cfg compile-profile (import "../stdlib/profile.tl"))

(import "compiler_load.tl")

(import "compiler_typecheck.tl")

(defenum ResultCompilerCheck
  (OkCompilerCheck CompilerTypecheckSummary)
  (ErrCompilerCheck CompilerDiagnostic))

(cfg
  compile-profile
  (define compiler-check-profile-start-ms : i64
    0))

(cfg
  compile-profile
  (define (compiler-check-profile-start) : unit
    (set! compiler-check-profile-start-ms (profile-now-ms))))

(cfg
  compile-profile
  (define (compiler-check-profile-finish [phase : String]) : unit
    (print-error
      (string-append
        "compile-profile|check."
        (string-append
          phase
          (string-append
            "|"
            (string-append
              (int->string (- (profile-now-ms) compiler-check-profile-start-ms))
              "|0|0|0\n")))))))

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
  (begin
    (cfg compile-profile (compiler-check-profile-start))
    (match (typecheck-compiler-program-with-paths (ast-program decls) paths)
      [(OkCompilerTypecheck summary)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "typecheck"))
          (OkCompilerCheck summary))]
      [(ErrCompilerTypecheck diag)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "typecheck"))
          (ErrCompilerCheck
            (compiler-check-diagnostic-with-fallback-path diag path)))])))

(define (compiler-check-program [path : String] [decls : AstDeclList]) : ResultCompilerCheck
  (compiler-check-program-with-paths path decls AstDeclPathNil))

(define (compiler-check-file [path : String]) : ResultCompilerCheck
  (begin
    (cfg compile-profile (compiler-check-profile-start))
    (match (compiler-load-file-with-paths path (sym-i64-empty))
      [(OkCompilerLoadWithPaths decls paths _ _)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "load"))
          (compiler-check-program-with-paths path decls paths))]
      [(ErrCompilerLoadWithPaths diag)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "load"))
          (ErrCompilerCheck diag))])))

(define (compiler-check-file-with-roots
  [path : String]
  [stdlib-roots : CompilerLoadRootList]) : ResultCompilerCheck
  (begin
    (cfg compile-profile (compiler-check-profile-start))
    (match (compiler-load-file-with-paths-and-roots
      path
      (sym-i64-empty)
      stdlib-roots)
      [(OkCompilerLoadWithPaths decls paths _ _)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "load"))
          (compiler-check-program-with-paths path decls paths))]
      [(ErrCompilerLoadWithPaths diag)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "load"))
          (ErrCompilerCheck diag))])))

(define (compiler-check-source [path : String] [source : String]) : ResultCompilerCheck
  (begin
    (cfg compile-profile (compiler-check-profile-start))
    (match (compiler-load-source-with-paths path source (sym-i64-empty))
      [(OkCompilerLoadWithPaths decls paths _ _)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "load"))
          (compiler-check-program-with-paths path decls paths))]
      [(ErrCompilerLoadWithPaths diag)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "load"))
          (ErrCompilerCheck diag))])))

(define (compiler-check-source-with-roots
  [path : String]
  [source : String]
  [stdlib-roots : CompilerLoadRootList]) : ResultCompilerCheck
  (begin
    (cfg compile-profile (compiler-check-profile-start))
    (match (compiler-load-source-with-paths-and-roots
      path
      source
      (sym-i64-empty)
      stdlib-roots)
      [(OkCompilerLoadWithPaths decls paths _ _)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "load"))
          (compiler-check-program-with-paths path decls paths))]
      [(ErrCompilerLoadWithPaths diag)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "load"))
          (ErrCompilerCheck diag))])))

(define (compiler-check-virtual-import-source) : String
  "(import \"compiler_ast_types.tl\")
(import \"compiler_ast_types.tl\")
(define selected : AstType (AstTyI64))
(define (main) : i64
  (match selected [(AstTyI64) 42] [_ 0]))")

(define (compiler-check-export-source) : String
  "(export
  (value answer)
  (type Pair)
  (constructor Pair)
  (field Pair left)
  (variant Present))
(defstruct Pair (left i64))
(defenum Maybe (Present i64))
(define answer : i64 42)
(define (main) : i64 answer)")

(define (compiler-check-virtual-import-ok?) : bool
  (match (compiler-check-source
    "selfhost/virtual_entry.tl"
    (compiler-check-virtual-import-source))
    [(OkCompilerCheck summary) (> (compiler-typecheck-summary-score summary) 0)]
    [(ErrCompilerCheck _) false]))

(define (compiler-check-export-ok?) : bool
  (match (compiler-check-source
    "selfhost/export_entry.tl"
    (compiler-check-export-source))
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
  (begin
    (unless
      (= (compiler-load-self-test) 42)
      (return
        (begin
          (panic "compiler-check: loader smoke mismatch")
          0)))
    (unless
      (compiler-check-virtual-import-ok?)
      (return
        (begin
          (panic "compiler-check: virtual import smoke mismatch")
          0)))
    (unless
      (compiler-check-export-ok?)
      (return
        (begin
          (panic "compiler-check: export smoke mismatch")
          0)))
    (unless
      (compiler-check-virtual-error-ok?)
      (return
        (begin
          (panic "compiler-check: virtual diagnostic smoke mismatch")
          0)))
    (unless
      (compiler-check-seen-root-ok?)
      (return
        (begin
          (panic "compiler-check: seen root smoke mismatch")
          0)))
    42))