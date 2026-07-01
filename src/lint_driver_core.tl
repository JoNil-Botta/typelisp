;; lint_driver_core.tl - Driver logic for the selfhost `typelisp lint` tool
;; (#1163): load a TypeLisp source, run the lint_core rules over its program, and
;; render each finding as `path:line:col: message`. Kept main-less so both the
;; CLI driver (`lint.tl`) and the runnable smoke (`lint_driver_smoke.tl`) can
;; import it. Warn-only by default; callers can pass `--check` after the input
;; path to exit non-zero when findings remain. The deprecated string.concat rule
;; and staged migration rules are opt-in until their in-tree migrations land.
(import stdlib.io)
(import stdlib.vector)
(import "compiler_check_core.tl")
(import "compiler_load.tl")
(import "lint_core.tl")
(import "package_source_core.tl")
(import stdlib.string)

;; Parsed lint CLI config: input paths, stdlib roots, whether `--check`
;; enforcing mode was requested (exit non-zero when findings are present), and
;; whether staged migration rules are enabled.
(defenum SelfhostLintConfig
  (File vector.StringVec vector.StringVec bool bool bool)
  (Package String bool vector.StringVec bool bool bool))

(defenum ResultSelfhostLintConfig
  (Ok SelfhostLintConfig)
  (Err String))

(define (selfhost-lint-flag? [value : String]) : bool
  (and (> (string.string-length value) 0) (= (string.string-ref value 0) '-')))

(define (selfhost-lint-config-finish
  [input-paths : vector.StringVec]
  [manifest-path : String]
  [has-manifest : bool]
  [stdlib-roots : vector.StringVec]
  [enforcing : bool]
  [deprecated-string-concat : bool]
  [redundant-function-name : bool]) : ResultSelfhostLintConfig
  (if (vector.string-vec-is-empty? input-paths)
    (ResultSelfhostLintConfig.Ok
      (SelfhostLintConfig.Package
        manifest-path
        has-manifest
        stdlib-roots
        enforcing
        deprecated-string-concat
        redundant-function-name))
    (if has-manifest
      (ResultSelfhostLintConfig.Err
        "selfhost-lint: cannot combine input paths with --manifest-path")
      (ResultSelfhostLintConfig.Ok
        (SelfhostLintConfig.File
          input-paths
          stdlib-roots
          enforcing
          deprecated-string-concat
          redundant-function-name)))))

(define (selfhost-lint-parse-options
  [idx : i64]
  [count : i64]
  [input-paths : vector.StringVec]
  [manifest-path : String]
  [has-manifest : bool]
  [stdlib-roots : vector.StringVec]
  [enforcing : bool]
  [deprecated-string-concat : bool]
  [redundant-function-name : bool]) : ResultSelfhostLintConfig
  (if (>= idx count)
    (selfhost-lint-config-finish
      input-paths
      manifest-path
      has-manifest
      stdlib-roots
      enforcing
      deprecated-string-concat
      redundant-function-name)
    (let
      [current : String (io.arg idx)]
      (cond
        [(string.eq current "--check")
          (selfhost-lint-parse-options
            (+ idx 1)
            count
            input-paths
            manifest-path
            has-manifest
            stdlib-roots
            true
            deprecated-string-concat
            redundant-function-name)]
        [(string.eq current "--deprecated-string-concat")
          (selfhost-lint-parse-options
            (+ idx 1)
            count
            input-paths
            manifest-path
            has-manifest
            stdlib-roots
            enforcing
            true
            redundant-function-name)]
        [(string.eq current "--redundant-function-name")
          (selfhost-lint-parse-options
            (+ idx 1)
            count
            input-paths
            manifest-path
            has-manifest
            stdlib-roots
            enforcing
            deprecated-string-concat
            true)]
        [(string.eq current "--stdlib-root")
          (if (>= (+ idx 1) count)
            (ResultSelfhostLintConfig.Err
              "selfhost-lint: --stdlib-root requires a value")
            (selfhost-lint-parse-options
              (+ idx 2)
              count
              input-paths
              manifest-path
              has-manifest
              (vector.string-vec-push stdlib-roots (io.arg (+ idx 1)))
              enforcing
              deprecated-string-concat
              redundant-function-name))]
        [(string.eq current "--manifest-path")
          (if (>= (+ idx 1) count)
            (ResultSelfhostLintConfig.Err
              "selfhost-lint: --manifest-path requires a value")
            (if has-manifest
              (ResultSelfhostLintConfig.Err
                "selfhost-lint: duplicate --manifest-path")
              (selfhost-lint-parse-options
                (+ idx 2)
                count
                input-paths
                (io.arg (+ idx 1))
                true
                stdlib-roots
                enforcing
                deprecated-string-concat
                redundant-function-name)))]
        [(selfhost-lint-flag? current)
          (ResultSelfhostLintConfig.Err
            (string.append "selfhost-lint: unknown flag " current))]
        [else
          (selfhost-lint-parse-options
            (+ idx 1)
            count
            (vector.string-vec-push input-paths current)
            manifest-path
            has-manifest
            stdlib-roots
            enforcing
            deprecated-string-concat
            redundant-function-name)]))))

;; Parse the `lint` config from arguments starting at `start`.
(define (selfhost-lint-config-from [start : i64] [count : i64]) : ResultSelfhostLintConfig
  (selfhost-lint-parse-options
    start
    count
    (vector.string-vec-new)
    ""
    false
    (vector.string-vec-new)
    false
    false
    false))

;; Render one finding as `path:line:col: message` (line/col from the flagged
;; node's source span; 0:0 only for synthesized nodes that carry no location).
(define (selfhost-lint-render-finding [path : String] [finding : LintFinding]) : String
  (let
    [fspan : AstSourceSpan (struct-get finding span)]
    (string.append
      path
      (string.append
        ":"
        (string.append
          (string.int->string (struct-get fspan start-line))
          (string.append
            ":"
            (string.append
              (string.int->string (struct-get fspan start-col))
              (string.append ": " (struct-get finding message)))))))))

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
      (io.print-string
        (string.append
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
  (or (= c ' ') (= c '\t') (= c '\n') (= c '\r')))

(define (selfhost-lint-prefix-at?
  [source : String]
  [start : i64]
  [needle : String]) : bool
  (let
    [source-len : i64 (string.string-length source)]
    [needle-len : i64 (string.string-length needle)]
    (if (< start 0)
      false
      (if (> (+ start needle-len) source-len)
        false
        (let
          [ok : bool true]
          [idx : i64 0]
          (begin
            (while (and ok (< idx needle-len))
              (if (=
                (string.string-ref source (+ start idx))
                (string.string-ref needle idx))
                (set! idx (+ idx 1))
                (set! ok false)))
            ok))))))

(define (selfhost-lint-form-delim? [source : String] [idx : i64]) : bool
  (let
    [source-len : i64 (string.string-length source)]
    (if (>= idx source-len)
      true
      (let
        [c : char (string.string-ref source idx)]
        (or (selfhost-lint-space? c) (= c ')'))))))

(define (selfhost-lint-line-start-index [source : String] [target-line : i64]) : i64
  (let
    [source-len : i64 (string.string-length source)]
    [idx : i64 0]
    [line : i64 1]
    [start : i64 0]
    (begin
      (while (and (< idx source-len) (< line target-line))
        (if (= (string.string-ref source idx) '\n')
          (begin
            (set! line (+ line 1))
            (set! start (+ idx 1))
            (set! idx (+ idx 1)))
          (set! idx (+ idx 1))))
      (if (= line target-line)
        start
        source-len))))

(define (selfhost-lint-span-start-index
  [source : String]
  [span : AstSourceSpan]) : i64
  (+
    (selfhost-lint-line-start-index source (struct-get span start-line))
    (- (struct-get span start-col) 1)))

(define (selfhost-lint-skip-line [source : String] [idx : i64] [n : i64]) : i64
  (let
    [j : i64 idx]
    (begin
      (while (and (< j n) (not (= (string.string-ref source j) '\n')))
        (set! j (+ j 1)))
      (if (< j n)
        (+ j 1)
        j))))

(define (selfhost-lint-skip-string [source : String] [idx : i64] [n : i64]) : i64
  (let
    [j : i64 (+ idx 1)]
    [done : bool false]
    (begin
      (while (and (< j n) (not done))
        (let
          [c : char (string.string-ref source j)]
          (if (= c '\\')
            (set! j (+ j 2))
            (if (= c '"')
              (begin
                (set! done true)
                (set! j (+ j 1)))
              (set! j (+ j 1))))))
      j)))

(define (selfhost-lint-apostrophe-char-escape? [c : char]) : bool
  (or (= c 'n') (= c 't') (= c 'r') (= c '0') (= c '\\') (= c '\'')))

(define (selfhost-lint-skip-apostrophe-char-literal
  [source : String]
  [idx : i64]
  [n : i64]) : i64
  (if (< (+ idx 1) n)
    (let
      [payload : char (string.string-ref source (+ idx 1))]
      (cond
        [(= payload '\\')
          (if (and
            (< (+ idx 3) n)
            (selfhost-lint-apostrophe-char-escape?
              (string.string-ref source (+ idx 2)))
            (= (string.string-ref source (+ idx 3)) '\''))
            (+ idx 4)
            (+ idx 1))]
        [(or (= payload '\'') (= payload '\n') (= payload '\r')) (+ idx 1)]
        [else
          (if (and
            (< (+ idx 2) n)
            (= (string.string-ref source (+ idx 2)) '\''))
            (+ idx 3)
            (+ idx 1))]))
    (+ idx 1)))

(define (selfhost-lint-skip-ws-comments [source : String] [idx : i64] [n : i64]) : i64
  (let
    [j : i64 idx]
    [done : bool false]
    (begin
      (while (and (< j n) (not done))
        (let
          [c : char (string.string-ref source j)]
          (cond
            [(selfhost-lint-space? c) (set! j (+ j 1))]
            [(= c ';') (set! j (selfhost-lint-skip-line source j n))]
            [else (set! done true)])))
      j)))

(define (selfhost-lint-source-form-delim? [c : char]) : bool
  (or
    (selfhost-lint-space? c)
    (= c '(')
    (= c ')')
    (= c '[')
    (= c ']')
    (= c ';')))

(define (selfhost-lint-skip-atom [source : String] [idx : i64] [n : i64]) : i64
  (let
    [j : i64 idx]
    (begin
      (while (and
        (< j n)
        (not (selfhost-lint-source-form-delim? (string.string-ref source j))))
        (set! j (+ j 1)))
      j)))

(define (selfhost-lint-skip-source-group
  [source : String]
  [idx : i64]
  [n : i64]) : i64
  (let
    [j : i64 (+ idx 1)]
    [depth : i64 1]
    [done : bool false]
    (begin
      (while (and (< j n) (not done))
        (let
          [c : char (string.string-ref source j)]
          (cond
            [(= c ';') (set! j (selfhost-lint-skip-line source j n))]
            [(= c '"') (set! j (selfhost-lint-skip-string source j n))]
            [(= c '\'')
              (set! j (selfhost-lint-skip-apostrophe-char-literal source j n))]
            [(or (= c '(') (= c '['))
              (begin
                (set! depth (+ depth 1))
                (set! j (+ j 1)))]
            [(or (= c ')') (= c ']'))
              (begin
                (set! depth (- depth 1))
                (set! j (+ j 1))
                (if (<= depth 0)
                  (set! done true)
                  unit))]
            [else (set! j (+ j 1))])))
      j)))

(define (selfhost-lint-skip-source-form [source : String] [idx : i64] [n : i64]) : i64
  (let
    [j : i64 (selfhost-lint-skip-ws-comments source idx n)]
    (if (>= j n)
      j
      (let
        [c : char (string.string-ref source j)]
        (cond
          [(or (= c '(') (= c '['))
            (selfhost-lint-skip-source-group source j n)]
          [(= c '"') (selfhost-lint-skip-string source j n)]
          [(= c '\'') (selfhost-lint-skip-apostrophe-char-literal source j n)]
          [else (selfhost-lint-skip-atom source j n)])))))

(define (selfhost-lint-begin-source-form-count
  [source : String]
  [span : AstSourceSpan]) : i64
  (let
    [start : i64 (selfhost-lint-span-start-index source span)]
    [n : i64 (string.string-length source)]
    [needle : String "(begin"]
    [needle-len : i64 (string.string-length needle)]
    (if (and
      (selfhost-lint-prefix-at? source start needle)
      (selfhost-lint-form-delim? source (+ start needle-len)))
      (let
        [idx : i64 (+ start needle-len)]
        [count : i64 0]
        [done : bool false]
        (begin
          (while (and (< idx n) (not done))
            (begin
              (set! idx (selfhost-lint-skip-ws-comments source idx n))
              (if (>= idx n)
                (set! done true)
                (let
                  [c : char (string.string-ref source idx)]
                  (if (or (= c ')') (= c ']'))
                    (set! done true)
                    (begin
                      (set! count (+ count 1))
                      (set! idx (selfhost-lint-skip-source-form source idx n))))))))
          count))
      1)))

;; True when line `line` (1-based) of `source` contains a `lint-allow: <rule-id>`
;; directive (as in `;; lint-allow: nested-if-ladder`). Scans the single line and
;; stops at its newline; `and`/`or` are not short-circuiting, so the `string.string-ref`
;; is guarded by the loop's `stop` flag rather than the bounds test.
(define (selfhost-lint-line-allows?
  [source : String]
  [line : i64]
  [rule-id : String]) : bool
  (let
    [needle : String (string.append "lint-allow: " rule-id)]
    [source-len : i64 (string.string-length source)]
    [line-start : i64 (selfhost-lint-line-start-index source line)]
    [found : bool false]
    [idx : i64 line-start]
    [stop : bool false]
    (begin
      (while (and (< idx source-len) (not stop))
        (if (= (string.string-ref source idx) '\n')
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
        [needle : String (string.append "(" form-name)]
        [line-start : i64 (selfhost-lint-line-start-index source line)]
        [idx : i64 (+ line-start (- col 1))]
        (and
          (selfhost-lint-prefix-at? source idx needle)
          (selfhost-lint-form-delim?
            source
            (+ idx (string.string-length needle))))))))

(define (selfhost-lint-derived-form-origin?
  [source : String]
  [span : AstSourceSpan]) : bool
  (or
    (selfhost-lint-form-origin? source span "cond")
    (selfhost-lint-form-origin? source span "when")
    (selfhost-lint-form-origin? source span "unless")))

(define (selfhost-lint-source-multiform-single-begin?
  [source : String]
  [finding : LintFinding]) : bool
  (and
    (string.eq (struct-get finding rule-id) (lint-rule-single-begin-id))
    (>
      (selfhost-lint-begin-source-form-count source (struct-get finding span))
      1)))

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
          (selfhost-lint-source-multiform-single-begin? source finding)
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
  [deprecated-string-concat : bool]
  [redundant-function-name : bool]) : LintFindings
  (match program
    [(AstProgram.Program decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        [base : LintFindings
          (if deprecated-string-concat
            (lint-program-with-deprecated-string-concat
              source
              (ast-program decls)
              (lint-default-ladder-threshold))
            (lint-program-with-source
              source
              (ast-program decls)
              (lint-default-ladder-threshold)))]
        (selfhost-lint-filter-derived-origins
          source
          (if redundant-function-name
            (lint-redundant-function-names-in-program
              source
              (ast-program decls)
              base)
            base)))]))

(define (selfhost-lint-program-findings
  [source : String]
  [program : AstProgram]) : LintFindings
  (selfhost-lint-program-findings-with-options source program false false))

(define (selfhost-lint-findings-append-from
  [src : LintFindings]
  [index : i64]
  [out : LintFindings]) : LintFindings
  (if (>= index (lint-findings-count src))
    out
    (selfhost-lint-findings-append-from
      src
      (+ index 1)
      (lint-findings-add (lint-findings-ref src index) out))))

(define (selfhost-lint-findings-append
  [left : LintFindings]
  [right : LintFindings]) : LintFindings
  (selfhost-lint-findings-append-from right 0 left))

(define (selfhost-lint-unused-unsafe-findings-from
  [path : String]
  [index : i64]
  [out : LintFindings]) : LintFindings
  (if (>= index (tc-unused-unsafe-block-count))
    out
    (let
      [next : LintFindings
        (if (and
          (not (tc-unused-unsafe-block-used? index))
          (string.eq (tc-unused-unsafe-block-path index) path))
          (lint-findings-add
            (lint-unused-unsafe-finding (tc-unused-unsafe-block-span index))
            out)
          out)]
      (selfhost-lint-unused-unsafe-findings-from path (+ index 1) next))))

(define (selfhost-lint-unused-unsafe-findings
  [path : String]
  [source : String]
  [program : AstProgram]
  [stdlib-roots : vector.StringVec]) : LintFindings
  (if (lint-program-has-unused-unsafe-candidate? program)
    (begin
      (tc-unused-unsafe-tracking-reset! path)
      (match (compiler-check-source-with-roots path source stdlib-roots)
        [(ResultCompilerCheck.Ok _)
          (let
            [findings : LintFindings
              (selfhost-lint-filter-derived-origins
                source
                (selfhost-lint-unused-unsafe-findings-from
                  path
                  0
                  (lint-findings-empty)))]
            (begin
              (tc-unused-unsafe-tracking-disable!)
              findings))]
        [(ResultCompilerCheck.Err _)
          (begin
            (tc-unused-unsafe-tracking-disable!)
            (lint-findings-empty))]))
    (lint-findings-empty)))

(define (selfhost-lint-program-and-typed-findings
  [path : String]
  [source : String]
  [program : AstProgram]
  [stdlib-roots : vector.StringVec]
  [deprecated-string-concat : bool]
  [redundant-function-name : bool]) : LintFindings
  (selfhost-lint-findings-append
    (selfhost-lint-program-findings-with-options
      source
      program
      deprecated-string-concat
      redundant-function-name)
    (selfhost-lint-unused-unsafe-findings path source program stdlib-roots)))

(define (selfhost-lint-source-with-roots-and-staged-options
  [path : String]
  [source : String]
  [stdlib-roots : vector.StringVec]
  [deprecated-string-concat : bool]
  [redundant-function-name : bool]) : LintFindings
  (match (parse-ast-source-diagnostic path source)
    [(ResultAstProgramDiagnostic.Ok program)
      (selfhost-lint-program-and-typed-findings
        path
        source
        program
        stdlib-roots
        deprecated-string-concat
        redundant-function-name)]
    [(ResultAstProgramDiagnostic.Err _) (lint-findings-empty)]))

(define (selfhost-lint-source-with-roots-and-options
  [path : String]
  [source : String]
  [stdlib-roots : vector.StringVec]
  [deprecated-string-concat : bool]) : LintFindings
  (selfhost-lint-source-with-roots-and-staged-options
    path
    source
    stdlib-roots
    deprecated-string-concat
    false))

;; Parse `source` (attributed to `path`) and run the lint rules over this source
;; unit only. Imports are linted when their own files are selected by the repo
;; lint gate, so a public driver does not duplicate every imported finding.
(define (selfhost-lint-source-with-roots
  [path : String]
  [source : String]
  [stdlib-roots : vector.StringVec]) : LintFindings
  (selfhost-lint-source-with-roots-and-options path source stdlib-roots false))

;; Package-level dead-code linting records top-level declarations as graph nodes.
;; Library packages expose every top-level declaration as API roots. Binary
;; packages report declarations unreachable from entry/test/generated roots.
(defstruct SelfhostLintDeadDecl
  (path String)
  (name String)
  (span AstSourceSpan)
  (refs vector.StringVec)
  (root bool)
  (reportable bool))

(defstruct SelfhostLintDeadDecls
  (slots (Array SelfhostLintDeadDecl))
  (len i64))

(defstruct SelfhostLintDeadScan
  (decls SelfhostLintDeadDecls)
  (roots vector.StringVec))

(define (selfhost-lint-dead-decls-slots [items : SelfhostLintDeadDecls]) : (Array
    SelfhostLintDeadDecl)
  (struct-get items slots))

(define (selfhost-lint-dead-decls-count [items : SelfhostLintDeadDecls]) : i64
  (struct-get items len))

(define (selfhost-lint-dead-decls-capacity [items : SelfhostLintDeadDecls]) : i64
  (array-length (selfhost-lint-dead-decls-slots items)))

(define (selfhost-lint-dead-decls-with-capacity [capacity : i64]) : SelfhostLintDeadDecls
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (SelfhostLintDeadDecls (make-array SelfhostLintDeadDecl cap) 0)))

(define (selfhost-lint-dead-decls-empty) : SelfhostLintDeadDecls
  (selfhost-lint-dead-decls-with-capacity 8))

(define (selfhost-lint-dead-decls-copy-range
  [dst : (Array SelfhostLintDeadDecl)]
  [src : (Array SelfhostLintDeadDecl)]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src index))
      (selfhost-lint-dead-decls-copy-range dst src (+ index 1) count))))

