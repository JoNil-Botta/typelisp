;; test.tl - Selfhost inline TypeLisp test discovery/typecheck runner (#940).
;;
;; First slice: discovers `(test name body...)` declarations from an entry module
;; and its imports, typechecks the loaded program, and reports the number of
;; inline tests found. Runtime execution of test bodies is a follow-up.
(import "compiler_check_core.tl")

(defenum ResultInlineTestRun
  (OkInlineTestRun i64)
  (ErrInlineTestRun CompilerDiagnostic))

(defenum InlineTestCliConfig
  (InlineTestCliConfig String CompilerLoadRootList))

(defenum ResultInlineTestCliConfig
  (OkInlineTestCliConfig InlineTestCliConfig)
  (ErrInlineTestCliConfig String))

(define (inline-test-decl-count [decls : AstDeclList]) : i64
  (match decls
    [(AstDeclNil) 0]
    [(AstDeclCons decl rest)
      (match decl
        [(AstDeclTest _ _) (+ 1 (inline-test-decl-count rest))]
        [_ (inline-test-decl-count rest)])]))

(define (inline-test-run-loaded
  [path : String]
  [decls : AstDeclList]
  [paths : AstDeclPathList]) : ResultInlineTestRun
  (match (typecheck-compiler-program-with-paths (AstProgram decls) paths)
    [(OkCompilerTypecheck _) (OkInlineTestRun (inline-test-decl-count decls))]
    [(ErrCompilerTypecheck diag)
      (ErrInlineTestRun
        (compiler-check-diagnostic-with-fallback-path diag path))]))

(define (inline-test-run-source-with-roots
  [path : String]
  [source : String]
  [stdlib-roots : CompilerLoadRootList]) : ResultInlineTestRun
  (match (compiler-load-source-with-paths-and-roots
    path
    source
    (sym-i64-empty)
    stdlib-roots)
    [(OkCompilerLoadWithPaths decls paths _)
      (inline-test-run-loaded path decls paths)]
    [(ErrCompilerLoadWithPaths diag) (ErrInlineTestRun diag)]))

(define (inline-test-run-source [path : String] [source : String]) : ResultInlineTestRun
  (inline-test-run-source-with-roots path source CompilerLoadRootNil))

(define (inline-test-run-file-with-roots
  [path : String]
  [stdlib-roots : CompilerLoadRootList]) : ResultInlineTestRun
  (match (compiler-load-file-with-paths-and-roots
    path
    (sym-i64-empty)
    stdlib-roots)
    [(OkCompilerLoadWithPaths decls paths _)
      (inline-test-run-loaded path decls paths)]
    [(ErrCompilerLoadWithPaths diag) (ErrInlineTestRun diag)]))

(define (inline-test-run-file [path : String]) : ResultInlineTestRun
  (inline-test-run-file-with-roots path CompilerLoadRootNil))

(define (inline-test-report-success [count : i64]) : String
  (string-append
    "TypeLisp inline tests typechecked: "
    (string-append (int->string count) " test(s)")))

(define (inline-test-report-typecheck-failure [diag : CompilerDiagnostic]) : String
  (string-append
    "TypeLisp inline tests failed during typecheck\n"
    (compiler-diagnostic-render diag)))

(define (inline-test-root-list-append
  [roots : CompilerLoadRootList]
  [root : String]) : CompilerLoadRootList
  (match roots
    [(CompilerLoadRootNil) (CompilerLoadRootCons root CompilerLoadRootNil)]
    [(CompilerLoadRootCons head rest)
      (CompilerLoadRootCons head (inline-test-root-list-append rest root))]))

(define (inline-test-flag? [value : String]) : bool
  (and (> (string-length value) 0) (= (string-ref value 0) #-')))

(define (inline-test-parse-options
  [idx : i64]
  [count : i64]
  [path : String]
  [roots : CompilerLoadRootList]) : ResultInlineTestCliConfig
  (if (>= idx count)
    (OkInlineTestCliConfig (InlineTestCliConfig path roots))
    (let ([current : String (arg idx)])
      (if (string-eq current "--stdlib-root")
        (if (>= (+ idx 1) count)
          (ErrInlineTestCliConfig "test: --stdlib-root requires a value")
          (inline-test-parse-options
            (+ idx 2)
            count
            path
            (inline-test-root-list-append roots (arg (+ idx 1)))))
        (if (inline-test-flag? current)
          (ErrInlineTestCliConfig (string-append "test: unknown flag " current))
          (ErrInlineTestCliConfig "test: accepts only one source file"))))))

(define (inline-test-cli-config [count : i64]) : ResultInlineTestCliConfig
  (if (< count 2)
    (ErrInlineTestCliConfig "test: expected source path")
    (let ([path : String (arg 1)])
      (if (inline-test-flag? path)
        (ErrInlineTestCliConfig "test: expected source path before flags")
        (inline-test-parse-options 2 count path CompilerLoadRootNil)))))

(define (inline-test-cli-run [config : InlineTestCliConfig]) : i64
  (match config
    [(InlineTestCliConfig path roots)
      (match (inline-test-run-file-with-roots path roots)
        [(OkInlineTestRun count)
          (begin
            (print-string
              (string-append (inline-test-report-success count) "\n"))
            0)]
        [(ErrInlineTestRun diag)
          (begin
            (print-error (inline-test-report-typecheck-failure diag))
            1)])]))

(define (inline-test-smoke-source) : String
  "(define answer : i64 42)
(test returns-unit unit)
(test returns-status answer)")

(define (inline-test-smoke-bad-source) : String
  "(test bad true)")

(define (inline-test-self-test) : i64
  (match (inline-test-run-source
    "selfhost/inline_test_ok.tl"
    (inline-test-smoke-source))
    [(OkInlineTestRun count)
      (if (= count 2)
        (match (inline-test-run-source
          "selfhost/inline_test_bad.tl"
          (inline-test-smoke-bad-source))
          [(ErrInlineTestRun diag)
            (if (string-eq
              (compiler-diagnostic-message diag)
              "typecheck: test body must return unit or i64")
              42
              (begin
                (panic "inline-test: bad diagnostic mismatch")
                0))]
          [(OkInlineTestRun _)
            (begin
              (panic "inline-test: bad source passed")
              0)])
        (begin
          (panic "inline-test: count mismatch")
          0))]
    [(ErrInlineTestRun diag)
      (begin
        (panic (compiler-diagnostic-message diag))
        0)]))

(define (main) : i64
  (match (inline-test-cli-config (arg-count))
    [(OkInlineTestCliConfig config) (inline-test-cli-run config)]
    [(ErrInlineTestCliConfig message)
      (begin
        (print-error message)
        1)]))