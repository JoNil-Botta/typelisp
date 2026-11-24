;; check_cli_core.tl - Self-hosted `check` (typecheck) command logic.
;;
;; Main-free, so the unified `main.tl` dispatcher runs the command without a
;; duplicate `main`.
(import stdlib.iterator)
(import compiler_owned_view as owned_view)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.text_buf)
(import source_text_core as source_text)
(import cli_option_core as cli_option)
(import compiler_target_cfg_core as target_cfg)
(import compiler_check_core)
(import compiler_typecheck_core as tc)
(import compiler_driver_core)
(import doc_test)
(import compiler_load)
(import compiler_ast_types as ast)
(import compiler_diagnostic as cdiag)
(import compiler_intern as ci)
(import package_source_core)
(import test_cli_core)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as svec)
(import sym_i64_env)

(defenum SelfhostCheckConfig
  (File String cli_option.CliCompileOptions)
  (Batch String cli_option.CliCompileOptions)
  (Package String bool cli_option.CliCompileOptions))

(defenum ResultSelfhostCheckConfig
  (Ok SelfhostCheckConfig)
  (Err String))

(defstruct SelfhostCheckOutcome
  (status i64)
  (stdout String)
  (stderr String))

;; Parse the `check` config from arguments starting at `start`. `count` is
;; `(arg-count)`.
(define (selfhost-check-config-from [start : i64] [count : i64]) : ResultSelfhostCheckConfig
  (let
    [args : cli_option.CliArgs
      (cli_option.cli-args
        "selfhost-check"
        "--stdlib-root <dir> --cfg <name> --target <target> --backend-mode <mode> --opt-level <0|1|2|s> -Os --debug|-g|--backtrace --manifest-path <file> --batch <file>"
        start
        count)]
    [input-path : String ""]
    [has-input : bool false]
    [manifest-path : String ""]
    [has-manifest : bool false]
    [batch-path : String ""]
    [has-batch : bool false]
    [options : cli_option.CliCompileOptions
      (cli_option.cli-compile-options (Linux) 1)]
    (while (cli_option.cli-args-next! (&mut args))
      (cond
        [(cli_option.cli-compile-option! (&mut options) (&mut args)) unit]
        [(string.eq args.name "--manifest-path")
          (if has-manifest
            (cli_option.cli-args-fail!
              (&mut args)
              "selfhost-check: duplicate --manifest-path")
            (begin
              (set! manifest-path (cli_option.cli-args-value (& args)))
              (set! has-manifest true)))]
        [(string.eq args.name "--batch")
          (if has-batch
            (cli_option.cli-args-fail!
              (&mut args)
              "selfhost-check: duplicate --batch")
            (begin
              (set! batch-path (cli_option.cli-args-value (& args)))
              (set! has-batch true)))]
        [(cli_option.cli-flag? args.arg)
          (cli_option.cli-args-fail-arg!
            (&mut args)
            "selfhost-check: unknown flag ")]
        [has-input
          (cli_option.cli-args-fail-arg!
            (&mut args)
            "selfhost-check: unexpected argument ")]
        [else
          (set! input-path (string.copy (& args.arg)))
          (set! has-input true)]))
    (cond
      [args.failed (Err args.error)]
      [(and has-batch has-input)
        (Err "selfhost-check: cannot combine input path with --batch")]
      [(and has-batch has-manifest)
        (Err "selfhost-check: cannot combine --batch with --manifest-path")]
      [(and has-input has-manifest)
        (Err "selfhost-check: cannot combine input path with --manifest-path")]
      [has-batch (Ok (Batch batch-path options))]
      [has-input (Ok (File input-path options))]
      [else (Ok (Package manifest-path has-manifest options))])))

(define (selfhost-check-print-passed) : i64
  (io.print-format "{}" "Type checking passed!\n")
  0)

(define (selfhost-check-report-diagnostics
  [diagnostics : cdiag.CompilerDiagnosticList]) : unit
  (let
    [count : i64 (cdiag.compiler-diagnostic-list-count diagnostics)]
    [sources : compiler_driver_core.CompilerDriverDiagnosticSources
      (compiler_driver_core.compiler-driver-diagnostic-sources-new)]
    (for [index (iterator.range 0 count)]
      (io.print-error
        (compiler_driver_core.compiler-driver-render-source-diagnostic-from
          (&mut sources)
          (cdiag.compiler-diagnostic-list-get diagnostics index))))))

