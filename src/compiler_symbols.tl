;; compiler_symbols.tl - Top-level compiler symbol table over AstProgram (#405).
;;
;; Handles are packed as kind * stride + declaration index, where index is the
;; source-order position among supported declarations. Import declarations have
;; no top-level symbol name here and do not consume an index.
(import "../stdlib/io.tl")

(import "compiler_parse_core.tl")

(import "sym_i64_env.tl")

(import "../stdlib/hashmap.tl")

(import "../stdlib/string.tl")

(defenum CompilerSymbols
  (CompilerSymbols I64I64Map I64I64Map I64I64Map (Array AstDecl) (Array String)))

(defenum ResultCompilerSymbols
  (OkCompilerSymbols CompilerSymbols)
  (ErrCompilerSymbols String))

(defenum CompilerMaybeString
  (CompilerNoString)
  (CompilerSomeString String))

(defenum CompilerQualifiedName
  (CompilerQualifiedName i64 i64))

(defenum CompilerRegistries
  (CompilerRegistries I64I64Map I64I64Map))

(defenum ResultCompilerRegistries
  (OkCompilerRegistries CompilerRegistries)
  (ErrCompilerRegistries String))

(defenum CompilerExports
  (CompilerExports I64I64Map))

(defenum ResultCompilerExports
  (OkCompilerExports CompilerExports)
  (ErrCompilerExports String))

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

(define (compiler-symbol-kind-defdispatch) : i64
  9)

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

(define (compiler-symbol-map-empty) : I64I64Map
  (i64-i64-map-with-capacity 256))

(define (compiler-symbol-map-lookup-id [map : I64I64Map] [name-id : i64]) : MaybeI64
  (match (i64-i64-map-get map name-id)
    [(I64I64MapFound value) (SomeI64 value)]
    [(I64I64MapMissing) NoneI64]))

(define (compiler-symbol-map-lookup [map : I64I64Map] [name : String]) : MaybeI64
  (compiler-symbol-map-lookup-id map (compiler-symbol-name-key-id name)))

(define (compiler-symbol-map-contains-id? [map : I64I64Map] [name-id : i64]) : bool
  (match (compiler-symbol-map-lookup-id map name-id)
    [(SomeI64 _) true]
    [(NoneI64) false]))

(define (compiler-symbol-map-contains? [map : I64I64Map] [name : String]) : bool
  (compiler-symbol-map-contains-id? map (compiler-symbol-name-key-id name)))

(define (compiler-symbol-map-bind-id
  [map : I64I64Map]
  [name-id : i64]
  [handle : i64]) : I64I64Map
  (i64-i64-map-put map name-id handle))

(define (compiler-symbol-map-bind
  [map : I64I64Map]
  [name : String]
  [handle : i64]) : I64I64Map
  (compiler-symbol-map-bind-id map (compiler-symbol-name-key-id name) handle))

(define (compiler-decl-list-index-count [decls : AstDeclList]) : i64
  (match decls
    [(AstDeclNil) 0]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclImport _) (compiler-decl-list-index-count rest)]
          [(AstDeclExport _) (compiler-decl-list-index-count rest)]
          [(AstDeclModule _) (compiler-decl-list-index-count rest)]
          [(AstDeclTest _ _ _) (compiler-decl-list-index-count rest)]
          [_ (+ 1 (compiler-decl-list-index-count rest))]))]))

(define (compiler-symbols-empty-with-decls [decl-count : i64]) : CompilerSymbols
  (CompilerSymbols
    (compiler-symbol-map-empty)
    (compiler-symbol-map-empty)
    (compiler-symbol-map-empty)
    (make-array AstDecl decl-count)
    (make-array String decl-count)))

(define (compiler-symbols-empty) : CompilerSymbols
  (compiler-symbols-empty-with-decls 0))

(define (compiler-registries-empty) : CompilerRegistries
  (CompilerRegistries (compiler-symbol-map-empty) (compiler-symbol-map-empty)))

(define (compiler-exports-empty) : CompilerExports
  (CompilerExports (compiler-symbol-map-empty)))

(define (compiler-exports-lookup
  [exports : CompilerExports]
  [kind : String]
  [module : String]
  [name : String]) : MaybeI64
  (compiler-exports-lookup-id
    exports
    (intern kind)
    (intern module)
    (intern name)))

(define (compiler-exports-lookup-id
  [exports : CompilerExports]
  [kind-id : i64]
  [module-id : i64]
  [name-id : i64]) : MaybeI64
  (match exports
    [(CompilerExports exported)
      (compiler-symbol-map-lookup-id
        exported
        (compiler-export-key-id-by-id module-id kind-id name-id))]))

(define (compiler-exports-add
  [exports : CompilerExports]
  [kind : String]
  [module : String]
  [name : String]
  [handle : i64]) : ResultCompilerExports
  (compiler-exports-add-id
    exports
    (intern kind)
    (intern module)
    (intern name)
    kind
    module
    name
    handle))

(define (compiler-exports-add-id
  [exports : CompilerExports]
  [kind-id : i64]
  [module-id : i64]
  [name-id : i64]
  [kind : String]
  [module : String]
  [name : String]
  [handle : i64]) : ResultCompilerExports
  (match exports
    [(CompilerExports exported)
      (let
        [key-id : i64 (compiler-export-key-id-by-id module-id kind-id name-id)]
        (match (compiler-symbol-map-lookup-id exported key-id)
          [(SomeI64 existing)
            (if (= existing handle)
              (OkCompilerExports exports)
              (ErrCompilerExports
                (compiler-export-duplicate-message kind module name)))]
          [(NoneI64)
            (OkCompilerExports
              (CompilerExports
                (compiler-symbol-map-bind-id exported key-id handle)))]))]))

(define (compiler-symbols-lookup-value
  [symbols : CompilerSymbols]
  [name : String]) : MaybeI64
  (compiler-symbols-lookup-value-id symbols (intern name)))

(define (compiler-symbols-lookup-value-id
  [symbols : CompilerSymbols]
  [name-id : i64]) : MaybeI64
  (match symbols
    [(CompilerSymbols values _ _ _ _)
      (compiler-symbol-map-lookup-id
        values
        (compiler-symbol-name-id-key name-id))]))

(define (compiler-symbols-lookup-type
  [symbols : CompilerSymbols]
  [name : String]) : MaybeI64
  (compiler-symbols-lookup-type-id symbols (intern name)))

(define (compiler-symbols-lookup-type-id
  [symbols : CompilerSymbols]
  [name-id : i64]) : MaybeI64
  (match symbols
    [(CompilerSymbols _ types _ _ _)
      (compiler-symbol-map-lookup-id
        types
        (compiler-symbol-name-id-key name-id))]))

(define (compiler-symbols-lookup-macro
  [symbols : CompilerSymbols]
  [name : String]) : MaybeI64
  (compiler-symbols-lookup-macro-id symbols (intern name)))

(define (compiler-symbols-lookup-macro-id
  [symbols : CompilerSymbols]
  [name-id : i64]) : MaybeI64
  (match symbols
    [(CompilerSymbols _ _ macros _ _)
      (compiler-symbol-map-lookup-id
        macros
        (compiler-symbol-name-id-key name-id))]))

(define (compiler-symbols-decls [symbols : CompilerSymbols]) : (Array AstDecl)
  (match symbols
    [(CompilerSymbols _ _ _ decls _) decls]))

(define (compiler-symbols-owner-names [symbols : CompilerSymbols]) : (Array
    String)
  (match symbols
    [(CompilerSymbols _ _ _ _ owner-names) owner-names]))

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

(define (compiler-struct-field-key [struct-name : String] [field-name : String]) : String
  ;; Flat field registry key. Field names may repeat across structs because the
  ;; struct name is part of the key.
  (string-append (string-append struct-name ".") field-name))

(define (compiler-composite-pair-key-id [left-id : i64] [right-id : i64]) : i64
  (+ (intern-capacity) (+ (* left-id (intern-capacity)) right-id)))

(define (compiler-composite-triple-key-id
  [left-id : i64]
  [middle-id : i64]
  [right-id : i64]) : i64
  (let
    [stride : i64 (intern-capacity)]
    [stride2 : i64 (* (intern-capacity) (intern-capacity))]
    (+
      (+ stride stride2)
      (+ (* left-id stride2) (+ (* middle-id stride) right-id)))))

(define (compiler-struct-field-key-id-by-id
  [struct-name-id : i64]
  [field-name-id : i64]) : i64
  (if (intern-qualified? struct-name-id)
    (compiler-composite-triple-key-id
      (intern-qualified-module-id struct-name-id)
      (intern-qualified-base-id struct-name-id)
      field-name-id)
    (compiler-composite-pair-key-id struct-name-id field-name-id)))

(define (compiler-struct-field-key-id
  [struct-name : String]
  [field-name : String]) : i64
  (compiler-struct-field-key-id-by-id (intern struct-name) (intern field-name)))

(define (compiler-struct-field-key-id-in-module-by-id
  [module-id : i64]
  [struct-name-id : i64]
  [field-name-id : i64]) : i64
  (if (or (< module-id 0) (= (string-length (intern-str module-id)) 0))
    (compiler-composite-pair-key-id struct-name-id field-name-id)
    (compiler-composite-triple-key-id module-id struct-name-id field-name-id)))

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

(define (compiler-enum-qualified-variant-name
  [enum-name : String]
  [variant-name : String]) : String
  (string-append enum-name (string-append "." variant-name)))

(define (compiler-qualified-name [module : String] [name : String]) : CompilerQualifiedName
  (CompilerQualifiedName (intern module) (intern name)))

(define (compiler-symbol-module-key-id-by-id [module-id : i64] [name-id : i64]) : i64
  (if (or (< module-id 0) (= (string-length (intern-str module-id)) 0))
    name-id
    (compiler-composite-pair-key-id module-id name-id)))

(define (compiler-symbol-module-key-id [module : String] [name : String]) : i64
  (compiler-symbol-module-key-id-by-id (intern module) (intern name)))

(define (compiler-symbol-module-key-id-by-name-id
  [module : String]
  [name-id : i64]) : i64
  (compiler-symbol-module-key-id-by-id (intern module) name-id))

(define (compiler-symbol-name-id-key [name-id : i64]) : i64
  (if (intern-qualified? name-id)
    (compiler-composite-pair-key-id
      (intern-qualified-module-id name-id)
      (intern-qualified-base-id name-id))
    name-id))

(define (compiler-symbol-name-key-id [name : String]) : i64
  (compiler-symbol-name-id-key (intern name)))

(define (compiler-qualified-name-key-id [name : CompilerQualifiedName]) : i64
  (match name
    [(CompilerQualifiedName module-id base-id)
      (compiler-symbol-module-key-id-by-id module-id base-id)]))

(define (compiler-export-kind-value) : String
  "value")

(define (compiler-export-kind-type) : String
  "type")

(define (compiler-export-kind-macro) : String
  "macro")

(define (compiler-export-kind-constructor) : String
  "constructor")

(define (compiler-export-kind-field) : String
  "field")

(define (compiler-export-kind-variant) : String
  "variant")

(define (compiler-export-key [module : String] [kind : String] [name : String]) : String
  (compiler-symbol-module-key
    module
    (string-append kind (string-append ":" name))))

(define (compiler-export-key-id-by-id
  [module-id : i64]
  [kind-id : i64]
  [name-id : i64]) : i64
  (compiler-composite-triple-key-id module-id kind-id name-id))

(define (compiler-export-key-id
  [module : String]
  [kind : String]
  [name : String]) : i64
  (compiler-export-key-id-by-id (intern module) (intern kind) (intern name)))

(define (compiler-export-field-name [type-name : String] [field-name : String]) : String
  (compiler-struct-field-key type-name field-name))

(define (compiler-export-display-name [module : String] [name : String]) : String
  (compiler-symbol-module-key module name))

(define (compiler-export-unknown-message
  [kind : String]
  [module : String]
  [name : String]) : String
  (string-append
    "symbols: cannot export unknown "
    (string-append
      kind
      (string-append " " (compiler-export-display-name module name)))))

(define (compiler-export-namespace-message
  [kind : String]
  [module : String]
  [name : String]) : String
  (string-append
    "symbols: export namespace mismatch for "
    (string-append
      kind
      (string-append " " (compiler-export-display-name module name)))))

(define (compiler-export-duplicate-message
  [kind : String]
  [module : String]
  [name : String]) : String
  (string-append
    "symbols: duplicate export "
    (string-append
      kind
      (string-append " " (compiler-export-display-name module name)))))

(define (compiler-symbols-add-value-alias
  [symbols : CompilerSymbols]
  [name : String]
  [handle : i64]) : CompilerSymbols
  (match symbols
    [(CompilerSymbols values types macros decls owner-names)
      (if (compiler-symbol-map-contains? values name)
        symbols
        (CompilerSymbols
          (compiler-symbol-map-bind values name handle)
          types
          macros
          decls
          owner-names))]))

(define (compiler-symbols-add-type-alias
  [symbols : CompilerSymbols]
  [name : String]
  [handle : i64]) : CompilerSymbols
  (match symbols
    [(CompilerSymbols values types macros decls owner-names)
      (if (compiler-symbol-map-contains? types name)
        symbols
        (CompilerSymbols
          values
          (compiler-symbol-map-bind types name handle)
          macros
          decls
          owner-names))]))

