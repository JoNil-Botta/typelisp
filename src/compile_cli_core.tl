;; compile_cli_core.tl - Main-free selfhost compile/check core.
;;
;; Wraps compiler_driver_core.tl's input/output API with the selfhost compile CLI:
;; `compile <file.tl> [-o <file>] [--emit-ir] [--pic] [--target <target>]
;; [--opt-level <0|1|2>] [--backend-mode scalar] [--stdlib-root <dir>...]
;; [--cfg <name>...] [--profile-allocations]`,
;; plus `check <file.tl> [--stdlib-root <dir>...]`.
;; Bootstrap scripts call the retained `compile.tl` driver with the same
;; `compile` subcommand shape used by the unified CLI.
;; `--backend-mode scalar`, `avx2`, and `avx512` are accepted by the selfhost
;; compiler.
;; `--emit-ir` writes a deterministic TypeLisp-owned IR summary. `--dump-ir`
;; writes textual IR, optionally at an `after-<pass>` boundary; `--trace-passes`
;; and `--verify-ir` expose optimizer diagnostics without changing normal
;; compilation.
;; `--pic` writes runtime-free, no-entry PIC assembly plus `<output>.fixups`.
;;
;; This is a main-free core (like the other `*_cli_core.tl` modules): the entry
;; `compile-cli-run [count]` dispatches and executes a command, reading `(io.arg 1)`
;; as the command name. The retained bootstrap `compile.tl` driver and the
;; unified `cli.tl` dispatcher both call it, so the single binary drives the
;; compiler.
(import stdlib.io)
(import stdlib.arena)
(import stdlib.fs)
(import stdlib.vector)
(import (vector.vector String) as cli_svec)
(import cli_option_core as cli_option)
(import compiler_allocation_profile as allocation_profile)
(import compiler_cfg_core as cfg_core)
(import "compiler_check_core.tl")
(import "compiler_driver_core.tl")
(import "compiler_windows_coff_core.tl")
(import "doc_test.tl")
(import "test_cli_core.tl")
(import stdlib.string)
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
(define compile-cli-dump-ir-requested : bool
  false)
(define compile-cli-dump-ir-pass : String
  "")
(define compile-cli-verify-ir-requested : bool
  false)
(define compile-cli-trace-passes-requested : bool
  false)

(defstruct CompileCliCfgNames
  (slots (__tl_dyn-array String))
  (len i64))

(define (compile-cli-cfg-names-with-capacity [capacity : i64]) : CompileCliCfgNames
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (CompileCliCfgNames (make-array String cap) 0)))

(define (compile-cli-cfg-names-empty) : CompileCliCfgNames
  (compile-cli-cfg-names-with-capacity 4))

(define (compile-cli-cfg-names-copy-range!
  [dst : (&mut dst (__tl_dyn-array String))]
  [src : (& src (__tl_dyn-array String))]
  [index : i64]
  [count : i64]) : unit
  (let
    [i : i64 index]
    (while (< i count)
      (begin
        (array-set! dst i (array-ref src i))
        (set! i (+ i 1))))))

(define (compile-cli-cfg-names-grow! [names : (&mut names CompileCliCfgNames)]) : unit
  (let
    [count : i64 (struct-get names len)]
    [old-cap : i64 (array-length (struct-get names slots))]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [bigger : (__tl_dyn-array String) (make-array String new-cap)]
    (begin
      (compile-cli-cfg-names-copy-range!
        (&mut bigger)
        (& (struct-get names slots))
        0
        count)
      (set! (struct-get names slots) bigger))))

(define (compile-cli-cfg-names-push!
  [names : (&mut names CompileCliCfgNames)]
  [name : String]) : unit
  (begin
    (if (< (struct-get names len) (array-length (struct-get names slots)))
      unit
      (compile-cli-cfg-names-grow! names))
    (let
      [index : i64 (struct-get names len)]
      (begin
        (array-set! (struct-get names slots) index name)
        (set! (struct-get names len) (+ index 1))))))

(define (compile-cli-cfg-names-get
  [names : (& names CompileCliCfgNames)]
  [index : i64]) : String
  (if (if (>= index 0)
    (< index (struct-get names len))
    false)
    (array-ref (struct-get names slots) index)
    ""))

(define (compile-cli-cfg-names-add [names : CompileCliCfgNames] [name : String]) : CompileCliCfgNames
  (let
    [next : CompileCliCfgNames names]
    (begin
      (compile-cli-cfg-names-push! (&mut next) name)
      next)))

