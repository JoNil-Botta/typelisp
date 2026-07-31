;; lint_driver_core.tl - Driver logic for the selfhost `typelisp lint` tool:
;; load a TypeLisp source, run the lint_core rules over its program, and
;; render each finding through the shared source diagnostic renderer. Kept
;; main-less so both the CLI driver (`lint.tl`) and the runnable smoke
;; (`lint_driver_smoke.tl`) can import it. Warn-only by default; callers can pass
;; `--check` after the input path to exit non-zero when findings remain, or
;; `--format flat` for the stable `path:line:col: message` machine format. The
;; deprecated string.concat rule and staged migration rules are opt-in.
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.arena)
(import stdlib.vector)
(import (vector.vector String) as lint_svec)
(import "compiler_check_core.tl")
(import compiler_target_cfg_core as target_cfg)
(import "compiler_load.tl")
(import compiler_intern as ci)
(import "lint_core.tl")
(import "package_source_core.tl")
(import stdlib.string)
(import sym_i64_env)

(define (selfhost-lint-write-text [path : String] [contents : String]) : unit
  (io.write-file path (byte_buf.str-as-bytes (& contents))))

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
(define selfhost-lint-legacy-path-import : bool
  false)
(define selfhost-lint-flat-output : bool
  false)

(define (selfhost-lint-language-config-reset!) : unit
  (begin
    (set!
      selfhost-lint-language-target
      (target_cfg.compiler-target-cfg-default))
    (set! selfhost-lint-language-cfg-names (lint_svec.new))
    (set! selfhost-lint-cli-has-target false)
    (set! selfhost-lint-legacy-path-import false)
    (set! selfhost-lint-flat-output false)))

(define (selfhost-lint-language-cfgs) : sym_i64_env.SymI64Env
  (target_cfg.compiler-target-cfgs-with-names
    selfhost-lint-language-target
    selfhost-lint-language-cfg-names))

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
  [input-paths : lint_svec.Vec]
  [manifest-path : String]
  [has-manifest : bool]
  [stdlib-roots : lint_svec.Vec]
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
        [(string.eq current "--legacy-path-import")
          (begin
            (set! selfhost-lint-legacy-path-import true)
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
              name-case))]
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
                    (string.append
                      "selfhost-lint: unsupported --format "
                      (string.append format " (expected rich or flat)")))])))]
        [(string.eq current "--cfg")
          (if (>= (+ idx 1) count)
            (ResultSelfhostLintConfig.Err
              "selfhost-lint: --cfg requires a value")
            (begin
              (lint_svec.push
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
                    (string.append "selfhost-lint: " message))])))]
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
                  (lint_svec.push (&mut next-roots) (io.arg (+ idx 1)))
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
            (string.append "selfhost-lint: unknown flag " current))]
        [else
          (selfhost-lint-parse-options
            (+ idx 1)
            count
            (let
              [next-paths : lint_svec.Vec input-paths]
              (begin
                (lint_svec.push (&mut next-paths) current)
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
  [finding : LintFinding]) : CompilerDiagnostic
  (let
    [fspan : AstSourceSpan (struct-get finding span)]
    [rule-id : String (struct-get finding rule-id)]
    [suggestion : String (lint-rule-suggestion (string.copy (& rule-id)))]
    (compiler-diagnostic-with-help
      (compiler-diagnostic-with-code
        (compiler-diagnostic-with-level
          (compiler-diagnostic-from-ast-span
            path
            fspan
            (struct-get finding message))
          CompilerDiagnosticWarning)
        rule-id)
      suggestion)))

;; Rich diagnostics are the human-facing default. `--format flat` preserves the
;; historical line-oriented form for scripts and editors that parse it.
(define (selfhost-lint-render-finding
  [path : String]
  [source : String]
  [finding : LintFinding]) : String
  (let
    [diag : CompilerDiagnostic (selfhost-lint-finding-diagnostic path finding)]
    (if selfhost-lint-flat-output
      (compiler-diagnostic-render diag)
      (compiler-diagnostic-render-source diag source))))

(define (selfhost-lint-render-finding-line
  [path : String]
  [source : String]
  [finding : LintFinding]) : String
  (let
    [rendered : String (selfhost-lint-render-finding path source finding)]
    (if selfhost-lint-flat-output
      (string.append rendered "\n")
      rendered)))

;; Print every finding to stdout; returns the number printed.
;; Findings are stored in discovery order, so render backward to preserve the
;; historical list-accumulator output order.
(define (selfhost-lint-print-findings-from
  [path : String]
  [source : String]
  [items : LintFindings]
  [index : i64]
  [printed : i64]) : i64
  (if (< index 0)
    printed
    (begin
      (io.print-string
        (selfhost-lint-render-finding-line
          path
          source
          (lint-findings-ref items index)))
      (selfhost-lint-print-findings-from
        path
        source
        items
        (- index 1)
        (+ printed 1)))))

(define (selfhost-lint-print-findings
  [path : String]
  [source : String]
  [items : LintFindings]) : i64
  (selfhost-lint-print-findings-from
    path
    source
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
    (selfhost-lint-line-start-index source (ast-source-span-start-line span))
    (- (ast-source-span-start-col span) 1)))

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
    [line : i64 (ast-source-span-start-line span)]
    [rule-id : String (struct-get finding rule-id)]
    (if (<= line 1)
      false
      (selfhost-lint-line-allows? source (- line 1) rule-id))))

(define (selfhost-lint-form-origin?
  [source : String]
  [span : AstSourceSpan]
  [form-name : String]) : bool
  (let
    [line : i64 (ast-source-span-start-line span)]
    [col : i64 (ast-source-span-start-col span)]
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

(define (selfhost-lint-program-findings-with-all-options
  [source : String]
  [program : AstProgram]
  [deprecated-string-concat : bool]
  [redundant-function-name : bool]
  [prefer-dotted-field : bool]
  [name-case : bool]) : LintFindings
  (match program
    [(AstProgram.Program decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        [base : LintFindings
          (lint-program-with-source-options
            source
            (ast-program decls)
            (lint-default-ladder-threshold)
            deprecated-string-concat
            name-case)]
        [with-redundant : LintFindings
          (if redundant-function-name
            (lint-redundant-function-names-in-program
              source
              (ast-program decls)
              base)
            base)]
        [with-prefer : LintFindings
          (if prefer-dotted-field
            (lint-prefer-dotted-fields-in-program
              (ast-program decls)
              with-redundant)
            with-redundant)]
        [with-legacy-path-imports : LintFindings
          (if selfhost-lint-legacy-path-import
            (lint-legacy-path-imports-in-program
              (ast-program decls)
              with-prefer)
            with-prefer)]
        (selfhost-lint-filter-derived-origins source with-legacy-path-imports))]))

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

(defstruct SelfhostLintUnsafeSurfaceName
  (name String)
  (requires-unsafe bool))

;; Append-only and read front to back: contiguous slots with a doubling push.
(defstruct SelfhostLintUnsafeSurfaceNames
  (slots (__tl_dyn-array SelfhostLintUnsafeSurfaceName))
  (len i64))

(define (selfhost-lint-unsafe-surface-names-empty) : SelfhostLintUnsafeSurfaceNames
  (SelfhostLintUnsafeSurfaceNames
    (make-array SelfhostLintUnsafeSurfaceName 8)
    0))

(define (selfhost-lint-unsafe-surface-names-add
  [fact : SelfhostLintUnsafeSurfaceName]
  [names : SelfhostLintUnsafeSurfaceNames]) : SelfhostLintUnsafeSurfaceNames
  (let
    [cells : (__tl_dyn-array SelfhostLintUnsafeSurfaceName)
      (struct-get names slots)]
    [n : i64 (struct-get names len)]
    [index : i64 0]
    (begin
      (if (< n (array-length cells))
        unit
        (let
          [bigger : (__tl_dyn-array SelfhostLintUnsafeSurfaceName)
            (make-array SelfhostLintUnsafeSurfaceName (* n 2))]
          (begin
            (while (< index n)
              (begin
                (array-set! bigger index (array-ref cells index))
                (set! index (+ index 1))))
            (set! cells bigger))))
      (array-set! cells n fact)
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
    (make-array SelfhostLintUnsafeSurfaceCacheEntry 8)
    0))

(define selfhost-lint-unsafe-surface-cache : SelfhostLintUnsafeSurfaceCache
  (selfhost-lint-unsafe-surface-cache-empty))

(define (selfhost-lint-unsafe-surface-cache-entry [index : i64]) : SelfhostLintUnsafeSurfaceCacheEntry
  (array-ref (struct-get selfhost-lint-unsafe-surface-cache slots) index))

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
    [n : i64 (struct-get selfhost-lint-unsafe-surface-cache len)]
    [index : i64 0]
    (begin
      (while (and
        (< index n)
        (not
          (string.eq
            (struct-get (selfhost-lint-unsafe-surface-cache-entry index) path)
            path)))
        (set! index (+ index 1)))
      (if (< index n)
        (let
          [entry : SelfhostLintUnsafeSurfaceCacheEntry
            (selfhost-lint-unsafe-surface-cache-entry index)]
          (SelfhostLintUnsafeSurfaceLookup.Hit
            (struct-get entry valid)
            (struct-get entry names)))
        (SelfhostLintUnsafeSurfaceLookup.Miss)))))

(define (selfhost-lint-unsafe-surface-value-kind?
  [kind : CompilerLoadSurfaceDeclKind]) : bool
  (match kind
    [(CompilerLoadSurfaceFunction) true]
    [(CompilerLoadSurfaceExtern) true]
    [(CompilerLoadSurfaceStruct) true]
    [(CompilerLoadSurfaceEnum) true]
    [(CompilerLoadSurfaceDispatch) true]
    [_ false]))

(define (selfhost-lint-unsafe-surface-copy-decls
  [decls : CompilerLoadSurfaceDeclList]
  [root-module : i64]
  [out : SelfhostLintUnsafeSurfaceNames]) : SelfhostLintUnsafeSurfaceNames
  (let
    [index : i64 0]
    [result : SelfhostLintUnsafeSurfaceNames out]
    (begin
      (while (< index (compiler-load-surface-decl-list-count decls))
        (let
          [decl : CompilerLoadSurfaceDecl
            (compiler-load-surface-decl-list-at decls index)]
          (begin
            (if (and
              (= (struct-get decl module) root-module)
              (not (struct-get decl has-generated-meta))
              (selfhost-lint-unsafe-surface-value-kind? (struct-get decl kind)))
              (set!
                result
                (selfhost-lint-unsafe-surface-names-add
                  (SelfhostLintUnsafeSurfaceName
                    (string.copy (intern-str (struct-get decl name)))
                    (struct-get decl was-unsafe))
                  result))
              unit)
            (set! index (+ index 1)))))
      result)))

(define (selfhost-lint-unsafe-surface-cache-push!
  [entry : SelfhostLintUnsafeSurfaceCacheEntry]) : unit
  (let
    [n : i64 (struct-get selfhost-lint-unsafe-surface-cache len)]
    [index : i64 0]
    (begin
      (if (<
        n
        (array-length (struct-get selfhost-lint-unsafe-surface-cache slots)))
        unit
        (let
          [bigger : (__tl_dyn-array SelfhostLintUnsafeSurfaceCacheEntry)
            (make-array SelfhostLintUnsafeSurfaceCacheEntry (* n 2))]
          (begin
            (while (< index n)
              (begin
                (array-set!
                  bigger
                  index
                  (selfhost-lint-unsafe-surface-cache-entry index))
                (set! index (+ index 1))))
            (set! (struct-get selfhost-lint-unsafe-surface-cache slots) bigger))))
      (array-set! (struct-get selfhost-lint-unsafe-surface-cache slots) n entry)
      (set! (struct-get selfhost-lint-unsafe-surface-cache len) (+ n 1)))))

(define (selfhost-lint-unsafe-surface-cache-store-summary!
  [path : String]
  [summary : CompilerLoadSurfaceSummary]) : unit
  (let
    [home : i64 (arena.tl_arena_current)]
    (begin
      (unsafe
        (arena.tl_arena_set selfhost-lint-unsafe-surface-cache-arena))
      (selfhost-lint-unsafe-surface-cache-push!
        (SelfhostLintUnsafeSurfaceCacheEntry
          (string.copy path)
          true
          (selfhost-lint-unsafe-surface-copy-decls
            (struct-get summary decls)
            (struct-get summary declaration-module-id)
            (selfhost-lint-unsafe-surface-names-empty))))
      (unsafe
        (arena.tl_arena_set home)))))

(define (selfhost-lint-unsafe-surface-cache-store-invalid! [path : String]) : unit
  (let
    [home : i64 (arena.tl_arena_current)]
    (begin
      (unsafe
        (arena.tl_arena_set selfhost-lint-unsafe-surface-cache-arena))
      (selfhost-lint-unsafe-surface-cache-push!
        (SelfhostLintUnsafeSurfaceCacheEntry
          (string.copy path)
          false
          (selfhost-lint-unsafe-surface-names-empty)))
      (unsafe
        (arena.tl_arena_set home)))))

(define (selfhost-lint-unsafe-surface-cache-load!
  [path : String]
  [cfgs : sym_i64_env.SymI64Env]) : SelfhostLintUnsafeSurfaceLookup
  (let
    [normalized : String (compiler-load-normalize-path path)]
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
            (ast-node-pool-compat-context-active?)
            (io.file-exists? normalized))
            (match (parse-ast-source-diagnostic-with-cfg-and-pools
              normalized
              (byte_buf.to-string (io.read-file normalized))
              cfgs
              (ast-node-pool-compat-context-current))
              [(ResultAstProgramDiagnostic.Ok program)
                (match (compiler-load-surface-summary-build
                  normalized
                  0
                  ""
                  program
                  0
                  true)
                  [(ResultCompilerLoadSurfaceSummary.Ok summary)
                    (selfhost-lint-unsafe-surface-cache-store-summary!
                      normalized
                      summary)]
                  [(ResultCompilerLoadSurfaceSummary.Err _)
                    (selfhost-lint-unsafe-surface-cache-store-invalid!
                      normalized)])]
              [(ResultAstProgramDiagnostic.Err _)
                (selfhost-lint-unsafe-surface-cache-store-invalid! normalized)])
            (selfhost-lint-unsafe-surface-cache-store-invalid! normalized))
          (selfhost-lint-unsafe-surface-cache-lookup normalized))])))

