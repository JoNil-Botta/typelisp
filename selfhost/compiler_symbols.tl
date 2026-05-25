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

(defenum CompilerRegistries
  (CompilerRegistries SymI64Env SymI64Env))

(defenum ResultCompilerRegistries
  (OkCompilerRegistries CompilerRegistries)
  (ErrCompilerRegistries String))

(define (compiler-symbol-kind-value-define) : i64
  1)

(define (compiler-symbol-kind-function-define) : i64
  2)

(define (compiler-symbol-kind-extern) : i64
  3)

(define (compiler-symbol-kind-defenum) : i64
  4)

(define (compiler-symbol-kind-defstruct) : i64
  5)

(define (compiler-symbol-kind-enum-variant) : i64
  6)

(define (compiler-symbol-kind-struct-field) : i64
  7)

(define (compiler-symbol-handle-stride) : i64
  1000000000)

(define (compiler-registry-child-stride) : i64
  1000)

(define (compiler-symbol-make-handle [kind : i64] [index : i64]) : i64
  (+ (* kind (compiler-symbol-handle-stride)) index))

(define (compiler-symbol-handle-kind [handle : i64]) : i64
  (/ handle (compiler-symbol-handle-stride)))

(define (compiler-symbol-handle-index [handle : i64]) : i64
  (% handle (compiler-symbol-handle-stride)))

(define (compiler-registry-make-handle
  [kind : i64]
  [owner-index : i64]
  [child-index : i64]) : i64
  (+
    (* kind (compiler-symbol-handle-stride))
    (+ (* owner-index (compiler-registry-child-stride)) child-index)))

(define (compiler-registry-handle-kind [handle : i64]) : i64
  (compiler-symbol-handle-kind handle))

(define (compiler-registry-handle-owner-index [handle : i64]) : i64
  (/ (compiler-symbol-handle-index handle) (compiler-registry-child-stride)))

(define (compiler-registry-handle-child-index [handle : i64]) : i64
  (% (compiler-symbol-handle-index handle) (compiler-registry-child-stride)))

(define (compiler-registry-variant-owner-handle [handle : i64]) : i64
  (compiler-symbol-make-handle
    (compiler-symbol-kind-defenum)
    (compiler-registry-handle-owner-index handle)))

(define (compiler-registry-struct-owner-handle [handle : i64]) : i64
  (compiler-symbol-make-handle
    (compiler-symbol-kind-defstruct)
    (compiler-registry-handle-owner-index handle)))

(define (compiler-symbols-empty) : CompilerSymbols
  (CompilerSymbols (sym-i64-empty) (sym-i64-empty)))

(define (compiler-registries-empty) : CompilerRegistries
  (CompilerRegistries (sym-i64-empty) (sym-i64-empty)))

(define (compiler-symbols-lookup-value
  [symbols : CompilerSymbols]
  [name : String]) : MaybeI64
  (match symbols
    [(CompilerSymbols values _) (sym-i64-lookup values name)]))

(define (compiler-symbols-lookup-type
  [symbols : CompilerSymbols]
  [name : String]) : MaybeI64
  (match symbols
    [(CompilerSymbols _ types) (sym-i64-lookup types name)]))

(define (compiler-symbols-duplicate-value-message [name : String]) : String
  (string-append "symbols: duplicate value declaration " name))

(define (compiler-symbols-duplicate-type-message [name : String]) : String
  (string-append "symbols: duplicate type declaration " name))

(define (compiler-registries-duplicate-variant-message [name : String]) : String
  (string-append "symbols: duplicate enum variant " name))

(define (compiler-struct-field-key [struct-name : String] [field-name : String])
  :
  String
  ;; Flat field registry key. Field names may repeat across structs because the
  ;; struct name is part of the key.
  (string-append (string-append struct-name ".") field-name))

(define (compiler-registries-duplicate-field-message
  [struct-name : String]
  [field-name : String]) : String
  (string-append
    "symbols: duplicate field "
    (compiler-struct-field-key struct-name field-name)))

(define (compiler-symbols-add-value
  [symbols : CompilerSymbols]
  [name : String]
  [handle : i64]) : ResultCompilerSymbols
  (match symbols
    [(CompilerSymbols values types)
      (if (sym-i64-contains values name)
        (ErrCompilerSymbols (compiler-symbols-duplicate-value-message name))
        (OkCompilerSymbols
          (CompilerSymbols (sym-i64-bind values name handle) types)))]))

