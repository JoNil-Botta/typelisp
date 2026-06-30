;; build_run_core.tl - Shared selfhost source build/run execution helpers (#1018).
(import "compiler_driver_core.tl")
(import "compiler_object_coff.tl")
(import "compiler_object_elf.tl")
(import stdlib.env)
(import stdlib.fs)
(import stdlib.io)
(import stdlib.msvc)
(import stdlib.process)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.vector)

(defenum SourceToolCommandStatus
  (Ok)
  (Err String))

(defenum ResultSourceToolCommand
  (Ok process.ProcessCommand)
  (Err String))

(defenum ResultSourceToolString
  (Ok String)
  (Err String))

(defenum SourceToolDirectObjectStatus
  (Ok)
  (Unavailable String)
  (Err String))

(defenum ResultSourceToolTarget
  (Ok CompilerBackendTarget)
  (Err String))

(defenum ResultSourceToolBackendMode
  (Ok CompilerBackendMode)
  (Err String))

(defstruct SourceToolLinkInputs
  (libs process.ProcessStringList)
  (search-dirs process.ProcessStringList)
  (raw-args process.ProcessStringList))

(defenum ResultSourceToolLinkInputs
  (Ok SourceToolLinkInputs)
  (Err String))

(define (source-tool-cfg-names-to-env-from
  [cfg-names : vector.StringVec]
  [index : i64]
  [env : SymI64Env]) : SymI64Env
  (if (>= index (vector.string-vec-len cfg-names))
    env
    (source-tool-cfg-names-to-env-from
      cfg-names
      (+ index 1)
      (compiler-cfg-enable env (vector.string-vec-get cfg-names index "")))))

(define (source-tool-cfg-names-to-env [cfg-names : vector.StringVec]) : SymI64Env
  (source-tool-cfg-names-to-env-from cfg-names 0 (compiler-cfg-empty)))

(define (source-tool-target-name [target : CompilerBackendTarget]) : String
  (match target
    [(CompilerBackendTarget.Linux) "linux-x86_64"]
    [(CompilerBackendTarget.Windows) "windows-x86_64"]))

(define (source-tool-default-target) : CompilerBackendTarget
  (if (string.eq (env.env-path-separator) ";")
    (CompilerBackendTarget.Windows)
    (CompilerBackendTarget.Linux)))

(define (source-tool-default-target-name) : String
  (source-tool-target-name (source-tool-default-target)))

(define (source-tool-target [value : String]) : ResultSourceToolTarget
  (if (or (string.eq value "linux-x86_64") (string.eq value "linux_x86_64"))
    (ResultSourceToolTarget.Ok (CompilerBackendTarget.Linux))
    (if (or
      (string.eq value "windows-x86_64")
      (string.eq value "windows_x86_64"))
      (ResultSourceToolTarget.Ok (CompilerBackendTarget.Windows))
      (ResultSourceToolTarget.Err (string.append "unknown target " value)))))

(define (source-tool-target-supported? [target : CompilerBackendTarget]) : bool
  (match target
    [(CompilerBackendTarget.Linux) true]
    [(CompilerBackendTarget.Windows) true]))

(define (source-tool-backend-mode [command : String] [value : String]) : ResultSourceToolBackendMode
  (cond
    [(string.eq value "scalar")
      (ResultSourceToolBackendMode.Ok (CompilerBackendMode.Scalar))]
    [(string.eq value "avx2")
      (ResultSourceToolBackendMode.Ok (CompilerBackendMode.Avx2))]
    [(string.eq value "avx512")
      (ResultSourceToolBackendMode.Ok (CompilerBackendMode.Avx512))]
    [else
      (ResultSourceToolBackendMode.Err
        (str_cat.str-cat command ": unknown backend mode " value))]))

(define (source-tool-opt-level-valid? [value : String]) : bool
  (or (string.eq value "0") (string.eq value "1") (string.eq value "2")))

(define (source-tool-flag? [value : String]) : bool
  (and (> (string.string-length value) 0) (= (string.string-ref value 0) '-')))

(define (source-tool-args-append
  [args : process.ProcessStringList]
  [value : String]) : process.ProcessStringList
  (process.args-append args (process.args-single value)))

(define (source-tool-command5
  [executable : String]
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]) : process.ProcessCommand
  (process.command
    executable
    (source-tool-args-append
      (source-tool-args-append
        (source-tool-args-append
          (source-tool-args-append
            (source-tool-args-append (process.args-empty) a)
            b)
          c)
        d)
      e)))

(define (source-tool-command6
  [executable : String]
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]
  [f : String]) : process.ProcessCommand
  (process.command
    executable
    (source-tool-args-append
      (source-tool-args-append
        (source-tool-args-append
          (source-tool-args-append
            (source-tool-args-append
              (source-tool-args-append (process.args-empty) a)
              b)
            c)
          d)
        e)
      f)))

(define (source-tool-command7
  [executable : String]
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]
  [f : String]
  [g : String]) : process.ProcessCommand
  (process.command
    executable
    (source-tool-args-append
      (source-tool-args-append
        (source-tool-args-append
          (source-tool-args-append
            (source-tool-args-append
              (source-tool-args-append
                (source-tool-args-append (process.args-empty) a)
                b)
              c)
            d)
          e)
        f)
      g)))

(define (source-tool-git-executable) : String
  (source-tool-resolve-command "git"))

(define (source-tool-git-clone-command [remote : String] [root : String]) : process.ProcessCommand
  (source-tool-command5
    (source-tool-git-executable)
    "-c"
    "core.longpaths=true"
    "clone"
    remote
    root))

(define (source-tool-git-checkout-command
  [root : String]
  [checkout-ref : String]) : process.ProcessCommand
  (source-tool-command7
    (source-tool-git-executable)
    "-c"
    "core.longpaths=true"
    "-C"
    root
    "checkout"
    "--detach"
    checkout-ref))

(define (source-tool-git-rev-parse-command [root : String]) : process.ProcessCommand
  (source-tool-command6
    (source-tool-git-executable)
    "-c"
    "core.longpaths=true"
    "-C"
    root
    "rev-parse"
    "HEAD"))

(define (source-tool-args-from-argv
  [idx : i64]
  [count : i64]
  [args : process.ProcessStringList]) : process.ProcessStringList
  (if (>= idx count)
    args
    (source-tool-args-from-argv
      (+ idx 1)
      count
      (source-tool-args-append args (io.arg idx)))))

(define (source-tool-link-inputs-empty) : SourceToolLinkInputs
  (SourceToolLinkInputs
    (process.args-empty)
    (process.args-empty)
    (process.args-empty)))

;; Wrap a list of fully-resolved archive/object paths (e.g. package dependency
;; static archives, #1155) as link inputs. They are passed verbatim as raw args
;; so both `ld` and MSVC `link.exe` treat them as positional inputs.
(define (source-tool-link-inputs-from-archives
  [archives : process.ProcessStringList]) : SourceToolLinkInputs
  (SourceToolLinkInputs (process.args-empty) (process.args-empty) archives))

(define (source-tool-link-inputs-libs [inputs : SourceToolLinkInputs]) : process.ProcessStringList
  (struct-get inputs libs))

(define (source-tool-link-inputs-search-dirs [inputs : SourceToolLinkInputs]) : process.ProcessStringList
  (struct-get inputs search-dirs))

(define (source-tool-link-inputs-raw-args [inputs : SourceToolLinkInputs]) : process.ProcessStringList
  (struct-get inputs raw-args))

(define (source-tool-link-inputs-empty? [inputs : SourceToolLinkInputs]) : bool
  (and
    (= (process.args-count (source-tool-link-inputs-libs inputs)) 0)
    (= (process.args-count (source-tool-link-inputs-search-dirs inputs)) 0)
    (= (process.args-count (source-tool-link-inputs-raw-args inputs)) 0)))

(define (source-tool-linux-crt-entry?
  [target : CompilerBackendTarget]
  [link-inputs : SourceToolLinkInputs]) : bool
  (match target
    [(CompilerBackendTarget.Linux)
      (not (source-tool-link-inputs-empty? link-inputs))]
    [(CompilerBackendTarget.Windows) false]))

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
  [items : process.ProcessStringList]
  [value : String]) : bool
  (match items
    [(process.ProcessStringNil) false]
    [(process.ProcessStringCons head rest)
      (or
        (string.eq head value)
        (source-tool-string-list-contains? (box-get rest) value))]))