(define (selfhost-lint-dead-decls-grow [items : SelfhostLintDeadDecls]) : SelfhostLintDeadDecls
  (let
    [n : i64 (selfhost-lint-dead-decls-count items)]
    [bigger : (Array SelfhostLintDeadDecl)
      (make-array
        SelfhostLintDeadDecl
        (* (selfhost-lint-dead-decls-capacity items) 2))]
    (begin
      (selfhost-lint-dead-decls-copy-range
        bigger
        (selfhost-lint-dead-decls-slots items)
        0
        n)
      (SelfhostLintDeadDecls bigger n))))

(define (selfhost-lint-dead-decls-add
  [decl : SelfhostLintDeadDecl]
  [items : SelfhostLintDeadDecls]) : SelfhostLintDeadDecls
  (if (<
    (selfhost-lint-dead-decls-count items)
    (selfhost-lint-dead-decls-capacity items))
    (let
      [slots : (Array SelfhostLintDeadDecl)
        (selfhost-lint-dead-decls-slots items)]
      [n : i64 (selfhost-lint-dead-decls-count items)]
      (begin
        (array-set! slots n decl)
        (SelfhostLintDeadDecls slots (+ n 1))))
    (selfhost-lint-dead-decls-add decl (selfhost-lint-dead-decls-grow items))))

(define (selfhost-lint-dead-decls-ref
  [items : SelfhostLintDeadDecls]
  [index : i64]) : SelfhostLintDeadDecl
  (array-ref (selfhost-lint-dead-decls-slots items) index))

(define (selfhost-lint-dead-decls-set
  [items : SelfhostLintDeadDecls]
  [index : i64]
  [decl : SelfhostLintDeadDecl]) : SelfhostLintDeadDecls
  (begin
    (array-set! (selfhost-lint-dead-decls-slots items) index decl)
    items))

(define (selfhost-lint-dead-root-add [roots : vector.StringVec] [name : String]) : vector.StringVec
  (if (vector.string-vec-contains? roots name)
    roots
    (vector.string-vec-push roots name)))

(define (selfhost-lint-dead-scan-add-decl
  [scan : SelfhostLintDeadScan]
  [decl : SelfhostLintDeadDecl]) : SelfhostLintDeadScan
  (SelfhostLintDeadScan
    (selfhost-lint-dead-decls-add decl (struct-get scan decls))
    (struct-get scan roots)))

(define (selfhost-lint-dead-scan-add-root
  [scan : SelfhostLintDeadScan]
  [name : String]) : SelfhostLintDeadScan
  (SelfhostLintDeadScan
    (struct-get scan decls)
    (selfhost-lint-dead-root-add (struct-get scan roots) name)))

(define (selfhost-lint-dead-ref-add [refs : vector.StringVec] [name : String]) : vector.StringVec
  (if (vector.string-vec-contains? refs name)
    refs
    (vector.string-vec-push refs name)))

(define (selfhost-lint-dead-ref-add-id [refs : vector.StringVec] [name : i64]) : vector.StringVec
  (selfhost-lint-dead-ref-add refs (intern-str name)))

(define (selfhost-lint-dead-maybe-type-refs
  [maybe-ty : AstMaybeType]
  [refs : vector.StringVec]) : vector.StringVec
  (match maybe-ty
    [(AstMaybeType.No) refs]
    [(AstMaybeType.Some ty) (selfhost-lint-dead-type-refs ty refs)]))

(define (selfhost-lint-dead-type-list-refs
  [types : AstTypeList]
  [refs : vector.StringVec]) : vector.StringVec
  (match types
    [(AstTypeList.Nil) refs]
    [(AstTypeList.Cons head rest)
      (selfhost-lint-dead-type-list-refs
        (box-get rest)
        (selfhost-lint-dead-type-refs (ty-node-get head) refs))]))

