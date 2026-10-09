;; compile_cli_core.tl - Main-free selfhost compile/check core.
;;
;; Wraps compiler_driver_core.tl's input/output API with the selfhost compile CLI:
;; `compile <file.tl> [-o <file>] [--emit-ir] [--pic] [--no-entry] [--target <target>]
;; [--opt-level <0|1|2>] [--backend-mode scalar] [--stdlib-root <dir>...]
;; [--cfg <name>...] [--profile-allocations]`,
;; plus `check <file.tl> [--stdlib-root <dir>...]`.
;; Bootstrap scripts drive the compiler through this `compile` subcommand.
;; `--backend-mode scalar`, `avx2`, and `avx512` are accepted by the selfhost
;; compiler.
;; `--emit-ir` writes a deterministic TypeLisp-owned IR summary. `--dump-ir`
;; writes textual IR, optionally at an `after-<pass>` boundary; `--trace-passes`
;; and `--verify-ir` expose optimizer diagnostics without changing normal
;; compilation.
;; `--pic` writes runtime-free, no-entry PIC assembly plus `<output>.fixups`.
;; `--no-entry` writes ordinary assembly without a program entry point, for a
;; module that defines no `main` (#7071); it also applies to every `--batch`
;; entry.
;;
;; This is a main-free core (like the other `*_cli_core.tl` modules): the entry
;; `compile-cli-run [count]` dispatches and executes a command, reading `(io.arg 1)`
;; as the command name. The unified `main.tl` dispatcher calls it, so the single
;; binary drives the compiler.
(import compiler_owned_view as owned_view)
(import stdlib.arena)
(import stdlib.byte_buf)
(import stdlib.env)
(import stdlib.io)
(import stdlib.fs)
(import stdlib.vector)
(import (vector.vector String) as cli_svec)
(import cli_option_core as cli_option)
(import compiler_allocation_profile as allocation_profile)
(import compiler_cfg_core as cfg_core)
(import compiler_backend as backend)
(import compiler_diagnostic as cdiag)
(import compiler_load as load)
(import compiler_intern as ci)
(import compiler_ir_types as ir)
(import compiler_optimize as opt)
(import compiler_driver_core)
(import compiler_typecheck_core as tc_core)
(import compiler_windows_coff_core)
(import doc_test)
(import test_cli_core)
(import stdlib.string)
(import source_text_core as source_text)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.text_buf)
(import sym_i64_env)
(cfg
  compile-startup-profile
  (import compiler_startup_profile as startup_profile))

(defenum ResultCompileCliBatchEntryList
  ;; Batch entries are adjacent input/output string pairs in this generated
  ;; vector. Reusing the CLI string vector keeps this hot root within the
  ;; stage-0 compiler's allocation budget.
  (Ok cli_svec.Vec)
  (Err i64))

(defenum ResultCompileCliWindowsBatchEntryList
  ;; Windows artifact rows occupy input/object/assembly/mode slots. `mode` is
  ;; either `auto` (the normalized three-field default) or `force-assembly`.
  (Ok cli_svec.Vec)
  (Err i64))

(defenum ResultCompileCliWindowsBatchEntry
  (Ok String String String)
  (Err i64))

(define compile-cli-allocation-profile-requested : bool
  false)

;; `--no-entry`: emit library assembly without a program entry point.
(define compile-cli-no-entry-requested : bool
  false)
(define compile-cli-dump-ir-requested : bool
  false)
(define compile-cli-dump-ir-pass : String
  "")
(define compile-cli-verify-ir-requested : bool
  false)
(define compile-cli-trace-passes-requested : bool
  false)

(define (compile-cli-cfg-names-to-env [names : (& names cli_svec.Vec)]) : sym_i64_env.SymI64Env
  (let
    [env : sym_i64_env.SymI64Env (cfg_core.compiler-cfg-empty)]
    [index : i64 0]
    (while (< index (cli_svec.len names))
      (set!
        env
        (cfg_core.compiler-cfg-enable env (cli_svec.get names index "")))
      (set! index (+ index 1)))
    env))

(define (compile-cli-cfg-names-to-env-with-intern-state
  [names : (& names cli_svec.Vec)]
  [intern-state : (&mut intern-state ci.InternCompatState)]) : sym_i64_env.SymI64Env
  (let
    [env : sym_i64_env.SymI64Env (cfg_core.compiler-cfg-empty)]
    [index : i64 0]
    (while (< index (cli_svec.len names))
      (set!
        env
        (cfg_core.compiler-cfg-enable-with-intern-state
          env
          (cli_svec.get names index "")
          intern-state))
      (set! index (+ index 1)))
    env))

(defenum CompileCliConfig
  (Config
    String
    String
    bool
    bool
    bool
    backend.CompilerBackendTarget
    cli_svec.Vec
    cli_svec.Vec
    backend.CompilerBackendMode
    i64))

(defenum CompileCliBatchConfig
  (Config
    String
    bool
    backend.CompilerBackendTarget
    cli_svec.Vec
    cli_svec.Vec
    backend.CompilerBackendMode
    i64
    bool
    bool
    String))

(defenum ResultCompileCliConfig
  (Ok CompileCliConfig)
  (Err String))

(defenum ResultCompileCliBatchConfig
  (Ok CompileCliBatchConfig)
  (Err String))

(defenum CompileCliAction
  (Run CompileCliConfig)
  (Batch CompileCliBatchConfig)
  (Error String))

(defenum ResultCompileCliTarget
  (Ok backend.CompilerBackendTarget)
  (Err String))

(define (compile-cli-path-separator? [c : char]) : bool
  (or (= c '/') (= c '\\')))

(define (compile-cli-after-pass? [value : String]) : bool
  (and
    (> (string.string-length value) 6)
    (source_text.starts-with? value "after-")))

(define (compile-cli-default-output-with-extension
  [input-path : String]
  [extension : String]) : String
  (let
    [n : i64 (string.string-length input-path)]
    [i : i64 0]
    [last-dot : i64 -1]
    [last-sep : i64 -1]
    (while (< i n)
      (let
        [c : char (string.string-ref input-path i)]
        (if (= c '.')
          (set! last-dot i)
          (set! last-dot last-dot))
        (if (compile-cli-path-separator? c)
          (set! last-sep i)
          (set! last-sep last-sep))
        (set! i (+ i 1))))
    (if (> last-dot last-sep)
      (str_cat.str-cat (string.substring input-path 0 last-dot) extension)
      (str_cat.str-cat input-path extension))))

(define (compile-cli-default-output [input-path : String]) : String
  (compile-cli-default-output-with-extension input-path ".s"))

(define (compile-cli-default-ir-output [input-path : String]) : String
  (compile-cli-default-output-with-extension input-path ".ir"))

(define (compile-cli-unknown-target [value : String]) : String
  (str_cat.str-cat
    "Error: unknown target '"
    value
    "'. Expected linux-x86_64 or windows-x86_64"))

(define (compile-cli-target [value : String]) : ResultCompileCliTarget
  (if (or (string.eq value "linux-x86_64") (string.eq value "linux_x86_64"))
    (Ok (Linux))
    (if (or
      (string.eq value "windows-x86_64")
      (string.eq value "windows_x86_64"))
      (Ok (Windows))
      (Err (compile-cli-unknown-target value)))))

(define (compile-cli-invalid-opt-level [value : String]) : String
  (str_cat.str-cat
    "compile: invalid --opt-level "
    value
    "; expected 0, 1, or 2"))

;; `--backend-mode` accepts scalar, avx2 and avx512.
(defenum ResultCompileCliBackendMode
  (Ok backend.CompilerBackendMode)
  (Err String))

(define (compile-cli-backend-mode [value : String]) : ResultCompileCliBackendMode
  (cond
    [(string.eq value "scalar") (Ok (Scalar))]
    [(string.eq value "avx2") (Ok (Avx2))]
    [(string.eq value "avx512") (Ok (Avx512))]
    [else
      (Err
        (str_cat.str-cat
          "Error: unknown backend mode '"
          value
          "'. Expected scalar, avx2, or avx512"))]))

;; Options `compile` and `compile --batch` share.
(defstruct CompileCliOptions
  (target backend.CompilerBackendTarget)
  (has-target bool)
  (stdlib-roots cli_svec.Vec)
  (cfgs cli_svec.Vec)
  (opt-level i64)
  (has-opt-level bool)
  (backend-mode backend.CompilerBackendMode))

(define (compile-cli-options) : CompileCliOptions
  (CompileCliOptions
    (Linux)
    false
    (cli_svec.new)
    (cli_svec.new)
    (opt.compiler-optimize-default-level)
    false
    (Scalar)))

