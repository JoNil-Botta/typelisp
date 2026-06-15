;; lint_driver_core.tl - Driver logic for the selfhost `typelisp lint` tool
;; (#1163): load a TypeLisp source, run the lint_core rules over its program, and
;; render each finding as `path:line:col: message`. Kept main-less so both the
;; CLI driver (`lint.tl`) and the runnable smoke (`lint_driver_smoke.tl`) can
;; import it. Warn-only by default; callers can pass `--check` after the input
;; path to exit non-zero when findings remain. The deprecated string-concat rule
;; is opt-in until the remaining in-tree str-cat migrations land.
(import stdlib.io as io_mod)

(import stdlib.list as list_mod)

(import "compiler_load.tl")

(import "lint_core.tl")

(import "package_source_core.tl")

(import stdlib.string as string_mod)

(import stdlib.vector as vector_mod)

;; Parsed lint CLI config: input paths, stdlib roots, whether `--check`
;; enforcing mode was requested (exit non-zero when findings are present), and
;; whether the staged deprecated string-concat rule is enabled.
(defenum SelfhostLintConfig
  (SelfhostLintFileConfig vector_mod.StringVec vector_mod.StringVec bool bool)
  (SelfhostLintPackageConfig String bool vector_mod.StringVec bool bool))

(defenum ResultSelfhostLintConfig
  (OkSelfhostLintConfig SelfhostLintConfig)
  (ErrSelfhostLintConfig String))

(define (selfhost-lint-flag? [value : String]) : bool
  (and (> (string-length value) 0) (= (string-ref value 0) #-')))

(define (selfhost-lint-config-finish
  [input-paths : vector_mod.StringVec]
  [manifest-path : String]
  [has-manifest : bool]
  [stdlib-roots : vector_mod.StringVec]
  [enforcing : bool]
  [deprecated-string-concat : bool]) : ResultSelfhostLintConfig
  (if (vector_mod.string-vec-is-empty? input-paths)
    (OkSelfhostLintConfig
      (SelfhostLintPackageConfig
        manifest-path
        has-manifest
        stdlib-roots
        enforcing
        deprecated-string-concat))
    (if has-manifest
      (ErrSelfhostLintConfig
        "selfhost-lint: cannot combine input paths with --manifest-path")
      (OkSelfhostLintConfig
        (SelfhostLintFileConfig
          input-paths
          stdlib-roots
          enforcing
          deprecated-string-concat)))))

(define (selfhost-lint-parse-options
  [idx : i64]
  [count : i64]
  [input-paths : vector_mod.StringVec]
  [manifest-path : String]
  [has-manifest : bool]
  [stdlib-roots : vector_mod.StringVec]
  [enforcing : bool]
  [deprecated-string-concat : bool]) : ResultSelfhostLintConfig
  (if (>= idx count)
    (selfhost-lint-config-finish
      input-paths
      manifest-path
      has-manifest
      stdlib-roots
      enforcing
      deprecated-string-concat)
    (let
      [current : String (io_mod.arg idx)]
      (if (string_mod.string-eq current "--check")
        (selfhost-lint-parse-options
          (+ idx 1)
          count
          input-paths
          manifest-path
          has-manifest
          stdlib-roots
          true
          deprecated-string-concat)
        (if (string_mod.string-eq current "--deprecated-string-concat")
          (selfhost-lint-parse-options
            (+ idx 1)
            count
            input-paths
            manifest-path
            has-manifest
            stdlib-roots
            enforcing
            true)
          (if (string_mod.string-eq current "--stdlib-root")
            (if (>= (+ idx 1) count)
              (ErrSelfhostLintConfig
                "selfhost-lint: --stdlib-root requires a value")
              (selfhost-lint-parse-options
                (+ idx 2)
                count
                input-paths
                manifest-path
                has-manifest
                (vector_mod.string-vec-push stdlib-roots (io_mod.arg (+ idx 1)))
                enforcing
                deprecated-string-concat))
            (if (string_mod.string-eq current "--manifest-path")
              (if (>= (+ idx 1) count)
                (ErrSelfhostLintConfig
                  "selfhost-lint: --manifest-path requires a value")
                (if has-manifest
                  (ErrSelfhostLintConfig
                    "selfhost-lint: duplicate --manifest-path")
                  (selfhost-lint-parse-options
                    (+ idx 2)
                    count
                    input-paths
                    (io_mod.arg (+ idx 1))
                    true
                    stdlib-roots
                    enforcing
                    deprecated-string-concat)))
              (if (selfhost-lint-flag? current)
                (ErrSelfhostLintConfig
                  (string_mod.string-append
                    "selfhost-lint: unknown flag "
                    current))
                (selfhost-lint-parse-options
                  (+ idx 1)
                  count
                  (vector_mod.string-vec-push input-paths current)
                  manifest-path
                  has-manifest
                  stdlib-roots
                  enforcing
                  deprecated-string-concat)))))))))

;; Parse the `lint` config from arguments starting at `start`.
(define (selfhost-lint-config-from [start : i64] [count : i64]) : ResultSelfhostLintConfig
  (selfhost-lint-parse-options
    start
    count
    (vector_mod.string-vec-new)
    ""
    false
    (vector_mod.string-vec-new)
    false
    false))

;; Render one finding as `path:line:col: message` (line/col from the flagged
;; node's source span; 0:0 only for synthesized nodes that carry no location).
(define (selfhost-lint-render-finding [path : String] [finding : LintFinding]) : String
  (let
    [fspan : AstSourceSpan (struct-get finding span)]
    (string_mod.string-append
      path
      (string_mod.string-append
        ":"
        (string_mod.string-append
          (string_mod.int->string (struct-get fspan start-line))
          (string_mod.string-append
            ":"
            (string_mod.string-append
              (string_mod.int->string (struct-get fspan start-col))
              (string_mod.string-append ": " (struct-get finding message)))))))))

;; Print every finding (one per line) to stdout; returns the number printed.
;; Findings are stored in discovery order, so render backward to preserve the
;; historical list-accumulator output order.
(define (selfhost-lint-print-findings-from
  [path : String]
  [items : LintFindings]
  [index : i64]
  [printed : i64]) : i64
  (if (< index 0)
    printed
    (begin
      (io_mod.print-string
        (string_mod.string-append
          (selfhost-lint-render-finding path (lint-findings-ref items index))
          "\n"))
      (selfhost-lint-print-findings-from path items (- index 1) (+ printed 1)))))

(define (selfhost-lint-print-findings [path : String] [items : LintFindings]) : i64
  (selfhost-lint-print-findings-from
    path
    items
    (- (lint-findings-count items) 1)
    0))

(define (selfhost-lint-space? [c : char]) : bool
  (or (= c #\space') (= c #\tab') (= c #\newline') (= c #\return')))

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
    [needle : String (string_mod.string-append "lint-allow: " rule-id)]
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
        [needle : String (string_mod.string-append "(" form-name)]
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
    (selfhost-lint-form-origin? source span "when")
    (selfhost-lint-form-origin? source span "unless")))

(define (selfhost-lint-filter-derived-origins-from
  [source : String]
  [items : LintFindings]
  [index : i64]
  [out : LintFindings]) : LintFindings
  (if (>= index (lint-findings-count items))
    out
    (let
      [finding : LintFinding (lint-findings-ref items index)]
      [next : LintFindings
        (if (or
          (selfhost-lint-derived-form-origin? source (struct-get finding span))
          (selfhost-lint-suppressed? source finding))
          out
          (lint-findings-add finding out))]
      (selfhost-lint-filter-derived-origins-from source items (+ index 1) next))))

(define (selfhost-lint-filter-derived-origins
  [source : String]
  [items : LintFindings]) : LintFindings
  (selfhost-lint-filter-derived-origins-from
    source
    items
    0
    (lint-findings-empty)))

(define (selfhost-lint-program-findings-with-options
  [source : String]
  [program : AstProgram]
  [deprecated-string-concat : bool]) : LintFindings
  (match program
    [(AstProgram decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        (selfhost-lint-filter-derived-origins
          source
          (if deprecated-string-concat
            (lint-program-with-deprecated-string-concat
              source
              (ast-program decls)
              (lint-default-ladder-threshold))
            (lint-program (ast-program decls) (lint-default-ladder-threshold)))))]))

(define (selfhost-lint-program-findings
  [source : String]
  [program : AstProgram]) : LintFindings
  (selfhost-lint-program-findings-with-options source program false))

(define (selfhost-lint-source-with-roots-and-options
  [path : String]
  [source : String]
  [stdlib-roots : vector_mod.StringVec]
  [deprecated-string-concat : bool]) : LintFindings
  (match (parse-ast-source-diagnostic path source)
    [(OkAstProgramDiagnostic program)
      (selfhost-lint-program-findings-with-options
        source
        program
        deprecated-string-concat)]
    [(ErrAstProgramDiagnostic _) (lint-findings-empty)]))

;; Parse `source` (attributed to `path`) and run the lint rules over this source
;; unit only. Imports are linted when their own files are selected by the repo
;; lint gate, so a public driver does not duplicate every imported finding.
(define (selfhost-lint-source-with-roots
  [path : String]
  [source : String]
  [stdlib-roots : vector_mod.StringVec]) : LintFindings
  (selfhost-lint-source-with-roots-and-options path source stdlib-roots false))

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
  [stdlib-roots : vector_mod.StringVec]
  [enforcing : bool]
  [deprecated-string-concat : bool]) : i64
  (let
    [source : String (io_mod.read-file input-path)]
    (match (parse-ast-source-diagnostic input-path source)
      [(OkAstProgramDiagnostic program)
        (let
          [findings : LintFindings
            (selfhost-lint-program-findings-with-options
              source
              program
              deprecated-string-concat)]
          (begin
            (selfhost-lint-print-findings input-path findings)
            (io_mod.print-string
              (string_mod.string-append
                "lint: "
                (string_mod.string-append
                  (string_mod.int->string (lint-findings-count findings))
                  " finding(s)\n")))
            (selfhost-lint-enforce-exit
              enforcing
              (lint-findings-count findings))))]
      [(ErrAstProgramDiagnostic diag)
        (begin
          (io_mod.print-error (compiler-diagnostic-render diag))
          1)])))

(define (selfhost-lint-files-from
  [input-paths : vector_mod.StringVec]
  [index : i64]
  [stdlib-roots : vector_mod.StringVec]
  [enforcing : bool]
  [deprecated-string-concat : bool]
  [print-headers : bool]
  [status : i64]) : i64
  (if (>= index (vector_mod.string-vec-len input-paths))
    status
    (let
      [input-path : String (vector_mod.string-vec-get input-paths index "")]
      [file-status : i64
        (begin
          (if print-headers
            (io_mod.print-string
              (string_mod.string-append
                "--- "
                (string_mod.string-append input-path "\n")))
            unit)
          (selfhost-lint-file
            input-path
            stdlib-roots
            enforcing
            deprecated-string-concat))]
      (selfhost-lint-files-from
        input-paths
        (+ index 1)
        stdlib-roots
        enforcing
        deprecated-string-concat
        print-headers
        (if (= status 0)
          file-status
          status)))))

(define (selfhost-lint-files
  [input-paths : vector_mod.StringVec]
  [stdlib-roots : vector_mod.StringVec]
  [enforcing : bool]
  [deprecated-string-concat : bool]
  [print-headers : bool]
  [status : i64]) : i64
  (selfhost-lint-files-from
    input-paths
    0
    stdlib-roots
    enforcing
    deprecated-string-concat
    print-headers
    status))

(define (selfhost-lint-package-files-from
  [input-paths : vector_mod.StringVec]
  [index : i64]
  [stdlib-roots : vector_mod.StringVec]
  [enforcing : bool]
  [deprecated-string-concat : bool]
  [print-headers : bool]
  [status : i64]) : i64
  (if (>= index (vector_mod.string-vec-len input-paths))
    status
    (let
      [input-path : String (vector_mod.string-vec-get input-paths index "")]
      [file-status : i64
        (begin
          (if print-headers
            (io_mod.print-string
              (string_mod.string-append
                "--- "
                (string_mod.string-append input-path "\n")))
            unit)
          (selfhost-lint-file
            input-path
            stdlib-roots
            enforcing
            deprecated-string-concat))]
      (selfhost-lint-package-files-from
        input-paths
        (+ index 1)
        stdlib-roots
        enforcing
        deprecated-string-concat
        print-headers
        (if (= status 0)
          file-status
          status)))))

(define (selfhost-lint-package-files
  [input-paths : vector_mod.StringVec]
  [stdlib-roots : vector_mod.StringVec]
  [enforcing : bool]
  [deprecated-string-concat : bool]
  [print-headers : bool]
  [status : i64]) : i64
  (selfhost-lint-package-files-from
    input-paths
    0
    stdlib-roots
    enforcing
    deprecated-string-concat
    print-headers
    status))

(define (selfhost-lint-package
  [manifest-path : String]
  [has-manifest : bool]
  [stdlib-roots : vector_mod.StringVec]
  [enforcing : bool]
  [deprecated-string-concat : bool]) : i64
  (match (package-source-discover-for "lint" manifest-path has-manifest)
    [(ErrPackageSourceSet message)
      (begin
        (io_mod.print-error (string_mod.string-append message "\n"))
        1)]
    [(OkPackageSourceSet source-set)
      (selfhost-lint-package-files
        (struct-get source-set sources)
        stdlib-roots
        enforcing
        deprecated-string-concat
        (> (vector_mod.string-vec-len (struct-get source-set sources)) 1)
        0)]))

;; Run the `lint` command over arguments starting at `start`.
(define (selfhost-lint-run-from [start : i64] [count : i64]) : i64
  (match (selfhost-lint-config-from start count)
    [(OkSelfhostLintConfig config)
      (match config
        [(SelfhostLintFileConfig
            input-paths
            stdlib-roots
            enforcing
            deprecated-string-concat)
          (selfhost-lint-files
            input-paths
            stdlib-roots
            enforcing
            deprecated-string-concat
            (> (vector_mod.string-vec-len input-paths) 1)
            0)]
        [(SelfhostLintPackageConfig
            manifest-path
            has-manifest
            stdlib-roots
            enforcing
            deprecated-string-concat)
          (selfhost-lint-package
            manifest-path
            has-manifest
            stdlib-roots
            enforcing
            deprecated-string-concat)])]
    [(ErrSelfhostLintConfig message)
      (begin
        (io_mod.print-error (string_mod.string-append message "\n"))
        2)]))

;; ---- self-test (driven by lint_driver_smoke.tl) ----
;; A five-deep value-dispatch if-ladder. The nested-if-ladder rule remains
;; registered, but #2579 keeps it dormant while bootstrap source must use
;; nested `if` instead of bracket `cond`, so this emits no findings.
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

;; Same ladder, but with a `;; lint-allow: nested-if-ladder` directive retained
;; to prove the dormant rule id still parses as a stable suppression key.
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

;; A directive for a different rule id also emits no ladder finding while the
;; rule is dormant.
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

(define (selfhost-lint-unit-set-source) : String
  "(define (check [ok : bool]) : i64
  (let
    [seen : bool true]
    (begin
      (if (not ok)
        unit
        (set! seen false))
      (if seen 42 0))))")

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

(define (selfhost-lint-cascading-and-source) : String
  "(define (check [a : bool] [b : bool] [c : bool]) : bool
  (and a (and b c)))")

(define (selfhost-lint-cascading-or-source) : String
  "(define (check [a : bool] [b : bool] [c : bool]) : bool
  (or (or a b) c))")

(define (selfhost-lint-cascading-core-and-source) : String
  "(define (check [a : bool] [b : bool] [c : bool]) : bool
  (and a (and b c)))")

(define (selfhost-lint-flat-and-source) : String
  "(define (check [a : bool] [b : bool] [c : bool]) : bool
  (and a b c))")

(define (selfhost-lint-mixed-and-or-source) : String
  "(define (check [a : bool] [b : bool] [c : bool]) : bool
  (and a (or b c)))")

(define (selfhost-lint-suppressed-cascading-and-source) : String
  "(define (check [a : bool] [b : bool] [c : bool]) : bool
  ;; lint-allow: cascading-and-or
  (and a (and b c)))")

(define (selfhost-lint-two-findings-source) : String
  "(define (first [x : i64]) : i64
  (if (= x 0)
    0
    (if (= x 1)
      1
      (if (= x 2)
        2
        3))))

(define (second [x : i64]) : i64
  (if (= x 0)
    10
    (if (= x 1)
      20
      (if (= x 2)
        30
        40))))")

;; Number of findings reported for `source` (after derived-form-origin +
;; suppression filtering), via the public source-lint path.
(define (selfhost-lint-source-finding-count [source : String]) : i64
  (lint-findings-count
    (selfhost-lint-source-with-roots
      "lint_driver_self_test.tl"
      source
      (vector_mod.string-vec-new))))

;; Compatibility helper retained for the nested-if-ladder metadata shape.
(define (selfhost-lint-reported-finding-ok? [findings : LintFindings]) : bool
  (match (lint-findings-get findings 0)
    [(LintSomeFinding finding)
      (let
        [fspan : AstSourceSpan (struct-get finding span)]
        (and
          (= (struct-get finding depth) 5)
          (> (struct-get fspan start-line) 0)
          (string_mod.string-eq
            (struct-get finding rule-id)
            (lint-rule-nested-if-ladder-id))))]
    [(LintNoFinding) false]))

(define (selfhost-lint-nested-let-finding-ok? [findings : LintFindings]) : bool
  (match (lint-findings-get findings 0)
    [(LintSomeFinding finding)
      (let
        [fspan : AstSourceSpan (struct-get finding span)]
        (and
          (> (struct-get fspan start-line) 0)
          (string_mod.string-eq
            (struct-get finding rule-id)
            (lint-rule-nested-let-id))))]
    [(LintNoFinding) false]))

(define (selfhost-lint-return-path-finding-ok? [findings : LintFindings]) : bool
  (match (lint-findings-get findings 0)
    [(LintSomeFinding finding)
      (let
        [fspan : AstSourceSpan (struct-get finding span)]
        (and
          (= (struct-get finding depth) 3)
          (> (struct-get fspan start-line) 0)
          (string_mod.string-eq
            (struct-get finding rule-id)
            (lint-rule-return-path-chain-id))))]
    [(LintNoFinding) false]))

(define (selfhost-lint-unit-if-finding-ok? [findings : LintFindings]) : bool
  (match (lint-findings-get findings 0)
    [(LintSomeFinding finding)
      (let
        [fspan : AstSourceSpan (struct-get finding span)]
        (and
          (= (struct-get finding depth) 1)
          (> (struct-get fspan start-line) 0)
          (string_mod.string-eq
            (struct-get finding rule-id)
            (lint-rule-unit-if-guard-id))))]
    [(LintNoFinding) false]))

(define (selfhost-lint-cascading-and-or-finding-ok?
  [findings : LintFindings]
  [message : String]) : bool
  (match (lint-findings-get findings 0)
    [(LintSomeFinding finding)
      (let
        [fspan : AstSourceSpan (struct-get finding span)]
        (and
          (= (struct-get finding depth) 3)
          (> (struct-get fspan start-line) 0)
          (string_mod.string-eq
            (struct-get finding rule-id)
            (lint-rule-cascading-and-or-id))
          (string_mod.string-eq (struct-get finding message) message)))]
    [(LintNoFinding) false]))

(define (selfhost-lint-render-order-ok? [findings : LintFindings]) : bool
  (if (= (lint-findings-count findings) 2)
    (match (lint-findings-get findings 1)
      [(LintSomeFinding rendered-first)
        (match (lint-findings-get findings 0)
          [(LintSomeFinding rendered-second)
            (let
              [first-span : AstSourceSpan (struct-get rendered-first span)]
              [second-span : AstSourceSpan (struct-get rendered-second span)]
              (and
                (= (struct-get first-span start-line) 11)
                (= (struct-get second-span start-line) 2)))]
          [(LintNoFinding) false])]
      [(LintNoFinding) false])
    false))

(define (compiler-lint-driver-self-test) : i64
  (let
    [reported : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-ladder-source)
        (vector_mod.string-vec-new))]
    [return-reported : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-return-path-chain-source)
        (vector_mod.string-vec-new))]
    [unit-reported : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-unit-if-source)
        (vector_mod.string-vec-new))]
    [unit-set-reported : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-unit-set-source)
        (vector_mod.string-vec-new))]
    [two-reported : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-two-findings-source)
        (vector_mod.string-vec-new))]
    [cascading-and-reported : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-cascading-and-source)
        (vector_mod.string-vec-new))]
    [cascading-or-reported : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-cascading-or-source)
        (vector_mod.string-vec-new))]
    [cascading-core-and-reported : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-cascading-core-and-source)
        (vector_mod.string-vec-new))]
    (if (not (= (lint-findings-count reported) 0))
      1
      (if (not (= (lint-findings-count return-reported) 1))
        9
        (if (not (selfhost-lint-return-path-finding-ok? return-reported))
          10
          (if (not (= (lint-findings-count unit-reported) 1))
            12
            (if (not (selfhost-lint-unit-if-finding-ok? unit-reported))
              13
              (if (not (= (lint-findings-count unit-set-reported) 1))
                16
                (if (not (selfhost-lint-unit-if-finding-ok? unit-set-reported))
                  17
                  (if (not (= (lint-findings-count two-reported) 0))
                    18
                    (if (not (= (lint-findings-count cascading-and-reported) 1))
                      20
                      (if (not
                        (selfhost-lint-cascading-and-or-finding-ok?
                          cascading-and-reported
                          "cascading and: prefer flat n-ary form (and a b c)"))
                        21
                        (if (not
                          (= (lint-findings-count cascading-or-reported) 1))
                          22
                          (if (not
                            (selfhost-lint-cascading-and-or-finding-ok?
                              cascading-or-reported
                              "cascading or: prefer flat n-ary form (or a b c)"))
                            23
                            (if (not
                              (=
                                (lint-findings-count
                                  cascading-core-and-reported)
                                1))
                              24
                              (if (not
                                (selfhost-lint-cascading-and-or-finding-ok?
                                  cascading-core-and-reported
                                  "cascading and: prefer flat n-ary form (and a b c)"))
                                25
                                (if (not
                                  (=
                                    (selfhost-lint-source-finding-count
                                      (selfhost-lint-flat-and-source))
                                    0))
                                  26
                                  (if (not
                                    (=
                                      (selfhost-lint-source-finding-count
                                        (selfhost-lint-mixed-and-or-source))
                                      0))
                                    27
                                    (if (not
                                      (=
                                        (selfhost-lint-source-finding-count
                                          (selfhost-lint-suppressed-cascading-and-source))
                                        0))
                                      28
                                      (if (not
                                        (=
                                          (selfhost-lint-source-finding-count
                                            (selfhost-lint-suppressed-return-path-chain-source))
                                          0))
                                        11
                                        (if (not
                                          (=
                                            (selfhost-lint-source-finding-count
                                              (selfhost-lint-suppressed-unit-if-source))
                                            0))
                                          14
                                          (if (not
                                            (=
                                              (selfhost-lint-source-finding-count
                                                (selfhost-lint-when-unless-source))
                                              0))
                                            15
                                            (if (not
                                              (=
                                                (selfhost-lint-source-finding-count
                                                  (selfhost-lint-suppressed-ladder-source))
                                                0))
                                              3
                                              (if (not
                                                (=
                                                  (selfhost-lint-source-finding-count
                                                    (selfhost-lint-wrong-allow-ladder-source))
                                                  0))
                                                4
                                                (if (not
                                                  (=
                                                    (selfhost-lint-source-finding-count
                                                      (selfhost-lint-clean-source))
                                                    0))
                                                  5
                                                  (if (not
                                                    (selfhost-lint-nested-let-finding-ok?
                                                      (selfhost-lint-source-with-roots
                                                        "lint_driver_self_test.tl"
                                                        (selfhost-lint-nested-let-source)
                                                        (vector_mod.string-vec-new))))
                                                    9
                                                    (if (not
                                                      (=
                                                        (selfhost-lint-source-finding-count
                                                          (selfhost-lint-shadowing-nested-let-source))
                                                        0))
                                                      10
                                                      (if (not
                                                        (=
                                                          (selfhost-lint-source-finding-count
                                                            (selfhost-lint-begin-inner-let-source))
                                                          0))
                                                        11
                                                        (if (not
                                                          (=
                                                            (selfhost-lint-source-finding-count
                                                              (selfhost-lint-suppressed-nested-let-source))
                                                            0))
                                                          12
                                                          (if (not
                                                            (=
                                                              (selfhost-lint-enforce-exit
                                                                true
                                                                1)
                                                              1))
                                                            6
                                                            (if (not
                                                              (=
                                                                (selfhost-lint-enforce-exit
                                                                  true
                                                                  0)
                                                                0))
                                                              7
                                                              (if (not
                                                                (=
                                                                  (selfhost-lint-enforce-exit
                                                                    false
                                                                    1)
                                                                  0))
                                                                8
                                                                42))))))))))))))))))))))))))))))))