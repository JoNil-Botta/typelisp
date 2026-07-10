;; compiler_symbols.tl - Top-level compiler symbol table over AstProgram.
;;
;; Handles are packed as kind * stride + declaration index, where index is the
;; source-order position among supported declarations. Import declarations have
;; no top-level symbol name here and do not consume an index.
(import stdlib.io)
(import stdlib.arena)
(import compiler_builtin_ids as cbi)
(import "compiler_parse_core.tl")
(import "compiler_diagnostic.tl")
(import sym_i64_env)
(import stdlib.hashmap)
(import stdlib.string)
(import stdlib.option)
(import (option i64) as option_i64)
(import (hashmap i64 i64) as symbol_map)

(defenum CompilerSymbols
  (CompilerSymbols
    symbol_map.Map
    symbol_map.Map
    symbol_map.Map
    (Array AstDecl)
    (Array i64)))

(defenum ResultCompilerSymbols
  (Ok CompilerSymbols)
  (Err String))

;; Keep the compact String result for symbol-table helpers, but offer a
;; source-facing adapter for callers that have declaration paths. Symbol
;; construction itself is deliberately used by small internal probes too.
(defenum ResultCompilerSymbolsDiagnostic
  (Ok CompilerSymbols)
  (Err (Box CompilerDiagnostic)))

(defenum CompilerSymbolsMaybeSpan
  (No)
  (Some AstSourceSpan))

(defenum CompilerMaybeString
  (CompilerNoString)
  (CompilerSomeString String))

(defenum CompilerQualifiedName
  (CompilerQualifiedName i64 i64))

(defenum CompilerRegistries
  (CompilerRegistries symbol_map.Map symbol_map.Map))

(defenum ResultCompilerRegistries
  (Ok CompilerRegistries)
  (Err String))

;; `build-compiler-symbols-with-paths` is single-threaded and reports its
;; failure immediately to a caller. Retain the current declaration only for
;; that short handoff so the public diagnostic adapter can keep its source
;; path and expression-derived span without widening every internal helper.
(define compiler-symbols-last-error-decl : AstDecl
  (ast-decl-module ""))
(define compiler-symbols-last-error-path : String
  "")
(define compiler-symbols-last-error-span : AstSourceSpan
  (ast-decl-span-fallback))
(define compiler-symbols-last-error-has-span : bool
  false)

(define (compiler-symbols-clear-last-error!) : unit
  (begin
    (set! compiler-symbols-last-error-decl (ast-decl-module ""))
    (set! compiler-symbols-last-error-path "")
    (set! compiler-symbols-last-error-span (ast-decl-span-fallback))
    (set! compiler-symbols-last-error-has-span false)))

(define (compiler-symbols-note-last-error! [decl : AstDecl] [path : String]) : unit
  (begin
    (set! compiler-symbols-last-error-decl decl)
    (set! compiler-symbols-last-error-path path)
    (set! compiler-symbols-last-error-span (ast-decl-span-fallback))
    (set! compiler-symbols-last-error-has-span false)))

(define (compiler-symbols-expr-maybe-span [expr : AstExpr]) : CompilerSymbolsMaybeSpan
  (match expr
    [(AstExpr.Spanned _ span) (CompilerSymbolsMaybeSpan.Some span)]
    [(AstExpr.Unary _ inner)
      (compiler-symbols-expr-maybe-span (ast-node-get inner))]
    [(AstExpr.Ann inner _)
      (compiler-symbols-expr-maybe-span (ast-node-get inner))]
    [(AstExpr.Cast inner _)
      (compiler-symbols-expr-maybe-span (ast-node-get inner))]
    [(AstExpr.Borrow _ _ inner)
      (compiler-symbols-expr-maybe-span (ast-node-get inner))]
    [_ CompilerSymbolsMaybeSpan.No]))

(define (compiler-symbols-decl-maybe-span [decl : AstDecl]) : CompilerSymbolsMaybeSpan
  (match decl
    [(AstDecl.Def _ _ body)
      (compiler-symbols-expr-maybe-span (ast-node-get body))]
    [(AstDecl.DefFn _ _ _ body _)
      (compiler-symbols-expr-maybe-span (ast-node-get body))]
    [(AstDecl.DefMacro _ _ _ body)
      (compiler-symbols-expr-maybe-span (ast-node-get body))]
    [(AstDecl.Test _ _ span) (CompilerSymbolsMaybeSpan.Some span)]
    [(AstDecl.Unsafe inner-box)
      (compiler-symbols-decl-maybe-span (box-get inner-box))]
    [(AstDecl.ComptimeDecl _ template-box)
      (compiler-symbols-decl-maybe-span (box-get template-box))]
    [_ CompilerSymbolsMaybeSpan.No]))

(define (compiler-symbols-last-error-diagnostic [message : String]) : CompilerDiagnostic
  (if compiler-symbols-last-error-has-span
    (compiler-diagnostic-from-ast-span
      compiler-symbols-last-error-path
      compiler-symbols-last-error-span
      message)
    (match (compiler-symbols-decl-maybe-span compiler-symbols-last-error-decl)
      [(CompilerSymbolsMaybeSpan.Some span)
        (compiler-diagnostic-from-ast-span
          compiler-symbols-last-error-path
          span
          message)]
      [(CompilerSymbolsMaybeSpan.No)
        (compiler-diagnostic-at-start compiler-symbols-last-error-path message)])))

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

(define (compiler-symbol-kind-struct-cleanup) : i64
  10)

(define (compiler-symbol-kind-enum-cleanup) : i64
  11)

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

(define (compiler-symbol-map-empty) : symbol_map.Map
  (symbol_map.with-capacity 256))

(define (compiler-symbol-map-missing-handle) : i64
  -1)

(define (compiler-symbol-existing-name-id [name : String]) : option_i64.Option
  (match (intern-lookup-preserving-generated-id name)
    [(InternLookupFound name-id) (option_i64.Some name-id)]
    [(InternLookupMissing) option_i64.None]))

(define (compiler-symbol-require-existing-name-id [name : String]) : i64
  (match (compiler-symbol-existing-name-id name)
    [(option_i64.Some name-id) name-id]
    [(option_i64.None)
      (io.panic
        (string.append "symbols: name was not interned while parsing: " name))]))

(define (compiler-symbol-existing-name-id-or [name : String] [fallback : i64]) : i64
  (match (compiler-symbol-existing-name-id name)
    [(option_i64.Some name-id) name-id]
    [(option_i64.None) fallback]))

;; A generated public declaration may reuse a spelling that was already
;; assigned a source id by the parser. Keep its generated identity as the
;; primary symbol, but also expose the declaration under that source id so
;; parsed references can resolve it without constructing or interning a name.
(define (compiler-symbol-source-spelling-id-or-self [name-id : i64]) : i64
  (if (or (< name-id 0) (>= name-id (intern-capacity)))
    name-id
    (match (intern-lookup (intern-str name-id))
      [(InternLookupFound source-id) source-id]
      [(InternLookupMissing) name-id])))

(define (compiler-symbol-existing-module-id [module : String]) : i64
  (if (= (string.string-length module) 0)
    (compiler-symbol-root-module-id)
    (compiler-symbol-require-existing-name-id module)))

(define (compiler-symbol-existing-module-id-or
  [module : String]
  [fallback : i64]) : i64
  (if (= (string.string-length module) 0)
    (compiler-symbol-root-module-id)
    (compiler-symbol-existing-name-id-or module fallback)))

(define (compiler-symbol-map-lookup-id
  [map : (& map symbol_map.Map)]
  [name-id : i64]) : option_i64.Option
  (let
    [handle : i64
      (symbol_map.get-value-or map name-id (compiler-symbol-map-missing-handle))]
    (if (>= handle 0)
      (option_i64.Some handle)
      option_i64.None)))

(define (compiler-symbol-map-lookup
  [map : (& map symbol_map.Map)]
  [name : String]) : option_i64.Option
  (match (compiler-symbol-existing-name-id name)
    [(option_i64.Some name-id)
      (compiler-symbol-map-lookup-id map (compiler-symbol-name-id-key name-id))]
    [(option_i64.None) option_i64.None]))

(define (compiler-symbol-map-contains-id?
  [map : (& map symbol_map.Map)]
  [name-id : i64]) : bool
  (match (compiler-symbol-map-lookup-id map name-id)
    [(option_i64.Some _) true]
    [(option_i64.None) false]))

(define (compiler-symbol-map-contains?
  [map : (& map symbol_map.Map)]
  [name : String]) : bool
  (compiler-symbol-map-contains-id? map (compiler-symbol-name-key-id name)))

(define (compiler-symbol-map-bind-id!
  [map : (&mut map symbol_map.Map)]
  [name-id : i64]
  [handle : i64]) : unit
  (symbol_map.insert-ref! map name-id handle))

(define (compiler-symbol-map-bind!
  [map : (&mut map symbol_map.Map)]
  [name : String]
  [handle : i64]) : unit
  (compiler-symbol-map-bind-id!
    map
    (compiler-symbol-name-id-key
      (compiler-symbol-require-existing-name-id name))
    handle))

(define (compiler-decl-list-index-count [decls : AstDeclList]) : i64
  (let
    [count : i64 0]
    [index : i64 0]
    [decl-count : i64 (ast-decl-list-len (& decls))]
    [decl-offset : i64 (struct-get decls offset)]
    (begin
      (while (< index decl-count)
        (let
          [decl : AstDecl
            (array-ref (struct-get decls slots) (+ decl-offset index))]
          (begin
            (match decl
              [(AstDecl.Import _) unit]
              [(AstDecl.Module _) unit]
              [(AstDecl.ModuleBody _ body-box)
                (set!
                  count
                  (+ count (compiler-decl-list-index-count (box-get body-box))))]
              [(AstDecl.Test _ _ _) unit]
              [_ (set! count (+ count 1))])
            (set! index (+ index 1)))))
      count)))

(define (compiler-symbols-empty-with-decls [decl-count : i64]) : CompilerSymbols
  (CompilerSymbols
    (compiler-symbol-map-empty)
    (compiler-symbol-map-empty)
    (compiler-symbol-map-empty)
    (make-array AstDecl decl-count)
    (make-array i64 decl-count)))

(define (compiler-symbols-empty) : CompilerSymbols
  (compiler-symbols-empty-with-decls 0))

(define (compiler-registries-empty) : CompilerRegistries
  (CompilerRegistries (compiler-symbol-map-empty) (compiler-symbol-map-empty)))

(define (compiler-symbols-lookup-value
  [symbols : CompilerSymbols]
  [name : String]) : option_i64.Option
  (match (compiler-symbol-existing-name-id name)
    [(option_i64.Some name-id)
      (compiler-symbols-lookup-value-id symbols name-id)]
    [(option_i64.None) option_i64.None]))

(define (compiler-symbols-lookup-value-id
  [symbols : CompilerSymbols]
  [name-id : i64]) : option_i64.Option
  (match symbols
    [(CompilerSymbols values _ _ _ _)
      (match (compiler-symbol-map-lookup-id
        (& values)
        (compiler-symbol-name-id-key name-id))
        [(option_i64.Some handle) (option_i64.Some handle)]
        [(option_i64.None)
          (match (compiler-symbol-dotted-variant-key-id name-id)
            [(option_i64.Some key-id)
              (compiler-symbol-map-lookup-id (& values) key-id)]
            [(option_i64.None) option_i64.None])])]))

(define (compiler-symbols-lookup-type
  [symbols : CompilerSymbols]
  [name : String]) : option_i64.Option
  (match (compiler-symbol-existing-name-id name)
    [(option_i64.Some name-id)
      (compiler-symbols-lookup-type-id symbols name-id)]
    [(option_i64.None) option_i64.None]))

(define (compiler-symbols-lookup-type-id
  [symbols : CompilerSymbols]
  [name-id : i64]) : option_i64.Option
  (match symbols
    [(CompilerSymbols _ types _ _ _)
      (compiler-symbol-map-lookup-id
        (& types)
        (compiler-symbol-name-id-key name-id))]))

(define (compiler-symbols-lookup-macro
  [symbols : CompilerSymbols]
  [name : String]) : option_i64.Option
  (match (compiler-symbol-existing-name-id name)
    [(option_i64.Some name-id)
      (compiler-symbols-lookup-macro-id symbols name-id)]
    [(option_i64.None) option_i64.None]))

(define (compiler-symbols-lookup-macro-id
  [symbols : CompilerSymbols]
  [name-id : i64]) : option_i64.Option
  (match symbols
    [(CompilerSymbols _ _ macros _ _)
      (compiler-symbol-map-lookup-id
        (& macros)
        (compiler-symbol-name-id-key name-id))]))

(define (compiler-symbols-missing-handle) : i64
  (compiler-symbol-map-missing-handle))

(define (compiler-symbols-handle-found? [handle : i64]) : bool
  (>= handle 0))

(define (compiler-symbols-option-or
  [found : option_i64.Option]
  [fallback : i64]) : i64
  (match found
    [(option_i64.Some handle) handle]
    [option_i64.None fallback]))

(define (compiler-symbols-lookup-value-or
  [symbols : CompilerSymbols]
  [name : String]
  [fallback : i64]) : i64
  (compiler-symbols-option-or
    (compiler-symbols-lookup-value symbols name)
    fallback))

(define (compiler-symbols-lookup-value-id-or
  [symbols : CompilerSymbols]
  [name-id : i64]
  [fallback : i64]) : i64
  (compiler-symbols-option-or
    (compiler-symbols-lookup-value-id symbols name-id)
    fallback))

(define (compiler-symbols-lookup-type-or
  [symbols : CompilerSymbols]
  [name : String]
  [fallback : i64]) : i64
  (compiler-symbols-option-or
    (compiler-symbols-lookup-type symbols name)
    fallback))

(define (compiler-symbols-lookup-type-id-or
  [symbols : CompilerSymbols]
  [name-id : i64]
  [fallback : i64]) : i64
  (compiler-symbols-option-or
    (compiler-symbols-lookup-type-id symbols name-id)
    fallback))

(define (compiler-symbols-lookup-macro-or
  [symbols : CompilerSymbols]
  [name : String]
  [fallback : i64]) : i64
  (compiler-symbols-option-or
    (compiler-symbols-lookup-macro symbols name)
    fallback))

(define (compiler-symbols-lookup-macro-id-or
  [symbols : CompilerSymbols]
  [name-id : i64]
  [fallback : i64]) : i64
  (compiler-symbols-option-or
    (compiler-symbols-lookup-macro-id symbols name-id)
    fallback))

(define (compiler-symbols-decls [symbols : CompilerSymbols]) : (Array AstDecl)
  (match symbols
    [(CompilerSymbols _ _ _ decls _) decls]))

(define (compiler-symbols-owner-module-ids [symbols : CompilerSymbols]) : (Array
    i64)
  (match symbols
    [(CompilerSymbols _ _ _ _ owner-module-ids) owner-module-ids]))

(define (compiler-symbols-duplicate-value-message [name : String]) : String
  (string.append "symbols: duplicate value declaration " name))

(define (compiler-symbols-duplicate-type-message [name : String]) : String
  (string.append "symbols: duplicate type declaration " name))

(define (compiler-symbols-duplicate-macro-message [name : String]) : String
  (string.append "symbols: duplicate macro declaration " name))

(define (compiler-symbols-duplicate-macro-value-message [name : String]) : String
  (string.append "symbols: duplicate macro/value declaration " name))

(define (compiler-registries-duplicate-variant-message [name : String]) : String
  (string.append "symbols: duplicate enum variant " name))

(define (compiler-struct-field-key [struct-name : String] [field-name : String]) : String
  ;; Flat field registry key. Field names may repeat across structs because the
  ;; struct name is part of the key.
  (string.append (string.append struct-name ".") field-name))

(define (compiler-composite-pair-key-id [left-id : i64] [right-id : i64]) : i64
  (+ (intern-capacity) (+ (* left-id (intern-capacity)) right-id)))

(define (compiler-composite-pair-key-id? [key-id : i64]) : bool
  (and
    (>= key-id (intern-capacity))
    (< key-id (+ (intern-capacity) (* (intern-capacity) (intern-capacity))))))

(define (compiler-composite-pair-left-id [key-id : i64]) : i64
  (/ (- key-id (intern-capacity)) (intern-capacity)))

(define (compiler-composite-pair-right-id [key-id : i64]) : i64
  (% (- key-id (intern-capacity)) (intern-capacity)))

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

(define (compiler-composite-triple-key-id? [key-id : i64]) : bool
  (let
    [stride : i64 (intern-capacity)]
    [stride2 : i64 (* stride stride)]
    [offset : i64 (+ stride stride2)]
    (and (>= key-id offset) (< key-id (+ offset (* stride2 stride))))))

(define (compiler-composite-triple-left-id [key-id : i64]) : i64
  (let
    [stride : i64 (intern-capacity)]
    [stride2 : i64 (* stride stride)]
    [offset : i64 (+ stride stride2)]
    (/ (- key-id offset) stride2)))

(define (compiler-composite-triple-middle-id [key-id : i64]) : i64
  (let
    [stride : i64 (intern-capacity)]
    [stride2 : i64 (* stride stride)]
    [offset : i64 (+ stride stride2)]
    (% (/ (- key-id offset) stride) stride)))

(define (compiler-composite-triple-right-id [key-id : i64]) : i64
  (let
    [stride : i64 (intern-capacity)]
    [stride2 : i64 (* stride stride)]
    [offset : i64 (+ stride stride2)]
    (% (- key-id offset) stride)))

(define (compiler-struct-field-key-id-by-id
  [struct-name-id : i64]
  [field-name-id : i64]) : i64
  (if (compiler-composite-pair-key-id? struct-name-id)
    (compiler-composite-triple-key-id
      (compiler-composite-pair-left-id struct-name-id)
      (compiler-composite-pair-right-id struct-name-id)
      field-name-id)
    (if (>= struct-name-id (intern-capacity))
      (compiler-composite-pair-key-id struct-name-id field-name-id)
      (if (intern-qualified? struct-name-id)
        (compiler-composite-triple-key-id
          (intern-qualified-module-id struct-name-id)
          (intern-qualified-base-id struct-name-id)
          field-name-id)
        (compiler-composite-pair-key-id struct-name-id field-name-id)))))

(define (compiler-struct-field-key-id
  [struct-name : String]
  [field-name : String]) : i64
  (compiler-struct-field-key-id-by-id
    (compiler-symbol-require-existing-name-id struct-name)
    (compiler-symbol-require-existing-name-id field-name)))

(define (compiler-struct-field-key-id-in-module-by-id
  [module-id : i64]
  [struct-name-id : i64]
  [field-name-id : i64]) : i64
  (if (or
    (< module-id 0)
    (and
      (< module-id (intern-capacity))
      (= (string.string-length (intern-str module-id)) 0)))
    (compiler-composite-pair-key-id struct-name-id field-name-id)
    (compiler-composite-triple-key-id module-id struct-name-id field-name-id)))

(define (compiler-registries-duplicate-field-message
  [struct-name : String]
  [field-name : String]) : String
  (string.append
    "symbols: duplicate field "
    (compiler-struct-field-key struct-name field-name)))

(define (compiler-symbol-module-key [module : String] [name : String]) : String
  (if (= (string.string-length module) 0)
    name
    (string.append module (string.append "/" name))))

(define (compiler-symbol-root-module-id) : i64
  -1)

(define (compiler-symbol-root-module-id? [module-id : i64]) : bool
  (or
    (< module-id 0)
    (and
      (< module-id (intern-capacity))
      (= (string.string-length (intern-str module-id)) 0))))