(define (selfhost-check-append-advisories
  [advisories : (& advisories cdiag.CompilerAdvisoryList)]
  [err-buf : text_buf.TextBuf]) : text_buf.TextBuf
  (let
    [count : i64 (cdiag.compiler-advisory-list-count advisories)]
    [sources : compiler_driver_core.CompilerDriverDiagnosticSources
      (compiler_driver_core.compiler-driver-diagnostic-sources-new)]
    [out : text_buf.TextBuf err-buf]
    (for [index (iterator.range 0 count)]
      (let
        [advisory : cdiag.CompilerAdvisory
          (cdiag.compiler-advisory-list-get advisories index)]
        [diagnostic : cdiag.CompilerDiagnostic
          (cdiag.compiler-advisory-diagnostic (& advisory))]
        (text_buf.append!
          out
          (compiler_driver_core.compiler-driver-render-source-diagnostic-from
            (&mut sources)
            diagnostic))))
    out))

(define (selfhost-check-append-diagnostics
  [diagnostics : cdiag.CompilerDiagnosticList]
  [err-buf : text_buf.TextBuf]) : text_buf.TextBuf
  (let
    [count : i64 (cdiag.compiler-diagnostic-list-count diagnostics)]
    [sources : compiler_driver_core.CompilerDriverDiagnosticSources
      (compiler_driver_core.compiler-driver-diagnostic-sources-new)]
    [out : text_buf.TextBuf err-buf]
    (for [index (iterator.range 0 count)]
      (text_buf.append!
        out
        (compiler_driver_core.compiler-driver-render-source-diagnostic-from
          (&mut sources)
          (cdiag.compiler-diagnostic-list-get diagnostics index))))
    out))

(define (selfhost-check-copy-target
  [target : (& target target_cfg.CompilerTargetCfg)]) : target_cfg.CompilerTargetCfg
  (match target
    [(Linux) (Linux)]
    [(Windows) (Windows)]))

(define (selfhost-check-file-outcome
  [input-path : String]
  [options : (& options cli_option.CliCompileOptions)]) : SelfhostCheckOutcome
  (let
    [target : target_cfg.CompilerTargetCfg
      (selfhost-check-copy-target (& options.target))]
    [check-cfgs : sym_i64_env.SymI64Env
      (target_cfg.compiler-target-cfgs-with-names
        target
        (svec.clone-vec (& options.cfgs)))]
    (match (compiler_check_core.compiler-check-file-with-roots-and-cfg
      (string.copy (& input-path))
      (svec.clone-vec (& options.stdlib-roots))
      check-cfgs)
      [(Ok _ advisories)
        (let
          [err-buf : text_buf.TextBuf
            (selfhost-check-append-advisories (& advisories) (text_buf.empty))]
          (match (test_cli_core.tltest-inline-typecheck-file-with-cfg-result
            (string.copy (& input-path))
            (svec.clone-vec (& options.stdlib-roots))
            (target_cfg.compiler-target-cfgs-with-names
              target
              (svec.clone-vec (& options.cfgs)))
            "typecheck-prefix-inline-check")
            [(test_cli_core.ResultTlTestInlineCheck.Err message)
              (SelfhostCheckOutcome
                1
                ""
                (text_buf.render (text_buf.append err-buf message)))]
            [(test_cli_core.ResultTlTestInlineCheck.Ok)
              (let
                [report : doc_test.DocTestRunReport
                  (doc_test.doc-test-typecheck-file-with-roots-and-cfg
                    input-path
                    (svec.clone-vec (& options.stdlib-roots))
                    (target_cfg.compiler-target-cfgs-with-names
                      target
                      (svec.clone-vec (& options.cfgs))))]
                [rendered : String (doc_test.doc-test-run-report-render report)]
                (if (source_text.starts-with? (& rendered) "doc tests failed:")
                  (SelfhostCheckOutcome
                    1
                    ""
                    (text_buf.render (text_buf.append err-buf rendered)))
                  (SelfhostCheckOutcome
                    0
                    "Type checking passed!\n"
                    (text_buf.render err-buf))))]))]
      [(Err diag advisories)
        (let
          [err-buf : text_buf.TextBuf
            (selfhost-check-append-diagnostics
              (deref diag)
              (selfhost-check-append-advisories (& advisories) (text_buf.empty)))]
          (SelfhostCheckOutcome 1 "" (text_buf.render err-buf)))])))

(define (selfhost-check-file
  [input-path : String]
  [options : cli_option.CliCompileOptions]) : i64
  (let
    [outcome : SelfhostCheckOutcome
      (selfhost-check-file-outcome input-path (& options))]
    (when
      (> (string.string-length (& outcome.stderr)) 0)
      (io.print-error outcome.stderr))
    (when
      (> (string.string-length (& outcome.stdout)) 0)
      (io.print-format "{}" outcome.stdout))
    outcome.status))

