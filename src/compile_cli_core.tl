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
;;
;; This is a main-free core (like the other `*_cli_core.tl` modules): the entry
;; `compile-cli-run [count]` dispatches and executes a command, reading `(arg 1)`
;; as the command name. The retained bootstrap `compile.tl` driver and the
;; unified `cli.tl` dispatcher both call it, so the single binary drives the
;; compiler (#1638).
(import "../stdlib/io.tl")

(import "../stdlib/arena.tl")

(import "compiler_check_core.tl")

(import "compiler_driver_core.tl")

(import "doc_test.tl")

(import "../stdlib/string.tl")

(import "../stdlib/str_cat.tl")

;; Pair-shaped batch entries stay as a list until aggregate-element vector
;; support makes a generated entry vector cleaner than parallel StringVecs.
(defenum CompileCliBatchEntryList
  (CompileCliBatchEntryNil)
  (CompileCliBatchEntryCons String String (Box CompileCliBatchEntryList)))

(defenum ResultCompileCliBatchEntryList
  (OkCompileCliBatchEntryList CompileCliBatchEntryList)
  (ErrCompileCliBatchEntryList i64))

(define (compile-cli-batch-entry-cons
  [input-path : String]
  [output-path : String]
  [rest : CompileCliBatchEntryList]) : CompileCliBatchEntryList
  (CompileCliBatchEntryCons input-path output-path (box rest)))

(defenum CompileCliConfig
  (CompileCliConfig
    String
    String
    bool
    bool
    bool
    CompilerBackendTarget
    StringVec
    StringVec
    CompilerBackendMode
    i64))

(defenum CompileCliBatchConfig
  (CompileCliBatchConfig
    String
    bool
    CompilerBackendTarget
    StringVec
    StringVec
    CompilerBackendMode
    i64))

(defenum ResultCompileCliConfig
  (OkCompileCliConfig CompileCliConfig)
  (ErrCompileCliConfig String))

(defenum ResultCompileCliBatchConfig
  (OkCompileCliBatchConfig CompileCliBatchConfig)
  (ErrCompileCliBatchConfig String))

(defenum CompileCliAction
  (CompileCliRun CompileCliConfig)
  (CompileCliBatch CompileCliBatchConfig)
  (CompileCliCheck String StringVec)
  (CompileCliHelp)
  (CompileCliError String))

(defenum ResultCompileCliCheckConfig
  (OkCompileCliCheckConfig String StringVec)
  (ErrCompileCliCheckConfig String))

(defenum ResultCompileCliTarget
  (OkCompileCliTarget CompilerBackendTarget)
  (ErrCompileCliTarget String))

(define (compile-cli-path-separator? [c : char]) : bool
  (or (= c #/') (= c #\\')))

(define (compile-cli-flag? [value : String]) : bool
  (and (> (string-length value) 0) (= (string-ref value 0) #-')))

(define (compile-cli-usage) : String
  "Usage:\n  typelisp check <file.tl> [--stdlib-root <dir>...]\n  typelisp compile <file.tl> [-o <file>] [--emit-ir] [--pic] [--target <target>] [--backend-mode <mode>] [--opt-level <0|1|2>] [--stdlib-root <dir>...] [--cfg <name>...]\n  typelisp compile --batch <input-output-list> [--target <target>] [--backend-mode <mode>] [--opt-level <0|1|2>] [--stdlib-root <dir>...] [--cfg <name>...]")

(define (compile-cli-message-with-usage [message : String]) : String
  (string-append message (string-append "\n\n" (compile-cli-usage))))

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
  (str-cat
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
  (str-cat "compile: invalid --opt-level " value "; expected 0, 1, or 2"))

;; `--backend-mode` parity with Rust (which accepts scalar/avx2/avx512).
(defenum ResultCompileCliBackendMode
  (OkCompileCliBackendMode CompilerBackendMode)
  (ErrCompileCliBackendMode String))

(define (compile-cli-backend-mode [value : String]) : ResultCompileCliBackendMode
  (cond
    (string-eq value "scalar")
    (OkCompileCliBackendMode (BackendModeScalar))
    (string-eq value "avx2")
    (OkCompileCliBackendMode (BackendModeAvx2))
    (string-eq value "avx512")
    (OkCompileCliBackendMode (BackendModeAvx512))
    (ErrCompileCliBackendMode
      (str-cat
        "Error: unknown backend mode '"
        value
        "'. Expected scalar, avx2, or avx512"))))

(define (compile-cli-parse-options
  [idx : i64]
  [count : i64]
  [input-path : String]
  [output-path : String]
  [has-output : bool]
  [has-target : bool]
  [target : CompilerBackendTarget]
  [stdlib-roots : StringVec]
  [cfg-names : StringVec]
  [emit-ir : bool]
  [pic : bool]
  [has-opt-level : bool]
  [opt-level : i64]
  [backend-mode : CompilerBackendMode]) : ResultCompileCliConfig
  (if (>= idx count)
    (if (and emit-ir pic)
      (ErrCompileCliConfig "compile: --pic cannot be combined with --emit-ir")
      (OkCompileCliConfig
        (CompileCliConfig
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
      [current : String (arg idx)]
      (cond
        (string-eq current "-o")
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
              cfg-names
              emit-ir
              pic
              has-opt-level
              opt-level
              backend-mode)))
        (string-eq current "--stdlib-root")
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
            (string-vec-push stdlib-roots (arg (+ idx 1)))
            cfg-names
            emit-ir
            pic
            has-opt-level
            opt-level
            backend-mode))
        (string-eq current "--cfg")
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
            (string-vec-push cfg-names (arg (+ idx 1)))
            emit-ir
            pic
            has-opt-level
            opt-level
            backend-mode))
        (string-eq current "--target")
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
                  cfg-names
                  emit-ir
                  pic
                  has-opt-level
                  opt-level
                  backend-mode)]
              [(ErrCompileCliTarget message) (ErrCompileCliConfig message)])))
        (string-eq current "--opt-level")
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
                    cfg-names
                    emit-ir
                    pic
                    true
                    parsed-level
                    backend-mode)]
                [(ErrCompilerOptimizeLevel)
                  (ErrCompileCliConfig (compile-cli-invalid-opt-level value))]))))
        (string-eq current "--backend-mode")
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
                cfg-names
                emit-ir
                pic
                has-opt-level
                opt-level
                parsed-mode)]
            [(ErrCompileCliBackendMode message) (ErrCompileCliConfig message)]))
        (string-eq current "--pic")
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
          backend-mode)
        (string-eq current "--emit-ir")
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
          backend-mode)
        (compile-cli-flag? current)
        (ErrCompileCliConfig (string-append "compile: unknown flag " current))
        (ErrCompileCliConfig
          (string-append "compile: unexpected argument " current))))))