(define (compiler-symbols-add-macro-alias
  [symbols : CompilerSymbols]
  [name : String]
  [handle : i64]) : CompilerSymbols
  (match symbols
    [(CompilerSymbols values types macros decls owner-names)
      (if (compiler-symbol-map-contains? macros name)
        symbols
        (CompilerSymbols
          values
          types
          (compiler-symbol-map-bind macros name handle)
          decls
          owner-names))]))

(define (compiler-symbols-remove-macro-alias-if-handle
  [symbols : CompilerSymbols]
  [name : String]
  [handle : i64]) : CompilerSymbols
  (match symbols
    [(CompilerSymbols values types macros decls owner-names)
      (match (compiler-symbol-map-lookup macros name)
        [(SomeI64 existing)
          (if (= existing handle)
            (match (i64-i64-map-remove
              macros
              (compiler-symbol-name-key-id name))
              [(I64I64MapRemoveOk next-macros)
                (CompilerSymbols values types next-macros decls owner-names)]
              [(I64I64MapRemoveMissing _) symbols])
            symbols)]
        [(NoneI64) symbols])]))

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
  (compiler-symbols-add-value-id
    symbols
    (compiler-symbol-name-key-id name)
    name
    handle))

(define (compiler-symbols-add-value-id
  [symbols : CompilerSymbols]
  [name-id : i64]
  [display-name : String]
  [handle : i64]) : ResultCompilerSymbols
  (match symbols
    [(CompilerSymbols values types macros decls owner-names)
      (if (compiler-symbol-map-contains-id? values name-id)
        (ErrCompilerSymbols
          (compiler-symbols-duplicate-value-message display-name))
        (if (compiler-symbol-map-contains-id? macros name-id)
          (ErrCompilerSymbols
            (compiler-symbols-duplicate-macro-value-message display-name))
          (OkCompilerSymbols
            (CompilerSymbols
              (compiler-symbol-map-bind-id values name-id handle)
              types
              macros
              decls
              owner-names))))]))

(define (compiler-symbols-add-variant-value
  [symbols : CompilerSymbols]
  [name : String]
  [handle : i64]) : ResultCompilerSymbols
  (compiler-symbols-add-variant-value-id
    symbols
    (compiler-symbol-name-key-id name)
    name
    handle))

(define (compiler-symbols-add-variant-value-id
  [symbols : CompilerSymbols]
  [name-id : i64]
  [display-name : String]
  [handle : i64]) : ResultCompilerSymbols
  (match symbols
    [(CompilerSymbols values types macros decls owner-names)
      (match (compiler-symbol-map-lookup-id values name-id)
        [(SomeI64 existing)
          (if (=
            (compiler-symbol-handle-kind existing)
            (compiler-symbol-kind-enum-variant))
            (ErrCompilerSymbols
              (compiler-registries-duplicate-variant-message display-name))
            (ErrCompilerSymbols
              (compiler-symbols-duplicate-value-message display-name)))]
        [(NoneI64)
          (if (compiler-symbol-map-contains-id? macros name-id)
            (ErrCompilerSymbols
              (compiler-symbols-duplicate-macro-value-message display-name))
            (OkCompilerSymbols
              (CompilerSymbols
                (compiler-symbol-map-bind-id values name-id handle)
                types
                macros
                decls
                owner-names)))])]))

(define (compiler-symbols-add-variant-flat-value-alias-id
  [symbols : CompilerSymbols]
  [name-id : i64]
  [display-name : String]
  [handle : i64]) : ResultCompilerSymbols
  (match symbols
    [(CompilerSymbols values types macros decls owner-names)
      (match (compiler-symbol-map-lookup-id values name-id)
        [(SomeI64 existing)
          (if (=
            (compiler-symbol-handle-kind existing)
            (compiler-symbol-kind-enum-variant))
            (OkCompilerSymbols symbols)
            (ErrCompilerSymbols
              (compiler-symbols-duplicate-value-message display-name)))]
        [(NoneI64)
          (if (compiler-symbol-map-contains-id? macros name-id)
            (ErrCompilerSymbols
              (compiler-symbols-duplicate-macro-value-message display-name))
            (OkCompilerSymbols
              (CompilerSymbols
                (compiler-symbol-map-bind-id values name-id handle)
                types
                macros
                decls
                owner-names)))])]))

(define (compiler-symbols-add-type
  [symbols : CompilerSymbols]
  [name : String]
  [handle : i64]) : ResultCompilerSymbols
  (compiler-symbols-add-type-id
    symbols
    (compiler-symbol-name-key-id name)
    name
    handle))

(define (compiler-symbols-add-type-id
  [symbols : CompilerSymbols]
  [name-id : i64]
  [display-name : String]
  [handle : i64]) : ResultCompilerSymbols
  (match symbols
    [(CompilerSymbols values types macros decls owner-names)
      (if (compiler-symbol-map-contains-id? types name-id)
        (ErrCompilerSymbols
          (compiler-symbols-duplicate-type-message display-name))
        (OkCompilerSymbols
          (CompilerSymbols
            values
            (compiler-symbol-map-bind-id types name-id handle)
            macros
            decls
            owner-names)))]))

(define (compiler-symbols-add-macro
  [symbols : CompilerSymbols]
  [name : String]
  [handle : i64]) : ResultCompilerSymbols
  (compiler-symbols-add-macro-id
    symbols
    (compiler-symbol-name-key-id name)
    name
    handle))

(define (compiler-symbols-add-macro-id
  [symbols : CompilerSymbols]
  [name-id : i64]
  [display-name : String]
  [handle : i64]) : ResultCompilerSymbols
  (match symbols
    [(CompilerSymbols values types macros decls owner-names)
      (if (compiler-symbol-map-contains-id? macros name-id)
        (ErrCompilerSymbols
          (compiler-symbols-duplicate-macro-message display-name))
        (if (compiler-symbol-map-contains-id? values name-id)
          (ErrCompilerSymbols
            (compiler-symbols-duplicate-macro-value-message display-name))
          (OkCompilerSymbols
            (CompilerSymbols
              values
              types
              (compiler-symbol-map-bind-id macros name-id handle)
              decls
              owner-names))))]))

(define (compiler-symbols-add-value-in-module
  [symbols : CompilerSymbols]
  [module : String]
  [name : String]
  [handle : i64]) : ResultCompilerSymbols
  (let
    [key-id : i64 (compiler-symbol-module-key-id module name)]
    [display-name : String (compiler-symbol-module-key module name)]
    (match (compiler-symbols-add-value-id symbols key-id display-name handle)
      [(OkCompilerSymbols next)
        (OkCompilerSymbols (compiler-symbols-add-value-alias next name handle))]
      [(ErrCompilerSymbols message) (ErrCompilerSymbols message)])))

(define (compiler-symbols-add-type-in-module
  [symbols : CompilerSymbols]
  [module : String]
  [name : String]
  [handle : i64]) : ResultCompilerSymbols
  (let
    [key-id : i64 (compiler-symbol-module-key-id module name)]
    [display-name : String (compiler-symbol-module-key module name)]
    (match (compiler-symbols-add-type-id symbols key-id display-name handle)
      [(OkCompilerSymbols next)
        (OkCompilerSymbols (compiler-symbols-add-type-alias next name handle))]
      [(ErrCompilerSymbols message) (ErrCompilerSymbols message)])))

(define (compiler-symbols-add-variant-value-in-module
  [symbols : CompilerSymbols]
  [module : String]
  [enum-name : String]
  [name : String]
  [enum-index : i64]
  [variant-index : i64]) : ResultCompilerSymbols
  (let
    [qualified-name : String
      (compiler-enum-qualified-variant-name enum-name name)]
    [qualified-key-id : i64
      (compiler-symbol-module-key-id module qualified-name)]
    [qualified-display-name : String
      (compiler-symbol-module-key module qualified-name)]
    [flat-key-id : i64 (compiler-symbol-module-key-id module name)]
    [flat-display-name : String (compiler-symbol-module-key module name)]
    [handle : i64
      (compiler-registry-make-handle
        (compiler-symbol-kind-enum-variant)
        enum-index
        variant-index)]
    (match (compiler-symbols-add-variant-value-id
      symbols
      qualified-key-id
      qualified-display-name
      handle)
      [(OkCompilerSymbols next)
        (match (compiler-symbols-add-variant-flat-value-alias-id
          next
          flat-key-id
          flat-display-name
          handle)
          [(OkCompilerSymbols with-flat)
            (OkCompilerSymbols
              (compiler-symbols-add-value-alias with-flat name handle))]
          [(ErrCompilerSymbols message) (ErrCompilerSymbols message)])]
      [(ErrCompilerSymbols message) (ErrCompilerSymbols message)])))

(define (compiler-symbols-add-variant-values-in-module
  [symbols : CompilerSymbols]
  [module : String]
  [enum-name : String]
  [variants : AstVariantDefList]
  [enum-index : i64]
  [variant-index : i64]) : ResultCompilerSymbols
  (match variants
    [(AstVariantDefNil) (OkCompilerSymbols symbols)]
    [(AstVariantDefCons variant rest)
      (let
        [rest : AstVariantDefList (box-get rest)]
        (match variant
          [(AstVariantDef name _ _)
            (match (compiler-symbols-add-variant-value-in-module
              symbols
              module
              enum-name
              (intern-str name)
              enum-index
              variant-index)
              [(OkCompilerSymbols next)
                (compiler-symbols-add-variant-values-in-module
                  next
                  module
                  enum-name
                  rest
                  enum-index
                  (+ variant-index 1))]
              [(ErrCompilerSymbols message) (ErrCompilerSymbols message)])]))]))

(define (compiler-symbols-add-macro-in-module
  [symbols : CompilerSymbols]
  [module : String]
  [name : String]
  [handle : i64]) : ResultCompilerSymbols
  (let
    [key-id : i64 (compiler-symbol-module-key-id module name)]
    [display-name : String (compiler-symbol-module-key module name)]
    (match (compiler-symbols-add-macro-id symbols key-id display-name handle)
      [(OkCompilerSymbols next)
        (OkCompilerSymbols (compiler-symbols-add-macro-alias next name handle))]
      [(ErrCompilerSymbols message) (ErrCompilerSymbols message)])))

(define (compiler-export-value-handle? [handle : i64]) : bool
  (let
    [kind : i64 (compiler-symbol-handle-kind handle)]
    (or
      (= kind (compiler-symbol-kind-value-define))
      (= kind (compiler-symbol-kind-function-define))
      (= kind (compiler-symbol-kind-extern))
      (= kind (compiler-symbol-kind-defdispatch)))))

(define (compiler-export-type-handle? [handle : i64]) : bool
  (let
    [kind : i64 (compiler-symbol-handle-kind handle)]
    (or
      (= kind (compiler-symbol-kind-defenum))
      (= kind (compiler-symbol-kind-defstruct)))))

(define (compiler-export-constructor-handle? [handle : i64]) : bool
  (= (compiler-symbol-handle-kind handle) (compiler-symbol-kind-defstruct)))

(define (compiler-export-variant-handle? [handle : i64]) : bool
  (= (compiler-symbol-handle-kind handle) (compiler-symbol-kind-enum-variant)))

(define (compiler-export-field-handle? [handle : i64]) : bool
  (= (compiler-symbol-handle-kind handle) (compiler-symbol-kind-struct-field)))

(define (compiler-symbols-lookup-value-in-module
  [symbols : CompilerSymbols]
  [module : String]
  [name : String]) : MaybeI64
  (compiler-symbols-lookup-value-in-module-id
    symbols
    (intern module)
    (intern name)))

(define (compiler-symbols-lookup-value-in-module-id
  [symbols : CompilerSymbols]
  [module-id : i64]
  [name-id : i64]) : MaybeI64
  (match symbols
    [(CompilerSymbols values _ _ _ _)
      (compiler-symbol-map-lookup-id
        values
        (compiler-symbol-module-key-id-by-id module-id name-id))]))

(define (compiler-symbols-lookup-type-in-module
  [symbols : CompilerSymbols]
  [module : String]
  [name : String]) : MaybeI64
  (compiler-symbols-lookup-type-in-module-id
    symbols
    (intern module)
    (intern name)))

(define (compiler-symbols-lookup-type-in-module-id
  [symbols : CompilerSymbols]
  [module-id : i64]
  [name-id : i64]) : MaybeI64
  (match symbols
    [(CompilerSymbols _ types _ _ _)
      (compiler-symbol-map-lookup-id
        types
        (compiler-symbol-module-key-id-by-id module-id name-id))]))

(define (compiler-symbols-lookup-macro-in-module
  [symbols : CompilerSymbols]
  [module : String]
  [name : String]) : MaybeI64
  (compiler-symbols-lookup-macro-in-module-id
    symbols
    (intern module)
    (intern name)))

(define (compiler-symbols-lookup-macro-in-module-id
  [symbols : CompilerSymbols]
  [module-id : i64]
  [name-id : i64]) : MaybeI64
  (match symbols
    [(CompilerSymbols _ _ macros _ _)
      (compiler-symbol-map-lookup-id
        macros
        (compiler-symbol-module-key-id-by-id module-id name-id))]))

(define (compiler-registries-lookup-field-in-module
  [registries : CompilerRegistries]
  [module : String]
  [type-name : String]
  [field-name : String]) : MaybeI64
  (compiler-registries-lookup-field-in-module-id
    registries
    (intern module)
    (intern type-name)
    (intern field-name)))