(define (compiler-symbols-add-type
  [symbols : CompilerSymbols]
  [name : String]
  [handle : i64]) : ResultCompilerSymbols
  (match symbols
    [(CompilerSymbols values types)
      (if (sym-i64-contains types name)
        (ErrCompilerSymbols (compiler-symbols-duplicate-type-message name))
        (OkCompilerSymbols
          (CompilerSymbols values (sym-i64-bind types name handle))))]))

(define (compiler-symbols-add-decl
  [symbols : CompilerSymbols]
  [decl : AstDecl]
  [index : i64]) : ResultCompilerSymbols
  (match decl
    [(AstDeclDef name _ _)
      (compiler-symbols-add-value
        symbols
        name
        (compiler-symbol-make-handle (compiler-symbol-kind-value-define) index))]
    [(AstDeclDefFn name _ _ _)
      (compiler-symbols-add-value
        symbols
        name
        (compiler-symbol-make-handle
          (compiler-symbol-kind-function-define)
          index))]
    [(AstDeclExtern name _)
      (compiler-symbols-add-value
        symbols
        name
        (compiler-symbol-make-handle (compiler-symbol-kind-extern) index))]
    [(AstDeclDefEnum name _)
      (compiler-symbols-add-type
        symbols
        name
        (compiler-symbol-make-handle (compiler-symbol-kind-defenum) index))]
    [(AstDeclDefStruct name _)
      (compiler-symbols-add-type
        symbols
        name
        (compiler-symbol-make-handle (compiler-symbol-kind-defstruct) index))]
    [(AstDeclImport _) (OkCompilerSymbols symbols)]
    [(AstDeclModule _) (OkCompilerSymbols symbols)]
    [(AstDeclTest _ _ _) (OkCompilerSymbols symbols)]
    [(AstDeclComptimeDecl template)
      (compiler-symbols-add-decl symbols template index)]))

(define (build-compiler-symbol-list
  [decls : AstDeclList]
  [symbols : CompilerSymbols]
  [index : i64]) : ResultCompilerSymbols
  (match decls
    [(AstDeclNil) (OkCompilerSymbols symbols)]
    [(AstDeclCons decl rest)
      (match decl
        [(AstDeclImport _) (build-compiler-symbol-list rest symbols index)]
        [(AstDeclModule _) (build-compiler-symbol-list rest symbols index)]
        [(AstDeclTest _ _ _) (build-compiler-symbol-list rest symbols index)]
        [_
          (match (compiler-symbols-add-decl symbols decl index)
            [(OkCompilerSymbols next-symbols)
              (build-compiler-symbol-list rest next-symbols (+ index 1))]
            [(ErrCompilerSymbols message) (ErrCompilerSymbols message)])])]))

(define (build-compiler-symbols [program : AstProgram]) : ResultCompilerSymbols
  (match program
    [(AstProgram decls)
      (build-compiler-symbol-list decls (compiler-symbols-empty) 0)]))

(define (build-compiler-symbols-from-source [src : String]) : ResultCompilerSymbols
  (match (parse-ast-source src)
    [(OkAstProgram program) (build-compiler-symbols program)]
    [(ErrAstProgram message) (ErrCompilerSymbols message)]))

(define (compiler-registries-lookup-variant
  [registries : CompilerRegistries]
  [name : String]) : MaybeI64
  (match registries
    [(CompilerRegistries variants _) (sym-i64-lookup variants name)]))

(define (compiler-registries-lookup-struct-field
  [registries : CompilerRegistries]
  [struct-name : String]
  [field-name : String]) : MaybeI64
  (match registries
    [(CompilerRegistries _ fields)
      (sym-i64-lookup fields (compiler-struct-field-key struct-name field-name))]))

(define (compiler-registries-add-variant
  [registries : CompilerRegistries]
  [name : String]
  [enum-index : i64]
  [variant-index : i64]) : ResultCompilerRegistries
  (match registries
    [(CompilerRegistries variants fields)
      (if (sym-i64-contains variants name)
        (ErrCompilerRegistries
          (compiler-registries-duplicate-variant-message name))
        (OkCompilerRegistries
          (CompilerRegistries
            (sym-i64-bind
              variants
              name
              (compiler-registry-make-handle
                (compiler-symbol-kind-enum-variant)
                enum-index
                variant-index))
            fields)))]))

