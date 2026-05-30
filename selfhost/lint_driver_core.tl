;; lint_driver_core.tl - Driver logic for the selfhost `typelisp lint` tool
;; (#1163): load a TypeLisp source, run the lint_core rules over its program, and
;; render each finding as `path:line:col: message`. Kept main-less so both the
;; CLI driver (`lint.tl`) and the runnable smoke (`lint_driver_smoke.tl`) can
;; import it. Warn-only by design (the file driver returns 0 even with findings);
;; CI enforcement is layered on top per #1164.
(import "compiler_load.tl")

(import "lint_core.tl")

;; Parsed lint CLI config: input path, stdlib roots, and whether `--check`
;; enforcing mode was requested (exit non-zero when findings are present).
(defenum SelfhostLintConfig
  (SelfhostLintConfig String CompilerLoadRootList bool))

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
  [stdlib-roots : CompilerLoadRootList]
  [enforcing : bool]) : ResultSelfhostLintConfig
  (if (>= idx count)
    (OkSelfhostLintConfig
      (SelfhostLintConfig input-path stdlib-roots enforcing))
    (let
      [current : String (arg idx)]
      (cond
        [(string-eq current "--check")
          (selfhost-lint-parse-options
            (+ idx 1)
            count
            input-path
            stdlib-roots
            true)]
        [(string-eq current "--stdlib-root")
          (if (>= (+ idx 1) count)
            (ErrSelfhostLintConfig
              "selfhost-lint: --stdlib-root requires a value")
            (selfhost-lint-parse-options
              (+ idx 2)
              count
              input-path
              (selfhost-lint-root-list-append stdlib-roots (arg (+ idx 1)))
              enforcing))]
        [(selfhost-lint-flag? current)
          (ErrSelfhostLintConfig
            (string-append "selfhost-lint: unknown flag " current))]
        [else
          (ErrSelfhostLintConfig
            (string-append "selfhost-lint: unexpected argument " current))]))))

(define (selfhost-lint-config [count : i64]) : ResultSelfhostLintConfig
  (if (< count 2)
    (ErrSelfhostLintConfig "selfhost-lint: expected input path")
    (let
      [input-path : String (arg 1)]
      (if (selfhost-lint-flag? input-path)
        (ErrSelfhostLintConfig
          "selfhost-lint: expected input path before flags")
        (selfhost-lint-parse-options
          2
          count
          input-path
          CompilerLoadRootNil
          false)))))

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

