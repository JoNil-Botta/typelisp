;; compile_cli_core.tl - Main-free selfhost compile/check core.
;;
;; Wraps compiler_driver_core.tl's input/output API with the selfhost compile CLI:
;; `compile <file.tl> [-o <file>] [--emit-ir] [--pic] [--no-entry] [--target <target>]
;; [--opt-level <0|1|2|s> -Os] [--backend-mode scalar] [--stdlib-root <dir>...]
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
(import compiler_backend_operands as be_operand)
(import compiler_backend_program_facts as be_facts)
(import compiler_backend_state as be_state)
(import stdlib.iterator)
(import compiler_owned_view as owned_view)
(import stdlib.arena)
(import stdlib.byte_buf)
(import stdlib.env)
(import stdlib.io)
(import stdlib.fs)
(import stdlib.vector)
(import (vector.vector String) as cli_svec)
(import cli_option_core as cli_option)
(import build_run_core)
(import compiler_target_cfg_core as target_cfg)
(import compiler_allocation_profile as allocation_profile)
(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (import compiler_ast_types as ast))
(import compiler_backend_peephole as be_peephole)
(import compiler_backend_object as be_object)
(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (import compiler_build_identity as build_identity))
(import compiler_diagnostic as cdiag)
(import compiler_load as load)
(import compiler_intern as ci)
(import compiler_ir_types as ir)
(import compiler_lower as lower)
(import compiler_optimize as opt)
(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (import compiler_symbols as csym))
(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (import compiler_tli_codec as tli_codec))
(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (import compiler_tli_extract as tli_extract))
(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (import compiler_tli_types as tli_types))
(import compiler_driver_core)
(import tli_cli_core as tli_cli)
(cfg
  embedded-stdlib-tlci
  (import compiler_embedded_stdlib_tlci as embedded_tlci))
(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (import compiler_typecheck_api as tc_api))
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
(define compile-cli-sysroot-options : tli_cli.TliSysrootOptions
  (tli_cli.tli-sysroot-options))
(define compile-cli-extra-tli-paths : cli_svec.Vec
  (cli_svec.new))

(defenum CompileCliConfig
  (Config
    String
    String
    bool
    bool
    bool
    be_state.CompilerBackendTarget
    cli_svec.Vec
    cli_svec.Vec
    be_state.CompilerBackendMode
    i64))

(defstruct CompileCliEmitTliConfig
  (input-path String)
  (output-path String)
  (target be_state.CompilerBackendTarget)
  (stdlib-roots cli_svec.Vec)
  (cfgs cli_svec.Vec))

(defenum CompileCliBatchConfig
  (Config
    String
    bool
    bool
    be_state.CompilerBackendTarget
    cli_svec.Vec
    cli_svec.Vec
    be_state.CompilerBackendMode
    i64
    bool
    bool
    String))

(defenum ResultCompileCliConfig
  (Ok CompileCliConfig)
  (EmitTli CompileCliEmitTliConfig)
  (Err String))

(defenum ResultCompileCliBatchConfig
  (Ok CompileCliBatchConfig)
  (Err String))

(defenum CompileCliAction
  (Run CompileCliConfig)
  (EmitTli CompileCliEmitTliConfig)
  (Batch CompileCliBatchConfig)
  (Error String))

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
    [last-dot : i64 -1]
    [last-sep : i64 -1]
    (for [i (iterator.range 0 n)]
      (let
        [c : char (string.string-ref input-path i)]
        (if (= c '.')
          (set! last-dot i)
          (set! last-dot last-dot))
        (if (compile-cli-path-separator? c)
          (set! last-sep i)
          (set! last-sep last-sep))))
    (if (> last-dot last-sep)
      (str_cat.str-cat (string.substring input-path 0 last-dot) extension)
      (str_cat.str-cat input-path extension))))

(define (compile-cli-default-output [input-path : String]) : String
  (compile-cli-default-output-with-extension input-path ".s"))

(define (compile-cli-default-ir-output [input-path : String]) : String
  (compile-cli-default-output-with-extension input-path ".ir"))

(define (compile-cli-default-tli-output [input-path : String]) : String
  (compile-cli-default-output-with-extension input-path ".tli"))

(define (compile-cli-common-option!
  [options : (&mut options cli_option.CliCompileOptions)]
  [args : (&mut args cli_option.CliArgs)]) : bool
  (if (or
    (cli_option.cli-compile-option! options args)
    (tli_cli.tli-sysroot-option! (&mut compile-cli-sysroot-options) args))
    true
    (cond
      [(string.eq args.name "--extra-tli")
        (let
          [path : String (cli_option.cli-args-value args)]
          (if (= (string.string-length (& path)) 0)
            (cli_option.cli-args-fail!
              args
              "compile: --extra-tli requires a non-empty file path")
            (cli_svec.push-ref! (&mut compile-cli-extra-tli-paths) path)))
        true]
      [(string.eq args.name "--profile-allocations")
        (if compile-cli-allocation-profile-requested
          (cli_option.cli-args-fail!
            args
            "compile: --profile-allocations was provided more than once")
          (set! compile-cli-allocation-profile-requested true))
        true]
      [(string.eq args.name "--verify-ir")
        (if compile-cli-verify-ir-requested
          (cli_option.cli-args-fail!
            args
            "compile: --verify-ir was provided more than once")
          (begin
            (set! compile-cli-verify-ir-requested true)
            (ir.compiler-debug-type-graph-verify-set! true)))
        true]
      [else false])))

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
            (str_cat.str-cat
              "--stdlib-root <dir> --cfg <name> --target <target> --opt-level <0|1|2|s> -Os
               --debug|-g|--backtrace --backend-mode <mode> --profile-allocations
               --extra-tli <file> -o <file> --pic --no-entry --emit-ir --emit-tli
               --dump-ir --verify-ir --trace-passes "
              (tli_cli.tli-sysroot-cli-options))
            (+ input-idx 1)
            count)]
        [options : cli_option.CliCompileOptions
          (cli_option.cli-compile-options
            (Linux)
            (opt.compiler-optimize-default-level))]
        [output-path : String
          (compile-cli-default-output (string.copy (& input-path)))]
        [has-output : bool false]
        [emit-ir : bool false]
        [emit-tli : bool false]
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
              [(string.eq args.name "--emit-tli")
                (if emit-tli
                  (cli_option.cli-args-fail!
                    (&mut args)
                    "compile: --emit-tli was provided more than once")
                  (set! emit-tli true))]
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
                    (+= args.next 1)))
                (set! emit-ir true)]
              [(string.eq args.name "--trace-passes")
                (if compile-cli-trace-passes-requested
                  (cli_option.cli-args-fail!
                    (&mut args)
                    "compile: --trace-passes was provided more than once")
                  (set! compile-cli-trace-passes-requested true))]
              [else (compile-cli-unknown-argument! (&mut args))])))
        (unless args.failed (ir.compiler-debug-info-set-enabled! options.debug))
        (cond
          [args.failed (Err args.error)]
          [(and emit-tli emit-ir)
            (Err
              "compile: --emit-tli cannot be combined with --emit-ir or --dump-ir")]
          [(and emit-tli pic)
            (Err "compile: --emit-tli cannot be combined with --pic")]
          [(and emit-tli compile-cli-no-entry-requested)
            (Err "compile: --emit-tli cannot be combined with --no-entry")]
          [(and emit-ir pic)
            (Err "compile: --pic cannot be combined with --emit-ir")]
          [(and compile-cli-no-entry-requested pic)
            (Err
              "compile: --no-entry cannot be combined with --pic, whose assembly never has an entry")]
          [(and compile-cli-no-entry-requested emit-ir)
            (Err
              "compile: --no-entry selects assembly output and cannot be combined with --emit-ir or --dump-ir")]
          [emit-tli
            (ResultCompileCliConfig.EmitTli
              (CompileCliEmitTliConfig
                (string.copy (& input-path))
                (if has-output
                  output-path
                  (compile-cli-default-tli-output input-path))
                (build_run_core.source-tool-backend-target options.target)
                options.stdlib-roots
                options.cfgs))]
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
                (build_run_core.source-tool-backend-target options.target)
                options.stdlib-roots
                options.cfgs
                (build_run_core.source-tool-backend-mode
                  (cli_option.cli-compile-options-backend-mode
                    options.backend-mode
                    options.has-backend-mode
                    options.opt-level))
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
          (str_cat.str-cat
            "--stdlib-root <dir> --cfg <name> --target <target> --opt-level <0|1|2|s> -Os
             --debug|-g|--backtrace --backend-mode <mode> --profile-allocations
             --extra-tli <file> -o --emit-ir --emit-tli --pic --no-entry --verify-ir
             --prefix-cache-stats --windows-coff-plan "
            (tli_cli.tli-sysroot-cli-options))
          (+ batch-path-idx 1)
          count)]
      [options : cli_option.CliCompileOptions
        (cli_option.cli-compile-options
          (Linux)
          (opt.compiler-optimize-default-level))]
      [emit-ir : bool false]
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
              (if emit-ir
                (cli_option.cli-args-fail!
                  (&mut args)
                  "compile: IR output was requested more than once")
                (set! emit-ir true))]
            [(string.eq args.name "--emit-tli")
              (cli_option.cli-args-fail!
                (&mut args)
                "compile: --batch does not support --emit-tli")]
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
                  (+= args.next 1)])]
            [else (compile-cli-unknown-argument! (&mut args))])))
      (unless args.failed (ir.compiler-debug-info-set-enabled! options.debug))
      (cond
        [args.failed (Err args.error)]
        [(and compile-cli-no-entry-requested emit-ir)
          (Err
            "compile: --no-entry selects assembly output and cannot be combined with --emit-ir or --dump-ir")]
        [(and has-windows-coff-plan emit-ir)
          (Err "compile: --windows-coff-plan cannot be combined with --emit-ir")]
        [(and
            has-windows-coff-plan
            (or
              (not options.has-target)
              (not
                (be_facts.compiler-backend-target-windows?
                  (build_run_core.source-tool-backend-target options.target)))))
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
              emit-ir
              options.has-target
              (build_run_core.source-tool-backend-target options.target)
              options.stdlib-roots
              options.cfgs
              (build_run_core.source-tool-backend-mode
                (cli_option.cli-compile-options-backend-mode
                  options.backend-mode
                  options.has-backend-mode
                  options.opt-level))
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
      [(EmitTli config) (CompileCliAction.EmitTli config)]
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
        output-path
        (compiler_driver_core.compiler-driver-state-owned-lower-state state)))))

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
  [target : be_state.CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [cfgs : (& cfgs cli_svec.Vec)]
  [backend-mode : be_state.CompilerBackendMode]
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
      (let
        [cells : (__tl_dyn-array ci.InternCompatState)
          (compiler_driver_core.compiler-driver-state-intern-cells
            (owned_view.compiler-owned-shared-view state))]
        (ci.intern-compat-state-reset! (&mut (array-ref cells 0))))
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
                  (target_cfg.compiler-target-user-cfgs cfgs))
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
              (be_state.compiler-backend-state-set-shared-object-code-model!
                (compiler_driver_core.compiler-driver-state-backend (& state))
                (compile-cli-shared-object-requested?))
              (let
                [intern-cells : (__tl_dyn-array ci.InternCompatState)
                  (compiler_driver_core.compiler-driver-state-intern-cells
                    (owned_view.compiler-owned-shared-view state))]
                [emit-cfgs : sym_i64_env.SymI64Env
                  (target_cfg.compiler-target-user-cfgs-with-intern-state
                    cfgs
                    (&mut (array-ref intern-cells 0)))]
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
    [(or (CoffObject _ _ advisories) (Assembly _ _ advisories)
         (Err _ advisories))
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
              "write"
              (compiler_driver_core.compiler-driver-state-owned-lower-state
                _state))
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
              "write"
              (compiler_driver_core.compiler-driver-state-owned-lower-state
                _state))
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
                  (be_object.compiler-direct-object-fallback-category category)))
              (Err write-status))))]
      [(Err diag advisories)
        (begin
          (compiler_driver_core.compiler-driver-print-advisories (& advisories))
          (compiler_driver_core.compiler-driver-allocation-profile-snapshot-for-job!
            (compiler_driver_core.compiler-driver-state-typecheck _state)
            "write-error"
            (compiler_driver_core.compiler-driver-state-owned-lower-state
              _state))
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
  [backend-mode : be_state.CompilerBackendMode]
  [opt-level : i64]) : ResultCompileCliWindowsBatchEntry
  (begin
    ;; Match the legacy batch entry lifecycle exactly through the one-lowering
    ;; driver boundary. The selected bytes are written before the caller tears
    ;; down this entry's scratch arena.
    (if (=
      (compiler_driver_core.compiler-driver-state-intern-generation state)
      0)
      (let
        [cells : (__tl_dyn-array ci.InternCompatState)
          (compiler_driver_core.compiler-driver-state-intern-cells
            (owned_view.compiler-owned-shared-view state))]
        (ci.intern-compat-state-reset! (&mut (array-ref cells 0))))
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
            [intern-cells : (__tl_dyn-array ci.InternCompatState)
              (compiler_driver_core.compiler-driver-state-intern-cells
                (owned_view.compiler-owned-shared-view state))]
            [emit-cfgs : sym_i64_env.SymI64Env
              (target_cfg.compiler-target-user-cfgs-with-intern-state
                cfgs
                (&mut (array-ref intern-cells 0)))]
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
  [target : be_state.CompilerBackendTarget]
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
            (unsafe
              ;; unsafe: installs the global load session; replaced before this arena ends
              (compiler_driver_core.compiler-driver-reset-file-state!))
            (unsafe
              ;; unsafe: interned names live in the persistent intern arena, not this one
              (test_cli_core.tltest-inline-typecheck-file-with-cfg
                (owned_view.compiler-owned-shared-view input-path)
                (owned_view.compiler-owned-shared-view stdlib-roots)
                (compiler_driver_core.compiler-driver-target-cfgs
                  target
                  (target_cfg.compiler-target-user-cfgs cfgs))
                "typecheck-prefix-inline-compile-batch")))
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
  [target : be_state.CompilerBackendTarget]
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
  [target : be_state.CompilerBackendTarget]
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
        (+= i 1)))
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
  [emit-ir : bool]
  [has-target : bool]
  [target : be_state.CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [cfgs : (& cfgs cli_svec.Vec)]
  [backend-mode : be_state.CompilerBackendMode]
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
            emit-ir
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
          "batch-steady"
          (compiler_driver_core.compiler-driver-state-owned-lower-state state))
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
            emit-ir
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
  [state : compiler_driver_core.CompilerDriverState]
  [entry-count : i64]) : unit
  (let
    [backend-state : be_state.CompilerBackendState
      (compiler_driver_core.compiler-driver-state-backend state)]
    [typecheck-state : tc_core.TcJobState
      (compiler_driver_core.compiler-driver-state-typecheck state)]
    [macro-state : tc_core.TcMacroState
      (tc_core.tc-job-state-macro-state typecheck-state)]
    (be_state.compiler-backend-peephole-carry-safe-reset-with-backend-state!
      backend-state
      (be_state.compiler-backend-state-stream-state backend-state))
    (be_peephole.compiler-backend-peephole-owner-global-reset-with-backend-state!
      backend-state
      (be_state.compiler-backend-state-stream-state backend-state))
    (be_operand.compiler-backend-state-slot-frame-cache-storage-ensure!
      backend-state)
    (be_operand.compiler-backend-state-immediate-cache-storage-ensure!
      backend-state)
    (be_facts.compiler-backend-state-slot-cache-reset! backend-state)
    (tc_core.tc-type-needs-resolution-storage-ensure-for-job! typecheck-state)
    (tc_core.tc-agg-size-cache-storage-ensure-for-job! typecheck-state)
    (tc_core.tc-agg-align-cache-storage-ensure-for-job! typecheck-state)
    (tc_core.tc-agg-regwords-cache-storage-ensure-for-job! typecheck-state)
    (tc_core.tc-lazy-import-stub-storage-ensure-for-job! typecheck-state)
    (tc_core.tc-agg-layout-cache-table-storage-ensure-for-job! typecheck-state)
    (tc_core.tc-type-handle-cache-storage-ensure-for-job! typecheck-state)
    (tc_core.macro-unqualified-import-cache-storage-ensure! macro-state)
    (tc_core.macro-alias-cache-storage-ensure! macro-state)
    (lower.compiler-lower-function-memo-storage-ensure!
      (compiler_driver_core.compiler-driver-state-owned-lower-state (& state)))
    ;; The decoded image is fixed batch infrastructure too. Initialize its
    ;; bytes before entry 0; admission and mapping still require each entry's
    ;; fresh source proofs.
    (when
      (> entry-count 1)
      (cfg
        embedded-stdlib-tlci
        (begin
          (embedded_tlci.compiler-embedded-stdlib-tlci-surface-bytes
            (compiler_driver_core.compiler-driver-state-surface-arena state))
          unit)
        unit))))

(define (compile-cli-run-batch-entries
  [state : compiler_driver_core.CompilerDriverState]
  [entries : cli_svec.Vec]
  [emit-ir : bool]
  [has-target : bool]
  [target : be_state.CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [cfgs : cli_svec.Vec]
  [backend-mode : be_state.CompilerBackendMode]
  [opt-level : i64]) : i64
  (compile-cli-batch-persistent-table-storage-ensure!
    (owned_view.compiler-owned-shared-view state)
    (/ (cli_svec.len (& entries)) 2))
  (when
    (and (not emit-ir) (not (compile-cli-shared-object-requested?)))
    (with-scratch
      (tli_cli.tli-batch-cache-warm-for-names!
        (compiler_driver_core.compiler-driver-target-cfg-from-backend target)
        (& stdlib-roots.slots)
        (cli_svec.len (& stdlib-roots))
        (& cfgs.slots)
        (cli_svec.len (& cfgs))
        (ir.compiler-debug-info-enabled?)
        opt-level
        true)))
  (let
    [_image-owner : i64
      (compiler_driver_core.compiler-driver-state-surface-arena (& state))]
    [status : i64
      (compile-cli-run-batch-entries-from
        state
        (& entries)
        0
        emit-ir
        has-target
        target
        stdlib-roots
        cfgs
        backend-mode
        opt-level
        0)]
    (cfg
      embedded-stdlib-tlci
      (embedded_tlci.compiler-embedded-stdlib-tlci-forget-decoded! _image-owner)
      unit)
    status))

(define (compile-cli-run-windows-batch-entries-from
  [state : compiler_driver_core.CompilerDriverState]
  [entries : (& entries cli_svec.Vec)]
  [index : i64]
  [stdlib-roots : cli_svec.Vec]
  [cfgs : (& cfgs cli_svec.Vec)]
  [backend-mode : be_state.CompilerBackendMode]
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
      ;; A program lowered against the prebuilt stdlib calls into the sysroot
      ;; libstdlib.a, so its row tells the linker to add that archive.
      [archive : String
        (if (be_state.compiler-backend-state-archive-runtime?
          (compiler_driver_core.compiler-driver-state-backend (& state)))
          "stdlib-archive"
          "none")]
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
              (cli_svec.push-ref! results archive)
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
          "batch-steady"
          (compiler_driver_core.compiler-driver-state-owned-lower-state state))
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
      (text_buf.append! out "|")
      (text_buf.append! out (cli_svec.get results (+ index 4) ""))
      (text_buf.append! out "\n")
      (+= index 5))
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
  [backend-mode : be_state.CompilerBackendMode]
  [opt-level : i64]) : i64
  (let
    [results : cli_svec.Vec (cli_svec.new)]
    [_tables : unit
      (compile-cli-batch-persistent-table-storage-ensure!
        (owned_view.compiler-owned-shared-view state)
        (/ (cli_svec.len (& entries)) 4))]
    [_warm-tli : unit
      (when
        (not (compile-cli-shared-object-requested?))
        (with-scratch
          (tli_cli.tli-batch-cache-warm-for-names!
            (target_cfg.CompilerTargetCfg.Windows)
            (& stdlib-roots.slots)
            (cli_svec.len (& stdlib-roots))
            (& cfgs.slots)
            (cli_svec.len (& cfgs))
            (ir.compiler-debug-info-enabled?)
            opt-level
            true)))]
    [_image-owner : i64
      (compiler_driver_core.compiler-driver-state-surface-arena (& state))]
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
    (cfg
      embedded-stdlib-tlci
      (embedded_tlci.compiler-embedded-stdlib-tlci-forget-decoded! _image-owner)
      unit)
    (if (= status 0)
      (compile-cli-write-windows-batch-result-plan result-plan-path (& results))
      status)))

(define (compile-cli-run-batch-from
  [state : compiler_driver_core.CompilerDriverState]
  [text : String]
  [start : i64]
  [line : i64]
  [emit-ir : bool]
  [has-target : bool]
  [target : be_state.CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [cfgs : cli_svec.Vec]
  [backend-mode : be_state.CompilerBackendMode]
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
            emit-ir
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
  [target : be_state.CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [cfgs : cli_svec.Vec]
  [backend-mode : be_state.CompilerBackendMode]
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
          emit-ir
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
              (compiler_driver_core.compiler-driver-state-retain-stdlib-proofs!
                state)
              (tli_cli.tli-batch-cache-begin!)
              (be_state.compiler-backend-state-set-shared-object-code-model!
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
                  emit-ir
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
          (tli_cli.tli-batch-cache-end!)
          (compiler_driver_core.compiler-driver-state-release-stdlib-proofs!
            state)
          (compiler_driver_core.compiler-driver-state-prefix-cache-clear! state)
          (compiler_driver_core.compiler-driver-state-prefix-cache-disable!
            state)
          status)])))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (compile-cli-emit-tli-svec-find
    [items : (& cli_svec.Vec)]
    [target : (& str)]) : i64
    (for [i (iterator.range 0 (cli_svec.len items))]
      (when (string.eq (& (array-ref items.slots i)) target) (return i)))
    -1))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (compile-cli-emit-tli-file-sha256 [path : (& str)]) : (Array u8 32)
    (match (io.try-read-file path)
      [(OkIoBytes raw)
        (tli_extract.tli-extract-sha256 (byte_buf.as-bytes (& raw)))]
      [(ErrIoBytes _) (make-array u8 32)])))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (compile-cli-emit-tli-pre-sources
    [load-state : (& load.CompilerLoadSessionState)]
    [decls : (& ast.AstDeclList)]
    [paths : (& ast.AstDeclPathList)]
    [modules : (& ast.AstDeclModuleList)]
    [input-path : (& str)]) : (__tl_dyn-array tli_extract.TliSource)
    (let
      [count : i64 (ast.ast-decl-list-len decls)]
      [seen-paths : cli_svec.Vec (cli_svec.new)]
      [seen-mods : cli_svec.Vec (cli_svec.new)]
      [last-path : String ""]
      [last-slot : i64 -1]
      [root-mod-id : i64 (csym.compiler-symbol-root-module-id)]
      (for [index (iterator.range 0 count)]
        (let
          [path : String (ast.ast-decl-path-list-get paths index "")]
          [mod-id : i64
            (ast.ast-decl-module-list-get-id modules index root-mod-id)]
          [mod-name : String
            (if (csym.compiler-symbol-root-module-id? mod-id)
              ""
              (ci.intern-str mod-id))]
          (unless
            (or
              (= (string.string-length (& path)) 0)
              (source_text.starts-with? (& path) "<tli-stdlib>:")
              (load.compiler-load-stdlib-import? (& path))
              (source_text.starts-with? (& mod-name) "stdlib.")
              (and
                (> (string.string-length (& mod-name)) 0)
                (load.compiler-load-session-state-tli-has-module?
                  load-state
                  (& mod-name))))
            (let
              [slot : i64
                (if (and (>= last-slot 0) (string.eq (& last-path) (& path)))
                  last-slot
                  (compile-cli-emit-tli-svec-find (& seen-paths) (& path)))]
              (if (< slot 0)
                (let
                  [fresh : i64 (cli_svec.len (& seen-paths))]
                  (cli_svec.push-ref! (&mut seen-paths) (string.copy (& path)))
                  (cli_svec.push-ref!
                    (&mut seen-mods)
                    (string.copy (& mod-name)))
                  (set! last-path path)
                  (set! last-slot fresh))
                (begin
                  (set! last-path path)
                  (set! last-slot slot)
                  (when
                    (and
                      (=
                        (string.string-length
                          (& (array-ref seen-mods.slots slot)))
                        0)
                      (> (string.string-length (& mod-name)) 0))
                    (set! (array-ref seen-mods.slots slot) mod-name))))))))
      (when
        (= (cli_svec.len (& seen-paths)) 0)
        (cli_svec.push-ref! (&mut seen-paths) (string.copy input-path))
        (cli_svec.push-ref! (&mut seen-mods) ""))
      (let
        [n : i64 (cli_svec.len (& seen-paths))]
        [out : (__tl_dyn-array tli_extract.TliSource)
          (__tl_make-array tli_extract.TliSource n)]
        (for [i (iterator.range 0 n)]
          (let
            [path : String (string.copy (& (array-ref seen-paths.slots i)))]
            [raw-mod : String (string.copy (& (array-ref seen-mods.slots i)))]
            [mod-name : String
              (if (> (string.string-length (& raw-mod)) 0)
                raw-mod
                (load.compiler-load-canonical-module-id-from-path (& path)))]
            [digest : (Array u8 32) (compile-cli-emit-tli-file-sha256 (& path))]
            (set!
              (array-ref out i)
              (tli_extract.TliSource mod-name path digest))))
        out))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (compile-cli-emit-tli-filter-generated-sources
    [load-state : (& load.CompilerLoadSessionState)]
    [pre-count : i64]
    [raw-all : (& (__tl_dyn-array tli_extract.TliSource))]) : (__tl_dyn-array
      tli_extract.TliSource)
    (let
      [total : i64 (array-length (deref raw-all))]
      [keep : (__tl_dyn-array bool) (__tl_make-array bool total)]
      [kept : i64 0]
      (for [i (iterator.range 0 total)]
        (let
          [ok : bool
            (or
              (< i pre-count)
              (not
                (load.compiler-load-session-state-tli-has-module?
                  load-state
                  (& (array-ref (deref raw-all) i).module-name))))]
          (set! (array-ref keep i) ok)
          (when ok (+= kept 1))))
      (let
        [out : (__tl_dyn-array tli_extract.TliSource)
          (__tl_make-array tli_extract.TliSource kept)]
        [dst : i64 0]
        (for [i (iterator.range 0 total)]
          (when
            (array-ref keep i)
            (set!
              (array-ref out dst)
              (tli_extract.TliSource
                (string.copy (& (array-ref (deref raw-all) i).module-name))
                (string.copy (& (array-ref (deref raw-all) i).path))
                (array-ref (deref raw-all) i).digest))
            (+= dst 1)))
        out))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (compile-cli-emit-tli-snapshot-external-imports!
    [bundle : (&mut tli_types.TliBundle)]
    [load-state : (& load.CompilerLoadSessionState)]) : unit
    (for [m (iterator.range 0 (array-length bundle.modules))]
      (for [i
        (iterator.range 0 (array-length (array-ref bundle.modules m).imports))]
        (let
          [imp-name : String
            (string.copy
              (& (array-ref (array-ref bundle.modules m).imports i).module-name))]
          (match (load.compiler-load-session-state-tli-module-sha256
            load-state
            (& imp-name))
            [(Some ext-digest)
              (set!
                (array-ref (array-ref bundle.modules m).imports i).interface-sha256
                ext-digest)]
            [(None) unit]))))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (compile-cli-run-emit-tli [config : CompileCliEmitTliConfig]) : i64
    (match config
      [(CompileCliEmitTliConfig input-path output-path target stdlib-roots cfgs)
        (compiler_driver_core.compiler-driver-reset-file-state!)
        (let
          [emit-cfgs : sym_i64_env.SymI64Env
            (compiler_driver_core.compiler-driver-target-cfgs
              target
              (target_cfg.compiler-target-user-cfgs (& cfgs)))]
          [target-cfg : target_cfg.CompilerTargetCfg
            (compiler_driver_core.compiler-driver-target-cfg-from-backend
              target)]
          [load-state : load.CompilerLoadSessionState
            (load.compiler-load-serial-test-session-state)]
          (match (compiler_driver_core.compiler-driver-open-tli-catalog-for-session!
            (& load-state)
            (& input-path)
            target-cfg
            (& stdlib-roots)
            emit-cfgs
            0
            false)
            [(Err tli-msg)
              (compiler_driver_core.compiler-driver-finish-tli-hydrated-serial-session!)
              (io.print-error tli-msg)
              1]
            [(Ok)
              (match (compiler_driver_core.compiler-driver-load-file-with-runtime
                (string.copy (& input-path))
                (cli_svec.clone-vec (& stdlib-roots))
                emit-cfgs)
                [(Err diag)
                  (compiler_driver_core.compiler-driver-finish-tli-hydrated-serial-session!)
                  (io.print-error
                    (cdiag.compiler-diagnostic-render (& (__tl-box-place diag))))
                  1]
                [(Ok decls paths modules _)
                  (let
                    [pre-sources : (__tl_dyn-array tli_extract.TliSource)
                      (compile-cli-emit-tli-pre-sources
                        (& load-state)
                        (& decls)
                        (& paths)
                        (& modules)
                        (& input-path))]
                    [request : tc_api.TypecheckRequest
                      (tc_api.typecheck-request-serial
                        (ast.AstProgram.Program (box decls))
                        (ast.ast-decl-path-list-with-modules paths (& modules))
                        (cli_svec.clone-vec (& stdlib-roots))
                        emit-cfgs
                        (tc_core.tc-prefix-default-cache-scope))]
                    [cfg-digest : (Array u8 32)
                      (tli_extract.tli-extract-cfg-digest request.cfgs)]
                    [records : (__tl_dyn-array tli_extract.TliExtractModule)
                      (tli_extract.tli-extract-open-modules
                        (& request)
                        (& pre-sources))]
                    [job : tc_core.TcJobState request.job-state]
                    [producer : String
                      (build_identity.compiler-build-producer-identity)]
                    [target-triple : String
                      (tli_cli.tli-sysroot-target-triple target-cfg)]
                    (set! request.retain-global-call-effects true)
                    (match (tc_api.typecheck-compiler-request-checked request)
                      [(or (Partial diagnostics _ _ _) (Err diagnostics))
                        (tc_core.tc-global-call-effects-finish! job)
                        (compiler_driver_core.compiler-driver-finish-tli-hydrated-serial-session!)
                        (io.print-error
                          (compiler_driver_core.compiler-driver-render-source-diagnostic
                            (cdiag.compiler-diagnostic-list-first
                              (& (__tl-box-place diagnostics)))))
                        1]
                      [(Ok _ ctx env checked-paths)
                        (let
                          [raw-all : (__tl_dyn-array tli_extract.TliSource)
                            (tli_extract.tli-extract-add-generated-sources
                              ctx
                              (& checked-paths)
                              (& pre-sources))]
                          [all-sources : (__tl_dyn-array tli_extract.TliSource)
                            (compile-cli-emit-tli-filter-generated-sources
                              (& load-state)
                              (array-length pre-sources)
                              (& raw-all))]
                          [all-records : (__tl_dyn-array
                            tli_extract.TliExtractModule)
                            (tli_extract.tli-extract-extend-records
                              records
                              (& all-sources))]
                          [bundle : tli_types.TliBundle
                            (tli_extract.tli-extract-checked
                              ctx
                              env
                              (& checked-paths)
                              (& all-sources)
                              all-records
                              (& cfg-digest)
                              0
                              producer
                              target-triple)]
                          (compile-cli-emit-tli-snapshot-external-imports!
                            (&mut bundle)
                            (& load-state))
                          (tc_core.tc-global-call-effects-finish! job)
                          (compiler_driver_core.compiler-driver-finish-tli-hydrated-serial-session!)
                          (if (not
                            (tli_extract.tli-extract-pin-imports! (&mut bundle)))
                            (begin
                              (io.print-error
                                "compile: TLI import cycle cannot pin module record digests\n")
                              1)
                            (let
                              [encoded : (__tl_dyn-array u8)
                                (tli_codec.tli-encode-bundle (& bundle))]
                              [buf : byte_buf.ByteBuf
                                (byte_buf.from-array encoded)]
                              (match (io.try-write-file
                                (& output-path)
                                (byte_buf.as-bytes (& buf)))
                                [(OkIoUnit)
                                  (io.print-format
                                    "{}"
                                    (str_cat.str-cat "Wrote " output-path "\n"))
                                  0]
                                [(ErrIoUnit error)
                                  (io.print-error
                                    (str_cat.str-cat
                                      "compile: cannot write "
                                      output-path
                                      ": "
                                      (io.error-message error)
                                      "\n"))
                                  1]))))]))])]))])))

(cfg
  (not
    (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci))
  (define (compile-cli-run-emit-tli [_config : CompileCliEmitTliConfig]) : i64
    (io.print-error
      "compile: --emit-tli requires checked frontend surface support\n")
    1))

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
    [(EmitTli config) (compile-cli-run-emit-tli config)]
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
        (set! compile-cli-sysroot-options (tli_cli.tli-sysroot-options))
        (set! compile-cli-extra-tli-paths (cli_svec.new))
        (tli_cli.tli-reset-active-sysroot-options!)
        (tli_cli.tli-reset-active-extra-tli-paths!)
        (ir.compiler-debug-info-set-enabled! false)
        (ir.compiler-debug-type-graph-verify-set! false)
        (ir.compiler-debug-path-remap-clear!)
        (let
          [parsed : CompileCliAction (compile-cli-dispatch count)]
          (tli_cli.tli-set-active-sysroot-options!
            (& compile-cli-sysroot-options))
          (tli_cli.tli-set-active-extra-tli-paths!
            (& compile-cli-extra-tli-paths))
          parsed))]
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