(define (compiler-registries-add-field
  [registries : CompilerRegistries]
  [struct-name : String]
  [field-name : String]
  [struct-index : i64]
  [field-index : i64]) : ResultCompilerRegistries
  (match registries
    [(CompilerRegistries variants fields)
      (let ([key : String (compiler-struct-field-key struct-name field-name)])
        (if (sym-i64-contains fields key)
          (ErrCompilerRegistries
            (compiler-registries-duplicate-field-message struct-name field-name))
          (OkCompilerRegistries
            (CompilerRegistries
              variants
              (sym-i64-bind
                fields
                key
                (compiler-registry-make-handle
                  (compiler-symbol-kind-struct-field)
                  struct-index
                  field-index))))))]))

(define (build-compiler-variant-registry-list
  [variants : AstVariantDefList]
  [registries : CompilerRegistries]
  [enum-index : i64]
  [variant-index : i64]) : ResultCompilerRegistries
  (match variants
    [(AstVariantDefNil) (OkCompilerRegistries registries)]
    [(AstVariantDefCons variant rest)
      (match variant
        [(AstVariantDef name _)
          (match (compiler-registries-add-variant
            registries
            name
            enum-index
            variant-index)
            [(OkCompilerRegistries next-registries)
              (build-compiler-variant-registry-list
                rest
                next-registries
                enum-index
                (+ variant-index 1))]
            [(ErrCompilerRegistries message) (ErrCompilerRegistries message)])])]))

(define (build-compiler-field-registry-list
  [fields : AstFieldDefList]
  [registries : CompilerRegistries]
  [seen : SymI64Env]
  [struct-name : String]
  [struct-index : i64]
  [field-index : i64]) : ResultCompilerRegistries
  (match fields
    [(AstFieldDefNil) (OkCompilerRegistries registries)]
    [(AstFieldDefCons field rest)
      (match field
        [(AstFieldDef name _)
          (if (sym-i64-contains seen name)
            (ErrCompilerRegistries
              (compiler-registries-duplicate-field-message struct-name name))
            (match (compiler-registries-add-field
              registries
              struct-name
              name
              struct-index
              field-index)
              [(OkCompilerRegistries next-registries)
                (build-compiler-field-registry-list
                  rest
                  next-registries
                  (sym-i64-bind seen name field-index)
                  struct-name
                  struct-index
                  (+ field-index 1))]
              [(ErrCompilerRegistries message) (ErrCompilerRegistries message)]))])]))

(define (build-compiler-registry-list
  [decls : AstDeclList]
  [registries : CompilerRegistries]
  [index : i64]) : ResultCompilerRegistries
  (match decls
    [(AstDeclNil) (OkCompilerRegistries registries)]
    [(AstDeclCons decl rest)
      (match decl
        [(AstDeclImport _) (build-compiler-registry-list rest registries index)]
        [(AstDeclModule _) (build-compiler-registry-list rest registries index)]
        [(AstDeclTest _ _ _)
          (build-compiler-registry-list rest registries index)]
        [(AstDeclDefEnum _ variants)
          (match (build-compiler-variant-registry-list
            variants
            registries
            index
            0)
            [(OkCompilerRegistries next-registries)
              (build-compiler-registry-list rest next-registries (+ index 1))]
            [(ErrCompilerRegistries message) (ErrCompilerRegistries message)])]
        [(AstDeclDefStruct name fields)
          (match (build-compiler-field-registry-list
            fields
            registries
            (sym-i64-empty)
            name
            index
            0)
            [(OkCompilerRegistries next-registries)
              (build-compiler-registry-list rest next-registries (+ index 1))]
            [(ErrCompilerRegistries message) (ErrCompilerRegistries message)])]
        [(AstDeclComptimeDecl template)
          (match template
            [(AstDeclDefEnum _ variants)
              (match (build-compiler-variant-registry-list
                variants
                registries
                index
                0)
                [(OkCompilerRegistries next-registries)
                  (build-compiler-registry-list
                    rest
                    next-registries
                    (+ index 1))]
                [(ErrCompilerRegistries message)
                  (ErrCompilerRegistries message)])]
            [(AstDeclDefStruct name fields)
              (match (build-compiler-field-registry-list
                fields
                registries
                (sym-i64-empty)
                name
                index
                0)
                [(OkCompilerRegistries next-registries)
                  (build-compiler-registry-list
                    rest
                    next-registries
                    (+ index 1))]
                [(ErrCompilerRegistries message)
                  (ErrCompilerRegistries message)])]
            [_ (build-compiler-registry-list rest registries (+ index 1))])]
        [_ (build-compiler-registry-list rest registries (+ index 1))])]))

