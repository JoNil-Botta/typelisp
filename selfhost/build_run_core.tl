;; build_run_core.tl - Shared selfhost source build/run execution helpers (#1018).
(import "compiler_driver_core.tl")

(import "../stdlib/env.tl")

(import "../stdlib/fs.tl")

(import "../stdlib/io.tl")

(import "../stdlib/msvc.tl")

(import "../stdlib/process.tl")

(import "../stdlib/string.tl")

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
  (OkSourceToolBackendMode CompilerBackendMode)
  (ErrSourceToolBackendMode String))

(defstruct SourceToolLinkInputs
  (libs ProcessStringList)
  (search-dirs ProcessStringList)
  (raw-args ProcessStringList))

(defenum ResultSourceToolLinkInputs
  (OkSourceToolLinkInputs SourceToolLinkInputs)
  (ErrSourceToolLinkInputs String))

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
  (cond
    [(string-eq value "scalar") (OkSourceToolBackendMode (BackendModeScalar))]
    [(string-eq value "avx2") (OkSourceToolBackendMode (BackendModeAvx2))]
    [(string-eq value "avx512") (OkSourceToolBackendMode (BackendModeAvx512))]
    [else
      (ErrSourceToolBackendMode
        (source-tool-cat3 command ": unknown backend mode " value))]))

(define (source-tool-opt-level-valid? [value : String]) : bool
  (or
    (string-eq value "0")
    (or (string-eq value "1") (or (string-eq value "2") (string-eq value "3")))))

