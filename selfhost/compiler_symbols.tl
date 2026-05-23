;; compiler_symbols.tl - Top-level compiler symbol table over AstProgram (#405).
;;
;; This is intentionally an assoc-list slice over SymI64Env, not the future
;; hash-table work from #42. Handles are packed as kind * stride + declaration
;; index, where index is the source-order position among supported declarations.
;; Import declarations have no top-level symbol name here and do not consume an
;; index.

(import "compiler_parse_core.tl")
(import "sym_i64_env.tl")

(defenum CompilerSymbols
  (CompilerSymbols SymI64Env SymI64Env))

(defenum ResultCompilerSymbols
  (OkCompilerSymbols CompilerSymbols)
  (ErrCompilerSymbols String))

(define (compiler-symbol-kind-value-define) : i64 1)
(define (compiler-symbol-kind-function-define) : i64 2)
(define (compiler-symbol-kind-extern) : i64 3)
(define (compiler-symbol-kind-defenum) : i64 4)
(define (compiler-symbol-kind-defstruct) : i64 5)

(define (compiler-symbol-handle-stride) : i64 1000000)

(define (compiler-symbol-make-handle [kind : i64] [index : i64]) : i64
  (+ (* kind (compiler-symbol-handle-stride)) index))

(define (compiler-symbol-handle-kind [handle : i64]) : i64
  (/ handle (compiler-symbol-handle-stride)))

(define (compiler-symbol-handle-index [handle : i64]) : i64
  (% handle (compiler-symbol-handle-stride)))

(define (compiler-symbols-empty) : CompilerSymbols
  (CompilerSymbols (sym-i64-empty) (sym-i64-empty)))

(define (compiler-symbols-lookup-value [symbols : CompilerSymbols] [name : String]) : MaybeI64
  (match symbols
    [(CompilerSymbols values _) (sym-i64-lookup values name)]))

(define (compiler-symbols-lookup-type [symbols : CompilerSymbols] [name : String]) : MaybeI64
  (match symbols
    [(CompilerSymbols _ types) (sym-i64-lookup types name)]))

(define (compiler-symbols-duplicate-value-message [name : String]) : String
  (string-append "symbols: duplicate value declaration " name))

(define (compiler-symbols-duplicate-type-message [name : String]) : String
  (string-append "symbols: duplicate type declaration " name))

(define (compiler-symbols-add-value [symbols : CompilerSymbols] [name : String] [handle : i64]) : ResultCompilerSymbols
  (match symbols
    [(CompilerSymbols values types)
     (if (sym-i64-contains values name)
         (ErrCompilerSymbols (compiler-symbols-duplicate-value-message name))
         (OkCompilerSymbols (CompilerSymbols (sym-i64-bind values name handle) types)))]))

(define (compiler-symbols-add-type [symbols : CompilerSymbols] [name : String] [handle : i64]) : ResultCompilerSymbols
  (match symbols
    [(CompilerSymbols values types)
     (if (sym-i64-contains types name)
         (ErrCompilerSymbols (compiler-symbols-duplicate-type-message name))
         (OkCompilerSymbols (CompilerSymbols values (sym-i64-bind types name handle))))]))

(define (compiler-symbols-add-decl [symbols : CompilerSymbols] [decl : AstDecl] [index : i64]) : ResultCompilerSymbols
  (match decl
    [(AstDeclDef name _ _)
     (compiler-symbols-add-value symbols name
       (compiler-symbol-make-handle (compiler-symbol-kind-value-define) index))]
    [(AstDeclDefFn name _ _ _)
     (compiler-symbols-add-value symbols name
       (compiler-symbol-make-handle (compiler-symbol-kind-function-define) index))]
    [(AstDeclExtern name _)
     (compiler-symbols-add-value symbols name
       (compiler-symbol-make-handle (compiler-symbol-kind-extern) index))]
    [(AstDeclDefEnum name _)
     (compiler-symbols-add-type symbols name
       (compiler-symbol-make-handle (compiler-symbol-kind-defenum) index))]
    [(AstDeclDefStruct name _)
     (compiler-symbols-add-type symbols name
       (compiler-symbol-make-handle (compiler-symbol-kind-defstruct) index))]
    [(AstDeclImport _) (OkCompilerSymbols symbols)]))

(define (build-compiler-symbol-list [decls : AstDeclList] [symbols : CompilerSymbols] [index : i64]) : ResultCompilerSymbols
  (match decls
    [(AstDeclNil) (OkCompilerSymbols symbols)]
    [(AstDeclCons decl rest)
     (match decl
       [(AstDeclImport _) (build-compiler-symbol-list rest symbols index)]
       [_ (match (compiler-symbols-add-decl symbols decl index)
            [(OkCompilerSymbols next-symbols)
             (build-compiler-symbol-list rest next-symbols (+ index 1))]
            [(ErrCompilerSymbols message) (ErrCompilerSymbols message)])])]))

(define (build-compiler-symbols [program : AstProgram]) : ResultCompilerSymbols
  (match program
    [(AstProgram decls) (build-compiler-symbol-list decls (compiler-symbols-empty) 0)]))

(define (build-compiler-symbols-from-source [src : String]) : ResultCompilerSymbols
  (match (parse-ast-source src)
    [(OkAstProgram program) (build-compiler-symbols program)]
    [(ErrAstProgram message) (ErrCompilerSymbols message)]))

(define (compiler-symbol-lookup-score [found : MaybeI64] [want-kind : i64] [want-index : i64]) : i64
  (match found
    [(SomeI64 handle)
     (if (and (= (compiler-symbol-handle-kind handle) want-kind)
              (= (compiler-symbol-handle-index handle) want-index))
         1
         0)]
    [(NoneI64) 0]))

(define (compiler-symbols-miss-score [found : MaybeI64]) : i64
  (match found
    [(NoneI64) 1]
    [(SomeI64 _) 0]))

(define (compiler-symbols-smoke-source) : String
  "(import \"stdlib/test.tl\")
(defstruct Point (x i64) (y i64))
(defenum Maybe (None) (Some i64))
(extern print-string : (-> String unit))
(define answer : i64 42)
(define (main [argc : i64] [name : String]) : i64
  (let ([x : i64 1] [arr (array 1 2 3)])
    (begin
      (set! x (+ x 41))
      (if (and (= x 42) true)
          (match (Some x) [(Some v) v] [_ 0])
          0))))")

(define (compiler-symbols-smoke-score [symbols : CompilerSymbols]) : i64
  (+ (compiler-symbol-lookup-score
       (compiler-symbols-lookup-type symbols "Point")
       (compiler-symbol-kind-defstruct)
       0)
     (+ (compiler-symbol-lookup-score
          (compiler-symbols-lookup-type symbols "Maybe")
          (compiler-symbol-kind-defenum)
          1)
        (+ (compiler-symbol-lookup-score
             (compiler-symbols-lookup-value symbols "print-string")
             (compiler-symbol-kind-extern)
             2)
           (+ (compiler-symbol-lookup-score
                (compiler-symbols-lookup-value symbols "answer")
                (compiler-symbol-kind-value-define)
                3)
              (+ (compiler-symbol-lookup-score
                   (compiler-symbols-lookup-value symbols "main")
                   (compiler-symbol-kind-function-define)
                   4)
                 (+ (compiler-symbols-miss-score
                      (compiler-symbols-lookup-value symbols "stdlib/test.tl"))
                    (compiler-symbols-miss-score
                      (compiler-symbols-lookup-type symbols "missing")))))))))

(define (compiler-symbols-duplicate-value-source) : String
  "(define answer : i64 1)
(define (answer) : i64 2)")

(define (compiler-symbols-duplicate-type-source) : String
  "(defstruct Point (x i64))
(defenum Point (PointVariant))")

(define (compiler-symbols-duplicate-value-ok?) : bool
  (match (build-compiler-symbols-from-source (compiler-symbols-duplicate-value-source))
    [(ErrCompilerSymbols message)
     (string-eq message (compiler-symbols-duplicate-value-message "answer"))]
    [(OkCompilerSymbols _) false]))

(define (compiler-symbols-duplicate-type-ok?) : bool
  (match (build-compiler-symbols-from-source (compiler-symbols-duplicate-type-source))
    [(ErrCompilerSymbols message)
     (string-eq message (compiler-symbols-duplicate-type-message "Point"))]
    [(OkCompilerSymbols _) false]))

(define (compiler-symbols-self-test) : i64
  (match (build-compiler-symbols-from-source (compiler-symbols-smoke-source))
    [(OkCompilerSymbols symbols)
     (if (and (= (compiler-symbols-smoke-score symbols) 7)
              (and (compiler-symbols-duplicate-value-ok?)
                   (compiler-symbols-duplicate-type-ok?)))
         42
         (begin
           (panic "symbols: smoke score mismatch")
           0))]
    [(ErrCompilerSymbols message)
     (begin
       (panic message)
       0)]))