(define (selfhost-lint-dead-type-id-refs [ty : i64] [refs : vector.StringVec]) : vector.StringVec
  (selfhost-lint-dead-type-refs (ty-node-get ty) refs))

(define (selfhost-lint-dead-type-refs [ty : AstType] [refs : vector.StringVec]) : vector.StringVec
  (match ty
    [(AstType.I64) refs]
    [(AstType.I32) refs]
    [(AstType.I16) refs]
    [(AstType.I8) refs]
    [(AstType.U64) refs]
    [(AstType.U32) refs]
    [(AstType.U16) refs]
    [(AstType.U8) refs]
    [(AstType.F64) refs]
    [(AstType.F32) refs]
    [(AstType.Bool) refs]
    [(AstType.Char) refs]
    [(AstType.String) refs]
    [(AstType.Str) refs]
    [(AstType.Bytes) refs]
    [(AstType.Unit) refs]
    [(AstType.Never) refs]
    [(AstType.Expr) refs]
    [(AstType.ExprList) refs]
    [(AstType.Func args ret)
      (selfhost-lint-dead-type-id-refs
        ret
        (selfhost-lint-dead-type-list-refs (box-get args) refs))]
    [(AstType.Tuple items)
      (selfhost-lint-dead-type-list-refs (box-get items) refs)]
    [(AstType.Array elem _) (selfhost-lint-dead-type-id-refs elem refs)]
    [(AstType.DynArray elem) (selfhost-lint-dead-type-id-refs elem refs)]
    [(AstType.Box elem) (selfhost-lint-dead-type-id-refs elem refs)]
    [(AstType.Region _ inner) (selfhost-lint-dead-type-id-refs inner refs)]
    [(AstType.Ref _ inner) (selfhost-lint-dead-type-id-refs inner refs)]
    [(AstType.MutRef _ inner) (selfhost-lint-dead-type-id-refs inner refs)]
    [(AstType.Enum name) (selfhost-lint-dead-ref-add-id refs name)]
    [(AstType.EnumArgs name _) (selfhost-lint-dead-ref-add-id refs name)]
    [(AstType.Struct name) (selfhost-lint-dead-ref-add-id refs name)]
    [(AstType.StructArgs name _) (selfhost-lint-dead-ref-add-id refs name)]
    [(AstType.Var name) (selfhost-lint-dead-ref-add-id refs name)]
    [(AstType.VarArgs name _) (selfhost-lint-dead-ref-add-id refs name)]
    [(AstType.Ptr inner) (selfhost-lint-dead-type-id-refs inner refs)]
    [(AstType.MutPtr inner) (selfhost-lint-dead-type-id-refs inner refs)]))

(define (selfhost-lint-dead-param-list-refs
  [params : AstParamList]
  [refs : vector.StringVec]) : vector.StringVec
  (match params
    [(AstParamList.Nil) refs]
    [(AstParamList.Cons param rest)
      (match param
        [(AstParam.Param _ ty _)
          (selfhost-lint-dead-param-list-refs
            (box-get rest)
            (selfhost-lint-dead-type-refs ty refs))])]))

(define (selfhost-lint-dead-macro-param-list-refs
  [params : AstMacroParamList]
  [refs : vector.StringVec]) : vector.StringVec
  (match params
    [(AstMacroParamList.Nil) refs]
    [(AstMacroParamList.Cons param rest)
      (match param
        [(AstMacroParam.Param _ ty _)
          (selfhost-lint-dead-macro-param-list-refs
            (box-get rest)
            (selfhost-lint-dead-type-refs ty refs))])]))

(define (selfhost-lint-dead-pattern-list-refs
  [patterns : AstPatternList]
  [refs : vector.StringVec]) : vector.StringVec
  (match patterns
    [(AstPatternList.Nil) refs]
    [(AstPatternList.Cons head rest)
      (selfhost-lint-dead-pattern-list-refs
        (box-get rest)
        (selfhost-lint-dead-pattern-refs (box-get head) refs))]))

(define (selfhost-lint-dead-pattern-refs
  [pattern : AstPattern]
  [refs : vector.StringVec]) : vector.StringVec
  (match pattern
    [(AstPattern.Var _ maybe-ty)
      (selfhost-lint-dead-maybe-type-refs maybe-ty refs)]
    [(AstPattern.Tuple items)
      (selfhost-lint-dead-pattern-list-refs (box-get items) refs)]
    [(AstPattern.Wildcard) refs]
    [(AstPattern.Binding _) refs]
    [(AstPattern.Variant name items)
      (selfhost-lint-dead-pattern-list-refs
        (box-get items)
        (selfhost-lint-dead-ref-add-id refs name))]
    [(AstPattern.Literal _) refs]))

(define (selfhost-lint-dead-expr-list-refs
  [exprs : AstExprList]
  [refs : vector.StringVec]) : vector.StringVec
  (match exprs
    [(AstExprList.Nil) refs]
    [(AstExprList.Cons head rest)
      (selfhost-lint-dead-expr-list-refs
        (box-get rest)
        (selfhost-lint-dead-expr-refs (ast-node-get head) refs))]))

(define (selfhost-lint-dead-let-binding-refs
  [bindings : AstLetBindingList]
  [refs : vector.StringVec]) : vector.StringVec
  (match bindings
    [(AstLetBindingList.Nil) refs]
    [(AstLetBindingList.Cons binding rest)
      (match binding
        [(AstLetBinding.Binding _ maybe-ty init)
          (selfhost-lint-dead-let-binding-refs
            (box-get rest)
            (selfhost-lint-dead-expr-refs
              (ast-node-get init)
              (selfhost-lint-dead-maybe-type-refs maybe-ty refs)))])]))

(define (selfhost-lint-dead-match-arm-refs
  [arms : AstMatchArmList]
  [refs : vector.StringVec]) : vector.StringVec
  (match arms
    [(AstMatchArmList.Nil) refs]
    [(AstMatchArmList.Cons arm rest)
      (match arm
        [(AstMatchArm.Arm pattern body)
          (selfhost-lint-dead-match-arm-refs
            (box-get rest)
            (selfhost-lint-dead-expr-refs
              (ast-node-get body)
              (selfhost-lint-dead-pattern-refs pattern refs)))])]))

(define (selfhost-lint-dead-resource-binding-refs
  [bindings : AstResourceBindingList]
  [refs : vector.StringVec]) : vector.StringVec
  (match bindings
    [(AstResourceBindingList.Nil) refs]
    [(AstResourceBindingList.Cons binding rest)
      (match binding
        [(AstResourceBinding.Binding _ init cleanup)
          (selfhost-lint-dead-resource-binding-refs
            (box-get rest)
            (selfhost-lint-dead-expr-refs
              (ast-node-get cleanup)
              (selfhost-lint-dead-expr-refs (ast-node-get init) refs)))])]))