(define (compiler-registries-lookup-field-in-module-id
  [registries : CompilerRegistries]
  [module-id : i64]
  [type-name-id : i64]
  [field-name-id : i64]) : MaybeI64
  (match registries
    [(CompilerRegistries _ fields)
      (compiler-symbol-map-lookup-id
        fields
        (compiler-struct-field-key-id-in-module-by-id
          module-id
          type-name-id
          field-name-id))]))

(define (compiler-export-type-or-macro-present?
  [symbols : CompilerSymbols]
  [module : String]
  [name : String]) : bool
  (match (compiler-symbols-lookup-type-in-module symbols module name)
    [(SomeI64 _) true]
    [(NoneI64)
      (match (compiler-symbols-lookup-macro-in-module symbols module name)
        [(SomeI64 _) true]
        [(NoneI64) false])]))

(define (compiler-export-value-or-macro-present?
  [symbols : CompilerSymbols]
  [module : String]
  [name : String]) : bool
  (match (compiler-symbols-lookup-value-in-module symbols module name)
    [(SomeI64 _) true]
    [(NoneI64)
      (match (compiler-symbols-lookup-macro-in-module symbols module name)
        [(SomeI64 _) true]
        [(NoneI64) false])]))

(define (compiler-export-value-or-type-present?
  [symbols : CompilerSymbols]
  [module : String]
  [name : String]) : bool
  (match (compiler-symbols-lookup-value-in-module symbols module name)
    [(SomeI64 _) true]
    [(NoneI64)
      (match (compiler-symbols-lookup-type-in-module symbols module name)
        [(SomeI64 _) true]
        [(NoneI64) false])]))

(define (compiler-exports-add-value-item
  [exports : CompilerExports]
  [symbols : CompilerSymbols]
  [module : String]
  [name : String]) : ResultCompilerExports
  (match (compiler-symbols-lookup-value-in-module symbols module name)
    [(SomeI64 handle)
      (if (compiler-export-value-handle? handle)
        (compiler-exports-add
          exports
          (compiler-export-kind-value)
          module
          name
          handle)
        (ErrCompilerExports
          (compiler-export-namespace-message
            (compiler-export-kind-value)
            module
            name)))]
    [(NoneI64)
      (if (compiler-export-type-or-macro-present? symbols module name)
        (ErrCompilerExports
          (compiler-export-namespace-message
            (compiler-export-kind-value)
            module
            name))
        (ErrCompilerExports
          (compiler-export-unknown-message
            (compiler-export-kind-value)
            module
            name)))]))

(define (compiler-exports-add-type-item
  [exports : CompilerExports]
  [symbols : CompilerSymbols]
  [module : String]
  [name : String]) : ResultCompilerExports
  (match (compiler-symbols-lookup-type-in-module symbols module name)
    [(SomeI64 handle)
      (if (compiler-export-type-handle? handle)
        (compiler-exports-add
          exports
          (compiler-export-kind-type)
          module
          name
          handle)
        (ErrCompilerExports
          (compiler-export-namespace-message
            (compiler-export-kind-type)
            module
            name)))]
    [(NoneI64)
      (if (compiler-export-value-or-macro-present? symbols module name)
        (ErrCompilerExports
          (compiler-export-namespace-message
            (compiler-export-kind-type)
            module
            name))
        (ErrCompilerExports
          (compiler-export-unknown-message
            (compiler-export-kind-type)
            module
            name)))]))

(define (compiler-exports-add-macro-item
  [exports : CompilerExports]
  [symbols : CompilerSymbols]
  [module : String]
  [name : String]) : ResultCompilerExports
  (match (compiler-symbols-lookup-macro-in-module symbols module name)
    [(SomeI64 handle)
      (compiler-exports-add
        exports
        (compiler-export-kind-macro)
        module
        name
        handle)]
    [(NoneI64)
      (if (compiler-export-value-or-type-present? symbols module name)
        (ErrCompilerExports
          (compiler-export-namespace-message
            (compiler-export-kind-macro)
            module
            name))
        (ErrCompilerExports
          (compiler-export-unknown-message
            (compiler-export-kind-macro)
            module
            name)))]))

(define (compiler-exports-add-constructor-item
  [exports : CompilerExports]
  [symbols : CompilerSymbols]
  [module : String]
  [name : String]) : ResultCompilerExports
  (match (compiler-symbols-lookup-value-in-module symbols module name)
    [(SomeI64 handle)
      (if (compiler-export-constructor-handle? handle)
        (compiler-exports-add
          exports
          (compiler-export-kind-constructor)
          module
          name
          handle)
        (ErrCompilerExports
          (compiler-export-namespace-message
            (compiler-export-kind-constructor)
            module
            name)))]
    [(NoneI64)
      (if (compiler-export-type-or-macro-present? symbols module name)
        (ErrCompilerExports
          (compiler-export-namespace-message
            (compiler-export-kind-constructor)
            module
            name))
        (ErrCompilerExports
          (compiler-export-unknown-message
            (compiler-export-kind-constructor)
            module
            name)))]))

(define (compiler-exports-variant-qualified-name
  [symbols : CompilerSymbols]
  [handle : i64]
  [variant-name : String]) : CompilerMaybeString
  (match (compiler-symbols-owner-name-at-index
    symbols
    (compiler-registry-handle-owner-index handle))
    [(CompilerSomeString owner)
      (CompilerSomeString
        (compiler-enum-qualified-variant-name
          (intern-name-base owner)
          variant-name))]
    [(CompilerNoString) (CompilerNoString)]))

(define (compiler-exports-add-qualified-variant-alias
  [exports : CompilerExports]
  [symbols : CompilerSymbols]
  [module : String]
  [name : String]
  [handle : i64]) : ResultCompilerExports
  (if (intern-name-dotted? name)
    (OkCompilerExports exports)
    (match (compiler-exports-variant-qualified-name symbols handle name)
      [(CompilerSomeString qualified-name)
        (compiler-exports-add
          exports
          (compiler-export-kind-variant)
          module
          qualified-name
          handle)]
      [(CompilerNoString) (OkCompilerExports exports)])))

(define (compiler-exports-add-variant-item
  [exports : CompilerExports]
  [symbols : CompilerSymbols]
  [owner-symbols : CompilerSymbols]
  [module : String]
  [name : String]) : ResultCompilerExports
  (match (compiler-symbols-lookup-value-in-module symbols module name)
    [(SomeI64 handle)
      (if (compiler-export-variant-handle? handle)
        (match (compiler-exports-add
          exports
          (compiler-export-kind-variant)
          module
          name
          handle)
          [(OkCompilerExports next)
            (compiler-exports-add-qualified-variant-alias
              next
              owner-symbols
              module
              name
              handle)]
          [(ErrCompilerExports message) (ErrCompilerExports message)])
        (ErrCompilerExports
          (compiler-export-namespace-message
            (compiler-export-kind-variant)
            module
            name)))]
    [(NoneI64)
      (if (compiler-export-type-or-macro-present? symbols module name)
        (ErrCompilerExports
          (compiler-export-namespace-message
            (compiler-export-kind-variant)
            module
            name))
        (ErrCompilerExports
          (compiler-export-unknown-message
            (compiler-export-kind-variant)
            module
            name)))]))

(define (compiler-exports-add-field-item
  [exports : CompilerExports]
  [symbols : CompilerSymbols]
  [registries : CompilerRegistries]
  [module : String]
  [type-name : String]
  [field-name : String]) : ResultCompilerExports
  (let
    [display-name : String (compiler-export-field-name type-name field-name)]
    (match (compiler-symbols-lookup-type-in-module symbols module type-name)
      [(SomeI64 type-handle)
        (if (compiler-export-constructor-handle? type-handle)
          (match (compiler-registries-lookup-field-in-module
            registries
            module
            type-name
            field-name)
            [(SomeI64 handle)
              (if (compiler-export-field-handle? handle)
                (compiler-exports-add
                  exports
                  (compiler-export-kind-field)
                  module
                  display-name
                  handle)
                (ErrCompilerExports
                  (compiler-export-namespace-message
                    (compiler-export-kind-field)
                    module
                    display-name)))]
            [(NoneI64)
              (ErrCompilerExports
                (compiler-export-unknown-message
                  (compiler-export-kind-field)
                  module
                  display-name))])
          (ErrCompilerExports
            (compiler-export-namespace-message
              (compiler-export-kind-field)
              module
              display-name)))]
      [(NoneI64)
        (ErrCompilerExports
          (compiler-export-unknown-message
            (compiler-export-kind-field)
            module
            display-name))])))

(define (compiler-symbols-add-decl
  [symbols : CompilerSymbols]
  [decl : AstDecl]
  [index : i64]) : ResultCompilerSymbols
  (compiler-symbols-add-decl-in-module symbols "" decl index))

(define (compiler-symbols-generated-meta-suffix [meta : AstGeneratedDeclMeta]) : String
  (match meta
    [(AstSomeGeneratedDeclMeta generator item _ key)
      (if (> (string-length key) 0)
        (string-append " (generated identity: " (string-append key ")"))
        (string-append
          " (generated declaration: "
          (string-append
            item
            (string-append " from " (string-append generator ")")))))]
    [(AstNoGeneratedDeclMeta) ""]))

(define (compiler-symbols-with-generated-context
  [message : String]
  [meta : AstGeneratedDeclMeta]) : String
  (string-append message (compiler-symbols-generated-meta-suffix meta)))

(define (compiler-symbols-add-struct-cleanup-in-module
  [symbols : CompilerSymbols]
  [module : String]
  [cleanup : AstStructCleanup]
  [index : i64]) : ResultCompilerSymbols
  (match cleanup
    [(AstStructNoCleanup) (OkCompilerSymbols symbols)]
    [(AstStructCleanupFn cleanup-name)
      (compiler-symbols-add-value-in-module
        symbols
        module
        (intern-str cleanup-name)
        (compiler-symbol-make-handle (compiler-symbol-kind-defstruct) index))]))

(define (compiler-symbols-add-enum-cleanup-in-module
  [symbols : CompilerSymbols]
  [module : String]
  [cleanup : AstEnumCleanup]
  [index : i64]) : ResultCompilerSymbols
  (match cleanup
    [(AstEnumNoCleanup) (OkCompilerSymbols symbols)]
    [(AstEnumCleanupFn cleanup-name)
      (compiler-symbols-add-value-in-module
        symbols
        module
        (intern-str cleanup-name)
        (compiler-symbol-make-handle (compiler-symbol-kind-defenum) index))]))

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
        (intern-str name)
        (compiler-symbol-make-handle (compiler-symbol-kind-value-define) index))]
    [(AstDeclDefFn name _ _ _ _)
      (compiler-symbols-add-value-in-module
        symbols
        module
        (intern-str name)
        (compiler-symbol-make-handle
          (compiler-symbol-kind-function-define)
          index))]
    [(AstDeclDefMacro name _ _ _)
      (compiler-symbols-add-macro-in-module
        symbols
        module
        (intern-str name)
        (compiler-symbol-make-handle (compiler-symbol-kind-defmacro) index))]
    [(AstDeclExtern name _ _ _)
      (compiler-symbols-add-value-in-module
        symbols
        module
        (intern-str name)
        (compiler-symbol-make-handle (compiler-symbol-kind-extern) index))]
    [(AstDeclDefDispatch name _)
      (compiler-symbols-add-value-in-module
        symbols
        module
        (intern-str name)
        (compiler-symbol-make-handle (compiler-symbol-kind-defdispatch) index))]
    [(AstDeclDefEnum name cleanup variants)
      (match (compiler-symbols-add-type-in-module
        symbols
        module
        (intern-str name)
        (compiler-symbol-make-handle (compiler-symbol-kind-defenum) index))
        [(OkCompilerSymbols next)
          (match (compiler-symbols-add-variant-values-in-module
            next
            module
            (intern-str name)
            variants
            index
            0)
            [(OkCompilerSymbols with-variants)
              (compiler-symbols-add-enum-cleanup-in-module
                with-variants
                module
                cleanup
                index)]
            [(ErrCompilerSymbols message) (ErrCompilerSymbols message)])]
        [(ErrCompilerSymbols message) (ErrCompilerSymbols message)])]
    [(AstDeclDefEnumLifetimes name _ cleanup variants)
      (match (compiler-symbols-add-type-in-module
        symbols
        module
        (intern-str name)
        (compiler-symbol-make-handle (compiler-symbol-kind-defenum) index))
        [(OkCompilerSymbols next)
          (match (compiler-symbols-add-variant-values-in-module
            next
            module
            (intern-str name)
            variants
            index
            0)
            [(OkCompilerSymbols with-variants)
              (compiler-symbols-add-enum-cleanup-in-module
                with-variants
                module
                cleanup
                index)]
            [(ErrCompilerSymbols message) (ErrCompilerSymbols message)])]
        [(ErrCompilerSymbols message) (ErrCompilerSymbols message)])]
    [(AstDeclDefStruct name _ cleanup _)
      (match (compiler-symbols-add-type-in-module
        symbols
        module
        (intern-str name)
        (compiler-symbol-make-handle (compiler-symbol-kind-defstruct) index))
        [(OkCompilerSymbols next)
          (match (compiler-symbols-add-value-in-module
            next
            module
            (intern-str name)
            (compiler-symbol-make-handle (compiler-symbol-kind-defstruct) index))
            [(OkCompilerSymbols with-constructor)
              (compiler-symbols-add-struct-cleanup-in-module
                with-constructor
                module
                cleanup
                index)]
            [(ErrCompilerSymbols message) (ErrCompilerSymbols message)])]
        [(ErrCompilerSymbols message) (ErrCompilerSymbols message)])]
    [(AstDeclDefStructLifetimes name _ _ cleanup _)
      (match (compiler-symbols-add-type-in-module
        symbols
        module
        (intern-str name)
        (compiler-symbol-make-handle (compiler-symbol-kind-defstruct) index))
        [(OkCompilerSymbols next)
          (match (compiler-symbols-add-value-in-module
            next
            module
            (intern-str name)
            (compiler-symbol-make-handle (compiler-symbol-kind-defstruct) index))
            [(OkCompilerSymbols with-constructor)
              (compiler-symbols-add-struct-cleanup-in-module
                with-constructor
                module
                cleanup
                index)]
            [(ErrCompilerSymbols message) (ErrCompilerSymbols message)])]
        [(ErrCompilerSymbols message) (ErrCompilerSymbols message)])]
    [(AstDeclIncludeStr _ _) (OkCompilerSymbols symbols)]
    [(AstDeclIncludeBin _ _) (OkCompilerSymbols symbols)]
    [(AstDeclImport _) (OkCompilerSymbols symbols)]
    [(AstDeclExport _) (OkCompilerSymbols symbols)]
    [(AstDeclModule _) (OkCompilerSymbols symbols)]
    [(AstDeclTest _ _ _) (OkCompilerSymbols symbols)]
    [(AstDeclUnsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (compiler-symbols-add-decl-in-module symbols module inner index))]
    [(AstDeclComptimeDecl meta template-box)
      (let
        [template : AstDecl (box-get template-box)]
        (match (compiler-symbols-add-decl-in-module
          symbols
          module
          template
          index)
          [(OkCompilerSymbols next) (OkCompilerSymbols next)]
          [(ErrCompilerSymbols message)
            (ErrCompilerSymbols
              (compiler-symbols-with-generated-context message meta))]))]))

