;; compile_cli_core.tl - Main-free selfhost compile/check core (#565, #1639).
;;
;; Wraps compiler_driver_core.tl's input/output API with the selfhost compile CLI:
;; `compile <file.tl> [-o <file>] [--emit-ir] [--pic] [--target <target>]
;; [--opt-level <0|1|2>] [--backend-mode scalar] [--stdlib-root <dir>...]
;; [--cfg <name>...]`,
;; plus `check <file.tl> [--stdlib-root <dir>...]`.
;; Bootstrap scripts call the retained `compile.tl` driver with the same
;; `compile` subcommand shape used by the unified CLI.
;; `--backend-mode scalar`, `avx2`, and `avx512` are accepted by the selfhost
;; compiler.
;; `--emit-ir` writes a deterministic TypeLisp-owned IR summary.
;; `--pic` writes runtime-free, no-entry PIC assembly plus `<output>.fixups`.
;;
;; This is a main-free core (like the other `*_cli_core.tl` modules): the entry
;; `compile-cli-run [count]` dispatches and executes a command, reading `(io.arg 1)`
;; as the command name. The retained bootstrap `compile.tl` driver and the
;; unified `cli.tl` dispatcher both call it, so the single binary drives the
;; compiler (#1638).
(import stdlib.io)
(import stdlib.vector)
(import "compiler_check_core.tl")
(import "compiler_driver_core.tl")
(import "doc_test.tl")
(import "test_cli_core.tl")
(import stdlib.string)
(import stdlib.str_cat)
(import sym_i64_env)

;; Pair-shaped batch entries stay as a list until aggregate-element vector
;; support makes a generated entry vector cleaner than parallel StringVecs.
(defenum CompileCliBatchEntryList
  (Nil)
  (Cons String String (Box CompileCliBatchEntryList)))

(defenum ResultCompileCliBatchEntryList
  (Ok CompileCliBatchEntryList)
  (Err i64))

(define (compile-cli-batch-entry-cons
  [input-path : String]
  [output-path : String]
  [rest : CompileCliBatchEntryList]) : CompileCliBatchEntryList
  (CompileCliBatchEntryList.Cons input-path output-path (box rest)))

(defenum CompileCliConfig
  (Config
    String
    String
    bool
    bool
    bool
    CompilerBackendTarget
    vector.StringVec
    vector.StringVec
    CompilerBackendMode
    i64))

(defenum CompileCliBatchConfig
  (Config
    String
    bool
    CompilerBackendTarget
    vector.StringVec
    vector.StringVec
    CompilerBackendMode
    i64
    bool))

(defenum ResultCompileCliConfig
  (Ok CompileCliConfig)
  (Err String))

(defenum ResultCompileCliBatchConfig
  (Ok CompileCliBatchConfig)
  (Err String))

(defenum CompileCliAction
  (Run CompileCliConfig)
  (Batch CompileCliBatchConfig)
  (Check String vector.StringVec)
  (Help)
  (Error String))

(defenum ResultCompileCliCheckConfig
  (Ok String vector.StringVec)
  (Err String))

(defenum ResultCompileCliTarget
  (Ok CompilerBackendTarget)
  (Err String))

(define (compile-cli-path-separator? [c : char]) : bool
  (or (= c '/') (= c '\\')))

(define (compile-cli-flag? [value : String]) : bool
  (and (> (string.string-length value) 0) (= (string.string-ref value 0) '-')))

(define (compile-cli-usage) : String
  "Usage:\n  typelisp check <file.tl> [--stdlib-root <dir>...]\n  typelisp compile <file.tl> [-o <file>] [--emit-ir] [--pic] [--target <target>] [--backend-mode <mode>] [--opt-level <0|1|2>] [--stdlib-root <dir>...] [--cfg <name>...]\n  typelisp compile --batch <input-output-list> [--target <target>] [--backend-mode <mode>] [--opt-level <0|1|2>] [--stdlib-root <dir>...] [--cfg <name>...] [--prefix-cache-stats]")

(define (compile-cli-message-with-usage [message : String]) : String
  (string.string-append
    message
    (string.string-append "\n\n" (compile-cli-usage))))

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
        (string.string-append
          (string.substring input-path 0 last-dot)
          extension)
        (string.string-append input-path extension)))))

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
  (if (or
    (string.string-eq value "linux-x86_64")
    (string.string-eq value "linux_x86_64"))
    (ResultCompileCliTarget.Ok (CompilerBackendTarget.Linux))
    (if (or
      (string.string-eq value "windows-x86_64")
      (string.string-eq value "windows_x86_64"))
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
    [(string.string-eq value "scalar")
      (ResultCompileCliBackendMode.Ok (CompilerBackendMode.Scalar))]
    [(string.string-eq value "avx2")
      (ResultCompileCliBackendMode.Ok (CompilerBackendMode.Avx2))]
    [(string.string-eq value "avx512")
      (ResultCompileCliBackendMode.Ok (CompilerBackendMode.Avx512))]
    [else
      (ResultCompileCliBackendMode.Err
        (str_cat.str-cat
          "Error: unknown backend mode '"
          value
          "'. Expected scalar, avx2, or avx512"))]))

