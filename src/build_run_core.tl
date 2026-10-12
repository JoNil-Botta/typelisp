;; build_run_core.tl - Shared selfhost source build/run execution helpers.
(import stdlib.iterator)
(import compiler_owned_view as owned_view)
(import stdlib.vector)
(import (vector.vector String) as cli_svec)
(import compiler_driver_core)
(import compiler_backend as backend)
(import compiler_ast_types as ast)
(import compiler_cfg_core as cfg_core)
(import compiler_ir_types as ir)
(import compiler_load as load)
(import compiler_object as cobj)
(import compiler_object_coff)
(import compiler_object_elf)
(import compiler_runtime_bindings as runtime_bindings)
(import compiler_windows_coff_core)
(import stdlib.env)
(import stdlib.byte_buf)
(import stdlib.fs)
(import stdlib.io)
(import stdlib.msvc)
(import stdlib.process)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import sym_i64_env)

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
  (Ok backend.CompilerBackendTarget)
  (Err String))

(defenum ResultSourceToolBackendMode
  (Ok backend.CompilerBackendMode)
  (Err String))

;; Who declared each link input, in declaration order: its kind ("library",
;; "search-path", "arg" or "archive"), the value the linker sees, and the
;; declaration, such as "package `w` (w/typelisp.pkg) field `linux-libraries`".
(defstruct SourceToolLinkOrigins
  (kinds process.ProcessStringList)
  (values process.ProcessStringList)
  (declared-by process.ProcessStringList))

(defstruct SourceToolLinkInputs
  (libs process.ProcessStringList)
  (search-dirs process.ProcessStringList)
  (raw-args process.ProcessStringList)
  ;; Package dependency static archives, in link order. They follow the raw
  ;; arguments; on Linux they, the libraries and the raw arguments form one
  ;; linker group, so an archive may need a library named before it and two
  ;; archives may reference each other.
  (archives process.ProcessStringList)
  ;; Every declaration, kept even when a merge drops its input as a duplicate.
  (origins SourceToolLinkOrigins))

(defenum ResultSourceToolLinkInputs
  (Ok SourceToolLinkInputs)
  (Err String))

(define (source-tool-cfg-names-to-env [names : cli_svec.Vec]) : sym_i64_env.SymI64Env
  (let
    [env : sym_i64_env.SymI64Env (cfg_core.compiler-cfg-empty)]
    (for [index (iterator.range 0 (cli_svec.len (& names)))]
      (set!
        env
        (cfg_core.compiler-cfg-enable env (& (cli_svec.get (& names) index "")))))
    env))

(define (source-tool-target-name [target : backend.CompilerBackendTarget]) : String
  (backend.compiler-backend-target-triple target))

(define (source-tool-default-target) : backend.CompilerBackendTarget
  (if (string.eq (env.path-separator) ";")
    (Windows)
    (Linux)))

(define (source-tool-default-target-name) : String
  (source-tool-target-name (source-tool-default-target)))

(define (source-tool-target [value : String]) : ResultSourceToolTarget
  (if (or (string.eq value "linux-x86_64") (string.eq value "linux_x86_64"))
    (Ok (Linux))
    (if (or
      (string.eq value "windows-x86_64")
      (string.eq value "windows_x86_64"))
      (Ok (Windows))
      (Err (str_cat.str-cat "unknown target " value)))))

(define (source-tool-backend-mode [command : String] [value : String]) : ResultSourceToolBackendMode
  (cond
    [(string.eq value "scalar") (Ok (Scalar))]
    [(string.eq value "avx2") (Ok (Avx2))]
    [(string.eq value "avx512") (Ok (Avx512))]
    [else (Err (str_cat.str-cat command ": unknown backend mode " value))]))

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

(define (source-tool-link-origins-empty) : SourceToolLinkOrigins
  (SourceToolLinkOrigins
    (process.args-empty)
    (process.args-empty)
    (process.args-empty)))

(define (source-tool-link-origins-append
  [left : SourceToolLinkOrigins]
  [right : SourceToolLinkOrigins]) : SourceToolLinkOrigins
  (SourceToolLinkOrigins
    (process.args-append left.kinds right.kinds)
    (process.args-append left.values right.values)
    (process.args-append left.declared-by right.declared-by)))

(define (source-tool-link-inputs-empty) : SourceToolLinkInputs
  (SourceToolLinkInputs
    (process.args-empty)
    (process.args-empty)
    (process.args-empty)
    (process.args-empty)
    (source-tool-link-origins-empty)))

;; Wrap fully-resolved package dependency static archives as link inputs.
(define (source-tool-link-inputs-from-archives
  [archives : process.ProcessStringList]) : SourceToolLinkInputs
  (SourceToolLinkInputs
    (process.args-empty)
    (process.args-empty)
    (process.args-empty)
    archives
    (source-tool-link-origins-empty)))

(define (source-tool-link-inputs-libs
  [inputs : (& inputs SourceToolLinkInputs)]) : process.ProcessStringList
  (let
    [inputs : SourceToolLinkInputs
      (owned_view.compiler-owned-reference-shared-view inputs)]
    inputs.libs))

(define (source-tool-link-inputs-search-dirs
  [inputs : (& inputs SourceToolLinkInputs)]) : process.ProcessStringList
  (let
    [inputs : SourceToolLinkInputs
      (owned_view.compiler-owned-reference-shared-view inputs)]
    inputs.search-dirs))

(define (source-tool-link-inputs-raw-args
  [inputs : (& inputs SourceToolLinkInputs)]) : process.ProcessStringList
  (let
    [inputs : SourceToolLinkInputs
      (owned_view.compiler-owned-reference-shared-view inputs)]
    inputs.raw-args))

(define (source-tool-link-inputs-archives
  [inputs : (& inputs SourceToolLinkInputs)]) : process.ProcessStringList
  (let
    [inputs : SourceToolLinkInputs
      (owned_view.compiler-owned-reference-shared-view inputs)]
    inputs.archives))

(define (source-tool-link-inputs-origins
  [inputs : (& inputs SourceToolLinkInputs)]) : SourceToolLinkOrigins
  (let
    [inputs : SourceToolLinkInputs
      (owned_view.compiler-owned-reference-shared-view inputs)]
    inputs.origins))

(define (source-tool-link-inputs-add-origin
  [inputs : SourceToolLinkInputs]
  [kind : String]
  [value : String]
  [declared-by : String]) : SourceToolLinkInputs
  (SourceToolLinkInputs
    inputs.libs
    inputs.search-dirs
    inputs.raw-args
    inputs.archives
    (SourceToolLinkOrigins
      (source-tool-args-append inputs.origins.kinds kind)
      (source-tool-args-append inputs.origins.values value)
      (source-tool-args-append inputs.origins.declared-by declared-by))))

(define (source-tool-link-inputs-empty?
  [inputs : (& inputs SourceToolLinkInputs)]) : bool
  (and
    (= (process.args-count inputs.libs) 0)
    (= (process.args-count inputs.search-dirs) 0)
    (= (process.args-count inputs.raw-args) 0)
    (= (process.args-count inputs.archives) 0)))

(define (source-tool-linux-crt-entry?
  [target : backend.CompilerBackendTarget]
  [link-inputs : (& link-inputs SourceToolLinkInputs)]) : bool
  (match target
    [(Linux) (not (source-tool-link-inputs-empty? link-inputs))]
    [(Windows) false]))

(define (source-tool-link-inputs-add-lib
  [inputs : SourceToolLinkInputs]
  [name : String]) : SourceToolLinkInputs
  (SourceToolLinkInputs
    (source-tool-args-append (source-tool-link-inputs-libs inputs) name)
    (source-tool-link-inputs-search-dirs inputs)
    (source-tool-link-inputs-raw-args inputs)
    (source-tool-link-inputs-archives inputs)
    (source-tool-link-inputs-origins inputs)))

(define (source-tool-link-inputs-add-search-dir
  [inputs : SourceToolLinkInputs]
  [dir : String]) : SourceToolLinkInputs
  (SourceToolLinkInputs
    (source-tool-link-inputs-libs inputs)
    (source-tool-args-append (source-tool-link-inputs-search-dirs inputs) dir)
    (source-tool-link-inputs-raw-args inputs)
    (source-tool-link-inputs-archives inputs)
    (source-tool-link-inputs-origins inputs)))

