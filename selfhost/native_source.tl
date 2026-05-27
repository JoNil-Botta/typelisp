;; native_source.tl - Linux selfhost source build/run helpers (#1338).
;;
;; This is the source-file executable path shared by selfhost/build.tl and
;; selfhost/run.tl. It deliberately stays Linux + scalar for this slice; other
;; targets/modes can keep using the private host-action bridge until the
;; corresponding selfhost backend/linker support exists.
(import "compiler_driver_core.tl")

(import "stdlib/env.tl")

(import "stdlib/fs.tl")

(import "stdlib/io.tl")

(import "stdlib/process.tl")

(defenum ResultNativeSourcePath
  (OkNativeSourcePath String)
  (ErrNativeSourcePath String))

(defenum ResultNativeSourceUnit
  (OkNativeSourceUnit)
  (ErrNativeSourceUnit String))

(define (native-source-cat3 [a : String] [b : String] [c : String]) : String
  (string-append a (string-append b c)))

(define (native-source-target-linux? [target : String]) : bool
  (or (string-eq target "linux-x86_64") (string-eq target "linux_x86_64")))

(define (native-source-host-linux?) : bool
  (not (fs-windows?)))

(define (native-source-default-output-with-extension
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
            (if (char-eq c #.')
              (set! last-dot i)
              (set! last-dot last-dot))
            (if (fs-path-separator? c)
              (set! last-sep i)
              (set! last-sep last-sep))
            (set! i (+ i 1)))))
      (if (> last-dot last-sep)
        (string-append (substring input-path 0 last-dot) extension)
        (string-append input-path extension)))))

(define (native-source-default-executable-path [input-path : String]) : String
  (native-source-default-output-with-extension input-path ""))

(define (native-source-root-list-append
  [roots : CompilerLoadRootList]
  [root : String]) : CompilerLoadRootList
  (match roots
    [(CompilerLoadRootNil) (CompilerLoadRootCons root CompilerLoadRootNil)]
    [(CompilerLoadRootCons head rest)
      (CompilerLoadRootCons head (native-source-root-list-append rest root))]))

(define (native-source-roots-with-env [roots : CompilerLoadRootList]) : CompilerLoadRootList
  (match (env-get "TYPELISP_STDLIB_ROOT")
    [(EnvSomeString value)
      (if (> (string-length value) 0)
        (native-source-root-list-append roots value)
        roots)]
    [(EnvNoString) roots]))

(define (native-source-process-args-append
  [args : ProcessStringList]
  [value : String]) : ProcessStringList
  (process-args-append args (process-args-single value)))

(define (native-source-dir-root? [path : String]) : bool
  (or
    (string-eq path "")
    (or (string-eq path ".") (or (string-eq path "/") (string-eq path "\\")))))

(define (native-source-ensure-dir [path : String]) : ResultNativeSourceUnit
  (if (native-source-dir-root? path)
    OkNativeSourceUnit
    (match (try-file-exists? path)
      [(OkIoBool exists)
        (if exists
          OkNativeSourceUnit
          (match (native-source-ensure-dir (fs-dirname path))
            [(ErrNativeSourceUnit message) (ErrNativeSourceUnit message)]
            [(OkNativeSourceUnit)
              (match (try-mkdir path)
                [(OkIoUnit) OkNativeSourceUnit]
                [(ErrIoUnit error)
                  (ErrNativeSourceUnit (io-error-message error))])]))]
      [(ErrIoBool error) (ErrNativeSourceUnit (io-error-message error))])))

(define (native-source-ensure-parent [path : String]) : ResultNativeSourceUnit
  (native-source-ensure-dir (fs-dirname path)))

(define (native-source-cleanup
  [temp-dir : String]
  [asm-path : String]
  [obj-path : String]
  [bin-path : String]
  [cleanup-bin : bool]) : unit
  (begin
    (try-remove-file-if-exists asm-path)
    (try-remove-file-if-exists obj-path)
    (if cleanup-bin
      (try-remove-file-if-exists bin-path)
      OkIoUnit)
    (try-remove-dir-if-exists temp-dir)
    unit))

