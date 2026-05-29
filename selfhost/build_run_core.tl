;; build_run_core.tl - Shared selfhost source build/run execution helpers (#1018).
(import "compiler_driver_core.tl")

(import "../stdlib/fs.tl")

(import "../stdlib/io.tl")

(import "../stdlib/msvc.tl")

(import "../stdlib/process.tl")

(defenum SourceToolCommandStatus
  (SourceToolCommandOk)
  (SourceToolCommandErr String))

(defenum ResultSourceToolCommand
  (OkSourceToolCommand ProcessCommand)
  (ErrSourceToolCommand String))

(defenum ResultSourceToolString
  (OkSourceToolString String)
  (ErrSourceToolString String))

(defenum ResultSourceToolTarget
  (OkSourceToolTarget CompilerBackendTarget)
  (ErrSourceToolTarget String))

(defenum ResultSourceToolBackendMode
  (OkSourceToolBackendMode)
  (ErrSourceToolBackendMode String))

(define (source-tool-cat3 [a : String] [b : String] [c : String]) : String
  (string-append a (string-append b c)))

(define (source-tool-target-name [target : CompilerBackendTarget]) : String
  (match target
    [(BackendTargetLinux) "linux-x86_64"]
    [(BackendTargetWindows) "windows-x86_64"]))

(define (source-tool-default-target) : CompilerBackendTarget
  (if (string-eq (env-path-separator) ";")
    (BackendTargetWindows)
    (BackendTargetLinux)))

(define (source-tool-default-target-name) : String
  (source-tool-target-name (source-tool-default-target)))

(define (source-tool-target [value : String]) : ResultSourceToolTarget
  (if (or (string-eq value "linux-x86_64") (string-eq value "linux_x86_64"))
    (OkSourceToolTarget (BackendTargetLinux))
    (if (or
      (string-eq value "windows-x86_64")
      (string-eq value "windows_x86_64"))
      (OkSourceToolTarget (BackendTargetWindows))
      (ErrSourceToolTarget (string-append "unknown target " value)))))

(define (source-tool-target-supported? [target : CompilerBackendTarget]) : bool
  (match target
    [(BackendTargetLinux) true]
    [(BackendTargetWindows) true]))

(define (source-tool-backend-mode [command : String] [value : String]) : ResultSourceToolBackendMode
  (if (string-eq value "scalar")
    (OkSourceToolBackendMode)
    (if (or (string-eq value "avx2") (string-eq value "avx512"))
      (ErrSourceToolBackendMode
        (source-tool-cat3
          command
          ": --backend-mode "
          (string-append
            value
            (string-append
              " requires the Rust "
              (string-append
                command
                " driver until selfhost SIMD support (#1014)")))))
      (ErrSourceToolBackendMode
        (source-tool-cat3 command ": unknown backend mode " value)))))

(define (source-tool-opt-level-valid? [value : String]) : bool
  (or
    (string-eq value "0")
    (or (string-eq value "1") (or (string-eq value "2") (string-eq value "3")))))

(define (source-tool-flag? [value : String]) : bool
  (and (> (string-length value) 0) (= (string-ref value 0) #-')))

(define (source-tool-root-list-append
  [roots : CompilerLoadRootList]
  [root : String]) : CompilerLoadRootList
  (match roots
    [(CompilerLoadRootNil) (CompilerLoadRootCons root CompilerLoadRootNil)]
    [(CompilerLoadRootCons head rest)
      (CompilerLoadRootCons head (source-tool-root-list-append rest root))]))

(define (source-tool-args-append [args : ProcessStringList] [value : String]) : ProcessStringList
  (process-args-append args (process-args-single value)))

(define (source-tool-args-from-argv
  [idx : i64]
  [count : i64]
  [args : ProcessStringList]) : ProcessStringList
  (if (>= idx count)
    args
    (source-tool-args-from-argv
      (+ idx 1)
      count
      (source-tool-args-append args (arg idx)))))

(define (source-tool-path-separator? [c : char]) : bool
  (or (= c #/') (= c #\\')))

(define (source-tool-has-path-separator? [path : String]) : bool
  (let
    [n : i64 (string-length path)]
    [i : i64 0]
    [found : bool false]
    (begin
      (while (and (< i n) (not found))
        (begin
          (if (source-tool-path-separator? (string-ref path i))
            (set! found true)
            unit)
          (set! i (+ i 1))))
      found)))

(define (source-tool-path-entry-command [dir : String] [tool : String]) : String
  (if (= (string-length dir) 0)
    tool
    (fs-path-join dir tool)))

(define (source-tool-find-command-on-path
  [tool : String]
  [paths : EnvStringList]) : String
  (match paths
    [(EnvStringNil) tool]
    [(EnvStringCons dir rest)
      (let
        [candidate : String (source-tool-path-entry-command dir tool)]
        (match (try-file-exists? candidate)
          [(OkIoBool exists)
            (if exists
              candidate
              (source-tool-find-command-on-path tool rest))]
          [(ErrIoBool _) (source-tool-find-command-on-path tool rest)]))]))

(define (source-tool-resolve-command [tool : String]) : String
  (if (source-tool-has-path-separator? tool)
    tool
    (match (env-path-list "PATH")
      [(EnvSomeStringList paths) (source-tool-find-command-on-path tool paths)]
      [(EnvNoStringList) tool])))

(define (source-tool-env-command-or-default
  [name : String]
  [default-command : String]) : String
  (match (env-get name)
    [(EnvSomeString value)
      (if (string-eq value "")
        default-command
        value)]
    [(EnvNoString) default-command]))

(define (source-tool-replace-extension
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
            (if (source-tool-path-separator? c)
              (set! last-sep i)
              (set! last-sep last-sep))
            (set! i (+ i 1)))))
      (if (> last-dot last-sep)
        (string-append (substring input-path 0 last-dot) extension)
        (string-append input-path extension)))))

(define (source-tool-default-output
  [source : String]
  [target : CompilerBackendTarget]) : String
  (match target
    [(BackendTargetLinux) (source-tool-replace-extension source "")]
    [(BackendTargetWindows) (source-tool-replace-extension source ".exe")]))

(define (source-tool-object-extension [target : CompilerBackendTarget]) : String
  (match target
    [(BackendTargetLinux) "o"]
    [(BackendTargetWindows) "obj"]))

(define (source-tool-executable-extension [target : CompilerBackendTarget]) : String
  (match target
    [(BackendTargetLinux) ""]
    [(BackendTargetWindows) ".exe"]))

(define (source-tool-static-library-extension [target : CompilerBackendTarget]) : String
  (match target
    [(BackendTargetLinux) ".a"]
    [(BackendTargetWindows) ".lib"]))

(define (source-tool-static-library-filename
  [name : String]
  [target : CompilerBackendTarget]) : String
  (match target
    [(BackendTargetLinux)
      (string-append
        "lib"
        (string-append name (source-tool-static-library-extension target)))]
    [(BackendTargetWindows)
      (string-append name (source-tool-static-library-extension target))]))

(define (source-tool-artifact-stem [source : String]) : String
  (source-tool-replace-extension (fs-basename source) ""))

(define (source-tool-asm-path [temp-dir : String] [source : String]) : String
  (fs-path-join
    temp-dir
    (string-append (source-tool-artifact-stem source) ".s")))

(define (source-tool-obj-path
  [temp-dir : String]
  [source : String]
  [target : CompilerBackendTarget]) : String
  (fs-path-join
    temp-dir
    (string-append
      (source-tool-artifact-stem source)
      (string-append "." (source-tool-object-extension target)))))

(define (source-tool-temp-bin-path
  [temp-dir : String]
  [source : String]
  [target : CompilerBackendTarget]) : String
  (fs-path-join
    temp-dir
    (string-append
      (source-tool-artifact-stem source)
      (source-tool-executable-extension target))))

(define (source-tool-create-temp-dir [prefix : String]) : ResultSourceToolString
  (match (try-create-temp-dir prefix)
    [(OkIoString path) (OkSourceToolString path)]
    [(ErrIoString error) (ErrSourceToolString (io-error-message error))]))

(define (source-tool-cannot-read-module-message
  [source : String]
  [error : IoError]) : String
  (string-append
    (string-append "Error: cannot read module '" source)
    (string-append "': " (io-error-message error))))

(define (source-tool-emit-assembly
  [source : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : CompilerLoadRootList]
  [opt-level : i64]) : ResultSourceToolString
  (match (try-read-file source)
    [(ErrIoString error)
      (ErrSourceToolString
        (source-tool-cannot-read-module-message source error))]
    [(OkIoString _)
      (match (compiler-driver-emit-file-for-target-with-roots-and-level
        source
        target
        stdlib-roots
        opt-level)
        [(OkCompilerDriver asm)
          (OkSourceToolString (source-tool-augment-assembly asm))]
        [(ErrCompilerDriver diag)
          (ErrSourceToolString (compiler-diagnostic-render diag))])]))

(define (source-tool-print-string-runtime) : String
  "
    .globl _tl_print_string
_tl_print_string:
    movq 8(%rdi), %rdx
    movq 0(%rdi), %rsi
    movq $1, %rdi
    movq $1, %rax
    syscall
    movq $0, %rax
    ret
")

(define (source-tool-needs-print-string-runtime? [asm : String]) : bool
  (and
    (string-contains asm "call _tl_print_string")
    (not (string-contains asm "_tl_print_string:"))))

(define (source-tool-augment-assembly [asm : String]) : String
  (if (source-tool-needs-print-string-runtime? asm)
    (string-append asm (source-tool-print-string-runtime))
    asm))

(define (source-tool-write-file
  [path : String]
  [contents : String]
  [context : String]) : SourceToolCommandStatus
  (match (try-write-file path contents)
    [(OkIoUnit) SourceToolCommandOk]
    [(ErrIoUnit error)
      (SourceToolCommandErr
        (source-tool-cat3 context ": " (io-error-message error)))]))

(define (source-tool-forward-output [output : ProcessOutput]) : unit
  (begin
    (stdout-write (process-output-stdout output))
    (stderr-write (process-output-stderr output))))

(define (source-tool-run-command
  [role : String]
  [target : CompilerBackendTarget]
  [command : ProcessCommand]) : SourceToolCommandStatus
  (let
    [tool : String (process-command-executable command)]
    (match (process-output command)
      [(OkProcessOutput output)
        (begin
          (source-tool-forward-output output)
          (if (process-success? output)
            SourceToolCommandOk
            (SourceToolCommandErr
              (string-append
                (string-append
                  (string-append "Error: " role)
                  (string-append " '" tool))
                (string-append
                  (string-append
                    "' failed for target "
                    (source-tool-target-name target))
                  (string-append
                    " with status "
                    (int->string (process-output-status output))))))))]
      [(ErrProcessOutput error)
        (SourceToolCommandErr
          (string-append
            (string-append
              (string-append "Error: failed to run " role)
              (string-append " '" tool))
            (string-append
              (string-append "' for target " (source-tool-target-name target))
              (string-append ": " (process-error-message error)))))])))

(define (source-tool-assembler-command [asm-path : String] [obj-path : String]) : ProcessCommand
  (process-command
    (source-tool-resolve-command "as")
    (process-args-cons
      asm-path
      (process-args-cons "-o" (process-args-cons obj-path (process-args-empty))))))

(define (source-tool-windows-assembler-command
  [asm-path : String]
  [obj-path : String]) : ProcessCommand
  (process-command
    (source-tool-env-command-or-default
      "TYPELISP_WINDOWS_CLANG"
      (source-tool-resolve-command "clang"))
    (process-args-cons
      "--target=x86_64-pc-windows-msvc"
      (process-args-cons
        "-c"
        (process-args-cons
          asm-path
          (process-args-cons
            "-o"
            (process-args-cons obj-path (process-args-empty))))))))

(define (source-tool-linker-command [obj-path : String] [bin-path : String]) : ProcessCommand
  (process-command
    (source-tool-resolve-command "ld")
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
              (process-args-cons "-lc" (process-args-empty)))))))))