(define (compiler-symbol-module-key-by-id [module-id : i64] [name-id : i64]) : String
  (let
    [name : String
      (if (compiler-composite-triple-key-id? name-id)
        (compiler-symbol-module-key
          (intern-str (compiler-composite-triple-left-id name-id))
          (compiler-enum-qualified-variant-name
            (intern-str (compiler-composite-triple-middle-id name-id))
            (intern-str (compiler-composite-triple-right-id name-id))))
        (if (compiler-composite-pair-key-id? name-id)
          (compiler-enum-qualified-variant-name
            (intern-str (compiler-composite-pair-left-id name-id))
            (intern-str (compiler-composite-pair-right-id name-id)))
          (if (and (>= name-id 0) (< name-id (intern-capacity)))
            (intern-str name-id)
            "<structural-symbol>")))]
    (if (or
      (compiler-composite-triple-key-id? name-id)
      (compiler-symbol-root-module-id? module-id))
      name
      (if (and (>= module-id 0) (< module-id (intern-capacity)))
        (compiler-symbol-module-key (intern-str module-id) name)
        name))))

(define (compiler-enum-qualified-variant-name
  [enum-name : String]
  [variant-name : String]) : String
  (string.append enum-name (string.append "." variant-name)))

(define (compiler-enum-qualified-variant-name-id
  [enum-name-id : i64]
  [variant-name-id : i64]) : i64
  (compiler-composite-pair-key-id enum-name-id variant-name-id))

(define (compiler-qualified-name [module : String] [name : String]) : CompilerQualifiedName
  (CompilerQualifiedName
    (compiler-symbol-require-existing-name-id module)
    (compiler-symbol-require-existing-name-id name)))

(define (compiler-symbol-module-key-id-by-id [module-id : i64] [name-id : i64]) : i64
  (if (compiler-symbol-root-module-id? module-id)
    name-id
    (if (compiler-composite-pair-key-id? name-id)
      (compiler-composite-triple-key-id
        module-id
        (compiler-composite-pair-left-id name-id)
        (compiler-composite-pair-right-id name-id))
      (compiler-composite-pair-key-id module-id name-id))))

(define (compiler-symbol-module-key-id [module : String] [name : String]) : i64
  (compiler-symbol-module-key-id-by-id
    (compiler-symbol-require-existing-name-id module)
    (compiler-symbol-require-existing-name-id name)))

(define (compiler-symbol-module-key-id-by-name-id
  [module : String]
  [name-id : i64]) : i64
  (compiler-symbol-module-key-id-by-id
    (compiler-symbol-require-existing-name-id module)
    name-id))

(define (compiler-symbol-name-id-key [name-id : i64]) : i64
  (if (or (< name-id 0) (>= name-id (intern-capacity)))
    name-id
    (if (intern-qualified? name-id)
      (compiler-composite-pair-key-id
        (intern-qualified-module-id name-id)
        (intern-qualified-base-id name-id))
      name-id)))

(define (compiler-symbol-name-key-id [name : String]) : i64
  (compiler-symbol-name-id-key (compiler-symbol-require-existing-name-id name)))

(define (compiler-symbol-existing-name-slice-id
  [name : String]
  [start : i64]
  [len : i64]) : option_i64.Option
  (compiler-symbol-existing-name-id (string.substring name start len)))

(define (compiler-symbol-dotted-variant-key-id-in-module
  [name-id : i64]
  [default-module-id : i64]) : option_i64.Option
  (if (or (< name-id 0) (>= name-id (intern-capacity)))
    option_i64.None
    (let
      [module-id : i64
        (if (intern-qualified? name-id)
          (intern-qualified-module-id name-id)
          default-module-id)]
      [base-id : i64
        (if (intern-qualified? name-id)
          (intern-qualified-base-id name-id)
          name-id)]
      [base : String (intern-str base-id)]
      [n : i64 (string.string-length base)]
      [i : i64 0]
      [previous-dot : i64 -1]
      [last-dot : i64 -1]
      (begin
        (while (< i n)
          (begin
            (if (string.char-eq (string.string-ref base i) '.')
              (begin
                (set! previous-dot last-dot)
                (set! last-dot i))
              unit)
            (set! i (+ i 1))))
        (if (< last-dot 0)
          option_i64.None
          (let
            [module-end : i64
              (if (intern-qualified? name-id)
                -1
                previous-dot)]
            [enum-start : i64
              (if (>= module-end 0)
                (+ module-end 1)
                0)]
            [enum-len : i64 (- last-dot enum-start)]
            [variant-start : i64 (+ last-dot 1)]
            [variant-len : i64 (- n variant-start)]
            [resolved-module-id : i64
              (if (>= module-end 0)
                (compiler-symbol-existing-name-id-or
                  (string.substring base 0 module-end)
                  -2)
                module-id)]
            (if (or
              (< resolved-module-id -1)
              (or (<= enum-len 0) (<= variant-len 0)))
              option_i64.None
              (match (compiler-symbol-existing-name-slice-id
                base
                enum-start
                enum-len)
                [(option_i64.Some enum-name-id)
                  (match (compiler-symbol-existing-name-slice-id
                    base
                    variant-start
                    variant-len)
                    [(option_i64.Some variant-name-id)
                      (option_i64.Some
                        (compiler-symbol-module-key-id-by-id
                          resolved-module-id
                          (compiler-enum-qualified-variant-name-id
                            enum-name-id
                            variant-name-id)))]
                    [(option_i64.None) option_i64.None])]
                [(option_i64.None) option_i64.None]))))))))

(define (compiler-symbol-dotted-variant-key-id [name-id : i64]) : option_i64.Option
  (compiler-symbol-dotted-variant-key-id-in-module
    name-id
    (compiler-symbol-root-module-id)))

(define (compiler-symbol-dotted-variant-key-id-in-module-or
  [name-id : i64]
  [default-module-id : i64]
  [fallback : i64]) : i64
  (match (compiler-symbol-dotted-variant-key-id-in-module
    name-id
    default-module-id)
    [(option_i64.Some key-id) key-id]
    [(option_i64.None) fallback]))

(define (compiler-qualified-name-key-id [name : CompilerQualifiedName]) : i64
  (match name
    [(CompilerQualifiedName module-id base-id)
      (compiler-symbol-module-key-id-by-id module-id base-id)]))

(define (compiler-symbols-add-value-alias
  [symbols : CompilerSymbols]
  [name : String]
  [handle : i64]) : CompilerSymbols
  (match symbols
    [(CompilerSymbols values types macros decls owner-names)
      (if (compiler-symbol-map-contains? (& values) name)
        symbols
        (begin
          (compiler-symbol-map-bind! (&mut values) name handle)
          (CompilerSymbols values types macros decls owner-names)))]))

(define (compiler-symbols-add-value-alias-key-id
  [symbols : CompilerSymbols]
  [key-id : i64]
  [handle : i64]) : CompilerSymbols
  (match symbols
    [(CompilerSymbols values types macros decls owner-names)
      (if (compiler-symbol-map-contains-id? (& values) key-id)
        symbols
        (begin
          (compiler-symbol-map-bind-id! (&mut values) key-id handle)
          (CompilerSymbols values types macros decls owner-names)))]))

(define (compiler-symbols-add-type-alias
  [symbols : CompilerSymbols]
  [name : String]
  [handle : i64]) : CompilerSymbols
  (match symbols
    [(CompilerSymbols values types macros decls owner-names)
      (if (compiler-symbol-map-contains? (& types) name)
        symbols
        (begin
          (compiler-symbol-map-bind! (&mut types) name handle)
          (CompilerSymbols values types macros decls owner-names)))]))

(define (compiler-symbols-add-type-alias-key-id
  [symbols : CompilerSymbols]
  [key-id : i64]
  [handle : i64]) : CompilerSymbols
  (match symbols
    [(CompilerSymbols values types macros decls owner-names)
      (if (compiler-symbol-map-contains-id? (& types) key-id)
        symbols
        (begin
          (compiler-symbol-map-bind-id! (&mut types) key-id handle)
          (CompilerSymbols values types macros decls owner-names)))]))

(define (compiler-symbols-add-macro-alias
  [symbols : CompilerSymbols]
  [name : String]
  [handle : i64]) : CompilerSymbols
  (match symbols
    [(CompilerSymbols values types macros decls owner-names)
      (if (compiler-symbol-map-contains? (& macros) name)
        symbols
        (begin
          (compiler-symbol-map-bind! (&mut macros) name handle)
          (CompilerSymbols values types macros decls owner-names)))]))

(define (compiler-symbols-add-macro-alias-key-id
  [symbols : CompilerSymbols]
  [key-id : i64]
  [handle : i64]) : CompilerSymbols
  (match symbols
    [(CompilerSymbols values types macros decls owner-names)
      (if (compiler-symbol-map-contains-id? (& macros) key-id)
        symbols
        (begin
          (compiler-symbol-map-bind-id! (&mut macros) key-id handle)
          (CompilerSymbols values types macros decls owner-names)))]))

(define (compiler-symbols-remove-macro-alias-if-handle
  [symbols : CompilerSymbols]
  [name-id : i64]
  [handle : i64]) : CompilerSymbols
  (match symbols
    [(CompilerSymbols values types macros decls owner-names)
      (match (compiler-symbol-map-lookup-id
        (& macros)
        (compiler-symbol-name-id-key name-id))
        [(option_i64.Some existing)
          (if (= existing handle)
            (if (symbol_map.remove-ok?
              (symbol_map.remove-ref!
                (&mut macros)
                (compiler-symbol-name-id-key name-id)))
              (CompilerSymbols values types macros decls owner-names)
              symbols)
            symbols)]
        [(option_i64.None) symbols])]))

(define (compiler-registries-add-variant-alias
  [registries : CompilerRegistries]
  [name : String]
  [handle : i64]) : CompilerRegistries
  (match registries
    [(CompilerRegistries variants fields)
      (if (compiler-symbol-map-contains? (& variants) name)
        registries
        (begin
          (compiler-symbol-map-bind! (&mut variants) name handle)
          (CompilerRegistries variants fields)))]))

(define (compiler-registries-add-variant-alias-key-id
  [registries : CompilerRegistries]
  [key-id : i64]
  [handle : i64]) : CompilerRegistries
  (match registries
    [(CompilerRegistries variants fields)
      (if (compiler-symbol-map-contains-id? (& variants) key-id)
        registries
        (begin
          (compiler-symbol-map-bind-id! (&mut variants) key-id handle)
          (CompilerRegistries variants fields)))]))

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
      (if (compiler-symbol-map-contains-id? (& values) name-id)
        (ResultCompilerSymbols.Err
          (compiler-symbols-duplicate-value-message display-name))
        (if (compiler-symbol-map-contains-id? (& macros) name-id)
          (ResultCompilerSymbols.Err
            (compiler-symbols-duplicate-macro-value-message display-name))
          (begin
            (compiler-symbol-map-bind-id! (&mut values) name-id handle)
            (ResultCompilerSymbols.Ok
              (CompilerSymbols values types macros decls owner-names)))))]))

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
      (match (compiler-symbol-map-lookup-id (& values) name-id)
        [(option_i64.Some existing)
          (if (=
            (compiler-symbol-handle-kind existing)
            (compiler-symbol-kind-enum-variant))
            (ResultCompilerSymbols.Err
              (compiler-registries-duplicate-variant-message display-name))
            (ResultCompilerSymbols.Err
              (compiler-symbols-duplicate-value-message display-name)))]
        [(option_i64.None)
          (if (compiler-symbol-map-contains-id? (& macros) name-id)
            (ResultCompilerSymbols.Err
              (compiler-symbols-duplicate-macro-value-message display-name))
            (begin
              (compiler-symbol-map-bind-id! (&mut values) name-id handle)
              (ResultCompilerSymbols.Ok
                (CompilerSymbols values types macros decls owner-names))))])]))

(define (compiler-symbols-add-variant-flat-value-alias-id
  [symbols : CompilerSymbols]
  [name-id : i64]
  [display-name : String]
  [handle : i64]) : ResultCompilerSymbols
  (match symbols
    [(CompilerSymbols values types macros decls owner-names)
      (match (compiler-symbol-map-lookup-id (& values) name-id)
        [(option_i64.Some existing)
          (if (=
            (compiler-symbol-handle-kind existing)
            (compiler-symbol-kind-enum-variant))
            (ResultCompilerSymbols.Ok symbols)
            (ResultCompilerSymbols.Err
              (compiler-symbols-duplicate-value-message display-name)))]
        [(option_i64.None)
          (if (compiler-symbol-map-contains-id? (& macros) name-id)
            (ResultCompilerSymbols.Err
              (compiler-symbols-duplicate-macro-value-message display-name))
            (begin
              (compiler-symbol-map-bind-id! (&mut values) name-id handle)
              (ResultCompilerSymbols.Ok
                (CompilerSymbols values types macros decls owner-names))))])]))

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
      (if (compiler-symbol-map-contains-id? (& types) name-id)
        (ResultCompilerSymbols.Err
          (compiler-symbols-duplicate-type-message display-name))
        (begin
          (compiler-symbol-map-bind-id! (&mut types) name-id handle)
          (ResultCompilerSymbols.Ok
            (CompilerSymbols values types macros decls owner-names))))]))

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
      (if (compiler-symbol-map-contains-id? (& macros) name-id)
        (ResultCompilerSymbols.Err
          (compiler-symbols-duplicate-macro-message display-name))
        (if (compiler-symbol-map-contains-id? (& values) name-id)
          (ResultCompilerSymbols.Err
            (compiler-symbols-duplicate-macro-value-message display-name))
          (begin
            (compiler-symbol-map-bind-id! (&mut macros) name-id handle)
            (ResultCompilerSymbols.Ok
              (CompilerSymbols values types macros decls owner-names)))))]))

(define (compiler-symbols-handle-from-nonroot-owner?
  [symbols : CompilerSymbols]
  [handle : i64]) : bool
  (not
    (compiler-symbol-root-module-id?
      (compiler-symbols-owner-module-id-at-index-or
        symbols
        (compiler-symbol-handle-index handle)
        (compiler-symbol-root-module-id)))))

(define (compiler-symbols-add-root-macro-id
  [symbols : CompilerSymbols]
  [name-id : i64]
  [display-name : String]
  [handle : i64]) : ResultCompilerSymbols
  (match symbols
    [(CompilerSymbols values types macros decls owner-names)
      (match (compiler-symbol-map-lookup-id (& macros) name-id)
        [(option_i64.Some existing)
          (if (compiler-symbols-handle-from-nonroot-owner? symbols existing)
            (if (compiler-symbol-map-contains-id? (& values) name-id)
              (ResultCompilerSymbols.Err
                (compiler-symbols-duplicate-macro-value-message display-name))
              (begin
                (compiler-symbol-map-bind-id! (&mut macros) name-id handle)
                (ResultCompilerSymbols.Ok
                  (CompilerSymbols values types macros decls owner-names))))
            (ResultCompilerSymbols.Err
              (compiler-symbols-duplicate-macro-message display-name)))]
        [(option_i64.None)
          (if (compiler-symbol-map-contains-id? (& values) name-id)
            (ResultCompilerSymbols.Err
              (compiler-symbols-duplicate-macro-value-message display-name))
            (begin
              (compiler-symbol-map-bind-id! (&mut macros) name-id handle)
              (ResultCompilerSymbols.Ok
                (CompilerSymbols values types macros decls owner-names))))])]))

(define (compiler-symbols-add-root-value-id
  [symbols : CompilerSymbols]
  [name-id : i64]
  [display-name : String]
  [handle : i64]) : ResultCompilerSymbols
  (match symbols
    [(CompilerSymbols values types macros decls owner-names)
      (match (compiler-symbol-map-lookup-id (& values) name-id)
        [(option_i64.Some existing)
          (if (compiler-symbols-handle-from-nonroot-owner? symbols existing)
            (if (compiler-symbol-map-contains-id? (& macros) name-id)
              (ResultCompilerSymbols.Err
                (compiler-symbols-duplicate-macro-value-message display-name))
              (begin
                (compiler-symbol-map-bind-id! (&mut values) name-id handle)
                (ResultCompilerSymbols.Ok
                  (CompilerSymbols values types macros decls owner-names))))
            (ResultCompilerSymbols.Err
              (compiler-symbols-duplicate-value-message display-name)))]
        [(option_i64.None)
          (if (compiler-symbol-map-contains-id? (& macros) name-id)
            (ResultCompilerSymbols.Err
              (compiler-symbols-duplicate-macro-value-message display-name))
            (begin
              (compiler-symbol-map-bind-id! (&mut values) name-id handle)
              (ResultCompilerSymbols.Ok
                (CompilerSymbols values types macros decls owner-names))))])]))

(define (compiler-symbols-add-value-in-module
  [symbols : CompilerSymbols]
  [module : String]
  [name : String]
  [handle : i64]) : ResultCompilerSymbols
  (compiler-symbols-add-value-in-module-id
    symbols
    (compiler-symbol-existing-module-id module)
    (compiler-symbol-require-existing-name-id name)
    handle))

(define (compiler-symbols-add-value-in-module-id
  [symbols : CompilerSymbols]
  [module-id : i64]
  [name-id : i64]
  [handle : i64]) : ResultCompilerSymbols
  (let
    [key-id : i64 (compiler-symbol-module-key-id-by-id module-id name-id)]
    [display-name : String (compiler-symbol-module-key-by-id module-id name-id)]
    (match (if (compiler-symbol-root-module-id? module-id)
      (compiler-symbols-add-root-value-id symbols key-id display-name handle)
      (compiler-symbols-add-value-id symbols key-id display-name handle))
      [(ResultCompilerSymbols.Ok next)
        (if (compiler-symbols-comptime-module-id? module-id)
          (ResultCompilerSymbols.Ok next)
          (ResultCompilerSymbols.Ok
            (compiler-symbols-add-value-alias-key-id
              next
              (compiler-symbol-name-id-key name-id)
              handle)))]
      [(ResultCompilerSymbols.Err message) (ResultCompilerSymbols.Err message)])))

(define (compiler-symbols-comptime-module? [module : String]) : bool
  (string.eq module "stdlib.comptime"))

(define (compiler-symbols-comptime-module-id? [module-id : i64]) : bool
  (and
    (not (compiler-symbol-root-module-id? module-id))
    (and
      (< module-id (intern-capacity))
      (compiler-symbols-comptime-module? (intern-str module-id)))))

(define (compiler-symbols-add-type-in-module
  [symbols : CompilerSymbols]
  [module : String]
  [name : String]
  [handle : i64]) : ResultCompilerSymbols
  (compiler-symbols-add-type-in-module-id
    symbols
    (compiler-symbol-existing-module-id module)
    (compiler-symbol-require-existing-name-id name)
    handle))

(define (compiler-symbols-add-type-in-module-id
  [symbols : CompilerSymbols]
  [module-id : i64]
  [name-id : i64]
  [handle : i64]) : ResultCompilerSymbols
  (let
    [key-id : i64 (compiler-symbol-module-key-id-by-id module-id name-id)]
    [source-name-id : i64 (compiler-symbol-source-spelling-id-or-self name-id)]
    [display-name : String (compiler-symbol-module-key-by-id module-id name-id)]
    (match (compiler-symbols-add-type-id symbols key-id display-name handle)
      [(ResultCompilerSymbols.Ok next)
        (let
          [with-source-spelling : CompilerSymbols
            (if (= source-name-id name-id)
              next
              (compiler-symbols-add-type-alias-key-id
                next
                (compiler-symbol-module-key-id-by-id module-id source-name-id)
                handle))]
          (if (compiler-symbols-comptime-module-id? module-id)
            (ResultCompilerSymbols.Ok with-source-spelling)
            (ResultCompilerSymbols.Ok
              (compiler-symbols-add-type-alias-key-id
                with-source-spelling
                (compiler-symbol-name-id-key name-id)
                handle))))]
      [(ResultCompilerSymbols.Err message) (ResultCompilerSymbols.Err message)])))