(define (source-tool-link-inputs-add-raw-arg
  [inputs : SourceToolLinkInputs]
  [arg-value : String]) : SourceToolLinkInputs
  (SourceToolLinkInputs
    (source-tool-link-inputs-libs inputs)
    (source-tool-link-inputs-search-dirs inputs)
    (source-tool-args-append
      (source-tool-link-inputs-raw-args inputs)
      arg-value)
    (source-tool-link-inputs-archives inputs)
    (source-tool-link-inputs-origins inputs)))

(define (source-tool-string-list-contains?
  [items : (& items process.ProcessStringList)]
  [value : String]) : bool
  (let
    [n : i64 (process.args-count items)]
    [i : i64 0]
    [found : bool false]
    (while (and (< i n) (not found))
      (if (string.eq (process.args-ref items i) value)
        (set! found true)
        unit)
      (+= i 1))
    found))

(define (source-tool-args-append-unique
  [items : process.ProcessStringList]
  [value : String]) : process.ProcessStringList
  (if (source-tool-string-list-contains?
    items
    (owned_view.compiler-owned-shared-view value))
    items
    (source-tool-args-append items value)))

(define (source-tool-string-list-merge-unique
  [left : process.ProcessStringList]
  [right : process.ProcessStringList]) : process.ProcessStringList
  (let
    [n : i64 (process.args-count right)]
    [out : process.ProcessStringList left]
    (for [i (iterator.range 0 n)]
      (set! out (source-tool-args-append-unique out (process.args-ref right i))))
    out))

;; Libraries, search directories and archives merge first-seen with exact
;; duplicates removed, which never changes what the linker resolves: a search
;; directory applies to every library, and libraries and archives form one
;; group or are searched repeatedly. Raw arguments are removed only when
;; `dedup-raw?`: a raw argument may be one half of a positional pair such as
;; `--whole-archive`, so another package's copy must stay.
(define (source-tool-link-inputs-merge-with
  [left : SourceToolLinkInputs]
  [right : SourceToolLinkInputs]
  [dedup-raw? : bool]) : SourceToolLinkInputs
  (SourceToolLinkInputs
    (source-tool-string-list-merge-unique
      (source-tool-link-inputs-libs left)
      (source-tool-link-inputs-libs right))
    (source-tool-string-list-merge-unique
      (source-tool-link-inputs-search-dirs left)
      (source-tool-link-inputs-search-dirs right))
    (if dedup-raw?
      (source-tool-string-list-merge-unique
        (source-tool-link-inputs-raw-args left)
        (source-tool-link-inputs-raw-args right))
      (process.args-append
        (source-tool-link-inputs-raw-args left)
        (source-tool-link-inputs-raw-args right)))
    (source-tool-string-list-merge-unique
      (source-tool-link-inputs-archives left)
      (source-tool-link-inputs-archives right))
    (source-tool-link-origins-append
      (source-tool-link-inputs-origins left)
      (source-tool-link-inputs-origins right))))

(define (source-tool-link-inputs-merge
  [left : SourceToolLinkInputs]
  [right : SourceToolLinkInputs]) : SourceToolLinkInputs
  (source-tool-link-inputs-merge-with left right true))

(define (source-tool-link-inputs-add-ast
  [inputs : SourceToolLinkInputs]
  [item : ast.AstExternLinkInput]) : SourceToolLinkInputs
  (match item
    [(Lib name)
      (SourceToolLinkInputs
        (source-tool-args-append-unique
          (source-tool-link-inputs-libs inputs)
          name)
        (source-tool-link-inputs-search-dirs inputs)
        (source-tool-link-inputs-raw-args inputs)
        (source-tool-link-inputs-archives inputs)
        (source-tool-link-inputs-origins inputs))]
    [(Search dir)
      (SourceToolLinkInputs
        (source-tool-link-inputs-libs inputs)
        (source-tool-args-append-unique
          (source-tool-link-inputs-search-dirs inputs)
          dir)
        (source-tool-link-inputs-raw-args inputs)
        (source-tool-link-inputs-archives inputs)
        (source-tool-link-inputs-origins inputs))]
    [(Arg arg-value)
      (SourceToolLinkInputs
        (source-tool-link-inputs-libs inputs)
        (source-tool-link-inputs-search-dirs inputs)
        (source-tool-args-append-unique
          (source-tool-link-inputs-raw-args inputs)
          arg-value)
        (source-tool-link-inputs-archives inputs)
        (source-tool-link-inputs-origins inputs))]))

(define (source-tool-link-inputs-add-ast-list
  [inputs : SourceToolLinkInputs]
  [items : (& items ast.AstExternLinkInputList)]
  [index : i64]) : SourceToolLinkInputs
  (if (>= index (ast.ast-extern-link-input-list-len items))
    inputs
    (source-tool-link-inputs-add-ast-list
      (source-tool-link-inputs-add-ast
        inputs
        (ast.ast-extern-link-input-list-get
          items
          index
          (ast.ast-extern-link-input-fallback)))
      items
      (+ index 1))))

(define (source-tool-link-inputs-from-decls
  [decls : ast.AstDeclList]
  [inputs : SourceToolLinkInputs]) : SourceToolLinkInputs
  (match (ast.ast-decl-list-step decls)
    [(Nil) inputs]
    [(Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        (match (ast.ast-decl-unwrapped (& decl))
          [(Extern decl-meta _ _ metadata _)
            (let
              [metadata-items : ast.AstExternLinkInputList
                (ast.ast-extern-metadata-link-inputs (deref metadata))]
              (source-tool-link-inputs-from-decls
                rest
                (source-tool-link-inputs-add-ast-list
                  inputs
                  (& metadata-items)
                  0)))]
          [_ (source-tool-link-inputs-from-decls rest inputs)]))]))