(define (source-tool-flag? [value : String]) : bool
  (and (> (string-length value) 0) (= (string-ref value 0) #-')))

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

(define (source-tool-link-inputs-empty) : SourceToolLinkInputs
  (SourceToolLinkInputs
    (process-args-empty)
    (process-args-empty)
    (process-args-empty)))

;; Wrap a list of fully-resolved archive/object paths (e.g. package dependency
;; static archives, #1155) as link inputs. They are passed verbatim as raw args
;; so both `ld` and MSVC `link.exe` treat them as positional inputs.
(define (source-tool-link-inputs-from-archives [archives : ProcessStringList]) : SourceToolLinkInputs
  (SourceToolLinkInputs (process-args-empty) (process-args-empty) archives))

(define (source-tool-link-inputs-libs [inputs : SourceToolLinkInputs]) : ProcessStringList
  (struct-get inputs libs))

(define (source-tool-link-inputs-search-dirs [inputs : SourceToolLinkInputs]) : ProcessStringList
  (struct-get inputs search-dirs))

(define (source-tool-link-inputs-raw-args [inputs : SourceToolLinkInputs]) : ProcessStringList
  (struct-get inputs raw-args))

(define (source-tool-link-inputs-empty? [inputs : SourceToolLinkInputs]) : bool
  (and
    (= (process-args-count (source-tool-link-inputs-libs inputs)) 0)
    (and
      (= (process-args-count (source-tool-link-inputs-search-dirs inputs)) 0)
      (= (process-args-count (source-tool-link-inputs-raw-args inputs)) 0))))

(define (source-tool-linux-crt-entry?
  [target : CompilerBackendTarget]
  [link-inputs : SourceToolLinkInputs]) : bool
  (match target
    [(BackendTargetLinux) (not (source-tool-link-inputs-empty? link-inputs))]
    [(BackendTargetWindows) false]))

(define (source-tool-link-inputs-add-lib
  [inputs : SourceToolLinkInputs]
  [name : String]) : SourceToolLinkInputs
  (SourceToolLinkInputs
    (source-tool-args-append (source-tool-link-inputs-libs inputs) name)
    (source-tool-link-inputs-search-dirs inputs)
    (source-tool-link-inputs-raw-args inputs)))

(define (source-tool-link-inputs-add-search-dir
  [inputs : SourceToolLinkInputs]
  [dir : String]) : SourceToolLinkInputs
  (SourceToolLinkInputs
    (source-tool-link-inputs-libs inputs)
    (source-tool-args-append (source-tool-link-inputs-search-dirs inputs) dir)
    (source-tool-link-inputs-raw-args inputs)))

(define (source-tool-link-inputs-add-raw-arg
  [inputs : SourceToolLinkInputs]
  [arg-value : String]) : SourceToolLinkInputs
  (SourceToolLinkInputs
    (source-tool-link-inputs-libs inputs)
    (source-tool-link-inputs-search-dirs inputs)
    (source-tool-args-append
      (source-tool-link-inputs-raw-args inputs)
      arg-value)))

(define (source-tool-string-list-contains?
  [items : ProcessStringList]
  [value : String]) : bool
  (match items
    [(ProcessStringNil) false]
    [(ProcessStringCons head rest)
      (or
        (string-eq head value)
        (source-tool-string-list-contains? (box-get rest) value))]))

(define (source-tool-args-append-unique
  [items : ProcessStringList]
  [value : String]) : ProcessStringList
  (if (source-tool-string-list-contains? items value)
    items
    (source-tool-args-append items value)))

(define (source-tool-string-list-merge-unique
  [left : ProcessStringList]
  [right : ProcessStringList]) : ProcessStringList
  (match right
    [(ProcessStringNil) left]
    [(ProcessStringCons head rest)
      (source-tool-string-list-merge-unique
        (source-tool-args-append-unique left head)
        (box-get rest))]))

(define (source-tool-string-list-eq?
  [left : ProcessStringList]
  [right : ProcessStringList]) : bool
  (match left
    [(ProcessStringNil)
      (match right
        [(ProcessStringNil) true]
        [_ false])]
    [(ProcessStringCons left-head left-rest)
      (match right
        [(ProcessStringCons right-head right-rest)
          (and
            (string-eq left-head right-head)
            (source-tool-string-list-eq?
              (box-get left-rest)
              (box-get right-rest)))]
        [_ false])]))

(define (source-tool-link-inputs-merge
  [left : SourceToolLinkInputs]
  [right : SourceToolLinkInputs]) : SourceToolLinkInputs
  (SourceToolLinkInputs
    (source-tool-string-list-merge-unique
      (source-tool-link-inputs-libs left)
      (source-tool-link-inputs-libs right))
    (source-tool-string-list-merge-unique
      (source-tool-link-inputs-search-dirs left)
      (source-tool-link-inputs-search-dirs right))
    (source-tool-string-list-merge-unique
      (source-tool-link-inputs-raw-args left)
      (source-tool-link-inputs-raw-args right))))

(define (source-tool-link-inputs-add-ast
  [inputs : SourceToolLinkInputs]
  [item : AstExternLinkInput]) : SourceToolLinkInputs
  (match item
    [(AstExternLinkLib name)
      (SourceToolLinkInputs
        (source-tool-args-append-unique
          (source-tool-link-inputs-libs inputs)
          name)
        (source-tool-link-inputs-search-dirs inputs)
        (source-tool-link-inputs-raw-args inputs))]
    [(AstExternLinkSearch dir)
      (SourceToolLinkInputs
        (source-tool-link-inputs-libs inputs)
        (source-tool-args-append-unique
          (source-tool-link-inputs-search-dirs inputs)
          dir)
        (source-tool-link-inputs-raw-args inputs))]
    [(AstExternLinkArg arg-value)
      (SourceToolLinkInputs
        (source-tool-link-inputs-libs inputs)
        (source-tool-link-inputs-search-dirs inputs)
        (source-tool-args-append-unique
          (source-tool-link-inputs-raw-args inputs)
          arg-value))]))

(define (source-tool-link-inputs-add-ast-list
  [inputs : SourceToolLinkInputs]
  [items : AstExternLinkInputList]) : SourceToolLinkInputs
  (match items
    [(AstExternLinkInputNil) inputs]
    [(AstExternLinkInputCons head rest)
      (let
        [rest : AstExternLinkInputList (box-get rest)]
        (source-tool-link-inputs-add-ast-list
          (source-tool-link-inputs-add-ast inputs head)
          rest))]))

(define (source-tool-link-inputs-eq?
  [left : SourceToolLinkInputs]
  [right : SourceToolLinkInputs]) : bool
  (and
    (source-tool-string-list-eq?
      (source-tool-link-inputs-libs left)
      (source-tool-link-inputs-libs right))
    (and
      (source-tool-string-list-eq?
        (source-tool-link-inputs-search-dirs left)
        (source-tool-link-inputs-search-dirs right))
      (source-tool-string-list-eq?
        (source-tool-link-inputs-raw-args left)
        (source-tool-link-inputs-raw-args right)))))

(define (source-tool-link-inputs-dedupe-smoke-ok?) : bool
  (let
    [metadata-items : AstExternLinkInputList
      (ast-extern-link-input-cons
        (AstExternLinkLib "m")
        (ast-extern-link-input-cons
          (AstExternLinkLib "m")
          (ast-extern-link-input-cons
            (AstExternLinkSearch "native")
            (ast-extern-link-input-cons
              (AstExternLinkArg "-Wl,a")
              AstExternLinkInputNil))))]
    [metadata-inputs : SourceToolLinkInputs
      (source-tool-link-inputs-add-ast-list
        (source-tool-link-inputs-empty)
        metadata-items)]
    [explicit-inputs : SourceToolLinkInputs
      (source-tool-link-inputs-add-raw-arg
        (source-tool-link-inputs-add-raw-arg
          (source-tool-link-inputs-add-search-dir
            (source-tool-link-inputs-add-search-dir
              (source-tool-link-inputs-add-lib
                (source-tool-link-inputs-add-lib
                  (source-tool-link-inputs-empty)
                  "m")
                "z")
              "native")
            "cli")
          "-Wl,a")
        "-Wl,b")]
    [expected : SourceToolLinkInputs
      (SourceToolLinkInputs
        (process-args-cons "m" (process-args-cons "z" (process-args-empty)))
        (process-args-cons
          "native"
          (process-args-cons "cli" (process-args-empty)))
        (process-args-cons
          "-Wl,a"
          (process-args-cons "-Wl,b" (process-args-empty))))]
    (source-tool-link-inputs-eq?
      (source-tool-link-inputs-merge metadata-inputs explicit-inputs)
      expected)))

(define (source-tool-link-inputs-from-decls
  [decls : AstDeclList]
  [inputs : SourceToolLinkInputs]) : SourceToolLinkInputs
  (match decls
    [(AstDeclNil) inputs]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclExtern _ _ metadata _)
            (source-tool-link-inputs-from-decls
              rest
              (source-tool-link-inputs-add-ast-list
                inputs
                (ast-extern-metadata-link-inputs metadata)))]
          [(AstDeclUnsafe inner-box)
            (let
              [inner : AstDecl (box-get inner-box)]
              (source-tool-link-inputs-from-decls
                (ast-decl-cons inner rest)
                inputs))]
          [_ (source-tool-link-inputs-from-decls rest inputs)]))]))