(define (compile-cli-batch-parse-options
  [idx : i64]
  [count : i64]
  [batch-path : String]
  [has-target : bool]
  [target : CompilerBackendTarget]
  [stdlib-roots : StringVec]
  [cfg-names : StringVec]
  [has-opt-level : bool]
  [opt-level : i64]
  [backend-mode : CompilerBackendMode]) : ResultCompileCliBatchConfig
  (if (>= idx count)
    (OkCompileCliBatchConfig
      (CompileCliBatchConfig
        batch-path
        has-target
        target
        stdlib-roots
        cfg-names
        backend-mode
        opt-level))
    (let
      [current : String (arg idx)]
      (cond
        (string-eq current "-o")
        (ErrCompileCliBatchConfig
          "compile: --batch reads output paths from the batch file")
        (string-eq current "--emit-ir")
        (ErrCompileCliBatchConfig "compile: --batch does not support --emit-ir")
        (string-eq current "--pic")
        (ErrCompileCliBatchConfig "compile: --batch does not support --pic")
        (string-eq current "--stdlib-root")
        (if (>= (+ idx 1) count)
          (ErrCompileCliBatchConfig "compile: --stdlib-root requires a value")
          (compile-cli-batch-parse-options
            (+ idx 2)
            count
            batch-path
            has-target
            target
            (string-vec-push stdlib-roots (arg (+ idx 1)))
            cfg-names
            has-opt-level
            opt-level
            backend-mode))
        (string-eq current "--cfg")
        (if (>= (+ idx 1) count)
          (ErrCompileCliBatchConfig "compile: --cfg requires a value")
          (compile-cli-batch-parse-options
            (+ idx 2)
            count
            batch-path
            has-target
            target
            stdlib-roots
            (string-vec-push cfg-names (arg (+ idx 1)))
            has-opt-level
            opt-level
            backend-mode))
        (string-eq current "--target")
        (if (>= (+ idx 1) count)
          (ErrCompileCliBatchConfig "compile: --target requires a value")
          (if has-target
            (ErrCompileCliBatchConfig
              "compile: --target was provided more than once")
            (match (compile-cli-target (arg (+ idx 1)))
              [(OkCompileCliTarget parsed-target)
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
                  backend-mode)]
              [(ErrCompileCliTarget message) (ErrCompileCliBatchConfig message)])))
        (string-eq current "--opt-level")
        (if (>= (+ idx 1) count)
          (ErrCompileCliBatchConfig "compile: --opt-level requires a value")
          (if has-opt-level
            (ErrCompileCliBatchConfig
              "compile: --opt-level was provided more than once")
            (let
              [value : String (arg (+ idx 1))]
              (match (compiler-optimize-parse-level value)
                [(OkCompilerOptimizeLevel parsed-level)
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
                    backend-mode)]
                [(ErrCompilerOptimizeLevel)
                  (ErrCompileCliBatchConfig
                    (compile-cli-invalid-opt-level value))]))))
        (string-eq current "--backend-mode")
        (if (>= (+ idx 1) count)
          (ErrCompileCliBatchConfig "compile: --backend-mode requires a value")
          (match (compile-cli-backend-mode (arg (+ idx 1)))
            [(OkCompileCliBackendMode parsed-mode)
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
                parsed-mode)]
            [(ErrCompileCliBackendMode message)
              (ErrCompileCliBatchConfig message)]))
        (compile-cli-flag? current)
        (ErrCompileCliBatchConfig
          (string-append "compile: unknown flag " current))
        (ErrCompileCliBatchConfig
          (string-append "compile: unexpected argument " current))))))

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
          (string-vec-new)
          (string-vec-new)
          false
          false
          false
          (compiler-optimize-default-level)
          (BackendModeScalar))))))