(define (selfhost-check-batch-line-count [text : (& text str)]) : i64
  (let
    [n : i64 (string.string-length text)]
    (if (= n 0)
      0
      (let
        [lines : i64 0]
        (for [i (iterator.range 0 n)]
          (when (= (string.string-ref text i) '\n') (+= lines 1)))
        (if (= (string.string-ref text (- n 1)) '\n')
          lines
          (+ lines 1))))))

(define (selfhost-check-batch-emit-stream [text : (& text str)]) : unit
  (let
    [n : i64 (string.string-length text)]
    (when
      (> n 0)
      (io.print-format "{}" (string.copy text))
      (when
        (not (= (string.string-ref text (- n 1)) '\n'))
        (io.print-format "{}" "\n")))))

(define (selfhost-check-batch-emit-entry
  [index : i64]
  [input-path : (& input-path str)]
  [outcome : SelfhostCheckOutcome]) : unit
  (let
    [out-lines : i64 (selfhost-check-batch-line-count (& outcome.stdout))]
    [err-lines : i64 (selfhost-check-batch-line-count (& outcome.stderr))]
    [header : text_buf.TextBuf (text_buf.empty)]
    (text_buf.append! header "CHECK_BATCH_ENTRY|")
    (text_buf.append-int! header index)
    (text_buf.append! header "|")
    (text_buf.append-int! header outcome.status)
    (text_buf.append! header "|")
    (text_buf.append-int! header out-lines)
    (text_buf.append! header "|")
    (text_buf.append-int! header err-lines)
    (text_buf.append! header "|")
    (text_buf.append! header (string.copy input-path))
    (text_buf.append! header "\n")
    (io.print-format "{}" (text_buf.render header))
    (selfhost-check-batch-emit-stream (& outcome.stdout))
    (selfhost-check-batch-emit-stream (& outcome.stderr))))

(define (selfhost-check-batch-paths-from-text [text : (& text str)]) : svec.Vec
  (let
    [n : i64 (string.string-length text)]
    [start : i64 0]
    [paths : svec.Vec (svec.new)]
    (while (< start n)
      (let
        [line-end : i64 (source_text.line-end text start)]
        [next-start : i64 (source_text.next-line-start text line-end)]
        (when
          (> line-end start)
          (svec.push-ref!
            (&mut paths)
            (string.substring text start (- line-end start))))
        (set! start next-start)))
    paths))

(define (selfhost-check-batch-run-entry
  [index : i64]
  [input-path : (& input-path str)]
  [options : (& options cli_option.CliCompileOptions)]) : unit
  (let
    [entry : test_cli_core.TlTestEntry (test_cli_core.tltest-entry-new)]
    (in-arena
      entry.owner
      (let
        [outcome : SelfhostCheckOutcome
          (selfhost-check-file-outcome (string.copy input-path) options)]
        (selfhost-check-batch-emit-entry index input-path outcome)
        (tc.tc-entry-hidden-names-release!)))
    (test_cli_core.tltest-entry-finish entry 0)
    unit))

(define (selfhost-check-batch
  [batch-path : String]
  [options : cli_option.CliCompileOptions]) : i64
  (match (io.try-read-file (& batch-path))
    [(ErrIoBytes error)
      (io.print-error
        (str_cat.str-cat
          "selfhost-check: failed to read --batch list file: "
          (io.error-message error)
          "\n"))
      1]
    [(OkIoBytes contents)
      (let
        [text : String (byte_buf.to-string contents)]
        [paths : svec.Vec (selfhost-check-batch-paths-from-text (& text))]
        [count : i64 (svec.len (& paths))]
        (if (= count 0)
          (begin
            (io.print-error "selfhost-check: --batch list is empty\n")
            1)
          (begin
            (for [index (iterator.range 0 count)]
              (let
                [path : String (svec.get (& paths) index "")]
                (selfhost-check-batch-run-entry index (& path) (& options))))
            (tc.tc-prefix-snapshot-cache-clear!)
            (io.print-format
              "{}"
              (str_cat.str-cat
                "CHECK_BATCH_END|"
                (string.int->string count)
                "\n"))
            0)))]))

(define (selfhost-check-package-kind-entry?
  [kind : compiler_load.CompilerPkgKind]) : bool
  (match kind
    [(CompilerPkgKindBin) true]
    [(CompilerPkgKindLib) false]))

(define (selfhost-check-package-entry-path
  [manifest-dir : String]
  [manifest : compiler_load.CompilerPkgManifest]) : String
  (compiler_load.compiler-load-normalize-path
    (compiler_load.compiler-load-join-root-path manifest-dir manifest.entry)))

(define (selfhost-check-package-has-inline-tests? [sources : (& svec.Vec)]) : bool
  (for [index (iterator.range 0 (svec.len sources))]
    (when
      (test_cli_core.tltest-source-has-inline-tests?
        (svec.get sources index ""))
      (return true)))
  false)

