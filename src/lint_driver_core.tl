;; lint_driver_core.tl - Driver logic for the selfhost `typelisp lint` tool
;; (#1163): load a TypeLisp source, run the lint_core rules over its program, and
;; render each finding as `path:line:col: message`. Kept main-less so both the
;; CLI driver (`lint.tl`) and the runnable smoke (`lint_driver_smoke.tl`) can
;; import it. Warn-only by default; callers can pass `--check` after the input
;; path to exit non-zero when findings remain. The deprecated string-concat rule
;; is opt-in until the remaining in-tree str-cat migrations land.
(import "../stdlib/io.tl")
(import "../stdlib/list.tl")
(import "compiler_check_core.tl")
(import "compiler_load.tl")
(import "lint_core.tl")
(import "package_source_core.tl")
(import "../stdlib/string.tl")

;; Parsed lint CLI config: input paths, stdlib roots, whether `--check`
;; enforcing mode was requested (exit non-zero when findings are present), and
;; whether the staged deprecated string-concat rule is enabled.
(defenum SelfhostLintConfig
  (SelfhostLintFileConfig StringVec StringVec bool bool)
  (SelfhostLintPackageConfig String bool StringVec bool bool))

(defenum ResultSelfhostLintConfig
  (OkSelfhostLintConfig SelfhostLintConfig)
  (ErrSelfhostLintConfig String))

(define (selfhost-lint-flag? [value : String]) : bool
  (and (> (string-length value) 0) (= (string-ref value 0) #-')))

(define (selfhost-lint-config-finish
  [input-paths : StringVec]
  [manifest-path : String]
  [has-manifest : bool]
  [stdlib-roots : StringVec]
  [enforcing : bool]
  [deprecated-string-concat : bool]) : ResultSelfhostLintConfig
  (if (string-vec-is-empty? input-paths)
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
  [input-paths : StringVec]
  [manifest-path : String]
  [has-manifest : bool]
  [stdlib-roots : StringVec]
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
      [current : String (arg idx)]
      (cond
        [(string-eq current "--check")
          (selfhost-lint-parse-options
            (+ idx 1)
            count
            input-paths
            manifest-path
            has-manifest
            stdlib-roots
            true
            deprecated-string-concat)]
        [(string-eq current "--deprecated-string-concat")
          (selfhost-lint-parse-options
            (+ idx 1)
            count
            input-paths
            manifest-path
            has-manifest
            stdlib-roots
            enforcing
            true)]
        [(string-eq current "--stdlib-root")
          (if (>= (+ idx 1) count)
            (ErrSelfhostLintConfig
              "selfhost-lint: --stdlib-root requires a value")
            (selfhost-lint-parse-options
              (+ idx 2)
              count
              input-paths
              manifest-path
              has-manifest
              (string-vec-push stdlib-roots (arg (+ idx 1)))
              enforcing
              deprecated-string-concat))]
        [(string-eq current "--manifest-path")
          (if (>= (+ idx 1) count)
            (ErrSelfhostLintConfig
              "selfhost-lint: --manifest-path requires a value")
            (if has-manifest
              (ErrSelfhostLintConfig "selfhost-lint: duplicate --manifest-path")
              (selfhost-lint-parse-options
                (+ idx 2)
                count
                input-paths
                (arg (+ idx 1))
                true
                stdlib-roots
                enforcing
                deprecated-string-concat)))]
        [(selfhost-lint-flag? current)
          (ErrSelfhostLintConfig
            (string-append "selfhost-lint: unknown flag " current))]
        [else
          (selfhost-lint-parse-options
            (+ idx 1)
            count
            (string-vec-push input-paths current)
            manifest-path
            has-manifest
            stdlib-roots
            enforcing
            deprecated-string-concat)]))))

;; Parse the `lint` config from arguments starting at `start`.
(define (selfhost-lint-config-from [start : i64] [count : i64]) : ResultSelfhostLintConfig
  (selfhost-lint-parse-options
    start
    count
    (string-vec-new)
    ""
    false
    (string-vec-new)
    false
    false))

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
      (print-string
        (string-append
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
            (lint-program-with-source
              source
              (ast-program decls)
              (lint-default-ladder-threshold)))))]))

(define (selfhost-lint-program-findings
  [source : String]
  [program : AstProgram]) : LintFindings
  (selfhost-lint-program-findings-with-options source program false))

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

(define (selfhost-lint-source-has-unsafe? [source : String]) : bool
  (let
    [needle : String "unsafe"]
    (string-contains (& source) (& needle))))

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
          (string-eq (tc-unused-unsafe-block-path index) path))
          (lint-findings-add
            (lint-unused-unsafe-finding (tc-unused-unsafe-block-span index))
            out)
          out)]
      (selfhost-lint-unused-unsafe-findings-from path (+ index 1) next))))