(define (native-source-forward-output [output : ProcessOutput]) : unit
  (begin
    (print-string (process-output-stdout output))
    (print-error (process-output-stderr output))
    unit))

(define (native-source-run-tool
  [role : String]
  [tool : String]
  [args : ProcessStringList]) : ResultNativeSourceUnit
  (match (process-output (process-command tool args))
    [(ErrProcessOutput error)
      (ErrNativeSourceUnit
        (native-source-cat3
          (native-source-cat3
            (native-source-cat3 "Error: failed to run " role " '")
            tool
            "' for target linux-x86_64: ")
          (process-error-message error)
          ""))]
    [(OkProcessOutput output)
      (begin
        (native-source-forward-output output)
        (if (= (process-output-status output) 0)
          OkNativeSourceUnit
          (ErrNativeSourceUnit
            (native-source-cat3
              (native-source-cat3
                (native-source-cat3 "Error: " role " '")
                tool
                "' failed for target linux-x86_64 with status ")
              (int->string (process-output-status output))
              ""))))]))

(define (native-source-assembler-args [asm-path : String] [obj-path : String]) : ProcessStringList
  (process-args-cons
    asm-path
    (process-args-cons "-o" (process-args-single obj-path))))

(define (native-source-linker-args [obj-path : String] [bin-path : String]) : ProcessStringList
  (process-args-cons
    obj-path
    (process-args-cons
      "-o"
      (process-args-cons
        bin-path
        (process-args-cons
          "-dynamic-linker"
          (process-args-cons
            "/lib64/ld-linux-x86-64.so.2"
            (process-args-single "-lc")))))))

(define (native-source-supported
  [command-name : String]
  [target : String]
  [mode : String]) : ResultNativeSourceUnit
  (if (not (native-source-host-linux?))
    (ErrNativeSourceUnit
      (native-source-cat3
        command-name
        ": source executable build is currently supported by selfhost only on Linux"
        ""))
    (if (not (native-source-target-linux? target))
      (ErrNativeSourceUnit
        (native-source-cat3
          (native-source-cat3
            command-name
            ": source executable build currently supports linux-x86_64 only; got "
            "")
          target
          ""))
      (if (not (string-eq mode "scalar"))
        (ErrNativeSourceUnit
          (native-source-cat3
            (native-source-cat3 command-name ": --backend-mode " "")
            mode
            " requires the Rust host-action bridge until selfhost SIMD support (#1014)"))
        OkNativeSourceUnit))))

(define (native-source-write-asm
  [input-path : String]
  [asm-path : String]
  [stdlib-roots : CompilerLoadRootList]
  [opt-level : i64]) : ResultNativeSourceUnit
  (match (compiler-driver-emit-file-for-target-with-roots-and-level
    input-path
    (BackendTargetLinux)
    (native-source-roots-with-env stdlib-roots)
    opt-level)
    [(ErrCompilerDriver diag)
      (ErrNativeSourceUnit (compiler-diagnostic-render diag))]
    [(OkCompilerDriver asm)
      (match (try-write-file asm-path asm)
        [(OkIoUnit) OkNativeSourceUnit]
        [(ErrIoUnit error) (ErrNativeSourceUnit (io-error-message error))])]))