(define (source-tool-args-append-unique
  [items : process.ProcessStringList]
  [value : String]) : process.ProcessStringList
  (if (source-tool-string-list-contains? items value)
    items
    (source-tool-args-append items value)))

(define (source-tool-string-list-merge-unique
  [left : process.ProcessStringList]
  [right : process.ProcessStringList]) : process.ProcessStringList
  (match right
    [(process.ProcessStringNil) left]
    [(process.ProcessStringCons head rest)
      (source-tool-string-list-merge-unique
        (source-tool-args-append-unique left head)
        (box-get rest))]))

(define (source-tool-string-list-eq?
  [left : process.ProcessStringList]
  [right : process.ProcessStringList]) : bool
  (match left
    [(process.ProcessStringNil)
      (match right
        [(process.ProcessStringNil) true]
        [_ false])]
    [(process.ProcessStringCons left-head left-rest)
      (match right
        [(process.ProcessStringCons right-head right-rest)
          (and
            (string.eq left-head right-head)
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
    (source-tool-string-list-eq?
      (source-tool-link-inputs-search-dirs left)
      (source-tool-link-inputs-search-dirs right))
    (source-tool-string-list-eq?
      (source-tool-link-inputs-raw-args left)
      (source-tool-link-inputs-raw-args right))))

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
        (process.args-cons "m" (process.args-cons "z" (process.args-empty)))
        (process.args-cons
          "native"
          (process.args-cons "cli" (process.args-empty)))
        (process.args-cons
          "-Wl,a"
          (process.args-cons "-Wl,b" (process.args-empty))))]
    (source-tool-link-inputs-eq?
      (source-tool-link-inputs-merge metadata-inputs explicit-inputs)
      expected)))

(define (source-tool-link-inputs-from-decls
  [decls : AstDeclList]
  [inputs : SourceToolLinkInputs]) : SourceToolLinkInputs
  (match decls
    [(AstDeclList.Nil) inputs]
    [(AstDeclList.Cons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDecl.Extern _ _ metadata _)
            (source-tool-link-inputs-from-decls
              rest
              (source-tool-link-inputs-add-ast-list
                inputs
                (ast-extern-metadata-link-inputs metadata)))]
          [(AstDecl.Unsafe inner-box)
            (let
              [inner : AstDecl (box-get inner-box)]
              (source-tool-link-inputs-from-decls
                (ast-decl-cons inner rest)
                inputs))]
          [_ (source-tool-link-inputs-from-decls rest inputs)]))]))

(define (source-tool-link-inputs-for-source
  [source : String]
  [stdlib-roots : vector.StringVec]
  [cfgs : SymI64Env]
  [explicit-inputs : SourceToolLinkInputs]) : ResultSourceToolLinkInputs
  (match (compiler-load-file-with-paths-and-roots-cfg
    source
    (sym-i64-empty)
    stdlib-roots
    cfgs)
    [(ResultCompilerLoadWithPaths.Ok decls _ _ _)
      (ResultSourceToolLinkInputs.Ok
        (source-tool-link-inputs-merge
          (source-tool-link-inputs-from-decls
            decls
            (source-tool-link-inputs-empty))
          explicit-inputs))]
    [(ResultCompilerLoadWithPaths.Err diag)
      (ResultSourceToolLinkInputs.Err
        (compiler-diagnostic-render (box-get diag)))]))

(define (source-tool-path-separator? [c : char]) : bool
  (or (= c '/') (= c '\\')))

(define (source-tool-has-path-separator? [path : String]) : bool
  (let
    [n : i64 (string.string-length path)]
    [i : i64 0]
    [found : bool false]
    (begin
      (while (and (< i n) (not found))
        (begin
          (if (source-tool-path-separator? (string.string-ref path i))
            (set! found true)
            unit)
          (set! i (+ i 1))))
      found)))

(define (source-tool-path-entry-command [dir : String] [tool : String]) : String
  (if (= (string.string-length dir) 0)
    tool
    (source-tool-fs-path-join dir tool)))

(define (source-tool-fs-path-join [left : String] [right : String]) : String
  (fs.fs-path-join (& left) (& right)))

(define (source-tool-fs-basename [path : String]) : String
  (fs.fs-basename (& path)))

(define (source-tool-try-file-exists? [path : String]) : io.ResultIoBool
  (io.try-file-exists? (& path)))

(define (source-tool-try-read-file [path : String]) : io.ResultIoString
  (io.try-read-file (& path)))

(define (source-tool-try-remove-file-if-exists [path : String]) : io.ResultIoUnit
  (fs.try-remove-file-if-exists (& path)))

(define (source-tool-try-remove-dir-if-exists [path : String]) : io.ResultIoUnit
  (fs.try-remove-dir-if-exists (& path)))

(define (source-tool-stdout-write [text : String]) : unit
  (io.stdout-write (& text)))

(define (source-tool-stderr-write [text : String]) : unit
  (io.stderr-write (& text)))

(define (source-tool-path-command-exists? [candidate : String]) : bool
  (match (source-tool-try-file-exists? candidate)
    [(io.OkIoBool exists) exists]
    [(io.ErrIoBool _) false]))

(define (source-tool-windows-host?) : bool
  (string.eq (env.env-path-separator) ";"))

(define (source-tool-windows-exe-candidate [candidate : String]) : String
  (if (source-tool-windows-host?)
    (string.append candidate ".exe")
    candidate))

(define (source-tool-find-command-on-path
  [tool : String]
  [paths : vector.StringVec]
  [index : i64]) : String
  (if (>= index (vector.string-vec-len paths))
    tool
    (let
      [dir : String (vector.string-vec-get paths index "")]
      [candidate : String (source-tool-path-entry-command dir tool)]
      (if (source-tool-path-command-exists? candidate)
        candidate
        (let
          [exe-candidate : String (source-tool-windows-exe-candidate candidate)]
          (if (and
            (not (string.eq exe-candidate candidate))
            (source-tool-path-command-exists? exe-candidate))
            exe-candidate
            (source-tool-find-command-on-path tool paths (+ index 1))))))))

(define (source-tool-resolve-command [tool : String]) : String
  (if (source-tool-has-path-separator? tool)
    tool
    (let
      [name : String "PATH"]
      (match (env.env-path-list-vec (& name))
        [(env.EnvSomeStringVec paths)
          (source-tool-find-command-on-path tool paths 0)]
        [(env.EnvNoStringVec) tool]))))

(define (source-tool-env-command-or-default
  [name : String]
  [default-command : String]) : String
  (match (env.env-get (& name))
    [(env.EnvSomeString value)
      (if (string.eq value "")
        default-command
        value)]
    [(env.EnvNoString) default-command]))

(define (source-tool-resolved-env-command-or-default
  [name : String]
  [default-command : String]) : String
  (source-tool-resolve-command
    (source-tool-env-command-or-default name default-command)))

(define (source-tool-env-command-set? [name : String]) : bool
  (match (env.env-get (& name))
    [(env.EnvSomeString value) (not (string.eq value ""))]
    [(env.EnvNoString) false]))

(define (source-tool-replace-extension
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
            (if (source-tool-path-separator? c)
              (set! last-sep i)
              (set! last-sep last-sep))
            (set! i (+ i 1)))))
      (if (> last-dot last-sep)
        (str_cat.str-cat (string.substring input-path 0 last-dot) extension)
        (str_cat.str-cat input-path extension)))))

(define (source-tool-default-output
  [source : String]
  [target : CompilerBackendTarget]) : String
  (match target
    [(CompilerBackendTarget.Linux) (source-tool-replace-extension source "")]
    [(CompilerBackendTarget.Windows)
      (source-tool-replace-extension source ".exe")]))

