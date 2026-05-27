;; compiler_load.tl - Shared selfhost compiler source/import loader.
(import "compiler_parse_core.tl")

(import "compiler_diagnostic.tl")

(import "sym_i64_env.tl")

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

(defenum CompilerLoadSegmentList
  (CompilerLoadSegmentNil)
  (CompilerLoadSegmentCons String CompilerLoadSegmentList))

(defenum CompilerLoadMaybeModuleId
  (CompilerLoadNoModuleId)
  (CompilerLoadSomeModuleId String))

(defenum ResultCompilerLoadModuleId
  (OkCompilerLoadModuleId String)
  (ErrCompilerLoadModuleId CompilerDiagnostic))

(define (compiler-load-char-code-at [text : String] [idx : i64]) : i64
  (cast (string-ref text idx) : i64))

(define (compiler-load-path-separator? [c : char]) : bool
  (or (= c #/') (= c #\\')))

(define (compiler-load-absolute-path? [path : String]) : bool
  (let
    [n : i64 (string-length path)]
    (if (= n 0)
      false
      (let
        [first : char (string-ref path 0)]
        (if (compiler-load-path-separator? first)
          true
          (if (> n 1)
            (= (string-ref path 1) #:')
            false))))))

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

(define (compiler-load-rooted-path? [path : String]) : bool
  (if (= (string-length path) 0)
    false
    (compiler-load-path-separator? (string-ref path 0))))

(define (compiler-load-segment-list-render [segments : CompilerLoadSegmentList]) : String
  (match segments
    [(CompilerLoadSegmentNil) ""]
    [(CompilerLoadSegmentCons head rest)
      (let
        [prefix : String (compiler-load-segment-list-render rest)]
        (if (= (string-length prefix) 0)
          head
          (string-append prefix (string-append "/" head))))]))

(define (compiler-load-normalize-segment
  [segment : String]
  [segments : CompilerLoadSegmentList]
  [rooted : bool]) : CompilerLoadSegmentList
  (if (or (string-eq segment "") (string-eq segment "."))
    segments
    (if (string-eq segment "..")
      (match segments
        [(CompilerLoadSegmentNil)
          (if rooted
            CompilerLoadSegmentNil
            (CompilerLoadSegmentCons segment segments))]
        [(CompilerLoadSegmentCons top rest)
          (if (string-eq top "..")
            (CompilerLoadSegmentCons segment segments)
            rest)])
      (CompilerLoadSegmentCons segment segments))))

(define (compiler-load-normalize-path [path : String]) : String
  (let
    [n : i64 (string-length path)]
    [i : i64 0]
    [segment-start : i64 0]
    [rooted : bool (compiler-load-rooted-path? path)]
    [segments : CompilerLoadSegmentList CompilerLoadSegmentNil]
    (begin
      (while (< i n)
        (begin
          (if (compiler-load-path-separator? (string-ref path i))
            (begin
              (set!
                segments
                (compiler-load-normalize-segment
                  (substring path segment-start (- i segment-start))
                  segments
                  rooted))
              (set! segment-start (+ i 1)))
            (set! segment-start segment-start))
          (set! i (+ i 1))))
      (set!
        segments
        (compiler-load-normalize-segment
          (substring path segment-start (- n segment-start))
          segments
          rooted))
      (let
        [body : String (compiler-load-segment-list-render segments)]
        (if rooted
          (if (= (string-length body) 0)
            "/"
            (string-append "/" body))
          body)))))

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

(define (compiler-load-resolve-stdlib-root
  [suffix : String]
  [roots : CompilerLoadRootList]) : CompilerLoadMaybePath
  (match roots
    [(CompilerLoadRootNil) (CompilerLoadNoPath)]
    [(CompilerLoadRootCons root rest)
      (let
        [candidate : String (compiler-load-join-root-path root suffix)]
        (if (file-exists? candidate)
          (CompilerLoadSomePath candidate)
          (compiler-load-resolve-stdlib-root suffix rest)))]))

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
            (match (compiler-load-resolve-stdlib-root
              (compiler-load-stdlib-suffix import-path)
              stdlib-roots)
              [(CompilerLoadSomePath root-path) root-path]
              [(CompilerLoadNoPath)
                (if (file-exists? import-path)
                  import-path
                  primary)])
            primary))]
      (OkPkgResolve resolved))))