;; Apply an option both compile modes accept. False when the current option
;; is another one.
(define (compile-cli-common-option!
  [options : (&mut options CompileCliOptions)]
  [args : (&mut args cli_option.CliArgs)]) : bool
  (cond
    [(string.eq args.name "--stdlib-root")
      (cli_svec.push-ref!
        (&mut options.stdlib-roots)
        (cli_option.cli-args-value args))
      true]
    [(string.eq args.name "--cfg")
      (cli_svec.push-ref! (&mut options.cfgs) (cli_option.cli-args-value args))
      true]
    [(string.eq args.name "--target")
      (if options.has-target
        (cli_option.cli-args-fail!
          args
          "compile: --target was provided more than once")
        (match (compile-cli-target (cli_option.cli-args-value args))
          [(Ok parsed-target)
            (set! options.target parsed-target)
            (set! options.has-target true)]
          [(Err message) (cli_option.cli-args-fail! args message)]))
      true]
    [(string.eq args.name "--opt-level")
      (let
        [value : String (cli_option.cli-args-value args)]
        [level : i64 (cli_option.cli-option-opt-level (& value))]
        (cond
          [options.has-opt-level
            (cli_option.cli-args-fail!
              args
              "compile: --opt-level was provided more than once")]
          [(< level 0)
            (cli_option.cli-args-fail!
              args
              (compile-cli-invalid-opt-level value))]
          [else
            (set! options.opt-level level)
            (set! options.has-opt-level true)])
        true)]
    [(string.eq args.name "--debug")
      (ir.compiler-debug-info-set-enabled! true)
      true]
    [(string.eq args.name "--backend-mode")
      (match (compile-cli-backend-mode (cli_option.cli-args-value args))
        [(Ok parsed-mode) (set! options.backend-mode parsed-mode)]
        [(Err message) (cli_option.cli-args-fail! args message)])
      true]
    [(string.eq args.name "--profile-allocations")
      (if compile-cli-allocation-profile-requested
        (cli_option.cli-args-fail!
          args
          "compile: --profile-allocations was provided more than once")
        (set! compile-cli-allocation-profile-requested true))
      true]
    [else false]))

(define (compile-cli-unknown-argument! [args : (&mut args cli_option.CliArgs)]) : unit
  (if (cli_option.cli-flag? args.arg)
    (cli_option.cli-args-fail-arg! args "compile: unknown flag ")
    (cli_option.cli-args-fail-arg! args "compile: unexpected argument ")))

(define (compile-cli-no-entry-option! [args : (&mut args cli_option.CliArgs)]) : unit
  (if compile-cli-no-entry-requested
    (cli_option.cli-args-fail!
      args
      "compile: --no-entry was provided more than once")
    (set! compile-cli-no-entry-requested true)))

(define (compile-cli-config-from [input-idx : i64] [count : i64]) : ResultCompileCliConfig
  (cond
    [(>= input-idx count) (Err "compile: expected source path")]
    [(cli_option.cli-flag? (io.arg input-idx))
      (Err "compile: expected source path before flags")]
    [else
      (let
        [input-path : String (io.arg input-idx)]
        [args : cli_option.CliArgs
          (cli_option.cli-args
            "compile"
            "--stdlib-root <dir> --cfg <name> --target <target> --opt-level <0|1|2>
             --debug|-g|--backtrace --backend-mode <mode> --profile-allocations
             -o <file> --pic --no-entry --emit-ir --dump-ir --verify-ir
             --trace-passes"
            (+ input-idx 1)
            count)]
        [options : CompileCliOptions (compile-cli-options)]
        [output-path : String
          (compile-cli-default-output (string.copy (& input-path)))]
        [has-output : bool false]
        [emit-ir : bool false]
        [pic : bool false]
        (while (cli_option.cli-args-next! (&mut args))
          (unless
            (compile-cli-common-option! (&mut options) (&mut args))
            (cond
              [(string.eq args.name "-o")
                (if has-output
                  (cli_option.cli-args-fail!
                    (&mut args)
                    "compile: -o was provided more than once")
                  (begin
                    (set! output-path (cli_option.cli-args-value (& args)))
                    (set! has-output true)))]
              [(string.eq args.name "--pic") (set! pic true)]
              [(string.eq args.name "--no-entry")
                (compile-cli-no-entry-option! (&mut args))]
              [(and
                  emit-ir
                  (or
                    (string.eq args.name "--emit-ir")
                    (string.eq args.name "--dump-ir")))
                (cli_option.cli-args-fail!
                  (&mut args)
                  "compile: IR output was requested more than once")]
              [(string.eq args.name "--emit-ir") (set! emit-ir true)]
              [(string.eq args.name "--dump-ir")
                (set! compile-cli-dump-ir-requested true)
                (set! compile-cli-dump-ir-pass "")
                ;; An optional `after-<pass>` value selects the dump point.
                (when
                  (and
                    (< args.next count)
                    (compile-cli-after-pass? (io.arg args.next)))
                  (let
                    [value : String (io.arg args.next)]
                    (set!
                      compile-cli-dump-ir-pass
                      (string.substring
                        value
                        6
                        (- (string.string-length value) 6)))
                    (set! args.next (+ args.next 1))))
                (set! emit-ir true)]
              [(string.eq args.name "--verify-ir")
                (if compile-cli-verify-ir-requested
                  (cli_option.cli-args-fail!
                    (&mut args)
                    "compile: --verify-ir was provided more than once")
                  (begin
                    (set! compile-cli-verify-ir-requested true)
                    (ir.compiler-debug-type-graph-verify-set! true)))]
              [(string.eq args.name "--trace-passes")
                (if compile-cli-trace-passes-requested
                  (cli_option.cli-args-fail!
                    (&mut args)
                    "compile: --trace-passes was provided more than once")
                  (set! compile-cli-trace-passes-requested true))]
              [else (compile-cli-unknown-argument! (&mut args))])))
        (cond
          [args.failed (Err args.error)]
          [(and emit-ir pic)
            (Err "compile: --pic cannot be combined with --emit-ir")]
          [(and compile-cli-no-entry-requested pic)
            (Err
              "compile: --no-entry cannot be combined with --pic, whose assembly never has an entry")]
          [(and compile-cli-no-entry-requested emit-ir)
            (Err
              "compile: --no-entry selects assembly output and cannot be combined with --emit-ir or --dump-ir")]
          [else
            (Ok
              (CompileCliConfig.Config
                (string.copy (& input-path))
                (if (and emit-ir (not has-output))
                  (compile-cli-default-ir-output input-path)
                  output-path)
                emit-ir
                pic
                options.has-target
                options.target
                options.stdlib-roots
                options.cfgs
                options.backend-mode
                options.opt-level))]))]))

(define (compile-cli-batch-config-from [batch-path-idx : i64] [count : i64]) : ResultCompileCliBatchConfig
  (if (or
    (>= batch-path-idx count)
    (cli_option.cli-flag? (io.arg batch-path-idx)))
    (Err "compile: --batch requires a list file")
    (let
      [batch-path : String (io.arg batch-path-idx)]
      [args : cli_option.CliArgs
        (cli_option.cli-args
          "compile"
          "--stdlib-root <dir> --cfg <name> --target <target> --opt-level <0|1|2>
           --debug|-g|--backtrace --backend-mode <mode> --profile-allocations
           -o --emit-ir --pic --no-entry --prefix-cache-stats --windows-coff-plan"
          (+ batch-path-idx 1)
          count)]
      [options : CompileCliOptions (compile-cli-options)]
      [prefix-cache-stats : bool false]
      [has-windows-coff-plan : bool false]
      [windows-coff-plan-path : String ""]
      (while (cli_option.cli-args-next! (&mut args))
        (unless
          (compile-cli-common-option! (&mut options) (&mut args))
          (cond
            [(string.eq args.name "-o")
              (cli_option.cli-args-fail!
                (&mut args)
                "compile: --batch reads output paths from the batch file")]
            [(string.eq args.name "--emit-ir")
              (cli_option.cli-args-fail!
                (&mut args)
                "compile: --batch does not support --emit-ir")]
            [(string.eq args.name "--pic")
              (cli_option.cli-args-fail!
                (&mut args)
                "compile: --batch does not support --pic")]
            [(string.eq args.name "--no-entry")
              (compile-cli-no-entry-option! (&mut args))]
            [(string.eq args.name "--prefix-cache-stats")
              (set! prefix-cache-stats true)]
            ;; The result path is taken by hand: a duplicate is reported
            ;; before a missing path, and a flag is no path.
            [(string.eq args.name "--windows-coff-plan")
              (cond
                [has-windows-coff-plan
                  (cli_option.cli-args-fail!
                    (&mut args)
                    "compile: --windows-coff-plan was provided more than once")]
                [(or
                    (>= args.next count)
                    (cli_option.cli-flag? (io.arg args.next)))
                  (cli_option.cli-args-fail!
                    (&mut args)
                    "compile: --windows-coff-plan requires a result path")]
                [else
                  (set! windows-coff-plan-path (io.arg args.next))
                  (set! has-windows-coff-plan true)
                  (set! args.next (+ args.next 1))])]
            [else (compile-cli-unknown-argument! (&mut args))])))
      (cond
        [args.failed (Err args.error)]
        [(and
            has-windows-coff-plan
            (or
              (not options.has-target)
              (not (backend.compiler-backend-target-windows? options.target))))
          (Err "compile: --windows-coff-plan requires --target windows-x86_64")]
        [(and
            has-windows-coff-plan
            (string.eq batch-path windows-coff-plan-path))
          (Err
            "compile: --windows-coff-plan result path must differ from the batch input")]
        [else
          (Ok
            (CompileCliBatchConfig.Config
              batch-path
              options.has-target
              options.target
              options.stdlib-roots
              options.cfgs
              options.backend-mode
              options.opt-level
              prefix-cache-stats
              has-windows-coff-plan
              windows-coff-plan-path))]))))