(define (compile-cli-command-config [count : i64]) : ResultCompileCliConfig
  (compile-cli-config-from 2 count))

(define (compile-cli-batch-config-from [batch-path-idx : i64] [count : i64]) : ResultCompileCliBatchConfig
  (if (>= batch-path-idx count)
    (ErrCompileCliBatchConfig "compile: --batch requires a list file")
    (let
      [batch-path : String (arg batch-path-idx)]
      (if (compile-cli-flag? batch-path)
        (ErrCompileCliBatchConfig "compile: --batch requires a list file")
        (compile-cli-batch-parse-options
          (+ batch-path-idx 1)
          count
          batch-path
          false
          (BackendTargetLinux)
          (string-vec-new)
          (string-vec-new)
          false
          (compiler-optimize-default-level)
          (BackendModeScalar))))))

(define (compile-cli-command-action [count : i64]) : CompileCliAction
  (if (and (> count 2) (string-eq (arg 2) "--batch"))
    (match (compile-cli-batch-config-from 3 count)
      [(OkCompileCliBatchConfig config) (CompileCliBatch config)]
      [(ErrCompileCliBatchConfig message) (CompileCliError message)])
    (match (compile-cli-command-config count)
      [(OkCompileCliConfig config) (CompileCliRun config)]
      [(ErrCompileCliConfig message) (CompileCliError message)])))

(define (compile-cli-check-parse-options
  [idx : i64]
  [count : i64]
  [input-path : String]
  [stdlib-roots : StringVec]) : ResultCompileCliCheckConfig
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
            (string-vec-push stdlib-roots (arg (+ idx 1)))))
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
      (string-vec-new))))

(define (compile-cli-top-level-check-config [count : i64]) : ResultCompileCliCheckConfig
  (compile-cli-check-config-from
    2
    count
    (compile-cli-message-with-usage "Error: missing file argument")))

(define (compile-cli-dispatch [count : i64]) : CompileCliAction
  (if (< count 2)
    (CompileCliError
      (compile-cli-message-with-usage "typelisp: expected command"))
    (let
      [command : String (arg 1)]
      (cond
        (or
          (string-eq command "help")
          (string-eq command "--help")
          (string-eq command "-h"))
        (CompileCliHelp)
        (string-eq command "compile")
        (compile-cli-command-action count)
        (string-eq command "check")
        (match (compile-cli-top-level-check-config count)
          [(OkCompileCliCheckConfig input-path roots)
            (CompileCliCheck input-path roots)]
          [(ErrCompileCliCheckConfig message) (CompileCliError message)])
        (CompileCliError
          (compile-cli-message-with-usage
            (string-append "Unknown command: " command)))))))