(define (selfhost-lint-dead-expr-refs
  [expr : AstExpr]
  [refs : vector.StringVec]) : vector.StringVec
  (match expr
    [(AstExpr.Spanned inner-box _)
      (selfhost-lint-dead-expr-refs (ast-node-get inner-box) refs)]
    [(AstExpr.Literal _) refs]
    [(AstExpr.Var name) (selfhost-lint-dead-ref-add-id refs name)]
    [(AstExpr.Binary _ left right)
      (selfhost-lint-dead-expr-refs
        (ast-node-get right)
        (selfhost-lint-dead-expr-refs (ast-node-get left) refs))]
    [(AstExpr.Unary _ inner)
      (selfhost-lint-dead-expr-refs (ast-node-get inner) refs)]
    [(AstExpr.Call func args)
      (selfhost-lint-dead-expr-list-refs
        args
        (selfhost-lint-dead-expr-refs (ast-node-get func) refs))]
    [(AstExpr.If cond then-branch else-branch)
      (selfhost-lint-dead-expr-refs
        (ast-node-get else-branch)
        (selfhost-lint-dead-expr-refs
          (ast-node-get then-branch)
          (selfhost-lint-dead-expr-refs (ast-node-get cond) refs)))]
    [(AstExpr.Let let-box)
      (match (box-get let-box)
        [(AstLet.Let bindings body)
          (selfhost-lint-dead-expr-refs
            (ast-node-get body)
            (selfhost-lint-dead-let-binding-refs bindings refs))])]
    [(AstExpr.Lambda lambda-box)
      (match (box-get lambda-box)
        [(AstLambda.Lambda params ret body)
          (selfhost-lint-dead-expr-refs
            (ast-node-get body)
            (selfhost-lint-dead-maybe-type-refs
              ret
              (selfhost-lint-dead-param-list-refs params refs)))])]
    [(AstExpr.Tuple exprs) (selfhost-lint-dead-expr-list-refs exprs refs)]
    [(AstExpr.TupleRef tuple _)
      (selfhost-lint-dead-expr-refs (ast-node-get tuple) refs)]
    [(AstExpr.Array exprs) (selfhost-lint-dead-expr-list-refs exprs refs)]
    [(AstExpr.MakeArray elem len)
      (selfhost-lint-dead-expr-refs
        (ast-node-get len)
        (selfhost-lint-dead-type-refs elem refs))]
    [(AstExpr.ArrayRef array index)
      (selfhost-lint-dead-expr-refs
        (ast-node-get index)
        (selfhost-lint-dead-expr-refs (ast-node-get array) refs))]
    [(AstExpr.ArraySet array index value)
      (selfhost-lint-dead-expr-refs
        (ast-node-get value)
        (selfhost-lint-dead-expr-refs
          (ast-node-get index)
          (selfhost-lint-dead-expr-refs (ast-node-get array) refs)))]
    [(AstExpr.ArrayPush array value)
      (selfhost-lint-dead-expr-refs
        (ast-node-get value)
        (selfhost-lint-dead-expr-refs (ast-node-get array) refs))]
    [(AstExpr.StringRef text index)
      (selfhost-lint-dead-expr-refs
        (ast-node-get index)
        (selfhost-lint-dead-expr-refs (ast-node-get text) refs))]
    [(AstExpr.While cond body)
      (selfhost-lint-dead-expr-refs
        (ast-node-get body)
        (selfhost-lint-dead-expr-refs (ast-node-get cond) refs))]
    [(AstExpr.Begin exprs) (selfhost-lint-dead-expr-list-refs exprs refs)]
    [(AstExpr.Unsafe exprs) (selfhost-lint-dead-expr-list-refs exprs refs)]
    [(AstExpr.Set target value)
      (selfhost-lint-dead-expr-refs
        (ast-node-get value)
        (selfhost-lint-dead-ref-add-id refs target))]
    [(AstExpr.Ann inner ty)
      (selfhost-lint-dead-type-refs
        ty
        (selfhost-lint-dead-expr-refs (ast-node-get inner) refs))]
    [(AstExpr.Cast inner ty)
      (selfhost-lint-dead-type-refs
        ty
        (selfhost-lint-dead-expr-refs (ast-node-get inner) refs))]
    [(AstExpr.Borrow _ _ place)
      (selfhost-lint-dead-expr-refs (ast-node-get place) refs)]
    [(AstExpr.Match match-box)
      (match (box-get match-box)
        [(AstMatch.Match scrutinee arms)
          (selfhost-lint-dead-match-arm-refs
            arms
            (selfhost-lint-dead-expr-refs (ast-node-get scrutinee) refs))])]
    [(AstExpr.Foreach fe-box)
      (match (box-get fe-box)
        [(AstForeach.Foreach _ index-ty start end body)
          (selfhost-lint-dead-expr-refs
            (ast-node-get body)
            (selfhost-lint-dead-expr-refs
              (ast-node-get end)
              (selfhost-lint-dead-expr-refs
                (ast-node-get start)
                (selfhost-lint-dead-type-refs index-ty refs))))])]
    [(AstExpr.SpmdReduce reduce-box)
      (match (box-get reduce-box)
        [(AstSpmdReduce.Reduce _ _ index-ty start end init value)
          (selfhost-lint-dead-expr-refs
            (ast-node-get value)
            (selfhost-lint-dead-expr-refs
              (ast-node-get init)
              (selfhost-lint-dead-expr-refs
                (ast-node-get end)
                (selfhost-lint-dead-expr-refs
                  (ast-node-get start)
                  (selfhost-lint-dead-type-refs index-ty refs)))))])]
    [(AstExpr.SpmdScan scan-box)
      (match (box-get scan-box)
        [(AstSpmdScan.Scan _ _ index-ty start end _ prefix-ty init value body)
          (selfhost-lint-dead-expr-refs
            (ast-node-get body)
            (selfhost-lint-dead-expr-refs
              (ast-node-get value)
              (selfhost-lint-dead-expr-refs
                (ast-node-get init)
                (selfhost-lint-dead-expr-refs
                  (ast-node-get end)
                  (selfhost-lint-dead-expr-refs
                    (ast-node-get start)
                    (selfhost-lint-dead-type-refs
                      prefix-ty
                      (selfhost-lint-dead-type-refs index-ty refs)))))))])]
    [(AstExpr.SpmdBroadcast value lane)
      (selfhost-lint-dead-expr-refs
        (ast-node-get lane)
        (selfhost-lint-dead-expr-refs (ast-node-get value) refs))]
    [(AstExpr.SpmdShuffle value lane)
      (selfhost-lint-dead-expr-refs
        (ast-node-get lane)
        (selfhost-lint-dead-expr-refs (ast-node-get value) refs))]
    [(AstExpr.StructGet receiver _)
      (selfhost-lint-dead-expr-refs (ast-node-get receiver) refs)]
    [(AstExpr.StructSet receiver _ value)
      (selfhost-lint-dead-expr-refs
        (ast-node-get value)
        (selfhost-lint-dead-expr-refs (ast-node-get receiver) refs))]
    [(AstExpr.WithRegion _ body) (selfhost-lint-dead-expr-list-refs body refs)]
    [(AstExpr.WithEscape scratch body)
      (selfhost-lint-dead-expr-list-refs
        body
        (selfhost-lint-dead-expr-refs (ast-node-get scratch) refs))]
    [(AstExpr.WithScratch body) (selfhost-lint-dead-expr-list-refs body refs)]
    [(AstExpr.InArena arena body)
      (selfhost-lint-dead-expr-list-refs
        body
        (selfhost-lint-dead-expr-refs (ast-node-get arena) refs))]
    [(AstExpr.WithResource wr-box)
      (match (box-get wr-box)
        [(AstWithResource.WithResource bindings body)
          (selfhost-lint-dead-expr-list-refs
            body
            (selfhost-lint-dead-resource-binding-refs bindings refs))])]
    [(AstExpr.Box inner)
      (selfhost-lint-dead-expr-refs (ast-node-get inner) refs)]
    [(AstExpr.BoxGet inner)
      (selfhost-lint-dead-expr-refs (ast-node-get inner) refs)]
    [(AstExpr.BoxTake inner)
      (selfhost-lint-dead-expr-refs (ast-node-get inner) refs)]
    [(AstExpr.BoxSet inner value)
      (selfhost-lint-dead-expr-refs
        (ast-node-get value)
        (selfhost-lint-dead-expr-refs (ast-node-get inner) refs))]
    [(AstExpr.TypeLiteral ty) (selfhost-lint-dead-type-refs ty refs)]
    [(AstExpr.Init maybe-ty) (selfhost-lint-dead-maybe-type-refs maybe-ty refs)]
    [(AstExpr.Comptime inner)
      (selfhost-lint-dead-expr-refs (ast-node-get inner) refs)]
    [(AstExpr.Quote inner)
      (selfhost-lint-dead-expr-refs (ast-node-get inner) refs)]
    [(AstExpr.Quasiquote inner)
      (selfhost-lint-dead-expr-refs (ast-node-get inner) refs)]
    [(AstExpr.Unquote inner)
      (selfhost-lint-dead-expr-refs (ast-node-get inner) refs)]
    [(AstExpr.UnquoteSplicing inner)
      (selfhost-lint-dead-expr-refs (ast-node-get inner) refs)]
    [(AstExpr.BracketClause items)
      (selfhost-lint-dead-expr-list-refs items refs)]
    [(AstExpr.Try inner)
      (selfhost-lint-dead-expr-refs (ast-node-get inner) refs)]
    [(AstExpr.Return inner)
      (selfhost-lint-dead-expr-refs (ast-node-get inner) refs)]
    [(AstExpr.PtrNull ty) (selfhost-lint-dead-type-refs ty refs)]
    [(AstExpr.PtrNullCheck inner)
      (selfhost-lint-dead-expr-refs (ast-node-get inner) refs)]
    [(AstExpr.PtrAddrOf place)
      (selfhost-lint-dead-expr-refs (ast-node-get place) refs)]
    [(AstExpr.PtrRead ptr)
      (selfhost-lint-dead-expr-refs (ast-node-get ptr) refs)]
    [(AstExpr.PtrWrite ptr value)
      (selfhost-lint-dead-expr-refs
        (ast-node-get value)
        (selfhost-lint-dead-expr-refs (ast-node-get ptr) refs))]
    [(AstExpr.PtrOffset ptr offset)
      (selfhost-lint-dead-expr-refs
        (ast-node-get offset)
        (selfhost-lint-dead-expr-refs (ast-node-get ptr) refs))]
    [(AstExpr.PtrCast ptr ty)
      (selfhost-lint-dead-type-refs
        ty
        (selfhost-lint-dead-expr-refs (ast-node-get ptr) refs))]
    [(AstExpr.PtrToInt ptr)
      (selfhost-lint-dead-expr-refs (ast-node-get ptr) refs)]
    [(AstExpr.IntToPtr value ty)
      (selfhost-lint-dead-type-refs
        ty
        (selfhost-lint-dead-expr-refs (ast-node-get value) refs))]
    [(AstExpr.StringData inner)
      (selfhost-lint-dead-expr-refs (ast-node-get inner) refs)]
    [(AstExpr.StringFromBytes ptr len)
      (selfhost-lint-dead-expr-refs
        (ast-node-get len)
        (selfhost-lint-dead-expr-refs (ast-node-get ptr) refs))]
    [(AstExpr.ArrayData inner)
      (selfhost-lint-dead-expr-refs (ast-node-get inner) refs)]
    [(AstExpr.BinaryData _) refs]
    [(AstExpr.SpmdProgramIndex) refs]
    [(AstExpr.SpmdProgramCount) refs]
    [(AstExpr.ProgramArgc) refs]
    [(AstExpr.ProgramArgv) refs]
    [(AstExpr.ProgramEnvp) refs]
    [(AstExpr.CpuIdEax leaf subleaf)
      (selfhost-lint-dead-expr-refs
        (ast-node-get subleaf)
        (selfhost-lint-dead-expr-refs (ast-node-get leaf) refs))]
    [(AstExpr.CpuIdEbx leaf subleaf)
      (selfhost-lint-dead-expr-refs
        (ast-node-get subleaf)
        (selfhost-lint-dead-expr-refs (ast-node-get leaf) refs))]
    [(AstExpr.CpuIdEcx leaf subleaf)
      (selfhost-lint-dead-expr-refs
        (ast-node-get subleaf)
        (selfhost-lint-dead-expr-refs (ast-node-get leaf) refs))]
    [(AstExpr.CpuIdEdx leaf subleaf)
      (selfhost-lint-dead-expr-refs
        (ast-node-get subleaf)
        (selfhost-lint-dead-expr-refs (ast-node-get leaf) refs))]
    [(AstExpr.Xgetbv index)
      (selfhost-lint-dead-expr-refs (ast-node-get index) refs)]
    [(AstExpr.Syscall args) (selfhost-lint-dead-expr-list-refs args refs)]))

(define (selfhost-lint-dead-expr-span [expr-id : i64]) : AstSourceSpan
  (match (ast-node-get expr-id)
    [(AstExpr.Spanned _ span) span]
    [_ (lint-no-span)]))

(define (selfhost-lint-dead-find-prefix-from
  [source : String]
  [needle : String]
  [idx : i64]) : i64
  (let
    [source-len : i64 (string.string-length source)]
    [found : i64 (- 0 1)]
    [i : i64 idx]
    (begin
      (while (and (< found 0) (< i source-len))
        (if (selfhost-lint-prefix-at? source i needle)
          (set! found i)
          (set! i (+ i 1))))
      found)))

(define (selfhost-lint-dead-index-line [source : String] [target : i64]) : i64
  (let
    [i : i64 0]
    [line : i64 1]
    (begin
      (while (< i target)
        (begin
          (if (= (string.string-ref source i) '\n')
            (set! line (+ line 1))
            unit)
          (set! i (+ i 1))))
      line)))

(define (selfhost-lint-dead-index-col [source : String] [target : i64]) : i64
  (let
    [i : i64 0]
    [col : i64 1]
    (begin
      (while (< i target)
        (begin
          (if (= (string.string-ref source i) '\n')
            (set! col 1)
            (set! col (+ col 1)))
          (set! i (+ i 1))))
      col)))

(define (selfhost-lint-dead-index-span
  [source : String]
  [idx : i64]
  [fallback : AstSourceSpan]) : AstSourceSpan
  (if (< idx 0)
    fallback
    (let
      [line : i64 (selfhost-lint-dead-index-line source idx)]
      [col : i64 (selfhost-lint-dead-index-col source idx)]
      (AstSourceSpan line col line (+ col 1)))))

(define (selfhost-lint-dead-decl-span
  [source : String]
  [name : String]
  [body-span : AstSourceSpan]) : AstSourceSpan
  (let
    [fn-needle : String (string.append "(define (" name)]
    [fn-idx : i64 (selfhost-lint-dead-find-prefix-from source fn-needle 0)]
    (if (>= fn-idx 0)
      (selfhost-lint-dead-index-span source fn-idx body-span)
      (selfhost-lint-dead-index-span
        source
        (selfhost-lint-dead-find-prefix-from
          source
          (string.append "(define " name)
          0)
        body-span))))

(define (selfhost-lint-dead-refs-to-roots-from
  [scan : SelfhostLintDeadScan]
  [refs : vector.StringVec]
  [index : i64]) : SelfhostLintDeadScan
  (if (>= index (vector.string-vec-len refs))
    scan
    (selfhost-lint-dead-refs-to-roots-from
      (selfhost-lint-dead-scan-add-root
        scan
        (vector.string-vec-get refs index ""))
      refs
      (+ index 1))))

(define (selfhost-lint-dead-refs-to-roots
  [scan : SelfhostLintDeadScan]
  [refs : vector.StringVec]) : SelfhostLintDeadScan
  (selfhost-lint-dead-refs-to-roots-from scan refs 0))

(define (selfhost-lint-dead-field-cleanup-refs
  [cleanup : AstFieldCleanup]
  [refs : vector.StringVec]) : vector.StringVec
  (match cleanup
    [(AstFieldCleanup.No) refs]
    [(AstFieldCleanup.Fn name) (selfhost-lint-dead-ref-add-id refs name)]
    [(AstFieldCleanup.Owned) refs]))

(define (selfhost-lint-dead-field-def-list-refs
  [fields : AstFieldDefList]
  [refs : vector.StringVec]) : vector.StringVec
  (match fields
    [(AstFieldDefList.Nil) refs]
    [(AstFieldDefList.Cons field rest)
      (match field
        [(AstFieldDef.Def _ ty cleanup)
          (selfhost-lint-dead-field-def-list-refs
            (box-get rest)
            (selfhost-lint-dead-field-cleanup-refs
              cleanup
              (selfhost-lint-dead-type-refs ty refs)))])]))

(define (selfhost-lint-dead-struct-cleanup-refs
  [cleanup : AstStructCleanup]
  [refs : vector.StringVec]) : vector.StringVec
  (match cleanup
    [(AstStructCleanup.No) refs]
    [(AstStructCleanup.Fn name) (selfhost-lint-dead-ref-add-id refs name)]))

(define (selfhost-lint-dead-enum-cleanup-refs
  [cleanup : AstEnumCleanup]
  [refs : vector.StringVec]) : vector.StringVec
  (match cleanup
    [(AstEnumCleanup.No) refs]
    [(AstEnumCleanup.Fn name) (selfhost-lint-dead-ref-add-id refs name)]))

