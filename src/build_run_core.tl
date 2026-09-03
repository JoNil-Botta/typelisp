;; build_run_core.tl - Shared selfhost source build/run execution helpers.
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

(defstruct SourceToolLinkInputs
  (libs process.ProcessStringList)
  (search-dirs process.ProcessStringList)
  (raw-args process.ProcessStringList))

(defenum ResultSourceToolLinkInputs
  (Ok SourceToolLinkInputs)
  (Err String))

(defstruct SourceToolCfgNames
  (slots (__tl_dyn-array String))
  (len i64))

(define (source-tool-cfg-names-with-capacity [capacity : i64]) : SourceToolCfgNames
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (SourceToolCfgNames (__tl_make-array String cap) 0)))

(define (source-tool-cfg-names-empty) : SourceToolCfgNames
  (source-tool-cfg-names-with-capacity 4))

(define (source-tool-cfg-names-copy-range!
  [dst : (&mut dst (__tl_dyn-array String))]
  [src : (& src (__tl_dyn-array String))]
  [index : i64]
  [count : i64]) : unit
  (let
    [i : i64 index]
    (while (< i count)
      (begin
        (set! (array-ref dst i) (array-ref src i))
        (set! i (+ i 1))))))

(define (source-tool-cfg-names-grow! [names : (&mut names SourceToolCfgNames)]) : unit
  (let
    [count : i64 names.len]
    [old-cap : i64 (array-length names.slots)]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [bigger : (__tl_dyn-array String) (__tl_make-array String new-cap)]
    (begin
      (source-tool-cfg-names-copy-range! (&mut bigger) (& names.slots) 0 count)
      (set! names.slots bigger))))

(define (source-tool-cfg-names-push!
  [names : (&mut names SourceToolCfgNames)]
  [name : String]) : unit
  (begin
    (if (< names.len (array-length names.slots))
      unit
      (source-tool-cfg-names-grow! names))
    (let
      [index : i64 names.len]
      (begin
        (set! (array-ref names.slots index) name)
        (set! names.len (+ index 1))))))

(define (source-tool-cfg-names-get
  [names : (& names SourceToolCfgNames)]
  [index : i64]) : String
  (if (if (>= index 0)
    (< index names.len)
    false)
    (array-ref names.slots index)
    ""))

(define (source-tool-cfg-names-add [names : SourceToolCfgNames] [name : String]) : SourceToolCfgNames
  (let
    [next : SourceToolCfgNames (owned_view.compiler-owned-shared-view names)]
    (begin
      (source-tool-cfg-names-push! (&mut next) name)
      next)))

