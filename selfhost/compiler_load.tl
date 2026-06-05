;; compiler_load.tl - Shared selfhost compiler source/import loader.
(import "../stdlib/io.tl")

(import "../stdlib/arena.tl")

(import "compiler_parse_core.tl")

(import "compiler_diagnostic.tl")

(import "sym_i64_env.tl")

(import "../stdlib/env.tl")

(import "../stdlib/fs.tl")

(import "compiler_embedded_stdlib.tl")

(defenum ResultCompilerLoad
  (OkCompilerLoad AstDeclList SymI64Env)
  (ErrCompilerLoad CompilerDiagnostic))

(defenum ResultCompilerLoadWithPaths
  (OkCompilerLoadWithPaths
    AstDeclList
    AstDeclPathList
    AstDeclModuleList
    SymI64Env)
  (ErrCompilerLoadWithPaths CompilerDiagnostic))

(defenum CompilerLoadRootList
  (CompilerLoadRootNil)
  (CompilerLoadRootCons String CompilerLoadRootList))

(defenum CompilerLoadMaybePath
  (CompilerLoadNoPath)
  (CompilerLoadSomePath String))

(defenum ResultPkgResolve
  (OkPkgResolve String)
  (ErrPkgResolve String))

(defenum CompilerLoadMaybeModuleId
  (CompilerLoadNoModuleId)
  (CompilerLoadSomeModuleId String))

(defenum CompilerLoadMaybeDecl
  (CompilerLoadNoDecl)
  (CompilerLoadSomeDecl AstDecl))

(defenum ResultCompilerLoadInclude
  (OkCompilerLoadInclude AstDecl)
  (ErrCompilerLoadInclude CompilerDiagnostic))

(defenum ResultCompilerLoadModuleId
  (OkCompilerLoadModuleId String)
  (ErrCompilerLoadModuleId CompilerDiagnostic))

(define (compiler-load-char-code-at [text : String] [idx : i64]) : i64
  (cast (string-ref text idx) : i64))

(define (compiler-load-path-separator? [c : char]) : bool
  (fs-path-separator? c))

(define (compiler-load-absolute-path? [path : String]) : bool
  (fs-path-absolute? (& path)))

(define (compiler-load-dirname [path : String]) : String
  (let
    [n : i64 (string-length path)]
    [i : i64 0]
    [last : i64 -1]
    (begin
      (while (< i n)
        (begin
          (if (compiler-load-path-separator? (string-ref path i))
            (set! last i)
            (set! last last))
          (set! i (+ i 1))))
      (if (< last 0)
        ""
        (substring path 0 (+ last 1))))))

(define (compiler-load-join-import-path
  [importer-path : String]
  [import-path : String]) : String
  (if (compiler-load-absolute-path? import-path)
    import-path
    (string-append (compiler-load-dirname importer-path) import-path)))

(define (compiler-load-normalize-path [path : String]) : String
  (fs-path-normalize (& path)))

(define (compiler-load-safe-relative? [path : String]) : bool
  (fs-path-safe-relative? (& path)))

(define (compiler-load-string-prefix-at?
  [text : String]
  [prefix : String]
  [start : i64]) : bool
  (let
    [text-len : i64 (string-length text)]
    [prefix-len : i64 (string-length prefix)]
    (if (< start 0)
      false
      (if (> (+ start prefix-len) text-len)
        false
        (let
          [i : i64 0]
          [ok : bool true]
          (begin
            (while ok
              (if (< i prefix-len)
                (if (=
                  (compiler-load-char-code-at text (+ start i))
                  (compiler-load-char-code-at prefix i))
                  (set! i (+ i 1))
                  (set! ok false))
                (set! ok false)))
            (= i prefix-len)))))))

(define (compiler-load-stdlib-import? [path : String]) : bool
  (compiler-load-string-prefix-at? path "stdlib/" 0))

(define (compiler-load-stdlib-suffix [path : String]) : String
  (substring path 7 (- (string-length path) 7)))

(define (compiler-load-join-root-path [root : String] [suffix : String]) : String
  (let
    [n : i64 (string-length root)]
    (if (= n 0)
      suffix
      (let
        [last : char (string-ref root (- n 1))]
        (if (compiler-load-path-separator? last)
          (string-append root suffix)
          (string-append root (string-append "/" suffix)))))))

(define (compiler-load-root-list-append
  [roots : CompilerLoadRootList]
  [root : String]) : CompilerLoadRootList
  (match roots
    [(CompilerLoadRootNil) (CompilerLoadRootCons root CompilerLoadRootNil)]
    [(CompilerLoadRootCons head rest)
      (CompilerLoadRootCons head (compiler-load-root-list-append rest root))]))

(define (compiler-load-roots-with-env [roots : CompilerLoadRootList]) : CompilerLoadRootList
  (let
    [name : String "TYPELISP_STDLIB_ROOT"]
    (match (env-get (& name))
      [(EnvNoString) roots]
      [(EnvSomeString root)
        (if (= (string-length root) 0)
          roots
          (compiler-load-root-list-append roots root))])))

(define (compiler-load-resolve-stdlib-root-raw
  [suffix : String]
  [roots : CompilerLoadRootList]) : CompilerLoadMaybePath
  (if (compiler-load-safe-relative? suffix)
    (match roots
      [(CompilerLoadRootNil) (CompilerLoadNoPath)]
      [(CompilerLoadRootCons root rest)
        (let
          [candidate : String (compiler-load-join-root-path root suffix)]
          (if (file-exists? candidate)
            (CompilerLoadSomePath candidate)
            (compiler-load-resolve-stdlib-root-raw suffix rest)))])
    (CompilerLoadNoPath)))

(define (compiler-load-resolve-stdlib-root
  [suffix : String]
  [roots : CompilerLoadRootList]) : CompilerLoadMaybePath
  (compiler-load-resolve-stdlib-root-raw
    suffix
    (compiler-load-roots-with-env roots)))

(define (compiler-load-embedded-stdlib-source [suffix : String]) : CompilerEmbeddedStdlibSource
  (if (compiler-load-safe-relative? suffix)
    (compiler-embedded-stdlib-lookup suffix)
    (CompilerEmbeddedStdlibNoSource)))

(define (compiler-load-embedded-stdlib-path [suffix : String]) : CompilerLoadMaybePath
  (match (compiler-load-embedded-stdlib-source suffix)
    [(CompilerEmbeddedStdlibSomeSource _)
      (CompilerLoadSomePath (string-append "stdlib/" suffix))]
    [(CompilerEmbeddedStdlibNoSource) (CompilerLoadNoPath)]))

(define (compiler-load-embedded-stdlib-source-for-path [path : String]) : CompilerEmbeddedStdlibSource
  (if (compiler-load-stdlib-import? path)
    (compiler-load-embedded-stdlib-source (compiler-load-stdlib-suffix path))
    (CompilerEmbeddedStdlibNoSource)))

(define (compiler-load-resolve-import
  [importer-path : String]
  [import-path : String]) : String
  (compiler-load-resolve-import-with-roots
    importer-path
    import-path
    CompilerLoadRootNil))

(define (compiler-load-resolve-import-with-roots
  [importer-path : String]
  [import-path : String]
  [stdlib-roots : CompilerLoadRootList]) : String
  (match (compiler-load-resolve-import-result-with-roots
    importer-path
    import-path
    stdlib-roots)
    [(OkPkgResolve resolved) resolved]
    [(ErrPkgResolve _) import-path]))

(define (compiler-load-resolve-import-result-with-roots
  [importer-path : String]
  [import-path : String]
  [stdlib-roots : CompilerLoadRootList]) : ResultPkgResolve
  (if (compiler-load-pkg-import? import-path)
    (compiler-load-resolve-pkg-import-from-disk importer-path import-path)
    (let
      [primary : String
        (compiler-load-join-import-path importer-path import-path)]
      [resolved : String
        (if (file-exists? primary)
          primary
          (if (compiler-load-stdlib-import? import-path)
            (let
              [suffix : String (compiler-load-stdlib-suffix import-path)]
              (match (compiler-load-resolve-stdlib-root suffix stdlib-roots)
                [(CompilerLoadSomePath root-path) root-path]
                [(CompilerLoadNoPath)
                  (if (file-exists? import-path)
                    import-path
                    (match (compiler-load-embedded-stdlib-path suffix)
                      [(CompilerLoadSomePath embedded-path) embedded-path]
                      [(CompilerLoadNoPath) primary]))]))
            primary))]
      (OkPkgResolve resolved))))

(define (compiler-load-include-str-def [name : String] [contents : String]) : AstDecl
  (ast-decl-def
    name
    (AstSomeType (AstTyString))
    (AstExprLiteral (AstLitString contents))))

(define (compiler-load-include-str-read-error
  [importer-path : String]
  [include-path : String]
  [resolved : String]) : CompilerDiagnostic
  (compiler-diagnostic-at-start
    importer-path
    (string-append
      "compiler-load: cannot read include-str "
      (string-append
        include-path
        (string-append
          " from "
          (string-append
            importer-path
            (string-append " (resolved " (string-append resolved ")"))))))))

(define (compiler-load-include-str-from-resolved
  [importer-path : String]
  [include-path : String]
  [resolved : String]
  [name : String]) : ResultCompilerLoadInclude
  (if (file-exists? resolved)
    (OkCompilerLoadInclude
      (compiler-load-include-str-def name (read-file resolved)))
    (match (compiler-load-embedded-stdlib-source-for-path resolved)
      [(CompilerEmbeddedStdlibSomeSource source)
        (OkCompilerLoadInclude (compiler-load-include-str-def name source))]
      [(CompilerEmbeddedStdlibNoSource)
        (ErrCompilerLoadInclude
          (compiler-load-include-str-read-error
            importer-path
            include-path
            resolved))])))

(define (compiler-load-expand-include-str
  [importer-path : String]
  [include-path : String]
  [name : String]
  [stdlib-roots : CompilerLoadRootList]) : ResultCompilerLoadInclude
  (match (compiler-load-resolve-import-result-with-roots
    importer-path
    include-path
    stdlib-roots)
    [(OkPkgResolve resolved)
      (compiler-load-include-str-from-resolved
        importer-path
        include-path
        resolved
        name)]
    [(ErrPkgResolve message)
      (ErrCompilerLoadInclude
        (compiler-diagnostic-at-start importer-path message))]))

(define (compiler-load-decl-list-append
  [left : AstDeclList]
  [right : AstDeclList]) : AstDeclList
  (match left
    [(AstDeclNil) right]
    [(AstDeclCons head rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (ast-decl-cons head (compiler-load-decl-list-append rest right)))]))

(define (compiler-load-decl-path-list-append
  [left : AstDeclPathList]
  [right : AstDeclPathList]) : AstDeclPathList
  (match left
    [(AstDeclPathNil) right]
    [(AstDeclPathCons head rest)
      (let
        [rest : AstDeclPathList (box-get rest)]
        (ast-decl-path-cons
          head
          (compiler-load-decl-path-list-append rest right)))]))

(define (compiler-load-decl-module-list-append
  [left : AstDeclModuleList]
  [right : AstDeclModuleList]) : AstDeclModuleList
  (match left
    [(AstDeclModuleNil) right]
    [(AstDeclModuleCons head rest)
      (let
        [rest : AstDeclModuleList (box-get rest)]
        (ast-decl-module-cons
          head
          (compiler-load-decl-module-list-append rest right)))]))

(define (compiler-load-drop-paths [result : ResultCompilerLoadWithPaths]) : ResultCompilerLoad
  (match result
    [(OkCompilerLoadWithPaths decls _ _ seen) (OkCompilerLoad decls seen)]
    [(ErrCompilerLoadWithPaths diag) (ErrCompilerLoad diag)]))

(define (compiler-load-decls-module-id-loop
  [path : String]
  [decls : AstDeclList]
  [fallback : String]
  [found : CompilerLoadMaybeModuleId]) : ResultCompilerLoadModuleId
  (match decls
    [(AstDeclNil)
      (match found
        [(CompilerLoadNoModuleId) (OkCompilerLoadModuleId fallback)]
        [(CompilerLoadSomeModuleId name) (OkCompilerLoadModuleId name)])]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclModule name)
            (match found
              [(CompilerLoadNoModuleId)
                (compiler-load-decls-module-id-loop
                  path
                  rest
                  fallback
                  (CompilerLoadSomeModuleId name))]
              [(CompilerLoadSomeModuleId _)
                (ErrCompilerLoadModuleId
                  (compiler-diagnostic-at-start
                    path
                    "compiler-load: duplicate module declaration"))])]
          [_ (compiler-load-decls-module-id-loop path rest fallback found)]))]))

(define (compiler-load-decls-module-id [path : String] [decls : AstDeclList]) : ResultCompilerLoadModuleId
  (compiler-load-decls-module-id-loop
    path
    decls
    (compiler-load-normalize-path path)
    CompilerLoadNoModuleId))

(define (compiler-load-check-expected-module
  [path : String]
  [expected : AstMaybeModuleName]
  [actual : String]) : ResultCompilerLoadModuleId
  (match expected
    [(AstNoModuleName) (OkCompilerLoadModuleId actual)]
    [(AstSomeModuleName want)
      (if (string-eq want actual)
        (OkCompilerLoadModuleId actual)
        (ErrCompilerLoadModuleId
          (compiler-diagnostic-at-start
            path
            (string-append
              "compiler-load: import expected module "
              (string-append want (string-append " but loaded " actual))))))]))