(define (compiler-load-decl-list-append
  [left : AstDeclList]
  [right : AstDeclList]) : AstDeclList
  (match left
    [(AstDeclNil) right]
    [(AstDeclCons head rest)
      (AstDeclCons head (compiler-load-decl-list-append rest right))]))

(define (compiler-load-decl-path-list-append
  [left : AstDeclPathList]
  [right : AstDeclPathList]) : AstDeclPathList
  (match left
    [(AstDeclPathNil) right]
    [(AstDeclPathCons head rest)
      (AstDeclPathCons head (compiler-load-decl-path-list-append rest right))]))

(define (compiler-load-decl-module-list-append
  [left : AstDeclModuleList]
  [right : AstDeclModuleList]) : AstDeclModuleList
  (match left
    [(AstDeclModuleNil) right]
    [(AstDeclModuleCons head rest)
      (AstDeclModuleCons
        head
        (compiler-load-decl-module-list-append rest right))]))

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
        [_ (compiler-load-decls-module-id-loop path rest fallback found)])]))

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

(define (compiler-load-decls-with-module-and-roots
  [decls : AstDeclList]
  [importer-path : String]
  [importer-module : String]
  [seen : SymI64Env]
  [stdlib-roots : CompilerLoadRootList]) : ResultCompilerLoadWithPaths
  (match decls
    [(AstDeclNil)
      (OkCompilerLoadWithPaths AstDeclNil AstDeclPathNil AstDeclModuleNil seen)]
    [(AstDeclCons decl rest)
      (match decl
        [(AstDeclImport (AstImportSpec import-path expected-module _))
          (match (compiler-load-resolve-import-result-with-roots
            importer-path
            import-path
            stdlib-roots)
            [(OkPkgResolve resolved)
              (match (compiler-load-file-with-paths-and-roots-expect
                resolved
                seen
                stdlib-roots
                expected-module)
                [(OkCompilerLoadWithPaths
                    imported-decls
                    imported-paths
                    imported-modules
                    import-seen)
                  (match (compiler-load-decls-with-module-and-roots
                    rest
                    importer-path
                    importer-module
                    import-seen
                    stdlib-roots)
                    [(OkCompilerLoadWithPaths
                        rest-decls
                        rest-paths
                        rest-modules
                        rest-seen)
                      (OkCompilerLoadWithPaths
                        (compiler-load-decl-list-append
                          imported-decls
                          rest-decls)
                        (compiler-load-decl-path-list-append
                          imported-paths
                          rest-paths)
                        (compiler-load-decl-module-list-append
                          imported-modules
                          rest-modules)
                        rest-seen)]
                    [(ErrCompilerLoadWithPaths diag)
                      (ErrCompilerLoadWithPaths diag)])]
                [(ErrCompilerLoadWithPaths diag)
                  (ErrCompilerLoadWithPaths diag)])]
            [(ErrPkgResolve message)
              (ErrCompilerLoadWithPaths
                (compiler-diagnostic-at-start importer-path message))])]
        [_
          (match (compiler-load-decls-with-module-and-roots
            rest
            importer-path
            importer-module
            seen
            stdlib-roots)
            [(OkCompilerLoadWithPaths
                rest-decls
                rest-paths
                rest-modules
                rest-seen)
              (OkCompilerLoadWithPaths
                (AstDeclCons decl rest-decls)
                (AstDeclPathCons importer-path rest-paths)
                (AstDeclModuleCons importer-module rest-modules)
                rest-seen)]
            [(ErrCompilerLoadWithPaths diag) (ErrCompilerLoadWithPaths diag)])])]))

(define (compiler-load-decls-with-paths-and-roots
  [decls : AstDeclList]
  [importer-path : String]
  [seen : SymI64Env]
  [stdlib-roots : CompilerLoadRootList]) : ResultCompilerLoadWithPaths
  (match (compiler-load-decls-module-id importer-path decls)
    [(OkCompilerLoadModuleId module-id)
      (if (sym-i64-contains seen module-id)
        (OkCompilerLoadWithPaths
          AstDeclNil
          AstDeclPathNil
          AstDeclModuleNil
          seen)
        (compiler-load-decls-with-module-and-roots
          decls
          importer-path
          module-id
          (sym-i64-bind seen module-id 1)
          stdlib-roots))]
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
  (match program
    [(AstProgram decls)
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
                (compiler-load-decls-with-module-and-roots
                  decls
                  path
                  module-id
                  (sym-i64-bind seen module-id 1)
                  stdlib-roots))]
            [(ErrCompilerLoadModuleId diag) (ErrCompilerLoadWithPaths diag)])]
        [(ErrCompilerLoadModuleId diag) (ErrCompilerLoadWithPaths diag)])]))

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

