;; lint_driver_core.tl - Driver logic for the selfhost `typelisp lint` tool
;; (#1163): load a TypeLisp source, run the lint_core rules over its program, and
;; render each finding as `path:line:col: message`. Kept main-less so both the
;; CLI driver (`lint.tl`) and the runnable smoke (`lint_driver_smoke.tl`) can
;; import it. Warn-only by design (the file driver returns 0 even with findings);
;; CI enforcement is layered on top per #1164.
(import "../stdlib/io.tl")

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
    [(CompilerLoadRootNil)
      (CompilerLoadRootCons root (box CompilerLoadRootNil))]
    [(CompilerLoadRootCons head rest)
      (CompilerLoadRootCons
        head
        (box (selfhost-lint-root-list-append (box-get rest) root)))]))

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

;; Parse the `lint` config from arguments starting at `start` (the index of the
;; input path); options follow at `start+1`. `count` is `(arg-count)`.
(define (selfhost-lint-config-from [start : i64] [count : i64]) : ResultSelfhostLintConfig
  (if (< count (+ start 1))
    (ErrSelfhostLintConfig "selfhost-lint: expected input path")
    (let
      [input-path : String (arg start)]
      (if (selfhost-lint-flag? input-path)
        (ErrSelfhostLintConfig
          "selfhost-lint: expected input path before flags")
        (selfhost-lint-parse-options
          (+ start 1)
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

(define (selfhost-lint-form-delim? [source : String] [idx : i64]) : bool
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

;; True when line `line` (1-based) of `source` contains a `lint-allow: <rule-id>`
;; directive (as in `;; lint-allow: nested-if-ladder`). Scans the single line and
;; stops at its newline; `and`/`or` are not short-circuiting, so the `string-ref`
;; is guarded by the loop's `stop` flag rather than the bounds test.
(define (selfhost-lint-line-allows?
  [source : String]
  [line : i64]
  [rule-id : String]) : bool
  (let
    [needle : String (string-append "lint-allow: " rule-id)]
    [source-len : i64 (string-length source)]
    [line-start : i64 (selfhost-lint-line-start-index source line)]
    [found : bool false]
    [idx : i64 line-start]
    [stop : bool false]
    (begin
      (while (and (< idx source-len) (not stop))
        (if (= (string-ref source idx) #\newline')
          (set! stop true)
          (if (selfhost-lint-prefix-at? source idx needle)
            (begin
              (set! found true)
              (set! stop true))
            (set! idx (+ idx 1)))))
      found)))

;; A finding is suppressed when the line immediately above its flagged form
;; carries `;; lint-allow: <its-rule-id>`. Findings on line 1 have no line above
;; and cannot be suppressed this way.
(define (selfhost-lint-suppressed? [source : String] [finding : LintFinding]) : bool
  (let
    [span : AstSourceSpan (struct-get finding span)]
    [line : i64 (struct-get span start-line)]
    [rule-id : String (struct-get finding rule-id)]
    (if (<= line 1)
      false
      (selfhost-lint-line-allows? source (- line 1) rule-id))))

(define (selfhost-lint-form-origin?
  [source : String]
  [span : AstSourceSpan]
  [form-name : String]) : bool
  (let
    [line : i64 (struct-get span start-line)]
    [col : i64 (struct-get span start-col)]
    (if (or (<= line 0) (<= col 0))
      false
      (let
        [needle : String (string-append "(" form-name)]
        [line-start : i64 (selfhost-lint-line-start-index source line)]
        [idx : i64 (+ line-start (- col 1))]
        (and
          (selfhost-lint-prefix-at? source idx needle)
          (selfhost-lint-form-delim? source (+ idx (string-length needle))))))))

(define (selfhost-lint-derived-form-origin?
  [source : String]
  [span : AstSourceSpan]) : bool
  (or
    (selfhost-lint-form-origin? source span "cond")
    (or
      (selfhost-lint-form-origin? source span "when")
      (selfhost-lint-form-origin? source span "unless"))))

(define (selfhost-lint-filter-derived-origins
  [source : String]
  [items : LintFindingList]) : LintFindingList
  (match items
    [(LintFindingNil) LintFindingNil]
    [(LintFindingCons finding rest)
      (let
        [filtered-rest : LintFindingList
          (selfhost-lint-filter-derived-origins source rest)]
        (if (or
          (selfhost-lint-derived-form-origin? source (struct-get finding span))
          (selfhost-lint-suppressed? source finding))
          filtered-rest
          (LintFindingCons finding filtered-rest)))]))

(define (selfhost-lint-program-findings
  [source : String]
  [program : AstProgram]) : LintFindingList
  (match program
    [(AstProgram decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        (selfhost-lint-filter-derived-origins
          source
          (lint-program (ast-program decls) (lint-default-ladder-threshold))))]))

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

;; Run the `lint` command over arguments starting at `start`.
(define (selfhost-lint-run-from [start : i64] [count : i64]) : i64
  (match (selfhost-lint-config-from start count)
    [(OkSelfhostLintConfig config)
      (match config
        [(SelfhostLintConfig input-path stdlib-roots enforcing)
          (selfhost-lint-file input-path stdlib-roots enforcing)])]
    [(ErrSelfhostLintConfig message)
      (begin
        (print-error (string-append message "\n"))
        2)]))

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

;; Same ladder, but with a `;; lint-allow: nested-if-ladder` directive on the
;; line immediately above the flagged `if` - the finding must be suppressed.
(define (selfhost-lint-suppressed-ladder-source) : String
  "(define (classify [x : i64]) : i64
  ;; lint-allow: nested-if-ladder
  (if (= x 0)
    10
    (if (= x 1)
      20
      (if (= x 2)
        30
        0))))")

;; A directive for a different rule id must not suppress this rule.
(define (selfhost-lint-wrong-allow-ladder-source) : String
  "(define (classify [x : i64]) : i64
  ;; lint-allow: other-rule
  (if (= x 0)
    10
    (if (= x 1)
      20
      (if (= x 2)
        30
        0))))")

(define (selfhost-lint-return-path-chain-source) : String
  "(define (check [a : bool] [b : bool] [c : bool]) : i64
  (if a
    (if b
      (if c
        42
        3)
      2)
    1))")

(define (selfhost-lint-suppressed-return-path-chain-source) : String
  "(define (check [a : bool] [b : bool] [c : bool]) : i64
  ;; lint-allow: return-path-chain
  (if a
    (if b
      (if c
        42
        3)
      2)
    1))")

(define (selfhost-lint-unit-if-source) : String
  "(define (check [ok : bool]) : i64
  (begin
    (if ok
      (return 1)
      unit)
    42))")

(define (selfhost-lint-suppressed-unit-if-source) : String
  "(define (check [ok : bool]) : i64
  (begin
    ;; lint-allow: unit-if-guard
    (if ok
      (return 1)
      unit)
    42))")

(define (selfhost-lint-when-unless-source) : String
  "(define (check [a : bool] [b : bool]) : i64
  (begin
    (when a (return 1))
    (unless b (return 2))
    42))")

;; A clean source with no nested-`if` ladder - zero findings.
(define (selfhost-lint-clean-source) : String
  "(define (inc [x : i64]) : i64 (+ x 1))")

(define (selfhost-lint-nested-let-source) : String
  "(define (main) : i64
  (let
    [a : i64 1]
    (let
      [b : i64 (+ a 1)]
      (+ a b))))")

(define (selfhost-lint-shadowing-nested-let-source) : String
  "(define (main) : i64
  (let
    [a : i64 1]
    (let
      [a : i64 2]
      a)))")

(define (selfhost-lint-begin-inner-let-source) : String
  "(define (main) : i64
  (let
    [a : i64 1]
    (begin
      (let [b : i64 (+ a 1)] b)
      a)))")

(define (selfhost-lint-suppressed-nested-let-source) : String
  "(define (main) : i64
  ;; lint-allow: nested-let
  (let
    [a : i64 1]
    (let
      [b : i64 (+ a 1)]
      (+ a b))))")

;; Number of findings reported for `source` (after derived-form-origin +
;; suppression filtering), via the public source-lint path.
(define (selfhost-lint-source-finding-count [source : String]) : i64
  (lint-finding-list-count
    (selfhost-lint-source-with-roots
      "lint_driver_self_test.tl"
      source
      CompilerLoadRootNil)))

;; The reported ladder finding has depth 5, a stable rule id, and a real source
;; line.
(define (selfhost-lint-reported-finding-ok? [findings : LintFindingList]) : bool
  (match findings
    [(LintFindingCons finding _)
      (let
        [fspan : AstSourceSpan (struct-get finding span)]
        (and
          (= (struct-get finding depth) 5)
          (and
            (> (struct-get fspan start-line) 0)
            (string-eq
              (struct-get finding rule-id)
              (lint-rule-nested-if-ladder-id)))))]
    [(LintFindingNil) false]))

(define (selfhost-lint-nested-let-finding-ok? [findings : LintFindingList]) : bool
  (match findings
    [(LintFindingCons finding _)
      (let
        [fspan : AstSourceSpan (struct-get finding span)]
        (and
          (> (struct-get fspan start-line) 0)
          (string-eq (struct-get finding rule-id) (lint-rule-nested-let-id))))]
    [(LintFindingNil) false]))

(define (selfhost-lint-return-path-finding-ok? [findings : LintFindingList]) : bool
  (match findings
    [(LintFindingCons finding _)
      (let
        [fspan : AstSourceSpan (struct-get finding span)]
        (and
          (= (struct-get finding depth) 3)
          (and
            (> (struct-get fspan start-line) 0)
            (string-eq
              (struct-get finding rule-id)
              (lint-rule-return-path-chain-id)))))]
    [(LintFindingNil) false]))

(define (selfhost-lint-unit-if-finding-ok? [findings : LintFindingList]) : bool
  (match findings
    [(LintFindingCons finding _)
      (let
        [fspan : AstSourceSpan (struct-get finding span)]
        (and
          (= (struct-get finding depth) 1)
          (and
            (> (struct-get fspan start-line) 0)
            (string-eq
              (struct-get finding rule-id)
              (lint-rule-unit-if-guard-id)))))]
    [(LintFindingNil) false]))

(define (compiler-lint-driver-self-test) : i64
  (let
    [reported : LintFindingList
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-ladder-source)
        CompilerLoadRootNil)]
    [return-reported : LintFindingList
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-return-path-chain-source)
        CompilerLoadRootNil)]
    [unit-reported : LintFindingList
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-unit-if-source)
        CompilerLoadRootNil)]
    (cond
      ;; one reported finding, carrying the rule id / depth / span
      [(not (= (lint-finding-list-count reported) 1)) 1]
      [(not (selfhost-lint-reported-finding-ok? reported)) 2]
      [(not (= (lint-finding-list-count return-reported) 1)) 9]
      [(not (selfhost-lint-return-path-finding-ok? return-reported)) 10]
      [(not (= (lint-finding-list-count unit-reported) 1)) 12]
      [(not (selfhost-lint-unit-if-finding-ok? unit-reported)) 13]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-suppressed-return-path-chain-source))
            0))
        11]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-suppressed-unit-if-source))
            0))
        14]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-when-unless-source))
            0))
        15]
      ;; one suppressed finding (`;; lint-allow: nested-if-ladder`) -> none reported
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-suppressed-ladder-source))
            0))
        3]
      ;; a directive for a different rule id does not suppress this rule
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-wrong-allow-ladder-source))
            1))
        4]
      ;; one clean file -> none reported
      [(not
          (=
            (selfhost-lint-source-finding-count (selfhost-lint-clean-source))
            0))
        5]
      ;; body-only nested let reports one nested-let finding
      [(not
          (selfhost-lint-nested-let-finding-ok?
            (selfhost-lint-source-with-roots
              "lint_driver_self_test.tl"
              (selfhost-lint-nested-let-source)
              CompilerLoadRootNil)))
        9]
      ;; inner let shadowing an outer binding is not semantics-preserving to
      ;; suggest, so it remains clean.
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-shadowing-nested-let-source))
            0))
        10]
      ;; an inner let inside a real begin body is not the body-only pattern.
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-begin-inner-let-source))
            0))
        11]
      ;; nested-let findings use the same inline suppression path.
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-suppressed-nested-let-source))
            0))
        12]
      ;; enforcing (`--check`) mode exits 1 when findings remain, 0 when clean
      [(not (= (selfhost-lint-enforce-exit true 1) 1)) 6]
      [(not (= (selfhost-lint-enforce-exit true 0) 0)) 7]
      ;; warn-only mode (default) exits 0 even with findings
      [(not (= (selfhost-lint-enforce-exit false 1) 0)) 8]
      [else 42])))