(define (native-source-build-executable
  [command-name : String]
  [input-path : String]
  [bin-path : String]
  [target : String]
  [mode : String]
  [stdlib-roots : CompilerLoadRootList]
  [opt-level : i64]
  [cleanup-bin : bool]) : ResultNativeSourcePath
  (match (native-source-supported command-name target mode)
    [(ErrNativeSourceUnit message) (ErrNativeSourcePath message)]
    [(OkNativeSourceUnit)
      (match (try-create-temp-dir "typelisp-native-source")
        [(ErrIoString error)
          (ErrNativeSourcePath
            (string-append
              "Error: failed to create temporary native source directory: "
              (io-error-message error)))]
        [(OkIoString temp-dir)
          (let
            [asm-path : String (fs-path-join temp-dir "source.s")]
            [obj-path : String (fs-path-join temp-dir "source.o")]
            (match (native-source-ensure-parent bin-path)
              [(ErrNativeSourceUnit message)
                (begin
                  (native-source-cleanup
                    temp-dir
                    asm-path
                    obj-path
                    bin-path
                    cleanup-bin)
                  (ErrNativeSourcePath message))]
              [(OkNativeSourceUnit)
                (match (native-source-write-asm
                  input-path
                  asm-path
                  stdlib-roots
                  opt-level)
                  [(ErrNativeSourceUnit message)
                    (begin
                      (native-source-cleanup
                        temp-dir
                        asm-path
                        obj-path
                        bin-path
                        cleanup-bin)
                      (ErrNativeSourcePath message))]
                  [(OkNativeSourceUnit)
                    (match (native-source-run-tool
                      "assembler"
                      "as"
                      (native-source-assembler-args asm-path obj-path))
                      [(ErrNativeSourceUnit message)
                        (begin
                          (native-source-cleanup
                            temp-dir
                            asm-path
                            obj-path
                            bin-path
                            cleanup-bin)
                          (ErrNativeSourcePath message))]
                      [(OkNativeSourceUnit)
                        (match (native-source-run-tool
                          "linker"
                          "ld"
                          (native-source-linker-args obj-path bin-path))
                          [(ErrNativeSourceUnit message)
                            (begin
                              (native-source-cleanup
                                temp-dir
                                asm-path
                                obj-path
                                bin-path
                                cleanup-bin)
                              (ErrNativeSourcePath message))]
                          [(OkNativeSourceUnit)
                            (begin
                              (native-source-cleanup
                                temp-dir
                                asm-path
                                obj-path
                                bin-path
                                cleanup-bin)
                              (OkNativeSourcePath bin-path))])])])]))])]))

(define (native-source-build-command
  [input-path : String]
  [output-path : String]
  [has-output : bool]
  [target : String]
  [mode : String]
  [stdlib-roots : CompilerLoadRootList]
  [opt-level : i64]) : i64
  (let
    [bin-path : String
      (if has-output
        output-path
        (native-source-default-executable-path input-path))]
    (match (native-source-build-executable
      "build"
      input-path
      bin-path
      target
      mode
      stdlib-roots
      opt-level
      false)
      [(OkNativeSourcePath built)
        (begin
          (print-string
            (string-append "Generated: " (string-append built "\n")))
          0)]
      [(ErrNativeSourcePath message)
        (begin
          (print-error message)
          1)])))

(define (native-source-run-command
  [input-path : String]
  [target : String]
  [mode : String]
  [stdlib-roots : CompilerLoadRootList]
  [runtime-args : ProcessStringList]
  [opt-level : i64]) : i64
  (match (try-create-temp-dir "typelisp-native-run-bin")
    [(ErrIoString error)
      (begin
        (print-error
          (string-append
            "Error: failed to create temporary native run directory: "
            (io-error-message error)))
        1)]
    [(OkIoString run-dir)
      (let
        [bin-path : String (fs-path-join run-dir "program")]
        (match (native-source-build-executable
          "run"
          input-path
          bin-path
          target
          mode
          stdlib-roots
          opt-level
          true)
          [(ErrNativeSourcePath message)
            (begin
              (try-remove-dir-if-exists run-dir)
              (print-error message)
              1)]
          [(OkNativeSourcePath built)
            (match (process-output (process-command built runtime-args))
              [(ErrProcessOutput error)
                (begin
                  (try-remove-file-if-exists built)
                  (try-remove-dir-if-exists run-dir)
                  (print-error
                    (string-append
                      "Error: failed to run executable for target linux-x86_64: "
                      (process-error-message error)))
                  1)]
              [(OkProcessOutput output)
                (begin
                  (native-source-forward-output output)
                  (try-remove-file-if-exists built)
                  (try-remove-dir-if-exists run-dir)
                  (process-output-status output))])]))]))