(define (compiler-load-source-with-paths-and-roots-expect
  [path : String]
  [source : String]
  [seen : SymI64Env]
  [stdlib-roots : CompilerLoadRootList]
  [expected-module : AstMaybeModuleName]) : ResultCompilerLoadWithPaths
  (match (parse-ast-source-diagnostic path source)
    [(OkAstProgramDiagnostic program)
      (compiler-load-program-with-paths-and-roots-expect
        path
        program
        seen
        stdlib-roots
        expected-module)]
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

(define (compiler-load-file-with-paths-and-roots-expect
  [path : String]
  [seen : SymI64Env]
  [stdlib-roots : CompilerLoadRootList]
  [expected-module : AstMaybeModuleName]) : ResultCompilerLoadWithPaths
  (if (file-exists? path)
    (match (parse-ast-source-diagnostic path (read-file path))
      [(OkAstProgramDiagnostic program)
        (compiler-load-program-with-paths-and-roots-expect
          path
          program
          seen
          stdlib-roots
          expected-module)]
      [(ErrAstProgramDiagnostic diag) (ErrCompilerLoadWithPaths diag)])
    (ErrCompilerLoadWithPaths
      (compiler-diagnostic-at-start
        path
        (string-append "compiler-load: cannot read import " path)))))

(define (compiler-load-file [path : String] [seen : SymI64Env]) : ResultCompilerLoad
  (compiler-load-drop-paths (compiler-load-file-with-paths path seen)))

(define (compiler-load-file-with-roots
  [path : String]
  [seen : SymI64Env]
  [stdlib-roots : CompilerLoadRootList]) : ResultCompilerLoad
  (compiler-load-drop-paths
    (compiler-load-file-with-paths-and-roots path seen stdlib-roots)))

(define (compiler-load-decl-list-count [decls : AstDeclList]) : i64
  (match decls
    [(AstDeclNil) 0]
    [(AstDeclCons _ rest) (+ 1 (compiler-load-decl-list-count rest))]))

(define (compiler-load-two-modules?
  [modules : AstDeclModuleList]
  [want : String]) : bool
  (match modules
    [(AstDeclModuleCons first (AstDeclModuleCons second AstDeclModuleNil))
      (and (string-eq first want) (string-eq second want))]
    [_ false]))

(define (compiler-load-entry-cycle-modules? [modules : AstDeclModuleList]) : bool
  (match modules
    [(AstDeclModuleCons
        first
        (AstDeclModuleCons
          second
          (AstDeclModuleCons third (AstDeclModuleCons fourth AstDeclModuleNil))))
      (and
        (string-eq first "smoke.entry")
        (and
          (string-eq second "smoke.dep")
          (and (string-eq third "smoke.dep") (string-eq fourth "smoke.entry"))))]
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
          (= (compiler-load-decl-list-count decls) 4)
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
              [(AstDeclModuleCons
                  first
                  (AstDeclModuleCons second AstDeclModuleNil))
                (and
                  (string-eq first "target/compiler_load_legacy_dep.tl")
                  (string-eq second "target/compiler_load_legacy_entry.tl"))]
              [_ false])
            (sym-i64-contains seen "target/compiler_load_legacy_dep.tl")))]
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
          (= (compiler-load-decl-list-count decls) 8)
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
          (= (compiler-load-decl-list-count decls) 8)
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

