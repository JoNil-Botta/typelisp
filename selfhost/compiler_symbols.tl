;; compiler_symbols.tl - Top-level compiler symbol table over AstProgram (#405).
;;
;; Handles are packed as kind * stride + declaration index, where index is the
;; source-order position among supported declarations. Import declarations have
;; no top-level symbol name here and do not consume an index.
(import "compiler_parse_core.tl")

(import "sym_i64_env.tl")

(import "stdlib/hashmap.tl")

(defenum CompilerSymbols
  (CompilerSymbols StringI64Map StringI64Map StringI64Map))

(defenum ResultCompilerSymbols
  (OkCompilerSymbols CompilerSymbols)
  (ErrCompilerSymbols String))

(defenum CompilerRegistries
  (CompilerRegistries StringI64Map StringI64Map))

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

(define (compiler-symbol-kind-defmacro) : i64
  8)

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

(define (compiler-symbol-map-empty) : StringI64Map
  (string-i64-map-with-capacity 256))

(define (compiler-symbol-map-lookup [map : StringI64Map] [name : String]) : MaybeI64
  (match (string-i64-map-get map name)
    [(StringI64MapFound value) (SomeI64 value)]
    [(StringI64MapMissing) NoneI64]))

(define (compiler-symbol-map-contains? [map : StringI64Map] [name : String]) : bool
  (match (compiler-symbol-map-lookup map name)
    [(SomeI64 _) true]
    [(NoneI64) false]))

(define (compiler-symbol-map-bind
  [map : StringI64Map]
  [name : String]
  [handle : i64]) : StringI64Map
  (string-i64-map-put map name handle))

(define (compiler-symbols-empty) : CompilerSymbols
  (CompilerSymbols
    (compiler-symbol-map-empty)
    (compiler-symbol-map-empty)
    (compiler-symbol-map-empty)))

(define (compiler-registries-empty) : CompilerRegistries
  (CompilerRegistries (compiler-symbol-map-empty) (compiler-symbol-map-empty)))

(define (compiler-symbols-lookup-value
  [symbols : CompilerSymbols]
  [name : String]) : MaybeI64
  (match symbols
    [(CompilerSymbols values _ _) (compiler-symbol-map-lookup values name)]))

(define (compiler-symbols-lookup-type
  [symbols : CompilerSymbols]
  [name : String]) : MaybeI64
  (match symbols
    [(CompilerSymbols _ types _) (compiler-symbol-map-lookup types name)]))

(define (compiler-symbols-lookup-macro
  [symbols : CompilerSymbols]
  [name : String]) : MaybeI64
  (match symbols
    [(CompilerSymbols _ _ macros) (compiler-symbol-map-lookup macros name)]))

(define (compiler-symbols-duplicate-value-message [name : String]) : String
  (string-append "symbols: duplicate value declaration " name))

(define (compiler-symbols-duplicate-type-message [name : String]) : String
  (string-append "symbols: duplicate type declaration " name))

(define (compiler-symbols-duplicate-macro-message [name : String]) : String
  (string-append "symbols: duplicate macro declaration " name))

(define (compiler-symbols-duplicate-macro-value-message [name : String]) : String
  (string-append "symbols: duplicate macro/value declaration " name))

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

(define (compiler-symbol-module-key [module : String] [name : String]) : String
  (if (= (string-length module) 0)
    name
    (string-append module (string-append "/" name))))

(define (compiler-symbols-add-value-alias
  [symbols : CompilerSymbols]
  [name : String]
  [handle : i64]) : CompilerSymbols
  (match symbols
    [(CompilerSymbols values types macros)
      (if (compiler-symbol-map-contains? values name)
        symbols
        (CompilerSymbols
          (compiler-symbol-map-bind values name handle)
          types
          macros))]))

(define (compiler-symbols-add-type-alias
  [symbols : CompilerSymbols]
  [name : String]
  [handle : i64]) : CompilerSymbols
  (match symbols
    [(CompilerSymbols values types macros)
      (if (compiler-symbol-map-contains? types name)
        symbols
        (CompilerSymbols
          values
          (compiler-symbol-map-bind types name handle)
          macros))]))

(define (compiler-symbols-add-macro-alias
  [symbols : CompilerSymbols]
  [name : String]
  [handle : i64]) : CompilerSymbols
  (match symbols
    [(CompilerSymbols values types macros)
      (if (compiler-symbol-map-contains? macros name)
        symbols
        (CompilerSymbols
          values
          types
          (compiler-symbol-map-bind macros name handle)))]))

(define (compiler-registries-add-variant-alias
  [registries : CompilerRegistries]
  [name : String]
  [handle : i64]) : CompilerRegistries
  (match registries
    [(CompilerRegistries variants fields)
      (if (compiler-symbol-map-contains? variants name)
        registries
        (CompilerRegistries
          (compiler-symbol-map-bind variants name handle)
          fields))]))

(define (compiler-symbols-add-value
  [symbols : CompilerSymbols]
  [name : String]
  [handle : i64]) : ResultCompilerSymbols
  (match symbols
    [(CompilerSymbols values types macros)
      (if (compiler-symbol-map-contains? values name)
        (ErrCompilerSymbols (compiler-symbols-duplicate-value-message name))
        (if (compiler-symbol-map-contains? macros name)
          (ErrCompilerSymbols
            (compiler-symbols-duplicate-macro-value-message name))
          (OkCompilerSymbols
            (CompilerSymbols
              (compiler-symbol-map-bind values name handle)
              types
              macros))))]))

(define (compiler-symbols-add-variant-value
  [symbols : CompilerSymbols]
  [name : String]
  [handle : i64]) : ResultCompilerSymbols
  (match symbols
    [(CompilerSymbols values types macros)
      (match (compiler-symbol-map-lookup values name)
        [(SomeI64 existing)
          (if (=
            (compiler-symbol-handle-kind existing)
            (compiler-symbol-kind-enum-variant))
            (ErrCompilerSymbols
              (compiler-registries-duplicate-variant-message name))
            (ErrCompilerSymbols (compiler-symbols-duplicate-value-message name)))]
        [(NoneI64)
          (if (compiler-symbol-map-contains? macros name)
            (ErrCompilerSymbols
              (compiler-symbols-duplicate-macro-value-message name))
            (OkCompilerSymbols
              (CompilerSymbols
                (compiler-symbol-map-bind values name handle)
                types
                macros)))])]))

(define (compiler-symbols-add-type
  [symbols : CompilerSymbols]
  [name : String]
  [handle : i64]) : ResultCompilerSymbols
  (match symbols
    [(CompilerSymbols values types macros)
      (if (compiler-symbol-map-contains? types name)
        (ErrCompilerSymbols (compiler-symbols-duplicate-type-message name))
        (OkCompilerSymbols
          (CompilerSymbols
            values
            (compiler-symbol-map-bind types name handle)
            macros)))]))

(define (compiler-symbols-add-macro
  [symbols : CompilerSymbols]
  [name : String]
  [handle : i64]) : ResultCompilerSymbols
  (match symbols
    [(CompilerSymbols values types macros)
      (if (compiler-symbol-map-contains? macros name)
        (ErrCompilerSymbols (compiler-symbols-duplicate-macro-message name))
        (if (compiler-symbol-map-contains? values name)
          (ErrCompilerSymbols
            (compiler-symbols-duplicate-macro-value-message name))
          (OkCompilerSymbols
            (CompilerSymbols
              values
              types
              (compiler-symbol-map-bind macros name handle)))))]))

(define (compiler-symbols-add-value-in-module
  [symbols : CompilerSymbols]
  [module : String]
  [name : String]
  [handle : i64]) : ResultCompilerSymbols
  (let
    [key : String (compiler-symbol-module-key module name)]
    (match (compiler-symbols-add-value symbols key handle)
      [(OkCompilerSymbols next)
        (OkCompilerSymbols (compiler-symbols-add-value-alias next name handle))]
      [(ErrCompilerSymbols message) (ErrCompilerSymbols message)])))

(define (compiler-symbols-add-type-in-module
  [symbols : CompilerSymbols]
  [module : String]
  [name : String]
  [handle : i64]) : ResultCompilerSymbols
  (let
    [key : String (compiler-symbol-module-key module name)]
    (match (compiler-symbols-add-type symbols key handle)
      [(OkCompilerSymbols next)
        (OkCompilerSymbols (compiler-symbols-add-type-alias next name handle))]
      [(ErrCompilerSymbols message) (ErrCompilerSymbols message)])))

(define (compiler-symbols-add-variant-value-in-module
  [symbols : CompilerSymbols]
  [module : String]
  [name : String]
  [enum-index : i64]
  [variant-index : i64]) : ResultCompilerSymbols
  (let
    [key : String (compiler-symbol-module-key module name)]
    [handle : i64
      (compiler-registry-make-handle
        (compiler-symbol-kind-enum-variant)
        enum-index
        variant-index)]
    (match (compiler-symbols-add-variant-value symbols key handle)
      [(OkCompilerSymbols next)
        (OkCompilerSymbols (compiler-symbols-add-value-alias next name handle))]
      [(ErrCompilerSymbols message) (ErrCompilerSymbols message)])))

(define (compiler-symbols-add-variant-values-in-module
  [symbols : CompilerSymbols]
  [module : String]
  [variants : AstVariantDefList]
  [enum-index : i64]
  [variant-index : i64]) : ResultCompilerSymbols
  (match variants
    [(AstVariantDefNil) (OkCompilerSymbols symbols)]
    [(AstVariantDefCons variant rest)
      (match variant
        [(AstVariantDef name _)
          (match (compiler-symbols-add-variant-value-in-module
            symbols
            module
            name
            enum-index
            variant-index)
            [(OkCompilerSymbols next)
              (compiler-symbols-add-variant-values-in-module
                next
                module
                rest
                enum-index
                (+ variant-index 1))]
            [(ErrCompilerSymbols message) (ErrCompilerSymbols message)])])]))

(define (compiler-symbols-add-macro-in-module
  [symbols : CompilerSymbols]
  [module : String]
  [name : String]
  [handle : i64]) : ResultCompilerSymbols
  (let
    [key : String (compiler-symbol-module-key module name)]
    (match (compiler-symbols-add-macro symbols key handle)
      [(OkCompilerSymbols next)
        (OkCompilerSymbols (compiler-symbols-add-macro-alias next name handle))]
      [(ErrCompilerSymbols message) (ErrCompilerSymbols message)])))

(define (compiler-symbols-add-decl
  [symbols : CompilerSymbols]
  [decl : AstDecl]
  [index : i64]) : ResultCompilerSymbols
  (compiler-symbols-add-decl-in-module symbols "" decl index))

(define (compiler-symbols-add-decl-in-module
  [symbols : CompilerSymbols]
  [module : String]
  [decl : AstDecl]
  [index : i64]) : ResultCompilerSymbols
  (match decl
    [(AstDeclDef name _ _)
      (compiler-symbols-add-value-in-module
        symbols
        module
        name
        (compiler-symbol-make-handle (compiler-symbol-kind-value-define) index))]
    [(AstDeclDefFn name _ _ _)
      (compiler-symbols-add-value-in-module
        symbols
        module
        name
        (compiler-symbol-make-handle
          (compiler-symbol-kind-function-define)
          index))]
    [(AstDeclDefMacro name _ _ _)
      (compiler-symbols-add-macro-in-module
        symbols
        module
        name
        (compiler-symbol-make-handle (compiler-symbol-kind-defmacro) index))]
    [(AstDeclExtern name _ _)
      (compiler-symbols-add-value
        symbols
        name
        (compiler-symbol-make-handle (compiler-symbol-kind-extern) index))]
    [(AstDeclDefEnum name variants)
      (match (compiler-symbols-add-type-in-module
        symbols
        module
        name
        (compiler-symbol-make-handle (compiler-symbol-kind-defenum) index))
        [(OkCompilerSymbols next)
          (compiler-symbols-add-variant-values-in-module
            next
            module
            variants
            index
            0)]
        [(ErrCompilerSymbols message) (ErrCompilerSymbols message)])]
    [(AstDeclDefStruct name _ _ _)
      (match (compiler-symbols-add-type-in-module
        symbols
        module
        name
        (compiler-symbol-make-handle (compiler-symbol-kind-defstruct) index))
        [(OkCompilerSymbols next)
          (compiler-symbols-add-value-in-module
            next
            module
            name
            (compiler-symbol-make-handle (compiler-symbol-kind-defstruct) index))]
        [(ErrCompilerSymbols message) (ErrCompilerSymbols message)])]
    [(AstDeclImport _) (OkCompilerSymbols symbols)]
    [(AstDeclExport _) (OkCompilerSymbols symbols)]
    [(AstDeclModule _) (OkCompilerSymbols symbols)]
    [(AstDeclTest _ _ _) (OkCompilerSymbols symbols)]
    [(AstDeclComptimeDecl template)
      (compiler-symbols-add-decl-in-module symbols module template index)]))

(define (compiler-symbols-add-variant-value-aliases
  [symbols : CompilerSymbols]
  [alias : String]
  [variants : AstVariantDefList]
  [enum-index : i64]
  [variant-index : i64]) : CompilerSymbols
  (match variants
    [(AstVariantDefNil) symbols]
    [(AstVariantDefCons variant rest)
      (match variant
        [(AstVariantDef name _)
          (compiler-symbols-add-variant-value-aliases
            (compiler-symbols-add-value-alias
              symbols
              (compiler-symbol-module-key alias name)
              (compiler-registry-make-handle
                (compiler-symbol-kind-enum-variant)
                enum-index
                variant-index))
            alias
            rest
            enum-index
            (+ variant-index 1))])]))

(define (compiler-symbols-add-decl-alias-in-module
  [symbols : CompilerSymbols]
  [alias : String]
  [decl : AstDecl]
  [index : i64]) : CompilerSymbols
  (match decl
    [(AstDeclDef name _ _)
      (compiler-symbols-add-value-alias
        symbols
        (compiler-symbol-module-key alias name)
        (compiler-symbol-make-handle (compiler-symbol-kind-value-define) index))]
    [(AstDeclDefFn name _ _ _)
      (compiler-symbols-add-value-alias
        symbols
        (compiler-symbol-module-key alias name)
        (compiler-symbol-make-handle
          (compiler-symbol-kind-function-define)
          index))]
    [(AstDeclDefMacro name _ _ _)
      (compiler-symbols-add-macro-alias
        symbols
        (compiler-symbol-module-key alias name)
        (compiler-symbol-make-handle (compiler-symbol-kind-defmacro) index))]
    [(AstDeclExtern name _ _)
      (compiler-symbols-add-value-alias
        symbols
        (compiler-symbol-module-key alias name)
        (compiler-symbol-make-handle (compiler-symbol-kind-extern) index))]
    [(AstDeclDefEnum name variants)
      (compiler-symbols-add-variant-value-aliases
        (compiler-symbols-add-type-alias
          symbols
          (compiler-symbol-module-key alias name)
          (compiler-symbol-make-handle (compiler-symbol-kind-defenum) index))
        alias
        variants
        index
        0)]
    [(AstDeclDefStruct name _ _ _)
      (compiler-symbols-add-value-alias
        (compiler-symbols-add-type-alias
          symbols
          (compiler-symbol-module-key alias name)
          (compiler-symbol-make-handle (compiler-symbol-kind-defstruct) index))
        (compiler-symbol-module-key alias name)
        (compiler-symbol-make-handle (compiler-symbol-kind-defstruct) index))]
    [(AstDeclComptimeDecl template)
      (compiler-symbols-add-decl-alias-in-module symbols alias template index)]
    [_ symbols]))

(define (compiler-symbols-add-module-aliases-list
  [symbols : CompilerSymbols]
  [decls : AstDeclList]
  [target-module : String]
  [alias : String]
  [index : i64]
  [module : String]) : CompilerSymbols
  (match decls
    [(AstDeclNil) symbols]
    [(AstDeclCons decl rest)
      (match decl
        [(AstDeclImport _)
          (compiler-symbols-add-module-aliases-list
            symbols
            rest
            target-module
            alias
            index
            module)]
        [(AstDeclExport _)
          (compiler-symbols-add-module-aliases-list
            symbols
            rest
            target-module
            alias
            index
            module)]
        [(AstDeclModule next-module)
          (compiler-symbols-add-module-aliases-list
            symbols
            rest
            target-module
            alias
            index
            next-module)]
        [(AstDeclTest _ _ _)
          (compiler-symbols-add-module-aliases-list
            symbols
            rest
            target-module
            alias
            index
            module)]
        [_
          (let
            [next-symbols : CompilerSymbols
              (if (string-eq module target-module)
                (compiler-symbols-add-decl-alias-in-module
                  symbols
                  alias
                  decl
                  index)
                symbols)]
            (compiler-symbols-add-module-aliases-list
              next-symbols
              rest
              target-module
              alias
              (+ index 1)
              module))])]))

(define (compiler-symbols-add-module-aliases
  [symbols : CompilerSymbols]
  [decls : AstDeclList]
  [target-module : String]
  [alias : String]) : CompilerSymbols
  (compiler-symbols-add-module-aliases-list
    symbols
    decls
    target-module
    alias
    0
    ""))

(define (build-compiler-symbol-aliases-list
  [all-decls : AstDeclList]
  [decls : AstDeclList]
  [symbols : CompilerSymbols]) : CompilerSymbols
  (match decls
    [(AstDeclNil) symbols]
    [(AstDeclCons decl rest)
      (let
        [next-symbols : CompilerSymbols
          (match decl
            [(AstDeclImport
                (AstImportSpec
                  _
                  (AstSomeModuleName target-module)
                  (AstSomeImportAlias alias)))
              (compiler-symbols-add-module-aliases
                symbols
                all-decls
                target-module
                alias)]
            [_ symbols])]
        (build-compiler-symbol-aliases-list all-decls rest next-symbols))]))

(define (build-compiler-symbol-list
  [decls : AstDeclList]
  [symbols : CompilerSymbols]
  [index : i64]) : ResultCompilerSymbols
  (build-compiler-symbol-list-in-module decls symbols index ""))

(define (build-compiler-symbol-list-in-module
  [decls : AstDeclList]
  [symbols : CompilerSymbols]
  [index : i64]
  [module : String]) : ResultCompilerSymbols
  (match decls
    [(AstDeclNil) (OkCompilerSymbols symbols)]
    [(AstDeclCons decl rest)
      (match decl
        [(AstDeclImport _)
          (build-compiler-symbol-list-in-module rest symbols index module)]
        [(AstDeclExport _)
          (build-compiler-symbol-list-in-module rest symbols index module)]
        [(AstDeclModule next-module)
          (build-compiler-symbol-list-in-module rest symbols index next-module)]
        [(AstDeclTest _ _ _)
          (build-compiler-symbol-list-in-module rest symbols index module)]
        [_
          (match (compiler-symbols-add-decl-in-module symbols module decl index)
            [(OkCompilerSymbols next-symbols)
              (build-compiler-symbol-list-in-module
                rest
                next-symbols
                (+ index 1)
                module)]
            [(ErrCompilerSymbols message) (ErrCompilerSymbols message)])])]))

(define (build-compiler-symbols [program : AstProgram]) : ResultCompilerSymbols
  (match program
    [(AstProgram decls)
      (match (build-compiler-symbol-list decls (compiler-symbols-empty) 0)
        [(OkCompilerSymbols symbols)
          (OkCompilerSymbols
            (build-compiler-symbol-aliases-list decls decls symbols))]
        [(ErrCompilerSymbols message) (ErrCompilerSymbols message)])]))

(define (build-compiler-symbols-from-source [src : String]) : ResultCompilerSymbols
  (match (parse-ast-source src)
    [(OkAstProgram program) (build-compiler-symbols program)]
    [(ErrAstProgram message) (ErrCompilerSymbols message)]))

(define (compiler-registries-lookup-variant
  [registries : CompilerRegistries]
  [name : String]) : MaybeI64
  (match registries
    [(CompilerRegistries variants _) (compiler-symbol-map-lookup variants name)]))

(define (compiler-registries-lookup-struct-field
  [registries : CompilerRegistries]
  [struct-name : String]
  [field-name : String]) : MaybeI64
  (match registries
    [(CompilerRegistries _ fields)
      (compiler-symbol-map-lookup
        fields
        (compiler-struct-field-key struct-name field-name))]))

(define (compiler-registries-add-variant
  [registries : CompilerRegistries]
  [name : String]
  [enum-index : i64]
  [variant-index : i64]) : ResultCompilerRegistries
  (match registries
    [(CompilerRegistries variants fields)
      (if (compiler-symbol-map-contains? variants name)
        (ErrCompilerRegistries
          (compiler-registries-duplicate-variant-message name))
        (OkCompilerRegistries
          (CompilerRegistries
            (compiler-symbol-map-bind
              variants
              name
              (compiler-registry-make-handle
                (compiler-symbol-kind-enum-variant)
                enum-index
                variant-index))
            fields)))]))

(define (compiler-registries-add-variant-in-module
  [registries : CompilerRegistries]
  [module : String]
  [name : String]
  [enum-index : i64]
  [variant-index : i64]) : ResultCompilerRegistries
  (let
    [key : String (compiler-symbol-module-key module name)]
    [handle : i64
      (compiler-registry-make-handle
        (compiler-symbol-kind-enum-variant)
        enum-index
        variant-index)]
    (match registries
      [(CompilerRegistries variants fields)
        (if (compiler-symbol-map-contains? variants key)
          (ErrCompilerRegistries
            (compiler-registries-duplicate-variant-message key))
          (OkCompilerRegistries
            (compiler-registries-add-variant-alias
              (CompilerRegistries
                (compiler-symbol-map-bind variants key handle)
                fields)
              name
              handle)))])))

(define (compiler-registries-add-field
  [registries : CompilerRegistries]
  [struct-name : String]
  [field-name : String]
  [struct-index : i64]
  [field-index : i64]) : ResultCompilerRegistries
  (match registries
    [(CompilerRegistries variants fields)
      (let
        [key : String (compiler-struct-field-key struct-name field-name)]
        (if (compiler-symbol-map-contains? fields key)
          (ErrCompilerRegistries
            (compiler-registries-duplicate-field-message struct-name field-name))
          (OkCompilerRegistries
            (CompilerRegistries
              variants
              (compiler-symbol-map-bind
                fields
                key
                (compiler-registry-make-handle
                  (compiler-symbol-kind-struct-field)
                  struct-index
                  field-index))))))]))

(define (compiler-registries-add-field-alias
  [registries : CompilerRegistries]
  [struct-name : String]
  [field-name : String]
  [handle : i64]) : CompilerRegistries
  (match registries
    [(CompilerRegistries variants fields)
      (let
        [key : String (compiler-struct-field-key struct-name field-name)]
        (if (compiler-symbol-map-contains? fields key)
          registries
          (CompilerRegistries
            variants
            (compiler-symbol-map-bind fields key handle))))]))

(define (compiler-registries-add-variant-aliases-list
  [registries : CompilerRegistries]
  [alias : String]
  [variants : AstVariantDefList]
  [enum-index : i64]
  [variant-index : i64]) : CompilerRegistries
  (match variants
    [(AstVariantDefNil) registries]
    [(AstVariantDefCons variant rest)
      (match variant
        [(AstVariantDef name _)
          (compiler-registries-add-variant-aliases-list
            (compiler-registries-add-variant-alias
              registries
              (compiler-symbol-module-key alias name)
              (compiler-registry-make-handle
                (compiler-symbol-kind-enum-variant)
                enum-index
                variant-index))
            alias
            rest
            enum-index
            (+ variant-index 1))])]))

(define (compiler-registries-add-field-aliases-list
  [registries : CompilerRegistries]
  [struct-name : String]
  [fields : AstFieldDefList]
  [struct-index : i64]
  [field-index : i64]) : CompilerRegistries
  (match fields
    [(AstFieldDefNil) registries]
    [(AstFieldDefCons field rest)
      (match field
        [(AstFieldDef name _ _)
          (compiler-registries-add-field-aliases-list
            (compiler-registries-add-field-alias
              registries
              struct-name
              name
              (compiler-registry-make-handle
                (compiler-symbol-kind-struct-field)
                struct-index
                field-index))
            struct-name
            rest
            struct-index
            (+ field-index 1))])]))

(define (compiler-registries-add-decl-alias-in-module
  [registries : CompilerRegistries]
  [alias : String]
  [decl : AstDecl]
  [index : i64]) : CompilerRegistries
  (match decl
    [(AstDeclDefEnum _ variants)
      (compiler-registries-add-variant-aliases-list
        registries
        alias
        variants
        index
        0)]
    [(AstDeclDefStruct name _ _ fields)
      (compiler-registries-add-field-aliases-list
        registries
        (compiler-symbol-module-key alias name)
        fields
        index
        0)]
    [(AstDeclComptimeDecl template)
      (compiler-registries-add-decl-alias-in-module
        registries
        alias
        template
        index)]
    [_ registries]))

(define (compiler-registries-add-module-aliases-list
  [registries : CompilerRegistries]
  [decls : AstDeclList]
  [target-module : String]
  [alias : String]
  [index : i64]
  [module : String]) : CompilerRegistries
  (match decls
    [(AstDeclNil) registries]
    [(AstDeclCons decl rest)
      (match decl
        [(AstDeclImport _)
          (compiler-registries-add-module-aliases-list
            registries
            rest
            target-module
            alias
            index
            module)]
        [(AstDeclExport _)
          (compiler-registries-add-module-aliases-list
            registries
            rest
            target-module
            alias
            index
            module)]
        [(AstDeclModule next-module)
          (compiler-registries-add-module-aliases-list
            registries
            rest
            target-module
            alias
            index
            next-module)]
        [(AstDeclTest _ _ _)
          (compiler-registries-add-module-aliases-list
            registries
            rest
            target-module
            alias
            index
            module)]
        [_
          (let
            [next-registries : CompilerRegistries
              (if (string-eq module target-module)
                (compiler-registries-add-decl-alias-in-module
                  registries
                  alias
                  decl
                  index)
                registries)]
            (compiler-registries-add-module-aliases-list
              next-registries
              rest
              target-module
              alias
              (+ index 1)
              module))])]))

(define (compiler-registries-add-module-aliases
  [registries : CompilerRegistries]
  [decls : AstDeclList]
  [target-module : String]
  [alias : String]) : CompilerRegistries
  (compiler-registries-add-module-aliases-list
    registries
    decls
    target-module
    alias
    0
    ""))

(define (build-compiler-registry-aliases-list
  [all-decls : AstDeclList]
  [decls : AstDeclList]
  [registries : CompilerRegistries]) : CompilerRegistries
  (match decls
    [(AstDeclNil) registries]
    [(AstDeclCons decl rest)
      (let
        [next-registries : CompilerRegistries
          (match decl
            [(AstDeclImport
                (AstImportSpec
                  _
                  (AstSomeModuleName target-module)
                  (AstSomeImportAlias alias)))
              (compiler-registries-add-module-aliases
                registries
                all-decls
                target-module
                alias)]
            [_ registries])]
        (build-compiler-registry-aliases-list all-decls rest next-registries))]))

(define (build-compiler-variant-registry-list
  [variants : AstVariantDefList]
  [registries : CompilerRegistries]
  [enum-index : i64]
  [variant-index : i64]) : ResultCompilerRegistries
  (build-compiler-variant-registry-list-in-module
    variants
    registries
    ""
    enum-index
    variant-index))

(define (build-compiler-variant-registry-list-in-module
  [variants : AstVariantDefList]
  [registries : CompilerRegistries]
  [module : String]
  [enum-index : i64]
  [variant-index : i64]) : ResultCompilerRegistries
  (match variants
    [(AstVariantDefNil) (OkCompilerRegistries registries)]
    [(AstVariantDefCons variant rest)
      (match variant
        [(AstVariantDef name _)
          (match (compiler-registries-add-variant-in-module
            registries
            module
            name
            enum-index
            variant-index)
            [(OkCompilerRegistries next-registries)
              (build-compiler-variant-registry-list-in-module
                rest
                next-registries
                module
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
        [(AstFieldDef name _ _)
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
  (build-compiler-registry-list-in-module decls registries index ""))

(define (build-compiler-registry-list-in-module
  [decls : AstDeclList]
  [registries : CompilerRegistries]
  [index : i64]
  [module : String]) : ResultCompilerRegistries
  (match decls
    [(AstDeclNil) (OkCompilerRegistries registries)]
    [(AstDeclCons decl rest)
      (match decl
        [(AstDeclImport _)
          (build-compiler-registry-list-in-module rest registries index module)]
        [(AstDeclExport _)
          (build-compiler-registry-list-in-module rest registries index module)]
        [(AstDeclModule next-module)
          (build-compiler-registry-list-in-module
            rest
            registries
            index
            next-module)]
        [(AstDeclTest _ _ _)
          (build-compiler-registry-list-in-module rest registries index module)]
        [(AstDeclDefEnum _ variants)
          (match (build-compiler-variant-registry-list-in-module
            variants
            registries
            module
            index
            0)
            [(OkCompilerRegistries next-registries)
              (build-compiler-registry-list-in-module
                rest
                next-registries
                (+ index 1)
                module)]
            [(ErrCompilerRegistries message) (ErrCompilerRegistries message)])]
        [(AstDeclDefStruct name _ _ fields)
          (match (build-compiler-field-registry-list
            fields
            registries
            (sym-i64-empty)
            (compiler-symbol-module-key module name)
            index
            0)
            [(OkCompilerRegistries next-registries)
              (build-compiler-registry-list-in-module
                rest
                next-registries
                (+ index 1)
                module)]
            [(ErrCompilerRegistries message) (ErrCompilerRegistries message)])]
        [(AstDeclComptimeDecl template)
          (match template
            [(AstDeclDefEnum _ variants)
              (match (build-compiler-variant-registry-list-in-module
                variants
                registries
                module
                index
                0)
                [(OkCompilerRegistries next-registries)
                  (build-compiler-registry-list-in-module
                    rest
                    next-registries
                    (+ index 1)
                    module)]
                [(ErrCompilerRegistries message)
                  (ErrCompilerRegistries message)])]
            [(AstDeclDefStruct name _ _ fields)
              (match (build-compiler-field-registry-list
                fields
                registries
                (sym-i64-empty)
                (compiler-symbol-module-key module name)
                index
                0)
                [(OkCompilerRegistries next-registries)
                  (build-compiler-registry-list-in-module
                    rest
                    next-registries
                    (+ index 1)
                    module)]
                [(ErrCompilerRegistries message)
                  (ErrCompilerRegistries message)])]
            [_
              (build-compiler-registry-list-in-module
                rest
                registries
                (+ index 1)
                module)])]
        [_
          (build-compiler-registry-list-in-module
            rest
            registries
            (+ index 1)
            module)])]))

(define (build-compiler-registries [program : AstProgram]) : ResultCompilerRegistries
  (match (build-compiler-symbols program)
    [(OkCompilerSymbols _)
      (match program
        [(AstProgram decls)
          (match (build-compiler-registry-list
            decls
            (compiler-registries-empty)
            0)
            [(OkCompilerRegistries registries)
              (OkCompilerRegistries
                (build-compiler-registry-aliases-list decls decls registries))]
            [(ErrCompilerRegistries message) (ErrCompilerRegistries message)])])]
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
        [(AstDeclExport _) (compiler-decl-list-at-index rest target index)]
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
        [(AstFieldDef _ ty _)
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
        [(AstDeclDefStruct _ _ _ fields)
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
  (let
    [x : i64 1]
    [arr (array 1 2 3)]
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
        (compiler-symbols-lookup-value symbols "Point")
        (compiler-symbol-kind-defstruct)
        0)
      (+
        (compiler-symbol-lookup-score
          (compiler-symbols-lookup-type symbols "Maybe")
          (compiler-symbol-kind-defenum)
          1)
        (+
          (compiler-registry-lookup-score
            (compiler-symbols-lookup-value symbols "None")
            (compiler-symbol-kind-enum-variant)
            1
            0)
          (+
            (compiler-registry-lookup-score
              (compiler-symbols-lookup-value symbols "Some")
              (compiler-symbol-kind-enum-variant)
              1
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
                      (compiler-symbols-lookup-type symbols "missing"))))))))))))

(define (compiler-registries-smoke-score
  [program : AstProgram]
  [registries : CompilerRegistries]) : i64
  (let
    [some : MaybeI64 (compiler-registries-lookup-variant registries "Some")]
    [none : MaybeI64 (compiler-registries-lookup-variant registries "None")]
    [x-field : MaybeI64
      (compiler-registries-lookup-struct-field registries "Point" "x")]
    [y-field : MaybeI64
      (compiler-registries-lookup-struct-field registries "Point" "y")]
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

(define (compiler-symbols-macro-source) : String
  "(defmacro (all [first : bool] [rest : bool ...]) : bool first)
(define (main) : i64 0)")

(define (compiler-symbols-duplicate-macro-value-source) : String
  "(defmacro (same) : bool (expr-bool true))
(define same : i64 1)")

(define (compiler-symbols-variant-function-collision-source) : String
  "(defenum A (Foo))
(define (Foo [x : i64]) : i64 x)")

(define (compiler-symbols-variant-define-collision-source) : String
  "(defenum A (Foo))
(define Foo : i64 42)")

(define (compiler-symbols-variant-extern-collision-source) : String
  "(defenum A (Foo))
(extern Foo : (-> i64 i64))")

(define (compiler-symbols-variant-struct-collision-source) : String
  "(defenum A (Foo))
(defstruct Foo (x i64))")

(define (compiler-symbols-struct-function-collision-source) : String
  "(defstruct Point (x i64))
(define (Point [x : i64]) : i64 x)")

(define (compiler-symbols-struct-define-collision-source) : String
  "(defstruct Point (x i64))
(define Point : i64 42)")

(define (compiler-symbols-struct-extern-collision-source) : String
  "(defstruct Point (x i64))
(extern Point : (-> i64 i64))")

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

(define (compiler-symbols-duplicate-value-error-ok?
  [src : String]
  [name : String]) : bool
  (match (build-compiler-symbols-from-source src)
    [(ErrCompilerSymbols message)
      (string-eq message (compiler-symbols-duplicate-value-message name))]
    [(OkCompilerSymbols _) false]))

(define (compiler-symbols-variant-value-collisions-ok?) : bool
  (and
    (compiler-symbols-duplicate-value-error-ok?
      (compiler-symbols-variant-function-collision-source)
      "Foo")
    (and
      (compiler-symbols-duplicate-value-error-ok?
        (compiler-symbols-variant-define-collision-source)
        "Foo")
      (and
        (compiler-symbols-duplicate-value-error-ok?
          (compiler-symbols-variant-extern-collision-source)
          "Foo")
        (compiler-symbols-duplicate-value-error-ok?
          (compiler-symbols-variant-struct-collision-source)
          "Foo")))))

(define (compiler-symbols-struct-value-collisions-ok?) : bool
  (and
    (compiler-symbols-duplicate-value-error-ok?
      (compiler-symbols-struct-function-collision-source)
      "Point")
    (and
      (compiler-symbols-duplicate-value-error-ok?
        (compiler-symbols-struct-define-collision-source)
        "Point")
      (compiler-symbols-duplicate-value-error-ok?
        (compiler-symbols-struct-extern-collision-source)
        "Point"))))

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

(define (compiler-symbols-macro-namespace-ok?) : bool
  (match (build-compiler-symbols-from-source (compiler-symbols-macro-source))
    [(OkCompilerSymbols symbols)
      (and
        (=
          (compiler-symbol-lookup-score
            (compiler-symbols-lookup-macro symbols "all")
            (compiler-symbol-kind-defmacro)
            0)
          1)
        (and
          (=
            (compiler-symbols-miss-score
              (compiler-symbols-lookup-value symbols "all"))
            1)
          (=
            (compiler-symbol-lookup-score
              (compiler-symbols-lookup-value symbols "main")
              (compiler-symbol-kind-function-define)
              1)
            1)))]
    [(ErrCompilerSymbols _) false]))

(define (compiler-symbols-duplicate-macro-value-ok?) : bool
  (match (build-compiler-symbols-from-source
    (compiler-symbols-duplicate-macro-value-source))
    [(ErrCompilerSymbols message)
      (string-eq
        message
        (compiler-symbols-duplicate-macro-value-message "same"))]
    [(OkCompilerSymbols _) false]))

(define (compiler-registry-large-owner-handle-ok?) : bool
  (let
    [handle : i64
      (compiler-registry-make-handle (compiler-symbol-kind-enum-variant) 1234 5)]
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

(define (compiler-symbols-module-scope-source) : String
  "(module left)
(define same : i64 1)
(defenum Maybe (None) (Some i64))
(defstruct Point (x i64))
(module right)
(define same : i64 2)
(defenum Maybe (None) (Some i64))
(defstruct Point (x i64))")

(define (compiler-symbols-module-scope-ok?) : bool
  (match (parse-ast-source (compiler-symbols-module-scope-source))
    [(OkAstProgram program)
      (match (build-compiler-symbols program)
        [(OkCompilerSymbols symbols)
          (match (build-compiler-registries program)
            [(OkCompilerRegistries registries)
              (and
                (=
                  (compiler-symbol-lookup-score
                    (compiler-symbols-lookup-value symbols "left/same")
                    (compiler-symbol-kind-value-define)
                    0)
                  1)
                (and
                  (=
                    (compiler-symbol-lookup-score
                      (compiler-symbols-lookup-value symbols "right/same")
                      (compiler-symbol-kind-value-define)
                      3)
                    1)
                  (and
                    (=
                      (compiler-symbol-lookup-score
                        (compiler-symbols-lookup-type symbols "left/Maybe")
                        (compiler-symbol-kind-defenum)
                        1)
                      1)
                    (and
                      (=
                        (compiler-symbol-lookup-score
                          (compiler-symbols-lookup-type symbols "right/Point")
                          (compiler-symbol-kind-defstruct)
                          5)
                        1)
                      (and
                        (=
                          (compiler-registry-lookup-score
                            (compiler-registries-lookup-variant
                              registries
                              "left/None")
                            (compiler-symbol-kind-enum-variant)
                            1
                            0)
                          1)
                        (and
                          (=
                            (compiler-registry-lookup-score
                              (compiler-registries-lookup-variant
                                registries
                                "right/Some")
                              (compiler-symbol-kind-enum-variant)
                              4
                              1)
                            1)
                          (and
                            (=
                              (compiler-registry-lookup-score
                                (compiler-registries-lookup-struct-field
                                  registries
                                  "left/Point"
                                  "x")
                                (compiler-symbol-kind-struct-field)
                                2
                                0)
                              1)
                            (=
                              (compiler-registry-lookup-score
                                (compiler-registries-lookup-struct-field
                                  registries
                                  "right/Point"
                                  "x")
                                (compiler-symbol-kind-struct-field)
                                5
                                0)
                              1))))))))]
            [(ErrCompilerRegistries _) false])]
        [(ErrCompilerSymbols _) false])]
    [(ErrAstProgram _) false]))

(define (compiler-symbols-import-alias-source) : String
  "(module data)
(define answer : i64 7)
(define (get) : i64 answer)
(defenum Maybe (None) (Some i64))
(defstruct Point (x i64))
(module main)
(import \"data.tl\" module data :as d)
(define (main) : i64 (d/get))")

(define (compiler-symbols-import-alias-ok?) : bool
  (match (parse-ast-source (compiler-symbols-import-alias-source))
    [(OkAstProgram program)
      (match (build-compiler-symbols program)
        [(OkCompilerSymbols symbols)
          (match (build-compiler-registries program)
            [(OkCompilerRegistries registries)
              (and
                (=
                  (compiler-symbol-lookup-score
                    (compiler-symbols-lookup-value symbols "d/get")
                    (compiler-symbol-kind-function-define)
                    1)
                  1)
                (and
                  (=
                    (compiler-symbol-lookup-score
                      (compiler-symbols-lookup-type symbols "d/Point")
                      (compiler-symbol-kind-defstruct)
                      3)
                    1)
                  (and
                    (=
                      (compiler-registry-lookup-score
                        (compiler-registries-lookup-variant registries "d/Some")
                        (compiler-symbol-kind-enum-variant)
                        2
                        1)
                      1)
                    (=
                      (compiler-registry-lookup-score
                        (compiler-registries-lookup-struct-field
                          registries
                          "d/Point"
                          "x")
                        (compiler-symbol-kind-struct-field)
                        3
                        0)
                      1))))]
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
                (= (compiler-symbols-smoke-score symbols) 10)
                (and
                  (= (compiler-registries-smoke-score program registries) 8)
                  (and
                    (compiler-symbols-duplicate-value-ok?)
                    (and
                      (compiler-symbols-duplicate-type-ok?)
                      (and
                        (compiler-symbols-variant-value-collisions-ok?)
                        (and
                          (compiler-symbols-struct-value-collisions-ok?)
                          (and
                            (compiler-registries-duplicate-variant-ok?)
                            (and
                              (compiler-registries-duplicate-field-ok?)
                              (and
                                (compiler-registry-large-owner-handle-ok?)
                                (and
                                  (compiler-symbols-comptime-decl-ok?)
                                  (and
                                    (compiler-symbols-module-scope-ok?)
                                    (and
                                      (compiler-symbols-import-alias-ok?)
                                      (and
                                        (compiler-symbols-macro-namespace-ok?)
                                        (compiler-symbols-duplicate-macro-value-ok?))))))))))))))
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