(define (selfhost-check-package
  [manifest-path : String]
  [has-manifest : bool]
  [options : cli_option.CliCompileOptions]) : i64
  (match (package_source_core.package-source-resolve-manifest
    "check"
    manifest-path
    has-manifest)
    [(Err message)
      (io.print-error message)
      1]
    [(Ok source-set)
      (let
        [manifest : compiler_load.CompilerPkgManifest source-set.manifest]
        [manifest-dir : String source-set.manifest-dir]
        [entry-path : String
          (selfhost-check-package-entry-path
            (owned_view.compiler-owned-shared-view manifest-dir)
            (owned_view.compiler-owned-shared-view manifest))]
        [emit-entry : bool (selfhost-check-package-kind-entry? manifest.kind)]
        [_reset-file-state : unit
          (compiler_driver_core.compiler-driver-reset-file-state!)]
        [job : tc.TcJobState (tc.tc-serial-job-state)]
        [cfgs : sym_i64_env.SymI64Env
          (target_cfg.compiler-target-cfgs-with-names
            options.target
            (svec.clone-vec (& options.cfgs)))]
        [_begin-check : unit
          (compiler_check_core.compiler-check-package-begin! job)]
        [loaded : compiler_load.ResultCompilerLoadWithPaths
          (compiler_load.compiler-load-package-file-with-runtime-cfg
            (& entry-path)
            (& options.stdlib-roots)
            (& manifest-dir)
            (& manifest.deps)
            emit-entry
            cfgs)]
        ;; Reachable paths own their strings and carry no session-local ids.
        [reachable : ast.AstDeclPathList
          (match (& loaded)
            [(Ok _ paths _ seen)
              (compiler_load.compiler-load-package-reachable-paths
                (& entry-path)
                paths
                seen)]
            [(Err _) (ast.ast-decl-path-list-new)])]
        [sources : svec.Vec
          (package_source_core.package-source-reachable-owned-files
            (& reachable)
            (& manifest-dir)
            (& options.stdlib-roots))]
        [checked : compiler_check_core.ResultCompilerCheckWithPaths
          (if (selfhost-check-package-has-inline-tests? (& sources))
            (let
              [status : i64
                (test_cli_core.tltest-inline-typecheck-package-sources-with-cfg
                  sources
                  (svec.clone-vec (& options.stdlib-roots))
                  (string.copy (& manifest-dir))
                  (string.copy (& manifest.name))
                  (compiler_load.clone-compiler-pkg-deps (& manifest.deps))
                  cfgs
                  "typecheck-prefix-inline-check-package")]
              (when (not (= status 0)) (return status))
              ;; Inline preflight resets the loader pools and interned cfg ids.
              (compiler_check_core.compiler-check-package-entry-file-with-roots-and-cfg
                entry-path
                (svec.clone-vec (& options.stdlib-roots))
                (string.copy (& manifest-dir))
                (compiler_load.clone-compiler-pkg-deps (& manifest.deps))
                emit-entry
                (target_cfg.compiler-target-cfgs-with-names
                  options.target
                  (svec.clone-vec (& options.cfgs)))
                job))
            (compiler_check_core.compiler-check-package-loaded
              entry-path
              loaded
              (svec.clone-vec (& options.stdlib-roots))
              cfgs
              job))]
        (match checked
          [(Ok _ _ advisories)
            (compiler_driver_core.compiler-driver-print-advisories
              (& advisories))
            (let
              [_reset-after-entry : unit
                (begin
                  (compiler_driver_core.compiler-driver-reset-file-state!)
                  (ci.intern-persistent-arena-reset!))]
              [doctest-status : i64
                (doc_test.doc-test-report-status
                  (doc_test.doc-test-typecheck-package-paths-with-roots-and-cfg
                    reachable
                    options.stdlib-roots
                    manifest-dir
                    manifest.deps
                    (target_cfg.compiler-target-cfgs-with-names
                      options.target
                      options.cfgs)))]
              (if (= doctest-status 0)
                (selfhost-check-print-passed)
                doctest-status))]
          [(Err diag advisories)
            (compiler_driver_core.compiler-driver-print-advisories
              (& advisories))
            (selfhost-check-report-diagnostics
              (cdiag.compiler-diagnostic-list-box-shared-view diag))
            1]))]))

;; Run the `check` command over arguments starting at `start`.
(define (selfhost-check-run-from [start : i64] [count : i64]) : i64
  (match (selfhost-check-config-from start count)
    [(Ok config)
      (match config
        [(File input-path options) (selfhost-check-file input-path options)]
        [(Batch batch-path options) (selfhost-check-batch batch-path options)]
        [(Package manifest-path has-manifest options)
          (selfhost-check-package manifest-path has-manifest options)])]
    [(Err message)
      (io.print-error message)
      1]))