(define (compiler-symbols-add-local-value-in-module
  [symbols : CompilerSymbols]
  [module : String]
  [name : String]
  [handle : i64]) : ResultCompilerSymbols
  (compiler-symbols-add-value-id
    symbols
    (compiler-symbol-module-key-id module name)
    (compiler-symbol-module-key module name)
    handle))

(define (compiler-symbols-add-local-type-in-module
  [symbols : CompilerSymbols]
  [module : String]
  [name : String]
  [handle : i64]) : ResultCompilerSymbols
  (compiler-symbols-add-type-id
    symbols
    (compiler-symbol-module-key-id module name)
    (compiler-symbol-module-key module name)
    handle))

(define (compiler-symbols-add-local-macro-in-module
  [symbols : CompilerSymbols]
  [module : String]
  [name : String]
  [handle : i64]) : ResultCompilerSymbols
  (compiler-symbols-add-macro-id
    symbols
    (compiler-symbol-module-key-id module name)
    (compiler-symbol-module-key module name)
    handle))

(define (compiler-symbols-add-local-struct-cleanup-in-module
  [symbols : CompilerSymbols]
  [module : String]
  [cleanup : AstStructCleanup]
  [index : i64]) : ResultCompilerSymbols
  (match cleanup
    [(AstStructNoCleanup) (OkCompilerSymbols symbols)]
    [(AstStructCleanupFn cleanup-name)
      (compiler-symbols-add-local-value-in-module
        symbols
        module
        (intern-str cleanup-name)
        (compiler-symbol-make-handle (compiler-symbol-kind-defstruct) index))]))

(define (compiler-symbols-add-local-enum-cleanup-in-module
  [symbols : CompilerSymbols]
  [module : String]
  [cleanup : AstEnumCleanup]
  [index : i64]) : ResultCompilerSymbols
  (match cleanup
    [(AstEnumNoCleanup) (OkCompilerSymbols symbols)]
    [(AstEnumCleanupFn cleanup-name)
      (compiler-symbols-add-local-value-in-module
        symbols
        module
        (intern-str cleanup-name)
        (compiler-symbol-make-handle (compiler-symbol-kind-defenum) index))]))

(define (compiler-symbols-add-local-variant-value-in-module
  [symbols : CompilerSymbols]
  [module : String]
  [name : String]
  [enum-index : i64]
  [variant-index : i64]) : ResultCompilerSymbols
  (compiler-symbols-add-variant-value-id
    symbols
    (compiler-symbol-module-key-id module name)
    (compiler-symbol-module-key module name)
    (compiler-registry-make-handle
      (compiler-symbol-kind-enum-variant)
      enum-index
      variant-index)))

(define (compiler-symbols-add-local-variant-values-in-module
  [symbols : CompilerSymbols]
  [module : String]
  [variants : AstVariantDefList]
  [enum-index : i64]
  [variant-index : i64]) : ResultCompilerSymbols
  (match variants
    [(AstVariantDefNil) (OkCompilerSymbols symbols)]
    [(AstVariantDefCons variant rest)
      (let
        [rest : AstVariantDefList (box-get rest)]
        (match variant
          [(AstVariantDef name _ _)
            (match (compiler-symbols-add-local-variant-value-in-module
              symbols
              module
              (intern-str name)
              enum-index
              variant-index)
              [(OkCompilerSymbols next)
                (compiler-symbols-add-local-variant-values-in-module
                  next
                  module
                  rest
                  enum-index
                  (+ variant-index 1))]
              [(ErrCompilerSymbols message) (ErrCompilerSymbols message)])]))]))

(define (compiler-symbols-add-local-decl-in-module
  [symbols : CompilerSymbols]
  [module : String]
  [decl : AstDecl]
  [index : i64]) : ResultCompilerSymbols
  (match decl
    [(AstDeclDef name _ _)
      (compiler-symbols-add-local-value-in-module
        symbols
        module
        (intern-str name)
        (compiler-symbol-make-handle (compiler-symbol-kind-value-define) index))]
    [(AstDeclDefFn name _ _ _ _)
      (compiler-symbols-add-local-value-in-module
        symbols
        module
        (intern-str name)
        (compiler-symbol-make-handle
          (compiler-symbol-kind-function-define)
          index))]
    [(AstDeclDefMacro name _ _ _)
      (compiler-symbols-add-local-macro-in-module
        symbols
        module
        (intern-str name)
        (compiler-symbol-make-handle (compiler-symbol-kind-defmacro) index))]
    [(AstDeclExtern name _ _ _)
      (compiler-symbols-add-local-value-in-module
        symbols
        module
        (intern-str name)
        (compiler-symbol-make-handle (compiler-symbol-kind-extern) index))]
    [(AstDeclDefDispatch name _)
      (compiler-symbols-add-local-value-in-module
        symbols
        module
        (intern-str name)
        (compiler-symbol-make-handle (compiler-symbol-kind-defdispatch) index))]
    [(AstDeclDefEnum name cleanup variants)
      (match (compiler-symbols-add-local-type-in-module
        symbols
        module
        (intern-str name)
        (compiler-symbol-make-handle (compiler-symbol-kind-defenum) index))
        [(OkCompilerSymbols next)
          (match (compiler-symbols-add-local-variant-values-in-module
            next
            module
            variants
            index
            0)
            [(OkCompilerSymbols with-variants)
              (compiler-symbols-add-local-enum-cleanup-in-module
                with-variants
                module
                cleanup
                index)]
            [(ErrCompilerSymbols message) (ErrCompilerSymbols message)])]
        [(ErrCompilerSymbols message) (ErrCompilerSymbols message)])]
    [(AstDeclDefEnumLifetimes name _ cleanup variants)
      (match (compiler-symbols-add-local-type-in-module
        symbols
        module
        (intern-str name)
        (compiler-symbol-make-handle (compiler-symbol-kind-defenum) index))
        [(OkCompilerSymbols next)
          (match (compiler-symbols-add-local-variant-values-in-module
            next
            module
            variants
            index
            0)
            [(OkCompilerSymbols with-variants)
              (compiler-symbols-add-local-enum-cleanup-in-module
                with-variants
                module
                cleanup
                index)]
            [(ErrCompilerSymbols message) (ErrCompilerSymbols message)])]
        [(ErrCompilerSymbols message) (ErrCompilerSymbols message)])]
    [(AstDeclDefStruct name _ cleanup _)
      (match (compiler-symbols-add-local-type-in-module
        symbols
        module
        (intern-str name)
        (compiler-symbol-make-handle (compiler-symbol-kind-defstruct) index))
        [(OkCompilerSymbols next)
          (match (compiler-symbols-add-local-value-in-module
            next
            module
            (intern-str name)
            (compiler-symbol-make-handle (compiler-symbol-kind-defstruct) index))
            [(OkCompilerSymbols with-constructor)
              (compiler-symbols-add-local-struct-cleanup-in-module
                with-constructor
                module
                cleanup
                index)]
            [(ErrCompilerSymbols message) (ErrCompilerSymbols message)])]
        [(ErrCompilerSymbols message) (ErrCompilerSymbols message)])]
    [(AstDeclDefStructLifetimes name _ _ cleanup _)
      (match (compiler-symbols-add-local-type-in-module
        symbols
        module
        (intern-str name)
        (compiler-symbol-make-handle (compiler-symbol-kind-defstruct) index))
        [(OkCompilerSymbols next)
          (match (compiler-symbols-add-local-value-in-module
            next
            module
            (intern-str name)
            (compiler-symbol-make-handle (compiler-symbol-kind-defstruct) index))
            [(OkCompilerSymbols with-constructor)
              (compiler-symbols-add-local-struct-cleanup-in-module
                with-constructor
                module
                cleanup
                index)]
            [(ErrCompilerSymbols message) (ErrCompilerSymbols message)])]
        [(ErrCompilerSymbols message) (ErrCompilerSymbols message)])]
    [(AstDeclIncludeStr _ _) (OkCompilerSymbols symbols)]
    [(AstDeclIncludeBin _ _) (OkCompilerSymbols symbols)]
    [(AstDeclImport _) (OkCompilerSymbols symbols)]
    [(AstDeclExport _) (OkCompilerSymbols symbols)]
    [(AstDeclModule _) (OkCompilerSymbols symbols)]
    [(AstDeclTest _ _ _) (OkCompilerSymbols symbols)]
    [(AstDeclUnsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (compiler-symbols-add-local-decl-in-module symbols module inner index))]
    [(AstDeclComptimeDecl meta template-box)
      (let
        [template : AstDecl (box-get template-box)]
        (match (compiler-symbols-add-local-decl-in-module
          symbols
          module
          template
          index)
          [(OkCompilerSymbols next) (OkCompilerSymbols next)]
          [(ErrCompilerSymbols message)
            (ErrCompilerSymbols
              (compiler-symbols-with-generated-context message meta))]))]))

(define (compiler-symbols-add-variant-value-aliases
  [symbols : CompilerSymbols]
  [alias : String]
  [enum-name : String]
  [variants : AstVariantDefList]
  [enum-index : i64]
  [variant-index : i64]) : CompilerSymbols
  (match variants
    [(AstVariantDefNil) symbols]
    [(AstVariantDefCons variant rest)
      (let
        [rest : AstVariantDefList (box-get rest)]
        (match variant
          [(AstVariantDef name _ _)
            (let
              [variant-name : String (intern-str name)]
              [qualified-name : String
                (compiler-enum-qualified-variant-name enum-name variant-name)]
              [handle : i64
                (compiler-registry-make-handle
                  (compiler-symbol-kind-enum-variant)
                  enum-index
                  variant-index)]
              (compiler-symbols-add-variant-value-aliases
                (compiler-symbols-add-value-alias
                  (compiler-symbols-add-value-alias
                    symbols
                    (compiler-symbol-module-key alias variant-name)
                    handle)
                  (compiler-symbol-module-key alias qualified-name)
                  handle)
                alias
                enum-name
                rest
                enum-index
                (+ variant-index 1)))]))]))

(define (compiler-symbols-add-struct-cleanup-alias
  [symbols : CompilerSymbols]
  [alias : String]
  [cleanup : AstStructCleanup]
  [index : i64]) : CompilerSymbols
  (match cleanup
    [(AstStructNoCleanup) symbols]
    [(AstStructCleanupFn cleanup-name)
      (compiler-symbols-add-value-alias
        symbols
        (compiler-symbol-module-key alias (intern-str cleanup-name))
        (compiler-symbol-make-handle (compiler-symbol-kind-defstruct) index))]))

(define (compiler-symbols-add-enum-cleanup-alias
  [symbols : CompilerSymbols]
  [alias : String]
  [cleanup : AstEnumCleanup]
  [index : i64]) : CompilerSymbols
  (match cleanup
    [(AstEnumNoCleanup) symbols]
    [(AstEnumCleanupFn cleanup-name)
      (compiler-symbols-add-value-alias
        symbols
        (compiler-symbol-module-key alias (intern-str cleanup-name))
        (compiler-symbol-make-handle (compiler-symbol-kind-defenum) index))]))