(define (compiler-load-decls-with-paths
  [decls : AstDeclList]
  [importer-path : String]
  [seen : SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-decls-with-paths-and-roots
    decls
    importer-path
    seen
    CompilerLoadRootNil))

(define (compiler-load-alias-decl-list
  [import-path : String]
  [expected-module : AstMaybeModuleName]
  [alias : AstMaybeImportAlias]
  [rest : AstDeclList]) : AstDeclList
  (match alias
    [(AstSomeImportAlias _)
      (ast-decl-cons
        (AstDeclImport (AstImportSpec import-path expected-module alias))
        rest)]
    [(AstNoImportAlias) rest]))

(define (compiler-load-alias-path-list
  [importer-path : String]
  [alias : AstMaybeImportAlias]
  [rest : AstDeclPathList]) : AstDeclPathList
  (match alias
    [(AstSomeImportAlias _) (ast-decl-path-cons importer-path rest)]
    [(AstNoImportAlias) rest]))

(define (compiler-load-alias-module-list
  [importer-module : String]
  [alias : AstMaybeImportAlias]
  [rest : AstDeclModuleList]) : AstDeclModuleList
  (match alias
    [(AstSomeImportAlias _) (ast-decl-module-cons importer-module rest)]
    [(AstNoImportAlias) rest]))

(define (compiler-load-decls-with-module-and-roots
  [decls : AstDeclList]
  [importer-path : String]
  [importer-module : String]
  [seen : SymI64Env]
  [stdlib-roots : CompilerLoadRootList]) : ResultCompilerLoadWithPaths
  (compiler-load-decls-with-module-and-roots-cfg
    decls
    importer-path
    importer-module
    seen
    stdlib-roots
    (compiler-cfg-empty)))

(define (compiler-load-decls-with-module-and-roots-cfg
  [decls : AstDeclList]
  [importer-path : String]
  [importer-module : String]
  [seen : SymI64Env]
  [stdlib-roots : CompilerLoadRootList]
  [cfgs : SymI64Env]) : ResultCompilerLoadWithPaths
  (match decls
    [(AstDeclNil)
      (OkCompilerLoadWithPaths AstDeclNil AstDeclPathNil AstDeclModuleNil seen)]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclImport (AstImportSpec import-path expected-module alias))
            (match (compiler-load-resolve-import-result-with-roots
              importer-path
              import-path
              stdlib-roots)
              [(OkPkgResolve resolved)
                (match (compiler-load-file-with-paths-and-roots-expect-cfg
                  resolved
                  seen
                  stdlib-roots
                  expected-module
                  cfgs)
                  [(OkCompilerLoadWithPaths
                      imported-decls
                      imported-paths
                      imported-modules
                      import-seen)
                    (match (compiler-load-decls-with-module-and-roots-cfg
                      rest
                      importer-path
                      importer-module
                      import-seen
                      stdlib-roots
                      cfgs)
                      [(OkCompilerLoadWithPaths
                          rest-decls
                          rest-paths
                          rest-modules
                          rest-seen)
                        (OkCompilerLoadWithPaths
                          (compiler-load-decl-list-append
                            imported-decls
                            (compiler-load-alias-decl-list
                              resolved
                              expected-module
                              alias
                              rest-decls))
                          (compiler-load-decl-path-list-append
                            imported-paths
                            (compiler-load-alias-path-list
                              importer-path
                              alias
                              rest-paths))
                          (compiler-load-decl-module-list-append
                            imported-modules
                            (compiler-load-alias-module-list
                              importer-module
                              alias
                              rest-modules))
                          rest-seen)]
                      [(ErrCompilerLoadWithPaths diag)
                        (ErrCompilerLoadWithPaths diag)])]
                  [(ErrCompilerLoadWithPaths diag)
                    (ErrCompilerLoadWithPaths diag)])]
              [(ErrPkgResolve message)
                (ErrCompilerLoadWithPaths
                  (compiler-diagnostic-at-start importer-path message))])]
          [(AstDeclIncludeStr name include-path)
            (match (compiler-load-expand-include-str
              importer-path
              include-path
              name
              stdlib-roots)
              [(OkCompilerLoadInclude expanded)
                (match (compiler-load-decls-with-module-and-roots-cfg
                  rest
                  importer-path
                  importer-module
                  seen
                  stdlib-roots
                  cfgs)
                  [(OkCompilerLoadWithPaths
                      rest-decls
                      rest-paths
                      rest-modules
                      rest-seen)
                    (OkCompilerLoadWithPaths
                      (ast-decl-cons expanded rest-decls)
                      (ast-decl-path-cons importer-path rest-paths)
                      (ast-decl-module-cons importer-module rest-modules)
                      rest-seen)]
                  [(ErrCompilerLoadWithPaths diag)
                    (ErrCompilerLoadWithPaths diag)])]
              [(ErrCompilerLoadInclude diag) (ErrCompilerLoadWithPaths diag)])]
          [_
            (match (compiler-load-decls-with-module-and-roots-cfg
              rest
              importer-path
              importer-module
              seen
              stdlib-roots
              cfgs)
              [(OkCompilerLoadWithPaths
                  rest-decls
                  rest-paths
                  rest-modules
                  rest-seen)
                (OkCompilerLoadWithPaths
                  (ast-decl-cons decl rest-decls)
                  (ast-decl-path-cons importer-path rest-paths)
                  (ast-decl-module-cons importer-module rest-modules)
                  rest-seen)]
              [(ErrCompilerLoadWithPaths diag) (ErrCompilerLoadWithPaths diag)])]))]))

(define (compiler-load-decls-with-paths-and-roots
  [decls : AstDeclList]
  [importer-path : String]
  [seen : SymI64Env]
  [stdlib-roots : CompilerLoadRootList]) : ResultCompilerLoadWithPaths
  (compiler-load-decls-with-paths-and-roots-cfg
    decls
    importer-path
    seen
    stdlib-roots
    (compiler-cfg-empty)))

(define (compiler-load-decls-with-paths-and-roots-cfg
  [decls : AstDeclList]
  [importer-path : String]
  [seen : SymI64Env]
  [stdlib-roots : CompilerLoadRootList]
  [cfgs : SymI64Env]) : ResultCompilerLoadWithPaths
  (match (compiler-load-decls-module-id importer-path decls)
    [(OkCompilerLoadModuleId module-id)
      (if (sym-i64-contains seen module-id)
        (OkCompilerLoadWithPaths
          AstDeclNil
          AstDeclPathNil
          AstDeclModuleNil
          seen)
        (compiler-load-decls-with-module-and-roots-cfg
          decls
          importer-path
          module-id
          (sym-i64-bind seen module-id 1)
          stdlib-roots
          cfgs))]
    [(ErrCompilerLoadModuleId diag) (ErrCompilerLoadWithPaths diag)]))

(define (compiler-load-decls
  [decls : AstDeclList]
  [importer-path : String]
  [seen : SymI64Env]) : ResultCompilerLoad
  (compiler-load-drop-paths
    (compiler-load-decls-with-paths decls importer-path seen)))

(define (compiler-load-decls-with-roots
  [decls : AstDeclList]
  [importer-path : String]
  [seen : SymI64Env]
  [stdlib-roots : CompilerLoadRootList]) : ResultCompilerLoad
  (compiler-load-drop-paths
    (compiler-load-decls-with-paths-and-roots
      decls
      importer-path
      seen
      stdlib-roots)))

(define (compiler-load-program-with-paths
  [path : String]
  [program : AstProgram]
  [seen : SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-program-with-paths-and-roots
    path
    program
    seen
    CompilerLoadRootNil))

(define (compiler-load-program-with-paths-and-roots
  [path : String]
  [program : AstProgram]
  [seen : SymI64Env]
  [stdlib-roots : CompilerLoadRootList]) : ResultCompilerLoadWithPaths
  (compiler-load-program-with-paths-and-roots-expect
    path
    program
    seen
    stdlib-roots
    AstNoModuleName))

(define (compiler-load-program-with-paths-and-roots-expect
  [path : String]
  [program : AstProgram]
  [seen : SymI64Env]
  [stdlib-roots : CompilerLoadRootList]
  [expected-module : AstMaybeModuleName]) : ResultCompilerLoadWithPaths
  (compiler-load-program-with-paths-and-roots-expect-cfg
    path
    program
    seen
    stdlib-roots
    expected-module
    (compiler-cfg-empty)))

(define (compiler-load-program-with-paths-and-roots-expect-cfg
  [path : String]
  [program : AstProgram]
  [seen : SymI64Env]
  [stdlib-roots : CompilerLoadRootList]
  [expected-module : AstMaybeModuleName]
  [cfgs : SymI64Env]) : ResultCompilerLoadWithPaths
  (match program
    [(AstProgram decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (compiler-load-decls-module-id path decls)
          [(OkCompilerLoadModuleId module-id)
            (match (compiler-load-check-expected-module
              path
              expected-module
              module-id)
              [(OkCompilerLoadModuleId _)
                (if (sym-i64-contains seen module-id)
                  (OkCompilerLoadWithPaths
                    AstDeclNil
                    AstDeclPathNil
                    AstDeclModuleNil
                    seen)
                  (compiler-load-decls-with-module-and-roots-cfg
                    decls
                    path
                    module-id
                    (sym-i64-bind seen module-id 1)
                    stdlib-roots
                    cfgs))]
              [(ErrCompilerLoadModuleId diag) (ErrCompilerLoadWithPaths diag)])]
          [(ErrCompilerLoadModuleId diag) (ErrCompilerLoadWithPaths diag)]))]))

(define (compiler-load-program
  [path : String]
  [program : AstProgram]
  [seen : SymI64Env]) : ResultCompilerLoad
  (compiler-load-drop-paths
    (compiler-load-program-with-paths path program seen)))

(define (compiler-load-program-with-roots
  [path : String]
  [program : AstProgram]
  [seen : SymI64Env]
  [stdlib-roots : CompilerLoadRootList]) : ResultCompilerLoad
  (compiler-load-drop-paths
    (compiler-load-program-with-paths-and-roots path program seen stdlib-roots)))