(define (compile-cli-parse-options
  [idx : i64]
  [count : i64]
  [input-path : String]
  [output-path : String]
  [has-output : bool]
  [has-target : bool]
  [target : CompilerBackendTarget]
  [stdlib-roots : vector.StringVec]
  [cfg-names : vector.StringVec]
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
          cfg-names
          backend-mode
          opt-level)))
    (let
      [current : String (io.arg idx)]
      (cond
        [(string.string-eq current "-o")
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
                cfg-names
                emit-ir
                pic
                has-opt-level
                opt-level
                backend-mode)))]
        [(string.string-eq current "--stdlib-root")
          (if (>= (+ idx 1) count)
            (ResultCompileCliConfig.Err
              "compile: --stdlib-root requires a value")
            (compile-cli-parse-options
              (+ idx 2)
              count
              input-path
              output-path
              has-output
              has-target
              target
              (vector.string-vec-push stdlib-roots (io.arg (+ idx 1)))
              cfg-names
              emit-ir
              pic
              has-opt-level
              opt-level
              backend-mode))]
        [(string.string-eq current "--cfg")
          (if (>= (+ idx 1) count)
            (ResultCompileCliConfig.Err "compile: --cfg requires a value")
            (compile-cli-parse-options
              (+ idx 2)
              count
              input-path
              output-path
              has-output
              has-target
              target
              stdlib-roots
              (vector.string-vec-push cfg-names (io.arg (+ idx 1)))
              emit-ir
              pic
              has-opt-level
              opt-level
              backend-mode))]
        [(string.string-eq current "--target")
          (if (>= (+ idx 1) count)
            (ResultCompileCliConfig.Err "compile: --target requires a value")
            (if has-target
              (ResultCompileCliConfig.Err
                "compile: --target was provided more than once")
              (match (compile-cli-target (io.arg (+ idx 1)))
                [(ResultCompileCliTarget.Ok parsed-target)
                  (compile-cli-parse-options
                    (+ idx 2)
                    count
                    input-path
                    output-path
                    has-output
                    true
                    parsed-target
                    stdlib-roots
                    cfg-names
                    emit-ir
                    pic
                    has-opt-level
                    opt-level
                    backend-mode)]
                [(ResultCompileCliTarget.Err message)
                  (ResultCompileCliConfig.Err message)])))]
        [(string.string-eq current "--opt-level")
          (if (>= (+ idx 1) count)
            (ResultCompileCliConfig.Err "compile: --opt-level requires a value")
            (if has-opt-level
              (ResultCompileCliConfig.Err
                "compile: --opt-level was provided more than once")
              (let
                [value : String (io.arg (+ idx 1))]
                (match (compiler-optimize-parse-level value)
                  [(ResultCompilerOptimizeLevel.Ok parsed-level)
                    (compile-cli-parse-options
                      (+ idx 2)
                      count
                      input-path
                      output-path
                      has-output
                      has-target
                      target
                      stdlib-roots
                      cfg-names
                      emit-ir
                      pic
                      true
                      parsed-level
                      backend-mode)]
                  [(ResultCompilerOptimizeLevel.Err)
                    (ResultCompileCliConfig.Err
                      (compile-cli-invalid-opt-level value))]))))]
        [(string.string-eq current "--backend-mode")
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
                  cfg-names
                  emit-ir
                  pic
                  has-opt-level
                  opt-level
                  parsed-mode)]
              [(ResultCompileCliBackendMode.Err message)
                (ResultCompileCliConfig.Err message)]))]
        [(string.string-eq current "--pic")
          (compile-cli-parse-options
            (+ idx 1)
            count
            input-path
            output-path
            has-output
            has-target
            target
            stdlib-roots
            cfg-names
            emit-ir
            true
            has-opt-level
            opt-level
            backend-mode)]
        [(string.string-eq current "--emit-ir")
          (compile-cli-parse-options
            (+ idx 1)
            count
            input-path
            output-path
            has-output
            has-target
            target
            stdlib-roots
            cfg-names
            true
            pic
            has-opt-level
            opt-level
            backend-mode)]
        [else
          (if (compile-cli-flag? current)
            (ResultCompileCliConfig.Err
              (string.string-append "compile: unknown flag " current))
            (ResultCompileCliConfig.Err
              (string.string-append "compile: unexpected argument " current)))]))))