(define (compiler-symbols-add-decl-alias-in-module
  [symbols : CompilerSymbols]
  [alias : String]
  [decl : AstDecl]
  [index : i64]) : CompilerSymbols
  (match decl
    [(AstDeclDef name _ _)
      (compiler-symbols-add-value-alias
        symbols
        (compiler-symbol-module-key alias (intern-str name))
        (compiler-symbol-make-handle (compiler-symbol-kind-value-define) index))]
    [(AstDeclDefFn name _ _ _ _)
      (compiler-symbols-add-value-alias
        symbols
        (compiler-symbol-module-key alias (intern-str name))
        (compiler-symbol-make-handle
          (compiler-symbol-kind-function-define)
          index))]
    [(AstDeclDefMacro name _ _ _)
      (compiler-symbols-add-macro-alias
        symbols
        (compiler-symbol-module-key alias (intern-str name))
        (compiler-symbol-make-handle (compiler-symbol-kind-defmacro) index))]
    [(AstDeclExtern name _ _ _)
      (compiler-symbols-add-value-alias
        symbols
        (compiler-symbol-module-key alias (intern-str name))
        (compiler-symbol-make-handle (compiler-symbol-kind-extern) index))]
    [(AstDeclDefDispatch name _)
      (compiler-symbols-add-value-alias
        symbols
        (compiler-symbol-module-key alias (intern-str name))
        (compiler-symbol-make-handle (compiler-symbol-kind-defdispatch) index))]
    [(AstDeclDefEnum name cleanup variants)
      (compiler-symbols-add-enum-cleanup-alias
        (compiler-symbols-add-variant-value-aliases
          (compiler-symbols-add-type-alias
            symbols
            (compiler-symbol-module-key alias (intern-str name))
            (compiler-symbol-make-handle (compiler-symbol-kind-defenum) index))
          alias
          (intern-str name)
          variants
          index
          0)
        alias
        cleanup
        index)]
    [(AstDeclDefEnumLifetimes name _ cleanup variants)
      (compiler-symbols-add-enum-cleanup-alias
        (compiler-symbols-add-variant-value-aliases
          (compiler-symbols-add-type-alias
            symbols
            (compiler-symbol-module-key alias (intern-str name))
            (compiler-symbol-make-handle (compiler-symbol-kind-defenum) index))
          alias
          (intern-str name)
          variants
          index
          0)
        alias
        cleanup
        index)]
    [(AstDeclDefStruct name _ cleanup _)
      (compiler-symbols-add-struct-cleanup-alias
        (compiler-symbols-add-value-alias
          (compiler-symbols-add-type-alias
            symbols
            (compiler-symbol-module-key alias (intern-str name))
            (compiler-symbol-make-handle (compiler-symbol-kind-defstruct) index))
          (compiler-symbol-module-key alias (intern-str name))
          (compiler-symbol-make-handle (compiler-symbol-kind-defstruct) index))
        alias
        cleanup
        index)]
    [(AstDeclDefStructLifetimes name _ _ cleanup _)
      (compiler-symbols-add-struct-cleanup-alias
        (compiler-symbols-add-value-alias
          (compiler-symbols-add-type-alias
            symbols
            (compiler-symbol-module-key alias (intern-str name))
            (compiler-symbol-make-handle (compiler-symbol-kind-defstruct) index))
          (compiler-symbol-module-key alias (intern-str name))
          (compiler-symbol-make-handle (compiler-symbol-kind-defstruct) index))
        alias
        cleanup
        index)]
    [(AstDeclComptimeDecl _ template-box)
      (let
        [template : AstDecl (box-get template-box)]
        (compiler-symbols-add-decl-alias-in-module symbols alias template index))]
    [(AstDeclUnsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (compiler-symbols-add-decl-alias-in-module symbols alias inner index))]
    [_ symbols]))

(define (compiler-symbols-remove-decl-macro-alias
  [symbols : CompilerSymbols]
  [decl : AstDecl]
  [index : i64]) : CompilerSymbols
  (match decl
    [(AstDeclDefMacro name _ _ _)
      (compiler-symbols-remove-macro-alias-if-handle
        symbols
        (intern-str name)
        (compiler-symbol-make-handle (compiler-symbol-kind-defmacro) index))]
    [(AstDeclComptimeDecl _ template-box)
      (let
        [template : AstDecl (box-get template-box)]
        (compiler-symbols-remove-decl-macro-alias symbols template index))]
    [(AstDeclUnsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (compiler-symbols-remove-decl-macro-alias symbols inner index))]
    [_ symbols]))

;; An explicit `module ... as alias` import should expose macros as `alias/name`
;; without leaving the module's legacy bare macro alias in the importer.
(define (compiler-symbols-remove-module-macro-aliases-list
  [symbols : CompilerSymbols]
  [decls : AstDeclList]
  [target-module : String]
  [index : i64]
  [module : String]) : CompilerSymbols
  (match decls
    [(AstDeclNil) symbols]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclImport _)
            (compiler-symbols-remove-module-macro-aliases-list
              symbols
              rest
              target-module
              index
              module)]
          [(AstDeclIncludeStr _ _)
            (compiler-symbols-remove-module-macro-aliases-list
              symbols
              rest
              target-module
              index
              module)]
          [(AstDeclIncludeBin _ _)
            (compiler-symbols-remove-module-macro-aliases-list
              symbols
              rest
              target-module
              index
              module)]
          [(AstDeclExport _)
            (compiler-symbols-remove-module-macro-aliases-list
              symbols
              rest
              target-module
              index
              module)]
          [(AstDeclModule next-module)
            (compiler-symbols-remove-module-macro-aliases-list
              symbols
              rest
              target-module
              index
              (intern-str next-module))]
          [(AstDeclTest _ _ _)
            (compiler-symbols-remove-module-macro-aliases-list
              symbols
              rest
              target-module
              index
              module)]
          [_
            (let
              [next-symbols : CompilerSymbols
                (if (string-eq module target-module)
                  (compiler-symbols-remove-decl-macro-alias symbols decl index)
                  symbols)]
              (compiler-symbols-remove-module-macro-aliases-list
                next-symbols
                rest
                target-module
                (+ index 1)
                module))]))]))

(define (compiler-symbols-remove-module-macro-aliases
  [symbols : CompilerSymbols]
  [decls : AstDeclList]
  [target-module : String]) : CompilerSymbols
  (compiler-symbols-remove-module-macro-aliases-list
    symbols
    decls
    target-module
    0
    ""))

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
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclImport _)
            (compiler-symbols-add-module-aliases-list
              symbols
              rest
              target-module
              alias
              index
              module)]
          [(AstDeclIncludeStr _ _)
            (compiler-symbols-add-module-aliases-list
              symbols
              rest
              target-module
              alias
              index
              module)]
          [(AstDeclIncludeBin _ _)
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
              (intern-str next-module))]
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
                module))]))]))

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
        [rest : AstDeclList (box-get rest)]
        [next-symbols : CompilerSymbols
          (match decl
            [(AstDeclImport
                (AstImportSpec
                  _
                  _
                  (AstSomeModuleName target-module)
                  (AstSomeImportAlias alias)))
              (compiler-symbols-add-module-aliases
                (compiler-symbols-remove-module-macro-aliases
                  symbols
                  all-decls
                  target-module)
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

(define (compiler-symbol-indexed-decl [decl : AstDecl]) : AstDecl
  (match decl
    [(AstDeclComptimeDecl _ template-box)
      (let
        [template : AstDecl (box-get template-box)]
        template)]
    [(AstDeclUnsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        inner)]
    [_ decl]))

(define (compiler-symbol-owner-name-for-decl [decl : AstDecl] [module : String]) : String
  (match decl
    [(AstDeclDefEnum name _ _)
      (compiler-symbol-module-key module (intern-str name))]
    [(AstDeclDefEnumLifetimes name _ _ _)
      (compiler-symbol-module-key module (intern-str name))]
    [(AstDeclDefStruct name _ _ _)
      (compiler-symbol-module-key module (intern-str name))]
    [(AstDeclDefStructLifetimes name _ _ _ _)
      (compiler-symbol-module-key module (intern-str name))]
    [_ ""]))

(define (compiler-symbols-index-decl!
  [symbols : CompilerSymbols]
  [decl : AstDecl]
  [index : i64]
  [module : String]) : unit
  (let
    [indexed : AstDecl (compiler-symbol-indexed-decl decl)]
    (begin
      (array-set! (compiler-symbols-decls symbols) index indexed)
      (array-set!
        (compiler-symbols-owner-names symbols)
        index
        (compiler-symbol-owner-name-for-decl indexed module)))))

(define (compiler-symbols-owner-name-at-index
  [symbols : CompilerSymbols]
  [target : i64]) : CompilerMaybeString
  (let
    [owner-names : (Array String) (compiler-symbols-owner-names symbols)]
    (if (or (< target 0) (>= target (array-length owner-names)))
      (CompilerNoString)
      (let
        [owner-name : String (array-ref owner-names target)]
        (if (> (string-length owner-name) 0)
          (CompilerSomeString owner-name)
          (CompilerNoString))))))

(define (build-compiler-symbol-list-in-module
  [decls : AstDeclList]
  [symbols : CompilerSymbols]
  [index : i64]
  [module : String]) : ResultCompilerSymbols
  (match decls
    [(AstDeclNil) (OkCompilerSymbols symbols)]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclImport _)
            (build-compiler-symbol-list-in-module rest symbols index module)]
          [(AstDeclIncludeStr _ _)
            (build-compiler-symbol-list-in-module rest symbols index module)]
          [(AstDeclIncludeBin _ _)
            (build-compiler-symbol-list-in-module rest symbols index module)]
          [(AstDeclExport _)
            (build-compiler-symbol-list-in-module rest symbols index module)]
          [(AstDeclModule next-module)
            (build-compiler-symbol-list-in-module
              rest
              symbols
              index
              (intern-str next-module))]
          [(AstDeclTest _ _ _)
            (build-compiler-symbol-list-in-module rest symbols index module)]
          [_
            (begin
              (compiler-symbols-index-decl! symbols decl index module)
              (match (compiler-symbols-add-decl-in-module
                symbols
                module
                decl
                index)
                [(OkCompilerSymbols next-symbols)
                  (build-compiler-symbol-list-in-module
                    rest
                    next-symbols
                    (+ index 1)
                    module)]
                [(ErrCompilerSymbols message) (ErrCompilerSymbols message)]))]))]))

(define (build-compiler-symbols [program : AstProgram]) : ResultCompilerSymbols
  (match program
    [(AstProgram decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (build-compiler-symbol-list
          decls
          (compiler-symbols-empty-with-decls
            (compiler-decl-list-index-count decls))
          0)
          [(OkCompilerSymbols symbols)
            (OkCompilerSymbols
              (build-compiler-symbol-aliases-list decls decls symbols))]
          [(ErrCompilerSymbols message) (ErrCompilerSymbols message)]))]))

(define (build-compiler-symbols-from-source [src : String]) : ResultCompilerSymbols
  (match (parse-ast-source src)
    [(OkAstProgram program) (build-compiler-symbols program)]
    [(ErrAstProgram message) (ErrCompilerSymbols message)]))

(define (build-compiler-local-symbol-list-in-module
  [decls : AstDeclList]
  [symbols : CompilerSymbols]
  [index : i64]
  [module : String]) : ResultCompilerSymbols
  (match decls
    [(AstDeclNil) (OkCompilerSymbols symbols)]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclImport _)
            (build-compiler-local-symbol-list-in-module
              rest
              symbols
              index
              module)]
          [(AstDeclIncludeStr _ _)
            (build-compiler-local-symbol-list-in-module
              rest
              symbols
              index
              module)]
          [(AstDeclIncludeBin _ _)
            (build-compiler-local-symbol-list-in-module
              rest
              symbols
              index
              module)]
          [(AstDeclExport _)
            (build-compiler-local-symbol-list-in-module
              rest
              symbols
              index
              module)]
          [(AstDeclModule next-module)
            (build-compiler-local-symbol-list-in-module
              rest
              symbols
              index
              (intern-str next-module))]
          [(AstDeclTest _ _ _)
            (build-compiler-local-symbol-list-in-module
              rest
              symbols
              index
              module)]
          [_
            (match (compiler-symbols-add-local-decl-in-module
              symbols
              module
              decl
              index)
              [(OkCompilerSymbols next-symbols)
                (build-compiler-local-symbol-list-in-module
                  rest
                  next-symbols
                  (+ index 1)
                  module)]
              [(ErrCompilerSymbols message) (ErrCompilerSymbols message)])]))]))

(define (build-compiler-local-symbols [program : AstProgram]) : ResultCompilerSymbols
  (match program
    [(AstProgram decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        (build-compiler-local-symbol-list-in-module
          decls
          (compiler-symbols-empty)
          0
          ""))]))

(define (compiler-registries-lookup-variant
  [registries : CompilerRegistries]
  [name : String]) : MaybeI64
  (compiler-registries-lookup-variant-id registries (intern name)))

(define (compiler-registries-lookup-variant-id
  [registries : CompilerRegistries]
  [name-id : i64]) : MaybeI64
  (match registries
    [(CompilerRegistries variants _)
      (compiler-symbol-map-lookup-id
        variants
        (compiler-symbol-name-id-key name-id))]))

(define (compiler-registries-lookup-struct-field
  [registries : CompilerRegistries]
  [struct-name : String]
  [field-name : String]) : MaybeI64
  (compiler-registries-lookup-struct-field-id
    registries
    (intern struct-name)
    (intern field-name)))

