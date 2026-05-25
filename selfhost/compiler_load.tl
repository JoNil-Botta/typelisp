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
  (let
    [primary : String
      (compiler-load-join-import-path importer-path import-path)]
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
        primary))))

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
          (let
            [resolved : String
              (compiler-load-resolve-import-with-roots
                importer-path
                import-path
                stdlib-roots)]
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
                      (compiler-load-decl-list-append imported-decls rest-decls)
                      (compiler-load-decl-path-list-append
                        imported-paths
                        rest-paths)
                      (compiler-load-decl-module-list-append
                        imported-modules
                        rest-modules)
                      rest-seen)]
                  [(ErrCompilerLoadWithPaths diag)
                    (ErrCompilerLoadWithPaths diag)])]
              [(ErrCompilerLoadWithPaths diag) (ErrCompilerLoadWithPaths diag)]))]
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

(define (compiler-load-self-test) : i64
  (if (compiler-load-normalize-ok?)
    (if (compiler-load-source-provenance-ok?)
      (if (compiler-load-expected-module-conflict-ok?)
        (if (compiler-load-duplicate-module-ok?)
          (if (compiler-load-seen-module-ok?)
            (if (compiler-load-file-import-dedup-cycle-ok?)
              (if (compiler-load-file-fallback-path-dedup-ok?)
                (if (compiler-load-diamond-import-ok?)
                  42
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
      (panic "compiler-load: normalize smoke mismatch")
      0)))