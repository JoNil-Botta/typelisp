;; compiler_load.tl - Shared selfhost compiler source/import loader.

(import "compiler_parse_core.tl")

(import "compiler_diagnostic.tl")

(import "sym_i64_env.tl")

(defenum ResultCompilerLoad
  (OkCompilerLoad AstDeclList SymI64Env)
  (ErrCompilerLoad String))

(defenum ResultCompilerLoadDiagnostic
  (OkCompilerLoadDiagnostic AstDeclList SymI64Env)
  (ErrCompilerLoadDiagnostic CompilerDiagnostic))

(defenum ResultCompilerLoadParse
  (OkCompilerLoadParse AstProgram)
  (ErrCompilerLoadParse CompilerDiagnostic))

(defenum ResultCompilerLoadDeclListDiagnostic
  (OkCompilerLoadDeclListDiagnostic AstDeclList)
  (ErrCompilerLoadDeclListDiagnostic CompilerDiagnostic))

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
  (let ([n : i64 (string-length path)] [i : i64 0] [last : i64 -1])
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
  (let ([text-len : i64 (string-length text)]
    [prefix-len : i64 (string-length prefix)])
    (if (< start 0)
      false
      (if (> (+ start prefix-len) text-len)
        false
        (let ([i : i64 0] [ok : bool true])
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

(define (compiler-load-resolve-import
  [importer-path : String]
  [import-path : String]) : String
  (let ([primary
      :
      String
      (compiler-load-join-import-path importer-path import-path)])
    (if (file-exists? primary)
      primary
      (if (and
        (compiler-load-stdlib-import? import-path)
        (file-exists? import-path))
        import-path
        primary))))

(define (compiler-load-decl-list-append
  [left : AstDeclList]
  [right : AstDeclList]) : AstDeclList
  (match left
    [(AstDeclNil) right]
    [(AstDeclCons head rest)
      (AstDeclCons head (compiler-load-decl-list-append rest right))]))

(define (compiler-load-decls
  [decls : AstDeclList]
  [importer-path : String]
  [seen : SymI64Env]) : ResultCompilerLoad
  (match decls
    [(AstDeclNil) (OkCompilerLoad AstDeclNil seen)]
    [(AstDeclCons decl rest)
      (match decl
        [(AstDeclImport import-path)
          (let ([resolved
              :
              String
              (compiler-load-resolve-import importer-path import-path)])
            (match (compiler-load-file resolved seen)
              [(OkCompilerLoad imported-decls import-seen)
                (match (compiler-load-decls rest importer-path import-seen)
                  [(OkCompilerLoad rest-decls rest-seen)
                    (OkCompilerLoad
                      (compiler-load-decl-list-append imported-decls rest-decls)
                      rest-seen)]
                  [(ErrCompilerLoad message) (ErrCompilerLoad message)])]
              [(ErrCompilerLoad message) (ErrCompilerLoad message)]))]
        [_
          (match (compiler-load-decls rest importer-path seen)
            [(OkCompilerLoad rest-decls rest-seen)
              (OkCompilerLoad (AstDeclCons decl rest-decls) rest-seen)]
            [(ErrCompilerLoad message) (ErrCompilerLoad message)])])]))

(define (compiler-load-parse-program-forms-diagnostic
  [path : String]
  [dispatch : SymI64Env]
  [toks : (Array SpannedToken)]
  [cur : (Array i64)]) : ResultCompilerLoadDeclListDiagnostic
  (if (= (peek-spanned-tag toks cur) (tag-end))
    (OkCompilerLoadDeclListDiagnostic AstDeclNil)
    (match (read-form-spanned-result toks cur)
      [(OkSpannedSexpr form)
        (match (parse-ast-decl dispatch form)
          [(OkAstDecl decl)
            (match (compiler-load-parse-program-forms-diagnostic
              path
              dispatch
              toks
              cur)
              [(OkCompilerLoadDeclListDiagnostic rest)
                (OkCompilerLoadDeclListDiagnostic (AstDeclCons decl rest))]
              [(ErrCompilerLoadDeclListDiagnostic diag)
                (ErrCompilerLoadDeclListDiagnostic diag)])]
          [(ErrAstDecl message)
            (ErrCompilerLoadDeclListDiagnostic
              (compiler-diagnostic-at-span
                path
                (spanned-sexpr-span form)
                message))])]
      [(ErrSpannedSexpr err)
        (ErrCompilerLoadDeclListDiagnostic
          (compiler-diagnostic-from-source-error path err))])))

(define (compiler-load-parse-program-diagnostic
  [path : String]
  [toks : (Array SpannedToken)]) : ResultCompilerLoadParse
  (let ([cur : (Array i64) (make-array i64 1)])
    (let ([dispatch : SymI64Env (compiler-parse-dispatch-env)])
      (begin
        (array-set! cur 0 0)
        (match (compiler-load-parse-program-forms-diagnostic
          path
          dispatch
          toks
          cur)
          [(OkCompilerLoadDeclListDiagnostic decls)
            (OkCompilerLoadParse (AstProgram decls))]
          [(ErrCompilerLoadDeclListDiagnostic diag) (ErrCompilerLoadParse diag)])))))

(define (compiler-load-parse-source-diagnostic [path : String] [src : String]) : ResultCompilerLoadParse
  (match (lex-spanned-result src)
    [(OkSpannedTokens toks) (compiler-load-parse-program-diagnostic path toks)]
    [(ErrSpannedTokens err)
      (ErrCompilerLoadParse (compiler-diagnostic-from-source-error path err))]))

(define (compiler-load-decls-diagnostic
  [decls : AstDeclList]
  [importer-path : String]
  [seen : SymI64Env]) : ResultCompilerLoadDiagnostic
  (match decls
    [(AstDeclNil) (OkCompilerLoadDiagnostic AstDeclNil seen)]
    [(AstDeclCons decl rest)
      (match decl
        [(AstDeclImport import-path)
          (let ([resolved
              :
              String
              (compiler-load-resolve-import importer-path import-path)])
            (match (compiler-load-file-diagnostic resolved seen)
              [(OkCompilerLoadDiagnostic imported-decls import-seen)
                (match (compiler-load-decls-diagnostic
                  rest
                  importer-path
                  import-seen)
                  [(OkCompilerLoadDiagnostic rest-decls rest-seen)
                    (OkCompilerLoadDiagnostic
                      (compiler-load-decl-list-append imported-decls rest-decls)
                      rest-seen)]
                  [(ErrCompilerLoadDiagnostic diag)
                    (ErrCompilerLoadDiagnostic diag)])]
              [(ErrCompilerLoadDiagnostic diag)
                (ErrCompilerLoadDiagnostic diag)]))]
        [_
          (match (compiler-load-decls-diagnostic rest importer-path seen)
            [(OkCompilerLoadDiagnostic rest-decls rest-seen)
              (OkCompilerLoadDiagnostic (AstDeclCons decl rest-decls) rest-seen)]
            [(ErrCompilerLoadDiagnostic diag) (ErrCompilerLoadDiagnostic diag)])])]))

(define (compiler-load-file-diagnostic [path : String] [seen : SymI64Env]) : ResultCompilerLoadDiagnostic
  (if (sym-i64-contains seen path)
    (OkCompilerLoadDiagnostic AstDeclNil seen)
    (if (file-exists? path)
      (match (compiler-load-parse-source-diagnostic path (read-file path))
        [(OkCompilerLoadParse program)
          (match program
            [(AstProgram decls)
              (compiler-load-decls-diagnostic
                decls
                path
                (sym-i64-bind seen path 1))])]
        [(ErrCompilerLoadParse diag) (ErrCompilerLoadDiagnostic diag)])
      (ErrCompilerLoadDiagnostic
        (compiler-diagnostic-at-start
          path
          (string-append "compiler-load: cannot read import " path))))))

(define (compiler-load-file [path : String] [seen : SymI64Env]) : ResultCompilerLoad
  (if (sym-i64-contains seen path)
    (OkCompilerLoad AstDeclNil seen)
    (if (file-exists? path)
      (match (parse-ast-source (read-file path))
        [(OkAstProgram program)
          (match program
            [(AstProgram decls)
              (compiler-load-decls decls path (sym-i64-bind seen path 1))])]
        [(ErrAstProgram message) (ErrCompilerLoad message)])
      (ErrCompilerLoad
        (string-append "compiler-load: cannot read import " path)))))