(define (source-tool-object-extension [target : CompilerBackendTarget]) : String
  (match target
    [(CompilerBackendTarget.Linux) "o"]
    [(CompilerBackendTarget.Windows) "obj"]))

(define (source-tool-executable-extension [target : CompilerBackendTarget]) : String
  (match target
    [(CompilerBackendTarget.Linux) ""]
    [(CompilerBackendTarget.Windows) ".exe"]))

(define (source-tool-static-library-extension [target : CompilerBackendTarget]) : String
  (match target
    [(CompilerBackendTarget.Linux) ".a"]
    [(CompilerBackendTarget.Windows) ".lib"]))

(define (source-tool-static-library-filename
  [name : String]
  [target : CompilerBackendTarget]) : String
  (match target
    [(CompilerBackendTarget.Linux)
      (str_cat.str-cat "lib" name (source-tool-static-library-extension target))]
    [(CompilerBackendTarget.Windows)
      (str_cat.str-cat name (source-tool-static-library-extension target))]))

(define (source-tool-artifact-stem [source : String]) : String
  (source-tool-replace-extension (source-tool-fs-basename source) ""))

(define (source-tool-asm-path [temp-dir : String] [source : String]) : String
  (source-tool-fs-path-join
    temp-dir
    (str_cat.str-cat (source-tool-artifact-stem source) ".s")))

(define (source-tool-obj-path
  [temp-dir : String]
  [source : String]
  [target : CompilerBackendTarget]) : String
  (source-tool-fs-path-join
    temp-dir
    (str_cat.str-cat
      (source-tool-artifact-stem source)
      "."
      (source-tool-object-extension target))))

(define (source-tool-temp-bin-path
  [temp-dir : String]
  [source : String]
  [target : CompilerBackendTarget]) : String
  (source-tool-fs-path-join
    temp-dir
    (str_cat.str-cat
      (source-tool-artifact-stem source)
      (source-tool-executable-extension target))))

(define (source-tool-create-temp-dir [prefix : String]) : ResultSourceToolString
  (match (fs.try-create-temp-dir (& prefix))
    [(io.OkIoString path) (ResultSourceToolString.Ok path)]
    [(io.ErrIoString error)
      (ResultSourceToolString.Err (io.io-error-message error))]))

(define (source-tool-cannot-read-module-message
  [source : String]
  [error : io.IoError]) : String
  (str_cat.str-cat
    "Error: cannot read module '"
    source
    "': "
    (io.io-error-message error)))

(define (source-tool-emit-assembly
  [source : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : vector.StringVec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : SymI64Env]
  [link-inputs : SourceToolLinkInputs]) : ResultSourceToolString
  (match (source-tool-try-read-file source)
    [(io.ErrIoString error)
      (ResultSourceToolString.Err
        (source-tool-cannot-read-module-message source error))]
    [(io.OkIoString _)
      (match (compiler-driver-emit-file-with-target-roots-level-mode-cfg-and-crt
        source
        target
        true
        stdlib-roots
        opt-level
        mode
        cfgs
        (source-tool-linux-crt-entry? target link-inputs))
        [(ResultCompilerDriver.Ok asm)
          (ResultSourceToolString.Ok
            (source-tool-augment-assembly-for-target asm target))]
        [(ResultCompilerDriver.Err diag)
          (ResultSourceToolString.Err
            (compiler-diagnostic-render (box-get diag)))])]))

(define (source-tool-emit-package-assembly
  [source : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : vector.StringVec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [manifest-dir : String]
  [package-owner : String]
  [deps : CompilerPkgDeps]
  [emit-entry : bool]
  [crt-entry : bool]) : ResultSourceToolString
  (match (source-tool-try-read-file source)
    [(io.ErrIoString error)
      (ResultSourceToolString.Err
        (source-tool-cannot-read-module-message source error))]
    [(io.OkIoString _)
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
        [(ResultCompilerDriver.Ok asm)
          (ResultSourceToolString.Ok
            (source-tool-augment-assembly-for-target asm target))]
        [(ResultCompilerDriver.Err diag)
          (ResultSourceToolString.Err
            (compiler-diagnostic-render (box-get diag)))])]))

(define (source-tool-linux-direct-object-env-name) : String
  "TYPELISP_LINUX_DIRECT_OBJECT")

(define (source-tool-linux-direct-object-enabled?) : bool
  (source-tool-env-command-set? (source-tool-linux-direct-object-env-name)))

(define (source-tool-linux-direct-object-linkable?
  [image : CompilerObjectImage]) : bool
  (and
    (compiler-object-elf-image-supported? image)
    (or
      (compiler-object-symbol-list-contains?
        (struct-get image symbols)
        "_tl_start"
        (CompilerObjectSymbolBinding.Export)
        (CompilerObjectSymbolKind.Function))
      (compiler-object-symbol-list-contains?
        (struct-get image symbols)
        "main"
        (CompilerObjectSymbolBinding.Export)
        (CompilerObjectSymbolKind.Function)))
    (>
      (compiler-object-elf-section-raw-size
        image
        (CompilerObjectSectionKind.Text))
      0)))

(define (source-tool-linux-direct-object-archivable?
  [image : CompilerObjectImage]) : bool
  (compiler-object-elf-image-supported? image))

(define (source-tool-linux-direct-object-unavailable-message) : String
  "linux direct object unavailable: object image lacks encoded .text or entry symbol")

(define (source-tool-linux-direct-object-archive-unavailable-message) : String
  "linux direct object unavailable: object image has unsupported ELF records")

(define (source-tool-render-linkable-linux-elf-object
  [image : CompilerObjectImage]) : ResultSourceToolString
  (if (source-tool-linux-direct-object-linkable? image)
    (match (compiler-object-elf-render image)
      [(ResultCompilerObjectElf.Ok obj) (ResultSourceToolString.Ok obj)]
      [(ResultCompilerObjectElf.Err message)
        (ResultSourceToolString.Err message)])
    (ResultSourceToolString.Err
      (source-tool-linux-direct-object-unavailable-message))))

(define (source-tool-render-archivable-linux-elf-object
  [image : CompilerObjectImage]) : ResultSourceToolString
  (if (source-tool-linux-direct-object-archivable? image)
    (match (compiler-object-elf-render image)
      [(ResultCompilerObjectElf.Ok obj) (ResultSourceToolString.Ok obj)]
      [(ResultCompilerObjectElf.Err message)
        (ResultSourceToolString.Err message)])
    (ResultSourceToolString.Err
      (source-tool-linux-direct-object-archive-unavailable-message))))

(define (source-tool-emit-linux-elf-object
  [source : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : vector.StringVec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : SymI64Env]
  [link-inputs : SourceToolLinkInputs]) : ResultSourceToolString
  (match target
    [(CompilerBackendTarget.Linux)
      (match (source-tool-try-read-file source)
        [(io.ErrIoString error)
          (ResultSourceToolString.Err
            (source-tool-cannot-read-module-message source error))]
        [(io.OkIoString _)
          (match (compiler-driver-emit-file-object-image-with-target-roots-level-mode-cfg-and-crt
            source
            target
            true
            stdlib-roots
            opt-level
            mode
            cfgs
            (source-tool-linux-crt-entry? target link-inputs))
            [(ResultCompilerDriverObject.Ok image)
              (source-tool-render-linkable-linux-elf-object image)]
            [(ResultCompilerDriverObject.Err diag)
              (ResultSourceToolString.Err
                (compiler-diagnostic-render (box-get diag)))])])]
    [(CompilerBackendTarget.Windows)
      (ResultSourceToolString.Err
        "direct ELF object emission is only available for linux-x86_64")]))