(define (compiler-registries-lookup-struct-field-id
  [registries : CompilerRegistries]
  [struct-name-id : i64]
  [field-name-id : i64]) : MaybeI64
  (match registries
    [(CompilerRegistries _ fields)
      (compiler-symbol-map-lookup-id
        fields
        (compiler-struct-field-key-id-by-id struct-name-id field-name-id))]))

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
  [enum-name : String]
  [name : String]
  [enum-index : i64]
  [variant-index : i64]) : ResultCompilerRegistries
  (let
    [qualified-name : String
      (compiler-enum-qualified-variant-name enum-name name)]
    [qualified-key-id : i64
      (compiler-symbol-module-key-id module qualified-name)]
    [qualified-display-name : String
      (compiler-symbol-module-key module qualified-name)]
    [handle : i64
      (compiler-registry-make-handle
        (compiler-symbol-kind-enum-variant)
        enum-index
        variant-index)]
    (match registries
      [(CompilerRegistries variants fields)
        (if (compiler-symbol-map-contains-id? variants qualified-key-id)
          (ErrCompilerRegistries
            (compiler-registries-duplicate-variant-message
              qualified-display-name))
          (OkCompilerRegistries
            (compiler-registries-add-variant-alias
              (compiler-registries-add-variant-alias
                (CompilerRegistries
                  (compiler-symbol-map-bind-id variants qualified-key-id handle)
                  fields)
                (compiler-symbol-module-key module name)
                handle)
              name
              handle)))])))

(define (compiler-registries-add-field
  [registries : CompilerRegistries]
  [struct-name : String]
  [field-name : String]
  [struct-index : i64]
  [field-index : i64]) : ResultCompilerRegistries
  (compiler-registries-add-field-id
    registries
    (intern struct-name)
    (intern field-name)
    struct-name
    field-name
    struct-index
    field-index))

(define (compiler-registries-add-field-id
  [registries : CompilerRegistries]
  [struct-name-id : i64]
  [field-name-id : i64]
  [struct-name : String]
  [field-name : String]
  [struct-index : i64]
  [field-index : i64]) : ResultCompilerRegistries
  (match registries
    [(CompilerRegistries variants fields)
      (let
        [key-id : i64
          (compiler-struct-field-key-id-by-id struct-name-id field-name-id)]
        (if (compiler-symbol-map-contains-id? fields key-id)
          (ErrCompilerRegistries
            (compiler-registries-duplicate-field-message struct-name field-name))
          (OkCompilerRegistries
            (CompilerRegistries
              variants
              (compiler-symbol-map-bind-id
                fields
                key-id
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
        [key-id : i64 (compiler-struct-field-key-id struct-name field-name)]
        (if (compiler-symbol-map-contains-id? fields key-id)
          registries
          (CompilerRegistries
            variants
            (compiler-symbol-map-bind-id fields key-id handle))))]))

(define (compiler-registries-add-variant-aliases-list
  [registries : CompilerRegistries]
  [alias : String]
  [enum-name : String]
  [variants : AstVariantDefList]
  [enum-index : i64]
  [variant-index : i64]) : CompilerRegistries
  (match variants
    [(AstVariantDefNil) registries]
    [(AstVariantDefCons variant rest)
      (let
        [rest : AstVariantDefList (box-get rest)]
        (match variant
          [(AstVariantDef name _ _)
            (let
              [variant-name : String (intern-str name)]
              [qualified-name : String
                (compiler-enum-qualified-variant-name enum-name variant-name)]
              [handle : i64
                (compiler-registry-make-handle
                  (compiler-symbol-kind-enum-variant)
                  enum-index
                  variant-index)]
              (compiler-registries-add-variant-aliases-list
                (compiler-registries-add-variant-alias
                  (compiler-registries-add-variant-alias
                    registries
                    (compiler-symbol-module-key alias variant-name)
                    handle)
                  (compiler-symbol-module-key alias qualified-name)
                  handle)
                alias
                enum-name
                rest
                enum-index
                (+ variant-index 1)))]))]))

(define (compiler-registries-add-field-aliases-list
  [registries : CompilerRegistries]
  [struct-name : String]
  [fields : AstFieldDefList]
  [struct-index : i64]
  [field-index : i64]) : CompilerRegistries
  (match fields
    [(AstFieldDefNil) registries]
    [(AstFieldDefCons field rest)
      (let
        [rest : AstFieldDefList (box-get rest)]
        (match field
          [(AstFieldDef name _ _)
            (compiler-registries-add-field-aliases-list
              (compiler-registries-add-field-alias
                registries
                struct-name
                (intern-str name)
                (compiler-registry-make-handle
                  (compiler-symbol-kind-struct-field)
                  struct-index
                  field-index))
              struct-name
              rest
              struct-index
              (+ field-index 1))]))]))

(define (compiler-registries-add-decl-alias-in-module
  [registries : CompilerRegistries]
  [alias : String]
  [decl : AstDecl]
  [index : i64]) : CompilerRegistries
  (match decl
    [(AstDeclDefEnum name _ variants)
      (compiler-registries-add-variant-aliases-list
        registries
        alias
        (intern-str name)
        variants
        index
        0)]
    [(AstDeclDefEnumLifetimes name _ _ variants)
      (compiler-registries-add-variant-aliases-list
        registries
        alias
        (intern-str name)
        variants
        index
        0)]
    [(AstDeclDefStruct name _ _ fields)
      (compiler-registries-add-field-aliases-list
        registries
        (compiler-symbol-module-key alias (intern-str name))
        fields
        index
        0)]
    [(AstDeclDefStructLifetimes name _ _ _ fields)
      (compiler-registries-add-field-aliases-list
        registries
        (compiler-symbol-module-key alias (intern-str name))
        fields
        index
        0)]
    [(AstDeclComptimeDecl _ template-box)
      (let
        [template : AstDecl (box-get template-box)]
        (compiler-registries-add-decl-alias-in-module
          registries
          alias
          template
          index))]
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
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclImport _)
            (compiler-registries-add-module-aliases-list
              registries
              rest
              target-module
              alias
              index
              module)]
          [(AstDeclIncludeStr _ _)
            (compiler-registries-add-module-aliases-list
              registries
              rest
              target-module
              alias
              index
              module)]
          [(AstDeclIncludeBin _ _)
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
              (intern-str next-module))]
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
                module))]))]))

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
        [rest : AstDeclList (box-get rest)]
        [next-registries : CompilerRegistries
          (match decl
            [(AstDeclImport
                (AstImportSpec
                  _
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
  [enum-name : String]
  [enum-index : i64]
  [variant-index : i64]) : ResultCompilerRegistries
  (build-compiler-variant-registry-list-in-module
    variants
    registries
    ""
    enum-name
    enum-index
    variant-index))

(define (build-compiler-variant-registry-list-in-module
  [variants : AstVariantDefList]
  [registries : CompilerRegistries]
  [module : String]
  [enum-name : String]
  [enum-index : i64]
  [variant-index : i64]) : ResultCompilerRegistries
  (match variants
    [(AstVariantDefNil) (OkCompilerRegistries registries)]
    [(AstVariantDefCons variant rest)
      (let
        [rest : AstVariantDefList (box-get rest)]
        (match variant
          [(AstVariantDef name _ _)
            (match (compiler-registries-add-variant-in-module
              registries
              module
              enum-name
              (intern-str name)
              enum-index
              variant-index)
              [(OkCompilerRegistries next-registries)
                (build-compiler-variant-registry-list-in-module
                  rest
                  next-registries
                  module
                  enum-name
                  enum-index
                  (+ variant-index 1))]
              [(ErrCompilerRegistries message) (ErrCompilerRegistries message)])]))]))

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
      (let
        [rest : AstFieldDefList (box-get rest)]
        (match field
          [(AstFieldDef name _ _)
            (if (sym-i64-contains-id seen name)
              (ErrCompilerRegistries
                (compiler-registries-duplicate-field-message
                  struct-name
                  (intern-str name)))
              (match (compiler-registries-add-field
                registries
                struct-name
                (intern-str name)
                struct-index
                field-index)
                [(OkCompilerRegistries next-registries)
                  (build-compiler-field-registry-list
                    rest
                    next-registries
                    (sym-i64-bind-id seen name field-index)
                    struct-name
                    struct-index
                    (+ field-index 1))]
                [(ErrCompilerRegistries message)
                  (ErrCompilerRegistries message)]))]))]))

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
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclImport _)
            (build-compiler-registry-list-in-module
              rest
              registries
              index
              module)]
          [(AstDeclIncludeStr _ _)
            (build-compiler-registry-list-in-module
              rest
              registries
              index
              module)]
          [(AstDeclIncludeBin _ _)
            (build-compiler-registry-list-in-module
              rest
              registries
              index
              module)]
          [(AstDeclExport _)
            (build-compiler-registry-list-in-module
              rest
              registries
              index
              module)]
          [(AstDeclModule next-module)
            (build-compiler-registry-list-in-module
              rest
              registries
              index
              (intern-str next-module))]
          [(AstDeclTest _ _ _)
            (build-compiler-registry-list-in-module
              rest
              registries
              index
              module)]
          [(AstDeclDefEnum name _ variants)
            (match (build-compiler-variant-registry-list-in-module
              variants
              registries
              module
              (intern-str name)
              index
              0)
              [(OkCompilerRegistries next-registries)
                (build-compiler-registry-list-in-module
                  rest
                  next-registries
                  (+ index 1)
                  module)]
              [(ErrCompilerRegistries message) (ErrCompilerRegistries message)])]
          [(AstDeclDefEnumLifetimes name _ _ variants)
            (match (build-compiler-variant-registry-list-in-module
              variants
              registries
              module
              (intern-str name)
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
              (compiler-symbol-module-key module (intern-str name))
              index
              0)
              [(OkCompilerRegistries next-registries)
                (build-compiler-registry-list-in-module
                  rest
                  next-registries
                  (+ index 1)
                  module)]
              [(ErrCompilerRegistries message) (ErrCompilerRegistries message)])]
          [(AstDeclDefStructLifetimes name _ _ _ fields)
            (match (build-compiler-field-registry-list
              fields
              registries
              (sym-i64-empty)
              (compiler-symbol-module-key module (intern-str name))
              index
              0)
              [(OkCompilerRegistries next-registries)
                (build-compiler-registry-list-in-module
                  rest
                  next-registries
                  (+ index 1)
                  module)]
              [(ErrCompilerRegistries message) (ErrCompilerRegistries message)])]
          [(AstDeclComptimeDecl _ template-box)
            (let
              [template : AstDecl (box-get template-box)]
              (match template
                [(AstDeclDefEnum name _ variants)
                  (match (build-compiler-variant-registry-list-in-module
                    variants
                    registries
                    module
                    (intern-str name)
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
                [(AstDeclDefEnumLifetimes name _ _ variants)
                  (match (build-compiler-variant-registry-list-in-module
                    variants
                    registries
                    module
                    (intern-str name)
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
                    (compiler-symbol-module-key module (intern-str name))
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
                [(AstDeclDefStructLifetimes name _ _ _ fields)
                  (match (build-compiler-field-registry-list
                    fields
                    registries
                    (sym-i64-empty)
                    (compiler-symbol-module-key module (intern-str name))
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
                    module)]))]
          [_
            (build-compiler-registry-list-in-module
              rest
              registries
              (+ index 1)
              module)]))]))

(define (build-compiler-registries-with-symbols
  [program : AstProgram]
  [_symbols : CompilerSymbols]) : ResultCompilerRegistries
  (match program
    [(AstProgram decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (build-compiler-registry-list
          decls
          (compiler-registries-empty)
          0)
          [(OkCompilerRegistries registries)
            (OkCompilerRegistries
              (build-compiler-registry-aliases-list decls decls registries))]
          [(ErrCompilerRegistries message) (ErrCompilerRegistries message)]))]))

(define (build-compiler-registries [program : AstProgram]) : ResultCompilerRegistries
  (match (build-compiler-symbols program)
    [(OkCompilerSymbols symbols)
      (build-compiler-registries-with-symbols program symbols)]
    [(ErrCompilerSymbols message) (ErrCompilerRegistries message)]))

(define (build-compiler-registries-from-source [src : String]) : ResultCompilerRegistries
  (match (parse-ast-source src)
    [(OkAstProgram program) (build-compiler-registries program)]
    [(ErrAstProgram message) (ErrCompilerRegistries message)]))

(define (build-compiler-export-item
  [exports : CompilerExports]
  [symbols : CompilerSymbols]
  [owner-symbols : CompilerSymbols]
  [registries : CompilerRegistries]
  [module : String]
  [item : AstExportItem]) : ResultCompilerExports
  (match item
    [(AstExportValue name)
      (compiler-exports-add-value-item exports symbols module name)]
    [(AstExportType name)
      (compiler-exports-add-type-item exports symbols module name)]
    [(AstExportMacro name)
      (compiler-exports-add-macro-item exports symbols module name)]
    [(AstExportConstructor name)
      (compiler-exports-add-constructor-item exports symbols module name)]
    [(AstExportField type-name field-name)
      (compiler-exports-add-field-item
        exports
        symbols
        registries
        module
        type-name
        field-name)]
    [(AstExportVariant name)
      (compiler-exports-add-variant-item
        exports
        symbols
        owner-symbols
        module
        name)]))

(define (build-compiler-export-items
  [exports : CompilerExports]
  [symbols : CompilerSymbols]
  [owner-symbols : CompilerSymbols]
  [registries : CompilerRegistries]
  [module : String]
  [items : AstExportItemList]) : ResultCompilerExports
  (match items
    [(AstExportItemNil) (OkCompilerExports exports)]
    [(AstExportItemCons item rest)
      (let
        [rest : AstExportItemList (box-get rest)]
        (match (build-compiler-export-item
          exports
          symbols
          owner-symbols
          registries
          module
          item)
          [(OkCompilerExports next-exports)
            (build-compiler-export-items
              next-exports
              symbols
              owner-symbols
              registries
              module
              rest)]
          [(ErrCompilerExports message) (ErrCompilerExports message)]))]))

(define (build-compiler-export-list-in-module
  [decls : AstDeclList]
  [symbols : CompilerSymbols]
  [owner-symbols : CompilerSymbols]
  [registries : CompilerRegistries]
  [exports : CompilerExports]
  [module : String]) : ResultCompilerExports
  (match decls
    [(AstDeclNil) (OkCompilerExports exports)]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclModule next-module)
            (build-compiler-export-list-in-module
              rest
              symbols
              owner-symbols
              registries
              exports
              (intern-str next-module))]
          [(AstDeclExport items)
            (match (build-compiler-export-items
              exports
              symbols
              owner-symbols
              registries
              module
              items)
              [(OkCompilerExports next-exports)
                (build-compiler-export-list-in-module
                  rest
                  symbols
                  owner-symbols
                  registries
                  next-exports
                  module)]
              [(ErrCompilerExports message) (ErrCompilerExports message)])]
          [(AstDeclUnsafe inner-box)
            (let
              [inner : AstDecl (box-get inner-box)]
              (match inner
                [(AstDeclExport items)
                  (match (build-compiler-export-items
                    exports
                    symbols
                    owner-symbols
                    registries
                    module
                    items)
                    [(OkCompilerExports next-exports)
                      (build-compiler-export-list-in-module
                        rest
                        symbols
                        owner-symbols
                        registries
                        next-exports
                        module)]
                    [(ErrCompilerExports message) (ErrCompilerExports message)])]
                [_
                  (build-compiler-export-list-in-module
                    rest
                    symbols
                    owner-symbols
                    registries
                    exports
                    module)]))]
          [_
            (build-compiler-export-list-in-module
              rest
              symbols
              owner-symbols
              registries
              exports
              module)]))]))

