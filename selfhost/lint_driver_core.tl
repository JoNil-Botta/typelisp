;; lint_driver_core.tl - Driver logic for the selfhost `typelisp lint` tool
;; (#1163): load a TypeLisp source, run the lint_core rules over its program, and
;; render each finding as `path:line:col: message`. Kept main-less so both the
;; CLI driver (`lint.tl`) and the runnable smoke (`lint_driver_smoke.tl`) can
;; import it. Warn-only by design (the file driver returns 0 even with findings);
;; CI enforcement is layered on top per #1164.
(import "compiler_load.tl")

(import "lint_core.tl")

(defenum SelfhostLintConfig
  (SelfhostLintConfig String CompilerLoadRootList))

(defenum ResultSelfhostLintConfig
  (OkSelfhostLintConfig SelfhostLintConfig)
  (ErrSelfhostLintConfig String))

(define (selfhost-lint-flag? [value : String]) : bool
  (and (> (string-length value) 0) (= (string-ref value 0) #-')))

(define (selfhost-lint-root-list-append
  [roots : CompilerLoadRootList]
  [root : String]) : CompilerLoadRootList
  (match roots
    [(CompilerLoadRootNil) (CompilerLoadRootCons root CompilerLoadRootNil)]
    [(CompilerLoadRootCons head rest)
      (CompilerLoadRootCons head (selfhost-lint-root-list-append rest root))]))

(define (selfhost-lint-parse-options
  [idx : i64]
  [count : i64]
  [input-path : String]
  [stdlib-roots : CompilerLoadRootList]) : ResultSelfhostLintConfig
  (if (>= idx count)
    (OkSelfhostLintConfig (SelfhostLintConfig input-path stdlib-roots))
    (let
      [current : String (arg idx)]
      (if (string-eq current "--stdlib-root")
        (if (>= (+ idx 1) count)
          (ErrSelfhostLintConfig
            "selfhost-lint: --stdlib-root requires a value")
          (selfhost-lint-parse-options
            (+ idx 2)
            count
            input-path
            (selfhost-lint-root-list-append stdlib-roots (arg (+ idx 1)))))
        (if (selfhost-lint-flag? current)
          (ErrSelfhostLintConfig
            (string-append "selfhost-lint: unknown flag " current))
          (ErrSelfhostLintConfig
            (string-append "selfhost-lint: unexpected argument " current)))))))

(define (selfhost-lint-config [count : i64]) : ResultSelfhostLintConfig
  (if (< count 2)
    (ErrSelfhostLintConfig "selfhost-lint: expected input path")
    (let
      [input-path : String (arg 1)]
      (if (selfhost-lint-flag? input-path)
        (ErrSelfhostLintConfig
          "selfhost-lint: expected input path before flags")
        (selfhost-lint-parse-options 2 count input-path CompilerLoadRootNil)))))

;; Render one finding as `path:line:col: message` (line/col from the flagged
;; node's source span; 0:0 only for synthesized nodes that carry no location).
(define (selfhost-lint-render-finding [path : String] [finding : LintFinding]) : String
  (let
    [fspan : AstSourceSpan (struct-get finding span)]
    (string-append
      path
      (string-append
        ":"
        (string-append
          (int->string (struct-get fspan start-line))
          (string-append
            ":"
            (string-append
              (int->string (struct-get fspan start-col))
              (string-append ": " (struct-get finding message)))))))))

;; Print every finding (one per line) to stdout; returns the number printed.
(define (selfhost-lint-print-findings [path : String] [items : LintFindingList]) : i64
  (match items
    [(LintFindingNil) 0]
    [(LintFindingCons finding rest)
      (begin
        (print-string
          (string-append (selfhost-lint-render-finding path finding) "\n"))
        (+ 1 (selfhost-lint-print-findings path rest)))]))

;; Parse `source` (attributed to `path`) and run the lint rules over its program.
(define (selfhost-lint-source-with-roots
  [path : String]
  [source : String]
  [stdlib-roots : CompilerLoadRootList]) : LintFindingList
  (match (compiler-load-source-with-paths-and-roots
    path
    source
    (sym-i64-empty)
    stdlib-roots)
    [(OkCompilerLoadWithPaths decls _ _ _)
      (lint-program (AstProgram decls) (lint-default-ladder-threshold))]
    [(ErrCompilerLoadWithPaths _) LintFindingNil]))

;; Lint a file on disk: print its findings + a summary; return 0 (warn-only), or
;; 1 when the file could not be loaded.
(define (selfhost-lint-file
  [input-path : String]
  [stdlib-roots : CompilerLoadRootList]) : i64
  (match (compiler-load-file-with-paths-and-roots
    input-path
    (sym-i64-empty)
    stdlib-roots)
    [(OkCompilerLoadWithPaths decls _ _ _)
      (let
        [findings : LintFindingList
          (lint-program (AstProgram decls) (lint-default-ladder-threshold))]
        (begin
          (selfhost-lint-print-findings input-path findings)
          (print-string
            (string-append
              "lint: "
              (string-append
                (int->string (lint-finding-list-count findings))
                " finding(s)\n")))
          0))]
    [(ErrCompilerLoadWithPaths diag)
      (begin
        (print-error (compiler-diagnostic-render diag))
        1)]))

;; ---- self-test (driven by lint_driver_smoke.tl) ----
;; A five-deep value-dispatch if-ladder (length 5 >= the default threshold of 3),
;; so linting it yields exactly one finding at depth 5.
(define (selfhost-lint-ladder-source) : String
  "(define (classify [x : i64]) : i64
  (if (= x 0)
    10
    (if (= x 1)
      20
      (if (= x 2)
        30
        (if (= x 3)
          40
          (if (= x 4)
            50
            0))))))")

(define (compiler-lint-driver-self-test) : i64
  (let
    [findings : LintFindingList
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-ladder-source)
        CompilerLoadRootNil)]
    (if (= (lint-finding-list-count findings) 1)
      (match findings
        [(LintFindingCons finding _)
          (let
            [fspan : AstSourceSpan (struct-get finding span)]
            (if (= (struct-get finding depth) 5)
              (if (> (struct-get fspan start-line) 0)
                42
                1)
              2))]
        [(LintFindingNil) 3])
      4)))