(define (source-tool-link-inputs-for-source
  [source : String]
  [stdlib-roots : StringVec]
  [explicit-inputs : SourceToolLinkInputs]) : ResultSourceToolLinkInputs
  (match (compiler-load-file-with-paths-and-roots
    source
    (sym-i64-empty)
    stdlib-roots)
    [(OkCompilerLoadWithPaths decls _ _ _)
      (OkSourceToolLinkInputs
        (source-tool-link-inputs-merge
          (source-tool-link-inputs-from-decls
            decls
            (source-tool-link-inputs-empty))
          explicit-inputs))]
    [(ErrCompilerLoadWithPaths diag)
      (ErrSourceToolLinkInputs (compiler-diagnostic-render diag))]))

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
    (source-tool-fs-path-join dir tool)))

(define (source-tool-fs-path-join [left : String] [right : String]) : String
  (fs-path-join (& left) (& right)))

(define (source-tool-fs-basename [path : String]) : String
  (fs-basename (& path)))

(define (source-tool-try-file-exists? [path : String]) : ResultIoBool
  (try-file-exists? (& path)))

(define (source-tool-try-read-file [path : String]) : ResultIoString
  (try-read-file (& path)))

(define (source-tool-try-remove-file-if-exists [path : String]) : ResultIoUnit
  (try-remove-file-if-exists (& path)))

(define (source-tool-try-remove-dir-if-exists [path : String]) : ResultIoUnit
  (try-remove-dir-if-exists (& path)))

(define (source-tool-stdout-write [text : String]) : unit
  (stdout-write (& text)))

(define (source-tool-stderr-write [text : String]) : unit
  (stderr-write (& text)))

