;; lint_driver_core.tl - Driver logic for the selfhost `typelisp lint` tool:
;; load a TypeLisp source, run the lint_core rules over its program, and
;; render each finding through the shared source diagnostic renderer. Kept
;; main-less so both the CLI dispatcher (`main.tl`) and the runnable smoke
;; (`lint_driver_smoke.tl`) can import it. Warn-only by default; callers can pass
;; `--check` after the input path to exit non-zero when findings remain, or
;; `--format flat` for the stable `path:line:col: message` machine format. The
;; deprecated string.concat rule and staged migration rules are opt-in.
(import compiler_owned_view as owned_view)
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
(import cli_option_core as cli_option)
(import lint_core)
(import lint_policy_core as lint_policy)
(import package_source_core)
(import stdlib.string)
(import source_text_core as source_text)
(import sym_i64_env)

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
(define selfhost-lint-flat-output : bool
  false)

;: Translate the staged lint switches into the shared typed policy without
;: changing the legacy `--check` enforcement or renderer behavior.
(define (selfhost-lint-compatibility-policy
  [deprecated-string-concat : bool]
  [redundant-function-name : bool]
  [prefer-dotted-field : bool]
  [name-case : bool]) : lint_policy.LintPolicyResolution
  (lint_policy.lint-policy-legacy-resolution
    deprecated-string-concat
    redundant-function-name
    prefer-dotted-field
    name-case))

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
    (set! selfhost-lint-flat-output false)))

(define (selfhost-lint-language-cfgs) : sym_i64_env.SymI64Env
  (target_cfg.compiler-target-cfgs-with-names
    selfhost-lint-language-target
    (unsafe
      (ptr-read (ptr-addr-of selfhost-lint-language-cfg-names)))))

;; Parse the `lint` config from arguments starting at `start`.
(define (selfhost-lint-config-from [start : i64] [count : i64]) : ResultSelfhostLintConfig
  (let
    [args : cli_option.CliArgs
      (begin
        (selfhost-lint-language-config-reset!)
        (cli_option.cli-args
          "selfhost-lint"
          "--check --deprecated-string-concat --redundant-function-name
           --prefer-dotted-field --name-case --format <rich|flat> --cfg <name>
           --target <target> --stdlib-root <dir> --manifest-path <file>"
          start
          count))]
    [input-paths : lint_svec.Vec (lint_svec.new)]
    [manifest-path : String ""]
    [has-manifest : bool false]
    [has-target : bool false]
    [stdlib-roots : lint_svec.Vec (lint_svec.new)]
    [enforcing : bool false]
    [deprecated-string-concat : bool false]
    [redundant-function-name : bool false]
    [prefer-dotted-field : bool false]
    [name-case : bool false]
    (begin
      (while (cli_option.cli-args-next! (&mut args))
        (cond
          [(string.eq args.name "--check") (set! enforcing true)]
          [(string.eq args.name "--deprecated-string-concat")
            (set! deprecated-string-concat true)]
          [(string.eq args.name "--redundant-function-name")
            (set! redundant-function-name true)]
          [(string.eq args.name "--prefer-dotted-field")
            (set! prefer-dotted-field true)]
          [(string.eq args.name "--name-case") (set! name-case true)]
          [(string.eq args.name "--format")
            (let
              [format : String (cli_option.cli-args-value (& args))]
              (cond
                [(string.eq format "flat")
                  (set! selfhost-lint-flat-output true)]
                [(string.eq format "rich")
                  (set! selfhost-lint-flat-output false)]
                [else
                  (cli_option.cli-args-fail!
                    (&mut args)
                    (str_cat.str-cat
                      "selfhost-lint: unsupported --format "
                      format
                      " (expected rich or flat)"))]))]
          [(string.eq args.name "--cfg")
            (lint_svec.push-ref!
              (&mut selfhost-lint-language-cfg-names)
              (cli_option.cli-args-value (& args)))]
          [(string.eq args.name "--target")
            (if has-target
              (cli_option.cli-args-fail!
                (&mut args)
                "selfhost-lint: --target was provided more than once")
              (match (target_cfg.compiler-target-cfg-parse
                (cli_option.cli-args-value (& args)))
                [(target_cfg.ResultCompilerTargetCfg.Ok parsed-target)
                  (begin
                    (set! selfhost-lint-language-target parsed-target)
                    (set! has-target true))]
                [(target_cfg.ResultCompilerTargetCfg.Err message)
                  (cli_option.cli-args-fail!
                    (&mut args)
                    (str_cat.str-cat "selfhost-lint: " message))]))]
          [(string.eq args.name "--stdlib-root")
            (lint_svec.push-ref!
              (&mut stdlib-roots)
              (cli_option.cli-args-value (& args)))]
          [(string.eq args.name "--manifest-path")
            (if has-manifest
              (cli_option.cli-args-fail!
                (&mut args)
                "selfhost-lint: duplicate --manifest-path")
              (begin
                (set! manifest-path (cli_option.cli-args-value (& args)))
                (set! has-manifest true)))]
          [(cli_option.cli-flag? args.arg)
            (cli_option.cli-args-fail-arg!
              (&mut args)
              "selfhost-lint: unknown flag ")]
          [else
            (lint_svec.push-ref! (&mut input-paths) (string.copy (& args.arg)))]))
      (cond
        [args.failed (ResultSelfhostLintConfig.Err args.error)]
        [(lint_svec.is-empty? (& input-paths))
          (ResultSelfhostLintConfig.Ok
            (SelfhostLintConfig.Package
              manifest-path
              has-manifest
              stdlib-roots
              enforcing
              deprecated-string-concat
              redundant-function-name
              prefer-dotted-field
              name-case))]
        [has-manifest
          (ResultSelfhostLintConfig.Err
            "selfhost-lint: cannot combine input paths with --manifest-path")]
        [else
          (ResultSelfhostLintConfig.Ok
            (SelfhostLintConfig.File
              input-paths
              stdlib-roots
              enforcing
              deprecated-string-concat
              redundant-function-name
              prefer-dotted-field
              name-case))]))))

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
    [diagnostic : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-with-help
        (cdiag.compiler-diagnostic-with-code
          (cdiag.compiler-diagnostic-with-level
            (cdiag.compiler-diagnostic-from-ast-span path fspan finding.message)
            cdiag.CompilerDiagnosticWarning)
          rule-id)
        suggestion)]
    (match finding.fix
      [(lint_core.LintFixAvailable fix)
        (cdiag.compiler-diagnostic-with-fix diagnostic fix)]
      [(lint_core.LintFixUnavailable _ _) diagnostic])))

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
;; Findings are stored in discovery order; render backward, newest first, to
;; keep the established output order.
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
          (owned_view.compiler-owned-shared-view path)
          (owned_view.compiler-owned-shared-view source)
          (lint_core.lint-findings-ref
            (owned_view.compiler-owned-shared-view items)
            index)))
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
    (owned_view.compiler-owned-shared-view items)
    (- (lint_core.lint-findings-count items) 1)
    0))

(define (selfhost-lint-form-delim? [source : (& source str)] [idx : i64]) : bool
  (let
    [source-len : i64 (string.string-length source)]
    (if (>= idx source-len)
      true
      (let
        [c : char (string.string-ref source idx)]
        (or (source_text.source-text-space? c) (= c ')'))))))

(define (selfhost-lint-line-start-index
  [source : (& source str)]
  [target-line : i64]) : i64
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
  [source : (& source str)]
  [span : ast.AstSourceSpan]) : i64
  (+
    (selfhost-lint-line-start-index
      source
      (ast.ast-source-span-start-line span))
    (- (ast.ast-source-span-start-col span) 1)))

(define (selfhost-lint-skip-ws-comments
  [source : (& source str)]
  [idx : i64]
  [n : i64]) : i64
  (let
    [j : i64 idx]
    [done : bool false]
    (begin
      (while (and (< j n) (not done))
        (let
          [c : char (string.string-ref source j)]
          (cond
            [(source_text.source-text-space? c) (set! j (+ j 1))]
            [(= c ';') (set! j (source_text.source-text-skip-line source j n))]
            [else (set! done true)])))
      j)))

(define (selfhost-lint-source-form-delim? [c : char]) : bool
  (or
    (source_text.source-text-space? c)
    (= c '(')
    (= c ')')
    (= c '[')
    (= c ']')
    (= c ';')))

(define (selfhost-lint-skip-atom
  [source : (& source str)]
  [idx : i64]
  [n : i64]) : i64
  (let
    [j : i64 idx]
    (begin
      (while (and
        (< j n)
        (not (selfhost-lint-source-form-delim? (string.string-ref source j))))
        (set! j (+ j 1)))
      j)))