(define (selfhost-lint-unsafe-surface-import-alias
  [import-edge : CompilerLoadSurfaceImport]) : String
  (match (struct-get import-edge alias)
    [(CompilerLoadSurfaceSomeString alias) alias]
    [(CompilerLoadSurfaceNoString)
      (match (struct-get import-edge default-alias)
        [(CompilerLoadSurfaceSomeString alias) alias]
        [(CompilerLoadSurfaceNoString) ""])]))

(define (selfhost-lint-unsafe-surface-add-names!
  [alias : String]
  [names : SelfhostLintUnsafeSurfaceNames]) : unit
  (let
    [n : i64 (struct-get names len)]
    [index : i64 0]
    (while (< index n)
      (let
        [fact : SelfhostLintUnsafeSurfaceName
          (array-ref (struct-get names slots) index)]
        (begin
          (lint-unused-unsafe-classifier-add-exact-name!
            (string.append alias (string.append "." (struct-get fact name)))
            (struct-get fact requires-unsafe))
          (lint-unused-unsafe-classifier-add-exact-name!
            (string.append alias (string.append "/" (struct-get fact name)))
            (struct-get fact requires-unsafe))
          (set! index (+ index 1)))))))

(define (selfhost-lint-unsafe-surface-add-local-decls!
  [decls : CompilerLoadSurfaceDeclList]
  [root-module : i64]) : unit
  (let
    [index : i64 0]
    (while (< index (compiler-load-surface-decl-list-count decls))
      (let
        [decl : CompilerLoadSurfaceDecl
          (compiler-load-surface-decl-list-at decls index)]
        (begin
          (if (and
            (= (struct-get decl module) root-module)
            (not (struct-get decl has-generated-meta))
            (selfhost-lint-unsafe-surface-value-kind? (struct-get decl kind)))
            (lint-unused-unsafe-classifier-add-exact-name!
              (string.copy (intern-str (struct-get decl name)))
              (struct-get decl was-unsafe))
            unit)
          ;; A top-level declaration can shadow an import alias. Only qualified
          ;; references consult this root blocker, so unqualified local facts
          ;; remain usable.
          (if (not (struct-get decl has-generated-meta))
            (lint-unused-unsafe-classifier-add-unknown-root!
              (string.copy (intern-str (struct-get decl name))))
            unit)
          (set! index (+ index 1)))))))

(define (selfhost-lint-unsafe-surface-resolve-import
  [path : String]
  [stdlib-roots : lint_svec.Vec]
  [import-edge : CompilerLoadSurfaceImport]) : ResultPkgResolve
  (match (struct-get import-edge kind)
    [(CompilerLoadSurfaceImportPath)
      (compiler-load-resolve-import-result-with-roots
        path
        (struct-get import-edge import-path)
        stdlib-roots)]
    [(CompilerLoadSurfaceImportModule)
      (compiler-load-resolve-module-import-with-roots
        path
        ""
        (struct-get import-edge import-path)
        stdlib-roots)]
    [_ (ResultPkgResolve.Err "lint: macro import surface is not static")]))