(define (build-compiler-registries [program : AstProgram]) : ResultCompilerRegistries
  (match (build-compiler-symbols program)
    [(OkCompilerSymbols _)
      (match program
        [(AstProgram decls)
          (build-compiler-registry-list decls (compiler-registries-empty) 0)])]
    [(ErrCompilerSymbols message) (ErrCompilerRegistries message)]))

(define (build-compiler-registries-from-source [src : String]) : ResultCompilerRegistries
  (match (parse-ast-source src)
    [(OkAstProgram program) (build-compiler-registries program)]
    [(ErrAstProgram message) (ErrCompilerRegistries message)]))

(define (compiler-decl-list-at-index
  [decls : AstDeclList]
  [target : i64]
  [index : i64]) : ResultAstDecl
  (match decls
    [(AstDeclNil) (ErrAstDecl "symbols: declaration index not found")]
    [(AstDeclCons decl rest)
      (match decl
        [(AstDeclImport _) (compiler-decl-list-at-index rest target index)]
        [(AstDeclModule _) (compiler-decl-list-at-index rest target index)]
        [(AstDeclTest _ _ _) (compiler-decl-list-at-index rest target index)]
        [_
          (if (= target index)
            (match decl
              [(AstDeclComptimeDecl template) (OkAstDecl template)]
              [_ (OkAstDecl decl)])
            (compiler-decl-list-at-index rest target (+ index 1)))])]))

(define (compiler-program-decl-at-index [program : AstProgram] [target : i64]) : ResultAstDecl
  (match program
    [(AstProgram decls) (compiler-decl-list-at-index decls target 0)]))

(define (compiler-variant-types-at-index
  [variants : AstVariantDefList]
  [target : i64]
  [index : i64]) : ResultAstTypeList
  (match variants
    [(AstVariantDefNil) (ErrAstTypeList "symbols: variant index not found")]
    [(AstVariantDefCons variant rest)
      (match variant
        [(AstVariantDef _ fields)
          (if (= target index)
            (OkAstTypeList fields)
            (compiler-variant-types-at-index rest target (+ index 1)))])]))

(define (compiler-field-type-at-index
  [fields : AstFieldDefList]
  [target : i64]
  [index : i64]) : ResultAstType
  (match fields
    [(AstFieldDefNil) (ErrAstType "symbols: field index not found")]
    [(AstFieldDefCons field rest)
      (match field
        [(AstFieldDef _ ty)
          (if (= target index)
            (OkAstType ty)
            (compiler-field-type-at-index rest target (+ index 1)))])]))

(define (compiler-registries-variant-fields
  [program : AstProgram]
  [handle : i64]) : ResultAstTypeList
  (match (compiler-program-decl-at-index
    program
    (compiler-registry-handle-owner-index handle))
    [(OkAstDecl decl)
      (match decl
        [(AstDeclDefEnum _ variants)
          (compiler-variant-types-at-index
            variants
            (compiler-registry-handle-child-index handle)
            0)]
        [_ (ErrAstTypeList "symbols: variant owner is not enum")])]
    [(ErrAstDecl message) (ErrAstTypeList message)]))

(define (compiler-registries-struct-field-type
  [program : AstProgram]
  [handle : i64]) : ResultAstType
  (match (compiler-program-decl-at-index
    program
    (compiler-registry-handle-owner-index handle))
    [(OkAstDecl decl)
      (match decl
        [(AstDeclDefStruct _ fields)
          (compiler-field-type-at-index
            fields
            (compiler-registry-handle-child-index handle)
            0)]
        [_ (ErrAstType "symbols: field owner is not struct")])]
    [(ErrAstDecl message) (ErrAstType message)]))

(define (compiler-symbol-lookup-score
  [found : MaybeI64]
  [want-kind : i64]
  [want-index : i64]) : i64
  (match found
    [(SomeI64 handle)
      (if (and
        (= (compiler-symbol-handle-kind handle) want-kind)
        (= (compiler-symbol-handle-index handle) want-index))
        1
        0)]
    [(NoneI64) 0]))