(define (compiler-symbols-add-variant-value-key-in-module-id
  [symbols : CompilerSymbols]
  [key-id : i64]
  [module-id : i64]
  [display-name-id : i64]
  [handle : i64]) : ResultCompilerSymbols
  (match symbols
    [(CompilerSymbols values types macros decls owner-names)
      (match (compiler-symbol-map-lookup-id (& values) key-id)
        [(option_i64.Some existing)
          (if (=
            (compiler-symbol-handle-kind existing)
            (compiler-symbol-kind-enum-variant))
            (ResultCompilerSymbols.Err
              (compiler-registries-duplicate-variant-message
                (compiler-symbol-module-key-by-id module-id display-name-id)))
            (ResultCompilerSymbols.Err
              (compiler-symbols-duplicate-value-message
                (compiler-symbol-module-key-by-id module-id display-name-id))))]
        [(option_i64.None)
          (if (compiler-symbol-map-contains-id? (& macros) key-id)
            (ResultCompilerSymbols.Err
              (compiler-symbols-duplicate-macro-value-message
                (compiler-symbol-module-key-by-id module-id display-name-id)))
            (begin
              (compiler-symbol-map-bind-id! (&mut values) key-id handle)
              (ResultCompilerSymbols.Ok
                (CompilerSymbols values types macros decls owner-names))))])]))

(define (compiler-symbols-add-variant-flat-value-alias-key-in-module-id
  [symbols : CompilerSymbols]
  [key-id : i64]
  [module-id : i64]
  [display-name-id : i64]
  [handle : i64]) : ResultCompilerSymbols
  (match symbols
    [(CompilerSymbols values types macros decls owner-names)
      (match (compiler-symbol-map-lookup-id (& values) key-id)
        [(option_i64.Some existing)
          (if (=
            (compiler-symbol-handle-kind existing)
            (compiler-symbol-kind-enum-variant))
            (ResultCompilerSymbols.Ok symbols)
            (ResultCompilerSymbols.Err
              (compiler-symbols-duplicate-value-message
                (compiler-symbol-module-key-by-id module-id display-name-id))))]
        [(option_i64.None)
          (if (compiler-symbol-map-contains-id? (& macros) key-id)
            (ResultCompilerSymbols.Err
              (compiler-symbols-duplicate-macro-value-message
                (compiler-symbol-module-key-by-id module-id display-name-id)))
            (begin
              (compiler-symbol-map-bind-id! (&mut values) key-id handle)
              (ResultCompilerSymbols.Ok
                (CompilerSymbols values types macros decls owner-names))))])]))

(define (compiler-symbols-add-variant-value-in-module
  [symbols : CompilerSymbols]
  [module : String]
  [enum-name : String]
  [name : String]
  [enum-index : i64]
  [variant-index : i64]) : ResultCompilerSymbols
  (compiler-symbols-add-variant-value-in-module-id
    symbols
    (compiler-symbol-existing-module-id module)
    (compiler-symbol-require-existing-name-id enum-name)
    (compiler-symbol-require-existing-name-id name)
    enum-index
    variant-index))

(define (compiler-symbols-add-variant-value-in-module-id
  [symbols : CompilerSymbols]
  [module-id : i64]
  [enum-name-id : i64]
  [name-id : i64]
  [enum-index : i64]
  [variant-index : i64]) : ResultCompilerSymbols
  (let
    [qualified-name-id : i64
      (compiler-enum-qualified-variant-name-id enum-name-id name-id)]
    [qualified-key-id : i64
      (compiler-symbol-module-key-id-by-id module-id qualified-name-id)]
    [qualified-display-name : String
      (compiler-symbol-module-key-by-id module-id qualified-name-id)]
    [flat-key-id : i64 (compiler-symbol-module-key-id-by-id module-id name-id)]
    [flat-display-name : String
      (compiler-symbol-module-key-by-id module-id name-id)]
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
      [(ResultCompilerSymbols.Ok next)
        (match (compiler-symbols-add-variant-flat-value-alias-id
          next
          flat-key-id
          flat-display-name
          handle)
          [(ResultCompilerSymbols.Ok with-flat)
            (if (compiler-symbols-comptime-module-id? module-id)
              (ResultCompilerSymbols.Ok with-flat)
              (ResultCompilerSymbols.Ok
                (compiler-symbols-add-value-alias-key-id
                  with-flat
                  (compiler-symbol-name-id-key name-id)
                  handle)))]
          [(ResultCompilerSymbols.Err message)
            (ResultCompilerSymbols.Err message)])]
      [(ResultCompilerSymbols.Err message) (ResultCompilerSymbols.Err message)])))

(define (compiler-symbols-add-variant-values-in-module-id
  [symbols : CompilerSymbols]
  [module-id : i64]
  [enum-name-id : i64]
  [variants : AstVariantDefList]
  [enum-index : i64]
  [variant-index : i64]) : ResultCompilerSymbols
  (if (>= variant-index (ast-variant-def-list-len (& variants)))
    (ResultCompilerSymbols.Ok symbols)
    (match (ast-variant-def-list-get
      (& variants)
      variant-index
      (ast-variant-def-fallback))
      [(AstVariantDef.Def name _ _)
        (match (compiler-symbols-add-variant-value-in-module-id
          symbols
          module-id
          enum-name-id
          name
          enum-index
          variant-index)
          [(ResultCompilerSymbols.Ok next)
            (compiler-symbols-add-variant-values-in-module-id
              next
              module-id
              enum-name-id
              variants
              enum-index
              (+ variant-index 1))]
          [(ResultCompilerSymbols.Err message)
            (ResultCompilerSymbols.Err message)])])))

(define (compiler-symbols-add-variant-values-in-module
  [symbols : CompilerSymbols]
  [module : String]
  [enum-name : String]
  [variants : AstVariantDefList]
  [enum-index : i64]
  [variant-index : i64]) : ResultCompilerSymbols
  (compiler-symbols-add-variant-values-in-module-id
    symbols
    (intern module)
    (intern enum-name)
    variants
    enum-index
    variant-index))

(define (compiler-symbols-add-macro-in-module
  [symbols : CompilerSymbols]
  [module : String]
  [name : String]
  [handle : i64]) : ResultCompilerSymbols
  (compiler-symbols-add-macro-in-module-id
    symbols
    (compiler-symbol-existing-module-id module)
    (compiler-symbol-require-existing-name-id name)
    handle))

(define (compiler-symbols-add-macro-in-module-id
  [symbols : CompilerSymbols]
  [module-id : i64]
  [name-id : i64]
  [handle : i64]) : ResultCompilerSymbols
  (let
    [key-id : i64 (compiler-symbol-module-key-id-by-id module-id name-id)]
    [display-name : String (compiler-symbol-module-key-by-id module-id name-id)]
    (match (if (compiler-symbol-root-module-id? module-id)
      (compiler-symbols-add-root-macro-id symbols key-id display-name handle)
      (compiler-symbols-add-macro-id symbols key-id display-name handle))
      [(ResultCompilerSymbols.Ok next)
        (ResultCompilerSymbols.Ok
          (compiler-symbols-add-macro-alias-key-id
            next
            (compiler-symbol-name-id-key name-id)
            handle))]
      [(ResultCompilerSymbols.Err message) (ResultCompilerSymbols.Err message)])))

(define (compiler-symbols-lookup-value-in-module
  [symbols : CompilerSymbols]
  [module : String]
  [name : String]) : option_i64.Option
  (let
    [missing : i64 -2]
    [module-id : i64 (compiler-symbol-existing-module-id-or module missing)]
    [name-id : i64 (compiler-symbol-existing-name-id-or name missing)]
    (if (or (= module-id missing) (= name-id missing))
      option_i64.None
      (compiler-symbols-lookup-value-in-module-id symbols module-id name-id))))

(define (compiler-symbols-lookup-value-in-module-id
  [symbols : CompilerSymbols]
  [module-id : i64]
  [name-id : i64]) : option_i64.Option
  (match symbols
    [(CompilerSymbols values _ _ _ _)
      (compiler-symbol-map-lookup-id
        (& values)
        (compiler-symbol-module-key-id-by-id module-id name-id))]))

(define (compiler-symbols-lookup-type-in-module
  [symbols : CompilerSymbols]
  [module : String]
  [name : String]) : option_i64.Option
  (let
    [missing : i64 -2]
    [module-id : i64 (compiler-symbol-existing-module-id-or module missing)]
    [name-id : i64 (compiler-symbol-existing-name-id-or name missing)]
    (if (or (= module-id missing) (= name-id missing))
      option_i64.None
      (compiler-symbols-lookup-type-in-module-id symbols module-id name-id))))

(define (compiler-symbols-lookup-type-in-module-id
  [symbols : CompilerSymbols]
  [module-id : i64]
  [name-id : i64]) : option_i64.Option
  (match symbols
    [(CompilerSymbols _ types _ _ _)
      (compiler-symbol-map-lookup-id
        (& types)
        (compiler-symbol-module-key-id-by-id module-id name-id))]))

(define (compiler-symbols-lookup-macro-in-module
  [symbols : CompilerSymbols]
  [module : String]
  [name : String]) : option_i64.Option
  (let
    [missing : i64 -2]
    [module-id : i64 (compiler-symbol-existing-module-id-or module missing)]
    [name-id : i64 (compiler-symbol-existing-name-id-or name missing)]
    (if (or (= module-id missing) (= name-id missing))
      option_i64.None
      (compiler-symbols-lookup-macro-in-module-id symbols module-id name-id))))

(define (compiler-symbols-lookup-macro-in-module-id
  [symbols : CompilerSymbols]
  [module-id : i64]
  [name-id : i64]) : option_i64.Option
  (match symbols
    [(CompilerSymbols _ _ macros _ _)
      (compiler-symbol-map-lookup-id
        (& macros)
        (compiler-symbol-module-key-id-by-id module-id name-id))]))

(define (compiler-symbols-lookup-value-in-module-or
  [symbols : CompilerSymbols]
  [module : String]
  [name : String]
  [fallback : i64]) : i64
  (compiler-symbols-option-or
    (compiler-symbols-lookup-value-in-module symbols module name)
    fallback))

(define (compiler-symbols-lookup-value-in-module-id-or
  [symbols : CompilerSymbols]
  [module-id : i64]
  [name-id : i64]
  [fallback : i64]) : i64
  (compiler-symbols-option-or
    (compiler-symbols-lookup-value-in-module-id symbols module-id name-id)
    fallback))

(define (compiler-symbols-lookup-type-in-module-or
  [symbols : CompilerSymbols]
  [module : String]
  [name : String]
  [fallback : i64]) : i64
  (compiler-symbols-option-or
    (compiler-symbols-lookup-type-in-module symbols module name)
    fallback))

(define (compiler-symbols-lookup-type-in-module-id-or
  [symbols : CompilerSymbols]
  [module-id : i64]
  [name-id : i64]
  [fallback : i64]) : i64
  (compiler-symbols-option-or
    (compiler-symbols-lookup-type-in-module-id symbols module-id name-id)
    fallback))

(define (compiler-symbols-lookup-macro-in-module-or
  [symbols : CompilerSymbols]
  [module : String]
  [name : String]
  [fallback : i64]) : i64
  (compiler-symbols-option-or
    (compiler-symbols-lookup-macro-in-module symbols module name)
    fallback))

(define (compiler-symbols-lookup-macro-in-module-id-or
  [symbols : CompilerSymbols]
  [module-id : i64]
  [name-id : i64]
  [fallback : i64]) : i64
  (compiler-symbols-option-or
    (compiler-symbols-lookup-macro-in-module-id symbols module-id name-id)
    fallback))

(define (compiler-registries-lookup-field-in-module
  [registries : CompilerRegistries]
  [module : String]
  [type-name : String]
  [field-name : String]) : option_i64.Option
  (let
    [missing : i64 -2]
    [module-id : i64 (compiler-symbol-existing-module-id-or module missing)]
    [type-name-id : i64 (compiler-symbol-existing-name-id-or type-name missing)]
    [field-name-id : i64
      (compiler-symbol-existing-name-id-or field-name missing)]
    (if (or
      (= module-id missing)
      (or (= type-name-id missing) (= field-name-id missing)))
      option_i64.None
      (compiler-registries-lookup-field-in-module-id
        registries
        module-id
        type-name-id
        field-name-id))))

(define (compiler-registries-lookup-field-in-module-id
  [registries : CompilerRegistries]
  [module-id : i64]
  [type-name-id : i64]
  [field-name-id : i64]) : option_i64.Option
  (match registries
    [(CompilerRegistries _ fields)
      (compiler-symbol-map-lookup-id
        (& fields)
        (compiler-struct-field-key-id-in-module-by-id
          module-id
          type-name-id
          field-name-id))]))

(define (compiler-registries-lookup-field-in-module-or
  [registries : CompilerRegistries]
  [module : String]
  [type-name : String]
  [field-name : String]
  [fallback : i64]) : i64
  (compiler-symbols-option-or
    (compiler-registries-lookup-field-in-module
      registries
      module
      type-name
      field-name)
    fallback))

(define (compiler-registries-lookup-field-in-module-id-or
  [registries : CompilerRegistries]
  [module-id : i64]
  [type-name-id : i64]
  [field-name-id : i64]
  [fallback : i64]) : i64
  (compiler-symbols-option-or
    (compiler-registries-lookup-field-in-module-id
      registries
      module-id
      type-name-id
      field-name-id)
    fallback))

(define (compiler-symbols-add-decl
  [symbols : CompilerSymbols]
  [decl : AstDecl]
  [index : i64]) : ResultCompilerSymbols
  (compiler-symbols-add-decl-in-module
    symbols
    (compiler-symbol-root-module-id)
    decl
    index))

(define (compiler-symbols-generated-meta-suffix [meta : AstGeneratedDeclMeta]) : String
  (match meta
    [(AstGeneratedDeclMeta.Some generator item _ key)
      (if (> (string.string-length key) 0)
        (string.append " (generated identity: " (string.append key ")"))
        (string.append
          " (generated declaration: "
          (string.append
            item
            (string.append " from " (string.append generator ")")))))]
    [(AstGeneratedDeclMeta.No) ""]))

(define (compiler-symbols-with-generated-context
  [message : String]
  [meta : AstGeneratedDeclMeta]) : String
  (string.append message (compiler-symbols-generated-meta-suffix meta)))

(define (compiler-symbols-add-struct-cleanup-in-module
  [symbols : CompilerSymbols]
  [module-id : i64]
  [cleanup : AstStructCleanup]
  [index : i64]) : ResultCompilerSymbols
  (match cleanup
    [(AstStructCleanup.No) (ResultCompilerSymbols.Ok symbols)]
    [(AstStructCleanup.Fn cleanup-name)
      (compiler-symbols-add-value-in-module-id
        symbols
        module-id
        cleanup-name
        (compiler-symbol-make-handle
          (compiler-symbol-kind-struct-cleanup)
          index))]))

(define (compiler-symbols-add-enum-cleanup-in-module
  [symbols : CompilerSymbols]
  [module-id : i64]
  [cleanup : AstEnumCleanup]
  [index : i64]) : ResultCompilerSymbols
  (match cleanup
    [(AstEnumCleanup.No) (ResultCompilerSymbols.Ok symbols)]
    [(AstEnumCleanup.Fn cleanup-name)
      (compiler-symbols-add-value-in-module-id
        symbols
        module-id
        cleanup-name
        (compiler-symbol-make-handle (compiler-symbol-kind-enum-cleanup) index))]))

