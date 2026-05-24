;; compile.tl - Command-shaped selfhost compile driver (#565).

;;

;; Wraps compiler_driver.tl's input/output API with the first selfhost compile

;; CLI slice: `<file.tl> [-o <file>] [--target <target>]`. Backend-mode/IR/stdlib-root flags

;; remain Rust-driver-only for now and are rejected explicitly.

(import "compiler_driver_core.tl")

(defenum CompileCliConfig
  (CompileCliConfig String String bool CompilerBackendTarget))

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
  (let (
    [n : i64 (string-length input-path)]
    [i : i64 0]
    [last-dot : i64 -1]
    [last-sep : i64 -1])
    (begin
      (while (< i n)
        (let ([c : char (string-ref input-path i)])
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

(define (compile-cli-parse-options
  [idx : i64]
  [count : i64]
  [input-path : String]
  [output-path : String]
  [has-output : bool]
  [has-target : bool]
  [target : CompilerBackendTarget]) : ResultCompileCliConfig
  (if (>= idx count)
    (OkCompileCliConfig
      (CompileCliConfig input-path output-path has-target target))
    (let ([current : String (arg idx)])
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
              target)))
        (if (string-eq current "--stdlib-root")
          (if (>= (+ idx 1) count)
            (ErrCompileCliConfig "compile: --stdlib-root requires a value")
            (ErrCompileCliConfig (compile-cli-unsupported-flag current)))
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
                      parsed-target)]
                  [(ErrCompileCliTarget message) (ErrCompileCliConfig message)])))
            (if (string-eq current "--backend-mode")
              (if (>= (+ idx 1) count)
                (ErrCompileCliConfig "compile: --backend-mode requires a value")
                (ErrCompileCliConfig (compile-cli-unsupported-flag current)))
              (if (string-eq current "--emit-ir")
                (ErrCompileCliConfig (compile-cli-unsupported-flag current))
                (if (compile-cli-flag? current)
                  (ErrCompileCliConfig
                    (string-append "compile: unknown flag " current))
                  (ErrCompileCliConfig
                    (string-append "compile: unexpected argument " current)))))))))))

(define (compile-cli-config [count : i64]) : ResultCompileCliConfig
  (if (< count 2)
    (ErrCompileCliConfig "compile: expected source path")
    (let ([input-path : String (arg 1)])
      (if (compile-cli-flag? input-path)
        (ErrCompileCliConfig "compile: expected source path before flags")
        (compile-cli-parse-options
          2
          count
          input-path
          (compile-cli-default-output input-path)
          false
          false
          (BackendTargetLinux))))))

(define (main) : i64
  (match (compile-cli-config (arg-count))
    [(OkCompileCliConfig config)
      (match config
        [(CompileCliConfig input-path output-path has-target target)
          (if has-target
            (compiler-driver-compile-file-for-target
              input-path
              output-path
              target)
            (compiler-driver-compile-file input-path output-path))])]
    [(ErrCompileCliConfig message)
      (begin
        (print-error message)
        1)]))