(define (selfhost-lint-unsafe-surface-prepare-imports!
  [path : String]
  [stdlib-roots : lint_svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [imports : CompilerLoadSurfaceImportList]) : unit
  (let
    [index : i64 0]
    (while (< index (compiler-load-surface-import-list-count imports))
      (let
        [import-edge : CompilerLoadSurfaceImport
          (compiler-load-surface-import-list-at imports index)]
        [alias : String (selfhost-lint-unsafe-surface-import-alias import-edge)]
        (begin
          (if (string.eq alias "")
            unit
            (match (selfhost-lint-unsafe-surface-resolve-import
              path
              stdlib-roots
              import-edge)
              [(ResultPkgResolve.Err _) unit]
              [(ResultPkgResolve.Ok resolved)
                (match (selfhost-lint-unsafe-surface-cache-load! resolved cfgs)
                  [(SelfhostLintUnsafeSurfaceLookup.Miss) unit]
                  [(SelfhostLintUnsafeSurfaceLookup.Hit valid names)
                    (if valid
                      (selfhost-lint-unsafe-surface-add-names! alias names)
                      unit)])]))
          (set! index (+ index 1)))))))

(define (selfhost-lint-unsafe-surface-prepare!
  [path : String]
  [program : AstProgram]
  [stdlib-roots : lint_svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : unit
  (begin
    (selfhost-lint-unsafe-surface-cache-ensure!)
    (lint-unused-unsafe-classifier-reset!)
    (match (compiler-load-surface-summary-build path 0 "" program 0 false)
      [(ResultCompilerLoadSurfaceSummary.Err _) unit]
      [(ResultCompilerLoadSurfaceSummary.Ok summary)
        (begin
          (selfhost-lint-unsafe-surface-add-local-decls!
            (struct-get summary decls)
            (struct-get summary declaration-module-id))
          (selfhost-lint-unsafe-surface-prepare-imports!
            path
            stdlib-roots
            cfgs
            (struct-get summary imports)))])
    (lint-unused-unsafe-classifier-enable!)))

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

(define (selfhost-lint-typed-unused-unsafe-findings
  [path : String]
  [source : String]
  [stdlib-roots : lint_svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : LintFindings
  (begin
    (set! selfhost-lint-typed-unused-unsafe-error "")
    (tc-unused-unsafe-tracking-reset! path)
    ;; File/package lint parses into a destroyable, explicitly installed pool.
    ;; Run the nested check on process pools and reinstall the lint pool before
    ;; its caller resumes the AST walk.
    (match (if (ast-node-pool-compat-context-active?)
      (let
        [lint-pools : AstNodePoolContext (ast-node-pool-compat-context-current)]
        (begin
          (ast-node-pool-compat-context-clear!)
          (let
            [checked : ResultCompilerCheck
              (compiler-check-source-with-roots-and-cfg
                path
                source
                stdlib-roots
                cfgs)]
            (begin
              (ast-node-pool-compat-context-use! lint-pools)
              checked))))
      (compiler-check-source-with-roots-and-cfg path source stdlib-roots cfgs))
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
      [(ResultCompilerCheck.Err diag)
        (begin
          (set!
            selfhost-lint-typed-unused-unsafe-error
            (compiler-diagnostic-render
              (compiler-diagnostic-list-first (box-get diag))))
          (tc-unused-unsafe-tracking-disable!)
          (lint-findings-empty))])))

(define (selfhost-lint-source-unused-unsafe-findings
  [path : String]
  [source : String]
  [program : AstProgram]
  [stdlib-roots : lint_svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : LintFindings
  (if (lint-program-has-unused-unsafe-candidate? program)
    (begin
      (set!
        selfhost-lint-unused-unsafe-fallback-file-count
        (+ selfhost-lint-unused-unsafe-fallback-file-count 1))
      (selfhost-lint-typed-unused-unsafe-findings path source stdlib-roots cfgs))
    (lint-findings-empty)))

(define (selfhost-lint-findings-without-unused-unsafe-from
  [items : LintFindings]
  [index : i64]
  [out : LintFindings]) : LintFindings
  (if (>= index (lint-findings-count items))
    out
    (let
      [finding : LintFinding (lint-findings-ref items index)]
      [next : LintFindings
        (if (string.eq
          (struct-get finding rule-id)
          (lint-rule-unused-unsafe-id))
          out
          (lint-findings-add finding out))]
      (selfhost-lint-findings-without-unused-unsafe-from items (+ index 1) next))))

(define (selfhost-lint-findings-without-unused-unsafe [items : LintFindings]) : LintFindings
  (selfhost-lint-findings-without-unused-unsafe-from
    items
    0
    (lint-findings-empty)))

(define (selfhost-lint-program-and-typed-findings
  [path : String]
  [source : String]
  [program : AstProgram]
  [stdlib-roots : lint_svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [deprecated-string-concat : bool]
  [redundant-function-name : bool]
  [prefer-dotted-field : bool]
  [name-case : bool]) : LintFindings
  (begin
    (set! selfhost-lint-typed-unused-unsafe-error "")
    (selfhost-lint-unsafe-surface-prepare! path program stdlib-roots cfgs)
    (let
      [ordinary : LintFindings
        (selfhost-lint-program-findings-with-all-options
          source
          program
          deprecated-string-concat
          redundant-function-name
          prefer-dotted-field
          name-case)]
      [unknown-count : i64 (lint-unused-unsafe-classifier-unknown-count)]
      [required-count : i64 (lint-unused-unsafe-classifier-required-count)]
      [unused-count : i64 (lint-unused-unsafe-classifier-unused-count)]
      [typed : LintFindings
        (if (> unknown-count 0)
          (selfhost-lint-typed-unused-unsafe-findings
            path
            source
            stdlib-roots
            cfgs)
          (lint-findings-empty))]
      [base : LintFindings
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
        (lint-unused-unsafe-classifier-disable!)
        (selfhost-lint-findings-append base typed)))))

(define (selfhost-lint-source-with-roots-and-all-options-with-cfg
  [path : String]
  [source : String]
  [stdlib-roots : lint_svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [deprecated-string-concat : bool]
  [redundant-function-name : bool]
  [prefer-dotted-field : bool]
  [name-case : bool]) : LintFindings
  (begin
    ;; LSP/source-mode callers commonly run in a destroyable request arena.
    ;; Never let a prior request's compact cache survive into the next one;
    ;; explicit file/package batches reset once in their outer batch arena.
    (set! selfhost-lint-typed-unused-unsafe-error "")
    (selfhost-lint-unsafe-surface-cache-reset!)
    (lint-unused-unsafe-classifier-reset!)
    (let
      [findings : LintFindings
        (match (parse-ast-source-diagnostic-with-cfg path source cfgs)
          [(ResultAstProgramDiagnostic.Ok program)
            (let
              [ordinary : LintFindings
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
          [(ResultAstProgramDiagnostic.Err _) (lint-findings-empty)])]
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
  [name-case : bool]) : LintFindings
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
  [prefer-dotted-field : bool]) : LintFindings
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
  [deprecated-string-concat : bool]) : LintFindings
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
  [stdlib-roots : lint_svec.Vec]) : LintFindings
  (selfhost-lint-source-with-roots-and-options path source stdlib-roots false))

(define (selfhost-lint-source-with-roots-and-cfg
  [path : String]
  [source : String]
  [stdlib-roots : lint_svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : LintFindings
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
  (span AstSourceSpan)
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
  (Err (Box CompilerDiagnostic)))

(defenum ResultSelfhostLintDeadImportList
  (Ok lint_svec.Vec)
  (Err (Box CompilerDiagnostic)))

(defenum ResultSelfhostLintDeadSources
  (Ok SelfhostLintDeadSourceSet)
  (Err (Box CompilerDiagnostic)))

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
  (compiler-cfg-enable
    (compiler-cfg-enable
      (compiler-cfg-union
        (compiler-cfg-enable
          (compiler-cfg-enable
            (compiler-cfg-enable
              (compiler-cfg-enable (selfhost-lint-language-cfgs) "test")
              "scratch-vreg")
            "embedded-stdlib-tlci")
          "compiler-build-identity")
        "compile-profile")
      "regalloc-census")
    "scavenge-census"))

(define (selfhost-lint-package-dead-cfgs) : sym_i64_env.SymI64Env
  (compiler-cfg-union
    (compiler-cfg-enable
      (selfhost-lint-package-dead-cfgs-base)
      "scavenge-self-check")
    "compile-profile-summary"))

(define (selfhost-lint-dead-decls-slots [items : SelfhostLintDeadDecls]) : (__tl_dyn-array
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
  [dst : (__tl_dyn-array SelfhostLintDeadDecl)]
  [src : (__tl_dyn-array SelfhostLintDeadDecl)]
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
    [bigger : (__tl_dyn-array SelfhostLintDeadDecl)
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
      [slots : (__tl_dyn-array SelfhostLintDeadDecl)
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

(define (selfhost-lint-dead-root-add [roots : lint_svec.Vec] [name : String]) : lint_svec.Vec
  (if (lint_svec.contains? (& roots) name)
    roots
    (let
      [next-roots : lint_svec.Vec roots]
      (begin
        (lint_svec.push (&mut next-roots) name)
        next-roots))))

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

(define (selfhost-lint-dead-scan-add-roots-from
  [scan : SelfhostLintDeadScan]
  [roots : lint_svec.Vec]
  [index : i64]) : SelfhostLintDeadScan
  (if (>= index (lint_svec.len (& roots)))
    scan
    (selfhost-lint-dead-scan-add-roots-from
      (selfhost-lint-dead-scan-add-root scan (lint_svec.get (& roots) index ""))
      roots
      (+ index 1))))

(define (selfhost-lint-dead-scan-add-roots
  [scan : SelfhostLintDeadScan]
  [roots : lint_svec.Vec]) : SelfhostLintDeadScan
  (selfhost-lint-dead-scan-add-roots-from scan roots 0))

(define (selfhost-lint-dead-module-key [module : String] [name : String]) : String
  (if (= (string.string-length module) 0)
    name
    (string.append module (string.append "/" name))))

(define (selfhost-lint-dead-default-module-from-path [path : String]) : String
  (parse-ast-dotted-import-default-alias
    (compiler-load-canonical-module-id-from-path path)))

(define (selfhost-lint-dead-qualified-ref-prefix) : String
  "\nselfhost-lint-dead-qualified-ref\n")

(define (selfhost-lint-dead-qualified-ref [key : String] [fallback : String]) : String
  (string.append
    (selfhost-lint-dead-qualified-ref-prefix)
    (string.append key (string.append "\n" fallback))))

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
  (string.append
    (selfhost-lint-dead-source-root-prefix)
    (string.append
      (compiler-load-normalize-path path)
      (string.append "\n" name))))

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
  [out : lint_svec.Vec]) : lint_svec.Vec
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

(define (selfhost-lint-dead-ref-add-raw [refs : lint_svec.Vec] [name : String]) : lint_svec.Vec
  (if (lint_svec.contains? (& refs) name)
    refs
    (let
      [next-refs : lint_svec.Vec refs]
      (begin
        (lint_svec.push (&mut next-refs) name)
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

(define (selfhost-lint-dead-ref-add [refs : lint_svec.Vec] [name : String]) : lint_svec.Vec
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
            selfhost-lint-dead-import-aliases
            (ci.intern-source-slice name 0 last-dot)
            -1)]
        [module : String
          (if (< target 0)
            (string.substring name 0 last-dot)
            (intern-str target))]
        (selfhost-lint-dead-ref-add-raw
          refs
          (selfhost-lint-dead-qualified-ref
            (selfhost-lint-dead-module-key module member)
            member)))
      (selfhost-lint-dead-ref-add-raw refs name))))

(define (selfhost-lint-dead-ref-add-id [refs : lint_svec.Vec] [name : i64]) : lint_svec.Vec
  (selfhost-lint-dead-ref-add refs (intern-str name)))

(define (selfhost-lint-dead-maybe-type-refs
  [maybe-ty : AstMaybeType]
  [refs : lint_svec.Vec]) : lint_svec.Vec
  (match maybe-ty
    [(AstMaybeType.No) refs]
    [(AstMaybeType.Some ty) (selfhost-lint-dead-type-refs ty refs)]))

(define (selfhost-lint-dead-type-list-refs
  [types : AstTypeList]
  [refs : lint_svec.Vec]) : lint_svec.Vec
  (selfhost-lint-dead-type-list-refs-at (& types) refs 0))

(define (selfhost-lint-dead-type-list-refs-at
  [types : (& types AstTypeList)]
  [refs : lint_svec.Vec]
  [index : i64]) : lint_svec.Vec
  (if (>= index (ast-type-list-len types))
    refs
    (selfhost-lint-dead-type-list-refs-at
      types
      (selfhost-lint-dead-type-refs
        (ty-node-get (ast-type-list-get types index (ast-type-id-fallback)))
        refs)
      (+ index 1))))

(define (selfhost-lint-dead-type-id-refs [ty : i64] [refs : lint_svec.Vec]) : lint_svec.Vec
  (selfhost-lint-dead-type-refs (ty-node-get ty) refs))

(define (selfhost-lint-dead-type-refs [ty : AstType] [refs : lint_svec.Vec]) : lint_svec.Vec
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
    [(AstType.MutPtr inner) (selfhost-lint-dead-type-id-refs inner refs)]
    [(AstType.Consume inner) (selfhost-lint-dead-type-id-refs inner refs)]))

(define (selfhost-lint-dead-param-list-refs
  [params : AstParamList]
  [refs : lint_svec.Vec]) : lint_svec.Vec
  (selfhost-lint-dead-param-list-refs-at (& params) refs 0))

(define (selfhost-lint-dead-param-list-refs-at
  [params : (& params AstParamList)]
  [refs : lint_svec.Vec]
  [index : i64]) : lint_svec.Vec
  (if (>= index (ast-param-list-len params))
    refs
    (match (ast-param-list-get params index (ast-param-fallback))
      [(AstParam.Param _ ty _ _)
        (selfhost-lint-dead-param-list-refs-at
          params
          (selfhost-lint-dead-type-refs ty refs)
          (+ index 1))])))

(define (selfhost-lint-dead-macro-param-list-refs
  [params : AstMacroParamList]
  [refs : lint_svec.Vec]) : lint_svec.Vec
  (selfhost-lint-dead-macro-param-list-refs-at (& params) refs 0))

(define (selfhost-lint-dead-macro-param-list-refs-at
  [params : (& params AstMacroParamList)]
  [refs : lint_svec.Vec]
  [index : i64]) : lint_svec.Vec
  (if (>= index (ast-macro-param-list-len params))
    refs
    (match (ast-macro-param-list-get params index (ast-macro-param-fallback))
      [(AstMacroParam.Param _ ty _ _)
        (selfhost-lint-dead-macro-param-list-refs-at
          params
          (selfhost-lint-dead-type-refs ty refs)
          (+ index 1))])))

(define (selfhost-lint-dead-pattern-list-refs
  [patterns : AstPatternList]
  [refs : lint_svec.Vec]) : lint_svec.Vec
  (selfhost-lint-dead-pattern-list-refs-at (& patterns) refs 0))

(define (selfhost-lint-dead-pattern-list-refs-at
  [patterns : (& patterns AstPatternList)]
  [refs : lint_svec.Vec]
  [index : i64]) : lint_svec.Vec
  (if (>= index (struct-get patterns len))
    refs
    (selfhost-lint-dead-pattern-list-refs-at
      patterns
      (selfhost-lint-dead-pattern-refs
        (ast-pattern-list-get patterns index (ast-pattern-fallback))
        refs)
      (+ index 1))))

(define (selfhost-lint-dead-pattern-refs
  [pattern : AstPattern]
  [refs : lint_svec.Vec]) : lint_svec.Vec
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
  [refs : lint_svec.Vec]) : lint_svec.Vec
  (selfhost-lint-dead-expr-list-refs-from exprs refs 0))

(define (selfhost-lint-dead-expr-list-refs-from
  [exprs : AstExprList]
  [refs : lint_svec.Vec]
  [index : i64]) : lint_svec.Vec
  (if (>= index (struct-get (& exprs) len))
    refs
    (selfhost-lint-dead-expr-list-refs-from
      exprs
      (selfhost-lint-dead-expr-refs
        (ast-node-get (ast-expr-list-get (& exprs) index 0))
        refs)
      (+ index 1))))

(define (selfhost-lint-dead-let-binding-refs
  [bindings : AstLetBindingList]
  [refs : lint_svec.Vec]) : lint_svec.Vec
  (selfhost-lint-dead-let-binding-refs-at (& bindings) refs 0))

(define (selfhost-lint-dead-let-binding-refs-at
  [bindings : (& bindings AstLetBindingList)]
  [refs : lint_svec.Vec]
  [index : i64]) : lint_svec.Vec
  (if (>= index (ast-let-binding-list-len bindings))
    refs
    (match (ast-let-binding-list-get bindings index (ast-let-binding-fallback))
      [(AstLetBinding.Binding _ maybe-ty init)
        (selfhost-lint-dead-let-binding-refs-at
          bindings
          (selfhost-lint-dead-expr-refs
            (ast-node-get init)
            (selfhost-lint-dead-maybe-type-refs maybe-ty refs))
          (+ index 1))])))

(define (selfhost-lint-dead-match-arm-refs
  [arms : AstMatchArmList]
  [refs : lint_svec.Vec]) : lint_svec.Vec
  (selfhost-lint-dead-match-arm-refs-at (& arms) refs 0))

(define (selfhost-lint-dead-match-arm-refs-at
  [arms : (& arms AstMatchArmList)]
  [refs : lint_svec.Vec]
  [index : i64]) : lint_svec.Vec
  (if (>= index (struct-get arms len))
    refs
    (match (ast-match-arm-list-get arms index (ast-match-arm-fallback))
      [(AstMatchArm.Arm pattern body)
        (selfhost-lint-dead-match-arm-refs-at
          arms
          (selfhost-lint-dead-expr-refs
            (ast-node-get body)
            (selfhost-lint-dead-pattern-refs pattern refs))
          (+ index 1))])))

(define (selfhost-lint-dead-resource-binding-refs
  [bindings : AstResourceBindingList]
  [refs : lint_svec.Vec]) : lint_svec.Vec
  (selfhost-lint-dead-resource-binding-refs-at (& bindings) refs 0))

(define (selfhost-lint-dead-resource-binding-refs-at
  [bindings : (& bindings AstResourceBindingList)]
  [refs : lint_svec.Vec]
  [index : i64]) : lint_svec.Vec
  (if (>= index (ast-resource-binding-list-len bindings))
    refs
    (match (ast-resource-binding-list-get
      bindings
      index
      (ast-resource-binding-fallback))
      [(AstResourceBinding.Binding _ init cleanup _)
        (selfhost-lint-dead-resource-binding-refs-at
          bindings
          (selfhost-lint-dead-expr-refs
            (ast-node-get cleanup)
            (selfhost-lint-dead-expr-refs (ast-node-get init) refs))
          (+ index 1))])))

(define (selfhost-lint-dead-expr-refs [expr : AstExpr] [refs : lint_svec.Vec]) : lint_svec.Vec
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
    [(AstExpr.DynArray exprs) (selfhost-lint-dead-expr-list-refs exprs refs)]
    [(AstExpr.MakeArray elem-id len)
      (selfhost-lint-dead-expr-refs
        (ast-node-get len)
        (selfhost-lint-dead-type-refs (ty-node-get elem-id) refs))]
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
    [(AstExpr.ArrayTake array live index)
      (selfhost-lint-dead-expr-refs
        (ast-node-get index)
        (selfhost-lint-dead-expr-refs
          (ast-node-get live)
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
    [(AstExpr.Ann inner ty-id)
      (selfhost-lint-dead-type-refs
        (ty-node-get ty-id)
        (selfhost-lint-dead-expr-refs (ast-node-get inner) refs))]
    [(AstExpr.Cast inner ty-id)
      (selfhost-lint-dead-type-refs
        (ty-node-get ty-id)
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
    [(AstExpr.StructGet receiver field)
      (selfhost-lint-dead-ref-add-id
        (selfhost-lint-dead-expr-refs (ast-node-get receiver) refs)
        field)]
    [(AstExpr.StructSet receiver field value)
      (selfhost-lint-dead-expr-refs
        (ast-node-get value)
        (selfhost-lint-dead-ref-add-id
          (selfhost-lint-dead-expr-refs (ast-node-get receiver) refs)
          field))]
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
    [(AstExpr.TypeLiteral ty-id)
      (selfhost-lint-dead-type-refs (ty-node-get ty-id) refs)]
    [(AstExpr.Init maybe-ty-id)
      (selfhost-lint-dead-maybe-type-refs
        (ast-maybe-type-from-id maybe-ty-id)
        refs)]
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
    [(AstExpr.Break) refs]
    [(AstExpr.Continue) refs]
    [(AstExpr.PtrNull ty-id)
      (selfhost-lint-dead-type-refs (ty-node-get ty-id) refs)]
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
    [(AstExpr.PtrCast ptr ty-id)
      (selfhost-lint-dead-type-refs
        (ty-node-get ty-id)
        (selfhost-lint-dead-expr-refs (ast-node-get ptr) refs))]
    [(AstExpr.PtrToInt ptr)
      (selfhost-lint-dead-expr-refs (ast-node-get ptr) refs)]
    [(AstExpr.IntToPtr value ty-id)
      (selfhost-lint-dead-type-refs
        (ty-node-get ty-id)
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
  [fallback : AstSourceSpan]) : AstSourceSpan
  (if (< idx 0)
    fallback
    (let
      [line : i64 (selfhost-lint-dead-index-line source idx)]
      [col : i64 (selfhost-lint-dead-index-col source idx)]
      (ast-source-span line col line (+ col 1)))))

(define (selfhost-lint-dead-decl-span
  [source : String]
  [name : String]
  [body-span : AstSourceSpan]) : AstSourceSpan
  (let
    [fn-needle : String (string.append "(define (" name)]
    [fn-idx : i64 (selfhost-lint-dead-find-name-prefix-from source fn-needle 0)]
    (if (>= fn-idx 0)
      (selfhost-lint-dead-index-span source fn-idx body-span)
      (selfhost-lint-dead-index-span
        source
        (selfhost-lint-dead-find-name-prefix-from
          source
          (string.append "(define " name)
          0)
        body-span))))

(define (selfhost-lint-dead-refs-to-roots-from
  [scan : SelfhostLintDeadScan]
  [refs : lint_svec.Vec]
  [index : i64]) : SelfhostLintDeadScan
  (if (>= index (lint_svec.len (& refs)))
    scan
    (selfhost-lint-dead-refs-to-roots-from
      (selfhost-lint-dead-scan-add-root scan (lint_svec.get (& refs) index ""))
      refs
      (+ index 1))))

(define (selfhost-lint-dead-refs-to-roots
  [scan : SelfhostLintDeadScan]
  [refs : lint_svec.Vec]) : SelfhostLintDeadScan
  (selfhost-lint-dead-refs-to-roots-from scan refs 0))

(define (selfhost-lint-dead-field-cleanup-refs
  [cleanup : AstFieldCleanup]
  [refs : lint_svec.Vec]) : lint_svec.Vec
  (match cleanup
    [(AstFieldCleanup.No) refs]
    [(AstFieldCleanup.Fn name) (selfhost-lint-dead-ref-add-id refs name)]
    [(AstFieldCleanup.Owned) refs]))

(define (selfhost-lint-dead-field-def-list-refs
  [fields : AstFieldDefList]
  [refs : lint_svec.Vec]) : lint_svec.Vec
  (selfhost-lint-dead-field-def-list-refs-at (& fields) refs 0))

(define (selfhost-lint-dead-field-def-list-refs-at
  [fields : (& fields AstFieldDefList)]
  [refs : lint_svec.Vec]
  [index : i64]) : lint_svec.Vec
  (if (>= index (struct-get fields len))
    refs
    (match (ast-field-def-list-get fields index (ast-field-def-fallback))
      [(AstFieldDef.Def _ ty cleanup)
        (selfhost-lint-dead-field-def-list-refs-at
          fields
          (selfhost-lint-dead-field-cleanup-refs
            cleanup
            (selfhost-lint-dead-type-refs ty refs))
          (+ index 1))])))

(define (selfhost-lint-dead-struct-cleanup-refs
  [cleanup : AstStructCleanup]
  [refs : lint_svec.Vec]) : lint_svec.Vec
  (match cleanup
    [(AstStructCleanup.No) refs]
    [(AstStructCleanup.Fn name) (selfhost-lint-dead-ref-add-id refs name)]))

(define (selfhost-lint-dead-enum-cleanup-refs
  [cleanup : AstEnumCleanup]
  [refs : lint_svec.Vec]) : lint_svec.Vec
  (match cleanup
    [(AstEnumCleanup.No) refs]
    [(AstEnumCleanup.Fn name) (selfhost-lint-dead-ref-add-id refs name)]))

(define (selfhost-lint-dead-variant-cleanup-refs
  [cleanup : AstVariantPayloadCleanup]
  [refs : lint_svec.Vec]) : lint_svec.Vec
  (match cleanup
    [(AstVariantPayloadCleanup.No) refs]
    [(AstVariantPayloadCleanup.Fn name)
      (selfhost-lint-dead-ref-add-id refs name)]
    [(AstVariantPayloadCleanup.Owned) refs]))

(define (selfhost-lint-dead-variant-cleanup-list-refs
  [items : AstVariantPayloadCleanupList]
  [refs : lint_svec.Vec]) : lint_svec.Vec
  (selfhost-lint-dead-variant-cleanup-list-refs-at (& items) refs 0))

(define (selfhost-lint-dead-variant-cleanup-list-refs-at
  [items : (& items AstVariantPayloadCleanupList)]
  [refs : lint_svec.Vec]
  [index : i64]) : lint_svec.Vec
  (if (>= index (struct-get items len))
    refs
    (selfhost-lint-dead-variant-cleanup-list-refs-at
      items
      (selfhost-lint-dead-variant-cleanup-refs
        (ast-variant-payload-cleanup-list-get
          items
          index
          (ast-variant-payload-cleanup-fallback))
        refs)
      (+ index 1))))

(define (selfhost-lint-dead-variant-def-list-refs
  [variants : AstVariantDefList]
  [refs : lint_svec.Vec]) : lint_svec.Vec
  (selfhost-lint-dead-variant-def-list-refs-at (& variants) refs 0))

(define (selfhost-lint-dead-variant-def-list-refs-at
  [variants : (& variants AstVariantDefList)]
  [refs : lint_svec.Vec]
  [index : i64]) : lint_svec.Vec
  (if (>= index (struct-get variants len))
    refs
    (match (ast-variant-def-list-get variants index (ast-variant-def-fallback))
      [(AstVariantDef.Def name payloads cleanups)
        (selfhost-lint-dead-variant-def-list-refs-at
          variants
          (selfhost-lint-dead-variant-cleanup-list-refs
            cleanups
            (selfhost-lint-dead-type-list-refs
              payloads
              (selfhost-lint-dead-ref-add-id refs name)))
          (+ index 1))])))

(define (selfhost-lint-dead-dispatch-variant-list-refs-from
  [variants : (& variants AstDispatchVariantList)]
  [index : i64]
  [refs : lint_svec.Vec]) : lint_svec.Vec
  (if (>= index (struct-get variants len))
    refs
    (match (ast-dispatch-variant-list-get
      variants
      index
      (ast-dispatch-variant-fallback))
      [(AstDispatchVariant.Variant _ name)
        (selfhost-lint-dead-dispatch-variant-list-refs-from
          variants
          (+ index 1)
          (selfhost-lint-dead-ref-add-id refs name))])))

(define (selfhost-lint-dead-dispatch-variant-list-refs
  [variants : AstDispatchVariantList]
  [refs : lint_svec.Vec]) : lint_svec.Vec
  (selfhost-lint-dead-dispatch-variant-list-refs-from (& variants) 0 refs))

(define (selfhost-lint-dead-extern-abi-refs
  [abi : AstExternAbi]
  [refs : lint_svec.Vec]) : lint_svec.Vec
  (match abi
    [(AstExternAbi.C) refs]
    [(AstExternAbi.CVarargsOpen) refs]
    [(AstExternAbi.CVarargsTyped tail-ty)
      (selfhost-lint-dead-type-refs tail-ty refs)]))

(define (selfhost-lint-dead-extern-metadata-refs
  [meta : AstExternMetadata]
  [refs : lint_svec.Vec]) : lint_svec.Vec
  (match meta
    [(AstExternMetadata.Metadata abi _ _ _ _)
      (selfhost-lint-dead-extern-abi-refs abi refs)]))

(define (selfhost-lint-dead-generated-meta-refs
  [meta : AstGeneratedDeclMeta]
  [refs : lint_svec.Vec]) : lint_svec.Vec
  (match meta
    [(AstGeneratedDeclMeta.No) refs]
    [(AstGeneratedDeclMeta.Some _ _ args _)
      (selfhost-lint-dead-expr-list-refs args refs)]))

(define (selfhost-lint-dead-add-node
  [scan : SelfhostLintDeadScan]
  [path : String]
  [module : String]
  [name : String]
  [span : AstSourceSpan]
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
  [span : AstSourceSpan]
  [refs : lint_svec.Vec]
  [root : bool]
  [reportable : bool]) : SelfhostLintDeadScan
  (let
    [with-node : SelfhostLintDeadScan
      (selfhost-lint-dead-add-node scan path module name span refs reportable)]
    [explicit-root : bool
      (selfhost-lint-suppressed? source (lint-dead-code-finding name span))]
    (if root
      (selfhost-lint-dead-scan-add-root with-node name)
      (if explicit-root
        (selfhost-lint-dead-scan-add-root
          with-node
          (selfhost-lint-dead-source-root path name))
        with-node))))

(define (selfhost-lint-dead-scan-decl
  [scan : SelfhostLintDeadScan]
  [path : String]
  [module : String]
  [source : String]
  [decl : AstDecl]
  [visible-root : bool]
  [requested-report : bool]) : SelfhostLintDeadScan
  (let
    [allow-report : bool
      (and requested-report (not (ast-decl-comptime-only? decl)))]
    [result : SelfhostLintDeadScan
      (match decl
        [(AstDecl.ModuleBody name body-box)
          (selfhost-lint-dead-scan-decls
            scan
            path
            (intern-str name)
            source
            visible-root
            allow-report
            (box-get body-box))]
        [(AstDecl.Module _) scan]
        [(AstDecl.Def decl-meta name maybe-ty body)
          (let
            [text : String (intern-str name)]
            [refs : lint_svec.Vec
              (selfhost-lint-dead-expr-refs
                (ast-node-get body)
                (selfhost-lint-dead-maybe-type-refs maybe-ty (lint_svec.new)))]
            [span : AstSourceSpan
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
        [(AstDecl.DefFn decl-meta name params ret body _)
          (let
            [text : String (intern-str name)]
            [refs : lint_svec.Vec
              (selfhost-lint-dead-expr-refs
                (ast-node-get body)
                (selfhost-lint-dead-type-refs
                  ret
                  (selfhost-lint-dead-param-list-refs params (lint_svec.new))))]
            [span : AstSourceSpan
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
        [(AstDecl.DefMacro decl-meta name params ret body)
          (selfhost-lint-dead-add-visible-node
            scan
            path
            module
            source
            (intern-str name)
            (selfhost-lint-dead-expr-span body)
            (selfhost-lint-dead-expr-refs
              (ast-node-get body)
              (selfhost-lint-dead-type-refs
                ret
                (selfhost-lint-dead-macro-param-list-refs
                  params
                  (lint_svec.new))))
            visible-root
            allow-report)]
        [(AstDecl.Extern decl-meta name _ meta ty)
          (selfhost-lint-dead-add-visible-node
            scan
            path
            module
            source
            (intern-str name)
            (lint-no-span)
            (selfhost-lint-dead-type-refs
              ty
              (selfhost-lint-dead-extern-metadata-refs
                (box-get meta)
                (lint_svec.new)))
            visible-root
            allow-report)]
        [(AstDecl.DefEnum decl-meta name cleanup variants)
          (selfhost-lint-dead-add-visible-node
            scan
            path
            module
            source
            (intern-str name)
            (lint-no-span)
            (selfhost-lint-dead-variant-def-list-refs
              variants
              (selfhost-lint-dead-enum-cleanup-refs cleanup (lint_svec.new)))
            visible-root
            allow-report)]
        [(AstDecl.DefEnumLifetimes decl-meta name _ cleanup variants)
          (selfhost-lint-dead-add-visible-node
            scan
            path
            module
            source
            (intern-str name)
            (lint-no-span)
            (selfhost-lint-dead-variant-def-list-refs
              variants
              (selfhost-lint-dead-enum-cleanup-refs cleanup (lint_svec.new)))
            visible-root
            allow-report)]
        [(AstDecl.DefStruct decl-meta name _ cleanup fields)
          (selfhost-lint-dead-add-visible-node
            scan
            path
            module
            source
            (intern-str name)
            (lint-no-span)
            (selfhost-lint-dead-field-def-list-refs
              fields
              (selfhost-lint-dead-struct-cleanup-refs cleanup (lint_svec.new)))
            visible-root
            allow-report)]
        [(AstDecl.DefStructLifetimes decl-meta name _ _ cleanup fields)
          (selfhost-lint-dead-add-visible-node
            scan
            path
            module
            source
            (intern-str name)
            (lint-no-span)
            (selfhost-lint-dead-field-def-list-refs
              fields
              (selfhost-lint-dead-struct-cleanup-refs cleanup (lint_svec.new)))
            visible-root
            allow-report)]
        [(AstDecl.Import
            decl-meta
            (AstImportSpec.Spec (AstImportKind.Macro call-expr _) _ _ _ _))
          (selfhost-lint-dead-refs-to-roots
            scan
            (selfhost-lint-dead-expr-refs
              (ast-node-get call-expr)
              (lint_svec.new)))]
        [(AstDecl.Import
            decl-meta
            (AstImportSpec.Spec (AstImportKind.MacroDecls call-expr _) _ _ _ _))
          (selfhost-lint-dead-refs-to-roots
            scan
            (selfhost-lint-dead-expr-refs
              (ast-node-get call-expr)
              (lint_svec.new)))]
        [(AstDecl.Import decl-meta _) scan]
        [(AstDecl.IncludeStr _ _) scan]
        [(AstDecl.IncludeStrComptime _ _) scan]
        [(AstDecl.IncludeStrLzss _ _) scan]
        [(AstDecl.IncludeBin _ _) scan]
        [(AstDecl.DefDispatch decl-meta name variants)
          (selfhost-lint-dead-add-visible-node
            scan
            path
            module
            source
            (intern-str name)
            (lint-no-span)
            (selfhost-lint-dead-dispatch-variant-list-refs
              variants
              (lint_svec.new))
            visible-root
            allow-report)]
        [(AstDecl.Test _ body _)
          (selfhost-lint-dead-refs-to-roots
            scan
            (selfhost-lint-dead-expr-refs (ast-node-get body) (lint_svec.new)))]
        [(AstDecl.Unsafe inner)
          (selfhost-lint-dead-scan-decl
            scan
            path
            module
            source
            (box-get inner)
            visible-root
            allow-report)])]
    (selfhost-lint-dead-refs-to-roots
      result
      (selfhost-lint-dead-generated-meta-refs
        (ast-decl-generated-meta decl)
        (lint_svec.new)))))

(define (selfhost-lint-dead-scan-decls
  [scan : SelfhostLintDeadScan]
  [path : String]
  [module : String]
  [source : String]
  [visible-root : bool]
  [reportable : bool]
  [decls : AstDeclList]) : SelfhostLintDeadScan
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil) scan]
    [(AstDeclListStep.Cons decl rest)
      (match decl
        [(AstDecl.Module name)
          (selfhost-lint-dead-scan-decls
            scan
            path
            (intern-str name)
            source
            visible-root
            reportable
            rest)]
        [(AstDecl.ModuleBody name body-box)
          (selfhost-lint-dead-scan-decls
            (selfhost-lint-dead-scan-decls
              scan
              path
              (intern-str name)
              source
              visible-root
              reportable
              (box-get body-box))
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
  [decls : AstDeclList]
  [aliases : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil) aliases]
    [(AstDeclListStep.Cons decl rest)
      (match decl
        [(AstDecl.Import
            _
            (AstImportSpec.Spec
              (AstImportKind.Module)
              _
              (AstMaybeModuleName.Some target)
              (AstMaybeImportAlias.Some alias)
              _))
          (selfhost-lint-dead-import-aliases-from-decls
            rest
            (sym_i64_env.sym-i64-bind-id
              aliases
              alias
              (parse-ast-dotted-import-default-alias-id target)))]
        [(AstDecl.ModuleBody _ body-box)
          (selfhost-lint-dead-import-aliases-from-decls
            rest
            (selfhost-lint-dead-import-aliases-from-decls
              (box-get body-box)
              aliases))]
        [_ (selfhost-lint-dead-import-aliases-from-decls rest aliases)])]))

(define (selfhost-lint-dead-scan-source-with-cfgs
  [scan : SelfhostLintDeadScan]
  [path : String]
  [source : String]
  [visible-root : bool]
  [reportable : bool]
  [cfgs : sym_i64_env.SymI64Env]) : SelfhostLintDeadScan
  (match (parse-ast-source-diagnostic-with-cfg path source cfgs)
    [(ResultAstProgramDiagnostic.Ok program)
      (match program
        [(AstProgram.Program decls-box)
          (let
            [decls : AstDeclList (box-get decls-box)]
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
    [(ResultAstProgramDiagnostic.Err _) scan]))

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
  [items : lint_svec.Vec]) : lint_svec.Vec
  (if (>= index (lint_svec.len (& source)))
    items
    (let
      [value : String (lint_svec.get (& source) index "")]
      [owned : String (clone value)]
      [next : lint_svec.Vec items]
      (begin
        (lint_svec.push (&mut next) owned)
        (selfhost-lint-dead-clone-string-vec-from source (+ index 1) next)))))

(define (selfhost-lint-dead-clone-string-vec [source : lint_svec.Vec]) : lint_svec.Vec
  (selfhost-lint-dead-clone-string-vec-from source 0 (lint_svec.new)))

(define (selfhost-lint-dead-clone-decl [decl : SelfhostLintDeadDecl]) : SelfhostLintDeadDecl
  (let
    [path : String (struct-get decl path)]
    [name : String (struct-get decl name)]
    [key : String (struct-get decl key)]
    [span : AstSourceSpan (struct-get decl span)]
    (SelfhostLintDeadDecl
      (clone path)
      (clone name)
      (clone key)
      (AstSourceSpan
        (struct-get span start-line)
        (struct-get span start-col)
        (struct-get span end-line)
        (struct-get span end-col))
      (selfhost-lint-dead-clone-string-vec (struct-get decl refs))
      (struct-get decl root)
      (struct-get decl reportable))))

(define (selfhost-lint-dead-scan-clone-decls-from
  [scan : SelfhostLintDeadScan]
  [source-scan : SelfhostLintDeadScan]
  [index : i64]) : SelfhostLintDeadScan
  (if (>= index (selfhost-lint-dead-decls-count (struct-get source-scan decls)))
    scan
    (let
      [decl : SelfhostLintDeadDecl
        (selfhost-lint-dead-decls-ref (struct-get source-scan decls) index)]
      [owned : SelfhostLintDeadDecl (selfhost-lint-dead-clone-decl decl)]
      (selfhost-lint-dead-scan-clone-decls-from
        (selfhost-lint-dead-scan-add-decl scan owned)
        source-scan
        (+ index 1)))))

(define (selfhost-lint-dead-scan-clone-roots-from
  [scan : SelfhostLintDeadScan]
  [source-scan : SelfhostLintDeadScan]
  [index : i64]) : SelfhostLintDeadScan
  (if (>= index (lint_svec.len (& (struct-get source-scan roots))))
    scan
    (let
      [root : String
        (lint_svec.get (& (struct-get source-scan roots)) index "")]
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
    [pools : AstNodePoolContext
      (ast-node-pool-context-new-with-capacities-in-arena
        selfhost-lint-expr-pool-initial-capacity
        selfhost-lint-type-pool-initial-capacity
        pool-arena)]
    [_install-pools : unit (ast-node-pool-compat-context-use! pools)]
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
      (ast-node-pool-context-reset-to! pools 0 0)
      (ast-node-pool-compat-context-clear!)
      (ast-node-pool-context-destroy-storage! pools)
      (unsafe
        (begin
          (arena.set! home)
          (arena.destroy scratch)
          (arena.tl_arena_destroy (ast-node-pool-context-base-arena pools))))
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
      (struct-get (selfhost-lint-dead-decls-ref items index) name)
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
      (struct-get (selfhost-lint-dead-decls-ref items index) key)
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
    (if (struct-get decl root)
      items
      (let
        [marked : SelfhostLintDeadDecl
          (SelfhostLintDeadDecl
            (struct-get decl path)
            (struct-get decl name)
            (struct-get decl key)
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
        (if (string.eq (struct-get decl name) name)
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
        (if (and
          (string.eq (struct-get decl path) path)
          (string.eq (struct-get decl name) name))
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

(define (selfhost-lint-package-kind-entry? [kind : CompilerPkgKind]) : bool
  (match kind
    [(CompilerPkgKindBin) true]
    [(CompilerPkgKindLib) false]))

(define (selfhost-lint-package-entry-path
  [manifest-dir : String]
  [manifest : CompilerPkgManifest]) : String
  (compiler-load-normalize-path
    (compiler-load-join-root-path manifest-dir (struct-get manifest entry))))

;; Package sources commonly live below `src/`, while package test roots under
;; `src/tests/` import them by module name. Make the entry directory available
;; to the per-file lint loader without classifying it as stdlib-owned source.
(define (selfhost-lint-package-import-roots
  [source-set : PackageSourceSet]
  [stdlib-roots : lint_svec.Vec]) : lint_svec.Vec
  (let
    [manifest : CompilerPkgManifest (struct-get source-set manifest)]
    [manifest-dir : String (struct-get source-set manifest-dir)]
    [entry-path : String
      (selfhost-lint-package-entry-path manifest-dir manifest)]
    [entry-dir : String (compiler-load-dirname entry-path)]
    [source-root : String
      (compiler-load-normalize-path
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
          (lint_svec.push (&mut roots) source-root)
          roots)))))

(define (selfhost-lint-package-source-list-contains-from
  [sources : lint_svec.Vec]
  [path : String]
  [index : i64]) : bool
  (if (>= index (lint_svec.len (& sources)))
    false
    (if (string.eq
      (compiler-load-normalize-path (lint_svec.get (& sources) index ""))
      (compiler-load-normalize-path path))
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
  [stdlib-roots : lint_svec.Vec]) : bool
  (let
    [normalized : String (compiler-load-normalize-path path)]
    [stdlib-path : String
      (if (compiler-load-stdlib-import? normalized)
        normalized
        (compiler-load-stdlib-owned-path-from-roots normalized stdlib-roots))]
    (compiler-load-stdlib-import? stdlib-path)))

(define (selfhost-lint-package-dead-source-path?
  [path : String]
  [sources : lint_svec.Vec]
  [stdlib-roots : lint_svec.Vec]) : bool
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
    (package-source-vec-insert items (compiler-load-normalize-path path))
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
  [roots : lint_svec.Vec]) : lint_svec.Vec
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
                  (compiler-load-normalize-path
                    (compiler-load-join-root-path manifest-dir relative)))]
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
  [source-set : PackageSourceSet]) : lint_svec.Vec
  (let
    [manifest-dir : String (struct-get source-set manifest-dir)]
    [path : String
      (compiler-load-join-root-path manifest-dir "src/compile_manifest.txt")]
    (if (io.file-exists? path)
      (selfhost-lint-dead-manifest-roots
        (byte_buf.to-string (io.read-file path))
        manifest-dir)
      (lint_svec.new))))

(define (selfhost-lint-package-dead-repository-test-roots
  [source-set : PackageSourceSet]) : lint_svec.Vec
  (match (package-source-scan-optional-dir
    "lint"
    (struct-get source-set manifest-dir)
    "src/tests"
    (lint_svec.new))
    [(ResultPackageSourceList.Ok sources) sources]
    [(ResultPackageSourceList.Err _) (selfhost-lint-package-empty-source-list)]))

(define (selfhost-lint-package-dead-import-paths-from-decls
  [decls : AstDeclList]
  [importer-path : String]
  [import-root : String]
  [source-set : PackageSourceSet]
  [root-sources : lint_svec.Vec]
  [stdlib-roots : lint_svec.Vec]
  [pools : AstNodePoolContext]
  [package-imports : bool]
  [items : lint_svec.Vec]) : ResultSelfhostLintDeadImportList
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil) (ResultSelfhostLintDeadImportList.Ok items)]
    [(AstDeclListStep.Cons decl rest)
      (match decl
        [(AstDecl.Import
            decl-meta
            (AstImportSpec.Spec kind import-path expected-module alias _))
          (if (compiler-load-macro-import-kind? kind)
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
              [manifest : CompilerPkgManifest (struct-get source-set manifest)]
              [manifest-dir : String (struct-get source-set manifest-dir)]
              (match (if package-imports
                (compiler-load-resolve-package-import-spec
                  importer-path
                  kind
                  import-path
                  expected-module
                  stdlib-roots
                  manifest-dir
                  (struct-get manifest deps))
                (compiler-load-resolve-import-spec-with-roots
                  importer-path
                  import-root
                  kind
                  import-path
                  expected-module
                  stdlib-roots))
                [(ResultPkgResolve.Err message)
                  (ResultSelfhostLintDeadImportList.Err
                    (box (compiler-diagnostic-at-start importer-path message)))]
                [(ResultPkgResolve.Ok resolved)
                  (let
                    [resolved-id : i64 (compiler-load-source-path-id resolved)]
                    [package-externs : bool
                      (and
                        package-imports
                        (compiler-load-package-import-externs?
                          kind
                          import-path
                          expected-module
                          (struct-get manifest deps)))]
                    [preload-candidate : bool
                      (and
                        (not package-externs)
                        (compiler-load-lazy-import-preload-candidate?
                          importer-path
                          kind
                          alias))]
                    [preload-demand : CompilerLoadLazyAliasDemand
                      (compiler-load-lazy-import-preload-demand
                        preload-candidate
                        alias
                        rest
                        pools)]
                    [preload-summary-needed : bool
                      (and
                        preload-candidate
                        (not
                          (or
                            (struct-get preload-demand qualified)
                            (struct-get preload-demand unknown))))]
                    [_preload-summary : unit
                      (if preload-summary-needed
                        (compiler-load-lazy-import-preload-summary-with-pools
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
                        (compiler-load-lazy-import-skip?
                          importer-path
                          kind
                          resolved-id
                          expected-module
                          alias
                          rest
                          pools
                          preload-demand))]
                    [next : lint_svec.Vec
                      (if (or
                        preload-skip
                        (not
                          (selfhost-lint-package-dead-graph-source-path?
                            resolved
                            (struct-get source-set sources)
                            root-sources
                            stdlib-roots)))
                        items
                        (selfhost-lint-dead-root-add
                          items
                          (compiler-load-normalize-path resolved)))]
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
        [(AstDecl.ModuleBody _ body-box)
          (match (selfhost-lint-package-dead-import-paths-from-decls
            (box-get body-box)
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
  [source-set : PackageSourceSet]
  [root-sources : lint_svec.Vec]
  [stdlib-roots : lint_svec.Vec]
  [package-imports : bool]) : ResultSelfhostLintDeadImportList
  (let
    ;; Discover the closure one file at a time. Loading every root's complete
    ;; graph here retains duplicate ASTs and makes repository lint unbounded.
    [_reset-file-state : unit (selfhost-lint-reset-file-state!)]
    [home : arena.Arena (arena.current)]
    [pool-arena : i64 (arena.tl_arena_make)]
    [pools : AstNodePoolContext
      (ast-node-pool-context-new-with-capacities-in-arena
        selfhost-lint-expr-pool-initial-capacity
        selfhost-lint-type-pool-initial-capacity
        pool-arena)]
    [_install-pools : unit (ast-node-pool-compat-context-use! pools)]
    [scratch : arena.Arena (arena.make)]
    [scratch-result : ResultSelfhostLintDeadImportList
      (begin
        (unsafe
          (arena.set! scratch))
        (match (parse-ast-source-diagnostic-with-cfg
          path
          (byte_buf.to-string (io.read-file path))
          (selfhost-lint-package-dead-cfgs))
          [(ResultAstProgramDiagnostic.Err diag)
            (ResultSelfhostLintDeadImportList.Err diag)]
          [(ResultAstProgramDiagnostic.Ok program)
            (match program
              [(AstProgram.Program decls-box)
                (selfhost-lint-package-dead-import-paths-from-decls
                  (box-get decls-box)
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
      (ast-node-pool-context-reset-to! pools 0 0)
      (ast-node-pool-compat-context-clear!)
      (ast-node-pool-context-destroy-storage! pools)
      (unsafe
        (begin
          (arena.set! home)
          (arena.destroy scratch)
          (arena.tl_arena_destroy (ast-node-pool-context-base-arena pools))))
      result)))

(define (selfhost-lint-package-dead-path-closure-from
  [queue : lint_svec.Vec]
  [index : i64]
  [import-root : String]
  [source-set : PackageSourceSet]
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
                    (set!
                      next
                      (selfhost-lint-dead-root-add
                        next
                        (lint_svec.get (& imports) import-index "")))
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
      (package-source-vec-insert items (lint_svec.get (& paths) index ""))
      paths
      (+ index 1))))

(define (selfhost-lint-package-dead-closure-sources-mode
  [entry-path : String]
  [source-set : PackageSourceSet]
  [root-sources : lint_svec.Vec]
  [stdlib-roots : lint_svec.Vec]
  [items : lint_svec.Vec]
  [package-imports : bool]) : ResultSelfhostLintDeadSourceList
  (let
    [start : lint_svec.Vec
      (selfhost-lint-package-dead-graph-source-insert
        (lint_svec.new)
        entry-path
        (struct-get source-set sources)
        root-sources
        stdlib-roots)]
    [import-root : String (compiler-load-dirname entry-path)]
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
  [source-set : PackageSourceSet]
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
  [source-set : PackageSourceSet]
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
  [source-set : PackageSourceSet]
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
  [source-set : PackageSourceSet]
  [stdlib-roots : lint_svec.Vec]
  [items : lint_svec.Vec]) : ResultSelfhostLintDeadSourceList
  (selfhost-lint-package-dead-root-closure-sources-from
    root-sources
    source-set
    stdlib-roots
    items
    0))

(define (selfhost-lint-package-dead-sources
  [source-set : PackageSourceSet]
  [stdlib-roots : lint_svec.Vec]) : ResultSelfhostLintDeadSources
  (let
    [manifest : CompilerPkgManifest (struct-get source-set manifest)]
    [package-roots : lint_svec.Vec
      (selfhost-lint-package-import-roots source-set stdlib-roots)]
    [explicit-roots : lint_svec.Vec
      (selfhost-lint-package-dead-compile-manifest-roots source-set)]
    [kind : CompilerPkgKind (struct-get manifest kind)]
    (if (selfhost-lint-package-kind-entry? kind)
      (let
        [manifest-dir : String (struct-get source-set manifest-dir)]
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
                    (struct-get source-set sources)
                    explicit-roots))])]))
      (ResultSelfhostLintDeadSources.Ok
        (SelfhostLintDeadSourceSet
          (struct-get source-set sources)
          (selfhost-lint-package-empty-source-list)
          (struct-get source-set sources)
          explicit-roots)))))

(define (selfhost-lint-package-dead-code
  [source-set : SelfhostLintDeadSourceSet]
  [stdlib-roots : lint_svec.Vec]
  [kind : CompilerPkgKind]) : SelfhostLintDeadDecls
  (let
    [visible-root : bool (selfhost-lint-package-dead-visible-root? kind)]
    [reportable : bool (selfhost-lint-package-dead-reportable? kind)]
    [scan : SelfhostLintDeadScan
      (selfhost-lint-dead-scan-add-roots
        (selfhost-lint-package-dead-add-kind-roots
          (selfhost-lint-package-dead-scan-files
            (struct-get source-set sources)
            (struct-get source-set reportable-sources)
            stdlib-roots
            0
            visible-root
            reportable
            (SelfhostLintDeadScan
              (selfhost-lint-dead-decls-empty)
              (lint_svec.new)))
          kind)
        (struct-get source-set explicit-roots))]
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
              (selfhost-lint-render-finding-line
                path
                source
                (lint-dead-code-finding
                  (struct-get decl name)
                  (struct-get decl span))))
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
    (lint-unused-unsafe-classifier-reset!)
    (tc-unused-unsafe-tracking-clear!)
    (tc-prefix-snapshot-cache-clear!)
    (compiler-check-reset-pools!)
    (compiler-check-reset-interns!)
    (compiler-typecheck-reset-file-state!)))

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
    [pools : AstNodePoolContext
      (ast-node-pool-context-new-with-capacities-in-arena
        selfhost-lint-expr-pool-initial-capacity
        selfhost-lint-type-pool-initial-capacity
        pool-arena)]
    [_install-pools : unit (ast-node-pool-compat-context-use! pools)]
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
      (unsafe
        (arena.set! home))
      ;; Reset compiler-check state while the file scratch arena is still mapped;
      ;; typed lint rules can leave scratch-backed nodes in check/typecheck caches.
      (selfhost-lint-reset-file-state!)
      (ast-node-pool-context-reset-to! pools 0 0)
      (ast-node-pool-compat-context-clear!)
      (ast-node-pool-context-destroy-storage! pools)
      (unsafe
        (begin
          (arena.set! home)
          (arena.destroy scratch)
          (arena.tl_arena_destroy (ast-node-pool-context-base-arena pools))))
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
    [pools : AstNodePoolContext
      (ast-node-pool-context-new-with-capacities-in-arena
        selfhost-lint-expr-pool-initial-capacity
        selfhost-lint-type-pool-initial-capacity
        pool-arena)]
    [_install-pools : unit (ast-node-pool-compat-context-use! pools)]
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
      (unsafe
        (arena.set! home))
      (selfhost-lint-reset-file-state!)
      (ast-node-pool-context-reset-to! pools 0 0)
      (ast-node-pool-compat-context-clear!)
      (ast-node-pool-context-destroy-storage! pools)
      (unsafe
        (begin
          (arena.set! home)
          (arena.destroy scratch)
          (arena.tl_arena_destroy (ast-node-pool-context-base-arena pools))))
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
    (match (parse-ast-source-diagnostic-with-cfg-and-pools
      input-path
      source
      (selfhost-lint-language-cfgs)
      (ast-node-pool-compat-context-current))
      [(ResultAstProgramDiagnostic.Ok program)
        (let
          [findings : LintFindings
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
              (io.print-string
                (string.append
                  "lint: "
                  (string.append
                    (string.int->string (lint-findings-count findings))
                    " finding(s)\n")))
              (selfhost-lint-enforce-exit
                enforcing
                (lint-findings-count findings)))
            (begin
              (io.print-error
                (string.append selfhost-lint-typed-unused-unsafe-error "\n"))
              1)))]
      [(ResultAstProgramDiagnostic.Err diag)
        (begin
          (io.print-error (compiler-diagnostic-render (box-get diag)))
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
    (match (parse-ast-source-diagnostic-with-cfg-and-pools
      input-path
      source
      (selfhost-lint-language-cfgs)
      (ast-node-pool-compat-context-current))
      [(ResultAstProgramDiagnostic.Ok program)
        (let
          [findings : LintFindings
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
                (io.print-string
                  (string.append
                    "lint: "
                    (string.append
                      (string.int->string total-count)
                      " finding(s)\n")))
                (selfhost-lint-enforce-exit enforcing total-count)))
            (begin
              (io.print-error
                (string.append selfhost-lint-typed-unused-unsafe-error "\n"))
              1)))]
      [(ResultAstProgramDiagnostic.Err diag)
        (begin
          (io.print-error (compiler-diagnostic-render (box-get diag)))
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
            (io.print-string
              (string.append "--- " (string.append input-path "\n")))
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
            (io.print-string
              (string.append "--- " (string.append input-path "\n")))
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
  (match (package-source-discover-for "lint" manifest-path has-manifest)
    [(ResultPackageSourceSet.Err message)
      (begin
        (io.print-error (string.append message "\n"))
        1)]
    [(ResultPackageSourceSet.Ok source-set)
      (let
        [sources : lint_svec.Vec (struct-get source-set sources)]
        [manifest : CompilerPkgManifest (struct-get source-set manifest)]
        [package-roots : lint_svec.Vec
          (selfhost-lint-package-import-roots source-set stdlib-roots)]
        (match (selfhost-lint-package-dead-sources source-set stdlib-roots)
          [(ResultSelfhostLintDeadSources.Ok dead-sources)
            (let
              [dead-decls : SelfhostLintDeadDecls
                (selfhost-lint-package-dead-code
                  dead-sources
                  package-roots
                  (struct-get manifest kind))]
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
              (io.print-error (compiler-diagnostic-render (box-get diag)))
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

(define (selfhost-lint-guard-ladder-source) : String
  "(define (check [a : bool] [b : bool] [c : bool]) : i64
  (begin
    (if a
      (return 1)
      (if b
        (return 2)
        (if c
          (return 3)
          unit)))
    42))")

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

(define (selfhost-lint-all-exit-ladder-source) : String
  "(define (classify [x : i64]) : i64
  (if (= x 0)
    (return 10)
    (if (= x 1)
      (return 20)
      (if (= x 2)
        (return 30)
        (return 0)))))")

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
  "(define (main) : i64 (pkg.public-api 1))
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
    (string.append "(cfg test (te" "st \"test-only\" (test-only-helper)))")))

(define (selfhost-lint-package-dead-entry-source) : String
  "(define (main) : i64 42)
(define (test-reached-helper) : i64 7)
(define (unused-entry-helper) : i64 9)")

(define (selfhost-lint-package-dead-test-root-source) : String
  "(define (main) : i64 (test-reached-helper))")

(define (selfhost-lint-package-dead-manifest-root-source) : String
  "(define (manifest-entry) : i64 (manifest-helper))
(define (manifest-helper) : i64 7)
(define (manifest-unused) : i64 9)")

(define (selfhost-lint-package-dead-manifest-root-manifest) : String
  "case|lint-root-fixture|src/manifest_api.tl|assembly|skip|direct
lint-root|manifest-entry
contains|_tl_manifest_entry:
end
")

(define (selfhost-lint-package-dead-explicit-root-source) : String
  "(define (retained-api-with-extra) : i64 1)
;; lint-allow: dead-code
(define (retained-api) : i64 (retained-helper))
(define (retained-helper) : i64 7)
(define (explicit-unused) : i64 9)")

(define (selfhost-lint-package-dead-cfg-source) : String
  "(define (main) : i64
  (+ (cfg scratch-vreg (scratch-vreg-helper) 40)
     (+ (cfg embedded-stdlib-tlci (embedded-helper) 1)
        (cfg compile-profile
          (profile-mode-helper)
          (ordinary-mode-helper)))))
(cfg scratch-vreg
  (define (scratch-vreg-helper) : i64 7))
(cfg scratch-vreg
  (define (scratch-vreg-unused) : i64 8))
(cfg embedded-stdlib-tlci
  (define (embedded-helper) : i64 1))
(cfg embedded-stdlib-tlci
  (define (embedded-unused) : i64 2))
(cfg compile-profile
  (define (profile-helper) : i64 1))
(cfg compile-profile-summary
  (define (profile-summary-helper) : i64 1))
(cfg compile-profile
  (define (profile-mode-helper) : i64
    (cfg compile-profile-summary
      (profile-summary-helper)
      (profile-helper))))
(cfg compile-profile
  (define (profile-unused) : i64 2))
(cfg lint-fixture-experimental
  (define (experimental-helper) : i64 9))
(define (ordinary-mode-helper) : i64 1)
(define (ordinary-unused) : i64 0)")

(define (selfhost-lint-package-dead-qualified-left-source) : String
  "(module left)
(define (helper) : i64 1)")

(define (selfhost-lint-package-dead-qualified-right-source) : String
  "(module right)
(define (live) : i64 (helper))
(define (helper) : i64 2)")

(define (selfhost-lint-package-dead-qualified-main-source) : String
  "(module main)
(import left)
(import right)
(define (main) : i64 (right.live))")

(define (selfhost-lint-package-dead-moduleless-left-source) : String
  "(define (live) : i64 (helper))
(define (helper) : i64 1)
(define (unused) : i64 11)")

(define (selfhost-lint-package-dead-moduleless-right-source) : String
  "(define (live) : i64 (helper))
(define (helper) : i64 2)
(define (unused) : i64 12)")

(define (selfhost-lint-package-dead-moduleless-main-source) : String
  "(import pkg.left as first)
(import pkg.right as second)
(define (main) : i64 (+ (first.live) (second.live)))")

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
    [cur : (__tl_dyn-array i64) (make-array i64 1)]
    (begin
      (array-set! cur 0 3)
      (array-ref cur 0))))")

(define (selfhost-lint-single-element-array-dotted-source) : String
  "(define (main) : i64
  (let
    [cur : (__tl_dyn-array i64) (array.make-array i64 1)]
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
    [cur : (__tl_dyn-array i64) (make-array i64 1)]
    (array-ref cur index)))")

(define (selfhost-lint-single-element-array-escape-source) : String
  "(define (use-array [items : (__tl_dyn-array i64)]) : i64
  (array-length items))
(define (main) : i64
  (let
    [cur : (__tl_dyn-array i64) (make-array i64 1)]
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

(define (selfhost-lint-dynamic-array-literal-dotted-source) : String
  "(define (make-items [a : i64] [b : i64] [c : i64]) : (__tl_dyn-array i64)
  (let
    [items : (__tl_dyn-array i64) (array.make-array i64 3)]
    (begin
      (array-set! items 0 a)
      (array-set! items 1 b)
      (array-set! items 2 c)
      items)))")

(define (selfhost-lint-dynamic-array-literal-bare-source) : String
  "(define (make-items) : (__tl_dyn-array i64)
  (let
    [items : (__tl_dyn-array i64) (make-array i64 2)]
    (begin
      (array-set! items 0 4)
      (array-set! items 1 7)
      items)))")

(define (selfhost-lint-dynamic-array-literal-return-source) : String
  "(define (make-items) : (__tl_dyn-array i64)
  (let
    [items : (__tl_dyn-array i64) (make-array i64 2)]
    (begin
      (array-set! items 0 4)
      (array-set! items 1 7)
      (return items))))")

(define (selfhost-lint-dynamic-array-literal-assignment-source) : String
  "(define (set-items [result : (__tl_dyn-array i64)]) : unit
  (let
    [items : (__tl_dyn-array i64) (make-array i64 2)]
    (begin
      (array-set! items 0 4)
      (array-set! items 1 7)
      (set! result items))))")

(define (selfhost-lint-dynamic-array-literal-ambiguous-two-var-source) : String
  "(define (make-items [first : i64] [second : i64]) : (__tl_dyn-array i64)
  (let
    [items : (__tl_dyn-array i64) (make-array i64 2)]
    (begin
      (array-set! items 0 first)
      (array-set! items 1 second)
      items)))")

(define (selfhost-lint-dynamic-array-literal-read-before-complete-source) : String
  "(define (make-items) : (__tl_dyn-array i64)
  (let
    [items : (__tl_dyn-array i64) (make-array i64 2)]
    (begin
      (array-set! items 0 4)
      (array-ref items 0)
      (array-set! items 1 7)
      items)))")

(define (selfhost-lint-dynamic-array-literal-computed-index-source) : String
  "(define (make-items [index : i64]) : (__tl_dyn-array i64)
  (let
    [items : (__tl_dyn-array i64) (make-array i64 2)]
    (begin
      (array-set! items index 4)
      (array-set! items 1 7)
      items)))")

(define (selfhost-lint-dynamic-array-literal-duplicate-index-source) : String
  "(define (make-items) : (__tl_dyn-array i64)
  (let
    [items : (__tl_dyn-array i64) (make-array i64 3)]
    (begin
      (array-set! items 0 4)
      (array-set! items 0 7)
      (array-set! items 2 9)
      items)))")

(define (selfhost-lint-dynamic-array-literal-gapped-index-source) : String
  "(define (make-items) : (__tl_dyn-array i64)
  (let
    [items : (__tl_dyn-array i64) (make-array i64 3)]
    (begin
      (array-set! items 0 4)
      (array-set! items 2 7)
      (array-set! items 1 9)
      items)))")

(define (selfhost-lint-dynamic-array-literal-partial-source) : String
  "(define (make-items) : (__tl_dyn-array i64)
  (let
    [items : (__tl_dyn-array i64) (make-array i64 2)]
    (begin
      (array-set! items 0 4)
      items)))")

(define (selfhost-lint-dynamic-array-literal-escape-source) : String
  "(define (consume [items : (__tl_dyn-array i64)]) : unit unit)
(define (make-items) : (__tl_dyn-array i64)
  (let
    [items : (__tl_dyn-array i64) (make-array i64 2)]
    (begin
      (array-set! items 0 4)
      (consume items)
      (array-set! items 1 7)
      items)))")

(define (selfhost-lint-dynamic-array-literal-suppressed-source) : String
  "(define (make-items) : (__tl_dyn-array i64)
  (let
    ;; lint-allow: prefer-dynamic-array-literal
    [items : (__tl_dyn-array i64) (make-array i64 2)]
    (begin
      (array-set! items 0 4)
      (array-set! items 1 7)
      items)))")

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
      (lint_svec.new))))

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
      (lint_svec.new))
    rule-id))

(define (selfhost-lint-unused-import-finding-ok? [findings : LintFindings]) : bool
  (match (lint-findings-get findings 0)
    [(LintMaybeFinding.Some finding)
      (let
        [fspan : AstSourceSpan (struct-get finding span)]
        (and
          (= (lint-findings-count findings) 1)
          (> (ast-source-span-start-line fspan) 0)
          (string.eq (struct-get finding rule-id) (lint-rule-unused-import-id))))]
    [(LintMaybeFinding.No) false]))

(define (selfhost-lint-unused-imports-self-test) : i64
  (let
    [unused : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-unused-dotted-import-source)
        (lint_svec.new))]
    [unused-path-alias : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-unused-explicit-path-alias-source)
        (lint_svec.new))]
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
        (SelfhostLintDeadScan (selfhost-lint-dead-decls-empty) (lint_svec.new))
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

(define (selfhost-lint-package-dead-code-test-root-fixture-decls) : SelfhostLintDeadDecls
  (let
    [entry-source : String (selfhost-lint-package-dead-entry-source)]
    [test-source : String (selfhost-lint-package-dead-test-root-source)]
    [scan-entry : SelfhostLintDeadScan
      (selfhost-lint-dead-scan-source
        (SelfhostLintDeadScan (selfhost-lint-dead-decls-empty) (lint_svec.new))
        "pkg/src/main.tl"
        entry-source
        false
        true)]
    [scan-test : SelfhostLintDeadScan
      (selfhost-lint-dead-scan-source
        scan-entry
        "pkg/src/tests/entry_smoke.tl"
        test-source
        false
        false)]
    [scan : SelfhostLintDeadScan
      (selfhost-lint-package-dead-add-kind-roots scan-test CompilerPkgKindBin)]
    (selfhost-lint-dead-mark-roots-from
      (struct-get scan decls)
      (struct-get scan roots)
      0)))

(define (selfhost-lint-package-dead-code-manifest-root-fixture-decls) : SelfhostLintDeadDecls
  (let
    [manifest-dir : String "pkg"]
    [path : String
      (compiler-load-normalize-path
        (compiler-load-join-root-path manifest-dir "src/manifest_api.tl"))]
    [source : String (selfhost-lint-package-dead-manifest-root-source)]
    [roots : lint_svec.Vec
      (selfhost-lint-dead-manifest-roots
        (selfhost-lint-package-dead-manifest-root-manifest)
        manifest-dir)]
    [scan-source : SelfhostLintDeadScan
      (selfhost-lint-dead-scan-source
        (SelfhostLintDeadScan (selfhost-lint-dead-decls-empty) (lint_svec.new))
        path
        source
        false
        true)]
    [scan : SelfhostLintDeadScan
      (selfhost-lint-dead-scan-add-roots scan-source roots)]
    (selfhost-lint-dead-mark-roots-from
      (struct-get scan decls)
      (struct-get scan roots)
      0)))

(define (selfhost-lint-package-dead-code-explicit-root-fixture-decls) : SelfhostLintDeadDecls
  (let
    [source : String (selfhost-lint-package-dead-explicit-root-source)]
    [scan-source : SelfhostLintDeadScan
      (selfhost-lint-dead-scan-source
        (SelfhostLintDeadScan (selfhost-lint-dead-decls-empty) (lint_svec.new))
        "pkg/explicit_api.tl"
        source
        false
        true)]
    [scan : SelfhostLintDeadScan
      (selfhost-lint-package-dead-add-kind-roots scan-source CompilerPkgKindBin)]
    (selfhost-lint-dead-mark-roots-from
      (struct-get scan decls)
      (struct-get scan roots)
      0)))

(define (selfhost-lint-package-dead-code-cfg-fixture-decls) : SelfhostLintDeadDecls
  (let
    [source : String (selfhost-lint-package-dead-cfg-source)]
    [scan-source : SelfhostLintDeadScan
      (selfhost-lint-dead-scan-source
        (SelfhostLintDeadScan (selfhost-lint-dead-decls-empty) (lint_svec.new))
        "pkg/cfg.tl"
        source
        false
        true)]
    [scan : SelfhostLintDeadScan
      (selfhost-lint-package-dead-add-kind-roots scan-source CompilerPkgKindBin)]
    (selfhost-lint-dead-mark-roots-from
      (struct-get scan decls)
      (struct-get scan roots)
      0)))

(define (selfhost-lint-package-dead-qualified-import-fixture-decls) : SelfhostLintDeadDecls
  (let
    [left-source : String (selfhost-lint-package-dead-qualified-left-source)]
    [right-source : String (selfhost-lint-package-dead-qualified-right-source)]
    [main-source : String (selfhost-lint-package-dead-qualified-main-source)]
    [scan-left : SelfhostLintDeadScan
      (selfhost-lint-dead-scan-source
        (SelfhostLintDeadScan (selfhost-lint-dead-decls-empty) (lint_svec.new))
        "pkg/left.tl"
        left-source
        false
        true)]
    [scan-right : SelfhostLintDeadScan
      (selfhost-lint-dead-scan-source
        scan-left
        "pkg/right.tl"
        right-source
        false
        true)]
    [scan-main : SelfhostLintDeadScan
      (selfhost-lint-dead-scan-source
        scan-right
        "pkg/main.tl"
        main-source
        false
        true)]
    [scan : SelfhostLintDeadScan
      (selfhost-lint-package-dead-add-kind-roots scan-main CompilerPkgKindBin)]
    (selfhost-lint-dead-mark-roots-from
      (struct-get scan decls)
      (struct-get scan roots)
      0)))

(define (selfhost-lint-package-dead-moduleless-import-fixture-decls) : SelfhostLintDeadDecls
  (let
    [left-source : String (selfhost-lint-package-dead-moduleless-left-source)]
    [right-source : String (selfhost-lint-package-dead-moduleless-right-source)]
    [main-source : String (selfhost-lint-package-dead-moduleless-main-source)]
    [scan-left : SelfhostLintDeadScan
      (selfhost-lint-dead-scan-source
        (SelfhostLintDeadScan (selfhost-lint-dead-decls-empty) (lint_svec.new))
        "pkg/left.tl"
        left-source
        false
        true)]
    [scan-right : SelfhostLintDeadScan
      (selfhost-lint-dead-scan-source
        scan-left
        "pkg/right.tl"
        right-source
        false
        true)]
    [scan-main : SelfhostLintDeadScan
      (selfhost-lint-dead-scan-source
        scan-right
        "pkg/main.tl"
        main-source
        false
        true)]
    [scan : SelfhostLintDeadScan
      (selfhost-lint-package-dead-add-kind-roots scan-main CompilerPkgKindBin)]
    (selfhost-lint-dead-mark-roots-from
      (struct-get scan decls)
      (struct-get scan roots)
      0)))

(define (selfhost-lint-package-dead-import-closure-fixture-ok?) : bool
  (let
    [root : String "target/lint_dead_root_import_closure"]
    [src-dir : String (compiler-load-join-root-path root "src")]
    [test-dir : String (compiler-load-join-root-path src-dir "tests")]
    [manifest-path : String (compiler-load-join-root-path root "typelisp.pkg")]
    [main-path : String (compiler-load-join-root-path src-dir "main.tl")]
    [core-path : String (compiler-load-join-root-path src-dir "core.tl")]
    [test-path : String
      (compiler-load-join-root-path test-dir "imported_smoke.tl")]
    [second-test-path : String
      (compiler-load-join-root-path test-dir "second_imported_smoke.tl")]
    (begin
      (compiler-load-test-mkdir root)
      (compiler-load-test-mkdir src-dir)
      (compiler-load-test-mkdir test-dir)
      (selfhost-lint-write-text
        manifest-path
        "(package
  (name \"lint-dead-root-import-closure\")
  (version \"1\")
  (kind \"bin\"))")
      (selfhost-lint-write-text
        main-path
        "(import \"core.tl\")
(define (main) : i64
  (core-entry))")
      (selfhost-lint-write-text
        core-path
        "(define (core-entry) : i64 7)
(define (core-test-helper) : i64 42)
(define (core-second-test-helper) : i64 43)
(define (core-unused) : i64 13)")
      (selfhost-lint-write-text
        test-path
        "(import core)
(define (main) : i64
  (core-test-helper))")
      (selfhost-lint-write-text
        second-test-path
        "(import core)
(define (main) : i64
  (core-second-test-helper))")
      (match (package-source-discover-for "lint" manifest-path true)
        [(ResultPackageSourceSet.Err _) false]
        [(ResultPackageSourceSet.Ok source-set)
          (match (selfhost-lint-package-dead-sources source-set (lint_svec.new))
            [(ResultSelfhostLintDeadSources.Err _) false]
            [(ResultSelfhostLintDeadSources.Ok dead-source-set)
              (let
                [roots : lint_svec.Vec
                  (selfhost-lint-package-import-roots
                    source-set
                    (lint_svec.new))]
                [dead-decls : SelfhostLintDeadDecls
                  (selfhost-lint-package-dead-code
                    dead-source-set
                    roots
                    (struct-get (struct-get source-set manifest) kind))]
                [core-count : i64
                  (selfhost-lint-package-dead-count-for-source
                    (compiler-load-normalize-path core-path)
                    (byte_buf.to-string (io.read-file core-path))
                    dead-decls)]
                (and
                  (lint_svec.contains?
                    (& roots)
                    (compiler-load-normalize-path src-dir))
                  (= core-count 1)))])]))))

(define (selfhost-lint-package-dead-code-self-test) : i64
  (let
    [source-a : String (selfhost-lint-package-dead-source-a)]
    [source-b : String (selfhost-lint-package-dead-source-b)]
    [cfg-source : String (selfhost-lint-package-dead-cfg-source)]
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
    [test-root-decls : SelfhostLintDeadDecls
      (selfhost-lint-package-dead-code-test-root-fixture-decls)]
    [test-root-count : i64
      (selfhost-lint-package-dead-count-for-source
        "pkg/src/main.tl"
        (selfhost-lint-package-dead-entry-source)
        test-root-decls)]
    [manifest-root-source : String
      (selfhost-lint-package-dead-manifest-root-source)]
    [manifest-root-decls : SelfhostLintDeadDecls
      (selfhost-lint-package-dead-code-manifest-root-fixture-decls)]
    [manifest-root-count : i64
      (selfhost-lint-package-dead-count-for-source
        (compiler-load-normalize-path
          (compiler-load-join-root-path "pkg" "src/manifest_api.tl"))
        manifest-root-source
        manifest-root-decls)]
    [explicit-root-source : String
      (selfhost-lint-package-dead-explicit-root-source)]
    [explicit-root-decls : SelfhostLintDeadDecls
      (selfhost-lint-package-dead-code-explicit-root-fixture-decls)]
    [explicit-root-count : i64
      (selfhost-lint-package-dead-count-for-source
        "pkg/explicit_api.tl"
        explicit-root-source
        explicit-root-decls)]
    [cfg-bin-decls : SelfhostLintDeadDecls
      (selfhost-lint-package-dead-code-cfg-fixture-decls)]
    [cfg-bin-count : i64
      (selfhost-lint-package-dead-count-for-source
        "pkg/cfg.tl"
        cfg-source
        cfg-bin-decls)]
    [ordinary-mode-index : i64
      (selfhost-lint-dead-decls-index-of cfg-bin-decls "ordinary-mode-helper")]
    [qualified-import-decls : SelfhostLintDeadDecls
      (selfhost-lint-package-dead-qualified-import-fixture-decls)]
    [qualified-left-count : i64
      (selfhost-lint-package-dead-count-for-source
        "pkg/left.tl"
        (selfhost-lint-package-dead-qualified-left-source)
        qualified-import-decls)]
    [qualified-right-count : i64
      (selfhost-lint-package-dead-count-for-source
        "pkg/right.tl"
        (selfhost-lint-package-dead-qualified-right-source)
        qualified-import-decls)]
    [moduleless-import-decls : SelfhostLintDeadDecls
      (selfhost-lint-package-dead-moduleless-import-fixture-decls)]
    [moduleless-left-count : i64
      (selfhost-lint-package-dead-count-for-source
        "pkg/left.tl"
        (selfhost-lint-package-dead-moduleless-left-source)
        moduleless-import-decls)]
    [moduleless-right-count : i64
      (selfhost-lint-package-dead-count-for-source
        "pkg/right.tl"
        (selfhost-lint-package-dead-moduleless-right-source)
        moduleless-import-decls)]
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
      [(not (= test-root-count 1)) 57]
      [(not (= manifest-root-count 1)) 62]
      ;; The explicit API and its dependency stay live. The prefix-colliding
      ;; declaration and the unrelated sibling remain dead.
      [(not (= explicit-root-count 2)) 63]
      ;; Supported scratch, embedded-TLCI, and profile cfgs reach their live
      ;; helpers and retain one dead declaration each. The ordinary
      ;; compile-profile fallback also stays live. The inactive experimental
      ;; cfg stays absent; the unrelated ordinary bin-local declaration is
      ;; still dead.
      [(not (= cfg-bin-count 4)) 61]
      [(or
          (< ordinary-mode-index 0)
          (not
            (struct-get
              (selfhost-lint-dead-decls-ref cfg-bin-decls ordinary-mode-index)
              root)))
        66]
      [(not (selfhost-lint-package-dead-import-closure-fixture-ok?)) 58]
      [(not (= qualified-left-count 1)) 59]
      [(not (= qualified-right-count 0)) 60]
      ;; Moduleless dotted imports use their path-derived default aliases.
      ;; Duplicate declaration/helper names in both imported modules remain
      ;; distinct, while each unrelated sibling remains dead.
      [(not (= moduleless-left-count 1)) 64]
      [(not (= moduleless-right-count 1)) 65]
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

(define (selfhost-lint-dynamic-array-literal-self-test) : i64
  (let
    [rule : String (lint-rule-prefer-dynamic-array-literal-id)]
    (cond
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-dynamic-array-literal-dotted-source)
              rule)
            1))
        140]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-dynamic-array-literal-bare-source)
              rule)
            1))
        141]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-dynamic-array-literal-return-source)
              rule)
            1))
        152]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-dynamic-array-literal-assignment-source)
              rule)
            1))
        153]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-dynamic-array-literal-ambiguous-two-var-source)
              rule)
            0))
        149]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-dynamic-array-literal-read-before-complete-source)
              rule)
            0))
        142]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-dynamic-array-literal-computed-index-source)
              rule)
            0))
        143]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-dynamic-array-literal-duplicate-index-source)
              rule)
            0))
        150]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-dynamic-array-literal-gapped-index-source)
              rule)
            0))
        151]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-dynamic-array-literal-partial-source)
              rule)
            0))
        144]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-dynamic-array-literal-escape-source)
              rule)
            0))
        145]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-dynamic-array-literal-suppressed-source)
              rule)
            0))
        146]
      [(not
          (string.eq
            (lint-rule-message rule)
            (lint-rule-prefer-dynamic-array-literal-message)))
        147]
      [(not
          (string.eq
            (lint-rule-suggestion rule)
            (lint-rule-prefer-dynamic-array-literal-suggestion)))
        148]
      [else 42])))