(define (selfhost-lint-dead-variant-cleanup-refs
  [cleanup : AstVariantPayloadCleanup]
  [refs : vector.StringVec]) : vector.StringVec
  (match cleanup
    [(AstVariantPayloadCleanup.No) refs]
    [(AstVariantPayloadCleanup.Fn name)
      (selfhost-lint-dead-ref-add-id refs name)]
    [(AstVariantPayloadCleanup.Owned) refs]))

(define (selfhost-lint-dead-variant-cleanup-list-refs
  [items : AstVariantPayloadCleanupList]
  [refs : vector.StringVec]) : vector.StringVec
  (match items
    [(AstVariantPayloadCleanupList.Nil) refs]
    [(AstVariantPayloadCleanupList.Cons cleanup rest)
      (selfhost-lint-dead-variant-cleanup-list-refs
        (box-get rest)
        (selfhost-lint-dead-variant-cleanup-refs cleanup refs))]))

(define (selfhost-lint-dead-variant-def-list-refs
  [variants : AstVariantDefList]
  [refs : vector.StringVec]) : vector.StringVec
  (match variants
    [(AstVariantDefList.Nil) refs]
    [(AstVariantDefList.Cons variant rest)
      (match variant
        [(AstVariantDef.Def name payloads cleanups)
          (selfhost-lint-dead-variant-def-list-refs
            (box-get rest)
            (selfhost-lint-dead-variant-cleanup-list-refs
              cleanups
              (selfhost-lint-dead-type-list-refs
                payloads
                (selfhost-lint-dead-ref-add-id refs name))))])]))

(define (selfhost-lint-dead-dispatch-variant-list-refs-from
  [variants : (& variants AstDispatchVariantList)]
  [index : i64]
  [refs : vector.StringVec]) : vector.StringVec
  (if (>= index (ast-dispatch-variant-list-len variants))
    refs
    (match (ast-dispatch-variant-list-get
      variants
      index
      (ast-dispatch-variant-fallback))
      [(AstDispatchVariant.Variant _ name)
        (selfhost-lint-dead-dispatch-variant-list-refs-from
          variants
          (+ index 1)
          (selfhost-lint-dead-ref-add refs name))])))

(define (selfhost-lint-dead-dispatch-variant-list-refs
  [variants : AstDispatchVariantList]
  [refs : vector.StringVec]) : vector.StringVec
  (selfhost-lint-dead-dispatch-variant-list-refs-from (& variants) 0 refs))

(define (selfhost-lint-dead-extern-abi-refs
  [abi : AstExternAbi]
  [refs : vector.StringVec]) : vector.StringVec
  (match abi
    [(AstExternAbi.C) refs]
    [(AstExternAbi.CVarargsOpen) refs]
    [(AstExternAbi.CVarargsTyped tail-ty)
      (selfhost-lint-dead-type-refs tail-ty refs)]))

(define (selfhost-lint-dead-extern-metadata-refs
  [meta : AstExternMetadata]
  [refs : vector.StringVec]) : vector.StringVec
  (match meta
    [(AstExternMetadata.Metadata abi _ _ _)
      (selfhost-lint-dead-extern-abi-refs abi refs)]))

(define (selfhost-lint-dead-generated-meta-refs
  [meta : AstGeneratedDeclMeta]
  [refs : vector.StringVec]) : vector.StringVec
  (match meta
    [(AstGeneratedDeclMeta.No) refs]
    [(AstGeneratedDeclMeta.Some _ _ args _)
      (selfhost-lint-dead-expr-list-refs args refs)]))

(define (selfhost-lint-dead-add-node
  [scan : SelfhostLintDeadScan]
  [path : String]
  [name : String]
  [span : AstSourceSpan]
  [refs : vector.StringVec]
  [reportable : bool]) : SelfhostLintDeadScan
  (selfhost-lint-dead-scan-add-decl
    scan
    (SelfhostLintDeadDecl path name span refs false reportable)))

(define (selfhost-lint-dead-add-visible-node
  [scan : SelfhostLintDeadScan]
  [path : String]
  [name : String]
  [span : AstSourceSpan]
  [refs : vector.StringVec]
  [root : bool]
  [reportable : bool]) : SelfhostLintDeadScan
  (let
    [with-node : SelfhostLintDeadScan
      (selfhost-lint-dead-add-node scan path name span refs reportable)]
    (if root
      (selfhost-lint-dead-scan-add-root with-node name)
      with-node)))

(define (selfhost-lint-dead-scan-decl
  [scan : SelfhostLintDeadScan]
  [path : String]
  [source : String]
  [decl : AstDecl]
  [visible-root : bool]
  [allow-report : bool]) : SelfhostLintDeadScan
  (match decl
    [(AstDecl.ModuleBody _ body-box)
      (selfhost-lint-dead-scan-decls
        scan
        path
        source
        visible-root
        allow-report
        (box-get body-box))]
    [(AstDecl.Module _) scan]
    [(AstDecl.Def name maybe-ty body)
      (let
        [text : String (intern-str name)]
        [refs : vector.StringVec
          (selfhost-lint-dead-expr-refs
            (ast-node-get body)
            (selfhost-lint-dead-maybe-type-refs
              maybe-ty
              (vector.string-vec-new)))]
        [span : AstSourceSpan
          (selfhost-lint-dead-decl-span
            source
            text
            (selfhost-lint-dead-expr-span body))]
        (selfhost-lint-dead-add-visible-node
          scan
          path
          text
          span
          refs
          visible-root
          allow-report))]
    [(AstDecl.DefFn name params ret body _)
      (let
        [text : String (intern-str name)]
        [refs : vector.StringVec
          (selfhost-lint-dead-expr-refs
            (ast-node-get body)
            (selfhost-lint-dead-type-refs
              ret
              (selfhost-lint-dead-param-list-refs
                params
                (vector.string-vec-new))))]
        [span : AstSourceSpan
          (selfhost-lint-dead-decl-span
            source
            text
            (selfhost-lint-dead-expr-span body))]
        (selfhost-lint-dead-add-visible-node
          scan
          path
          text
          span
          refs
          visible-root
          allow-report))]
    [(AstDecl.DefMacro name params ret body)
      (selfhost-lint-dead-add-visible-node
        scan
        path
        (intern-str name)
        (selfhost-lint-dead-expr-span body)
        (selfhost-lint-dead-expr-refs
          (ast-node-get body)
          (selfhost-lint-dead-type-refs
            ret
            (selfhost-lint-dead-macro-param-list-refs
              params
              (vector.string-vec-new))))
        visible-root
        allow-report)]
    [(AstDecl.Extern name _ meta ty)
      (selfhost-lint-dead-add-visible-node
        scan
        path
        (intern-str name)
        (lint-no-span)
        (selfhost-lint-dead-type-refs
          ty
          (selfhost-lint-dead-extern-metadata-refs meta (vector.string-vec-new)))
        visible-root
        allow-report)]
    [(AstDecl.DefEnum name cleanup variants)
      (selfhost-lint-dead-add-visible-node
        scan
        path
        (intern-str name)
        (lint-no-span)
        (selfhost-lint-dead-variant-def-list-refs
          variants
          (selfhost-lint-dead-enum-cleanup-refs cleanup (vector.string-vec-new)))
        visible-root
        allow-report)]
    [(AstDecl.DefEnumLifetimes name _ cleanup variants)
      (selfhost-lint-dead-add-visible-node
        scan
        path
        (intern-str name)
        (lint-no-span)
        (selfhost-lint-dead-variant-def-list-refs
          variants
          (selfhost-lint-dead-enum-cleanup-refs cleanup (vector.string-vec-new)))
        visible-root
        allow-report)]
    [(AstDecl.DefStruct name _ cleanup fields)
      (selfhost-lint-dead-add-visible-node
        scan
        path
        (intern-str name)
        (lint-no-span)
        (selfhost-lint-dead-field-def-list-refs
          fields
          (selfhost-lint-dead-struct-cleanup-refs
            cleanup
            (vector.string-vec-new)))
        visible-root
        allow-report)]
    [(AstDecl.DefStructLifetimes name _ _ cleanup fields)
      (selfhost-lint-dead-add-visible-node
        scan
        path
        (intern-str name)
        (lint-no-span)
        (selfhost-lint-dead-field-def-list-refs
          fields
          (selfhost-lint-dead-struct-cleanup-refs
            cleanup
            (vector.string-vec-new)))
        visible-root
        allow-report)]
    [(AstDecl.Import
        (AstImportSpec.Spec (AstImportKind.Macro call-expr _) _ _ _ _))
      (selfhost-lint-dead-refs-to-roots
        scan
        (selfhost-lint-dead-expr-refs
          (ast-node-get call-expr)
          (vector.string-vec-new)))]
    [(AstDecl.Import
        (AstImportSpec.Spec (AstImportKind.MacroDecls call-expr _) _ _ _ _))
      (selfhost-lint-dead-refs-to-roots
        scan
        (selfhost-lint-dead-expr-refs
          (ast-node-get call-expr)
          (vector.string-vec-new)))]
    [(AstDecl.Import _) scan]
    [(AstDecl.IncludeStr _ _) scan]
    [(AstDecl.IncludeBin _ _) scan]
    [(AstDecl.DefDispatch name variants)
      (selfhost-lint-dead-add-visible-node
        scan
        path
        (intern-str name)
        (lint-no-span)
        (selfhost-lint-dead-dispatch-variant-list-refs
          variants
          (vector.string-vec-new))
        visible-root
        allow-report)]
    [(AstDecl.Test _ body _)
      (selfhost-lint-dead-refs-to-roots
        scan
        (selfhost-lint-dead-expr-refs
          (ast-node-get body)
          (vector.string-vec-new)))]
    [(AstDecl.Unsafe inner)
      (selfhost-lint-dead-scan-decl
        scan
        path
        source
        (box-get inner)
        visible-root
        allow-report)]
    [(AstDecl.ComptimeDecl meta inner)
      (selfhost-lint-dead-refs-to-roots
        (selfhost-lint-dead-scan-decl
          scan
          path
          source
          (box-get inner)
          visible-root
          false)
        (selfhost-lint-dead-generated-meta-refs meta (vector.string-vec-new)))]))

(define (selfhost-lint-dead-scan-decls
  [scan : SelfhostLintDeadScan]
  [path : String]
  [source : String]
  [visible-root : bool]
  [reportable : bool]
  [decls : AstDeclList]) : SelfhostLintDeadScan
  (match decls
    [(AstDeclList.Nil) scan]
    [(AstDeclList.Cons decl rest)
      (selfhost-lint-dead-scan-decls
        (selfhost-lint-dead-scan-decl
          scan
          path
          source
          decl
          visible-root
          reportable)
        path
        source
        visible-root
        reportable
        (box-get rest))]))

(define (selfhost-lint-dead-scan-source
  [scan : SelfhostLintDeadScan]
  [path : String]
  [source : String]
  [visible-root : bool]
  [reportable : bool]) : SelfhostLintDeadScan
  (match (parse-ast-source-diagnostic path source)
    [(ResultAstProgramDiagnostic.Ok program)
      (match program
        [(AstProgram.Program decls-box)
          (selfhost-lint-dead-scan-decls
            scan
            path
            source
            visible-root
            reportable
            (box-get decls-box))])]
    [(ResultAstProgramDiagnostic.Err _) scan]))

(define (selfhost-lint-package-dead-scan-files
  [sources : PackageSourceList]
  [index : i64]
  [visible-root : bool]
  [reportable : bool]
  [scan : SelfhostLintDeadScan]) : SelfhostLintDeadScan
  (if (>= index (package-source-list-len sources))
    scan
    (let
      [path : String (package-source-list-get sources index "")]
      (selfhost-lint-package-dead-scan-files
        sources
        (+ index 1)
        visible-root
        reportable
        (selfhost-lint-dead-scan-source
          scan
          path
          (io.read-file path)
          visible-root
          reportable)))))

(define (selfhost-lint-dead-decls-index-of-from
  [items : SelfhostLintDeadDecls]
  [name : String]
  [index : i64]) : i64
  (if (>= index (selfhost-lint-dead-decls-count items))
    (- 0 1)
    (if (string.eq
      (struct-get (selfhost-lint-dead-decls-ref items index) name)
      name)
      index
      (selfhost-lint-dead-decls-index-of-from items name (+ index 1)))))

(define (selfhost-lint-dead-decls-index-of
  [items : SelfhostLintDeadDecls]
  [name : String]) : i64
  (selfhost-lint-dead-decls-index-of-from items name 0))