(define (compiler-symbols-add-decl-in-module
  [symbols : CompilerSymbols]
  [module-id : i64]
  [decl : AstDecl]
  [index : i64]) : ResultCompilerSymbols
  (match decl
    [(AstDecl.Def name _ _)
      (compiler-symbols-add-value-in-module-id
        symbols
        module-id
        name
        (compiler-symbol-make-handle (compiler-symbol-kind-value-define) index))]
    [(AstDecl.DefFn name _ _ _ _)
      (compiler-symbols-add-value-in-module-id
        symbols
        module-id
        name
        (compiler-symbol-make-handle
          (compiler-symbol-kind-function-define)
          index))]
    [(AstDecl.DefMacro name _ _ _)
      (compiler-symbols-add-macro-in-module-id
        symbols
        module-id
        name
        (compiler-symbol-make-handle (compiler-symbol-kind-defmacro) index))]
    [(AstDecl.Extern name _ _ _)
      (compiler-symbols-add-value-in-module-id
        symbols
        module-id
        name
        (compiler-symbol-make-handle (compiler-symbol-kind-extern) index))]
    [(AstDecl.DefDispatch name _)
      (compiler-symbols-add-value-in-module-id
        symbols
        module-id
        name
        (compiler-symbol-make-handle (compiler-symbol-kind-defdispatch) index))]
    [(AstDecl.DefEnum name cleanup variants)
      (match (compiler-symbols-add-type-in-module-id
        symbols
        module-id
        name
        (compiler-symbol-make-handle (compiler-symbol-kind-defenum) index))
        [(ResultCompilerSymbols.Ok next)
          (match (compiler-symbols-add-variant-values-in-module-id
            next
            module-id
            name
            variants
            index
            0)
            [(ResultCompilerSymbols.Ok with-variants)
              (compiler-symbols-add-enum-cleanup-in-module
                with-variants
                module-id
                cleanup
                index)]
            [(ResultCompilerSymbols.Err message)
              (ResultCompilerSymbols.Err message)])]
        [(ResultCompilerSymbols.Err message)
          (ResultCompilerSymbols.Err message)])]
    [(AstDecl.DefEnumLifetimes name _ cleanup variants)
      (match (compiler-symbols-add-type-in-module-id
        symbols
        module-id
        name
        (compiler-symbol-make-handle (compiler-symbol-kind-defenum) index))
        [(ResultCompilerSymbols.Ok next)
          (match (compiler-symbols-add-variant-values-in-module-id
            next
            module-id
            name
            variants
            index
            0)
            [(ResultCompilerSymbols.Ok with-variants)
              (compiler-symbols-add-enum-cleanup-in-module
                with-variants
                module-id
                cleanup
                index)]
            [(ResultCompilerSymbols.Err message)
              (ResultCompilerSymbols.Err message)])]
        [(ResultCompilerSymbols.Err message)
          (ResultCompilerSymbols.Err message)])]
    [(AstDecl.DefStruct name _ cleanup _)
      (match (compiler-symbols-add-type-in-module-id
        symbols
        module-id
        name
        (compiler-symbol-make-handle (compiler-symbol-kind-defstruct) index))
        [(ResultCompilerSymbols.Ok next)
          (match (compiler-symbols-add-value-in-module-id
            next
            module-id
            name
            (compiler-symbol-make-handle (compiler-symbol-kind-defstruct) index))
            [(ResultCompilerSymbols.Ok with-constructor)
              (compiler-symbols-add-struct-cleanup-in-module
                with-constructor
                module-id
                cleanup
                index)]
            [(ResultCompilerSymbols.Err message)
              (ResultCompilerSymbols.Err message)])]
        [(ResultCompilerSymbols.Err message)
          (ResultCompilerSymbols.Err message)])]
    [(AstDecl.DefStructLifetimes name _ _ cleanup _)
      (match (compiler-symbols-add-type-in-module-id
        symbols
        module-id
        name
        (compiler-symbol-make-handle (compiler-symbol-kind-defstruct) index))
        [(ResultCompilerSymbols.Ok next)
          (match (compiler-symbols-add-value-in-module-id
            next
            module-id
            name
            (compiler-symbol-make-handle (compiler-symbol-kind-defstruct) index))
            [(ResultCompilerSymbols.Ok with-constructor)
              (compiler-symbols-add-struct-cleanup-in-module
                with-constructor
                module-id
                cleanup
                index)]
            [(ResultCompilerSymbols.Err message)
              (ResultCompilerSymbols.Err message)])]
        [(ResultCompilerSymbols.Err message)
          (ResultCompilerSymbols.Err message)])]
    [(AstDecl.IncludeStr _ _) (ResultCompilerSymbols.Ok symbols)]
    [(AstDecl.IncludeBin _ _) (ResultCompilerSymbols.Ok symbols)]
    [(AstDecl.Import _) (ResultCompilerSymbols.Ok symbols)]
    [(AstDecl.Module _) (ResultCompilerSymbols.Ok symbols)]
    [(AstDecl.ModuleBody name body-box)
      (build-compiler-symbol-list-in-module
        (box-get body-box)
        (box-get body-box)
        symbols
        index
        name)]
    [(AstDecl.Test _ _ _) (ResultCompilerSymbols.Ok symbols)]
    [(AstDecl.Unsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (compiler-symbols-add-decl-in-module symbols module-id inner index))]
    [(AstDecl.ComptimeDecl meta template-box)
      (let
        [template : AstDecl (box-get template-box)]
        (match (compiler-symbols-add-decl-in-module
          symbols
          module-id
          template
          index)
          [(ResultCompilerSymbols.Ok next) (ResultCompilerSymbols.Ok next)]
          [(ResultCompilerSymbols.Err message)
            (ResultCompilerSymbols.Err
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
    [(AstStructCleanup.No) (ResultCompilerSymbols.Ok symbols)]
    [(AstStructCleanup.Fn cleanup-name)
      (compiler-symbols-add-local-value-in-module
        symbols
        module
        (intern-str cleanup-name)
        (compiler-symbol-make-handle
          (compiler-symbol-kind-struct-cleanup)
          index))]))

(define (compiler-symbols-add-local-enum-cleanup-in-module
  [symbols : CompilerSymbols]
  [module : String]
  [cleanup : AstEnumCleanup]
  [index : i64]) : ResultCompilerSymbols
  (match cleanup
    [(AstEnumCleanup.No) (ResultCompilerSymbols.Ok symbols)]
    [(AstEnumCleanup.Fn cleanup-name)
      (compiler-symbols-add-local-value-in-module
        symbols
        module
        (intern-str cleanup-name)
        (compiler-symbol-make-handle (compiler-symbol-kind-enum-cleanup) index))]))

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
  (if (>= variant-index (ast-variant-def-list-len (& variants)))
    (ResultCompilerSymbols.Ok symbols)
    (match (ast-variant-def-list-get
      (& variants)
      variant-index
      (ast-variant-def-fallback))
      [(AstVariantDef.Def name _ _)
        (match (compiler-symbols-add-local-variant-value-in-module
          symbols
          module
          (intern-str name)
          enum-index
          variant-index)
          [(ResultCompilerSymbols.Ok next)
            (compiler-symbols-add-local-variant-values-in-module
              next
              module
              variants
              enum-index
              (+ variant-index 1))]
          [(ResultCompilerSymbols.Err message)
            (ResultCompilerSymbols.Err message)])])))

(define (compiler-symbols-add-local-decl-in-module
  [symbols : CompilerSymbols]
  [module : String]
  [decl : AstDecl]
  [index : i64]) : ResultCompilerSymbols
  (match decl
    [(AstDecl.Def name _ _)
      (compiler-symbols-add-local-value-in-module
        symbols
        module
        (intern-str name)
        (compiler-symbol-make-handle (compiler-symbol-kind-value-define) index))]
    [(AstDecl.DefFn name _ _ _ _)
      (compiler-symbols-add-local-value-in-module
        symbols
        module
        (intern-str name)
        (compiler-symbol-make-handle
          (compiler-symbol-kind-function-define)
          index))]
    [(AstDecl.DefMacro name _ _ _)
      (compiler-symbols-add-local-macro-in-module
        symbols
        module
        (intern-str name)
        (compiler-symbol-make-handle (compiler-symbol-kind-defmacro) index))]
    [(AstDecl.Extern name _ _ _)
      (compiler-symbols-add-local-value-in-module
        symbols
        module
        (intern-str name)
        (compiler-symbol-make-handle (compiler-symbol-kind-extern) index))]
    [(AstDecl.DefDispatch name _)
      (compiler-symbols-add-local-value-in-module
        symbols
        module
        (intern-str name)
        (compiler-symbol-make-handle (compiler-symbol-kind-defdispatch) index))]
    [(AstDecl.DefEnum name cleanup variants)
      (match (compiler-symbols-add-local-type-in-module
        symbols
        module
        (intern-str name)
        (compiler-symbol-make-handle (compiler-symbol-kind-defenum) index))
        [(ResultCompilerSymbols.Ok next)
          (match (compiler-symbols-add-local-variant-values-in-module
            next
            module
            variants
            index
            0)
            [(ResultCompilerSymbols.Ok with-variants)
              (compiler-symbols-add-local-enum-cleanup-in-module
                with-variants
                module
                cleanup
                index)]
            [(ResultCompilerSymbols.Err message)
              (ResultCompilerSymbols.Err message)])]
        [(ResultCompilerSymbols.Err message)
          (ResultCompilerSymbols.Err message)])]
    [(AstDecl.DefEnumLifetimes name _ cleanup variants)
      (match (compiler-symbols-add-local-type-in-module
        symbols
        module
        (intern-str name)
        (compiler-symbol-make-handle (compiler-symbol-kind-defenum) index))
        [(ResultCompilerSymbols.Ok next)
          (match (compiler-symbols-add-local-variant-values-in-module
            next
            module
            variants
            index
            0)
            [(ResultCompilerSymbols.Ok with-variants)
              (compiler-symbols-add-local-enum-cleanup-in-module
                with-variants
                module
                cleanup
                index)]
            [(ResultCompilerSymbols.Err message)
              (ResultCompilerSymbols.Err message)])]
        [(ResultCompilerSymbols.Err message)
          (ResultCompilerSymbols.Err message)])]
    [(AstDecl.DefStruct name _ cleanup _)
      (match (compiler-symbols-add-local-type-in-module
        symbols
        module
        (intern-str name)
        (compiler-symbol-make-handle (compiler-symbol-kind-defstruct) index))
        [(ResultCompilerSymbols.Ok next)
          (match (compiler-symbols-add-local-value-in-module
            next
            module
            (intern-str name)
            (compiler-symbol-make-handle (compiler-symbol-kind-defstruct) index))
            [(ResultCompilerSymbols.Ok with-constructor)
              (compiler-symbols-add-local-struct-cleanup-in-module
                with-constructor
                module
                cleanup
                index)]
            [(ResultCompilerSymbols.Err message)
              (ResultCompilerSymbols.Err message)])]
        [(ResultCompilerSymbols.Err message)
          (ResultCompilerSymbols.Err message)])]
    [(AstDecl.DefStructLifetimes name _ _ cleanup _)
      (match (compiler-symbols-add-local-type-in-module
        symbols
        module
        (intern-str name)
        (compiler-symbol-make-handle (compiler-symbol-kind-defstruct) index))
        [(ResultCompilerSymbols.Ok next)
          (match (compiler-symbols-add-local-value-in-module
            next
            module
            (intern-str name)
            (compiler-symbol-make-handle (compiler-symbol-kind-defstruct) index))
            [(ResultCompilerSymbols.Ok with-constructor)
              (compiler-symbols-add-local-struct-cleanup-in-module
                with-constructor
                module
                cleanup
                index)]
            [(ResultCompilerSymbols.Err message)
              (ResultCompilerSymbols.Err message)])]
        [(ResultCompilerSymbols.Err message)
          (ResultCompilerSymbols.Err message)])]
    [(AstDecl.IncludeStr _ _) (ResultCompilerSymbols.Ok symbols)]
    [(AstDecl.IncludeBin _ _) (ResultCompilerSymbols.Ok symbols)]
    [(AstDecl.Import _) (ResultCompilerSymbols.Ok symbols)]
    [(AstDecl.Module _) (ResultCompilerSymbols.Ok symbols)]
    [(AstDecl.ModuleBody _ _) (ResultCompilerSymbols.Ok symbols)]
    [(AstDecl.Test _ _ _) (ResultCompilerSymbols.Ok symbols)]
    [(AstDecl.Unsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (compiler-symbols-add-local-decl-in-module symbols module inner index))]
    [(AstDecl.ComptimeDecl meta template-box)
      (let
        [template : AstDecl (box-get template-box)]
        (match (compiler-symbols-add-local-decl-in-module
          symbols
          module
          template
          index)
          [(ResultCompilerSymbols.Ok next) (ResultCompilerSymbols.Ok next)]
          [(ResultCompilerSymbols.Err message)
            (ResultCompilerSymbols.Err
              (compiler-symbols-with-generated-context message meta))]))]))

(define (compiler-symbols-add-variant-value-aliases
  [symbols : CompilerSymbols]
  [alias-id : i64]
  [enum-name-id : i64]
  [variants : AstVariantDefList]
  [enum-index : i64]
  [variant-index : i64]) : CompilerSymbols
  (if (>= variant-index (ast-variant-def-list-len (& variants)))
    symbols
    (match (ast-variant-def-list-get
      (& variants)
      variant-index
      (ast-variant-def-fallback))
      [(AstVariantDef.Def name _ _)
        (let
          [qualified-name-id : i64
            (compiler-enum-qualified-variant-name-id enum-name-id name)]
          [handle : i64
            (compiler-registry-make-handle
              (compiler-symbol-kind-enum-variant)
              enum-index
              variant-index)]
          (compiler-symbols-add-variant-value-aliases
            (compiler-symbols-add-value-alias-key-id
              (compiler-symbols-add-value-alias-key-id
                symbols
                (compiler-symbol-module-key-id-by-id alias-id name)
                handle)
              (compiler-symbol-module-key-id-by-id alias-id qualified-name-id)
              handle)
            alias-id
            enum-name-id
            variants
            enum-index
            (+ variant-index 1)))])))

(define (compiler-symbols-add-struct-cleanup-alias
  [symbols : CompilerSymbols]
  [alias-id : i64]
  [cleanup : AstStructCleanup]
  [index : i64]) : CompilerSymbols
  (match cleanup
    [(AstStructCleanup.No) symbols]
    [(AstStructCleanup.Fn cleanup-name)
      (compiler-symbols-add-value-alias-key-id
        symbols
        (compiler-symbol-module-key-id-by-id alias-id cleanup-name)
        (compiler-symbol-make-handle
          (compiler-symbol-kind-struct-cleanup)
          index))]))

(define (compiler-symbols-add-enum-cleanup-alias
  [symbols : CompilerSymbols]
  [alias-id : i64]
  [cleanup : AstEnumCleanup]
  [index : i64]) : CompilerSymbols
  (match cleanup
    [(AstEnumCleanup.No) symbols]
    [(AstEnumCleanup.Fn cleanup-name)
      (compiler-symbols-add-value-alias-key-id
        symbols
        (compiler-symbol-module-key-id-by-id alias-id cleanup-name)
        (compiler-symbol-make-handle (compiler-symbol-kind-enum-cleanup) index))]))

(define (compiler-symbols-add-decl-alias-in-module
  [symbols : CompilerSymbols]
  [alias-id : i64]
  [decl : AstDecl]
  [index : i64]) : CompilerSymbols
  (match decl
    [(AstDecl.Def name _ _)
      (compiler-symbols-add-value-alias-key-id
        symbols
        (compiler-symbol-module-key-id-by-id alias-id name)
        (compiler-symbol-make-handle (compiler-symbol-kind-value-define) index))]
    [(AstDecl.DefFn name _ _ _ _)
      (compiler-symbols-add-value-alias-key-id
        symbols
        (compiler-symbol-module-key-id-by-id alias-id name)
        (compiler-symbol-make-handle
          (compiler-symbol-kind-function-define)
          index))]
    [(AstDecl.DefMacro name _ _ _)
      (compiler-symbols-add-macro-alias-key-id
        symbols
        (compiler-symbol-module-key-id-by-id alias-id name)
        (compiler-symbol-make-handle (compiler-symbol-kind-defmacro) index))]
    [(AstDecl.Extern name _ _ _)
      (compiler-symbols-add-value-alias-key-id
        symbols
        (compiler-symbol-module-key-id-by-id alias-id name)
        (compiler-symbol-make-handle (compiler-symbol-kind-extern) index))]
    [(AstDecl.DefDispatch name _)
      (compiler-symbols-add-value-alias-key-id
        symbols
        (compiler-symbol-module-key-id-by-id alias-id name)
        (compiler-symbol-make-handle (compiler-symbol-kind-defdispatch) index))]
    [(AstDecl.DefEnum name cleanup variants)
      (compiler-symbols-add-enum-cleanup-alias
        (compiler-symbols-add-variant-value-aliases
          (compiler-symbols-add-type-alias-key-id
            symbols
            (compiler-symbol-module-key-id-by-id alias-id name)
            (compiler-symbol-make-handle (compiler-symbol-kind-defenum) index))
          alias-id
          name
          variants
          index
          0)
        alias-id
        cleanup
        index)]
    [(AstDecl.DefEnumLifetimes name _ cleanup variants)
      (compiler-symbols-add-enum-cleanup-alias
        (compiler-symbols-add-variant-value-aliases
          (compiler-symbols-add-type-alias-key-id
            symbols
            (compiler-symbol-module-key-id-by-id alias-id name)
            (compiler-symbol-make-handle (compiler-symbol-kind-defenum) index))
          alias-id
          name
          variants
          index
          0)
        alias-id
        cleanup
        index)]
    [(AstDecl.DefStruct name _ cleanup _)
      (compiler-symbols-add-struct-cleanup-alias
        (compiler-symbols-add-value-alias-key-id
          (compiler-symbols-add-type-alias-key-id
            symbols
            (compiler-symbol-module-key-id-by-id alias-id name)
            (compiler-symbol-make-handle (compiler-symbol-kind-defstruct) index))
          (compiler-symbol-module-key-id-by-id alias-id name)
          (compiler-symbol-make-handle (compiler-symbol-kind-defstruct) index))
        alias-id
        cleanup
        index)]
    [(AstDecl.DefStructLifetimes name _ _ cleanup _)
      (compiler-symbols-add-struct-cleanup-alias
        (compiler-symbols-add-value-alias-key-id
          (compiler-symbols-add-type-alias-key-id
            symbols
            (compiler-symbol-module-key-id-by-id alias-id name)
            (compiler-symbol-make-handle (compiler-symbol-kind-defstruct) index))
          (compiler-symbol-module-key-id-by-id alias-id name)
          (compiler-symbol-make-handle (compiler-symbol-kind-defstruct) index))
        alias-id
        cleanup
        index)]
    [(AstDecl.ComptimeDecl _ template-box)
      (let
        [template : AstDecl (box-get template-box)]
        (compiler-symbols-add-decl-alias-in-module
          symbols
          alias-id
          template
          index))]
    [(AstDecl.Unsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (compiler-symbols-add-decl-alias-in-module symbols alias-id inner index))]
    [(AstDecl.ModuleBody _ _) symbols]
    [_ symbols]))

(define (compiler-symbols-remove-decl-macro-alias
  [symbols : CompilerSymbols]
  [decl : AstDecl]
  [index : i64]) : CompilerSymbols
  (match decl
    [(AstDecl.DefMacro name _ _ _)
      (compiler-symbols-remove-macro-alias-if-handle
        symbols
        name
        (compiler-symbol-make-handle (compiler-symbol-kind-defmacro) index))]
    [(AstDecl.ComptimeDecl _ template-box)
      (let
        [template : AstDecl (box-get template-box)]
        (compiler-symbols-remove-decl-macro-alias symbols template index))]
    [(AstDecl.Unsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (compiler-symbols-remove-decl-macro-alias symbols inner index))]
    [_ symbols]))

(define (compiler-symbols-macro-module-set-add-decl
  [modules : sym_i64_env.SymI64Env]
  [module-id : i64]
  [decl : AstDecl]) : sym_i64_env.SymI64Env
  (match decl
    [(AstDecl.DefMacro _ _ _ _)
      (if (sym_i64_env.sym-i64-contains-id modules module-id)
        modules
        (sym_i64_env.sym-i64-bind-id modules module-id 1))]
    [(AstDecl.ComptimeDecl _ template-box)
      (let
        [template : AstDecl (box-get template-box)]
        (compiler-symbols-macro-module-set-add-decl modules module-id template))]
    [(AstDecl.Unsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (compiler-symbols-macro-module-set-add-decl modules module-id inner))]
    [(AstDecl.ModuleBody name body-box)
      (compiler-symbols-macro-module-set-list (box-get body-box) name modules)]
    [_ modules]))

(define (compiler-symbols-macro-module-set-list
  [decls : AstDeclList]
  [module-id : i64]
  [modules : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (let
    [cur-modules : sym_i64_env.SymI64Env modules]
    [cur-module : i64 module-id]
    [index : i64 0]
    [decl-count : i64 (ast-decl-list-len (& decls))]
    [decl-offset : i64 (struct-get decls offset)]
    (begin
      (while (< index decl-count)
        (let
          [decl : AstDecl
            (array-ref (struct-get decls slots) (+ decl-offset index))]
          (begin
            (match decl
              [(AstDecl.Module next-module) (set! cur-module next-module)]
              [(AstDecl.Import _) unit]
              [(AstDecl.IncludeStr _ _) unit]
              [(AstDecl.IncludeBin _ _) unit]
              [(AstDecl.Test _ _ _) unit]
              [_
                (set!
                  cur-modules
                  (compiler-symbols-macro-module-set-add-decl
                    cur-modules
                    cur-module
                    decl))])
            (set! index (+ index 1)))))
      cur-modules)))

(define (compiler-symbols-macro-module-set [decls : AstDeclList]) : sym_i64_env.SymI64Env
  (compiler-symbols-macro-module-set-list
    decls
    (compiler-symbol-root-module-id)
    (sym_i64_env.sym-i64-empty)))

;; An explicit `module ... as alias` import resolves dotted uses through the
;; import target directly. It should not leave the module's legacy bare macro
;; alias in the importer.
;; Real (non-Import/Module/Test) decls grouped by their enclosing module, built
;; once so alias installation touches only a module's own decls instead of
;; rescanning every decl in the program per import. Installing aliases for M
;; imported modules over a program of N decls was O(M*N) per symbol-table build
;; (and the table is rebuilt many times across a self-compile); the index makes
;; it O(N) to build plus O(decls-in-target-module) per import.
;;
;; Fields: mod-ids[slot] and mod-head[slot] are a small module-id -> head-entry
;; association (module counts are tiny, so a linear probe beats a hashmap here);
;; num-modules is its length. Per-module entries chain forward in decl order via
;; ent-next (-1 terminates); ent-pos[k] is the decl's index in `decls` and
;; ent-ridx[k] is the global real-decl ordinal the alias handles are keyed by --
;; both identical to the ordinals the previous whole-program scans produced.
(defenum ModuleDeclIndex
  (ModuleDeclIndex
    (Array i64)
    (Array i64)
    i64
    (Array i64)
    (Array i64)
    (Array i64)))

;; Linear probe for `module-id` in the first `num-modules` slots of `mod-ids`;
;; returns its slot or -1. Extracted from the index builder so that hot loop
;; keeps fewer values live at once.
(define (compiler-module-index-find-slot
  [mod-ids : (Array i64)]
  [num-modules : i64]
  [module-id : i64]) : i64
  (let
    [i : i64 0]
    [slot : i64 -1]
    (begin
      (while (< i num-modules)
        (if (= (array-ref mod-ids i) module-id)
          (begin
            (set! slot i)
            (set! i num-modules))
          (set! i (+ i 1))))
      slot)))

(define (compiler-symbols-build-module-decl-index [decls : AstDeclList]) : ModuleDeclIndex
  (let
    [decl-count : i64 (ast-decl-list-len (& decls))]
    [cap : i64
      (if (> decl-count 0)
        decl-count
        1)]
    [decl-offset : i64 (struct-get decls offset)]
    [slots : (Array AstDecl) (struct-get decls slots)]
    [mod-ids : (Array i64) (make-array i64 cap)]
    [mod-head : (Array i64) (make-array i64 cap)]
    [mod-tail : (Array i64) (make-array i64 cap)]
    [ent-pos : (Array i64) (make-array i64 cap)]
    [ent-ridx : (Array i64) (make-array i64 cap)]
    [ent-next : (Array i64) (make-array i64 cap)]
    [num-modules : i64 0]
    [num-entries : i64 0]
    [real-index : i64 0]
    [cur-module : i64 (compiler-symbol-root-module-id)]
    [position : i64 0]
    (begin
      (while (< position decl-count)
        (begin
          (match (array-ref slots (+ decl-offset position))
            [(AstDecl.Import _) unit]
            [(AstDecl.IncludeStr _ _) unit]
            [(AstDecl.IncludeBin _ _) unit]
            [(AstDecl.Module next-module) (set! cur-module next-module)]
            [(AstDecl.Test _ _ _) unit]
            [_
              (let
                [slot : i64
                  (compiler-module-index-find-slot
                    mod-ids
                    num-modules
                    cur-module)]
                (begin
                  (if (< slot 0)
                    (begin
                      (set! slot num-modules)
                      (array-set! mod-ids num-modules cur-module)
                      (array-set! mod-head num-modules -1)
                      (array-set! mod-tail num-modules -1)
                      (set! num-modules (+ num-modules 1)))
                    unit)
                  (array-set! ent-pos num-entries position)
                  (array-set! ent-ridx num-entries real-index)
                  (array-set! ent-next num-entries -1)
                  (if (< (array-ref mod-head slot) 0)
                    (begin
                      (array-set! mod-head slot num-entries)
                      (array-set! mod-tail slot num-entries))
                    (begin
                      (array-set!
                        ent-next
                        (array-ref mod-tail slot)
                        num-entries)
                      (array-set! mod-tail slot num-entries)))
                  (set! num-entries (+ num-entries 1))
                  (set! real-index (+ real-index 1))))])
          (set! position (+ position 1))))
      (ModuleDeclIndex mod-ids mod-head num-modules ent-pos ent-ridx ent-next))))

(define (compiler-module-decl-index-head
  [index : ModuleDeclIndex]
  [module-id : i64]) : i64
  (match index
    [(ModuleDeclIndex mod-ids mod-head num-modules _ _ _)
      (let
        [i : i64 0]
        [head : i64 -1]
        (begin
          (while (< i num-modules)
            (if (= (array-ref mod-ids i) module-id)
              (begin
                (set! head (array-ref mod-head i))
                (set! i num-modules))
              (set! i (+ i 1))))
          head))]))

(define (compiler-symbols-remove-module-macro-aliases-indexed
  [symbols : CompilerSymbols]
  [decls : AstDeclList]
  [index : ModuleDeclIndex]
  [target-module-id : i64]) : CompilerSymbols
  (match index
    [(ModuleDeclIndex _ _ _ ent-pos ent-ridx ent-next)
      (let
        [decl-offset : i64 (struct-get decls offset)]
        [slots : (Array AstDecl) (struct-get decls slots)]
        [cur-symbols : CompilerSymbols symbols]
        [k : i64 (compiler-module-decl-index-head index target-module-id)]
        (begin
          (while (>= k 0)
            (begin
              (set!
                cur-symbols
                (compiler-symbols-remove-decl-macro-alias
                  cur-symbols
                  (array-ref slots (+ decl-offset (array-ref ent-pos k)))
                  (array-ref ent-ridx k)))
              (set! k (array-ref ent-next k))))
          cur-symbols))]))

(define (compiler-symbols-add-module-aliases-indexed
  [symbols : CompilerSymbols]
  [decls : AstDeclList]
  [index : ModuleDeclIndex]
  [target-module-id : i64]
  [alias-id : i64]) : CompilerSymbols
  (match index
    [(ModuleDeclIndex _ _ _ ent-pos ent-ridx ent-next)
      (let
        [decl-offset : i64 (struct-get decls offset)]
        [slots : (Array AstDecl) (struct-get decls slots)]
        [cur-symbols : CompilerSymbols symbols]
        [k : i64 (compiler-module-decl-index-head index target-module-id)]
        (begin
          (while (>= k 0)
            (begin
              (set!
                cur-symbols
                (compiler-symbols-add-decl-alias-in-module
                  cur-symbols
                  alias-id
                  (array-ref slots (+ decl-offset (array-ref ent-pos k)))
                  (array-ref ent-ridx k)))
              (set! k (array-ref ent-next k))))
          cur-symbols))]))

(define (compiler-symbols-import-alias-key
  [importer-module : String]
  [alias : String]) : String
  (if (string.eq alias "")
    importer-module
    alias))

(define (compiler-symbols-import-alias-key-id
  [importer-module : i64]
  [alias : i64]) : i64
  (if (= alias cbi.compiler-builtin-id-fix-empty)
    importer-module
    alias))

(define (build-compiler-symbol-aliases-list
  [all-decls : AstDeclList]
  [decls : AstDeclList]
  [symbols : CompilerSymbols]
  [module-id : i64]
  [macro-modules : sym_i64_env.SymI64Env]) : CompilerSymbols
  (let
    [cur-symbols : CompilerSymbols symbols]
    [cur-module-id : i64 module-id]
    [index : i64 0]
    [decl-count : i64 (ast-decl-list-len (& decls))]
    [decl-offset : i64 (struct-get decls offset)]
    [decl-index : ModuleDeclIndex
      (compiler-symbols-build-module-decl-index all-decls)]
    (begin
      (while (< index decl-count)
        (let
          [decl : AstDecl
            (array-ref (struct-get decls slots) (+ decl-offset index))]
          [next-symbols : CompilerSymbols
            (match decl
              [(AstDecl.Import
                  (AstImportSpec.Spec
                    _
                    _
                    (AstMaybeModuleName.Some target-module)
                    (AstMaybeImportAlias.Some alias)
                    _))
                (let
                  [target-module-id : i64 target-module]
                  [target-has-macros : bool
                    (sym_i64_env.sym-i64-contains-id
                      macro-modules
                      target-module-id)]
                  [without-bare-macros : CompilerSymbols
                    (if target-has-macros
                      (compiler-symbols-remove-module-macro-aliases-indexed
                        cur-symbols
                        all-decls
                        decl-index
                        target-module-id)
                      cur-symbols)]
                  (if (= alias cbi.compiler-builtin-id-fix-empty)
                    (compiler-symbols-add-module-aliases-indexed
                      without-bare-macros
                      all-decls
                      decl-index
                      target-module-id
                      cur-module-id)
                    without-bare-macros))]
              [_ cur-symbols])]
          (begin
            (set! cur-symbols next-symbols)
            (match decl
              [(AstDecl.Module next-module) (set! cur-module-id next-module)]
              [_ unit])
            (set! index (+ index 1)))))
      cur-symbols)))

(define (build-compiler-symbol-list
  [decls : AstDeclList]
  [symbols : CompilerSymbols]
  [index : i64]) : ResultCompilerSymbols
  (build-compiler-symbol-list-in-module
    decls
    decls
    symbols
    index
    (compiler-symbol-root-module-id)))

(define (compiler-symbol-decl-counts-for-index? [decl : AstDecl]) : bool
  (match decl
    [(AstDecl.Import _) false]
    [(AstDecl.IncludeStr _ _) false]
    [(AstDecl.IncludeBin _ _) false]
    [(AstDecl.Module _) false]
    [(AstDecl.ModuleBody _ _) false]
    [(AstDecl.Test _ _ _) false]
    [_ true]))

(define (compiler-symbol-path-list-repeat [decls : AstDeclList] [path : String]) : AstDeclPathList
  (let
    [out : AstDeclPathList
      (ast-decl-path-list-with-capacity (ast-decl-list-len (& decls)))]
    [index : i64 0]
    [count : i64 (ast-decl-list-len (& decls))]
    (begin
      (while (< index count)
        (begin
          (ast-decl-path-list-push (&mut out) path)
          (set! index (+ index 1))))
      out)))

(define (compiler-symbol-path-at-index
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [target : i64]
  [index : i64]) : String
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil) ""]
    [(AstDeclListStep.Cons decl rest)
      (let
        [rest : AstDeclList rest]
        [decl-path : String
          (match (ast-decl-path-list-step paths)
            [(AstDeclPathListStep.Cons path _) path]
            [(AstDeclPathListStep.Nil) ""])]
        [rest-paths : AstDeclPathList
          (match (ast-decl-path-list-step paths)
            [(AstDeclPathListStep.Cons _ path-rest)
              (let
                [path-rest : AstDeclPathList path-rest]
                path-rest)]
            [(AstDeclPathListStep.Nil) (ast-decl-path-list-new)])]
        (match decl
          [(AstDecl.ModuleBody _ body-box)
            (let
              [body : AstDeclList (box-get body-box)]
              [body-count : i64 (compiler-decl-list-index-count body)]
              (if (< target (+ index body-count))
                (compiler-symbol-path-at-index
                  body
                  (compiler-symbol-path-list-repeat body decl-path)
                  target
                  index)
                (compiler-symbol-path-at-index
                  rest
                  rest-paths
                  target
                  (+ index body-count))))]
          [_
            (if (compiler-symbol-decl-counts-for-index? decl)
              (if (= target index)
                decl-path
                (compiler-symbol-path-at-index
                  rest
                  rest-paths
                  target
                  (+ index 1)))
              (compiler-symbol-path-at-index rest rest-paths target index))]))]))

(define (compiler-symbols-duplicate-location-suffix
  [first-path : String]
  [duplicate-path : String]) : String
  (if (> (string.string-length first-path) 0)
    (if (> (string.string-length duplicate-path) 0)
      (string.append
        " (first declared in "
        (string.append
          first-path
          (string.append "; duplicate in " (string.append duplicate-path ")"))))
      (string.append " (first declared in " (string.append first-path ")")))
    (if (> (string.string-length duplicate-path) 0)
      (string.append " (duplicate in " (string.append duplicate-path ")"))
      "")))

(define (compiler-symbols-duplicate-value-message-with-paths
  [symbols : CompilerSymbols]
  [all-decls : AstDeclList]
  [all-paths : AstDeclPathList]
  [module-id : i64]
  [name-id : i64]
  [_index : i64]
  [decl-path : String]) : CompilerMaybeString
  (match (compiler-symbols-lookup-value-in-module-id symbols module-id name-id)
    [(option_i64.Some existing)
      (if (and
        (compiler-symbol-root-module-id? module-id)
        (compiler-symbols-handle-from-nonroot-owner? symbols existing))
        CompilerNoString
        (let
          [first-path : String
            (compiler-symbol-path-at-index
              all-decls
              all-paths
              (compiler-symbol-handle-index existing)
              0)]
          [display-name : String
            (compiler-symbol-module-key-by-id module-id name-id)]
          (CompilerSomeString
            (string.append
              (compiler-symbols-duplicate-value-message display-name)
              (compiler-symbols-duplicate-location-suffix first-path decl-path)))))]
    [(option_i64.None) CompilerNoString]))

(define (compiler-symbols-duplicate-value-message-for-decl-with-paths
  [symbols : CompilerSymbols]
  [all-decls : AstDeclList]
  [all-paths : AstDeclPathList]
  [module-id : i64]
  [decl : AstDecl]
  [index : i64]
  [decl-path : String]) : CompilerMaybeString
  (match decl
    [(AstDecl.Def name _ _)
      (compiler-symbols-duplicate-value-message-with-paths
        symbols
        all-decls
        all-paths
        module-id
        name
        index
        decl-path)]
    [(AstDecl.DefFn name _ _ _ _)
      (compiler-symbols-duplicate-value-message-with-paths
        symbols
        all-decls
        all-paths
        module-id
        name
        index
        decl-path)]
    [(AstDecl.Extern name _ _ _)
      (compiler-symbols-duplicate-value-message-with-paths
        symbols
        all-decls
        all-paths
        module-id
        name
        index
        decl-path)]
    [(AstDecl.DefDispatch name _)
      (compiler-symbols-duplicate-value-message-with-paths
        symbols
        all-decls
        all-paths
        module-id
        name
        index
        decl-path)]
    [(AstDecl.Unsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (compiler-symbols-duplicate-value-message-for-decl-with-paths
          symbols
          all-decls
          all-paths
          module-id
          inner
          index
          decl-path))]
    [(AstDecl.ComptimeDecl _ template-box)
      (let
        [template : AstDecl (box-get template-box)]
        (compiler-symbols-duplicate-value-message-for-decl-with-paths
          symbols
          all-decls
          all-paths
          module-id
          template
          index
          decl-path))]
    [_ CompilerNoString]))

(define (compiler-symbol-indexed-decl [decl : AstDecl]) : AstDecl
  (match decl
    [(AstDecl.ComptimeDecl _ template-box)
      (let
        [template : AstDecl (box-get template-box)]
        template)]
    [(AstDecl.Unsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        inner)]
    [_ decl]))

(define (compiler-symbol-owner-name-for-decl [decl : AstDecl] [module-id : i64]) : String
  (match decl
    [(AstDecl.Def name _ _) (compiler-symbol-module-key-by-id module-id name)]
    [(AstDecl.DefFn name _ _ _ _)
      (compiler-symbol-module-key-by-id module-id name)]
    [(AstDecl.Extern name _ _ _)
      (compiler-symbol-module-key-by-id module-id name)]
    [(AstDecl.DefMacro name _ _ _)
      (compiler-symbol-module-key-by-id module-id name)]
    [(AstDecl.DefDispatch name _)
      (compiler-symbol-module-key-by-id module-id name)]
    [(AstDecl.DefEnum name _ _)
      (compiler-symbol-module-key-by-id module-id name)]
    [(AstDecl.DefEnumLifetimes name _ _ _)
      (compiler-symbol-module-key-by-id module-id name)]
    [(AstDecl.DefStruct name _ _ _)
      (compiler-symbol-module-key-by-id module-id name)]
    [(AstDecl.DefStructLifetimes name _ _ _ _)
      (compiler-symbol-module-key-by-id module-id name)]
    [_ ""]))

(define (compiler-symbol-owner-id-for-decl [decl : AstDecl] [module-id : i64]) : i64
  (match decl
    [(AstDecl.Def name _ _)
      (compiler-symbol-module-key-id-by-id module-id name)]
    [(AstDecl.DefFn name _ _ _ _)
      (compiler-symbol-module-key-id-by-id module-id name)]
    [(AstDecl.Extern name _ _ _)
      (compiler-symbol-module-key-id-by-id module-id name)]
    [(AstDecl.DefMacro name _ _ _)
      (compiler-symbol-module-key-id-by-id module-id name)]
    [(AstDecl.DefDispatch name _)
      (compiler-symbol-module-key-id-by-id module-id name)]
    [(AstDecl.DefEnum name _ _)
      (compiler-symbol-module-key-id-by-id module-id name)]
    [(AstDecl.DefEnumLifetimes name _ _ _)
      (compiler-symbol-module-key-id-by-id module-id name)]
    [(AstDecl.DefStruct name _ _ _)
      (compiler-symbol-module-key-id-by-id module-id name)]
    [(AstDecl.DefStructLifetimes name _ _ _ _)
      (compiler-symbol-module-key-id-by-id module-id name)]
    [_ -1]))

(define (compiler-symbols-index-decl!
  [symbols : CompilerSymbols]
  [decl : AstDecl]
  [index : i64]
  [module-id : i64]) : unit
  (let
    [indexed : AstDecl (compiler-symbol-indexed-decl decl)]
    (begin
      (array-set! (compiler-symbols-decls symbols) index indexed)
      (array-set! (compiler-symbols-owner-module-ids symbols) index module-id))))

(define (compiler-symbols-owner-module-id-at-index-or
  [symbols : CompilerSymbols]
  [target : i64]
  [fallback : i64]) : i64
  (let
    [owner-module-ids : (Array i64) (compiler-symbols-owner-module-ids symbols)]
    (if (or (< target 0) (>= target (array-length owner-module-ids)))
      fallback
      (array-ref owner-module-ids target))))

(define (compiler-symbols-owner-id-at-index-or
  [symbols : CompilerSymbols]
  [target : i64]
  [fallback : i64]) : i64
  (let
    [decls : (Array AstDecl) (compiler-symbols-decls symbols)]
    [owner-module-ids : (Array i64) (compiler-symbols-owner-module-ids symbols)]
    (if (or (< target 0) (>= target (array-length owner-module-ids)))
      fallback
      (let
        [owner-id : i64
          (compiler-symbol-owner-id-for-decl
            (array-ref decls target)
            (array-ref owner-module-ids target))]
        (if (< owner-id 0)
          fallback
          owner-id)))))

(define (compiler-symbols-owner-name-at-index
  [symbols : CompilerSymbols]
  [target : i64]) : CompilerMaybeString
  (let
    [decls : (Array AstDecl) (compiler-symbols-decls symbols)]
    [owner-module-ids : (Array i64) (compiler-symbols-owner-module-ids symbols)]
    (if (or (< target 0) (>= target (array-length owner-module-ids)))
      (CompilerNoString)
      (let
        [owner-name : String
          (compiler-symbol-owner-name-for-decl
            (array-ref decls target)
            (array-ref owner-module-ids target))]
        (if (> (string.string-length owner-name) 0)
          (CompilerSomeString owner-name)
          (CompilerNoString))))))

(define (build-compiler-symbol-list-in-module
  [all-decls : AstDeclList]
  [decls : AstDeclList]
  [symbols : CompilerSymbols]
  [index : i64]
  [module-id : i64]) : ResultCompilerSymbols
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil) (ResultCompilerSymbols.Ok symbols)]
    [(AstDeclListStep.Cons decl rest)
      (let
        [rest : AstDeclList rest]
        (match decl
          [(AstDecl.Import _)
            (build-compiler-symbol-list-in-module
              all-decls
              rest
              symbols
              index
              module-id)]
          [(AstDecl.IncludeStr _ _)
            (build-compiler-symbol-list-in-module
              all-decls
              rest
              symbols
              index
              module-id)]
          [(AstDecl.IncludeBin _ _)
            (build-compiler-symbol-list-in-module
              all-decls
              rest
              symbols
              index
              module-id)]
          [(AstDecl.Module next-module)
            (build-compiler-symbol-list-in-module
              all-decls
              rest
              symbols
              index
              next-module)]
          [(AstDecl.ModuleBody name body-box)
            (let
              [body : AstDeclList (box-get body-box)]
              [body-count : i64 (compiler-decl-list-index-count body)]
              (match (build-compiler-symbol-list-in-module
                all-decls
                body
                symbols
                index
                name)
                [(ResultCompilerSymbols.Ok body-symbols)
                  (build-compiler-symbol-list-in-module
                    all-decls
                    rest
                    body-symbols
                    (+ index body-count)
                    module-id)]
                [(ResultCompilerSymbols.Err message)
                  (ResultCompilerSymbols.Err message)]))]
          [(AstDecl.Test _ _ _)
            (build-compiler-symbol-list-in-module
              all-decls
              rest
              symbols
              index
              module-id)]
          [_
            (begin
              (compiler-symbols-index-decl! symbols decl index module-id)
              (match (compiler-symbols-add-decl-in-module
                symbols
                module-id
                decl
                index)
                [(ResultCompilerSymbols.Ok next-symbols)
                  (build-compiler-symbol-list-in-module
                    all-decls
                    rest
                    next-symbols
                    (+ index 1)
                    module-id)]
                [(ResultCompilerSymbols.Err message)
                  (ResultCompilerSymbols.Err message)]))]))]))