;; Compatibility helper retained for the nested-if-ladder metadata shape.
(define (selfhost-lint-reported-finding-ok?
  [findings : LintFindings]
  [depth : i64]
  [message : String]) : bool
  (match (lint-findings-get findings 0)
    [(LintMaybeFinding.Some finding)
      (let
        [fspan : AstSourceSpan (struct-get finding span)]
        (and
          (= (struct-get finding depth) depth)
          (> (ast-source-span-start-line fspan) 0)
          (string.eq
            (struct-get finding rule-id)
            (lint-rule-nested-if-ladder-id))
          (string.eq (struct-get finding message) message)))]
    [(LintMaybeFinding.No) false]))

(define (selfhost-lint-nested-let-finding-ok? [findings : LintFindings]) : bool
  (match (lint-findings-get findings 0)
    [(LintMaybeFinding.Some finding)
      (let
        [fspan : AstSourceSpan (struct-get finding span)]
        (and
          (> (ast-source-span-start-line fspan) 0)
          (string.eq (struct-get finding rule-id) (lint-rule-nested-let-id))))]
    [(LintMaybeFinding.No) false]))

(define (selfhost-lint-return-path-finding-ok? [findings : LintFindings]) : bool
  (match (lint-findings-get findings 0)
    [(LintMaybeFinding.Some finding)
      (let
        [fspan : AstSourceSpan (struct-get finding span)]
        (and
          (= (struct-get finding depth) 3)
          (> (ast-source-span-start-line fspan) 0)
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
          (> (ast-source-span-start-line fspan) 0)
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
          (> (ast-source-span-start-line fspan) 0)
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

(define (compiler-lint-driver-self-test) : i64
  (let
    [reported : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-ladder-source)
        (lint_svec.new))]
    [guard-reported : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-guard-ladder-source)
        (lint_svec.new))]
    [return-reported : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-return-path-chain-source)
        (lint_svec.new))]
    [all-exit-ladder-reported : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-all-exit-ladder-source)
        (lint_svec.new))]
    [unit-reported : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-unit-if-source)
        (lint_svec.new))]
    [unit-set-reported : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-unit-set-source)
        (lint_svec.new))]
    [two-reported : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-two-findings-source)
        (lint_svec.new))]
    [cascading-and-reported : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-cascading-and-source)
        (lint_svec.new))]
    [cascading-or-reported : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-cascading-or-source)
        (lint_svec.new))]
    [cascading-core-and-reported : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-cascading-core-and-source)
        (lint_svec.new))]
    [transitional-core-reported : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-transitional-core-macro-source)
        (lint_svec.new))]
    (cond
      [(or
          (not (= (lint-findings-count reported) 1))
          (not
            (selfhost-lint-reported-finding-ok?
              reported
              5
              (lint-rule-nested-if-ladder-value-message))))
        1]
      [(or
          (not (= (lint-findings-count guard-reported) 1))
          (not
            (selfhost-lint-reported-finding-ok?
              guard-reported
              3
              (lint-rule-nested-if-ladder-guard-message))))
        70]
      [(not (= (lint-findings-count return-reported) 1)) 9]
      [(not (selfhost-lint-return-path-finding-ok? return-reported)) 10]
      [(not
          (=
            (selfhost-lint-findings-rule-count
              all-exit-ladder-reported
              (lint-rule-nested-if-ladder-id))
            0))
        41]
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
              (lint_svec.new))))
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