(define (compile-cli-batch-parse-options
  [idx : i64]
  [count : i64]
  [batch-path : String]
  [has-target : bool]
  [target : CompilerBackendTarget]
  [stdlib-roots : vector.StringVec]
  [cfg-names : vector.StringVec]
  [has-opt-level : bool]
  [opt-level : i64]
  [backend-mode : CompilerBackendMode]
  [prefix-cache-stats : bool]) : ResultCompileCliBatchConfig
  (if (>= idx count)
    (ResultCompileCliBatchConfig.Ok
      (CompileCliBatchConfig.Config
        batch-path
        has-target
        target
        stdlib-roots
        cfg-names
        backend-mode
        opt-level
        prefix-cache-stats))
    (let
      [current : String (io.arg idx)]
      (cond
        [(string.string-eq current "-o")
          (ResultCompileCliBatchConfig.Err
            "compile: --batch reads output paths from the batch file")]
        [(string.string-eq current "--emit-ir")
          (ResultCompileCliBatchConfig.Err
            "compile: --batch does not support --emit-ir")]
        [(string.string-eq current "--pic")
          (ResultCompileCliBatchConfig.Err
            "compile: --batch does not support --pic")]
        [(string.string-eq current "--stdlib-root")
          (if (>= (+ idx 1) count)
            (ResultCompileCliBatchConfig.Err
              "compile: --stdlib-root requires a value")
            (compile-cli-batch-parse-options
              (+ idx 2)
              count
              batch-path
              has-target
              target
              (vector.string-vec-push stdlib-roots (io.arg (+ idx 1)))
              cfg-names
              has-opt-level
              opt-level
              backend-mode
              prefix-cache-stats))]
        [(string.string-eq current "--cfg")
          (if (>= (+ idx 1) count)
            (ResultCompileCliBatchConfig.Err "compile: --cfg requires a value")
            (compile-cli-batch-parse-options
              (+ idx 2)
              count
              batch-path
              has-target
              target
              stdlib-roots
              (vector.string-vec-push cfg-names (io.arg (+ idx 1)))
              has-opt-level
              opt-level
              backend-mode
              prefix-cache-stats))]
        [(string.string-eq current "--target")
          (if (>= (+ idx 1) count)
            (ResultCompileCliBatchConfig.Err
              "compile: --target requires a value")
            (if has-target
              (ResultCompileCliBatchConfig.Err
                "compile: --target was provided more than once")
              (match (compile-cli-target (io.arg (+ idx 1)))
                [(ResultCompileCliTarget.Ok parsed-target)
                  (compile-cli-batch-parse-options
                    (+ idx 2)
                    count
                    batch-path
                    true
                    parsed-target
                    stdlib-roots
                    cfg-names
                    has-opt-level
                    opt-level
                    backend-mode
                    prefix-cache-stats)]
                [(ResultCompileCliTarget.Err message)
                  (ResultCompileCliBatchConfig.Err message)])))]
        [(string.string-eq current "--opt-level")
          (if (>= (+ idx 1) count)
            (ResultCompileCliBatchConfig.Err
              "compile: --opt-level requires a value")
            (if has-opt-level
              (ResultCompileCliBatchConfig.Err
                "compile: --opt-level was provided more than once")
              (let
                [value : String (io.arg (+ idx 1))]
                (match (compiler-optimize-parse-level value)
                  [(ResultCompilerOptimizeLevel.Ok parsed-level)
                    (compile-cli-batch-parse-options
                      (+ idx 2)
                      count
                      batch-path
                      has-target
                      target
                      stdlib-roots
                      cfg-names
                      true
                      parsed-level
                      backend-mode
                      prefix-cache-stats)]
                  [(ResultCompilerOptimizeLevel.Err)
                    (ResultCompileCliBatchConfig.Err
                      (compile-cli-invalid-opt-level value))]))))]
        [(string.string-eq current "--backend-mode")
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
                  cfg-names
                  has-opt-level
                  opt-level
                  parsed-mode
                  prefix-cache-stats)]
              [(ResultCompileCliBackendMode.Err message)
                (ResultCompileCliBatchConfig.Err message)]))]
        [(string.string-eq current "--prefix-cache-stats")
          (compile-cli-batch-parse-options
            (+ idx 1)
            count
            batch-path
            has-target
            target
            stdlib-roots
            cfg-names
            has-opt-level
            opt-level
            backend-mode
            true)]
        [else
          (if (compile-cli-flag? current)
            (ResultCompileCliBatchConfig.Err
              (string.string-append "compile: unknown flag " current))
            (ResultCompileCliBatchConfig.Err
              (string.string-append "compile: unexpected argument " current)))]))))

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
          (vector.string-vec-new)
          (vector.string-vec-new)
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
          (vector.string-vec-new)
          (vector.string-vec-new)
          false
          (compiler-optimize-default-level)
          (CompilerBackendMode.Scalar)
          false)))))