(define (selfhost-lint-dead-mark-refs-from
  [items : SelfhostLintDeadDecls]
  [refs : vector.StringVec]
  [index : i64]) : SelfhostLintDeadDecls
  (if (>= index (vector.string-vec-len refs))
    items
    (selfhost-lint-dead-mark-refs-from
      (selfhost-lint-dead-mark-reachable-name
        items
        (vector.string-vec-get refs index ""))
      refs
      (+ index 1))))

(define (selfhost-lint-dead-mark-reachable-index
  [items : SelfhostLintDeadDecls]
  [index : i64]) : SelfhostLintDeadDecls
  (let
    [decl : SelfhostLintDeadDecl (selfhost-lint-dead-decls-ref items index)]
    (if (struct-get decl root)
      items
      (let
        [marked : SelfhostLintDeadDecl
          (SelfhostLintDeadDecl
            (struct-get decl path)
            (struct-get decl name)
            (struct-get decl span)
            (struct-get decl refs)
            true
            (struct-get decl reportable))]
        [updated : SelfhostLintDeadDecls
          (selfhost-lint-dead-decls-set items index marked)]
        (selfhost-lint-dead-mark-refs-from updated (struct-get marked refs) 0)))))

(define (selfhost-lint-dead-mark-reachable-name
  [items : SelfhostLintDeadDecls]
  [name : String]) : SelfhostLintDeadDecls
  (let
    [index : i64 (selfhost-lint-dead-decls-index-of items name)]
    (if (< index 0)
      items
      (selfhost-lint-dead-mark-reachable-index items index))))

(define (selfhost-lint-dead-mark-roots-from
  [items : SelfhostLintDeadDecls]
  [roots : vector.StringVec]
  [index : i64]) : SelfhostLintDeadDecls
  (if (>= index (vector.string-vec-len roots))
    items
    (selfhost-lint-dead-mark-roots-from
      (selfhost-lint-dead-mark-reachable-name
        items
        (vector.string-vec-get roots index ""))
      roots
      (+ index 1))))

(define (selfhost-lint-package-dead-visible-root? [kind : CompilerPkgKind]) : bool
  (match kind
    [(CompilerPkgKindBin) false]
    [(CompilerPkgKindLib) true]))

(define (selfhost-lint-package-dead-reportable? [kind : CompilerPkgKind]) : bool
  (match kind
    [(CompilerPkgKindBin) true]
    [(CompilerPkgKindLib) false]))

(define (selfhost-lint-package-dead-add-kind-roots
  [scan : SelfhostLintDeadScan]
  [kind : CompilerPkgKind]) : SelfhostLintDeadScan
  (match kind
    [(CompilerPkgKindBin) (selfhost-lint-dead-scan-add-root scan "main")]
    [(CompilerPkgKindLib) scan]))

(define (selfhost-lint-package-dead-code
  [sources : PackageSourceList]
  [kind : CompilerPkgKind]) : SelfhostLintDeadDecls
  (let
    [visible-root : bool (selfhost-lint-package-dead-visible-root? kind)]
    [reportable : bool (selfhost-lint-package-dead-reportable? kind)]
    [scan : SelfhostLintDeadScan
      (selfhost-lint-package-dead-add-kind-roots
        (selfhost-lint-package-dead-scan-files
          sources
          0
          visible-root
          reportable
          (SelfhostLintDeadScan
            (selfhost-lint-dead-decls-empty)
            (vector.string-vec-new)))
        kind)]
    (selfhost-lint-dead-mark-roots-from
      (struct-get scan decls)
      (struct-get scan roots)
      0)))

(define (selfhost-lint-package-dead-finding-active?
  [source : String]
  [decl : SelfhostLintDeadDecl]) : bool
  (if (not (struct-get decl reportable))
    false
    (if (struct-get decl root)
      false
      (not
        (selfhost-lint-suppressed?
          source
          (lint-dead-code-finding (struct-get decl name) (struct-get decl span)))))))

(define (selfhost-lint-package-dead-count-for-source-from
  [path : String]
  [source : String]
  [items : SelfhostLintDeadDecls]
  [index : i64]
  [count : i64]) : i64
  (if (>= index (selfhost-lint-dead-decls-count items))
    count
    (let
      [decl : SelfhostLintDeadDecl (selfhost-lint-dead-decls-ref items index)]
      [next-count : i64
        (if (and
          (string.eq (struct-get decl path) path)
          (selfhost-lint-package-dead-finding-active? source decl))
          (+ count 1)
          count)]
      (selfhost-lint-package-dead-count-for-source-from
        path
        source
        items
        (+ index 1)
        next-count))))

(define (selfhost-lint-package-dead-count-for-source
  [path : String]
  [source : String]
  [items : SelfhostLintDeadDecls]) : i64
  (selfhost-lint-package-dead-count-for-source-from path source items 0 0))

(define (selfhost-lint-package-dead-print-for-source-from
  [path : String]
  [source : String]
  [items : SelfhostLintDeadDecls]
  [index : i64]
  [printed : i64]) : i64
  (if (>= index (selfhost-lint-dead-decls-count items))
    printed
    (let
      [decl : SelfhostLintDeadDecl (selfhost-lint-dead-decls-ref items index)]
      [next-printed : i64
        (if (and
          (string.eq (struct-get decl path) path)
          (selfhost-lint-package-dead-finding-active? source decl))
          (begin
            (io.print-string
              (string.append
                (selfhost-lint-render-finding
                  path
                  (lint-dead-code-finding
                    (struct-get decl name)
                    (struct-get decl span)))
                "\n"))
            (+ printed 1))
          printed)]
      (selfhost-lint-package-dead-print-for-source-from
        path
        source
        items
        (+ index 1)
        next-printed))))

(define (selfhost-lint-package-dead-print-for-source
  [path : String]
  [source : String]
  [items : SelfhostLintDeadDecls]) : i64
  (selfhost-lint-package-dead-print-for-source-from path source items 0 0))

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
  [stdlib-roots : vector.StringVec]
  [enforcing : bool]
  [deprecated-string-concat : bool]
  [redundant-function-name : bool]) : i64
  (let
    [source : String (io.read-file input-path)]
    (match (parse-ast-source-diagnostic input-path source)
      [(ResultAstProgramDiagnostic.Ok program)
        (let
          [findings : LintFindings
            (selfhost-lint-program-and-typed-findings
              input-path
              source
              program
              stdlib-roots
              deprecated-string-concat
              redundant-function-name)]
          (begin
            (selfhost-lint-print-findings input-path findings)
            (io.print-string
              (string.append
                "lint: "
                (string.append
                  (string.int->string (lint-findings-count findings))
                  " finding(s)\n")))
            (selfhost-lint-enforce-exit
              enforcing
              (lint-findings-count findings))))]
      [(ResultAstProgramDiagnostic.Err diag)
        (begin
          (io.print-error (compiler-diagnostic-render (box-get diag)))
          1)])))

(define (selfhost-lint-file-with-package-dead
  [input-path : String]
  [stdlib-roots : vector.StringVec]
  [enforcing : bool]
  [deprecated-string-concat : bool]
  [redundant-function-name : bool]
  [dead-decls : SelfhostLintDeadDecls]) : i64
  (let
    [source : String (io.read-file input-path)]
    (match (parse-ast-source-diagnostic input-path source)
      [(ResultAstProgramDiagnostic.Ok program)
        (let
          [findings : LintFindings
            (selfhost-lint-program-and-typed-findings
              input-path
              source
              program
              stdlib-roots
              deprecated-string-concat
              redundant-function-name)]
          [ordinary-count : i64
            (selfhost-lint-print-findings input-path findings)]
          [dead-count : i64
            (selfhost-lint-package-dead-print-for-source
              input-path
              source
              dead-decls)]
          [total-count : i64 (+ ordinary-count dead-count)]
          (begin
            (io.print-string
              (string.append
                "lint: "
                (string.append (string.int->string total-count) " finding(s)\n")))
            (selfhost-lint-enforce-exit enforcing total-count)))]
      [(ResultAstProgramDiagnostic.Err diag)
        (begin
          (io.print-error (compiler-diagnostic-render (box-get diag)))
          1)])))

(define (selfhost-lint-files-from
  [input-paths : vector.StringVec]
  [index : i64]
  [stdlib-roots : vector.StringVec]
  [enforcing : bool]
  [deprecated-string-concat : bool]
  [redundant-function-name : bool]
  [print-headers : bool]
  [status : i64]) : i64
  (if (>= index (vector.string-vec-len input-paths))
    status
    (let
      [input-path : String (vector.string-vec-get input-paths index "")]
      [file-status : i64
        (begin
          (if print-headers
            (io.print-string
              (string.append "--- " (string.append input-path "\n")))
            unit)
          (selfhost-lint-file
            input-path
            stdlib-roots
            enforcing
            deprecated-string-concat
            redundant-function-name))]
      (selfhost-lint-files-from
        input-paths
        (+ index 1)
        stdlib-roots
        enforcing
        deprecated-string-concat
        redundant-function-name
        print-headers
        (if (= status 0)
          file-status
          status)))))

(define (selfhost-lint-files
  [input-paths : vector.StringVec]
  [stdlib-roots : vector.StringVec]
  [enforcing : bool]
  [deprecated-string-concat : bool]
  [redundant-function-name : bool]
  [print-headers : bool]
  [status : i64]) : i64
  (selfhost-lint-files-from
    input-paths
    0
    stdlib-roots
    enforcing
    deprecated-string-concat
    redundant-function-name
    print-headers
    status))

(define (selfhost-lint-package-files-from
  [input-paths : PackageSourceList]
  [index : i64]
  [stdlib-roots : vector.StringVec]
  [enforcing : bool]
  [deprecated-string-concat : bool]
  [redundant-function-name : bool]
  [dead-decls : SelfhostLintDeadDecls]
  [print-headers : bool]
  [status : i64]) : i64
  (if (>= index (package-source-list-len input-paths))
    status
    (let
      [input-path : String (package-source-list-get input-paths index "")]
      [file-status : i64
        (begin
          (if print-headers
            (io.print-string
              (string.append "--- " (string.append input-path "\n")))
            unit)
          (selfhost-lint-file-with-package-dead
            input-path
            stdlib-roots
            enforcing
            deprecated-string-concat
            redundant-function-name
            dead-decls))]
      (selfhost-lint-package-files-from
        input-paths
        (+ index 1)
        stdlib-roots
        enforcing
        deprecated-string-concat
        redundant-function-name
        dead-decls
        print-headers
        (if (= status 0)
          file-status
          status)))))

(define (selfhost-lint-package-files
  [input-paths : PackageSourceList]
  [stdlib-roots : vector.StringVec]
  [enforcing : bool]
  [deprecated-string-concat : bool]
  [redundant-function-name : bool]
  [dead-decls : SelfhostLintDeadDecls]
  [print-headers : bool]
  [status : i64]) : i64
  (selfhost-lint-package-files-from
    input-paths
    0
    stdlib-roots
    enforcing
    deprecated-string-concat
    redundant-function-name
    dead-decls
    print-headers
    status))

(define (selfhost-lint-package
  [manifest-path : String]
  [has-manifest : bool]
  [stdlib-roots : vector.StringVec]
  [enforcing : bool]
  [deprecated-string-concat : bool]
  [redundant-function-name : bool]) : i64
  (match (package-source-discover-for "lint" manifest-path has-manifest)
    [(ResultPackageSourceSet.Err message)
      (begin
        (io.print-error (string.append message "\n"))
        1)]
    [(ResultPackageSourceSet.Ok source-set)
      (let
        [sources : PackageSourceList (struct-get source-set sources)]
        [manifest : CompilerPkgManifest (struct-get source-set manifest)]
        [dead-decls : SelfhostLintDeadDecls
          (selfhost-lint-package-dead-code sources (struct-get manifest kind))]
        (selfhost-lint-package-files
          sources
          stdlib-roots
          enforcing
          deprecated-string-concat
          redundant-function-name
          dead-decls
          (> (package-source-list-len sources) 1)
          0))]))

