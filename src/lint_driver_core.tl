;; lint_driver_core.tl - Driver logic for the selfhost `typelisp lint` tool:
;; load a TypeLisp source, run the lint_core rules over its program, and
;; render each finding through the shared source diagnostic renderer. Kept
;; main-less so both the CLI driver (`lint.tl`) and the runnable smoke
;; (`lint_driver_smoke.tl`) can import it. Warn-only by default; callers can pass
;; `--check` after the input path to exit non-zero when findings remain, or
;; `--format flat` for the stable `path:line:col: message` machine format. The
;; deprecated string.concat rule and staged migration rules are opt-in.
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.arena)
(import stdlib.vector)
(import (vector.vector String) as lint_svec)
(import compiler_check_core)
(import compiler_ast_types as ast)
(import compiler_target_cfg_core as target_cfg)
(import compiler_load)
(import compiler_diagnostic as cdiag)
(import compiler_typecheck_core as tc)
(import compiler_intern as ci)
(import compiler_parse_core as parser)
(import lint_core)
(import package_source_core)
(import stdlib.string)
(import sym_i64_env)

(defmacro (selfhost-lint-global-shared-view [place : Expr]) : Expr
  (cfg
    stage0-seed-bootstrap
    place
    `(unsafe
      (ptr-read (ptr-addr-of ,place)))))

(defmacro (selfhost-lint-global-array-element-shared-view
  [items : Expr]
  [index : Expr]) : Expr
  (cfg
    stage0-seed-bootstrap
    `(array-ref ,items ,index)
    `(unsafe
      (ptr-read (ptr-offset (__tl_array-data ,items) ,index)))))

;; Parsed lint CLI config: input paths, stdlib roots, whether `--check`
;; enforcing mode was requested (exit non-zero when findings are present), and
;; whether staged migration rules are enabled.
(defenum SelfhostLintConfig
  (File lint_svec.Vec lint_svec.Vec bool bool bool bool bool)
  (Package String bool lint_svec.Vec bool bool bool bool bool))

(defenum ResultSelfhostLintConfig
  (Ok SelfhostLintConfig)
  (Err String))

(define selfhost-lint-language-target : target_cfg.CompilerTargetCfg
  (target_cfg.compiler-target-cfg-default))
(define selfhost-lint-language-cfg-names : lint_svec.Vec
  (lint_svec.new))
(define selfhost-lint-cli-has-target : bool
  false)
(define selfhost-lint-flat-output : bool
  false)

;; Test/driver hook: module globals are private, so smokes flip the renderer
;; through this setter instead of assigning the global directly.
(define (selfhost-lint-set-flat-output! [enabled : bool]) : unit
  (set! selfhost-lint-flat-output enabled))

(define (selfhost-lint-language-config-reset!) : unit
  (begin
    (set!
      selfhost-lint-language-target
      (target_cfg.compiler-target-cfg-default))
    (set! selfhost-lint-language-cfg-names (lint_svec.new))
    (set! selfhost-lint-cli-has-target false)
    (set! selfhost-lint-flat-output false)))

(define (selfhost-lint-language-cfgs) : sym_i64_env.SymI64Env
  (target_cfg.compiler-target-cfgs-with-names
    selfhost-lint-language-target
    (selfhost-lint-global-shared-view selfhost-lint-language-cfg-names)))

(define (selfhost-lint-flag? [value : String]) : bool
  (and (> (string.string-length value) 0) (= (string.string-ref value 0) '-')))

(define (selfhost-lint-config-finish
  [input-paths : lint_svec.Vec]
  [manifest-path : String]
  [has-manifest : bool]
  [stdlib-roots : lint_svec.Vec]
  [enforcing : bool]
  [deprecated-string-concat : bool]
  [redundant-function-name : bool]
  [prefer-dotted-field : bool]
  [name-case : bool]) : ResultSelfhostLintConfig
  (if (lint_svec.is-empty? (& input-paths))
    (ResultSelfhostLintConfig.Ok
      (SelfhostLintConfig.Package
        manifest-path
        has-manifest
        stdlib-roots
        enforcing
        deprecated-string-concat
        redundant-function-name
        prefer-dotted-field
        name-case))
    (if has-manifest
      (ResultSelfhostLintConfig.Err
        "selfhost-lint: cannot combine input paths with --manifest-path")
      (ResultSelfhostLintConfig.Ok
        (SelfhostLintConfig.File
          input-paths
          stdlib-roots
          enforcing
          deprecated-string-concat
          redundant-function-name
          prefer-dotted-field
          name-case)))))

(define (selfhost-lint-parse-options
  [idx : i64]
  [count : i64]
  [input-paths : lint_svec.Vec (:consume)]
  [manifest-path : String]
  [has-manifest : bool]
  [stdlib-roots : lint_svec.Vec (:consume)]
  [enforcing : bool]
  [deprecated-string-concat : bool]
  [redundant-function-name : bool]
  [prefer-dotted-field : bool]
  [name-case : bool]) : ResultSelfhostLintConfig
  (if (>= idx count)
    (selfhost-lint-config-finish
      input-paths
      manifest-path
      has-manifest
      stdlib-roots
      enforcing
      deprecated-string-concat
      redundant-function-name
      prefer-dotted-field
      name-case)
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
            redundant-function-name
            prefer-dotted-field
            name-case)]
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
            redundant-function-name
            prefer-dotted-field
            name-case)]
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
            true
            prefer-dotted-field
            name-case)]
        [(string.eq current "--prefer-dotted-field")
          (selfhost-lint-parse-options
            (+ idx 1)
            count
            input-paths
            manifest-path
            has-manifest
            stdlib-roots
            enforcing
            deprecated-string-concat
            redundant-function-name
            true
            name-case)]
        [(string.eq current "--name-case")
          (selfhost-lint-parse-options
            (+ idx 1)
            count
            input-paths
            manifest-path
            has-manifest
            stdlib-roots
            enforcing
            deprecated-string-concat
            redundant-function-name
            prefer-dotted-field
            true)]
        [(string.eq current "--format")
          (if (>= (+ idx 1) count)
            (ResultSelfhostLintConfig.Err
              "selfhost-lint: --format requires a value")
            (let
              [format : String (io.arg (+ idx 1))]
              (cond
                [(string.eq format "flat")
                  (begin
                    (set! selfhost-lint-flat-output true)
                    (selfhost-lint-parse-options
                      (+ idx 2)
                      count
                      input-paths
                      manifest-path
                      has-manifest
                      stdlib-roots
                      enforcing
                      deprecated-string-concat
                      redundant-function-name
                      prefer-dotted-field
                      name-case))]
                [(string.eq format "rich")
                  (begin
                    (set! selfhost-lint-flat-output false)
                    (selfhost-lint-parse-options
                      (+ idx 2)
                      count
                      input-paths
                      manifest-path
                      has-manifest
                      stdlib-roots
                      enforcing
                      deprecated-string-concat
                      redundant-function-name
                      prefer-dotted-field
                      name-case))]
                [else
                  (ResultSelfhostLintConfig.Err
                    (str_cat.str-cat
                      "selfhost-lint: unsupported --format "
                      format
                      " (expected rich or flat)"))])))]
        [(string.eq current "--cfg")
          (if (>= (+ idx 1) count)
            (ResultSelfhostLintConfig.Err
              "selfhost-lint: --cfg requires a value")
            (begin
              (lint_svec.push-ref!
                (&mut selfhost-lint-language-cfg-names)
                (io.arg (+ idx 1)))
              (selfhost-lint-parse-options
                (+ idx 2)
                count
                input-paths
                manifest-path
                has-manifest
                stdlib-roots
                enforcing
                deprecated-string-concat
                redundant-function-name
                prefer-dotted-field
                name-case)))]
        [(string.eq current "--target")
          (if (>= (+ idx 1) count)
            (ResultSelfhostLintConfig.Err
              "selfhost-lint: --target requires a value")
            (if selfhost-lint-cli-has-target
              (ResultSelfhostLintConfig.Err
                "selfhost-lint: --target was provided more than once")
              (match (target_cfg.compiler-target-cfg-parse (io.arg (+ idx 1)))
                [(target_cfg.ResultCompilerTargetCfg.Ok parsed-target)
                  (begin
                    (set! selfhost-lint-language-target parsed-target)
                    (set! selfhost-lint-cli-has-target true)
                    (selfhost-lint-parse-options
                      (+ idx 2)
                      count
                      input-paths
                      manifest-path
                      has-manifest
                      stdlib-roots
                      enforcing
                      deprecated-string-concat
                      redundant-function-name
                      prefer-dotted-field
                      name-case))]
                [(target_cfg.ResultCompilerTargetCfg.Err message)
                  (ResultSelfhostLintConfig.Err
                    (str_cat.str-cat "selfhost-lint: " message))])))]
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
              (let
                [next-roots : lint_svec.Vec stdlib-roots]
                (begin
                  (lint_svec.push-ref! (&mut next-roots) (io.arg (+ idx 1)))
                  next-roots))
              enforcing
              deprecated-string-concat
              redundant-function-name
              prefer-dotted-field
              name-case))]
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
                redundant-function-name
                prefer-dotted-field
                name-case)))]
        [(selfhost-lint-flag? current)
          (ResultSelfhostLintConfig.Err
            (str_cat.str-cat "selfhost-lint: unknown flag " current))]
        [else
          (selfhost-lint-parse-options
            (+ idx 1)
            count
            (let
              [next-paths : lint_svec.Vec input-paths]
              (begin
                (lint_svec.push-ref! (&mut next-paths) current)
                next-paths))
            manifest-path
            has-manifest
            stdlib-roots
            enforcing
            deprecated-string-concat
            redundant-function-name
            prefer-dotted-field
            name-case)]))))

;; Parse the `lint` config from arguments starting at `start`.
(define (selfhost-lint-config-from [start : i64] [count : i64]) : ResultSelfhostLintConfig
  (begin
    (selfhost-lint-language-config-reset!)
    (selfhost-lint-parse-options
      start
      count
      (lint_svec.new)
      ""
      false
      (lint_svec.new)
      false
      false
      false
      false
      false)))

;; Convert a finding to the common diagnostic model. The diagnostic code is
;; deliberately the lint suppression key printed by `lint-allow`.
(define (selfhost-lint-finding-diagnostic
  [path : String]
  [finding : lint_core.LintFinding]) : cdiag.CompilerDiagnostic
  (let
    [fspan : ast.AstSourceSpan finding.span]
    [rule-id : String finding.rule-id]
    [suggestion : String
      (lint_core.lint-rule-suggestion (string.copy (& rule-id)))]
    (cdiag.compiler-diagnostic-with-help
      (cdiag.compiler-diagnostic-with-code
        (cdiag.compiler-diagnostic-with-level
          (cdiag.compiler-diagnostic-from-ast-span path fspan finding.message)
          cdiag.CompilerDiagnosticWarning)
        rule-id)
      suggestion)))

;; Rich diagnostics are the human-facing default. `--format flat` preserves the
;; historical line-oriented form for scripts and editors that parse it.
(define (selfhost-lint-render-finding
  [path : String]
  [source : String]
  [finding : lint_core.LintFinding]) : String
  (let
    [diag : cdiag.CompilerDiagnostic
      (selfhost-lint-finding-diagnostic path finding)]
    (if selfhost-lint-flat-output
      (cdiag.compiler-diagnostic-render diag)
      (cdiag.compiler-diagnostic-render-source diag source))))

(define (selfhost-lint-render-finding-line
  [path : String]
  [source : String]
  [finding : lint_core.LintFinding]) : String
  (let
    [rendered : String (selfhost-lint-render-finding path source finding)]
    (if selfhost-lint-flat-output
      (str_cat.str-cat rendered "\n")
      rendered)))

;; Print every finding to stdout; returns the number printed.
;; Findings are stored in discovery order, so render backward to preserve the
;; historical list-accumulator output order.
(define (selfhost-lint-print-findings-from
  [path : String]
  [source : String]
  [items : lint_core.LintFindings]
  [index : i64]
  [printed : i64]) : i64
  (if (< index 0)
    printed
    (begin
      (io.print-format
        "{}"
        (selfhost-lint-render-finding-line
          path
          source
          (lint_core.lint-findings-ref items index)))
      (selfhost-lint-print-findings-from
        path
        source
        items
        (- index 1)
        (+ printed 1)))))

(define (selfhost-lint-print-findings
  [path : String]
  [source : String]
  [items : lint_core.LintFindings]) : i64
  (selfhost-lint-print-findings-from
    path
    source
    items
    (- (lint_core.lint-findings-count items) 1)
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
  [span : ast.AstSourceSpan]) : i64
  (+
    (selfhost-lint-line-start-index
      source
      (ast.ast-source-span-start-line span))
    (- (ast.ast-source-span-start-col span) 1)))

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
  [span : ast.AstSourceSpan]) : i64
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
    [needle : String (str_cat.str-cat "lint-allow: " rule-id)]
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
(define (selfhost-lint-suppressed?
  [source : String]
  [finding : lint_core.LintFinding]) : bool
  (let
    [span : ast.AstSourceSpan finding.span]
    [line : i64 (ast.ast-source-span-start-line span)]
    [rule-id : String finding.rule-id]
    (if (<= line 1)
      false
      (selfhost-lint-line-allows? source (- line 1) rule-id))))

(define (selfhost-lint-form-origin?
  [source : String]
  [span : ast.AstSourceSpan]
  [form-name : String]) : bool
  (let
    [line : i64 (ast.ast-source-span-start-line span)]
    [col : i64 (ast.ast-source-span-start-col span)]
    (if (or (<= line 0) (<= col 0))
      false
      (let
        [needle : String (str_cat.str-cat "(" form-name)]
        [line-start : i64 (selfhost-lint-line-start-index source line)]
        [idx : i64 (+ line-start (- col 1))]
        (and
          (selfhost-lint-prefix-at? source idx needle)
          (selfhost-lint-form-delim?
            source
            (+ idx (string.string-length needle))))))))

(define (selfhost-lint-derived-form-origin?
  [source : String]
  [span : ast.AstSourceSpan]) : bool
  (or
    (selfhost-lint-form-origin? source span "cond")
    (selfhost-lint-form-origin? source span "when")
    (selfhost-lint-form-origin? source span "unless")))

(define (selfhost-lint-source-multiform-single-begin?
  [source : String]
  [finding : lint_core.LintFinding]) : bool
  (and
    (string.eq finding.rule-id (lint_core.lint-rule-single-begin-id))
    (> (selfhost-lint-begin-source-form-count source finding.span) 1)))

(define (selfhost-lint-filter-derived-origins-from
  [source : String]
  [items : lint_core.LintFindings]
  [index : i64]
  [out : lint_core.LintFindings]) : lint_core.LintFindings
  (if (>= index (lint_core.lint-findings-count items))
    out
    (let
      [finding : lint_core.LintFinding
        (lint_core.lint-findings-ref items index)]
      [next : lint_core.LintFindings
        (if (or
          (selfhost-lint-derived-form-origin? source finding.span)
          (selfhost-lint-source-multiform-single-begin? source finding)
          (selfhost-lint-suppressed? source finding))
          out
          (lint_core.lint-findings-add finding out))]
      (selfhost-lint-filter-derived-origins-from source items (+ index 1) next))))

(define (selfhost-lint-filter-derived-origins
  [source : String]
  [items : lint_core.LintFindings]) : lint_core.LintFindings
  (selfhost-lint-filter-derived-origins-from
    source
    items
    0
    (lint_core.lint-findings-empty)))

(define (selfhost-lint-program-findings-with-all-options
  [source : String]
  [program : ast.AstProgram]
  [deprecated-string-concat : bool]
  [redundant-function-name : bool]
  [_prefer-dotted-field : bool]
  [name-case : bool]) : lint_core.LintFindings
  (match program
    [(ast.AstProgram.Program decls-box)
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
        [base : lint_core.LintFindings
          (lint_core.lint-program-with-source-options
            source
            (ast.ast-program decls)
            (lint_core.lint-default-ladder-threshold)
            deprecated-string-concat
            name-case)]
        [with-redundant : lint_core.LintFindings
          (if redundant-function-name
            (lint_core.lint-redundant-function-names-in-program
              source
              (ast.ast-program decls)
              base)
            base)]
        ;; Dotted field projection is now the only public spelling. Keep the
        ;; staged option as a no-op for command-line compatibility.
        [with-prefer : lint_core.LintFindings with-redundant]
        (selfhost-lint-filter-derived-origins source with-prefer))]))

(define (selfhost-lint-findings-append-from
  [src : lint_core.LintFindings]
  [index : i64]
  [out : lint_core.LintFindings]) : lint_core.LintFindings
  (if (>= index (lint_core.lint-findings-count src))
    out
    (selfhost-lint-findings-append-from
      src
      (+ index 1)
      (lint_core.lint-findings-add (lint_core.lint-findings-ref src index) out))))

(define (selfhost-lint-findings-append
  [left : lint_core.LintFindings]
  [right : lint_core.LintFindings]) : lint_core.LintFindings
  (selfhost-lint-findings-append-from right 0 left))

(defstruct SelfhostLintUnsafeSurfaceName
  (name String)
  (requires-unsafe bool))

;; Append-only and read front to back: contiguous slots with a doubling push.
(defstruct SelfhostLintUnsafeSurfaceNames
  (slots (__tl_dyn-array SelfhostLintUnsafeSurfaceName))
  (len i64))

(define (selfhost-lint-unsafe-surface-names-empty) : SelfhostLintUnsafeSurfaceNames
  (SelfhostLintUnsafeSurfaceNames
    (__tl_make-array SelfhostLintUnsafeSurfaceName 8)
    0))

(define (selfhost-lint-unsafe-surface-names-add
  [fact : SelfhostLintUnsafeSurfaceName]
  [names : SelfhostLintUnsafeSurfaceNames]) : SelfhostLintUnsafeSurfaceNames
  (let
    [cells : (__tl_dyn-array SelfhostLintUnsafeSurfaceName) names.slots]
    [n : i64 names.len]
    [index : i64 0]
    (begin
      (if (< n (array-length cells))
        unit
        (let
          [bigger : (__tl_dyn-array SelfhostLintUnsafeSurfaceName)
            (__tl_make-array SelfhostLintUnsafeSurfaceName (* n 2))]
          (begin
            (while (< index n)
              (begin
                (set! (array-ref bigger index) (array-ref cells index))
                (set! index (+ index 1))))
            (set! cells bigger))))
      (set! (array-ref cells n) fact)
      (SelfhostLintUnsafeSurfaceNames cells (+ n 1)))))

(defstruct SelfhostLintUnsafeSurfaceCacheEntry
  (path String)
  (valid bool)
  (names SelfhostLintUnsafeSurfaceNames))

(defstruct SelfhostLintUnsafeSurfaceCache
  (slots (__tl_dyn-array SelfhostLintUnsafeSurfaceCacheEntry))
  (len i64))

(defenum SelfhostLintUnsafeSurfaceLookup
  (Miss)
  (Hit bool SelfhostLintUnsafeSurfaceNames))

(define (selfhost-lint-unsafe-surface-cache-empty) : SelfhostLintUnsafeSurfaceCache
  (SelfhostLintUnsafeSurfaceCache
    (__tl_make-array SelfhostLintUnsafeSurfaceCacheEntry 8)
    0))

(define selfhost-lint-unsafe-surface-cache : SelfhostLintUnsafeSurfaceCache
  (selfhost-lint-unsafe-surface-cache-empty))

(define (selfhost-lint-unsafe-surface-cache-entry [index : i64]) : SelfhostLintUnsafeSurfaceCacheEntry
  (selfhost-lint-global-array-element-shared-view
    (__tl-project-field selfhost-lint-unsafe-surface-cache slots)
    index))

;; The cache arena is the explicit batch's outer arena. Entries copy only path,
;; declaration name, and safety bits out of each file scratch; no AST nodes,
;; signatures, or pool-backed lists survive their owner arena.
(define selfhost-lint-unsafe-surface-cache-arena : i64
  0)
(define selfhost-lint-unsafe-surface-parse-count : i64
  0)
(define selfhost-lint-unsafe-surface-hit-count : i64
  0)
(define selfhost-lint-unused-unsafe-fallback-file-count : i64
  0)
(define selfhost-lint-unused-unsafe-surface-required-count : i64
  0)
(define selfhost-lint-unused-unsafe-surface-unused-count : i64
  0)
(define selfhost-lint-unused-unsafe-surface-unknown-count : i64
  0)

;; Status-bearing file/package callers consume this before their scratch arena
;; is reset; findings-only source callers keep their existing API.
(define selfhost-lint-typed-unused-unsafe-error : String
  "")

(define (selfhost-lint-typed-unused-unsafe-error-shared-view) : String
  (selfhost-lint-global-shared-view selfhost-lint-typed-unused-unsafe-error))

(define (selfhost-lint-unsafe-surface-cache-reset!) : unit
  (begin
    (set!
      selfhost-lint-unsafe-surface-cache
      (selfhost-lint-unsafe-surface-cache-empty))
    (set! selfhost-lint-unsafe-surface-cache-arena (arena.tl_arena_current))
    (set! selfhost-lint-unsafe-surface-parse-count 0)
    (set! selfhost-lint-unsafe-surface-hit-count 0)
    (set! selfhost-lint-unused-unsafe-fallback-file-count 0)
    (set! selfhost-lint-unused-unsafe-surface-required-count 0)
    (set! selfhost-lint-unused-unsafe-surface-unused-count 0)
    (set! selfhost-lint-unused-unsafe-surface-unknown-count 0)))

(define (selfhost-lint-unsafe-surface-cache-release!) : unit
  (begin
    (set!
      selfhost-lint-unsafe-surface-cache
      (selfhost-lint-unsafe-surface-cache-empty))
    (set! selfhost-lint-unsafe-surface-cache-arena 0)))

(define (selfhost-lint-unsafe-surface-cache-ensure!) : unit
  (if (= selfhost-lint-unsafe-surface-cache-arena 0)
    (selfhost-lint-unsafe-surface-cache-reset!)
    unit))

(define (selfhost-lint-unsafe-surface-cache-parse-count) : i64
  selfhost-lint-unsafe-surface-parse-count)

(define (selfhost-lint-unsafe-surface-cache-hit-count) : i64
  selfhost-lint-unsafe-surface-hit-count)

(define (selfhost-lint-unused-unsafe-fallback-count) : i64
  selfhost-lint-unused-unsafe-fallback-file-count)

(define (selfhost-lint-unused-unsafe-surface-required-total) : i64
  selfhost-lint-unused-unsafe-surface-required-count)

(define (selfhost-lint-unused-unsafe-surface-classified-total) : i64
  (+
    selfhost-lint-unused-unsafe-surface-required-count
    selfhost-lint-unused-unsafe-surface-unused-count))

;; Paths are stored at most once (only the miss path stores), so scanning the
;; slots front to back returns the same entry the newest-first chain did.
(define (selfhost-lint-unsafe-surface-cache-lookup [path : String]) : SelfhostLintUnsafeSurfaceLookup
  (let
    [n : i64 (__tl-project-field selfhost-lint-unsafe-surface-cache len)]
    [index : i64 0]
    (begin
      (while (and
        (< index n)
        (not
          (string.eq
            (__tl-project-field
              (selfhost-lint-unsafe-surface-cache-entry index)
              path)
            path)))
        (set! index (+ index 1)))
      (if (< index n)
        (let
          [entry : SelfhostLintUnsafeSurfaceCacheEntry
            (selfhost-lint-unsafe-surface-cache-entry index)]
          (SelfhostLintUnsafeSurfaceLookup.Hit entry.valid entry.names))
        (SelfhostLintUnsafeSurfaceLookup.Miss)))))

(define (selfhost-lint-unsafe-surface-value-kind?
  [kind : compiler_load.CompilerLoadSurfaceDeclKind]) : bool
  (match kind
    [(CompilerLoadSurfaceFunction) true]
    [(CompilerLoadSurfaceExtern) true]
    [(CompilerLoadSurfaceStruct) true]
    [(CompilerLoadSurfaceEnum) true]
    [(CompilerLoadSurfaceDispatch) true]
    [_ false]))

(define (selfhost-lint-unsafe-surface-copy-decls
  [decls : compiler_load.CompilerLoadSurfaceDeclList]
  [root-module : i64]
  [out : SelfhostLintUnsafeSurfaceNames]) : SelfhostLintUnsafeSurfaceNames
  (let
    [index : i64 0]
    [result : SelfhostLintUnsafeSurfaceNames out]
    (begin
      (while (<
        index
        (compiler_load.compiler-load-surface-decl-list-count decls))
        (let
          [decl : compiler_load.CompilerLoadSurfaceDecl
            (compiler_load.compiler-load-surface-decl-list-at decls index)]
          (begin
            (if (and
              (= decl.module root-module)
              (not decl.has-generated-meta)
              (selfhost-lint-unsafe-surface-value-kind? decl.kind))
              (set!
                result
                (selfhost-lint-unsafe-surface-names-add
                  (SelfhostLintUnsafeSurfaceName
                    (string.copy (ci.intern-str decl.name))
                    decl.was-unsafe)
                  result))
              unit)
            (set! index (+ index 1)))))
      result)))

(define (selfhost-lint-unsafe-surface-cache-push!
  [entry : SelfhostLintUnsafeSurfaceCacheEntry]) : unit
  (let
    [n : i64 (__tl-project-field selfhost-lint-unsafe-surface-cache len)]
    [index : i64 0]
    (begin
      (if (<
        n
        (array-length
          (__tl-project-field selfhost-lint-unsafe-surface-cache slots)))
        unit
        (let
          [bigger : (__tl_dyn-array SelfhostLintUnsafeSurfaceCacheEntry)
            (__tl_make-array SelfhostLintUnsafeSurfaceCacheEntry (* n 2))]
          (begin
            (while (< index n)
              (begin
                (set!
                  (array-ref bigger index)
                  (selfhost-lint-unsafe-surface-cache-entry index))
                (set! index (+ index 1))))
            (__tl-project-set-field
              selfhost-lint-unsafe-surface-cache
              slots
              bigger))))
      (set!
        (array-ref
          (__tl-project-field selfhost-lint-unsafe-surface-cache slots)
          n)
        entry)
      (__tl-project-set-field selfhost-lint-unsafe-surface-cache len (+ n 1)))))

(define (selfhost-lint-unsafe-surface-cache-store-summary!
  [path : String]
  [summary : compiler_load.CompilerLoadSurfaceSummary]) : unit
  (in-arena
    (arena.Arena selfhost-lint-unsafe-surface-cache-arena)
    (selfhost-lint-unsafe-surface-cache-push!
      (SelfhostLintUnsafeSurfaceCacheEntry
        (string.copy path)
        true
        (selfhost-lint-unsafe-surface-copy-decls
          summary.decls
          summary.declaration-module-id
          (selfhost-lint-unsafe-surface-names-empty))))))

(define (selfhost-lint-unsafe-surface-cache-store-invalid! [path : String]) : unit
  (in-arena
    (arena.Arena selfhost-lint-unsafe-surface-cache-arena)
    (selfhost-lint-unsafe-surface-cache-push!
      (SelfhostLintUnsafeSurfaceCacheEntry
        (string.copy path)
        false
        (selfhost-lint-unsafe-surface-names-empty)))))

(define (selfhost-lint-unsafe-surface-cache-load!
  [path : String]
  [cfgs : sym_i64_env.SymI64Env]) : SelfhostLintUnsafeSurfaceLookup
  (let
    [normalized : String (compiler_load.compiler-load-normalize-path path)]
    (match (selfhost-lint-unsafe-surface-cache-lookup normalized)
      [(SelfhostLintUnsafeSurfaceLookup.Hit valid names)
        (begin
          (set!
            selfhost-lint-unsafe-surface-hit-count
            (+ selfhost-lint-unsafe-surface-hit-count 1))
          (SelfhostLintUnsafeSurfaceLookup.Hit valid names))]
      [(SelfhostLintUnsafeSurfaceLookup.Miss)
        (begin
          (set!
            selfhost-lint-unsafe-surface-parse-count
            (+ selfhost-lint-unsafe-surface-parse-count 1))
          ;; Explicit file/package linting installs a growable pool context that
          ;; can safely own a second parse. Pure source helpers use the legacy
          ;; active pool, so leave their imports Unknown and use typed fallback.
          (if (and
            (ast.ast-node-pool-compat-context-active?)
            (io.file-exists? normalized))
            (match (parser.parse-ast-source-diagnostic-with-cfg-and-pools
              normalized
              (byte_buf.to-string (io.read-file normalized))
              cfgs
              (ast.ast-node-pool-compat-context-current))
              [(parser.ResultAstProgramDiagnostic.Ok program)
                (match (compiler_load.compiler-load-surface-summary-build
                  normalized
                  0
                  ""
                  program
                  0
                  true)
                  [(compiler_load.ResultCompilerLoadSurfaceSummary.Ok summary)
                    (selfhost-lint-unsafe-surface-cache-store-summary!
                      normalized
                      summary)]
                  [(compiler_load.ResultCompilerLoadSurfaceSummary.Err _)
                    (selfhost-lint-unsafe-surface-cache-store-invalid!
                      normalized)])]
              [(parser.ResultAstProgramDiagnostic.Err _)
                (selfhost-lint-unsafe-surface-cache-store-invalid! normalized)])
            (selfhost-lint-unsafe-surface-cache-store-invalid! normalized))
          (selfhost-lint-unsafe-surface-cache-lookup normalized))])))

(define (selfhost-lint-unsafe-surface-import-alias
  [import-edge : compiler_load.CompilerLoadSurfaceImport]) : String
  (match import-edge.alias
    [(CompilerLoadSurfaceSomeString alias) alias]
    [(CompilerLoadSurfaceNoString)
      (match import-edge.default-alias
        [(CompilerLoadSurfaceSomeString alias) alias]
        [(CompilerLoadSurfaceNoString) ""])]))

(define (selfhost-lint-unsafe-surface-add-names!
  [alias : String]
  [names : SelfhostLintUnsafeSurfaceNames]) : unit
  (let
    [n : i64 names.len]
    [index : i64 0]
    (while (< index n)
      (let
        [fact : SelfhostLintUnsafeSurfaceName (array-ref names.slots index)]
        (begin
          (lint_core.lint-unused-unsafe-classifier-add-exact-name!
            (str_cat.str-cat alias "." fact.name)
            fact.requires-unsafe)
          (lint_core.lint-unused-unsafe-classifier-add-exact-name!
            (str_cat.str-cat alias "/" fact.name)
            fact.requires-unsafe)
          (set! index (+ index 1)))))))

(define (selfhost-lint-unsafe-surface-add-local-decls!
  [decls : compiler_load.CompilerLoadSurfaceDeclList]
  [root-module : i64]) : unit
  (let
    [index : i64 0]
    (while (< index (compiler_load.compiler-load-surface-decl-list-count decls))
      (let
        [decl : compiler_load.CompilerLoadSurfaceDecl
          (compiler_load.compiler-load-surface-decl-list-at decls index)]
        (begin
          (if (and
            (= decl.module root-module)
            (not decl.has-generated-meta)
            (selfhost-lint-unsafe-surface-value-kind? decl.kind))
            (lint_core.lint-unused-unsafe-classifier-add-exact-name!
              (string.copy (ci.intern-str decl.name))
              decl.was-unsafe)
            unit)
          ;; A top-level declaration can shadow an import alias. Only qualified
          ;; references consult this root blocker, so unqualified local facts
          ;; remain usable.
          (if (not decl.has-generated-meta)
            (lint_core.lint-unused-unsafe-classifier-add-unknown-root!
              (string.copy (ci.intern-str decl.name)))
            unit)
          (set! index (+ index 1)))))))

(define (selfhost-lint-unsafe-surface-resolve-import
  [path : String]
  [stdlib-roots : lint_svec.Vec]
  [import-edge : compiler_load.CompilerLoadSurfaceImport]) : compiler_load.ResultPkgResolve
  (match import-edge.kind
    [(CompilerLoadSurfaceImportModule)
      (compiler_load.compiler-load-resolve-module-import-with-roots
        path
        (compiler_load.compiler-load-dirname path)
        import-edge.import-path
        stdlib-roots)]
    [_
      (compiler_load.ResultPkgResolve.Err
        "lint: macro import surface is not static")]))

(define (selfhost-lint-unsafe-surface-prepare-imports!
  [path : String]
  [stdlib-roots : lint_svec.Vec (:consume)]
  [cfgs : sym_i64_env.SymI64Env]
  [imports : compiler_load.CompilerLoadSurfaceImportList]) : unit
  (let
    [index : i64 0]
    (while (<
      index
      (compiler_load.compiler-load-surface-import-list-count imports))
      (let
        [import-edge : compiler_load.CompilerLoadSurfaceImport
          (compiler_load.compiler-load-surface-import-list-at imports index)]
        [alias : String (selfhost-lint-unsafe-surface-import-alias import-edge)]
        (begin
          (if (string.eq alias "")
            unit
            (match (selfhost-lint-unsafe-surface-resolve-import
              path
              stdlib-roots
              import-edge)
              [(compiler_load.ResultPkgResolve.Err _) unit]
              [(compiler_load.ResultPkgResolve.Ok resolved)
                (match (selfhost-lint-unsafe-surface-cache-load! resolved cfgs)
                  [(SelfhostLintUnsafeSurfaceLookup.Miss) unit]
                  [(SelfhostLintUnsafeSurfaceLookup.Hit valid names)
                    (if valid
                      (selfhost-lint-unsafe-surface-add-names! alias names)
                      unit)])]))
          (set! index (+ index 1)))))))

(define (selfhost-lint-unsafe-surface-prepare!
  [path : String]
  [program : ast.AstProgram]
  [stdlib-roots : lint_svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : unit
  (begin
    (selfhost-lint-unsafe-surface-cache-ensure!)
    (lint_core.lint-unused-unsafe-classifier-reset!)
    (match (compiler_load.compiler-load-surface-summary-build
      path
      0
      ""
      program
      0
      false)
      [(compiler_load.ResultCompilerLoadSurfaceSummary.Err _) unit]
      [(compiler_load.ResultCompilerLoadSurfaceSummary.Ok summary)
        (begin
          (selfhost-lint-unsafe-surface-add-local-decls!
            summary.decls
            summary.declaration-module-id)
          (selfhost-lint-unsafe-surface-prepare-imports!
            path
            stdlib-roots
            cfgs
            summary.imports))])
    (lint_core.lint-unused-unsafe-classifier-enable!)))

(define (selfhost-lint-unused-unsafe-findings-from
  [state : tc.TcUnusedUnsafeState]
  [path : String]
  [index : i64]
  [out : lint_core.LintFindings]) : lint_core.LintFindings
  (if (>= index (tc.tc-unused-unsafe-block-count state))
    out
    (let
      [next : lint_core.LintFindings
        (if (and
          (not (tc.tc-unused-unsafe-block-used? state index))
          (string.eq (tc.tc-unused-unsafe-block-path state index) path))
          (lint_core.lint-findings-add
            (lint_core.lint-unused-unsafe-finding
              (tc.tc-unused-unsafe-block-span state index))
            out)
          out)]
      (selfhost-lint-unused-unsafe-findings-from state path (+ index 1) next))))

(define (selfhost-lint-typed-unused-unsafe-findings
  [path : String]
  [source : String]
  [stdlib-roots : lint_svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : lint_core.LintFindings
  (let
    [job-state : tc.TcJobState (tc.tc-job-state-new)]
    [unused-unsafe : tc.TcUnusedUnsafeState
      (tc.tc-job-state-unused-unsafe job-state)]
    (begin
      (set! selfhost-lint-typed-unused-unsafe-error "")
      (tc.tc-unused-unsafe-tracking-reset! unused-unsafe path)
      ;; File/package lint parses into a destroyable, explicitly installed pool.
      ;; Run the nested check on process pools and reinstall the lint pool before
      ;; its caller resumes the AST walk.
      (match (if (ast.ast-node-pool-compat-context-active?)
        (let
          [lint-pools : ast.AstNodePoolContext
            (ast.ast-node-pool-compat-context-current)]
          (begin
            (ast.ast-node-pool-compat-context-clear!)
            (let
              [checked : compiler_check_core.ResultCompilerCheck
                (compiler_check_core.compiler-check-source-with-roots-and-cfg-and-job-state
                  path
                  source
                  stdlib-roots
                  cfgs
                  job-state)]
              (begin
                (ast.ast-node-pool-compat-context-use! lint-pools)
                checked))))
        (compiler_check_core.compiler-check-source-with-roots-and-cfg-and-job-state
          path
          source
          stdlib-roots
          cfgs
          job-state))
        [(compiler_check_core.ResultCompilerCheck.Ok _)
          (let
            [findings : lint_core.LintFindings
              (selfhost-lint-filter-derived-origins
                source
                (selfhost-lint-unused-unsafe-findings-from
                  unused-unsafe
                  path
                  0
                  (lint_core.lint-findings-empty)))]
            (begin
              (tc.tc-unused-unsafe-tracking-disable! unused-unsafe)
              findings))]
        [(compiler_check_core.ResultCompilerCheck.Err diag)
          (begin
            (set!
              selfhost-lint-typed-unused-unsafe-error
              (cdiag.compiler-diagnostic-render
                (cdiag.compiler-diagnostic-list-first (__tl-box-place diag))))
            (tc.tc-unused-unsafe-tracking-disable! unused-unsafe)
            (lint_core.lint-findings-empty))]))))

(define (selfhost-lint-source-unused-unsafe-findings
  [path : String]
  [source : String]
  [program : ast.AstProgram]
  [stdlib-roots : lint_svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : lint_core.LintFindings
  (if (lint_core.lint-program-has-unused-unsafe-candidate? program)
    (begin
      (set!
        selfhost-lint-unused-unsafe-fallback-file-count
        (+ selfhost-lint-unused-unsafe-fallback-file-count 1))
      (selfhost-lint-typed-unused-unsafe-findings path source stdlib-roots cfgs))
    (lint_core.lint-findings-empty)))

(define (selfhost-lint-findings-without-unused-unsafe-from
  [items : lint_core.LintFindings]
  [index : i64]
  [out : lint_core.LintFindings]) : lint_core.LintFindings
  (if (>= index (lint_core.lint-findings-count items))
    out
    (let
      [finding : lint_core.LintFinding
        (lint_core.lint-findings-ref items index)]
      [next : lint_core.LintFindings
        (if (string.eq finding.rule-id (lint_core.lint-rule-unused-unsafe-id))
          out
          (lint_core.lint-findings-add finding out))]
      (selfhost-lint-findings-without-unused-unsafe-from items (+ index 1) next))))

(define (selfhost-lint-findings-without-unused-unsafe
  [items : lint_core.LintFindings]) : lint_core.LintFindings
  (selfhost-lint-findings-without-unused-unsafe-from
    items
    0
    (lint_core.lint-findings-empty)))

(define (selfhost-lint-program-and-typed-findings
  [path : String]
  [source : String]
  [program : ast.AstProgram]
  [stdlib-roots : lint_svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [deprecated-string-concat : bool]
  [redundant-function-name : bool]
  [prefer-dotted-field : bool]
  [name-case : bool]) : lint_core.LintFindings
  (begin
    (set! selfhost-lint-typed-unused-unsafe-error "")
    (selfhost-lint-unsafe-surface-prepare! path program stdlib-roots cfgs)
    (let
      [ordinary : lint_core.LintFindings
        (selfhost-lint-program-findings-with-all-options
          source
          program
          deprecated-string-concat
          redundant-function-name
          prefer-dotted-field
          name-case)]
      [unknown-count : i64
        (lint_core.lint-unused-unsafe-classifier-unknown-count)]
      [required-count : i64
        (lint_core.lint-unused-unsafe-classifier-required-count)]
      [unused-count : i64
        (lint_core.lint-unused-unsafe-classifier-unused-count)]
      [typed : lint_core.LintFindings
        (if (> unknown-count 0)
          (selfhost-lint-typed-unused-unsafe-findings
            path
            source
            stdlib-roots
            cfgs)
          (lint_core.lint-findings-empty))]
      [base : lint_core.LintFindings
        (if (> unknown-count 0)
          (selfhost-lint-findings-without-unused-unsafe ordinary)
          ordinary)]
      (begin
        (set!
          selfhost-lint-unused-unsafe-surface-required-count
          (+ selfhost-lint-unused-unsafe-surface-required-count required-count))
        (set!
          selfhost-lint-unused-unsafe-surface-unused-count
          (+ selfhost-lint-unused-unsafe-surface-unused-count unused-count))
        (set!
          selfhost-lint-unused-unsafe-surface-unknown-count
          (+ selfhost-lint-unused-unsafe-surface-unknown-count unknown-count))
        (if (> unknown-count 0)
          (set!
            selfhost-lint-unused-unsafe-fallback-file-count
            (+ selfhost-lint-unused-unsafe-fallback-file-count 1))
          unit)
        (lint_core.lint-unused-unsafe-classifier-disable!)
        (selfhost-lint-findings-append base typed)))))

(define (selfhost-lint-source-with-roots-and-all-options-with-cfg
  [path : String]
  [source : String]
  [stdlib-roots : lint_svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [deprecated-string-concat : bool]
  [redundant-function-name : bool]
  [prefer-dotted-field : bool]
  [name-case : bool]) : lint_core.LintFindings
  (begin
    ;; LSP/source-mode callers commonly run in a destroyable request arena.
    ;; Never let a prior request's compact cache survive into the next one;
    ;; explicit file/package batches reset once in their outer batch arena.
    (set! selfhost-lint-typed-unused-unsafe-error "")
    (selfhost-lint-unsafe-surface-cache-reset!)
    (lint_core.lint-unused-unsafe-classifier-reset!)
    (let
      [findings : lint_core.LintFindings
        (match (parser.parse-ast-source-diagnostic-with-cfg path source cfgs)
          [(parser.ResultAstProgramDiagnostic.Ok program)
            (let
              [ordinary : lint_core.LintFindings
                (selfhost-lint-program-findings-with-all-options
                  source
                  program
                  deprecated-string-concat
                  redundant-function-name
                  prefer-dotted-field
                  name-case)]
              (selfhost-lint-findings-append
                ordinary
                (selfhost-lint-source-unused-unsafe-findings
                  path
                  source
                  program
                  stdlib-roots
                  cfgs)))]
          [(parser.ResultAstProgramDiagnostic.Err _)
            (lint_core.lint-findings-empty)])]
      (begin
        ;; Preserve diagnostic counters, but leave no cache pointer into the
        ;; caller's request arena after returning its findings.
        (selfhost-lint-unsafe-surface-cache-release!)
        findings))))

(define (selfhost-lint-source-with-roots-and-all-options
  [path : String]
  [source : String]
  [stdlib-roots : lint_svec.Vec]
  [deprecated-string-concat : bool]
  [redundant-function-name : bool]
  [prefer-dotted-field : bool]
  [name-case : bool]) : lint_core.LintFindings
  (selfhost-lint-source-with-roots-and-all-options-with-cfg
    path
    source
    stdlib-roots
    (selfhost-lint-language-cfgs)
    deprecated-string-concat
    redundant-function-name
    prefer-dotted-field
    name-case))

(define (selfhost-lint-source-with-roots-and-staged-options
  [path : String]
  [source : String]
  [stdlib-roots : lint_svec.Vec]
  [deprecated-string-concat : bool]
  [redundant-function-name : bool]
  [prefer-dotted-field : bool]) : lint_core.LintFindings
  (selfhost-lint-source-with-roots-and-all-options
    path
    source
    stdlib-roots
    deprecated-string-concat
    redundant-function-name
    prefer-dotted-field
    false))

(define (selfhost-lint-source-with-roots-and-options
  [path : String]
  [source : String]
  [stdlib-roots : lint_svec.Vec]
  [deprecated-string-concat : bool]) : lint_core.LintFindings
  (selfhost-lint-source-with-roots-and-staged-options
    path
    source
    stdlib-roots
    deprecated-string-concat
    false
    false))

;; Parse `source` (attributed to `path`) and run the lint rules over this source
;; unit only. Imports are linted when their own files are selected by the repo
;; lint gate, so a public driver does not duplicate every imported finding.
(define (selfhost-lint-source-with-roots
  [path : String]
  [source : String]
  [stdlib-roots : lint_svec.Vec]) : lint_core.LintFindings
  (selfhost-lint-source-with-roots-and-options path source stdlib-roots false))

(define (selfhost-lint-source-with-roots-and-cfg
  [path : String]
  [source : String]
  [stdlib-roots : lint_svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : lint_core.LintFindings
  (selfhost-lint-source-with-roots-and-all-options-with-cfg
    path
    source
    stdlib-roots
    cfgs
    false
    false
    false
    false))

;; Package-level dead-code linting records top-level declarations as graph nodes.
;; Library packages expose every top-level declaration as API roots. Binary
;; packages report declarations unreachable from entry/test/generated roots.
(defstruct SelfhostLintDeadDecl
  (path String)
  (name String)
  (key String)
  (span ast.AstSourceSpan)
  (refs lint_svec.Vec)
  (root bool)
  (reportable bool))

(defstruct SelfhostLintDeadDecls
  (slots (__tl_dyn-array SelfhostLintDeadDecl))
  (len i64))

(defstruct SelfhostLintDeadSourceSet
  (sources lint_svec.Vec)
  (root-sources lint_svec.Vec)
  (reportable-sources lint_svec.Vec)
  (explicit-roots lint_svec.Vec))

(defenum ResultSelfhostLintDeadSourceList
  (Ok lint_svec.Vec)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultSelfhostLintDeadImportList
  (Ok lint_svec.Vec)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultSelfhostLintDeadSources
  (Ok SelfhostLintDeadSourceSet)
  (Err (Box cdiag.CompilerDiagnostic)))

(defstruct SelfhostLintDeadScan
  (decls SelfhostLintDeadDecls)
  (roots lint_svec.Vec))

(define selfhost-lint-dead-import-aliases : sym_i64_env.SymI64Env
  (sym_i64_env.sym-i64-empty))

(define (selfhost-lint-package-dead-cfgs-base) : sym_i64_env.SymI64Env
  ;; Package reachability models the configurations built by the shipped
  ;; bootstrap and the repository's compiler instrumentation gates. Keep this
  ;; list explicit: arbitrary caller cfgs must stay inactive rather than
  ;; turning conditional implementation details into API.
  (parser.compiler-cfg-enable
    (parser.compiler-cfg-enable
      (parser.compiler-cfg-union
        (parser.compiler-cfg-enable
          (parser.compiler-cfg-enable
            (parser.compiler-cfg-enable
              (parser.compiler-cfg-enable (selfhost-lint-language-cfgs) "test")
              "scratch-vreg")
            "embedded-stdlib-tlci")
          "compiler-build-identity")
        "compile-profile")
      "regalloc-census")
    "scavenge-census"))

(define (selfhost-lint-package-dead-cfgs) : sym_i64_env.SymI64Env
  (parser.compiler-cfg-union
    (parser.compiler-cfg-enable
      (selfhost-lint-package-dead-cfgs-base)
      "scavenge-self-check")
    "compile-profile-summary"))

(define (selfhost-lint-dead-decls-slots [items : SelfhostLintDeadDecls]) : (__tl_dyn-array
    SelfhostLintDeadDecl)
  items.slots)

(define (selfhost-lint-dead-decls-count [items : SelfhostLintDeadDecls]) : i64
  items.len)

(define (selfhost-lint-dead-decls-capacity [items : SelfhostLintDeadDecls]) : i64
  (array-length (selfhost-lint-dead-decls-slots items)))

(define (selfhost-lint-dead-decls-with-capacity [capacity : i64]) : SelfhostLintDeadDecls
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (SelfhostLintDeadDecls (__tl_make-array SelfhostLintDeadDecl cap) 0)))

(define (selfhost-lint-dead-decls-empty) : SelfhostLintDeadDecls
  (selfhost-lint-dead-decls-with-capacity 8))

(define (selfhost-lint-dead-decls-copy-range
  [dst : (__tl_dyn-array SelfhostLintDeadDecl)]
  [src : (__tl_dyn-array SelfhostLintDeadDecl)]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (set! (array-ref dst index) (array-ref src index))
      (selfhost-lint-dead-decls-copy-range dst src (+ index 1) count))))

(define (selfhost-lint-dead-decls-grow [items : SelfhostLintDeadDecls]) : SelfhostLintDeadDecls
  (let
    [n : i64 (selfhost-lint-dead-decls-count items)]
    [bigger : (__tl_dyn-array SelfhostLintDeadDecl)
      (__tl_make-array
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
      [slots : (__tl_dyn-array SelfhostLintDeadDecl)
        (selfhost-lint-dead-decls-slots items)]
      [n : i64 (selfhost-lint-dead-decls-count items)]
      (begin
        (set! (array-ref slots n) decl)
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
    (set! (array-ref (selfhost-lint-dead-decls-slots items) index) decl)
    items))

(define (selfhost-lint-dead-root-add
  [roots : lint_svec.Vec (:consume)]
  [name : String]) : lint_svec.Vec
  (if (lint_svec.contains? (& roots) name)
    roots
    (let
      [next-roots : lint_svec.Vec roots]
      (begin
        (lint_svec.push-ref! (&mut next-roots) name)
        next-roots))))

(define (selfhost-lint-dead-root-add!
  [roots : (&mut roots lint_svec.Vec)]
  [name : String]) : unit
  (if (lint_svec.contains? (& roots) name)
    unit
    (lint_svec.push-ref! roots name)))

(define (selfhost-lint-dead-scan-add-decl
  [scan : SelfhostLintDeadScan]
  [decl : SelfhostLintDeadDecl]) : SelfhostLintDeadScan
  (SelfhostLintDeadScan
    (selfhost-lint-dead-decls-add decl scan.decls)
    scan.roots))

(define (selfhost-lint-dead-scan-add-root
  [scan : SelfhostLintDeadScan (:consume)]
  [name : String]) : SelfhostLintDeadScan
  (SelfhostLintDeadScan
    scan.decls
    (selfhost-lint-dead-root-add scan.roots name)))

(define (selfhost-lint-dead-scan-add-roots-from
  [scan : SelfhostLintDeadScan (:consume)]
  [roots : lint_svec.Vec]
  [index : i64]) : SelfhostLintDeadScan
  (if (>= index (lint_svec.len (& roots)))
    scan
    (selfhost-lint-dead-scan-add-roots-from
      (selfhost-lint-dead-scan-add-root scan (lint_svec.get (& roots) index ""))
      roots
      (+ index 1))))

(define (selfhost-lint-dead-scan-add-roots
  [scan : SelfhostLintDeadScan (:consume)]
  [roots : lint_svec.Vec]) : SelfhostLintDeadScan
  (selfhost-lint-dead-scan-add-roots-from scan roots 0))

(define (selfhost-lint-dead-module-key [module : String] [name : String]) : String
  (if (= (string.string-length module) 0)
    name
    (str_cat.str-cat module "/" name)))

(define (selfhost-lint-dead-default-module-from-path [path : String]) : String
  (parser.parse-ast-dotted-import-default-alias
    (compiler_load.compiler-load-canonical-module-id-from-path path)))

(define (selfhost-lint-dead-qualified-ref-prefix) : String
  "\nselfhost-lint-dead-qualified-ref\n")

(define (selfhost-lint-dead-qualified-ref [key : String] [fallback : String]) : String
  (str_cat.str-cat (selfhost-lint-dead-qualified-ref-prefix) key "\n" fallback))

(define (selfhost-lint-dead-qualified-ref? [ref : String]) : bool
  (selfhost-lint-prefix-at? ref 0 (selfhost-lint-dead-qualified-ref-prefix)))

(define (selfhost-lint-dead-qualified-ref-separator [ref : String]) : i64
  (string.index-of-byte
    (& ref)
    (string.string-length (selfhost-lint-dead-qualified-ref-prefix))
    (cast '\n' : u8)))

(define (selfhost-lint-dead-qualified-ref-key [ref : String]) : String
  (let
    [start : i64
      (string.string-length (selfhost-lint-dead-qualified-ref-prefix))]
    [sep : i64 (selfhost-lint-dead-qualified-ref-separator ref)]
    (if (< sep start)
      ""
      (string.substring ref start (- sep start)))))

(define (selfhost-lint-dead-qualified-ref-fallback [ref : String]) : String
  (let
    [sep : i64 (selfhost-lint-dead-qualified-ref-separator ref)]
    [name-len : i64 (string.string-length ref)]
    (if (or (< sep 0) (>= (+ sep 1) name-len))
      ""
      (string.substring ref (+ sep 1) (- name-len (+ sep 1))))))

(define (selfhost-lint-dead-source-root-prefix) : String
  "\nselfhost-lint-dead-source-root\n")

(define (selfhost-lint-dead-source-root [path : String] [name : String]) : String
  (str_cat.str-cat
    (selfhost-lint-dead-source-root-prefix)
    (compiler_load.compiler-load-normalize-path path)
    "\n"
    name))

(define (selfhost-lint-dead-source-root? [root : String]) : bool
  (selfhost-lint-prefix-at? root 0 (selfhost-lint-dead-source-root-prefix)))

(define (selfhost-lint-dead-source-root-separator [root : String]) : i64
  (string.index-of-byte
    (& root)
    (string.string-length (selfhost-lint-dead-source-root-prefix))
    (cast '\n' : u8)))

(define (selfhost-lint-dead-source-root-path [root : String]) : String
  (let
    [start : i64 (string.string-length (selfhost-lint-dead-source-root-prefix))]
    [sep : i64 (selfhost-lint-dead-source-root-separator root)]
    (if (< sep start)
      ""
      (string.substring root start (- sep start)))))

(define (selfhost-lint-dead-source-root-name [root : String]) : String
  (let
    [sep : i64 (selfhost-lint-dead-source-root-separator root)]
    [n : i64 (string.string-length root)]
    (if (or (< sep 0) (>= (+ sep 1) n))
      ""
      (string.substring root (+ sep 1) (- n (+ sep 1))))))

(define (selfhost-lint-dead-local-ref [module : String] [ref : String]) : String
  (if (selfhost-lint-dead-qualified-ref? ref)
    ref
    (if (= (string.string-length module) 0)
      ref
      (selfhost-lint-dead-qualified-ref
        (selfhost-lint-dead-module-key module ref)
        ref))))

(define (selfhost-lint-dead-localize-refs-from
  [module : String]
  [refs : lint_svec.Vec]
  [index : i64]
  [out : lint_svec.Vec (:consume)]) : lint_svec.Vec
  (if (>= index (lint_svec.len (& refs)))
    out
    (selfhost-lint-dead-localize-refs-from
      module
      refs
      (+ index 1)
      (selfhost-lint-dead-ref-add-raw
        out
        (selfhost-lint-dead-local-ref module (lint_svec.get (& refs) index ""))))))

(define (selfhost-lint-dead-localize-refs
  [module : String]
  [refs : lint_svec.Vec]) : lint_svec.Vec
  (if (= (string.string-length module) 0)
    refs
    (selfhost-lint-dead-localize-refs-from module refs 0 (lint_svec.new))))

(define (selfhost-lint-dead-ref-add-raw
  [refs : lint_svec.Vec (:consume)]
  [name : String]) : lint_svec.Vec
  (if (lint_svec.contains? (& refs) name)
    refs
    (let
      [next-refs : lint_svec.Vec refs]
      (begin
        (lint_svec.push-ref! (&mut next-refs) name)
        next-refs))))

(define (selfhost-lint-dead-last-dot-from
  [name : String]
  [index : i64]
  [last-dot : i64]) : i64
  (if (>= index (string.string-length name))
    last-dot
    (selfhost-lint-dead-last-dot-from
      name
      (+ index 1)
      (if (= (string.string-ref name index) '.')
        index
        last-dot))))

(define (selfhost-lint-dead-last-dot [name : String]) : i64
  (selfhost-lint-dead-last-dot-from name 0 (- 0 1)))

(define (selfhost-lint-dead-ref-add
  [refs : lint_svec.Vec (:consume)]
  [name : String]) : lint_svec.Vec
  (let
    [last-dot : i64 (selfhost-lint-dead-last-dot name)]
    [name-len : i64 (string.string-length name)]
    (if (and (>= last-dot 0) (< (+ last-dot 1) name-len))
      (let
        [member-start : i64 (+ last-dot 1)]
        [member : String
          (string.substring name member-start (- name-len member-start))]
        [target : i64
          (sym_i64_env.sym-i64-lookup-id-or
            (selfhost-lint-global-shared-view selfhost-lint-dead-import-aliases)
            (ci.intern-source-slice name 0 last-dot)
            -1)]
        [module : String
          (if (< target 0)
            (string.substring name 0 last-dot)
            (ci.intern-str target))]
        (selfhost-lint-dead-ref-add-raw
          refs
          (selfhost-lint-dead-qualified-ref
            (selfhost-lint-dead-module-key module member)
            member)))
      (selfhost-lint-dead-ref-add-raw refs name))))

(define (selfhost-lint-dead-ref-add-id
  [refs : lint_svec.Vec (:consume)]
  [name : i64]) : lint_svec.Vec
  (selfhost-lint-dead-ref-add refs (ci.intern-str name)))

(define (selfhost-lint-dead-maybe-type-refs
  [maybe-ty : ast.AstMaybeType]
  [refs : lint_svec.Vec (:consume)]) : lint_svec.Vec
  (match maybe-ty
    [(ast.AstMaybeType.No) refs]
    [(ast.AstMaybeType.Some ty) (selfhost-lint-dead-type-refs ty refs)]))

(define (selfhost-lint-dead-type-list-refs
  [types : ast.AstTypeList]
  [refs : lint_svec.Vec (:consume)]) : lint_svec.Vec
  (selfhost-lint-dead-type-list-refs-at (& types) refs 0))

(define (selfhost-lint-dead-type-list-refs-at
  [types : (& types ast.AstTypeList)]
  [refs : lint_svec.Vec (:consume)]
  [index : i64]) : lint_svec.Vec
  (if (>= index (ast.ast-type-list-len types))
    refs
    (selfhost-lint-dead-type-list-refs-at
      types
      (selfhost-lint-dead-type-refs
        (ast.ty-node-get
          (ast.ast-type-list-get types index (ast.ast-type-id-fallback)))
        refs)
      (+ index 1))))

(define (selfhost-lint-dead-type-id-refs
  [ty : i64]
  [refs : lint_svec.Vec (:consume)]) : lint_svec.Vec
  (selfhost-lint-dead-type-refs (ast.ty-node-get ty) refs))

(define (selfhost-lint-dead-type-refs
  [ty : ast.AstType]
  [refs : lint_svec.Vec (:consume)]) : lint_svec.Vec
  (match ty
    [(ast.AstType.I64) refs]
    [(ast.AstType.I32) refs]
    [(ast.AstType.I16) refs]
    [(ast.AstType.I8) refs]
    [(ast.AstType.U64) refs]
    [(ast.AstType.U32) refs]
    [(ast.AstType.U16) refs]
    [(ast.AstType.U8) refs]
    [(ast.AstType.F64) refs]
    [(ast.AstType.F32) refs]
    [(ast.AstType.Bool) refs]
    [(ast.AstType.Char) refs]
    [(ast.AstType.String) refs]
    [(ast.AstType.Str) refs]
    [(ast.AstType.Bytes) refs]
    [(ast.AstType.Unit) refs]
    [(ast.AstType.Never) refs]
    [(ast.AstType.Expr) refs]
    [(ast.AstType.ExprList) refs]
    [(ast.AstType.Func args ret)
      (selfhost-lint-dead-type-id-refs
        ret
        (selfhost-lint-dead-type-list-refs (__tl-box-place args) refs))]
    [(ast.AstType.Tuple items)
      (selfhost-lint-dead-type-list-refs (__tl-box-place items) refs)]
    [(ast.AstType.Array elem _) (selfhost-lint-dead-type-id-refs elem refs)]
    [(ast.AstType.DynArray elem) (selfhost-lint-dead-type-id-refs elem refs)]
    [(ast.AstType.Slice elem) (selfhost-lint-dead-type-id-refs elem refs)]
    [(ast.AstType.Box elem) (selfhost-lint-dead-type-id-refs elem refs)]
    [(ast.AstType.Region _ inner) (selfhost-lint-dead-type-id-refs inner refs)]
    [(ast.AstType.Ref _ inner) (selfhost-lint-dead-type-id-refs inner refs)]
    [(ast.AstType.MutRef _ inner) (selfhost-lint-dead-type-id-refs inner refs)]
    [(ast.AstType.Enum name) (selfhost-lint-dead-ref-add-id refs name)]
    [(ast.AstType.EnumArgs name _) (selfhost-lint-dead-ref-add-id refs name)]
    [(ast.AstType.Struct name) (selfhost-lint-dead-ref-add-id refs name)]
    [(ast.AstType.StructArgs name _) (selfhost-lint-dead-ref-add-id refs name)]
    [(ast.AstType.Var name) (selfhost-lint-dead-ref-add-id refs name)]
    [(ast.AstType.VarArgs name _) (selfhost-lint-dead-ref-add-id refs name)]
    [(ast.AstType.Ptr inner) (selfhost-lint-dead-type-id-refs inner refs)]
    [(ast.AstType.MutPtr inner) (selfhost-lint-dead-type-id-refs inner refs)]
    [(ast.AstType.Consume inner) (selfhost-lint-dead-type-id-refs inner refs)]))

(define (selfhost-lint-dead-param-list-refs
  [params : ast.AstParamList]
  [refs : lint_svec.Vec (:consume)]) : lint_svec.Vec
  (selfhost-lint-dead-param-list-refs-at (& params) refs 0))

(define (selfhost-lint-dead-param-list-refs-at
  [params : (& params ast.AstParamList)]
  [refs : lint_svec.Vec (:consume)]
  [index : i64]) : lint_svec.Vec
  (if (>= index (ast.ast-param-list-len params))
    refs
    (match (ast.ast-param-list-get params index (ast.ast-param-fallback))
      [(ast.AstParam.Param _ ty _ _)
        (selfhost-lint-dead-param-list-refs-at
          params
          (selfhost-lint-dead-type-refs ty refs)
          (+ index 1))])))

(define (selfhost-lint-dead-macro-param-list-refs
  [params : ast.AstMacroParamList]
  [refs : lint_svec.Vec (:consume)]) : lint_svec.Vec
  (selfhost-lint-dead-macro-param-list-refs-at (& params) refs 0))

(define (selfhost-lint-dead-macro-param-list-refs-at
  [params : (& params ast.AstMacroParamList)]
  [refs : lint_svec.Vec (:consume)]
  [index : i64]) : lint_svec.Vec
  (if (>= index (ast.ast-macro-param-list-len params))
    refs
    (match (ast.ast-macro-param-list-get
      params
      index
      (ast.ast-macro-param-fallback))
      [(ast.AstMacroParam.Param _ ty _ _)
        (selfhost-lint-dead-macro-param-list-refs-at
          params
          (selfhost-lint-dead-type-refs ty refs)
          (+ index 1))])))

(define (selfhost-lint-dead-pattern-list-refs
  [patterns : ast.AstPatternList]
  [refs : lint_svec.Vec (:consume)]) : lint_svec.Vec
  (selfhost-lint-dead-pattern-list-refs-at (& patterns) refs 0))

(define (selfhost-lint-dead-pattern-list-refs-at
  [patterns : (& patterns ast.AstPatternList)]
  [refs : lint_svec.Vec (:consume)]
  [index : i64]) : lint_svec.Vec
  (if (>= index patterns.len)
    refs
    (selfhost-lint-dead-pattern-list-refs-at
      patterns
      (selfhost-lint-dead-pattern-refs
        (ast.ast-pattern-list-get patterns index (ast.ast-pattern-fallback))
        refs)
      (+ index 1))))

(define (selfhost-lint-dead-pattern-refs
  [pattern : ast.AstPattern]
  [refs : lint_svec.Vec (:consume)]) : lint_svec.Vec
  (match pattern
    [(ast.AstPattern.Var _ maybe-ty)
      (selfhost-lint-dead-maybe-type-refs maybe-ty refs)]
    [(ast.AstPattern.Tuple items)
      (selfhost-lint-dead-pattern-list-refs (__tl-box-place items) refs)]
    [(ast.AstPattern.Array items)
      (selfhost-lint-dead-pattern-list-refs (__tl-box-place items) refs)]
    [(ast.AstPattern.Wildcard) refs]
    [(ast.AstPattern.Binding _) refs]
    [(ast.AstPattern.Variant name items)
      (selfhost-lint-dead-pattern-list-refs
        (__tl-box-place items)
        (selfhost-lint-dead-ref-add-id refs name))]
    [(ast.AstPattern.Literal _) refs]))

(define (selfhost-lint-dead-expr-list-refs
  [exprs : ast.AstExprList]
  [refs : lint_svec.Vec (:consume)]) : lint_svec.Vec
  (selfhost-lint-dead-expr-list-refs-from exprs refs 0))

(define (selfhost-lint-dead-expr-list-refs-from
  [exprs : ast.AstExprList]
  [refs : lint_svec.Vec (:consume)]
  [index : i64]) : lint_svec.Vec
  (if (>= index exprs.len)
    refs
    (selfhost-lint-dead-expr-list-refs-from
      exprs
      (selfhost-lint-dead-expr-refs
        (ast.ast-node-get (ast.ast-expr-list-get (& exprs) index 0))
        refs)
      (+ index 1))))

(define (selfhost-lint-dead-let-binding-refs
  [bindings : ast.AstLetBindingList]
  [refs : lint_svec.Vec (:consume)]) : lint_svec.Vec
  (selfhost-lint-dead-let-binding-refs-at (& bindings) refs 0))

(define (selfhost-lint-dead-let-binding-refs-at
  [bindings : (& bindings ast.AstLetBindingList)]
  [refs : lint_svec.Vec (:consume)]
  [index : i64]) : lint_svec.Vec
  (if (>= index (ast.ast-let-binding-list-len bindings))
    refs
    (match (ast.ast-let-binding-list-get
      bindings
      index
      (ast.ast-let-binding-fallback))
      [(ast.AstLetBinding.Binding _ maybe-ty init)
        (selfhost-lint-dead-let-binding-refs-at
          bindings
          (selfhost-lint-dead-expr-refs
            (ast.ast-node-get init)
            (selfhost-lint-dead-maybe-type-refs maybe-ty refs))
          (+ index 1))])))

(define (selfhost-lint-dead-match-arm-refs
  [arms : ast.AstMatchArmList]
  [refs : lint_svec.Vec (:consume)]) : lint_svec.Vec
  (selfhost-lint-dead-match-arm-refs-at (& arms) refs 0))

(define (selfhost-lint-dead-match-arm-refs-at
  [arms : (& arms ast.AstMatchArmList)]
  [refs : lint_svec.Vec (:consume)]
  [index : i64]) : lint_svec.Vec
  (if (>= index arms.len)
    refs
    (match (ast.ast-match-arm-list-get arms index (ast.ast-match-arm-fallback))
      [(ast.AstMatchArm.Arm pattern body)
        (selfhost-lint-dead-match-arm-refs-at
          arms
          (selfhost-lint-dead-expr-refs
            (ast.ast-node-get body)
            (selfhost-lint-dead-pattern-refs pattern refs))
          (+ index 1))])))

(define (selfhost-lint-dead-resource-binding-refs
  [bindings : ast.AstResourceBindingList]
  [refs : lint_svec.Vec (:consume)]) : lint_svec.Vec
  (selfhost-lint-dead-resource-binding-refs-at (& bindings) refs 0))

(define (selfhost-lint-dead-resource-binding-refs-at
  [bindings : (& bindings ast.AstResourceBindingList)]
  [refs : lint_svec.Vec (:consume)]
  [index : i64]) : lint_svec.Vec
  (if (>= index (ast.ast-resource-binding-list-len bindings))
    refs
    (match (ast.ast-resource-binding-list-get
      bindings
      index
      (ast.ast-resource-binding-fallback))
      [(ast.AstResourceBinding.Binding _ init cleanup _)
        (selfhost-lint-dead-resource-binding-refs-at
          bindings
          (selfhost-lint-dead-expr-refs
            (ast.ast-node-get cleanup)
            (selfhost-lint-dead-expr-refs (ast.ast-node-get init) refs))
          (+ index 1))])))

(define (selfhost-lint-dead-expr-refs
  [expr : ast.AstExpr]
  [refs : lint_svec.Vec (:consume)]) : lint_svec.Vec
  (match expr
    [(ast.AstExpr.Spanned inner-box _)
      (selfhost-lint-dead-expr-refs (ast.ast-node-get inner-box) refs)]
    [(ast.AstExpr.MacroExpansion inner-box _ _)
      (selfhost-lint-dead-expr-refs (ast.ast-node-get inner-box) refs)]
    [(ast.AstExpr.Literal _) refs]
    [(ast.AstExpr.Var name) (selfhost-lint-dead-ref-add-id refs name)]
    [(ast.AstExpr.Binary _ left right)
      (selfhost-lint-dead-expr-refs
        (ast.ast-node-get right)
        (selfhost-lint-dead-expr-refs (ast.ast-node-get left) refs))]
    [(ast.AstExpr.Unary _ inner)
      (selfhost-lint-dead-expr-refs (ast.ast-node-get inner) refs)]
    [(ast.AstExpr.Call func args)
      (selfhost-lint-dead-expr-list-refs
        args
        (selfhost-lint-dead-expr-refs (ast.ast-node-get func) refs))]
    [(ast.AstExpr.If cond then-branch else-branch)
      (selfhost-lint-dead-expr-refs
        (ast.ast-node-get else-branch)
        (selfhost-lint-dead-expr-refs
          (ast.ast-node-get then-branch)
          (selfhost-lint-dead-expr-refs (ast.ast-node-get cond) refs)))]
    [(ast.AstExpr.Let let-box)
      (match (__tl-box-place let-box)
        [(ast.AstLet.Let bindings body)
          (selfhost-lint-dead-expr-refs
            (ast.ast-node-get body)
            (selfhost-lint-dead-let-binding-refs bindings refs))])]
    [(ast.AstExpr.Lambda lambda-box)
      (match (__tl-box-place lambda-box)
        [(ast.AstLambda.Lambda params ret body)
          (selfhost-lint-dead-expr-refs
            (ast.ast-node-get body)
            (selfhost-lint-dead-maybe-type-refs
              ret
              (selfhost-lint-dead-param-list-refs params refs)))])]
    [(ast.AstExpr.Tuple exprs) (selfhost-lint-dead-expr-list-refs exprs refs)]
    [(ast.AstExpr.TupleRef tuple _)
      (selfhost-lint-dead-expr-refs (ast.ast-node-get tuple) refs)]
    [(ast.AstExpr.Array exprs) (selfhost-lint-dead-expr-list-refs exprs refs)]
    [(ast.AstExpr.DynArray exprs)
      (selfhost-lint-dead-expr-list-refs exprs refs)]
    [(ast.AstExpr.MakeArray elem-id len)
      (selfhost-lint-dead-expr-refs
        (ast.ast-node-get len)
        (selfhost-lint-dead-type-refs (ast.ty-node-get elem-id) refs))]
    [(ast.AstExpr.ArrayRef array index)
      (selfhost-lint-dead-expr-refs
        (ast.ast-node-get index)
        (selfhost-lint-dead-expr-refs (ast.ast-node-get array) refs))]
    [(ast.AstExpr.ArraySet array index value)
      (selfhost-lint-dead-expr-refs
        (ast.ast-node-get value)
        (selfhost-lint-dead-expr-refs
          (ast.ast-node-get index)
          (selfhost-lint-dead-expr-refs (ast.ast-node-get array) refs)))]
    [(ast.AstExpr.ArrayTake array live index)
      (selfhost-lint-dead-expr-refs
        (ast.ast-node-get index)
        (selfhost-lint-dead-expr-refs
          (ast.ast-node-get live)
          (selfhost-lint-dead-expr-refs (ast.ast-node-get array) refs)))]
    [(ast.AstExpr.FixedArrayTake array index)
      (selfhost-lint-dead-expr-refs
        (ast.ast-node-get index)
        (selfhost-lint-dead-expr-refs (ast.ast-node-get array) refs))]
    [(ast.AstExpr.Replace place replacement)
      (selfhost-lint-dead-expr-refs
        (ast.ast-node-get replacement)
        (selfhost-lint-dead-expr-refs (ast.ast-node-get place) refs))]
    [(ast.AstExpr.ArrayPush array value)
      (selfhost-lint-dead-expr-refs
        (ast.ast-node-get value)
        (selfhost-lint-dead-expr-refs (ast.ast-node-get array) refs))]
    [(ast.AstExpr.StringRef text index)
      (selfhost-lint-dead-expr-refs
        (ast.ast-node-get index)
        (selfhost-lint-dead-expr-refs (ast.ast-node-get text) refs))]
    [(ast.AstExpr.While cond body)
      (selfhost-lint-dead-expr-refs
        (ast.ast-node-get body)
        (selfhost-lint-dead-expr-refs (ast.ast-node-get cond) refs))]
    [(ast.AstExpr.ForOwnedState payload)
      (selfhost-lint-dead-expr-refs
        (ast.ast-node-get (ast.ast-for-owned-state-body (& payload)))
        (selfhost-lint-dead-expr-refs
          (ast.ast-node-get (ast.ast-for-owned-state-source (& payload)))
          refs))]
    [(ast.AstExpr.ForOwnedStep payload)
      (let
        [source : i64 (ast.ast-for-owned-step-source-name (& payload))]
        [index : i64 (ast.ast-for-owned-step-index-name (& payload))]
        [expected-type : i64 (ast.ast-for-owned-step-expected-type (& payload))]
        [done : i64 (ast.ast-for-owned-step-done-name (& payload))]
        [body : i64 (ast.ast-for-owned-step-body (& payload))]
        (selfhost-lint-dead-expr-refs
          (ast.ast-node-get body)
          (selfhost-lint-dead-expr-refs
            (ast.ast-node-get done)
            (if (>= expected-type 0)
              (selfhost-lint-dead-expr-refs
                (ast.ast-node-get expected-type)
                (selfhost-lint-dead-expr-refs
                  (ast.ast-node-get index)
                  (selfhost-lint-dead-expr-refs (ast.ast-node-get source) refs)))
              (selfhost-lint-dead-expr-refs
                (ast.ast-node-get index)
                (selfhost-lint-dead-expr-refs (ast.ast-node-get source) refs))))))]
    [(ast.AstExpr.Begin exprs) (selfhost-lint-dead-expr-list-refs exprs refs)]
    [(ast.AstExpr.Unsafe exprs) (selfhost-lint-dead-expr-list-refs exprs refs)]
    [(ast.AstExpr.Set target value)
      (selfhost-lint-dead-expr-refs
        (ast.ast-node-get value)
        (selfhost-lint-dead-ref-add-id refs target))]
    [(ast.AstExpr.Ann inner ty-id)
      (selfhost-lint-dead-type-refs
        (ast.ty-node-get ty-id)
        (selfhost-lint-dead-expr-refs (ast.ast-node-get inner) refs))]
    [(ast.AstExpr.Cast inner ty-id)
      (selfhost-lint-dead-type-refs
        (ast.ty-node-get ty-id)
        (selfhost-lint-dead-expr-refs (ast.ast-node-get inner) refs))]
    [(ast.AstExpr.Borrow _ _ place)
      (selfhost-lint-dead-expr-refs (ast.ast-node-get place) refs)]
    [(ast.AstExpr.Match match-box)
      (match (__tl-box-place match-box)
        [(ast.AstMatch.Match scrutinee arms)
          (selfhost-lint-dead-match-arm-refs
            arms
            (selfhost-lint-dead-expr-refs (ast.ast-node-get scrutinee) refs))])]
    [(ast.AstExpr.Foreach fe-box)
      (match (__tl-box-place fe-box)
        [(ast.AstForeach.Foreach _ index-ty start end body)
          (selfhost-lint-dead-expr-refs
            (ast.ast-node-get body)
            (selfhost-lint-dead-expr-refs
              (ast.ast-node-get end)
              (selfhost-lint-dead-expr-refs
                (ast.ast-node-get start)
                (selfhost-lint-dead-type-refs index-ty refs))))])]
    [(ast.AstExpr.SpmdReduce reduce-box)
      (match (__tl-box-place reduce-box)
        [(ast.AstSpmdReduce.Reduce _ _ index-ty start end init value)
          (selfhost-lint-dead-expr-refs
            (ast.ast-node-get value)
            (selfhost-lint-dead-expr-refs
              (ast.ast-node-get init)
              (selfhost-lint-dead-expr-refs
                (ast.ast-node-get end)
                (selfhost-lint-dead-expr-refs
                  (ast.ast-node-get start)
                  (selfhost-lint-dead-type-refs index-ty refs)))))])]
    [(ast.AstExpr.SpmdScan scan-box)
      (match (__tl-box-place scan-box)
        [(ast.AstSpmdScan.Scan
            _
            _
            index-ty
            start
            end
            _
            prefix-ty
            init
            value
            body)
          (selfhost-lint-dead-expr-refs
            (ast.ast-node-get body)
            (selfhost-lint-dead-expr-refs
              (ast.ast-node-get value)
              (selfhost-lint-dead-expr-refs
                (ast.ast-node-get init)
                (selfhost-lint-dead-expr-refs
                  (ast.ast-node-get end)
                  (selfhost-lint-dead-expr-refs
                    (ast.ast-node-get start)
                    (selfhost-lint-dead-type-refs
                      prefix-ty
                      (selfhost-lint-dead-type-refs index-ty refs)))))))])]
    [(ast.AstExpr.SpmdBroadcast value lane)
      (selfhost-lint-dead-expr-refs
        (ast.ast-node-get lane)
        (selfhost-lint-dead-expr-refs (ast.ast-node-get value) refs))]
    [(ast.AstExpr.SpmdShuffle value lane)
      (selfhost-lint-dead-expr-refs
        (ast.ast-node-get lane)
        (selfhost-lint-dead-expr-refs (ast.ast-node-get value) refs))]
    [(ast.AstExpr.StructGet receiver field)
      (selfhost-lint-dead-ref-add-id
        (selfhost-lint-dead-expr-refs (ast.ast-node-get receiver) refs)
        field)]
    [(ast.AstExpr.StructSet receiver field value)
      (selfhost-lint-dead-expr-refs
        (ast.ast-node-get value)
        (selfhost-lint-dead-ref-add-id
          (selfhost-lint-dead-expr-refs (ast.ast-node-get receiver) refs)
          field))]
    [(ast.AstExpr.WithRegion _ body)
      (selfhost-lint-dead-expr-list-refs body refs)]
    [(ast.AstExpr.WithEscape scratch body)
      (selfhost-lint-dead-expr-list-refs
        body
        (selfhost-lint-dead-expr-refs (ast.ast-node-get scratch) refs))]
    [(ast.AstExpr.WithScratch body)
      (selfhost-lint-dead-expr-list-refs body refs)]
    [(ast.AstExpr.InArena arena body)
      (selfhost-lint-dead-expr-list-refs
        body
        (selfhost-lint-dead-expr-refs (ast.ast-node-get arena) refs))]
    [(ast.AstExpr.WithResource wr-box)
      (match (__tl-box-place wr-box)
        [(ast.AstWithResource.WithResource bindings body)
          (selfhost-lint-dead-expr-list-refs
            body
            (selfhost-lint-dead-resource-binding-refs bindings refs))])]
    [(ast.AstExpr.Box inner)
      (selfhost-lint-dead-expr-refs (ast.ast-node-get inner) refs)]
    [(ast.AstExpr.BoxGet inner)
      (selfhost-lint-dead-expr-refs (ast.ast-node-get inner) refs)]
    [(ast.AstExpr.BoxTake inner)
      (selfhost-lint-dead-expr-refs (ast.ast-node-get inner) refs)]
    [(ast.AstExpr.BoxSet inner value)
      (selfhost-lint-dead-expr-refs
        (ast.ast-node-get value)
        (selfhost-lint-dead-expr-refs (ast.ast-node-get inner) refs))]
    [(ast.AstExpr.TypeLiteral ty-id)
      (selfhost-lint-dead-type-refs (ast.ty-node-get ty-id) refs)]
    [(ast.AstExpr.Init maybe-ty-id)
      (selfhost-lint-dead-maybe-type-refs
        (ast.ast-maybe-type-from-id maybe-ty-id)
        refs)]
    [(ast.AstExpr.Comptime inner)
      (selfhost-lint-dead-expr-refs (ast.ast-node-get inner) refs)]
    [(ast.AstExpr.Quote inner)
      (selfhost-lint-dead-expr-refs (ast.ast-node-get inner) refs)]
    [(ast.AstExpr.Quasiquote inner)
      (selfhost-lint-dead-expr-refs (ast.ast-node-get inner) refs)]
    [(ast.AstExpr.Unquote inner)
      (selfhost-lint-dead-expr-refs (ast.ast-node-get inner) refs)]
    [(ast.AstExpr.UnquoteSplicing inner)
      (selfhost-lint-dead-expr-refs (ast.ast-node-get inner) refs)]
    [(ast.AstExpr.BracketClause items)
      (selfhost-lint-dead-expr-list-refs items refs)]
    [(ast.AstExpr.Try inner)
      (selfhost-lint-dead-expr-refs (ast.ast-node-get inner) refs)]
    [(ast.AstExpr.Return inner)
      (selfhost-lint-dead-expr-refs (ast.ast-node-get inner) refs)]
    [(ast.AstExpr.Break) refs]
    [(ast.AstExpr.Continue) refs]
    [(ast.AstExpr.PtrNull ty-id)
      (selfhost-lint-dead-type-refs (ast.ty-node-get ty-id) refs)]
    [(ast.AstExpr.PtrNullCheck inner)
      (selfhost-lint-dead-expr-refs (ast.ast-node-get inner) refs)]
    [(ast.AstExpr.PtrAddrOf place)
      (selfhost-lint-dead-expr-refs (ast.ast-node-get place) refs)]
    [(ast.AstExpr.PtrRead ptr)
      (selfhost-lint-dead-expr-refs (ast.ast-node-get ptr) refs)]
    [(ast.AstExpr.PtrWrite ptr value)
      (selfhost-lint-dead-expr-refs
        (ast.ast-node-get value)
        (selfhost-lint-dead-expr-refs (ast.ast-node-get ptr) refs))]
    [(ast.AstExpr.PtrOffset ptr offset)
      (selfhost-lint-dead-expr-refs
        (ast.ast-node-get offset)
        (selfhost-lint-dead-expr-refs (ast.ast-node-get ptr) refs))]
    [(ast.AstExpr.PtrCast ptr ty-id)
      (selfhost-lint-dead-type-refs
        (ast.ty-node-get ty-id)
        (selfhost-lint-dead-expr-refs (ast.ast-node-get ptr) refs))]
    [(ast.AstExpr.PtrToInt ptr)
      (selfhost-lint-dead-expr-refs (ast.ast-node-get ptr) refs)]
    [(ast.AstExpr.IntToPtr value ty-id)
      (selfhost-lint-dead-type-refs
        (ast.ty-node-get ty-id)
        (selfhost-lint-dead-expr-refs (ast.ast-node-get value) refs))]
    [(ast.AstExpr.StringData inner)
      (selfhost-lint-dead-expr-refs (ast.ast-node-get inner) refs)]
    [(ast.AstExpr.StringFromBytes ptr len)
      (selfhost-lint-dead-expr-refs
        (ast.ast-node-get len)
        (selfhost-lint-dead-expr-refs (ast.ast-node-get ptr) refs))]
    [(ast.AstExpr.ArrayData inner)
      (selfhost-lint-dead-expr-refs (ast.ast-node-get inner) refs)]
    [(ast.AstExpr.BinaryData _) refs]
    [(ast.AstExpr.SpmdProgramIndex) refs]
    [(ast.AstExpr.SpmdProgramCount) refs]
    [(ast.AstExpr.ProgramArgc) refs]
    [(ast.AstExpr.ProgramArgv) refs]
    [(ast.AstExpr.ProgramEnvp) refs]
    [(ast.AstExpr.CpuIdEax leaf subleaf)
      (selfhost-lint-dead-expr-refs
        (ast.ast-node-get subleaf)
        (selfhost-lint-dead-expr-refs (ast.ast-node-get leaf) refs))]
    [(ast.AstExpr.CpuIdEbx leaf subleaf)
      (selfhost-lint-dead-expr-refs
        (ast.ast-node-get subleaf)
        (selfhost-lint-dead-expr-refs (ast.ast-node-get leaf) refs))]
    [(ast.AstExpr.CpuIdEcx leaf subleaf)
      (selfhost-lint-dead-expr-refs
        (ast.ast-node-get subleaf)
        (selfhost-lint-dead-expr-refs (ast.ast-node-get leaf) refs))]
    [(ast.AstExpr.CpuIdEdx leaf subleaf)
      (selfhost-lint-dead-expr-refs
        (ast.ast-node-get subleaf)
        (selfhost-lint-dead-expr-refs (ast.ast-node-get leaf) refs))]
    [(ast.AstExpr.Xgetbv index)
      (selfhost-lint-dead-expr-refs (ast.ast-node-get index) refs)]
    [(ast.AstExpr.Syscall args) (selfhost-lint-dead-expr-list-refs args refs)]))

(define (selfhost-lint-dead-expr-span [expr-id : i64]) : ast.AstSourceSpan
  (match (ast.ast-node-get expr-id)
    [(ast.AstExpr.Spanned _ span) span]
    [_ (lint_core.lint-no-span)]))

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

(define (selfhost-lint-dead-find-name-prefix-from
  [source : String]
  [needle : String]
  [idx : i64]) : i64
  (let
    [found : i64 (selfhost-lint-dead-find-prefix-from source needle idx)]
    (if (< found 0)
      found
      (if (selfhost-lint-form-delim?
        source
        (+ found (string.string-length needle)))
        found
        (selfhost-lint-dead-find-name-prefix-from source needle (+ found 1))))))

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
  [fallback : ast.AstSourceSpan]) : ast.AstSourceSpan
  (if (< idx 0)
    fallback
    (let
      [line : i64 (selfhost-lint-dead-index-line source idx)]
      [col : i64 (selfhost-lint-dead-index-col source idx)]
      (ast.ast-source-span line col line (+ col 1)))))

(define (selfhost-lint-dead-decl-span
  [source : String]
  [name : String]
  [body-span : ast.AstSourceSpan]) : ast.AstSourceSpan
  (let
    [fn-needle : String (str_cat.str-cat "(define (" name)]
    [fn-idx : i64 (selfhost-lint-dead-find-name-prefix-from source fn-needle 0)]
    (if (>= fn-idx 0)
      (selfhost-lint-dead-index-span source fn-idx body-span)
      (selfhost-lint-dead-index-span
        source
        (selfhost-lint-dead-find-name-prefix-from
          source
          (str_cat.str-cat "(define " name)
          0)
        body-span))))

(define (selfhost-lint-dead-refs-to-roots-from
  [scan : SelfhostLintDeadScan (:consume)]
  [refs : lint_svec.Vec]
  [index : i64]) : SelfhostLintDeadScan
  (if (>= index (lint_svec.len (& refs)))
    scan
    (selfhost-lint-dead-refs-to-roots-from
      (selfhost-lint-dead-scan-add-root scan (lint_svec.get (& refs) index ""))
      refs
      (+ index 1))))

(define (selfhost-lint-dead-refs-to-roots
  [scan : SelfhostLintDeadScan (:consume)]
  [refs : lint_svec.Vec]) : SelfhostLintDeadScan
  (selfhost-lint-dead-refs-to-roots-from scan refs 0))

(define (selfhost-lint-dead-field-cleanup-refs
  [cleanup : ast.AstFieldCleanup]
  [refs : lint_svec.Vec (:consume)]) : lint_svec.Vec
  (match cleanup
    [(ast.AstFieldCleanup.No) refs]
    [(ast.AstFieldCleanup.Fn name) (selfhost-lint-dead-ref-add-id refs name)]
    [(ast.AstFieldCleanup.Owned) refs]))

(define (selfhost-lint-dead-field-def-list-refs
  [fields : ast.AstFieldDefList]
  [refs : lint_svec.Vec (:consume)]) : lint_svec.Vec
  (selfhost-lint-dead-field-def-list-refs-at (& fields) refs 0))

(define (selfhost-lint-dead-field-def-list-refs-at
  [fields : (& fields ast.AstFieldDefList)]
  [refs : lint_svec.Vec (:consume)]
  [index : i64]) : lint_svec.Vec
  (if (>= index fields.len)
    refs
    (match (ast.ast-field-def-list-get
      fields
      index
      (ast.ast-field-def-fallback))
      [(ast.AstFieldDef.Def _ ty cleanup)
        (selfhost-lint-dead-field-def-list-refs-at
          fields
          (selfhost-lint-dead-field-cleanup-refs
            cleanup
            (selfhost-lint-dead-type-refs ty refs))
          (+ index 1))])))

(define (selfhost-lint-dead-struct-cleanup-refs
  [cleanup : ast.AstStructCleanup]
  [refs : lint_svec.Vec (:consume)]) : lint_svec.Vec
  (match cleanup
    [(ast.AstStructCleanup.No) refs]
    [(ast.AstStructCleanup.Fn name) (selfhost-lint-dead-ref-add-id refs name)]))

(define (selfhost-lint-dead-enum-cleanup-refs
  [cleanup : ast.AstEnumCleanup]
  [refs : lint_svec.Vec (:consume)]) : lint_svec.Vec
  (match cleanup
    [(ast.AstEnumCleanup.No) refs]
    [(ast.AstEnumCleanup.Fn name) (selfhost-lint-dead-ref-add-id refs name)]))

(define (selfhost-lint-dead-variant-cleanup-refs
  [cleanup : ast.AstVariantPayloadCleanup]
  [refs : lint_svec.Vec (:consume)]) : lint_svec.Vec
  (match cleanup
    [(ast.AstVariantPayloadCleanup.No) refs]
    [(ast.AstVariantPayloadCleanup.Fn name)
      (selfhost-lint-dead-ref-add-id refs name)]
    [(ast.AstVariantPayloadCleanup.Owned) refs]))

(define (selfhost-lint-dead-variant-cleanup-list-refs
  [items : ast.AstVariantPayloadCleanupList]
  [refs : lint_svec.Vec (:consume)]) : lint_svec.Vec
  (selfhost-lint-dead-variant-cleanup-list-refs-at (& items) refs 0))

(define (selfhost-lint-dead-variant-cleanup-list-refs-at
  [items : (& items ast.AstVariantPayloadCleanupList)]
  [refs : lint_svec.Vec (:consume)]
  [index : i64]) : lint_svec.Vec
  (if (>= index items.len)
    refs
    (selfhost-lint-dead-variant-cleanup-list-refs-at
      items
      (selfhost-lint-dead-variant-cleanup-refs
        (ast.ast-variant-payload-cleanup-list-get
          items
          index
          (ast.ast-variant-payload-cleanup-fallback))
        refs)
      (+ index 1))))

(define (selfhost-lint-dead-variant-def-list-refs
  [variants : ast.AstVariantDefList]
  [refs : lint_svec.Vec (:consume)]) : lint_svec.Vec
  (selfhost-lint-dead-variant-def-list-refs-at (& variants) refs 0))

(define (selfhost-lint-dead-variant-def-list-refs-at
  [variants : (& variants ast.AstVariantDefList)]
  [refs : lint_svec.Vec (:consume)]
  [index : i64]) : lint_svec.Vec
  (if (>= index variants.len)
    refs
    (match (ast.ast-variant-def-list-get
      variants
      index
      (ast.ast-variant-def-fallback))
      [(ast.AstVariantDef.Def name payloads cleanups)
        (selfhost-lint-dead-variant-def-list-refs-at
          variants
          (selfhost-lint-dead-variant-cleanup-list-refs
            cleanups
            (selfhost-lint-dead-type-list-refs
              payloads
              (selfhost-lint-dead-ref-add-id refs name)))
          (+ index 1))])))

(define (selfhost-lint-dead-dispatch-variant-list-refs-from
  [variants : (& variants ast.AstDispatchVariantList)]
  [index : i64]
  [refs : lint_svec.Vec (:consume)]) : lint_svec.Vec
  (if (>= index variants.len)
    refs
    (match (ast.ast-dispatch-variant-list-get
      variants
      index
      (ast.ast-dispatch-variant-fallback))
      [(ast.AstDispatchVariant.Variant _ name)
        (selfhost-lint-dead-dispatch-variant-list-refs-from
          variants
          (+ index 1)
          (selfhost-lint-dead-ref-add-id refs name))])))

(define (selfhost-lint-dead-dispatch-variant-list-refs
  [variants : ast.AstDispatchVariantList]
  [refs : lint_svec.Vec (:consume)]) : lint_svec.Vec
  (selfhost-lint-dead-dispatch-variant-list-refs-from (& variants) 0 refs))

(define (selfhost-lint-dead-extern-abi-refs
  [abi : ast.AstExternAbi]
  [refs : lint_svec.Vec (:consume)]) : lint_svec.Vec
  (match abi
    [(ast.AstExternAbi.C) refs]
    [(ast.AstExternAbi.CVarargsOpen) refs]
    [(ast.AstExternAbi.CVarargsTyped tail-ty)
      (selfhost-lint-dead-type-refs tail-ty refs)]))

(define (selfhost-lint-dead-extern-metadata-refs
  [meta : ast.AstExternMetadata]
  [refs : lint_svec.Vec (:consume)]) : lint_svec.Vec
  (match meta
    [(ast.AstExternMetadata.Metadata abi _ _ _ _)
      (selfhost-lint-dead-extern-abi-refs abi refs)]))

(define (selfhost-lint-dead-generated-meta-refs
  [meta : ast.AstGeneratedDeclMeta]
  [refs : lint_svec.Vec (:consume)]) : lint_svec.Vec
  (match meta
    [(ast.AstGeneratedDeclMeta.No) refs]
    [(ast.AstGeneratedDeclMeta.Some _ _ args _)
      (selfhost-lint-dead-expr-list-refs args refs)]))

(define (selfhost-lint-dead-add-node
  [scan : SelfhostLintDeadScan]
  [path : String]
  [module : String]
  [name : String]
  [span : ast.AstSourceSpan]
  [refs : lint_svec.Vec]
  [reportable : bool]) : SelfhostLintDeadScan
  (let
    [node-refs : lint_svec.Vec (selfhost-lint-dead-localize-refs module refs)]
    [key : String (selfhost-lint-dead-module-key module name)]
    (selfhost-lint-dead-scan-add-decl
      scan
      (SelfhostLintDeadDecl path name key span node-refs false reportable))))

(define (selfhost-lint-dead-add-visible-node
  [scan : SelfhostLintDeadScan]
  [path : String]
  [module : String]
  [source : String]
  [name : String]
  [span : ast.AstSourceSpan]
  [refs : lint_svec.Vec]
  [root : bool]
  [reportable : bool]) : SelfhostLintDeadScan
  (let
    [with-node : SelfhostLintDeadScan
      (selfhost-lint-dead-add-node scan path module name span refs reportable)]
    [explicit-root : bool
      (selfhost-lint-suppressed?
        source
        (lint_core.lint-dead-code-finding name span))]
    (if root
      (selfhost-lint-dead-scan-add-root with-node name)
      (if explicit-root
        (selfhost-lint-dead-scan-add-root
          with-node
          (selfhost-lint-dead-source-root path name))
        with-node))))

(define (selfhost-lint-dead-scan-decl
  [scan : SelfhostLintDeadScan (:consume)]
  [path : String]
  [module : String]
  [source : String]
  [decl : ast.AstDecl]
  [visible-root : bool]
  [requested-report : bool]) : SelfhostLintDeadScan
  (let
    [allow-report : bool
      (and requested-report (not (ast.ast-decl-comptime-only? decl)))]
    [result : SelfhostLintDeadScan
      (match decl
        [(ast.AstDecl.ModuleBody name body-box)
          (selfhost-lint-dead-scan-decls
            scan
            path
            (ci.intern-str name)
            source
            visible-root
            allow-report
            (__tl-box-place body-box))]
        [(ast.AstDecl.Module _) scan]
        [(ast.AstDecl.Def decl-meta name maybe-ty body)
          (let
            [text : String (ci.intern-str name)]
            [refs : lint_svec.Vec
              (selfhost-lint-dead-expr-refs
                (ast.ast-node-get body)
                (selfhost-lint-dead-maybe-type-refs maybe-ty (lint_svec.new)))]
            [span : ast.AstSourceSpan
              (selfhost-lint-dead-decl-span
                source
                text
                (selfhost-lint-dead-expr-span body))]
            (selfhost-lint-dead-add-visible-node
              scan
              path
              module
              source
              text
              span
              refs
              visible-root
              allow-report))]
        [(ast.AstDecl.DefFn decl-meta name params ret body _)
          (let
            [text : String (ci.intern-str name)]
            [refs : lint_svec.Vec
              (selfhost-lint-dead-expr-refs
                (ast.ast-node-get body)
                (selfhost-lint-dead-type-refs
                  ret
                  (selfhost-lint-dead-param-list-refs params (lint_svec.new))))]
            [span : ast.AstSourceSpan
              (selfhost-lint-dead-decl-span
                source
                text
                (selfhost-lint-dead-expr-span body))]
            (selfhost-lint-dead-add-visible-node
              scan
              path
              module
              source
              text
              span
              refs
              visible-root
              allow-report))]
        [(ast.AstDecl.DefMacro decl-meta name params ret body)
          (selfhost-lint-dead-add-visible-node
            scan
            path
            module
            source
            (ci.intern-str name)
            (selfhost-lint-dead-expr-span body)
            (selfhost-lint-dead-expr-refs
              (ast.ast-node-get body)
              (selfhost-lint-dead-type-refs
                ret
                (selfhost-lint-dead-macro-param-list-refs
                  params
                  (lint_svec.new))))
            visible-root
            allow-report)]
        [(ast.AstDecl.Extern decl-meta name _ meta ty)
          (selfhost-lint-dead-add-visible-node
            scan
            path
            module
            source
            (ci.intern-str name)
            (lint_core.lint-no-span)
            (selfhost-lint-dead-type-refs
              ty
              (selfhost-lint-dead-extern-metadata-refs
                (__tl-box-place meta)
                (lint_svec.new)))
            visible-root
            allow-report)]
        [(ast.AstDecl.DefEnum decl-meta name cleanup variants)
          (selfhost-lint-dead-add-visible-node
            scan
            path
            module
            source
            (ci.intern-str name)
            (lint_core.lint-no-span)
            (selfhost-lint-dead-variant-def-list-refs
              variants
              (selfhost-lint-dead-enum-cleanup-refs cleanup (lint_svec.new)))
            visible-root
            allow-report)]
        [(ast.AstDecl.DefEnumLifetimes decl-meta name _ cleanup variants)
          (selfhost-lint-dead-add-visible-node
            scan
            path
            module
            source
            (ci.intern-str name)
            (lint_core.lint-no-span)
            (selfhost-lint-dead-variant-def-list-refs
              variants
              (selfhost-lint-dead-enum-cleanup-refs cleanup (lint_svec.new)))
            visible-root
            allow-report)]
        [(ast.AstDecl.DefStruct decl-meta name _ cleanup fields)
          (selfhost-lint-dead-add-visible-node
            scan
            path
            module
            source
            (ci.intern-str name)
            (lint_core.lint-no-span)
            (selfhost-lint-dead-field-def-list-refs
              fields
              (selfhost-lint-dead-struct-cleanup-refs cleanup (lint_svec.new)))
            visible-root
            allow-report)]
        [(ast.AstDecl.DefStructLifetimes decl-meta name _ _ cleanup fields)
          (selfhost-lint-dead-add-visible-node
            scan
            path
            module
            source
            (ci.intern-str name)
            (lint_core.lint-no-span)
            (selfhost-lint-dead-field-def-list-refs
              fields
              (selfhost-lint-dead-struct-cleanup-refs cleanup (lint_svec.new)))
            visible-root
            allow-report)]
        [(ast.AstDecl.Import
            decl-meta
            (ast.AstImportSpec.Spec
              (ast.AstImportKind.Macro call-expr _)
              _
              _
              _
              _))
          (selfhost-lint-dead-refs-to-roots
            scan
            (selfhost-lint-dead-expr-refs
              (ast.ast-node-get call-expr)
              (lint_svec.new)))]
        [(ast.AstDecl.Import
            decl-meta
            (ast.AstImportSpec.Spec
              (ast.AstImportKind.MacroDecls call-expr _)
              _
              _
              _
              _))
          (selfhost-lint-dead-refs-to-roots
            scan
            (selfhost-lint-dead-expr-refs
              (ast.ast-node-get call-expr)
              (lint_svec.new)))]
        [(ast.AstDecl.Import decl-meta _) scan]
        [(ast.AstDecl.IncludeStr _ _) scan]
        [(ast.AstDecl.IncludeStrComptime _ _) scan]
        [(ast.AstDecl.IncludeStrLzss _ _) scan]
        [(ast.AstDecl.IncludeBin _ _) scan]
        [(ast.AstDecl.DefDispatch decl-meta name variants)
          (selfhost-lint-dead-add-visible-node
            scan
            path
            module
            source
            (ci.intern-str name)
            (lint_core.lint-no-span)
            (selfhost-lint-dead-dispatch-variant-list-refs
              variants
              (lint_svec.new))
            visible-root
            allow-report)]
        [(ast.AstDecl.Test _ body _)
          (selfhost-lint-dead-refs-to-roots
            scan
            (selfhost-lint-dead-expr-refs
              (ast.ast-node-get body)
              (lint_svec.new)))]
        [(ast.AstDecl.Unsafe inner)
          (selfhost-lint-dead-scan-decl
            scan
            path
            module
            source
            (__tl-box-place inner)
            visible-root
            allow-report)])]
    (selfhost-lint-dead-refs-to-roots
      result
      (selfhost-lint-dead-generated-meta-refs
        (ast.ast-decl-generated-meta decl)
        (lint_svec.new)))))

(define (selfhost-lint-dead-scan-decls
  [scan : SelfhostLintDeadScan (:consume)]
  [path : String]
  [module : String]
  [source : String]
  [visible-root : bool]
  [reportable : bool]
  [decls : ast.AstDeclList]) : SelfhostLintDeadScan
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) scan]
    [(ast.AstDeclListStep.Cons decl rest)
      (match decl
        [(ast.AstDecl.Module name)
          (selfhost-lint-dead-scan-decls
            scan
            path
            (ci.intern-str name)
            source
            visible-root
            reportable
            rest)]
        [(ast.AstDecl.ModuleBody name body-box)
          (selfhost-lint-dead-scan-decls
            (selfhost-lint-dead-scan-decls
              scan
              path
              (ci.intern-str name)
              source
              visible-root
              reportable
              (__tl-box-place body-box))
            path
            module
            source
            visible-root
            reportable
            rest)]
        [_
          (selfhost-lint-dead-scan-decls
            (selfhost-lint-dead-scan-decl
              scan
              path
              module
              source
              decl
              visible-root
              reportable)
            path
            module
            source
            visible-root
            reportable
            rest)])]))

(define (selfhost-lint-dead-import-aliases-from-decls
  [decls : ast.AstDeclList]
  [aliases : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) aliases]
    [(ast.AstDeclListStep.Cons decl rest)
      (match decl
        [(ast.AstDecl.Import
            _
            (ast.AstImportSpec.Spec
              (ast.AstImportKind.Module)
              _
              (ast.AstMaybeModuleName.Some target)
              (ast.AstMaybeImportAlias.Some alias)
              _))
          (selfhost-lint-dead-import-aliases-from-decls
            rest
            (sym_i64_env.sym-i64-bind-id
              aliases
              alias
              (parser.parse-ast-dotted-import-default-alias-id target)))]
        [(ast.AstDecl.ModuleBody _ body-box)
          (selfhost-lint-dead-import-aliases-from-decls
            rest
            (selfhost-lint-dead-import-aliases-from-decls
              (__tl-box-place body-box)
              aliases))]
        [_ (selfhost-lint-dead-import-aliases-from-decls rest aliases)])]))

(define (selfhost-lint-dead-scan-source-with-cfgs
  [scan : SelfhostLintDeadScan]
  [path : String]
  [source : String]
  [visible-root : bool]
  [reportable : bool]
  [cfgs : sym_i64_env.SymI64Env]) : SelfhostLintDeadScan
  (match (parser.parse-ast-source-diagnostic-with-cfg path source cfgs)
    [(parser.ResultAstProgramDiagnostic.Ok program)
      (match program
        [(ast.AstProgram.Program decls-box)
          (let
            [decls : ast.AstDeclList (__tl-box-place decls-box)]
            (begin
              (set!
                selfhost-lint-dead-import-aliases
                (selfhost-lint-dead-import-aliases-from-decls
                  decls
                  (sym_i64_env.sym-i64-empty)))
              (selfhost-lint-dead-scan-decls
                scan
                path
                (selfhost-lint-dead-default-module-from-path path)
                source
                visible-root
                reportable
                decls)))])]
    [(parser.ResultAstProgramDiagnostic.Err _) scan]))

(define (selfhost-lint-dead-scan-source
  [scan : SelfhostLintDeadScan]
  [path : String]
  [source : String]
  [visible-root : bool]
  [reportable : bool]) : SelfhostLintDeadScan
  ;; Branch-union cfgs preserve both supported sides of an expression in one
  ;; AST, so large compiler sources are parsed once while reachability still
  ;; observes summary and detailed compile-profile references.
  (selfhost-lint-dead-scan-source-with-cfgs
    scan
    path
    source
    visible-root
    reportable
    (selfhost-lint-package-dead-cfgs)))

(define (selfhost-lint-dead-clone-string-vec-from
  [source : lint_svec.Vec]
  [index : i64]
  [items : lint_svec.Vec (:consume)]) : lint_svec.Vec
  (if (>= index (lint_svec.len (& source)))
    items
    (let
      [value : String (lint_svec.get (& source) index "")]
      [owned : String (clone value)]
      [next : lint_svec.Vec items]
      (begin
        (lint_svec.push-ref! (&mut next) owned)
        (selfhost-lint-dead-clone-string-vec-from source (+ index 1) next)))))

(define (selfhost-lint-dead-clone-string-vec [source : lint_svec.Vec]) : lint_svec.Vec
  (selfhost-lint-dead-clone-string-vec-from source 0 (lint_svec.new)))

(define (selfhost-lint-dead-clone-decl [decl : SelfhostLintDeadDecl]) : SelfhostLintDeadDecl
  (let
    [path : String decl.path]
    [name : String decl.name]
    [key : String decl.key]
    [span : ast.AstSourceSpan decl.span]
    (SelfhostLintDeadDecl
      (clone path)
      (clone name)
      (clone key)
      (ast.AstSourceSpan
        span.start-line
        span.start-col
        span.end-line
        span.end-col)
      (selfhost-lint-dead-clone-string-vec decl.refs)
      decl.root
      decl.reportable)))

(define (selfhost-lint-dead-scan-clone-decls-from
  [scan : SelfhostLintDeadScan]
  [source-scan : SelfhostLintDeadScan]
  [index : i64]) : SelfhostLintDeadScan
  (if (>= index (selfhost-lint-dead-decls-count source-scan.decls))
    scan
    (let
      [decl : SelfhostLintDeadDecl
        (selfhost-lint-dead-decls-ref source-scan.decls index)]
      [owned : SelfhostLintDeadDecl (selfhost-lint-dead-clone-decl decl)]
      (selfhost-lint-dead-scan-clone-decls-from
        (selfhost-lint-dead-scan-add-decl scan owned)
        source-scan
        (+ index 1)))))

(define (selfhost-lint-dead-scan-clone-roots-from
  [scan : SelfhostLintDeadScan (:consume)]
  [source-scan : SelfhostLintDeadScan]
  [index : i64]) : SelfhostLintDeadScan
  (if (>= index (lint_svec.len (& source-scan.roots)))
    scan
    (let
      [root : String (lint_svec.get (& source-scan.roots) index "")]
      [owned : String (clone root)]
      (selfhost-lint-dead-scan-clone-roots-from
        (selfhost-lint-dead-scan-add-root scan owned)
        source-scan
        (+ index 1)))))

(define (selfhost-lint-dead-scan-clone-into
  [scan : SelfhostLintDeadScan]
  [source-scan : SelfhostLintDeadScan]) : SelfhostLintDeadScan
  (selfhost-lint-dead-scan-clone-roots-from
    (selfhost-lint-dead-scan-clone-decls-from scan source-scan 0)
    source-scan
    0))

(define (selfhost-lint-dead-scan-file-in-scratch
  [scan : SelfhostLintDeadScan]
  [path : String]
  [visible-root : bool]
  [reportable : bool]) : SelfhostLintDeadScan
  (let
    ;; Package lint needs only compact declaration metadata after scanning a
    ;; file. Clone that metadata home, then release the file's complete AST.
    [home : arena.Arena (arena.current)]
    [pool-arena : i64 (arena.tl_arena_make)]
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities-in-arena
        selfhost-lint-expr-pool-initial-capacity
        selfhost-lint-type-pool-initial-capacity
        pool-arena)]
    [_install-pools : unit (ast.ast-node-pool-compat-context-use! pools)]
    [scratch : arena.Arena (arena.make)]
    [source-scan : SelfhostLintDeadScan
      (begin
        (unsafe
          (arena.set! scratch))
        (selfhost-lint-dead-scan-source
          (SelfhostLintDeadScan
            (selfhost-lint-dead-decls-empty)
            (lint_svec.new))
          path
          (byte_buf.to-string (io.read-file path))
          visible-root
          reportable))]
    [_restore-home : unit
      (unsafe
        (arena.set! home))]
    [next : SelfhostLintDeadScan
      (selfhost-lint-dead-scan-clone-into scan source-scan)]
    (begin
      (selfhost-lint-reset-file-state!)
      (ast.ast-node-pool-context-reset-to! pools 0 0)
      (ast.ast-node-pool-compat-context-clear!)
      (ast.ast-node-pool-context-destroy-storage! pools)
      (unsafe
        (begin
          (arena.set! home)
          (arena.destroy scratch)
          (arena.tl_arena_destroy (ast.ast-node-pool-context-base-arena pools))))
      next)))

(define (selfhost-lint-package-dead-scan-files
  [sources : lint_svec.Vec]
  [reportable-sources : lint_svec.Vec]
  [stdlib-roots : lint_svec.Vec]
  [index : i64]
  [visible-root : bool]
  [reportable : bool]
  [scan : SelfhostLintDeadScan]) : SelfhostLintDeadScan
  (if (>= index (lint_svec.len (& sources)))
    scan
    (let
      [path : String (lint_svec.get (& sources) index "")]
      (selfhost-lint-package-dead-scan-files
        sources
        reportable-sources
        stdlib-roots
        (+ index 1)
        visible-root
        reportable
        (selfhost-lint-dead-scan-file-in-scratch
          scan
          path
          visible-root
          (and
            reportable
            (selfhost-lint-package-dead-source-path?
              path
              reportable-sources
              stdlib-roots)))))))

(define (selfhost-lint-dead-decls-index-of-from
  [items : SelfhostLintDeadDecls]
  [name : String]
  [index : i64]) : i64
  (if (>= index (selfhost-lint-dead-decls-count items))
    (- 0 1)
    (if (string.eq
      (__tl-project-field (selfhost-lint-dead-decls-ref items index) name)
      name)
      index
      (selfhost-lint-dead-decls-index-of-from items name (+ index 1)))))

(define (selfhost-lint-dead-decls-index-of
  [items : SelfhostLintDeadDecls]
  [name : String]) : i64
  (selfhost-lint-dead-decls-index-of-from items name 0))

(define (selfhost-lint-dead-decls-index-of-key-from
  [items : SelfhostLintDeadDecls]
  [key : String]
  [index : i64]) : i64
  (if (>= index (selfhost-lint-dead-decls-count items))
    (- 0 1)
    (if (string.eq
      (__tl-project-field (selfhost-lint-dead-decls-ref items index) key)
      key)
      index
      (selfhost-lint-dead-decls-index-of-key-from items key (+ index 1)))))

(define (selfhost-lint-dead-decls-index-of-key
  [items : SelfhostLintDeadDecls]
  [key : String]) : i64
  (selfhost-lint-dead-decls-index-of-key-from items key 0))

(define (selfhost-lint-dead-mark-refs-from
  [items : SelfhostLintDeadDecls]
  [refs : lint_svec.Vec]
  [index : i64]) : SelfhostLintDeadDecls
  (if (>= index (lint_svec.len (& refs)))
    items
    (selfhost-lint-dead-mark-refs-from
      (selfhost-lint-dead-mark-reachable-ref
        items
        (lint_svec.get (& refs) index ""))
      refs
      (+ index 1))))

(define (selfhost-lint-dead-mark-reachable-index
  [items : SelfhostLintDeadDecls]
  [index : i64]) : SelfhostLintDeadDecls
  (let
    [decl : SelfhostLintDeadDecl (selfhost-lint-dead-decls-ref items index)]
    (if decl.root
      items
      (let
        [marked : SelfhostLintDeadDecl
          (SelfhostLintDeadDecl
            decl.path
            decl.name
            decl.key
            decl.span
            decl.refs
            true
            decl.reportable)]
        [updated : SelfhostLintDeadDecls
          (selfhost-lint-dead-decls-set items index marked)]
        (selfhost-lint-dead-mark-refs-from updated marked.refs 0)))))

(define (selfhost-lint-dead-mark-reachable-name
  [items : SelfhostLintDeadDecls]
  [name : String]) : SelfhostLintDeadDecls
  (let
    [index : i64 (selfhost-lint-dead-decls-index-of items name)]
    (if (< index 0)
      items
      (selfhost-lint-dead-mark-reachable-index items index))))

(define (selfhost-lint-dead-mark-reachable-ref
  [items : SelfhostLintDeadDecls]
  [ref : String]) : SelfhostLintDeadDecls
  (if (selfhost-lint-dead-qualified-ref? ref)
    (let
      [index : i64
        (selfhost-lint-dead-decls-index-of-key
          items
          (selfhost-lint-dead-qualified-ref-key ref))]
      (if (< index 0)
        (selfhost-lint-dead-mark-reachable-name
          items
          (selfhost-lint-dead-qualified-ref-fallback ref))
        (selfhost-lint-dead-mark-reachable-index items index)))
    (selfhost-lint-dead-mark-reachable-name items ref)))

(define (selfhost-lint-dead-mark-root-name-from
  [items : SelfhostLintDeadDecls]
  [name : String]
  [index : i64]) : SelfhostLintDeadDecls
  (if (>= index (selfhost-lint-dead-decls-count items))
    items
    (let
      [decl : SelfhostLintDeadDecl (selfhost-lint-dead-decls-ref items index)]
      [next : SelfhostLintDeadDecls
        (if (string.eq decl.name name)
          (selfhost-lint-dead-mark-reachable-index items index)
          items)]
      (selfhost-lint-dead-mark-root-name-from next name (+ index 1)))))

(define (selfhost-lint-dead-mark-source-root-from
  [items : SelfhostLintDeadDecls]
  [path : String]
  [name : String]
  [index : i64]) : SelfhostLintDeadDecls
  (if (>= index (selfhost-lint-dead-decls-count items))
    items
    (let
      [decl : SelfhostLintDeadDecl (selfhost-lint-dead-decls-ref items index)]
      [next : SelfhostLintDeadDecls
        (if (and (string.eq decl.path path) (string.eq decl.name name))
          (selfhost-lint-dead-mark-reachable-index items index)
          items)]
      (selfhost-lint-dead-mark-source-root-from next path name (+ index 1)))))

(define (selfhost-lint-dead-mark-root-name
  [items : SelfhostLintDeadDecls]
  [name : String]) : SelfhostLintDeadDecls
  (cond
    [(selfhost-lint-dead-source-root? name)
      (selfhost-lint-dead-mark-source-root-from
        items
        (selfhost-lint-dead-source-root-path name)
        (selfhost-lint-dead-source-root-name name)
        0)]
    [(selfhost-lint-dead-qualified-ref? name)
      (selfhost-lint-dead-mark-reachable-ref items name)]
    [else (selfhost-lint-dead-mark-root-name-from items name 0)]))

(define (selfhost-lint-dead-mark-roots-from
  [items : SelfhostLintDeadDecls]
  [roots : lint_svec.Vec]
  [index : i64]) : SelfhostLintDeadDecls
  (if (>= index (lint_svec.len (& roots)))
    items
    (selfhost-lint-dead-mark-roots-from
      (selfhost-lint-dead-mark-root-name
        items
        (lint_svec.get (& roots) index ""))
      roots
      (+ index 1))))

(define (selfhost-lint-package-dead-visible-root?
  [kind : compiler_load.CompilerPkgKind]) : bool
  (match kind
    [(CompilerPkgKindBin) false]
    [(CompilerPkgKindLib) true]))

(define (selfhost-lint-package-dead-reportable?
  [kind : compiler_load.CompilerPkgKind]) : bool
  (match kind
    [(CompilerPkgKindBin) true]
    [(CompilerPkgKindLib) false]))

(define (selfhost-lint-package-dead-add-kind-roots
  [scan : SelfhostLintDeadScan (:consume)]
  [kind : compiler_load.CompilerPkgKind]) : SelfhostLintDeadScan
  (match kind
    [(CompilerPkgKindBin) (selfhost-lint-dead-scan-add-root scan "main")]
    [(CompilerPkgKindLib) scan]))

(define (selfhost-lint-package-kind-entry?
  [kind : compiler_load.CompilerPkgKind]) : bool
  (match kind
    [(CompilerPkgKindBin) true]
    [(CompilerPkgKindLib) false]))

(define (selfhost-lint-package-entry-path
  [manifest-dir : String]
  [manifest : compiler_load.CompilerPkgManifest]) : String
  (compiler_load.compiler-load-normalize-path
    (compiler_load.compiler-load-join-root-path manifest-dir manifest.entry)))

;; Package sources commonly live below `src/`, while package test roots under
;; `src/tests/` import them by module name. Make the entry directory available
;; to the per-file lint loader without classifying it as stdlib-owned source.
(define (selfhost-lint-package-import-roots
  [source-set : package_source_core.PackageSourceSet]
  [stdlib-roots : lint_svec.Vec (:consume)]) : lint_svec.Vec
  (let
    [manifest : compiler_load.CompilerPkgManifest source-set.manifest]
    [manifest-dir : String source-set.manifest-dir]
    [entry-path : String
      (selfhost-lint-package-entry-path manifest-dir manifest)]
    [entry-dir : String (compiler_load.compiler-load-dirname entry-path)]
    [source-root : String
      (compiler_load.compiler-load-normalize-path
        (if (= (string.string-length entry-dir) 0)
          manifest-dir
          entry-dir))]
    (if (or
      (= (string.string-length source-root) 0)
      (lint_svec.contains? (& stdlib-roots) source-root))
      stdlib-roots
      (let
        [roots : lint_svec.Vec stdlib-roots]
        (begin
          (lint_svec.push-ref! (&mut roots) source-root)
          roots)))))

(define (selfhost-lint-package-source-list-contains-from
  [sources : lint_svec.Vec]
  [path : String]
  [index : i64]) : bool
  (if (>= index (lint_svec.len (& sources)))
    false
    (if (string.eq
      (compiler_load.compiler-load-normalize-path
        (lint_svec.get (& sources) index ""))
      (compiler_load.compiler-load-normalize-path path))
      true
      (selfhost-lint-package-source-list-contains-from sources path (+ index 1)))))

(define (selfhost-lint-package-source-list-contains?
  [sources : lint_svec.Vec]
  [path : String]) : bool
  (selfhost-lint-package-source-list-contains-from sources path 0))

(define (selfhost-lint-package-empty-source-list) : lint_svec.Vec
  (lint_svec.new))

(define (selfhost-lint-package-stdlib-source?
  [path : String]
  [stdlib-roots : lint_svec.Vec (:consume)]) : bool
  (let
    [normalized : String (compiler_load.compiler-load-normalize-path path)]
    [stdlib-path : String
      (if (compiler_load.compiler-load-stdlib-import? normalized)
        normalized
        (compiler_load.compiler-load-stdlib-owned-path-from-roots
          normalized
          stdlib-roots))]
    (compiler_load.compiler-load-stdlib-import? stdlib-path)))

(define (selfhost-lint-package-dead-source-path?
  [path : String]
  [sources : lint_svec.Vec]
  [stdlib-roots : lint_svec.Vec (:consume)]) : bool
  (and
    (> (string.string-length path) 0)
    (selfhost-lint-package-source-list-contains? sources path)
    (not (selfhost-lint-package-stdlib-source? path stdlib-roots))))

(define (selfhost-lint-package-dead-graph-source-path?
  [path : String]
  [sources : lint_svec.Vec]
  [root-sources : lint_svec.Vec]
  [stdlib-roots : lint_svec.Vec]) : bool
  (and
    (> (string.string-length path) 0)
    (or
      (selfhost-lint-package-source-list-contains? sources path)
      (selfhost-lint-package-source-list-contains? root-sources path))
    (not (selfhost-lint-package-stdlib-source? path stdlib-roots))))

(define (selfhost-lint-package-dead-graph-source-insert
  [items : lint_svec.Vec]
  [path : String]
  [sources : lint_svec.Vec]
  [root-sources : lint_svec.Vec]
  [stdlib-roots : lint_svec.Vec]) : lint_svec.Vec
  (if (selfhost-lint-package-dead-graph-source-path?
    path
    sources
    root-sources
    stdlib-roots)
    (package_source_core.package-source-vec-insert
      items
      (compiler_load.compiler-load-normalize-path path))
    items))

(define (selfhost-lint-dead-manifest-trim-cr [value : String]) : String
  (let
    [n : i64 (string.string-length value)]
    (if (> n 0)
      (if (= (string.string-ref value (- n 1)) '\r')
        (string.substring value 0 (- n 1))
        value)
      value)))

(define (selfhost-lint-dead-manifest-field [line : String] [target : i64]) : String
  (let
    [n : i64 (string.string-length line)]
    [field : i64 0]
    [start : i64 0]
    [index : i64 0]
    [found : bool false]
    [value : String ""]
    (begin
      (while (and (<= index n) (not found))
        (let
          [delimiter : bool
            (if (= index n)
              true
              (= (string.string-ref line index) '|'))]
          (if delimiter
            (if (= field target)
              (begin
                (set!
                  value
                  (selfhost-lint-dead-manifest-trim-cr
                    (string.substring line start (- index start))))
                (set! found true))
              (begin
                (set! field (+ field 1))
                (set! start (+ index 1))
                (set! index (+ index 1))))
            (set! index (+ index 1)))))
      value)))

(define (selfhost-lint-dead-manifest-line-end [source : String] [start : i64]) : i64
  (let
    [n : i64 (string.string-length source)]
    [index : i64 start]
    [done : bool false]
    (begin
      (while (not done)
        (if (>= index n)
          (set! done true)
          (if (= (string.string-ref source index) '\n')
            (set! done true)
            (set! index (+ index 1)))))
      index)))

(define (selfhost-lint-dead-manifest-roots-from
  [source : String]
  [manifest-dir : String]
  [index : i64]
  [case-path : String]
  [roots : lint_svec.Vec (:consume)]) : lint_svec.Vec
  (let
    [n : i64 (string.string-length source)]
    (if (>= index n)
      roots
      (let
        [line-end : i64 (selfhost-lint-dead-manifest-line-end source index)]
        [line : String (string.substring source index (- line-end index))]
        [kind : String (selfhost-lint-dead-manifest-field line 0)]
        [next-index : i64
          (if (< line-end n)
            (+ line-end 1)
            line-end)]
        (cond
          [(string.eq kind "case")
            (let
              [relative : String (selfhost-lint-dead-manifest-field line 2)]
              [next-path : String
                (if (= (string.string-length relative) 0)
                  ""
                  (compiler_load.compiler-load-normalize-path
                    (compiler_load.compiler-load-join-root-path
                      manifest-dir
                      relative)))]
              (selfhost-lint-dead-manifest-roots-from
                source
                manifest-dir
                next-index
                next-path
                roots))]
          [(string.eq kind "lint-root")
            (let
              [name : String (selfhost-lint-dead-manifest-field line 1)]
              [next-roots : lint_svec.Vec
                (if (or
                  (= (string.string-length case-path) 0)
                  (= (string.string-length name) 0))
                  roots
                  (selfhost-lint-dead-root-add
                    roots
                    (selfhost-lint-dead-source-root case-path name)))]
              (selfhost-lint-dead-manifest-roots-from
                source
                manifest-dir
                next-index
                case-path
                next-roots))]
          [(string.eq kind "end")
            (selfhost-lint-dead-manifest-roots-from
              source
              manifest-dir
              next-index
              ""
              roots)]
          [else
            (selfhost-lint-dead-manifest-roots-from
              source
              manifest-dir
              next-index
              case-path
              roots)])))))

(define (selfhost-lint-dead-manifest-roots
  [source : String]
  [manifest-dir : String]) : lint_svec.Vec
  (selfhost-lint-dead-manifest-roots-from
    source
    manifest-dir
    0
    ""
    (lint_svec.new)))

(define (selfhost-lint-package-dead-compile-manifest-roots
  [source-set : package_source_core.PackageSourceSet]) : lint_svec.Vec
  (let
    [manifest-dir : String source-set.manifest-dir]
    [path : String
      (compiler_load.compiler-load-join-root-path
        manifest-dir
        "src/compile_manifest.txt")]
    (if (io.file-exists? path)
      (selfhost-lint-dead-manifest-roots
        (byte_buf.to-string (io.read-file path))
        manifest-dir)
      (lint_svec.new))))

(define (selfhost-lint-package-dead-repository-test-roots
  [source-set : package_source_core.PackageSourceSet]) : lint_svec.Vec
  (match (package_source_core.package-source-scan-optional-dir
    "lint"
    source-set.manifest-dir
    "src/tests"
    (lint_svec.new))
    [(package_source_core.ResultPackageSourceList.Ok sources) sources]
    [(package_source_core.ResultPackageSourceList.Err _)
      (selfhost-lint-package-empty-source-list)]))

(define (selfhost-lint-package-dead-import-paths-from-decls
  [decls : ast.AstDeclList]
  [importer-path : String]
  [import-root : String]
  [source-set : package_source_core.PackageSourceSet]
  [root-sources : lint_svec.Vec]
  [stdlib-roots : lint_svec.Vec]
  [pools : ast.AstNodePoolContext]
  [package-imports : bool]
  [items : lint_svec.Vec]) : ResultSelfhostLintDeadImportList
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) (ResultSelfhostLintDeadImportList.Ok items)]
    [(ast.AstDeclListStep.Cons decl rest)
      (match decl
        [(ast.AstDecl.Import
            decl-meta
            (ast.AstImportSpec.Spec kind import-path expected-module alias _))
          (if (compiler_load.compiler-load-macro-import-kind? kind)
            (selfhost-lint-package-dead-import-paths-from-decls
              rest
              importer-path
              import-root
              source-set
              root-sources
              stdlib-roots
              pools
              package-imports
              items)
            (let
              [manifest : compiler_load.CompilerPkgManifest source-set.manifest]
              [manifest-dir : String source-set.manifest-dir]
              (match (if package-imports
                (compiler_load.compiler-load-resolve-package-import-spec
                  importer-path
                  kind
                  import-path
                  expected-module
                  stdlib-roots
                  manifest-dir
                  manifest.deps)
                (compiler_load.compiler-load-resolve-import-spec-with-roots
                  importer-path
                  import-root
                  kind
                  import-path
                  expected-module
                  stdlib-roots))
                [(compiler_load.ResultPkgResolve.Err message)
                  (ResultSelfhostLintDeadImportList.Err
                    (box
                      (cdiag.compiler-diagnostic-at-start importer-path message)))]
                [(compiler_load.ResultPkgResolve.Ok resolved)
                  (let
                    [resolved-id : i64
                      (compiler_load.compiler-load-source-path-id resolved)]
                    [package-externs : bool
                      (and
                        package-imports
                        (compiler_load.compiler-load-package-import-externs?
                          kind
                          import-path
                          expected-module
                          manifest.deps))]
                    [preload-candidate : bool
                      (and
                        (not package-externs)
                        (compiler_load.compiler-load-lazy-import-preload-candidate?
                          importer-path
                          kind
                          alias))]
                    [preload-demand : compiler_load.CompilerLoadLazyAliasDemand
                      (compiler_load.compiler-load-lazy-import-preload-demand
                        preload-candidate
                        alias
                        rest
                        pools)]
                    [preload-summary-needed : bool
                      (and
                        preload-candidate
                        (not
                          (or preload-demand.qualified preload-demand.unknown)))]
                    [_preload-summary : unit
                      (if preload-summary-needed
                        (compiler_load.compiler-load-lazy-import-preload-summary-with-pools
                          resolved
                          resolved-id
                          stdlib-roots
                          expected-module
                          manifest-dir
                          (selfhost-lint-package-dead-cfgs)
                          pools)
                        unit)]
                    [preload-skip : bool
                      (and
                        preload-summary-needed
                        (compiler_load.compiler-load-lazy-import-skip?
                          importer-path
                          kind
                          resolved
                          resolved-id
                          expected-module
                          alias
                          rest
                          pools
                          preload-demand
                          stdlib-roots))]
                    [next : lint_svec.Vec
                      (if (or
                        preload-skip
                        (not
                          (selfhost-lint-package-dead-graph-source-path?
                            resolved
                            source-set.sources
                            root-sources
                            stdlib-roots)))
                        items
                        (selfhost-lint-dead-root-add
                          items
                          (compiler_load.compiler-load-normalize-path resolved)))]
                    (selfhost-lint-package-dead-import-paths-from-decls
                      rest
                      importer-path
                      import-root
                      source-set
                      root-sources
                      stdlib-roots
                      pools
                      package-imports
                      next))])))]
        [(ast.AstDecl.ModuleBody _ body-box)
          (match (selfhost-lint-package-dead-import-paths-from-decls
            (__tl-box-place body-box)
            importer-path
            import-root
            source-set
            root-sources
            stdlib-roots
            pools
            package-imports
            items)
            [(ResultSelfhostLintDeadImportList.Err diag)
              (ResultSelfhostLintDeadImportList.Err diag)]
            [(ResultSelfhostLintDeadImportList.Ok nested)
              (selfhost-lint-package-dead-import-paths-from-decls
                rest
                importer-path
                import-root
                source-set
                root-sources
                stdlib-roots
                pools
                package-imports
                nested)])]
        [_
          (selfhost-lint-package-dead-import-paths-from-decls
            rest
            importer-path
            import-root
            source-set
            root-sources
            stdlib-roots
            pools
            package-imports
            items)])]))

(define (selfhost-lint-package-dead-file-imports-in-scratch
  [path : String]
  [import-root : String]
  [source-set : package_source_core.PackageSourceSet]
  [root-sources : lint_svec.Vec]
  [stdlib-roots : lint_svec.Vec]
  [package-imports : bool]) : ResultSelfhostLintDeadImportList
  (let
    ;; Discover the closure one file at a time. Loading every root's complete
    ;; graph here retains duplicate ASTs and makes repository lint unbounded.
    [_reset-file-state : unit (selfhost-lint-reset-file-state!)]
    [home : arena.Arena (arena.current)]
    [pool-arena : i64 (arena.tl_arena_make)]
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities-in-arena
        selfhost-lint-expr-pool-initial-capacity
        selfhost-lint-type-pool-initial-capacity
        pool-arena)]
    [_install-pools : unit (ast.ast-node-pool-compat-context-use! pools)]
    [scratch : arena.Arena (arena.make)]
    [scratch-result : ResultSelfhostLintDeadImportList
      (begin
        (unsafe
          (arena.set! scratch))
        (match (parser.parse-ast-source-diagnostic-with-cfg
          path
          (byte_buf.to-string (io.read-file path))
          (selfhost-lint-package-dead-cfgs))
          [(parser.ResultAstProgramDiagnostic.Err diag)
            (ResultSelfhostLintDeadImportList.Err diag)]
          [(parser.ResultAstProgramDiagnostic.Ok program)
            (match program
              [(ast.AstProgram.Program decls-box)
                (selfhost-lint-package-dead-import-paths-from-decls
                  (__tl-box-place decls-box)
                  path
                  import-root
                  source-set
                  root-sources
                  stdlib-roots
                  pools
                  package-imports
                  (lint_svec.new))])]))]
    [_restore-home : unit
      (unsafe
        (arena.set! home))]
    [result : ResultSelfhostLintDeadImportList
      (match scratch-result
        [(ResultSelfhostLintDeadImportList.Ok imports)
          (ResultSelfhostLintDeadImportList.Ok
            (selfhost-lint-dead-clone-string-vec imports))]
        [(ResultSelfhostLintDeadImportList.Err diag)
          (ResultSelfhostLintDeadImportList.Err (clone diag))])]
    (begin
      (selfhost-lint-reset-file-state!)
      (ast.ast-node-pool-context-reset-to! pools 0 0)
      (ast.ast-node-pool-compat-context-clear!)
      (ast.ast-node-pool-context-destroy-storage! pools)
      (unsafe
        (begin
          (arena.set! home)
          (arena.destroy scratch)
          (arena.tl_arena_destroy (ast.ast-node-pool-context-base-arena pools))))
      result)))

(define (selfhost-lint-package-dead-path-closure-from
  [queue : lint_svec.Vec (:consume)]
  [index : i64]
  [import-root : String]
  [source-set : package_source_core.PackageSourceSet]
  [root-sources : lint_svec.Vec]
  [stdlib-roots : lint_svec.Vec]
  [package-imports : bool]) : ResultSelfhostLintDeadSourceList
  (if (>= index (lint_svec.len (& queue)))
    (ResultSelfhostLintDeadSourceList.Ok queue)
    (match (selfhost-lint-package-dead-file-imports-in-scratch
      (lint_svec.get (& queue) index "")
      import-root
      source-set
      root-sources
      stdlib-roots
      package-imports)
      [(ResultSelfhostLintDeadImportList.Err diag)
        (ResultSelfhostLintDeadSourceList.Err diag)]
      [(ResultSelfhostLintDeadImportList.Ok imports)
        (let
          [next : lint_svec.Vec queue]
          [_append : unit
            (begin
              (let
                [import-index : i64 0]
                (while (< import-index (lint_svec.len (& imports)))
                  (begin
                    (selfhost-lint-dead-root-add!
                      (&mut next)
                      (lint_svec.get (& imports) import-index ""))
                    (set! import-index (+ import-index 1)))))
              unit)]
          (selfhost-lint-package-dead-path-closure-from
            next
            (+ index 1)
            import-root
            source-set
            root-sources
            stdlib-roots
            package-imports))])))

(define (selfhost-lint-package-dead-merge-paths-from
  [items : lint_svec.Vec]
  [paths : lint_svec.Vec]
  [index : i64]) : lint_svec.Vec
  (if (>= index (lint_svec.len (& paths)))
    items
    (selfhost-lint-package-dead-merge-paths-from
      (package_source_core.package-source-vec-insert
        items
        (lint_svec.get (& paths) index ""))
      paths
      (+ index 1))))

(define (selfhost-lint-package-dead-closure-sources-mode
  [entry-path : String]
  [source-set : package_source_core.PackageSourceSet]
  [root-sources : lint_svec.Vec]
  [stdlib-roots : lint_svec.Vec]
  [items : lint_svec.Vec]
  [package-imports : bool]) : ResultSelfhostLintDeadSourceList
  (let
    [start : lint_svec.Vec
      (selfhost-lint-package-dead-graph-source-insert
        (lint_svec.new)
        entry-path
        source-set.sources
        root-sources
        stdlib-roots)]
    [import-root : String (compiler_load.compiler-load-dirname entry-path)]
    (match (selfhost-lint-package-dead-path-closure-from
      start
      0
      import-root
      source-set
      root-sources
      stdlib-roots
      package-imports)
      [(ResultSelfhostLintDeadSourceList.Err diag)
        (ResultSelfhostLintDeadSourceList.Err diag)]
      [(ResultSelfhostLintDeadSourceList.Ok paths)
        (ResultSelfhostLintDeadSourceList.Ok
          (selfhost-lint-package-dead-merge-paths-from items paths 0))])))

(define (selfhost-lint-package-dead-closure-sources
  [entry-path : String]
  [source-set : package_source_core.PackageSourceSet]
  [root-sources : lint_svec.Vec]
  [stdlib-roots : lint_svec.Vec]
  [items : lint_svec.Vec]) : ResultSelfhostLintDeadSourceList
  (selfhost-lint-package-dead-closure-sources-mode
    entry-path
    source-set
    root-sources
    stdlib-roots
    items
    true))

(define (selfhost-lint-package-dead-root-file-closure-sources
  [entry-path : String]
  [source-set : package_source_core.PackageSourceSet]
  [root-sources : lint_svec.Vec]
  [stdlib-roots : lint_svec.Vec]
  [items : lint_svec.Vec]) : ResultSelfhostLintDeadSourceList
  (selfhost-lint-package-dead-closure-sources-mode
    entry-path
    source-set
    root-sources
    stdlib-roots
    items
    false))

(define (selfhost-lint-package-dead-root-closure-sources-from
  [root-sources : lint_svec.Vec]
  [source-set : package_source_core.PackageSourceSet]
  [stdlib-roots : lint_svec.Vec]
  [items : lint_svec.Vec]
  [index : i64]) : ResultSelfhostLintDeadSourceList
  (if (>= index (lint_svec.len (& root-sources)))
    (ResultSelfhostLintDeadSourceList.Ok items)
    (match (selfhost-lint-package-dead-root-file-closure-sources
      (lint_svec.get (& root-sources) index "")
      source-set
      root-sources
      stdlib-roots
      items)
      [(ResultSelfhostLintDeadSourceList.Err diag)
        (ResultSelfhostLintDeadSourceList.Err diag)]
      [(ResultSelfhostLintDeadSourceList.Ok next-sources)
        (selfhost-lint-package-dead-root-closure-sources-from
          root-sources
          source-set
          stdlib-roots
          next-sources
          (+ index 1))])))

(define (selfhost-lint-package-dead-root-closure-sources
  [root-sources : lint_svec.Vec]
  [source-set : package_source_core.PackageSourceSet]
  [stdlib-roots : lint_svec.Vec]
  [items : lint_svec.Vec]) : ResultSelfhostLintDeadSourceList
  (selfhost-lint-package-dead-root-closure-sources-from
    root-sources
    source-set
    stdlib-roots
    items
    0))

(define (selfhost-lint-package-dead-sources
  [source-set : package_source_core.PackageSourceSet]
  [stdlib-roots : lint_svec.Vec]) : ResultSelfhostLintDeadSources
  (let
    [manifest : compiler_load.CompilerPkgManifest source-set.manifest]
    [package-roots : lint_svec.Vec
      (selfhost-lint-package-import-roots source-set stdlib-roots)]
    [explicit-roots : lint_svec.Vec
      (selfhost-lint-package-dead-compile-manifest-roots source-set)]
    [kind : compiler_load.CompilerPkgKind manifest.kind]
    (if (selfhost-lint-package-kind-entry? kind)
      (let
        [manifest-dir : String source-set.manifest-dir]
        [entry-path : String
          (selfhost-lint-package-entry-path manifest-dir manifest)]
        [root-sources : lint_svec.Vec
          (selfhost-lint-package-dead-repository-test-roots source-set)]
        (match (selfhost-lint-package-dead-closure-sources
          entry-path
          source-set
          root-sources
          package-roots
          (lint_svec.new))
          [(ResultSelfhostLintDeadSourceList.Err diag)
            (ResultSelfhostLintDeadSources.Err diag)]
          [(ResultSelfhostLintDeadSourceList.Ok entry-sources)
            (match (selfhost-lint-package-dead-root-closure-sources
              root-sources
              source-set
              package-roots
              entry-sources)
              [(ResultSelfhostLintDeadSourceList.Err diag)
                (ResultSelfhostLintDeadSources.Err diag)]
              [(ResultSelfhostLintDeadSourceList.Ok graph-sources)
                (ResultSelfhostLintDeadSources.Ok
                  (SelfhostLintDeadSourceSet
                    graph-sources
                    root-sources
                    source-set.sources
                    explicit-roots))])]))
      (ResultSelfhostLintDeadSources.Ok
        (SelfhostLintDeadSourceSet
          source-set.sources
          (selfhost-lint-package-empty-source-list)
          source-set.sources
          explicit-roots)))))

(define (selfhost-lint-package-dead-code
  [source-set : SelfhostLintDeadSourceSet]
  [stdlib-roots : lint_svec.Vec]
  [kind : compiler_load.CompilerPkgKind]) : SelfhostLintDeadDecls
  (let
    [visible-root : bool (selfhost-lint-package-dead-visible-root? kind)]
    [reportable : bool (selfhost-lint-package-dead-reportable? kind)]
    [scan : SelfhostLintDeadScan
      (selfhost-lint-dead-scan-add-roots
        (selfhost-lint-package-dead-add-kind-roots
          (selfhost-lint-package-dead-scan-files
            source-set.sources
            source-set.reportable-sources
            stdlib-roots
            0
            visible-root
            reportable
            (SelfhostLintDeadScan
              (selfhost-lint-dead-decls-empty)
              (lint_svec.new)))
          kind)
        source-set.explicit-roots)]
    (selfhost-lint-dead-mark-roots-from scan.decls scan.roots 0)))

(define (selfhost-lint-package-dead-finding-active?
  [source : String]
  [decl : SelfhostLintDeadDecl]) : bool
  (if (not decl.reportable)
    false
    (if decl.root
      false
      (not
        (selfhost-lint-suppressed?
          source
          (lint_core.lint-dead-code-finding decl.name decl.span))))))

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
          (string.eq decl.path path)
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
          (string.eq decl.path path)
          (selfhost-lint-package-dead-finding-active? source decl))
          (begin
            (io.print-format
              "{}"
              (selfhost-lint-render-finding-line
                path
                source
                (lint_core.lint-dead-code-finding decl.name decl.span)))
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

(define (selfhost-lint-reset-file-state!) : unit
  (begin
    (set! selfhost-lint-typed-unused-unsafe-error "")
    (lint_core.lint-unused-unsafe-classifier-reset!)
    (tc.tc-prefix-snapshot-cache-clear!)
    (compiler_check_core.compiler-check-reset-pools!)
    (compiler_check_core.compiler-check-reset-interns!)
    (tc.compiler-typecheck-reset-file-state!)))

(define selfhost-lint-expr-pool-initial-capacity : i64
  1)
(define selfhost-lint-type-pool-initial-capacity : i64
  1)

(define (selfhost-lint-run-file-in-scratch
  [input-path : String]
  [stdlib-roots : lint_svec.Vec]
  [enforcing : bool]
  [deprecated-string-concat : bool]
  [redundant-function-name : bool]
  [prefer-dotted-field : bool]
  [name-case : bool]) : i64
  (let
    ;; Keep each input file's parse/typecheck work in a destroyable arena so a
    ;; long lint batch does not retain earlier files until process exit.
    [home : arena.Arena (arena.current)]
    [pool-arena : i64 (arena.tl_arena_make)]
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities-in-arena
        selfhost-lint-expr-pool-initial-capacity
        selfhost-lint-type-pool-initial-capacity
        pool-arena)]
    [_install-pools : unit (ast.ast-node-pool-compat-context-use! pools)]
    [scratch : arena.Arena (arena.make)]
    [status : i64
      (begin
        (unsafe
          (arena.set! scratch))
        (selfhost-lint-file
          input-path
          stdlib-roots
          enforcing
          deprecated-string-concat
          redundant-function-name
          prefer-dotted-field
          name-case))]
    (begin
      ;; Without an explicit batch reset, the unsafe-surface cache was ensured
      ;; into this file's scratch arena; release it so the scratch teardown
      ;; cannot leave the global cache pointing into freed memory. A batch
      ;; installs the cache in its own outer arena, which outlives each file.
      (if (= selfhost-lint-unsafe-surface-cache-arena (arena.tl_arena_current))
        (selfhost-lint-unsafe-surface-cache-release!)
        unit)
      (unsafe
        (arena.set! home))
      ;; Reset compiler-check state while the file scratch arena is still mapped;
      ;; typed lint rules can leave scratch-backed nodes in check/typecheck caches.
      (selfhost-lint-reset-file-state!)
      (ast.ast-node-pool-context-reset-to! pools 0 0)
      (ast.ast-node-pool-compat-context-clear!)
      (ast.ast-node-pool-context-destroy-storage! pools)
      (unsafe
        (begin
          (arena.set! home)
          (arena.destroy scratch)
          (arena.tl_arena_destroy (ast.ast-node-pool-context-base-arena pools))))
      status)))

(define (selfhost-lint-run-file-with-package-dead-in-scratch
  [input-path : String]
  [stdlib-roots : lint_svec.Vec]
  [enforcing : bool]
  [deprecated-string-concat : bool]
  [redundant-function-name : bool]
  [prefer-dotted-field : bool]
  [name-case : bool]
  [dead-decls : SelfhostLintDeadDecls]) : i64
  (let
    [home : arena.Arena (arena.current)]
    [pool-arena : i64 (arena.tl_arena_make)]
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities-in-arena
        selfhost-lint-expr-pool-initial-capacity
        selfhost-lint-type-pool-initial-capacity
        pool-arena)]
    [_install-pools : unit (ast.ast-node-pool-compat-context-use! pools)]
    [scratch : arena.Arena (arena.make)]
    [status : i64
      (begin
        (unsafe
          (arena.set! scratch))
        (selfhost-lint-file-with-package-dead
          input-path
          stdlib-roots
          enforcing
          deprecated-string-concat
          redundant-function-name
          prefer-dotted-field
          name-case
          dead-decls))]
    (begin
      ;; Without an explicit batch reset, the unsafe-surface cache was ensured
      ;; into this file's scratch arena; release it so the scratch teardown
      ;; cannot leave the global cache pointing into freed memory. A batch
      ;; installs the cache in its own outer arena, which outlives each file.
      (if (= selfhost-lint-unsafe-surface-cache-arena (arena.tl_arena_current))
        (selfhost-lint-unsafe-surface-cache-release!)
        unit)
      (unsafe
        (arena.set! home))
      (selfhost-lint-reset-file-state!)
      (ast.ast-node-pool-context-reset-to! pools 0 0)
      (ast.ast-node-pool-compat-context-clear!)
      (ast.ast-node-pool-context-destroy-storage! pools)
      (unsafe
        (begin
          (arena.set! home)
          (arena.destroy scratch)
          (arena.tl_arena_destroy (ast.ast-node-pool-context-base-arena pools))))
      status)))

(define (selfhost-lint-file
  [input-path : String]
  [stdlib-roots : lint_svec.Vec]
  [enforcing : bool]
  [deprecated-string-concat : bool]
  [redundant-function-name : bool]
  [prefer-dotted-field : bool]
  [name-case : bool]) : i64
  (let
    [source : String (byte_buf.to-string (io.read-file input-path))]
    ;; Parse directly INTO the installed compat-context pools rather than the
    ;; plain `parse-ast-source-diagnostic`, whose capture-active/install! dance
    ;; is a no-op under an explicit compat context: when the parse grows
    ;; (reallocates) its captured pool the fresh backing array is dropped, so the
    ;; AST lint walk later reads stale/undersized slots via ast-node-get and
    ;; mis-reports live params/imports as unused on large sources (the
    ;; compiler_backend.tl phi-copy/tail false positives). Threading the live
    ;; context keeps ast-node-get pointed at the grown pool.
    (match (parser.parse-ast-source-diagnostic-with-cfg-and-pools
      input-path
      source
      (selfhost-lint-language-cfgs)
      (ast.ast-node-pool-compat-context-current))
      [(parser.ResultAstProgramDiagnostic.Ok program)
        (let
          [findings : lint_core.LintFindings
            (selfhost-lint-program-and-typed-findings
              input-path
              source
              program
              stdlib-roots
              (selfhost-lint-language-cfgs)
              deprecated-string-concat
              redundant-function-name
              prefer-dotted-field
              name-case)]
          (if (string.eq selfhost-lint-typed-unused-unsafe-error "")
            (begin
              (selfhost-lint-print-findings input-path source findings)
              (io.print-format
                "{}"
                (str_cat.str-cat
                  "lint: "
                  (string.int->string (lint_core.lint-findings-count findings))
                  " finding(s)\n"))
              (selfhost-lint-enforce-exit
                enforcing
                (lint_core.lint-findings-count findings)))
            (begin
              (io.print-error
                (str_cat.str-cat-scoped
                  selfhost-lint-typed-unused-unsafe-error
                  "\n"))
              1)))]
      [(parser.ResultAstProgramDiagnostic.Err diag)
        (begin
          (io.print-error
            (cdiag.compiler-diagnostic-render (__tl-box-place diag)))
          1)])))

(define (selfhost-lint-file-with-package-dead
  [input-path : String]
  [stdlib-roots : lint_svec.Vec]
  [enforcing : bool]
  [deprecated-string-concat : bool]
  [redundant-function-name : bool]
  [prefer-dotted-field : bool]
  [name-case : bool]
  [dead-decls : SelfhostLintDeadDecls]) : i64
  (let
    [source : String (byte_buf.to-string (io.read-file input-path))]
    ;; Parse directly INTO the installed compat-context pools rather than the
    ;; plain `parse-ast-source-diagnostic`, whose capture-active/install! dance
    ;; is a no-op under an explicit compat context: when the parse grows
    ;; (reallocates) its captured pool the fresh backing array is dropped, so the
    ;; AST lint walk later reads stale/undersized slots via ast-node-get and
    ;; mis-reports live params/imports as unused on large sources (the
    ;; compiler_backend.tl phi-copy/tail false positives). Threading the live
    ;; context keeps ast-node-get pointed at the grown pool.
    (match (parser.parse-ast-source-diagnostic-with-cfg-and-pools
      input-path
      source
      (selfhost-lint-language-cfgs)
      (ast.ast-node-pool-compat-context-current))
      [(parser.ResultAstProgramDiagnostic.Ok program)
        (let
          [findings : lint_core.LintFindings
            (selfhost-lint-program-and-typed-findings
              input-path
              source
              program
              stdlib-roots
              (selfhost-lint-language-cfgs)
              deprecated-string-concat
              redundant-function-name
              prefer-dotted-field
              name-case)]
          (if (string.eq selfhost-lint-typed-unused-unsafe-error "")
            (let
              [ordinary-count : i64
                (selfhost-lint-print-findings input-path source findings)]
              [dead-count : i64
                (selfhost-lint-package-dead-print-for-source
                  input-path
                  source
                  dead-decls)]
              [total-count : i64 (+ ordinary-count dead-count)]
              (begin
                (io.print-format
                  "{}"
                  (str_cat.str-cat
                    "lint: "
                    (string.int->string total-count)
                    " finding(s)\n"))
                (selfhost-lint-enforce-exit enforcing total-count)))
            (begin
              (io.print-error
                (str_cat.str-cat-scoped
                  selfhost-lint-typed-unused-unsafe-error
                  "\n"))
              1)))]
      [(parser.ResultAstProgramDiagnostic.Err diag)
        (begin
          (io.print-error
            (cdiag.compiler-diagnostic-render (__tl-box-place diag)))
          1)])))

(define (selfhost-lint-files-from
  [input-paths : lint_svec.Vec]
  [index : i64]
  [stdlib-roots : lint_svec.Vec]
  [enforcing : bool]
  [deprecated-string-concat : bool]
  [redundant-function-name : bool]
  [prefer-dotted-field : bool]
  [name-case : bool]
  [print-headers : bool]
  [status : i64]) : i64
  (if (>= index (lint_svec.len (& input-paths)))
    status
    (let
      [input-path : String (lint_svec.get (& input-paths) index "")]
      [file-status : i64
        (begin
          (if print-headers
            (io.print-format "{}" (str_cat.str-cat "--- " input-path "\n"))
            unit)
          (selfhost-lint-run-file-in-scratch
            input-path
            stdlib-roots
            enforcing
            deprecated-string-concat
            redundant-function-name
            prefer-dotted-field
            name-case))]
      (selfhost-lint-files-from
        input-paths
        (+ index 1)
        stdlib-roots
        enforcing
        deprecated-string-concat
        redundant-function-name
        prefer-dotted-field
        name-case
        print-headers
        (if (= status 0)
          file-status
          status)))))

(define (selfhost-lint-files
  [input-paths : lint_svec.Vec]
  [stdlib-roots : lint_svec.Vec]
  [enforcing : bool]
  [deprecated-string-concat : bool]
  [redundant-function-name : bool]
  [prefer-dotted-field : bool]
  [name-case : bool]
  [print-headers : bool]
  [status : i64]) : i64
  (begin
    (selfhost-lint-unsafe-surface-cache-reset!)
    (selfhost-lint-files-from
      input-paths
      0
      stdlib-roots
      enforcing
      deprecated-string-concat
      redundant-function-name
      prefer-dotted-field
      name-case
      print-headers
      status)))

(define (selfhost-lint-package-files-from
  [input-paths : lint_svec.Vec]
  [index : i64]
  [stdlib-roots : lint_svec.Vec]
  [enforcing : bool]
  [deprecated-string-concat : bool]
  [redundant-function-name : bool]
  [prefer-dotted-field : bool]
  [name-case : bool]
  [dead-decls : SelfhostLintDeadDecls]
  [print-headers : bool]
  [status : i64]) : i64
  (if (>= index (lint_svec.len (& input-paths)))
    status
    (let
      [input-path : String (lint_svec.get (& input-paths) index "")]
      [file-status : i64
        (begin
          (if print-headers
            (io.print-format "{}" (str_cat.str-cat "--- " input-path "\n"))
            unit)
          (selfhost-lint-run-file-with-package-dead-in-scratch
            input-path
            stdlib-roots
            enforcing
            deprecated-string-concat
            redundant-function-name
            prefer-dotted-field
            name-case
            dead-decls))]
      (selfhost-lint-package-files-from
        input-paths
        (+ index 1)
        stdlib-roots
        enforcing
        deprecated-string-concat
        redundant-function-name
        prefer-dotted-field
        name-case
        dead-decls
        print-headers
        (if (= status 0)
          file-status
          status)))))

(define (selfhost-lint-package-files
  [input-paths : lint_svec.Vec]
  [stdlib-roots : lint_svec.Vec]
  [enforcing : bool]
  [deprecated-string-concat : bool]
  [redundant-function-name : bool]
  [prefer-dotted-field : bool]
  [name-case : bool]
  [dead-decls : SelfhostLintDeadDecls]
  [print-headers : bool]
  [status : i64]) : i64
  (begin
    (selfhost-lint-unsafe-surface-cache-reset!)
    (selfhost-lint-package-files-from
      input-paths
      0
      stdlib-roots
      enforcing
      deprecated-string-concat
      redundant-function-name
      prefer-dotted-field
      name-case
      dead-decls
      print-headers
      status)))

(define (selfhost-lint-package
  [manifest-path : String]
  [has-manifest : bool]
  [stdlib-roots : lint_svec.Vec]
  [enforcing : bool]
  [deprecated-string-concat : bool]
  [redundant-function-name : bool]
  [prefer-dotted-field : bool]
  [name-case : bool]) : i64
  (match (package_source_core.package-source-discover-for
    "lint"
    manifest-path
    has-manifest)
    [(package_source_core.ResultPackageSourceSet.Err message)
      (begin
        (io.print-error (str_cat.str-cat message "\n"))
        1)]
    [(package_source_core.ResultPackageSourceSet.Ok source-set)
      (let
        [sources : lint_svec.Vec source-set.sources]
        [manifest : compiler_load.CompilerPkgManifest source-set.manifest]
        [dead-sources-result : ResultSelfhostLintDeadSources
          (selfhost-lint-package-dead-sources source-set stdlib-roots)]
        [package-roots : lint_svec.Vec
          (selfhost-lint-package-import-roots source-set stdlib-roots)]
        (match dead-sources-result
          [(ResultSelfhostLintDeadSources.Ok dead-sources)
            (let
              [dead-decls : SelfhostLintDeadDecls
                (selfhost-lint-package-dead-code
                  dead-sources
                  package-roots
                  manifest.kind)]
              (selfhost-lint-package-files
                sources
                package-roots
                enforcing
                deprecated-string-concat
                redundant-function-name
                prefer-dotted-field
                name-case
                dead-decls
                (> (lint_svec.len (& sources)) 1)
                0))]
          [(ResultSelfhostLintDeadSources.Err diag)
            (begin
              (io.print-error
                (cdiag.compiler-diagnostic-render (__tl-box-place diag)))
              1)]))]))

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
            redundant-function-name
            prefer-dotted-field
            name-case)
          (selfhost-lint-files
            input-paths
            stdlib-roots
            enforcing
            deprecated-string-concat
            redundant-function-name
            prefer-dotted-field
            name-case
            (> (lint_svec.len (& input-paths)) 1)
            0)]
        [(SelfhostLintConfig.Package
            manifest-path
            has-manifest
            stdlib-roots
            enforcing
            deprecated-string-concat
            redundant-function-name
            prefer-dotted-field
            name-case)
          (selfhost-lint-package
            manifest-path
            has-manifest
            stdlib-roots
            enforcing
            deprecated-string-concat
            redundant-function-name
            prefer-dotted-field
            name-case)])]
    [(ResultSelfhostLintConfig.Err message)
      (begin
        (io.print-error (str_cat.str-cat message "\n"))
        2)]))