(define (source-tool-cfg-names-to-env-from
  [names : (& names SourceToolCfgNames)]
  [index : i64]
  [env : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (if (>= index names.len)
    env
    (source-tool-cfg-names-to-env-from
      names
      (+ index 1)
      (cfg_core.compiler-cfg-enable env (source-tool-cfg-names-get names index)))))

(define (source-tool-cfg-names-to-env [names : SourceToolCfgNames]) : sym_i64_env.SymI64Env
  (source-tool-cfg-names-to-env-from (& names) 0 (cfg_core.compiler-cfg-empty)))

(define (source-tool-target-name [target : backend.CompilerBackendTarget]) : String
  (match target
    [(backend.CompilerBackendTarget.Linux) "linux-x86_64"]
    [(backend.CompilerBackendTarget.Windows) "windows-x86_64"]))

(define (source-tool-default-target) : backend.CompilerBackendTarget
  (if (string.eq (env.path-separator) ";")
    (backend.CompilerBackendTarget.Windows)
    (backend.CompilerBackendTarget.Linux)))

(define (source-tool-default-target-name) : String
  (source-tool-target-name (source-tool-default-target)))

(define (source-tool-target [value : String]) : ResultSourceToolTarget
  (if (or (string.eq value "linux-x86_64") (string.eq value "linux_x86_64"))
    (ResultSourceToolTarget.Ok (backend.CompilerBackendTarget.Linux))
    (if (or
      (string.eq value "windows-x86_64")
      (string.eq value "windows_x86_64"))
      (ResultSourceToolTarget.Ok (backend.CompilerBackendTarget.Windows))
      (ResultSourceToolTarget.Err (str_cat.str-cat "unknown target " value)))))

(define (source-tool-backend-mode [command : String] [value : String]) : ResultSourceToolBackendMode
  (cond
    [(string.eq value "scalar")
      (ResultSourceToolBackendMode.Ok (backend.CompilerBackendMode.Scalar))]
    [(string.eq value "avx2")
      (ResultSourceToolBackendMode.Ok (backend.CompilerBackendMode.Avx2))]
    [(string.eq value "avx512")
      (ResultSourceToolBackendMode.Ok (backend.CompilerBackendMode.Avx512))]
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
;; static archives) as link inputs. They are passed verbatim as raw args
;; so both `ld` and MSVC `link.exe` treat them as positional inputs.
(define (source-tool-link-inputs-from-archives
  [archives : process.ProcessStringList]) : SourceToolLinkInputs
  (SourceToolLinkInputs (process.args-empty) (process.args-empty) archives))

(define (source-tool-link-inputs-libs [inputs : SourceToolLinkInputs]) : process.ProcessStringList
  inputs.libs)

(define (source-tool-link-inputs-search-dirs [inputs : SourceToolLinkInputs]) : process.ProcessStringList
  inputs.search-dirs)

(define (source-tool-link-inputs-raw-args [inputs : SourceToolLinkInputs]) : process.ProcessStringList
  inputs.raw-args)

(define (source-tool-link-inputs-empty?
  [inputs : (& inputs SourceToolLinkInputs)]) : bool
  (and
    (= (process.args-count inputs.libs) 0)
    (= (process.args-count inputs.search-dirs) 0)
    (= (process.args-count inputs.raw-args) 0)))

(define (source-tool-linux-crt-entry?
  [target : backend.CompilerBackendTarget]
  [link-inputs : SourceToolLinkInputs]) : bool
  (match target
    [(backend.CompilerBackendTarget.Linux)
      (not (source-tool-link-inputs-empty? link-inputs))]
    [(backend.CompilerBackendTarget.Windows) false]))

(define (source-tool-link-inputs-add-lib
  [inputs : SourceToolLinkInputs]
  [name : String]) : SourceToolLinkInputs
  (SourceToolLinkInputs
    (source-tool-args-append
      (source-tool-link-inputs-libs
        (owned_view.compiler-owned-shared-view inputs))
      name)
    (source-tool-link-inputs-search-dirs
      (owned_view.compiler-owned-shared-view inputs))
    (source-tool-link-inputs-raw-args inputs)))

(define (source-tool-link-inputs-add-search-dir
  [inputs : SourceToolLinkInputs]
  [dir : String]) : SourceToolLinkInputs
  (SourceToolLinkInputs
    (source-tool-link-inputs-libs
      (owned_view.compiler-owned-shared-view inputs))
    (source-tool-args-append
      (source-tool-link-inputs-search-dirs
        (owned_view.compiler-owned-shared-view inputs))
      dir)
    (source-tool-link-inputs-raw-args inputs)))

(define (source-tool-link-inputs-add-raw-arg
  [inputs : SourceToolLinkInputs]
  [arg-value : String]) : SourceToolLinkInputs
  (SourceToolLinkInputs
    (source-tool-link-inputs-libs
      (owned_view.compiler-owned-shared-view inputs))
    (source-tool-link-inputs-search-dirs
      (owned_view.compiler-owned-shared-view inputs))
    (source-tool-args-append
      (source-tool-link-inputs-raw-args inputs)
      arg-value)))

(define (source-tool-string-list-contains?
  [items : process.ProcessStringList]
  [value : String]) : bool
  (let
    [n : i64 (process.args-count items)]
    [i : i64 0]
    [found : bool false]
    (begin
      (while (and (< i n) (not found))
        (begin
          (if (string.eq (process.args-ref items i) value)
            (set! found true)
            unit)
          (set! i (+ i 1))))
      found)))

(define (source-tool-args-append-unique
  [items : process.ProcessStringList]
  [value : String]) : process.ProcessStringList
  (if (source-tool-string-list-contains?
    (owned_view.compiler-owned-shared-view items)
    (owned_view.compiler-owned-shared-view value))
    items
    (source-tool-args-append items value)))

(define (source-tool-string-list-merge-unique
  [left : process.ProcessStringList]
  [right : process.ProcessStringList]) : process.ProcessStringList
  (let
    [n : i64 (process.args-count right)]
    [i : i64 0]
    [out : process.ProcessStringList left]
    (begin
      (while (< i n)
        (begin
          (set!
            out
            (source-tool-args-append-unique out (process.args-ref right i)))
          (set! i (+ i 1))))
      out)))

(define (source-tool-string-list-eq?
  [left : process.ProcessStringList]
  [right : process.ProcessStringList]) : bool
  (let
    [n : i64 (process.args-count left)]
    [i : i64 0]
    [same : bool (= n (process.args-count right))]
    (begin
      (while (and same (< i n))
        (begin
          (if (string.eq (process.args-ref left i) (process.args-ref right i))
            unit
            (set! same false))
          (set! i (+ i 1))))
      same)))

(define (source-tool-link-inputs-merge
  [left : SourceToolLinkInputs]
  [right : SourceToolLinkInputs]) : SourceToolLinkInputs
  (SourceToolLinkInputs
    (source-tool-string-list-merge-unique
      (source-tool-link-inputs-libs
        (owned_view.compiler-owned-shared-view left))
      (source-tool-link-inputs-libs
        (owned_view.compiler-owned-shared-view right)))
    (source-tool-string-list-merge-unique
      (source-tool-link-inputs-search-dirs
        (owned_view.compiler-owned-shared-view left))
      (source-tool-link-inputs-search-dirs
        (owned_view.compiler-owned-shared-view right)))
    (source-tool-string-list-merge-unique
      (source-tool-link-inputs-raw-args left)
      (source-tool-link-inputs-raw-args right))))

(define (source-tool-link-inputs-add-ast
  [inputs : SourceToolLinkInputs]
  [item : ast.AstExternLinkInput]) : SourceToolLinkInputs
  (match item
    [(ast.AstExternLinkInput.Lib name)
      (SourceToolLinkInputs
        (source-tool-args-append-unique
          (source-tool-link-inputs-libs
            (owned_view.compiler-owned-shared-view inputs))
          name)
        (source-tool-link-inputs-search-dirs
          (owned_view.compiler-owned-shared-view inputs))
        (source-tool-link-inputs-raw-args inputs))]
    [(ast.AstExternLinkInput.Search dir)
      (SourceToolLinkInputs
        (source-tool-link-inputs-libs
          (owned_view.compiler-owned-shared-view inputs))
        (source-tool-args-append-unique
          (source-tool-link-inputs-search-dirs
            (owned_view.compiler-owned-shared-view inputs))
          dir)
        (source-tool-link-inputs-raw-args inputs))]
    [(ast.AstExternLinkInput.Arg arg-value)
      (SourceToolLinkInputs
        (source-tool-link-inputs-libs
          (owned_view.compiler-owned-shared-view inputs))
        (source-tool-link-inputs-search-dirs
          (owned_view.compiler-owned-shared-view inputs))
        (source-tool-args-append-unique
          (source-tool-link-inputs-raw-args inputs)
          arg-value))]))

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

(define (source-tool-link-inputs-eq?
  [left : SourceToolLinkInputs]
  [right : SourceToolLinkInputs]) : bool
  (and
    (source-tool-string-list-eq?
      (source-tool-link-inputs-libs
        (owned_view.compiler-owned-shared-view left))
      (source-tool-link-inputs-libs
        (owned_view.compiler-owned-shared-view right)))
    (source-tool-string-list-eq?
      (source-tool-link-inputs-search-dirs
        (owned_view.compiler-owned-shared-view left))
      (source-tool-link-inputs-search-dirs
        (owned_view.compiler-owned-shared-view right)))
    (source-tool-string-list-eq?
      (source-tool-link-inputs-raw-args left)
      (source-tool-link-inputs-raw-args right))))

(define (source-tool-link-inputs-dedupe-smoke-ok?) : bool
  (let
    [metadata-items : ast.AstExternLinkInputList
      (ast.ast-extern-link-input-list-new)]
    [metadata-inputs : SourceToolLinkInputs
      (begin
        (ast.ast-extern-link-input-list-push
          (&mut metadata-items)
          (ast.AstExternLinkInput.Lib "m"))
        (ast.ast-extern-link-input-list-push
          (&mut metadata-items)
          (ast.AstExternLinkInput.Lib "m"))
        (ast.ast-extern-link-input-list-push
          (&mut metadata-items)
          (ast.AstExternLinkInput.Search "native"))
        (ast.ast-extern-link-input-list-push
          (&mut metadata-items)
          (ast.AstExternLinkInput.Arg "-Wl,a"))
        (source-tool-link-inputs-add-ast-list
          (source-tool-link-inputs-empty)
          (& metadata-items)
          0))]
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
  [decls : ast.AstDeclList]
  [inputs : SourceToolLinkInputs]) : SourceToolLinkInputs
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) inputs]
    [(ast.AstDeclListStep.Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        (match (ast.ast-decl-unwrapped decl)
          [(ast.AstDecl.Extern decl-meta _ _ metadata _)
            (let
              [metadata-items : ast.AstExternLinkInputList
                (ast.ast-extern-metadata-link-inputs
                  (owned_view.compiler-owned-box-shared-view metadata))]
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
    (owned_view.compiler-owned-shared-view source)
    (sym_i64_env.sym-i64-empty)
    (owned_view.compiler-owned-shared-view stdlib-roots)
    cfgs)
    [(load.ResultCompilerLoadWithPaths.Ok decls _ _ _)
      (ResultSourceToolLinkInputs.Ok
        (source-tool-link-inputs-merge
          (source-tool-link-inputs-from-decls
            decls
            (source-tool-link-inputs-empty))
          explicit-inputs))]
    [(load.ResultCompilerLoadWithPaths.Err diag)
      (ResultSourceToolLinkInputs.Err
        (compiler_driver_core.compiler-driver-render-source-diagnostic
          (owned_view.compiler-owned-box-shared-view diag)))]))

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
  (fs.path-join (& left) (& right)))

(define (source-tool-fs-basename [path : String]) : String
  (fs.basename (& path)))

(define (source-tool-try-file-exists? [path : String]) : io.ResultIoBool
  (io.try-file-exists? (& path)))

(define (source-tool-try-read-file [path : String]) : io.ResultIoString
  (match (io.try-read-file (& path))
    [(io.OkIoBytes contents) (io.OkIoString (byte_buf.to-string contents))]
    [(io.ErrIoBytes error) (io.ErrIoString error)]))

(define (source-tool-try-remove-file-if-exists [path : String]) : io.ResultIoUnit
  (fs.try-remove-file-if-exists (& path)))

(define (source-tool-try-remove-dir-if-exists [path : String]) : io.ResultIoUnit
  (fs.try-remove-dir-if-exists (& path)))

(define (source-tool-stdout-write [text : String]) : unit
  (io.stdout-write (byte_buf.str-as-bytes (& text))))

(define (source-tool-stderr-write [text : String]) : unit
  (io.stderr-write (byte_buf.str-as-bytes (& text))))

(define (source-tool-path-command-exists? [candidate : String]) : bool
  (match (source-tool-try-file-exists? candidate)
    [(io.OkIoBool exists) exists]
    [(io.ErrIoBool _) false]))

(define (source-tool-windows-host?) : bool
  (string.eq (env.path-separator) ";"))

(define (source-tool-windows-exe-candidate [candidate : String]) : String
  (if (source-tool-windows-host?)
    (str_cat.str-cat candidate ".exe")
    candidate))

(define (source-tool-find-command-on-path-from
  [tool : String]
  [paths : env.EnvStringList]
  [index : i64]) : String
  (if (>= index (env.string-list-count paths))
    tool
    (let
      [candidate : String
        (source-tool-path-entry-command
          (env.string-list-ref paths index)
          (owned_view.compiler-owned-shared-view tool))]
      (if (source-tool-path-command-exists?
        (owned_view.compiler-owned-shared-view candidate))
        candidate
        (let
          [exe-candidate : String
            (source-tool-windows-exe-candidate
              (owned_view.compiler-owned-shared-view candidate))]
          (if (and
            (not (string.eq exe-candidate candidate))
            (source-tool-path-command-exists?
              (owned_view.compiler-owned-shared-view exe-candidate)))
            exe-candidate
            (source-tool-find-command-on-path-from tool paths (+ index 1))))))))

(define (source-tool-find-command-on-path
  [tool : String]
  [paths : env.EnvStringList]) : String
  (source-tool-find-command-on-path-from tool paths 0))

(define (source-tool-resolve-command [tool : String]) : String
  (if (source-tool-has-path-separator?
    (owned_view.compiler-owned-shared-view tool))
    tool
    (let
      [name : String "PATH"]
      (match (env.path-list (& name))
        [(env.EnvSomeStringList paths)
          (source-tool-find-command-on-path tool paths)]
        [(env.EnvNoStringList) tool]))))

(define (source-tool-env-command-or-default
  [name : String]
  [default-command : String]) : String
  (match (env.get (& name))
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
  (match (env.get (& name))
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
  [target : backend.CompilerBackendTarget]) : String
  (match target
    [(backend.CompilerBackendTarget.Linux)
      (source-tool-replace-extension source "")]
    [(backend.CompilerBackendTarget.Windows)
      (source-tool-replace-extension source ".exe")]))

(define (source-tool-object-extension [target : backend.CompilerBackendTarget]) : String
  (match target
    [(backend.CompilerBackendTarget.Linux) "o"]
    [(backend.CompilerBackendTarget.Windows) "obj"]))

(define (source-tool-executable-extension
  [target : backend.CompilerBackendTarget]) : String
  (match target
    [(backend.CompilerBackendTarget.Linux) ""]
    [(backend.CompilerBackendTarget.Windows) ".exe"]))

(define (source-tool-static-library-extension
  [target : backend.CompilerBackendTarget]) : String
  (match target
    [(backend.CompilerBackendTarget.Linux) ".a"]
    [(backend.CompilerBackendTarget.Windows) ".lib"]))

(define (source-tool-static-library-filename
  [name : String]
  [target : backend.CompilerBackendTarget]) : String
  (match target
    [(backend.CompilerBackendTarget.Linux)
      (str_cat.str-cat "lib" name (source-tool-static-library-extension target))]
    [(backend.CompilerBackendTarget.Windows)
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
  [target : backend.CompilerBackendTarget]) : String
  (source-tool-fs-path-join
    temp-dir
    (str_cat.str-cat
      (source-tool-artifact-stem source)
      "."
      (source-tool-object-extension target))))

(define (source-tool-temp-bin-path
  [temp-dir : String]
  [source : String]
  [target : backend.CompilerBackendTarget]) : String
  (source-tool-fs-path-join
    temp-dir
    (str_cat.str-cat
      (source-tool-artifact-stem source)
      (source-tool-executable-extension target))))

(define (source-tool-create-temp-dir [prefix : String]) : ResultSourceToolString
  (match (fs.try-create-temp-dir (& prefix))
    [(io.OkIoString path) (ResultSourceToolString.Ok path)]
    [(io.ErrIoString error)
      (ResultSourceToolString.Err (io.error-message error))]))

(define (source-tool-cannot-read-module-message
  [source : String]
  [error : io.IoError]) : String
  (str_cat.str-cat
    "Error: cannot read module '"
    (owned_view.compiler-owned-shared-view source)
    "': "
    (io.error-message error)))

(define (source-tool-emit-assembly
  [source : String]
  [target : backend.CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [opt-level : i64]
  [mode : backend.CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]
  [link-inputs : SourceToolLinkInputs]) : ResultSourceToolString
  (match (source-tool-try-read-file
    (owned_view.compiler-owned-shared-view source))
    [(io.ErrIoString error)
      (ResultSourceToolString.Err
        (source-tool-cannot-read-module-message source error))]
    [(io.OkIoString _)
      (match (compiler_driver_core.compiler-driver-emit-file-with-target-roots-level-mode-cfg-and-crt
        source
        target
        true
        stdlib-roots
        opt-level
        mode
        cfgs
        (source-tool-linux-crt-entry? target link-inputs))
        [(compiler_driver_core.ResultCompilerDriver.Ok asm)
          (ResultSourceToolString.Ok
            (source-tool-augment-assembly-for-target asm target))]
        [(compiler_driver_core.ResultCompilerDriver.Err diag)
          (ResultSourceToolString.Err
            (compiler_driver_core.compiler-driver-render-source-diagnostic
              (owned_view.compiler-owned-box-shared-view diag)))])]))

(define (source-tool-linux-direct-object-env-name) : String
  "TYPELISP_LINUX_DIRECT_OBJECT")

(define (source-tool-linux-direct-object-enabled?) : bool
  (source-tool-env-command-set? (source-tool-linux-direct-object-env-name)))

(define (source-tool-linux-direct-object-linkable?
  [image : cobj.CompilerObjectImage]) : bool
  (and
    (compiler_object_elf.compiler-object-elf-image-supported?
      (owned_view.compiler-owned-shared-view image))
    (or
      (cobj.compiler-object-symbol-list-contains?
        (owned_view.compiler-owned-shared-view image.symbols)
        "_tl_start"
        (cobj.CompilerObjectSymbolBinding.Export)
        (cobj.CompilerObjectSymbolKind.Function))
      (cobj.compiler-object-symbol-list-contains?
        (owned_view.compiler-owned-shared-view image.symbols)
        "main"
        (cobj.CompilerObjectSymbolBinding.Export)
        (cobj.CompilerObjectSymbolKind.Function)))
    (>
      (compiler_object_elf.compiler-object-elf-section-raw-size
        (owned_view.compiler-owned-shared-view image)
        (cobj.CompilerObjectSectionKind.Text))
      0)))

(define (source-tool-linux-direct-object-archivable?
  [image : cobj.CompilerObjectImage]) : bool
  (compiler_object_elf.compiler-object-elf-image-supported?
    (owned_view.compiler-owned-shared-view image)))

(define (source-tool-linux-direct-object-unavailable-message) : String
  "linux direct object unavailable: object image lacks encoded .text or entry symbol")

(define (source-tool-linux-direct-object-archive-unavailable-message) : String
  "linux direct object unavailable: object image has unsupported ELF records")

(define (source-tool-render-linkable-linux-elf-object
  [image : cobj.CompilerObjectImage]) : ResultSourceToolString
  (if (source-tool-linux-direct-object-linkable?
    (owned_view.compiler-owned-shared-view image))
    (match (compiler_object_elf.compiler-object-elf-render
      (owned_view.compiler-owned-shared-view image))
      [(compiler_object_elf.ResultCompilerObjectElf.Ok obj)
        (ResultSourceToolString.Ok obj)]
      [(compiler_object_elf.ResultCompilerObjectElf.Err message)
        (ResultSourceToolString.Err message)])
    (ResultSourceToolString.Err
      (source-tool-linux-direct-object-unavailable-message))))

(define (source-tool-render-archivable-linux-elf-object
  [image : cobj.CompilerObjectImage]) : ResultSourceToolString
  (if (source-tool-linux-direct-object-archivable?
    (owned_view.compiler-owned-shared-view image))
    (match (compiler_object_elf.compiler-object-elf-render
      (owned_view.compiler-owned-shared-view image))
      [(compiler_object_elf.ResultCompilerObjectElf.Ok obj)
        (ResultSourceToolString.Ok obj)]
      [(compiler_object_elf.ResultCompilerObjectElf.Err message)
        (ResultSourceToolString.Err message)])
    (ResultSourceToolString.Err
      (source-tool-linux-direct-object-archive-unavailable-message))))

(define (source-tool-emit-linux-elf-object
  [source : String]
  [target : backend.CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [opt-level : i64]
  [mode : backend.CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]
  [link-inputs : SourceToolLinkInputs]) : ResultSourceToolString
  (match target
    [(backend.CompilerBackendTarget.Linux)
      (match (source-tool-try-read-file
        (owned_view.compiler-owned-shared-view source))
        [(io.ErrIoString error)
          (ResultSourceToolString.Err
            (source-tool-cannot-read-module-message
              (owned_view.compiler-owned-shared-view source)
              error))]
        [(io.OkIoString _)
          (match (compiler_driver_core.compiler-driver-emit-file-object-image-with-target-roots-level-mode-cfg-and-crt
            (owned_view.compiler-owned-shared-view source)
            target
            true
            stdlib-roots
            opt-level
            mode
            cfgs
            (source-tool-linux-crt-entry? target link-inputs))
            [(compiler_driver_core.ResultCompilerDriverObject.Ok image)
              (source-tool-render-linkable-linux-elf-object image)]
            [(compiler_driver_core.ResultCompilerDriverObject.Unavailable
                category)
              (ResultSourceToolString.Err category)]
            [(compiler_driver_core.ResultCompilerDriverObject.Err diag)
              (ResultSourceToolString.Err
                (compiler_driver_core.compiler-driver-render-source-diagnostic
                  (owned_view.compiler-owned-box-shared-view diag)))])])]
    [(backend.CompilerBackendTarget.Windows)
      (ResultSourceToolString.Err
        "direct ELF object emission is only available for linux-x86_64")]))

(define (source-tool-emit-lowered-linux-elf-object
  [source : String]
  [program : ir.CompilerIrProgram]
  [spans : ir.CompilerSourceSpans]
  [target : backend.CompilerBackendTarget]
  [opt-level : i64]
  [link-inputs : SourceToolLinkInputs]) : ResultSourceToolString
  (match target
    [(backend.CompilerBackendTarget.Linux)
      (match (compiler_driver_core.compiler-driver-emit-lowered-object-image-with-level-mode-entry-and-crt
        (ast.ast-node-pool-reader-context-current)
        source
        program
        spans
        target
        true
        (backend.CompilerBackendMode.Scalar)
        opt-level
        true
        (source-tool-linux-crt-entry? target link-inputs))
        [(compiler_driver_core.ResultCompilerDriverObject.Ok image)
          (source-tool-render-linkable-linux-elf-object image)]
        [(compiler_driver_core.ResultCompilerDriverObject.Unavailable category)
          (ResultSourceToolString.Err category)]
        [(compiler_driver_core.ResultCompilerDriverObject.Err diag)
          (ResultSourceToolString.Err
            (compiler_driver_core.compiler-driver-render-source-diagnostic
              (owned_view.compiler-owned-box-shared-view diag)))])]
    [(backend.CompilerBackendTarget.Windows)
      (ResultSourceToolString.Err
        "direct ELF object emission is only available for linux-x86_64")]))

(define (source-tool-windows-direct-object-env-name) : String
  "TYPELISP_WINDOWS_DIRECT_OBJECT")

(define (source-tool-windows-direct-object-enabled?) : bool
  (source-tool-env-command-set? (source-tool-windows-direct-object-env-name)))

(define (source-tool-windows-direct-object-relocations-linkable?
  [symbols : cobj.CompilerObjectSymbolList]
  [relocs : cobj.CompilerObjectRelocationList]) : bool
  (compiler_windows_coff_core.compiler-windows-coff-relocations-linkable?
    symbols
    relocs))

(define (source-tool-windows-direct-object-linkable?
  [image : cobj.CompilerObjectImage]) : bool
  (compiler_windows_coff_core.compiler-windows-coff-linkable? image))

(define (source-tool-windows-direct-object-unavailable-message) : String
  "windows direct object unavailable: object image lacks encoded .text, _tl_start, or Windows runtime entry body")

(define (source-tool-render-linkable-windows-coff-object
  [image : cobj.CompilerObjectImage]) : ResultSourceToolString
  (if (source-tool-windows-direct-object-linkable?
    (owned_view.compiler-owned-shared-view image))
    (match (compiler_object_coff.compiler-object-coff-render
      (owned_view.compiler-owned-shared-view image))
      [(compiler_object_coff.ResultCompilerObjectCoff.Ok obj)
        (ResultSourceToolString.Ok obj)]
      [(compiler_object_coff.ResultCompilerObjectCoff.Err message)
        (ResultSourceToolString.Err message)])
    (ResultSourceToolString.Err
      (source-tool-windows-direct-object-unavailable-message))))

(define (source-tool-emit-windows-coff-object
  [source : String]
  [target : backend.CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [opt-level : i64]
  [mode : backend.CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]
  [link-inputs : SourceToolLinkInputs]) : ResultSourceToolString
  (match target
    [(backend.CompilerBackendTarget.Linux)
      (ResultSourceToolString.Err
        "direct COFF object emission is only available for windows-x86_64")]
    [(backend.CompilerBackendTarget.Windows)
      (match (source-tool-try-read-file
        (owned_view.compiler-owned-shared-view source))
        [(io.ErrIoString error)
          (ResultSourceToolString.Err
            (source-tool-cannot-read-module-message
              (owned_view.compiler-owned-shared-view source)
              error))]
        [(io.OkIoString _)
          (match (compiler_driver_core.compiler-driver-emit-file-object-image-with-target-roots-level-mode-cfg-and-crt
            (owned_view.compiler-owned-shared-view source)
            target
            true
            stdlib-roots
            opt-level
            mode
            cfgs
            (source-tool-linux-crt-entry? target link-inputs))
            [(compiler_driver_core.ResultCompilerDriverObject.Ok image)
              (source-tool-render-linkable-windows-coff-object image)]
            [(compiler_driver_core.ResultCompilerDriverObject.Unavailable
                category)
              (ResultSourceToolString.Err category)]
            [(compiler_driver_core.ResultCompilerDriverObject.Err diag)
              (ResultSourceToolString.Err
                (compiler_driver_core.compiler-driver-render-source-diagnostic
                  (owned_view.compiler-owned-box-shared-view diag)))])])]))

(define (source-tool-emit-lowered-windows-coff-object
  [source : String]
  [program : ir.CompilerIrProgram]
  [spans : ir.CompilerSourceSpans]
  [target : backend.CompilerBackendTarget]
  [opt-level : i64]) : ResultSourceToolString
  (match target
    [(backend.CompilerBackendTarget.Linux)
      (ResultSourceToolString.Err
        "direct COFF object emission is only available for windows-x86_64")]
    [(backend.CompilerBackendTarget.Windows)
      (match (compiler_driver_core.compiler-driver-emit-lowered-object-image-with-level-mode-entry-and-crt
        (ast.ast-node-pool-reader-context-current)
        source
        program
        spans
        target
        true
        (backend.CompilerBackendMode.Scalar)
        opt-level
        true
        false)
        [(compiler_driver_core.ResultCompilerDriverObject.Ok image)
          (source-tool-render-linkable-windows-coff-object image)]
        [(compiler_driver_core.ResultCompilerDriverObject.Unavailable category)
          (ResultSourceToolString.Err category)]
        [(compiler_driver_core.ResultCompilerDriverObject.Err diag)
          (ResultSourceToolString.Err
            (compiler_driver_core.compiler-driver-render-source-diagnostic
              (owned_view.compiler-owned-box-shared-view diag)))])]))

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
  [path : String]
  [contents : String]
  [context : String]) : SourceToolCommandStatus
  (match (io.try-write-file (& path) (byte_buf.str-as-bytes (& contents)))
    [(io.OkIoUnit) SourceToolCommandStatus.Ok]
    [(io.ErrIoUnit error)
      (SourceToolCommandStatus.Err
        (str_cat.str-cat context ": " (io.error-message error)))]))

(define (source-tool-forward-output [output : process.ProcessOutput]) : unit
  (begin
    (source-tool-stdout-write (process.output-stdout output))
    (source-tool-stderr-write (process.output-stderr output))))

(define (source-tool-run-command
  [role : String]
  [target : backend.CompilerBackendTarget]
  [command : process.ProcessCommand]) : SourceToolCommandStatus
  (let
    [tool : String (process.command-executable command)]
    [command-to-run : process.ProcessCommand
      (source-tool-command-for-target target command)]
    (match (process.output command-to-run)
      [(process.OkProcessOutput output)
        (begin
          (source-tool-forward-output
            (owned_view.compiler-owned-shared-view output))
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
  (process.args-append
    (source-tool-linux-link-search-args
      (source-tool-link-inputs-search-dirs
        (owned_view.compiler-owned-shared-view inputs)))
    (process.args-append
      (source-tool-linux-link-lib-args
        (source-tool-link-inputs-libs
          (owned_view.compiler-owned-shared-view inputs)))
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

;; Freestanding Win32: no CRT (no vcruntime140/ucrt/msvcrt) and only the
;; audited kernel32 plus ntdll system boundary.
;; The backend emits its own entry (_tl_start) plus kernel32-backed shims for the
;; CRT-ABI symbols the runtime/stdlib reference. Stdlib random seeding uses
;; kernel32 FFI only, so no advapi32; no COM (ole32/oleaut32) is needed either.
(define (source-tool-windows-link-libs) : process.ProcessStringList
  (process.args-cons
    "kernel32.lib"
    (process.args-cons "ntdll.lib" (process.args-empty))))

(define (source-tool-windows-system-libs-smoke-ok?) : bool
  (let
    [libs : process.ProcessStringList (source-tool-windows-link-libs)]
    (and
      (= (process.args-count libs) 2)
      (string.eq (process.args-ref libs 0) "kernel32.lib")
      (string.eq (process.args-ref libs 1) "ntdll.lib"))))

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

(define (source-tool-link-inputs-windows-args [inputs : SourceToolLinkInputs]) : process.ProcessStringList
  (process.args-append
    (source-tool-windows-link-search-args
      (source-tool-link-inputs-search-dirs
        (owned_view.compiler-owned-shared-view inputs)))
    (process.args-append
      (source-tool-windows-link-lib-args
        (source-tool-link-inputs-libs
          (owned_view.compiler-owned-shared-view inputs)))
      (source-tool-link-inputs-raw-args inputs))))

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
      (if (ir.compiler-debug-info-enabled?)
        (process.args-cons "/DEBUG" args)
        args))))

(define (source-tool-windows-stack-reserve-smoke-ok?) : bool
  (source-tool-string-list-contains?
    (source-tool-windows-linker-args
      "input.obj"
      "output.exe"
      (source-tool-link-inputs-empty))
    (source-tool-windows-stack-reserve-arg)))

(define (source-tool-windows-debug-linker-smoke-ok?) : bool
  (let
    [previous : bool (ir.compiler-debug-info-enabled?)]
    [ok : bool false]
    (begin
      (ir.compiler-debug-info-set-enabled! true)
      (set!
        ok
        (source-tool-string-list-contains?
          (source-tool-windows-linker-args
            "input.obj"
            "output.exe"
            (source-tool-link-inputs-empty))
          "/DEBUG"))
      (ir.compiler-debug-info-set-enabled! previous)
      ok)))

(define (source-tool-linux-direct-object-linkability-smoke-ok?) : bool
  (match (backend.compiler-backend-emit-source-object-image-for-target
    "(define answer : i64 40)
(define (inc [x : i64]) : i64 (+ x 1))
(define (main) : i64 (inc answer))"
    (backend.CompilerBackendTarget.Linux))
    [(backend.ResultCompilerBackendObject.Ok image)
      (if (source-tool-linux-direct-object-linkable?
        (owned_view.compiler-owned-shared-view image))
        (match (source-tool-render-linkable-linux-elf-object
          (owned_view.compiler-owned-shared-view image))
          [(ResultSourceToolString.Ok obj) (> (string.string-length obj) 0)]
          [(ResultSourceToolString.Err _) false])
        false)]
    [(backend.ResultCompilerBackendObject.Err _) false]))

(define (source-tool-windows-direct-object-linkability-smoke-ok?) : bool
  (match (backend.compiler-backend-emit-source-object-image-for-target
    "(extern (unused-direct [value : i64]) : i64
  (:symbol \"typelisp_unused_direct\"))
(extern unused-data (:symbol \"typelisp_unused_data\") : i64)
(extern unused-fnptr (:symbol \"typelisp_unused_fnptr\") : (-> i64 i64))
(define (main) : i64 0)"
    (backend.CompilerBackendTarget.Windows))
    [(backend.ResultCompilerBackendObject.Ok image)
      (if (source-tool-windows-direct-object-linkable?
        (owned_view.compiler-owned-shared-view image))
        (match (source-tool-render-linkable-windows-coff-object
          (owned_view.compiler-owned-shared-view image))
          [(ResultSourceToolString.Ok obj) (> (string.string-length obj) 0)]
          [(ResultSourceToolString.Err _) false])
        false)]
    [(backend.ResultCompilerBackendObject.Err _) false]))

(define (source-tool-windows-direct-object-runtime-fallback-smoke-ok?) : bool
  (match (backend.compiler-backend-emit-source-object-image-for-target
    "(define (main) : i64
  (let [items : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    (array-length items)))"
    (backend.CompilerBackendTarget.Windows))
    [(backend.ResultCompilerBackendObject.Ok image)
      (not (source-tool-windows-direct-object-linkable? image))]
    [(backend.ResultCompilerBackendObject.Err _) false]))

(define (source-tool-windows-direct-object-relocation-gate-smoke-ok?) : bool
  (let
    [symbols0 : cobj.CompilerObjectSymbolBuilder
      (cobj.compiler-object-symbol-builder-with-capacity 4)]
    [symbols1 : cobj.CompilerObjectSymbolBuilder
      (cobj.compiler-object-symbol-builder-push
        symbols0
        (cobj.CompilerObjectSymbol.Symbol
          "GetStdHandle"
          (cobj.CompilerObjectSymbolBinding.Extern)
          (cobj.CompilerObjectSymbolKind.Function)
          cobj.CompilerObjectMaybeSection.No))]
    [symbols2 : cobj.CompilerObjectSymbolBuilder
      (cobj.compiler-object-symbol-builder-push
        symbols1
        (cobj.CompilerObjectSymbol.Symbol
          "NtCreateFile"
          (cobj.CompilerObjectSymbolBinding.Extern)
          (cobj.CompilerObjectSymbolKind.Function)
          cobj.CompilerObjectMaybeSection.No))]
    [symbols3 : cobj.CompilerObjectSymbolBuilder
      (cobj.compiler-object-symbol-builder-push
        symbols2
        (cobj.CompilerObjectSymbol.Symbol
          "GetCurrentProcessId"
          (cobj.CompilerObjectSymbolBinding.Extern)
          (cobj.CompilerObjectSymbolKind.Function)
          cobj.CompilerObjectMaybeSection.No))]
    [symbols4 : cobj.CompilerObjectSymbolBuilder
      (cobj.compiler-object-symbol-builder-push
        symbols3
        (cobj.CompilerObjectSymbol.Symbol
          "NtOpenFile"
          (cobj.CompilerObjectSymbolBinding.Extern)
          (cobj.CompilerObjectSymbolKind.Function)
          cobj.CompilerObjectMaybeSection.No))]
    [symbols : cobj.CompilerObjectSymbolList
      (cobj.compiler-object-symbol-builder-finish symbols4)]
    [empty-relocs : cobj.CompilerObjectRelocationList
      (cobj.compiler-object-relocation-builder-finish
        (cobj.compiler-object-relocation-builder-with-capacity 1))]
    [allowed-relocs : cobj.CompilerObjectRelocationList
      (cobj.compiler-object-relocation-builder-finish
        (cobj.compiler-object-relocation-builder-push
          (cobj.compiler-object-relocation-builder-push
            (cobj.compiler-object-relocation-builder-with-capacity 2)
            (cobj.CompilerObjectRelocation.Relocation
              (cobj.CompilerObjectSectionKind.Text)
              "main"
              (cobj.CompilerObjectRelocationKind.Call)
              "GetStdHandle"))
          (cobj.CompilerObjectRelocation.Relocation
            (cobj.CompilerObjectSectionKind.Text)
            "main"
            (cobj.CompilerObjectRelocationKind.Call)
            "NtCreateFile")))]
    [blocked-win32-relocs : cobj.CompilerObjectRelocationList
      (cobj.compiler-object-relocation-builder-finish
        (cobj.compiler-object-relocation-builder-push
          (cobj.compiler-object-relocation-builder-with-capacity 1)
          (cobj.CompilerObjectRelocation.Relocation
            (cobj.CompilerObjectSectionKind.Text)
            "main"
            (cobj.CompilerObjectRelocationKind.Call)
            "GetCurrentProcessId")))]
    [blocked-ntdll-relocs : cobj.CompilerObjectRelocationList
      (cobj.compiler-object-relocation-builder-finish
        (cobj.compiler-object-relocation-builder-push
          (cobj.compiler-object-relocation-builder-with-capacity 1)
          (cobj.CompilerObjectRelocation.Relocation
            (cobj.CompilerObjectSectionKind.Text)
            "main"
            (cobj.CompilerObjectRelocationKind.Call)
            "NtOpenFile")))]
    (and
      (source-tool-windows-direct-object-relocations-linkable?
        (owned_view.compiler-owned-shared-view symbols)
        empty-relocs)
      (source-tool-windows-direct-object-relocations-linkable?
        (owned_view.compiler-owned-shared-view symbols)
        allowed-relocs)
      (not
        (source-tool-windows-direct-object-relocations-linkable?
          (owned_view.compiler-owned-shared-view symbols)
          blocked-win32-relocs))
      (not
        (source-tool-windows-direct-object-relocations-linkable?
          symbols
          blocked-ntdll-relocs)))))

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
      (match (msvc.find-tool (& target) (& tool))
        [(msvc.OkMsvcTool resolved-tool)
          (ResultSourceToolCommand.Ok
            (process.command-with-env-list
              (process.command
                (msvc.tool-executable resolved-tool)
                (source-tool-windows-linker-args obj-path bin-path link-inputs))
              (msvc.tool-process-env resolved-tool)))]
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

(define (source-tool-ascii-case-eq [left : String] [right : String]) : bool
  (let
    [left-n : i64 (string.string-length left)]
    [right-n : i64 (string.string-length right)]
    [i : i64 0]
    [same : bool (= left-n right-n)]
    (begin
      (while (and same (< i left-n))
        (begin
          (if (=
            (source-tool-ascii-fold-char (string.string-ref left i))
            (source-tool-ascii-fold-char (string.string-ref right i)))
            unit
            (set! same false))
          (set! i (+ i 1))))
      same)))

(define (source-tool-windows-llvm-archiver-name? [command : String]) : bool
  (let
    [basename : String (source-tool-fs-basename command)]
    (or
      (source-tool-ascii-case-eq
        (owned_view.compiler-owned-shared-view basename)
        "llvm-ar")
      (source-tool-ascii-case-eq basename "llvm-ar.exe"))))

(define (source-tool-windows-msvc-archiver-name? [command : String]) : bool
  (let
    [basename : String (source-tool-fs-basename command)]
    (or
      (source-tool-ascii-case-eq
        (owned_view.compiler-owned-shared-view basename)
        "lib")
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
      [(source-tool-windows-llvm-archiver-name?
          (owned_view.compiler-owned-shared-view command))
        (ResultSourceToolCommand.Ok
          (source-tool-windows-llvm-archiver-command
            command
            obj-path
            archive-path))]
      [(source-tool-windows-msvc-archiver-name?
          (owned_view.compiler-owned-shared-view command))
        (ResultSourceToolCommand.Ok
          (process.command
            command
            (source-tool-windows-msvc-archiver-args obj-path archive-path)))]
      [else
        (ResultSourceToolCommand.Err
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
        [(msvc.OkMsvcTool resolved-tool)
          (ResultSourceToolCommand.Ok
            (process.command-with-env-list
              (process.command
                (msvc.tool-executable resolved-tool)
                (source-tool-windows-msvc-archiver-args obj-path archive-path))
              (msvc.tool-process-env resolved-tool)))]
        [(msvc.ErrMsvcTool _)
          (ResultSourceToolCommand.Ok
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
  (begin
    (source-tool-try-remove-file-if-exists asm-path)
    (source-tool-try-remove-file-if-exists obj-path)
    (if remove-bin
      (source-tool-try-remove-file-if-exists bin-path)
      io.OkIoUnit)
    (source-tool-try-remove-dir-if-exists temp-dir)
    unit))

(define (source-tool-assemble
  [target : backend.CompilerBackendTarget]
  [asm-path : String]
  [obj-path : String]) : SourceToolCommandStatus
  (match target
    [(backend.CompilerBackendTarget.Linux)
      (source-tool-run-command
        "assembler"
        target
        (source-tool-assembler-command asm-path obj-path))]
    [(backend.CompilerBackendTarget.Windows)
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
    [(backend.CompilerBackendTarget.Linux)
      (source-tool-run-command
        "linker"
        target
        (source-tool-linker-command obj-path bin-path link-inputs))]
    [(backend.CompilerBackendTarget.Windows)
      (match (source-tool-windows-linker-command obj-path bin-path link-inputs)
        [(ResultSourceToolCommand.Ok command)
          (source-tool-run-command "linker" target command)]
        [(ResultSourceToolCommand.Err message)
          (SourceToolCommandStatus.Err message)])]))

(define (source-tool-archive
  [target : backend.CompilerBackendTarget]
  [obj-path : String]
  [archive-path : String]) : SourceToolCommandStatus
  (match target
    [(backend.CompilerBackendTarget.Linux)
      (source-tool-run-command
        "archiver"
        target
        (source-tool-archiver-command obj-path archive-path))]
    [(backend.CompilerBackendTarget.Windows)
      (match (source-tool-windows-archiver-command obj-path archive-path)
        [(ResultSourceToolCommand.Ok command)
          (source-tool-run-command "archiver" target command)]
        [(ResultSourceToolCommand.Err message)
          (SourceToolCommandStatus.Err message)])]))

(define (source-tool-assemble-and-link
  [target : backend.CompilerBackendTarget]
  [asm-path : String]
  [obj-path : String]
  [bin-path : String]
  [link-inputs : SourceToolLinkInputs]) : SourceToolCommandStatus
  (match (source-tool-assemble
    target
    asm-path
    (owned_view.compiler-owned-shared-view obj-path))
    [(SourceToolCommandStatus.Ok)
      (source-tool-link target obj-path bin-path link-inputs)]
    [(SourceToolCommandStatus.Err message)
      (SourceToolCommandStatus.Err message)]))

(define (source-tool-assemble-and-archive
  [target : backend.CompilerBackendTarget]
  [asm-path : String]
  [obj-path : String]
  [archive-path : String]) : SourceToolCommandStatus
  (match (source-tool-assemble
    target
    asm-path
    (owned_view.compiler-owned-shared-view obj-path))
    [(SourceToolCommandStatus.Ok)
      (source-tool-archive target obj-path archive-path)]
    [(SourceToolCommandStatus.Err message)
      (SourceToolCommandStatus.Err message)]))

(define (source-tool-write-direct-object-and-link
  [obj-path : String]
  [bin-path : String]
  [target : backend.CompilerBackendTarget]
  [link-inputs : SourceToolLinkInputs]
  [obj : String]
  [context : String]) : SourceToolDirectObjectStatus
  (match (source-tool-write-file
    (owned_view.compiler-owned-shared-view obj-path)
    obj
    context)
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
  [target : backend.CompilerBackendTarget]
  [obj : String]
  [context : String]) : SourceToolDirectObjectStatus
  (match (source-tool-write-file
    (owned_view.compiler-owned-shared-view obj-path)
    obj
    context)
    [(SourceToolCommandStatus.Err message)
      (SourceToolDirectObjectStatus.Err message)]
    [(SourceToolCommandStatus.Ok)
      (match (source-tool-archive target obj-path archive-path)
        [(SourceToolCommandStatus.Ok) SourceToolDirectObjectStatus.Ok]
        [(SourceToolCommandStatus.Err message)
          (SourceToolDirectObjectStatus.Err message)])]))

(define (source-tool-try-windows-direct-object-and-link
  [source : String]
  [target : backend.CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [opt-level : i64]
  [mode : backend.CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]
  [link-inputs : SourceToolLinkInputs]
  [obj-path : String]
  [bin-path : String]) : SourceToolDirectObjectStatus
  (if (and
    (not (ir.compiler-debug-info-enabled?))
    (source-tool-windows-direct-object-enabled?)
    (backend.compiler-backend-target-windows? target))
    (match (source-tool-emit-windows-coff-object
      source
      target
      stdlib-roots
      opt-level
      mode
      cfgs
      (owned_view.compiler-owned-shared-view link-inputs))
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
  [target : backend.CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [opt-level : i64]
  [mode : backend.CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]
  [link-inputs : SourceToolLinkInputs]
  [obj-path : String]
  [bin-path : String]) : SourceToolDirectObjectStatus
  (if (and
    (not (ir.compiler-debug-info-enabled?))
    (source-tool-linux-direct-object-enabled?)
    (backend.compiler-backend-target-linux? target))
    (match (source-tool-emit-linux-elf-object
      source
      target
      stdlib-roots
      opt-level
      mode
      cfgs
      (owned_view.compiler-owned-shared-view link-inputs))
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
  [program : ir.CompilerIrProgram]
  [spans : ir.CompilerSourceSpans]
  [target : backend.CompilerBackendTarget]
  [opt-level : i64]
  [link-inputs : SourceToolLinkInputs]
  [obj-path : String]
  [bin-path : String]) : SourceToolDirectObjectStatus
  (if (and
    (not (ir.compiler-debug-info-enabled?))
    (source-tool-windows-direct-object-enabled?)
    (backend.compiler-backend-target-windows? target))
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
  [program : ir.CompilerIrProgram]
  [spans : ir.CompilerSourceSpans]
  [target : backend.CompilerBackendTarget]
  [opt-level : i64]
  [link-inputs : SourceToolLinkInputs]
  [obj-path : String]
  [bin-path : String]) : SourceToolDirectObjectStatus
  (if (and
    (not (ir.compiler-debug-info-enabled?))
    (source-tool-linux-direct-object-enabled?)
    (backend.compiler-backend-target-linux? target))
    (match (source-tool-emit-lowered-linux-elf-object
      source
      program
      spans
      target
      opt-level
      (owned_view.compiler-owned-shared-view link-inputs))
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
  [target : backend.CompilerBackendTarget]
  [asm-path : String]
  [obj-path : String]
  [bin-path : String]
  [link-inputs : SourceToolLinkInputs]
  [asm : String]
  [write-context : String]) : SourceToolCommandStatus
  (match (source-tool-write-file
    (owned_view.compiler-owned-shared-view asm-path)
    asm
    write-context)
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
  [target : backend.CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [opt-level : i64]
  [mode : backend.CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]
  [link-inputs : SourceToolLinkInputs]
  [asm-path : String]
  [obj-path : String]
  [bin-path : String]
  [write-context : String]) : SourceToolCommandStatus
  (match (source-tool-emit-assembly
    source
    target
    (owned_view.compiler-owned-shared-view stdlib-roots)
    opt-level
    mode
    cfgs
    (owned_view.compiler-owned-shared-view link-inputs))
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
  [target : backend.CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [opt-level : i64]
  [mode : backend.CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]
  [link-inputs : SourceToolLinkInputs]
  [asm-path : String]
  [obj-path : String]
  [bin-path : String]
  [write-context : String]) : SourceToolCommandStatus
  (match (source-tool-try-linux-direct-object-and-link
    (owned_view.compiler-owned-shared-view source)
    target
    (owned_view.compiler-owned-shared-view stdlib-roots)
    opt-level
    mode
    (owned_view.compiler-owned-shared-view cfgs)
    (owned_view.compiler-owned-shared-view link-inputs)
    (owned_view.compiler-owned-shared-view obj-path)
    (owned_view.compiler-owned-shared-view bin-path))
    [(SourceToolDirectObjectStatus.Ok) SourceToolCommandStatus.Ok]
    [(SourceToolDirectObjectStatus.Err message)
      (SourceToolCommandStatus.Err message)]
    [(SourceToolDirectObjectStatus.Unavailable _)
      (match (source-tool-try-windows-direct-object-and-link
        (owned_view.compiler-owned-shared-view source)
        target
        (owned_view.compiler-owned-shared-view stdlib-roots)
        opt-level
        mode
        (owned_view.compiler-owned-shared-view cfgs)
        (owned_view.compiler-owned-shared-view link-inputs)
        (owned_view.compiler-owned-shared-view obj-path)
        (owned_view.compiler-owned-shared-view bin-path))
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
  [program : ir.CompilerIrProgram]
  [spans : ir.CompilerSourceSpans]
  [target : backend.CompilerBackendTarget]
  [opt-level : i64]
  [link-inputs : SourceToolLinkInputs]
  [asm-path : String]
  [obj-path : String]
  [bin-path : String]
  [write-context : String]) : SourceToolCommandStatus
  (match (source-tool-try-lowered-linux-direct-object-and-link
    (owned_view.compiler-owned-shared-view source)
    (owned_view.compiler-owned-shared-view program)
    (owned_view.compiler-owned-shared-view spans)
    target
    opt-level
    (owned_view.compiler-owned-shared-view link-inputs)
    (owned_view.compiler-owned-shared-view obj-path)
    (owned_view.compiler-owned-shared-view bin-path))
    [(SourceToolDirectObjectStatus.Ok) SourceToolCommandStatus.Ok]
    [(SourceToolDirectObjectStatus.Err message)
      (SourceToolCommandStatus.Err message)]
    [(SourceToolDirectObjectStatus.Unavailable _)
      (match (source-tool-try-lowered-windows-direct-object-and-link
        (owned_view.compiler-owned-shared-view source)
        (owned_view.compiler-owned-shared-view program)
        (owned_view.compiler-owned-shared-view spans)
        target
        opt-level
        (owned_view.compiler-owned-shared-view link-inputs)
        (owned_view.compiler-owned-shared-view obj-path)
        (owned_view.compiler-owned-shared-view bin-path))
        [(SourceToolDirectObjectStatus.Ok) SourceToolCommandStatus.Ok]
        [(SourceToolDirectObjectStatus.Err message)
          (SourceToolCommandStatus.Err message)]
        [(SourceToolDirectObjectStatus.Unavailable _)
          (match (compiler_driver_core.compiler-driver-emit-lowered-with-level
            source
            program
            spans
            target
            true
            opt-level)
            [(compiler_driver_core.ResultCompilerDriver.Ok asm)
              (source-tool-write-assembly-and-link
                target
                asm-path
                obj-path
                bin-path
                link-inputs
                (source-tool-augment-assembly-for-target asm target)
                write-context)]
            [(compiler_driver_core.ResultCompilerDriver.Err diag)
              (SourceToolCommandStatus.Err
                (compiler_driver_core.compiler-driver-render-source-diagnostic
                  (owned_view.compiler-owned-box-shared-view diag)))])])]))

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
    [asm-path : String
      (source-tool-asm-path
        (owned_view.compiler-owned-shared-view temp-dir)
        (owned_view.compiler-owned-shared-view source))]
    [obj-path : String
      (source-tool-obj-path
        (owned_view.compiler-owned-shared-view temp-dir)
        (owned_view.compiler-owned-shared-view source)
        target)]
    [bin-path : String
      (if has-output
        output
        (source-tool-default-output
          (owned_view.compiler-owned-shared-view source)
          target))]
    (match (source-tool-link-inputs-for-source
      (owned_view.compiler-owned-shared-view source)
      (owned_view.compiler-owned-shared-view stdlib-roots)
      (compiler_driver_core.compiler-driver-target-cfgs
        target
        (cfg_core.compiler-cfg-empty))
      (owned_view.compiler-owned-shared-view link-inputs))
      [(ResultSourceToolLinkInputs.Err message)
        (begin
          (io.print-error message)
          (source-tool-clean-temp temp-dir asm-path obj-path bin-path false)
          1)]
      [(ResultSourceToolLinkInputs.Ok effective-link-inputs)
        (begin
          (compiler_driver_core.compiler-driver-reset-file-state!)
          (match (source-tool-object-or-assembly-and-link
            (owned_view.compiler-owned-shared-view source)
            target
            (owned_view.compiler-owned-shared-view stdlib-roots)
            opt-level
            mode
            (cfg_core.compiler-cfg-empty)
            (owned_view.compiler-owned-shared-view effective-link-inputs)
            (owned_view.compiler-owned-shared-view asm-path)
            (owned_view.compiler-owned-shared-view obj-path)
            (owned_view.compiler-owned-shared-view bin-path)
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
                (io.print-format
                  "{}"
                  (str_cat.str-cat
                    "Built "
                    (owned_view.compiler-owned-shared-view bin-path)
                    "\n"))
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
  [target : backend.CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [opt-level : i64]
  [mode : backend.CompilerBackendMode]
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
          (str_cat.str-cat "build: failed to create temp dir: " message))
        1)]))

(define (source-tool-run-executable
  [bin-path : String]
  [target : backend.CompilerBackendTarget]
  [runtime-args : process.ProcessStringList]) : process.ResultProcessOutput
  (process.output
    (source-tool-command-for-target
      target
      (process.command bin-path runtime-args))))

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
  [cfg-names : SourceToolCfgNames]
  [runtime-args : process.ProcessStringList]
  [opt-level : i64]
  [mode : backend.CompilerBackendMode]
  [link-inputs : SourceToolLinkInputs]
  [stream-output : bool]
  [temp-dir : String]) : i64
  (let
    [asm-path : String
      (source-tool-asm-path
        (owned_view.compiler-owned-shared-view temp-dir)
        (owned_view.compiler-owned-shared-view source))]
    [obj-path : String
      (source-tool-obj-path
        (owned_view.compiler-owned-shared-view temp-dir)
        (owned_view.compiler-owned-shared-view source)
        target)]
    [bin-path : String
      (source-tool-temp-bin-path
        (owned_view.compiler-owned-shared-view temp-dir)
        (owned_view.compiler-owned-shared-view source)
        target)]
    [link-cfgs : sym_i64_env.SymI64Env
      (source-tool-cfg-names-to-env
        (owned_view.compiler-owned-shared-view cfg-names))]
    (match (source-tool-link-inputs-for-source
      (owned_view.compiler-owned-shared-view source)
      (owned_view.compiler-owned-shared-view stdlib-roots)
      (compiler_driver_core.compiler-driver-target-cfgs target link-cfgs)
      (owned_view.compiler-owned-shared-view link-inputs))
      [(ResultSourceToolLinkInputs.Err message)
        (begin
          (io.print-error message)
          (source-tool-clean-temp temp-dir asm-path obj-path bin-path true)
          1)]
      [(ResultSourceToolLinkInputs.Ok effective-link-inputs)
        (begin
          (compiler_driver_core.compiler-driver-reset-file-state!)
          (let
            [emit-cfgs : sym_i64_env.SymI64Env
              (source-tool-cfg-names-to-env cfg-names)]
            (match (source-tool-object-or-assembly-and-link
              (owned_view.compiler-owned-shared-view source)
              target
              (owned_view.compiler-owned-shared-view stdlib-roots)
              opt-level
              mode
              (owned_view.compiler-owned-shared-view emit-cfgs)
              (owned_view.compiler-owned-shared-view effective-link-inputs)
              (owned_view.compiler-owned-shared-view asm-path)
              (owned_view.compiler-owned-shared-view obj-path)
              (owned_view.compiler-owned-shared-view bin-path)
              "run: failed to write assembly artifact")
              [(SourceToolCommandStatus.Err message)
                (begin
                  (io.print-error message)
                  (source-tool-clean-temp
                    temp-dir
                    asm-path
                    obj-path
                    (owned_view.compiler-owned-shared-view bin-path)
                    true)
                  1)]
              [(SourceToolCommandStatus.Ok)
                (match (if stream-output
                  (source-tool-run-executable-inherit
                    (owned_view.compiler-owned-shared-view bin-path)
                    target
                    runtime-args)
                  (source-tool-run-executable
                    (owned_view.compiler-owned-shared-view bin-path)
                    target
                    runtime-args))
                  [(process.OkProcessOutput output)
                    (let
                      [status : i64 (process.output-status output)]
                      (begin
                        (if stream-output
                          unit
                          (source-tool-forward-output output))
                        (source-tool-clean-temp
                          temp-dir
                          asm-path
                          obj-path
                          (owned_view.compiler-owned-shared-view bin-path)
                          true)
                        status))]
                  [(process.ErrProcessOutput error)
                    (begin
                      (io.print-error
                        (str_cat.str-cat
                          "Error: failed to run executable '"
                          (owned_view.compiler-owned-shared-view bin-path)
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
                      1)])])))])))

(define (source-tool-run-source
  [source : String]
  [target : backend.CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [cfg-names : SourceToolCfgNames]
  [runtime-args : process.ProcessStringList]
  [opt-level : i64]
  [mode : backend.CompilerBackendMode]
  [link-inputs : SourceToolLinkInputs]
  [stream-output : bool]) : i64
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
        stream-output
        temp-dir)]
    [(ResultSourceToolString.Err message)
      (begin
        (io.print-error
          (str_cat.str-cat "run: failed to create temp dir: " message))
        1)]))