(define (source-tool-windows-link-libs) : ProcessStringList
  (process-args-cons
    "msvcrt.lib"
    (process-args-cons
      "legacy_stdio_definitions.lib"
      (process-args-cons
        "kernel32.lib"
        (process-args-cons
          "advapi32.lib"
          (process-args-cons
            "ole32.lib"
            (process-args-cons "oleaut32.lib" (process-args-empty))))))))

(define (source-tool-windows-linker-args
  [obj-path : String]
  [bin-path : String]) : ProcessStringList
  (process-args-cons
    "/NOLOGO"
    (process-args-cons
      obj-path
      (process-args-cons
        (string-append "/OUT:" bin-path)
        (process-args-cons
          "/SUBSYSTEM:CONSOLE"
          (process-args-cons
            "/DYNAMICBASE:NO"
            (process-args-cons
              "/STACK:16777216"
              (source-tool-windows-link-libs))))))))

(define (source-tool-windows-linker-command
  [obj-path : String]
  [bin-path : String]) : ResultSourceToolCommand
  (match (msvc-find-tool "x86_64-pc-windows-msvc" "link.exe")
    [(OkMsvcTool tool)
      (OkSourceToolCommand
        (process-command-with-env-list
          (process-command
            (source-tool-env-command-or-default
              "TYPELISP_WINDOWS_LINK"
              (msvc-tool-executable tool))
            (source-tool-windows-linker-args obj-path bin-path))
          (msvc-tool-process-env tool)))]
    [(ErrMsvcTool error)
      (ErrSourceToolCommand
        (string-append
          "Error: failed to resolve linker 'link.exe' for target windows-x86_64: "
          (msvc-error-message error)))]))