(define (selfhost-lint-unused-unsafe-findings
  [path : String]
  [source : String]
  [stdlib-roots : StringVec]) : LintFindings
  (if (selfhost-lint-source-has-unsafe? source)
    (begin
      (tc-unused-unsafe-tracking-reset!)
      (match (compiler-check-source-with-roots path source stdlib-roots)
        [(OkCompilerCheck _)
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
        [(ErrCompilerCheck _)
          (begin
            (tc-unused-unsafe-tracking-disable!)
            (lint-findings-empty))]))
    (lint-findings-empty)))

(define (selfhost-lint-program-and-typed-findings
  [path : String]
  [source : String]
  [program : AstProgram]
  [stdlib-roots : StringVec]
  [deprecated-string-concat : bool]) : LintFindings
  (selfhost-lint-findings-append
    (selfhost-lint-program-findings-with-options
      source
      program
      deprecated-string-concat)
    (selfhost-lint-unused-unsafe-findings path source stdlib-roots)))

(define (selfhost-lint-source-with-roots-and-options
  [path : String]
  [source : String]
  [stdlib-roots : StringVec]
  [deprecated-string-concat : bool]) : LintFindings
  (match (parse-ast-source-diagnostic path source)
    [(OkAstProgramDiagnostic program)
      (selfhost-lint-program-and-typed-findings
        path
        source
        program
        stdlib-roots
        deprecated-string-concat)]
    [(ErrAstProgramDiagnostic _) (lint-findings-empty)]))

;; Parse `source` (attributed to `path`) and run the lint rules over this source
;; unit only. Imports are linted when their own files are selected by the repo
;; lint gate, so a public driver does not duplicate every imported finding.
(define (selfhost-lint-source-with-roots
  [path : String]
  [source : String]
  [stdlib-roots : StringVec]) : LintFindings
  (selfhost-lint-source-with-roots-and-options path source stdlib-roots false))

;; Package-level dead-code linting records all top-level declarations as graph
;; nodes, but only reports private `define` values/functions. Non-reportable
;; nodes still carry references so exported types/macros can keep helpers alive.
(defstruct SelfhostLintDeadDecl
  (path String)
  (name String)
  (span AstSourceSpan)
  (refs StringVec)
  (root bool)
  (reportable bool))

(defstruct SelfhostLintDeadDecls
  (slots (Array SelfhostLintDeadDecl))
  (len i64))

(defstruct SelfhostLintDeadScan
  (decls SelfhostLintDeadDecls)
  (roots StringVec))

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

(define (selfhost-lint-dead-root-add [roots : StringVec] [name : String]) : StringVec
  (if (string-vec-contains? roots name)
    roots
    (string-vec-push roots name)))

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

(define (selfhost-lint-dead-ref-add [refs : StringVec] [name : String]) : StringVec
  (if (string-vec-contains? refs name)
    refs
    (string-vec-push refs name)))

(define (selfhost-lint-dead-ref-add-id [refs : StringVec] [name : i64]) : StringVec
  (selfhost-lint-dead-ref-add refs (intern-str name)))

(define (selfhost-lint-dead-maybe-type-refs
  [maybe-ty : AstMaybeType]
  [refs : StringVec]) : StringVec
  (match maybe-ty
    [(AstNoType) refs]
    [(AstSomeType ty) (selfhost-lint-dead-type-refs ty refs)]))

(define (selfhost-lint-dead-type-list-refs
  [types : AstTypeList]
  [refs : StringVec]) : StringVec
  (match types
    [(AstTypeNil) refs]
    [(AstTypeCons head rest)
      (selfhost-lint-dead-type-list-refs
        (box-get rest)
        (selfhost-lint-dead-type-refs (ty-node-get head) refs))]))

(define (selfhost-lint-dead-type-id-refs [ty : i64] [refs : StringVec]) : StringVec
  (selfhost-lint-dead-type-refs (ty-node-get ty) refs))

(define (selfhost-lint-dead-type-refs [ty : AstType] [refs : StringVec]) : StringVec
  (match ty
    [(AstTyI64) refs]
    [(AstTyI32) refs]
    [(AstTyI16) refs]
    [(AstTyI8) refs]
    [(AstTyU64) refs]
    [(AstTyU32) refs]
    [(AstTyU16) refs]
    [(AstTyU8) refs]
    [(AstTyF64) refs]
    [(AstTyF32) refs]
    [(AstTyBool) refs]
    [(AstTyChar) refs]
    [(AstTyString) refs]
    [(AstTyStr) refs]
    [(AstTyBytes) refs]
    [(AstTyUnit) refs]
    [(AstTyNever) refs]
    [(AstTyExpr) refs]
    [(AstTyExprList) refs]
    [(AstTyFunc args ret)
      (selfhost-lint-dead-type-id-refs
        ret
        (selfhost-lint-dead-type-list-refs args refs))]
    [(AstTyTuple items) (selfhost-lint-dead-type-list-refs items refs)]
    [(AstTyArray elem _) (selfhost-lint-dead-type-id-refs elem refs)]
    [(AstTyDynArray elem) (selfhost-lint-dead-type-id-refs elem refs)]
    [(AstTyBox elem) (selfhost-lint-dead-type-id-refs elem refs)]
    [(AstTyRegion _ inner) (selfhost-lint-dead-type-id-refs inner refs)]
    [(AstTyRef _ inner) (selfhost-lint-dead-type-id-refs inner refs)]
    [(AstTyMutRef _ inner) (selfhost-lint-dead-type-id-refs inner refs)]
    [(AstTyEnum name) (selfhost-lint-dead-ref-add-id refs name)]
    [(AstTyEnumArgs name _) (selfhost-lint-dead-ref-add-id refs name)]
    [(AstTyStruct name) (selfhost-lint-dead-ref-add-id refs name)]
    [(AstTyStructArgs name _) (selfhost-lint-dead-ref-add-id refs name)]
    [(AstTyVar name) (selfhost-lint-dead-ref-add-id refs name)]
    [(AstTyVarArgs name _) (selfhost-lint-dead-ref-add-id refs name)]
    [(AstTyPtr inner) (selfhost-lint-dead-type-id-refs inner refs)]
    [(AstTyMutPtr inner) (selfhost-lint-dead-type-id-refs inner refs)]))

(define (selfhost-lint-dead-param-list-refs
  [params : AstParamList]
  [refs : StringVec]) : StringVec
  (match params
    [(AstParamNil) refs]
    [(AstParamCons param rest)
      (match param
        [(AstParam _ ty _)
          (selfhost-lint-dead-param-list-refs
            (box-get rest)
            (selfhost-lint-dead-type-refs ty refs))])]))

(define (selfhost-lint-dead-macro-param-list-refs
  [params : AstMacroParamList]
  [refs : StringVec]) : StringVec
  (match params
    [(AstMacroParamNil) refs]
    [(AstMacroParamCons param rest)
      (match param
        [(AstMacroParam _ ty _)
          (selfhost-lint-dead-macro-param-list-refs
            (box-get rest)
            (selfhost-lint-dead-type-refs ty refs))])]))

(define (selfhost-lint-dead-pattern-list-refs
  [patterns : AstPatternList]
  [refs : StringVec]) : StringVec
  (match patterns
    [(AstPatternNil) refs]
    [(AstPatternCons head rest)
      (selfhost-lint-dead-pattern-list-refs
        (box-get rest)
        (selfhost-lint-dead-pattern-refs (box-get head) refs))]))

(define (selfhost-lint-dead-pattern-refs
  [pattern : AstPattern]
  [refs : StringVec]) : StringVec
  (match pattern
    [(AstPatVar _ maybe-ty) (selfhost-lint-dead-maybe-type-refs maybe-ty refs)]
    [(AstPatTuple items)
      (selfhost-lint-dead-pattern-list-refs (box-get items) refs)]
    [(AstPatWildcard) refs]
    [(AstPatBinding _) refs]
    [(AstPatVariant name items)
      (selfhost-lint-dead-pattern-list-refs
        (box-get items)
        (selfhost-lint-dead-ref-add-id refs name))]
    [(AstPatLiteral _) refs]))

(define (selfhost-lint-dead-expr-list-refs
  [exprs : AstExprList]
  [refs : StringVec]) : StringVec
  (match exprs
    [(AstExprNil) refs]
    [(AstExprCons head rest)
      (selfhost-lint-dead-expr-list-refs
        (box-get rest)
        (selfhost-lint-dead-expr-refs (ast-node-get head) refs))]))

(define (selfhost-lint-dead-let-binding-refs
  [bindings : AstLetBindingList]
  [refs : StringVec]) : StringVec
  (match bindings
    [(AstLetBindingNil) refs]
    [(AstLetBindingCons binding rest)
      (match binding
        [(AstLetBinding _ maybe-ty init)
          (selfhost-lint-dead-let-binding-refs
            (box-get rest)
            (selfhost-lint-dead-expr-refs
              (ast-node-get init)
              (selfhost-lint-dead-maybe-type-refs maybe-ty refs)))])]))

(define (selfhost-lint-dead-match-arm-refs
  [arms : AstMatchArmList]
  [refs : StringVec]) : StringVec
  (match arms
    [(AstMatchArmNil) refs]
    [(AstMatchArmCons arm rest)
      (match arm
        [(AstMatchArm pattern body)
          (selfhost-lint-dead-match-arm-refs
            (box-get rest)
            (selfhost-lint-dead-expr-refs
              (ast-node-get body)
              (selfhost-lint-dead-pattern-refs pattern refs)))])]))

(define (selfhost-lint-dead-resource-binding-refs
  [bindings : AstResourceBindingList]
  [refs : StringVec]) : StringVec
  (match bindings
    [(AstResourceBindingNil) refs]
    [(AstResourceBindingCons binding rest)
      (match binding
        [(AstResourceBinding _ init cleanup)
          (selfhost-lint-dead-resource-binding-refs
            (box-get rest)
            (selfhost-lint-dead-expr-refs
              (ast-node-get cleanup)
              (selfhost-lint-dead-expr-refs (ast-node-get init) refs)))])]))

(define (selfhost-lint-dead-expr-refs [expr : AstExpr] [refs : StringVec]) : StringVec
  (match expr
    [(AstExprSpanned inner-box _)
      (selfhost-lint-dead-expr-refs (ast-node-get inner-box) refs)]
    [(AstExprLiteral _) refs]
    [(AstExprVar name) (selfhost-lint-dead-ref-add-id refs name)]
    [(AstExprBinary _ left right)
      (selfhost-lint-dead-expr-refs
        (ast-node-get right)
        (selfhost-lint-dead-expr-refs (ast-node-get left) refs))]
    [(AstExprUnary _ inner)
      (selfhost-lint-dead-expr-refs (ast-node-get inner) refs)]
    [(AstExprCall func args)
      (selfhost-lint-dead-expr-list-refs
        args
        (selfhost-lint-dead-expr-refs (ast-node-get func) refs))]
    [(AstExprIf cond then-branch else-branch)
      (selfhost-lint-dead-expr-refs
        (ast-node-get else-branch)
        (selfhost-lint-dead-expr-refs
          (ast-node-get then-branch)
          (selfhost-lint-dead-expr-refs (ast-node-get cond) refs)))]
    [(AstExprLet bindings body)
      (selfhost-lint-dead-expr-refs
        (ast-node-get body)
        (selfhost-lint-dead-let-binding-refs bindings refs))]
    [(AstExprLambda params ret body)
      (selfhost-lint-dead-expr-refs
        (ast-node-get body)
        (selfhost-lint-dead-maybe-type-refs
          ret
          (selfhost-lint-dead-param-list-refs params refs)))]
    [(AstExprTuple exprs) (selfhost-lint-dead-expr-list-refs exprs refs)]
    [(AstExprTupleRef tuple _)
      (selfhost-lint-dead-expr-refs (ast-node-get tuple) refs)]
    [(AstExprArray exprs) (selfhost-lint-dead-expr-list-refs exprs refs)]
    [(AstExprMakeArray elem len)
      (selfhost-lint-dead-expr-refs
        (ast-node-get len)
        (selfhost-lint-dead-type-refs elem refs))]
    [(AstExprArrayRef array index)
      (selfhost-lint-dead-expr-refs
        (ast-node-get index)
        (selfhost-lint-dead-expr-refs (ast-node-get array) refs))]
    [(AstExprArraySet array index value)
      (selfhost-lint-dead-expr-refs
        (ast-node-get value)
        (selfhost-lint-dead-expr-refs
          (ast-node-get index)
          (selfhost-lint-dead-expr-refs (ast-node-get array) refs)))]
    [(AstExprArrayPush array value)
      (selfhost-lint-dead-expr-refs
        (ast-node-get value)
        (selfhost-lint-dead-expr-refs (ast-node-get array) refs))]
    [(AstExprStringRef text index)
      (selfhost-lint-dead-expr-refs
        (ast-node-get index)
        (selfhost-lint-dead-expr-refs (ast-node-get text) refs))]
    [(AstExprWhile cond body)
      (selfhost-lint-dead-expr-refs
        (ast-node-get body)
        (selfhost-lint-dead-expr-refs (ast-node-get cond) refs))]
    [(AstExprBegin exprs) (selfhost-lint-dead-expr-list-refs exprs refs)]
    [(AstExprUnsafe exprs) (selfhost-lint-dead-expr-list-refs exprs refs)]
    [(AstExprSet target value)
      (selfhost-lint-dead-expr-refs
        (ast-node-get value)
        (selfhost-lint-dead-ref-add-id refs target))]
    [(AstExprAnn inner ty)
      (selfhost-lint-dead-type-refs
        ty
        (selfhost-lint-dead-expr-refs (ast-node-get inner) refs))]
    [(AstExprCast inner ty)
      (selfhost-lint-dead-type-refs
        ty
        (selfhost-lint-dead-expr-refs (ast-node-get inner) refs))]
    [(AstExprBorrow _ _ place)
      (selfhost-lint-dead-expr-refs (ast-node-get place) refs)]
    [(AstExprMatch scrutinee arms)
      (selfhost-lint-dead-match-arm-refs
        arms
        (selfhost-lint-dead-expr-refs (ast-node-get scrutinee) refs))]
    [(AstExprForeach _ index-ty start end body)
      (selfhost-lint-dead-expr-refs
        (ast-node-get body)
        (selfhost-lint-dead-expr-refs
          (ast-node-get end)
          (selfhost-lint-dead-expr-refs
            (ast-node-get start)
            (selfhost-lint-dead-type-refs index-ty refs))))]
    [(AstExprSpmdReduce _ _ index-ty start end init value)
      (selfhost-lint-dead-expr-refs
        (ast-node-get value)
        (selfhost-lint-dead-expr-refs
          (ast-node-get init)
          (selfhost-lint-dead-expr-refs
            (ast-node-get end)
            (selfhost-lint-dead-expr-refs
              (ast-node-get start)
              (selfhost-lint-dead-type-refs index-ty refs)))))]
    [(AstExprSpmdBroadcast value lane)
      (selfhost-lint-dead-expr-refs
        (ast-node-get lane)
        (selfhost-lint-dead-expr-refs (ast-node-get value) refs))]
    [(AstExprStructGet receiver _)
      (selfhost-lint-dead-expr-refs (ast-node-get receiver) refs)]
    [(AstExprStructSet receiver _ value)
      (selfhost-lint-dead-expr-refs
        (ast-node-get value)
        (selfhost-lint-dead-expr-refs (ast-node-get receiver) refs))]
    [(AstExprWithRegion _ body) (selfhost-lint-dead-expr-list-refs body refs)]
    [(AstExprWithEscape scratch body)
      (selfhost-lint-dead-expr-list-refs
        body
        (selfhost-lint-dead-expr-refs (ast-node-get scratch) refs))]
    [(AstExprWithScratch body) (selfhost-lint-dead-expr-list-refs body refs)]
    [(AstExprInArena arena body)
      (selfhost-lint-dead-expr-list-refs
        body
        (selfhost-lint-dead-expr-refs (ast-node-get arena) refs))]
    [(AstExprWithResource bindings body)
      (selfhost-lint-dead-expr-list-refs
        body
        (selfhost-lint-dead-resource-binding-refs bindings refs))]
    [(AstExprBox inner)
      (selfhost-lint-dead-expr-refs (ast-node-get inner) refs)]
    [(AstExprBoxGet inner)
      (selfhost-lint-dead-expr-refs (ast-node-get inner) refs)]
    [(AstExprBoxTake inner)
      (selfhost-lint-dead-expr-refs (ast-node-get inner) refs)]
    [(AstExprBoxSet inner value)
      (selfhost-lint-dead-expr-refs
        (ast-node-get value)
        (selfhost-lint-dead-expr-refs (ast-node-get inner) refs))]
    [(AstExprTypeLiteral ty) (selfhost-lint-dead-type-refs ty refs)]
    [(AstExprInit maybe-ty) (selfhost-lint-dead-maybe-type-refs maybe-ty refs)]
    [(AstExprComptime inner)
      (selfhost-lint-dead-expr-refs (ast-node-get inner) refs)]
    [(AstExprQuote inner)
      (selfhost-lint-dead-expr-refs (ast-node-get inner) refs)]
    [(AstExprQuasiquote inner)
      (selfhost-lint-dead-expr-refs (ast-node-get inner) refs)]
    [(AstExprUnquote inner)
      (selfhost-lint-dead-expr-refs (ast-node-get inner) refs)]
    [(AstExprUnquoteSplicing inner)
      (selfhost-lint-dead-expr-refs (ast-node-get inner) refs)]
    [(AstExprBracketClause items)
      (selfhost-lint-dead-expr-list-refs items refs)]
    [(AstExprTry inner)
      (selfhost-lint-dead-expr-refs (ast-node-get inner) refs)]
    [(AstExprReturn inner)
      (selfhost-lint-dead-expr-refs (ast-node-get inner) refs)]
    [(AstExprPtrNull ty) (selfhost-lint-dead-type-refs ty refs)]
    [(AstExprPtrNullCheck inner)
      (selfhost-lint-dead-expr-refs (ast-node-get inner) refs)]
    [(AstExprPtrAddrOf place)
      (selfhost-lint-dead-expr-refs (ast-node-get place) refs)]
    [(AstExprPtrRead ptr)
      (selfhost-lint-dead-expr-refs (ast-node-get ptr) refs)]
    [(AstExprPtrWrite ptr value)
      (selfhost-lint-dead-expr-refs
        (ast-node-get value)
        (selfhost-lint-dead-expr-refs (ast-node-get ptr) refs))]
    [(AstExprPtrOffset ptr offset)
      (selfhost-lint-dead-expr-refs
        (ast-node-get offset)
        (selfhost-lint-dead-expr-refs (ast-node-get ptr) refs))]
    [(AstExprPtrCast ptr ty)
      (selfhost-lint-dead-type-refs
        ty
        (selfhost-lint-dead-expr-refs (ast-node-get ptr) refs))]
    [(AstExprPtrToInt ptr)
      (selfhost-lint-dead-expr-refs (ast-node-get ptr) refs)]
    [(AstExprIntToPtr value ty)
      (selfhost-lint-dead-type-refs
        ty
        (selfhost-lint-dead-expr-refs (ast-node-get value) refs))]
    [(AstExprStringData inner)
      (selfhost-lint-dead-expr-refs (ast-node-get inner) refs)]
    [(AstExprStringFromBytes ptr len)
      (selfhost-lint-dead-expr-refs
        (ast-node-get len)
        (selfhost-lint-dead-expr-refs (ast-node-get ptr) refs))]
    [(AstExprArrayData inner)
      (selfhost-lint-dead-expr-refs (ast-node-get inner) refs)]
    [(AstExprBinaryData _) refs]
    [(AstExprProgramArgc) refs]
    [(AstExprProgramArgv) refs]
    [(AstExprProgramEnvp) refs]
    [(AstExprCpuIdEax leaf subleaf)
      (selfhost-lint-dead-expr-refs
        (ast-node-get subleaf)
        (selfhost-lint-dead-expr-refs (ast-node-get leaf) refs))]
    [(AstExprCpuIdEbx leaf subleaf)
      (selfhost-lint-dead-expr-refs
        (ast-node-get subleaf)
        (selfhost-lint-dead-expr-refs (ast-node-get leaf) refs))]
    [(AstExprCpuIdEcx leaf subleaf)
      (selfhost-lint-dead-expr-refs
        (ast-node-get subleaf)
        (selfhost-lint-dead-expr-refs (ast-node-get leaf) refs))]
    [(AstExprCpuIdEdx leaf subleaf)
      (selfhost-lint-dead-expr-refs
        (ast-node-get subleaf)
        (selfhost-lint-dead-expr-refs (ast-node-get leaf) refs))]
    [(AstExprXgetbv index)
      (selfhost-lint-dead-expr-refs (ast-node-get index) refs)]
    [(AstExprSyscall args) (selfhost-lint-dead-expr-list-refs args refs)]))

(define (selfhost-lint-dead-expr-span [expr-id : i64]) : AstSourceSpan
  (match (ast-node-get expr-id)
    [(AstExprSpanned _ span) span]
    [_ (lint-no-span)]))

(define (selfhost-lint-dead-find-prefix-from
  [source : String]
  [needle : String]
  [idx : i64]) : i64
  (let
    [source-len : i64 (string-length source)]
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
          (if (= (string-ref source i) #\newline')
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
          (if (= (string-ref source i) #\newline')
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
    [fn-needle : String (string-append "(define (" name)]
    [fn-idx : i64 (selfhost-lint-dead-find-prefix-from source fn-needle 0)]
    (if (>= fn-idx 0)
      (selfhost-lint-dead-index-span source fn-idx body-span)
      (selfhost-lint-dead-index-span
        source
        (selfhost-lint-dead-find-prefix-from
          source
          (string-append "(define " name)
          0)
        body-span))))

(define (selfhost-lint-dead-export-refs
  [items : AstExportItemList]
  [scan : SelfhostLintDeadScan]) : SelfhostLintDeadScan
  (match items
    [(AstExportItemNil) scan]
    [(AstExportItemCons item rest)
      (let
        [next : SelfhostLintDeadScan
          (match item
            [(AstExportValue name) (selfhost-lint-dead-scan-add-root scan name)]
            [(AstExportType name) (selfhost-lint-dead-scan-add-root scan name)]
            [(AstExportMacro name) (selfhost-lint-dead-scan-add-root scan name)]
            [(AstExportConstructor name)
              (selfhost-lint-dead-scan-add-root scan name)]
            [(AstExportField type-name field-name)
              (selfhost-lint-dead-scan-add-root
                (selfhost-lint-dead-scan-add-root scan type-name)
                field-name)]
            [(AstExportVariant name)
              (selfhost-lint-dead-scan-add-root scan name)])]
        (selfhost-lint-dead-export-refs (box-get rest) next))]))

(define (selfhost-lint-dead-refs-to-roots-from
  [scan : SelfhostLintDeadScan]
  [refs : StringVec]
  [index : i64]) : SelfhostLintDeadScan
  (if (>= index (string-vec-len refs))
    scan
    (selfhost-lint-dead-refs-to-roots-from
      (selfhost-lint-dead-scan-add-root scan (string-vec-get refs index ""))
      refs
      (+ index 1))))

(define (selfhost-lint-dead-refs-to-roots
  [scan : SelfhostLintDeadScan]
  [refs : StringVec]) : SelfhostLintDeadScan
  (selfhost-lint-dead-refs-to-roots-from scan refs 0))

(define (selfhost-lint-dead-field-cleanup-refs
  [cleanup : AstFieldCleanup]
  [refs : StringVec]) : StringVec
  (match cleanup
    [(AstFieldNoCleanup) refs]
    [(AstFieldCleanupFn name) (selfhost-lint-dead-ref-add-id refs name)]
    [(AstFieldOwnedCleanup) refs]))

(define (selfhost-lint-dead-field-def-list-refs
  [fields : AstFieldDefList]
  [refs : StringVec]) : StringVec
  (match fields
    [(AstFieldDefNil) refs]
    [(AstFieldDefCons field rest)
      (match field
        [(AstFieldDef _ ty cleanup)
          (selfhost-lint-dead-field-def-list-refs
            (box-get rest)
            (selfhost-lint-dead-field-cleanup-refs
              cleanup
              (selfhost-lint-dead-type-refs ty refs)))])]))

(define (selfhost-lint-dead-struct-cleanup-refs
  [cleanup : AstStructCleanup]
  [refs : StringVec]) : StringVec
  (match cleanup
    [(AstStructNoCleanup) refs]
    [(AstStructCleanupFn name) (selfhost-lint-dead-ref-add-id refs name)]))

(define (selfhost-lint-dead-enum-cleanup-refs
  [cleanup : AstEnumCleanup]
  [refs : StringVec]) : StringVec
  (match cleanup
    [(AstEnumNoCleanup) refs]
    [(AstEnumCleanupFn name) (selfhost-lint-dead-ref-add-id refs name)]))

(define (selfhost-lint-dead-variant-cleanup-refs
  [cleanup : AstVariantPayloadCleanup]
  [refs : StringVec]) : StringVec
  (match cleanup
    [(AstVariantPayloadNoCleanup) refs]
    [(AstVariantPayloadCleanupFn name)
      (selfhost-lint-dead-ref-add-id refs name)]
    [(AstVariantPayloadOwnedCleanup) refs]))

(define (selfhost-lint-dead-variant-cleanup-list-refs
  [items : AstVariantPayloadCleanupList]
  [refs : StringVec]) : StringVec
  (match items
    [(AstVariantPayloadCleanupNil) refs]
    [(AstVariantPayloadCleanupCons cleanup rest)
      (selfhost-lint-dead-variant-cleanup-list-refs
        (box-get rest)
        (selfhost-lint-dead-variant-cleanup-refs cleanup refs))]))

(define (selfhost-lint-dead-variant-def-list-refs
  [variants : AstVariantDefList]
  [refs : StringVec]) : StringVec
  (match variants
    [(AstVariantDefNil) refs]
    [(AstVariantDefCons variant rest)
      (match variant
        [(AstVariantDef name payloads cleanups)
          (selfhost-lint-dead-variant-def-list-refs
            (box-get rest)
            (selfhost-lint-dead-variant-cleanup-list-refs
              cleanups
              (selfhost-lint-dead-type-list-refs
                payloads
                (selfhost-lint-dead-ref-add-id refs name))))])]))

(define (selfhost-lint-dead-dispatch-variant-list-refs
  [variants : AstDispatchVariantList]
  [refs : StringVec]) : StringVec
  (match variants
    [(AstDispatchVariantNil) refs]
    [(AstDispatchVariantCons variant rest)
      (match variant
        [(AstDispatchVariant _ name)
          (selfhost-lint-dead-dispatch-variant-list-refs
            (box-get rest)
            (selfhost-lint-dead-ref-add refs name))])]))

(define (selfhost-lint-dead-extern-abi-refs
  [abi : AstExternAbi]
  [refs : StringVec]) : StringVec
  (match abi
    [(AstExternAbiC) refs]
    [(AstExternAbiCVarargsOpen) refs]
    [(AstExternAbiCVarargsTyped tail-ty)
      (selfhost-lint-dead-type-refs tail-ty refs)]))

(define (selfhost-lint-dead-extern-metadata-refs
  [meta : AstExternMetadata]
  [refs : StringVec]) : StringVec
  (match meta
    [(AstExternMetadata abi _ _ _)
      (selfhost-lint-dead-extern-abi-refs abi refs)]))

(define (selfhost-lint-dead-generated-meta-refs
  [meta : AstGeneratedDeclMeta]
  [refs : StringVec]) : StringVec
  (match meta
    [(AstNoGeneratedDeclMeta) refs]
    [(AstSomeGeneratedDeclMeta _ _ args _)
      (selfhost-lint-dead-expr-list-refs args refs)]))

(define (selfhost-lint-dead-add-node
  [scan : SelfhostLintDeadScan]
  [path : String]
  [name : String]
  [span : AstSourceSpan]
  [refs : StringVec]
  [reportable : bool]) : SelfhostLintDeadScan
  (selfhost-lint-dead-scan-add-decl
    scan
    (SelfhostLintDeadDecl path name span refs false reportable)))

(define (selfhost-lint-dead-scan-decl
  [scan : SelfhostLintDeadScan]
  [path : String]
  [source : String]
  [decl : AstDecl]
  [allow-report : bool]) : SelfhostLintDeadScan
  (match decl
    [(AstDeclModule _) scan]
    [(AstDeclDef name maybe-ty body)
      (let
        [text : String (intern-str name)]
        [refs : StringVec
          (selfhost-lint-dead-expr-refs
            (ast-node-get body)
            (selfhost-lint-dead-maybe-type-refs maybe-ty (string-vec-new)))]
        [span : AstSourceSpan
          (selfhost-lint-dead-decl-span
            source
            text
            (selfhost-lint-dead-expr-span body))]
        [with-node : SelfhostLintDeadScan
          (selfhost-lint-dead-add-node
            scan
            path
            text
            span
            refs
            (and allow-report (not (string-eq text "main"))))]
        (if (string-eq text "main")
          (selfhost-lint-dead-scan-add-root with-node text)
          with-node))]
    [(AstDeclDefFn name params ret body export)
      (let
        [text : String (intern-str name)]
        [refs : StringVec
          (selfhost-lint-dead-expr-refs
            (ast-node-get body)
            (selfhost-lint-dead-type-refs
              ret
              (selfhost-lint-dead-param-list-refs params (string-vec-new))))]
        [span : AstSourceSpan
          (selfhost-lint-dead-decl-span
            source
            text
            (selfhost-lint-dead-expr-span body))]
        [is-exported : bool
          (match export
            [(AstFnNoExport) false]
            [(AstFnExport _) true])]
        [is-main : bool (string-eq text "main")]
        [with-node : SelfhostLintDeadScan
          (selfhost-lint-dead-add-node
            scan
            path
            text
            span
            refs
            (if allow-report
              (if is-exported
                false
                (not is-main))
              false))]
        (if (or is-exported is-main)
          (selfhost-lint-dead-scan-add-root with-node text)
          with-node))]
    [(AstDeclDefMacro name params ret body)
      (selfhost-lint-dead-add-node
        scan
        path
        (intern-str name)
        (selfhost-lint-dead-expr-span body)
        (selfhost-lint-dead-expr-refs
          (ast-node-get body)
          (selfhost-lint-dead-type-refs
            ret
            (selfhost-lint-dead-macro-param-list-refs params (string-vec-new))))
        false)]
    [(AstDeclExtern name _ meta ty)
      (selfhost-lint-dead-add-node
        scan
        path
        (intern-str name)
        (lint-no-span)
        (selfhost-lint-dead-type-refs
          ty
          (selfhost-lint-dead-extern-metadata-refs meta (string-vec-new)))
        false)]
    [(AstDeclDefEnum name cleanup variants)
      (selfhost-lint-dead-add-node
        scan
        path
        (intern-str name)
        (lint-no-span)
        (selfhost-lint-dead-variant-def-list-refs
          variants
          (selfhost-lint-dead-enum-cleanup-refs cleanup (string-vec-new)))
        false)]
    [(AstDeclDefEnumLifetimes name _ cleanup variants)
      (selfhost-lint-dead-add-node
        scan
        path
        (intern-str name)
        (lint-no-span)
        (selfhost-lint-dead-variant-def-list-refs
          variants
          (selfhost-lint-dead-enum-cleanup-refs cleanup (string-vec-new)))
        false)]
    [(AstDeclDefStruct name _ cleanup fields)
      (selfhost-lint-dead-add-node
        scan
        path
        (intern-str name)
        (lint-no-span)
        (selfhost-lint-dead-field-def-list-refs
          fields
          (selfhost-lint-dead-struct-cleanup-refs cleanup (string-vec-new)))
        false)]
    [(AstDeclDefStructLifetimes name _ _ cleanup fields)
      (selfhost-lint-dead-add-node
        scan
        path
        (intern-str name)
        (lint-no-span)
        (selfhost-lint-dead-field-def-list-refs
          fields
          (selfhost-lint-dead-struct-cleanup-refs cleanup (string-vec-new)))
        false)]
    [(AstDeclImport (AstImportSpec (AstImportMacro call-expr) _ _ _ _))
      (selfhost-lint-dead-refs-to-roots
        scan
        (selfhost-lint-dead-expr-refs (ast-node-get call-expr) (string-vec-new)))]
    [(AstDeclImport (AstImportSpec (AstImportMacroDecls call-expr) _ _ _ _))
      (selfhost-lint-dead-refs-to-roots
        scan
        (selfhost-lint-dead-expr-refs (ast-node-get call-expr) (string-vec-new)))]
    [(AstDeclImport _) scan]
    [(AstDeclIncludeStr _ _) scan]
    [(AstDeclIncludeBin _ _) scan]
    [(AstDeclExport items) (selfhost-lint-dead-export-refs items scan)]
    [(AstDeclDefDispatch name variants)
      (selfhost-lint-dead-add-node
        scan
        path
        (intern-str name)
        (lint-no-span)
        (selfhost-lint-dead-dispatch-variant-list-refs
          variants
          (string-vec-new))
        false)]
    [(AstDeclTest _ body _)
      (selfhost-lint-dead-refs-to-roots
        scan
        (selfhost-lint-dead-expr-refs (ast-node-get body) (string-vec-new)))]
    [(AstDeclUnsafe inner)
      (selfhost-lint-dead-scan-decl
        scan
        path
        source
        (box-get inner)
        allow-report)]
    [(AstDeclComptimeDecl meta inner)
      (selfhost-lint-dead-refs-to-roots
        (selfhost-lint-dead-scan-decl scan path source (box-get inner) false)
        (selfhost-lint-dead-generated-meta-refs meta (string-vec-new)))]))

(define (selfhost-lint-dead-scan-decls
  [scan : SelfhostLintDeadScan]
  [path : String]
  [source : String]
  [decls : AstDeclList]) : SelfhostLintDeadScan
  (match decls
    [(AstDeclNil) scan]
    [(AstDeclCons decl rest)
      (selfhost-lint-dead-scan-decls
        (selfhost-lint-dead-scan-decl scan path source decl true)
        path
        source
        (box-get rest))]))

(define (selfhost-lint-dead-scan-source
  [scan : SelfhostLintDeadScan]
  [path : String]
  [source : String]) : SelfhostLintDeadScan
  (match (parse-ast-source-diagnostic path source)
    [(OkAstProgramDiagnostic program)
      (match program
        [(AstProgram decls-box)
          (selfhost-lint-dead-scan-decls scan path source (box-get decls-box))])]
    [(ErrAstProgramDiagnostic _) scan]))

(define (selfhost-lint-package-dead-scan-files
  [sources : StringVec]
  [index : i64]
  [scan : SelfhostLintDeadScan]) : SelfhostLintDeadScan
  (if (>= index (string-vec-len sources))
    scan
    (let
      [path : String (string-vec-get sources index "")]
      (selfhost-lint-package-dead-scan-files
        sources
        (+ index 1)
        (selfhost-lint-dead-scan-source scan path (read-file path))))))

(define (selfhost-lint-dead-decls-index-of-from
  [items : SelfhostLintDeadDecls]
  [name : String]
  [index : i64]) : i64
  (if (>= index (selfhost-lint-dead-decls-count items))
    (- 0 1)
    (if (string-eq
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
  [refs : StringVec]
  [index : i64]) : SelfhostLintDeadDecls
  (if (>= index (string-vec-len refs))
    items
    (selfhost-lint-dead-mark-refs-from
      (selfhost-lint-dead-mark-reachable-name
        items
        (string-vec-get refs index ""))
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
  [roots : StringVec]
  [index : i64]) : SelfhostLintDeadDecls
  (if (>= index (string-vec-len roots))
    items
    (selfhost-lint-dead-mark-roots-from
      (selfhost-lint-dead-mark-reachable-name
        items
        (string-vec-get roots index ""))
      roots
      (+ index 1))))

(define (selfhost-lint-package-dead-code [sources : StringVec]) : SelfhostLintDeadDecls
  (let
    [scan : SelfhostLintDeadScan
      (selfhost-lint-package-dead-scan-files
        sources
        0
        (SelfhostLintDeadScan (selfhost-lint-dead-decls-empty) (string-vec-new)))]
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
          (string-eq (struct-get decl path) path)
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
          (string-eq (struct-get decl path) path)
          (selfhost-lint-package-dead-finding-active? source decl))
          (begin
            (print-string
              (string-append
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
  [stdlib-roots : StringVec]
  [enforcing : bool]
  [deprecated-string-concat : bool]) : i64
  (let
    [source : String (read-file input-path)]
    (match (parse-ast-source-diagnostic input-path source)
      [(OkAstProgramDiagnostic program)
        (let
          [findings : LintFindings
            (selfhost-lint-program-and-typed-findings
              input-path
              source
              program
              stdlib-roots
              deprecated-string-concat)]
          (begin
            (selfhost-lint-print-findings input-path findings)
            (print-string
              (string-append
                "lint: "
                (string-append
                  (int->string (lint-findings-count findings))
                  " finding(s)\n")))
            (selfhost-lint-enforce-exit
              enforcing
              (lint-findings-count findings))))]
      [(ErrAstProgramDiagnostic diag)
        (begin
          (print-error (compiler-diagnostic-render diag))
          1)])))

(define (selfhost-lint-file-with-package-dead
  [input-path : String]
  [stdlib-roots : StringVec]
  [enforcing : bool]
  [deprecated-string-concat : bool]
  [dead-decls : SelfhostLintDeadDecls]) : i64
  (let
    [source : String (read-file input-path)]
    (match (parse-ast-source-diagnostic input-path source)
      [(OkAstProgramDiagnostic program)
        (let
          [findings : LintFindings
            (selfhost-lint-program-and-typed-findings
              input-path
              source
              program
              stdlib-roots
              deprecated-string-concat)]
          [ordinary-count : i64
            (selfhost-lint-print-findings input-path findings)]
          [dead-count : i64
            (selfhost-lint-package-dead-print-for-source
              input-path
              source
              dead-decls)]
          [total-count : i64 (+ ordinary-count dead-count)]
          (begin
            (print-string
              (string-append
                "lint: "
                (string-append (int->string total-count) " finding(s)\n")))
            (selfhost-lint-enforce-exit enforcing total-count)))]
      [(ErrAstProgramDiagnostic diag)
        (begin
          (print-error (compiler-diagnostic-render diag))
          1)])))

(define (selfhost-lint-files-from
  [input-paths : StringVec]
  [index : i64]
  [stdlib-roots : StringVec]
  [enforcing : bool]
  [deprecated-string-concat : bool]
  [print-headers : bool]
  [status : i64]) : i64
  (if (>= index (string-vec-len input-paths))
    status
    (let
      [input-path : String (string-vec-get input-paths index "")]
      [file-status : i64
        (begin
          (if print-headers
            (print-string
              (string-append "--- " (string-append input-path "\n")))
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
  [input-paths : StringVec]
  [stdlib-roots : StringVec]
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
  [input-paths : StringVec]
  [index : i64]
  [stdlib-roots : StringVec]
  [enforcing : bool]
  [deprecated-string-concat : bool]
  [dead-decls : SelfhostLintDeadDecls]
  [print-headers : bool]
  [status : i64]) : i64
  (if (>= index (string-vec-len input-paths))
    status
    (let
      [input-path : String (string-vec-get input-paths index "")]
      [file-status : i64
        (begin
          (if print-headers
            (print-string
              (string-append "--- " (string-append input-path "\n")))
            unit)
          (selfhost-lint-file-with-package-dead
            input-path
            stdlib-roots
            enforcing
            deprecated-string-concat
            dead-decls))]
      (selfhost-lint-package-files-from
        input-paths
        (+ index 1)
        stdlib-roots
        enforcing
        deprecated-string-concat
        dead-decls
        print-headers
        (if (= status 0)
          file-status
          status)))))

(define (selfhost-lint-package-files
  [input-paths : StringVec]
  [stdlib-roots : StringVec]
  [enforcing : bool]
  [deprecated-string-concat : bool]
  [dead-decls : SelfhostLintDeadDecls]
  [print-headers : bool]
  [status : i64]) : i64
  (selfhost-lint-package-files-from
    input-paths
    0
    stdlib-roots
    enforcing
    deprecated-string-concat
    dead-decls
    print-headers
    status))

(define (selfhost-lint-package
  [manifest-path : String]
  [has-manifest : bool]
  [stdlib-roots : StringVec]
  [enforcing : bool]
  [deprecated-string-concat : bool]) : i64
  (match (package-source-discover-for "lint" manifest-path has-manifest)
    [(ErrPackageSourceSet message)
      (begin
        (print-error (string-append message "\n"))
        1)]
    [(OkPackageSourceSet source-set)
      (let
        [sources : StringVec (struct-get source-set sources)]
        [dead-decls : SelfhostLintDeadDecls
          (selfhost-lint-package-dead-code sources)]
        (selfhost-lint-package-files
          sources
          stdlib-roots
          enforcing
          deprecated-string-concat
          dead-decls
          (> (string-vec-len sources) 1)
          0))]))

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
            (> (string-vec-len input-paths) 1)
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
        (print-error (string-append message "\n"))
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

(define (selfhost-lint-used-import-export-source) : String
  "(import pkg.data)
(export (value data.value))")

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
  "(export (value public-api))
(define (public-api [x : i64]) : i64 (helper x))
(define (helper [x : i64]) : i64 (cross-file-helper x))
(define (unused-private) : i64 1)
;; lint-allow: dead-code
(define (suppressed-unused) : i64 2)")

(define (selfhost-lint-package-dead-source-b) : String
  (string-append
    "(define (cross-file-helper [x : i64]) : i64 (+ x 1))
(define (test-only-helper) : i64 3)
"
    (string-append "(te" "st \"test-only\" (test-only-helper))")))

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
      (string-vec-new))))

(define (selfhost-lint-findings-rule-count-from
  [findings : LintFindings]
  [rule-id : String]
  [index : i64]
  [count : i64]) : i64
  (if (>= index (lint-findings-count findings))
    count
    (match (lint-findings-get findings index)
      [(LintSomeFinding finding)
        (selfhost-lint-findings-rule-count-from
          findings
          rule-id
          (+ index 1)
          (if (string-eq (struct-get finding rule-id) rule-id)
            (+ count 1)
            count))]
      [(LintNoFinding)
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
      (string-vec-new))
    rule-id))

(define (selfhost-lint-unused-import-finding-ok? [findings : LintFindings]) : bool
  (match (lint-findings-get findings 0)
    [(LintSomeFinding finding)
      (let
        [fspan : AstSourceSpan (struct-get finding span)]
        (and
          (= (lint-findings-count findings) 1)
          (> (struct-get fspan start-line) 0)
          (string-eq (struct-get finding rule-id) (lint-rule-unused-import-id))))]
    [(LintNoFinding) false]))

(define (selfhost-lint-unused-imports-self-test) : i64
  (let
    [unused : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-unused-dotted-import-source)
        (string-vec-new))]
    [unused-path-alias : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-unused-explicit-path-alias-source)
        (string-vec-new))]
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
              (selfhost-lint-used-import-export-source))
            0))
        39]
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

(define (selfhost-lint-package-dead-code-self-test) : i64
  (let
    [source-a : String (selfhost-lint-package-dead-source-a)]
    [source-b : String (selfhost-lint-package-dead-source-b)]
    [scan-a : SelfhostLintDeadScan
      (selfhost-lint-dead-scan-source
        (SelfhostLintDeadScan (selfhost-lint-dead-decls-empty) (string-vec-new))
        "pkg/a.tl"
        source-a)]
    [scan-b : SelfhostLintDeadScan
      (selfhost-lint-dead-scan-source scan-a "pkg/b.tl" source-b)]
    [decls : SelfhostLintDeadDecls
      (selfhost-lint-dead-mark-roots-from
        (struct-get scan-b decls)
        (struct-get scan-b roots)
        0)]
    [count-a : i64
      (selfhost-lint-package-dead-count-for-source "pkg/a.tl" source-a decls)]
    [count-b : i64
      (selfhost-lint-package-dead-count-for-source "pkg/b.tl" source-b decls)]
    (cond
      [(not (= count-a 1)) 50]
      [(not (= count-b 0)) 51]
      [(not
          (string-eq
            (lint-rule-message (lint-rule-dead-code-id))
            (lint-rule-dead-code-message)))
        52]
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
          (string-eq
            (lint-rule-message rule)
            (lint-rule-unused-assignment-message)))
        56]
      [else 42])))

;; Compatibility helper retained for the nested-if-ladder metadata shape.
(define (selfhost-lint-reported-finding-ok? [findings : LintFindings]) : bool
  (match (lint-findings-get findings 0)
    [(LintSomeFinding finding)
      (let
        [fspan : AstSourceSpan (struct-get finding span)]
        (and
          (= (struct-get finding depth) 5)
          (> (struct-get fspan start-line) 0)
          (string-eq
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
          (string-eq (struct-get finding rule-id) (lint-rule-nested-let-id))))]
    [(LintNoFinding) false]))

(define (selfhost-lint-return-path-finding-ok? [findings : LintFindings]) : bool
  (match (lint-findings-get findings 0)
    [(LintSomeFinding finding)
      (let
        [fspan : AstSourceSpan (struct-get finding span)]
        (and
          (= (struct-get finding depth) 3)
          (> (struct-get fspan start-line) 0)
          (string-eq
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
          (string-eq (struct-get finding rule-id) (lint-rule-unit-if-guard-id))))]
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
          (string-eq
            (struct-get finding rule-id)
            (lint-rule-cascading-and-or-id))
          (string-eq (struct-get finding message) message)))]
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
        (string-vec-new))]
    [return-reported : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-return-path-chain-source)
        (string-vec-new))]
    [unit-reported : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-unit-if-source)
        (string-vec-new))]
    [unit-set-reported : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-unit-set-source)
        (string-vec-new))]
    [two-reported : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-two-findings-source)
        (string-vec-new))]
    [cascading-and-reported : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-cascading-and-source)
        (string-vec-new))]
    [cascading-or-reported : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-cascading-or-source)
        (string-vec-new))]
    [cascading-core-and-reported : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-cascading-core-and-source)
        (string-vec-new))]
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
              (string-vec-new))))
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
      [(not (= (selfhost-lint-enforce-exit true 1) 1)) 6]
      [(not (= (selfhost-lint-enforce-exit true 0) 0)) 7]
      [(not (= (selfhost-lint-enforce-exit false 1) 0)) 8]
      [else 42])))