;;; --- typelisp.pkg manifest parser (#834, slice 1) ---------------------------
;;; Parse a `typelisp.pkg` manifest, an S-expression of the form
;;;   (package (name "...") (version "...") (entry "...")
;;;            (dependencies (alias "path") ...))
;;; into a structured value, mirroring `src/package.rs::parse_manifest`'s field
;;; set and diagnostics. Reuses the selfhost reader (`lex` + `read-result`, both
;;; already reachable here via compiler_parse_core -> read.tl) instead of a
;;; bespoke manifest tokenizer. `pkg:<alias>/...` resolution + loader
;;; integration are slice 2; this slice is the parser + diagnostics.
;;; A parsed dependency: an import alias and its package-root path.
(defstruct CompilerPkgDep
  (alias String)
  (path String))

;;; Alias->path dependency list from a parsed manifest.
(defenum CompilerPkgDepList
  (CompilerPkgDepNil)
  (CompilerPkgDepCons CompilerPkgDep CompilerPkgDepList))

;;; A parsed `typelisp.pkg` manifest.
(defstruct CompilerPkgManifest
  (name String)
  (version String)
  (entry String)
  (deps CompilerPkgDepList))

;;; Parse result: the manifest or a diagnostic.
(defenum ResultCompilerPkgManifest
  (OkCompilerPkgManifest CompilerPkgManifest)
  (ErrCompilerPkgManifest String))

;;; Internal: a single extracted string field value, or a diagnostic.
(defenum ResultPkgString
  (OkPkgString String)
  (ErrPkgString String))

;;; Internal: a parsed dependency list, or a diagnostic.
(defenum ResultCompilerPkgDepList
  (OkCompilerPkgDepList CompilerPkgDepList)
  (ErrCompilerPkgDepList String))

;;; Count the dependencies in a parsed list.
(define (compiler-pkg-dep-list-count [deps : CompilerPkgDepList]) : i64
  (match deps
    [(CompilerPkgDepNil) 0]
    [(CompilerPkgDepCons _ rest) (+ 1 (compiler-pkg-dep-list-count rest))]))

;;; Extract a single `"value"` from a field tail `("value")`.
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

;;; Parse the `(alias "path") ...` entries of a `(dependencies ...)` field.
(define (compiler-load-manifest-parse-deps [entries : Sexpr]) : ResultCompilerPkgDepList
  (match entries
    [(SNil) (OkCompilerPkgDepList (CompilerPkgDepNil))]
    [(SCons entry rest)
      (match entry
        [(SCons ehead etail)
          (match ehead
            [(SSym alias)
              (match (compiler-load-manifest-string-value etail alias)
                [(ErrPkgString m) (ErrCompilerPkgDepList m)]
                [(OkPkgString path)
                  (match (compiler-load-manifest-parse-deps rest)
                    [(ErrCompilerPkgDepList m) (ErrCompilerPkgDepList m)]
                    [(OkCompilerPkgDepList tail-deps)
                      (OkCompilerPkgDepList
                        (CompilerPkgDepCons
                          (CompilerPkgDep alias path)
                          tail-deps))])])]
            [_
              (ErrCompilerPkgDepList
                "dependency entries must start with an alias name")])]
        [_
          (ErrCompilerPkgDepList
            "dependency entries must be lists like `(alias \"path\")`")])]
    [_
      (ErrCompilerPkgDepList
        "`dependencies` must be a list of `(alias \"path\")` entries")]))

;;; Walk the package fields, accumulating name/version/entry/deps, then check
;;; the three required string fields are present.
(define (compiler-load-manifest-fields
  [fields : Sexpr]
  [name : String]
  [version : String]
  [entry : String]
  [deps : CompilerPkgDepList]) : ResultCompilerPkgManifest
  (match fields
    [(SNil)
      (if (string-eq name "")
        (ErrCompilerPkgManifest "manifest missing required field `name`")
        (if (string-eq version "")
          (ErrCompilerPkgManifest "manifest missing required field `version`")
          (if (string-eq entry "")
            (ErrCompilerPkgManifest "manifest missing required field `entry`")
            (OkCompilerPkgManifest
              (CompilerPkgManifest name version entry deps)))))]
    [(SCons field rest)
      (match field
        [(SCons fhead ftail)
          (match fhead
            [(SSym fname)
              (if (string-eq fname "dependencies")
                (match (compiler-load-manifest-parse-deps ftail)
                  [(ErrCompilerPkgDepList m) (ErrCompilerPkgManifest m)]
                  [(OkCompilerPkgDepList parsed-deps)
                    (compiler-load-manifest-fields
                      rest
                      name
                      version
                      entry
                      parsed-deps)])
                (if (string-eq fname "name")
                  (match (compiler-load-manifest-string-value ftail fname)
                    [(ErrPkgString m) (ErrCompilerPkgManifest m)]
                    [(OkPkgString val)
                      (compiler-load-manifest-fields
                        rest
                        val
                        version
                        entry
                        deps)])
                  (if (string-eq fname "version")
                    (match (compiler-load-manifest-string-value ftail fname)
                      [(ErrPkgString m) (ErrCompilerPkgManifest m)]
                      [(OkPkgString val)
                        (compiler-load-manifest-fields rest name val entry deps)])
                    (if (string-eq fname "entry")
                      (match (compiler-load-manifest-string-value ftail fname)
                        [(ErrPkgString m) (ErrCompilerPkgManifest m)]
                        [(OkPkgString val)
                          (compiler-load-manifest-fields
                            rest
                            name
                            version
                            val
                            deps)])
                      (ErrCompilerPkgManifest
                        (string-append
                          "unknown manifest field `"
                          (string-append fname "`")))))))]
            [_
              (ErrCompilerPkgManifest
                "package fields must start with a field name")])]
        [_
          (ErrCompilerPkgManifest
            "package fields must be lists like `(name \"...\")`")])]
    [_
      (ErrCompilerPkgManifest
        "package fields must be lists like `(name \"...\")`")]))

;;; Parse the top-level `(package ...)` form.
(define (compiler-load-manifest-from-form [form : Sexpr]) : ResultCompilerPkgManifest
  (match form
    [(SCons head rest)
      (match head
        [(SSym s)
          (if (string-eq s "package")
            (compiler-load-manifest-fields rest "" "" "" (CompilerPkgDepNil))
            (ErrCompilerPkgManifest
              (string-append
                "expected `package` form, got `"
                (string-append s "`"))))]
        [_ (ErrCompilerPkgManifest "manifest must start with `package`")])]
    [_ (ErrCompilerPkgManifest "manifest must be a `(package ...)` form")]))

;;; Parse a `typelisp.pkg` manifest source string into a structured manifest.
(define (compiler-load-parse-manifest [source : String]) : ResultCompilerPkgManifest
  (match (read-result (lex source))
    [(ErrSexpr msg) (ErrCompilerPkgManifest (string-append "manifest: " msg))]
    [(OkSexpr form) (compiler-load-manifest-from-form form)]))

;;; Self-test: a full manifest parses with the expected fields + dependency
;;; count.
(define (compiler-load-manifest-valid-full-ok?) : bool
  (match (compiler-load-parse-manifest
    "(package (name \"demo\") (version \"0.1.0\") (entry \"src/main.tl\") (dependencies (math \"../math\") (util \"../util\")))")
    [(OkCompilerPkgManifest m)
      (and
        (string-eq (struct-get m name) "demo")
        (and
          (string-eq (struct-get m version) "0.1.0")
          (and
            (string-eq (struct-get m entry) "src/main.tl")
            (= (compiler-pkg-dep-list-count (struct-get m deps)) 2))))]
    [(ErrCompilerPkgManifest _) false]))

;;; Self-test: a manifest without a `dependencies` field parses with no deps.
(define (compiler-load-manifest-valid-nodeps-ok?) : bool
  (match (compiler-load-parse-manifest
    "(package (name \"x\") (version \"1\") (entry \"e.tl\"))")
    [(OkCompilerPkgManifest m)
      (= (compiler-pkg-dep-list-count (struct-get m deps)) 0)]
    [(ErrCompilerPkgManifest _) false]))

;;; True when parsing `source` fails with exactly the `expected` diagnostic.
(define (compiler-load-manifest-rejects? [source : String] [expected : String]) : bool
  (match (compiler-load-parse-manifest source)
    [(ErrCompilerPkgManifest m) (string-eq m expected)]
    [(OkCompilerPkgManifest _) false]))

;;; Aggregate manifest-parser self-test (#834).
(define (compiler-load-pkg-manifest-ok?) : bool
  (and
    (compiler-load-manifest-valid-full-ok?)
    (and
      (compiler-load-manifest-valid-nodeps-ok?)
      (and
        (compiler-load-manifest-rejects?
          "(package (version \"1\") (entry \"e.tl\"))"
          "manifest missing required field `name`")
        (and
          (compiler-load-manifest-rejects?
            "(package (name \"x\") (entry \"e.tl\"))"
            "manifest missing required field `version`")
          (and
            (compiler-load-manifest-rejects?
              "(package (name \"x\") (version \"1\"))"
              "manifest missing required field `entry`")
            (compiler-load-manifest-rejects?
              "(module foo)"
              "expected `package` form, got `module`")))))))

;;; --- pkg:<alias>/... import resolution (#834, slice 2) ----------------------
;;; Resolve a `pkg:<alias>/<rest>` import against a parsed manifest's dependency
;;; list, relative to the manifest directory: `<manifest-dir>/<dep-path>/<rest>`,
;;; normalized. Rejects a missing alias, an empty/`/`-less spec, and a `rest`
;;; that escapes the dependency root via `..`, preserving those diagnostics when
;;; the import resolver runs inside the selfhost driver.
;;; True when an import path is a package import (`pkg:<alias>/...`).
(define (compiler-load-pkg-import? [path : String]) : bool
  (compiler-load-string-prefix-at? path "pkg:" 0))

;;; Index of the first '/' in `s` at or after `i`, or -1 if none.
(define (compiler-load-slash-index-from [s : String] [i : i64] [n : i64]) : i64
  (if (>= i n)
    -1
    (if (= (string-ref s i) #/')
      i
      (compiler-load-slash-index-from s (+ i 1) n))))

;;; True when a (normalized) relative path escapes its base via a leading `..`.
(define (compiler-load-path-escapes? [path : String]) : bool
  (if (compiler-load-string-prefix-at? path ".." 0)
    (if (= (string-length path) 2)
      true
      (= (string-ref path 2) #/'))
    false))

;;; Look up a dependency's root path by import alias.
(define (compiler-load-pkg-dep-lookup
  [deps : CompilerPkgDepList]
  [target-alias : String]) : CompilerLoadMaybePath
  (match deps
    [(CompilerPkgDepNil) (CompilerLoadNoPath)]
    [(CompilerPkgDepCons dep rest)
      (if (string-eq (struct-get dep alias) target-alias)
        (CompilerLoadSomePath (struct-get dep path))
        (compiler-load-pkg-dep-lookup rest target-alias))]))

;;; Resolve `pkg:<alias>/<rest>` against `deps`, relative to `manifest-dir`.
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
                        norm-rest)))))]))))))