(define (source-tool-archiver-command
  [obj-path : String]
  [archive-path : String]) : ProcessCommand
  (process-command
    (source-tool-resolve-command "ar")
    (process-args-cons
      "rcs"
      (process-args-cons
        archive-path
        (process-args-cons obj-path (process-args-empty))))))

(define (source-tool-windows-archiver-args
  [obj-path : String]
  [archive-path : String]) : ProcessStringList
  (process-args-cons
    "/NOLOGO"
    (process-args-cons
      (string-append "/OUT:" archive-path)
      (process-args-cons obj-path (process-args-empty)))))

(define (source-tool-windows-archiver-command
  [obj-path : String]
  [archive-path : String]) : ResultSourceToolCommand
  (match (msvc-find-tool "x86_64-pc-windows-msvc" "lib.exe")
    [(OkMsvcTool tool)
      (OkSourceToolCommand
        (process-command-with-env-list
          (process-command
            (source-tool-env-command-or-default
              "TYPELISP_WINDOWS_LIB"
              (msvc-tool-executable tool))
            (source-tool-windows-archiver-args obj-path archive-path))
          (msvc-tool-process-env tool)))]
    [(ErrMsvcTool error)
      (ErrSourceToolCommand
        (string-append
          "Error: failed to resolve archiver 'lib.exe' for target windows-x86_64: "
          (msvc-error-message error)))]))

