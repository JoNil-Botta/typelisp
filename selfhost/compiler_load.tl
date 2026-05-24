;; compiler_load.tl - Shared selfhost compiler source/import loader.

(import "compiler_parse_core.tl")

(import "compiler_diagnostic.tl")

(import "sym_i64_env.tl")

(defenum ResultCompilerLoad
  (OkCompilerLoad AstDeclList SymI64Env)
  (ErrCompilerLoad CompilerDiagnostic))

(defenum ResultCompilerLoadWithPaths
  (OkCompilerLoadWithPaths AstDeclList AstDeclPathList SymI64Env)
  (ErrCompilerLoadWithPaths CompilerDiagnostic))

(defenum CompilerLoadRootList
  (CompilerLoadRootNil)
  (CompilerLoadRootCons String CompilerLoadRootList))

(defenum CompilerLoadMaybePath
  (CompilerLoadNoPath)
  (CompilerLoadSomePath String))

(define (compiler-load-char-code-at [text : String] [idx : i64]) : i64
  (cast (string-ref text idx) : i64))

(define (compiler-load-path-separator? [c : char]) : bool
  (or (= c #/') (= c #\\')))

(define (compiler-load-absolute-path? [path : String]) : bool
  (let ([n : i64 (string-length path)])
    (if (= n 0)
      false
      (let ([first : char (string-ref path 0)])
        (if (compiler-load-path-separator? first)
          true
          (if (> n 1)
            (= (string-ref path 1) #:')
            false))))))

(define (compiler-load-dirname [path : String]) : String
  (let (
    [n : i64 (string-length path)]
    [i : i64 0]
    [last : i64 -1])
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

(define (compiler-load-string-prefix-at?
  [text : String]
  [prefix : String]
  [start : i64]) : bool
  (let (
    [text-len : i64 (string-length text)]
    [prefix-len : i64 (string-length prefix)])
    (if (< start 0)
      false
      (if (> (+ start prefix-len) text-len)
        false
        (let (
          [i : i64 0]
          [ok : bool true])
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
  (let ([n : i64 (string-length root)])
    (if (= n 0)
      suffix
      (let ([last : char (string-ref root (- n 1))])
        (if (compiler-load-path-separator? last)
          (string-append root suffix)
          (string-append root (string-append "/" suffix)))))))

(define (compiler-load-resolve-stdlib-root
  [suffix : String]
  [roots : CompilerLoadRootList]) : CompilerLoadMaybePath
  (match roots
    [(CompilerLoadRootNil) (CompilerLoadNoPath)]
    [(CompilerLoadRootCons root rest)
      (let ([candidate : String (compiler-load-join-root-path root suffix)])
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
  (let ([primary : String
    (compiler-load-join-import-path importer-path import-path)])
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

(define (compiler-load-drop-paths [result : ResultCompilerLoadWithPaths]) : ResultCompilerLoad
  (match result
    [(OkCompilerLoadWithPaths decls _ seen) (OkCompilerLoad decls seen)]
    [(ErrCompilerLoadWithPaths diag) (ErrCompilerLoad diag)]))

(define (compiler-load-decls-with-paths
  [decls : AstDeclList]
  [importer-path : String]
  [seen : SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-decls-with-paths-and-roots
    decls
    importer-path
    seen
    CompilerLoadRootNil))

(define (compiler-load-decls-with-paths-and-roots
  [decls : AstDeclList]
  [importer-path : String]
  [seen : SymI64Env]
  [stdlib-roots : CompilerLoadRootList]) : ResultCompilerLoadWithPaths
  (match decls
    [(AstDeclNil) (OkCompilerLoadWithPaths AstDeclNil AstDeclPathNil seen)]
    [(AstDeclCons decl rest)
      (match decl
        [(AstDeclImport import-path)
          (let ([resolved : String
            (compiler-load-resolve-import-with-roots
              importer-path
              import-path
              stdlib-roots)])
            (match (compiler-load-file-with-paths-and-roots
              resolved
              seen
              stdlib-roots)
              [(OkCompilerLoadWithPaths
                  imported-decls
                  imported-paths
                  import-seen)
                (match (compiler-load-decls-with-paths-and-roots
                  rest
                  importer-path
                  import-seen
                  stdlib-roots)
                  [(OkCompilerLoadWithPaths rest-decls rest-paths rest-seen)
                    (OkCompilerLoadWithPaths
                      (compiler-load-decl-list-append imported-decls rest-decls)
                      (compiler-load-decl-path-list-append
                        imported-paths
                        rest-paths)
                      rest-seen)]
                  [(ErrCompilerLoadWithPaths diag)
                    (ErrCompilerLoadWithPaths diag)])]
              [(ErrCompilerLoadWithPaths diag) (ErrCompilerLoadWithPaths diag)]))]
        [_
          (match (compiler-load-decls-with-paths-and-roots
            rest
            importer-path
            seen
            stdlib-roots)
            [(OkCompilerLoadWithPaths rest-decls rest-paths rest-seen)
              (OkCompilerLoadWithPaths
                (AstDeclCons decl rest-decls)
                (AstDeclPathCons importer-path rest-paths)
                rest-seen)]
            [(ErrCompilerLoadWithPaths diag) (ErrCompilerLoadWithPaths diag)])])]))

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
  (if (sym-i64-contains seen path)
    (OkCompilerLoadWithPaths AstDeclNil AstDeclPathNil seen)
    (match program
      [(AstProgram decls)
        (compiler-load-decls-with-paths-and-roots
          decls
          path
          (sym-i64-bind seen path 1)
          stdlib-roots)])))

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
  (if (sym-i64-contains seen path)
    (OkCompilerLoadWithPaths AstDeclNil AstDeclPathNil seen)
    (match (parse-ast-source-diagnostic path source)
      [(OkAstProgramDiagnostic program)
        (compiler-load-program-with-paths-and-roots
          path
          program
          seen
          stdlib-roots)]
      [(ErrAstProgramDiagnostic diag) (ErrCompilerLoadWithPaths diag)])))

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
  (if (sym-i64-contains seen path)
    (OkCompilerLoadWithPaths AstDeclNil AstDeclPathNil seen)
    (if (file-exists? path)
      (match (parse-ast-source-diagnostic path (read-file path))
        [(OkAstProgramDiagnostic program)
          (compiler-load-program-with-paths-and-roots
            path
            program
            seen
            stdlib-roots)]
        [(ErrAstProgramDiagnostic diag) (ErrCompilerLoadWithPaths diag)])
      (ErrCompilerLoadWithPaths
        (compiler-diagnostic-at-start
          path
          (string-append "compiler-load: cannot read import " path))))))

(define (compiler-load-file [path : String] [seen : SymI64Env]) : ResultCompilerLoad
  (compiler-load-drop-paths (compiler-load-file-with-paths path seen)))

(define (compiler-load-file-with-roots
  [path : String]
  [seen : SymI64Env]
  [stdlib-roots : CompilerLoadRootList]) : ResultCompilerLoad
  (compiler-load-drop-paths
    (compiler-load-file-with-paths-and-roots path seen stdlib-roots)))