(define (selfhost-lint-skip-source-group
  [source : (& source str)]
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
            [(= c ';') (set! j (source_text.source-text-skip-line source j n))]
            [(= c '"')
              (set! j (source_text.source-text-skip-string source j n))]
            [(= c '\'')
              (set! j (source_text.source-text-skip-char-literal source j n))]
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

(define (selfhost-lint-skip-source-form
  [source : (& source str)]
  [idx : i64]
  [n : i64]) : i64
  (let
    [j : i64 (selfhost-lint-skip-ws-comments source idx n)]
    (if (>= j n)
      j
      (let
        [c : char (string.string-ref source j)]
        (cond
          [(or (= c '(') (= c '['))
            (selfhost-lint-skip-source-group source j n)]
          [(= c '"') (source_text.source-text-skip-string source j n)]
          [(= c '\'') (source_text.source-text-skip-char-literal source j n)]
          [else (selfhost-lint-skip-atom source j n)])))))

(define (selfhost-lint-begin-source-form-count
  [source : (& source str)]
  [span : ast.AstSourceSpan]) : i64
  (let
    [start : i64 (selfhost-lint-span-start-index source span)]
    [n : i64 (string.string-length source)]
    [needle : String "(begin"]
    [needle-len : i64 (string.string-length needle)]
    (if (and
      (string.is-string-prefix-at source needle start)
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
  [source : (& source str)]
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
          (if (string.is-string-prefix-at source needle idx)
            (begin
              (set! found true)
              (set! stop true))
            (set! idx (+ idx 1)))))
      found)))

;; A finding is suppressed when the line immediately above its flagged form
;; carries `;; lint-allow: <its-rule-id>`. Findings on line 1 have no line above
;; and cannot be suppressed this way.
(define (selfhost-lint-suppressed?
  [source : (& source str)]
  [finding : lint_core.LintFinding]) : bool
  (let
    [span : ast.AstSourceSpan finding.span]
    [line : i64 (ast.ast-source-span-start-line span)]
    [rule-id : String finding.rule-id]
    (if (<= line 1)
      false
      (selfhost-lint-line-allows? source (- line 1) rule-id))))

(define (selfhost-lint-form-origin?
  [source : (& source str)]
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
          (string.is-string-prefix-at source needle idx)
          (selfhost-lint-form-delim?
            source
            (+ idx (string.string-length needle))))))))

(define (selfhost-lint-derived-form-origin?
  [source : (& source str)]
  [span : ast.AstSourceSpan]) : bool
  (or
    (selfhost-lint-form-origin? source span "cond")
    (selfhost-lint-form-origin? source span "when")
    (selfhost-lint-form-origin? source span "unless")))

(define (selfhost-lint-source-multiform-single-begin?
  [source : (& source str)]
  [finding : lint_core.LintFinding]) : bool
  (and
    (string.eq finding.rule-id (lint_core.lint-rule-single-begin-id))
    (> (selfhost-lint-begin-source-form-count source finding.span) 1)))

(define (selfhost-lint-path-suffix-at?
  [path : (& path str)]
  [suffix : String]
  [base : i64]
  [index : i64]) : bool
  (if (>= index (string.string-length suffix))
    true
    (let
      [left : char (string.string-ref path (+ base index))]
      [right : char (string.string-ref suffix index)]
      (if (or
        (= left right)
        (and (or (= left '/') (= left '\\')) (or (= right '/') (= right '\\'))))
        (selfhost-lint-path-suffix-at? path suffix base (+ index 1))
        false))))

(define (selfhost-lint-path-suffix? [path : (& path str)] [suffix : String]) : bool
  (let
    [path-len : i64 (string.string-length path)]
    [suffix-len : i64 (string.string-length suffix)]
    [base : i64 (- path-len suffix-len)]
    (and
      (>= base 0)
      (or
        (= base 0)
        (let
          [separator : char (string.string-ref path (- base 1))]
          (or (= separator '/') (= separator '\\'))))
      (selfhost-lint-path-suffix-at? path suffix base 0))))

;; Audited raw-arena module allowlist. It holds the line established by #6253;
;; #6620 owns classification/migration of the residual entries and should only
;; shrink this exact module set. Deliberate runtime-protocol fixtures stay
;; explicit so a new test or source module cannot silently inherit permission.
(define (selfhost-lint-raw-arena-op-allowlisted? [path : (& path str)]) : bool
  (or
    (selfhost-lint-path-suffix? path "src/compile_cli_core.tl")
    (selfhost-lint-path-suffix? path "src/compiler_ast_types.tl")
    (selfhost-lint-path-suffix? path "src/compiler_backend_tests.tl")
    (selfhost-lint-path-suffix? path "src/compiler_backend.tl")
    ;; The advisory sink owns a lazily allocated payload arena and destroys it
    ;; at the explicit per-job reset boundary.
    (selfhost-lint-path-suffix? path "src/compiler_diagnostic.tl")
    (selfhost-lint-path-suffix? path "src/compiler_driver_core.tl")
    (selfhost-lint-path-suffix? path "src/compiler_driver_smoke_tests.tl")
    (selfhost-lint-path-suffix? path "src/compiler_intern.tl")
    (selfhost-lint-path-suffix? path "src/compiler_ir_types.tl")
    (selfhost-lint-path-suffix? path "src/compiler_load.tl")
    (selfhost-lint-path-suffix? path "src/compiler_lower_tests.tl")
    (selfhost-lint-path-suffix? path "src/compiler_lower.tl")
    (selfhost-lint-path-suffix? path "src/compiler_optimize_tests.tl")
    (selfhost-lint-path-suffix? path "src/compiler_optimize.tl")
    (selfhost-lint-path-suffix? path "src/compiler_semantic_index.tl")
    (selfhost-lint-path-suffix? path "src/compiler_symbols.tl")
    (selfhost-lint-path-suffix? path "src/compiler_typecheck_core.tl")
    (selfhost-lint-path-suffix? path "src/lex.tl")
    (selfhost-lint-path-suffix? path "src/lint_driver_core.tl")
    (selfhost-lint-path-suffix? path "src/lsp_frame_core.tl")
    (selfhost-lint-path-suffix? path "src/read.tl")
    (selfhost-lint-path-suffix? path "src/test_cli_core.tl")
    (selfhost-lint-path-suffix? path "src/tests/compiler_ast_types_smoke.tl")
    (selfhost-lint-path-suffix? path "src/tests/compiler_ir_types_smoke.tl")
    (selfhost-lint-path-suffix?
      path
      "src/tests/compiler_typecheck_core_tests.tl")
    (selfhost-lint-path-suffix?
      path
      "src/tests/compiler_typecheck_list_storage_unit.tl")
    (selfhost-lint-path-suffix? path "src/tlci_loader.tl")
    (selfhost-lint-path-suffix? path "stdlib/arena.tl")
    (selfhost-lint-path-suffix? path "stdlib/tests/arena_atomic_api.tl")
    (selfhost-lint-path-suffix? path "tests/integration/arena_escape_stress.tl")
    (selfhost-lint-path-suffix?
      path
      "tests/integration/arena_growth_stable_handle.tl")
    (selfhost-lint-path-suffix?
      path
      "tests/integration/arena_lazy_singleton_raw_addr_escape.tl")
    (selfhost-lint-path-suffix?
      path
      "tests/integration/arena_poison_clone_survives.tl")
    (selfhost-lint-path-suffix?
      path
      "tests/integration/arena_poison_stale_array_trap.tl")
    (selfhost-lint-path-suffix?
      path
      "tests/integration/arena_pool_context_escape.tl")
    (selfhost-lint-path-suffix?
      path
      "tests/integration/arena_rewind_make_array_zero.tl")
    (selfhost-lint-path-suffix? path "tests/integration/atomic_thread_spawn.tl")
    (selfhost-lint-path-suffix? path "tests/integration/clone_deep_copy.tl")
    (selfhost-lint-path-suffix?
      path
      "tests/integration/clone_dynarray_scalar_bulk.tl")
    (selfhost-lint-path-suffix?
      path
      "tests/integration/compiler_arena_debug.tl")
    (selfhost-lint-path-suffix?
      path
      "tests/integration/make_array_default_reads_zero.tl")
    (selfhost-lint-path-suffix?
      path
      "tests/integration/mem_fill8_runtime_contract.tl")
    (selfhost-lint-path-suffix?
      path
      "tests/integration/region_reset_discard.tl")
    (selfhost-lint-path-suffix?
      path
      "tests/integration/region_reset_invalid_trap.tl")
    (selfhost-lint-path-suffix?
      path
      "tests/integration/region_reset_overflow_retains.tl")
    (selfhost-lint-path-suffix?
      path
      "tests/integration/region_reset_preserve.tl")
    (selfhost-lint-path-suffix? path "tests/integration/region_reset_zero.tl")
    (selfhost-lint-path-suffix? path "tests/integration/sym_i64_env.tl")
    (selfhost-lint-path-suffix?
      path
      "tests/integration/with_escape_clone_out.tl")
    (selfhost-lint-path-suffix?
      path
      "tools/embedded-stdlib-tlci/prelude_surface_producer.tl")))