(define (compile-cli-cfg-names-to-env-from
  [cfg-names : StringVec]
  [index : i64]
  [env : SymI64Env]) : SymI64Env
  (if (>= index (string-vec-len cfg-names))
    env
    (compile-cli-cfg-names-to-env-from
      cfg-names
      (+ index 1)
      (compiler-cfg-enable env (string-vec-get cfg-names index "")))))

(define (compile-cli-cfg-names-to-env [cfg-names : StringVec]) : SymI64Env
  (compile-cli-cfg-names-to-env-from cfg-names 0 (compiler-cfg-empty)))

(define (compile-cli-typecheck-doctests
  [input-path : String]
  [stdlib-roots : StringVec]) : i64
  (match (try-read-file (& input-path))
    [(ErrIoString _) 0]
    [(OkIoString source)
      (let
        [report : DocTestRunReport
          (doc-test-typecheck-source-with-roots input-path source stdlib-roots)]
        (if (doc-test-run-report-ok? report)
          0
          (begin
            (print-error (doc-test-run-report-render report))
            1)))]))

(define (compile-cli-run-compile-file
  [input-path : String]
  [output-path : String]
  [emit-ir : bool]
  [pic : bool]
  [has-target : bool]
  [target : CompilerBackendTarget]
  [stdlib-roots : StringVec]
  [cfg-names : StringVec]
  [backend-mode : CompilerBackendMode]
  [opt-level : i64]) : i64
  (let
    [doctest-status : i64
      (compile-cli-typecheck-doctests input-path stdlib-roots)]
    (if (= doctest-status 0)
      (begin
        (compiler-driver-reset-file-state!)
        (let
          [cfgs : SymI64Env (compile-cli-cfg-names-to-env cfg-names)]
          (cond
            emit-ir
            (compiler-driver-write-result
              (compiler-driver-emit-ir-summary-file-with-target-roots-level-mode-and-cfg
                input-path
                target
                stdlib-roots
                opt-level
                backend-mode
                cfgs)
              output-path)
            pic
            (compiler-driver-compile-file-pic-with-target-roots-level-mode-cfg
              input-path
              output-path
              target
              has-target
              stdlib-roots
              opt-level
              backend-mode
              cfgs)
            has-target
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
              cfgs))))
      doctest-status)))