(define (selfhost-lint-space? [c : char]) : bool
  (or (= c #\space') (or (= c #\tab') (or (= c #\newline') (= c #\return')))))

(define (selfhost-lint-prefix-at?
  [source : String]
  [start : i64]
  [needle : String]) : bool
  (let
    [source-len : i64 (string-length source)]
    [needle-len : i64 (string-length needle)]
    (if (< start 0)
      false
      (if (> (+ start needle-len) source-len)
        false
        (let
          [ok : bool true]
          [idx : i64 0]
          (begin
            (while (and ok (< idx needle-len))
              (if (= (string-ref source (+ start idx)) (string-ref needle idx))
                (set! idx (+ idx 1))
                (set! ok false)))
            ok))))))

(define (selfhost-lint-cond-delim? [source : String] [idx : i64]) : bool
  (let
    [source-len : i64 (string-length source)]
    (if (>= idx source-len)
      true
      (let
        [c : char (string-ref source idx)]
        (or (selfhost-lint-space? c) (= c #)'))))))

(define (selfhost-lint-line-start-index [source : String] [target-line : i64]) : i64
  (let
    [source-len : i64 (string-length source)]
    [idx : i64 0]
    [line : i64 1]
    [start : i64 0]
    (begin
      (while (and (< idx source-len) (< line target-line))
        (if (= (string-ref source idx) #\newline')
          (begin
            (set! line (+ line 1))
            (set! start (+ idx 1))
            (set! idx (+ idx 1)))
          (set! idx (+ idx 1))))
      (if (= line target-line)
        start
        source-len))))

(define (selfhost-lint-cond-origin? [source : String] [span : AstSourceSpan]) : bool
  (let
    [line : i64 (struct-get span start-line)]
    [col : i64 (struct-get span start-col)]
    (if (or (<= line 0) (<= col 0))
      false
      (let
        [line-start : i64 (selfhost-lint-line-start-index source line)]
        [idx : i64 (+ line-start (- col 1))]
        (and
          (selfhost-lint-prefix-at? source idx "(cond")
          (selfhost-lint-cond-delim? source (+ idx 5)))))))

(define (selfhost-lint-filter-cond-origins
  [source : String]
  [items : LintFindingList]) : LintFindingList
  (match items
    [(LintFindingNil) LintFindingNil]
    [(LintFindingCons finding rest)
      (let
        [filtered-rest : LintFindingList
          (selfhost-lint-filter-cond-origins source rest)]
        (if (selfhost-lint-cond-origin? source (struct-get finding span))
          filtered-rest
          (LintFindingCons finding filtered-rest)))]))

(define (selfhost-lint-program-findings
  [source : String]
  [program : AstProgram]) : LintFindingList
  (match program
    [(AstProgram decls)
      (selfhost-lint-filter-cond-origins
        source
        (lint-program (AstProgram decls) (lint-default-ladder-threshold)))]))

;; Parse `source` (attributed to `path`) and run the lint rules over this source
;; unit only. Imports are linted when their own files are selected by the repo
;; lint gate, so a public driver does not duplicate every imported finding.
(define (selfhost-lint-source-with-roots
  [path : String]
  [source : String]
  [stdlib-roots : CompilerLoadRootList]) : LintFindingList
  (match (parse-ast-source-diagnostic path source)
    [(OkAstProgramDiagnostic program)
      (selfhost-lint-program-findings source program)]
    [(ErrAstProgramDiagnostic _) LintFindingNil]))

;; Lint a file on disk: print its findings + a summary; return 0 (warn-only), or
;; 1 when the file could not be loaded.
;; Exit code for the file driver after a successful lint: `--check` enforcing
;; mode exits 1 when any finding remains; warn-only mode (the default) and a
;; clean file both exit 0. Parse/load failures exit 1 independently of this.
(define (selfhost-lint-enforce-exit [enforcing : bool] [finding-count : i64]) : i64
  (if (and enforcing (> finding-count 0))
    1
    0))

(define (selfhost-lint-file
  [input-path : String]
  [stdlib-roots : CompilerLoadRootList]
  [enforcing : bool]) : i64
  (let
    [source : String (read-file input-path)]
    (match (parse-ast-source-diagnostic input-path source)
      [(OkAstProgramDiagnostic program)
        (let
          [findings : LintFindingList
            (selfhost-lint-program-findings source program)]
          (begin
            (selfhost-lint-print-findings input-path findings)
            (print-string
              (string-append
                "lint: "
                (string-append
                  (int->string (lint-finding-list-count findings))
                  " finding(s)\n")))
            (selfhost-lint-enforce-exit
              enforcing
              (lint-finding-list-count findings))))]
      [(ErrAstProgramDiagnostic diag)
        (begin
          (print-error (compiler-diagnostic-render diag))
          1)])))

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

;; The reported ladder finding has depth 5 and a real source line.
(define (selfhost-lint-driver-finding-ok? [findings : LintFindingList]) : bool
  (match findings
    [(LintFindingCons finding _)
      (let
        [fspan : AstSourceSpan (struct-get finding span)]
        (and
          (= (struct-get finding depth) 5)
          (> (struct-get fspan start-line) 0)))]
    [(LintFindingNil) false]))

(define (compiler-lint-driver-self-test) : i64
  (let
    [findings : LintFindingList
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-ladder-source)
        CompilerLoadRootNil)]
    (cond
      [(not (= (lint-finding-list-count findings) 1)) 4]
      [(not (selfhost-lint-driver-finding-ok? findings)) 5]
      ;; enforcing (`--check`) mode exits 1 when findings remain, 0 when clean
      [(not (= (selfhost-lint-enforce-exit true 1) 1)) 6]
      [(not (= (selfhost-lint-enforce-exit true 0) 0)) 7]
      ;; warn-only mode (default) exits 0 even with findings
      [(not (= (selfhost-lint-enforce-exit false 1) 0)) 8]
      [else 42])))