;;; Parent directory of a directory path, or no-path at the top. `dirname`
;;; returns a path *including* its trailing separator, so a trailing separator
;;; is stripped first to make the walk-up progress (e.g. `src/` -> ``, the cwd).
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
        (let
          [parent : String (compiler-load-dirname trimmed)]
          (if (string-eq parent dir)
            (CompilerLoadNoPath)
            (CompilerLoadSomePath parent)))))))

;;; Walk up from `dir` looking for a `typelisp.pkg` manifest, mirroring the Rust
;;; `discover_manifest` (src/package.rs). `fuel` bounds the climb.
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

;;; Discover the nearest `typelisp.pkg` at or above the importer's directory.
(define (compiler-load-discover-manifest [start-path : String]) : CompilerLoadMaybePath
  (compiler-load-discover-manifest-up (compiler-load-dirname start-path) 256))

;;; Resolve a `pkg:<alias>/...` import by discovering and parsing the nearest
;;; `typelisp.pkg` relative to the importer, then resolving against its deps.
;;; Missing manifests and parse errors fall back to the raw import path so the
;;; loader reports a normal "cannot read import" error. Syntactically valid
;;; manifests preserve pkg-resolution diagnostics into the caller.
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

;;; Self-test fixture: `math` -> sibling dir, `util` -> vendored subdir.
(define (compiler-load-pkg-resolve-deps) : CompilerPkgDepList
  (CompilerPkgDepCons
    (CompilerPkgDep "math" "../math")
    (CompilerPkgDepCons
      (CompilerPkgDep "util" "vendor/util")
      (CompilerPkgDepNil))))