(define (build-compiler-symbol-list-with-paths-in-module
  [all-decls : AstDeclList]
  [all-paths : AstDeclPathList]
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [symbols : CompilerSymbols]
  [index : i64]
  [module-id : i64]) : ResultCompilerSymbols
  (let
    [cur-decls : AstDeclList decls]
    [cur-paths : AstDeclPathList paths]
    [cur-symbols : CompilerSymbols symbols]
    [cur-index : i64 index]
    [cur-module-id : i64 module-id]
    [result : ResultCompilerSymbols
      (ResultCompilerSymbols.Err "symbols: internal decls walk")]
    [done : bool false]
    (begin
      (while (not done)
        (match (ast-decl-list-step cur-decls)
          [(AstDeclListStep.Nil)
            (begin
              (set! result (ResultCompilerSymbols.Ok cur-symbols))
              (set! done true))]
          [(AstDeclListStep.Cons decl rest)
            (let
              [rest : AstDeclList rest]
              [decl-path : String
                (match (ast-decl-path-list-step cur-paths)
                  [(AstDeclPathListStep.Cons path _) path]
                  [(AstDeclPathListStep.Nil) ""])]
              [rest-paths : AstDeclPathList
                (match (ast-decl-path-list-step cur-paths)
                  [(AstDeclPathListStep.Cons _ path-rest)
                    (let
                      [path-rest : AstDeclPathList path-rest]
                      path-rest)]
                  [(AstDeclPathListStep.Nil) (ast-decl-path-list-new)])]
              (match decl
                [(AstDecl.Import _)
                  (begin
                    (set! cur-decls rest)
                    (set! cur-paths rest-paths))]
                [(AstDecl.IncludeStr _ _)
                  (begin
                    (set! cur-decls rest)
                    (set! cur-paths rest-paths))]
                [(AstDecl.IncludeBin _ _)
                  (begin
                    (set! cur-decls rest)
                    (set! cur-paths rest-paths))]
                [(AstDecl.Module next-module)
                  (begin
                    (set! cur-decls rest)
                    (set! cur-paths rest-paths)
                    (set! cur-module-id next-module))]
                [(AstDecl.ModuleBody name body-box)
                  (let
                    [body : AstDeclList (box-get body-box)]
                    [body-count : i64 (compiler-decl-list-index-count body)]
                    [body-paths : AstDeclPathList
                      (compiler-symbol-path-list-repeat body decl-path)]
                    (match (build-compiler-symbol-list-with-paths-in-module
                      all-decls
                      all-paths
                      body
                      body-paths
                      cur-symbols
                      cur-index
                      name)
                      [(ResultCompilerSymbols.Ok next-symbols)
                        (begin
                          (set! cur-decls rest)
                          (set! cur-paths rest-paths)
                          (set! cur-symbols next-symbols)
                          (set! cur-index (+ cur-index body-count)))]
                      [(ResultCompilerSymbols.Err message)
                        (begin
                          (set! result (ResultCompilerSymbols.Err message))
                          (set! done true))]))]
                [(AstDecl.Test _ _ _)
                  (begin
                    (set! cur-decls rest)
                    (set! cur-paths rest-paths))]
                [_
                  (match (compiler-symbols-duplicate-value-message-for-decl-with-paths
                    cur-symbols
                    all-decls
                    all-paths
                    cur-module-id
                    decl
                    cur-index
                    decl-path)
                    [(CompilerSomeString message)
                      (begin
                        (compiler-symbols-note-last-error! decl decl-path)
                        (set! result (ResultCompilerSymbols.Err message))
                        (set! done true))]
                    [CompilerNoString
                      (begin
                        (compiler-symbols-note-last-error! decl decl-path)
                        (compiler-symbols-index-decl!
                          cur-symbols
                          decl
                          cur-index
                          cur-module-id)
                        (match (compiler-symbols-add-decl-in-module
                          cur-symbols
                          cur-module-id
                          decl
                          cur-index)
                          [(ResultCompilerSymbols.Ok next-symbols)
                            (begin
                              (set! cur-decls rest)
                              (set! cur-paths rest-paths)
                              (set! cur-symbols next-symbols)
                              (set! cur-index (+ cur-index 1)))]
                          [(ResultCompilerSymbols.Err message)
                            (begin
                              (set! result (ResultCompilerSymbols.Err message))
                              (set! done true))]))])]))]))
      result)))

