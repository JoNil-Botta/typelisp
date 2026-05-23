;; compiler_symbols.tl - Top-level symbol table slice for the selfhost compiler.

(import "compiler_parse_core.tl")
(import "sym_i64_env.tl")

(defenum CompilerSymbols
  (CompilerSymbolsState SymI64Env i64))

(defenum ResultCompilerSymbols
  (OkCompilerSymbols CompilerSymbols)
  (ErrCompilerSymbols String))

(define (compiler-symbol-kind-value) : i64 1)
(define (compiler-symbol-kind-function) : i64 2)
(define (compiler-symbol-kind-extern) : i64 3)
(define (compiler-symbol-kind-enum) : i64 4)
(define (compiler-symbol-kind-struct) : i64 5)

(define (compiler-symbol-handle-stride) : i64 1000000)

(define (compiler-symbol-handle [kind : i64] [index : i64]) : i64
  (+ (* kind (compiler-symbol-handle-stride)) index))

(define (compiler-symbol-handle-kind [handle : i64]) : i64
  (/ handle (compiler-symbol-handle-stride)))

(define (compiler-symbol-handle-index [handle : i64]) : i64
  (% handle (compiler-symbol-handle-stride)))

(define (compiler-symbols-empty) : CompilerSymbols
  (CompilerSymbolsState (sym-i64-empty) 0))

(define (compiler-symbols-count [symbols : CompilerSymbols]) : i64
  (match symbols
    [(CompilerSymbolsState _ count) count]))

(define (compiler-symbols-lookup [symbols : CompilerSymbols] [name : String]) : MaybeI64
  (match symbols
    [(CompilerSymbolsState env _) (sym-i64-lookup env name)]))

(define (compiler-symbols-insert
         [symbols : CompilerSymbols]
         [name : String]
         [kind : i64]) : ResultCompilerSymbols
  (match symbols
    [(CompilerSymbolsState env next-index)
     (if (sym-i64-contains env name)
         (ErrCompilerSymbols "compiler symbols: duplicate top-level name")
         (OkCompilerSymbols
           (CompilerSymbolsState
             (sym-i64-bind env name (compiler-symbol-handle kind next-index))
             (+ next-index 1))))]))

(define (compiler-symbols-add-decl
         [symbols : CompilerSymbols]
         [decl : AstDecl]) : ResultCompilerSymbols
  (match decl
    [(AstDeclDef name _ _) (compiler-symbols-insert symbols name (compiler-symbol-kind-value))]
    [(AstDeclDefFn name _ _ _) (compiler-symbols-insert symbols name (compiler-symbol-kind-function))]
    [(AstDeclExtern name _) (compiler-symbols-insert symbols name (compiler-symbol-kind-extern))]
    [(AstDeclDefEnum name _) (compiler-symbols-insert symbols name (compiler-symbol-kind-enum))]
    [(AstDeclDefStruct name _) (compiler-symbols-insert symbols name (compiler-symbol-kind-struct))]
    [(AstDeclImport _) (OkCompilerSymbols symbols)]))

(define (compiler-symbols-build-decls
         [decls : AstDeclList]
         [symbols : CompilerSymbols]) : ResultCompilerSymbols
  (match decls
    [(AstDeclNil) (OkCompilerSymbols symbols)]
    [(AstDeclCons decl rest)
     (match (compiler-symbols-add-decl symbols decl)
       [(OkCompilerSymbols next-symbols) (compiler-symbols-build-decls rest next-symbols)]
       [(ErrCompilerSymbols message) (ErrCompilerSymbols message)])]))

(define (build-compiler-symbols [program : AstProgram]) : ResultCompilerSymbols
  (match program
    [(AstProgram decls) (compiler-symbols-build-decls decls (compiler-symbols-empty))]))

(define (compiler-symbol-handle-matches?
         [actual : MaybeI64]
         [kind : i64]
         [index : i64]) : bool
  (match actual
    [(SomeI64 handle)
     (and (= (compiler-symbol-handle-kind handle) kind)
          (= (compiler-symbol-handle-index handle) index))]
    [(NoneI64) false]))

(define (compiler-symbols-misses? [symbols : CompilerSymbols] [name : String]) : bool
  (match (compiler-symbols-lookup symbols name)
    [(SomeI64 _) false]
    [(NoneI64) true]))

(define (compiler-symbols-expect-smoke [symbols : CompilerSymbols]) : bool
  (and
    (= (compiler-symbols-count symbols) 5)
    (and
      (compiler-symbol-handle-matches?
        (compiler-symbols-lookup symbols "Point")
        (compiler-symbol-kind-struct)
        0)
      (and
        (compiler-symbol-handle-matches?
          (compiler-symbols-lookup symbols "Maybe")
          (compiler-symbol-kind-enum)
          1)
        (and
          (compiler-symbol-handle-matches?
            (compiler-symbols-lookup symbols "print-string")
            (compiler-symbol-kind-extern)
            2)
          (and
            (compiler-symbol-handle-matches?
              (compiler-symbols-lookup symbols "answer")
              (compiler-symbol-kind-value)
              3)
            (and
              (compiler-symbol-handle-matches?
                (compiler-symbols-lookup symbols "main")
                (compiler-symbol-kind-function)
                4)
              (compiler-symbols-misses? symbols "missing"))))))))

(define (compiler-symbols-smoke-source) : String
  "(import \"stdlib/test.tl\")
(defstruct Point (x i64) (y i64))
(defenum Maybe (None) (Some i64))
(extern print-string : (-> String unit))
(define answer : i64 42)
(define (main [argc : i64] [name : String]) : i64
  answer)")

(define (compiler-symbols-duplicate-source) : String
  "(define answer : i64 1)
(define answer : i64 2)")

(define (compiler-symbols-duplicate-ok?) : bool
  (match (parse-ast-source (compiler-symbols-duplicate-source))
    [(OkAstProgram program)
     (match (build-compiler-symbols program)
       [(OkCompilerSymbols _) false]
       [(ErrCompilerSymbols _) true])]
    [(ErrAstProgram _) false]))

(define (compiler-symbols-smoke) : i64
  (match (parse-ast-source (compiler-symbols-smoke-source))
    [(OkAstProgram program)
     (match (build-compiler-symbols program)
       [(OkCompilerSymbols symbols)
        (if (and (compiler-symbols-expect-smoke symbols)
                 (compiler-symbols-duplicate-ok?))
            42
            (begin
              (panic "compiler symbols: smoke mismatch")
              0))]
       [(ErrCompilerSymbols message)
        (begin
          (panic message)
          0)])]
    [(ErrAstProgram message)
     (begin
       (panic (string-append "compiler symbols: parse failed: " message))
       0)]))