(define (compiler-symbols-miss-score [found : MaybeI64]) : i64
  (match found
    [(NoneI64) 1]
    [(SomeI64 _) 0]))

(define (compiler-registry-lookup-score
  [found : MaybeI64]
  [want-kind : i64]
  [want-owner : i64]
  [want-child : i64]) : i64
  (match found
    [(SomeI64 handle)
      (if (and
        (= (compiler-registry-handle-kind handle) want-kind)
        (and
          (= (compiler-registry-handle-owner-index handle) want-owner)
          (= (compiler-registry-handle-child-index handle) want-child)))
        1
        0)]
    [(NoneI64) 0]))

(define (compiler-type-result-tag-score
  [found : ResultAstType]
  [want-tag : i64]) : i64
  (match found
    [(OkAstType ty)
      (if (= (ast-type-tag ty) want-tag)
        1
        0)]
    [(ErrAstType _) 0]))

(define (compiler-type-list-single-tag-score
  [found : ResultAstTypeList]
  [want-tag : i64]) : i64
  (match found
    [(OkAstTypeList types)
      (match types
        [(AstTypeCons ty AstTypeNil)
          (if (= (ast-type-tag ty) want-tag)
            1
            0)]
        [_ 0])]
    [(ErrAstTypeList _) 0]))

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
  (+
    (compiler-symbol-lookup-score
      (compiler-symbols-lookup-type symbols "Point")
      (compiler-symbol-kind-defstruct)
      0)
    (+
      (compiler-symbol-lookup-score
        (compiler-symbols-lookup-type symbols "Maybe")
        (compiler-symbol-kind-defenum)
        1)
      (+
        (compiler-symbol-lookup-score
          (compiler-symbols-lookup-value symbols "print-string")
          (compiler-symbol-kind-extern)
          2)
        (+
          (compiler-symbol-lookup-score
            (compiler-symbols-lookup-value symbols "answer")
            (compiler-symbol-kind-value-define)
            3)
          (+
            (compiler-symbol-lookup-score
              (compiler-symbols-lookup-value symbols "main")
              (compiler-symbol-kind-function-define)
              4)
            (+
              (compiler-symbols-miss-score
                (compiler-symbols-lookup-value symbols "stdlib/test.tl"))
              (compiler-symbols-miss-score
                (compiler-symbols-lookup-type symbols "missing")))))))))

(define (compiler-registries-smoke-score
  [program : AstProgram]
  [registries : CompilerRegistries]) : i64
  (let (
    [some : MaybeI64 (compiler-registries-lookup-variant registries "Some")]
    [none : MaybeI64 (compiler-registries-lookup-variant registries "None")]
    [x-field : MaybeI64
      (compiler-registries-lookup-struct-field registries "Point" "x")]
    [y-field : MaybeI64
      (compiler-registries-lookup-struct-field registries "Point" "y")])
    (+
      (compiler-registry-lookup-score
        some
        (compiler-symbol-kind-enum-variant)
        1
        1)
      (+
        (compiler-registry-lookup-score
          none
          (compiler-symbol-kind-enum-variant)
          1
          0)
        (+
          (compiler-registry-lookup-score
            x-field
            (compiler-symbol-kind-struct-field)
            0
            0)
          (+
            (compiler-registry-lookup-score
              y-field
              (compiler-symbol-kind-struct-field)
              0
              1)
            (+
              (match x-field
                [(SomeI64 handle)
                  (compiler-type-result-tag-score
                    (compiler-registries-struct-field-type program handle)
                    (ast-type-tag (AstTyI64)))]
                [(NoneI64) 0])
              (+
                (match some
                  [(SomeI64 handle)
                    (compiler-type-list-single-tag-score
                      (compiler-registries-variant-fields program handle)
                      (ast-type-tag (AstTyI64)))]
                  [(NoneI64) 0])
                (+
                  (compiler-symbols-miss-score
                    (compiler-registries-lookup-variant registries "Missing"))
                  (compiler-symbols-miss-score
                    (compiler-registries-lookup-struct-field
                      registries
                      "Point"
                      "z")))))))))))