(define (compile-cli-command-action [count : i64]) : CompileCliAction
  (if (and (> count 2) (string.string-eq (io.arg 2) "--batch"))
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
  [stdlib-roots : vector.StringVec]) : ResultCompileCliCheckConfig
  (if (>= idx count)
    (ResultCompileCliCheckConfig.Ok input-path stdlib-roots)
    (let
      [current : String (io.arg idx)]
      (if (string.string-eq current "--stdlib-root")
        (if (>= (+ idx 1) count)
          (ResultCompileCliCheckConfig.Err
            "Error: --stdlib-root requires a value")
          (compile-cli-check-parse-options
            (+ idx 2)
            count
            input-path
            (vector.string-vec-push stdlib-roots (io.arg (+ idx 1)))))
        (begin
          (io.print-error
            (string.string-append "Warning: unknown flag: " current))
          (compile-cli-check-parse-options
            (+ idx 1)
            count
            input-path
            stdlib-roots))))))

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
      (vector.string-vec-new))))

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
            (string.string-eq command "help")
            (string.string-eq command "--help")
            (string.string-eq command "-h"))
          (CompileCliAction.Help)]
        [(string.string-eq command "compile")
          (compile-cli-command-action count)]
        [(string.string-eq command "check")
          (match (compile-cli-top-level-check-config count)
            [(ResultCompileCliCheckConfig.Ok input-path roots)
              (CompileCliAction.Check input-path roots)]
            [(ResultCompileCliCheckConfig.Err message)
              (CompileCliAction.Error message)])]
        [else
          (CompileCliAction.Error
            (compile-cli-message-with-usage
              (string.string-append "Unknown command: " command)))]))))

