;; compiler_load.tl - Shared selfhost compiler source/import loader.

(import "compiler_parse_core.tl")

(import "sym_i64_env.tl")

(defenum ResultCompilerLoad
  (OkCompilerLoad AstDeclList SymI64Env)
  (ErrCompilerLoad String))

(define (compiler-load-char-code-at [text : String] [idx : i64]) : i64
  (cast (string-ref text idx) : i64))

(define (compiler-load-path-separator-code? [code : i64]) : bool
  (or (= code 47) (= code 92)))

(define (compiler-load-absolute-path? [path : String]) : bool
  (let ([n : i64 (string-length path)])
    (if (= n 0)
      false
      (let ([first : i64 (compiler-load-char-code-at path 0)])
        (if (compiler-load-path-separator-code? first)
          true
          (if (> n 1)
            (= (compiler-load-char-code-at path 1) 58)
            false))))))

(define (compiler-load-dirname [path : String]) : String
  (let ([n : i64 (string-length path)] [i : i64 0] [last : i64 -1])
    (begin
      (while (< i n)
        (begin
          (if (compiler-load-path-separator-code?
            (compiler-load-char-code-at path i))
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