(define (compiler-decl-list-has-exports? [decls : AstDeclList]) : bool
  (match decls
    [(AstDeclNil) false]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclExport _) true]
          [(AstDeclComptimeDecl _ template-box)
            (let
              [template : AstDecl (box-get template-box)]
              (match template
                [(AstDeclExport _) true]
                [_ (compiler-decl-list-has-exports? rest)]))]
          [_ (compiler-decl-list-has-exports? rest)]))]))

(define (compiler-program-has-exports? [program : AstProgram]) : bool
  (match program
    [(AstProgram decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        (compiler-decl-list-has-exports? decls))]))

(define (build-compiler-exports-with
  [program : AstProgram]
  [symbols : CompilerSymbols]
  [registries : CompilerRegistries]) : ResultCompilerExports
  (if (compiler-program-has-exports? program)
    (match (build-compiler-local-symbols program)
      [(OkCompilerSymbols local-symbols)
        (match program
          [(AstProgram decls-box)
            (let
              [decls : AstDeclList (box-get decls-box)]
              (build-compiler-export-list-in-module
                decls
                local-symbols
                symbols
                registries
                (compiler-exports-empty)
                ""))])]
      [(ErrCompilerSymbols message) (ErrCompilerExports message)])
    (OkCompilerExports (compiler-exports-empty))))

(define (build-compiler-exports [program : AstProgram]) : ResultCompilerExports
  (match (build-compiler-symbols program)
    [(OkCompilerSymbols symbols)
      (match (build-compiler-registries-with-symbols program symbols)
        [(OkCompilerRegistries registries)
          (build-compiler-exports-with program symbols registries)]
        [(ErrCompilerRegistries message) (ErrCompilerExports message)])]
    [(ErrCompilerSymbols message) (ErrCompilerExports message)]))

(define (build-compiler-exports-from-source [src : String]) : ResultCompilerExports
  (match (parse-ast-source src)
    [(OkAstProgram program) (build-compiler-exports program)]
    [(ErrAstProgram message) (ErrCompilerExports message)]))

(define (compiler-decl-list-at-index
  [decls : AstDeclList]
  [target : i64]
  [index : i64]) : ResultAstDecl
  (match decls
    [(AstDeclNil) (ErrAstDecl "symbols: declaration index not found")]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclImport _) (compiler-decl-list-at-index rest target index)]
          [(AstDeclIncludeStr _ _)
            (compiler-decl-list-at-index rest target index)]
          [(AstDeclIncludeBin _ _)
            (compiler-decl-list-at-index rest target index)]
          [(AstDeclExport _) (compiler-decl-list-at-index rest target index)]
          [(AstDeclModule _) (compiler-decl-list-at-index rest target index)]
          [(AstDeclTest _ _ _) (compiler-decl-list-at-index rest target index)]
          [_
            (if (= target index)
              (match decl
                [(AstDeclComptimeDecl _ template-box)
                  (let
                    [template : AstDecl (box-get template-box)]
                    (OkAstDecl template))]
                [(AstDeclUnsafe inner-box)
                  (let
                    [inner : AstDecl (box-get inner-box)]
                    (OkAstDecl inner))]
                [_ (OkAstDecl decl)])
              (compiler-decl-list-at-index rest target (+ index 1)))]))]))

(define (compiler-program-decl-at-index [program : AstProgram] [target : i64]) : ResultAstDecl
  (match program
    [(AstProgram decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        (compiler-decl-list-at-index decls target 0))]))

(define (compiler-symbols-decl-at-index
  [symbols : CompilerSymbols]
  [target : i64]) : ResultAstDecl
  (let
    [decls : (Array AstDecl) (compiler-symbols-decls symbols)]
    (if (or (< target 0) (>= target (array-length decls)))
      (ErrAstDecl "symbols: declaration index not found")
      (OkAstDecl (array-ref decls target)))))

(define (compiler-variant-types-at-index
  [variants : AstVariantDefList]
  [target : i64]
  [index : i64]) : ResultAstTypeList
  (match variants
    [(AstVariantDefNil) (ErrAstTypeList "symbols: variant index not found")]
    [(AstVariantDefCons variant rest)
      (let
        [rest : AstVariantDefList (box-get rest)]
        (match variant
          [(AstVariantDef _ fields _)
            (if (= target index)
              (OkAstTypeList fields)
              (compiler-variant-types-at-index rest target (+ index 1)))]))]))

(define (compiler-field-type-at-index
  [fields : AstFieldDefList]
  [target : i64]
  [index : i64]) : ResultAstType
  (match fields
    [(AstFieldDefNil) (ErrAstType "symbols: field index not found")]
    [(AstFieldDefCons field rest)
      (let
        [rest : AstFieldDefList (box-get rest)]
        (match field
          [(AstFieldDef _ ty _)
            (if (= target index)
              (OkAstType ty)
              (compiler-field-type-at-index rest target (+ index 1)))]))]))

(define (compiler-registries-variant-fields
  [program : AstProgram]
  [handle : i64]) : ResultAstTypeList
  (match (compiler-program-decl-at-index
    program
    (compiler-registry-handle-owner-index handle))
    [(OkAstDecl decl)
      (match decl
        [(AstDeclDefEnum _ _ variants)
          (compiler-variant-types-at-index
            variants
            (compiler-registry-handle-child-index handle)
            0)]
        [(AstDeclDefEnumLifetimes _ _ _ variants)
          (compiler-variant-types-at-index
            variants
            (compiler-registry-handle-child-index handle)
            0)]
        [_ (ErrAstTypeList "symbols: variant owner is not enum")])]
    [(ErrAstDecl message) (ErrAstTypeList message)]))

(define (compiler-registries-variant-fields-indexed
  [symbols : CompilerSymbols]
  [handle : i64]) : ResultAstTypeList
  (match (compiler-symbols-decl-at-index
    symbols
    (compiler-registry-handle-owner-index handle))
    [(OkAstDecl decl)
      (match decl
        [(AstDeclDefEnum _ _ variants)
          (compiler-variant-types-at-index
            variants
            (compiler-registry-handle-child-index handle)
            0)]
        [(AstDeclDefEnumLifetimes _ _ _ variants)
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
        [(AstDeclDefStructLifetimes _ _ _ _ fields)
          (compiler-field-type-at-index
            fields
            (compiler-registry-handle-child-index handle)
            0)]
        [_ (ErrAstType "symbols: field owner is not struct")])]
    [(ErrAstDecl message) (ErrAstType message)]))

(define (compiler-registries-struct-field-type-indexed
  [symbols : CompilerSymbols]
  [handle : i64]) : ResultAstType
  (match (compiler-symbols-decl-at-index
    symbols
    (compiler-registry-handle-owner-index handle))
    [(OkAstDecl decl)
      (match decl
        [(AstDeclDefStruct _ _ _ fields)
          (compiler-field-type-at-index
            fields
            (compiler-registry-handle-child-index handle)
            0)]
        [(AstDeclDefStructLifetimes _ _ _ _ fields)
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
        (= (compiler-registry-handle-owner-index handle) want-owner)
        (= (compiler-registry-handle-child-index handle) want-child))
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
        [(AstTypeCons ty rest)
          (let
            [ty : AstType (ty-node-get ty)]
            [rest : AstTypeList (box-get rest)]
            (match rest
              [(AstTypeNil)
                (if (= (ast-type-tag ty) want-tag)
                  1
                  0)]
              [_ 0]))]
        [_ 0])]
    [(ErrAstTypeList _) 0]))

(define (compiler-symbols-smoke-source) : String
  "(import \"stdlib/test.tl\")
(defstruct Point (x i64) (y i64))
(defenum Maybe (None) (Some i64))
(extern (print-string [arg0 : String]) : unit)
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
  "(defenum Left (Same) (Same))")

(define (compiler-registries-cross-enum-variant-source) : String
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
(extern (Foo [arg0 : i64]) : i64)")

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
(extern (Point [arg0 : i64]) : i64)")

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
    (compiler-symbols-duplicate-value-error-ok?
      (compiler-symbols-variant-define-collision-source)
      "Foo")
    (compiler-symbols-duplicate-value-error-ok?
      (compiler-symbols-variant-extern-collision-source)
      "Foo")
    (compiler-symbols-duplicate-value-error-ok?
      (compiler-symbols-variant-struct-collision-source)
      "Foo")))

(define (compiler-symbols-struct-value-collisions-ok?) : bool
  (and
    (compiler-symbols-duplicate-value-error-ok?
      (compiler-symbols-struct-function-collision-source)
      "Point")
    (compiler-symbols-duplicate-value-error-ok?
      (compiler-symbols-struct-define-collision-source)
      "Point")
    (compiler-symbols-duplicate-value-error-ok?
      (compiler-symbols-struct-extern-collision-source)
      "Point")))

(define (compiler-registries-duplicate-variant-ok?) : bool
  (match (build-compiler-registries-from-source
    (compiler-registries-duplicate-variant-source))
    [(ErrCompilerRegistries message)
      (string-eq
        message
        (compiler-registries-duplicate-variant-message "Left.Same"))]
    [(OkCompilerRegistries _) false]))

(define (compiler-registries-cross-enum-variant-ok?) : bool
  (match (build-compiler-registries-from-source
    (compiler-registries-cross-enum-variant-source))
    [(OkCompilerRegistries registries)
      (and
        (=
          (compiler-registry-lookup-score
            (compiler-registries-lookup-variant registries "Left.Same")
            (compiler-symbol-kind-enum-variant)
            0
            0)
          1)
        (=
          (compiler-registry-lookup-score
            (compiler-registries-lookup-variant registries "Right.Same")
            (compiler-symbol-kind-enum-variant)
            1
            0)
          1))]
    [(ErrCompilerRegistries _) false]))

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
        (=
          (compiler-symbols-miss-score
            (compiler-symbols-lookup-value symbols "all"))
          1)
        (=
          (compiler-symbol-lookup-score
            (compiler-symbols-lookup-value symbols "main")
            (compiler-symbol-kind-function-define)
            1)
          1))]
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
      (= (compiler-registry-handle-owner-index handle) 1234)
      (= (compiler-registry-handle-child-index handle) 5))))