(define (source-tool-clean-temp
  [temp-dir : String]
  [asm-path : String]
  [obj-path : String]
  [bin-path : String]
  [remove-bin : bool]) : unit
  (begin
    (try-remove-file-if-exists asm-path)
    (try-remove-file-if-exists obj-path)
    (if remove-bin
      (try-remove-file-if-exists bin-path)
      OkIoUnit)
    (try-remove-dir-if-exists temp-dir)
    unit))

(define (source-tool-assemble
  [target : CompilerBackendTarget]
  [asm-path : String]
  [obj-path : String]) : SourceToolCommandStatus
  (match target
    [(BackendTargetLinux)
      (source-tool-run-command
        "assembler"
        target
        (source-tool-assembler-command asm-path obj-path))]
    [(BackendTargetWindows)
      (source-tool-run-command
        "assembler"
        target
        (source-tool-windows-assembler-command asm-path obj-path))]))

(define (source-tool-link
  [target : CompilerBackendTarget]
  [obj-path : String]
  [bin-path : String]) : SourceToolCommandStatus
  (match target
    [(BackendTargetLinux)
      (source-tool-run-command
        "linker"
        target
        (source-tool-linker-command obj-path bin-path))]
    [(BackendTargetWindows)
      (match (source-tool-windows-linker-command obj-path bin-path)
        [(OkSourceToolCommand command)
          (source-tool-run-command "linker" target command)]
        [(ErrSourceToolCommand message) (SourceToolCommandErr message)])]))