(define (source-tool-emit-lowered-linux-elf-object
  [source : String]
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [target : CompilerBackendTarget]
  [opt-level : i64]
  [link-inputs : SourceToolLinkInputs]) : ResultSourceToolString
  (match target
    [(CompilerBackendTarget.Linux)
      (match (compiler-driver-emit-lowered-object-image-with-level-mode-entry-and-crt
        source
        program
        spans
        target
        true
        (CompilerBackendMode.Scalar)
        opt-level
        true
        (source-tool-linux-crt-entry? target link-inputs))
        [(ResultCompilerDriverObject.Ok image)
          (source-tool-render-linkable-linux-elf-object image)]
        [(ResultCompilerDriverObject.Err diag)
          (ResultSourceToolString.Err
            (compiler-diagnostic-render (box-get diag)))])]
    [(CompilerBackendTarget.Windows)
      (ResultSourceToolString.Err
        "direct ELF object emission is only available for linux-x86_64")]))

(define (source-tool-windows-direct-object-env-name) : String
  "TYPELISP_WINDOWS_DIRECT_OBJECT")

(define (source-tool-windows-direct-object-enabled?) : bool
  (source-tool-env-command-set? (source-tool-windows-direct-object-env-name)))

(define (source-tool-windows-direct-object-extern-linkable?
  [name : String]
  [kind : CompilerObjectSymbolKind]) : bool
  (and
    (compiler-object-symbol-kind-eq? kind (CompilerObjectSymbolKind.Function))
    (or
      (string.eq name "ExitProcess")
      (string.eq name "GetCommandLineA")
      (string.eq name "GetStdHandle")
      (string.eq name "WriteFile")
      (string.eq name "VirtualAlloc")
      (string.eq name "VirtualFree"))))

(define (source-tool-windows-direct-object-relocation-target-linkable?
  [symbols : CompilerObjectSymbolList]
  [target : String]) : bool
  (let
    [count : i64 (compiler-object-symbol-list-count symbols)]
    [index : i64 0]
    [ok : bool true]
    [done : bool false]
    (begin
      (while (and (not done) (< index count))
        (match (compiler-object-symbol-list-ref symbols index)
          [(CompilerObjectSymbol.Symbol name binding kind _)
            (if (string.eq name target)
              (begin
                (match binding
                  [(CompilerObjectSymbolBinding.Extern)
                    (set!
                      ok
                      (source-tool-windows-direct-object-extern-linkable?
                        name
                        kind))]
                  [_ (set! ok true)])
                (set! done true))
              (set! index (+ index 1)))]))
      ok)))

(define (source-tool-windows-direct-object-relocations-linkable?
  [symbols : CompilerObjectSymbolList]
  [relocs : CompilerObjectRelocationList]) : bool
  (let
    [count : i64 (compiler-object-relocation-list-count relocs)]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (match (compiler-object-relocation-list-ref relocs index)
          [(CompilerObjectRelocation.Relocation _ _ _ target)
            (if (source-tool-windows-direct-object-relocation-target-linkable?
              symbols
              target)
              (set! index (+ index 1))
              (set! ok false))]))
      ok)))

(define (source-tool-windows-direct-object-linkable?
  [image : CompilerObjectImage]) : bool
  (and
    (compiler-object-coff-image-supported? image)
    (source-tool-windows-direct-object-relocations-linkable?
      (struct-get image symbols)
      (struct-get image relocations))
    (compiler-object-symbol-list-contains?
      (struct-get image symbols)
      "_tl_start"
      (CompilerObjectSymbolBinding.Export)
      (CompilerObjectSymbolKind.Function))
    ;; Text labels live in the instruction stream, not the section data records.
    (>=
      (compiler-object-coff-section-label-offset
        image
        (CompilerObjectSectionKind.Text)
        "tl_setup_argv")
      0)
    (>
      (compiler-object-coff-section-raw-size
        image
        (CompilerObjectSectionKind.Text))
      0)))

(define (source-tool-windows-direct-object-unavailable-message) : String
  "windows direct object unavailable: object image lacks encoded .text, _tl_start, or Windows runtime entry body")

(define (source-tool-render-linkable-windows-coff-object
  [image : CompilerObjectImage]) : ResultSourceToolString
  (if (source-tool-windows-direct-object-linkable? image)
    (match (compiler-object-coff-render image)
      [(ResultCompilerObjectCoff.Ok obj) (ResultSourceToolString.Ok obj)]
      [(ResultCompilerObjectCoff.Err message)
        (ResultSourceToolString.Err message)])
    (ResultSourceToolString.Err
      (source-tool-windows-direct-object-unavailable-message))))

(define (source-tool-emit-windows-coff-object
  [source : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : vector.StringVec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : SymI64Env]
  [link-inputs : SourceToolLinkInputs]) : ResultSourceToolString
  (match target
    [(CompilerBackendTarget.Linux)
      (ResultSourceToolString.Err
        "direct COFF object emission is only available for windows-x86_64")]
    [(CompilerBackendTarget.Windows)
      (match (source-tool-try-read-file source)
        [(io.ErrIoString error)
          (ResultSourceToolString.Err
            (source-tool-cannot-read-module-message source error))]
        [(io.OkIoString _)
          (match (compiler-driver-emit-file-object-image-with-target-roots-level-mode-cfg-and-crt
            source
            target
            true
            stdlib-roots
            opt-level
            mode
            cfgs
            (source-tool-linux-crt-entry? target link-inputs))
            [(ResultCompilerDriverObject.Ok image)
              (source-tool-render-linkable-windows-coff-object image)]
            [(ResultCompilerDriverObject.Err diag)
              (ResultSourceToolString.Err
                (compiler-diagnostic-render (box-get diag)))])])]))

(define (source-tool-emit-lowered-windows-coff-object
  [source : String]
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [target : CompilerBackendTarget]
  [opt-level : i64]) : ResultSourceToolString
  (match target
    [(CompilerBackendTarget.Linux)
      (ResultSourceToolString.Err
        "direct COFF object emission is only available for windows-x86_64")]
    [(CompilerBackendTarget.Windows)
      (match (compiler-driver-emit-lowered-object-image-with-level-mode-entry-and-crt
        source
        program
        spans
        target
        true
        (CompilerBackendMode.Scalar)
        opt-level
        true
        false)
        [(ResultCompilerDriverObject.Ok image)
          (source-tool-render-linkable-windows-coff-object image)]
        [(ResultCompilerDriverObject.Err diag)
          (ResultSourceToolString.Err
            (compiler-diagnostic-render (box-get diag)))])]))

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
      (if (string.contains (& haystack) (& needle))
        haystack
        (string.append haystack (source-tool-noexecstack-note)))
      haystack)))

(define (source-tool-write-file
  [path : String]
  [contents : String]
  [context : String]) : SourceToolCommandStatus
  (match (io.try-write-file (& path) (& contents))
    [(io.OkIoUnit) SourceToolCommandStatus.Ok]
    [(io.ErrIoUnit error)
      (SourceToolCommandStatus.Err
        (str_cat.str-cat context ": " (io.io-error-message error)))]))

(define (source-tool-forward-output [output : process.ProcessOutput]) : unit
  (begin
    (source-tool-stdout-write (process.output-stdout output))
    (source-tool-stderr-write (process.output-stderr output))))

(define (source-tool-run-command
  [role : String]
  [target : CompilerBackendTarget]
  [command : process.ProcessCommand]) : SourceToolCommandStatus
  (let
    [tool : String (process.command-executable command)]
    [command-to-run : process.ProcessCommand
      (source-tool-command-for-target target command)]
    (match (process.output command-to-run)
      [(process.OkProcessOutput output)
        (begin
          (source-tool-forward-output output)
          (if (process.success? output)
            SourceToolCommandStatus.Ok
            (SourceToolCommandStatus.Err
              (str_cat.str-cat
                "Error: "
                role
                " '"
                tool
                "' failed for target "
                (source-tool-target-name target)
                " with status "
                (string.int->string (process.output-status output))))))]
      [(process.ErrProcessOutput error)
        (SourceToolCommandStatus.Err
          (str_cat.str-cat
            "Error: failed to run "
            role
            " '"
            tool
            "' for target "
            (source-tool-target-name target)
            ": "
            (process.error-message error)))])))

(define (source-tool-command-for-target
  [_target : CompilerBackendTarget]
  [command : process.ProcessCommand]) : process.ProcessCommand
  command)