(define (compile-cli-cfg-names-to-env-from
  [names : (& names CompileCliCfgNames)]
  [index : i64]
  [env : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (if (>= index (struct-get names len))
    env
    (compile-cli-cfg-names-to-env-from
      names
      (+ index 1)
      (compiler-cfg-enable env (compile-cli-cfg-names-get names index)))))

(define (compile-cli-cfg-names-to-env [names : CompileCliCfgNames]) : sym_i64_env.SymI64Env
  (compile-cli-cfg-names-to-env-from (& names) 0 (compiler-cfg-empty)))

(define (compile-cli-cfg-names-to-env-with-intern-state-from
  [names : (& names CompileCliCfgNames)]
  [index : i64]
  [env : sym_i64_env.SymI64Env]
  [intern-state : ci.InternCompatState]) : sym_i64_env.SymI64Env
  (if (>= index (struct-get names len))
    env
    (compile-cli-cfg-names-to-env-with-intern-state-from
      names
      (+ index 1)
      (cfg_core.compiler-cfg-enable-with-intern-state
        env
        (compile-cli-cfg-names-get names index)
        intern-state)
      intern-state)))

(define (compile-cli-cfg-names-to-env-with-intern-state
  [names : CompileCliCfgNames]
  [intern-state : ci.InternCompatState]) : sym_i64_env.SymI64Env
  (compile-cli-cfg-names-to-env-with-intern-state-from
    (& names)
    0
    (compiler-cfg-empty)
    intern-state))

(defenum CompileCliConfig
  (Config
    String
    String
    bool
    bool
    bool
    CompilerBackendTarget
    cli_svec.Vec
    CompileCliCfgNames
    CompilerBackendMode
    i64))

(defenum CompileCliBatchConfig
  (Config
    String
    bool
    CompilerBackendTarget
    cli_svec.Vec
    CompileCliCfgNames
    CompilerBackendMode
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
  (Check String cli_svec.Vec)
  (Help)
  (Error String))

(defenum ResultCompileCliCheckConfig
  (Ok String cli_svec.Vec)
  (Err String))

(defenum ResultCompileCliTarget
  (Ok CompilerBackendTarget)
  (Err String))

(define (compile-cli-path-separator? [c : char]) : bool
  (or (= c '/') (= c '\\')))

(define (compile-cli-flag? [value : String]) : bool
  (and (> (string.string-length value) 0) (= (string.string-ref value 0) '-')))

(define (compile-cli-after-pass? [value : String]) : bool
  (and
    (> (string.string-length value) 6)
    (string.eq (string.substring value 0 6) "after-")))

(define (compile-cli-usage) : String
  "Usage:\n  typelisp check <file.tl> [--stdlib-root <dir>...]\n  typelisp compile <file.tl> [-o <file>] [--debug|-g] [--emit-ir | --dump-ir [after-<pass>]] [--verify-ir] [--trace-passes] [--pic] [--target <target>] [--backend-mode <mode>] [--opt-level <0|1|2>] [--stdlib-root <dir>...] [--cfg <name>...] [--profile-allocations]\n  typelisp compile --batch <input-output-list> [--debug|-g] [--target <target>] [--backend-mode <mode>] [--opt-level <0|1|2>] [--stdlib-root <dir>...] [--cfg <name>...] [--prefix-cache-stats] [--profile-allocations]\n  typelisp compile --batch <artifact-list> --windows-coff-plan <result-plan> --target windows-x86_64 [--debug|-g] [--backend-mode <mode>] [--opt-level <0|1|2>] [--stdlib-root <dir>...] [--cfg <name>...] [--prefix-cache-stats] [--profile-allocations]")

(define (compile-cli-message-with-usage [message : String]) : String
  (string.append message (string.append "\n\n" (compile-cli-usage))))

(define (compile-cli-default-output-with-extension
  [input-path : String]
  [extension : String]) : String
  (let
    [n : i64 (string.string-length input-path)]
    [i : i64 0]
    [last-dot : i64 -1]
    [last-sep : i64 -1]
    (begin
      (while (< i n)
        (let
          [c : char (string.string-ref input-path i)]
          (begin
            (if (= c '.')
              (set! last-dot i)
              (set! last-dot last-dot))
            (if (compile-cli-path-separator? c)
              (set! last-sep i)
              (set! last-sep last-sep))
            (set! i (+ i 1)))))
      (if (> last-dot last-sep)
        (string.append (string.substring input-path 0 last-dot) extension)
        (string.append input-path extension)))))

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
    (ResultCompileCliTarget.Ok (CompilerBackendTarget.Linux))
    (if (or
      (string.eq value "windows-x86_64")
      (string.eq value "windows_x86_64"))
      (ResultCompileCliTarget.Ok (CompilerBackendTarget.Windows))
      (ResultCompileCliTarget.Err (compile-cli-unknown-target value)))))

(define (compile-cli-invalid-opt-level [value : String]) : String
  (str_cat.str-cat
    "compile: invalid --opt-level "
    value
    "; expected 0, 1, or 2"))

;; `--backend-mode` parity with Rust (which accepts scalar/avx2/avx512).
(defenum ResultCompileCliBackendMode
  (Ok CompilerBackendMode)
  (Err String))

(define (compile-cli-backend-mode [value : String]) : ResultCompileCliBackendMode
  (cond
    [(string.eq value "scalar")
      (ResultCompileCliBackendMode.Ok (CompilerBackendMode.Scalar))]
    [(string.eq value "avx2")
      (ResultCompileCliBackendMode.Ok (CompilerBackendMode.Avx2))]
    [(string.eq value "avx512")
      (ResultCompileCliBackendMode.Ok (CompilerBackendMode.Avx512))]
    [else
      (ResultCompileCliBackendMode.Err
        (str_cat.str-cat
          "Error: unknown backend mode '"
          value
          "'. Expected scalar, avx2, or avx512"))]))

(define (compile-cli-parse-common-option
  [kind : cli_option.CliCommonOptionKind]
  [value : String]
  [next-idx : i64]
  [count : i64]
  [input-path : String]
  [output-path : String]
  [has-output : bool]
  [has-target : bool]
  [target : CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [cfgs : CompileCliCfgNames]
  [emit-ir : bool]
  [pic : bool]
  [has-opt-level : bool]
  [opt-level : i64]
  [backend-mode : CompilerBackendMode]) : ResultCompileCliConfig
  (match kind
    [(cli_option.CliCommonOptionKind.StdlibRoot)
      (compile-cli-parse-options
        next-idx
        count
        input-path
        output-path
        has-output
        has-target
        target
        (let
          [next-roots : cli_svec.Vec stdlib-roots]
          (begin
            (cli_svec.push (&mut next-roots) value)
            next-roots))
        cfgs
        emit-ir
        pic
        has-opt-level
        opt-level
        backend-mode)]
    [(cli_option.CliCommonOptionKind.Cfg)
      (compile-cli-parse-options
        next-idx
        count
        input-path
        output-path
        has-output
        has-target
        target
        stdlib-roots
        (compile-cli-cfg-names-add cfgs value)
        emit-ir
        pic
        has-opt-level
        opt-level
        backend-mode)]
    [(cli_option.CliCommonOptionKind.Target)
      (if has-target
        (ResultCompileCliConfig.Err
          "compile: --target was provided more than once")
        (match (compile-cli-target value)
          [(ResultCompileCliTarget.Ok parsed-target)
            (compile-cli-parse-options
              next-idx
              count
              input-path
              output-path
              has-output
              true
              parsed-target
              stdlib-roots
              cfgs
              emit-ir
              pic
              has-opt-level
              opt-level
              backend-mode)]
          [(ResultCompileCliTarget.Err message)
            (ResultCompileCliConfig.Err message)]))]
    [(cli_option.CliCommonOptionKind.OptLevel)
      (if has-opt-level
        (ResultCompileCliConfig.Err
          "compile: --opt-level was provided more than once")
        (match (compiler-optimize-parse-level value)
          [(ResultCompilerOptimizeLevel.Ok parsed-level)
            (compile-cli-parse-options
              next-idx
              count
              input-path
              output-path
              has-output
              has-target
              target
              stdlib-roots
              cfgs
              emit-ir
              pic
              true
              parsed-level
              backend-mode)]
          [(ResultCompilerOptimizeLevel.Err)
            (ResultCompileCliConfig.Err (compile-cli-invalid-opt-level value))]))]))

(define (compile-cli-parse-options
  [idx : i64]
  [count : i64]
  [input-path : String]
  [output-path : String]
  [has-output : bool]
  [has-target : bool]
  [target : CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [cfgs : CompileCliCfgNames]
  [emit-ir : bool]
  [pic : bool]
  [has-opt-level : bool]
  [opt-level : i64]
  [backend-mode : CompilerBackendMode]) : ResultCompileCliConfig
  (if (>= idx count)
    (if (and emit-ir pic)
      (ResultCompileCliConfig.Err
        "compile: --pic cannot be combined with --emit-ir")
      (ResultCompileCliConfig.Ok
        (CompileCliConfig.Config
          input-path
          (if (and emit-ir (not has-output))
            (compile-cli-default-ir-output input-path)
            output-path)
          emit-ir
          pic
          has-target
          target
          stdlib-roots
          cfgs
          backend-mode
          opt-level)))
    (let
      [current : String (io.arg idx)]
      (match (cli_option.cli-common-option-parse
        current
        idx
        count
        cli_option.cli-common-option-all)
        [(cli_option.CliCommonOption.Missing kind)
          (ResultCompileCliConfig.Err
            (cli_option.cli-common-option-missing-message "compile" kind))]
        [(cli_option.CliCommonOption.Value kind value next-idx)
          (compile-cli-parse-common-option
            kind
            value
            next-idx
            count
            input-path
            output-path
            has-output
            has-target
            target
            stdlib-roots
            cfgs
            emit-ir
            pic
            has-opt-level
            opt-level
            backend-mode)]
        [(cli_option.CliCommonOption.NotCommon)
          (cond
            [(or (string.eq current "--debug") (string.eq current "-g"))
              (begin
                (compiler-debug-info-set-enabled! true)
                (compile-cli-parse-options
                  (+ idx 1)
                  count
                  input-path
                  output-path
                  has-output
                  has-target
                  target
                  stdlib-roots
                  cfgs
                  emit-ir
                  pic
                  has-opt-level
                  opt-level
                  backend-mode))]
            [(string.eq current "-o")
              (if (>= (+ idx 1) count)
                (ResultCompileCliConfig.Err "compile: -o requires a value")
                (if has-output
                  (ResultCompileCliConfig.Err
                    "compile: -o was provided more than once")
                  (compile-cli-parse-options
                    (+ idx 2)
                    count
                    input-path
                    (io.arg (+ idx 1))
                    true
                    has-target
                    target
                    stdlib-roots
                    cfgs
                    emit-ir
                    pic
                    has-opt-level
                    opt-level
                    backend-mode)))]
            [(string.eq current "--backend-mode")
              (if (>= (+ idx 1) count)
                (ResultCompileCliConfig.Err
                  "compile: --backend-mode requires a value")
                (match (compile-cli-backend-mode (io.arg (+ idx 1)))
                  [(ResultCompileCliBackendMode.Ok parsed-mode)
                    (compile-cli-parse-options
                      (+ idx 2)
                      count
                      input-path
                      output-path
                      has-output
                      has-target
                      target
                      stdlib-roots
                      cfgs
                      emit-ir
                      pic
                      has-opt-level
                      opt-level
                      parsed-mode)]
                  [(ResultCompileCliBackendMode.Err message)
                    (ResultCompileCliConfig.Err message)]))]
            [(string.eq current "--pic")
              (compile-cli-parse-options
                (+ idx 1)
                count
                input-path
                output-path
                has-output
                has-target
                target
                stdlib-roots
                cfgs
                emit-ir
                true
                has-opt-level
                opt-level
                backend-mode)]
            [(string.eq current "--emit-ir")
              (if emit-ir
                (ResultCompileCliConfig.Err
                  "compile: IR output was requested more than once")
                (compile-cli-parse-options
                  (+ idx 1)
                  count
                  input-path
                  output-path
                  has-output
                  has-target
                  target
                  stdlib-roots
                  cfgs
                  true
                  pic
                  has-opt-level
                  opt-level
                  backend-mode))]
            [(string.eq current "--dump-ir")
              (if emit-ir
                (ResultCompileCliConfig.Err
                  "compile: IR output was requested more than once")
                (let
                  [has-pass : bool
                    (and
                      (< (+ idx 1) count)
                      (compile-cli-after-pass? (io.arg (+ idx 1))))]
                  [next-idx : i64
                    (if has-pass
                      (+ idx 2)
                      (+ idx 1))]
                  (begin
                    (set! compile-cli-dump-ir-requested true)
                    (set!
                      compile-cli-dump-ir-pass
                      (if has-pass
                        (let
                          [value : String (io.arg (+ idx 1))]
                          (string.substring
                            value
                            6
                            (- (string.string-length value) 6)))
                        ""))
                    (compile-cli-parse-options
                      next-idx
                      count
                      input-path
                      output-path
                      has-output
                      has-target
                      target
                      stdlib-roots
                      cfgs
                      true
                      pic
                      has-opt-level
                      opt-level
                      backend-mode))))]
            [(string.eq current "--verify-ir")
              (if compile-cli-verify-ir-requested
                (ResultCompileCliConfig.Err
                  "compile: --verify-ir was provided more than once")
                (begin
                  (set! compile-cli-verify-ir-requested true)
                  (compile-cli-parse-options
                    (+ idx 1)
                    count
                    input-path
                    output-path
                    has-output
                    has-target
                    target
                    stdlib-roots
                    cfgs
                    emit-ir
                    pic
                    has-opt-level
                    opt-level
                    backend-mode)))]
            [(string.eq current "--trace-passes")
              (if compile-cli-trace-passes-requested
                (ResultCompileCliConfig.Err
                  "compile: --trace-passes was provided more than once")
                (begin
                  (set! compile-cli-trace-passes-requested true)
                  (compile-cli-parse-options
                    (+ idx 1)
                    count
                    input-path
                    output-path
                    has-output
                    has-target
                    target
                    stdlib-roots
                    cfgs
                    emit-ir
                    pic
                    has-opt-level
                    opt-level
                    backend-mode)))]
            [(string.eq current "--profile-allocations")
              (if compile-cli-allocation-profile-requested
                (ResultCompileCliConfig.Err
                  "compile: --profile-allocations was provided more than once")
                (begin
                  (set! compile-cli-allocation-profile-requested true)
                  (compile-cli-parse-options
                    (+ idx 1)
                    count
                    input-path
                    output-path
                    has-output
                    has-target
                    target
                    stdlib-roots
                    cfgs
                    emit-ir
                    pic
                    has-opt-level
                    opt-level
                    backend-mode)))]
            [else
              (if (compile-cli-flag? current)
                (ResultCompileCliConfig.Err
                  (string.append "compile: unknown flag " current))
                (ResultCompileCliConfig.Err
                  (string.append "compile: unexpected argument " current)))])]))))

(define (compile-cli-batch-parse-common-option
  [kind : cli_option.CliCommonOptionKind]
  [value : String]
  [next-idx : i64]
  [count : i64]
  [batch-path : String]
  [has-target : bool]
  [target : CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [cfgs : CompileCliCfgNames]
  [has-opt-level : bool]
  [opt-level : i64]
  [backend-mode : CompilerBackendMode]
  [prefix-cache-stats : bool]
  [has-windows-coff-plan : bool]
  [windows-coff-plan-path : String]) : ResultCompileCliBatchConfig
  (match kind
    [(cli_option.CliCommonOptionKind.StdlibRoot)
      (compile-cli-batch-parse-options
        next-idx
        count
        batch-path
        has-target
        target
        (let
          [next-roots : cli_svec.Vec stdlib-roots]
          (begin
            (cli_svec.push (&mut next-roots) value)
            next-roots))
        cfgs
        has-opt-level
        opt-level
        backend-mode
        prefix-cache-stats
        has-windows-coff-plan
        windows-coff-plan-path)]
    [(cli_option.CliCommonOptionKind.Cfg)
      (compile-cli-batch-parse-options
        next-idx
        count
        batch-path
        has-target
        target
        stdlib-roots
        (compile-cli-cfg-names-add cfgs value)
        has-opt-level
        opt-level
        backend-mode
        prefix-cache-stats
        has-windows-coff-plan
        windows-coff-plan-path)]
    [(cli_option.CliCommonOptionKind.Target)
      (if has-target
        (ResultCompileCliBatchConfig.Err
          "compile: --target was provided more than once")
        (match (compile-cli-target value)
          [(ResultCompileCliTarget.Ok parsed-target)
            (compile-cli-batch-parse-options
              next-idx
              count
              batch-path
              true
              parsed-target
              stdlib-roots
              cfgs
              has-opt-level
              opt-level
              backend-mode
              prefix-cache-stats
              has-windows-coff-plan
              windows-coff-plan-path)]
          [(ResultCompileCliTarget.Err message)
            (ResultCompileCliBatchConfig.Err message)]))]
    [(cli_option.CliCommonOptionKind.OptLevel)
      (if has-opt-level
        (ResultCompileCliBatchConfig.Err
          "compile: --opt-level was provided more than once")
        (match (compiler-optimize-parse-level value)
          [(ResultCompilerOptimizeLevel.Ok parsed-level)
            (compile-cli-batch-parse-options
              next-idx
              count
              batch-path
              has-target
              target
              stdlib-roots
              cfgs
              true
              parsed-level
              backend-mode
              prefix-cache-stats
              has-windows-coff-plan
              windows-coff-plan-path)]
          [(ResultCompilerOptimizeLevel.Err)
            (ResultCompileCliBatchConfig.Err
              (compile-cli-invalid-opt-level value))]))]))

(define (compile-cli-batch-parse-options
  [idx : i64]
  [count : i64]
  [batch-path : String]
  [has-target : bool]
  [target : CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [cfgs : CompileCliCfgNames]
  [has-opt-level : bool]
  [opt-level : i64]
  [backend-mode : CompilerBackendMode]
  [prefix-cache-stats : bool]
  [has-windows-coff-plan : bool]
  [windows-coff-plan-path : String]) : ResultCompileCliBatchConfig
  (if (>= idx count)
    (if (and
      has-windows-coff-plan
      (or (not has-target) (not (compiler-backend-target-windows? target))))
      (ResultCompileCliBatchConfig.Err
        "compile: --windows-coff-plan requires --target windows-x86_64")
      (if (and
        has-windows-coff-plan
        (string.eq batch-path windows-coff-plan-path))
        (ResultCompileCliBatchConfig.Err
          "compile: --windows-coff-plan result path must differ from the batch input")
        (ResultCompileCliBatchConfig.Ok
          (CompileCliBatchConfig.Config
            batch-path
            has-target
            target
            stdlib-roots
            cfgs
            backend-mode
            opt-level
            prefix-cache-stats
            has-windows-coff-plan
            windows-coff-plan-path))))
    (let
      [current : String (io.arg idx)]
      (match (cli_option.cli-common-option-parse
        current
        idx
        count
        cli_option.cli-common-option-all)
        [(cli_option.CliCommonOption.Missing kind)
          (ResultCompileCliBatchConfig.Err
            (cli_option.cli-common-option-missing-message "compile" kind))]
        [(cli_option.CliCommonOption.Value kind value next-idx)
          (compile-cli-batch-parse-common-option
            kind
            value
            next-idx
            count
            batch-path
            has-target
            target
            stdlib-roots
            cfgs
            has-opt-level
            opt-level
            backend-mode
            prefix-cache-stats
            has-windows-coff-plan
            windows-coff-plan-path)]
        [(cli_option.CliCommonOption.NotCommon)
          (cond
            [(or (string.eq current "--debug") (string.eq current "-g"))
              (begin
                (compiler-debug-info-set-enabled! true)
                (compile-cli-batch-parse-options
                  (+ idx 1)
                  count
                  batch-path
                  has-target
                  target
                  stdlib-roots
                  cfgs
                  has-opt-level
                  opt-level
                  backend-mode
                  prefix-cache-stats
                  has-windows-coff-plan
                  windows-coff-plan-path))]
            [(string.eq current "-o")
              (ResultCompileCliBatchConfig.Err
                "compile: --batch reads output paths from the batch file")]
            [(string.eq current "--emit-ir")
              (ResultCompileCliBatchConfig.Err
                "compile: --batch does not support --emit-ir")]
            [(string.eq current "--pic")
              (ResultCompileCliBatchConfig.Err
                "compile: --batch does not support --pic")]
            [(string.eq current "--backend-mode")
              (if (>= (+ idx 1) count)
                (ResultCompileCliBatchConfig.Err
                  "compile: --backend-mode requires a value")
                (match (compile-cli-backend-mode (io.arg (+ idx 1)))
                  [(ResultCompileCliBackendMode.Ok parsed-mode)
                    (compile-cli-batch-parse-options
                      (+ idx 2)
                      count
                      batch-path
                      has-target
                      target
                      stdlib-roots
                      cfgs
                      has-opt-level
                      opt-level
                      parsed-mode
                      prefix-cache-stats
                      has-windows-coff-plan
                      windows-coff-plan-path)]
                  [(ResultCompileCliBackendMode.Err message)
                    (ResultCompileCliBatchConfig.Err message)]))]
            [(string.eq current "--prefix-cache-stats")
              (compile-cli-batch-parse-options
                (+ idx 1)
                count
                batch-path
                has-target
                target
                stdlib-roots
                cfgs
                has-opt-level
                opt-level
                backend-mode
                true
                has-windows-coff-plan
                windows-coff-plan-path)]
            [(string.eq current "--windows-coff-plan")
              (if has-windows-coff-plan
                (ResultCompileCliBatchConfig.Err
                  "compile: --windows-coff-plan was provided more than once")
                (if (>= (+ idx 1) count)
                  (ResultCompileCliBatchConfig.Err
                    "compile: --windows-coff-plan requires a result path")
                  (let
                    [plan-path : String (io.arg (+ idx 1))]
                    (if (compile-cli-flag? plan-path)
                      (ResultCompileCliBatchConfig.Err
                        "compile: --windows-coff-plan requires a result path")
                      (compile-cli-batch-parse-options
                        (+ idx 2)
                        count
                        batch-path
                        has-target
                        target
                        stdlib-roots
                        cfgs
                        has-opt-level
                        opt-level
                        backend-mode
                        prefix-cache-stats
                        true
                        plan-path)))))]
            [(string.eq current "--profile-allocations")
              (if compile-cli-allocation-profile-requested
                (ResultCompileCliBatchConfig.Err
                  "compile: --profile-allocations was provided more than once")
                (begin
                  (set! compile-cli-allocation-profile-requested true)
                  (compile-cli-batch-parse-options
                    (+ idx 1)
                    count
                    batch-path
                    has-target
                    target
                    stdlib-roots
                    cfgs
                    has-opt-level
                    opt-level
                    backend-mode
                    prefix-cache-stats
                    has-windows-coff-plan
                    windows-coff-plan-path)))]
            [else
              (if (compile-cli-flag? current)
                (ResultCompileCliBatchConfig.Err
                  (string.append "compile: unknown flag " current))
                (ResultCompileCliBatchConfig.Err
                  (string.append "compile: unexpected argument " current)))])]))))

(define (compile-cli-config-from [input-idx : i64] [count : i64]) : ResultCompileCliConfig
  (if (>= input-idx count)
    (ResultCompileCliConfig.Err "compile: expected source path")
    (let
      [input-path : String (io.arg input-idx)]
      (if (compile-cli-flag? input-path)
        (ResultCompileCliConfig.Err
          "compile: expected source path before flags")
        (compile-cli-parse-options
          (+ input-idx 1)
          count
          input-path
          (compile-cli-default-output input-path)
          false
          false
          (CompilerBackendTarget.Linux)
          (cli_svec.new)
          (compile-cli-cfg-names-empty)
          false
          false
          false
          (compiler-optimize-default-level)
          (CompilerBackendMode.Scalar))))))

(define (compile-cli-command-config [count : i64]) : ResultCompileCliConfig
  (compile-cli-config-from 2 count))

(define (compile-cli-batch-config-from [batch-path-idx : i64] [count : i64]) : ResultCompileCliBatchConfig
  (if (>= batch-path-idx count)
    (ResultCompileCliBatchConfig.Err "compile: --batch requires a list file")
    (let
      [batch-path : String (io.arg batch-path-idx)]
      (if (compile-cli-flag? batch-path)
        (ResultCompileCliBatchConfig.Err
          "compile: --batch requires a list file")
        (compile-cli-batch-parse-options
          (+ batch-path-idx 1)
          count
          batch-path
          false
          (CompilerBackendTarget.Linux)
          (cli_svec.new)
          (compile-cli-cfg-names-empty)
          false
          (compiler-optimize-default-level)
          (CompilerBackendMode.Scalar)
          false
          false
          "")))))

(define (compile-cli-command-action [count : i64]) : CompileCliAction
  (if (and (> count 2) (string.eq (io.arg 2) "--batch"))
    (match (compile-cli-batch-config-from 3 count)
      [(ResultCompileCliBatchConfig.Ok config) (CompileCliAction.Batch config)]
      [(ResultCompileCliBatchConfig.Err message)
        (CompileCliAction.Error message)])
    (match (compile-cli-command-config count)
      [(ResultCompileCliConfig.Ok config) (CompileCliAction.Run config)]
      [(ResultCompileCliConfig.Err message) (CompileCliAction.Error message)])))

(define (compile-cli-check-parse-options
  [idx : i64]
  [count : i64]
  [input-path : String]
  [stdlib-roots : cli_svec.Vec]) : ResultCompileCliCheckConfig
  (if (>= idx count)
    (ResultCompileCliCheckConfig.Ok input-path stdlib-roots)
    (let
      [current : String (io.arg idx)]
      (match (cli_option.cli-common-option-parse
        current
        idx
        count
        cli_option.cli-common-option-stdlib-root)
        [(cli_option.CliCommonOption.Missing kind)
          (ResultCompileCliCheckConfig.Err
            (cli_option.cli-common-option-missing-message "Error" kind))]
        [(cli_option.CliCommonOption.Value _ value next-idx)
          (compile-cli-check-parse-options
            next-idx
            count
            input-path
            (let
              [next-roots : cli_svec.Vec stdlib-roots]
              (begin
                (cli_svec.push (&mut next-roots) value)
                next-roots)))]
        [(cli_option.CliCommonOption.NotCommon)
          (begin
            (io.print-error (string.append "Warning: unknown flag: " current))
            (compile-cli-check-parse-options
              (+ idx 1)
              count
              input-path
              stdlib-roots))]))))

(define (compile-cli-check-config-from
  [input-idx : i64]
  [count : i64]
  [missing-message : String]) : ResultCompileCliCheckConfig
  (if (>= input-idx count)
    (ResultCompileCliCheckConfig.Err missing-message)
    (compile-cli-check-parse-options
      (+ input-idx 1)
      count
      (io.arg input-idx)
      (cli_svec.new))))

(define (compile-cli-top-level-check-config [count : i64]) : ResultCompileCliCheckConfig
  (compile-cli-check-config-from
    2
    count
    (compile-cli-message-with-usage "Error: missing file argument")))

(define (compile-cli-dispatch [count : i64]) : CompileCliAction
  (if (< count 2)
    (CompileCliAction.Error
      (compile-cli-message-with-usage "typelisp: expected command"))
    (let
      [command : String (io.arg 1)]
      (cond
        [(or
            (string.eq command "help")
            (string.eq command "--help")
            (string.eq command "-h"))
          (CompileCliAction.Help)]
        [(string.eq command "compile") (compile-cli-command-action count)]
        [(string.eq command "check")
          (match (compile-cli-top-level-check-config count)
            [(ResultCompileCliCheckConfig.Ok input-path roots)
              (CompileCliAction.Check input-path roots)]
            [(ResultCompileCliCheckConfig.Err message)
              (CompileCliAction.Error message)])]
        [else
          (CompileCliAction.Error
            (compile-cli-message-with-usage
              (string.append "Unknown command: " command)))]))))

(define (compile-cli-typecheck-doctests
  [input-path : String]
  [stdlib-roots : cli_svec.Vec]) : i64
  (match (io.try-read-file (& input-path))
    [(io.ErrIoString _) 0]
    [(io.OkIoString source)
      (let
        [report : DocTestRunReport
          (doc-test-typecheck-source-with-roots input-path source stdlib-roots)]
        (if (doc-test-run-report-ok? report)
          0
          (begin
            (io.print-error (doc-test-run-report-render report))
            1)))]))

(define (compile-cli-ir-verification-failed?) : bool
  (let
    [message : String (compiler-opt-debug-verification-error)]
    (if (= (string.string-length message) 0)
      false
      (begin
        (io.print-error
          (str_cat.str-cat "compile: IR verification failed: " message "\n"))
        true))))

(define (compile-cli-write-result-with-ir-verification
  [state : CompilerDriverState]
  [result : ResultCompilerDriver]
  [output-path : String]) : i64
  (if (compile-cli-ir-verification-failed?)
    1
    (compiler-driver-write-result
      (compiler-driver-state-profile state)
      result
      output-path)))

(define (compile-cli-write-buffer-result-with-ir-verification
  [state : CompilerDriverState]
  [result : ResultCompilerDriverBuffer]
  [output-path : String]) : i64
  (if (compile-cli-ir-verification-failed?)
    1
    (compiler-driver-write-buffer-result
      (compiler-driver-state-profile state)
      result
      output-path)))

(define (compile-cli-write-pic-result-with-ir-verification
  [state : CompilerDriverState]
  [result : ResultCompilerDriverPic]
  [output-path : String]) : i64
  (if (compile-cli-ir-verification-failed?)
    1
    (compiler-driver-write-pic-result
      (compiler-driver-state-profile state)
      result
      output-path)))

(define (compile-cli-run-compile-file
  [state : CompilerDriverState]
  [input-path : String]
  [output-path : String]
  [emit-ir : bool]
  [pic : bool]
  ;; lint-allow: unused-variable
  [has-target : bool]
  [target : CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [cfgs : CompileCliCfgNames]
  [backend-mode : CompilerBackendMode]
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
    (if (= (compiler-driver-state-intern-generation state) 0)
      (ci.intern-compat-state-reset!
        (compiler-driver-state-owned-interns state))
      unit)
    (compiler-driver-state-install-pools! state)
    (compiler-driver-state-install-interns! state)
    (cfg
      compile-startup-profile
      (startup_profile.compiler-startup-profile-mark-preflight-begin!)
      unit)
    (let
      [doctest-status : i64
        (compile-cli-typecheck-doctests input-path stdlib-roots)]
      (if (= doctest-status 0)
        (let
          [inline-test-status : i64
            (if inline-preflight
              (tltest-inline-typecheck-file-with-cfg
                input-path
                stdlib-roots
                (compiler-driver-target-cfgs
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
              (compiler-driver-state-reset-file-state! state)
              (compiler-opt-debug-configure!
                compile-cli-trace-passes-requested
                compile-cli-dump-ir-pass
                compile-cli-verify-ir-requested)
              (let
                [emit-cfgs : sym_i64_env.SymI64Env
                  (compile-cli-cfg-names-to-env-with-intern-state
                    cfgs
                    (compiler-driver-state-owned-interns state))]
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
                        state
                        (if compile-cli-dump-ir-requested
                          (compiler-driver-state-emit-ir-text-file-with-target-roots-level-mode-and-cfg
                            state
                            input-path
                            target
                            stdlib-roots
                            opt-level
                            backend-mode
                            emit-cfgs
                            compile-cli-dump-ir-pass)
                          (compiler-driver-state-emit-ir-summary-file-with-target-roots-level-mode-and-cfg
                            state
                            input-path
                            target
                            stdlib-roots
                            opt-level
                            backend-mode
                            emit-cfgs))
                        output-path)
                      (if pic
                        (compile-cli-write-pic-result-with-ir-verification
                          state
                          (compiler-driver-state-emit-file-pic-with-target-roots-level-mode-and-cfg
                            state
                            input-path
                            target
                            true
                            stdlib-roots
                            opt-level
                            backend-mode
                            emit-cfgs)
                          output-path)
                        (compile-cli-write-buffer-result-with-ir-verification
                          state
                          (compiler-driver-state-emit-file-buffer-with-target-roots-level-mode-and-cfg
                            state
                            input-path
                            target
                            true
                            stdlib-roots
                            opt-level
                            backend-mode
                            emit-cfgs)
                          output-path))))]
                (begin
                  (compiler-driver-state-capture-session-floors! state)
                  status)))
            inline-test-status))
        (begin
          (cfg
            compile-startup-profile
            (startup_profile.compiler-startup-profile-mark-preflight-end!)
            unit)
          doctest-status)))))

(define (compile-cli-write-windows-batch-artifact
  [_state : CompilerDriverState]
  [result : ResultCompilerWindowsBatchArtifact]
  [object-path : String]
  [assembly-path : String]) : ResultCompileCliWindowsBatchEntry
  (if (compile-cli-ir-verification-failed?)
    (ResultCompileCliWindowsBatchEntry.Err 1)
    (match result
      [(ResultCompilerWindowsBatchArtifact.CoffObject object)
        (let
          [write-status : i64
            (begin
              (cfg
                compile-profile
                (compiler-driver-profile-start-phase
                  (compiler-driver-state-profile _state)))
              (match (io.try-write-file (& object-path) (& object))
                [(io.OkIoUnit) 0]
                [(io.ErrIoUnit error)
                  (begin
                    (io.print-error
                      (str_cat.str-cat
                        "compile: cannot write "
                        object-path
                        ": "
                        (io.error-message error)
                        "\n"))
                    1)]))]
          (begin
            (cfg
              compile-profile
              (compiler-driver-profile-finish-phase
                (compiler-driver-state-profile _state)
                "write"))
            (compiler-driver-allocation-profile-snapshot! "write")
            (cfg
              compile-profile
              (compiler-driver-profile-finish-total
                (compiler-driver-state-profile _state)))
            (if (= write-status 0)
              (begin
                (io.print-string
                  (string.append "Wrote " (string.append object-path "\n")))
                (ResultCompileCliWindowsBatchEntry.Ok
                  "coff-object"
                  object-path
                  "none"))
              (ResultCompileCliWindowsBatchEntry.Err write-status))))]
      [(ResultCompilerWindowsBatchArtifact.Assembly asm category)
        (let
          [write-status : i64
            (begin
              (cfg
                compile-profile
                (compiler-driver-profile-start-phase
                  (compiler-driver-state-profile _state)))
              (compiler-driver-write-text-buf assembly-path asm))]
          (begin
            (cfg
              compile-profile
              (compiler-driver-profile-finish-phase
                (compiler-driver-state-profile _state)
                "write"))
            (compiler-driver-allocation-profile-snapshot! "write")
            (cfg
              compile-profile
              (compiler-driver-profile-finish-total
                (compiler-driver-state-profile _state)))
            (if (= write-status 0)
              (begin
                (io.print-string
                  (string.append "Wrote " (string.append assembly-path "\n")))
                (ResultCompileCliWindowsBatchEntry.Ok
                  "assembly"
                  assembly-path
                  category))
              (ResultCompileCliWindowsBatchEntry.Err write-status))))]
      [(ResultCompilerWindowsBatchArtifact.Err diag)
        (begin
          (compiler-driver-allocation-profile-snapshot! "write-error")
          (cfg
            compile-profile
            (compiler-driver-profile-finish-total
              (compiler-driver-state-profile _state)))
          (io.print-error
            (compiler-driver-render-source-diagnostic (box-get diag)))
          (ResultCompileCliWindowsBatchEntry.Err 1))])))

(define (compile-cli-run-windows-batch-file
  [state : CompilerDriverState]
  [input-path : String]
  [object-path : String]
  [assembly-path : String]
  [force-assembly : bool]
  [stdlib-roots : cli_svec.Vec]
  [cfgs : CompileCliCfgNames]
  [backend-mode : CompilerBackendMode]
  [opt-level : i64]) : ResultCompileCliWindowsBatchEntry
  (begin
    ;; Match the legacy batch entry lifecycle exactly through the one-lowering
    ;; driver boundary. The selected bytes are written before the caller tears
    ;; down this entry's scratch arena.
    (if (= (compiler-driver-state-intern-generation state) 0)
      (ci.intern-compat-state-reset!
        (compiler-driver-state-owned-interns state))
      unit)
    (compiler-driver-state-install-pools! state)
    (compiler-driver-state-install-interns! state)
    (cfg
      compile-startup-profile
      (startup_profile.compiler-startup-profile-mark-preflight-begin!)
      unit)
    (let
      [doctest-status : i64
        (compile-cli-typecheck-doctests input-path stdlib-roots)]
      (if (= doctest-status 0)
        (begin
          (cfg
            compile-startup-profile
            (startup_profile.compiler-startup-profile-mark-preflight-end!)
            unit)
          (compiler-driver-state-reset-file-state! state)
          (compiler-opt-debug-configure!
            compile-cli-trace-passes-requested
            compile-cli-dump-ir-pass
            compile-cli-verify-ir-requested)
          (let
            [emit-cfgs : sym_i64_env.SymI64Env
              (compile-cli-cfg-names-to-env-with-intern-state
                cfgs
                (compiler-driver-state-owned-interns state))]
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
                  state
                  (compiler-windows-batch-state-emit-file
                    state
                    input-path
                    stdlib-roots
                    opt-level
                    backend-mode
                    emit-cfgs
                    force-assembly)
                  object-path
                  assembly-path))]
            (begin
              (compiler-driver-state-capture-session-floors! state)
              result)))
        (begin
          (cfg
            compile-startup-profile
            (startup_profile.compiler-startup-profile-mark-preflight-end!)
            unit)
          (ResultCompileCliWindowsBatchEntry.Err doctest-status))))))

(define (compile-cli-run-batch-inline-tests-from
  [entries : (& entries cli_svec.Vec)]
  [index : i64]
  [stride : i64]
  [target : CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [cfgs : CompileCliCfgNames]
  [ran-preflight : bool]) : i64
  (if (>= index (cli_svec.len entries))
    (if ran-preflight
      (begin
        ;; Detach the final preflight's loaded AST before its scratch owner is
        ;; gone and before the separate batch driver state is installed.
        (tltest-inline-clear-load-only-caches!)
        (compiler-driver-reset-file-state!)
        0)
      0)
    (let
      [input-path : String (cli_svec.get entries index "")]
      [has-inline-tests
        : bool
        ;; The predicate reads the whole source. Keep that transient buffer in
        ;; the same per-source lifetime as the optional inline typecheck instead
        ;; of retaining every manifest source in the batch caller arena.
        (with-scratch (tltest-source-has-inline-tests? input-path))]
      [status
        : i64
        ;; Match package inline preflight isolation: each source owns a
        ;; destroyable scratch chain and starts from a full file reset. Rebuild
        ;; cfg ids inside that reset because intern generations are per entry.
        (if has-inline-tests
          (with-scratch
            (begin
              (tltest-inline-clear-load-only-caches!)
              (compiler-driver-reset-file-state!)
              (tltest-inline-typecheck-file-with-cfg
                input-path
                stdlib-roots
                (compiler-driver-target-cfgs
                  target
                  (compile-cli-cfg-names-to-env cfgs))
                "typecheck-prefix-inline-compile-batch")))
          0)]
      ;; `compiler-load-default-session-use!` copies the active session wrapper
      ;; into the current arena. The preflight reset therefore leaves that
      ;; wrapper scratch-owned even though its default session data is stable.
      ;; Reinstall it after `with-scratch` has restored the enclosing arena.
      [_restore-default-session : unit
        (if has-inline-tests
          (compiler-load-default-session-use!)
          unit)]
      [_clear-entry : unit
        (if has-inline-tests
          (tltest-inline-clear-load-caches!)
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
  [entries : cli_svec.Vec]
  [target : CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [cfgs : CompileCliCfgNames]) : i64
  (compile-cli-run-batch-inline-tests-from
    (& entries)
    0
    2
    target
    stdlib-roots
    cfgs
    false))

(define (compile-cli-run-windows-batch-inline-tests
  [entries : cli_svec.Vec]
  [target : CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [cfgs : CompileCliCfgNames]) : i64
  (compile-cli-run-batch-inline-tests-from
    (& entries)
    0
    4
    target
    stdlib-roots
    cfgs
    false))

(define (compile-cli-batch-line-end [text : String] [start : i64] [n : i64]) : i64
  (let
    [i : i64 start]
    [done : bool false]
    (begin
      (while (and (not done) (< i n))
        (let
          [c : char (string.string-ref text i)]
          (if (or (= c '\n') (= c '\r'))
            (set! done true)
            (set! i (+ i 1)))))
      i)))

(define (compile-cli-batch-next-line [text : String] [line-end : i64] [n : i64]) : i64
  (if (>= line-end n)
    n
    (if (and
      (= (string.string-ref text line-end) '\r')
      (< (+ line-end 1) n)
      (= (string.string-ref text (+ line-end 1)) '\n'))
      (+ line-end 2)
      (+ line-end 1))))

(define (compile-cli-batch-find-separator
  [text : String]
  [start : i64]
  [end : i64]) : i64
  (let
    [i : i64 start]
    [found : i64 -1]
    (begin
      (while (and (= found -1) (< i end))
        (if (= (string.string-ref text i) '|')
          (set! found i)
          (set! i (+ i 1))))
      found)))

(define (compile-cli-batch-line-error [line : i64] [message : String]) : i64
  (begin
    (io.print-error
      (str_cat.str-cat
        "compile: malformed --batch line "
        (string.int->string line)
        ": "
        message
        "\n"))
    1))

(define (compile-cli-batch-parse-entries-into!
  [text : String]
  [start : i64]
  [line : i64]
  [n : i64]
  [entries : (&mut entries cli_svec.Vec)]) : i64
  (if (>= start n)
    0
    (let
      [line-end : i64 (compile-cli-batch-line-end text start n)]
      [next-start : i64 (compile-cli-batch-next-line text line-end n)]
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
                    (begin
                      (cli_svec.push entries input-path)
                      (cli_svec.push entries output-path)
                      (compile-cli-batch-parse-entries-into!
                        text
                        next-start
                        (+ line 1)
                        n
                        entries))))))))))))

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
      (ResultCompileCliBatchEntryList.Ok entries)
      (ResultCompileCliBatchEntryList.Err status))))