(define (source-tool-archive
  [target : CompilerBackendTarget]
  [obj-path : String]
  [archive-path : String]) : SourceToolCommandStatus
  (match target
    [(BackendTargetLinux)
      (source-tool-run-command
        "archiver"
        target
        (source-tool-archiver-command obj-path archive-path))]
    [(BackendTargetWindows)
      (match (source-tool-windows-archiver-command obj-path archive-path)
        [(OkSourceToolCommand command)
          (source-tool-run-command "archiver" target command)]
        [(ErrSourceToolCommand message) (SourceToolCommandErr message)])]))

(define (source-tool-assemble-and-link
  [target : CompilerBackendTarget]
  [asm-path : String]
  [obj-path : String]
  [bin-path : String]) : SourceToolCommandStatus
  (match (source-tool-assemble target asm-path obj-path)
    [(SourceToolCommandOk) (source-tool-link target obj-path bin-path)]
    [(SourceToolCommandErr message) (SourceToolCommandErr message)]))

(define (source-tool-assemble-and-archive
  [target : CompilerBackendTarget]
  [asm-path : String]
  [obj-path : String]
  [archive-path : String]) : SourceToolCommandStatus
  (match (source-tool-assemble target asm-path obj-path)
    [(SourceToolCommandOk) (source-tool-archive target obj-path archive-path)]
    [(SourceToolCommandErr message) (SourceToolCommandErr message)]))

(define (source-tool-build-source-in-temp
  [source : String]
  [output : String]
  [has-output : bool]
  [target : CompilerBackendTarget]
  [stdlib-roots : CompilerLoadRootList]
  [opt-level : i64]
  [temp-dir : String]) : i64
  (let
    [asm-path : String (source-tool-asm-path temp-dir source)]
    [obj-path : String (source-tool-obj-path temp-dir source target)]
    [bin-path : String
      (if has-output
        output
        (source-tool-default-output source target))]
    (match (source-tool-emit-assembly source target stdlib-roots opt-level)
      [(ErrSourceToolString message)
        (begin
          (print-error message)
          (source-tool-clean-temp temp-dir asm-path obj-path bin-path false)
          1)]
      [(OkSourceToolString asm)
        (match (source-tool-write-file
          asm-path
          asm
          "build: failed to write assembly artifact")
          [(SourceToolCommandErr message)
            (begin
              (print-error message)
              (source-tool-clean-temp temp-dir asm-path obj-path bin-path false)
              1)]
          [(SourceToolCommandOk)
            (match (source-tool-assemble-and-link
              target
              asm-path
              obj-path
              bin-path)
              [(SourceToolCommandErr message)
                (begin
                  (print-error message)
                  (source-tool-clean-temp
                    temp-dir
                    asm-path
                    obj-path
                    bin-path
                    false)
                  1)]
              [(SourceToolCommandOk)
                (begin
                  (print-string
                    (string-append "Generated: " (string-append bin-path "\n")))
                  (source-tool-clean-temp
                    temp-dir
                    asm-path
                    obj-path
                    bin-path
                    false)
                  0)])])])))