;; Run the `lint` command over arguments starting at `start`.
(define (selfhost-lint-run-from [start : i64] [count : i64]) : i64
  (match (selfhost-lint-config-from start count)
    [(ResultSelfhostLintConfig.Ok config)
      (match config
        [(SelfhostLintConfig.File
            input-paths
            stdlib-roots
            enforcing
            deprecated-string-concat
            redundant-function-name)
          (selfhost-lint-files
            input-paths
            stdlib-roots
            enforcing
            deprecated-string-concat
            redundant-function-name
            (> (vector.string-vec-len input-paths) 1)
            0)]
        [(SelfhostLintConfig.Package
            manifest-path
            has-manifest
            stdlib-roots
            enforcing
            deprecated-string-concat
            redundant-function-name)
          (selfhost-lint-package
            manifest-path
            has-manifest
            stdlib-roots
            enforcing
            deprecated-string-concat
            redundant-function-name)])]
    [(ResultSelfhostLintConfig.Err message)
      (begin
        (io.print-error (string.append message "\n"))
        2)]))

;; ---- self-test (driven by lint_driver_smoke.tl) ----
;; A five-deep value-dispatch if-ladder. The nested-if-ladder rule is active, so
;; this emits one finding at the ladder head.
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

;; Same ladder, but with a `;; lint-allow: nested-if-ladder` directive that
;; suppresses the ladder finding via its stable rule id.
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

;; A directive for a different rule id does not suppress the ladder finding, so
;; this still emits one.
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

(define (selfhost-lint-redundant-divergence-padding-source) : String
  "(define (main [flag : bool]) : i64
  (begin
    (begin
      (io.panic \"stop\")
      ;; lint-allow: unreachable-code
      0)
    (unsafe
      (io.error \"stop\")
      ;; lint-allow: unreachable-code
      1)
    (with-arena scratch
      (io.panic \"stop\")
      ;; lint-allow: unreachable-code
      2)
    (if flag
      (begin
        (io.panic \"stop\")
        ;; lint-allow: unreachable-code
        3)
      4)))")

(define (selfhost-lint-clean-divergence-source) : String
  "(define (main [flag : bool]) : i64
  (if flag
    (io.panic \"stop\")
    4))")

(define (selfhost-lint-suppressed-divergence-padding-source) : String
  "(define (main) : i64
  (begin
    ;; lint-allow: redundant-divergence-padding
    (io.panic \"stop\")
    ;; lint-allow: unreachable-code
    0))")

;; A clean source with no nested-`if` ladder - zero findings.
(define (selfhost-lint-clean-source) : String
  "(define (inc [x : i64]) : i64 (+ x 1))")

(define (selfhost-lint-unused-dotted-import-source) : String
  "(import pkg.data)
(define (main) : i64 42)")

(define (selfhost-lint-used-dotted-import-alias-source) : String
  "(import pkg.data)
(define (main) : i64 (data.value))")

(define (selfhost-lint-used-dotted-import-full-path-source) : String
  "(import pkg.data)
(define (main) : i64 (pkg.data.value))")

(define (selfhost-lint-unused-explicit-path-alias-source) : String
  "(import \"data.tl\" module data :as d)
(define (main) : i64 42)")

(define (selfhost-lint-used-explicit-path-alias-source) : String
  "(import \"data.tl\" module data :as d)
(define (main) : i64 (d.value))")

(define (selfhost-lint-unused-underscore-import-source) : String
  "(import pkg.data as _data)
(define (main) : i64 42)")

(define (selfhost-lint-legacy-path-import-source) : String
  "(import \"data.tl\")
(define (main) : i64 42)")

(define (selfhost-lint-used-import-type-source) : String
  "(import pkg.data)
(define (make) : data.Item (init : data.Item))")

(define (selfhost-lint-used-import-pattern-source) : String
  "(import pkg.data)
(define (read [x : data.Maybe]) : i64
  (match x
    [(data.Maybe.Some y) y]
    [_ 0]))")

(define (selfhost-lint-used-import-macro-call-source) : String
  "(import pkg.macros)
(pkg.macros.emit i64)")

(define (selfhost-lint-used-import-legacy-macro-call-source) : String
  "(import \"stdlib/core_macros.tl\" module stdlib.core_macros as core)
(define (check [flag : bool]) : bool (core/and flag true))")

(define (selfhost-lint-suppressed-unused-import-source) : String
  ";; lint-allow: unused-import
(import pkg.data)
(define (main) : i64 42)")

(define (selfhost-lint-package-dead-source-a) : String
  "(define (main) : i64 (public-api 1))
(define (public-api [x : i64]) : i64 (helper x))
(define (helper [x : i64]) : i64 (cross-file-helper x))
(define (default-visible-helper) : i64 1)
;; lint-allow: dead-code
(define (suppressed-visible-helper) : i64 2)")

(define (selfhost-lint-package-dead-source-b) : String
  (string.append
    "(define (cross-file-helper [x : i64]) : i64 (+ x 1))
(define (test-only-helper) : i64 3)
"
    (string.append "(te" "st \"test-only\" (test-only-helper))")))

(define (selfhost-lint-unused-assignment-init-source) : String
  "(define (main) : i64
  (let
    [x : i64 1]
    (begin
      (set! x 2)
      x)))")

(define (selfhost-lint-unused-assignment-set-source) : String
  "(define (main) : i64
  (let
    [x : i64 0]
    (begin
      (set! x (+ x 1))
      (set! x 2)
      x)))")

(define (selfhost-lint-used-before-overwrite-source) : String
  "(define (main) : i64
  (let
    [x : i64 1]
    (begin
      (set! x (+ x 1))
      x)))")

(define (selfhost-lint-branch-conservative-assignment-source) : String
  "(define (main [flag : bool]) : i64
  (let
    [x : i64 1]
    (begin
      (if flag
        (set! x 2)
        unit)
      (set! x 3)
      x)))")

(define (selfhost-lint-underscore-assignment-source) : String
  "(define (main) : i64
  (let
    [_x : i64 1]
    (begin
      (set! _x 2)
      _x)))")

(define (selfhost-lint-suppressed-unused-assignment-source) : String
  "(define (main) : i64
  (let
    ;; lint-allow: unused-assignment
    [x : i64 1]
    (begin
      (set! x 2)
      x)))")

(define (selfhost-lint-single-element-array-fixed-source) : String
  "(define (main) : i64
  (let
    [cur : (Array i64 1) (array 0)]
    (begin
      (array-set! cur 0 3)
      (array-ref cur 0))))")

(define (selfhost-lint-single-element-array-param-source) : String
  "(define (read-cell [cur : (Array i64 1)]) : i64
  (array-ref cur 0))")

(define (selfhost-lint-single-element-array-dynamic-source) : String
  "(define (main) : i64
  (let
    [cur : (Array i64) (make-array i64 1)]
    (begin
      (array-set! cur 0 3)
      (array-ref cur 0))))")

(define (selfhost-lint-single-element-array-dotted-source) : String
  "(define (main) : i64
  (let
    [cur : (Array i64) (array.make-array i64 1)]
    (begin
      (array-set! cur 0 3)
      (array.ref cur 0))))")

(define (selfhost-lint-single-element-array-nonzero-source) : String
  "(define (main) : i64
  (let
    [cur : (Array i64 2) (array 1 2)]
    (array-ref cur 1)))")

(define (selfhost-lint-single-element-array-dynamic-index-source) : String
  "(define (main [index : i64]) : i64
  (let
    [cur : (Array i64) (make-array i64 1)]
    (array-ref cur index)))")

(define (selfhost-lint-single-element-array-escape-source) : String
  "(define (use-array [items : (Array i64)]) : i64
  (array-length items))
(define (main) : i64
  (let
    [cur : (Array i64) (make-array i64 1)]
    (use-array cur)))")

(define (selfhost-lint-single-element-array-aggregate-source) : String
  "(define (main) : String
  (let
    [cur : (Array String 1) (array \"x\")]
    (array-ref cur 0)))")

(define (selfhost-lint-single-element-array-suppressed-source) : String
  "(define (main) : i64
  (let
    ;; lint-allow: single-element-array-cell
    [cur : (Array i64 1) (array 0)]
    (array-ref cur 0)))")

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
      [a : i64 (+ a 1)]
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

(define (selfhost-lint-single-begin-source) : String
  "(define (main) : i64
  (begin 42))")

(define (selfhost-lint-clean-begin-source) : String
  "(define (main) : i64
  (begin
    unit
    42))")

(define (selfhost-lint-cfg-begin-source) : String
  "(define (main) : i64
  (begin
    (cfg compile-profile (io.panic \"profile\"))
    42))")

(define (selfhost-lint-suppressed-single-begin-source) : String
  "(define (main) : i64
  ;; lint-allow: single-begin
  (begin 42))")

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

(define (selfhost-lint-transitional-core-macro-source) : String
  "(define (check [flag : bool]) : i64
  (begin
    (core.when flag unit)
    (core.unless false unit)
    (if (core.and flag (core.or false true))
      (if (core.cond [flag true] [else false]) 42 1)
      1)))")

(define (selfhost-lint-clean-core-macro-text-source) : String
  ";; core.cond in a comment is not an expression call head.
(import stdlib.core_macros as core)
(define core-dot-cond-text : String \"core.cond\")
(define (main) : i64
  (let
    [value : i64 core.cond]
    value))")

(define (selfhost-lint-suppressed-transitional-core-macro-source) : String
  "(define (main) : i64
  ;; lint-allow: transitional-core-macro-qualifier
  (if (core.cond [true true] [else false]) 42 1))")

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
      (vector.string-vec-new))))

(define (selfhost-lint-findings-rule-count-from
  [findings : LintFindings]
  [rule-id : String]
  [index : i64]
  [count : i64]) : i64
  (if (>= index (lint-findings-count findings))
    count
    (match (lint-findings-get findings index)
      [(LintMaybeFinding.Some finding)
        (selfhost-lint-findings-rule-count-from
          findings
          rule-id
          (+ index 1)
          (if (string.eq (struct-get finding rule-id) rule-id)
            (+ count 1)
            count))]
      [(LintMaybeFinding.No)
        (selfhost-lint-findings-rule-count-from
          findings
          rule-id
          (+ index 1)
          count)])))

(define (selfhost-lint-findings-rule-count
  [findings : LintFindings]
  [rule-id : String]) : i64
  (selfhost-lint-findings-rule-count-from findings rule-id 0 0))

(define (selfhost-lint-source-rule-count [source : String] [rule-id : String]) : i64
  (selfhost-lint-findings-rule-count
    (selfhost-lint-source-with-roots
      "lint_driver_self_test.tl"
      source
      (vector.string-vec-new))
    rule-id))

(define (selfhost-lint-unused-import-finding-ok? [findings : LintFindings]) : bool
  (match (lint-findings-get findings 0)
    [(LintMaybeFinding.Some finding)
      (let
        [fspan : AstSourceSpan (struct-get finding span)]
        (and
          (= (lint-findings-count findings) 1)
          (> (struct-get fspan start-line) 0)
          (string.eq (struct-get finding rule-id) (lint-rule-unused-import-id))))]
    [(LintMaybeFinding.No) false]))

(define (selfhost-lint-unused-imports-self-test) : i64
  (let
    [unused : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-unused-dotted-import-source)
        (vector.string-vec-new))]
    [unused-path-alias : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-unused-explicit-path-alias-source)
        (vector.string-vec-new))]
    (cond
      [(not (selfhost-lint-unused-import-finding-ok? unused)) 30]
      [(not (selfhost-lint-unused-import-finding-ok? unused-path-alias)) 31]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-used-dotted-import-alias-source))
            0))
        32]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-used-dotted-import-full-path-source))
            0))
        33]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-used-explicit-path-alias-source))
            0))
        34]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-unused-underscore-import-source))
            0))
        35]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-legacy-path-import-source))
            0))
        36]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-used-import-type-source))
            0))
        37]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-used-import-pattern-source))
            0))
        38]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-used-import-macro-call-source))
            0))
        40]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-suppressed-unused-import-source))
            0))
        41]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-used-import-legacy-macro-call-source))
            0))
        43]
      [else 42])))