(define (source-tool-path-command-exists? [candidate : String]) : bool
  (match (source-tool-try-file-exists? candidate)
    [(OkIoBool exists) exists]
    [(ErrIoBool _) false]))

(define (source-tool-windows-host?) : bool
  (string-eq (env-path-separator) ";"))

(define (source-tool-windows-exe-candidate [candidate : String]) : String
  (if (source-tool-windows-host?)
    (string-append candidate ".exe")
    candidate))

(define (source-tool-find-command-on-path
  [tool : String]
  [paths : EnvStringList]) : String
  (match paths
    [(EnvStringNil) tool]
    [(EnvStringCons dir rest)
      (let
        [candidate : String (source-tool-path-entry-command dir tool)]
        (if (source-tool-path-command-exists? candidate)
          candidate
          (let
            [exe-candidate : String
              (source-tool-windows-exe-candidate candidate)]
            (if (and
              (not (string-eq exe-candidate candidate))
              (source-tool-path-command-exists? exe-candidate))
              exe-candidate
              (source-tool-find-command-on-path tool (box-get rest))))))]))

(define (source-tool-resolve-command [tool : String]) : String
  (if (source-tool-has-path-separator? tool)
    tool
    (let
      [name : String "PATH"]
      (match (env-path-list (& name))
        [(EnvSomeStringList paths)
          (source-tool-find-command-on-path tool paths)]
        [(EnvNoStringList) tool]))))

(define (source-tool-env-command-or-default
  [name : String]
  [default-command : String]) : String
  (match (env-get (& name))
    [(EnvSomeString value)
      (if (string-eq value "")
        default-command
        value)]
    [(EnvNoString) default-command]))

(define (source-tool-resolved-env-command-or-default
  [name : String]
  [default-command : String]) : String
  (source-tool-resolve-command
    (source-tool-env-command-or-default name default-command)))

(define (source-tool-env-command-set? [name : String]) : bool
  (match (env-get (& name))
    [(EnvSomeString value) (not (string-eq value ""))]
    [(EnvNoString) false]))

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
  (source-tool-replace-extension (source-tool-fs-basename source) ""))

(define (source-tool-asm-path [temp-dir : String] [source : String]) : String
  (source-tool-fs-path-join
    temp-dir
    (string-append (source-tool-artifact-stem source) ".s")))

(define (source-tool-obj-path
  [temp-dir : String]
  [source : String]
  [target : CompilerBackendTarget]) : String
  (source-tool-fs-path-join
    temp-dir
    (string-append
      (source-tool-artifact-stem source)
      (string-append "." (source-tool-object-extension target)))))

(define (source-tool-temp-bin-path
  [temp-dir : String]
  [source : String]
  [target : CompilerBackendTarget]) : String
  (source-tool-fs-path-join
    temp-dir
    (string-append
      (source-tool-artifact-stem source)
      (source-tool-executable-extension target))))