;; `compile-cli-run` serves only `typelisp compile`.
(define (compile-cli-dispatch [count : i64]) : CompileCliAction
  (if (and (> count 2) (string.eq (io.arg 2) "--batch"))
    (match (compile-cli-batch-config-from 3 count)
      [(Ok config) (Batch config)]
      [(Err message) (Error message)])
    (match (compile-cli-config-from 2 count)
      [(Ok config) (Run config)]
      [(Err message) (Error message)])))

(define (compile-cli-print-ir-verification-error [message : String]) : unit
  (io.print-error
    (str_cat.str-cat "compile: IR verification failed: " message "\n")))

(define (compile-cli-reject-result-on-ir-verification
  [result : compiler_driver_core.ResultCompilerDriver]
  [message : String]) : i64
  (match result
    [(Ok _ advisories)
      (compiler_driver_core.compiler-driver-print-advisories (& advisories))]
    [(Err _ advisories)
      (compiler_driver_core.compiler-driver-print-advisories (& advisories))])
  (compile-cli-print-ir-verification-error message)
  1)

(define (compile-cli-reject-buffer-result-on-ir-verification
  [result : compiler_driver_core.ResultCompilerDriverBuffer]
  [message : String]) : i64
  (match result
    [(Ok _ advisories)
      (compiler_driver_core.compiler-driver-print-advisories (& advisories))]
    [(Err _ advisories)
      (compiler_driver_core.compiler-driver-print-advisories (& advisories))])
  (compile-cli-print-ir-verification-error message)
  1)

(define (compile-cli-reject-pic-result-on-ir-verification
  [result : compiler_driver_core.ResultCompilerDriverPic]
  [message : String]) : i64
  (match result
    [(Ok _ advisories)
      (compiler_driver_core.compiler-driver-print-advisories (& advisories))]
    [(Err _ advisories)
      (compiler_driver_core.compiler-driver-print-advisories (& advisories))])
  (compile-cli-print-ir-verification-error message)
  1)

(define (compile-cli-write-result-with-ir-verification
  [state : compiler_driver_core.CompilerDriverState]
  [result : compiler_driver_core.ResultCompilerDriver]
  [output-path : String]) : i64
  (let
    [message : String (opt.compiler-opt-debug-verification-error)]
    (if (> (string.string-length message) 0)
      (compile-cli-reject-result-on-ir-verification result message)
      (compiler_driver_core.compiler-driver-write-result
        (compiler_driver_core.compiler-driver-state-profile state)
        result
        output-path))))

(define (compile-cli-write-buffer-result-with-ir-verification
  [state : compiler_driver_core.CompilerDriverState]
  [result : compiler_driver_core.ResultCompilerDriverBuffer]
  [output-path : String]) : i64
  (let
    [message : String (opt.compiler-opt-debug-verification-error)]
    (if (> (string.string-length message) 0)
      (compile-cli-reject-buffer-result-on-ir-verification result message)
      (compiler_driver_core.compiler-driver-write-buffer-result
        (compiler_driver_core.compiler-driver-state-profile state)
        (compiler_driver_core.compiler-driver-state-typecheck state)
        result
        output-path))))

(define (compile-cli-write-pic-result-with-ir-verification
  [state : compiler_driver_core.CompilerDriverState]
  [result : compiler_driver_core.ResultCompilerDriverPic]
  [output-path : String]) : i64
  (let
    [message : String (opt.compiler-opt-debug-verification-error)]
    (if (> (string.string-length message) 0)
      (compile-cli-reject-pic-result-on-ir-verification result message)
      (compiler_driver_core.compiler-driver-write-pic-result
        (compiler_driver_core.compiler-driver-state-profile state)
        result
        output-path))))