(define (selfhost-lint-package-dead-code-fixture-decls
  [source-a : String]
  [source-b : String]
  [kind : CompilerPkgKind]) : SelfhostLintDeadDecls
  (let
    [visible-root : bool (selfhost-lint-package-dead-visible-root? kind)]
    [reportable : bool (selfhost-lint-package-dead-reportable? kind)]
    [scan-a : SelfhostLintDeadScan
      (selfhost-lint-dead-scan-source
        (SelfhostLintDeadScan
          (selfhost-lint-dead-decls-empty)
          (vector.string-vec-new))
        "pkg/a.tl"
        source-a
        visible-root
        reportable)]
    [scan-b : SelfhostLintDeadScan
      (selfhost-lint-dead-scan-source
        scan-a
        "pkg/b.tl"
        source-b
        visible-root
        reportable)]
    [scan : SelfhostLintDeadScan
      (selfhost-lint-package-dead-add-kind-roots scan-b kind)]
    (selfhost-lint-dead-mark-roots-from
      (struct-get scan decls)
      (struct-get scan roots)
      0)))

(define (selfhost-lint-package-dead-code-self-test) : i64
  (let
    [source-a : String (selfhost-lint-package-dead-source-a)]
    [source-b : String (selfhost-lint-package-dead-source-b)]
    [bin-decls : SelfhostLintDeadDecls
      (selfhost-lint-package-dead-code-fixture-decls
        source-a
        source-b
        CompilerPkgKindBin)]
    [lib-decls : SelfhostLintDeadDecls
      (selfhost-lint-package-dead-code-fixture-decls
        source-a
        source-b
        CompilerPkgKindLib)]
    [bin-count-a : i64
      (selfhost-lint-package-dead-count-for-source
        "pkg/a.tl"
        source-a
        bin-decls)]
    [bin-count-b : i64
      (selfhost-lint-package-dead-count-for-source
        "pkg/b.tl"
        source-b
        bin-decls)]
    [lib-count-a : i64
      (selfhost-lint-package-dead-count-for-source
        "pkg/a.tl"
        source-a
        lib-decls)]
    [lib-count-b : i64
      (selfhost-lint-package-dead-count-for-source
        "pkg/b.tl"
        source-b
        lib-decls)]
    [finding : LintFinding (lint-dead-code-finding "unused" (lint-no-span))]
    [finding-message : String (struct-get finding message)]
    [dead-suggestion : String (lint-rule-dead-code-suggestion)]
    [private-needle : String "private"]
    [export-needle : String "export"]
    (cond
      [(not (= bin-count-a 1)) 50]
      [(not (= bin-count-b 0)) 51]
      [(not (= lib-count-a 0)) 52]
      [(not (= lib-count-b 0)) 53]
      [(not
          (string.eq
            (lint-rule-message (lint-rule-dead-code-id))
            (lint-rule-dead-code-message)))
        54]
      [(string.contains (& finding-message) (& private-needle)) 55]
      [(string.contains (& dead-suggestion) (& export-needle)) 56]
      [else 42])))

(define (selfhost-lint-unused-assignment-self-test) : i64
  (let
    [rule : String (lint-rule-unused-assignment-id)]
    (cond
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-unused-assignment-init-source)
              rule)
            1))
        50]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-unused-assignment-set-source)
              rule)
            1))
        51]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-used-before-overwrite-source)
              rule)
            0))
        52]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-branch-conservative-assignment-source)
              rule)
            0))
        53]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-underscore-assignment-source)
              rule)
            0))
        54]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-suppressed-unused-assignment-source)
              rule)
            0))
        55]
      [(not
          (string.eq
            (lint-rule-message rule)
            (lint-rule-unused-assignment-message)))
        56]
      [else 42])))

(define (selfhost-lint-single-element-array-cell-self-test) : i64
  (let
    [rule : String (lint-rule-single-element-array-cell-id)]
    (cond
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-single-element-array-fixed-source)
              rule)
            1))
        60]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-single-element-array-param-source)
              rule)
            1))
        61]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-single-element-array-dynamic-source)
              rule)
            1))
        62]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-single-element-array-dotted-source)
              rule)
            1))
        63]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-single-element-array-nonzero-source)
              rule)
            0))
        64]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-single-element-array-dynamic-index-source)
              rule)
            0))
        65]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-single-element-array-escape-source)
              rule)
            0))
        66]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-single-element-array-aggregate-source)
              rule)
            0))
        67]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-single-element-array-suppressed-source)
              rule)
            0))
        68]
      [(not
          (string.eq
            (lint-rule-message rule)
            (lint-rule-single-element-array-cell-message)))
        69]
      [else 42])))

;; Compatibility helper retained for the nested-if-ladder metadata shape.
(define (selfhost-lint-reported-finding-ok? [findings : LintFindings]) : bool
  (match (lint-findings-get findings 0)
    [(LintMaybeFinding.Some finding)
      (let
        [fspan : AstSourceSpan (struct-get finding span)]
        (and
          (= (struct-get finding depth) 5)
          (> (struct-get fspan start-line) 0)
          (string.eq
            (struct-get finding rule-id)
            (lint-rule-nested-if-ladder-id))))]
    [(LintMaybeFinding.No) false]))

(define (selfhost-lint-nested-let-finding-ok? [findings : LintFindings]) : bool
  (match (lint-findings-get findings 0)
    [(LintMaybeFinding.Some finding)
      (let
        [fspan : AstSourceSpan (struct-get finding span)]
        (and
          (> (struct-get fspan start-line) 0)
          (string.eq (struct-get finding rule-id) (lint-rule-nested-let-id))))]
    [(LintMaybeFinding.No) false]))

(define (selfhost-lint-return-path-finding-ok? [findings : LintFindings]) : bool
  (match (lint-findings-get findings 0)
    [(LintMaybeFinding.Some finding)
      (let
        [fspan : AstSourceSpan (struct-get finding span)]
        (and
          (= (struct-get finding depth) 3)
          (> (struct-get fspan start-line) 0)
          (string.eq
            (struct-get finding rule-id)
            (lint-rule-return-path-chain-id))))]
    [(LintMaybeFinding.No) false]))

(define (selfhost-lint-unit-if-finding-ok? [findings : LintFindings]) : bool
  (match (lint-findings-get findings 0)
    [(LintMaybeFinding.Some finding)
      (let
        [fspan : AstSourceSpan (struct-get finding span)]
        (and
          (= (struct-get finding depth) 1)
          (> (struct-get fspan start-line) 0)
          (string.eq (struct-get finding rule-id) (lint-rule-unit-if-guard-id))))]
    [(LintMaybeFinding.No) false]))

(define (selfhost-lint-cascading-and-or-finding-ok?
  [findings : LintFindings]
  [message : String]) : bool
  (match (lint-findings-get findings 0)
    [(LintMaybeFinding.Some finding)
      (let
        [fspan : AstSourceSpan (struct-get finding span)]
        (and
          (= (struct-get finding depth) 3)
          (> (struct-get fspan start-line) 0)
          (string.eq
            (struct-get finding rule-id)
            (lint-rule-cascading-and-or-id))
          (string.eq (struct-get finding message) message)))]
    [(LintMaybeFinding.No) false]))

(define (selfhost-lint-transitional-core-macro-finding-ok?
  [findings : LintFindings]) : bool
  (match (lint-findings-get findings 0)
    [(LintMaybeFinding.Some finding)
      (and
        (= (lint-findings-count findings) 5)
        (string.eq
          (struct-get finding rule-id)
          (lint-rule-transitional-core-macro-qualifier-id))
        (string.eq
          (struct-get finding message)
          "transitional core macro qualifier: use when instead of core.when"))]
    [(LintMaybeFinding.No) false]))

(define (selfhost-lint-render-order-ok? [findings : LintFindings]) : bool
  (if (= (lint-findings-count findings) 2)
    (match (lint-findings-get findings 1)
      [(LintMaybeFinding.Some rendered-first)
        (match (lint-findings-get findings 0)
          [(LintMaybeFinding.Some rendered-second)
            (let
              [first-span : AstSourceSpan (struct-get rendered-first span)]
              [second-span : AstSourceSpan (struct-get rendered-second span)]
              (and
                (= (struct-get first-span start-line) 11)
                (= (struct-get second-span start-line) 2)))]
          [(LintMaybeFinding.No) false])]
      [(LintMaybeFinding.No) false])
    false))

(define (compiler-lint-driver-self-test) : i64
  (let
    [reported : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-ladder-source)
        (vector.string-vec-new))]
    [return-reported : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-return-path-chain-source)
        (vector.string-vec-new))]
    [unit-reported : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-unit-if-source)
        (vector.string-vec-new))]
    [unit-set-reported : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-unit-set-source)
        (vector.string-vec-new))]
    [two-reported : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-two-findings-source)
        (vector.string-vec-new))]
    [cascading-and-reported : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-cascading-and-source)
        (vector.string-vec-new))]
    [cascading-or-reported : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-cascading-or-source)
        (vector.string-vec-new))]
    [cascading-core-and-reported : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-cascading-core-and-source)
        (vector.string-vec-new))]
    [transitional-core-reported : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-transitional-core-macro-source)
        (vector.string-vec-new))]
    (cond
      [(or
          (not (= (lint-findings-count reported) 1))
          (not (selfhost-lint-reported-finding-ok? reported)))
        1]
      [(not (= (lint-findings-count return-reported) 1)) 9]
      [(not (selfhost-lint-return-path-finding-ok? return-reported)) 10]
      [(not (= (lint-findings-count unit-reported) 1)) 12]
      [(not (selfhost-lint-unit-if-finding-ok? unit-reported)) 13]
      [(not (= (lint-findings-count unit-set-reported) 1)) 16]
      [(not (selfhost-lint-unit-if-finding-ok? unit-set-reported)) 17]
      [(not (= (lint-findings-count two-reported) 2)) 18]
      [(not (= (lint-findings-count cascading-and-reported) 1)) 20]
      [(not
          (selfhost-lint-cascading-and-or-finding-ok?
            cascading-and-reported
            "cascading and: prefer flat n-ary form (and a b c)"))
        21]
      [(not (= (lint-findings-count cascading-or-reported) 1)) 22]
      [(not
          (selfhost-lint-cascading-and-or-finding-ok?
            cascading-or-reported
            "cascading or: prefer flat n-ary form (or a b c)"))
        23]
      [(not (= (lint-findings-count cascading-core-and-reported) 1)) 24]
      [(not
          (selfhost-lint-cascading-and-or-finding-ok?
            cascading-core-and-reported
            "cascading and: prefer flat n-ary form (and a b c)"))
        25]
      [(not (= (lint-findings-count transitional-core-reported) 5)) 37]
      [(not
          (selfhost-lint-transitional-core-macro-finding-ok?
            transitional-core-reported))
        38]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-clean-core-macro-text-source)
              (lint-rule-transitional-core-macro-qualifier-id))
            0))
        39]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-suppressed-transitional-core-macro-source)
              (lint-rule-transitional-core-macro-qualifier-id))
            0))
        40]
      [(not
          (=
            (selfhost-lint-source-finding-count (selfhost-lint-flat-and-source))
            0))
        26]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-mixed-and-or-source))
            0))
        27]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-suppressed-cascading-and-source))
            0))
        28]
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
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-redundant-divergence-padding-source)
              (lint-rule-redundant-divergence-padding-id))
            4))
        29]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-redundant-divergence-padding-source))
            4))
        30]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-clean-divergence-source))
            0))
        31]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-suppressed-divergence-padding-source)
              (lint-rule-redundant-divergence-padding-id))
            0))
        32]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-suppressed-ladder-source))
            0))
        3]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-wrong-allow-ladder-source))
            1))
        4]
      [(not
          (=
            (selfhost-lint-source-finding-count (selfhost-lint-clean-source))
            0))
        5]
      [(not
          (selfhost-lint-nested-let-finding-ok?
            (selfhost-lint-source-with-roots
              "lint_driver_self_test.tl"
              (selfhost-lint-nested-let-source)
              (vector.string-vec-new))))
        9]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-shadowing-nested-let-source))
            0))
        10]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-begin-inner-let-source))
            0))
        11]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-suppressed-nested-let-source))
            0))
        12]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-single-begin-source)
              (lint-rule-single-begin-id))
            1))
        33]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-clean-begin-source))
            0))
        34]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-cfg-begin-source)
              (lint-rule-single-begin-id))
            0))
        36]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-suppressed-single-begin-source)
              (lint-rule-single-begin-id))
            0))
        35]
      [(not (= (selfhost-lint-enforce-exit true 1) 1)) 6]
      [(not (= (selfhost-lint-enforce-exit true 0) 0)) 7]
      [(not (= (selfhost-lint-enforce-exit false 1) 0)) 8]
      [else 42])))