(define (compile-cli-batch-line-end [text : String] [start : i64] [n : i64]) : i64
  (let
    [i : i64 start]
    [done : bool false]
    (begin
      (while (and (not done) (< i n))
        (let
          [c : char (string-ref text i)]
          (if (or (= c #\newline') (= c #\return'))
            (set! done true)
            (set! i (+ i 1)))))
      i)))

(define (compile-cli-batch-next-line [text : String] [line-end : i64] [n : i64]) : i64
  (if (>= line-end n)
    n
    (if (and
      (= (string-ref text line-end) #\return')
      (< (+ line-end 1) n)
      (= (string-ref text (+ line-end 1)) #\newline'))
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
        (if (= (string-ref text i) #|')
          (set! found i)
          (set! i (+ i 1))))
      found)))

(define (compile-cli-batch-line-error [line : i64] [message : String]) : i64
  (begin
    (print-error
      (str-cat
        "compile: malformed --batch line "
        (int->string line)
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
    (OkCompileCliBatchEntryList CompileCliBatchEntryNil)
    (let
      [line-end : i64 (compile-cli-batch-line-end text start n)]
      [next-start : i64 (compile-cli-batch-next-line text line-end n)]
      (if (= start line-end)
        (compile-cli-batch-parse-entries-from text next-start (+ line 1) n)
        (let
          [sep : i64 (compile-cli-batch-find-separator text start line-end)]
          (if (< sep 0)
            (ErrCompileCliBatchEntryList
              (compile-cli-batch-line-error line "expected input|output"))
            (let
              [output-start : i64 (+ sep 1)]
              (if (= start sep)
                (ErrCompileCliBatchEntryList
                  (compile-cli-batch-line-error line "missing input path"))
                (if (= output-start line-end)
                  (ErrCompileCliBatchEntryList
                    (compile-cli-batch-line-error line "missing output path"))
                  (let
                    [input-path : String (substring text start (- sep start))]
                    [output-path : String
                      (substring text output-start (- line-end output-start))]
                    (match (compile-cli-batch-parse-entries-from
                      text
                      next-start
                      (+ line 1)
                      n)
                      [(OkCompileCliBatchEntryList rest)
                        (OkCompileCliBatchEntryList
                          (compile-cli-batch-entry-cons
                            input-path
                            output-path
                            rest))]
                      [(ErrCompileCliBatchEntryList status)
                        (ErrCompileCliBatchEntryList status)])))))))))))

(define (compile-cli-run-batch-entry
  [input-path : String]
  [output-path : String]
  [has-target : bool]
  [target : CompilerBackendTarget]
  [stdlib-roots : StringVec]
  [cfg-names : StringVec]
  [backend-mode : CompilerBackendMode]
  [opt-level : i64]) : i64
  (let
    [home : i64 (arena-current)]
    [scratch : i64 (arena-make)]
    (begin
      (unsafe
        (arena-set! scratch))
      (let
        [status : i64
          (compile-cli-run-compile-file
            input-path
            output-path
            false
            false
            has-target
            target
            stdlib-roots
            cfg-names
            backend-mode
            opt-level)]
        [scratch-head : i64 (arena-current)]
        (begin
          (unsafe
            (arena-set! home))
          (unsafe
            (arena-destroy scratch-head))
          status)))))

(define (compile-cli-run-batch-entries
  [entries : CompileCliBatchEntryList]
  [has-target : bool]
  [target : CompilerBackendTarget]
  [stdlib-roots : StringVec]
  [cfg-names : StringVec]
  [backend-mode : CompilerBackendMode]
  [opt-level : i64]) : i64
  (match entries
    [(CompileCliBatchEntryNil) 0]
    [(CompileCliBatchEntryCons input-path output-path rest)
      (let
        ;; Each batch entry gets a destroyable scratch arena, not just a
        ;; lexical rewind region. Rewinds intentionally retain overflow chunks
        ;; until the owning arena is destroyed (#2441), so long batches must
        ;; destroy the entry arena to avoid inter-entry growth.
        [status : i64
          (compile-cli-run-batch-entry
            input-path
            output-path
            has-target
            target
            stdlib-roots
            cfg-names
            backend-mode
            opt-level)]
        (if (= status 0)
          (compile-cli-run-batch-entries
            (box-get rest)
            has-target
            target
            stdlib-roots
            cfg-names
            backend-mode
            opt-level)
          (begin
            (print-error
              (str-cat "\ncompile: batch source failed: " input-path "\n"))
            status)))]))

(define (compile-cli-run-batch-from
  [text : String]
  [start : i64]
  [line : i64]
  [has-target : bool]
  [target : CompilerBackendTarget]
  [stdlib-roots : StringVec]
  [cfg-names : StringVec]
  [backend-mode : CompilerBackendMode]
  [opt-level : i64]) : i64
  (match (compile-cli-batch-parse-entries-from
    text
    start
    line
    (string-length text))
    [(OkCompileCliBatchEntryList entries)
      (compile-cli-run-batch-entries
        entries
        has-target
        target
        stdlib-roots
        cfg-names
        backend-mode
        opt-level)]
    [(ErrCompileCliBatchEntryList status) status]))

(define (compile-cli-run-batch [config : CompileCliBatchConfig]) : i64
  (begin
    (compiler-load-session-cache-enable!)
    (match config
      [(CompileCliBatchConfig
          batch-path
          has-target
          target
          stdlib-roots
          cfg-names
          backend-mode
          opt-level)
        (compile-cli-run-batch-from
          (read-file batch-path)
          0
          1
          has-target
          target
          stdlib-roots
          cfg-names
          backend-mode
          opt-level)])))

(define (compile-cli-run [count : i64]) : i64
  (match (compile-cli-dispatch count)
    [(CompileCliRun config)
      (match config
        [(CompileCliConfig
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
            input-path
            output-path
            emit-ir
            pic
            has-target
            target
            stdlib-roots
            cfg-names
            backend-mode
            opt-level)])]
    [(CompileCliBatch config) (compile-cli-run-batch config)]
    [(CompileCliCheck input-path stdlib-roots)
      (match (compiler-check-file-with-roots input-path stdlib-roots)
        [(OkCompilerCheck _)
          (let
            [doctest-status : i64
              (compile-cli-typecheck-doctests input-path stdlib-roots)]
            (if (= doctest-status 0)
              (begin
                (print-string "Type checking passed!\n")
                0)
              doctest-status))]
        [(ErrCompilerCheck diag)
          (begin
            (print-error (compiler-diagnostic-render diag))
            1)])]
    [(CompileCliHelp)
      (begin
        (print-error (compile-cli-usage))
        0)]
    [(CompileCliError message)
      (begin
        (print-error message)
        1)]))