(define (compiler-exports-valid-source) : String
  "(module data)
(define answer : i64 1)
(define (get) : i64 answer)
(extern (raw) : i64)
(defmacro (all [first : bool]) : bool first)
(defenum Maybe (None) (Some i64))
(defstruct Point (x i64) (y i64))
(export
  (value answer)
  (value get)
  (value raw)
  (macro all)
  (type Maybe)
  (type Point)
  (constructor Point)
  (field Point x)
  (variant None)
  (variant Some)
  (value answer))
(module main)
(import \"data.tl\" module data :as d)
(define (main) : i64 (d.get))")

(define (compiler-export-symbol-score
  [exports : CompilerExports]
  [kind-name : String]
  [module : String]
  [name : String]
  [want-kind : i64]
  [want-index : i64]) : i64
  (compiler-symbol-lookup-score
    (compiler-exports-lookup exports kind-name module name)
    want-kind
    want-index))

(define (compiler-export-registry-score
  [exports : CompilerExports]
  [kind-name : String]
  [module : String]
  [name : String]
  [want-kind : i64]
  [want-owner : i64]
  [want-child : i64]) : i64
  (compiler-registry-lookup-score
    (compiler-exports-lookup exports kind-name module name)
    want-kind
    want-owner
    want-child))

(define (compiler-exports-valid-ok?) : bool
  (match (parse-ast-source (compiler-exports-valid-source))
    [(OkAstProgram program)
      (match (build-compiler-symbols program)
        [(OkCompilerSymbols symbols)
          (match (build-compiler-registries program)
            [(OkCompilerRegistries registries)
              (match (build-compiler-exports-with program symbols registries)
                [(OkCompilerExports exports)
                  (let
                    [ok : bool true]
                    (begin
                      (if (=
                        (compiler-export-symbol-score
                          exports
                          (compiler-export-kind-value)
                          "data"
                          "answer"
                          (compiler-symbol-kind-value-define)
                          0)
                        1)
                        unit
                        (set! ok false))
                      (if (=
                        (compiler-export-symbol-score
                          exports
                          (compiler-export-kind-value)
                          "data"
                          "get"
                          (compiler-symbol-kind-function-define)
                          1)
                        1)
                        unit
                        (set! ok false))
                      (if (=
                        (compiler-export-symbol-score
                          exports
                          (compiler-export-kind-value)
                          "data"
                          "raw"
                          (compiler-symbol-kind-extern)
                          2)
                        1)
                        unit
                        (set! ok false))
                      (if (=
                        (compiler-export-symbol-score
                          exports
                          (compiler-export-kind-macro)
                          "data"
                          "all"
                          (compiler-symbol-kind-defmacro)
                          3)
                        1)
                        unit
                        (set! ok false))
                      (if (=
                        (compiler-export-symbol-score
                          exports
                          (compiler-export-kind-type)
                          "data"
                          "Maybe"
                          (compiler-symbol-kind-defenum)
                          4)
                        1)
                        unit
                        (set! ok false))
                      (if (=
                        (compiler-export-symbol-score
                          exports
                          (compiler-export-kind-constructor)
                          "data"
                          "Point"
                          (compiler-symbol-kind-defstruct)
                          5)
                        1)
                        unit
                        (set! ok false))
                      (if (=
                        (compiler-export-registry-score
                          exports
                          (compiler-export-kind-field)
                          "data"
                          "Point.x"
                          (compiler-symbol-kind-struct-field)
                          5
                          0)
                        1)
                        unit
                        (set! ok false))
                      (if (=
                        (compiler-export-registry-score
                          exports
                          (compiler-export-kind-variant)
                          "data"
                          "Some"
                          (compiler-symbol-kind-enum-variant)
                          4
                          1)
                        1)
                        unit
                        (set! ok false))
                      (if (=
                        (compiler-export-registry-score
                          exports
                          (compiler-export-kind-variant)
                          "data"
                          "Maybe.Some"
                          (compiler-symbol-kind-enum-variant)
                          4
                          1)
                        1)
                        unit
                        (set! ok false))
                      ok))]
                [(ErrCompilerExports _) false])]
            [(ErrCompilerRegistries _) false])]
        [(ErrCompilerSymbols _) false])]
    [(ErrAstProgram _) false]))

(define (compiler-exports-type-only-source) : String
  "(module data)
(defstruct Opaque (value i64))
(export (type Opaque))")

(define (compiler-exports-type-only-ok?) : bool
  (match (build-compiler-exports-from-source
    (compiler-exports-type-only-source))
    [(OkCompilerExports exports)
      (and
        (=
          (compiler-export-symbol-score
            exports
            (compiler-export-kind-type)
            "data"
            "Opaque"
            (compiler-symbol-kind-defstruct)
            0)
          1)
        (=
          (compiler-symbols-miss-score
            (compiler-exports-lookup
              exports
              (compiler-export-kind-constructor)
              "data"
              "Opaque"))
          1)
        (=
          (compiler-symbols-miss-score
            (compiler-exports-lookup
              exports
              (compiler-export-kind-field)
              "data"
              "Opaque.value"))
          1))]
    [(ErrCompilerExports _) false]))

(define (compiler-exports-error-ok? [src : String] [want : String]) : bool
  (match (build-compiler-exports-from-source src)
    [(ErrCompilerExports message) (string-eq message want)]
    [(OkCompilerExports _) false]))

(define (compiler-exports-unknown-value-ok?) : bool
  (compiler-exports-error-ok?
    "(module data)
(export (value missing))"
    (compiler-export-unknown-message
      (compiler-export-kind-value)
      "data"
      "missing")))

(define (compiler-exports-value-namespace-ok?) : bool
  (compiler-exports-error-ok?
    "(module data)
(defstruct Point (x i64))
(export (value Point))"
    (compiler-export-namespace-message
      (compiler-export-kind-value)
      "data"
      "Point")))

(define (compiler-exports-field-unknown-ok?) : bool
  (compiler-exports-error-ok?
    "(module data)
(defstruct Point (x i64))
(export (field Point y))"
    (compiler-export-unknown-message
      (compiler-export-kind-field)
      "data"
      "Point.y")))

(define (compiler-exports-variant-namespace-ok?) : bool
  (compiler-exports-error-ok?
    "(module data)
(defenum Maybe (Some))
(export (constructor Some))"
    (compiler-export-namespace-message
      (compiler-export-kind-constructor)
      "data"
      "Some")))

(define (compiler-exports-imported-alias-reject-ok?) : bool
  (and
    (compiler-exports-error-ok?
      "(module data)
(define answer : i64 1)
(module main)
(import \"data.tl\" module data :as d)
(export (value answer))"
      (compiler-export-unknown-message
        (compiler-export-kind-value)
        "main"
        "answer"))
    (compiler-exports-error-ok?
      "(import \"data.tl\" module data :as d)
(export (value d/answer))
(module data)
(define answer : i64 1)"
      (compiler-export-unknown-message
        (compiler-export-kind-value)
        ""
        "d/answer"))
    (compiler-exports-error-ok?
      "(import \"data.tl\" module data :as d)
(export (value answer))
(module data)
(define answer : i64 1)"
      (compiler-export-unknown-message (compiler-export-kind-value) "" "answer"))))

(define (compiler-exports-tests-ok?) : bool
  (and
    (compiler-exports-valid-ok?)
    (compiler-exports-type-only-ok?)
    (compiler-exports-unknown-value-ok?)
    (compiler-exports-value-namespace-ok?)
    (compiler-exports-field-unknown-ok?)
    (compiler-exports-variant-namespace-ok?)
    (compiler-exports-imported-alias-reject-ok?)))

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
                (=
                  (compiler-symbol-lookup-score
                    (compiler-symbols-lookup-type symbols "Maybe")
                    (compiler-symbol-kind-defenum)
                    1)
                  1)
                (= (compiler-registries-smoke-score program registries) 8))]
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
                (=
                  (compiler-symbol-lookup-score
                    (compiler-symbols-lookup-value symbols "right/same")
                    (compiler-symbol-kind-value-define)
                    3)
                  1)
                (=
                  (compiler-symbol-lookup-score
                    (compiler-symbols-lookup-type symbols "left/Maybe")
                    (compiler-symbol-kind-defenum)
                    1)
                  1)
                (=
                  (compiler-symbol-lookup-score
                    (compiler-symbols-lookup-type symbols "right/Point")
                    (compiler-symbol-kind-defstruct)
                    5)
                  1)
                (=
                  (compiler-registry-lookup-score
                    (compiler-registries-lookup-variant registries "left/None")
                    (compiler-symbol-kind-enum-variant)
                    1
                    0)
                  1)
                (=
                  (compiler-registry-lookup-score
                    (compiler-registries-lookup-variant registries "right/Some")
                    (compiler-symbol-kind-enum-variant)
                    4
                    1)
                  1)
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
                  1))]
            [(ErrCompilerRegistries _) false])]
        [(ErrCompilerSymbols _) false])]
    [(ErrAstProgram _) false]))

(define (compiler-symbols-structural-id-api-ok?) : bool
  (match (parse-ast-source (compiler-symbols-module-scope-source))
    [(OkAstProgram program)
      (match (build-compiler-symbols program)
        [(OkCompilerSymbols symbols)
          (match (build-compiler-registries program)
            [(OkCompilerRegistries registries)
              (and
                (=
                  (compiler-symbol-lookup-score
                    (compiler-symbols-lookup-value-id
                      symbols
                      (intern "left/same"))
                    (compiler-symbol-kind-value-define)
                    0)
                  1)
                (=
                  (compiler-symbol-lookup-score
                    (compiler-symbols-lookup-value-in-module-id
                      symbols
                      (intern "right")
                      (intern "same"))
                    (compiler-symbol-kind-value-define)
                    3)
                  1)
                (=
                  (compiler-symbol-lookup-score
                    (compiler-symbols-lookup-type-in-module-id
                      symbols
                      (intern "left")
                      (intern "Maybe"))
                    (compiler-symbol-kind-defenum)
                    1)
                  1)
                (=
                  (compiler-registry-lookup-score
                    (compiler-registries-lookup-variant-id
                      registries
                      (intern "right/Some"))
                    (compiler-symbol-kind-enum-variant)
                    4
                    1)
                  1)
                (=
                  (compiler-registry-lookup-score
                    (compiler-registries-lookup-field-in-module-id
                      registries
                      (intern "left")
                      (intern "Point")
                      (intern "x"))
                    (compiler-symbol-kind-struct-field)
                    2
                    0)
                  1))]
            [(ErrCompilerRegistries _) false])]
        [(ErrCompilerSymbols _) false])]
    [(ErrAstProgram _) false]))

(define (compiler-symbols-direct-qualified-add-ok?) : bool
  (let
    [handle : i64
      (compiler-symbol-make-handle (compiler-symbol-kind-value-define) 17)]
    (match (compiler-symbols-add-value
      (compiler-symbols-empty)
      "left/same"
      handle)
      [(OkCompilerSymbols symbols)
        (and
          (=
            (compiler-symbol-lookup-score
              (compiler-symbols-lookup-value symbols "left/same")
              (compiler-symbol-kind-value-define)
              17)
            1)
          (=
            (compiler-symbol-lookup-score
              (compiler-symbols-lookup-value-in-module-id
                symbols
                (intern "left")
                (intern "same"))
              (compiler-symbol-kind-value-define)
              17)
            1))]
      [(ErrCompilerSymbols _) false])))

(define (compiler-symbols-import-alias-source) : String
  "(module data)
(define answer : i64 7)
(define (get) : i64 answer)
(defmacro (all [args : bool ...]) : bool
  (if (expr-list-empty? args)
    (expr-bool true)
    `(if ,(expr-list-head args)
       (all ,@(expr-list-tail args))
       false)))
(defenum Maybe (None) (Some i64))
(defstruct Point (x i64))
(module main)
(import \"data.tl\" module data :as d)
(define (main) : i64 (d.get))")

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
                (=
                  (compiler-symbol-lookup-score
                    (compiler-symbols-lookup-macro symbols "d/all")
                    (compiler-symbol-kind-defmacro)
                    2)
                  1)
                (=
                  (compiler-symbols-miss-score
                    (compiler-symbols-lookup-macro symbols "all"))
                  1)
                (=
                  (compiler-symbol-lookup-score
                    (compiler-symbols-lookup-type symbols "d/Point")
                    (compiler-symbol-kind-defstruct)
                    4)
                  1)
                (=
                  (compiler-registry-lookup-score
                    (compiler-registries-lookup-variant registries "d/Some")
                    (compiler-symbol-kind-enum-variant)
                    3
                    1)
                  1)
                (=
                  (compiler-registry-lookup-score
                    (compiler-registries-lookup-struct-field
                      registries
                      "d/Point"
                      "x")
                    (compiler-symbol-kind-struct-field)
                    4
                    0)
                  1))]
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
              (let
                [ok : bool true]
                (begin
                  (if (= (compiler-symbols-smoke-score symbols) 10)
                    unit
                    (set! ok false))
                  (if (= (compiler-registries-smoke-score program registries) 8)
                    unit
                    (set! ok false))
                  (if (compiler-symbols-duplicate-value-ok?)
                    unit
                    (set! ok false))
                  (if (compiler-symbols-duplicate-type-ok?)
                    unit
                    (set! ok false))
                  (if (compiler-symbols-variant-value-collisions-ok?)
                    unit
                    (set! ok false))
                  (if (compiler-symbols-struct-value-collisions-ok?)
                    unit
                    (set! ok false))
                  (if (compiler-registries-duplicate-variant-ok?)
                    unit
                    (set! ok false))
                  (if (compiler-registries-cross-enum-variant-ok?)
                    unit
                    (set! ok false))
                  (if (compiler-registries-duplicate-field-ok?)
                    unit
                    (set! ok false))
                  (if (compiler-registry-large-owner-handle-ok?)
                    unit
                    (set! ok false))
                  (if (compiler-symbols-comptime-decl-ok?)
                    unit
                    (set! ok false))
                  (if (compiler-symbols-module-scope-ok?)
                    unit
                    (set! ok false))
                  (if (compiler-symbols-structural-id-api-ok?)
                    unit
                    (set! ok false))
                  (if (compiler-symbols-direct-qualified-add-ok?)
                    unit
                    (set! ok false))
                  (if (compiler-symbols-import-alias-ok?)
                    unit
                    (set! ok false))
                  (if (compiler-symbols-macro-namespace-ok?)
                    unit
                    (set! ok false))
                  (if (compiler-symbols-duplicate-macro-value-ok?)
                    unit
                    (set! ok false))
                  (if (compiler-exports-tests-ok?)
                    unit
                    (set! ok false))
                  (if ok
                    42
                    (begin
                      (panic "symbols: smoke score mismatch")
                      0))))]
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