(define (source-tool-windows-args-contain-space?
  [args : process.ProcessStringList]) : bool
  (match args
    [(process.ProcessStringNil) false]
    [(process.ProcessStringCons head rest)
      (let
        [text : String head]
        (or
          (process.string-contains-char? (& text) ' ')
          (source-tool-windows-args-contain-space? (box-get rest))))]))

(define (source-tool-windows-command-needs-cmd?
  [command : process.ProcessCommand]) : bool
  (let
    [text : String (process.command-executable command)]
    (or
      (process.string-contains-char? (& text) ' ')
      (source-tool-windows-args-contain-space? (process.command-argv command)))))

(define (source-tool-windows-cmd-quote [value : String]) : String
  (str_cat.str-cat "\"" value "\""))

(define (source-tool-windows-cmd-args [args : process.ProcessStringList]) : String
  (match args
    [(process.ProcessStringNil) ""]
    [(process.ProcessStringCons head rest)
      (str_cat.str-cat
        " "
        (source-tool-windows-cmd-quote head)
        (source-tool-windows-cmd-args (box-get rest)))]))

(define (source-tool-windows-cmd-line [command : process.ProcessCommand]) : String
  (str_cat.str-cat
    "call "
    (source-tool-windows-cmd-quote (process.command-executable command))
    (source-tool-windows-cmd-args (process.command-argv command))))

(define (source-tool-windows-command-shell) : String
  (source-tool-env-command-or-default "COMSPEC" "cmd.exe"))

(define (source-tool-windows-cmd-command [command : process.ProcessCommand]) : process.ProcessCommand
  (process.command-full
    (source-tool-windows-command-shell)
    (process.args-cons
      "/C"
      (process.args-single (source-tool-windows-cmd-line command)))
    (process.command-cwd command)
    (process.command-env command)
    (process.command-stdin command)))

(define (source-tool-assembler-command [asm-path : String] [obj-path : String]) : process.ProcessCommand
  (process.command
    (source-tool-resolve-command "as")
    (process.args-cons
      asm-path
      (process.args-cons "-o" (process.args-cons obj-path (process.args-empty))))))

(define (source-tool-windows-assembler-command
  [asm-path : String]
  [obj-path : String]) : process.ProcessCommand
  (process.command
    (source-tool-env-command-or-default
      "TYPELISP_WINDOWS_CLANG"
      (source-tool-resolve-command "clang"))
    (process.args-cons
      "--target=x86_64-pc-windows-msvc"
      (process.args-cons
        "-c"
        (process.args-cons
          asm-path
          (process.args-cons
            "-o"
            (process.args-cons obj-path (process.args-empty))))))))

(define (source-tool-linux-link-search-args [dirs : process.ProcessStringList]) : process.ProcessStringList
  (match dirs
    [(process.ProcessStringNil) (process.args-empty)]
    [(process.ProcessStringCons dir rest)
      (process.args-cons
        (string.append "-L" dir)
        (source-tool-linux-link-search-args (box-get rest)))]))

(define (source-tool-linux-link-lib-args [libs : process.ProcessStringList]) : process.ProcessStringList
  (match libs
    [(process.ProcessStringNil) (process.args-empty)]
    [(process.ProcessStringCons name rest)
      (process.args-cons
        (string.append "-l" name)
        (source-tool-linux-link-lib-args (box-get rest)))]))

(define (source-tool-link-inputs-linux-args [inputs : SourceToolLinkInputs]) : process.ProcessStringList
  (process.args-append
    (source-tool-linux-link-search-args
      (source-tool-link-inputs-search-dirs inputs))
    (process.args-append
      (source-tool-linux-link-lib-args (source-tool-link-inputs-libs inputs))
      (source-tool-link-inputs-raw-args inputs))))

(define (source-tool-linker-command
  [obj-path : String]
  [bin-path : String]
  [link-inputs : SourceToolLinkInputs]) : process.ProcessCommand
  (if (source-tool-link-inputs-empty? link-inputs)
    ;; No native link inputs: the runtime is pure syscalls and the backend
    ;; emits its own libc-ABI shims, so link a freestanding static binary with
    ;; no `-lc` and no dynamic loader. Programs that opt into native libraries
    ;; (the non-empty branch below) still go through `cc`.
    (process.command
      (source-tool-resolve-command "ld")
      (process.args-cons
        "-static"
        (process.args-cons
          "-e"
          (process.args-cons
            "_tl_start"
            (process.args-cons
              obj-path
              (process.args-cons
                "-o"
                (process.args-cons bin-path (process.args-empty))))))))
    (process.command
      (source-tool-env-command-or-default
        "TYPELISP_LINUX_CC"
        (source-tool-env-command-or-default
          "CC"
          (source-tool-resolve-command "cc")))
      (process.args-cons
        "-no-pie"
        (process.args-cons
          obj-path
          (process.args-cons
            "-o"
            (process.args-cons
              bin-path
              (source-tool-link-inputs-linux-args link-inputs))))))))

;; Freestanding Win32: no CRT (no vcruntime140/ucrt/msvcrt) and only kernel32.
;; The backend emits its own entry (_tl_start) plus kernel32-backed shims for the
;; CRT-ABI symbols the runtime/stdlib reference. Stdlib random seeding uses
;; kernel32 FFI only, so no advapi32; no COM (ole32/oleaut32) is needed either.
(define (source-tool-windows-link-libs) : process.ProcessStringList
  (process.args-cons "kernel32.lib" (process.args-empty)))

;; Keep this in sync with scripts/lib-native-link.sh's NL_WINDOWS_STACK_RESERVE.
;; The selfhost backend still needs more than 64MB on Windows for compiler-sized
;; sources such as src/doc_test.tl.
(define (source-tool-windows-stack-reserve-arg) : String
  "/STACK:134217728")

(define (source-tool-windows-link-search-args
  [dirs : process.ProcessStringList]) : process.ProcessStringList
  (match dirs
    [(process.ProcessStringNil) (process.args-empty)]
    [(process.ProcessStringCons dir rest)
      (process.args-cons
        (string.append "/LIBPATH:" dir)
        (source-tool-windows-link-search-args (box-get rest)))]))

(define (source-tool-windows-link-lib-args [libs : process.ProcessStringList]) : process.ProcessStringList
  (match libs
    [(process.ProcessStringNil) (process.args-empty)]
    [(process.ProcessStringCons name rest)
      (process.args-cons
        (string.append name ".lib")
        (source-tool-windows-link-lib-args (box-get rest)))]))

(define (source-tool-link-inputs-windows-args [inputs : SourceToolLinkInputs]) : process.ProcessStringList
  (process.args-append
    (source-tool-windows-link-search-args
      (source-tool-link-inputs-search-dirs inputs))
    (process.args-append
      (source-tool-windows-link-lib-args (source-tool-link-inputs-libs inputs))
      (source-tool-link-inputs-raw-args inputs))))

(define (source-tool-windows-linker-args
  [obj-path : String]
  [bin-path : String]
  [link-inputs : SourceToolLinkInputs]) : process.ProcessStringList
  (process.args-cons
    "/NOLOGO"
    (process.args-cons
      obj-path
      (process.args-cons
        (string.append "/OUT:" bin-path)
        (process.args-cons
          "/SUBSYSTEM:CONSOLE"
          (process.args-cons
            "/ENTRY:_tl_start"
            (process.args-cons
              "/NODEFAULTLIB"
              (process.args-cons
                "/DYNAMICBASE:NO"
                (process.args-cons
                  (source-tool-windows-stack-reserve-arg)
                  (process.args-append
                    (source-tool-link-inputs-windows-args link-inputs)
                    (source-tool-windows-link-libs)))))))))))

(define (source-tool-windows-stack-reserve-smoke-ok?) : bool
  (source-tool-string-list-contains?
    (source-tool-windows-linker-args
      "input.obj"
      "output.exe"
      (source-tool-link-inputs-empty))
    (source-tool-windows-stack-reserve-arg)))