;;; True when resolving `import-path` yields exactly `expected`.
(define (compiler-load-pkg-resolves? [import-path : String] [expected : String]) : bool
  (match (compiler-load-resolve-pkg-import
    import-path
    "proj"
    (compiler-load-pkg-resolve-deps))
    [(OkPkgResolve p) (string-eq p expected)]
    [(ErrPkgResolve _) false]))

;;; True when resolving `import-path` fails with exactly `expected`.
(define (compiler-load-pkg-resolve-rejects?
  [import-path : String]
  [expected : String]) : bool
  (match (compiler-load-resolve-pkg-import
    import-path
    "proj"
    (compiler-load-pkg-resolve-deps))
    [(ErrPkgResolve m) (string-eq m expected)]
    [(OkPkgResolve _) false]))

;;; Aggregate pkg-import resolution self-test (#834).
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
          (compiler-load-pkg-resolve-rejects?
            "pkg:math/../../etc.tl"
            "compiler-load: pkg import escapes package root: pkg:math/../../etc.tl"))))))

;;; True when `parent-dir dir` yields exactly `expected`.
(define (compiler-load-pkg-parent-dir-is? [dir : String] [expected : String]) : bool
  (match (compiler-load-parent-dir dir)
    [(CompilerLoadSomePath p) (string-eq p expected)]
    [(CompilerLoadNoPath) false]))