(define (build-compiler-symbols [program : AstProgram]) : ResultCompilerSymbols
  (match program
    [(AstProgram.Program decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (build-compiler-symbol-list
          decls
          (compiler-symbols-empty-with-decls
            (compiler-decl-list-index-count decls))
          0)
          [(ResultCompilerSymbols.Ok symbols)
            (let
              [macro-modules : sym_i64_env.SymI64Env
                (compiler-symbols-macro-module-set decls)]
              [aliased : CompilerSymbols
                (build-compiler-symbol-aliases-list
                  decls
                  decls
                  symbols
                  (compiler-symbol-root-module-id)
                  macro-modules)]
              (ResultCompilerSymbols.Ok aliased))]
          [(ResultCompilerSymbols.Err message)
            (ResultCompilerSymbols.Err message)]))]))

(define (build-compiler-symbols-with-paths
  [program : AstProgram]
  [paths : AstDeclPathList]) : ResultCompilerSymbols
  (match program
    [(AstProgram.Program decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (build-compiler-symbol-list-with-paths-in-module
          decls
          paths
          decls
          paths
          (compiler-symbols-empty-with-decls
            (compiler-decl-list-index-count decls))
          0
          (compiler-symbol-root-module-id))
          [(ResultCompilerSymbols.Ok symbols)
            (ResultCompilerSymbols.Ok
              (build-compiler-symbol-aliases-list
                decls
                decls
                symbols
                (compiler-symbol-root-module-id)
                (compiler-symbols-macro-module-set decls)))]
          [(ResultCompilerSymbols.Err message)
            (ResultCompilerSymbols.Err message)]))]))

(define (build-compiler-symbols-diagnostic-with-paths
  [program : AstProgram]
  [paths : AstDeclPathList]) : ResultCompilerSymbolsDiagnostic
  (begin
    (compiler-symbols-clear-last-error!)
    (match (build-compiler-symbols-with-paths program paths)
      [(ResultCompilerSymbols.Ok symbols)
        (ResultCompilerSymbolsDiagnostic.Ok symbols)]
      [(ResultCompilerSymbols.Err message)
        (ResultCompilerSymbolsDiagnostic.Err
          (box (compiler-symbols-last-error-diagnostic message)))])))

(define (build-compiler-symbols-from-source [src : String]) : ResultCompilerSymbols
  (match (parse-ast-source src)
    [(ResultAstProgram.Ok program) (build-compiler-symbols program)]
    [(ResultAstProgram.Err message) (ResultCompilerSymbols.Err message)]))

(define (compiler-registries-lookup-variant
  [registries : CompilerRegistries]
  [name : String]) : option_i64.Option
  (match (compiler-symbol-existing-name-id name)
    [(option_i64.Some name-id)
      (compiler-registries-lookup-variant-id registries name-id)]
    [(option_i64.None) option_i64.None]))

(define (compiler-registries-lookup-variant-id
  [registries : CompilerRegistries]
  [name-id : i64]) : option_i64.Option
  (match registries
    [(CompilerRegistries variants _)
      (match (compiler-symbol-map-lookup-id
        (& variants)
        (compiler-symbol-name-id-key name-id))
        [(option_i64.Some handle) (option_i64.Some handle)]
        [(option_i64.None)
          (match (compiler-symbol-dotted-variant-key-id name-id)
            [(option_i64.Some key-id)
              (compiler-symbol-map-lookup-id (& variants) key-id)]
            [(option_i64.None) option_i64.None])])]))

(define (compiler-registries-lookup-variant-key-id
  [registries : CompilerRegistries]
  [key-id : i64]) : option_i64.Option
  (match registries
    [(CompilerRegistries variants _)
      (compiler-symbol-map-lookup-id (& variants) key-id)]))

(define (compiler-registries-lookup-struct-field
  [registries : CompilerRegistries]
  [struct-name : String]
  [field-name : String]) : option_i64.Option
  (let
    [missing : i64 -1]
    [struct-name-id : i64
      (compiler-symbol-existing-name-id-or struct-name missing)]
    [field-name-id : i64
      (compiler-symbol-existing-name-id-or field-name missing)]
    (if (or (= struct-name-id missing) (= field-name-id missing))
      option_i64.None
      (compiler-registries-lookup-struct-field-id
        registries
        struct-name-id
        field-name-id))))

(define (compiler-registries-lookup-struct-field-id
  [registries : CompilerRegistries]
  [struct-name-id : i64]
  [field-name-id : i64]) : option_i64.Option
  (match registries
    [(CompilerRegistries _ fields)
      (compiler-symbol-map-lookup-id
        (& fields)
        (compiler-struct-field-key-id-by-id struct-name-id field-name-id))]))

(define (compiler-registries-lookup-variant-or
  [registries : CompilerRegistries]
  [name : String]
  [fallback : i64]) : i64
  (compiler-symbols-option-or
    (compiler-registries-lookup-variant registries name)
    fallback))

(define (compiler-registries-lookup-variant-id-or
  [registries : CompilerRegistries]
  [name-id : i64]
  [fallback : i64]) : i64
  (compiler-symbols-option-or
    (compiler-registries-lookup-variant-id registries name-id)
    fallback))

(define (compiler-registries-lookup-variant-key-id-or
  [registries : CompilerRegistries]
  [key-id : i64]
  [fallback : i64]) : i64
  (compiler-symbols-option-or
    (compiler-registries-lookup-variant-key-id registries key-id)
    fallback))

(define (compiler-registries-lookup-struct-field-or
  [registries : CompilerRegistries]
  [struct-name : String]
  [field-name : String]
  [fallback : i64]) : i64
  (compiler-symbols-option-or
    (compiler-registries-lookup-struct-field registries struct-name field-name)
    fallback))

(define (compiler-registries-lookup-struct-field-id-or
  [registries : CompilerRegistries]
  [struct-name-id : i64]
  [field-name-id : i64]
  [fallback : i64]) : i64
  (compiler-symbols-option-or
    (compiler-registries-lookup-struct-field-id
      registries
      struct-name-id
      field-name-id)
    fallback))

(define (compiler-registries-add-variant
  [registries : CompilerRegistries]
  [name : String]
  [enum-index : i64]
  [variant-index : i64]) : ResultCompilerRegistries
  (match registries
    [(CompilerRegistries variants fields)
      (if (compiler-symbol-map-contains? (& variants) name)
        (ResultCompilerRegistries.Err
          (compiler-registries-duplicate-variant-message name))
        (begin
          (compiler-symbol-map-bind!
            (&mut variants)
            name
            (compiler-registry-make-handle
              (compiler-symbol-kind-enum-variant)
              enum-index
              variant-index))
          (ResultCompilerRegistries.Ok (CompilerRegistries variants fields))))]))

(define (compiler-registries-add-variant-in-module
  [registries : CompilerRegistries]
  [module : String]
  [enum-name : String]
  [name : String]
  [enum-index : i64]
  [variant-index : i64]) : ResultCompilerRegistries
  (compiler-registries-add-variant-in-module-id
    registries
    (compiler-symbol-existing-module-id module)
    (compiler-symbol-require-existing-name-id enum-name)
    (compiler-symbol-require-existing-name-id name)
    enum-index
    variant-index))

(define (compiler-registries-add-variant-in-module-id
  [registries : CompilerRegistries]
  [module-id : i64]
  [enum-name-id : i64]
  [name-id : i64]
  [enum-index : i64]
  [variant-index : i64]) : ResultCompilerRegistries
  (let
    [source-enum-name-id : i64
      (compiler-symbol-source-spelling-id-or-self enum-name-id)]
    [source-name-id : i64 (compiler-symbol-source-spelling-id-or-self name-id)]
    [qualified-name-id : i64
      (compiler-enum-qualified-variant-name-id enum-name-id name-id)]
    [qualified-key-id : i64
      (compiler-symbol-module-key-id-by-id module-id qualified-name-id)]
    [qualified-display-name : String
      (compiler-symbol-module-key-by-id module-id qualified-name-id)]
    [handle : i64
      (compiler-registry-make-handle
        (compiler-symbol-kind-enum-variant)
        enum-index
        variant-index)]
    (match registries
      [(CompilerRegistries variants fields)
        (if (compiler-symbol-map-contains-id? (& variants) qualified-key-id)
          (ResultCompilerRegistries.Err
            (compiler-registries-duplicate-variant-message
              qualified-display-name))
          (begin
            (compiler-symbol-map-bind-id!
              (&mut variants)
              qualified-key-id
              handle)
            (ResultCompilerRegistries.Ok
              (compiler-registries-add-variant-alias-key-id
                (compiler-registries-add-variant-alias-key-id
                  (compiler-registries-add-variant-alias-key-id
                    (compiler-registries-add-variant-alias-key-id
                      (compiler-registries-add-variant-alias-key-id
                        (compiler-registries-add-variant-alias-key-id
                          (CompilerRegistries variants fields)
                          (compiler-symbol-module-key-id-by-id
                            module-id
                            name-id)
                          handle)
                        (compiler-symbol-name-id-key name-id)
                        handle)
                      (compiler-symbol-module-key-id-by-id
                        module-id
                        source-name-id)
                      handle)
                    (compiler-symbol-name-id-key source-name-id)
                    handle)
                  (compiler-symbol-module-key-id-by-id
                    module-id
                    (compiler-enum-qualified-variant-name-id
                      enum-name-id
                      source-name-id))
                  handle)
                (compiler-symbol-module-key-id-by-id
                  module-id
                  (compiler-enum-qualified-variant-name-id
                    source-enum-name-id
                    source-name-id))
                handle))))])))

(define (compiler-registries-add-field
  [registries : CompilerRegistries]
  [struct-name : String]
  [field-name : String]
  [struct-index : i64]
  [field-index : i64]) : ResultCompilerRegistries
  (compiler-registries-add-field-id
    registries
    (compiler-symbol-require-existing-name-id struct-name)
    (compiler-symbol-require-existing-name-id field-name)
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
        (if (compiler-symbol-map-contains-id? (& fields) key-id)
          (ResultCompilerRegistries.Err
            (compiler-registries-duplicate-field-message struct-name field-name))
          (begin
            (compiler-symbol-map-bind-id!
              (&mut fields)
              key-id
              (compiler-registry-make-handle
                (compiler-symbol-kind-struct-field)
                struct-index
                field-index))
            (ResultCompilerRegistries.Ok (CompilerRegistries variants fields)))))]))

(define (compiler-registries-add-field-in-module-id
  [registries : CompilerRegistries]
  [module-id : i64]
  [struct-name-id : i64]
  [field-name-id : i64]
  [struct-index : i64]
  [field-index : i64]) : ResultCompilerRegistries
  (match registries
    [(CompilerRegistries variants fields)
      (let
        [key-id : i64
          (compiler-struct-field-key-id-in-module-by-id
            module-id
            struct-name-id
            field-name-id)]
        (if (compiler-symbol-map-contains-id? (& fields) key-id)
          (ResultCompilerRegistries.Err
            (compiler-registries-duplicate-field-message
              (compiler-symbol-module-key-by-id module-id struct-name-id)
              (intern-str field-name-id)))
          (begin
            (compiler-symbol-map-bind-id!
              (&mut fields)
              key-id
              (compiler-registry-make-handle
                (compiler-symbol-kind-struct-field)
                struct-index
                field-index))
            (ResultCompilerRegistries.Ok (CompilerRegistries variants fields)))))]))

(define (compiler-registries-add-field-alias
  [registries : CompilerRegistries]
  [module-id : i64]
  [struct-name-id : i64]
  [field-name-id : i64]
  [handle : i64]) : CompilerRegistries
  (match registries
    [(CompilerRegistries variants fields)
      (let
        [key-id : i64
          (compiler-struct-field-key-id-in-module-by-id
            module-id
            struct-name-id
            field-name-id)]
        (if (compiler-symbol-map-contains-id? (& fields) key-id)
          registries
          (begin
            (compiler-symbol-map-bind-id! (&mut fields) key-id handle)
            (CompilerRegistries variants fields))))]))

(define (compiler-registries-add-variant-aliases-list
  [registries : CompilerRegistries]
  [alias-id : i64]
  [enum-name-id : i64]
  [variants : AstVariantDefList]
  [enum-index : i64]
  [variant-index : i64]) : CompilerRegistries
  (if (>= variant-index (ast-variant-def-list-len (& variants)))
    registries
    (match (ast-variant-def-list-get
      (& variants)
      variant-index
      (ast-variant-def-fallback))
      [(AstVariantDef.Def name _ _)
        (let
          [qualified-name-id : i64
            (compiler-enum-qualified-variant-name-id enum-name-id name)]
          [handle : i64
            (compiler-registry-make-handle
              (compiler-symbol-kind-enum-variant)
              enum-index
              variant-index)]
          (compiler-registries-add-variant-aliases-list
            (compiler-registries-add-variant-alias-key-id
              (compiler-registries-add-variant-alias-key-id
                registries
                (compiler-symbol-module-key-id-by-id alias-id name)
                handle)
              (compiler-symbol-module-key-id-by-id alias-id qualified-name-id)
              handle)
            alias-id
            enum-name-id
            variants
            enum-index
            (+ variant-index 1)))])))

(define (compiler-registries-add-field-aliases-list
  [registries : CompilerRegistries]
  [module-id : i64]
  [struct-name-id : i64]
  [fields : AstFieldDefList]
  [struct-index : i64]
  [field-index : i64]) : CompilerRegistries
  (if (>= field-index (ast-field-def-list-len (& fields)))
    registries
    (match (ast-field-def-list-get
      (& fields)
      field-index
      (ast-field-def-fallback))
      [(AstFieldDef.Def name _ _)
        (compiler-registries-add-field-aliases-list
          (compiler-registries-add-field-alias
            registries
            module-id
            struct-name-id
            name
            (compiler-registry-make-handle
              (compiler-symbol-kind-struct-field)
              struct-index
              field-index))
          module-id
          struct-name-id
          fields
          struct-index
          (+ field-index 1))])))

(define (compiler-registries-add-decl-alias-in-module
  [registries : CompilerRegistries]
  [alias-id : i64]
  [decl : AstDecl]
  [index : i64]) : CompilerRegistries
  (match decl
    [(AstDecl.DefEnum name _ variants)
      (compiler-registries-add-variant-aliases-list
        registries
        alias-id
        name
        variants
        index
        0)]
    [(AstDecl.DefEnumLifetimes name _ _ variants)
      (compiler-registries-add-variant-aliases-list
        registries
        alias-id
        name
        variants
        index
        0)]
    [(AstDecl.DefStruct name _ _ fields)
      (compiler-registries-add-field-aliases-list
        registries
        alias-id
        name
        fields
        index
        0)]
    [(AstDecl.DefStructLifetimes name _ _ _ fields)
      (compiler-registries-add-field-aliases-list
        registries
        alias-id
        name
        fields
        index
        0)]
    [(AstDecl.ComptimeDecl _ template-box)
      (let
        [template : AstDecl (box-get template-box)]
        (compiler-registries-add-decl-alias-in-module
          registries
          alias-id
          template
          index))]
    [_ registries]))