(define (compile-cli-windows-batch-parse-entries-into!
  [text : String]
  [start : i64]
  [line : i64]
  [n : i64]
  [entries : (&mut entries cli_svec.Vec)]) : i64
  (if (>= start n)
    0
    (let
      [line-end : i64 (compile-cli-batch-line-end text start n)]
      [next-start : i64 (compile-cli-batch-next-line text line-end n)]
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
                                (begin
                                  (cli_svec.push entries input-path)
                                  (cli_svec.push entries object-path)
                                  (cli_svec.push entries assembly-path)
                                  (cli_svec.push entries mode)
                                  (compile-cli-windows-batch-parse-entries-into!
                                    text
                                    next-start
                                    (+ line 1)
                                    n
                                    entries))))))))))))))))))

(define (compile-cli-windows-batch-parse-entries-from
  [text : String]
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
      (ResultCompileCliWindowsBatchEntryList.Ok entries)
      (ResultCompileCliWindowsBatchEntryList.Err status))))

(define (compile-cli-run-batch-entries-from
  [state : CompilerDriverState]
  [entries : (& entries cli_svec.Vec)]
  [index : i64]
  [has-target : bool]
  [target : CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [cfgs : CompileCliCfgNames]
  [backend-mode : CompilerBackendMode]
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
          (compiler-driver-batch-profile-start-entry!
            (compiler-driver-state-profile state)
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
            state
            input-path
            output-path
            false
            false
            has-target
            target
            stdlib-roots
            cfgs
            backend-mode
            opt-level
            false))]
      [_profile-emit : unit
        (cfg
          compile-profile
          (compiler-driver-batch-profile-mark!
            (compiler-driver-state-profile state)
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
          (compiler-driver-state-release-file-state-profiled! state ordinal)
          (compiler-driver-state-release-file-state! state))
        (allocation_profile.compiler-allocation-profile-control!
          2
          "batch-post-release"
          "entry-scratch-saved"
          scratch-end)
        (begin
          (compiler-driver-restore-arena-owner-current! (arena.raw-handle home))
          (unsafe
            (arena.tl_arena_destroy scratch-end)))
        ;; The next standalone preflight and the opt-in allocation profiler
        ;; still observe compatibility globals between batch entries. Install
        ;; the already-reset job context at that explicit boundary, after the
        ;; entry scratch owner has been destroyed.
        (compiler-driver-state-install-pools! state)
        (compiler-driver-state-install-interns! state)
        ;; The reset above has republished every compatibility aggregate into
        ;; `compat`; only now is the preceding entry's owner unreachable.
        (if (= previous-compat-arena 0)
          unit
          (unsafe
            (arena.tl_arena_destroy previous-compat-arena)))
        (compiler-driver-allocation-profile-snapshot! "batch-steady")
        (allocation_profile.compiler-allocation-profile-control!
          2
          "batch-steady"
          "batch-compat-reset"
          (arena.raw-handle compat))
        (cfg
          compile-profile
          (compiler-driver-batch-profile-mark!
            (compiler-driver-state-profile state)
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

(define (compile-cli-run-batch-entries
  [state : CompilerDriverState]
  [entries : cli_svec.Vec]
  [has-target : bool]
  [target : CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [cfgs : CompileCliCfgNames]
  [backend-mode : CompilerBackendMode]
  [opt-level : i64]) : i64
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
  [state : CompilerDriverState]
  [entries : (& entries cli_svec.Vec)]
  [index : i64]
  [stdlib-roots : cli_svec.Vec]
  [cfgs : CompileCliCfgNames]
  [backend-mode : CompilerBackendMode]
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
          (compiler-driver-batch-profile-start-entry!
            (compiler-driver-state-profile state)
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
            state
            input-path
            object-path
            assembly-path
            force-assembly
            stdlib-roots
            cfgs
            backend-mode
            opt-level))]
      [_profile-emit : unit
        (cfg
          compile-profile
          (compiler-driver-batch-profile-mark!
            (compiler-driver-state-profile state)
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
          (compiler-driver-restore-arena-owner-current! (arena.raw-handle home))
          (match entry-result
            [(ResultCompileCliWindowsBatchEntry.Ok kind path category)
              (begin
                (cli_svec.push results input-path)
                (cli_svec.push results kind)
                (cli_svec.push results path)
                (cli_svec.push results category)
                0)]
            [(ResultCompileCliWindowsBatchEntry.Err entry-status) entry-status]))]
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
          (compiler-driver-state-release-file-state-profiled! state ordinal)
          (compiler-driver-state-release-file-state! state))
        (allocation_profile.compiler-allocation-profile-control!
          2
          "batch-post-release"
          "entry-scratch-saved"
          scratch-end)
        (begin
          (compiler-driver-restore-arena-owner-current! (arena.raw-handle home))
          (unsafe
            (arena.tl_arena_destroy scratch-end)))
        (compiler-driver-state-install-pools! state)
        (compiler-driver-state-install-interns! state)
        (if (= previous-compat-arena 0)
          unit
          (unsafe
            (arena.tl_arena_destroy previous-compat-arena)))
        (compiler-driver-allocation-profile-snapshot! "batch-steady")
        (allocation_profile.compiler-allocation-profile-control!
          2
          "batch-steady"
          "batch-compat-reset"
          (arena.raw-handle compat))
        (cfg
          compile-profile
          (compiler-driver-batch-profile-mark!
            (compiler-driver-state-profile state)
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
    (begin
      (while (< index count)
        (begin
          (text_buf.append! out (cli_svec.get results index ""))
          (text_buf.append! out "|")
          (text_buf.append! out (cli_svec.get results (+ index 1) ""))
          (text_buf.append! out "|")
          (text_buf.append! out (cli_svec.get results (+ index 2) ""))
          (text_buf.append! out "|")
          (text_buf.append! out (cli_svec.get results (+ index 3) ""))
          (text_buf.append! out "\n")
          (set! index (+ index 4))))
      (text_buf.render out))))

(define (compile-cli-write-windows-batch-result-plan
  [plan-path : String]
  [results : (& results cli_svec.Vec)]) : i64
  (let
    [contents : String (compile-cli-windows-batch-result-plan results)]
    (match (io.try-write-file (& plan-path) (& contents))
      [(io.OkIoUnit)
        (begin
          (io.print-string
            (string.append "Wrote " (string.append plan-path "\n")))
          0)]
      [(io.ErrIoUnit error)
        (begin
          (io.print-error
            (str_cat.str-cat
              "compile: cannot write Windows COFF result plan "
              plan-path
              ": "
              (io.error-message error)
              "\n"))
          1)])))

(define (compile-cli-run-windows-batch-entries
  [state : CompilerDriverState]
  [entries : cli_svec.Vec]
  [result-plan-path : String]
  [stdlib-roots : cli_svec.Vec]
  [cfgs : CompileCliCfgNames]
  [backend-mode : CompilerBackendMode]
  [opt-level : i64]) : i64
  (let
    [results : cli_svec.Vec (cli_svec.new)]
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
  [state : CompilerDriverState]
  [text : String]
  [start : i64]
  [line : i64]
  [has-target : bool]
  [target : CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [cfgs : CompileCliCfgNames]
  [backend-mode : CompilerBackendMode]
  [opt-level : i64]) : i64
  (match (compile-cli-batch-parse-entries-from
    text
    start
    line
    (string.string-length text))
    [(ResultCompileCliBatchEntryList.Ok entries)
      (let
        [_install-preflight-state : unit
          (begin
            ;; The all-source inline preflight must fail before any batch
            ;; output is written. Route its compatibility load/typecheck work
            ;; through this batch's already-owned pools and intern table so the
            ;; first entry reset can destroy that residency. Leaving the
            ;; process-default owners installed retains the largest later
            ;; preflight source beside every subsequent compile.
            (compiler-driver-state-install-pools! state)
            (compiler-driver-state-install-interns! state))]
        [inline-test-status : i64
          (compile-cli-run-batch-inline-tests entries target stdlib-roots cfgs)]
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
    [(ResultCompileCliBatchEntryList.Err status) status]))

(define (compile-cli-run-windows-batch-from
  [state : CompilerDriverState]
  [text : String]
  [start : i64]
  [line : i64]
  [result-plan-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [cfgs : CompileCliCfgNames]
  [backend-mode : CompilerBackendMode]
  [opt-level : i64]) : i64
  (match (compile-cli-windows-batch-parse-entries-from
    text
    start
    line
    (string.string-length text))
    [(ResultCompileCliWindowsBatchEntryList.Ok entries)
      (let
        [_install-preflight-state : unit
          (begin
            (compiler-driver-state-install-pools! state)
            (compiler-driver-state-install-interns! state))]
        [inline-test-status : i64
          (compile-cli-run-windows-batch-inline-tests
            entries
            target
            stdlib-roots
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
    [(ResultCompileCliWindowsBatchEntryList.Err status) status]))

(define (compile-cli-remove-stale-windows-batch-plan [plan-path : String]) : i64
  (match (fs.try-remove-file-if-exists (& plan-path))
    [(io.OkIoUnit) 0]
    [(io.ErrIoUnit error)
      (begin
        (io.print-error
          (str_cat.str-cat
            "compile: cannot remove stale Windows COFF result plan "
            plan-path
            ": "
            (io.error-message error)
            "\n"))
        1)]))

(define (compile-cli-run-batch [config : CompileCliBatchConfig]) : i64
  (let
    [state : CompilerDriverState
      (compiler-driver-state-session-program-cache-disable
        (compiler-driver-state-new-for-compile))]
    (match config
      [(CompileCliBatchConfig.Config
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
              (compiler-driver-state-prefix-cache-enable! state)
              (compiler-driver-state-prefix-cache-clear! state)
              (if has-windows-coff-plan
                (let
                  [remove-status : i64
                    (compile-cli-remove-stale-windows-batch-plan
                      windows-coff-plan-path)]
                  (if (= remove-status 0)
                    (compile-cli-run-windows-batch-from
                      state
                      (io.read-file batch-path)
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
                  state
                  (io.read-file batch-path)
                  0
                  1
                  has-target
                  target
                  stdlib-roots
                  cfgs
                  backend-mode
                  opt-level)))]
          (begin
            (if prefix-cache-stats
              (compiler-driver-state-prefix-cache-print-stats
                state
                "compile-batch")
              unit)
            (compiler-driver-state-prefix-cache-clear! state)
            (compiler-driver-state-prefix-cache-disable! state)
            status))])))

(define (compile-cli-run-action [action : CompileCliAction]) : i64
  (match action
    [(CompileCliAction.Run config)
      (begin
        (cfg
          compile-startup-profile
          (startup_profile.compiler-startup-profile-mark-cli-compile-action!)
          unit)
        (match config
          [(CompileCliConfig.Config
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
              [state : CompilerDriverState
                (compiler-driver-state-new-for-compile)]
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
    [(CompileCliAction.Batch config) (compile-cli-run-batch config)]
    [(CompileCliAction.Check input-path stdlib-roots)
      (match (compiler-check-file-with-roots input-path stdlib-roots)
        [(ResultCompilerCheck.Ok _)
          (let
            [inline-test-status : i64
              (tltest-inline-typecheck-file-with-cfg
                input-path
                stdlib-roots
                (compiler-check-language-cfgs)
                "typecheck-prefix-inline-compile-check")]
            (if (= inline-test-status 0)
              (let
                [doctest-status : i64
                  (compile-cli-typecheck-doctests input-path stdlib-roots)]
                (if (= doctest-status 0)
                  (begin
                    (io.print-string "Type checking passed!\n")
                    0)
                  doctest-status))
              inline-test-status))]
        [(ResultCompilerCheck.Err diag)
          (begin
            (io.print-error
              (compiler-driver-render-source-diagnostic
                (compiler-diagnostic-list-first (box-get diag))))
            1)])]
    [(CompileCliAction.Help)
      (begin
        (io.print-error (compile-cli-usage))
        0)]
    [(CompileCliAction.Error message)
      (begin
        (io.print-error message)
        1)]))

(define (compile-cli-run [count : i64]) : i64
  (let
    [action : CompileCliAction
      (begin
        (set! compile-cli-allocation-profile-requested false)
        (set! compile-cli-dump-ir-requested false)
        (set! compile-cli-dump-ir-pass "")
        (set! compile-cli-verify-ir-requested false)
        (set! compile-cli-trace-passes-requested false)
        (compiler-debug-info-set-enabled! false)
        (compile-cli-dispatch count))]
    [profile? : bool compile-cli-allocation-profile-requested]
    (begin
      (if profile?
        (begin
          (allocation_profile.compiler-allocation-profile-control! 1 "" "" 0)
          (compiler-driver-allocation-profile-snapshot! "start"))
        unit)
      (let
        [status : i64 (compile-cli-run-action action)]
        (begin
          (if profile?
            (begin
              ;; Diagnostics do not all include a trailing newline. Keep the
              ;; final machine-readable phase on its own line after failures.
              (if (= status 0)
                unit
                (io.print-error "\n"))
              (compiler-driver-allocation-profile-snapshot! "complete")
              (allocation_profile.compiler-allocation-profile-control!
                3
                ""
                ""
                0)
              unit)
            unit)
          status)))))