(define (source-tool-linux-direct-object-linkability-smoke-ok?) : bool
  (match (compiler-backend-emit-source-object-image-for-target
    "(define answer : i64 40)
(define (inc [x : i64]) : i64 (+ x 1))
(define (main) : i64 (inc answer))"
    (CompilerBackendTarget.Linux))
    [(ResultCompilerBackendObject.Ok image)
      (if (source-tool-linux-direct-object-linkable? image)
        (match (source-tool-render-linkable-linux-elf-object image)
          [(ResultSourceToolString.Ok obj) (> (string.string-length obj) 0)]
          [(ResultSourceToolString.Err _) false])
        false)]
    [(ResultCompilerBackendObject.Err _) false]))

(define (source-tool-windows-direct-object-linkability-smoke-ok?) : bool
  (match (compiler-backend-emit-source-object-image-for-target
    "(define (main) : i64 0)"
    (CompilerBackendTarget.Windows))
    [(ResultCompilerBackendObject.Ok image)
      (if (source-tool-windows-direct-object-linkable? image)
        (match (source-tool-render-linkable-windows-coff-object image)
          [(ResultSourceToolString.Ok obj) (> (string.string-length obj) 0)]
          [(ResultSourceToolString.Err _) false])
        false)]
    [(ResultCompilerBackendObject.Err _) false]))

(define (source-tool-windows-direct-object-runtime-fallback-smoke-ok?) : bool
  (match (compiler-backend-emit-source-object-image-for-target
    "(define (main) : i64
  (let [items : (Array i64) (make-array i64 1)]
    (array-length items)))"
    (CompilerBackendTarget.Windows))
    [(ResultCompilerBackendObject.Ok image)
      (not (source-tool-windows-direct-object-linkable? image))]
    [(ResultCompilerBackendObject.Err _) false]))

(define (source-tool-windows-direct-object-relocation-gate-smoke-ok?) : bool
  (let
    [symbols : CompilerObjectSymbolList
      (compiler-object-symbol-cons
        (CompilerObjectSymbol.Symbol
          "GetStdHandle"
          (CompilerObjectSymbolBinding.Extern)
          (CompilerObjectSymbolKind.Function)
          CompilerObjectMaybeSection.No)
        (compiler-object-symbol-cons
          (CompilerObjectSymbol.Symbol
            "GetCurrentProcessId"
            (CompilerObjectSymbolBinding.Extern)
            (CompilerObjectSymbolKind.Function)
            CompilerObjectMaybeSection.No)
          CompilerObjectSymbolList.Nil))]
    [allowed-relocs : CompilerObjectRelocationList
      (compiler-object-relocation-cons
        (CompilerObjectRelocation.Relocation
          (CompilerObjectSectionKind.Text)
          "main"
          (CompilerObjectRelocationKind.Call)
          "GetStdHandle")
        CompilerObjectRelocationList.Nil)]
    [blocked-relocs : CompilerObjectRelocationList
      (compiler-object-relocation-cons
        (CompilerObjectRelocation.Relocation
          (CompilerObjectSectionKind.Text)
          "main"
          (CompilerObjectRelocationKind.Call)
          "GetCurrentProcessId")
        CompilerObjectRelocationList.Nil)]
    (and
      (source-tool-windows-direct-object-relocations-linkable?
        symbols
        CompilerObjectRelocationList.Nil)
      (source-tool-windows-direct-object-relocations-linkable?
        symbols
        allowed-relocs)
      (not
        (source-tool-windows-direct-object-relocations-linkable?
          symbols
          blocked-relocs)))))

(define (source-tool-windows-linker-fallback-command
  [obj-path : String]
  [bin-path : String]
  [link-inputs : SourceToolLinkInputs]) : process.ProcessCommand
  (process.command
    (source-tool-resolved-env-command-or-default
      "TYPELISP_WINDOWS_LINK"
      (source-tool-resolve-command "lld-link"))
    (source-tool-windows-linker-args obj-path bin-path link-inputs)))

(define (source-tool-windows-linker-command
  [obj-path : String]
  [bin-path : String]
  [link-inputs : SourceToolLinkInputs]) : ResultSourceToolCommand
  (if (source-tool-env-command-set? "TYPELISP_WINDOWS_LINK")
    (ResultSourceToolCommand.Ok
      (source-tool-windows-linker-fallback-command
        obj-path
        bin-path
        link-inputs))
    (let
      [target : String "x86_64-pc-windows-msvc"]
      [tool : String "link.exe"]
      (match (msvc.msvc-find-tool (& target) (& tool))
        [(msvc.OkMsvcTool resolved-tool)
          (ResultSourceToolCommand.Ok
            (process.command-with-env-list
              (process.command
                (msvc.msvc-tool-executable resolved-tool)
                (source-tool-windows-linker-args obj-path bin-path link-inputs))
              (msvc.msvc-tool-process-env resolved-tool)))]
        [(msvc.ErrMsvcTool _)
          (ResultSourceToolCommand.Ok
            (source-tool-windows-linker-fallback-command
              obj-path
              bin-path
              link-inputs))]))))

(define (source-tool-archiver-command
  [obj-path : String]
  [archive-path : String]) : process.ProcessCommand
  (process.command
    (source-tool-resolve-command "ar")
    (process.args-cons
      "rcs"
      (process.args-cons
        archive-path
        (process.args-cons obj-path (process.args-empty))))))

(define (source-tool-windows-archiver-args
  [obj-path : String]
  [archive-path : String]) : process.ProcessStringList
  (process.args-cons
    "/NOLOGO"
    (process.args-cons
      (string.append "/OUT:" archive-path)
      (process.args-cons obj-path (process.args-empty)))))

(define (source-tool-windows-archiver-fallback-command
  [obj-path : String]
  [archive-path : String]) : process.ProcessCommand
  (process.command
    (source-tool-resolved-env-command-or-default
      "TYPELISP_WINDOWS_LIB"
      (source-tool-resolve-command "llvm-lib"))
    (source-tool-windows-archiver-args obj-path archive-path)))