(define (compiler-symbols-duplicate-value-source) : String
  "(define answer : i64 1)
(define (answer) : i64 2)")

(define (compiler-symbols-duplicate-type-source) : String
  "(defstruct Point (x i64))
(defenum Point (PointVariant))")

(define (compiler-registries-duplicate-variant-source) : String
  "(defenum Left (Same))
(defenum Right (Same))")

(define (compiler-registries-duplicate-field-source) : String
  "(defstruct Pair (x i64) (x i64))")

(define (compiler-symbols-duplicate-value-ok?) : bool
  (match (build-compiler-symbols-from-source
    (compiler-symbols-duplicate-value-source))
    [(ErrCompilerSymbols message)
      (string-eq message (compiler-symbols-duplicate-value-message "answer"))]
    [(OkCompilerSymbols _) false]))

(define (compiler-symbols-duplicate-type-ok?) : bool
  (match (build-compiler-symbols-from-source
    (compiler-symbols-duplicate-type-source))
    [(ErrCompilerSymbols message)
      (string-eq message (compiler-symbols-duplicate-type-message "Point"))]
    [(OkCompilerSymbols _) false]))

(define (compiler-registries-duplicate-variant-ok?) : bool
  (match (build-compiler-registries-from-source
    (compiler-registries-duplicate-variant-source))
    [(ErrCompilerRegistries message)
      (string-eq message (compiler-registries-duplicate-variant-message "Same"))]
    [(OkCompilerRegistries _) false]))

(define (compiler-registries-duplicate-field-ok?) : bool
  (match (build-compiler-registries-from-source
    (compiler-registries-duplicate-field-source))
    [(ErrCompilerRegistries message)
      (string-eq
        message
        (compiler-registries-duplicate-field-message "Pair" "x"))]
    [(OkCompilerRegistries _) false]))

(define (compiler-registry-large-owner-handle-ok?) : bool
  (let ([handle : i64
    (compiler-registry-make-handle (compiler-symbol-kind-enum-variant) 1234 5)])
    (and
      (=
        (compiler-registry-handle-kind handle)
        (compiler-symbol-kind-enum-variant))
      (and
        (= (compiler-registry-handle-owner-index handle) 1234)
        (= (compiler-registry-handle-child-index handle) 5)))))

(define (compiler-symbols-comptime-decl-source) : String
  "(comptime-decl (defstruct Point (x i64) (y i64)))
(comptime-decl (defenum Maybe (None) (Some i64)))
(define (main) : i64 0)")

(define (compiler-symbols-comptime-decl-ok?) : bool
  (match (parse-ast-source (compiler-symbols-comptime-decl-source))
    [(OkAstProgram program)
      (match (build-compiler-symbols program)
        [(OkCompilerSymbols symbols)
          (match (build-compiler-registries program)
            [(OkCompilerRegistries registries)
              (and
                (=
                  (compiler-symbol-lookup-score
                    (compiler-symbols-lookup-type symbols "Point")
                    (compiler-symbol-kind-defstruct)
                    0)
                  1)
                (and
                  (=
                    (compiler-symbol-lookup-score
                      (compiler-symbols-lookup-type symbols "Maybe")
                      (compiler-symbol-kind-defenum)
                      1)
                    1)
                  (= (compiler-registries-smoke-score program registries) 8)))]
            [(ErrCompilerRegistries _) false])]
        [(ErrCompilerSymbols _) false])]
    [(ErrAstProgram _) false]))

(define (compiler-symbols-self-test) : i64
  (match (parse-ast-source (compiler-symbols-smoke-source))
    [(OkAstProgram program)
      (match (build-compiler-symbols program)
        [(OkCompilerSymbols symbols)
          (match (build-compiler-registries program)
            [(OkCompilerRegistries registries)
              (if (and
                (= (compiler-symbols-smoke-score symbols) 7)
                (and
                  (= (compiler-registries-smoke-score program registries) 8)
                  (and
                    (compiler-symbols-duplicate-value-ok?)
                    (and
                      (compiler-symbols-duplicate-type-ok?)
                      (and
                        (compiler-registries-duplicate-variant-ok?)
                        (and
                          (compiler-registries-duplicate-field-ok?)
                          (and
                            (compiler-registry-large-owner-handle-ok?)
                            (compiler-symbols-comptime-decl-ok?))))))))
                42
                (begin
                  (panic "symbols: smoke score mismatch")
                  0))]
            [(ErrCompilerRegistries message)
              (begin
                (panic message)
                0)])]
        [(ErrCompilerSymbols message)
          (begin
            (panic message)
            0)])]
    [(ErrAstProgram message)
      (begin
        (panic message)
        0)]))