(define (selfhost-lint-filter-derived-origins-from
  [path : (& path str)]
  [source : (& source str)]
  [items : lint_core.LintFindings]
  [index : i64]
  [raw-arena-allowlisted : bool]
  [out : lint_core.LintFindings]) : lint_core.LintFindings
  (if (>=
    index
    (lint_core.lint-findings-count
      (owned_view.compiler-owned-shared-view items)))
    out
    (let
      [finding : lint_core.LintFinding
        (lint_core.lint-findings-ref
          (owned_view.compiler-owned-shared-view items)
          index)]
      [next : lint_core.LintFindings
        (if (or
          (selfhost-lint-derived-form-origin? source finding.span)
          (selfhost-lint-source-multiform-single-begin?
            source
            (owned_view.compiler-owned-shared-view finding))
          (selfhost-lint-suppressed?
            source
            (owned_view.compiler-owned-shared-view finding))
          (and
            (string.eq finding.rule-id (lint_core.lint-rule-raw-arena-op-id))
            raw-arena-allowlisted))
          out
          (lint_core.lint-findings-add finding out))]
      (selfhost-lint-filter-derived-origins-from
        path
        source
        items
        (+ index 1)
        raw-arena-allowlisted
        next))))

(define (selfhost-lint-findings-have-rule-from?
  [items : lint_core.LintFindings]
  [rule-id : String]
  [index : i64]) : bool
  (if (>=
    index
    (lint_core.lint-findings-count
      (owned_view.compiler-owned-shared-view items)))
    false
    (if (string.eq
      (lint_core.lint-findings-ref
        (owned_view.compiler-owned-shared-view items)
        index).rule-id
      rule-id)
      true
      (selfhost-lint-findings-have-rule-from? items rule-id (+ index 1)))))

(define (selfhost-lint-filter-derived-origins
  [path : (& path str)]
  [source : String]
  [items : lint_core.LintFindings]) : lint_core.LintFindings
  (let
    [raw-arena-allowlisted : bool
      (and
        (selfhost-lint-findings-have-rule-from?
          (owned_view.compiler-owned-shared-view items)
          (lint_core.lint-rule-raw-arena-op-id)
          0)
        (selfhost-lint-raw-arena-op-allowlisted? path))]
    (selfhost-lint-filter-derived-origins-from
      path
      source
      items
      0
      raw-arena-allowlisted
      (lint_core.lint-findings-empty))))

(define (selfhost-lint-program-findings-with-all-options
  [path : (& path str)]
  [source : String]
  [program : ast.AstProgram]
  [deprecated-string-concat : bool]
  [redundant-function-name : bool]
  [prefer-dotted-field : bool]
  [name-case : bool]) : lint_core.LintFindings
  (match program
    [(ast.AstProgram.Program decls-box)
      (let
        [decls : ast.AstDeclList (ast.ast-decl-list-box-shared-view decls-box)]
        ;; Keep the default path allocation-free with respect to lint policy.
        ;; The policy adapter is only needed when a legacy opt-in is active.
        (if (not
          (or deprecated-string-concat redundant-function-name name-case))
          (selfhost-lint-filter-derived-origins
            path
            (owned_view.compiler-owned-shared-view source)
            (lint_core.lint-program-with-source-options
              source
              (ast.ast-program decls)
              (lint_core.lint-default-ladder-threshold)
              false
              false))
          (let
            [compatibility-policy : lint_policy.LintPolicyResolution
              (selfhost-lint-compatibility-policy
                deprecated-string-concat
                redundant-function-name
                prefer-dotted-field
                name-case)]
            [deprecated-enabled : bool
              (lint_policy.lint-policy-rule-enabled?
                compatibility-policy
                "deprecated-string-concat")]
            [redundant-enabled : bool
              (lint_policy.lint-policy-rule-enabled?
                compatibility-policy
                "redundant-function-name")]
            [name-case-enabled : bool
              (lint_policy.lint-policy-rule-enabled?
                compatibility-policy
                "global-name-case")]
            [base : lint_core.LintFindings
              (lint_core.lint-program-with-source-options
                (owned_view.compiler-owned-shared-view source)
                (ast.ast-program (owned_view.compiler-owned-shared-view decls))
                (lint_core.lint-default-ladder-threshold)
                deprecated-enabled
                name-case-enabled)]
            [with-redundant : lint_core.LintFindings
              (if redundant-enabled
                (lint_core.lint-redundant-function-names-in-program
                  (owned_view.compiler-owned-shared-view source)
                  (ast.ast-program decls)
                  base)
                base)]
            ;; Dotted field projection is now the only public spelling. Keep
            ;; the staged option as a no-op for command-line compatibility.
            [with-prefer : lint_core.LintFindings with-redundant]
            (selfhost-lint-filter-derived-origins path source with-prefer))))]))