(define (compiler-registries-add-module-aliases-indexed
  [registries : CompilerRegistries]
  [decls : AstDeclList]
  [index : ModuleDeclIndex]
  [target-module-id : i64]
  [alias-id : i64]) : CompilerRegistries
  (match index
    [(ModuleDeclIndex _ _ _ ent-pos ent-ridx ent-next)
      (let
        [decl-offset : i64 (struct-get decls offset)]
        [slots : (Array AstDecl) (struct-get decls slots)]
        [cur-registries : CompilerRegistries registries]
        [k : i64 (compiler-module-decl-index-head index target-module-id)]
        (begin
          (while (>= k 0)
            (begin
              (set!
                cur-registries
                (compiler-registries-add-decl-alias-in-module
                  cur-registries
                  alias-id
                  (array-ref slots (+ decl-offset (array-ref ent-pos k)))
                  (array-ref ent-ridx k)))
              (set! k (array-ref ent-next k))))
          cur-registries))]))

(define (build-compiler-registry-aliases-list
  [all-decls : AstDeclList]
  [decls : AstDeclList]
  [registries : CompilerRegistries]
  [module-id : i64]) : CompilerRegistries
  (let
    [enclosing-arena : i64 (arena.tl_arena_current)]
    [index-arena : i64 (arena.tl_arena_make)]
    [_switch-to-index : unit
      (unsafe
        (arena.tl_arena_set index-arena))]
    [decl-index : ModuleDeclIndex
      (compiler-symbols-build-module-decl-index all-decls)]
    [index-arena-head : i64 (arena.tl_arena_current)]
    [_restore-enclosing : unit
      (unsafe
        (arena.tl_arena_set enclosing-arena))]
    [result : CompilerRegistries
      (let
        [cur-registries : CompilerRegistries registries]
        [cur-module-id : i64 module-id]
        [index : i64 0]
        [decl-count : i64 (ast-decl-list-len (& decls))]
        [decl-offset : i64 (struct-get decls offset)]
        (begin
          (while (< index decl-count)
            (let
              [decl : AstDecl
                (array-ref (struct-get decls slots) (+ decl-offset index))]
              [next-registries : CompilerRegistries
                (match decl
                  [(AstDecl.Import
                      (AstImportSpec.Spec
                        _
                        _
                        (AstMaybeModuleName.Some target-module)
                        (AstMaybeImportAlias.Some alias)
                        _))
                    (if (= alias cbi.compiler-builtin-id-fix-empty)
                      (compiler-registries-add-module-aliases-indexed
                        cur-registries
                        all-decls
                        decl-index
                        target-module
                        (compiler-symbols-import-alias-key-id
                          cur-module-id
                          alias))
                      cur-registries)]
                  [_ cur-registries])]
              (begin
                (set! cur-registries next-registries)
                (match decl
                  [(AstDecl.Module next-module)
                    (set! cur-module-id next-module)]
                  [_ unit])
                (set! index (+ index 1)))))
          cur-registries))]
    (begin
      (unsafe
        (arena.tl_arena_destroy index-arena-head))
      result)))

(define (build-compiler-variant-registry-list-in-module
  [variants : AstVariantDefList]
  [registries : CompilerRegistries]
  [module-id : i64]
  [enum-name-id : i64]
  [enum-index : i64]
  [variant-index : i64]) : ResultCompilerRegistries
  (if (>= variant-index (ast-variant-def-list-len (& variants)))
    (ResultCompilerRegistries.Ok registries)
    (match (ast-variant-def-list-get
      (& variants)
      variant-index
      (ast-variant-def-fallback))
      [(AstVariantDef.Def name _ _)
        (match (compiler-registries-add-variant-in-module-id
          registries
          module-id
          enum-name-id
          name
          enum-index
          variant-index)
          [(ResultCompilerRegistries.Ok next-registries)
            (build-compiler-variant-registry-list-in-module
              variants
              next-registries
              module-id
              enum-name-id
              enum-index
              (+ variant-index 1))]
          [(ResultCompilerRegistries.Err message)
            (ResultCompilerRegistries.Err message)])])))

(define (build-compiler-field-registry-list
  [fields : AstFieldDefList]
  [registries : CompilerRegistries]
  [seen : sym_i64_env.SymI64Env]
  [module-id : i64]
  [struct-name-id : i64]
  [struct-index : i64]
  [field-index : i64]) : ResultCompilerRegistries
  (if (>= field-index (ast-field-def-list-len (& fields)))
    (ResultCompilerRegistries.Ok registries)
    (match (ast-field-def-list-get
      (& fields)
      field-index
      (ast-field-def-fallback))
      [(AstFieldDef.Def name _ _)
        (if (sym_i64_env.sym-i64-contains-id seen name)
          (ResultCompilerRegistries.Err
            (compiler-registries-duplicate-field-message
              (compiler-symbol-module-key-by-id module-id struct-name-id)
              (intern-str name)))
          (match (compiler-registries-add-field-in-module-id
            registries
            module-id
            struct-name-id
            name
            struct-index
            field-index)
            [(ResultCompilerRegistries.Ok next-registries)
              (build-compiler-field-registry-list
                fields
                next-registries
                (sym_i64_env.sym-i64-bind-id seen name field-index)
                module-id
                struct-name-id
                struct-index
                (+ field-index 1))]
            [(ResultCompilerRegistries.Err message)
              (ResultCompilerRegistries.Err message)]))])))

(define (build-compiler-registry-list
  [decls : AstDeclList]
  [registries : CompilerRegistries]
  [index : i64]) : ResultCompilerRegistries
  (build-compiler-registry-list-in-module
    decls
    registries
    index
    (compiler-symbol-root-module-id)))

(define (build-compiler-registry-list-in-module
  [decls : AstDeclList]
  [registries : CompilerRegistries]
  [index : i64]
  [module-id : i64]) : ResultCompilerRegistries
  (let
    [cur-registries : CompilerRegistries registries]
    [cur-index : i64 index]
    [cur-module-id : i64 module-id]
    [position : i64 0]
    [decl-count : i64 (ast-decl-list-len (& decls))]
    [decl-offset : i64 (struct-get decls offset)]
    [result : ResultCompilerRegistries
      (ResultCompilerRegistries.Err "symbols: internal registry walk")]
    [done : bool false]
    (begin
      (while (not done)
        (if (>= position decl-count)
          (begin
            (set! result (ResultCompilerRegistries.Ok cur-registries))
            (set! done true))
          (let
            [decl : AstDecl
              (array-ref (struct-get decls slots) (+ decl-offset position))]
            (match decl
              [(AstDecl.Import _) (set! position (+ position 1))]
              [(AstDecl.IncludeStr _ _) (set! position (+ position 1))]
              [(AstDecl.IncludeBin _ _) (set! position (+ position 1))]
              [(AstDecl.Module next-module)
                (begin
                  (set! position (+ position 1))
                  (set! cur-module-id next-module))]
              [(AstDecl.ModuleBody name body-box)
                (let
                  [body : AstDeclList (box-get body-box)]
                  [body-count : i64 (compiler-decl-list-index-count body)]
                  (match (build-compiler-registry-list-in-module
                    body
                    cur-registries
                    cur-index
                    name)
                    [(ResultCompilerRegistries.Ok next-registries)
                      (begin
                        (set! position (+ position 1))
                        (set! cur-registries next-registries)
                        (set! cur-index (+ cur-index body-count)))]
                    [(ResultCompilerRegistries.Err message)
                      (begin
                        (set! result (ResultCompilerRegistries.Err message))
                        (set! done true))]))]
              [(AstDecl.Test _ _ _) (set! position (+ position 1))]
              [(AstDecl.DefEnum name _ variants)
                (match (build-compiler-variant-registry-list-in-module
                  variants
                  cur-registries
                  cur-module-id
                  name
                  cur-index
                  0)
                  [(ResultCompilerRegistries.Ok next-registries)
                    (begin
                      (set! position (+ position 1))
                      (set! cur-registries next-registries)
                      (set! cur-index (+ cur-index 1)))]
                  [(ResultCompilerRegistries.Err message)
                    (begin
                      (set! result (ResultCompilerRegistries.Err message))
                      (set! done true))])]
              [(AstDecl.DefEnumLifetimes name _ _ variants)
                (match (build-compiler-variant-registry-list-in-module
                  variants
                  cur-registries
                  cur-module-id
                  name
                  cur-index
                  0)
                  [(ResultCompilerRegistries.Ok next-registries)
                    (begin
                      (set! position (+ position 1))
                      (set! cur-registries next-registries)
                      (set! cur-index (+ cur-index 1)))]
                  [(ResultCompilerRegistries.Err message)
                    (begin
                      (set! result (ResultCompilerRegistries.Err message))
                      (set! done true))])]
              [(AstDecl.DefStruct name _ _ fields)
                (match (build-compiler-field-registry-list
                  fields
                  cur-registries
                  (sym_i64_env.sym-i64-empty)
                  cur-module-id
                  name
                  cur-index
                  0)
                  [(ResultCompilerRegistries.Ok next-registries)
                    (begin
                      (set! position (+ position 1))
                      (set! cur-registries next-registries)
                      (set! cur-index (+ cur-index 1)))]
                  [(ResultCompilerRegistries.Err message)
                    (begin
                      (set! result (ResultCompilerRegistries.Err message))
                      (set! done true))])]
              [(AstDecl.DefStructLifetimes name _ _ _ fields)
                (match (build-compiler-field-registry-list
                  fields
                  cur-registries
                  (sym_i64_env.sym-i64-empty)
                  cur-module-id
                  name
                  cur-index
                  0)
                  [(ResultCompilerRegistries.Ok next-registries)
                    (begin
                      (set! position (+ position 1))
                      (set! cur-registries next-registries)
                      (set! cur-index (+ cur-index 1)))]
                  [(ResultCompilerRegistries.Err message)
                    (begin
                      (set! result (ResultCompilerRegistries.Err message))
                      (set! done true))])]
              [(AstDecl.ComptimeDecl _ template-box)
                (let
                  [template : AstDecl (box-get template-box)]
                  (match template
                    [(AstDecl.DefEnum name _ variants)
                      (match (build-compiler-variant-registry-list-in-module
                        variants
                        cur-registries
                        cur-module-id
                        name
                        cur-index
                        0)
                        [(ResultCompilerRegistries.Ok next-registries)
                          (begin
                            (set! position (+ position 1))
                            (set! cur-registries next-registries)
                            (set! cur-index (+ cur-index 1)))]
                        [(ResultCompilerRegistries.Err message)
                          (begin
                            (set! result (ResultCompilerRegistries.Err message))
                            (set! done true))])]
                    [(AstDecl.DefEnumLifetimes name _ _ variants)
                      (match (build-compiler-variant-registry-list-in-module
                        variants
                        cur-registries
                        cur-module-id
                        name
                        cur-index
                        0)
                        [(ResultCompilerRegistries.Ok next-registries)
                          (begin
                            (set! position (+ position 1))
                            (set! cur-registries next-registries)
                            (set! cur-index (+ cur-index 1)))]
                        [(ResultCompilerRegistries.Err message)
                          (begin
                            (set! result (ResultCompilerRegistries.Err message))
                            (set! done true))])]
                    [(AstDecl.DefStruct name _ _ fields)
                      (match (build-compiler-field-registry-list
                        fields
                        cur-registries
                        (sym_i64_env.sym-i64-empty)
                        cur-module-id
                        name
                        cur-index
                        0)
                        [(ResultCompilerRegistries.Ok next-registries)
                          (begin
                            (set! position (+ position 1))
                            (set! cur-registries next-registries)
                            (set! cur-index (+ cur-index 1)))]
                        [(ResultCompilerRegistries.Err message)
                          (begin
                            (set! result (ResultCompilerRegistries.Err message))
                            (set! done true))])]
                    [(AstDecl.DefStructLifetimes name _ _ _ fields)
                      (match (build-compiler-field-registry-list
                        fields
                        cur-registries
                        (sym_i64_env.sym-i64-empty)
                        cur-module-id
                        name
                        cur-index
                        0)
                        [(ResultCompilerRegistries.Ok next-registries)
                          (begin
                            (set! position (+ position 1))
                            (set! cur-registries next-registries)
                            (set! cur-index (+ cur-index 1)))]
                        [(ResultCompilerRegistries.Err message)
                          (begin
                            (set! result (ResultCompilerRegistries.Err message))
                            (set! done true))])]
                    [_
                      (begin
                        (set! position (+ position 1))
                        (set! cur-index (+ cur-index 1)))]))]
              [_
                (begin
                  (set! position (+ position 1))
                  (set! cur-index (+ cur-index 1)))]))))
      result)))

(define (build-compiler-registries-with-symbols
  [program : AstProgram]
  [_symbols : CompilerSymbols]) : ResultCompilerRegistries
  (match program
    [(AstProgram.Program decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (build-compiler-registry-list
          decls
          (compiler-registries-empty)
          0)
          [(ResultCompilerRegistries.Ok registries)
            (let
              [aliased : CompilerRegistries
                (build-compiler-registry-aliases-list
                  decls
                  decls
                  registries
                  (compiler-symbol-root-module-id))]
              (ResultCompilerRegistries.Ok aliased))]
          [(ResultCompilerRegistries.Err message)
            (ResultCompilerRegistries.Err message)]))]))

(define (build-compiler-registries [program : AstProgram]) : ResultCompilerRegistries
  (match (build-compiler-symbols program)
    [(ResultCompilerSymbols.Ok symbols)
      (build-compiler-registries-with-symbols program symbols)]
    [(ResultCompilerSymbols.Err message) (ResultCompilerRegistries.Err message)]))

(define (build-compiler-registries-from-source [src : String]) : ResultCompilerRegistries
  (match (parse-ast-source src)
    [(ResultAstProgram.Ok program) (build-compiler-registries program)]
    [(ResultAstProgram.Err message) (ResultCompilerRegistries.Err message)]))

(define (compiler-decl-list-at-index
  [decls : AstDeclList]
  [target : i64]
  [index : i64]) : ResultAstDecl
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil)
      (ResultAstDecl.Err "symbols: declaration index not found")]
    [(AstDeclListStep.Cons decl rest)
      (let
        [rest : AstDeclList rest]
        (match decl
          [(AstDecl.Import _) (compiler-decl-list-at-index rest target index)]
          [(AstDecl.IncludeStr _ _)
            (compiler-decl-list-at-index rest target index)]
          [(AstDecl.IncludeBin _ _)
            (compiler-decl-list-at-index rest target index)]
          [(AstDecl.Module _) (compiler-decl-list-at-index rest target index)]
          [(AstDecl.Test _ _ _) (compiler-decl-list-at-index rest target index)]
          [_
            (if (= target index)
              (match decl
                [(AstDecl.ComptimeDecl _ template-box)
                  (let
                    [template : AstDecl (box-get template-box)]
                    (ResultAstDecl.Ok template))]
                [(AstDecl.Unsafe inner-box)
                  (let
                    [inner : AstDecl (box-get inner-box)]
                    (ResultAstDecl.Ok inner))]
                [_ (ResultAstDecl.Ok decl)])
              (compiler-decl-list-at-index rest target (+ index 1)))]))]))

(define (compiler-program-decl-at-index [program : AstProgram] [target : i64]) : ResultAstDecl
  (match program
    [(AstProgram.Program decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        (compiler-decl-list-at-index decls target 0))]))

(define (compiler-symbols-decl-at-index
  [symbols : CompilerSymbols]
  [target : i64]) : ResultAstDecl
  (let
    [decls : (Array AstDecl) (compiler-symbols-decls symbols)]
    (if (or (< target 0) (>= target (array-length decls)))
      (ResultAstDecl.Err "symbols: declaration index not found")
      (ResultAstDecl.Ok (array-ref decls target)))))

(define (compiler-variant-types-at-index
  [variants : AstVariantDefList]
  [target : i64]
  [index : i64]) : ResultAstTypeList
  (if (>= index (ast-variant-def-list-len (& variants)))
    (ResultAstTypeList.Err "symbols: variant index not found")
    (match (ast-variant-def-list-get
      (& variants)
      index
      (ast-variant-def-fallback))
      [(AstVariantDef.Def _ fields _)
        (if (= target index)
          (ResultAstTypeList.Ok fields)
          (compiler-variant-types-at-index variants target (+ index 1)))])))

(define (compiler-field-type-at-index
  [fields : AstFieldDefList]
  [target : i64]
  [index : i64]) : ResultAstType
  (if (>= index (ast-field-def-list-len (& fields)))
    (ResultAstType.Err "symbols: field index not found")
    (match (ast-field-def-list-get (& fields) index (ast-field-def-fallback))
      [(AstFieldDef.Def _ ty _)
        (if (= target index)
          (ResultAstType.Ok ty)
          (compiler-field-type-at-index fields target (+ index 1)))])))

(define (compiler-registries-variant-fields
  [program : AstProgram]
  [handle : i64]) : ResultAstTypeList
  (match (compiler-program-decl-at-index
    program
    (compiler-registry-handle-owner-index handle))
    [(ResultAstDecl.Ok decl)
      (match decl
        [(AstDecl.DefEnum _ _ variants)
          (compiler-variant-types-at-index
            variants
            (compiler-registry-handle-child-index handle)
            0)]
        [(AstDecl.DefEnumLifetimes _ _ _ variants)
          (compiler-variant-types-at-index
            variants
            (compiler-registry-handle-child-index handle)
            0)]
        [_ (ResultAstTypeList.Err "symbols: variant owner is not enum")])]
    [(ResultAstDecl.Err message) (ResultAstTypeList.Err message)]))

(define (compiler-registries-variant-fields-indexed
  [symbols : CompilerSymbols]
  [handle : i64]) : ResultAstTypeList
  (match (compiler-symbols-decl-at-index
    symbols
    (compiler-registry-handle-owner-index handle))
    [(ResultAstDecl.Ok decl)
      (match decl
        [(AstDecl.DefEnum _ _ variants)
          (compiler-variant-types-at-index
            variants
            (compiler-registry-handle-child-index handle)
            0)]
        [(AstDecl.DefEnumLifetimes _ _ _ variants)
          (compiler-variant-types-at-index
            variants
            (compiler-registry-handle-child-index handle)
            0)]
        [_ (ResultAstTypeList.Err "symbols: variant owner is not enum")])]
    [(ResultAstDecl.Err message) (ResultAstTypeList.Err message)]))

(define (compiler-registries-struct-field-type
  [program : AstProgram]
  [handle : i64]) : ResultAstType
  (match (compiler-program-decl-at-index
    program
    (compiler-registry-handle-owner-index handle))
    [(ResultAstDecl.Ok decl)
      (match decl
        [(AstDecl.DefStruct _ _ _ fields)
          (compiler-field-type-at-index
            fields
            (compiler-registry-handle-child-index handle)
            0)]
        [(AstDecl.DefStructLifetimes _ _ _ _ fields)
          (compiler-field-type-at-index
            fields
            (compiler-registry-handle-child-index handle)
            0)]
        [_ (ResultAstType.Err "symbols: field owner is not struct")])]
    [(ResultAstDecl.Err message) (ResultAstType.Err message)]))

