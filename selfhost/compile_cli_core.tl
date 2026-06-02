;; compile_cli_core.tl - Main-free selfhost compile/tokenize/parse/debug core (#565, #1639).
;;
;; Wraps compiler_driver.tl's input/output API with the selfhost compile CLI:
;; `compile <file.tl> [-o <file>] [--emit-ir] [--target <target>]
;; [--opt-level <0|1|2|3>] [--backend-mode scalar] [--stdlib-root <dir>...]
;; [--cfg <name>...]`,
;; plus `tokenize`/`parse`/`check`/`debug …`.
;; The private bootstrap form `<file.tl> [compile options]` remains accepted so
;; existing stage1->stage2 scripts can call the raw compiler directly.
;; `--backend-mode scalar`, `avx2`, and `avx512` are accepted by the selfhost
;; compiler.
;; `--emit-ir` writes a deterministic TypeLisp-owned IR summary.
;;
;; This is a main-free core (like the other `*_cli_core.tl` modules): the entry
;; `compile-cli-run [count]` dispatches and executes a command, reading `(arg 1)`
;; as the command name. The standalone `compile.tl` driver and the unified
;; `cli.tl` dispatcher both call it; `cli.tl` routes compile/tokenize/parse/debug
;; here so the single binary drives the compiler (#1638).
(import "compiler_check_core.tl")

(import "compiler_driver_core.tl")

(import "frontend_tools_core.tl")

(defenum CompileCliConfig
  (CompileCliConfig
    String
    String
    bool
    bool
    CompilerBackendTarget
    CompilerLoadRootList
    SymI64Env
    CompilerBackendMode
    i64))

(defenum ResultCompileCliConfig
  (OkCompileCliConfig CompileCliConfig)
  (ErrCompileCliConfig String))

(defenum CompileCliAction
  (CompileCliRun CompileCliConfig)
  (CompileCliCheck String CompilerLoadRootList)
  (CompileCliTokenize String)
  (CompileCliParse String)
  (CompileCliHelp)
  (CompileCliError String))

(defenum ResultCompileCliCheckConfig
  (OkCompileCliCheckConfig String CompilerLoadRootList)
  (ErrCompileCliCheckConfig String))

(defenum ResultCompileCliTarget
  (OkCompileCliTarget CompilerBackendTarget)
  (ErrCompileCliTarget String))

(define (compile-cli-cat3 [a : String] [b : String] [c : String]) : String
  (string-append a (string-append b c)))

(define (compile-cli-path-separator? [c : char]) : bool
  (or (= c #/') (= c #\\')))

(define (compile-cli-flag? [value : String]) : bool
  (and (> (string-length value) 0) (= (string-ref value 0) #-')))

(define (compile-cli-usage) : String
  "Usage:\n  typelisp debug tokenize <file.tl>    Show tokens\n  typelisp debug parse <file.tl>       Show AST\n  typelisp debug check <file.tl> [--stdlib-root <dir>...]\n  typelisp tokenize <file.tl>\n  typelisp parse <file.tl>\n  typelisp check <file.tl> [--stdlib-root <dir>...]\n  typelisp compile <file.tl> [-o <file>] [--emit-ir] [--target <target>] [--backend-mode <mode>] [--opt-level <0|1|2|3>] [--stdlib-root <dir>...] [--cfg <name>...]")

(define (compile-cli-message-with-usage [message : String]) : String
  (string-append message (string-append "\n\n" (compile-cli-usage))))

(define (compile-cli-debug-usage) : String
  "Usage:\n    typelisp debug tokenize <file.tl>    Show tokens\n    typelisp debug parse <file.tl>       Show AST\n    typelisp debug check <file.tl> [--stdlib-root <dir>...]")

(define (compile-cli-debug-message-with-usage [message : String]) : String
  (string-append message (string-append "\n\n" (compile-cli-debug-usage))))

(define (compile-cli-default-output-with-extension
  [input-path : String]
  [extension : String]) : String
  (let
    [n : i64 (string-length input-path)]
    [i : i64 0]
    [last-dot : i64 -1]
    [last-sep : i64 -1]
    (begin
      (while (< i n)
        (let
          [c : char (string-ref input-path i)]
          (begin
            (if (= c #.')
              (set! last-dot i)
              (set! last-dot last-dot))
            (if (compile-cli-path-separator? c)
              (set! last-sep i)
              (set! last-sep last-sep))
            (set! i (+ i 1)))))
      (if (> last-dot last-sep)
        (string-append (substring input-path 0 last-dot) extension)
        (string-append input-path extension)))))

(define (compile-cli-default-output [input-path : String]) : String
  (compile-cli-default-output-with-extension input-path ".s"))

(define (compile-cli-default-ir-output [input-path : String]) : String
  (compile-cli-default-output-with-extension input-path ".ir"))

(define (compile-cli-unknown-target [value : String]) : String
  (compile-cli-cat3
    "Error: unknown target '"
    value
    "'. Expected linux-x86_64 or windows-x86_64"))

(define (compile-cli-target [value : String]) : ResultCompileCliTarget
  (if (or (string-eq value "linux-x86_64") (string-eq value "linux_x86_64"))
    (OkCompileCliTarget (BackendTargetLinux))
    (if (or
      (string-eq value "windows-x86_64")
      (string-eq value "windows_x86_64"))
      (OkCompileCliTarget (BackendTargetWindows))
      (ErrCompileCliTarget (compile-cli-unknown-target value)))))

(define (compile-cli-invalid-opt-level [value : String]) : String
  (compile-cli-cat3
    "compile: invalid --opt-level "
    value
    "; expected 0, 1, 2, or 3"))

;; `--backend-mode` parity with Rust (which accepts scalar/avx2/avx512).
(defenum ResultCompileCliBackendMode
  (OkCompileCliBackendMode CompilerBackendMode)
  (ErrCompileCliBackendMode String))

(define (compile-cli-backend-mode [value : String]) : ResultCompileCliBackendMode
  (cond
    [(string-eq value "scalar") (OkCompileCliBackendMode (BackendModeScalar))]
    [(string-eq value "avx2") (OkCompileCliBackendMode (BackendModeAvx2))]
    [(string-eq value "avx512") (OkCompileCliBackendMode (BackendModeAvx512))]
    [else
      (ErrCompileCliBackendMode
        (compile-cli-cat3
          "Error: unknown backend mode '"
          value
          "'. Expected scalar, avx2, or avx512"))]))

(define (compile-cli-root-list-append
  [roots : CompilerLoadRootList]
  [root : String]) : CompilerLoadRootList
  (match roots
    [(CompilerLoadRootNil) (CompilerLoadRootCons root CompilerLoadRootNil)]
    [(CompilerLoadRootCons head rest)
      (CompilerLoadRootCons head (compile-cli-root-list-append rest root))]))

(define (compile-cli-parse-options
  [idx : i64]
  [count : i64]
  [input-path : String]
  [output-path : String]
  [has-output : bool]
  [has-target : bool]
  [target : CompilerBackendTarget]
  [stdlib-roots : CompilerLoadRootList]
  [cfgs : SymI64Env]
  [emit-ir : bool]
  [has-opt-level : bool]
  [opt-level : i64]
  [backend-mode : CompilerBackendMode]) : ResultCompileCliConfig
  (if (>= idx count)
    (OkCompileCliConfig
      (CompileCliConfig
        input-path
        (if (and emit-ir (not has-output))
          (compile-cli-default-ir-output input-path)
          output-path)
        emit-ir
        has-target
        target
        stdlib-roots
        cfgs
        backend-mode
        opt-level))
    (let
      [current : String (arg idx)]
      (cond
        [(string-eq current "-o")
          (if (>= (+ idx 1) count)
            (ErrCompileCliConfig "compile: -o requires a value")
            (if has-output
              (ErrCompileCliConfig "compile: -o was provided more than once")
              (compile-cli-parse-options
                (+ idx 2)
                count
                input-path
                (arg (+ idx 1))
                true
                has-target
                target
                stdlib-roots
                cfgs
                emit-ir
                has-opt-level
                opt-level
                backend-mode)))]
        [(string-eq current "--stdlib-root")
          (if (>= (+ idx 1) count)
            (ErrCompileCliConfig "compile: --stdlib-root requires a value")
            (compile-cli-parse-options
              (+ idx 2)
              count
              input-path
              output-path
              has-output
              has-target
              target
              (compile-cli-root-list-append stdlib-roots (arg (+ idx 1)))
              cfgs
              emit-ir
              has-opt-level
              opt-level
              backend-mode))]
        [(string-eq current "--cfg")
          (if (>= (+ idx 1) count)
            (ErrCompileCliConfig "compile: --cfg requires a value")
            (compile-cli-parse-options
              (+ idx 2)
              count
              input-path
              output-path
              has-output
              has-target
              target
              stdlib-roots
              (compiler-cfg-enable cfgs (arg (+ idx 1)))
              emit-ir
              has-opt-level
              opt-level
              backend-mode))]
        [(string-eq current "--target")
          (if (>= (+ idx 1) count)
            (ErrCompileCliConfig "compile: --target requires a value")
            (if has-target
              (ErrCompileCliConfig
                "compile: --target was provided more than once")
              (match (compile-cli-target (arg (+ idx 1)))
                [(OkCompileCliTarget parsed-target)
                  (compile-cli-parse-options
                    (+ idx 2)
                    count
                    input-path
                    output-path
                    has-output
                    true
                    parsed-target
                    stdlib-roots
                    cfgs
                    emit-ir
                    has-opt-level
                    opt-level
                    backend-mode)]
                [(ErrCompileCliTarget message) (ErrCompileCliConfig message)])))]
        [(string-eq current "--opt-level")
          (if (>= (+ idx 1) count)
            (ErrCompileCliConfig "compile: --opt-level requires a value")
            (if has-opt-level
              (ErrCompileCliConfig
                "compile: --opt-level was provided more than once")
              (let
                [value : String (arg (+ idx 1))]
                (match (compiler-optimize-parse-level value)
                  [(OkCompilerOptimizeLevel parsed-level)
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
                      true
                      parsed-level
                      backend-mode)]
                  [(ErrCompilerOptimizeLevel)
                    (ErrCompileCliConfig (compile-cli-invalid-opt-level value))]))))]
        [(string-eq current "--backend-mode")
          (if (>= (+ idx 1) count)
            (ErrCompileCliConfig "compile: --backend-mode requires a value")
            (match (compile-cli-backend-mode (arg (+ idx 1)))
              [(OkCompileCliBackendMode parsed-mode)
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
                  has-opt-level
                  opt-level
                  parsed-mode)]
              [(ErrCompileCliBackendMode message) (ErrCompileCliConfig message)]))]
        [(string-eq current "--emit-ir")
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
            has-opt-level
            opt-level
            backend-mode)]
        [(compile-cli-flag? current)
          (ErrCompileCliConfig (string-append "compile: unknown flag " current))]
        [else
          (ErrCompileCliConfig
            (string-append "compile: unexpected argument " current))]))))

(define (compile-cli-config-from [input-idx : i64] [count : i64]) : ResultCompileCliConfig
  (if (>= input-idx count)
    (ErrCompileCliConfig "compile: expected source path")
    (let
      [input-path : String (arg input-idx)]
      (if (compile-cli-flag? input-path)
        (ErrCompileCliConfig "compile: expected source path before flags")
        (compile-cli-parse-options
          (+ input-idx 1)
          count
          input-path
          (compile-cli-default-output input-path)
          false
          false
          (BackendTargetLinux)
          CompilerLoadRootNil
          (compiler-cfg-empty)
          false
          false
          (compiler-optimize-default-level)
          (BackendModeScalar))))))

(define (compile-cli-command-config [count : i64]) : ResultCompileCliConfig
  (compile-cli-config-from 2 count))

(define (compile-cli-check-parse-options
  [idx : i64]
  [count : i64]
  [input-path : String]
  [stdlib-roots : CompilerLoadRootList]) : ResultCompileCliCheckConfig
  (if (>= idx count)
    (OkCompileCliCheckConfig input-path stdlib-roots)
    (let
      [current : String (arg idx)]
      (if (string-eq current "--stdlib-root")
        (if (>= (+ idx 1) count)
          (ErrCompileCliCheckConfig "Error: --stdlib-root requires a value")
          (compile-cli-check-parse-options
            (+ idx 2)
            count
            input-path
            (compile-cli-root-list-append stdlib-roots (arg (+ idx 1)))))
        (begin
          (print-error (string-append "Warning: unknown flag: " current))
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
    (ErrCompileCliCheckConfig missing-message)
    (compile-cli-check-parse-options
      (+ input-idx 1)
      count
      (arg input-idx)
      CompilerLoadRootNil)))

(define (compile-cli-top-level-check-config [count : i64]) : ResultCompileCliCheckConfig
  (compile-cli-check-config-from
    2
    count
    (compile-cli-message-with-usage "Error: missing file argument")))

(define (compile-cli-debug-check-config [count : i64]) : ResultCompileCliCheckConfig
  (compile-cli-check-config-from
    3
    count
    (compile-cli-debug-message-with-usage "Error: missing file argument")))

(define (compile-cli-top-level-path-action [command : String] [count : i64]) : CompileCliAction
  (if (< count 3)
    (CompileCliError
      (compile-cli-message-with-usage "Error: missing file argument"))
    (if (string-eq command "tokenize")
      (CompileCliTokenize (arg 2))
      (CompileCliParse (arg 2)))))

(define (compile-cli-debug-path-action [command : String] [count : i64]) : CompileCliAction
  (if (< count 4)
    (CompileCliError
      (compile-cli-debug-message-with-usage "Error: missing file argument"))
    (if (string-eq command "tokenize")
      (CompileCliTokenize (arg 3))
      (CompileCliParse (arg 3)))))

(define (compile-cli-debug-dispatch [count : i64]) : CompileCliAction
  (if (< count 3)
    (CompileCliError
      (compile-cli-debug-message-with-usage "Error: missing debug subcommand"))
    (let
      [command : String (arg 2)]
      (cond
        [(string-eq command "tokenize")
          (compile-cli-debug-path-action command count)]
        [(string-eq command "parse")
          (compile-cli-debug-path-action command count)]
        [(string-eq command "check")
          (match (compile-cli-debug-check-config count)
            [(OkCompileCliCheckConfig input-path roots)
              (CompileCliCheck input-path roots)]
            [(ErrCompileCliCheckConfig message) (CompileCliError message)])]
        [(or
            (string-eq command "help")
            (or (string-eq command "--help") (string-eq command "-h")))
          (CompileCliError (compile-cli-debug-usage))]
        [else
          (CompileCliError
            (compile-cli-debug-message-with-usage
              (string-append "Unknown debug command: " command)))]))))

(define (compile-cli-dispatch [count : i64]) : CompileCliAction
  (if (< count 2)
    (CompileCliError
      (compile-cli-message-with-usage "typelisp: expected command"))
    (let
      [command : String (arg 1)]
      (cond
        [(or
            (string-eq command "help")
            (or (string-eq command "--help") (string-eq command "-h")))
          (CompileCliHelp)]
        [(string-eq command "compile")
          (match (compile-cli-command-config count)
            [(OkCompileCliConfig config) (CompileCliRun config)]
            [(ErrCompileCliConfig message) (CompileCliError message)])]
        [(or (string-eq command "tokenize") (string-eq command "parse"))
          (compile-cli-top-level-path-action command count)]
        [(string-eq command "check")
          (match (compile-cli-top-level-check-config count)
            [(OkCompileCliCheckConfig input-path roots)
              (CompileCliCheck input-path roots)]
            [(ErrCompileCliCheckConfig message) (CompileCliError message)])]
        [(string-eq command "debug") (compile-cli-debug-dispatch count)]
        [else
          (CompileCliError
            (compile-cli-message-with-usage
              (string-append "Unknown command: " command)))]))))

(define (compile-cli-run [count : i64]) : i64
  (match (compile-cli-dispatch count)
    [(CompileCliRun config)
      (match config
        [(CompileCliConfig
            input-path
            output-path
            emit-ir
            has-target
            target
            stdlib-roots
            cfgs
            backend-mode
            opt-level)
          (if emit-ir
            (compiler-driver-write-result
              (compiler-driver-emit-ir-summary-file-with-roots-level-and-cfg
                input-path
                stdlib-roots
                opt-level
                cfgs)
              output-path)
            (if has-target
              (compiler-driver-compile-file-for-target-with-roots-level-mode-and-cfg
                input-path
                output-path
                target
                stdlib-roots
                opt-level
                backend-mode
                cfgs)
              (compiler-driver-compile-file-with-roots-level-mode-and-cfg
                input-path
                output-path
                stdlib-roots
                opt-level
                backend-mode
                cfgs)))])]
    [(CompileCliCheck input-path stdlib-roots)
      (match (compiler-check-file-with-roots input-path stdlib-roots)
        [(OkCompilerCheck _)
          (begin
            (print-string "Type checking passed!\n")
            0)]
        [(ErrCompilerCheck diag)
          (begin
            (print-error (compiler-diagnostic-render diag))
            1)])]
    [(CompileCliTokenize input-path) (front-tokenize-file input-path)]
    [(CompileCliParse input-path) (front-parse-file input-path)]
    [(CompileCliHelp)
      (begin
        (print-error (compile-cli-usage))
        0)]
    [(CompileCliError message)
      (begin
        (print-error message)
        1)]))
