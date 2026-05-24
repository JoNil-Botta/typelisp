;; compiler_driver_core.tl - Import-aware selfhost compiler driver helpers.

(import "compiler_backend.tl")
(import "compiler_optimize.tl")

(defenum ResultCompilerLoad
  (OkCompilerLoad AstDeclList SymI64Env)
  (ErrCompilerLoad String))

(define (compiler-driver-char-code-at [text : String] [idx : i64]) : i64
  (cast (string-ref text idx) : i64))

(define (compiler-driver-path-separator-code? [code : i64]) : bool
  (or (= code 47) (= code 92)))

(define (compiler-driver-absolute-path? [path : String]) : bool
  (let ([n : i64 (string-length path)])
    (if (= n 0)
        false
        (let ([first : i64 (compiler-driver-char-code-at path 0)])
          (if (compiler-driver-path-separator-code? first)
              true
              (if (> n 1)
                  (= (compiler-driver-char-code-at path 1) 58)
                  false))))))

(define (compiler-driver-dirname [path : String]) : String
  (let ([n : i64 (string-length path)]
        [i : i64 0]
        [last : i64 -1])
    (begin
      (while (< i n)
        (begin
          (if (compiler-driver-path-separator-code? (compiler-driver-char-code-at path i))
              (set! last i)
              (set! last last))
          (set! i (+ i 1))))
      (if (< last 0)
          ""
          (substring path 0 (+ last 1))))))

(define (compiler-driver-join-import-path [importer-path : String] [import-path : String]) : String
  (if (compiler-driver-absolute-path? import-path)
      import-path
      (string-append (compiler-driver-dirname importer-path) import-path)))

(define (compiler-driver-string-prefix-at? [text : String] [prefix : String] [start : i64]) : bool
  (let ([text-len : i64 (string-length text)]
        [prefix-len : i64 (string-length prefix)])
    (if (< start 0)
        false
        (if (> (+ start prefix-len) text-len)
            false
            (let ([i : i64 0]
                  [ok : bool true])
              (begin
                (while ok
                  (if (< i prefix-len)
                      (if (= (compiler-driver-char-code-at text (+ start i))
                             (compiler-driver-char-code-at prefix i))
                          (set! i (+ i 1))
                          (set! ok false))
                      (set! ok false)))
                (= i prefix-len)))))))

(define (compiler-driver-stdlib-import? [path : String]) : bool
  (compiler-driver-string-prefix-at? path "stdlib/" 0))

(define (compiler-driver-resolve-import [importer-path : String] [import-path : String]) : String
  (let ([primary : String (compiler-driver-join-import-path importer-path import-path)])
    (if (file-exists? primary)
        primary
        (if (and (compiler-driver-stdlib-import? import-path) (file-exists? import-path))
            import-path
            primary))))

(define (compiler-driver-decl-list-append [left : AstDeclList] [right : AstDeclList]) : AstDeclList
  (match left
    [(AstDeclNil) right]
    [(AstDeclCons head rest)
     (AstDeclCons head (compiler-driver-decl-list-append rest right))]))

(define (compiler-driver-load-decls [decls : AstDeclList] [importer-path : String] [seen : SymI64Env]) : ResultCompilerLoad
  (match decls
    [(AstDeclNil) (OkCompilerLoad AstDeclNil seen)]
    [(AstDeclCons decl rest)
     (match decl
       [(AstDeclImport import-path)
        (let ([resolved : String (compiler-driver-resolve-import importer-path import-path)])
          (match (compiler-driver-load-file resolved seen)
            [(OkCompilerLoad imported-decls import-seen)
             (match (compiler-driver-load-decls rest importer-path import-seen)
               [(OkCompilerLoad rest-decls rest-seen)
                (OkCompilerLoad
                  (compiler-driver-decl-list-append imported-decls rest-decls)
                  rest-seen)]
               [(ErrCompilerLoad message) (ErrCompilerLoad message)])]
            [(ErrCompilerLoad message) (ErrCompilerLoad message)]))]
       [_ (match (compiler-driver-load-decls rest importer-path seen)
            [(OkCompilerLoad rest-decls rest-seen)
             (OkCompilerLoad (AstDeclCons decl rest-decls) rest-seen)]
            [(ErrCompilerLoad message) (ErrCompilerLoad message)])])]))

(define (compiler-driver-load-file [path : String] [seen : SymI64Env]) : ResultCompilerLoad
  (if (sym-i64-contains seen path)
      (OkCompilerLoad AstDeclNil seen)
      (if (file-exists? path)
          (match (parse-ast-source (read-file path))
            [(OkAstProgram program)
             (match program
               [(AstProgram decls)
                (compiler-driver-load-decls decls path (sym-i64-bind seen path 1))])]
            [(ErrAstProgram message) (ErrCompilerLoad message)])
          (ErrCompilerLoad (string-append "compiler-driver: cannot read import " path)))))

(define (compiler-driver-emit-file [input-path : String]) : ResultCompilerBackend
  (match (compiler-driver-load-file input-path (sym-i64-empty))
    [(OkCompilerLoad decls _)
     (match (lower-compiler-program (AstProgram decls))
       [(OkCompilerLower program) (compiler-backend-emit-program (optimize-program program))]
       [(ErrCompilerLower message) (ErrCompilerBackend message)])]
    [(ErrCompilerLoad message) (ErrCompilerBackend message)]))

(define (compiler-driver-compile-file [input-path : String] [output-path : String]) : i64
  (match (compiler-driver-emit-file input-path)
    [(OkCompilerBackend asm)
     (begin
       (write-file output-path asm)
       0)]
    [(ErrCompilerBackend message)
     (begin
       (print-error message)
       1)]))