(define (source-tool-build-source
  [source : String]
  [output : String]
  [has-output : bool]
  [target : CompilerBackendTarget]
  [stdlib-roots : CompilerLoadRootList]
  [opt-level : i64]) : i64
  (match (source-tool-create-temp-dir "typelisp-build")
    [(OkSourceToolString temp-dir)
      (source-tool-build-source-in-temp
        source
        output
        has-output
        target
        stdlib-roots
        opt-level
        temp-dir)]
    [(ErrSourceToolString message)
      (begin
        (print-error
          (string-append "build: failed to create temp dir: " message))
        1)]))

(define (source-tool-run-executable
  [bin-path : String]
  [runtime-args : ProcessStringList]) : ResultProcessOutput
  (process-output (process-command bin-path runtime-args)))

(define (source-tool-run-source-in-temp
  [source : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : CompilerLoadRootList]
  [runtime-args : ProcessStringList]
  [opt-level : i64]
  [temp-dir : String]) : i64
  (let
    [asm-path : String (source-tool-asm-path temp-dir source)]
    [obj-path : String (source-tool-obj-path temp-dir source target)]
    [bin-path : String (source-tool-temp-bin-path temp-dir source target)]
    (match (source-tool-emit-assembly source target stdlib-roots opt-level)
      [(ErrSourceToolString message)
        (begin
          (print-error message)
          (source-tool-clean-temp temp-dir asm-path obj-path bin-path true)
          1)]
      [(OkSourceToolString asm)
        (match (source-tool-write-file
          asm-path
          asm
          "run: failed to write assembly artifact")
          [(SourceToolCommandErr message)
            (begin
              (print-error message)
              (source-tool-clean-temp temp-dir asm-path obj-path bin-path true)
              1)]
          [(SourceToolCommandOk)
            (match (source-tool-assemble-and-link
              target
              asm-path
              obj-path
              bin-path)
              [(SourceToolCommandErr message)
                (begin
                  (print-error message)
                  (source-tool-clean-temp
                    temp-dir
                    asm-path
                    obj-path
                    bin-path
                    true)
                  1)]
              [(SourceToolCommandOk)
                (match (source-tool-run-executable bin-path runtime-args)
                  [(OkProcessOutput output)
                    (let
                      [status : i64 (process-output-status output)]
                      (begin
                        (source-tool-forward-output output)
                        (source-tool-clean-temp
                          temp-dir
                          asm-path
                          obj-path
                          bin-path
                          true)
                        status))]
                  [(ErrProcessOutput error)
                    (begin
                      (print-error
                        (string-append
                          (string-append
                            "Error: failed to run executable '"
                            bin-path)
                          (string-append
                            (string-append
                              "' for target "
                              (source-tool-target-name target))
                            (string-append ": " (process-error-message error)))))
                      (source-tool-clean-temp
                        temp-dir
                        asm-path
                        obj-path
                        bin-path
                        true)
                      1)])])])])))

(define (source-tool-run-source
  [source : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : CompilerLoadRootList]
  [runtime-args : ProcessStringList]
  [opt-level : i64]) : i64
  (match (source-tool-create-temp-dir "typelisp-run")
    [(OkSourceToolString temp-dir)
      (source-tool-run-source-in-temp
        source
        target
        stdlib-roots
        runtime-args
        opt-level
        temp-dir)]
    [(ErrSourceToolString message)
      (begin
        (print-error (string-append "run: failed to create temp dir: " message))
        1)]))