(define (compiler-registries-struct-field-type-indexed
  [symbols : CompilerSymbols]
  [handle : i64]) : ResultAstType
  (match (compiler-symbols-decl-at-index
    symbols
    (compiler-registry-handle-owner-index handle))
    [(ResultAstDecl.Ok decl)
      (match decl
        [(AstDecl.DefStruct _ _ _ fields)
          (compiler-field-type-at-index
            fields
            (compiler-registry-handle-child-index handle)
            0)]
        [(AstDecl.DefStructLifetimes _ _ _ _ fields)
          (compiler-field-type-at-index
            fields
            (compiler-registry-handle-child-index handle)
            0)]
        [_ (ResultAstType.Err "symbols: field owner is not struct")])]
    [(ResultAstDecl.Err message) (ResultAstType.Err message)]))

(define (compiler-symbol-lookup-score
  [found : option_i64.Option]
  [want-kind : i64]
  [want-index : i64]) : i64
  (match found
    [(option_i64.Some handle)
      (if (and
        (= (compiler-symbol-handle-kind handle) want-kind)
        (= (compiler-symbol-handle-index handle) want-index))
        1
        0)]
    [(option_i64.None) 0]))

(define (compiler-symbols-miss-score [found : option_i64.Option]) : i64
  (match found
    [(option_i64.None) 1]
    [(option_i64.Some _) 0]))

(define (compiler-registry-miss-score [found : option_i64.Option]) : i64
  (match found
    [(option_i64.None) 1]
    [(option_i64.Some _) 0]))

(define (compiler-registry-lookup-score
  [found : option_i64.Option]
  [want-kind : i64]
  [want-owner : i64]
  [want-child : i64]) : i64
  (match found
    [(option_i64.Some handle)
      (if (and
        (= (compiler-registry-handle-kind handle) want-kind)
        (= (compiler-registry-handle-owner-index handle) want-owner)
        (= (compiler-registry-handle-child-index handle) want-child))
        1
        0)]
    [(option_i64.None) 0]))

(define (compiler-type-result-tag-score
  [found : ResultAstType]
  [want-tag : i64]) : i64
  (match found
    [(ResultAstType.Ok ty)
      (if (= (ast-type-tag ty) want-tag)
        1
        0)]
    [(ResultAstType.Err _) 0]))

(define (compiler-type-list-single-tag-score
  [found : ResultAstTypeList]
  [want-tag : i64]) : i64
  (match found
    [(ResultAstTypeList.Ok types)
      (if (= (ast-type-list-len (& types)) 1)
        (if (=
          (ast-type-tag
            (ty-node-get (ast-type-list-get (& types) 0 (ast-type-id-fallback))))
          want-tag)
          1
          0)
        0)]
    [(ResultAstTypeList.Err _) 0]))

(define (compiler-symbols-smoke-source) : String
  "(import stdlib.test)
(defstruct Point (x i64) (y i64))
(defenum Maybe (None) (Some i64))
(extern (io.print-string [arg0 : String]) : unit)
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
                (compiler-symbols-lookup-value symbols "io.print-string")
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
    [some : option_i64.Option
      (compiler-registries-lookup-variant registries "Some")]
    [none : option_i64.Option
      (compiler-registries-lookup-variant registries "None")]
    [x-field : option_i64.Option
      (compiler-registries-lookup-struct-field registries "Point" "x")]
    [y-field : option_i64.Option
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
                [(option_i64.Some handle)
                  (compiler-type-result-tag-score
                    (compiler-registries-struct-field-type program handle)
                    (ast-type-tag (AstType.I64)))]
                [(option_i64.None) 0])
              (+
                (match some
                  [(option_i64.Some handle)
                    (compiler-type-list-single-tag-score
                      (compiler-registries-variant-fields program handle)
                      (ast-type-tag (AstType.I64)))]
                  [(option_i64.None) 0])
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

(define (compiler-symbols-module-duplicate-value-source) : String
  "(module left)
(define same : i64 1)
(define same : i64 2)")

(define (compiler-symbols-module-duplicate-type-source) : String
  "(module left)
(defstruct Point (x i64))
(defenum Point (PointVariant))")

(define (compiler-symbols-module-duplicate-macro-value-source) : String
  "(module left)
(defmacro (same) : bool (expr-bool true))
(define same : i64 1)")

(define (compiler-symbols-module-duplicate-variant-source) : String
  "(module left)
(defenum Choice (Same) (Same))")

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
    [(ResultCompilerSymbols.Err message)
      (string.eq message (compiler-symbols-duplicate-value-message "answer"))]
    [(ResultCompilerSymbols.Ok _) false]))

(define (compiler-symbols-duplicate-type-ok?) : bool
  (match (build-compiler-symbols-from-source
    (compiler-symbols-duplicate-type-source))
    [(ResultCompilerSymbols.Err message)
      (string.eq message (compiler-symbols-duplicate-type-message "Point"))]
    [(ResultCompilerSymbols.Ok _) false]))

(define (compiler-symbols-duplicate-value-error-ok?
  [src : String]
  [name : String]) : bool
  (match (build-compiler-symbols-from-source src)
    [(ResultCompilerSymbols.Err message)
      (string.eq message (compiler-symbols-duplicate-value-message name))]
    [(ResultCompilerSymbols.Ok _) false]))

(define (compiler-symbols-module-duplicate-diagnostics-ok?) : bool
  (and
    (compiler-symbols-duplicate-value-error-ok?
      (compiler-symbols-module-duplicate-value-source)
      "left/same")
    (match (build-compiler-symbols-from-source
      (compiler-symbols-module-duplicate-type-source))
      [(ResultCompilerSymbols.Err message)
        (string.eq
          message
          (compiler-symbols-duplicate-type-message "left/Point"))]
      [(ResultCompilerSymbols.Ok _) false])
    (match (build-compiler-symbols-from-source
      (compiler-symbols-module-duplicate-macro-value-source))
      [(ResultCompilerSymbols.Err message)
        (string.eq
          message
          (compiler-symbols-duplicate-macro-value-message "left/same"))]
      [(ResultCompilerSymbols.Ok _) false])
    (match (build-compiler-symbols-from-source
      (compiler-symbols-module-duplicate-variant-source))
      [(ResultCompilerSymbols.Err message)
        (string.eq
          message
          (compiler-registries-duplicate-variant-message "left/Choice.Same"))]
      [(ResultCompilerSymbols.Ok _) false])))

(define (compiler-symbols-module-duplicate-with-paths-ok?) : bool
  (match (parse-ast-source (compiler-symbols-module-duplicate-value-source))
    [(ResultAstProgram.Ok program)
      (let
        [paths : AstDeclPathList (ast-decl-path-list-new)]
        (begin
          (ast-decl-path-list-push (&mut paths) "module.tl")
          (ast-decl-path-list-push (&mut paths) "first.tl")
          (ast-decl-path-list-push (&mut paths) "duplicate.tl")
          (match (build-compiler-symbols-with-paths program paths)
            [(ResultCompilerSymbols.Err message)
              (string.eq
                message
                "symbols: duplicate value declaration left/same (first declared in first.tl; duplicate in duplicate.tl)")]
            [(ResultCompilerSymbols.Ok _) false])))]
    [(ResultAstProgram.Err _) false]))

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
    [(ResultCompilerRegistries.Err message)
      (string.eq
        message
        (compiler-registries-duplicate-variant-message "Left.Same"))]
    [(ResultCompilerRegistries.Ok _) false]))

(define (compiler-registries-cross-enum-variant-ok?) : bool
  (match (build-compiler-registries-from-source
    (compiler-registries-cross-enum-variant-source))
    [(ResultCompilerRegistries.Ok registries)
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
    [(ResultCompilerRegistries.Err _) false]))

(define (compiler-registries-duplicate-field-ok?) : bool
  (match (build-compiler-registries-from-source
    (compiler-registries-duplicate-field-source))
    [(ResultCompilerRegistries.Err message)
      (string.eq
        message
        (compiler-registries-duplicate-field-message "Pair" "x"))]
    [(ResultCompilerRegistries.Ok _) false]))

(define (compiler-symbols-macro-namespace-ok?) : bool
  (match (build-compiler-symbols-from-source (compiler-symbols-macro-source))
    [(ResultCompilerSymbols.Ok symbols)
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
    [(ResultCompilerSymbols.Err _) false]))

(define (compiler-symbols-duplicate-macro-value-ok?) : bool
  (match (build-compiler-symbols-from-source
    (compiler-symbols-duplicate-macro-value-source))
    [(ResultCompilerSymbols.Err message)
      (string.eq
        message
        (compiler-symbols-duplicate-macro-value-message "same"))]
    [(ResultCompilerSymbols.Ok _) false]))

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

(define (compiler-symbols-comptime-decl-source) : String
  "(comptime-decl (defstruct Point (x i64) (y i64)))
(comptime-decl (defenum Maybe (None) (Some i64)))
(define (main) : i64 0)")

(define (compiler-symbols-comptime-decl-ok?) : bool
  (match (parse-ast-source (compiler-symbols-comptime-decl-source))
    [(ResultAstProgram.Ok program)
      (match (build-compiler-symbols program)
        [(ResultCompilerSymbols.Ok symbols)
          (match (build-compiler-registries program)
            [(ResultCompilerRegistries.Ok registries)
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
            [(ResultCompilerRegistries.Err _) false])]
        [(ResultCompilerSymbols.Err _) false])]
    [(ResultAstProgram.Err _) false]))

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
    [(ResultAstProgram.Ok program)
      (match (build-compiler-symbols program)
        [(ResultCompilerSymbols.Ok symbols)
          (match (build-compiler-registries program)
            [(ResultCompilerRegistries.Ok registries)
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
            [(ResultCompilerRegistries.Err _) false])]
        [(ResultCompilerSymbols.Err _) false])]
    [(ResultAstProgram.Err _) false]))

(define (compiler-symbols-structural-id-api-ok?) : bool
  (match (parse-ast-source (compiler-symbols-module-scope-source))
    [(ResultAstProgram.Ok program)
      (match (build-compiler-symbols program)
        [(ResultCompilerSymbols.Ok symbols)
          (match (build-compiler-registries program)
            [(ResultCompilerRegistries.Ok registries)
              (and
                (=
                  (compiler-symbol-lookup-score
                    (compiler-symbols-lookup-value-id
                      symbols
                      cbi.compiler-builtin-id-fix-left_slash_same)
                    (compiler-symbol-kind-value-define)
                    0)
                  1)
                (=
                  (compiler-symbol-lookup-score
                    (compiler-symbols-lookup-value-in-module-id
                      symbols
                      cbi.compiler-builtin-id-fix-right
                      cbi.compiler-builtin-id-fix-same)
                    (compiler-symbol-kind-value-define)
                    3)
                  1)
                (=
                  (compiler-symbol-lookup-score
                    (compiler-symbols-lookup-type-in-module-id
                      symbols
                      cbi.compiler-builtin-id-fix-left
                      cbi.compiler-builtin-id-fix-Maybe)
                    (compiler-symbol-kind-defenum)
                    1)
                  1)
                (=
                  (compiler-registry-lookup-score
                    (compiler-registries-lookup-variant-id
                      registries
                      cbi.compiler-builtin-id-fix-right_slash_Some)
                    (compiler-symbol-kind-enum-variant)
                    4
                    1)
                  1)
                (=
                  (compiler-registry-lookup-score
                    (compiler-registries-lookup-field-in-module-id
                      registries
                      cbi.compiler-builtin-id-fix-left
                      cbi.compiler-builtin-id-fix-Point
                      cbi.compiler-builtin-id-fix-x)
                    (compiler-symbol-kind-struct-field)
                    2
                    0)
                  1))]
            [(ResultCompilerRegistries.Err _) false])]
        [(ResultCompilerSymbols.Err _) false])]
    [(ResultAstProgram.Err _) false]))

(define (compiler-symbols-direct-qualified-add-ok?) : bool
  (let
    [handle : i64
      (compiler-symbol-make-handle (compiler-symbol-kind-value-define) 17)]
    (match (compiler-symbols-add-value
      (compiler-symbols-empty)
      "left/same"
      handle)
      [(ResultCompilerSymbols.Ok symbols)
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
                cbi.compiler-builtin-id-fix-left
                cbi.compiler-builtin-id-fix-same)
              (compiler-symbol-kind-value-define)
              17)
            1))]
      [(ResultCompilerSymbols.Err _) false])))

(define (compiler-symbols-import-alias-source) : String
  "(module data)
(define answer : i64 7)
(define (get) : i64 answer)
(defmacro (all [args : bool ...]) : bool
  `(all-from (__all-args ,@args) 0))
(defmacro (all-from [carrier : Expr] [idx : Expr]) : bool
  (match idx
    [(ExprInt i)
      (match carrier
        [(ExprCall _ elems)
          (if (>= i (expr-list-length elems))
            (expr-bool true)
            `(if ,(expr-list-nth elems i)
               (all-from ,carrier ,(expr-int (+ i 1)))
               false))]
        [_ (expr-bool true)])]
    [_ (expr-bool true)]))
(defenum Maybe (None) (Some i64))
(defstruct Point (x i64))
(module main)
(import \"data.tl\" module data :as d)
(define (main) : i64 (d.get))")

(define (compiler-symbols-import-alias-ok?) : bool
  (match (parse-ast-source (compiler-symbols-import-alias-source))
    [(ResultAstProgram.Ok program)
      (match (build-compiler-symbols program)
        [(ResultCompilerSymbols.Ok symbols)
          (match (build-compiler-registries program)
            [(ResultCompilerRegistries.Ok registries)
              (and
                (=
                  (compiler-symbols-miss-score
                    (compiler-symbols-lookup-value symbols "d/get"))
                  1)
                (=
                  (compiler-symbol-lookup-score
                    (compiler-symbols-lookup-value symbols "get")
                    (compiler-symbol-kind-function-define)
                    1)
                  1)
                (=
                  (compiler-symbols-miss-score
                    (compiler-symbols-lookup-macro symbols "d/all"))
                  1)
                (=
                  (compiler-symbols-miss-score
                    (compiler-symbols-lookup-macro symbols "all"))
                  1)
                (=
                  (compiler-symbols-miss-score
                    (compiler-symbols-lookup-type symbols "d/Point"))
                  1)
                (=
                  (compiler-symbol-lookup-score
                    (compiler-symbols-lookup-type symbols "Point")
                    (compiler-symbol-kind-defstruct)
                    5)
                  1)
                (=
                  (compiler-registry-miss-score
                    (compiler-registries-lookup-variant registries "d/Some"))
                  1)
                (=
                  (compiler-registry-lookup-score
                    (compiler-registries-lookup-variant registries "Some")
                    (compiler-symbol-kind-enum-variant)
                    4
                    1)
                  1)
                (=
                  (compiler-registry-miss-score
                    (compiler-registries-lookup-struct-field
                      registries
                      "d/Point"
                      "x"))
                  1))]
            [(ResultCompilerRegistries.Err _) false])]
        [(ResultCompilerSymbols.Err _) false])]
    [(ResultAstProgram.Err _) false]))

(define (compiler-symbols-comptime-root-helper-alias-source) : String
  "(module stdlib.comptime)
(defenum Expr (ExprBool bool))
(define (string.int->string [value : i64]) : String \"\")
(define (string.append [left : String] [right : String]) : String left)
(define (string.concat [left : String] [right : String]) : String left)
(define (expr-bool [value : bool]) : Expr (ExprBool value))
(module main)
(defenum Expr (ExprBool i64))
(define (expr-bool [value : i64]) : i64 value)")

(define (compiler-symbols-comptime-root-helper-alias-ok?) : bool
  (match (parse-ast-source (compiler-symbols-comptime-root-helper-alias-source))
    [(ResultAstProgram.Ok program)
      (match (build-compiler-symbols program)
        [(ResultCompilerSymbols.Ok symbols)
          (and
            (=
              (compiler-symbol-lookup-score
                (compiler-symbols-lookup-value
                  symbols
                  "stdlib.comptime/string.int->string")
                (compiler-symbol-kind-function-define)
                1)
              1)
            (=
              (compiler-symbol-lookup-score
                (compiler-symbols-lookup-value
                  symbols
                  "stdlib.comptime/string.append")
                (compiler-symbol-kind-function-define)
                2)
              1)
            (=
              (compiler-symbol-lookup-score
                (compiler-symbols-lookup-value
                  symbols
                  "stdlib.comptime/string.concat")
                (compiler-symbol-kind-function-define)
                3)
              1)
            (=
              (compiler-symbol-lookup-score
                (compiler-symbols-lookup-value
                  symbols
                  "stdlib.comptime/expr-bool")
                (compiler-symbol-kind-function-define)
                4)
              1)
            (=
              (compiler-symbol-lookup-score
                (compiler-symbols-lookup-type symbols "stdlib.comptime/Expr")
                (compiler-symbol-kind-defenum)
                0)
              1)
            (=
              (compiler-symbols-miss-score
                (compiler-symbols-lookup-value symbols "int->string"))
              1)
            (=
              (compiler-symbols-miss-score
                (compiler-symbols-lookup-value symbols "string-append"))
              1)
            (=
              (compiler-symbols-miss-score
                (compiler-symbols-lookup-value symbols "string-concat"))
              1)
            (=
              (compiler-symbol-lookup-score
                (compiler-symbols-lookup-value symbols "expr-bool")
                (compiler-symbol-kind-function-define)
                6)
              1)
            (=
              (compiler-symbol-lookup-score
                (compiler-symbols-lookup-type symbols "Expr")
                (compiler-symbol-kind-defenum)
                5)
              1)
            (=
              (compiler-registry-lookup-score
                (compiler-symbols-lookup-value symbols "ExprBool")
                (compiler-symbol-kind-enum-variant)
                5
                0)
              1))]
        [(ResultCompilerSymbols.Err _) false])]
    [(ResultAstProgram.Err _) false]))

(define (compiler-symbols-self-test) : i64
  (begin
    (cbi.compiler-builtin-refresh!)
    (match (parse-ast-source (compiler-symbols-smoke-source))
      [(ResultAstProgram.Ok program)
        (match (build-compiler-symbols program)
          [(ResultCompilerSymbols.Ok symbols)
            (match (build-compiler-registries program)
              [(ResultCompilerRegistries.Ok registries)
                (let
                  [ok : bool true]
                  (begin
                    (if (= (compiler-symbols-smoke-score symbols) 10)
                      unit
                      (set! ok false))
                    (if (=
                      (compiler-registries-smoke-score program registries)
                      8)
                      unit
                      (set! ok false))
                    (if (compiler-symbols-duplicate-value-ok?)
                      unit
                      (set! ok false))
                    (if (compiler-symbols-duplicate-type-ok?)
                      unit
                      (set! ok false))
                    (if (compiler-symbols-module-duplicate-diagnostics-ok?)
                      unit
                      (set! ok false))
                    (if (compiler-symbols-module-duplicate-with-paths-ok?)
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
                    (if (compiler-symbols-comptime-root-helper-alias-ok?)
                      unit
                      (set! ok false))
                    (if (compiler-symbols-macro-namespace-ok?)
                      unit
                      (set! ok false))
                    (if (compiler-symbols-duplicate-macro-value-ok?)
                      unit
                      (set! ok false))
                    (if ok
                      42
                      (io.panic "symbols: smoke score mismatch"))))]
              [(ResultCompilerRegistries.Err message) (io.panic message)])]
          [(ResultCompilerSymbols.Err message) (io.panic message)])]
      [(ResultAstProgram.Err message) (io.panic message)])))