;;; True when `parent-dir dir` reports no parent (top of the climb).
(define (compiler-load-pkg-parent-dir-none? [dir : String]) : bool
  (match (compiler-load-parent-dir dir)
    [(CompilerLoadNoPath) true]
    [(CompilerLoadSomePath _) false]))

;;; The manifest-discovery walk-up steps one directory at a time, descending to
;;; the cwd (``) before stopping (#834).
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
  (if (compiler-load-normalize-ok?)
    (if (compiler-load-relative-resolution-ok?)
      (if (compiler-load-source-provenance-ok?)
        (if (compiler-load-expected-module-conflict-ok?)
          (if (compiler-load-duplicate-module-ok?)
            (if (compiler-load-seen-module-ok?)
              (if (compiler-load-file-import-dedup-cycle-ok?)
                (if (compiler-load-file-fallback-path-dedup-ok?)
                  (if (compiler-load-diamond-import-ok?)
                    (if (compiler-load-transitive-import-ok?)
                      (if (compiler-load-missing-import-ok?)
                        (if (compiler-load-imported-parse-error-path-ok?)
                          (if (compiler-load-imported-duplicate-module-path-ok?)
                            (if (compiler-load-stdlib-root-fallback-ok?)
                              (if (compiler-load-stdlib-searched-root-ok?)
                                (if (compiler-load-stdlib-unresolved-ok?)
                                  (if (compiler-load-pkg-manifest-ok?)
                                    (if (compiler-load-pkg-resolve-ok?)
                                      (if (compiler-load-pkg-parent-dir-ok?)
                                        42
                                        (begin
                                          (panic
                                            "compiler-load: pkg parent-dir smoke mismatch")
                                          0))
                                      (begin
                                        (panic
                                          "compiler-load: pkg resolve smoke mismatch")
                                        0))
                                    (begin
                                      (panic
                                        "compiler-load: pkg manifest smoke mismatch")
                                      0))
                                  (begin
                                    (panic
                                      "compiler-load: stdlib unresolved smoke mismatch")
                                    0))
                                (begin
                                  (panic
                                    "compiler-load: stdlib searched root smoke mismatch")
                                  0))
                              (begin
                                (panic
                                  "compiler-load: stdlib root fallback smoke mismatch")
                                0))
                            (begin
                              (panic
                                "compiler-load: imported duplicate module path smoke mismatch")
                              0))
                          (begin
                            (panic
                              "compiler-load: imported parse error path smoke mismatch")
                            0))
                        (begin
                          (panic "compiler-load: missing import smoke mismatch")
                          0))
                      (begin
                        (panic
                          "compiler-load: transitive import smoke mismatch")
                        0))
                    (begin
                      (panic "compiler-load: diamond import smoke mismatch")
                      0))
                  (begin
                    (panic "compiler-load: fallback path dedup smoke mismatch")
                    0))
                (begin
                  (panic "compiler-load: import dedup/cycle smoke mismatch")
                  0))
              (begin
                (panic "compiler-load: seen module smoke mismatch")
                0))
            (begin
              (panic "compiler-load: duplicate module smoke mismatch")
              0))
          (begin
            (panic "compiler-load: expected module smoke mismatch")
            0))
        (begin
          (panic "compiler-load: source provenance smoke mismatch")
          0))
      (begin
        (panic "compiler-load: relative resolution smoke mismatch")
        0))
    (begin
      (panic "compiler-load: normalize smoke mismatch")
      0)))