(define (source-tool-windows-archiver-command
  [obj-path : String]
  [archive-path : String]) : ResultSourceToolCommand
  (if (source-tool-env-command-set? "TYPELISP_WINDOWS_LIB")
    (ResultSourceToolCommand.Ok
      (source-tool-windows-archiver-fallback-command obj-path archive-path))
    (let
      [target : String "x86_64-pc-windows-msvc"]
      [tool : String "lib.exe"]
      (match (msvc.msvc-find-tool (& target) (& tool))
        [(msvc.OkMsvcTool resolved-tool)
          (ResultSourceToolCommand.Ok
            (process.command-with-env-list
              (process.command
                (msvc.msvc-tool-executable resolved-tool)
                (source-tool-windows-archiver-args obj-path archive-path))
              (msvc.msvc-tool-process-env resolved-tool)))]
        [(msvc.ErrMsvcTool _)
          (ResultSourceToolCommand.Ok
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
      io.OkIoUnit)
    (source-tool-try-remove-dir-if-exists temp-dir)
    unit))

(define (source-tool-assemble
  [target : CompilerBackendTarget]
  [asm-path : String]
  [obj-path : String]) : SourceToolCommandStatus
  (match target
    [(CompilerBackendTarget.Linux)
      (source-tool-run-command
        "assembler"
        target
        (source-tool-assembler-command asm-path obj-path))]
    [(CompilerBackendTarget.Windows)
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
    [(CompilerBackendTarget.Linux)
      (source-tool-run-command
        "linker"
        target
        (source-tool-linker-command obj-path bin-path link-inputs))]
    [(CompilerBackendTarget.Windows)
      (match (source-tool-windows-linker-command obj-path bin-path link-inputs)
        [(ResultSourceToolCommand.Ok command)
          (source-tool-run-command "linker" target command)]
        [(ResultSourceToolCommand.Err message)
          (SourceToolCommandStatus.Err message)])]))

(define (source-tool-archive
  [target : CompilerBackendTarget]
  [obj-path : String]
  [archive-path : String]) : SourceToolCommandStatus
  (match target
    [(CompilerBackendTarget.Linux)
      (source-tool-run-command
        "archiver"
        target
        (source-tool-archiver-command obj-path archive-path))]
    [(CompilerBackendTarget.Windows)
      (match (source-tool-windows-archiver-command obj-path archive-path)
        [(ResultSourceToolCommand.Ok command)
          (source-tool-run-command "archiver" target command)]
        [(ResultSourceToolCommand.Err message)
          (SourceToolCommandStatus.Err message)])]))

(define (source-tool-assemble-and-link
  [target : CompilerBackendTarget]
  [asm-path : String]
  [obj-path : String]
  [bin-path : String]
  [link-inputs : SourceToolLinkInputs]) : SourceToolCommandStatus
  (match (source-tool-assemble target asm-path obj-path)
    [(SourceToolCommandStatus.Ok)
      (source-tool-link target obj-path bin-path link-inputs)]
    [(SourceToolCommandStatus.Err message)
      (SourceToolCommandStatus.Err message)]))

(define (source-tool-assemble-and-archive
  [target : CompilerBackendTarget]
  [asm-path : String]
  [obj-path : String]
  [archive-path : String]) : SourceToolCommandStatus
  (match (source-tool-assemble target asm-path obj-path)
    [(SourceToolCommandStatus.Ok)
      (source-tool-archive target obj-path archive-path)]
    [(SourceToolCommandStatus.Err message)
      (SourceToolCommandStatus.Err message)]))

(define (source-tool-write-direct-object-and-link
  [obj-path : String]
  [bin-path : String]
  [target : CompilerBackendTarget]
  [link-inputs : SourceToolLinkInputs]
  [obj : String]
  [context : String]) : SourceToolDirectObjectStatus
  (match (source-tool-write-file obj-path obj context)
    [(SourceToolCommandStatus.Err message)
      (SourceToolDirectObjectStatus.Err message)]
    [(SourceToolCommandStatus.Ok)
      (match (source-tool-link target obj-path bin-path link-inputs)
        [(SourceToolCommandStatus.Ok) SourceToolDirectObjectStatus.Ok]
        [(SourceToolCommandStatus.Err message)
          (SourceToolDirectObjectStatus.Err message)])]))

(define (source-tool-write-direct-object-and-archive
  [obj-path : String]
  [archive-path : String]
  [target : CompilerBackendTarget]
  [obj : String]
  [context : String]) : SourceToolDirectObjectStatus
  (match (source-tool-write-file obj-path obj context)
    [(SourceToolCommandStatus.Err message)
      (SourceToolDirectObjectStatus.Err message)]
    [(SourceToolCommandStatus.Ok)
      (match (source-tool-archive target obj-path archive-path)
        [(SourceToolCommandStatus.Ok) SourceToolDirectObjectStatus.Ok]
        [(SourceToolCommandStatus.Err message)
          (SourceToolDirectObjectStatus.Err message)])]))

(define (source-tool-try-windows-direct-object-and-link
  [source : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : vector.StringVec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : SymI64Env]
  [link-inputs : SourceToolLinkInputs]
  [obj-path : String]
  [bin-path : String]) : SourceToolDirectObjectStatus
  (if (and
    (source-tool-windows-direct-object-enabled?)
    (compiler-backend-target-windows? target))
    (match (source-tool-emit-windows-coff-object
      source
      target
      stdlib-roots
      opt-level
      mode
      cfgs
      link-inputs)
      [(ResultSourceToolString.Ok obj)
        (source-tool-write-direct-object-and-link
          obj-path
          bin-path
          target
          link-inputs
          obj
          "source-tool: failed to write direct object artifact")]
      [(ResultSourceToolString.Err message)
        (SourceToolDirectObjectStatus.Unavailable message)])
    (SourceToolDirectObjectStatus.Unavailable "windows direct object disabled")))

(define (source-tool-try-linux-direct-object-and-link
  [source : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : vector.StringVec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : SymI64Env]
  [link-inputs : SourceToolLinkInputs]
  [obj-path : String]
  [bin-path : String]) : SourceToolDirectObjectStatus
  (if (and
    (source-tool-linux-direct-object-enabled?)
    (compiler-backend-target-linux? target))
    (match (source-tool-emit-linux-elf-object
      source
      target
      stdlib-roots
      opt-level
      mode
      cfgs
      link-inputs)
      [(ResultSourceToolString.Ok obj)
        (source-tool-write-direct-object-and-link
          obj-path
          bin-path
          target
          link-inputs
          obj
          "source-tool: failed to write direct object artifact")]
      [(ResultSourceToolString.Err message)
        (SourceToolDirectObjectStatus.Unavailable message)])
    (SourceToolDirectObjectStatus.Unavailable "linux direct object disabled")))

(define (source-tool-try-lowered-windows-direct-object-and-link
  [source : String]
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [target : CompilerBackendTarget]
  [opt-level : i64]
  [link-inputs : SourceToolLinkInputs]
  [obj-path : String]
  [bin-path : String]) : SourceToolDirectObjectStatus
  (if (and
    (source-tool-windows-direct-object-enabled?)
    (compiler-backend-target-windows? target))
    (match (source-tool-emit-lowered-windows-coff-object
      source
      program
      spans
      target
      opt-level)
      [(ResultSourceToolString.Ok obj)
        (source-tool-write-direct-object-and-link
          obj-path
          bin-path
          target
          link-inputs
          obj
          "test: failed to write direct object artifact")]
      [(ResultSourceToolString.Err message)
        (SourceToolDirectObjectStatus.Unavailable message)])
    (SourceToolDirectObjectStatus.Unavailable "windows direct object disabled")))

(define (source-tool-try-lowered-linux-direct-object-and-link
  [source : String]
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [target : CompilerBackendTarget]
  [opt-level : i64]
  [link-inputs : SourceToolLinkInputs]
  [obj-path : String]
  [bin-path : String]) : SourceToolDirectObjectStatus
  (if (and
    (source-tool-linux-direct-object-enabled?)
    (compiler-backend-target-linux? target))
    (match (source-tool-emit-lowered-linux-elf-object
      source
      program
      spans
      target
      opt-level
      link-inputs)
      [(ResultSourceToolString.Ok obj)
        (source-tool-write-direct-object-and-link
          obj-path
          bin-path
          target
          link-inputs
          obj
          "test: failed to write direct object artifact")]
      [(ResultSourceToolString.Err message)
        (SourceToolDirectObjectStatus.Unavailable message)])
    (SourceToolDirectObjectStatus.Unavailable "linux direct object disabled")))

(define (source-tool-write-assembly-and-link
  [target : CompilerBackendTarget]
  [asm-path : String]
  [obj-path : String]
  [bin-path : String]
  [link-inputs : SourceToolLinkInputs]
  [asm : String]
  [write-context : String]) : SourceToolCommandStatus
  (match (source-tool-write-file asm-path asm write-context)
    [(SourceToolCommandStatus.Err message)
      (SourceToolCommandStatus.Err message)]
    [(SourceToolCommandStatus.Ok)
      (source-tool-assemble-and-link
        target
        asm-path
        obj-path
        bin-path
        link-inputs)]))

(define (source-tool-emit-assembly-and-link
  [source : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : vector.StringVec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : SymI64Env]
  [link-inputs : SourceToolLinkInputs]
  [asm-path : String]
  [obj-path : String]
  [bin-path : String]
  [write-context : String]) : SourceToolCommandStatus
  (match (source-tool-emit-assembly
    source
    target
    stdlib-roots
    opt-level
    mode
    cfgs
    link-inputs)
    [(ResultSourceToolString.Err message) (SourceToolCommandStatus.Err message)]
    [(ResultSourceToolString.Ok asm)
      (source-tool-write-assembly-and-link
        target
        asm-path
        obj-path
        bin-path
        link-inputs
        asm
        write-context)]))

(define (source-tool-object-or-assembly-and-link
  [source : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : vector.StringVec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : SymI64Env]
  [link-inputs : SourceToolLinkInputs]
  [asm-path : String]
  [obj-path : String]
  [bin-path : String]
  [write-context : String]) : SourceToolCommandStatus
  (match (source-tool-try-linux-direct-object-and-link
    source
    target
    stdlib-roots
    opt-level
    mode
    cfgs
    link-inputs
    obj-path
    bin-path)
    [(SourceToolDirectObjectStatus.Ok) SourceToolCommandStatus.Ok]
    [(SourceToolDirectObjectStatus.Err message)
      (SourceToolCommandStatus.Err message)]
    [(SourceToolDirectObjectStatus.Unavailable _)
      (match (source-tool-try-windows-direct-object-and-link
        source
        target
        stdlib-roots
        opt-level
        mode
        cfgs
        link-inputs
        obj-path
        bin-path)
        [(SourceToolDirectObjectStatus.Ok) SourceToolCommandStatus.Ok]
        [(SourceToolDirectObjectStatus.Err message)
          (SourceToolCommandStatus.Err message)]
        [(SourceToolDirectObjectStatus.Unavailable _)
          (source-tool-emit-assembly-and-link
            source
            target
            stdlib-roots
            opt-level
            mode
            cfgs
            link-inputs
            asm-path
            obj-path
            bin-path
            write-context)])]))

(define (source-tool-lowered-object-or-assembly-and-link
  [source : String]
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [target : CompilerBackendTarget]
  [opt-level : i64]
  [link-inputs : SourceToolLinkInputs]
  [asm-path : String]
  [obj-path : String]
  [bin-path : String]
  [write-context : String]) : SourceToolCommandStatus
  (match (source-tool-try-lowered-linux-direct-object-and-link
    source
    program
    spans
    target
    opt-level
    link-inputs
    obj-path
    bin-path)
    [(SourceToolDirectObjectStatus.Ok) SourceToolCommandStatus.Ok]
    [(SourceToolDirectObjectStatus.Err message)
      (SourceToolCommandStatus.Err message)]
    [(SourceToolDirectObjectStatus.Unavailable _)
      (match (source-tool-try-lowered-windows-direct-object-and-link
        source
        program
        spans
        target
        opt-level
        link-inputs
        obj-path
        bin-path)
        [(SourceToolDirectObjectStatus.Ok) SourceToolCommandStatus.Ok]
        [(SourceToolDirectObjectStatus.Err message)
          (SourceToolCommandStatus.Err message)]
        [(SourceToolDirectObjectStatus.Unavailable _)
          (match (compiler-driver-emit-lowered-with-level
            source
            program
            spans
            target
            true
            opt-level)
            [(ResultCompilerDriver.Ok asm)
              (source-tool-write-assembly-and-link
                target
                asm-path
                obj-path
                bin-path
                link-inputs
                (source-tool-augment-assembly-for-target asm target)
                write-context)]
            [(ResultCompilerDriver.Err diag)
              (SourceToolCommandStatus.Err
                (compiler-diagnostic-render (box-get diag)))])])]))

(define (source-tool-build-source-in-temp
  [source : String]
  [output : String]
  [has-output : bool]
  [target : CompilerBackendTarget]
  [stdlib-roots : vector.StringVec]
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
    (match (source-tool-link-inputs-for-source
      source
      stdlib-roots
      (compiler-driver-target-cfgs target (compiler-cfg-empty))
      link-inputs)
      [(ResultSourceToolLinkInputs.Err message)
        (begin
          (io.print-error message)
          (source-tool-clean-temp temp-dir asm-path obj-path bin-path false)
          1)]
      [(ResultSourceToolLinkInputs.Ok effective-link-inputs)
        (begin
          (compiler-driver-reset-file-state!)
          (match (source-tool-object-or-assembly-and-link
            source
            target
            stdlib-roots
            opt-level
            mode
            (compiler-cfg-empty)
            effective-link-inputs
            asm-path
            obj-path
            bin-path
            "build: failed to write assembly artifact")
            [(SourceToolCommandStatus.Err message)
              (begin
                (io.print-error message)
                (source-tool-clean-temp
                  temp-dir
                  asm-path
                  obj-path
                  bin-path
                  false)
                1)]
            [(SourceToolCommandStatus.Ok)
              (begin
                (io.print-string
                  (string.append "Built " (string.append bin-path "\n")))
                (source-tool-clean-temp
                  temp-dir
                  asm-path
                  obj-path
                  bin-path
                  false)
                0)]))])))

(define (source-tool-build-source
  [source : String]
  [output : String]
  [has-output : bool]
  [target : CompilerBackendTarget]
  [stdlib-roots : vector.StringVec]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [link-inputs : SourceToolLinkInputs]) : i64
  (match (source-tool-create-temp-dir "typelisp-build")
    [(ResultSourceToolString.Ok temp-dir)
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
    [(ResultSourceToolString.Err message)
      (begin
        (io.print-error
          (string.append "build: failed to create temp dir: " message))
        1)]))

(define (source-tool-run-executable
  [bin-path : String]
  [target : CompilerBackendTarget]
  [runtime-args : process.ProcessStringList]) : process.ResultProcessOutput
  (process.output
    (source-tool-command-for-target
      target
      (process.command bin-path runtime-args))))

(define (source-tool-run-source-in-temp
  [source : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : vector.StringVec]
  [cfg-names : vector.StringVec]
  [runtime-args : process.ProcessStringList]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [link-inputs : SourceToolLinkInputs]
  [temp-dir : String]) : i64
  (let
    [asm-path : String (source-tool-asm-path temp-dir source)]
    [obj-path : String (source-tool-obj-path temp-dir source target)]
    [bin-path : String (source-tool-temp-bin-path temp-dir source target)]
    (match (source-tool-link-inputs-for-source
      source
      stdlib-roots
      (compiler-driver-target-cfgs
        target
        (source-tool-cfg-names-to-env cfg-names))
      link-inputs)
      [(ResultSourceToolLinkInputs.Err message)
        (begin
          (io.print-error message)
          (source-tool-clean-temp temp-dir asm-path obj-path bin-path true)
          1)]
      [(ResultSourceToolLinkInputs.Ok effective-link-inputs)
        (begin
          (compiler-driver-reset-file-state!)
          (match (source-tool-object-or-assembly-and-link
            source
            target
            stdlib-roots
            opt-level
            mode
            (source-tool-cfg-names-to-env cfg-names)
            effective-link-inputs
            asm-path
            obj-path
            bin-path
            "run: failed to write assembly artifact")
            [(SourceToolCommandStatus.Err message)
              (begin
                (io.print-error message)
                (source-tool-clean-temp
                  temp-dir
                  asm-path
                  obj-path
                  bin-path
                  true)
                1)]
            [(SourceToolCommandStatus.Ok)
              (match (source-tool-run-executable bin-path target runtime-args)
                [(process.OkProcessOutput output)
                  (let
                    [status : i64 (process.output-status output)]
                    (begin
                      (source-tool-forward-output output)
                      (source-tool-clean-temp
                        temp-dir
                        asm-path
                        obj-path
                        bin-path
                        true)
                      status))]
                [(process.ErrProcessOutput error)
                  (begin
                    (io.print-error
                      (str_cat.str-cat
                        "Error: failed to run executable '"
                        bin-path
                        "' for target "
                        (source-tool-target-name target)
                        ": "
                        (process.error-message error)))
                    (source-tool-clean-temp
                      temp-dir
                      asm-path
                      obj-path
                      bin-path
                      true)
                    1)])]))])))

(define (source-tool-run-source
  [source : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : vector.StringVec]
  [cfg-names : vector.StringVec]
  [runtime-args : process.ProcessStringList]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [link-inputs : SourceToolLinkInputs]) : i64
  (match (source-tool-create-temp-dir "typelisp-run")
    [(ResultSourceToolString.Ok temp-dir)
      (source-tool-run-source-in-temp
        source
        target
        stdlib-roots
        cfg-names
        runtime-args
        opt-level
        mode
        link-inputs
        temp-dir)]
    [(ResultSourceToolString.Err message)
      (begin
        (io.print-error
          (string.append "run: failed to create temp dir: " message))
        1)]))