(define (source-tool-create-temp-dir [prefix : String]) : ResultSourceToolString
  (match (try-create-temp-dir (& prefix))
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
  [stdlib-roots : StringVec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [link-inputs : SourceToolLinkInputs]) : ResultSourceToolString
  (match (source-tool-try-read-file source)
    [(ErrIoString error)
      (ErrSourceToolString
        (source-tool-cannot-read-module-message source error))]
    [(OkIoString _)
      (match (compiler-driver-emit-file-with-target-roots-level-mode-and-crt
        source
        target
        true
        stdlib-roots
        opt-level
        mode
        (source-tool-linux-crt-entry? target link-inputs))
        [(OkCompilerDriver asm)
          (OkSourceToolString
            (source-tool-augment-assembly-for-target asm target))]
        [(ErrCompilerDriver diag)
          (ErrSourceToolString (compiler-diagnostic-render diag))])]))

(define (source-tool-emit-package-assembly
  [source : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : StringVec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [manifest-dir : String]
  [package-owner : String]
  [deps : CompilerPkgDeps]
  [emit-entry : bool]
  [crt-entry : bool]) : ResultSourceToolString
  (match (source-tool-try-read-file source)
    [(ErrIoString error)
      (ErrSourceToolString
        (source-tool-cannot-read-module-message source error))]
    [(OkIoString _)
      (match (compiler-driver-emit-package-file-with-target-roots-level-mode-and-crt
        source
        target
        true
        stdlib-roots
        opt-level
        mode
        manifest-dir
        package-owner
        deps
        emit-entry
        crt-entry)
        [(OkCompilerDriver asm)
          (OkSourceToolString
            (source-tool-augment-assembly-for-target asm target))]
        [(ErrCompilerDriver diag)
          (ErrSourceToolString (compiler-diagnostic-render diag))])]))

(define (source-tool-noexecstack-note) : String
  "
    .section .note.GNU-stack,\"\",@progbits
")

(define (source-tool-augment-assembly-for-target
  [asm : String]
  [target : CompilerBackendTarget]) : String
  (let
    [haystack : String asm]
    [needle : String ".note.GNU-stack"]
    (if (compiler-backend-target-linux? target)
      (if (string-contains (& haystack) (& needle))
        haystack
        (string-append haystack (source-tool-noexecstack-note)))
      haystack)))

(define (source-tool-write-file
  [path : String]
  [contents : String]
  [context : String]) : SourceToolCommandStatus
  (match (try-write-file (& path) (& contents))
    [(OkIoUnit) SourceToolCommandOk]
    [(ErrIoUnit error)
      (SourceToolCommandErr
        (source-tool-cat3 context ": " (io-error-message error)))]))

(define (source-tool-forward-output [output : ProcessOutput]) : unit
  (begin
    (source-tool-stdout-write (process-output-stdout output))
    (source-tool-stderr-write (process-output-stderr output))))

(define (source-tool-run-command
  [role : String]
  [target : CompilerBackendTarget]
  [command : ProcessCommand]) : SourceToolCommandStatus
  (let
    [tool : String (process-command-executable command)]
    [command-to-run : ProcessCommand
      (source-tool-command-for-target target command)]
    (match (process-output command-to-run)
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

(define (source-tool-command-for-target
  [target : CompilerBackendTarget]
  [command : ProcessCommand]) : ProcessCommand
  command)

(define (source-tool-windows-args-contain-space? [args : ProcessStringList]) : bool
  (match args
    [(ProcessStringNil) false]
    [(ProcessStringCons head rest)
      (let
        [text : String head]
        (or
          (process-string-contains-char? (& text) #\space')
          (source-tool-windows-args-contain-space? (box-get rest))))]))

(define (source-tool-windows-command-needs-cmd? [command : ProcessCommand]) : bool
  (let
    [text : String (process-command-executable command)]
    (or
      (process-string-contains-char? (& text) #\space')
      (source-tool-windows-args-contain-space? (process-command-argv command)))))

(define (source-tool-windows-cmd-quote [value : String]) : String
  (string-append "\"" (string-append value "\"")))

(define (source-tool-windows-cmd-args [args : ProcessStringList]) : String
  (match args
    [(ProcessStringNil) ""]
    [(ProcessStringCons head rest)
      (string-append
        " "
        (string-append
          (source-tool-windows-cmd-quote head)
          (source-tool-windows-cmd-args (box-get rest))))]))

(define (source-tool-windows-cmd-line [command : ProcessCommand]) : String
  (string-append
    (string-append
      "call "
      (source-tool-windows-cmd-quote (process-command-executable command)))
    (source-tool-windows-cmd-args (process-command-argv command))))

(define (source-tool-windows-command-shell) : String
  (source-tool-env-command-or-default "COMSPEC" "cmd.exe"))

(define (source-tool-windows-cmd-command [command : ProcessCommand]) : ProcessCommand
  (process-command-full
    (source-tool-windows-command-shell)
    (process-args-cons
      "/C"
      (process-args-single (source-tool-windows-cmd-line command)))
    (process-command-cwd command)
    (process-command-env command)
    (process-command-stdin command)))

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

(define (source-tool-linux-link-search-args [dirs : ProcessStringList]) : ProcessStringList
  (match dirs
    [(ProcessStringNil) (process-args-empty)]
    [(ProcessStringCons dir rest)
      (process-args-cons
        (string-append "-L" dir)
        (source-tool-linux-link-search-args (box-get rest)))]))

(define (source-tool-linux-link-lib-args [libs : ProcessStringList]) : ProcessStringList
  (match libs
    [(ProcessStringNil) (process-args-empty)]
    [(ProcessStringCons name rest)
      (process-args-cons
        (string-append "-l" name)
        (source-tool-linux-link-lib-args (box-get rest)))]))

(define (source-tool-link-inputs-linux-args [inputs : SourceToolLinkInputs]) : ProcessStringList
  (process-args-append
    (source-tool-linux-link-search-args
      (source-tool-link-inputs-search-dirs inputs))
    (process-args-append
      (source-tool-linux-link-lib-args (source-tool-link-inputs-libs inputs))
      (source-tool-link-inputs-raw-args inputs))))

(define (source-tool-linker-command
  [obj-path : String]
  [bin-path : String]
  [link-inputs : SourceToolLinkInputs]) : ProcessCommand
  (if (source-tool-link-inputs-empty? link-inputs)
    ;; No native link inputs: the runtime is pure syscalls and the backend
    ;; emits its own libc-ABI shims, so link a freestanding static binary with
    ;; no `-lc` and no dynamic loader. Programs that opt into native libraries
    ;; (the non-empty branch below) still go through `cc`.
    (process-command
      (source-tool-resolve-command "ld")
      (process-args-cons
        "-static"
        (process-args-cons
          obj-path
          (process-args-cons
            "-o"
            (process-args-cons bin-path (process-args-empty))))))
    (process-command
      (source-tool-env-command-or-default
        "TYPELISP_LINUX_CC"
        (source-tool-env-command-or-default
          "CC"
          (source-tool-resolve-command "cc")))
      (process-args-cons
        "-no-pie"
        (process-args-cons
          obj-path
          (process-args-cons
            "-o"
            (process-args-cons
              bin-path
              (source-tool-link-inputs-linux-args link-inputs))))))))

;; Freestanding Win32: no CRT (no vcruntime140/ucrt/msvcrt) and only kernel32.
;; The backend emits its own entry (_tl_start) plus kernel32-backed shims for the
;; CRT-ABI symbols the runtime/stdlib reference. Stdlib random seeding uses
;; kernel32 FFI only, so no advapi32; no COM (ole32/oleaut32) is needed either.
(define (source-tool-windows-link-libs) : ProcessStringList
  (process-args-cons "kernel32.lib" (process-args-empty)))

(define (source-tool-windows-stack-reserve-arg) : String
  "/STACK:268435456")

(define (source-tool-windows-link-search-args [dirs : ProcessStringList]) : ProcessStringList
  (match dirs
    [(ProcessStringNil) (process-args-empty)]
    [(ProcessStringCons dir rest)
      (process-args-cons
        (string-append "/LIBPATH:" dir)
        (source-tool-windows-link-search-args (box-get rest)))]))

(define (source-tool-windows-link-lib-args [libs : ProcessStringList]) : ProcessStringList
  (match libs
    [(ProcessStringNil) (process-args-empty)]
    [(ProcessStringCons name rest)
      (process-args-cons
        (string-append name ".lib")
        (source-tool-windows-link-lib-args (box-get rest)))]))

(define (source-tool-link-inputs-windows-args [inputs : SourceToolLinkInputs]) : ProcessStringList
  (process-args-append
    (source-tool-windows-link-search-args
      (source-tool-link-inputs-search-dirs inputs))
    (process-args-append
      (source-tool-windows-link-lib-args (source-tool-link-inputs-libs inputs))
      (source-tool-link-inputs-raw-args inputs))))

(define (source-tool-windows-linker-args
  [obj-path : String]
  [bin-path : String]
  [link-inputs : SourceToolLinkInputs]) : ProcessStringList
  (process-args-cons
    "/NOLOGO"
    (process-args-cons
      obj-path
      (process-args-cons
        (string-append "/OUT:" bin-path)
        (process-args-cons
          "/SUBSYSTEM:CONSOLE"
          (process-args-cons
            "/ENTRY:_tl_start"
            (process-args-cons
              "/NODEFAULTLIB"
              (process-args-cons
                "/DYNAMICBASE:NO"
                (process-args-cons
                  (source-tool-windows-stack-reserve-arg)
                  (process-args-append
                    (source-tool-link-inputs-windows-args link-inputs)
                    (source-tool-windows-link-libs)))))))))))

(define (source-tool-windows-stack-reserve-smoke-ok?) : bool
  (source-tool-string-list-contains?
    (source-tool-windows-linker-args
      "input.obj"
      "output.exe"
      (source-tool-link-inputs-empty))
    (source-tool-windows-stack-reserve-arg)))

(define (source-tool-windows-linker-fallback-command
  [obj-path : String]
  [bin-path : String]
  [link-inputs : SourceToolLinkInputs]) : ProcessCommand
  (process-command
    (source-tool-resolved-env-command-or-default
      "TYPELISP_WINDOWS_LINK"
      (source-tool-resolve-command "lld-link"))
    (source-tool-windows-linker-args obj-path bin-path link-inputs)))

(define (source-tool-windows-linker-command
  [obj-path : String]
  [bin-path : String]
  [link-inputs : SourceToolLinkInputs]) : ResultSourceToolCommand
  (if (source-tool-env-command-set? "TYPELISP_WINDOWS_LINK")
    (OkSourceToolCommand
      (source-tool-windows-linker-fallback-command
        obj-path
        bin-path
        link-inputs))
    (let
      [target : String "x86_64-pc-windows-msvc"]
      [tool : String "link.exe"]
      (match (msvc-find-tool (& target) (& tool))
        [(OkMsvcTool resolved-tool)
          (OkSourceToolCommand
            (process-command-with-env-list
              (process-command
                (msvc-tool-executable resolved-tool)
                (source-tool-windows-linker-args obj-path bin-path link-inputs))
              (msvc-tool-process-env resolved-tool)))]
        [(ErrMsvcTool _)
          (OkSourceToolCommand
            (source-tool-windows-linker-fallback-command
              obj-path
              bin-path
              link-inputs))]))))

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

(define (source-tool-windows-archiver-fallback-command
  [obj-path : String]
  [archive-path : String]) : ProcessCommand
  (process-command
    (source-tool-resolved-env-command-or-default
      "TYPELISP_WINDOWS_LIB"
      (source-tool-resolve-command "llvm-lib"))
    (source-tool-windows-archiver-args obj-path archive-path)))

(define (source-tool-windows-archiver-command
  [obj-path : String]
  [archive-path : String]) : ResultSourceToolCommand
  (if (source-tool-env-command-set? "TYPELISP_WINDOWS_LIB")
    (OkSourceToolCommand
      (source-tool-windows-archiver-fallback-command obj-path archive-path))
    (let
      [target : String "x86_64-pc-windows-msvc"]
      [tool : String "lib.exe"]
      (match (msvc-find-tool (& target) (& tool))
        [(OkMsvcTool resolved-tool)
          (OkSourceToolCommand
            (process-command-with-env-list
              (process-command
                (msvc-tool-executable resolved-tool)
                (source-tool-windows-archiver-args obj-path archive-path))
              (msvc-tool-process-env resolved-tool)))]
        [(ErrMsvcTool _)
          (OkSourceToolCommand
            (source-tool-windows-archiver-fallback-command
              obj-path
              archive-path))]))))

(define (source-tool-clean-temp
  [temp-dir : String]
  [asm-path : String]
  [obj-path : String]
  [bin-path : String]
  [remove-bin : bool]) : unit
  (begin
    (source-tool-try-remove-file-if-exists asm-path)
    (source-tool-try-remove-file-if-exists obj-path)
    (if remove-bin
      (source-tool-try-remove-file-if-exists bin-path)
      OkIoUnit)
    (source-tool-try-remove-dir-if-exists temp-dir)
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
  [bin-path : String]
  [link-inputs : SourceToolLinkInputs]) : SourceToolCommandStatus
  (match target
    [(BackendTargetLinux)
      (source-tool-run-command
        "linker"
        target
        (source-tool-linker-command obj-path bin-path link-inputs))]
    [(BackendTargetWindows)
      (match (source-tool-windows-linker-command obj-path bin-path link-inputs)
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
  [bin-path : String]
  [link-inputs : SourceToolLinkInputs]) : SourceToolCommandStatus
  (match (source-tool-assemble target asm-path obj-path)
    [(SourceToolCommandOk)
      (source-tool-link target obj-path bin-path link-inputs)]
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
  [stdlib-roots : StringVec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [link-inputs : SourceToolLinkInputs]
  [temp-dir : String]) : i64
  (let
    [asm-path : String (source-tool-asm-path temp-dir source)]
    [obj-path : String (source-tool-obj-path temp-dir source target)]
    [bin-path : String
      (if has-output
        output
        (source-tool-default-output source target))]
    (match (source-tool-link-inputs-for-source source stdlib-roots link-inputs)
      [(ErrSourceToolLinkInputs message)
        (begin
          (print-error message)
          (source-tool-clean-temp temp-dir asm-path obj-path bin-path false)
          1)]
      [(OkSourceToolLinkInputs effective-link-inputs)
        (match (source-tool-emit-assembly
          source
          target
          stdlib-roots
          opt-level
          mode
          effective-link-inputs)
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
                  (source-tool-clean-temp
                    temp-dir
                    asm-path
                    obj-path
                    bin-path
                    false)
                  1)]
              [(SourceToolCommandOk)
                (match (source-tool-assemble-and-link
                  target
                  asm-path
                  obj-path
                  bin-path
                  effective-link-inputs)
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
                        (string-append "Built " (string-append bin-path "\n")))
                      (source-tool-clean-temp
                        temp-dir
                        asm-path
                        obj-path
                        bin-path
                        false)
                      0)])])])])))

(define (source-tool-build-source
  [source : String]
  [output : String]
  [has-output : bool]
  [target : CompilerBackendTarget]
  [stdlib-roots : StringVec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [link-inputs : SourceToolLinkInputs]) : i64
  (match (source-tool-create-temp-dir "typelisp-build")
    [(OkSourceToolString temp-dir)
      (source-tool-build-source-in-temp
        source
        output
        has-output
        target
        stdlib-roots
        opt-level
        mode
        link-inputs
        temp-dir)]
    [(ErrSourceToolString message)
      (begin
        (print-error
          (string-append "build: failed to create temp dir: " message))
        1)]))

(define (source-tool-run-executable
  [bin-path : String]
  [target : CompilerBackendTarget]
  [runtime-args : ProcessStringList]) : ResultProcessOutput
  (process-output
    (source-tool-command-for-target
      target
      (process-command bin-path runtime-args))))

(define (source-tool-run-source-in-temp
  [source : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : StringVec]
  [runtime-args : ProcessStringList]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [link-inputs : SourceToolLinkInputs]
  [temp-dir : String]) : i64
  (let
    [asm-path : String (source-tool-asm-path temp-dir source)]
    [obj-path : String (source-tool-obj-path temp-dir source target)]
    [bin-path : String (source-tool-temp-bin-path temp-dir source target)]
    (match (source-tool-link-inputs-for-source source stdlib-roots link-inputs)
      [(ErrSourceToolLinkInputs message)
        (begin
          (print-error message)
          (source-tool-clean-temp temp-dir asm-path obj-path bin-path true)
          1)]
      [(OkSourceToolLinkInputs effective-link-inputs)
        (match (source-tool-emit-assembly
          source
          target
          stdlib-roots
          opt-level
          mode
          effective-link-inputs)
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
                  (source-tool-clean-temp
                    temp-dir
                    asm-path
                    obj-path
                    bin-path
                    true)
                  1)]
              [(SourceToolCommandOk)
                (match (source-tool-assemble-and-link
                  target
                  asm-path
                  obj-path
                  bin-path
                  effective-link-inputs)
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
                    (match (source-tool-run-executable
                      bin-path
                      target
                      runtime-args)
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
                                (string-append
                                  ": "
                                  (process-error-message error)))))
                          (source-tool-clean-temp
                            temp-dir
                            asm-path
                            obj-path
                            bin-path
                            true)
                          1)])])])])])))

(define (source-tool-run-source
  [source : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : StringVec]
  [runtime-args : ProcessStringList]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [link-inputs : SourceToolLinkInputs]) : i64
  (match (source-tool-create-temp-dir "typelisp-run")
    [(OkSourceToolString temp-dir)
      (source-tool-run-source-in-temp
        source
        target
        stdlib-roots
        runtime-args
        opt-level
        mode
        link-inputs
        temp-dir)]
    [(ErrSourceToolString message)
      (begin
        (print-error (string-append "run: failed to create temp dir: " message))
        1)]))