(define (compiler-load-source-with-paths
  [path : String]
  [source : String]
  [seen : SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-source-with-paths-and-roots
    path
    source
    seen
    CompilerLoadRootNil))

(define (compiler-load-source-with-paths-and-roots
  [path : String]
  [source : String]
  [seen : SymI64Env]
  [stdlib-roots : CompilerLoadRootList]) : ResultCompilerLoadWithPaths
  (compiler-load-source-with-paths-and-roots-expect
    path
    source
    seen
    stdlib-roots
    AstNoModuleName))

(define (compiler-load-source-with-paths-and-roots-cfg
  [path : String]
  [source : String]
  [seen : SymI64Env]
  [stdlib-roots : CompilerLoadRootList]
  [cfgs : SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-source-with-paths-and-roots-expect-cfg
    path
    source
    seen
    stdlib-roots
    AstNoModuleName
    cfgs))

(define (compiler-load-source-with-paths-and-roots-expect
  [path : String]
  [source : String]
  [seen : SymI64Env]
  [stdlib-roots : CompilerLoadRootList]
  [expected-module : AstMaybeModuleName]) : ResultCompilerLoadWithPaths
  (compiler-load-source-with-paths-and-roots-expect-cfg
    path
    source
    seen
    stdlib-roots
    expected-module
    (compiler-cfg-empty)))

(define (compiler-load-parse-result-escape
  [enclosing : i64]
  [parse-head : i64]
  [result : ResultAstProgramDiagnostic]) : ResultAstProgramDiagnostic
  (match result
    [(OkAstProgramDiagnostic program)
      (begin
        (unsafe
          (arena-set! enclosing))
        (let
          [escaped-program : AstProgram (clone program)]
          (begin
            (unsafe
              (arena-destroy parse-head))
            (OkAstProgramDiagnostic escaped-program))))]
    [(ErrAstProgramDiagnostic diag)
      (begin
        (unsafe
          (arena-set! enclosing))
        (let
          [escaped-diag : CompilerDiagnostic (clone diag)]
          (begin
            (unsafe
              (arena-destroy parse-head))
            (ErrAstProgramDiagnostic escaped-diag))))]))

(define (compiler-load-parse-source-diagnostic-escaping
  [path : String]
  [source : String]
  [cfgs : SymI64Env]) : ResultAstProgramDiagnostic
  (let
    [enclosing : i64 (arena-current)]
    [parse-arena : i64 (arena-make)]
    (begin
      (unsafe
        (arena-set! parse-arena))
      (compiler-load-parse-result-escape
        enclosing
        (arena-current)
        (parse-ast-source-diagnostic-with-cfg path source cfgs)))))

(define (compiler-load-parse-file-diagnostic-escaping
  [path : String]
  [cfgs : SymI64Env]) : ResultAstProgramDiagnostic
  (let
    [enclosing : i64 (arena-current)]
    [parse-arena : i64 (arena-make)]
    (begin
      (unsafe
        (arena-set! parse-arena))
      (compiler-load-parse-result-escape
        enclosing
        (arena-current)
        (parse-ast-source-diagnostic-with-cfg path (read-file path) cfgs)))))

(define (compiler-load-source-with-paths-and-roots-expect-cfg
  [path : String]
  [source : String]
  [seen : SymI64Env]
  [stdlib-roots : CompilerLoadRootList]
  [expected-module : AstMaybeModuleName]
  [cfgs : SymI64Env]) : ResultCompilerLoadWithPaths
  (match (compiler-load-parse-source-diagnostic-escaping path source cfgs)
    [(OkAstProgramDiagnostic program)
      (compiler-load-program-with-paths-and-roots-expect-cfg
        path
        program
        seen
        stdlib-roots
        expected-module
        cfgs)]
    [(ErrAstProgramDiagnostic diag) (ErrCompilerLoadWithPaths diag)]))

(define (compiler-load-source
  [path : String]
  [source : String]
  [seen : SymI64Env]) : ResultCompilerLoad
  (compiler-load-drop-paths (compiler-load-source-with-paths path source seen)))

(define (compiler-load-source-with-roots
  [path : String]
  [source : String]
  [seen : SymI64Env]
  [stdlib-roots : CompilerLoadRootList]) : ResultCompilerLoad
  (compiler-load-drop-paths
    (compiler-load-source-with-paths-and-roots path source seen stdlib-roots)))

(define (compiler-load-file-with-paths [path : String] [seen : SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-file-with-paths-and-roots path seen CompilerLoadRootNil))

(define (compiler-load-file-with-paths-and-roots
  [path : String]
  [seen : SymI64Env]
  [stdlib-roots : CompilerLoadRootList]) : ResultCompilerLoadWithPaths
  (compiler-load-file-with-paths-and-roots-expect
    path
    seen
    stdlib-roots
    AstNoModuleName))

(define (compiler-load-file-with-paths-and-roots-cfg
  [path : String]
  [seen : SymI64Env]
  [stdlib-roots : CompilerLoadRootList]
  [cfgs : SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-file-with-paths-and-roots-expect-cfg
    path
    seen
    stdlib-roots
    AstNoModuleName
    cfgs))

(define (compiler-load-file-with-paths-and-roots-expect
  [path : String]
  [seen : SymI64Env]
  [stdlib-roots : CompilerLoadRootList]
  [expected-module : AstMaybeModuleName]) : ResultCompilerLoadWithPaths
  (compiler-load-file-with-paths-and-roots-expect-cfg
    path
    seen
    stdlib-roots
    expected-module
    (compiler-cfg-empty)))

(define (compiler-load-file-with-paths-and-roots-expect-cfg
  [path : String]
  [seen : SymI64Env]
  [stdlib-roots : CompilerLoadRootList]
  [expected-module : AstMaybeModuleName]
  [cfgs : SymI64Env]) : ResultCompilerLoadWithPaths
  (if (file-exists? path)
    (match (compiler-load-parse-file-diagnostic-escaping path cfgs)
      [(OkAstProgramDiagnostic program)
        (compiler-load-program-with-paths-and-roots-expect-cfg
          path
          program
          seen
          stdlib-roots
          expected-module
          cfgs)]
      [(ErrAstProgramDiagnostic diag) (ErrCompilerLoadWithPaths diag)])
    (match (compiler-load-embedded-stdlib-source-for-path path)
      [(CompilerEmbeddedStdlibSomeSource source)
        (match (compiler-load-parse-source-diagnostic-escaping path source cfgs)
          [(OkAstProgramDiagnostic program)
            (compiler-load-program-with-paths-and-roots-expect-cfg
              path
              program
              seen
              stdlib-roots
              expected-module
              cfgs)]
          [(ErrAstProgramDiagnostic diag) (ErrCompilerLoadWithPaths diag)])]
      [(CompilerEmbeddedStdlibNoSource)
        (ErrCompilerLoadWithPaths
          (compiler-diagnostic-at-start
            path
            (string-append "compiler-load: cannot read import " path)))])))

(define (compiler-load-file [path : String] [seen : SymI64Env]) : ResultCompilerLoad
  (compiler-load-drop-paths (compiler-load-file-with-paths path seen)))

(define (compiler-load-file-with-roots
  [path : String]
  [seen : SymI64Env]
  [stdlib-roots : CompilerLoadRootList]) : ResultCompilerLoad
  (compiler-load-drop-paths
    (compiler-load-file-with-paths-and-roots path seen stdlib-roots)))

(define (compiler-load-package-hex-digit [n : i64]) : String
  (cond
    [(= n 0) "0"]
    [(= n 1) "1"]
    [(= n 2) "2"]
    [(= n 3) "3"]
    [(= n 4) "4"]
    [(= n 5) "5"]
    [(= n 6) "6"]
    [(= n 7) "7"]
    [(= n 8) "8"]
    [(= n 9) "9"]
    [(= n 10) "a"]
    [(= n 11) "b"]
    [(= n 12) "c"]
    [(= n 13) "d"]
    [(= n 14) "e"]
    [else "f"]))

(define (compiler-load-package-hex-byte [n : i64]) : String
  (string-append
    (compiler-load-package-hex-digit (/ n 16))
    (compiler-load-package-hex-digit (% n 16))))

(define (compiler-load-package-symbol-char
  [text : String]
  [idx : i64]
  [c : char]) : String
  (cond
    [(or
        (and (>= c #A') (<= c #Z'))
        (or
          (and (>= c #a') (<= c #z'))
          (or (and (>= c #0') (<= c #9')) (= c #_'))))
      (substring text idx 1)]
    [(= c #-') "_"]
    [(= c #?') "_question"]
    [(= c #!') "_bang"]
    [(= c #+') "_plus"]
    [(= c #*') "_star"]
    [(= c #/') "_slash"]
    [(= c #=') "_eq"]
    [(= c #<') "_lt"]
    [(= c #>') "_gt"]
    [(= c #:') "_colon"]
    [else
      (string-append
        "_u"
        (compiler-load-package-hex-byte (compiler-load-char-code-at text idx)))]))

(define (compiler-load-package-asm-safe-symbol [name : String]) : String
  (let
    [i : i64 0]
    [n : i64 (string-length name)]
    [out : String ""]
    (begin
      (while (< i n)
        (begin
          (set!
            out
            (string-append
              out
              (compiler-load-package-symbol-char name i (string-ref name i))))
          (set! i (+ i 1))))
      out)))

(define (compiler-load-package-user-symbol [name : String]) : String
  (if (string-eq name "main")
    "main"
    (string-append "_tl_" (compiler-load-package-asm-safe-symbol name))))

(define (compiler-load-package-module-key [module : String] [name : String]) : String
  (if (= (string-length module) 0)
    name
    (string-append module (string-append "/" name))))

(define (compiler-load-package-module-id
  [entry-path : String]
  [decl-path : String]) : String
  (let
    [base : String (compiler-load-dirname entry-path)]
    [base-len : i64 (string-length base)]
    [decl-len : i64 (string-length decl-path)]
    (if (and (> base-len 0) (compiler-load-string-prefix-at? decl-path base 0))
      (substring decl-path base-len (- decl-len base-len))
      decl-path)))

(define (compiler-load-package-module-logical-name
  [entry-path : String]
  [decl-path : String]
  [source-name : String]) : String
  (if (and (string-eq decl-path entry-path) (string-eq source-name "main"))
    "main"
    (string-append
      (string-append
        (compiler-load-package-module-id entry-path decl-path)
        "::")
      source-name)))

(define (compiler-load-package-entry-main?
  [entry-path : String]
  [decl-path : String]
  [module : String]
  [source-name : String]) : bool
  (and
    (and (string-eq decl-path entry-path) (string-eq source-name "main"))
    (or (string-eq module "") (string-eq module "main"))))

(define (compiler-load-package-decl-logical-name
  [entry-path : String]
  [decl-path : String]
  [module : String]
  [source-name : String]) : String
  (if (compiler-load-package-entry-main?
    entry-path
    decl-path
    module
    source-name)
    "main"
    (if (string-eq module "")
      (compiler-load-package-module-logical-name
        entry-path
        decl-path
        source-name)
      (compiler-load-package-module-logical-name
        entry-path
        decl-path
        (compiler-load-package-module-key module source-name)))))

(define (compiler-load-param-type-list [params : AstParamList]) : AstTypeList
  (match params
    [(AstParamNil) AstTypeNil]
    [(AstParamCons param rest)
      (let
        [rest : AstParamList (box-get rest)]
        (match param
          [(AstParam _ ty _)
            (ast-type-cons ty (compiler-load-param-type-list rest))]))]))

(define (compiler-load-package-def-fn-extern
  [entry-path : String]
  [decl-path : String]
  [module : String]
  [name : String]
  [params : AstParamList]
  [ret : AstType]) : AstDecl
  (let
    [logical : String
      (compiler-load-package-decl-logical-name entry-path decl-path module name)]
    (AstDeclExtern
      name
      (AstExternMetadata
        (AstExternAbiC)
        (compiler-load-package-user-symbol logical)
        AstExternLinkInputNil)
      (ast-ty-func (compiler-load-param-type-list params) ret))))

(define (compiler-load-package-transform-decl
  [entry-path : String]
  [decl-path : String]
  [module : String]
  [decl : AstDecl]) : CompilerLoadMaybeDecl
  (match decl
    [(AstDeclDefFn name params ret _)
      (CompilerLoadSomeDecl
        (compiler-load-package-def-fn-extern
          entry-path
          decl-path
          module
          name
          params
          ret))]
    [(AstDeclDefStruct _ _ _ _) (CompilerLoadSomeDecl decl)]
    [(AstDeclModule _) (CompilerLoadSomeDecl decl)]
    [(AstDeclUnsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (match (compiler-load-package-transform-decl
          entry-path
          decl-path
          module
          inner)
          [(CompilerLoadSomeDecl transformed)
            (CompilerLoadSomeDecl (ast-decl-unsafe transformed))]
          [(CompilerLoadNoDecl) (CompilerLoadNoDecl)]))]
    [(AstDeclComptimeDecl template-box)
      (let
        [template : AstDecl (box-get template-box)]
        (match (compiler-load-package-transform-decl
          entry-path
          decl-path
          module
          template)
          [(CompilerLoadSomeDecl transformed)
            (CompilerLoadSomeDecl (ast-decl-comptime-decl transformed))]
          [(CompilerLoadNoDecl) (CompilerLoadNoDecl)]))]
    [_ (CompilerLoadNoDecl)]))

(define (compiler-load-path-list-head-or
  [paths : AstDeclPathList]
  [fallback : String]) : String
  (match paths
    [(AstDeclPathCons path _) path]
    [(AstDeclPathNil) fallback]))

(define (compiler-load-path-list-tail [paths : AstDeclPathList]) : AstDeclPathList
  (match paths
    [(AstDeclPathCons _ rest)
      (let
        [rest : AstDeclPathList (box-get rest)]
        rest)]
    [(AstDeclPathNil) AstDeclPathNil]))

(define (compiler-load-package-extern-decls
  [entry-path : String]
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [seen : SymI64Env]
  [module : String]) : ResultCompilerLoadWithPaths
  (match decls
    [(AstDeclNil)
      (OkCompilerLoadWithPaths AstDeclNil AstDeclPathNil AstDeclModuleNil seen)]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        [decl-path : String (compiler-load-path-list-head-or paths entry-path)]
        [rest-paths : AstDeclPathList (compiler-load-path-list-tail paths)]
        [next-module : String
          (match decl
            [(AstDeclModule name) name]
            [_ module])]
        (match (compiler-load-package-extern-decls
          entry-path
          rest
          rest-paths
          seen
          next-module)
          [(OkCompilerLoadWithPaths
              rest-decls
              rest-decl-paths
              rest-modules
              rest-seen)
            (match (compiler-load-package-transform-decl
              entry-path
              decl-path
              module
              decl)
              [(CompilerLoadSomeDecl transformed)
                (OkCompilerLoadWithPaths
                  (ast-decl-cons transformed rest-decls)
                  (ast-decl-path-cons decl-path rest-decl-paths)
                  (ast-decl-module-cons module rest-modules)
                  rest-seen)]
              [(CompilerLoadNoDecl)
                (OkCompilerLoadWithPaths
                  rest-decls
                  rest-decl-paths
                  rest-modules
                  rest-seen)])]
          [(ErrCompilerLoadWithPaths diag) (ErrCompilerLoadWithPaths diag)]))]))

(define (compiler-load-package-entry-path-for-source [source-path : String]) : ResultPkgResolve
  (match (compiler-load-discover-manifest source-path)
    [(CompilerLoadNoPath)
      (ErrPkgResolve
        (string-append
          "compiler-load: dependency package manifest not found for "
          source-path))]
    [(CompilerLoadSomePath manifest-path)
      (match (compiler-load-parse-manifest (read-file manifest-path))
        [(ErrCompilerPkgManifest message)
          (ErrPkgResolve
            (string-append
              "compiler-load: invalid dependency package manifest '"
              (string-append manifest-path (string-append "': " message))))]
        [(OkCompilerPkgManifest manifest)
          (OkPkgResolve
            (compiler-load-normalize-path
              (compiler-load-join-root-path
                (compiler-load-dirname manifest-path)
                (struct-get manifest entry))))])]))

(define (compiler-load-package-externs-from-import
  [resolved : String]
  [seen : SymI64Env]
  [stdlib-roots : CompilerLoadRootList]
  [expected-module : AstMaybeModuleName]
  [cfgs : SymI64Env]) : ResultCompilerLoadWithPaths
  (match (compiler-load-package-entry-path-for-source resolved)
    [(ErrPkgResolve message)
      (ErrCompilerLoadWithPaths (compiler-diagnostic-at-start resolved message))]
    [(OkPkgResolve entry-path)
      (match (compiler-load-file-with-paths-and-roots-expect-cfg
        resolved
        seen
        stdlib-roots
        expected-module
        cfgs)
        [(OkCompilerLoadWithPaths imported-decls imported-paths _ import-seen)
          (compiler-load-package-extern-decls
            entry-path
            imported-decls
            imported-paths
            import-seen
            "")]
        [(ErrCompilerLoadWithPaths diag) (ErrCompilerLoadWithPaths diag)])]))

(define (compiler-load-package-expand-include-str
  [importer-path : String]
  [include-path : String]
  [name : String]
  [stdlib-roots : CompilerLoadRootList]
  [manifest-dir : String]
  [deps : CompilerPkgDepList]) : ResultCompilerLoadInclude
  (match (if (compiler-load-pkg-import? include-path)
    (compiler-load-resolve-pkg-import include-path manifest-dir deps)
    (compiler-load-resolve-import-result-with-roots
      importer-path
      include-path
      stdlib-roots))
    [(OkPkgResolve resolved)
      (compiler-load-include-str-from-resolved
        importer-path
        include-path
        resolved
        name)]
    [(ErrPkgResolve message)
      (ErrCompilerLoadInclude
        (compiler-diagnostic-at-start importer-path message))]))

(define (compiler-load-package-decls-with-module-and-roots
  [decls : AstDeclList]
  [importer-path : String]
  [importer-module : String]
  [seen : SymI64Env]
  [stdlib-roots : CompilerLoadRootList]
  [manifest-dir : String]
  [deps : CompilerPkgDepList]
  [cfgs : SymI64Env]) : ResultCompilerLoadWithPaths
  (match decls
    [(AstDeclNil)
      (OkCompilerLoadWithPaths AstDeclNil AstDeclPathNil AstDeclModuleNil seen)]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclImport (AstImportSpec import-path expected-module alias))
            (match (if (compiler-load-pkg-import? import-path)
              (compiler-load-resolve-pkg-import import-path manifest-dir deps)
              (compiler-load-resolve-import-result-with-roots
                importer-path
                import-path
                stdlib-roots))
              [(OkPkgResolve resolved)
                (match (if (compiler-load-pkg-import? import-path)
                  (compiler-load-package-externs-from-import
                    resolved
                    seen
                    stdlib-roots
                    expected-module
                    cfgs)
                  (compiler-load-package-file-with-paths-and-roots-expect
                    resolved
                    seen
                    stdlib-roots
                    expected-module
                    manifest-dir
                    deps
                    cfgs))
                  [(OkCompilerLoadWithPaths
                      imported-decls
                      imported-paths
                      imported-modules
                      import-seen)
                    (match (compiler-load-package-decls-with-module-and-roots
                      rest
                      importer-path
                      importer-module
                      import-seen
                      stdlib-roots
                      manifest-dir
                      deps
                      cfgs)
                      [(OkCompilerLoadWithPaths
                          rest-decls
                          rest-paths
                          rest-modules
                          rest-seen)
                        (OkCompilerLoadWithPaths
                          (compiler-load-decl-list-append
                            imported-decls
                            (compiler-load-alias-decl-list
                              resolved
                              expected-module
                              alias
                              rest-decls))
                          (compiler-load-decl-path-list-append
                            imported-paths
                            (compiler-load-alias-path-list
                              importer-path
                              alias
                              rest-paths))
                          (compiler-load-decl-module-list-append
                            imported-modules
                            (compiler-load-alias-module-list
                              importer-module
                              alias
                              rest-modules))
                          rest-seen)]
                      [(ErrCompilerLoadWithPaths diag)
                        (ErrCompilerLoadWithPaths diag)])]
                  [(ErrCompilerLoadWithPaths diag)
                    (ErrCompilerLoadWithPaths diag)])]
              [(ErrPkgResolve message)
                (ErrCompilerLoadWithPaths
                  (compiler-diagnostic-at-start importer-path message))])]
          [(AstDeclIncludeStr name include-path)
            (match (compiler-load-package-expand-include-str
              importer-path
              include-path
              name
              stdlib-roots
              manifest-dir
              deps)
              [(OkCompilerLoadInclude expanded)
                (match (compiler-load-package-decls-with-module-and-roots
                  rest
                  importer-path
                  importer-module
                  seen
                  stdlib-roots
                  manifest-dir
                  deps
                  cfgs)
                  [(OkCompilerLoadWithPaths
                      rest-decls
                      rest-paths
                      rest-modules
                      rest-seen)
                    (OkCompilerLoadWithPaths
                      (ast-decl-cons expanded rest-decls)
                      (ast-decl-path-cons importer-path rest-paths)
                      (ast-decl-module-cons importer-module rest-modules)
                      rest-seen)]
                  [(ErrCompilerLoadWithPaths diag)
                    (ErrCompilerLoadWithPaths diag)])]
              [(ErrCompilerLoadInclude diag) (ErrCompilerLoadWithPaths diag)])]
          [_
            (match (compiler-load-package-decls-with-module-and-roots
              rest
              importer-path
              importer-module
              seen
              stdlib-roots
              manifest-dir
              deps
              cfgs)
              [(OkCompilerLoadWithPaths
                  rest-decls
                  rest-paths
                  rest-modules
                  rest-seen)
                (OkCompilerLoadWithPaths
                  (ast-decl-cons decl rest-decls)
                  (ast-decl-path-cons importer-path rest-paths)
                  (ast-decl-module-cons importer-module rest-modules)
                  rest-seen)]
              [(ErrCompilerLoadWithPaths diag) (ErrCompilerLoadWithPaths diag)])]))]))

(define (compiler-load-package-program-with-paths-and-roots-expect
  [path : String]
  [program : AstProgram]
  [seen : SymI64Env]
  [stdlib-roots : CompilerLoadRootList]
  [expected-module : AstMaybeModuleName]
  [manifest-dir : String]
  [deps : CompilerPkgDepList]
  [cfgs : SymI64Env]) : ResultCompilerLoadWithPaths
  (match program
    [(AstProgram decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (compiler-load-decls-module-id path decls)
          [(OkCompilerLoadModuleId module-id)
            (match (compiler-load-check-expected-module
              path
              expected-module
              module-id)
              [(OkCompilerLoadModuleId _)
                (if (sym-i64-contains seen module-id)
                  (OkCompilerLoadWithPaths
                    AstDeclNil
                    AstDeclPathNil
                    AstDeclModuleNil
                    seen)
                  (compiler-load-package-decls-with-module-and-roots
                    decls
                    path
                    module-id
                    (sym-i64-bind seen module-id 1)
                    stdlib-roots
                    manifest-dir
                    deps
                    cfgs))]
              [(ErrCompilerLoadModuleId diag) (ErrCompilerLoadWithPaths diag)])]
          [(ErrCompilerLoadModuleId diag) (ErrCompilerLoadWithPaths diag)]))]))

(define (compiler-load-package-file-with-paths-and-roots-expect
  [path : String]
  [seen : SymI64Env]
  [stdlib-roots : CompilerLoadRootList]
  [expected-module : AstMaybeModuleName]
  [manifest-dir : String]
  [deps : CompilerPkgDepList]
  [cfgs : SymI64Env]) : ResultCompilerLoadWithPaths
  (if (file-exists? path)
    (match (parse-ast-source-diagnostic-with-cfg path (read-file path) cfgs)
      [(OkAstProgramDiagnostic program)
        (compiler-load-package-program-with-paths-and-roots-expect
          path
          program
          seen
          stdlib-roots
          expected-module
          manifest-dir
          deps
          cfgs)]
      [(ErrAstProgramDiagnostic diag) (ErrCompilerLoadWithPaths diag)])
    (match (compiler-load-embedded-stdlib-source-for-path path)
      [(CompilerEmbeddedStdlibSomeSource source)
        (match (compiler-load-parse-source-diagnostic-escaping path source cfgs)
          [(OkAstProgramDiagnostic program)
            (compiler-load-package-program-with-paths-and-roots-expect
              path
              program
              seen
              stdlib-roots
              expected-module
              manifest-dir
              deps
              cfgs)]
          [(ErrAstProgramDiagnostic diag) (ErrCompilerLoadWithPaths diag)])]
      [(CompilerEmbeddedStdlibNoSource)
        (ErrCompilerLoadWithPaths
          (compiler-diagnostic-at-start
            path
            (string-append "compiler-load: cannot read import " path)))])))

(define (compiler-load-package-file-with-paths-and-roots
  [path : String]
  [seen : SymI64Env]
  [stdlib-roots : CompilerLoadRootList]
  [manifest-dir : String]
  [deps : CompilerPkgDepList]) : ResultCompilerLoadWithPaths
  (compiler-load-package-file-with-paths-and-roots-expect
    path
    seen
    stdlib-roots
    AstNoModuleName
    manifest-dir
    deps
    (compiler-cfg-empty)))

(define (compiler-load-package-file-with-paths-and-roots-cfg
  [path : String]
  [seen : SymI64Env]
  [stdlib-roots : CompilerLoadRootList]
  [manifest-dir : String]
  [deps : CompilerPkgDepList]
  [cfgs : SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-package-file-with-paths-and-roots-expect
    path
    seen
    stdlib-roots
    AstNoModuleName
    manifest-dir
    deps
    cfgs))

(define (compiler-load-decl-list-count [decls : AstDeclList]) : i64
  (match decls
    [(AstDeclNil) 0]
    [(AstDeclCons _ rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (+ 1 (compiler-load-decl-list-count rest)))]))

(define (compiler-load-first-string-def?
  [decls : AstDeclList]
  [name : String]
  [want : String]) : bool
  (match decls
    [(AstDeclCons (AstDeclDef got (AstSomeType (AstTyString)) value-box) _)
      (let
        [value : AstExpr (box-get value-box)]
        (match value
          [(AstExprLiteral (AstLitString text))
            (and (string-eq got name) (string-eq text want))]
          [_ false]))]
    [_ false]))

(define (compiler-load-decl-list-has-import-alias?
  [decls : AstDeclList]
  [target-module : String]
  [target-alias : String]) : bool
  (match decls
    [(AstDeclNil) false]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclImport
              (AstImportSpec
                _
                (AstSomeModuleName module-name)
                (AstSomeImportAlias alias)))
            (if (and
              (string-eq module-name target-module)
              (string-eq alias target-alias))
              true
              (compiler-load-decl-list-has-import-alias?
                rest
                target-module
                target-alias))]
          [_
            (compiler-load-decl-list-has-import-alias?
              rest
              target-module
              target-alias)]))]))

(define (compiler-load-two-modules?
  [modules : AstDeclModuleList]
  [want : String]) : bool
  (match modules
    [(AstDeclModuleCons first tail)
      (let
        [tail : AstDeclModuleList (box-get tail)]
        (match tail
          [(AstDeclModuleCons second rest)
            (let
              [rest : AstDeclModuleList (box-get rest)]
              (match rest
                [(AstDeclModuleNil)
                  (and (string-eq first want) (string-eq second want))]
                [_ false]))]
          [_ false]))]
    [_ false]))

(define (compiler-load-entry-cycle-modules? [modules : AstDeclModuleList]) : bool
  (match modules
    [(AstDeclModuleCons first tail)
      (let
        [tail : AstDeclModuleList (box-get tail)]
        (match tail
          [(AstDeclModuleCons second rest2)
            (let
              [rest2 : AstDeclModuleList (box-get rest2)]
              (match rest2
                [(AstDeclModuleCons third rest3)
                  (let
                    [rest3 : AstDeclModuleList (box-get rest3)]
                    (match rest3
                      [(AstDeclModuleCons fourth rest4)
                        (let
                          [rest4 : AstDeclModuleList (box-get rest4)]
                          (match rest4
                            [(AstDeclModuleCons fifth rest5)
                              (let
                                [rest5 : AstDeclModuleList (box-get rest5)]
                                (match rest5
                                  [(AstDeclModuleCons sixth rest6)
                                    (let
                                      [rest6 : AstDeclModuleList
                                        (box-get rest6)]
                                      (match rest6
                                        [(AstDeclModuleNil)
                                          (and
                                            (string-eq first "smoke.entry")
                                            (and
                                              (string-eq second "smoke.dep")
                                              (and
                                                (string-eq third "smoke.dep")
                                                (and
                                                  (string-eq fourth "smoke.dep")
                                                  (and
                                                    (string-eq
                                                      fifth
                                                      "smoke.entry")
                                                    (string-eq
                                                      sixth
                                                      "smoke.entry"))))))]
                                        [_ false]))]
                                  [_ false]))]
                            [_ false]))]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [_ false]))

(define (compiler-load-normalize-ok?) : bool
  (and
    (string-eq
      (compiler-load-normalize-path "selfhost/./x/../compiler_load.tl")
      "selfhost/compiler_load.tl")
    (string-eq
      (compiler-load-normalize-path "target\\loader\\..\\dep.tl")
      "target/dep.tl")))

(define (compiler-load-source-provenance-ok?) : bool
  (match (compiler-load-source-with-paths
    "src/./main.tl"
    "(module app.main)
(define answer : i64 42)"
    (sym-i64-empty))
    [(OkCompilerLoadWithPaths decls _ modules seen)
      (and
        (= (compiler-load-decl-list-count decls) 2)
        (and
          (compiler-load-two-modules? modules "app.main")
          (sym-i64-contains seen "app.main")))]
    [(ErrCompilerLoadWithPaths _) false]))

(define (compiler-load-expected-module-conflict-ok?) : bool
  (match (compiler-load-source-with-paths-and-roots-expect
    "src/lib.tl"
    "(module lib.actual)
(define value : i64 1)"
    (sym-i64-empty)
    CompilerLoadRootNil
    (AstSomeModuleName "lib.want"))
    [(ErrCompilerLoadWithPaths diag)
      (string-eq
        (compiler-diagnostic-message diag)
        "compiler-load: import expected module lib.want but loaded lib.actual")]
    [(OkCompilerLoadWithPaths _ _ _ _) false]))

(define (compiler-load-duplicate-module-ok?) : bool
  (match (compiler-load-source
    "src/dup.tl"
    "(module dup.one)
(module dup.two)
(define value : i64 1)"
    (sym-i64-empty))
    [(ErrCompilerLoad diag)
      (string-eq
        (compiler-diagnostic-message diag)
        "compiler-load: duplicate module declaration")]
    [(OkCompilerLoad _ _) false]))

(define (compiler-load-seen-module-ok?) : bool
  (match (compiler-load-source
    "src/other.tl"
    "(module seen.module)
(define value : i64 1)"
    (sym-i64-bind (sym-i64-empty) "seen.module" 1))
    [(OkCompilerLoad decls _)
      (match decls
        [(AstDeclNil) true]
        [_ false])]
    [(ErrCompilerLoad _) false]))

(define (compiler-load-cfg-import-ok?) : bool
  (let
    [source : String
      "(module cfg.entry)
(cfg missing (import \"definitely_missing.tl\"))
(define value : i64 1)"]
    [enabled-source : String
      "(module cfg.entry.active)
(cfg feature (import \"definitely_missing.tl\"))
(define value : i64 1)"]
    [feature-cfg : SymI64Env
      (compiler-cfg-enable (compiler-cfg-empty) "feature")]
    (and
      (match (compiler-load-source-with-paths-and-roots-cfg
        "src/main.tl"
        source
        (sym-i64-empty)
        CompilerLoadRootNil
        (compiler-cfg-empty))
        [(OkCompilerLoadWithPaths decls _ _ _)
          (= (compiler-load-decl-list-count decls) 2)]
        [(ErrCompilerLoadWithPaths _) false])
      (match (compiler-load-source-with-paths-and-roots-cfg
        "src/main.tl"
        enabled-source
        (sym-i64-empty)
        CompilerLoadRootNil
        feature-cfg)
        [(ErrCompilerLoadWithPaths _) true]
        [(OkCompilerLoadWithPaths _ _ _ _) false]))))

(define (compiler-load-file-import-dedup-cycle-ok?) : bool
  (begin
    (write-file
      "target/compiler_load_dep.tl"
      "(module smoke.dep)
(import \"compiler_load_entry.tl\" module smoke.entry as entry)
(define dep : i64 1)")
    (write-file
      "target/compiler_load_entry.tl"
      "(module smoke.entry)
(import \"compiler_load_dep.tl\" module smoke.dep as dep)
(import \"./compiler_load_dep.tl\" module smoke.dep)
(define (main) : i64 dep)")
    (match (compiler-load-file-with-paths
      "target/compiler_load_entry.tl"
      (sym-i64-empty))
      [(OkCompilerLoadWithPaths decls _ modules seen)
        (and
          (= (compiler-load-decl-list-count decls) 6)
          (and
            (compiler-load-entry-cycle-modules? modules)
            (and
              (sym-i64-contains seen "smoke.entry")
              (sym-i64-contains seen "smoke.dep"))))]
      [(ErrCompilerLoadWithPaths _) false])))

(define (compiler-load-file-fallback-path-dedup-ok?) : bool
  (begin
    (write-file
      "target/compiler_load_legacy_dep.tl"
      "(define legacy-dep : i64 1)")
    (write-file
      "target/compiler_load_legacy_entry.tl"
      "(import \"compiler_load_legacy_dep.tl\")
(import \"./compiler_load_legacy_dep.tl\")
(define (main) : i64 legacy-dep)")
    (match (compiler-load-file-with-paths
      "target/compiler_load_legacy_entry.tl"
      (sym-i64-empty))
      [(OkCompilerLoadWithPaths decls _ modules seen)
        (and
          (= (compiler-load-decl-list-count decls) 2)
          (and
            (match modules
              [(AstDeclModuleCons first tail)
                (let
                  [tail : AstDeclModuleList (box-get tail)]
                  (match tail
                    [(AstDeclModuleCons second AstDeclModuleNil)
                      (and
                        (string-eq first "target/compiler_load_legacy_dep.tl")
                        (string-eq
                          second
                          "target/compiler_load_legacy_entry.tl"))]
                    [_ false]))]
              [_ false])
            (sym-i64-contains seen "target/compiler_load_legacy_dep.tl")))]
      [(ErrCompilerLoadWithPaths _) false])))

(define (compiler-load-import-alias-preserved-ok?) : bool
  (begin
    (write-file
      "target/cl_alias_dep.tl"
      "(module alias.dep)
(define (get) : i64 7)")
    (write-file
      "target/cl_alias_entry.tl"
      "(import \"cl_alias_dep.tl\" module alias.dep :as dep)
(module alias.entry)
(define (main) : i64 (dep/get))")
    (match (compiler-load-file-with-paths
      "target/cl_alias_entry.tl"
      (sym-i64-empty))
      [(OkCompilerLoadWithPaths decls _ _ _)
        (compiler-load-decl-list-has-import-alias? decls "alias.dep" "dep")]
      [(ErrCompilerLoadWithPaths _) false])))

;; Diamond import dedup (#1074 / #1041): entry imports A and B, both of which
;; import C; C must load exactly once. Writes fixture modules under target/ and
;; loads through the file loader, mirroring the existing dedup/cycle self-test.
(define (compiler-load-diamond-import-ok?) : bool
  (begin
    (write-file
      "target/cl_diamond_c.tl"
      "(module diamond.c)
(define c-val : i64 1)")
    (write-file
      "target/cl_diamond_a.tl"
      "(module diamond.a)
(import \"cl_diamond_c.tl\" module diamond.c as c)
(define a-val : i64 1)")
    (write-file
      "target/cl_diamond_b.tl"
      "(module diamond.b)
(import \"cl_diamond_c.tl\" module diamond.c as c)
(define b-val : i64 1)")
    (write-file
      "target/cl_diamond_entry.tl"
      "(module diamond.entry)
(import \"cl_diamond_a.tl\" module diamond.a as a)
(import \"cl_diamond_b.tl\" module diamond.b as b)
(define (main) : i64 0)")
    (match (compiler-load-file-with-paths
      "target/cl_diamond_entry.tl"
      (sym-i64-empty))
      [(OkCompilerLoadWithPaths decls _ _ seen)
        (and
          (= (compiler-load-decl-list-count decls) 12)
          (and
            (sym-i64-contains seen "diamond.c")
            (and
              (sym-i64-contains seen "diamond.a")
              (and
                (sym-i64-contains seen "diamond.b")
                (sym-i64-contains seen "diamond.entry")))))]
      [(ErrCompilerLoadWithPaths _) false])))

;; Transitive import dedup (#1074 / #1041): entry imports A, A imports B, B
;; imports C; the whole chain loads with the deterministic loaded decl count and
;; every module recorded in the seen set.
(define (compiler-load-transitive-import-ok?) : bool
  (begin
    (write-file "target/cl_tr_c.tl" "(module tr.c)
(define c-val : i64 1)")
    (write-file
      "target/cl_tr_b.tl"
      "(module tr.b)
(import \"cl_tr_c.tl\" module tr.c as c)
(define b-val : i64 1)")
    (write-file
      "target/cl_tr_a.tl"
      "(module tr.a)
(import \"cl_tr_b.tl\" module tr.b as b)
(define a-val : i64 1)")
    (write-file
      "target/cl_tr_entry.tl"
      "(module tr.entry)
(import \"cl_tr_a.tl\" module tr.a as a)
(define (main) : i64 0)")
    (match (compiler-load-file-with-paths
      "target/cl_tr_entry.tl"
      (sym-i64-empty))
      [(OkCompilerLoadWithPaths decls _ _ seen)
        (and
          (= (compiler-load-decl-list-count decls) 11)
          (and
            (sym-i64-contains seen "tr.c")
            (and
              (sym-i64-contains seen "tr.b")
              (and
                (sym-i64-contains seen "tr.a")
                (sym-i64-contains seen "tr.entry")))))]
      [(ErrCompilerLoadWithPaths _) false])))

;; An `(import ...)` of a path that does not resolve to a readable file reports
;; a `cannot read import <path>` diagnostic (the imported-file diagnostic; #1074).
(define (compiler-load-missing-import-ok?) : bool
  (match (compiler-load-source
    "src/app.tl"
    "(import \"no_such_module_xyz.tl\")
(define value : i64 1)"
    (sym-i64-empty))
    [(ErrCompilerLoad diag)
      (string-eq
        (compiler-diagnostic-message diag)
        "compiler-load: cannot read import src/no_such_module_xyz.tl")]
    [(OkCompilerLoad _ _) false]))

(define (compiler-load-include-str-relative-ok?) : bool
  (begin
    (write-file "target/cl_include_payload.txt" "hello from include")
    (write-file
      "target/cl_include_entry.tl"
      "(include-str payload \"cl_include_payload.txt\")
(define (main) : i64 0)")
    (match (compiler-load-file-with-paths
      "target/cl_include_entry.tl"
      (sym-i64-empty))
      [(OkCompilerLoadWithPaths decls _ _ _)
        (and
          (= (compiler-load-decl-list-count decls) 2)
          (compiler-load-first-string-def? decls "payload" "hello from include"))]
      [(ErrCompilerLoadWithPaths _) false])))

(define (compiler-load-include-str-stdlib-root-ok?) : bool
  (begin
    (write-file "target/cl_include_root_payload.txt" "hello from root")
    (match (compiler-load-source-with-paths-and-roots
      "src/include_entry.tl"
      "(include-str embedded \"stdlib/cl_include_root_payload.txt\")
(define (main) : i64 0)"
      (sym-i64-empty)
      (CompilerLoadRootCons "target" CompilerLoadRootNil))
      [(OkCompilerLoadWithPaths decls _ _ _)
        (and
          (= (compiler-load-decl-list-count decls) 2)
          (compiler-load-first-string-def? decls "embedded" "hello from root"))]
      [(ErrCompilerLoadWithPaths _) false])))

(define (compiler-load-missing-include-str-ok?) : bool
  (match (compiler-load-source
    "src/app.tl"
    "(include-str missing \"no_such_resource_xyz.txt\")
(define value : i64 1)"
    (sym-i64-empty))
    [(ErrCompilerLoad diag)
      (string-eq
        (compiler-diagnostic-message diag)
        "compiler-load: cannot read include-str no_such_resource_xyz.txt from src/app.tl (resolved src/no_such_resource_xyz.txt)")]
    [(OkCompilerLoad _ _) false]))

(define (compiler-load-include-str-raw-text-ok?) : bool
  (let
    [payload : String
      "(import \"definitely_missing.tl\")
(define injected : i64 7)"]
    (begin
      (write-file "target/cl_include_raw_payload.txt" payload)
      (write-file
        "target/cl_include_raw_entry.tl"
        "(include-str payload \"cl_include_raw_payload.txt\")
(define (main) : i64 0)")
      (match (compiler-load-file-with-paths
        "target/cl_include_raw_entry.tl"
        (sym-i64-empty))
        [(OkCompilerLoadWithPaths decls _ _ _)
          (and
            (= (compiler-load-decl-list-count decls) 2)
            (compiler-load-first-string-def? decls "payload" payload))]
        [(ErrCompilerLoadWithPaths _) false]))))

(define (compiler-load-embedded-stdlib-lookup-ok?) : bool
  (match (compiler-load-embedded-stdlib-source "string.tl")
    [(CompilerEmbeddedStdlibSomeSource source)
      (match (compiler-load-source-with-paths-and-roots
        "stdlib/string.tl"
        source
        (sym-i64-empty)
        CompilerLoadRootNil)
        [(OkCompilerLoadWithPaths decls _ _ _)
          (> (compiler-load-decl-list-count decls) 0)]
        [(ErrCompilerLoadWithPaths _) false])]
    [(CompilerEmbeddedStdlibNoSource) false]))

(define (compiler-load-embedded-stdlib-missing-ok?) : bool
  (match (compiler-load-embedded-stdlib-source "definitely_missing_xyz.tl")
    [(CompilerEmbeddedStdlibNoSource) true]
    [(CompilerEmbeddedStdlibSomeSource _) false]))

(define (compiler-load-embedded-stdlib-escape-rejected-ok?) : bool
  (match (compiler-load-embedded-stdlib-source "../string.tl")
    [(CompilerEmbeddedStdlibNoSource) true]
    [(CompilerEmbeddedStdlibSomeSource _) false]))

;; A parse error inside an imported file surfaces a diagnostic whose path is the
;; imported file (not the importer), preserving imported-file provenance (#1074).
(define (compiler-load-imported-parse-error-path-ok?) : bool
  (begin
    (write-file
      "target/cl_ipe_dep.tl"
      "(module ipe.dep)
(define broken : i64 )")
    (write-file
      "target/cl_ipe_entry.tl"
      "(module ipe.entry)
(import \"cl_ipe_dep.tl\" module ipe.dep as dep)
(define (main) : i64 0)")
    (match (compiler-load-file-with-paths
      "target/cl_ipe_entry.tl"
      (sym-i64-empty))
      [(ErrCompilerLoadWithPaths diag)
        (and
          (string-eq (compiler-diagnostic-path diag) "target/cl_ipe_dep.tl")
          (string-eq
            (compiler-diagnostic-message diag)
            "parse: malformed value definition"))]
      [(OkCompilerLoadWithPaths _ _ _ _) false])))

;; A duplicate `(module ...)` declaration inside an imported file surfaces a
;; diagnostic whose path is the imported file, not the importer (#1074).
(define (compiler-load-imported-duplicate-module-path-ok?) : bool
  (begin
    (write-file
      "target/cl_idm_dep.tl"
      "(module idm.depa)
(module idm.depb)
(define v : i64 1)")
    (write-file
      "target/cl_idm_entry.tl"
      "(module idm.entry)
(import \"cl_idm_dep.tl\" module idm.depa as dep)
(define (main) : i64 0)")
    (match (compiler-load-file-with-paths
      "target/cl_idm_entry.tl"
      (sym-i64-empty))
      [(ErrCompilerLoadWithPaths diag)
        (and
          (string-eq (compiler-diagnostic-path diag) "target/cl_idm_dep.tl")
          (string-eq
            (compiler-diagnostic-message diag)
            "compiler-load: duplicate module declaration"))]
      [(OkCompilerLoadWithPaths _ _ _ _) false])))

;; A `stdlib/<x>` import whose importer-relative path is absent resolves through
;; a configured `--stdlib-root` (root fallback) (#1074).
(define (compiler-load-stdlib-root-fallback-ok?) : bool
  (begin
    (write-file "target/cl_srf_mod.tl" "(module srf.mod)
(define v : i64 1)")
    (write-file
      "target/cl_srf_entry.tl"
      "(module srf.entry)
(import \"stdlib/cl_srf_mod.tl\" module srf.mod as m)
(define (main) : i64 0)")
    (match (compiler-load-file-with-paths-and-roots
      "target/cl_srf_entry.tl"
      (sym-i64-empty)
      (CompilerLoadRootCons "target" CompilerLoadRootNil))
      [(OkCompilerLoadWithPaths _ _ _ seen) (sym-i64-contains seen "srf.mod")]
      [(ErrCompilerLoadWithPaths _) false])))

;; `--stdlib-root` resolution searches roots in order; the first existing
;; candidate wins, so a missing leading root is skipped (#1074).
(define (compiler-load-stdlib-searched-root-ok?) : bool
  (begin
    (write-file "target/cl_ssr_mod.tl" "(module ssr.mod)
(define v : i64 1)")
    (write-file
      "target/cl_ssr_entry.tl"
      "(module ssr.entry)
(import \"stdlib/cl_ssr_mod.tl\" module ssr.mod as m)
(define (main) : i64 0)")
    (match (compiler-load-file-with-paths-and-roots
      "target/cl_ssr_entry.tl"
      (sym-i64-empty)
      (CompilerLoadRootCons
        "target/cl_ssr_absent_root"
        (CompilerLoadRootCons "target" CompilerLoadRootNil)))
      [(OkCompilerLoadWithPaths _ _ _ seen) (sym-i64-contains seen "ssr.mod")]
      [(ErrCompilerLoadWithPaths _) false])))

;; A `stdlib/<x>` import found in no configured root reports a cannot-read
;; diagnostic naming the importer-relative candidate path (#1074).
(define (compiler-load-stdlib-unresolved-ok?) : bool
  (begin
    (write-file
      "target/cl_sur_entry.tl"
      "(module sur.entry)
(import \"stdlib/cl_sur_missing.tl\" module sur.mod as m)
(define (main) : i64 0)")
    (match (compiler-load-file-with-paths-and-roots
      "target/cl_sur_entry.tl"
      (sym-i64-empty)
      (CompilerLoadRootCons "target" CompilerLoadRootNil))
      [(ErrCompilerLoadWithPaths diag)
        (string-eq
          (compiler-diagnostic-message diag)
          "compiler-load: cannot read import target/stdlib/cl_sur_missing.tl")]
      [(OkCompilerLoadWithPaths _ _ _ _) false])))

;; A configured stdlib root must not serve a suffix that lexically escapes the
;; root with `..` (#1681).
(define (compiler-load-stdlib-root-escape-rejected-ok?) : bool
  (let
    [root-dir : String "target/cl_sre_root"]
    [entry-dir : String "target/cl_sre_entry_dir"]
    (begin
      (fs-mkdir-status-owned root-dir)
      (fs-mkdir-status-owned entry-dir)
      (write-file "target/cl_sre_out.tl" "(module sre.out)
(define v : i64 1)")
      (write-file
        "target/cl_sre_entry_dir/entry.tl"
        "(module sre.entry)
(import \"stdlib/../cl_sre_out.tl\" module sre.out as out)
(define (main) : i64 0)")
      (match (compiler-load-file-with-paths-and-roots
        "target/cl_sre_entry_dir/entry.tl"
        (sym-i64-empty)
        (CompilerLoadRootCons "target/cl_sre_root" CompilerLoadRootNil))
        [(ErrCompilerLoadWithPaths _) true]
        [(OkCompilerLoadWithPaths _ _ _ _) false]))))

;: --- typelisp.pkg manifest parser (#834, slice 1) ---------------------------
;: Parse a `typelisp.pkg` manifest, an S-expression of the form
;:   (package (name "...") (version "...") (kind "bin") (entry "...")
;:            (dependencies (alias "path") ...))
;: into a structured value. Reuses the selfhost reader (`lex` + `read-result`,
;: both already reachable here via compiler_parse_core -> read.tl) instead of a
;: bespoke manifest tokenizer.
;: A parsed dependency: an import alias and its package-root path.
(defstruct CompilerPkgDep
  (alias String)
  (path String))

;: Alias->path dependency list from a parsed manifest.
(defenum CompilerPkgDepList
  (CompilerPkgDepNil)
  (CompilerPkgDepCons CompilerPkgDep CompilerPkgDepList))

;: Package artifact kind: binary executable or static library.
(defenum CompilerPkgKind
  (CompilerPkgKindBin)
  (CompilerPkgKindLib))

;: A parsed `typelisp.pkg` manifest.
(defstruct CompilerPkgManifest
  (name String)
  (version String)
  (kind CompilerPkgKind)
  (entry String)
  (deps CompilerPkgDepList))

;: Parse result: the manifest or a diagnostic.
(defenum ResultCompilerPkgManifest
  (OkCompilerPkgManifest CompilerPkgManifest)
  (ErrCompilerPkgManifest String))

;: Internal: a single extracted string field value, or a diagnostic.
(defenum ResultPkgString
  (OkPkgString String)
  (ErrPkgString String))

;: Internal: a parsed package kind, or a diagnostic.
(defenum ResultCompilerPkgKind
  (OkCompilerPkgKind CompilerPkgKind)
  (ErrCompilerPkgKind String))

;: Internal: a parsed dependency list, or a diagnostic.
(defenum ResultCompilerPkgDepList
  (OkCompilerPkgDepList CompilerPkgDepList)
  (ErrCompilerPkgDepList String))

;: Count the dependencies in a parsed list.
(define (compiler-pkg-dep-list-count [deps : CompilerPkgDepList]) : i64
  (match deps
    [(CompilerPkgDepNil) 0]
    [(CompilerPkgDepCons _ rest) (+ 1 (compiler-pkg-dep-list-count rest))]))

(define (compiler-load-package-name-char? [c : char]) : bool
  (let
    [code : i64 (cast c : i64)]
    (or
      (and (>= code 48) (<= code 57))
      (or
        (and (>= code 65) (<= code 90))
        (or (and (>= code 97) (<= code 122)) (or (= code 45) (= code 95)))))))

(define (compiler-load-package-token-valid? [value : String]) : bool
  (let
    [n : i64 (string-length value)]
    [i : i64 0]
    [ok : bool (> n 0)]
    (begin
      (while ok
        (if (< i n)
          (if (compiler-load-package-name-char? (string-ref value i))
            (set! i (+ i 1))
            (set! ok false))
          (set! ok false)))
      (= i n))))

(define (compiler-load-github-component-char? [c : char]) : bool
  (or (compiler-load-package-name-char? c) (= c #.')))

(define (compiler-load-github-component-valid? [value : String]) : bool
  (let
    [n : i64 (string-length value)]
    [i : i64 0]
    [ok : bool (> n 0)]
    (begin
      (while ok
        (if (< i n)
          (if (compiler-load-github-component-char? (string-ref value i))
            (set! i (+ i 1))
            (set! ok false))
          (set! ok false)))
      (= i n))))

(define (compiler-load-github-dependency-path? [path : String]) : bool
  (compiler-load-string-prefix-at? path "https://github.com/" 0))

(define (compiler-load-github-pin-kind-valid? [kind : String]) : bool
  (or
    (string-eq kind "rev")
    (or (string-eq kind "tag") (string-eq kind "branch"))))

(define (compiler-load-github-address-body [address : String]) : String
  (if (compiler-load-string-prefix-at? address "github.com/" 0)
    (substring address 11 (- (string-length address) 11))
    address))

(define (compiler-load-github-address-error [alias : String]) : ResultPkgString
  (ErrPkgString
    (string-append
      "manifest dependency `"
      (string-append
        alias
        "` github address must be `owner/repo` or `github.com/owner/repo`"))))

(define (compiler-load-normalize-github-address
  [alias : String]
  [address : String]
  [pin-kind : String]
  [pin-value : String]) : ResultPkgString
  (let
    [body : String (compiler-load-github-address-body address)]
    [body-len : i64 (string-length body)]
    [slash : i64 (compiler-load-slash-index-from body 0 body-len)]
    (if (or (< slash 1) (>= slash (- body-len 1)))
      (compiler-load-github-address-error alias)
      (let
        [owner : String (substring body 0 slash)]
        [repo : String (substring body (+ slash 1) (- body-len (+ slash 1)))]
        (if (>= (compiler-load-slash-index-from repo 0 (string-length repo)) 0)
          (compiler-load-github-address-error alias)
          (if (not (compiler-load-github-component-valid? owner))
            (compiler-load-github-address-error alias)
            (if (not (compiler-load-github-component-valid? repo))
              (compiler-load-github-address-error alias)
              (OkPkgString
                (string-append
                  "https://github.com/"
                  (string-append
                    owner
                    (string-append
                      "/"
                      (string-append
                        repo
                        (string-append
                          ".git#"
                          (string-append pin-kind (string-append "=" pin-value)))))))))))))))

(define (compiler-load-normal-relative-entry? [path : String]) : bool
  (compiler-load-safe-relative? path))

(define (compiler-load-pkg-dep-alias-seen?
  [deps : CompilerPkgDepList]
  [target-alias : String]) : bool
  (match deps
    [(CompilerPkgDepNil) false]
    [(CompilerPkgDepCons dep rest)
      (if (string-eq (struct-get dep alias) target-alias)
        true
        (compiler-load-pkg-dep-alias-seen? rest target-alias))]))

;: Extract a single `"value"` from a field tail `("value")`.
(define (compiler-load-manifest-string-value [ftail : Sexpr] [fname : String]) : ResultPkgString
  (match ftail
    [(SCons vhead vrest)
      (match vhead
        [(SStr val)
          (match vrest
            [(SNil) (OkPkgString val)]
            [_
              (ErrPkgString
                (string-append
                  "manifest field `"
                  (string-append fname "` takes a single string value")))])]
        [_
          (ErrPkgString
            (string-append
              "manifest field `"
              (string-append fname "` must have a string value")))])]
    [_
      (ErrPkgString
        (string-append
          "manifest field `"
          (string-append fname "` must have a string value")))]))

(define (compiler-load-manifest-github-pin
  [alias : String]
  [address : String]
  [pin-form : Sexpr]) : ResultPkgString
  (match pin-form
    [(SCons (SSym pin-kind) pin-tail)
      (if (compiler-load-github-pin-kind-valid? pin-kind)
        (match pin-tail
          [(SCons (SStr pin-value) (SNil))
            (if (string-eq pin-value "")
              (ErrPkgString
                (string-append
                  "manifest dependency `"
                  (string-append alias "` github pin must not be empty")))
              (compiler-load-normalize-github-address
                alias
                address
                pin-kind
                pin-value))]
          [_
            (ErrPkgString
              (string-append
                "manifest dependency `"
                (string-append
                  alias
                  "` github pin must be a single string value")))])
        (ErrPkgString
          (string-append
            "manifest dependency `"
            (string-append alias "` github pin must be rev, tag, or branch"))))]
    [_
      (ErrPkgString
        (string-append
          "manifest dependency `"
          (string-append
            alias
            "` github source requires exactly one rev, tag, or branch pin")))]))

(define (compiler-load-manifest-github-value
  [alias : String]
  [source-tail : Sexpr]) : ResultPkgString
  (match source-tail
    [(SCons (SStr address) after-address)
      (match after-address
        [(SCons pin-form (SNil))
          (compiler-load-manifest-github-pin alias address pin-form)]
        [_
          (ErrPkgString
            (string-append
              "manifest dependency `"
              (string-append
                alias
                "` github source requires exactly one rev, tag, or branch pin")))])]
    [_
      (ErrPkgString
        (string-append
          "manifest dependency `"
          (string-append
            alias
            "` github source must be `(github \"owner/repo\" (rev|tag|branch \"pin\"))`")))]))

(define (compiler-load-manifest-dependency-value
  [etail : Sexpr]
  [alias : String]) : ResultPkgString
  (match etail
    [(SCons vhead vrest)
      (match vrest
        [(SNil)
          (match vhead
            [(SStr path) (OkPkgString path)]
            [(SCons (SSym source-kind) source-tail)
              (if (string-eq source-kind "github")
                (compiler-load-manifest-github-value alias source-tail)
                (ErrPkgString
                  (string-append
                    "manifest dependency `"
                    (string-append
                      alias
                      "` must be a path string or github source"))))]
            [_
              (ErrPkgString
                (string-append
                  "manifest dependency `"
                  (string-append
                    alias
                    "` must be a path string or github source")))])]
        [_
          (ErrPkgString
            (string-append
              "manifest dependency `"
              (string-append
                alias
                "` takes a single path string or github source")))])]
    [_
      (ErrPkgString
        (string-append
          "manifest dependency `"
          (string-append alias "` must be a path string or github source")))]))

(define (compiler-load-manifest-kind-token [val : String]) : ResultCompilerPkgKind
  (if (string-eq val "bin")
    (OkCompilerPkgKind (CompilerPkgKindBin))
    (if (or (string-eq val "staticlib") (string-eq val "lib"))
      (OkCompilerPkgKind (CompilerPkgKindLib))
      (ErrCompilerPkgKind
        "manifest field `kind` must be `bin`, `staticlib`, or `lib`"))))

(define (compiler-load-manifest-kind-value [ftail : Sexpr]) : ResultCompilerPkgKind
  (match ftail
    [(SCons vhead vrest)
      (match vrest
        [(SNil)
          (match vhead
            [(SStr val) (compiler-load-manifest-kind-token val)]
            [(SSym val) (compiler-load-manifest-kind-token val)]
            [_
              (ErrCompilerPkgKind
                "manifest field `kind` must have a string or symbol value")])]
        [_ (ErrCompilerPkgKind "manifest field `kind` takes a single value")])]
    [_
      (ErrCompilerPkgKind
        "manifest field `kind` must have a string or symbol value")]))

(define (compiler-load-manifest-cons-dep
  [alias : String]
  [path : String]
  [rest : Sexpr]) : ResultCompilerPkgDepList
  (cond
    [(string-eq alias "")
      (ErrCompilerPkgDepList "dependency alias must not be empty")]
    [(not (compiler-load-package-token-valid? alias))
      (ErrCompilerPkgDepList
        "dependency alias may only contain ASCII letters, digits, '-' and '_'")]
    [(string-eq path "")
      (ErrCompilerPkgDepList
        (string-append
          "manifest dependency `"
          (string-append alias "` path must not be empty")))]
    [else
      (match (compiler-load-manifest-parse-deps rest)
        [(ErrCompilerPkgDepList m) (ErrCompilerPkgDepList m)]
        [(OkCompilerPkgDepList tail-deps)
          (if (compiler-load-pkg-dep-alias-seen? tail-deps alias)
            (ErrCompilerPkgDepList
              (string-append
                "duplicate dependency alias `"
                (string-append alias "`")))
            (OkCompilerPkgDepList
              (CompilerPkgDepCons (CompilerPkgDep alias path) tail-deps)))])]))

;: Parse the `(alias "path") ...` entries of a `(dependencies ...)` field.
(define (compiler-load-manifest-parse-deps [entries : Sexpr]) : ResultCompilerPkgDepList
  (match entries
    [(SNil) (OkCompilerPkgDepList (CompilerPkgDepNil))]
    [(SCons entry rest)
      (match entry
        [(SCons ehead etail)
          (match ehead
            [(SSym alias)
              (match (compiler-load-manifest-dependency-value etail alias)
                [(ErrPkgString m) (ErrCompilerPkgDepList m)]
                [(OkPkgString path)
                  (compiler-load-manifest-cons-dep alias path rest)])]
            [_
              (ErrCompilerPkgDepList
                "dependency entries must start with an alias name")])]
        [_
          (ErrCompilerPkgDepList
            "dependency entries must be lists like `(alias \"path\")`")])]
    [_
      (ErrCompilerPkgDepList
        "`dependencies` must be a list of `(alias \"path\")` or `(alias (github ...))` entries")]))

(define (compiler-load-manifest-default-entry [kind : CompilerPkgKind]) : String
  (match kind
    [(CompilerPkgKindBin) "src/main.tl"]
    [(CompilerPkgKindLib) "src/lib.tl"]))

;: Walk the package fields, accumulating name/version/kind/entry/deps, then
;: check required fields and synthesize convention defaults for omitted kind
;: and entry.
(define (compiler-load-manifest-fields
  [fields : Sexpr]
  [name : String]
  [has-name : bool]
  [version : String]
  [has-version : bool]
  [kind : CompilerPkgKind]
  [has-kind : bool]
  [entry : String]
  [has-entry : bool]
  [has-deps : bool]
  [deps : CompilerPkgDepList]) : ResultCompilerPkgManifest
  (match fields
    [(SNil)
      (let
        [final-entry : String
          (if has-entry
            entry
            (compiler-load-manifest-default-entry kind))]
        (cond
          [(not has-name)
            (ErrCompilerPkgManifest "manifest missing required field `name`")]
          [(string-eq name "")
            (ErrCompilerPkgManifest "manifest field `name` must not be empty")]
          [(not (compiler-load-package-token-valid? name))
            (ErrCompilerPkgManifest
              "manifest field `name` may only contain ASCII letters, digits, '-' and '_'")]
          [(not has-version)
            (ErrCompilerPkgManifest "manifest missing required field `version`")]
          [(string-eq version "")
            (ErrCompilerPkgManifest
              "manifest field `version` must not be empty")]
          [(string-eq final-entry "")
            (ErrCompilerPkgManifest "manifest field `entry` must not be empty")]
          [(not (compiler-load-normal-relative-entry? final-entry))
            (ErrCompilerPkgManifest
              "manifest field `entry` must be a normal relative path below the manifest directory")]
          [else
            (OkCompilerPkgManifest
              (CompilerPkgManifest name version kind final-entry deps))]))]
    [(SCons field rest)
      (match field
        [(SCons fhead ftail)
          (match fhead
            [(SSym fname)
              (cond
                [(string-eq fname "dependencies")
                  (if has-deps
                    (ErrCompilerPkgManifest
                      "duplicate manifest field `dependencies`")
                    (match (compiler-load-manifest-parse-deps ftail)
                      [(ErrCompilerPkgDepList m) (ErrCompilerPkgManifest m)]
                      [(OkCompilerPkgDepList parsed-deps)
                        (compiler-load-manifest-fields
                          rest
                          name
                          has-name
                          version
                          has-version
                          kind
                          has-kind
                          entry
                          has-entry
                          true
                          parsed-deps)]))]
                [(string-eq fname "name")
                  (if has-name
                    (ErrCompilerPkgManifest "duplicate manifest field `name`")
                    (match (compiler-load-manifest-string-value ftail fname)
                      [(ErrPkgString m) (ErrCompilerPkgManifest m)]
                      [(OkPkgString val)
                        (compiler-load-manifest-fields
                          rest
                          val
                          true
                          version
                          has-version
                          kind
                          has-kind
                          entry
                          has-entry
                          has-deps
                          deps)]))]
                [(string-eq fname "version")
                  (if has-version
                    (ErrCompilerPkgManifest
                      "duplicate manifest field `version`")
                    (match (compiler-load-manifest-string-value ftail fname)
                      [(ErrPkgString m) (ErrCompilerPkgManifest m)]
                      [(OkPkgString val)
                        (compiler-load-manifest-fields
                          rest
                          name
                          has-name
                          val
                          true
                          kind
                          has-kind
                          entry
                          has-entry
                          has-deps
                          deps)]))]
                [(string-eq fname "kind")
                  (if has-kind
                    (ErrCompilerPkgManifest "duplicate manifest field `kind`")
                    (match (compiler-load-manifest-kind-value ftail)
                      [(ErrCompilerPkgKind m) (ErrCompilerPkgManifest m)]
                      [(OkCompilerPkgKind val)
                        (compiler-load-manifest-fields
                          rest
                          name
                          has-name
                          version
                          has-version
                          val
                          true
                          entry
                          has-entry
                          has-deps
                          deps)]))]
                [(string-eq fname "entry")
                  (if has-entry
                    (ErrCompilerPkgManifest "duplicate manifest field `entry`")
                    (match (compiler-load-manifest-string-value ftail fname)
                      [(ErrPkgString m) (ErrCompilerPkgManifest m)]
                      [(OkPkgString val)
                        (compiler-load-manifest-fields
                          rest
                          name
                          has-name
                          version
                          has-version
                          kind
                          has-kind
                          val
                          true
                          has-deps
                          deps)]))]
                [else
                  (ErrCompilerPkgManifest
                    (string-append
                      "unknown manifest field `"
                      (string-append fname "`")))])]
            [_
              (ErrCompilerPkgManifest
                "package fields must start with a field name")])]
        [_
          (ErrCompilerPkgManifest
            "package fields must be lists like `(name \"...\")`")])]
    [_
      (ErrCompilerPkgManifest
        "package fields must be lists like `(name \"...\")`")]))

;: Parse the top-level `(package ...)` form.
(define (compiler-load-manifest-from-form [form : Sexpr]) : ResultCompilerPkgManifest
  (match form
    [(SCons head rest)
      (match head
        [(SSym s)
          (if (string-eq s "package")
            (compiler-load-manifest-fields
              rest
              ""
              false
              ""
              false
              (CompilerPkgKindBin)
              false
              ""
              false
              false
              (CompilerPkgDepNil))
            (ErrCompilerPkgManifest
              (string-append
                "expected `package` form, got `"
                (string-append s "`"))))]
        [_ (ErrCompilerPkgManifest "manifest must start with `package`")])]
    [_ (ErrCompilerPkgManifest "manifest must be a `(package ...)` form")]))

;: Parse a `typelisp.pkg` manifest source string into a structured manifest.
(define (compiler-load-parse-manifest [source : String]) : ResultCompilerPkgManifest
  (match (read-result (lex source))
    [(ErrSexpr msg) (ErrCompilerPkgManifest (string-append "manifest: " msg))]
    [(OkSexpr form) (compiler-load-manifest-from-form form)]))

;: Self-test: a full manifest parses with the expected fields + dependency
;: count.
(define (compiler-load-manifest-valid-full-ok?) : bool
  (match (compiler-load-parse-manifest
    "(package (name \"demo\") (version \"0.1.0\") (kind \"bin\") (entry \"src/main.tl\") (dependencies (math \"../math\") (util \"../util\")))")
    [(OkCompilerPkgManifest m)
      (and
        (string-eq (struct-get m name) "demo")
        (and
          (string-eq (struct-get m version) "0.1.0")
          (match (struct-get m kind)
            [(CompilerPkgKindBin)
              (and
                (string-eq (struct-get m entry) "src/main.tl")
                (= (compiler-pkg-dep-list-count (struct-get m deps)) 2))]
            [(CompilerPkgKindLib) false])))]
    [(ErrCompilerPkgManifest _) false]))

;: Self-test: a manifest without a `dependencies` field parses with no deps.
(define (compiler-load-manifest-valid-nodeps-ok?) : bool
  (match (compiler-load-parse-manifest
    "(package (name \"x\") (version \"1\") (kind staticlib))")
    [(OkCompilerPkgManifest m)
      (match (struct-get m kind)
        [(CompilerPkgKindLib)
          (and
            (string-eq (struct-get m entry) "src/lib.tl")
            (= (compiler-pkg-dep-list-count (struct-get m deps)) 0))]
        [(CompilerPkgKindBin) false])]
    [(ErrCompilerPkgManifest _) false]))

(define (compiler-load-manifest-default-bin-ok?) : bool
  (match (compiler-load-parse-manifest
    "(package (name \"default_bin\") (version \"1\"))")
    [(OkCompilerPkgManifest m)
      (match (struct-get m kind)
        [(CompilerPkgKindBin) (string-eq (struct-get m entry) "src/main.tl")]
        [(CompilerPkgKindLib) false])]
    [(ErrCompilerPkgManifest _) false]))

(define (compiler-load-manifest-entry-override-ok?) : bool
  (match (compiler-load-parse-manifest
    "(package (name \"override\") (version \"1\") (kind \"staticlib\") (entry \"custom/lib.tl\"))")
    [(OkCompilerPkgManifest m)
      (match (struct-get m kind)
        [(CompilerPkgKindLib) (string-eq (struct-get m entry) "custom/lib.tl")]
        [(CompilerPkgKindBin) false])]
    [(ErrCompilerPkgManifest _) false]))

(define (compiler-load-manifest-dep-path-is?
  [deps : CompilerPkgDepList]
  [alias : String]
  [expected : String]) : bool
  (match (compiler-load-pkg-dep-lookup deps alias)
    [(CompilerLoadSomePath path) (string-eq path expected)]
    [(CompilerLoadNoPath) false]))

(define (compiler-load-manifest-github-deps-ok?) : bool
  (match (compiler-load-parse-manifest
    "(package (name \"github_demo\") (version \"1\") (kind \"bin\") (entry \"src/main.tl\") (dependencies (math (github \"JoNil-Botta/math\" (rev \"abc123\"))) (util (github \"github.com/JoNil-Botta/util.repo\" (tag \"v1.0.0\"))) (core \"../core\")))")
    [(OkCompilerPkgManifest m)
      (let
        [deps : CompilerPkgDepList (struct-get m deps)]
        (and
          (= (compiler-pkg-dep-list-count deps) 3)
          (and
            (compiler-load-manifest-dep-path-is?
              deps
              "math"
              "https://github.com/JoNil-Botta/math.git#rev=abc123")
            (and
              (compiler-load-manifest-dep-path-is?
                deps
                "util"
                "https://github.com/JoNil-Botta/util.repo.git#tag=v1.0.0")
              (compiler-load-manifest-dep-path-is? deps "core" "../core")))))]
    [(ErrCompilerPkgManifest _) false]))

;: True when parsing `source` fails with exactly the `expected` diagnostic.
(define (compiler-load-manifest-rejects? [source : String] [expected : String]) : bool
  (match (compiler-load-parse-manifest source)
    [(ErrCompilerPkgManifest m) (string-eq m expected)]
    [(OkCompilerPkgManifest _) false]))

(define (compiler-load-pkg-manifest-github-validation-ok?) : bool
  (and
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (dependencies (math (github \"owner/repo\"))))"
      "manifest dependency `math` github source requires exactly one rev, tag, or branch pin")
    (and
      (compiler-load-manifest-rejects?
        "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (dependencies (math (github \"owner/repo/extra\" (rev \"abc\")))))"
        "manifest dependency `math` github address must be `owner/repo` or `github.com/owner/repo`")
      (and
        (compiler-load-manifest-rejects?
          "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (dependencies (math (github \"owner/repo\" (sha \"abc\")))))"
          "manifest dependency `math` github pin must be rev, tag, or branch")
        (compiler-load-manifest-rejects?
          "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (dependencies (math (github \"owner/repo\" (rev \"\")))))"
          "manifest dependency `math` github pin must not be empty")))))

(define (compiler-load-pkg-manifest-validation-ok?) : bool
  (and
    (compiler-load-manifest-rejects?
      "(package (name \"demo\") (name \"again\") (version \"1\") (kind \"bin\") (entry \"e.tl\"))"
      "duplicate manifest field `name`")
    (and
      (compiler-load-manifest-rejects?
        "(package (name \"\") (version \"1\") (kind \"bin\") (entry \"e.tl\"))"
        "manifest field `name` must not be empty")
      (and
        (compiler-load-manifest-rejects?
          "(package (name \"bad.name\") (version \"1\") (kind \"bin\") (entry \"e.tl\"))"
          "manifest field `name` may only contain ASCII letters, digits, '-' and '_'")
        (and
          (compiler-load-manifest-rejects?
            "(package (name \"x\") (version \"\") (kind \"bin\") (entry \"e.tl\"))"
            "manifest field `version` must not be empty")
          (and
            (compiler-load-manifest-rejects?
              "(package (name \"x\") (version \"1\") (kind \"bad\") (entry \"e.tl\"))"
              "manifest field `kind` must be `bin`, `staticlib`, or `lib`")
            (and
              (compiler-load-manifest-rejects?
                "(package (name \"x\") (version \"1\") (kind \"bin\") (kind \"lib\") (entry \"e.tl\"))"
                "duplicate manifest field `kind`")
              (and
                (compiler-load-manifest-rejects?
                  "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"\"))"
                  "manifest field `entry` must not be empty")
                (and
                  (compiler-load-manifest-rejects?
                    "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"../main.tl\"))"
                    "manifest field `entry` must be a normal relative path below the manifest directory")
                  (and
                    (compiler-load-manifest-rejects?
                      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (dependencies (math \"a\")) (dependencies (util \"b\")))"
                      "duplicate manifest field `dependencies`")
                    (and
                      (compiler-load-manifest-rejects?
                        "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (dependencies (math \"a\") (math \"b\")))"
                        "duplicate dependency alias `math`")
                      (and
                        (compiler-load-manifest-rejects?
                          "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (dependencies (bad.alias \"a\")))"
                          "dependency alias may only contain ASCII letters, digits, '-' and '_'")
                        (compiler-load-manifest-rejects?
                          "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (dependencies (math \"\")))"
                          "manifest dependency `math` path must not be empty")))))))))))))

;: Aggregate manifest-parser self-test (#834).
(define (compiler-load-pkg-manifest-ok?) : bool
  (and
    (compiler-load-manifest-valid-full-ok?)
    (and
      (compiler-load-manifest-valid-nodeps-ok?)
      (and
        (compiler-load-manifest-default-bin-ok?)
        (and
          (compiler-load-manifest-entry-override-ok?)
          (and
            (compiler-load-manifest-rejects?
              "(package (version \"1\") (kind \"bin\") (entry \"e.tl\"))"
              "manifest missing required field `name`")
            (and
              (compiler-load-manifest-rejects?
                "(package (name \"x\") (kind \"bin\") (entry \"e.tl\"))"
                "manifest missing required field `version`")
              (and
                (compiler-load-manifest-rejects?
                  "(module foo)"
                  "expected `package` form, got `module`")
                (and
                  (compiler-load-pkg-manifest-validation-ok?)
                  (and
                    (compiler-load-manifest-github-deps-ok?)
                    (compiler-load-pkg-manifest-github-validation-ok?)))))))))))

;: --- pkg:<alias>/... import resolution (#834, slice 2) ----------------------
;: Resolve a `pkg:<alias>/<rest>` import against a parsed manifest's dependency
;: list, relative to the manifest directory: `<manifest-dir>/<dep-path>/<rest>`,
;: normalized. Rejects a missing alias, an empty/`/`-less spec, and a `rest`
;: that escapes the dependency root via `..`, preserving those diagnostics when
;: the import resolver runs inside the selfhost driver.
;: True when an import path is a package import (`pkg:<alias>/...`).
(define (compiler-load-pkg-import? [path : String]) : bool
  (compiler-load-string-prefix-at? path "pkg:" 0))

;: Index of the first '/' in `s` at or after `i`, or -1 if none.
(define (compiler-load-slash-index-from [s : String] [i : i64] [n : i64]) : i64
  (if (>= i n)
    -1
    (if (= (string-ref s i) #/')
      i
      (compiler-load-slash-index-from s (+ i 1) n))))

;: True when a path is not a safe relative suffix below its package root.
(define (compiler-load-path-escapes? [path : String]) : bool
  (not (compiler-load-safe-relative? path)))

;: Look up a dependency's root path by import alias.
(define (compiler-load-pkg-dep-lookup
  [deps : CompilerPkgDepList]
  [target-alias : String]) : CompilerLoadMaybePath
  (match deps
    [(CompilerPkgDepNil) (CompilerLoadNoPath)]
    [(CompilerPkgDepCons dep rest)
      (if (string-eq (struct-get dep alias) target-alias)
        (CompilerLoadSomePath (struct-get dep path))
        (compiler-load-pkg-dep-lookup rest target-alias))]))

;: Resolve `pkg:<alias>/<rest>` against `deps`, relative to `manifest-dir`.
(define (compiler-load-resolve-pkg-import
  [import-path : String]
  [manifest-dir : String]
  [deps : CompilerPkgDepList]) : ResultPkgResolve
  (let
    [body : String (substring import-path 4 (- (string-length import-path) 4))]
    [slash : i64 (compiler-load-slash-index-from body 0 (string-length body))]
    (if (< slash 0)
      (ErrPkgResolve
        (string-append
          "compiler-load: pkg import missing '/' after alias: "
          import-path))
      (let
        [alias : String (substring body 0 slash)]
        [rest : String
          (substring body (+ slash 1) (- (string-length body) (+ slash 1)))]
        (if (= (string-length alias) 0)
          (ErrPkgResolve
            (string-append
              "compiler-load: pkg import has empty alias: "
              import-path))
          (match (compiler-load-pkg-dep-lookup deps alias)
            [(CompilerLoadNoPath)
              (ErrPkgResolve
                (string-append
                  "compiler-load: unknown package alias '"
                  (string-append alias (string-append "': " import-path))))]
            [(CompilerLoadSomePath dep-path)
              (if (compiler-load-github-dependency-path? dep-path)
                (ErrPkgResolve
                  (string-append
                    "compiler-load: GitHub dependency '"
                    (string-append
                      alias
                      (string-append
                        "' requires fetch support (#1157): "
                        import-path))))
                (let
                  [norm-rest : String (compiler-load-normalize-path rest)]
                  (if (compiler-load-path-escapes? norm-rest)
                    (ErrPkgResolve
                      (string-append
                        "compiler-load: pkg import escapes package root: "
                        import-path))
                    (OkPkgResolve
                      (compiler-load-normalize-path
                        (compiler-load-join-root-path
                          (compiler-load-join-root-path manifest-dir dep-path)
                          norm-rest))))))]))))))

;: Parent directory of a directory path, or no-path at the top. `dirname`
;: returns a path *including* its trailing separator, so a trailing separator
;: is stripped first to make the walk-up progress (e.g. `src/` -> ``, the cwd).
(define (compiler-load-parent-dir [dir : String]) : CompilerLoadMaybePath
  (let
    [n : i64 (string-length dir)]
    (if (= n 0)
      (CompilerLoadNoPath)
      (let
        [trimmed : String
          (if (compiler-load-path-separator? (string-ref dir (- n 1)))
            (substring dir 0 (- n 1))
            dir)]
        [parent : String (compiler-load-dirname trimmed)]
        (if (string-eq parent dir)
          (CompilerLoadNoPath)
          (CompilerLoadSomePath parent))))))

;: Walk up from `dir` looking for a `typelisp.pkg` manifest, mirroring the Rust
;: `discover_manifest` (src/package.rs). `fuel` bounds the climb.
(define (compiler-load-discover-manifest-up [dir : String] [fuel : i64]) : CompilerLoadMaybePath
  (if (<= fuel 0)
    (CompilerLoadNoPath)
    (let
      [candidate : String (string-append dir "typelisp.pkg")]
      (if (file-exists? candidate)
        (CompilerLoadSomePath candidate)
        (match (compiler-load-parent-dir dir)
          [(CompilerLoadNoPath) (CompilerLoadNoPath)]
          [(CompilerLoadSomePath parent)
            (compiler-load-discover-manifest-up parent (- fuel 1))])))))

;: Discover the nearest `typelisp.pkg` at or above the importer's directory.
(define (compiler-load-discover-manifest [start-path : String]) : CompilerLoadMaybePath
  (compiler-load-discover-manifest-up (compiler-load-dirname start-path) 256))

;: Resolve a `pkg:<alias>/...` import by discovering and parsing the nearest
;: `typelisp.pkg` relative to the importer, then resolving against its deps.
;: Missing manifests and parse errors fall back to the raw import path so the
;: loader reports a normal "cannot read import" error. Syntactically valid
;: manifests preserve pkg-resolution diagnostics into the caller.
(define (compiler-load-resolve-pkg-import-from-disk
  [importer-path : String]
  [import-path : String]) : ResultPkgResolve
  (match (compiler-load-discover-manifest importer-path)
    [(CompilerLoadNoPath) (OkPkgResolve import-path)]
    [(CompilerLoadSomePath manifest-path)
      (match (compiler-load-parse-manifest (read-file manifest-path))
        [(ErrCompilerPkgManifest _) (OkPkgResolve import-path)]
        [(OkCompilerPkgManifest manifest)
          (compiler-load-resolve-pkg-import
            import-path
            (compiler-load-dirname manifest-path)
            (struct-get manifest deps))])]))

;: Self-test fixture: local deps plus one GitHub dep that needs fetch support.
(define (compiler-load-pkg-resolve-deps) : CompilerPkgDepList
  (CompilerPkgDepCons
    (CompilerPkgDep "math" "../math")
    (CompilerPkgDepCons
      (CompilerPkgDep "util" "vendor/util")
      (CompilerPkgDepCons
        (CompilerPkgDep "remote" "https://github.com/owner/repo.git#rev=abc")
        (CompilerPkgDepNil)))))

;: True when resolving `import-path` yields exactly `expected`.
(define (compiler-load-pkg-resolves? [import-path : String] [expected : String]) : bool
  (match (compiler-load-resolve-pkg-import
    import-path
    "proj"
    (compiler-load-pkg-resolve-deps))
    [(OkPkgResolve p) (string-eq p expected)]
    [(ErrPkgResolve _) false]))

;: True when resolving `import-path` fails with exactly `expected`.
(define (compiler-load-pkg-resolve-rejects?
  [import-path : String]
  [expected : String]) : bool
  (match (compiler-load-resolve-pkg-import
    import-path
    "proj"
    (compiler-load-pkg-resolve-deps))
    [(ErrPkgResolve m) (string-eq m expected)]
    [(OkPkgResolve _) false]))

;: Aggregate pkg-import resolution self-test (#834).
(define (compiler-load-pkg-resolve-ok?) : bool
  (and
    (compiler-load-pkg-resolves? "pkg:math/src/add.tl" "math/src/add.tl")
    (and
      (compiler-load-pkg-resolves? "pkg:util/lib.tl" "proj/vendor/util/lib.tl")
      (and
        (compiler-load-pkg-resolve-rejects?
          "pkg:nope/x.tl"
          "compiler-load: unknown package alias 'nope': pkg:nope/x.tl")
        (and
          (compiler-load-pkg-resolve-rejects?
            "pkg:math"
            "compiler-load: pkg import missing '/' after alias: pkg:math")
          (and
            (compiler-load-pkg-resolve-rejects?
              "pkg:math/../../etc.tl"
              "compiler-load: pkg import escapes package root: pkg:math/../../etc.tl")
            (compiler-load-pkg-resolve-rejects?
              "pkg:remote/src/lib.tl"
              "compiler-load: GitHub dependency 'remote' requires fetch support (#1157): pkg:remote/src/lib.tl")))))))

;: True when `parent-dir dir` yields exactly `expected`.
(define (compiler-load-pkg-parent-dir-is? [dir : String] [expected : String]) : bool
  (match (compiler-load-parent-dir dir)
    [(CompilerLoadSomePath p) (string-eq p expected)]
    [(CompilerLoadNoPath) false]))

;: True when `parent-dir dir` reports no parent (top of the climb).
(define (compiler-load-pkg-parent-dir-none? [dir : String]) : bool
  (match (compiler-load-parent-dir dir)
    [(CompilerLoadNoPath) true]
    [(CompilerLoadSomePath _) false]))

;: The manifest-discovery walk-up steps one directory at a time, descending to
;: the cwd (``) before stopping (#834).
(define (compiler-load-pkg-parent-dir-ok?) : bool
  (and
    (compiler-load-pkg-parent-dir-is? "a/b/" "a/")
    (and
      (compiler-load-pkg-parent-dir-is? "a/b/c/" "a/b/")
      (and
        (compiler-load-pkg-parent-dir-is? "a/" "")
        (compiler-load-pkg-parent-dir-none? "")))))

;; relative-resolution variants (#1074): importer-relative join, parent-directory
;; (`..`) resolution end-to-end (join then normalize), and absolute-path
;; preservation (Unix-rooted and Windows-drive imports ignore the importer dir).
;; Pure path-string logic; complements `compiler-load-normalize-ok?` which covers
;; bare `.`/`..`/separator normalization without the importer-relative join.
(define (compiler-load-relative-resolution-ok?) : bool
  (and
    ;; importer-relative: import resolves against the importer's directory
    (string-eq
      (compiler-load-join-import-path "src/app/main.tl" "util.tl")
      "src/app/util.tl")
    (and
      ;; parent-directory (`..`) resolution end-to-end (join then normalize)
      (string-eq
        (compiler-load-normalize-path
          (compiler-load-join-import-path "src/app/main.tl" "../lib/helper.tl"))
        "src/lib/helper.tl")
      (and
        ;; absolute Unix-rooted import is preserved as-is (importer dir ignored)
        (string-eq
          (compiler-load-join-import-path "src/app/main.tl" "/opt/dep.tl")
          "/opt/dep.tl")
        ;; absolute Windows-drive import is preserved as-is
        (string-eq
          (compiler-load-join-import-path "src/app/main.tl" "C:/dep.tl")
          "C:/dep.tl")))))

(define (compiler-load-self-test) : i64
  (begin
    (unless
      (compiler-load-normalize-ok?)
      (return
        (begin
          (panic "compiler-load: normalize smoke mismatch")
          0)))
    (unless
      (compiler-load-relative-resolution-ok?)
      (return
        (begin
          (panic "compiler-load: relative resolution smoke mismatch")
          0)))
    (unless
      (compiler-load-source-provenance-ok?)
      (return
        (begin
          (panic "compiler-load: source provenance smoke mismatch")
          0)))
    (unless
      (compiler-load-expected-module-conflict-ok?)
      (return
        (begin
          (panic "compiler-load: expected module smoke mismatch")
          0)))
    (unless
      (compiler-load-duplicate-module-ok?)
      (return
        (begin
          (panic "compiler-load: duplicate module smoke mismatch")
          0)))
    (unless
      (compiler-load-seen-module-ok?)
      (return
        (begin
          (panic "compiler-load: seen module smoke mismatch")
          0)))
    (unless
      (compiler-load-cfg-import-ok?)
      (return
        (begin
          (panic "compiler-load: cfg import smoke mismatch")
          0)))
    (unless
      (compiler-load-file-import-dedup-cycle-ok?)
      (return
        (begin
          (panic "compiler-load: import dedup/cycle smoke mismatch")
          0)))
    (unless
      (compiler-load-file-fallback-path-dedup-ok?)
      (return
        (begin
          (panic "compiler-load: fallback path dedup smoke mismatch")
          0)))
    (unless
      (compiler-load-import-alias-preserved-ok?)
      (return
        (begin
          (panic "compiler-load: import alias preservation smoke mismatch")
          0)))
    (unless
      (compiler-load-diamond-import-ok?)
      (return
        (begin
          (panic "compiler-load: diamond import smoke mismatch")
          0)))
    (unless
      (compiler-load-transitive-import-ok?)
      (return
        (begin
          (panic "compiler-load: transitive import smoke mismatch")
          0)))
    (unless
      (compiler-load-missing-import-ok?)
      (return
        (begin
          (panic "compiler-load: missing import smoke mismatch")
          0)))
    (unless
      (compiler-load-include-str-relative-ok?)
      (return
        (begin
          (panic "compiler-load: include-str relative smoke mismatch")
          0)))
    (unless
      (compiler-load-include-str-stdlib-root-ok?)
      (return
        (begin
          (panic "compiler-load: include-str stdlib root smoke mismatch")
          0)))
    (unless
      (compiler-load-missing-include-str-ok?)
      (return
        (begin
          (panic "compiler-load: missing include-str smoke mismatch")
          0)))
    (unless
      (compiler-load-include-str-raw-text-ok?)
      (return
        (begin
          (panic "compiler-load: include-str raw text smoke mismatch")
          0)))
    (unless
      (compiler-load-embedded-stdlib-lookup-ok?)
      (return
        (begin
          (panic "compiler-load: embedded stdlib lookup smoke mismatch")
          0)))
    (unless
      (compiler-load-embedded-stdlib-missing-ok?)
      (return
        (begin
          (panic "compiler-load: embedded stdlib missing smoke mismatch")
          0)))
    (unless
      (compiler-load-embedded-stdlib-escape-rejected-ok?)
      (return
        (begin
          (panic "compiler-load: embedded stdlib escape smoke mismatch")
          0)))
    (unless
      (compiler-load-imported-parse-error-path-ok?)
      (return
        (begin
          (panic "compiler-load: imported parse error path smoke mismatch")
          0)))
    (unless
      (compiler-load-imported-duplicate-module-path-ok?)
      (return
        (begin
          (panic "compiler-load: imported duplicate module path smoke mismatch")
          0)))
    (unless
      (compiler-load-stdlib-root-fallback-ok?)
      (return
        (begin
          (panic "compiler-load: stdlib root fallback smoke mismatch")
          0)))
    (unless
      (compiler-load-stdlib-searched-root-ok?)
      (return
        (begin
          (panic "compiler-load: stdlib searched root smoke mismatch")
          0)))
    (unless
      (compiler-load-stdlib-unresolved-ok?)
      (return
        (begin
          (panic "compiler-load: stdlib unresolved smoke mismatch")
          0)))
    (unless
      (compiler-load-stdlib-root-escape-rejected-ok?)
      (return
        (begin
          (panic "compiler-load: stdlib root escape smoke mismatch")
          0)))
    (unless
      (compiler-load-pkg-manifest-ok?)
      (return
        (begin
          (panic "compiler-load: pkg manifest smoke mismatch")
          0)))
    (unless
      (compiler-load-pkg-resolve-ok?)
      (return
        (begin
          (panic "compiler-load: pkg resolve smoke mismatch")
          0)))
    (unless
      (compiler-load-pkg-parent-dir-ok?)
      (return
        (begin
          (panic "compiler-load: pkg parent-dir smoke mismatch")
          0)))
    42))