(define (compile-cli-cfg-names-to-env-from
  [cfg-names : vector.StringVec]
  [index : i64]
  [env : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (if (>= index (vector.string-vec-len cfg-names))
    env
    (compile-cli-cfg-names-to-env-from
      cfg-names
      (+ index 1)
      (compiler-cfg-enable env (vector.string-vec-get cfg-names index "")))))

(define (compile-cli-cfg-names-to-env [cfg-names : vector.StringVec]) : sym_i64_env.SymI64Env
  (compile-cli-cfg-names-to-env-from cfg-names 0 (compiler-cfg-empty)))

(define (compile-cli-typecheck-doctests
  [input-path : String]
  [stdlib-roots : vector.StringVec]) : i64
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

(define (compile-cli-run-compile-file
  [state : CompilerDriverState]
  [input-path : String]
  [output-path : String]
  [emit-ir : bool]
  [pic : bool]
  ;; lint-allow: unused-variable
  [has-target : bool]
  [target : CompilerBackendTarget]
  [stdlib-roots : vector.StringVec]
  [cfg-names : vector.StringVec]
  [backend-mode : CompilerBackendMode]
  [opt-level : i64]
  [inline-preflight : bool]) : i64
  (let
    [doctest-status : i64
      (compile-cli-typecheck-doctests input-path stdlib-roots)]
    (if (= doctest-status 0)
      (let
        [inline-test-status : i64
          (if inline-preflight
            (let
              [preflight-cfgs : sym_i64_env.SymI64Env
                (compile-cli-cfg-names-to-env cfg-names)]
              (tltest-inline-typecheck-file-with-cfg
                input-path
                stdlib-roots
                (compiler-driver-target-cfgs target preflight-cfgs)
                "typecheck-prefix-inline-compile"))
            0)]
        (if (= inline-test-status 0)
          (begin
            (compiler-driver-state-reset-file-state! state)
            (let
              [cfgs : sym_i64_env.SymI64Env
                (compile-cli-cfg-names-to-env cfg-names)]
              [status : i64
                (if emit-ir
                  (compiler-driver-write-result
                    (compiler-driver-state-emit-ir-summary-file-with-target-roots-level-mode-and-cfg
                      state
                      input-path
                      target
                      stdlib-roots
                      opt-level
                      backend-mode
                      cfgs)
                    output-path)
                  (if pic
                    (compiler-driver-write-pic-result
                      (compiler-driver-state-emit-file-pic-with-target-roots-level-mode-and-cfg
                        state
                        input-path
                        target
                        true
                        stdlib-roots
                        opt-level
                        backend-mode
                        cfgs)
                      output-path)
                    (compiler-driver-write-buffer-result
                      (compiler-driver-state-emit-file-buffer-with-target-roots-level-mode-and-cfg
                        state
                        input-path
                        target
                        true
                        stdlib-roots
                        opt-level
                        backend-mode
                        cfgs)
                      output-path)))]
              (begin
                (compiler-driver-state-capture-session-floors! state)
                status)))
          inline-test-status))
      doctest-status)))

(define (compile-cli-run-batch-inline-tests
  [entries : CompileCliBatchEntryList]
  [target : CompilerBackendTarget]
  [stdlib-roots : vector.StringVec]
  [cfg-names : vector.StringVec]) : i64
  (match entries
    [(CompileCliBatchEntryList.Nil) 0]
    [(CompileCliBatchEntryList.Cons input-path _ rest)
      (let
        [cfgs : sym_i64_env.SymI64Env (compile-cli-cfg-names-to-env cfg-names)]
        [status : i64
          (tltest-inline-typecheck-file-with-cfg
            input-path
            stdlib-roots
            (compiler-driver-target-cfgs target cfgs)
            "typecheck-prefix-inline-compile-batch")]
        (if (= status 0)
          (compile-cli-run-batch-inline-tests
            (box-get rest)
            target
            stdlib-roots
            cfg-names)
          (begin
            (io.print-error
              (str_cat.str-cat
                "\ncompile: batch source failed: "
                input-path
                "\n"))
            status)))]))

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

(define (compile-cli-batch-parse-entries-from
  [text : String]
  [start : i64]
  [line : i64]
  [n : i64]) : ResultCompileCliBatchEntryList
  (if (>= start n)
    (ResultCompileCliBatchEntryList.Ok CompileCliBatchEntryList.Nil)
    (let
      [line-end : i64 (compile-cli-batch-line-end text start n)]
      [next-start : i64 (compile-cli-batch-next-line text line-end n)]
      (if (= start line-end)
        (compile-cli-batch-parse-entries-from text next-start (+ line 1) n)
        (let
          [sep : i64 (compile-cli-batch-find-separator text start line-end)]
          (if (< sep 0)
            (ResultCompileCliBatchEntryList.Err
              (compile-cli-batch-line-error line "expected input|output"))
            (let
              [output-start : i64 (+ sep 1)]
              (if (= start sep)
                (ResultCompileCliBatchEntryList.Err
                  (compile-cli-batch-line-error line "missing input path"))
                (if (= output-start line-end)
                  (ResultCompileCliBatchEntryList.Err
                    (compile-cli-batch-line-error line "missing output path"))
                  (let
                    [input-path : String
                      (string.substring text start (- sep start))]
                    [output-path : String
                      (string.substring
                        text
                        output-start
                        (- line-end output-start))]
                    (match (compile-cli-batch-parse-entries-from
                      text
                      next-start
                      (+ line 1)
                      n)
                      [(ResultCompileCliBatchEntryList.Ok rest)
                        (ResultCompileCliBatchEntryList.Ok
                          (compile-cli-batch-entry-cons
                            input-path
                            output-path
                            rest))]
                      [(ResultCompileCliBatchEntryList.Err status)
                        (ResultCompileCliBatchEntryList.Err status)])))))))))))

(define (compile-cli-run-batch-entries
  [state : CompilerDriverState]
  [entries : CompileCliBatchEntryList]
  [has-target : bool]
  [target : CompilerBackendTarget]
  [stdlib-roots : vector.StringVec]
  [cfg-names : vector.StringVec]
  [backend-mode : CompilerBackendMode]
  [opt-level : i64]) : i64
  (match entries
    [(CompileCliBatchEntryList.Nil) 0]
    [(CompileCliBatchEntryList.Cons input-path output-path rest)
      (let
        ;; Each batch entry gets a destroyable scratch arena, not just a
        ;; lexical rewind region. Rewinds intentionally retain overflow chunks
        ;; until the owning arena is destroyed (#2441), so long batches must
        ;; destroy the entry arena to avoid inter-entry growth.
        [status : i64
          (with-scratch
            (compile-cli-run-compile-file
              state
              input-path
              output-path
              false
              false
              has-target
              target
              stdlib-roots
              cfg-names
              backend-mode
              opt-level
              false))]
        (if (= status 0)
          (compile-cli-run-batch-entries
            state
            (box-get rest)
            has-target
            target
            stdlib-roots
            cfg-names
            backend-mode
            opt-level)
          (begin
            (io.print-error
              (str_cat.str-cat
                "\ncompile: batch source failed: "
                input-path
                "\n"))
            status)))]))

(define (compile-cli-run-batch-from
  [state : CompilerDriverState]
  [text : String]
  [start : i64]
  [line : i64]
  [has-target : bool]
  [target : CompilerBackendTarget]
  [stdlib-roots : vector.StringVec]
  [cfg-names : vector.StringVec]
  [backend-mode : CompilerBackendMode]
  [opt-level : i64]) : i64
  (match (compile-cli-batch-parse-entries-from
    text
    start
    line
    (string.string-length text))
    [(ResultCompileCliBatchEntryList.Ok entries)
      (let
        [inline-test-status : i64
          (compile-cli-run-batch-inline-tests
            entries
            target
            stdlib-roots
            cfg-names)]
        (if (= inline-test-status 0)
          (compile-cli-run-batch-entries
            state
            entries
            has-target
            target
            stdlib-roots
            cfg-names
            backend-mode
            opt-level)
          inline-test-status))]
    [(ResultCompileCliBatchEntryList.Err status) status]))

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
          cfg-names
          backend-mode
          opt-level
          prefix-cache-stats)
        (let
          [status : i64
            (begin
              (tc-prefix-snapshot-cache-enable!)
              (tc-prefix-snapshot-cache-clear!)
              (compile-cli-run-batch-from
                state
                (io.read-file batch-path)
                0
                1
                has-target
                target
                stdlib-roots
                cfg-names
                backend-mode
                opt-level))]
          (begin
            (if prefix-cache-stats
              (tc-prefix-snapshot-cache-print-stats "compile-batch")
              unit)
            (tc-prefix-snapshot-cache-clear!)
            (tc-prefix-snapshot-cache-disable!)
            status))])))

(define (compile-cli-run [count : i64]) : i64
  (match (compile-cli-dispatch count)
    [(CompileCliAction.Run config)
      (match config
        [(CompileCliConfig.Config
            input-path
            output-path
            emit-ir
            pic
            has-target
            target
            stdlib-roots
            cfg-names
            backend-mode
            opt-level)
          (compile-cli-run-compile-file
            (compiler-driver-state-new-for-compile)
            input-path
            output-path
            emit-ir
            pic
            has-target
            target
            stdlib-roots
            cfg-names
            backend-mode
            opt-level
            true)])]
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
            (io.print-error (compiler-diagnostic-render (box-get diag)))
            1)])]
    [(CompileCliAction.Help)
      (begin
        (io.print-error (compile-cli-usage))
        0)]
    [(CompileCliAction.Error message)
      (begin
        (io.print-error message)
        1)]))