(define (source-tool-link-inputs-for-source
  [source : String]
  [stdlib-roots : cli_svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [explicit-inputs : SourceToolLinkInputs]) : ResultSourceToolLinkInputs
  (match (load.compiler-load-file-with-paths-and-roots-cfg
    source
    (sym_i64_env.sym-i64-empty)
    stdlib-roots
    cfgs)
    [(Ok decls _ _ _)
      (Ok
        (source-tool-link-inputs-merge
          (source-tool-link-inputs-from-decls
            decls
            (source-tool-link-inputs-empty))
          explicit-inputs))]
    [(Err diag)
      (Err
        (compiler_driver_core.compiler-driver-render-source-diagnostic
          (deref diag)))]))

(define (source-tool-path-separator? [c : char]) : bool
  (or (= c '/') (= c '\\')))

(define (source-tool-has-path-separator? [path : (& path str)]) : bool
  (let
    [n : i64 (string.string-length path)]
    [i : i64 0]
    [found : bool false]
    (while (and (< i n) (not found))
      (if (source-tool-path-separator? (string.string-ref path i))
        (set! found true)
        unit)
      (+= i 1))
    found))

(define (source-tool-path-entry-command [dir : String] [tool : String]) : String
  (if (= (string.string-length dir) 0)
    tool
    (source-tool-fs-path-join dir tool)))

(define (source-tool-fs-path-join [left : (& left str)] [right : String]) : String
  (fs.path-join left (& right)))

(define (source-tool-fs-basename [path : (& path str)]) : String
  (fs.basename path))

(define (source-tool-try-file-exists? [path : (& path str)]) : io.ResultIoBool
  (io.try-file-exists? path))

(define (source-tool-try-read-file [path : (& path str)]) : io.ResultIoString
  (let
    [contents (try (io.try-read-file path))]
    (OkIoString (byte_buf.to-string contents))))

(define (source-tool-try-remove-file-if-exists [path : (& path str)]) : io.ResultIoUnit
  (fs.try-remove-file-if-exists path))

(define (source-tool-try-remove-dir-if-exists [path : (& path str)]) : io.ResultIoUnit
  (fs.try-remove-dir-if-exists path))

(define (source-tool-stdout-write [text : String]) : unit
  (io.stdout-write (byte_buf.str-as-bytes (& text))))

(define (source-tool-stderr-write [text : String]) : unit
  (io.stderr-write (byte_buf.str-as-bytes (& text))))

(define (source-tool-path-command-exists? [candidate : (& candidate str)]) : bool
  (match (source-tool-try-file-exists? candidate)
    [(OkIoBool exists) exists]
    [(ErrIoBool _) false]))

(define (source-tool-windows-host?) : bool
  (string.eq (env.path-separator) ";"))

(define (source-tool-windows-exe-candidate [candidate : String]) : String
  (if (source-tool-windows-host?)
    (str_cat.str-cat candidate ".exe")
    candidate))

(define (source-tool-find-command-on-path-from
  [tool : String]
  [paths : env.EnvStringList]) : String
  (for [index (iterator.range 0 (env.string-list-count paths))]
    (let
      [candidate : String
        (source-tool-path-entry-command
          (env.string-list-ref paths index)
          (owned_view.compiler-owned-shared-view tool))]
      (if (source-tool-path-command-exists? candidate)
        (return candidate)
        (let
          [exe-candidate : String
            (source-tool-windows-exe-candidate
              (owned_view.compiler-owned-shared-view candidate))]
          (when
            (and
              (not (string.eq exe-candidate candidate))
              (source-tool-path-command-exists? exe-candidate))
            (return exe-candidate))))))
  tool)

(define (source-tool-find-command-on-path
  [tool : String]
  [paths : env.EnvStringList]) : String
  (source-tool-find-command-on-path-from tool paths))

(define (source-tool-resolve-command [tool : String]) : String
  (if (source-tool-has-path-separator? tool)
    tool
    (let
      [name : String "PATH"]
      (match (env.path-list (& name))
        [(EnvSomeStringList paths)
          (source-tool-find-command-on-path tool paths)]
        [(EnvNoStringList) tool]))))

(define (source-tool-env-command-or-default
  [name : String]
  [default-command : String]) : String
  (match (env.get (& name))
    [(EnvSomeString value)
      (if (string.eq value "")
        default-command
        value)]
    [(EnvNoString) default-command]))

(define (source-tool-resolved-env-command-or-default
  [name : String]
  [default-command : String]) : String
  (source-tool-resolve-command
    (source-tool-env-command-or-default name default-command)))

(define (source-tool-env-command-set? [name : String]) : bool
  (match (env.get (& name))
    [(EnvSomeString value) (not (string.eq value ""))]
    [(EnvNoString) false]))

(define (source-tool-replace-extension
  [input-path : String]
  [extension : String]) : String
  (let
    [n : i64 (string.string-length input-path)]
    [last-dot : i64 -1]
    [last-sep : i64 -1]
    (for [i (iterator.range 0 n)]
      (let
        [c : char (string.string-ref input-path i)]
        (if (= c '.')
          (set! last-dot i)
          (set! last-dot last-dot))
        (if (source-tool-path-separator? c)
          (set! last-sep i)
          (set! last-sep last-sep))))
    (if (> last-dot last-sep)
      (str_cat.str-cat (string.substring input-path 0 last-dot) extension)
      (str_cat.str-cat input-path extension))))

(define (source-tool-default-output
  [source : String]
  [target : backend.CompilerBackendTarget]) : String
  (match target
    [(Linux) (source-tool-replace-extension source "")]
    [(Windows) (source-tool-replace-extension source ".exe")]))

(define (source-tool-object-extension [target : backend.CompilerBackendTarget]) : String
  (match target
    [(Linux) "o"]
    [(Windows) "obj"]))

(define (source-tool-executable-extension
  [target : backend.CompilerBackendTarget]) : String
  (match target
    [(Linux) ""]
    [(Windows) ".exe"]))

(define (source-tool-static-library-extension
  [target : backend.CompilerBackendTarget]) : String
  (match target
    [(Linux) ".a"]
    [(Windows) ".lib"]))

(define (source-tool-static-library-filename
  [name : String]
  [target : backend.CompilerBackendTarget]) : String
  (match target
    [(Linux)
      (str_cat.str-cat "lib" name (source-tool-static-library-extension target))]
    [(Windows)
      (str_cat.str-cat name (source-tool-static-library-extension target))]))

(define (source-tool-artifact-stem [source : (& source str)]) : String
  (source-tool-replace-extension (source-tool-fs-basename source) ""))

(define (source-tool-asm-path
  [temp-dir : (& temp-dir str)]
  [source : (& source str)]) : String
  (source-tool-fs-path-join
    temp-dir
    (str_cat.str-cat (source-tool-artifact-stem source) ".s")))

(define (source-tool-obj-path
  [temp-dir : (& temp-dir str)]
  [source : (& source str)]
  [target : backend.CompilerBackendTarget]) : String
  (source-tool-fs-path-join
    temp-dir
    (str_cat.str-cat
      (source-tool-artifact-stem source)
      "."
      (source-tool-object-extension target))))

(define (source-tool-temp-bin-path
  [temp-dir : (& temp-dir str)]
  [source : (& source str)]
  [target : backend.CompilerBackendTarget]) : String
  (source-tool-fs-path-join
    temp-dir
    (str_cat.str-cat
      (source-tool-artifact-stem source)
      (source-tool-executable-extension target))))

(define (source-tool-create-temp-dir [prefix : String]) : ResultSourceToolString
  (match (fs.try-create-temp-dir (& prefix))
    [(OkIoString path) (Ok path)]
    [(ErrIoString error) (Err (io.error-message error))]))

(define (source-tool-cannot-read-module-message
  [source : String]
  [error : io.IoError]) : String
  (str_cat.str-cat
    "Error: cannot read module '"
    source
    "': "
    (io.error-message error)))

(define (source-tool-emit-assembly
  [source : String]
  [target : backend.CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [opt-level : i64]
  [mode : backend.CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]
  [link-inputs : (& link-inputs SourceToolLinkInputs)]) : ResultSourceToolString
  (match (source-tool-try-read-file source)
    [(ErrIoString error)
      (Err (source-tool-cannot-read-module-message source error))]
    [(OkIoString _)
      (match (compiler_driver_core.compiler-driver-emit-file-with-target-roots-level-mode-cfg-and-crt
        source
        target
        true
        stdlib-roots
        opt-level
        mode
        cfgs
        (source-tool-linux-crt-entry? target link-inputs))
        [(Ok asm advisories)
          (compiler_driver_core.compiler-driver-print-advisories (& advisories))
          (Ok (source-tool-augment-assembly-for-target asm target))]
        [(Err diag advisories)
          (compiler_driver_core.compiler-driver-print-advisories (& advisories))
          (Err
            (compiler_driver_core.compiler-driver-render-source-diagnostic
              (deref diag)))])]))

(define (source-tool-linux-direct-object-env-name) : String
  "TYPELISP_LINUX_DIRECT_OBJECT")

(define (source-tool-linux-direct-object-enabled?) : bool
  (source-tool-env-command-set? (source-tool-linux-direct-object-env-name)))

(defenum SourceToolLinuxDirectObjectEligibility
  (Eligible)
  (Fallback backend.CompilerDirectObjectFallbackReason))

(defenum ResultSourceToolLinuxDirectObject
  (Ok String)
  (Fallback backend.CompilerDirectObjectFallbackReason))

;; One ELF capability boundary for source and package artifacts. The package
;; policy preflight must not duplicate these serializer/linkability checks.
(define (source-tool-linux-direct-object-eligibility
  [kind : backend.CompilerDirectObjectArtifactKind]
  [image : cobj.CompilerObjectImage]) : SourceToolLinuxDirectObjectEligibility
  (cond
    [(not
        (compiler_object_elf.compiler-object-elf-sections-supported?
          image.sections))
      (Fallback ObjectEncoding)]
    [(not
        (compiler_object_elf.compiler-object-elf-relocation-list-supported?
          image.relocations))
      (Fallback ObjectRelocation)]
    [(not
        (and
          (compiler_object_elf.compiler-object-elf-relocation-sites-known?
            image
            image.relocations)
          (compiler_object_elf.compiler-object-elf-text-targets-known? image)
          (compiler_object_elf.compiler-object-elf-text-relocation-count-matches?
            image)))
      (Fallback ObjectFixup)]
    [(not (compiler_object_elf.compiler-object-elf-image-supported? image))
      (Fallback ObjectEncoding)]
    [(match kind
        [(Bin)
          (not
            (or
              (cobj.compiler-object-symbol-list-contains?
                image.symbols
                "_tl_start"
                (Export)
                (Function))
              (cobj.compiler-object-symbol-list-contains?
                image.symbols
                "main"
                (Export)
                (Function))))]
        [(StaticLib) false])
      (Fallback MissingEntrySymbol)]
    [(match kind
        [(Bin)
          (<=
            (compiler_object_elf.compiler-object-elf-section-raw-size
              image
              (Text))
            0)]
        [(StaticLib) false])
      (Fallback EmptyTextSection)]
    [else Eligible]))

(define (source-tool-render-linux-direct-object
  [kind : backend.CompilerDirectObjectArtifactKind]
  [image : cobj.CompilerObjectImage]) : ResultSourceToolLinuxDirectObject
  (match (source-tool-linux-direct-object-eligibility
    kind
    (owned_view.compiler-owned-shared-view image))
    [(Fallback reason) (Fallback reason)]
    [(Eligible)
      (match (compiler_object_elf.compiler-object-elf-render image)
        [(Ok object) (Ok object)]
        [(Err _) (Fallback ObjectEncoding)])]))

(define (source-tool-render-linkable-linux-elf-object
  [image : cobj.CompilerObjectImage]) : ResultSourceToolString
  (match (source-tool-render-linux-direct-object Bin image)
    [(Ok object) (Ok object)]
    [(Fallback reason)
      (Err
        (str_cat.str-cat
          "linux direct object unavailable: "
          (backend.compiler-direct-object-fallback-transcript reason)))]))

(define (source-tool-windows-direct-object-env-name) : String
  "TYPELISP_WINDOWS_DIRECT_OBJECT")

(define (source-tool-windows-direct-object-enabled?) : bool
  (source-tool-env-command-set? (source-tool-windows-direct-object-env-name)))

(define (source-tool-windows-direct-object-linkable?
  [image : cobj.CompilerObjectImage]) : bool
  (compiler_windows_coff_core.compiler-windows-coff-linkable? image))

(define (source-tool-windows-direct-object-unavailable-message) : String
  "windows direct object unavailable: object image lacks encoded .text, _tl_start, or Windows runtime entry body")

(define (source-tool-render-linkable-windows-coff-object
  [image : cobj.CompilerObjectImage]) : ResultSourceToolString
  (if (source-tool-windows-direct-object-linkable?
    (owned_view.compiler-owned-shared-view image))
    (Ok (try (compiler_object_coff.compiler-object-coff-render image)))
    (Err (source-tool-windows-direct-object-unavailable-message))))

(define (source-tool-noexecstack-note) : String
  "
    .section .note.GNU-stack,\"\",@progbits
")

(define (source-tool-augment-assembly-for-target
  [asm : String]
  [target : backend.CompilerBackendTarget]) : String
  (let
    [haystack : String asm]
    [needle : String ".note.GNU-stack"]
    (if (backend.compiler-backend-target-linux? target)
      (if (string.contains (& haystack) (& needle))
        haystack
        (str_cat.str-cat haystack (source-tool-noexecstack-note)))
      haystack)))

(define (source-tool-write-file
  [path : (& path str)]
  [contents : (& contents str)]
  [context : String]) : SourceToolCommandStatus
  (match (io.try-write-file path (byte_buf.str-as-bytes contents))
    [(OkIoUnit) Ok]
    [(ErrIoUnit error)
      (Err (str_cat.str-cat context ": " (io.error-message error)))]))

(define (source-tool-forward-output [output : (& output process.ProcessOutput)]) : unit
  (source-tool-stdout-write (process.output-stdout output))
  (source-tool-stderr-write (process.output-stderr output)))

;; The library a linker reported missing in `line`, or "": GNU ld's
;; `cannot find -lNAME`, lld's `unable to find library -lNAME`, and link.exe's
;; LNK1181 `cannot open input file 'NAME.lib'`.
(define (source-tool-missing-library-in-line [line : (& line str)]) : String
  (let
    [n : i64 (string.string-length line)]
    [gnu : i64
      (backend.compiler-backend-string-find-from line "cannot find -l" 0)]
    [lld : i64
      (backend.compiler-backend-string-find-from
        line
        "unable to find library -l"
        0)]
    [msvc : i64
      (backend.compiler-backend-string-find-from
        line
        "cannot open input file '"
        0)]
    [start : i64
      (cond
        [(>= gnu 0) (+ gnu 14)]
        [(>= lld 0) (+ lld 25)]
        [(>= msvc 0) (+ msvc 24)]
        [else -1])]
    [end : i64 start]
    (if (< start 0)
      ""
      (begin
        (while (and
          (< end n)
          (not (= (string.string-ref line end) ':'))
          (not (= (string.string-ref line end) '\''))
          (not (= (string.string-ref line end) ' ')))
          (+= end 1))
        (let
          [name : String (string.substring line start (- end start))]
          (if (and
            (>= msvc 0)
            (< gnu 0)
            (< lld 0)
            (> (string.string-length name) 4)
            (string.is-string-prefix-at
              (& name)
              ".lib"
              (- (string.string-length name) 4)))
            (string.substring (& name) 0 (- (string.string-length name) 4))
            name))))))

;; POSIX-shell single quoting, so a search path prints unambiguously.
(define (source-tool-quote [value : (& value str)]) : String
  (let
    [n : i64 (string.string-length value)]
    [out : String "'"]
    (for [index (iterator.range 0 n)]
      (let
        [c : char (string.string-ref value index)]
        (set!
          out
          (if (= c '\'')
            (str_cat.str-cat out "'\\''")
            (str_cat.str-cat out (string.substring value index 1))))))
    (str_cat.str-cat out "'")))

;; For each library the linker reported missing, the declarations that
;; requested it and the search paths it was looked for in.
(define (source-tool-link-failure-notes
  [stderr : (& stderr str)]
  [inputs : (& inputs SourceToolLinkInputs)]) : String
  (let
    [origins : SourceToolLinkOrigins (source-tool-link-inputs-origins inputs)]
    [dirs : process.ProcessStringList
      (source-tool-link-inputs-search-dirs inputs)]
    [n : i64 (string.string-length stderr)]
    [line-start : i64 0]
    [out : String ""]
    (while (< line-start n)
      (let
        [newline : i64 (string.index-of-byte stderr line-start 10)]
        [line-end : i64
          (if (< newline 0)
            n
            newline)]
        [line : String
          (string.substring stderr line-start (- line-end line-start))]
        [name : String (source-tool-missing-library-in-line (& line))]
        [named : bool false]
        (unless
          (= (string.string-length name) 0)
          (for [origin-index
            (iterator.range 0 (process.args-count origins.kinds))]
            (when
              (and
                (string.eq
                  (process.args-ref origins.kinds origin-index)
                  "library")
                (string.eq
                  (process.args-ref origins.values origin-index)
                  (owned_view.compiler-owned-shared-view name)))
              (set!
                out
                (str_cat.str-cat
                  out
                  "\nnote: native library `"
                  (owned_view.compiler-owned-shared-view name)
                  "` is required by "
                  (process.args-ref origins.declared-by origin-index)))
              (set! named true)))
          (if named
            (let
              [searched : String ""]
              (for [dir-index (iterator.range 0 (process.args-count dirs))]
                (set!
                  searched
                  (str_cat.str-cat
                    searched
                    " "
                    (let
                      [dir : String (process.args-ref dirs dir-index)]
                      (source-tool-quote (& dir))))))
              (set!
                out
                (str_cat.str-cat
                  out
                  "\nnote: search paths:"
                  (if (= (string.string-length searched) 0)
                    " none besides the linker's defaults"
                    (str_cat.str-cat searched " and the linker's defaults")))))
            unit))
        (set! line-start (+ line-end 1))))
    out))

(define (source-tool-run-command
  [role : String]
  [target : backend.CompilerBackendTarget]
  [command : process.ProcessCommand]) : SourceToolCommandStatus
  (source-tool-run-command-for
    role
    target
    command
    (source-tool-link-inputs-empty)))

;; Run `command`; a failed linker names the declarations behind the libraries
;; it could not find (source-tool-link-failure-notes).
(define (source-tool-run-command-for
  [role : String]
  [target : backend.CompilerBackendTarget]
  [command : process.ProcessCommand]
  [link-inputs : SourceToolLinkInputs]) : SourceToolCommandStatus
  (let
    [tool : String (process.command-executable command)]
    [command-to-run : process.ProcessCommand
      (source-tool-command-for-target target command)]
    (match (process.output command-to-run)
      [(OkProcessOutput output)
        (source-tool-forward-output output)
        (if (process.success? output)
          Ok
          (Err
            (str_cat.str-cat
              "Error: "
              role
              " '"
              tool
              "' failed for target "
              (source-tool-target-name target)
              " with status "
              (string.int->string (process.output-status output))
              (let
                [stderr : String (process.output-stderr output)]
                (source-tool-link-failure-notes (& stderr) (& link-inputs))))))]
      [(ErrProcessOutput error)
        (Err
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
  [_target : backend.CompilerBackendTarget]
  [command : process.ProcessCommand]) : process.ProcessCommand
  command)

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

;; Map every entry of `items` to `prefix` + entry + `suffix`, preserving argv
;; order.
(define (source-tool-decorated-args
  [items : process.ProcessStringList]
  [prefix : String]
  [suffix : String]
  [index : i64]) : process.ProcessStringList
  (if (>= index (process.args-count items))
    (process.args-empty)
    (process.args-cons
      (str_cat.str-cat
        (owned_view.compiler-owned-shared-view prefix)
        (process.args-ref items index)
        (owned_view.compiler-owned-shared-view suffix))
      (source-tool-decorated-args items prefix suffix (+ index 1)))))

(define (source-tool-linux-link-search-args [dirs : process.ProcessStringList]) : process.ProcessStringList
  (source-tool-decorated-args dirs "-L" "" 0))

(define (source-tool-linux-link-lib-args [libs : process.ProcessStringList]) : process.ProcessStringList
  (source-tool-decorated-args libs "-l" "" 0))

(define (source-tool-link-inputs-linux-args [inputs : SourceToolLinkInputs]) : process.ProcessStringList
  (let
    [archives : process.ProcessStringList
      (source-tool-link-inputs-archives inputs)]
    [grouped? : bool (> (process.args-count archives) 0)]
    [inputs-in-order : process.ProcessStringList
      (process.args-append
        (source-tool-linux-link-lib-args (source-tool-link-inputs-libs inputs))
        (process.args-append (source-tool-link-inputs-raw-args inputs) archives))]
    (process.args-append
      (source-tool-linux-link-search-args
        (source-tool-link-inputs-search-dirs inputs))
      (if grouped?
        (process.args-cons
          "-Wl,--start-group"
          (process.args-append
            inputs-in-order
            (process.args-single "-Wl,--end-group")))
        inputs-in-order))))

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

;; Freestanding Win32: no CRT (no vcruntime140/ucrt/msvcrt) and only the
;; audited kernel32 plus ntdll system boundary.
;; The backend emits its own entry (_tl_start) plus kernel32-backed shims for the
;; CRT-ABI symbols the runtime/stdlib reference. Stdlib random seeding uses
;; kernel32 FFI only, so no advapi32; no COM (ole32/oleaut32) is needed either.
;; The import libraries the Windows runtime binding table names, in first-use
;; order (#8318): kernel32.lib, then ntdll.lib.
(define (source-tool-windows-link-libs) : process.ProcessStringList
  (let
    [providers : (__tl_dyn-array String)
      (runtime_bindings.compiler-runtime-binding-providers "windows-x86_64")]
    [libs : process.ProcessStringList (process.args-empty)]
    [index : i64 (- (array-length providers) 1)]
    (while (>= index 0)
      (set!
        libs
        (process.args-cons (string.copy (& (array-ref providers index))) libs))
      (-= index 1))
    libs))

;; Keep the historical 256 MiB PE reserve used by the native-link scripts. The
;; freestanding entry now uses this stack only for bounded argv/fiber bootstrap;
;; `main`, including a self-hosted compiler, runs on the runtime-owned 1 GiB
;; fiber stack and no longer depends on this linker setting for correctness.
(define (source-tool-windows-stack-reserve-arg) : String
  "/STACK:268435456")

(define (source-tool-windows-link-search-args
  [dirs : process.ProcessStringList]) : process.ProcessStringList
  (source-tool-decorated-args dirs "/LIBPATH:" "" 0))

(define (source-tool-windows-link-lib-args [libs : process.ProcessStringList]) : process.ProcessStringList
  (source-tool-decorated-args libs "" ".lib" 0))

;; `link.exe` resolves a symbol from any library on the command line, so the
;; archives need no group.
(define (source-tool-link-inputs-windows-args [inputs : SourceToolLinkInputs]) : process.ProcessStringList
  (process.args-append
    (source-tool-windows-link-search-args
      (source-tool-link-inputs-search-dirs inputs))
    (process.args-append
      (source-tool-windows-link-lib-args (source-tool-link-inputs-libs inputs))
      (process.args-append
        (source-tool-link-inputs-raw-args inputs)
        (source-tool-link-inputs-archives inputs)))))

(define (source-tool-windows-linker-args
  [obj-path : String]
  [bin-path : String]
  [link-inputs : SourceToolLinkInputs]) : process.ProcessStringList
  (let
    [args : process.ProcessStringList
      (process.args-cons
        obj-path
        (process.args-cons
          (str_cat.str-cat "/OUT:" bin-path)
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
                      (source-tool-windows-link-libs)))))))))]
    (process.args-cons
      "/NOLOGO"
      ;; The image timestamp and debug GUID derive from the inputs, so linking
      ;; the same objects again produces the same bytes.
      (process.args-cons
        "/Brepro"
        (if (ir.compiler-debug-info-enabled?)
          (process.args-cons "/DEBUG" args)
          args)))))

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
    (Ok
      (source-tool-windows-linker-fallback-command
        obj-path
        bin-path
        link-inputs))
    (let
      [target : String "x86_64-pc-windows-msvc"]
      [tool : String "link.exe"]
      (match (msvc.find-tool (& target) (& tool))
        [(OkMsvcTool resolved-tool)
          (Ok
            (process.command-with-env-list
              (process.command
                (msvc.tool-executable resolved-tool)
                (source-tool-windows-linker-args obj-path bin-path link-inputs))
              (msvc.tool-process-env resolved-tool)))]
        [(ErrMsvcTool _)
          (Ok
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

(define (source-tool-windows-msvc-archiver-args
  [obj-path : String]
  [archive-path : String]) : process.ProcessStringList
  (process.args-cons
    "/NOLOGO"
    (process.args-cons
      "/Brepro"
      (process.args-cons
        (str_cat.str-cat "/OUT:" archive-path)
        (process.args-cons obj-path (process.args-empty))))))

(define (source-tool-windows-llvm-archiver-args
  [obj-path : String]
  [archive-path : String]) : process.ProcessStringList
  (process.args-cons
    "--format=coff"
    (process.args-cons
      "rcsD"
      (process.args-cons
        archive-path
        (process.args-cons obj-path (process.args-empty))))))

(define (source-tool-ascii-fold-char [c : char]) : char
  (if (and (>= c 'A') (<= c 'Z'))
    (cast (+ (cast c : i64) 32) : char)
    c))

(define (source-tool-ascii-case-eq [left : (& left str)] [right : String]) : bool
  (let
    [left-n : i64 (string.string-length left)]
    [right-n : i64 (string.string-length right)]
    [i : i64 0]
    [same : bool (= left-n right-n)]
    (while (and same (< i left-n))
      (if (=
        (source-tool-ascii-fold-char (string.string-ref left i))
        (source-tool-ascii-fold-char (string.string-ref right i)))
        unit
        (set! same false))
      (+= i 1))
    same))

(define (source-tool-windows-llvm-archiver-name? [command : (& command str)]) : bool
  (let
    [basename : String (source-tool-fs-basename command)]
    (or
      (source-tool-ascii-case-eq basename "llvm-ar")
      (source-tool-ascii-case-eq basename "llvm-ar.exe"))))

(define (source-tool-windows-msvc-archiver-name? [command : (& command str)]) : bool
  (let
    [basename : String (source-tool-fs-basename command)]
    (or
      (source-tool-ascii-case-eq basename "lib")
      (source-tool-ascii-case-eq basename "lib.exe"))))

(define (source-tool-windows-llvm-archiver-command
  [command : String]
  [obj-path : String]
  [archive-path : String]) : process.ProcessCommand
  (process.command
    command
    (source-tool-windows-llvm-archiver-args obj-path archive-path)))

(define (source-tool-windows-override-archiver-command
  [obj-path : String]
  [archive-path : String]) : ResultSourceToolCommand
  (let
    [name : String "TYPELISP_WINDOWS_LIB"]
    [command : String
      (source-tool-resolved-env-command-or-default
        name
        (source-tool-resolve-command "llvm-ar"))]
    (cond
      [(source-tool-windows-llvm-archiver-name? command)
        (Ok
          (source-tool-windows-llvm-archiver-command
            command
            obj-path
            archive-path))]
      [(source-tool-windows-msvc-archiver-name? command)
        (Ok
          (process.command
            command
            (source-tool-windows-msvc-archiver-args obj-path archive-path)))]
      [else
        (Err
          "TYPELISP_WINDOWS_LIB must resolve to llvm-ar(.exe) or MSVC lib(.exe); deterministic Windows archives require llvm-ar --format=coff rcsD or lib.exe /Brepro")])))

(define (source-tool-windows-archiver-command
  [obj-path : String]
  [archive-path : String]) : ResultSourceToolCommand
  (if (source-tool-env-command-set? "TYPELISP_WINDOWS_LIB")
    (source-tool-windows-override-archiver-command obj-path archive-path)
    (let
      [target : String "x86_64-pc-windows-msvc"]
      [tool : String "lib.exe"]
      (match (msvc.find-tool (& target) (& tool))
        [(OkMsvcTool resolved-tool)
          (Ok
            (process.command-with-env-list
              (process.command
                (msvc.tool-executable resolved-tool)
                (source-tool-windows-msvc-archiver-args obj-path archive-path))
              (msvc.tool-process-env resolved-tool)))]
        [(ErrMsvcTool _)
          (Ok
            (source-tool-windows-llvm-archiver-command
              (source-tool-resolve-command "llvm-ar")
              obj-path
              archive-path))]))))

(define (source-tool-clean-temp
  [temp-dir : String]
  [asm-path : String]
  [obj-path : String]
  [bin-path : String]
  [remove-bin : bool]) : unit
  (source-tool-try-remove-file-if-exists asm-path)
  (source-tool-try-remove-file-if-exists obj-path)
  (if remove-bin
    (source-tool-try-remove-file-if-exists bin-path)
    io.OkIoUnit)
  (source-tool-try-remove-dir-if-exists temp-dir)
  unit)

(define (source-tool-assemble
  [target : backend.CompilerBackendTarget]
  [asm-path : String]
  [obj-path : String]) : SourceToolCommandStatus
  (match target
    [(Linux)
      (source-tool-run-command
        "assembler"
        target
        (source-tool-assembler-command asm-path obj-path))]
    [(Windows)
      (source-tool-run-command
        "assembler"
        target
        (source-tool-windows-assembler-command asm-path obj-path))]))

(define (source-tool-link
  [target : backend.CompilerBackendTarget]
  [obj-path : String]
  [bin-path : String]
  [link-inputs : SourceToolLinkInputs]) : SourceToolCommandStatus
  (match target
    [(Linux)
      (source-tool-run-command-for
        "linker"
        target
        (source-tool-linker-command
          obj-path
          bin-path
          (owned_view.compiler-owned-shared-view link-inputs))
        link-inputs)]
    [(Windows)
      (let
        [command
          (try
            (source-tool-windows-linker-command
              obj-path
              bin-path
              (owned_view.compiler-owned-shared-view link-inputs)))]
        (source-tool-run-command-for "linker" target command link-inputs))]))

(define (source-tool-archive
  [target : backend.CompilerBackendTarget]
  [obj-path : String]
  [archive-path : String]) : SourceToolCommandStatus
  (match target
    [(Linux)
      (source-tool-run-command
        "archiver"
        target
        (source-tool-archiver-command obj-path archive-path))]
    [(Windows)
      (let
        [command
          (try (source-tool-windows-archiver-command obj-path archive-path))]
        (source-tool-run-command "archiver" target command))]))

(define (source-tool-assemble-and-link
  [target : backend.CompilerBackendTarget]
  [asm-path : String]
  [obj-path : String]
  [bin-path : String]
  [link-inputs : SourceToolLinkInputs]) : SourceToolCommandStatus
  (let
    [_
      (try
        (source-tool-assemble
          target
          asm-path
          (owned_view.compiler-owned-shared-view obj-path)))]
    (source-tool-link target obj-path bin-path link-inputs)))

(define (source-tool-assemble-and-archive
  [target : backend.CompilerBackendTarget]
  [asm-path : String]
  [obj-path : String]
  [archive-path : String]) : SourceToolCommandStatus
  (let
    [_
      (try
        (source-tool-assemble
          target
          asm-path
          (owned_view.compiler-owned-shared-view obj-path)))]
    (source-tool-archive target obj-path archive-path)))

(define (source-tool-write-direct-object-and-link
  [obj-path : String]
  [bin-path : String]
  [target : backend.CompilerBackendTarget]
  [link-inputs : SourceToolLinkInputs]
  [obj : String]
  [context : String]) : SourceToolDirectObjectStatus
  (match (source-tool-write-file obj-path obj context)
    [(Err message) (Err message)]
    [(Ok)
      (match (source-tool-link target obj-path bin-path link-inputs)
        [(Ok) Ok]
        [(Err message) (Err message)])]))

(define (source-tool-write-direct-object-and-archive
  [obj-path : String]
  [archive-path : String]
  [target : backend.CompilerBackendTarget]
  [obj : String]
  [context : String]) : SourceToolDirectObjectStatus
  (match (source-tool-write-file obj-path obj context)
    [(Err message) (Err message)]
    [(Ok)
      (match (source-tool-archive target obj-path archive-path)
        [(Ok) Ok]
        [(Err message) (Err message)])]))

;; --- One link route ----------------------------------------------------------
;;
;; What a link route compiles: a source file with its stdlib roots and cfg
;; environment, a program the caller already lowered (the test harness), or
;; assembly the caller already emitted (doctests).
(defenum SourceToolProgram
  (Source cli_svec.Vec sym_i64_env.SymI64Env)
  (Lowered ir.CompilerIrProgram ir.CompilerSourceSpans)
  (Assembly String))

;; The artifact paths of one program built in a temp dir.
(defstruct SourceToolTempFiles
  (dir String)
  (asm String)
  (obj String)
  (bin String))

;; One request to compile a program and link it into `files.bin`.
;; `write-context` prefixes a failed assembly write, as in "build: failed to
;; write assembly artifact".
(defstruct SourceToolLinkRequest
  (source String)
  (program SourceToolProgram)
  (target backend.CompilerBackendTarget)
  (opt-level i64)
  (mode backend.CompilerBackendMode)
  (link-inputs SourceToolLinkInputs)
  (files SourceToolTempFiles)
  (write-context String))

;; How running a linked program ended.
(defenum SourceToolRunOutcome
  (LinkFailed String)
  (Ran process.ProcessOutput)
  (SpawnFailed process.ProcessError))

(define (source-tool-temp-files
  [dir : String]
  [source : (& source str)]
  [target : backend.CompilerBackendTarget]) : SourceToolTempFiles
  (let
    [asm : String (source-tool-asm-path dir source)]
    [obj : String (source-tool-obj-path dir source target)]
    [bin : String (source-tool-temp-bin-path dir source target)]
    (SourceToolTempFiles dir asm obj bin)))

(define (source-tool-clean-temp-files
  [files : SourceToolTempFiles]
  [remove-bin : bool]) : unit
  (source-tool-clean-temp files.dir files.asm files.obj files.bin remove-bin))

(define (source-tool-program-lowered? [program : (& program SourceToolProgram)]) : bool
  (match program
    [(Lowered _ _) true]
    [_ false]))

(define (source-tool-program-assembly?
  [program : (& program SourceToolProgram)]) : bool
  (match program
    [(Assembly _) true]
    [_ false]))

;; Serialize an emitted object image for the target's linker, or say why the
;; program has to take the assembly route instead.
(define (source-tool-render-object-result
  [target : backend.CompilerBackendTarget]
  [result : compiler_driver_core.ResultCompilerDriverObject]) : ResultSourceToolString
  (match result
    [(Ok image advisories)
      (compiler_driver_core.compiler-driver-print-advisories (& advisories))
      (match target
        [(Linux) (source-tool-render-linkable-linux-elf-object image)]
        [(Windows) (source-tool-render-linkable-windows-coff-object image)])]
    [(Unavailable category _)
      (Err (backend.compiler-direct-object-fallback-category category))]
    [(Err diag advisories)
      (compiler_driver_core.compiler-driver-print-advisories (& advisories))
      (Err
        (compiler_driver_core.compiler-driver-render-source-diagnostic
          (deref diag)))]))

;; Emit a source or lowered program as a direct object. The lowered emitter
;; encodes scalar IR.
(define (source-tool-emit-object
  [source : String]
  [program : SourceToolProgram]
  [target : backend.CompilerBackendTarget]
  [opt-level : i64]
  [mode : backend.CompilerBackendMode]
  [link-inputs : (& link-inputs SourceToolLinkInputs)]) : ResultSourceToolString
  (let
    [crt-entry : bool (source-tool-linux-crt-entry? target link-inputs)]
    (match program
      [(Source stdlib-roots cfgs)
        (match (source-tool-try-read-file source)
          [(ErrIoString error)
            (Err (source-tool-cannot-read-module-message source error))]
          [(OkIoString _)
            (source-tool-render-object-result
              target
              (compiler_driver_core.compiler-driver-emit-file-object-image-with-target-roots-level-mode-cfg-and-crt
                source
                target
                true
                stdlib-roots
                opt-level
                mode
                cfgs
                crt-entry))])]
      [(Lowered lowered spans)
        (source-tool-render-object-result
          target
          (compiler_driver_core.compiler-driver-emit-lowered-object-image-with-level-mode-entry-and-crt
            (ast.ast-node-pool-reader-context-current)
            source
            lowered
            spans
            target
            true
            (Scalar)
            opt-level
            true
            crt-entry))]
      [(Assembly _) (Err "assembly has no direct object route")])))

;; The direct object route, taken only when TYPELISP_{LINUX,WINDOWS}_DIRECT_OBJECT
;; enables it for the target and no debug information is requested. Lowered
;; programs take it only in scalar mode: the lowered object emitters encode
;; scalar IR only (SIMD parity is #7030), so a SIMD program goes to assembly
;; with its mode intact instead of pairing vector IR with the scalar backend.
(define (source-tool-try-direct-object-and-link
  [request : SourceToolLinkRequest]) : SourceToolDirectObjectStatus
  (let
    [lowered : bool (source-tool-program-lowered? (& request.program))]
    (if (and
      (not (ir.compiler-debug-info-enabled?))
      (match request.target
        [(Linux) (source-tool-linux-direct-object-enabled?)]
        [(Windows) (source-tool-windows-direct-object-enabled?)])
      (not (source-tool-program-assembly? (& request.program)))
      (or (not lowered) (backend.compiler-backend-mode-scalar? request.mode)))
      (match (source-tool-emit-object
        request.source
        request.program
        request.target
        request.opt-level
        request.mode
        request.link-inputs)
        [(Ok obj)
          (source-tool-write-direct-object-and-link
            request.files.obj
            request.files.bin
            request.target
            request.link-inputs
            obj
            (if lowered
              "test: failed to write direct object artifact"
              "source-tool: failed to write direct object artifact"))]
        [(Err message) (Unavailable message)])
      (Unavailable "direct object disabled"))))

;; Emit a program as assembly for the external assembler.
(define (source-tool-emit-program-assembly
  [source : String]
  [program : SourceToolProgram]
  [target : backend.CompilerBackendTarget]
  [opt-level : i64]
  [mode : backend.CompilerBackendMode]
  [link-inputs : (& link-inputs SourceToolLinkInputs)]) : ResultSourceToolString
  (match program
    [(Source stdlib-roots cfgs)
      (source-tool-emit-assembly
        source
        target
        stdlib-roots
        opt-level
        mode
        cfgs
        link-inputs)]
    [(Lowered lowered spans)
      (match (compiler_driver_core.compiler-driver-emit-lowered-with-level-and-mode
        source
        lowered
        spans
        target
        true
        mode
        opt-level)
        [(Ok asm advisories)
          (compiler_driver_core.compiler-driver-print-advisories (& advisories))
          (Ok (source-tool-augment-assembly-for-target asm target))]
        [(Err diag advisories)
          (compiler_driver_core.compiler-driver-print-advisories (& advisories))
          (Err
            (compiler_driver_core.compiler-driver-render-source-diagnostic
              (deref diag)))])]
    [(Assembly asm) (Ok asm)]))

;; Compile `request`'s program and link it into `request.files.bin`: through a
;; direct object when that route is enabled and the object is linkable, else
;; through assembly and the external assembler.
(define (source-tool-link-program [request : SourceToolLinkRequest]) : SourceToolCommandStatus
  (match (source-tool-try-direct-object-and-link
    (owned_view.compiler-owned-shared-view request))
    [(Ok) Ok]
    [(Err message) (Err message)]
    [(Unavailable _)
      (let
        [asm
          (try
            (source-tool-emit-program-assembly
              request.source
              request.program
              request.target
              request.opt-level
              request.mode
              request.link-inputs))]
        [_
          (try
            (source-tool-write-file request.files.asm asm request.write-context))]
        (source-tool-assemble-and-link
          request.target
          request.files.asm
          request.files.obj
          request.files.bin
          request.link-inputs))]))

;; Link `request` and run the executable with `args` and the env overrides
;; `env`, streaming its output when `inherit` and capturing it otherwise. The
;; caller owns the temp files: it decides what to report and whether to keep
;; them.
(define (source-tool-link-and-run
  [request : SourceToolLinkRequest]
  [args : process.ProcessStringList]
  [env : process.ProcessEnvList]
  [inherit : bool]) : SourceToolRunOutcome
  (let
    [target : backend.CompilerBackendTarget request.target]
    [bin-path : String
      (owned_view.compiler-owned-shared-view request.files.bin)]
    (match (source-tool-link-program request)
      [(Err message) (LinkFailed message)]
      [(Ok)
        (let
          [command : process.ProcessCommand
            (source-tool-command-for-target
              target
              (process.command-with-env-list
                (process.command bin-path args)
                env))]
          (match (if inherit
            (process.inherit command)
            (process.output command))
            [(OkProcessOutput output) (Ran output)]
            [(ErrProcessOutput error) (SpawnFailed error)]))])))

;; Where `build` has the linker write its output. A failed GNU `ld` deletes the
;; file it was asked to write, so the linker never gets the destination itself
;; (#8192): it writes into a fresh directory beside the destination, on the
;; same filesystem, and only a successful link replaces the destination, by
;; `fs.try-atomic-replace`. A destination whose parent does not exist cannot
;; lose a file, so it is linked directly and the linker reports the parent.
(defenum SourceToolLinkDestination
  (Private String)
  (Direct)
  (Failed String))

(define (source-tool-link-destination [destination : (& destination str)]) : SourceToolLinkDestination
  (let
    [parent : String (fs.dirname destination)]
    [prefix : String ".typelisp-link"]
    (match (fs.try-create-temp-dir-in (& parent) (& prefix))
      [(OkIoString dir) (Private dir)]
      [(ErrIoString error)
        (match (source-tool-try-file-exists? (& parent))
          [(OkIoBool false) (Direct)]
          [_
            (Failed
              (str_cat.str-cat
                "build: failed to create a private link directory beside "
                (string.copy destination)
                ": "
                (io.error-message error)))])])))

;; Remove the private link directory and every file the tools wrote in it.
(define (source-tool-remove-private-link-dir [dir : (& dir str)]) : unit
  (match (fs.try-read-dir dir)
    [(OkIoStringVector entries)
      (for [index (iterator.range 0 (fs.string-vector-len (& entries)))]
        (let
          [name : String (fs.string-vector-get (& entries) index "")]
          (source-tool-try-remove-file-if-exists
            (& (fs.path-join dir (& name))))
          unit))]
    [(ErrIoStringVector _) unit])
  (source-tool-try-remove-dir-if-exists dir)
  unit)

;; A Windows `/DEBUG` link names its PDB after `/OUT`. Name it after the
;; destination instead, so the PDB keeps its place and embedded path.
(define (source-tool-link-inputs-for-destination
  [target : backend.CompilerBackendTarget]
  [link-dir : (& link-dir SourceToolLinkDestination)]
  [destination : (& destination str)]
  [inputs : SourceToolLinkInputs]) : SourceToolLinkInputs
  (match target
    [(Windows)
      (match link-dir
        [(Private _)
          (if (ir.compiler-debug-info-enabled?)
            (source-tool-link-inputs-add-raw-arg
              inputs
              (str_cat.str-cat
                "/PDB:"
                (source-tool-replace-extension (string.copy destination) ".pdb")))
            inputs)]
        [_ inputs])]
    [(Linux) inputs]))

;; Move a privately linked output onto its destination.
(define (source-tool-publish-linked-output
  [link-dir : (& link-dir SourceToolLinkDestination)]
  [linked : (& linked str)]
  [destination : (& destination str)]) : SourceToolCommandStatus
  (match link-dir
    [(Private _)
      (match (fs.try-atomic-replace linked destination)
        [(OkIoUnit) (Ok)]
        [(ErrIoUnit error)
          (Err
            (str_cat.str-cat
              "build: failed to replace "
              (string.copy destination)
              ": "
              (io.error-message error)))])]
    [_ (Ok)]))

(define (source-tool-build-source-in-temp
  [source : String]
  [output : String]
  [has-output : bool]
  [target : backend.CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [opt-level : i64]
  [mode : backend.CompilerBackendMode]
  [link-inputs : SourceToolLinkInputs]
  [temp-dir : String]) : i64
  (let
    [files : SourceToolTempFiles
      (source-tool-temp-files temp-dir source target)]
    ;; The executable goes beside the source (or to -o), not in the temp dir.
    [destination : String
      (if has-output
        output
        (source-tool-default-output
          (owned_view.compiler-owned-shared-view source)
          target))]
    [link-dir : SourceToolLinkDestination
      (source-tool-link-destination (& destination))]
    [status : i64
      (match (owned_view.compiler-owned-shared-view link-dir)
        [(Failed message)
          (io.print-error message)
          1]
        [_
          (set!
            files.bin
            (match (owned_view.compiler-owned-shared-view link-dir)
              [(Private dir)
                (fs.path-join (& dir) (& (fs.basename (& destination))))]
              [_ (string.copy destination)]))
          (match (source-tool-link-inputs-for-source
            (owned_view.compiler-owned-shared-view source)
            (owned_view.compiler-owned-shared-view stdlib-roots)
            (compiler_driver_core.compiler-driver-target-cfgs
              target
              (cfg_core.compiler-cfg-empty))
            link-inputs)
            [(Err message)
              (io.print-error message)
              1]
            [(Ok effective-link-inputs)
              (compiler_driver_core.compiler-driver-reset-file-state!)
              (match (source-tool-link-program
                (SourceToolLinkRequest
                  source
                  (Source stdlib-roots (cfg_core.compiler-cfg-empty))
                  target
                  opt-level
                  mode
                  (source-tool-link-inputs-for-destination
                    target
                    (& link-dir)
                    (& destination)
                    effective-link-inputs)
                  (owned_view.compiler-owned-shared-view files)
                  "build: failed to write assembly artifact"))
                [(Err message)
                  (io.print-error message)
                  1]
                [(Ok)
                  (match (source-tool-publish-linked-output
                    (& link-dir)
                    (& files.bin)
                    (& destination))
                    [(Err message)
                      (io.print-error message)
                      1]
                    [(Ok)
                      (io.print-format
                        "{}"
                        (str_cat.str-cat "Built " destination "\n"))
                      0])])])])]
    (source-tool-clean-temp-files files false)
    (match link-dir
      [(Private dir) (source-tool-remove-private-link-dir (& dir))]
      [_ unit])
    status))

(define (source-tool-build-source
  [source : String]
  [output : String]
  [has-output : bool]
  [target : backend.CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [opt-level : i64]
  [mode : backend.CompilerBackendMode]
  [link-inputs : SourceToolLinkInputs]) : i64
  (match (source-tool-create-temp-dir "typelisp-build")
    [(Ok temp-dir)
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
    [(Err message)
      (io.print-error
        (str_cat.str-cat "build: failed to create temp dir: " message))
      1]))

;: Run a user-facing executable while leaving child stdout/stderr connected to
;: the caller for live progress output.
(define (source-tool-run-executable-inherit
  [bin-path : String]
  [target : backend.CompilerBackendTarget]
  [runtime-args : process.ProcessStringList]) : process.ResultProcessOutput
  (process.inherit
    (source-tool-command-for-target
      target
      (process.command bin-path runtime-args))))

(define (source-tool-run-source-in-temp
  [source : String]
  [target : backend.CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [cfg-names : cli_svec.Vec]
  [runtime-args : process.ProcessStringList]
  [opt-level : i64]
  [mode : backend.CompilerBackendMode]
  [link-inputs : SourceToolLinkInputs]
  [stream-output : bool]
  [temp-dir : String]) : i64
  (let
    [files : SourceToolTempFiles
      (source-tool-temp-files temp-dir source target)]
    [status : i64
      (match (source-tool-link-inputs-for-source
        (owned_view.compiler-owned-shared-view source)
        (owned_view.compiler-owned-shared-view stdlib-roots)
        (compiler_driver_core.compiler-driver-target-cfgs
          target
          (source-tool-cfg-names-to-env
            (owned_view.compiler-owned-shared-view cfg-names)))
        link-inputs)
        [(Err message)
          (io.print-error message)
          1]
        [(Ok effective-link-inputs)
          (compiler_driver_core.compiler-driver-reset-file-state!)
          (match (source-tool-link-and-run
            (SourceToolLinkRequest
              source
              (Source stdlib-roots (source-tool-cfg-names-to-env cfg-names))
              target
              opt-level
              mode
              effective-link-inputs
              (owned_view.compiler-owned-shared-view files)
              "run: failed to write assembly artifact")
            runtime-args
            (process.env-empty)
            stream-output)
            [(LinkFailed message)
              (io.print-error message)
              1]
            [(Ran output)
              (let
                [status : i64 (process.output-status output)]
                (unless stream-output (source-tool-forward-output output))
                status)]
            [(SpawnFailed error)
              (io.print-error
                (str_cat.str-cat
                  "Error: failed to run executable '"
                  (owned_view.compiler-owned-shared-view files.bin)
                  "' for target "
                  (source-tool-target-name target)
                  ": "
                  (process.error-message error)))
              1])])]
    (source-tool-clean-temp-files files true)
    status))

(define (source-tool-run-source
  [source : String]
  [target : backend.CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [cfg-names : cli_svec.Vec]
  [runtime-args : process.ProcessStringList]
  [opt-level : i64]
  [mode : backend.CompilerBackendMode]
  [link-inputs : SourceToolLinkInputs]
  [stream-output : bool]) : i64
  (match (source-tool-create-temp-dir "typelisp-run")
    [(Ok temp-dir)
      (source-tool-run-source-in-temp
        source
        target
        stdlib-roots
        cfg-names
        runtime-args
        opt-level
        mode
        link-inputs
        stream-output
        temp-dir)]
    [(Err message)
      (io.print-error
        (str_cat.str-cat "run: failed to create temp dir: " message))
      1]))