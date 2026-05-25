;; compile.tl - Command-shaped selfhost compile driver (#565).
;;
;; Wraps compiler_driver.tl's input/output API with the first selfhost compile
;; CLI slice: `<file.tl> [-o <file>] [--target <target>]
;; [--opt-level <0|1|2|3>] [--stdlib-root <dir>...]`.
;; Backend-mode and IR flags remain Rust-driver-only for now and are rejected
;; explicitly.
(import "compiler_driver_core.tl")

(defenum CompileCliConfig
  (CompileCliConfig
    String
    String
    bool
    CompilerBackendTarget
    CompilerLoadRootList
    i64))

(defenum ResultCompileCliConfig
  (OkCompileCliConfig CompileCliConfig)
  (ErrCompileCliConfig String))

(defenum ResultCompileCliTarget
  (OkCompileCliTarget CompilerBackendTarget)
  (ErrCompileCliTarget String))

(define (compile-cli-cat3 [a : String] [b : String] [c : String]) : String
  (string-append a (string-append b c)))

(define (compile-cli-path-separator? [c : char]) : bool
  (or (= c #/') (= c #\\')))

(define (compile-cli-flag? [value : String]) : bool
  (and (> (string-length value) 0) (= (string-ref value 0) #-')))

(define (compile-cli-default-output [input-path : String]) : String
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
        (string-append (substring input-path 0 last-dot) ".s")
        (string-append input-path ".s")))))

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

(define (compile-cli-unsupported-flag [flag : String]) : String
  (compile-cli-cat3
    "compile: "
    flag
    " is not supported by the selfhost compile driver yet; use Rust typelisp compile"))

(define (compile-cli-invalid-opt-level [value : String]) : String
  (compile-cli-cat3
    "compile: invalid --opt-level "
    value
    "; expected 0, 1, 2, or 3"))

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
  [has-opt-level : bool]
  [opt-level : i64]) : ResultCompileCliConfig
  (if (>= idx count)
    (OkCompileCliConfig
      (CompileCliConfig
        input-path
        output-path
        has-target
        target
        stdlib-roots
        opt-level))
    (let
      [current : String (arg idx)]
      (if (string-eq current "-o")
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
              has-opt-level
              opt-level)))
        (if (string-eq current "--stdlib-root")
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
              has-opt-level
              opt-level))
          (if (string-eq current "--target")
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
                      has-opt-level
                      opt-level)]
                  [(ErrCompileCliTarget message) (ErrCompileCliConfig message)])))
            (if (string-eq current "--opt-level")
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
                          true
                          parsed-level)]
                      [(ErrCompilerOptimizeLevel)
                        (ErrCompileCliConfig
                          (compile-cli-invalid-opt-level value))]))))
              (if (string-eq current "--backend-mode")
                (if (>= (+ idx 1) count)
                  (ErrCompileCliConfig
                    "compile: --backend-mode requires a value")
                  (ErrCompileCliConfig (compile-cli-unsupported-flag current)))
                (if (string-eq current "--emit-ir")
                  (ErrCompileCliConfig (compile-cli-unsupported-flag current))
                  (if (compile-cli-flag? current)
                    (ErrCompileCliConfig
                      (string-append "compile: unknown flag " current))
                    (ErrCompileCliConfig
                      (string-append "compile: unexpected argument " current))))))))))))

(define (compile-cli-config [count : i64]) : ResultCompileCliConfig
  (if (< count 2)
    (ErrCompileCliConfig "compile: expected source path")
    (let
      [input-path : String (arg 1)]
      (if (compile-cli-flag? input-path)
        (ErrCompileCliConfig "compile: expected source path before flags")
        (compile-cli-parse-options
          2
          count
          input-path
          (compile-cli-default-output input-path)
          false
          false
          (BackendTargetLinux)
          CompilerLoadRootNil
          false
          (compiler-optimize-default-level))))))

(define (main) : i64
  (match (compile-cli-config (arg-count))
    [(OkCompileCliConfig config)
      (match config
        [(CompileCliConfig
            input-path
            output-path
            has-target
            target
            stdlib-roots
            opt-level)
          (if has-target
            (compiler-driver-compile-file-for-target-with-roots-and-level
              input-path
              output-path
              target
              stdlib-roots
              opt-level)
            (compiler-driver-compile-file-with-roots-and-level
              input-path
              output-path
              stdlib-roots
              opt-level))])]
    [(ErrCompileCliConfig message)
      (begin
        (print-error message)
        1)]))