;; Whether this `compile` asks for the Linux shared-object code model
;; (#8257). The cdylib target (#7481) will select it; until then this variable
;; is the test hook scripts/verify-linux-shared-object-code-model.sh drives it
;; with.
(define (compile-cli-shared-object-env-name) : String
  "TYPELISP_BACKEND_CODE_MODEL")

(define (compile-cli-shared-object-requested?) : bool
  (match (env.get (& (compile-cli-shared-object-env-name)))
    [(EnvSomeString value) (string.eq value "shared-object")]
    [(EnvNoString) false]))

(define (compile-cli-run-compile-file
  [state : compiler_driver_core.CompilerDriverState]
  [input-path : String]
  [output-path : String]
  [emit-ir : bool]
  [pic : bool]
  ;; lint-allow: unused-variable
  [has-target : bool]
  [target : backend.CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [cfgs : (& cfgs cli_svec.Vec)]
  [backend-mode : backend.CompilerBackendMode]
  [opt-level : i64]
  [inline-preflight : bool]) : i64
  (begin
    ;; Doctest and inline preflight still enter the standalone compiler-check
    ;; call graph before this job's state-aware reset. Make that residual
    ;; compatibility boundary explicit instead of relying on the previous
    ;; batch entry's cleanup to leave these globals installed.
    ;; A fresh state must advance its generation before installation: otherwise
    ;; process-level parser caches from CLI startup can mistake generation zero
    ;; for their owner and reuse ids from the bootstrap compatibility table.
    (if (=
      (compiler_driver_core.compiler-driver-state-intern-generation state)
      0)
      (ci.intern-compat-state-reset!
        (compiler_driver_core.compiler-driver-state-owned-interns-mut
          (owned_view.compiler-owned-shared-view state)))
      unit)
    (compiler_driver_core.compiler-driver-state-install-pools! state)
    (compiler_driver_core.compiler-driver-state-install-interns! state)
    (cfg
      compile-startup-profile
      (startup_profile.compiler-startup-profile-mark-preflight-begin!)
      unit)
    (let
      [doctest-status : i64
        (doc_test.doc-test-typecheck-file-status
          (owned_view.compiler-owned-shared-view input-path)
          (owned_view.compiler-owned-shared-view stdlib-roots))]
      (if (= doctest-status 0)
        (let
          [inline-test-status : i64
            (if inline-preflight
              (test_cli_core.tltest-inline-typecheck-file-with-cfg
                (owned_view.compiler-owned-shared-view input-path)
                (owned_view.compiler-owned-shared-view stdlib-roots)
                (compiler_driver_core.compiler-driver-target-cfgs
                  target
                  (compile-cli-cfg-names-to-env cfgs))
                "typecheck-prefix-inline-compile")
              0)]
          [_preflight-end : unit
            (cfg
              compile-startup-profile
              (startup_profile.compiler-startup-profile-mark-preflight-end!)
              unit)]
          (if (= inline-test-status 0)
            (begin
              (compiler_driver_core.compiler-driver-state-reset-file-state!
                (owned_view.compiler-owned-shared-view state))
              (opt.compiler-opt-debug-configure!
                (compiler_driver_core.compiler-driver-state-entry-structural-session
                  (owned_view.compiler-owned-shared-view state))
                compile-cli-trace-passes-requested
                (string.copy (& compile-cli-dump-ir-pass))
                compile-cli-verify-ir-requested)
              (backend.compiler-backend-state-set-shared-object-code-model!
                (compiler_driver_core.compiler-driver-state-backend (& state))
                (compile-cli-shared-object-requested?))
              (let
                [emit-cfgs : sym_i64_env.SymI64Env
                  (compile-cli-cfg-names-to-env-with-intern-state
                    cfgs
                    (compiler_driver_core.compiler-driver-state-owned-interns-mut
                      (owned_view.compiler-owned-shared-view state)))]
                [_file-state-reset-end : unit
                  (cfg
                    compile-startup-profile
                    (startup_profile.compiler-startup-profile-mark-file-state-reset-end!)
                    unit)]
                [status : i64
                  (begin
                    (cfg
                      compile-startup-profile
                      (startup_profile.compiler-startup-profile-mark-compile-driver-start!)
                      unit)
                    (if emit-ir
                      (compile-cli-write-result-with-ir-verification
                        (owned_view.compiler-owned-shared-view state)
                        (if compile-cli-dump-ir-requested
                          (compiler_driver_core.compiler-driver-state-emit-ir-text-file-with-target-roots-level-mode-and-cfg
                            (owned_view.compiler-owned-shared-view state)
                            input-path
                            target
                            stdlib-roots
                            opt-level
                            backend-mode
                            emit-cfgs
                            (string.copy (& compile-cli-dump-ir-pass)))
                          (compiler_driver_core.compiler-driver-state-emit-ir-summary-file-with-target-roots-level-mode-and-cfg
                            (owned_view.compiler-owned-shared-view state)
                            input-path
                            target
                            stdlib-roots
                            opt-level
                            backend-mode
                            emit-cfgs))
                        output-path)
                      (if pic
                        (compile-cli-write-pic-result-with-ir-verification
                          (owned_view.compiler-owned-shared-view state)
                          (compiler_driver_core.compiler-driver-state-emit-file-pic-with-target-roots-level-mode-and-cfg
                            (owned_view.compiler-owned-shared-view state)
                            input-path
                            target
                            true
                            stdlib-roots
                            opt-level
                            backend-mode
                            emit-cfgs)
                          output-path)
                        (compile-cli-write-buffer-result-with-ir-verification
                          (owned_view.compiler-owned-shared-view state)
                          (compiler_driver_core.compiler-driver-state-emit-file-buffer-with-target-roots-level-mode-and-cfg
                            (owned_view.compiler-owned-shared-view state)
                            input-path
                            target
                            true
                            stdlib-roots
                            opt-level
                            backend-mode
                            emit-cfgs
                            (not compile-cli-no-entry-requested))
                          output-path))))]
                (compiler_driver_core.compiler-driver-state-capture-session-floors!
                  state)
                status))
            inline-test-status))
        (begin
          (cfg
            compile-startup-profile
            (startup_profile.compiler-startup-profile-mark-preflight-end!)
            unit)
          doctest-status)))))

(define (compile-cli-reject-windows-batch-artifact-on-ir-verification
  [result : compiler_windows_coff_core.ResultCompilerWindowsBatchArtifact]
  [message : String]) : ResultCompileCliWindowsBatchEntry
  (match result
    [(CoffObject _ _ advisories)
      (compiler_driver_core.compiler-driver-print-advisories (& advisories))]
    [(Assembly _ _ advisories)
      (compiler_driver_core.compiler-driver-print-advisories (& advisories))]
    [(Err _ advisories)
      (compiler_driver_core.compiler-driver-print-advisories (& advisories))])
  (compile-cli-print-ir-verification-error message)
  (Err 1))

(define (compile-cli-write-windows-batch-artifact
  [_state : compiler_driver_core.CompilerDriverState]
  [result : compiler_windows_coff_core.ResultCompilerWindowsBatchArtifact]
  [object-path : String]
  [assembly-path : String]) : ResultCompileCliWindowsBatchEntry
  (if (> (string.string-length (opt.compiler-opt-debug-verification-error)) 0)
    (compile-cli-reject-windows-batch-artifact-on-ir-verification
      result
      (opt.compiler-opt-debug-verification-error))
    (match result
      [(CoffObject object _ advisories)
        (let
          [write-status : i64
            (begin
              (compiler_driver_core.compiler-driver-print-advisories
                (& advisories))
              (cfg
                compile-profile
                (compiler_driver_core.compiler-driver-profile-start-phase
                  (compiler_driver_core.compiler-driver-state-profile _state)))
              (match (io.try-write-file
                (& object-path)
                (byte_buf.str-as-bytes (& object)))
                [(OkIoUnit) 0]
                [(ErrIoUnit error)
                  (io.print-error
                    (str_cat.str-cat
                      "compile: cannot write "
                      (owned_view.compiler-owned-shared-view object-path)
                      ": "
                      (io.error-message error)
                      "\n"))
                  1]))]
          (begin
            (cfg
              compile-profile
              (compiler_driver_core.compiler-driver-profile-finish-phase
                (compiler_driver_core.compiler-driver-state-profile _state)
                "write"))
            (compiler_driver_core.compiler-driver-allocation-profile-snapshot-for-job!
              (compiler_driver_core.compiler-driver-state-typecheck _state)
              "write")
            (cfg
              compile-profile
              (compiler_driver_core.compiler-driver-profile-finish-total
                (compiler_driver_core.compiler-driver-state-profile _state)))
            (if (= write-status 0)
              (begin
                (io.print-format
                  "{}"
                  (str_cat.str-cat
                    "Wrote "
                    (owned_view.compiler-owned-shared-view object-path)
                    "\n"))
                (Ok "coff-object" object-path "none"))
              (Err write-status))))]
      [(Assembly asm category advisories)
        (let
          [write-status : i64
            (begin
              (compiler_driver_core.compiler-driver-print-advisories
                (& advisories))
              (cfg
                compile-profile
                (compiler_driver_core.compiler-driver-profile-start-phase
                  (compiler_driver_core.compiler-driver-state-profile _state)))
              (compiler_driver_core.compiler-driver-write-text-buf
                (owned_view.compiler-owned-shared-view assembly-path)
                asm))]
          (begin
            (cfg
              compile-profile
              (compiler_driver_core.compiler-driver-profile-finish-phase
                (compiler_driver_core.compiler-driver-state-profile _state)
                "write"))
            (compiler_driver_core.compiler-driver-allocation-profile-snapshot-for-job!
              (compiler_driver_core.compiler-driver-state-typecheck _state)
              "write")
            (cfg
              compile-profile
              (compiler_driver_core.compiler-driver-profile-finish-total
                (compiler_driver_core.compiler-driver-state-profile _state)))
            (if (= write-status 0)
              (begin
                (io.print-format
                  "{}"
                  (str_cat.str-cat
                    "Wrote "
                    (owned_view.compiler-owned-shared-view assembly-path)
                    "\n"))
                (Ok
                  "assembly"
                  assembly-path
                  (backend.compiler-direct-object-fallback-category category)))
              (Err write-status))))]
      [(Err diag advisories)
        (begin
          (compiler_driver_core.compiler-driver-print-advisories (& advisories))
          (compiler_driver_core.compiler-driver-allocation-profile-snapshot-for-job!
            (compiler_driver_core.compiler-driver-state-typecheck _state)
            "write-error")
          (cfg
            compile-profile
            (compiler_driver_core.compiler-driver-profile-finish-total
              (compiler_driver_core.compiler-driver-state-profile _state)))
          (io.print-error
            (compiler_driver_core.compiler-driver-render-source-diagnostic
              (cdiag.compiler-diagnostic-box-shared-view diag)))
          (Err 1))])))

(define (compile-cli-run-windows-batch-file
  [state : compiler_driver_core.CompilerDriverState]
  [input-path : String]
  [object-path : String]
  [assembly-path : String]
  [force-assembly : bool]
  [stdlib-roots : cli_svec.Vec]
  [cfgs : (& cfgs cli_svec.Vec)]
  [backend-mode : backend.CompilerBackendMode]
  [opt-level : i64]) : ResultCompileCliWindowsBatchEntry
  (begin
    ;; Match the legacy batch entry lifecycle exactly through the one-lowering
    ;; driver boundary. The selected bytes are written before the caller tears
    ;; down this entry's scratch arena.
    (if (=
      (compiler_driver_core.compiler-driver-state-intern-generation state)
      0)
      (ci.intern-compat-state-reset!
        (compiler_driver_core.compiler-driver-state-owned-interns-mut
          (owned_view.compiler-owned-shared-view state)))
      unit)
    (compiler_driver_core.compiler-driver-state-install-pools! state)
    (compiler_driver_core.compiler-driver-state-install-interns! state)
    (cfg
      compile-startup-profile
      (startup_profile.compiler-startup-profile-mark-preflight-begin!)
      unit)
    (let
      [doctest-status : i64
        (doc_test.doc-test-typecheck-file-status
          (owned_view.compiler-owned-shared-view input-path)
          (owned_view.compiler-owned-shared-view stdlib-roots))]
      (if (= doctest-status 0)
        (begin
          (cfg
            compile-startup-profile
            (startup_profile.compiler-startup-profile-mark-preflight-end!)
            unit)
          (compiler_driver_core.compiler-driver-state-reset-file-state!
            (owned_view.compiler-owned-shared-view state))
          (opt.compiler-opt-debug-configure!
            (compiler_driver_core.compiler-driver-state-entry-structural-session
              (owned_view.compiler-owned-shared-view state))
            compile-cli-trace-passes-requested
            (string.copy (& compile-cli-dump-ir-pass))
            compile-cli-verify-ir-requested)
          (let
            [emit-cfgs : sym_i64_env.SymI64Env
              (compile-cli-cfg-names-to-env-with-intern-state
                cfgs
                (compiler_driver_core.compiler-driver-state-owned-interns-mut
                  (owned_view.compiler-owned-shared-view state)))]
            [_file-state-reset-end : unit
              (cfg
                compile-startup-profile
                (startup_profile.compiler-startup-profile-mark-file-state-reset-end!)
                unit)]
            [result : ResultCompileCliWindowsBatchEntry
              (begin
                (cfg
                  compile-startup-profile
                  (startup_profile.compiler-startup-profile-mark-compile-driver-start!)
                  unit)
                (compile-cli-write-windows-batch-artifact
                  (owned_view.compiler-owned-shared-view state)
                  (compiler_windows_coff_core.compiler-windows-batch-state-emit-file
                    (owned_view.compiler-owned-shared-view state)
                    input-path
                    stdlib-roots
                    opt-level
                    backend-mode
                    emit-cfgs
                    (not compile-cli-no-entry-requested)
                    force-assembly)
                  object-path
                  assembly-path))]
            (compiler_driver_core.compiler-driver-state-capture-session-floors!
              state)
            result))
        (begin
          (cfg
            compile-startup-profile
            (startup_profile.compiler-startup-profile-mark-preflight-end!)
            unit)
          (Err doctest-status))))))

(define (compile-cli-run-batch-inline-tests-from
  [entries : (& entries cli_svec.Vec)]
  [index : i64]
  [stride : i64]
  [target : backend.CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [cfgs : (& cfgs cli_svec.Vec)]
  [ran-preflight : bool]) : i64
  (if (>= index (cli_svec.len entries))
    (if ran-preflight
      (begin
        ;; Detach the final preflight's loaded AST before its scratch owner is
        ;; gone and before the separate batch driver state is installed.
        (test_cli_core.tltest-inline-clear-load-only-caches!)
        (compiler_driver_core.compiler-driver-reset-file-state!)
        0)
      0)
    (let
      [input-path : String (cli_svec.get entries index "")]
      [has-inline-tests
        : bool
        ;; The predicate reads the whole source. Keep that transient buffer in
        ;; the same per-source lifetime as the optional inline typecheck instead
        ;; of retaining every manifest source in the batch caller arena.
        (with-scratch
          (test_cli_core.tltest-source-has-inline-tests?
            (owned_view.compiler-owned-shared-view input-path)))]
      [status
        : i64
        ;; Match package inline preflight isolation: each source owns a
        ;; destroyable scratch chain and starts from a full file reset. Rebuild
        ;; cfg ids inside that reset because intern generations are per entry.
        (if has-inline-tests
          (with-scratch
            (test_cli_core.tltest-inline-clear-load-only-caches!)
            (compiler_driver_core.compiler-driver-reset-file-state!)
            (test_cli_core.tltest-inline-typecheck-file-with-cfg
              (owned_view.compiler-owned-shared-view input-path)
              (owned_view.compiler-owned-shared-view stdlib-roots)
              (compiler_driver_core.compiler-driver-target-cfgs
                target
                (compile-cli-cfg-names-to-env cfgs))
              "typecheck-prefix-inline-compile-batch"))
          0)]
      ;; `compiler-load-default-session-use!` copies the active session wrapper
      ;; into the current arena. The preflight reset therefore leaves that
      ;; wrapper scratch-owned even though its default session data is stable.
      ;; Reinstall it after `with-scratch` has restored the enclosing arena.
      [_restore-default-session : unit
        (if has-inline-tests
          (load.compiler-load-default-session-use!)
          unit)]
      [_clear-entry : unit
        (if has-inline-tests
          (test_cli_core.tltest-inline-clear-load-caches!)
          unit)]
      (if (= status 0)
        (compile-cli-run-batch-inline-tests-from
          entries
          (+ index stride)
          stride
          target
          stdlib-roots
          cfgs
          (or ran-preflight has-inline-tests))
        (begin
          (io.print-error
            (str_cat.str-cat "\ncompile: batch source failed: " input-path "\n"))
          status)))))

(define (compile-cli-run-batch-inline-tests
  [entries : (& entries cli_svec.Vec)]
  [target : backend.CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [cfgs : (& cfgs cli_svec.Vec)]) : i64
  (compile-cli-run-batch-inline-tests-from
    (& entries)
    0
    2
    target
    stdlib-roots
    cfgs
    false))

(define (compile-cli-run-windows-batch-inline-tests
  [entries : (& entries cli_svec.Vec)]
  [target : backend.CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [cfgs : (& cfgs cli_svec.Vec)]) : i64
  (compile-cli-run-batch-inline-tests-from
    (& entries)
    0
    4
    target
    stdlib-roots
    cfgs
    false))

(define (compile-cli-batch-find-separator
  [text : (& text str)]
  [start : i64]
  [end : i64]) : i64
  (let
    [i : i64 start]
    [found : i64 -1]
    (while (and (= found -1) (< i end))
      (if (= (string.string-ref text i) '|')
        (set! found i)
        (set! i (+ i 1))))
    found))

(define (compile-cli-batch-line-error [line : i64] [message : String]) : i64
  (io.print-error
    (str_cat.str-cat
      "compile: malformed --batch line "
      (string.int->string line)
      ": "
      message
      "\n"))
  1)

(define (compile-cli-batch-parse-entries-into!
  [text : String]
  [start : i64]
  [line : i64]
  [n : i64]
  [entries : (&mut entries cli_svec.Vec)]) : i64
  (if (>= start n)
    0
    (let
      [line-end : i64 (source_text.line-end text start)]
      [next-start : i64 (source_text.next-line-start text line-end)]
      (if (= start line-end)
        (compile-cli-batch-parse-entries-into!
          text
          next-start
          (+ line 1)
          n
          entries)
        (let
          [sep : i64 (compile-cli-batch-find-separator text start line-end)]
          (if (< sep 0)
            (compile-cli-batch-line-error line "expected input|output")
            (let
              [output-start : i64 (+ sep 1)]
              (if (= start sep)
                (compile-cli-batch-line-error line "missing input path")
                (if (= output-start line-end)
                  (compile-cli-batch-line-error line "missing output path")
                  (let
                    [input-path : String
                      (string.substring text start (- sep start))]
                    [output-path : String
                      (string.substring
                        text
                        output-start
                        (- line-end output-start))]
                    (cli_svec.push-ref! entries input-path)
                    (cli_svec.push-ref! entries output-path)
                    (compile-cli-batch-parse-entries-into!
                      text
                      next-start
                      (+ line 1)
                      n
                      entries)))))))))))

(define (compile-cli-batch-parse-entries-from
  [text : String]
  [start : i64]
  [line : i64]
  [n : i64]) : ResultCompileCliBatchEntryList
  (let
    [entries : cli_svec.Vec (cli_svec.new)]
    [status : i64
      (compile-cli-batch-parse-entries-into! text start line n (&mut entries))]
    (if (= status 0)
      (Ok entries)
      (Err status))))

(define (compile-cli-windows-batch-parse-entries-into!
  [text : (& text str)]
  [start : i64]
  [line : i64]
  [n : i64]
  [entries : (&mut entries cli_svec.Vec)]) : i64
  (if (>= start n)
    0
    (let
      [line-end : i64 (source_text.line-end text start)]
      [next-start : i64 (source_text.next-line-start text line-end)]
      (if (= start line-end)
        (compile-cli-windows-batch-parse-entries-into!
          text
          next-start
          (+ line 1)
          n
          entries)
        (let
          [input-sep : i64
            (compile-cli-batch-find-separator text start line-end)]
          (if (< input-sep 0)
            (compile-cli-batch-line-error
              line
              "expected input|object|assembly[|force-assembly]")
            (let
              [object-start : i64 (+ input-sep 1)]
              [object-sep : i64
                (compile-cli-batch-find-separator text object-start line-end)]
              (if (= start input-sep)
                (compile-cli-batch-line-error line "missing input path")
                (if (< object-sep 0)
                  (compile-cli-batch-line-error line "missing assembly path")
                  (let
                    [assembly-start : i64 (+ object-sep 1)]
                    [mode-sep : i64
                      (compile-cli-batch-find-separator
                        text
                        assembly-start
                        line-end)]
                    [assembly-end : i64
                      (if (< mode-sep 0)
                        line-end
                        mode-sep)]
                    (if (= object-start object-sep)
                      (compile-cli-batch-line-error line "missing object path")
                      (if (= assembly-start assembly-end)
                        (compile-cli-batch-line-error
                          line
                          "missing assembly path")
                        (let
                          [mode-start : i64
                            (if (< mode-sep 0)
                              line-end
                              (+ mode-sep 1))]
                          [extra-sep : i64
                            (if (< mode-sep 0)
                              -1
                              (compile-cli-batch-find-separator
                                text
                                mode-start
                                line-end))]
                          [mode : String
                            (if (< mode-sep 0)
                              "auto"
                              (string.substring
                                text
                                mode-start
                                (- line-end mode-start)))]
                          (if (>= extra-sep 0)
                            (compile-cli-batch-line-error
                              line
                              "too many fields")
                            (if (and
                              (>= mode-sep 0)
                              (not (string.eq mode "force-assembly")))
                              (compile-cli-batch-line-error
                                line
                                "mode must be force-assembly")
                              (let
                                [input-path : String
                                  (string.substring
                                    text
                                    start
                                    (- input-sep start))]
                                [object-path : String
                                  (string.substring
                                    text
                                    object-start
                                    (- object-sep object-start))]
                                [assembly-path : String
                                  (string.substring
                                    text
                                    assembly-start
                                    (- assembly-end assembly-start))]
                                (cli_svec.push-ref! entries input-path)
                                (cli_svec.push-ref! entries object-path)
                                (cli_svec.push-ref! entries assembly-path)
                                (cli_svec.push-ref! entries mode)
                                (compile-cli-windows-batch-parse-entries-into!
                                  text
                                  next-start
                                  (+ line 1)
                                  n
                                  entries)))))))))))))))))

(define (compile-cli-windows-batch-parse-entries-from
  [text : (& text str)]
  [start : i64]
  [line : i64]
  [n : i64]) : ResultCompileCliWindowsBatchEntryList
  (let
    [entries : cli_svec.Vec (cli_svec.new)]
    [status : i64
      (compile-cli-windows-batch-parse-entries-into!
        text
        start
        line
        n
        (&mut entries))]
    (if (= status 0)
      (Ok entries)
      (Err status))))

(define (compile-cli-run-batch-entries-from
  [state : compiler_driver_core.CompilerDriverState]
  [entries : (& entries cli_svec.Vec)]
  [index : i64]
  [has-target : bool]
  [target : backend.CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [cfgs : (& cfgs cli_svec.Vec)]
  [backend-mode : backend.CompilerBackendMode]
  [opt-level : i64]
  [previous-compat-arena : i64]) : i64
  (if (>= index (cli_svec.len entries))
    0
    (let
      ;; lint-allow: unused-variable
      [ordinal : i64 (/ index 2)]
      [_profile-start : unit
        (cfg
          compile-profile
          (compiler_driver_core.compiler-driver-batch-profile-start-entry!
            (compiler_driver_core.compiler-driver-state-profile state)
            ordinal)
          unit)]
      [input-path : String (cli_svec.get entries index "")]
      [output-path : String (cli_svec.get entries (+ index 1) "")]
      ;; Each batch entry gets a destroyable scratch arena, not just a lexical
      ;; rewind region. Keep the exact scratch handle so cleanup does not
      ;; depend on which arena compiler driver internals leave active.
      [home : arena.Arena (arena.current)]
      ;; Compatibility globals rebuilt by post-emission resets must survive the
      ;; next entry's standalone preflight, but not the whole manifest. Rotate
      ;; a small owner after every entry instead of retaining those reset
      ;; aggregates in the process entry arena.
      [compat : arena.Arena (arena.make)]
      [scratch : arena.Arena (arena.make)]
      [status : i64
        (begin
          (unsafe
            (arena.set! scratch))
          (compile-cli-run-compile-file
            (owned_view.compiler-owned-shared-view state)
            (owned_view.compiler-owned-shared-view input-path)
            output-path
            false
            false
            has-target
            target
            (owned_view.compiler-owned-shared-view stdlib-roots)
            cfgs
            backend-mode
            opt-level
            false))]
      [_profile-emit : unit
        (cfg
          compile-profile
          (compiler_driver_core.compiler-driver-batch-profile-mark!
            (compiler_driver_core.compiler-driver-state-profile state)
            ordinal
            "emit-complete")
          unit)]
      ;; The compile grew `scratch` past its first 64 MiB segment; the arena's
      ;; live chain is reachable only from its newest segment (the active arena
      ;; right after the balanced compile), not the make() root handle.
      [scratch-end : i64 (arena.tl_arena_current)]
      (begin
        (allocation_profile.compiler-allocation-profile-control!
          2
          "batch-pre-release"
          "entry-scratch-saved"
          scratch-end)
        (allocation_profile.compiler-allocation-profile-control!
          2
          "batch-pre-release"
          "compiler-entry"
          (allocation_profile.compiler-allocation-profile-entry-arena-handle))
        (unsafe
          (arena.set! compat))
        ;; Clear compile state while the entry scratch arena is still mapped:
        ;; loader/typecheck caches may hold scratch-backed nodes until reset.
        (cfg
          compile-profile
          (compiler_driver_core.compiler-driver-state-release-file-state-profiled!
            (owned_view.compiler-owned-shared-view state)
            ordinal)
          (compiler_driver_core.compiler-driver-state-release-file-state!
            (owned_view.compiler-owned-shared-view state)))
        (allocation_profile.compiler-allocation-profile-control!
          2
          "batch-post-release"
          "entry-scratch-saved"
          scratch-end)
        (compiler_driver_core.compiler-driver-restore-arena-owner-current!
          (arena.raw-handle home))
        (unsafe
          (arena.tl_arena_destroy scratch-end))
        ;; The next standalone preflight and the opt-in allocation profiler
        ;; still observe compatibility globals between batch entries. Install
        ;; the already-reset job context at that explicit boundary, after the
        ;; entry scratch owner has been destroyed.
        (compiler_driver_core.compiler-driver-state-install-pools! state)
        (compiler_driver_core.compiler-driver-state-install-interns! state)
        ;; The reset above has republished every compatibility aggregate into
        ;; `compat`; only now is the preceding entry's owner unreachable.
        (if (= previous-compat-arena 0)
          unit
          (unsafe
            (arena.tl_arena_destroy previous-compat-arena)))
        (compiler_driver_core.compiler-driver-allocation-profile-snapshot-for-job!
          (compiler_driver_core.compiler-driver-state-typecheck state)
          "batch-steady")
        (allocation_profile.compiler-allocation-profile-control!
          2
          "batch-steady"
          "batch-compat-reset"
          (arena.raw-handle compat))
        (cfg
          compile-profile
          (compiler_driver_core.compiler-driver-batch-profile-mark!
            (compiler_driver_core.compiler-driver-state-profile state)
            ordinal
            "scratch-destroy-steady")
          unit)
        (if (= status 0)
          (compile-cli-run-batch-entries-from
            state
            entries
            (+ index 2)
            has-target
            target
            stdlib-roots
            cfgs
            backend-mode
            opt-level
            (arena.raw-handle compat))
          (begin
            (io.print-error
              (str_cat.str-cat
                "\ncompile: batch source failed: "
                input-path
                "\n"))
            status))))))

;; Batch telemetry treats the live allocation count at entry 0 as the stable
;; process baseline. Fixed compiler tables remain lazy for ordinary one-shot
;; commands, but a batch will need these tables during its first entry and keep
;; them for every later entry. Materialize them once before the first measured
;; entry so that persistent compiler infrastructure is part of the batch
;; baseline instead of being misattributed as leaked entry state.
(define (compile-cli-batch-persistent-table-storage-ensure!
  [state : compiler_driver_core.CompilerDriverState]) : unit
  (let
    [backend-state : backend.CompilerBackendState
      (compiler_driver_core.compiler-driver-state-backend state)]
    [typecheck-state : tc_core.TcJobState
      (compiler_driver_core.compiler-driver-state-typecheck state)]
    (backend.compiler-backend-peephole-carry-safe-reset-with-backend-state!
      backend-state
      (backend.compiler-backend-state-stream-state backend-state))
    (backend.compiler-backend-peephole-owner-global-reset-with-backend-state!
      backend-state
      (backend.compiler-backend-state-stream-state backend-state))
    (backend.compiler-backend-state-slot-frame-cache-storage-ensure!
      backend-state)
    (backend.compiler-backend-state-immediate-cache-storage-ensure!
      backend-state)
    (backend.compiler-backend-state-slot-cache-reset! backend-state)
    (tc_core.tc-type-needs-resolution-storage-ensure-for-job! typecheck-state)
    (tc_core.tc-agg-size-cache-storage-ensure-for-job! typecheck-state)
    (tc_core.tc-agg-align-cache-storage-ensure-for-job! typecheck-state)
    (tc_core.tc-agg-regwords-cache-storage-ensure-for-job! typecheck-state)
    (tc_core.tc-lazy-import-stub-storage-ensure-for-job! typecheck-state)
    (tc_core.tc-agg-layout-cache-table-storage-ensure-for-job! typecheck-state)
    (tc_core.macro-unqualified-import-cache-storage-ensure!
      (tc_core.tc-job-state-macro-state
        (compiler_driver_core.compiler-driver-state-typecheck state)))))

(define (compile-cli-run-batch-entries
  [state : compiler_driver_core.CompilerDriverState]
  [entries : cli_svec.Vec]
  [has-target : bool]
  [target : backend.CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [cfgs : cli_svec.Vec]
  [backend-mode : backend.CompilerBackendMode]
  [opt-level : i64]) : i64
  (compile-cli-batch-persistent-table-storage-ensure!
    (owned_view.compiler-owned-shared-view state))
  (compile-cli-run-batch-entries-from
    state
    (& entries)
    0
    has-target
    target
    stdlib-roots
    cfgs
    backend-mode
    opt-level
    0))

(define (compile-cli-run-windows-batch-entries-from
  [state : compiler_driver_core.CompilerDriverState]
  [entries : (& entries cli_svec.Vec)]
  [index : i64]
  [stdlib-roots : cli_svec.Vec]
  [cfgs : (& cfgs cli_svec.Vec)]
  [backend-mode : backend.CompilerBackendMode]
  [opt-level : i64]
  [previous-compat-arena : i64]
  [results : (&mut results cli_svec.Vec)]) : i64
  (if (>= index (cli_svec.len entries))
    0
    (let
      ;; lint-allow: unused-variable
      [ordinal : i64 (/ index 4)]
      [_profile-start : unit
        (cfg
          compile-profile
          (compiler_driver_core.compiler-driver-batch-profile-start-entry!
            (compiler_driver_core.compiler-driver-state-profile state)
            ordinal)
          unit)]
      [input-path : String (cli_svec.get entries index "")]
      [object-path : String (cli_svec.get entries (+ index 1) "")]
      [assembly-path : String (cli_svec.get entries (+ index 2) "")]
      [force-assembly : bool
        (string.eq (cli_svec.get entries (+ index 3) "auto") "force-assembly")]
      [home : arena.Arena (arena.current)]
      [compat : arena.Arena (arena.make)]
      [scratch : arena.Arena (arena.make)]
      [entry-result : ResultCompileCliWindowsBatchEntry
        (begin
          (unsafe
            (arena.set! scratch))
          (compile-cli-run-windows-batch-file
            (owned_view.compiler-owned-shared-view state)
            (owned_view.compiler-owned-shared-view input-path)
            object-path
            assembly-path
            force-assembly
            (owned_view.compiler-owned-shared-view stdlib-roots)
            cfgs
            backend-mode
            opt-level))]
      [_profile-emit : unit
        (cfg
          compile-profile
          (compiler_driver_core.compiler-driver-batch-profile-mark!
            (compiler_driver_core.compiler-driver-state-profile state)
            ordinal
            "emit-complete")
          unit)]
      [scratch-end : i64 (arena.tl_arena_current)]
      ;; Read the arena-backed result while `scratch` is still mapped. The
      ;; selected paths come from the outer parsed plan and the kind/category
      ;; strings are stable literals, so pushing them after restoring `home`
      ;; leaves no scratch-owned payload in the result vector.
      [status : i64
        (begin
          (compiler_driver_core.compiler-driver-restore-arena-owner-current!
            (arena.raw-handle home))
          (match entry-result
            [(Ok kind path category)
              (cli_svec.push-ref!
                results
                (owned_view.compiler-owned-shared-view input-path))
              (cli_svec.push-ref! results kind)
              (cli_svec.push-ref! results path)
              (cli_svec.push-ref! results category)
              0]
            [(Err entry-status) entry-status]))]
      (begin
        (allocation_profile.compiler-allocation-profile-control!
          2
          "batch-pre-release"
          "entry-scratch-saved"
          scratch-end)
        (allocation_profile.compiler-allocation-profile-control!
          2
          "batch-pre-release"
          "compiler-entry"
          (allocation_profile.compiler-allocation-profile-entry-arena-handle))
        (unsafe
          (arena.set! compat))
        (cfg
          compile-profile
          (compiler_driver_core.compiler-driver-state-release-file-state-profiled!
            (owned_view.compiler-owned-shared-view state)
            ordinal)
          (compiler_driver_core.compiler-driver-state-release-file-state!
            (owned_view.compiler-owned-shared-view state)))
        (allocation_profile.compiler-allocation-profile-control!
          2
          "batch-post-release"
          "entry-scratch-saved"
          scratch-end)
        (compiler_driver_core.compiler-driver-restore-arena-owner-current!
          (arena.raw-handle home))
        (unsafe
          (arena.tl_arena_destroy scratch-end))
        (compiler_driver_core.compiler-driver-state-install-pools! state)
        (compiler_driver_core.compiler-driver-state-install-interns! state)
        (if (= previous-compat-arena 0)
          unit
          (unsafe
            (arena.tl_arena_destroy previous-compat-arena)))
        (compiler_driver_core.compiler-driver-allocation-profile-snapshot-for-job!
          (compiler_driver_core.compiler-driver-state-typecheck state)
          "batch-steady")
        (allocation_profile.compiler-allocation-profile-control!
          2
          "batch-steady"
          "batch-compat-reset"
          (arena.raw-handle compat))
        (cfg
          compile-profile
          (compiler_driver_core.compiler-driver-batch-profile-mark!
            (compiler_driver_core.compiler-driver-state-profile state)
            ordinal
            "scratch-destroy-steady")
          unit)
        (if (= status 0)
          (compile-cli-run-windows-batch-entries-from
            state
            entries
            (+ index 4)
            stdlib-roots
            cfgs
            backend-mode
            opt-level
            (arena.raw-handle compat)
            results)
          (begin
            (io.print-error
              (str_cat.str-cat
                "\ncompile: batch source failed: "
                input-path
                "\n"))
            status))))))

(define (compile-cli-windows-batch-result-plan
  [results : (& results cli_svec.Vec)]) : String
  (let
    [out : text_buf.TextBuf (text_buf.empty)]
    [index : i64 0]
    [count : i64 (cli_svec.len results)]
    (while (< index count)
      (text_buf.append! out (cli_svec.get results index ""))
      (text_buf.append! out "|")
      (text_buf.append! out (cli_svec.get results (+ index 1) ""))
      (text_buf.append! out "|")
      (text_buf.append! out (cli_svec.get results (+ index 2) ""))
      (text_buf.append! out "|")
      (text_buf.append! out (cli_svec.get results (+ index 3) ""))
      (text_buf.append! out "\n")
      (set! index (+ index 4)))
    (text_buf.render out)))

(define (compile-cli-write-windows-batch-result-plan
  [plan-path : String]
  [results : (& results cli_svec.Vec)]) : i64
  (let
    [contents : String (compile-cli-windows-batch-result-plan results)]
    (match (io.try-write-file
      (& plan-path)
      (byte_buf.str-as-bytes (& contents)))
      [(OkIoUnit)
        (io.print-format "{}" (str_cat.str-cat "Wrote " plan-path "\n"))
        0]
      [(ErrIoUnit error)
        (io.print-error
          (str_cat.str-cat
            "compile: cannot write Windows COFF result plan "
            plan-path
            ": "
            (io.error-message error)
            "\n"))
        1])))

(define (compile-cli-run-windows-batch-entries
  [state : compiler_driver_core.CompilerDriverState]
  [entries : cli_svec.Vec]
  [result-plan-path : String]
  [stdlib-roots : cli_svec.Vec]
  [cfgs : cli_svec.Vec]
  [backend-mode : backend.CompilerBackendMode]
  [opt-level : i64]) : i64
  (let
    [results : cli_svec.Vec (cli_svec.new)]
    [_tables : unit
      (compile-cli-batch-persistent-table-storage-ensure!
        (owned_view.compiler-owned-shared-view state))]
    [status : i64
      (compile-cli-run-windows-batch-entries-from
        state
        (& entries)
        0
        stdlib-roots
        cfgs
        backend-mode
        opt-level
        0
        (&mut results))]
    (if (= status 0)
      (compile-cli-write-windows-batch-result-plan result-plan-path (& results))
      status)))

(define (compile-cli-run-batch-from
  [state : compiler_driver_core.CompilerDriverState]
  [text : String]
  [start : i64]
  [line : i64]
  [has-target : bool]
  [target : backend.CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [cfgs : cli_svec.Vec]
  [backend-mode : backend.CompilerBackendMode]
  [opt-level : i64]) : i64
  (match (compile-cli-batch-parse-entries-from
    (owned_view.compiler-owned-shared-view text)
    start
    line
    (string.string-length text))
    [(Ok entries)
      (let
        [_install-preflight-state : unit
          (begin
            ;; The all-source inline preflight must fail before any batch
            ;; output is written. Route its compatibility load/typecheck work
            ;; through this batch's already-owned pools and intern table so the
            ;; first entry reset can destroy that residency. Leaving the
            ;; process-default owners installed retains the largest later
            ;; preflight source beside every subsequent compile.
            (compiler_driver_core.compiler-driver-state-install-pools! state)
            (compiler_driver_core.compiler-driver-state-install-interns! state))]
        [inline-test-status : i64
          (compile-cli-run-batch-inline-tests
            entries
            target
            (owned_view.compiler-owned-shared-view stdlib-roots)
            cfgs)]
        (if (= inline-test-status 0)
          (compile-cli-run-batch-entries
            state
            entries
            has-target
            target
            stdlib-roots
            cfgs
            backend-mode
            opt-level)
          inline-test-status))]
    [(Err status) status]))

(define (compile-cli-run-windows-batch-from
  [state : compiler_driver_core.CompilerDriverState]
  [text : String]
  [start : i64]
  [line : i64]
  [result-plan-path : String]
  [target : backend.CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [cfgs : cli_svec.Vec]
  [backend-mode : backend.CompilerBackendMode]
  [opt-level : i64]) : i64
  (match (compile-cli-windows-batch-parse-entries-from
    text
    start
    line
    (string.string-length text))
    [(Ok entries)
      (let
        [_install-preflight-state : unit
          (begin
            (compiler_driver_core.compiler-driver-state-install-pools! state)
            (compiler_driver_core.compiler-driver-state-install-interns! state))]
        [inline-test-status : i64
          (compile-cli-run-windows-batch-inline-tests
            entries
            target
            (owned_view.compiler-owned-shared-view stdlib-roots)
            cfgs)]
        (if (= inline-test-status 0)
          (compile-cli-run-windows-batch-entries
            state
            entries
            result-plan-path
            stdlib-roots
            cfgs
            backend-mode
            opt-level)
          inline-test-status))]
    [(Err status) status]))

(define (compile-cli-remove-stale-windows-batch-plan [plan-path : String]) : i64
  (match (fs.try-remove-file-if-exists (& plan-path))
    [(OkIoUnit) 0]
    [(ErrIoUnit error)
      (io.print-error
        (str_cat.str-cat
          "compile: cannot remove stale Windows COFF result plan "
          plan-path
          ": "
          (io.error-message error)
          "\n"))
      1]))

(define (compile-cli-run-batch [config : CompileCliBatchConfig]) : i64
  (let
    [state : compiler_driver_core.CompilerDriverState
      (compiler_driver_core.compiler-driver-state-session-program-cache-disable
        (compiler_driver_core.compiler-driver-state-new-for-compile))]
    (match config
      [(Config
          batch-path
          has-target
          target
          stdlib-roots
          cfgs
          backend-mode
          opt-level
          prefix-cache-stats
          has-windows-coff-plan
          windows-coff-plan-path)
        (let
          [status : i64
            (begin
              (compiler_driver_core.compiler-driver-state-prefix-cache-enable!
                state)
              (compiler_driver_core.compiler-driver-state-prefix-cache-clear!
                state)
              (backend.compiler-backend-state-set-shared-object-code-model!
                (compiler_driver_core.compiler-driver-state-backend (& state))
                (compile-cli-shared-object-requested?))
              (if has-windows-coff-plan
                (let
                  [remove-status : i64
                    (compile-cli-remove-stale-windows-batch-plan
                      (owned_view.compiler-owned-shared-view
                        windows-coff-plan-path))]
                  (if (= remove-status 0)
                    (compile-cli-run-windows-batch-from
                      (owned_view.compiler-owned-shared-view state)
                      (byte_buf.to-string (io.read-file batch-path))
                      0
                      1
                      windows-coff-plan-path
                      target
                      stdlib-roots
                      cfgs
                      backend-mode
                      opt-level)
                    remove-status))
                (compile-cli-run-batch-from
                  (owned_view.compiler-owned-shared-view state)
                  (byte_buf.to-string (io.read-file batch-path))
                  0
                  1
                  has-target
                  target
                  stdlib-roots
                  cfgs
                  backend-mode
                  opt-level)))]
          (if prefix-cache-stats
            (compiler_driver_core.compiler-driver-state-prefix-cache-print-stats
              state
              "compile-batch")
            unit)
          (compiler_driver_core.compiler-driver-state-prefix-cache-clear! state)
          (compiler_driver_core.compiler-driver-state-prefix-cache-disable!
            state)
          status)])))

(define (compile-cli-run-action [action : CompileCliAction]) : i64
  (match action
    [(Run config)
      (begin
        (cfg
          compile-startup-profile
          (startup_profile.compiler-startup-profile-mark-cli-compile-action!)
          unit)
        (match config
          [(Config
              input-path
              output-path
              emit-ir
              pic
              has-target
              target
              stdlib-roots
              cfgs
              backend-mode
              opt-level)
            (let
              [_state-begin : unit
                (cfg
                  compile-startup-profile
                  (startup_profile.compiler-startup-profile-mark-driver-state-begin!)
                  unit)]
              [state : compiler_driver_core.CompilerDriverState
                (compiler_driver_core.compiler-driver-state-new-for-compile)]
              [_state-end : unit
                (cfg
                  compile-startup-profile
                  (startup_profile.compiler-startup-profile-mark-driver-state-end!)
                  unit)]
              [status : i64
                (compile-cli-run-compile-file
                  state
                  input-path
                  output-path
                  emit-ir
                  pic
                  has-target
                  target
                  stdlib-roots
                  cfgs
                  backend-mode
                  opt-level
                  true)]
              (begin
                (cfg
                  compile-startup-profile
                  (startup_profile.compiler-startup-profile-print!)
                  unit)
                status))]))]
    [(Batch config) (compile-cli-run-batch config)]
    [(Error message)
      (io.print-error message)
      1]))

(define (compile-cli-run [count : i64]) : i64
  (let
    [action : CompileCliAction
      (begin
        (set! compile-cli-allocation-profile-requested false)
        (set! compile-cli-no-entry-requested false)
        (set! compile-cli-dump-ir-requested false)
        (set! compile-cli-dump-ir-pass "")
        (set! compile-cli-verify-ir-requested false)
        (set! compile-cli-trace-passes-requested false)
        (ir.compiler-debug-info-set-enabled! false)
        (ir.compiler-debug-type-graph-verify-set! false)
        (ir.compiler-debug-path-remap-clear!)
        (compile-cli-dispatch count))]
    [profile? : bool compile-cli-allocation-profile-requested]
    (if profile?
      (begin
        (allocation_profile.compiler-allocation-profile-control! 1 "" "" 0)
        (compiler_driver_core.compiler-driver-allocation-profile-snapshot!
          "start"))
      unit)
    (let
      [status : i64 (compile-cli-run-action action)]
      (if profile?
        (begin
          ;; Diagnostics do not all include a trailing newline. Keep the
          ;; final machine-readable phase on its own line after failures.
          (if (= status 0)
            unit
            (io.print-error "\n"))
          (compiler_driver_core.compiler-driver-allocation-profile-snapshot!
            "complete")
          (allocation_profile.compiler-allocation-profile-control! 3 "" "" 0)
          unit)
        unit)
      status)))