(define (selfhost-lint-findings-append-from
  [src : lint_core.LintFindings]
  [index : i64]
  [out : lint_core.LintFindings]) : lint_core.LintFindings
  (if (>=
    index
    (lint_core.lint-findings-count (owned_view.compiler-owned-shared-view src)))
    out
    (selfhost-lint-findings-append-from
      (owned_view.compiler-owned-shared-view src)
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
  (unsafe
    (ptr-read
      (ptr-offset
        (__tl_array-data
          (__tl-project-field selfhost-lint-unsafe-surface-cache slots))
        index))))

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

;; Paths are stored at most once (only the miss path stores), so a front-to-back
;; scan finds the one entry for a path.
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
  [path : (& path str)]
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

(define (selfhost-lint-unsafe-surface-cache-store-invalid!
  [path : (& path str)]) : unit
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
    (match (selfhost-lint-unsafe-surface-cache-lookup
      (owned_view.compiler-owned-shared-view normalized))
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
            (io.file-exists? (owned_view.compiler-owned-shared-view normalized)))
            (match (parser.parse-ast-source-diagnostic-with-cfg-and-pools
              (owned_view.compiler-owned-shared-view normalized)
              (byte_buf.to-string
                (io.read-file
                  (owned_view.compiler-owned-shared-view normalized)))
              cfgs
              (ast.ast-node-pool-compat-context-current))
              [(parser.ResultAstProgramDiagnostic.Ok program)
                (match (compiler_load.compiler-load-surface-summary-build
                  (owned_view.compiler-owned-shared-view normalized)
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
  [import-edge : (& import-edge compiler_load.CompilerLoadSurfaceImport)]) : String
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
        [fact : SelfhostLintUnsafeSurfaceName
          (owned_view.compiler-owned-array-element-shared-view
            names.slots
            index)]
        (begin
          (lint_core.lint-unused-unsafe-classifier-add-exact-name!
            (str_cat.str-cat
              (owned_view.compiler-owned-shared-view alias)
              "."
              (owned_view.compiler-owned-shared-view fact.name))
            fact.requires-unsafe)
          (lint_core.lint-unused-unsafe-classifier-add-exact-name!
            (str_cat.str-cat
              (owned_view.compiler-owned-shared-view alias)
              "/"
              fact.name)
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
        (owned_view.compiler-owned-shared-view path)
        (compiler_load.compiler-load-dirname path)
        import-edge.import-path
        stdlib-roots)]
    [_
      (compiler_load.ResultPkgResolve.Err
        "lint: macro import surface is not static")]))

(define (selfhost-lint-unsafe-surface-prepare-imports!
  [path : String]
  [stdlib-roots : lint_svec.Vec]
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
              (owned_view.compiler-owned-shared-view path)
              (owned_view.compiler-owned-shared-view stdlib-roots)
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
      (owned_view.compiler-owned-shared-view path)
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
  [path : (& path str)]
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
      (tc.tc-unused-unsafe-tracking-reset!
        unused-unsafe
        (owned_view.compiler-owned-shared-view path))
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
                  (owned_view.compiler-owned-shared-view path)
                  (owned_view.compiler-owned-shared-view source)
                  stdlib-roots
                  cfgs
                  job-state)]
              (begin
                (ast.ast-node-pool-compat-context-use! lint-pools)
                checked))))
        (compiler_check_core.compiler-check-source-with-roots-and-cfg-and-job-state
          (owned_view.compiler-owned-shared-view path)
          (owned_view.compiler-owned-shared-view source)
          stdlib-roots
          cfgs
          job-state))
        [(compiler_check_core.ResultCompilerCheck.Ok _ _)
          (let
            [unused-findings : lint_core.LintFindings
              (selfhost-lint-unused-unsafe-findings-from
                unused-unsafe
                path
                0
                (lint_core.lint-findings-empty))]
            [findings : lint_core.LintFindings
              (selfhost-lint-filter-derived-origins path source unused-findings)]
            (begin
              (tc.tc-unused-unsafe-tracking-disable! unused-unsafe)
              findings))]
        [(compiler_check_core.ResultCompilerCheck.Err diag _)
          (begin
            (set!
              selfhost-lint-typed-unused-unsafe-error
              (cdiag.compiler-diagnostic-render
                (cdiag.compiler-diagnostic-list-first
                  (cdiag.compiler-diagnostic-list-box-shared-view diag))))
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
  (if (>=
    index
    (lint_core.lint-findings-count
      (owned_view.compiler-owned-shared-view items)))
    out
    (let
      [finding : lint_core.LintFinding
        (lint_core.lint-findings-ref
          (owned_view.compiler-owned-shared-view items)
          index)]
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
    (selfhost-lint-unsafe-surface-prepare!
      (owned_view.compiler-owned-shared-view path)
      (owned_view.compiler-owned-shared-view program)
      (owned_view.compiler-owned-shared-view stdlib-roots)
      cfgs)
    (let
      [ordinary : lint_core.LintFindings
        (selfhost-lint-program-findings-with-all-options
          path
          (owned_view.compiler-owned-shared-view source)
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
        (match (parser.parse-ast-source-diagnostic-with-cfg
          (owned_view.compiler-owned-shared-view path)
          (owned_view.compiler-owned-shared-view source)
          cfgs)
          [(parser.ResultAstProgramDiagnostic.Ok program)
            (let
              [ordinary : lint_core.LintFindings
                (selfhost-lint-program-findings-with-all-options
                  path
                  (owned_view.compiler-owned-shared-view source)
                  (owned_view.compiler-owned-shared-view program)
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
  (parser.compiler-cfg-union
    (parser.compiler-cfg-enable
      (parser.compiler-cfg-enable
        (parser.compiler-cfg-enable (selfhost-lint-language-cfgs) "test")
        "embedded-stdlib-tlci")
      "compiler-build-identity")
    "compile-profile"))

(define (selfhost-lint-package-dead-cfgs) : sym_i64_env.SymI64Env
  (parser.compiler-cfg-union
    (selfhost-lint-package-dead-cfgs-base)
    "compile-profile-summary"))

(define (selfhost-lint-dead-decls-slots [items : SelfhostLintDeadDecls]) : (__tl_dyn-array
    SelfhostLintDeadDecl)
  items.slots)

(define (selfhost-lint-dead-decls-count
  [items : (& items SelfhostLintDeadDecls)]) : i64
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
  [dst : (&mut dst (__tl_dyn-array SelfhostLintDeadDecl))]
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
        (*
          (selfhost-lint-dead-decls-capacity
            (owned_view.compiler-owned-shared-view items))
          2))]
    (begin
      (selfhost-lint-dead-decls-copy-range
        (&mut bigger)
        (selfhost-lint-dead-decls-slots items)
        0
        n)
      (SelfhostLintDeadDecls bigger n))))

(define (selfhost-lint-dead-decls-add
  [decl : SelfhostLintDeadDecl]
  [items : SelfhostLintDeadDecls]) : SelfhostLintDeadDecls
  (if (<
    (selfhost-lint-dead-decls-count items)
    (selfhost-lint-dead-decls-capacity
      (owned_view.compiler-owned-shared-view items)))
    (let
      [slots : (__tl_dyn-array SelfhostLintDeadDecl)
        (selfhost-lint-dead-decls-slots
          (owned_view.compiler-owned-shared-view items))]
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
    (set!
      (array-ref
        (selfhost-lint-dead-decls-slots
          (owned_view.compiler-owned-shared-view items))
        index)
      decl)
    items))

(define (selfhost-lint-dead-root-add [roots : lint_svec.Vec] [name : String]) : lint_svec.Vec
  (if (lint_svec.contains?
    (& roots)
    (owned_view.compiler-owned-shared-view name))
    roots
    (let
      [next-roots : lint_svec.Vec roots]
      (begin
        (lint_svec.push-ref! (&mut next-roots) name)
        next-roots))))

(define (selfhost-lint-dead-root-add!
  [roots : (&mut roots lint_svec.Vec)]
  [name : String]) : unit
  (if (lint_svec.contains?
    (& roots)
    (owned_view.compiler-owned-shared-view name))
    unit
    (lint_svec.push-ref! roots name)))

(define (selfhost-lint-dead-scan-add-decl
  [scan : SelfhostLintDeadScan]
  [decl : SelfhostLintDeadDecl]) : SelfhostLintDeadScan
  (SelfhostLintDeadScan
    (selfhost-lint-dead-decls-add decl scan.decls)
    scan.roots))

(define (selfhost-lint-dead-scan-add-root
  [scan : SelfhostLintDeadScan]
  [name : String]) : SelfhostLintDeadScan
  (SelfhostLintDeadScan
    scan.decls
    (selfhost-lint-dead-root-add scan.roots name)))

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
    (str_cat.str-cat module "/" name)))

(define (selfhost-lint-dead-default-module-from-path [path : String]) : String
  (parser.parse-ast-dotted-import-default-alias
    (compiler_load.compiler-load-canonical-module-id-from-path path)))

(define (selfhost-lint-dead-qualified-ref-prefix) : String
  "\nselfhost-lint-dead-qualified-ref\n")

(define (selfhost-lint-dead-qualified-ref [key : String] [fallback : String]) : String
  (str_cat.str-cat (selfhost-lint-dead-qualified-ref-prefix) key "\n" fallback))

(define (selfhost-lint-dead-qualified-ref? [ref : (& ref str)]) : bool
  (string.is-string-prefix-at ref (selfhost-lint-dead-qualified-ref-prefix) 0))

(define (selfhost-lint-dead-qualified-ref-separator [ref : (& ref str)]) : i64
  (string.index-of-byte
    ref
    (string.string-length (selfhost-lint-dead-qualified-ref-prefix))
    (cast '\n' : u8)))

(define (selfhost-lint-dead-qualified-ref-key [ref : (& ref str)]) : String
  (let
    [start : i64
      (string.string-length (selfhost-lint-dead-qualified-ref-prefix))]
    [sep : i64 (selfhost-lint-dead-qualified-ref-separator ref)]
    (if (< sep start)
      ""
      (string.substring ref start (- sep start)))))

(define (selfhost-lint-dead-qualified-ref-fallback [ref : (& ref str)]) : String
  (let
    [sep : i64 (selfhost-lint-dead-qualified-ref-separator ref)]
    [name-len : i64 (string.string-length ref)]
    (if (or (< sep 0) (>= (+ sep 1) name-len))
      ""
      (string.substring ref (+ sep 1) (- name-len (+ sep 1))))))

(define (selfhost-lint-dead-source-root-prefix) : String
  "\nselfhost-lint-dead-source-root\n")

(define (selfhost-lint-dead-source-root [path : (& path str)] [name : String]) : String
  (str_cat.str-cat
    (selfhost-lint-dead-source-root-prefix)
    (compiler_load.compiler-load-normalize-path path)
    "\n"
    name))

(define (selfhost-lint-dead-source-root? [root : (& root str)]) : bool
  (string.is-string-prefix-at root (selfhost-lint-dead-source-root-prefix) 0))

(define (selfhost-lint-dead-source-root-separator [root : (& root str)]) : i64
  (string.index-of-byte
    root
    (string.string-length (selfhost-lint-dead-source-root-prefix))
    (cast '\n' : u8)))

(define (selfhost-lint-dead-source-root-path [root : (& root str)]) : String
  (let
    [start : i64 (string.string-length (selfhost-lint-dead-source-root-prefix))]
    [sep : i64 (selfhost-lint-dead-source-root-separator root)]
    (if (< sep start)
      ""
      (string.substring root start (- sep start)))))

(define (selfhost-lint-dead-source-root-name [root : (& root str)]) : String
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
        (selfhost-lint-dead-module-key
          module
          (owned_view.compiler-owned-shared-view ref))
        ref))))

(define (selfhost-lint-dead-localize-refs-from
  [module : String]
  [refs : (& refs lint_svec.Vec)]
  [index : i64]
  [out : lint_svec.Vec]) : lint_svec.Vec
  (if (>= index (lint_svec.len (& refs)))
    out
    (selfhost-lint-dead-localize-refs-from
      (owned_view.compiler-owned-shared-view module)
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
  (if (lint_svec.contains?
    (& refs)
    (owned_view.compiler-owned-shared-view name))
    refs
    (let
      [next-refs : lint_svec.Vec refs]
      (begin
        (lint_svec.push-ref! (&mut next-refs) name)
        next-refs))))

(define (selfhost-lint-dead-last-dot-from
  [name : (& name str)]
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

(define (selfhost-lint-dead-last-dot [name : (& name str)]) : i64
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
        [import-aliases : sym_i64_env.SymI64Env
          selfhost-lint-dead-import-aliases]
        [target : i64
          (sym_i64_env.sym-i64-lookup-id-or
            import-aliases
            (ci.intern-source-slice name 0 last-dot)
            -1)]
        [module : String
          (if (< target 0)
            (string.substring name 0 last-dot)
            (ci.intern-str target))]
        (selfhost-lint-dead-ref-add-raw
          refs
          (selfhost-lint-dead-qualified-ref
            (selfhost-lint-dead-module-key
              module
              (owned_view.compiler-owned-shared-view member))
            member)))
      (selfhost-lint-dead-ref-add-raw refs name))))

(define (selfhost-lint-dead-expr-span [expr-id : i64]) : ast.AstSourceSpan
  (match (ast.ast-node-get expr-id)
    [(ast.AstExpr.Spanned _ span) span]
    [_ (lint_core.lint-no-span)]))

(define (selfhost-lint-dead-find-prefix-from
  [source : (& source str)]
  [needle : (& needle str)]
  [idx : i64]) : i64
  (let
    [source-len : i64 (string.string-length source)]
    [found : i64 (- 0 1)]
    [i : i64 idx]
    (begin
      (while (and (< found 0) (< i source-len))
        (if (string.is-string-prefix-at source needle i)
          (set! found i)
          (set! i (+ i 1))))
      found)))

(define (selfhost-lint-dead-find-name-prefix-from
  [source : (& source str)]
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

(define (selfhost-lint-dead-index-line [source : (& source str)] [target : i64]) : i64
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

(define (selfhost-lint-dead-index-col [source : (& source str)] [target : i64]) : i64
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
  [source : (& source str)]
  [idx : i64]
  [fallback : ast.AstSourceSpan]) : ast.AstSourceSpan
  (if (< idx 0)
    fallback
    (let
      [line : i64 (selfhost-lint-dead-index-line source idx)]
      [col : i64 (selfhost-lint-dead-index-col source idx)]
      (ast.ast-source-span line col line (+ col 1)))))

(define (selfhost-lint-dead-decl-span
  [source : (& source str)]
  [name : String]
  [body-span : ast.AstSourceSpan]) : ast.AstSourceSpan
  (let
    [fn-needle : String
      (str_cat.str-cat "(define (" (owned_view.compiler-owned-shared-view name))]
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

(define (selfhost-lint-dead-names-refs [names : lint_core.LintNames]) : lint_svec.Vec
  (let
    [refs : lint_svec.Vec (lint_svec.new)]
    [index : i64 0]
    (begin
      (while (< index names.len)
        (begin
          (set!
            refs
            (selfhost-lint-dead-ref-add
              refs
              (ci.intern-str (array-ref names.ids index))))
          (set! index (+ index 1))))
      refs)))

(define (selfhost-lint-dead-decl-refs [decl : ast.AstDecl]) : lint_svec.Vec
  (selfhost-lint-dead-names-refs
    (lint_core.lint-decl-names decl (lint_core.lint-names-empty true))))

(define (selfhost-lint-dead-add-node
  [scan : SelfhostLintDeadScan]
  [path : String]
  [module : String]
  [name : String]
  [span : ast.AstSourceSpan]
  [refs : lint_svec.Vec]
  [reportable : bool]) : SelfhostLintDeadScan
  (let
    [node-refs : lint_svec.Vec
      (selfhost-lint-dead-localize-refs
        (owned_view.compiler-owned-shared-view module)
        refs)]
    [key : String
      (selfhost-lint-dead-module-key
        module
        (owned_view.compiler-owned-shared-view name))]
    (selfhost-lint-dead-scan-add-decl
      scan
      (SelfhostLintDeadDecl path name key span node-refs false reportable))))

(define (selfhost-lint-dead-add-visible-node
  [scan : SelfhostLintDeadScan]
  [path : String]
  [module : String]
  [source : (& source str)]
  [name : String]
  [span : ast.AstSourceSpan]
  [refs : lint_svec.Vec]
  [root : bool]
  [reportable : bool]) : SelfhostLintDeadScan
  (let
    [with-node : SelfhostLintDeadScan
      (selfhost-lint-dead-add-node
        scan
        (owned_view.compiler-owned-shared-view path)
        module
        (owned_view.compiler-owned-shared-view name)
        span
        refs
        reportable)]
    [explicit-root : bool
      (selfhost-lint-suppressed?
        source
        (lint_core.lint-dead-code-finding
          (owned_view.compiler-owned-shared-view name)
          span))]
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
  [source : (& source str)]
  [decl : ast.AstDecl]
  [visible-root : bool]
  [requested-report : bool]) : SelfhostLintDeadScan
  (let
    [allow-report : bool
      (and
        requested-report
        (not
          (ast.ast-decl-comptime-only?
            (owned_view.compiler-owned-shared-view decl))))]
    [result : SelfhostLintDeadScan
      (match (owned_view.compiler-owned-shared-view decl)
        [(ast.AstDecl.ModuleBody name body-box)
          (selfhost-lint-dead-scan-decls
            scan
            path
            (ci.intern-str name)
            source
            visible-root
            allow-report
            (deref body-box))]
        [(ast.AstDecl.Module _) scan]
        [(ast.AstDecl.Def _ name _ body)
          (let
            [text : String (ci.intern-str name)]
            [span : ast.AstSourceSpan
              (selfhost-lint-dead-decl-span
                source
                (owned_view.compiler-owned-shared-view text)
                (selfhost-lint-dead-expr-span body))]
            (selfhost-lint-dead-add-visible-node
              scan
              path
              module
              source
              text
              span
              (selfhost-lint-dead-decl-refs
                (owned_view.compiler-owned-shared-view decl))
              visible-root
              allow-report))]
        [(ast.AstDecl.DefFn _ name _ _ body _)
          (let
            [text : String (ci.intern-str name)]
            [span : ast.AstSourceSpan
              (selfhost-lint-dead-decl-span
                source
                (owned_view.compiler-owned-shared-view text)
                (selfhost-lint-dead-expr-span body))]
            (selfhost-lint-dead-add-visible-node
              scan
              path
              module
              source
              text
              span
              (selfhost-lint-dead-decl-refs
                (owned_view.compiler-owned-shared-view decl))
              visible-root
              allow-report))]
        [(ast.AstDecl.DefMacro _ name _ _ body)
          (selfhost-lint-dead-add-visible-node
            scan
            path
            module
            source
            (ci.intern-str name)
            (selfhost-lint-dead-expr-span body)
            (selfhost-lint-dead-decl-refs
              (owned_view.compiler-owned-shared-view decl))
            visible-root
            allow-report)]
        [(ast.AstDecl.Extern _ name _ _ _)
          (selfhost-lint-dead-add-no-span-node
            scan
            path
            module
            source
            (owned_view.compiler-owned-shared-view decl)
            name
            visible-root
            allow-report)]
        [(ast.AstDecl.DefEnum _ name _ _)
          (selfhost-lint-dead-add-no-span-node
            scan
            path
            module
            source
            (owned_view.compiler-owned-shared-view decl)
            name
            visible-root
            allow-report)]
        [(ast.AstDecl.DefEnumLifetimes _ name _ _ _)
          (selfhost-lint-dead-add-no-span-node
            scan
            path
            module
            source
            (owned_view.compiler-owned-shared-view decl)
            name
            visible-root
            allow-report)]
        [(ast.AstDecl.DefStruct _ name _ _ _)
          (selfhost-lint-dead-add-no-span-node
            scan
            path
            module
            source
            (owned_view.compiler-owned-shared-view decl)
            name
            visible-root
            allow-report)]
        [(ast.AstDecl.DefStructLifetimes _ name _ _ _ _)
          (selfhost-lint-dead-add-no-span-node
            scan
            path
            module
            source
            (owned_view.compiler-owned-shared-view decl)
            name
            visible-root
            allow-report)]
        [(ast.AstDecl.DefDispatch _ name _)
          (selfhost-lint-dead-add-no-span-node
            scan
            path
            module
            source
            (owned_view.compiler-owned-shared-view decl)
            name
            visible-root
            allow-report)]
        ;; Macro imports and tests reference their names from outside any
        ;; declaration; other imports reference none.
        [(ast.AstDecl.Import _ _)
          (selfhost-lint-dead-refs-to-roots
            scan
            (selfhost-lint-dead-decl-refs
              (owned_view.compiler-owned-shared-view decl)))]
        [(ast.AstDecl.Test _ _ _ _)
          (selfhost-lint-dead-refs-to-roots
            scan
            (selfhost-lint-dead-decl-refs
              (owned_view.compiler-owned-shared-view decl)))]
        [(ast.AstDecl.IncludeStr _ _) scan]
        [(ast.AstDecl.IncludeStrComptime _ _) scan]
        [(ast.AstDecl.IncludeStrLzss _ _) scan]
        [(ast.AstDecl.IncludeBin _ _) scan]
        [(ast.AstDecl.Unsafe inner)
          (selfhost-lint-dead-scan-decl
            scan
            path
            module
            source
            (deref inner)
            visible-root
            allow-report)])]
    (selfhost-lint-dead-refs-to-roots
      result
      (selfhost-lint-dead-names-refs
        (lint_core.lint-generated-meta-names
          (ast.ast-decl-generated-meta decl)
          (lint_core.lint-names-empty true))))))

;; An extern, type or dispatch declaration: a node without a source span.
(define (selfhost-lint-dead-add-no-span-node
  [scan : SelfhostLintDeadScan]
  [path : String]
  [module : String]
  [source : (& source str)]
  [decl : ast.AstDecl]
  [name : i64]
  [visible-root : bool]
  [reportable : bool]) : SelfhostLintDeadScan
  (selfhost-lint-dead-add-visible-node
    scan
    path
    module
    source
    (ci.intern-str name)
    (lint_core.lint-no-span)
    (selfhost-lint-dead-decl-refs decl)
    visible-root
    reportable))

(define (selfhost-lint-dead-scan-decls
  [scan : SelfhostLintDeadScan]
  [path : String]
  [module : String]
  [source : (& source str)]
  [visible-root : bool]
  [reportable : bool]
  [decls : ast.AstDeclList]) : SelfhostLintDeadScan
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) scan]
    [(ast.AstDeclListStep.Cons decl rest)
      (match (owned_view.compiler-owned-shared-view decl)
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
              (owned_view.compiler-owned-shared-view path)
              (ci.intern-str name)
              source
              visible-root
              reportable
              (ast.ast-decl-list-box-shared-view body-box))
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
              (owned_view.compiler-owned-shared-view path)
              (owned_view.compiler-owned-shared-view module)
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
              (deref body-box)
              aliases))]
        [_ (selfhost-lint-dead-import-aliases-from-decls rest aliases)])]))

(define (selfhost-lint-dead-scan-source-with-cfgs
  [scan : SelfhostLintDeadScan]
  [path : String]
  [source : String]
  [visible-root : bool]
  [reportable : bool]
  [cfgs : sym_i64_env.SymI64Env]) : SelfhostLintDeadScan
  (match (parser.parse-ast-source-diagnostic-with-cfg
    (owned_view.compiler-owned-shared-view path)
    (owned_view.compiler-owned-shared-view source)
    cfgs)
    [(parser.ResultAstProgramDiagnostic.Ok program)
      (match program
        [(ast.AstProgram.Program decls-box)
          (let
            [decls : ast.AstDeclList
              (ast.ast-decl-list-box-shared-view decls-box)]
            (begin
              (set!
                selfhost-lint-dead-import-aliases
                (selfhost-lint-dead-import-aliases-from-decls
                  (owned_view.compiler-owned-shared-view decls)
                  (sym_i64_env.sym-i64-empty)))
              (selfhost-lint-dead-scan-decls
                scan
                (owned_view.compiler-owned-shared-view path)
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

(define (selfhost-lint-dead-scan-append-owned-decls-from
  [scan : SelfhostLintDeadScan]
  [source-scan : SelfhostLintDeadScan]
  [index : i64]) : SelfhostLintDeadScan
  (if (>= index (selfhost-lint-dead-decls-count source-scan.decls))
    scan
    (let
      [decl : SelfhostLintDeadDecl
        (selfhost-lint-dead-decls-ref
          (owned_view.compiler-owned-shared-view source-scan.decls)
          index)]
      (selfhost-lint-dead-scan-append-owned-decls-from
        (selfhost-lint-dead-scan-add-decl scan decl)
        source-scan
        (+ index 1)))))

(define (selfhost-lint-dead-scan-append-owned
  [scan : SelfhostLintDeadScan]
  [source-scan : SelfhostLintDeadScan]) : SelfhostLintDeadScan
  ;; with-scratch already cloned source-scan into the enclosing owner. Append
  ;; those now-home-owned values directly so the growing package scan is never
  ;; deep-cloned again for each input file.
  (selfhost-lint-dead-scan-add-roots
    (selfhost-lint-dead-scan-append-owned-decls-from
      scan
      (owned_view.compiler-owned-shared-view source-scan)
      0)
    source-scan.roots))

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
    [source-scan : SelfhostLintDeadScan
      (with-scratch
        (let
          [scratch-scan : SelfhostLintDeadScan
            (selfhost-lint-dead-scan-source
              (SelfhostLintDeadScan
                (selfhost-lint-dead-decls-empty)
                (lint_svec.new))
              (owned_view.compiler-owned-shared-view path)
              (byte_buf.to-string (io.read-file path))
              visible-root
              reportable)]
          (begin
            ;; Clear compiler globals while the scratch allocations they may
            ;; reference are still mapped. Allocate any replacement state in
            ;; the enclosing owner, then clone only this file's compact scan
            ;; out before reclaiming its complete AST.
            (in-arena home (selfhost-lint-reset-file-state!))
            scratch-scan)))]
    [next : SelfhostLintDeadScan
      (selfhost-lint-dead-scan-append-owned scan source-scan)]
    (begin
      (ast.ast-node-pool-context-reset-to! pools 0 0)
      (ast.ast-node-pool-compat-context-clear!)
      (ast.ast-node-pool-context-destroy-storage! pools)
      (unsafe
        (begin
          (arena.set! home)
          (arena.tl_arena_destroy (ast.ast-node-pool-context-base-arena pools))))
      next)))

(define (selfhost-lint-package-dead-scan-files
  [sources : lint_svec.Vec]
  [reportable-sources : (& reportable-sources lint_svec.Vec)]
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
        (owned_view.compiler-owned-shared-view stdlib-roots)
        (+ index 1)
        visible-root
        reportable
        (selfhost-lint-dead-scan-file-in-scratch
          scan
          (owned_view.compiler-owned-shared-view path)
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
      (__tl-project-field
        (selfhost-lint-dead-decls-ref
          (owned_view.compiler-owned-shared-view items)
          index)
        name)
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
      (__tl-project-field
        (selfhost-lint-dead-decls-ref
          (owned_view.compiler-owned-shared-view items)
          index)
        key)
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
    [decl : SelfhostLintDeadDecl
      (selfhost-lint-dead-decls-ref
        (owned_view.compiler-owned-shared-view items)
        index)]
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
          (selfhost-lint-dead-decls-set
            items
            index
            (owned_view.compiler-owned-shared-view marked))]
        (selfhost-lint-dead-mark-refs-from updated marked.refs 0)))))

(define (selfhost-lint-dead-mark-reachable-name
  [items : SelfhostLintDeadDecls]
  [name : String]) : SelfhostLintDeadDecls
  (let
    [index : i64
      (selfhost-lint-dead-decls-index-of
        (owned_view.compiler-owned-shared-view items)
        name)]
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
          (owned_view.compiler-owned-shared-view items)
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
      [decl : SelfhostLintDeadDecl
        (selfhost-lint-dead-decls-ref
          (owned_view.compiler-owned-shared-view items)
          index)]
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
      [decl : SelfhostLintDeadDecl
        (selfhost-lint-dead-decls-ref
          (owned_view.compiler-owned-shared-view items)
          index)]
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
  [scan : SelfhostLintDeadScan]
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
  [stdlib-roots : lint_svec.Vec]) : lint_svec.Vec
  (let
    [manifest : compiler_load.CompilerPkgManifest source-set.manifest]
    [manifest-dir : String source-set.manifest-dir]
    [entry-path : String
      (selfhost-lint-package-entry-path
        (owned_view.compiler-owned-shared-view manifest-dir)
        manifest)]
    [entry-dir : String (compiler_load.compiler-load-dirname entry-path)]
    [source-root : String
      (compiler_load.compiler-load-normalize-path
        (if (= (string.string-length entry-dir) 0)
          manifest-dir
          entry-dir))]
    (if (or
      (= (string.string-length source-root) 0)
      (lint_svec.contains?
        (& stdlib-roots)
        (owned_view.compiler-owned-shared-view source-root)))
      stdlib-roots
      (let
        [roots : lint_svec.Vec stdlib-roots]
        (begin
          (lint_svec.push-ref! (&mut roots) source-root)
          roots)))))

(define (selfhost-lint-package-source-list-contains-from
  [sources : (& sources lint_svec.Vec)]
  [path : (& path str)]
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
  [sources : (& sources lint_svec.Vec)]
  [path : (& path str)]) : bool
  (selfhost-lint-package-source-list-contains-from sources path 0))

(define (selfhost-lint-package-empty-source-list) : lint_svec.Vec
  (lint_svec.new))

(define (selfhost-lint-package-stdlib-source?
  [path : (& path str)]
  [stdlib-roots : lint_svec.Vec]) : bool
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
  [path : (& path str)]
  [sources : (& sources lint_svec.Vec)]
  [stdlib-roots : lint_svec.Vec]) : bool
  (and
    (> (string.string-length path) 0)
    (selfhost-lint-package-source-list-contains? sources path)
    (not (selfhost-lint-package-stdlib-source? path stdlib-roots))))

(define (selfhost-lint-package-dead-graph-source-path?
  [path : String]
  [sources : (& sources lint_svec.Vec)]
  [root-sources : (& root-sources lint_svec.Vec)]
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
  [sources : (& sources lint_svec.Vec)]
  [root-sources : (& root-sources lint_svec.Vec)]
  [stdlib-roots : lint_svec.Vec]) : lint_svec.Vec
  (if (selfhost-lint-package-dead-graph-source-path?
    (owned_view.compiler-owned-shared-view path)
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

(define (selfhost-lint-dead-manifest-field [line : (& line str)] [target : i64]) : String
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

(define (selfhost-lint-dead-manifest-line-end
  [source : (& source str)]
  [start : i64]) : i64
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
  [source : (& source str)]
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
                  (compiler_load.compiler-load-normalize-path
                    (compiler_load.compiler-load-join-root-path
                      (owned_view.compiler-owned-shared-view manifest-dir)
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
        (owned_view.compiler-owned-shared-view manifest-dir)
        "src/compile_manifest.txt")]
    (if (io.file-exists? (owned_view.compiler-owned-shared-view path))
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
              [manifest : compiler_load.CompilerPkgManifest
                (owned_view.compiler-owned-shared-view source-set.manifest)]
              [manifest-dir : String
                (owned_view.compiler-owned-shared-view source-set.manifest-dir)]
              (match (if package-imports
                (compiler_load.compiler-load-resolve-package-import-spec
                  (owned_view.compiler-owned-shared-view importer-path)
                  kind
                  (owned_view.compiler-owned-shared-view import-path)
                  expected-module
                  (owned_view.compiler-owned-shared-view stdlib-roots)
                  (owned_view.compiler-owned-shared-view manifest-dir)
                  (owned_view.compiler-owned-shared-view manifest.deps))
                (compiler_load.compiler-load-resolve-import-spec-with-roots
                  (owned_view.compiler-owned-shared-view importer-path)
                  (owned_view.compiler-owned-shared-view import-root)
                  kind
                  (owned_view.compiler-owned-shared-view import-path)
                  expected-module
                  (owned_view.compiler-owned-shared-view stdlib-roots)))
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
                          (owned_view.compiler-owned-shared-view importer-path)
                          kind
                          alias))]
                    [preload-demand : compiler_load.CompilerLoadLazyAliasDemand
                      (compiler_load.compiler-load-lazy-import-preload-demand
                        preload-candidate
                        alias
                        (owned_view.compiler-owned-shared-view rest)
                        pools)]
                    [preload-summary-needed : bool
                      (and
                        preload-candidate
                        (not
                          (or preload-demand.qualified preload-demand.unknown)))]
                    [_preload-summary : unit
                      (if preload-summary-needed
                        (compiler_load.compiler-load-lazy-import-preload-summary-with-pools
                          (owned_view.compiler-owned-shared-view resolved)
                          resolved-id
                          (owned_view.compiler-owned-shared-view stdlib-roots)
                          expected-module
                          manifest-dir
                          (selfhost-lint-package-dead-cfgs)
                          pools)
                        unit)]
                    [preload-skip : bool
                      (and
                        preload-summary-needed
                        (compiler_load.compiler-load-lazy-import-skip?
                          (owned_view.compiler-owned-shared-view importer-path)
                          kind
                          (owned_view.compiler-owned-shared-view resolved)
                          resolved-id
                          expected-module
                          alias
                          (owned_view.compiler-owned-shared-view rest)
                          pools
                          preload-demand
                          (owned_view.compiler-owned-shared-view stdlib-roots)))]
                    [next : lint_svec.Vec
                      (if (or
                        preload-skip
                        (not
                          (selfhost-lint-package-dead-graph-source-path?
                            (owned_view.compiler-owned-shared-view resolved)
                            source-set.sources
                            root-sources
                            (owned_view.compiler-owned-shared-view stdlib-roots))))
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
            (ast.ast-decl-list-box-shared-view body-box)
            (owned_view.compiler-owned-shared-view importer-path)
            (owned_view.compiler-owned-shared-view import-root)
            (owned_view.compiler-owned-shared-view source-set)
            (owned_view.compiler-owned-shared-view root-sources)
            (owned_view.compiler-owned-shared-view stdlib-roots)
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
    [result : ResultSelfhostLintDeadImportList
      (with-scratch
        (let
          [scratch-result : ResultSelfhostLintDeadImportList
            (match (parser.parse-ast-source-diagnostic-with-cfg
              (owned_view.compiler-owned-shared-view path)
              (byte_buf.to-string
                (io.read-file (owned_view.compiler-owned-shared-view path)))
              (selfhost-lint-package-dead-cfgs))
              [(parser.ResultAstProgramDiagnostic.Err diag)
                (ResultSelfhostLintDeadImportList.Err diag)]
              [(parser.ResultAstProgramDiagnostic.Ok program)
                (match program
                  [(ast.AstProgram.Program decls-box)
                    (selfhost-lint-package-dead-import-paths-from-decls
                      (ast.ast-decl-list-box-shared-view decls-box)
                      path
                      import-root
                      source-set
                      root-sources
                      stdlib-roots
                      pools
                      package-imports
                      (lint_svec.new))])])]
          (begin
            (in-arena home (selfhost-lint-reset-file-state!))
            scratch-result)))]
    (begin
      (ast.ast-node-pool-context-reset-to! pools 0 0)
      (ast.ast-node-pool-compat-context-clear!)
      (ast.ast-node-pool-context-destroy-storage! pools)
      (unsafe
        (begin
          (arena.set! home)
          (arena.tl_arena_destroy (ast.ast-node-pool-context-base-arena pools))))
      result)))

(define (selfhost-lint-package-dead-path-closure-from
  [queue : lint_svec.Vec]
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
      (owned_view.compiler-owned-shared-view import-root)
      (owned_view.compiler-owned-shared-view source-set)
      (owned_view.compiler-owned-shared-view root-sources)
      (owned_view.compiler-owned-shared-view stdlib-roots)
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
        (owned_view.compiler-owned-shared-view entry-path)
        source-set.sources
        root-sources
        (owned_view.compiler-owned-shared-view stdlib-roots))]
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
      (owned_view.compiler-owned-shared-view source-set)
      (owned_view.compiler-owned-shared-view root-sources)
      (owned_view.compiler-owned-shared-view stdlib-roots)
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
      (selfhost-lint-package-import-roots
        (owned_view.compiler-owned-shared-view source-set)
        stdlib-roots)]
    [explicit-roots : lint_svec.Vec
      (selfhost-lint-package-dead-compile-manifest-roots
        (owned_view.compiler-owned-shared-view source-set))]
    [kind : compiler_load.CompilerPkgKind manifest.kind]
    (if (selfhost-lint-package-kind-entry? kind)
      (let
        [manifest-dir : String source-set.manifest-dir]
        [entry-path : String
          (selfhost-lint-package-entry-path manifest-dir manifest)]
        [root-sources : lint_svec.Vec
          (selfhost-lint-package-dead-repository-test-roots
            (owned_view.compiler-owned-shared-view source-set))]
        (match (selfhost-lint-package-dead-closure-sources
          entry-path
          (owned_view.compiler-owned-shared-view source-set)
          (owned_view.compiler-owned-shared-view root-sources)
          (owned_view.compiler-owned-shared-view package-roots)
          (lint_svec.new))
          [(ResultSelfhostLintDeadSourceList.Err diag)
            (ResultSelfhostLintDeadSources.Err diag)]
          [(ResultSelfhostLintDeadSourceList.Ok entry-sources)
            (match (selfhost-lint-package-dead-root-closure-sources
              (owned_view.compiler-owned-shared-view root-sources)
              (owned_view.compiler-owned-shared-view source-set)
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
          (owned_view.compiler-owned-shared-view source-set.sources)
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
  [source : (& source str)]
  [decl : SelfhostLintDeadDecl]) : bool
  (if (not decl.reportable)
    false
    (if decl.root
      false
      (not
        (selfhost-lint-suppressed?
          source
          (lint_core.lint-dead-code-finding decl.name decl.span))))))

(define (selfhost-lint-package-dead-print-for-source-from
  [path : String]
  [source : String]
  [items : SelfhostLintDeadDecls]
  [index : i64]
  [printed : i64]) : i64
  (if (>= index (selfhost-lint-dead-decls-count items))
    printed
    (let
      [decl : SelfhostLintDeadDecl
        (selfhost-lint-dead-decls-ref
          (owned_view.compiler-owned-shared-view items)
          index)]
      [next-printed : i64
        (if (and
          (string.eq decl.path path)
          (selfhost-lint-package-dead-finding-active?
            source
            (owned_view.compiler-owned-shared-view decl)))
          (begin
            (io.print-format
              "{}"
              (selfhost-lint-render-finding-line
                (owned_view.compiler-owned-shared-view path)
                (owned_view.compiler-owned-shared-view source)
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
    [status : i64
      (with-scratch
        (let
          [file-status : i64
            (selfhost-lint-file
              input-path
              stdlib-roots
              enforcing
              deprecated-string-concat
              redundant-function-name
              prefer-dotted-field
              name-case)]
          (begin
            ;; Without an explicit batch reset, the unsafe-surface cache was
            ;; ensured into this file scratch. Release it before with-scratch
            ;; reclaims the arena, and rebuild global state in the enclosing
            ;; owner while the old scratch-backed nodes are still mapped.
            (if (arena.eq?
              (arena.Arena selfhost-lint-unsafe-surface-cache-arena)
              (arena.current))
              (selfhost-lint-unsafe-surface-cache-release!)
              unit)
            (in-arena home (selfhost-lint-reset-file-state!))
            file-status)))]
    (begin
      (ast.ast-node-pool-context-reset-to! pools 0 0)
      (ast.ast-node-pool-compat-context-clear!)
      (ast.ast-node-pool-context-destroy-storage! pools)
      (unsafe
        (begin
          (arena.set! home)
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
    [status : i64
      (with-scratch
        (let
          [file-status : i64
            (selfhost-lint-file-with-package-dead
              input-path
              stdlib-roots
              enforcing
              deprecated-string-concat
              redundant-function-name
              prefer-dotted-field
              name-case
              dead-decls)]
          (begin
            (if (arena.eq?
              (arena.Arena selfhost-lint-unsafe-surface-cache-arena)
              (arena.current))
              (selfhost-lint-unsafe-surface-cache-release!)
              unit)
            (in-arena home (selfhost-lint-reset-file-state!))
            file-status)))]
    (begin
      (ast.ast-node-pool-context-reset-to! pools 0 0)
      (ast.ast-node-pool-compat-context-clear!)
      (ast.ast-node-pool-context-destroy-storage! pools)
      (unsafe
        (begin
          (arena.set! home)
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
    [source : String
      (byte_buf.to-string
        (io.read-file (owned_view.compiler-owned-shared-view input-path)))]
    ;; Parse directly INTO the installed compat-context pools rather than the
    ;; plain `parse-ast-source-diagnostic`, whose capture-active/install! dance
    ;; is a no-op under an explicit compat context: when the parse grows
    ;; (reallocates) its captured pool the fresh backing array is dropped, so the
    ;; AST lint walk later reads stale/undersized slots via ast-node-get and
    ;; mis-reports live params/imports as unused on large sources. Threading
    ;; the live context keeps ast-node-get pointed at the grown pool.
    (match (parser.parse-ast-source-diagnostic-with-cfg-and-pools
      (owned_view.compiler-owned-shared-view input-path)
      (owned_view.compiler-owned-shared-view source)
      (selfhost-lint-language-cfgs)
      (ast.ast-node-pool-compat-context-current))
      [(parser.ResultAstProgramDiagnostic.Ok program)
        (let
          [findings : lint_core.LintFindings
            (selfhost-lint-program-and-typed-findings
              (owned_view.compiler-owned-shared-view input-path)
              (owned_view.compiler-owned-shared-view source)
              program
              stdlib-roots
              (selfhost-lint-language-cfgs)
              deprecated-string-concat
              redundant-function-name
              prefer-dotted-field
              name-case)]
          (if (string.eq selfhost-lint-typed-unused-unsafe-error "")
            (begin
              (selfhost-lint-print-findings
                input-path
                source
                (owned_view.compiler-owned-shared-view findings))
              (io.print-format
                "{}"
                (str_cat.str-cat
                  "lint: "
                  (string.int->string
                    (lint_core.lint-findings-count
                      (owned_view.compiler-owned-shared-view findings)))
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
          (io.print-error (cdiag.compiler-diagnostic-render (deref diag)))
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
    [source : String
      (byte_buf.to-string
        (io.read-file (owned_view.compiler-owned-shared-view input-path)))]
    ;; Parse directly INTO the installed compat-context pools rather than the
    ;; plain `parse-ast-source-diagnostic`, whose capture-active/install! dance
    ;; is a no-op under an explicit compat context: when the parse grows
    ;; (reallocates) its captured pool the fresh backing array is dropped, so the
    ;; AST lint walk later reads stale/undersized slots via ast-node-get and
    ;; mis-reports live params/imports as unused on large sources. Threading
    ;; the live context keeps ast-node-get pointed at the grown pool.
    (match (parser.parse-ast-source-diagnostic-with-cfg-and-pools
      (owned_view.compiler-owned-shared-view input-path)
      (owned_view.compiler-owned-shared-view source)
      (selfhost-lint-language-cfgs)
      (ast.ast-node-pool-compat-context-current))
      [(parser.ResultAstProgramDiagnostic.Ok program)
        (let
          [findings : lint_core.LintFindings
            (selfhost-lint-program-and-typed-findings
              (owned_view.compiler-owned-shared-view input-path)
              (owned_view.compiler-owned-shared-view source)
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
                (selfhost-lint-print-findings
                  (owned_view.compiler-owned-shared-view input-path)
                  (owned_view.compiler-owned-shared-view source)
                  findings)]
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
          (io.print-error (cdiag.compiler-diagnostic-render (deref diag)))
          1)])))

(define (selfhost-lint-files-from
  [input-paths : (& input-paths lint_svec.Vec)]
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
            (io.print-format
              "{}"
              (str_cat.str-cat
                "--- "
                (owned_view.compiler-owned-shared-view input-path)
                "\n"))
            unit)
          (selfhost-lint-run-file-in-scratch
            input-path
            (owned_view.compiler-owned-shared-view stdlib-roots)
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
  [input-paths : (& input-paths lint_svec.Vec)]
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
  [input-paths : (& input-paths lint_svec.Vec)]
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
            (io.print-format
              "{}"
              (str_cat.str-cat
                "--- "
                (owned_view.compiler-owned-shared-view input-path)
                "\n"))
            unit)
          (selfhost-lint-run-file-with-package-dead-in-scratch
            input-path
            (owned_view.compiler-owned-shared-view stdlib-roots)
            enforcing
            deprecated-string-concat
            redundant-function-name
            prefer-dotted-field
            name-case
            (owned_view.compiler-owned-shared-view dead-decls)))]
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
  [input-paths : (& input-paths lint_svec.Vec)]
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
        [sources : lint_svec.Vec
          (owned_view.compiler-owned-shared-view source-set.sources)]
        [manifest : compiler_load.CompilerPkgManifest
          (owned_view.compiler-owned-shared-view source-set.manifest)]
        [dead-sources-result : ResultSelfhostLintDeadSources
          (selfhost-lint-package-dead-sources
            (owned_view.compiler-owned-shared-view source-set)
            (owned_view.compiler-owned-shared-view stdlib-roots))]
        [package-roots : lint_svec.Vec
          (selfhost-lint-package-import-roots source-set stdlib-roots)]
        (match dead-sources-result
          [(ResultSelfhostLintDeadSources.Ok dead-sources)
            (let
              [dead-decls : SelfhostLintDeadDecls
                (selfhost-lint-package-dead-code
                  dead-sources
                  (owned_view.compiler-owned-shared-view package-roots)
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
                (cdiag.compiler-diagnostic-render
                  (cdiag.compiler-diagnostic-box-shared-view diag)))
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