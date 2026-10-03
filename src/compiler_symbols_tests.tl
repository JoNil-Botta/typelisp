;; compiler_symbols_tests.tl - White-box tests for the symbol tables and
;; compiler-symbols-self-test.
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.io)
(import compiler_builtin_ids as cbi)
(import compiler_parse_core as parser)
(import compiler_ast_types as ast)
(import compiler_intern as ci)
(import compiler_owned_view as owned_view)
(import sym_i64_env)
(import stdlib.string)
(import stdlib.option)
(import (option.option i64) as option_i64)
(import compiler_symbols as csym)

(define (compiler-registry-handle-kind [handle : i64]) : i64
  (csym.compiler-symbol-handle-kind handle))

(define (compiler-symbols-option-or
  [found : option_i64.Option]
  [fallback : i64]) : i64
  (match found
    [(Some handle) handle]
    [None fallback]))

(define (compiler-registries-lookup-field-in-module-id
  [registries : (& registries csym.CompilerRegistries)]
  [module-id : i64]
  [type-name-id : i64]
  [field-name-id : i64]) : option_i64.Option
  (match (csym.compiler-registries-reference-shared-view registries)
    [(CompilerRegistries _ fields _)
      (csym.compiler-symbol-map-lookup-id
        (& fields)
        (csym.compiler-struct-field-key-id-in-module-by-id
          module-id
          type-name-id
          field-name-id))]))

(define (build-compiler-symbols-from-source [src : String]) : csym.ResultCompilerSymbols
  (match (parser.parse-ast-source src)
    [(Ok program) (csym.build-compiler-symbols program)]
    [(Err message) (Err message)]))

;; Registry handles encode the flattened declaration owner index. A generated
;; declaration splice before an existing owner therefore needs to move the
;; cached handle forward by the number of index-bearing declarations inserted.
;; Updating the maps in place is proportional to the registry, rather than to
;; the whole program, and preserves the ordinary positional-handle ABI used by
;; typechecking and lowering.
(define (compiler-registry-handle-shift-owner-index
  [handle : i64]
  [insertion-index : i64]
  [delta : i64]) : i64
  (let
    [owner-index : i64 (csym.compiler-registry-handle-owner-index handle)]
    (if (>= owner-index insertion-index)
      (csym.compiler-registry-make-handle
        (compiler-registry-handle-kind handle)
        (+ owner-index delta)
        (csym.compiler-registry-handle-child-index handle))
      handle)))

(define (compiler-registry-shift-map-owner-indices!
  [map : (&mut map csym.CompilerSymbolMap)]
  [insertion-index : i64]
  [delta : i64]) : unit
  (if (<= delta 0)
    unit
    (let
      [capacity : i64 (array-length map.keys)]
      [index : i64 0]
      (while (< index capacity)
        (if (> (array-ref map.keys index) 0)
          (let
            [handle : i64 (array-ref map.values index)]
            (set!
              (array-ref map.values index)
              (compiler-registry-handle-shift-owner-index
                handle
                insertion-index
                delta)))
          unit)
        (set! index (+ index 1))))))

(define (compiler-registries-shift-owner-indices
  [registries : csym.CompilerRegistries]
  [insertion-index : i64]
  [delta : i64]) : csym.CompilerRegistries
  (match (csym.compiler-registries-shared-view registries)
    [(CompilerRegistries variants fields identity)
      (compiler-registry-shift-map-owner-indices!
        (&mut variants)
        insertion-index
        delta)
      (compiler-registry-shift-map-owner-indices!
        (&mut fields)
        insertion-index
        delta)
      (CompilerRegistries variants fields identity)]))

;; Extend an existing registry across an additive declaration splice. Callers
;; must conservatively reject imports and other surfaces that can alter alias
;; resolution; this helper only repairs positional owner handles and registers
;; the declarations newly inserted at `insertion-index`.
(define (compiler-registries-insert-decls
  [registries : csym.CompilerRegistries]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [insertion-index : i64]
  [module-id : i64]) : csym.ResultCompilerRegistries
  (let
    [added-count : i64 (csym.compiler-decl-list-index-count decls)]
    [shifted : csym.CompilerRegistries
      (compiler-registries-shift-owner-indices
        registries
        insertion-index
        added-count)]
    (csym.build-compiler-registry-list-in-module
      decls
      paths
      shifted
      insertion-index
      module-id)))

(define (build-compiler-registries-from-source [src : String]) : csym.ResultCompilerRegistries
  (match (parser.parse-ast-source src)
    [(Ok program) (csym.build-compiler-registries program)]
    [(Err message) (Err message)]))

(define (compiler-symbols-owner-module-id-at-index
  [symbols : (& symbols csym.CompilerSymbols)]
  [target : i64]) : i64
  (let
    [owners : (__tl_dyn-array i64)
      (csym.compiler-symbols-owner-module-ids symbols)]
    (if (or (< target 0) (>= target (csym.compiler-symbols-decl-count symbols)))
      -1
      (array-ref owners target))))

(define (compiler-symbols-variant-name-id-at-index
  [symbols : (& symbols csym.CompilerSymbols)]
  [owner-index : i64]
  [variant-index : i64]) : i64
  (match (csym.compiler-symbols-decl-at-index symbols owner-index)
    [(Ok decl)
      (match decl
        [(DefEnum decl-meta _ _ variants)
          (compiler-symbols-option-or
            (csym.compiler-variant-name-id-at-index variants variant-index 0)
            -1)]
        [(DefEnumLifetimes decl-meta _ _ _ variants)
          (compiler-symbols-option-or
            (csym.compiler-variant-name-id-at-index variants variant-index 0)
            -1)]
        [_ -1])]
    [(Err _) -1]))

(define (compiler-field-name-id-at-index
  [fields : ast.AstFieldDefList]
  [target : i64]) : i64
  (if (or (< target 0) (>= target (ast.ast-field-def-list-len (& fields))))
    -1
    (match (ast.ast-field-def-list-get
      (& fields)
      target
      (ast.ast-field-def-fallback))
      [(Def name-id _ _) (ci.intern-syntax-id-value name-id)])))

(define (compiler-symbols-field-name-id-at-index
  [symbols : (& symbols csym.CompilerSymbols)]
  [owner-index : i64]
  [field-index : i64]) : i64
  (match (csym.compiler-symbols-decl-at-index symbols owner-index)
    [(Ok decl)
      (match decl
        [(DefStruct decl-meta _ _ _ fields)
          (compiler-field-name-id-at-index fields field-index)]
        [(DefStructLifetimes decl-meta _ _ _ _ fields)
          (compiler-field-name-id-at-index fields field-index)]
        [_ -1])]
    [(Err _) -1]))

(define (compiler-symbols-expr-source-id [expr : ast.AstExpr]) : i64
  (match expr
    [(Spanned inner _)
      (compiler-symbols-expr-source-id (ast.ast-node-get inner))]
    [(Var name-id) name-id]
    [_ -1]))

(define (compiler-symbols-decl-value-source-id-at-index
  [symbols : (& symbols csym.CompilerSymbols)]
  [target : i64]) : i64
  (match (csym.compiler-symbols-decl-at-index symbols target)
    [(Ok (Def decl-meta _ _ value))
      (compiler-symbols-expr-source-id (ast.ast-node-get value))]
    [(Ok _) -1]
    [(Err _) -1]))

(define (compiler-symbol-lookup-score
  [found : option_i64.Option]
  [want-kind : i64]
  [want-index : i64]) : i64
  (match found
    [(Some handle)
      (if (and
        (= (csym.compiler-symbol-handle-kind handle) want-kind)
        (= (csym.compiler-symbol-handle-index handle) want-index))
        1
        0)]
    [(None) 0]))

(define (compiler-symbols-miss-score [found : option_i64.Option]) : i64
  (match found
    [(None) 1]
    [(Some _) 0]))

(define (compiler-registry-miss-score [found : option_i64.Option]) : i64
  (match found
    [(None) 1]
    [(Some _) 0]))

(define (compiler-registry-lookup-score
  [found : option_i64.Option]
  [want-kind : i64]
  [want-owner : i64]
  [want-child : i64]) : i64
  (match found
    [(Some handle)
      (if (and
        (= (compiler-registry-handle-kind handle) want-kind)
        (= (csym.compiler-registry-handle-owner-index handle) want-owner)
        (= (csym.compiler-registry-handle-child-index handle) want-child))
        1
        0)]
    [(None) 0]))

(define (compiler-type-result-tag-score
  [found : parser.ResultAstType]
  [want-tag : i64]) : i64
  (match found
    [(Ok ty)
      (if (= (ast.ast-type-tag ty) want-tag)
        1
        0)]
    [(Err _) 0]))

(define (compiler-type-list-single-tag-score
  [found : parser.ResultAstTypeList]
  [want-tag : i64]) : i64
  (match found
    [(Ok types)
      (if (= (ast.ast-type-list-len (& types)) 1)
        (if (=
          (ast.ast-type-tag
            (ast.ty-node-get
              (ast.ast-type-list-get (& types) 0 (ast.ast-type-id-fallback))))
          want-tag)
          1
          0)
        0)]
    [(Err _) 0]))

(define (compiler-symbols-smoke-score
  [symbols : (& symbols csym.CompilerSymbols)]) : i64
  (let
    [point-id : i64 (csym.compiler-symbols-decl-name-id-at-index symbols 0)]
    [maybe-id : i64 (csym.compiler-symbols-decl-name-id-at-index symbols 1)]
    [none-id : i64 (compiler-symbols-variant-name-id-at-index symbols 1 0)]
    [some-id : i64 (compiler-symbols-variant-name-id-at-index symbols 1 1)]
    [extern-id : i64 (csym.compiler-symbols-decl-name-id-at-index symbols 2)]
    [answer-id : i64 (csym.compiler-symbols-decl-name-id-at-index symbols 3)]
    [main-id : i64 (csym.compiler-symbols-decl-name-id-at-index symbols 4)]
    (+
      (compiler-symbol-lookup-score
        (csym.compiler-symbols-lookup-type-id symbols point-id)
        (csym.compiler-symbol-kind-defstruct)
        0)
      (+
        (compiler-symbol-lookup-score
          (csym.compiler-symbols-lookup-value-id symbols point-id)
          (csym.compiler-symbol-kind-defstruct)
          0)
        (+
          (compiler-symbol-lookup-score
            (csym.compiler-symbols-lookup-type-id symbols maybe-id)
            (csym.compiler-symbol-kind-defenum)
            1)
          (+
            (compiler-registry-lookup-score
              (csym.compiler-symbols-lookup-value-id symbols none-id)
              (csym.compiler-symbol-kind-enum-variant)
              1
              0)
            (+
              (compiler-registry-lookup-score
                (csym.compiler-symbols-lookup-value-id symbols some-id)
                (csym.compiler-symbol-kind-enum-variant)
                1
                1)
              (+
                (compiler-symbol-lookup-score
                  (csym.compiler-symbols-lookup-value-id symbols extern-id)
                  (csym.compiler-symbol-kind-extern)
                  2)
                (+
                  (compiler-symbol-lookup-score
                    (csym.compiler-symbols-lookup-value-id symbols answer-id)
                    (csym.compiler-symbol-kind-value-define)
                    3)
                  (+
                    (compiler-symbol-lookup-score
                      (csym.compiler-symbols-lookup-value-id symbols main-id)
                      (csym.compiler-symbol-kind-function-define)
                      4)
                    (+
                      (compiler-symbols-miss-score
                        (csym.compiler-symbols-lookup-value-id symbols -1))
                      (compiler-symbols-miss-score
                        (csym.compiler-symbols-lookup-type-id symbols -1)))))))))))))

(define (compiler-registries-smoke-score
  [symbols : (& symbols csym.CompilerSymbols)]
  [registries : (& registries csym.CompilerRegistries)]) : i64
  (let
    [point-id : i64 (csym.compiler-symbols-decl-name-id-at-index symbols 0)]
    [some-id : i64 (compiler-symbols-variant-name-id-at-index symbols 1 1)]
    [none-id : i64 (compiler-symbols-variant-name-id-at-index symbols 1 0)]
    [x-id : i64 (compiler-symbols-field-name-id-at-index symbols 0 0)]
    [y-id : i64 (compiler-symbols-field-name-id-at-index symbols 0 1)]
    [some : option_i64.Option
      (csym.compiler-registries-lookup-variant-id registries some-id)]
    [none : option_i64.Option
      (csym.compiler-registries-lookup-variant-id registries none-id)]
    [x-field : option_i64.Option
      (csym.compiler-registries-lookup-struct-field-id registries point-id x-id)]
    [y-field : option_i64.Option
      (csym.compiler-registries-lookup-struct-field-id registries point-id y-id)]
    (+
      (compiler-registry-lookup-score
        some
        (csym.compiler-symbol-kind-enum-variant)
        1
        1)
      (+
        (compiler-registry-lookup-score
          none
          (csym.compiler-symbol-kind-enum-variant)
          1
          0)
        (+
          (compiler-registry-lookup-score
            x-field
            (csym.compiler-symbol-kind-struct-field)
            0
            0)
          (+
            (compiler-registry-lookup-score
              y-field
              (csym.compiler-symbol-kind-struct-field)
              0
              1)
            (+
              (match x-field
                [(Some handle)
                  (compiler-type-result-tag-score
                    (csym.compiler-registries-struct-field-type-indexed
                      symbols
                      handle)
                    (ast.ast-type-tag (I64)))]
                [(None) 0])
              (+
                (match some
                  [(Some handle)
                    (compiler-type-list-single-tag-score
                      (csym.compiler-registries-variant-fields-indexed
                        symbols
                        handle)
                      (ast.ast-type-tag (I64)))]
                  [(None) 0])
                (+
                  (compiler-symbols-miss-score
                    (csym.compiler-registries-lookup-variant-id registries -1))
                  (compiler-symbols-miss-score
                    (csym.compiler-registries-lookup-struct-field-id
                      registries
                      point-id
                      -1)))))))))))

(define (compiler-symbols-module-duplicate-value-source) : String
  "(module left)
(define same : i64 1)
(define same : i64 2)")

(define (compiler-symbols-duplicate-value-ok?) : bool
  (match (build-compiler-symbols-from-source
    "(define answer : i64 1)
(define (answer) : i64 2)")
    [(Err message)
      (string.eq
        message
        (csym.compiler-symbols-duplicate-value-message "answer"))]
    [(Ok _) false]))

(define (compiler-symbols-duplicate-type-ok?) : bool
  (match (build-compiler-symbols-from-source
    "(defstruct Point (x i64))
(defenum Point (PointVariant))")
    [(Err message)
      (string.eq message (csym.compiler-symbols-duplicate-type-message "Point"))]
    [(Ok _) false]))

(define (compiler-symbols-duplicate-value-error-ok?
  [src : String]
  [name : String]) : bool
  (match (build-compiler-symbols-from-source src)
    [(Err message)
      (string.eq message (csym.compiler-symbols-duplicate-value-message name))]
    [(Ok _) false]))

(define (compiler-symbols-module-duplicate-diagnostics-ok?) : bool
  (and
    (compiler-symbols-duplicate-value-error-ok?
      (compiler-symbols-module-duplicate-value-source)
      "left/same")
    (match (build-compiler-symbols-from-source
      "(module left)
(defstruct Point (x i64))
(defenum Point (PointVariant))")
      [(Err message)
        (string.eq
          message
          (csym.compiler-symbols-duplicate-type-message "left/Point"))]
      [(Ok _) false])
    (match (build-compiler-symbols-from-source
      "(module left)
(defmacro (same) : bool (expr-bool true))
(defmacro (same) : bool (expr-bool false))")
      [(Err message)
        (string.eq
          message
          (csym.compiler-symbols-duplicate-macro-message "left/same"))]
      [(Ok _) false])
    (match (build-compiler-symbols-from-source
      "(module left)
(defenum Choice (Same) (Same))")
      [(Err message)
        (string.eq
          message
          (csym.compiler-registries-duplicate-variant-message
            "left/Choice.Same"))]
      [(Ok _) false])))

(define (compiler-symbols-module-duplicate-with-paths-ok?) : bool
  (match (parser.parse-ast-source
    (compiler-symbols-module-duplicate-value-source))
    [(Ok program)
      (let
        [paths : ast.AstDeclPathList (ast.ast-decl-path-list-new)]
        (ast.ast-decl-path-list-push-with-owner-id
          (&mut paths)
          "module.tl"
          cbi.compiler-builtin-id-fix-empty)
        (ast.ast-decl-path-list-push-with-owner-id
          (&mut paths)
          "first.tl"
          cbi.compiler-builtin-id-fix-empty)
        (ast.ast-decl-path-list-push-with-owner-id
          (&mut paths)
          "duplicate.tl"
          cbi.compiler-builtin-id-fix-empty)
        (match (csym.build-compiler-symbols-with-paths program paths)
          [(Err message)
            (string.eq
              message
              "symbols: duplicate value declaration left/same (first declared in first.tl; duplicate in duplicate.tl)")]
          [(Ok _) false]))]
    [(Err _) false]))

(define (compiler-symbols-variant-value-collisions-ok?) : bool
  (and
    (compiler-symbols-duplicate-value-error-ok?
      "(defenum A (Foo))
(define (Foo [x : i64]) : i64 x)"
      "Foo")
    (compiler-symbols-duplicate-value-error-ok?
      "(defenum A (Foo))
(define Foo : i64 42)"
      "Foo")
    (compiler-symbols-duplicate-value-error-ok?
      "(defenum A (Foo))
(extern (Foo [arg0 : i64]) : i64)"
      "Foo")
    (compiler-symbols-duplicate-value-error-ok?
      "(defenum A (Foo))
(defstruct Foo (x i64))"
      "Foo")))

;; The bare-name handle a root declaration of `root-src` leaves behind when an
;; imported module's `ResB` variants registered first, or -1 when the root
;; declaration is rejected.
(define (compiler-symbols-root-after-imported-variants-kind [root-src : String]) : i64
  (match (parser.parse-ast-source
    "(module lib)
(defenum ResB (Err i64) (Ok i64))")
    [(Ok base-program)
      (match (csym.build-compiler-symbols base-program)
        [(Ok base-symbols)
          (match (parser.parse-ast-source root-src)
            [(Ok (Program root-box))
              (match (csym.compiler-symbols-insert-decls
                base-symbols
                (deref root-box)
                (csym.compiler-symbol-root-module-id))
                [(Ok symbols)
                  (match (csym.compiler-symbols-lookup-value-id
                    (& symbols)
                    (csym.compiler-symbols-decl-name-id-at-index symbols 1))
                    [(Some handle) (csym.compiler-symbol-handle-kind handle)]
                    [(None) -2])]
                [(Err _) -1])]
            [_ -3])]
        [(Err _) -4])]
    [(Err _) -5]))

;; #8582: an imported enum's variants register bare-name aliases before the
;; entry module's declarations. A root struct, function or value named like one
;; of them replaces the alias, because the variant is owned by its enum's
;; (non-root) module; a root enum's own variant still collides (above).
(define (compiler-symbols-root-shadows-imported-variant-ok?) : bool
  (and
    (=
      (compiler-symbols-root-after-imported-variants-kind
        "(defstruct Ok (v i64))")
      (csym.compiler-symbol-kind-defstruct))
    (=
      (compiler-symbols-root-after-imported-variants-kind
        "(define (Ok [v : i64]) : i64 v)")
      (csym.compiler-symbol-kind-function-define))
    (=
      (compiler-symbols-root-after-imported-variants-kind
        "(define Err : i64 1)")
      (csym.compiler-symbol-kind-value-define))))

(define (compiler-symbols-struct-value-collisions-ok?) : bool
  (and
    (compiler-symbols-duplicate-value-error-ok?
      "(defstruct Point (x i64))
(define (Point [x : i64]) : i64 x)"
      "Point")
    (compiler-symbols-duplicate-value-error-ok?
      "(defstruct Point (x i64))
(define Point : i64 42)"
      "Point")
    (compiler-symbols-duplicate-value-error-ok?
      "(defstruct Point (x i64))
(extern (Point [arg0 : i64]) : i64)"
      "Point")))

(define (compiler-registries-duplicate-variant-ok?) : bool
  (match (build-compiler-registries-from-source "(defenum Left (Same) (Same))")
    [(Err message)
      (string.eq
        message
        (csym.compiler-registries-duplicate-variant-message "Left.Same"))]
    [(Ok _) false]))

(define (compiler-registries-cross-enum-variant-ok?) : bool
  (match (parser.parse-ast-source
    "(defenum Left (Same))
(defenum Right (Same))")
    [(Ok program)
      (match (csym.build-compiler-symbols program)
        [(Ok symbols)
          (match (csym.build-compiler-registries program)
            [(Ok registries)
              (let
                [left-id : i64
                  (csym.compiler-symbols-decl-name-id-at-index symbols 0)]
                [left-same-id : i64
                  (compiler-symbols-variant-name-id-at-index symbols 0 0)]
                [right-id : i64
                  (csym.compiler-symbols-decl-name-id-at-index symbols 1)]
                [right-same-id : i64
                  (compiler-symbols-variant-name-id-at-index symbols 1 0)]
                (and
                  (=
                    (compiler-registry-lookup-score
                      (csym.compiler-registries-lookup-variant-id
                        registries
                        (csym.compiler-enum-qualified-variant-name-id
                          left-id
                          left-same-id))
                      (csym.compiler-symbol-kind-enum-variant)
                      0
                      0)
                    1)
                  (=
                    (compiler-registry-lookup-score
                      (csym.compiler-registries-lookup-variant-id
                        registries
                        (csym.compiler-enum-qualified-variant-name-id
                          right-id
                          right-same-id))
                      (csym.compiler-symbol-kind-enum-variant)
                      1
                      0)
                    1)))]
            [(Err _) false])]
        [(Err _) false])]
    [(Err _) false]))

(define (compiler-registries-duplicate-field-ok?) : bool
  (match (build-compiler-registries-from-source
    "(defstruct Pair (x i64) (x i64))")
    [(Err message)
      (string.eq
        message
        (csym.compiler-registries-duplicate-field-message "Pair" "x"))]
    [(Ok _) false]))

(define (compiler-symbols-macro-namespace-ok?) : bool
  (match (parser.parse-ast-source
    "(defmacro (all [first : bool] [rest : bool ...]) : bool first)
(define (main) : i64 0)")
    [(Ok program)
      (match (csym.build-compiler-symbols program)
        [(Ok symbols)
          (let
            [all-id : i64
              (csym.compiler-symbols-decl-name-id-at-index symbols 0)]
            [main-id : i64
              (csym.compiler-symbols-decl-name-id-at-index symbols 1)]
            (and
              (=
                (compiler-symbol-lookup-score
                  (csym.compiler-symbols-lookup-macro-id symbols all-id)
                  (csym.compiler-symbol-kind-defmacro)
                  0)
                1)
              (=
                (compiler-symbols-miss-score
                  (csym.compiler-symbols-lookup-value-id symbols all-id))
                1)
              (=
                (compiler-symbol-lookup-score
                  (csym.compiler-symbols-lookup-value-id symbols main-id)
                  (csym.compiler-symbol-kind-function-define)
                  1)
                1)))]
        [(Err _) false])]
    [(Err _) false]))

(define (compiler-symbols-duplicate-macro-ok?) : bool
  (match (build-compiler-symbols-from-source
    "(defmacro (same) : bool (expr-bool true))
(defmacro (same) : bool (expr-bool false))")
    [(Err message)
      (string.eq message (csym.compiler-symbols-duplicate-macro-message "same"))]
    [(Ok _) false]))

(define (compiler-symbols-value-then-macro-namespace-ok?) : bool
  (match (parser.parse-ast-source
    "(define same : i64 1)
(defmacro (same) : bool (expr-bool true))")
    [(Ok program)
      (match (csym.build-compiler-symbols program)
        [(Ok symbols)
          (let
            [same-id : i64
              (csym.compiler-symbols-decl-name-id-at-index symbols 0)]
            (and
              (=
                (compiler-symbol-lookup-score
                  (csym.compiler-symbols-lookup-value-id symbols same-id)
                  (csym.compiler-symbol-kind-value-define)
                  0)
                1)
              (=
                (compiler-symbol-lookup-score
                  (csym.compiler-symbols-lookup-macro-id symbols same-id)
                  (csym.compiler-symbol-kind-defmacro)
                  1)
                1)))]
        [(Err _) false])]
    [(Err _) false]))

(define (compiler-symbols-module-macro-then-value-namespace-ok?) : bool
  (match (parser.parse-ast-source
    "(module left)
(defmacro (same) : bool (expr-bool true))
(define same : i64 1)")
    [(Ok program)
      (match (csym.build-compiler-symbols program)
        [(Ok symbols)
          (let
            [left-id : i64 cbi.compiler-builtin-id-fix-left]
            [same-id : i64 cbi.compiler-builtin-id-fix-same]
            (and
              (=
                (compiler-symbol-lookup-score
                  (csym.compiler-symbols-lookup-value-in-module-id
                    symbols
                    left-id
                    same-id)
                  (csym.compiler-symbol-kind-value-define)
                  1)
                1)
              (=
                (compiler-symbol-lookup-score
                  (csym.compiler-symbols-lookup-macro-in-module-id
                    symbols
                    left-id
                    same-id)
                  (csym.compiler-symbol-kind-defmacro)
                  0)
                1)
              (=
                (compiler-symbol-lookup-score
                  (csym.compiler-symbols-lookup-value-id symbols same-id)
                  (csym.compiler-symbol-kind-value-define)
                  1)
                1)
              (=
                (compiler-symbol-lookup-score
                  (csym.compiler-symbols-lookup-macro-id symbols same-id)
                  (csym.compiler-symbol-kind-defmacro)
                  0)
                1)))]
        [(Err _) false])]
    [(Err _) false]))

(define (compiler-symbols-macro-then-variant-namespace-ok?) : bool
  (match (parser.parse-ast-source
    "(defmacro (same) : bool (expr-bool true))
(defenum Choice (same))")
    [(Ok program)
      (match (csym.build-compiler-symbols program)
        [(Ok symbols)
          (let
            [same-id : i64
              (compiler-symbols-variant-name-id-at-index symbols 1 0)]
            (and
              (=
                (compiler-symbol-lookup-score
                  (csym.compiler-symbols-lookup-macro-id symbols same-id)
                  (csym.compiler-symbol-kind-defmacro)
                  0)
                1)
              (=
                (compiler-registry-lookup-score
                  (csym.compiler-symbols-lookup-value-id symbols same-id)
                  (csym.compiler-symbol-kind-enum-variant)
                  1
                  0)
                1)))]
        [(Err _) false])]
    [(Err _) false]))

(define (compiler-symbols-value-macro-namespace-ok?) : bool
  (and
    (compiler-symbols-value-then-macro-namespace-ok?)
    (compiler-symbols-module-macro-then-value-namespace-ok?)
    (compiler-symbols-macro-then-variant-namespace-ok?)))

(define (compiler-registry-large-owner-handle-ok?) : bool
  (let
    [handle : i64
      (csym.compiler-registry-make-handle
        (csym.compiler-symbol-kind-enum-variant)
        1234
        5)]
    (and
      (=
        (compiler-registry-handle-kind handle)
        (csym.compiler-symbol-kind-enum-variant))
      (= (csym.compiler-registry-handle-owner-index handle) 1234)
      (= (csym.compiler-registry-handle-child-index handle) 5))))

;; A threshold-sized registry map must shift every owner handle without moving
;; its scalar key/value storage.
(define (compiler-registry-shift-map-full-ok?) : bool
  (let
    [map : csym.CompilerSymbolMap (csym.compiler-symbol-map-empty)]
    [entry-count : i64 192]
    [index : i64 0]
    [ok : bool true]
    (while (< index entry-count)
      (csym.compiler-symbol-map-put!
        (&mut map)
        index
        (csym.compiler-registry-make-handle
          (csym.compiler-symbol-kind-enum-variant)
          index
          0))
      (set! index (+ index 1)))
    (compiler-registry-shift-map-owner-indices! (&mut map) 0 1)
    (set! index 0)
    (while (< index entry-count)
      (if (=
        (compiler-registry-lookup-score
          (csym.compiler-symbol-map-lookup-id (& map) index)
          (csym.compiler-symbol-kind-enum-variant)
          (+ index 1)
          0)
        1)
        unit
        (set! ok false))
      (set! index (+ index 1)))
    ok))

(define (compiler-registries-incremental-base-source) : String
  "(module nested
  (defenum Later (Empty) (Value i64))
  (defstruct Record (value i64)))")

(define (compiler-registries-incremental-later-variant-ok?
  [symbols : (& symbols csym.CompilerSymbols)]
  [registries : (& registries csym.CompilerRegistries)]) : bool
  (let
    [module-id : i64 (compiler-symbols-owner-module-id-at-index symbols 1)]
    [enum-id : i64 (csym.compiler-symbols-decl-name-id-at-index symbols 1)]
    [variant-id : i64 (compiler-symbols-variant-name-id-at-index symbols 1 1)]
    (match (csym.compiler-registries-lookup-variant-key-id
      registries
      (csym.compiler-symbol-module-key-id-by-id
        module-id
        (csym.compiler-enum-qualified-variant-name-id enum-id variant-id)))
      [(Some handle)
        (and
          (=
            (compiler-registry-lookup-score
              (Some handle)
              (csym.compiler-symbol-kind-enum-variant)
              1
              1)
            1)
          (match (csym.compiler-registries-variant-fields-indexed
            symbols
            handle)
            [(Ok types)
              (if (= (ast.ast-type-list-len (& types)) 1)
                (match (ast.ty-node-get
                  (ast.ast-type-list-get (& types) 0 (ast.ast-type-id-fallback)))
                  [(I64) true]
                  [_ false])
                false)]
            [(Err _) false]))]
      [(None) false])))

(define (compiler-registries-incremental-later-field-ok?
  [symbols : (& symbols csym.CompilerSymbols)]
  [registries : (& registries csym.CompilerRegistries)]) : bool
  (match (compiler-registries-lookup-field-in-module-id
    registries
    (compiler-symbols-owner-module-id-at-index symbols 2)
    (csym.compiler-symbols-decl-name-id-at-index symbols 2)
    (compiler-symbols-field-name-id-at-index symbols 2 0))
    [(Some handle)
      (and
        (=
          (compiler-registry-lookup-score
            (Some handle)
            (csym.compiler-symbol-kind-struct-field)
            2
            0)
          1)
        (match (csym.compiler-registries-struct-field-type-indexed
          symbols
          handle)
          [(Ok (I64)) true]
          [(Ok _) false]
          [(Err _) false]))]
    [(None) false]))

(define (compiler-registries-lifetime-field-indexed-ok?) : bool
  (match (parser.parse-ast-source
    "(defenum NotStruct (None))
(defstruct Borrowed (:lifetimes owner) (value (& owner i64)))")
    [(Ok program)
      (match (csym.build-compiler-symbols program)
        [(Ok symbols)
          (match (csym.build-compiler-registries program)
            [(Ok registries)
              (let
                [struct-index : i64 1]
                [struct-name-id : i64
                  (csym.compiler-symbols-decl-name-id-at-index
                    symbols
                    struct-index)]
                [field-name-id : i64
                  (compiler-symbols-field-name-id-at-index
                    symbols
                    struct-index
                    0)]
                [module-id : i64
                  (compiler-symbols-owner-module-id-at-index
                    symbols
                    struct-index)]
                (match (compiler-registries-lookup-field-in-module-id
                  registries
                  module-id
                  struct-name-id
                  field-name-id)
                  [(Some handle)
                    (and
                      (=
                        (compiler-registry-handle-kind handle)
                        (csym.compiler-symbol-kind-struct-field))
                      (=
                        (csym.compiler-registry-handle-owner-index handle)
                        struct-index)
                      (= (csym.compiler-registry-handle-child-index handle) 0)
                      (match (csym.compiler-registries-struct-field-type-indexed
                        symbols
                        handle)
                        [(Ok (Ref lifetime inner))
                          (and
                            (= lifetime (ci.intern "owner"))
                            (match (ast.ty-node-get inner)
                              [(I64) true]
                              [_ false]))]
                        [_ false])
                      (match (csym.compiler-registries-struct-field-type-indexed
                        symbols
                        ;; The largest encodable owner index names no
                        ;; declaration of this program.
                        (csym.compiler-registry-make-handle
                          (csym.compiler-symbol-kind-struct-field)
                          (- (csym.compiler-registry-owner-limit) 1)
                          0))
                        [(Err message)
                          (string.eq
                            message
                            "symbols: declaration index not found")]
                        [_ false])
                      (match (csym.compiler-registries-struct-field-type-indexed
                        symbols
                        (csym.compiler-registry-make-handle
                          (csym.compiler-symbol-kind-struct-field)
                          0
                          0))
                        [(Err message)
                          (string.eq
                            message
                            "symbols: field owner is not struct")]
                        [_ false]))]
                  [(None) false]))]
            [(Err _) false])]
        [(Err _) false])]
    [(Err _) false]))

;; A generated nominal splice at the start of a nested module must leave later
;; enum-variant and struct-field handles pointing at their shifted owners.
(define (compiler-registries-incremental-splice-ok?) : bool
  (match (parser.parse-ast-source (compiler-registries-incremental-base-source))
    [(Ok base-program)
      (match (csym.build-compiler-symbols base-program)
        [(Ok base-symbols)
          (match (csym.build-compiler-registries base-program)
            [(Ok base-registries)
              (match (parser.parse-ast-source "(defstruct Inserted (id i64))")
                [(Ok splice-program)
                  (match splice-program
                    [(Program splice-box)
                      (let
                        [splice-decls : ast.AstDeclList (deref splice-box)]
                        [splice-paths : ast.AstDeclPathList
                          (csym.compiler-symbol-path-list-repeat
                            splice-decls
                            ""
                            cbi.compiler-builtin-id-fix-empty)]
                        (match (compiler-registries-insert-decls
                          base-registries
                          splice-decls
                          splice-paths
                          0
                          (compiler-symbols-owner-module-id-at-index
                            base-symbols
                            0))
                          [(Ok rebased-registries)
                            (match (parser.parse-ast-source
                              "(module nested
  (defstruct Inserted (id i64))
  (defenum Later (Empty) (Value i64))
  (defstruct Record (value i64)))")
                              [(Ok combined-program)
                                (match (csym.build-compiler-symbols
                                  combined-program)
                                  [(Ok combined-symbols)
                                    (and
                                      (compiler-registries-incremental-later-variant-ok?
                                        combined-symbols
                                        rebased-registries)
                                      (compiler-registries-incremental-later-field-ok?
                                        combined-symbols
                                        rebased-registries))]
                                  [(Err _) false])]
                              [(Err _) false])]
                          [(Err _) false]))])]
                [(Err _) false])]
            [(Err _) false])]
        [(Err _) false])]
    [(Err _) false]))

(define (compiler-symbols-append-external-macro-alias-ok?) : bool
  (match (parser.parse-ast-source
    "(module data)
(defmacro (all [first : bool]) : bool first)")
    [(Ok base-program)
      (match (csym.build-compiler-symbols base-program)
        [(Ok base-symbols)
          (match (parser.parse-ast-source
            "(module fresh)
(define answer : i64 42)
(module main)
(import data as d)")
            [(Ok splice-program)
              (match splice-program
                [(Program splice-box)
                  (match (csym.compiler-symbols-insert-decls
                    base-symbols
                    (deref splice-box)
                    (csym.compiler-symbol-root-module-id))
                    [(Ok appended)
                      (let
                        [macro-id : i64
                          (csym.compiler-symbols-decl-name-id-at-index
                            appended
                            0)]
                        [module-id : i64
                          (compiler-symbols-owner-module-id-at-index appended 0)]
                        (and
                          (=
                            (compiler-symbol-lookup-score
                              (csym.compiler-symbols-lookup-macro-in-module-id
                                appended
                                module-id
                                macro-id)
                              (csym.compiler-symbol-kind-defmacro)
                              0)
                            1)
                          (=
                            (compiler-symbols-miss-score
                              (csym.compiler-symbols-lookup-macro-id
                                appended
                                macro-id))
                            1)))]
                    [(Err _) false])])]
            [(Err _) false])]
        [(Err _) false])]
    [(Err _) false]))

;; Append-only symbol and registry growth keeps old handles stable while the
;; new nominal owners share the symbol table's logical end.
(define (compiler-symbols-append-splice-ok?) : bool
  (match (parser.parse-ast-source (compiler-registries-incremental-base-source))
    [(Ok base-program)
      (match (csym.build-compiler-symbols base-program)
        [(Ok base-symbols)
          (match (csym.build-compiler-registries base-program)
            [(Ok base-registries)
              (match (parser.parse-ast-source
                "(module fresh
  (defenum Added (None) (Some i64))
  (defstruct Boxed (value i64)))")
                [(Ok splice-program)
                  (match splice-program
                    [(Program splice-box)
                      (let
                        [splice-decls : ast.AstDeclList (deref splice-box)]
                        [splice-paths : ast.AstDeclPathList
                          (csym.compiler-symbol-path-list-repeat
                            splice-decls
                            "generated.tl"
                            cbi.compiler-builtin-id-fix-empty)]
                        [append-index : i64
                          (csym.compiler-symbols-decl-count base-symbols)]
                        (match (csym.compiler-symbols-insert-decls
                          base-symbols
                          (ast.ast-place-shared-view splice-decls)
                          (csym.compiler-symbol-root-module-id))
                          [(Ok appended-symbols)
                            (match (csym.compiler-registries-append-decls
                              base-registries
                              splice-decls
                              splice-paths
                              append-index
                              (csym.compiler-symbol-root-module-id))
                              [(Ok appended-registries)
                                (let
                                  [old-module-id : i64
                                    (compiler-symbols-owner-module-id-at-index
                                      appended-symbols
                                      0)]
                                  [old-enum-id : i64
                                    (csym.compiler-symbols-decl-name-id-at-index
                                      appended-symbols
                                      0)]
                                  [old-variant-id : i64
                                    (compiler-symbols-variant-name-id-at-index
                                      appended-symbols
                                      0
                                      1)]
                                  [new-module-id : i64
                                    (compiler-symbols-owner-module-id-at-index
                                      appended-symbols
                                      append-index)]
                                  [new-enum-id : i64
                                    (csym.compiler-symbols-decl-name-id-at-index
                                      appended-symbols
                                      append-index)]
                                  [new-variant-id : i64
                                    (compiler-symbols-variant-name-id-at-index
                                      appended-symbols
                                      append-index
                                      1)]
                                  (and
                                    (=
                                      (csym.compiler-symbols-decl-count
                                        appended-symbols)
                                      (+ append-index 2))
                                    (=
                                      (compiler-registry-lookup-score
                                        (csym.compiler-registries-lookup-variant-key-id
                                          appended-registries
                                          (csym.compiler-symbol-module-key-id-by-id
                                            old-module-id
                                            (csym.compiler-enum-qualified-variant-name-id
                                              old-enum-id
                                              old-variant-id)))
                                        (csym.compiler-symbol-kind-enum-variant)
                                        0
                                        1)
                                      1)
                                    (=
                                      (compiler-registry-lookup-score
                                        (csym.compiler-registries-lookup-variant-key-id
                                          appended-registries
                                          (csym.compiler-symbol-module-key-id-by-id
                                            new-module-id
                                            (csym.compiler-enum-qualified-variant-name-id
                                              new-enum-id
                                              new-variant-id)))
                                        (csym.compiler-symbol-kind-enum-variant)
                                        append-index
                                        1)
                                      1)))]
                              [(Err _) false])]
                          [(Err _) false]))])]
                [(Err _) false])]
            [(Err _) false])]
        [(Err _) false])]
    [(Err _) false]))

(define (compiler-symbols-nominal-decl-ok?) : bool
  (match (parser.parse-ast-source
    "(defstruct Point (x i64) (y i64))
(defenum Maybe (None) (Some i64))
(define (main) : i64 0)")
    [(Ok program)
      (match (csym.build-compiler-symbols program)
        [(Ok symbols)
          (match (csym.build-compiler-registries program)
            [(Ok registries)
              (and
                (=
                  (compiler-symbol-lookup-score
                    (csym.compiler-symbols-lookup-type-id
                      symbols
                      (csym.compiler-symbols-decl-name-id-at-index symbols 0))
                    (csym.compiler-symbol-kind-defstruct)
                    0)
                  1)
                (=
                  (compiler-symbol-lookup-score
                    (csym.compiler-symbols-lookup-type-id
                      symbols
                      (csym.compiler-symbols-decl-name-id-at-index symbols 1))
                    (csym.compiler-symbol-kind-defenum)
                    1)
                  1)
                (= (compiler-registries-smoke-score symbols registries) 8))]
            [(Err _) false])]
        [(Err _) false])]
    [(Err _) false]))

;; The index of the first declaration named `name`, or -1.
(define (compiler-symbols-index-named
  [symbols : (& symbols csym.CompilerSymbols)]
  [name : String]) : i64
  (let
    [index : i64 0]
    [found : i64 -1]
    (while (and
      (< found 0)
      (< index (csym.compiler-symbols-decl-count symbols)))
      (let
        [name-id : i64
          (csym.compiler-symbols-decl-name-id-at-index symbols index)]
        (if (and
          (ci.intern-renderable-id? name-id)
          (string.eq (ci.intern-str name-id) name))
          (set! found index)
          unit)
        (set! index (+ index 1))))
    found))

;; The in-place owner-name comparison: 1 equal, 0 different, -1 unresolved, or
;; -2 when a resolved answer disagrees with comparing the rendered owner name.
(define (compiler-symbols-owner-compare-checked
  [symbols : (& symbols csym.CompilerSymbols)]
  [target : i64]
  [nominal-id : i64]) : i64
  (let
    [rendered-equal? : bool
      (match (csym.compiler-symbols-owner-name-at-index symbols target)
        [(CompilerSomeString name)
          (string.eq (ast.ast-nominal-name-id-display nominal-id) name)]
        [(CompilerNoString) false])]
    (match (csym.compiler-symbols-owner-name-at-index-compare
      symbols
      target
      nominal-id)
      [(Equal)
        (if rendered-equal?
          1
          -2)]
      [(Different)
        (if rendered-equal?
          -2
          0)]
      [(Unresolved) -1])))

(define (compiler-symbols-owner-compare-ok?) : bool
  (match (parser.parse-ast-source
    "(defstruct Top (x i64))
(module left)
(defstruct Point (x i64))
(define (helper) : i64 0)")
    [(Ok program)
      (match (csym.build-compiler-symbols program)
        [(Ok symbols)
          (let
            [top : i64 (compiler-symbols-index-named (& symbols) "Top")]
            [point : i64 (compiler-symbols-index-named (& symbols) "Point")]
            [helper : i64 (compiler-symbols-index-named (& symbols) "helper")]
            [left-id : i64
              (compiler-symbols-owner-module-id-at-index symbols point)]
            [point-id : i64
              (csym.compiler-symbols-decl-name-id-at-index symbols point)]
            [owners : (__tl_dyn-array i64)
              (csym.compiler-symbols-owner-module-ids symbols)]
            (and
              (>= top 0)
              (>= point 0)
              (>= helper 0)
              ;; A qualified source id and the structural module/name pair both
              ;; display as the owner's name.
              (=
                (compiler-symbols-owner-compare-checked
                  (& symbols)
                  point
                  (ci.intern "left/Point"))
                1)
              (=
                (compiler-symbols-owner-compare-checked
                  (& symbols)
                  point
                  (ci.intern-composite-pair-id left-id point-id))
                1)
              (=
                (compiler-symbols-owner-compare-checked
                  (& symbols)
                  helper
                  (ci.intern "left/helper"))
                1)
              ;; Each part and the separator must match exactly.
              (=
                (compiler-symbols-owner-compare-checked
                  (& symbols)
                  point
                  (ci.intern "left/Poin"))
                0)
              (=
                (compiler-symbols-owner-compare-checked
                  (& symbols)
                  point
                  (ci.intern "left/Points"))
                0)
              (=
                (compiler-symbols-owner-compare-checked
                  (& symbols)
                  point
                  (ci.intern "left.Point"))
                0)
              (=
                (compiler-symbols-owner-compare-checked
                  (& symbols)
                  point
                  (ci.intern "lefx/Point"))
                0)
              (=
                (compiler-symbols-owner-compare-checked
                  (& symbols)
                  point
                  (ci.intern "Point"))
                0)
              (=
                (compiler-symbols-owner-compare-checked
                  (& symbols)
                  point
                  (ci.intern "left/helper"))
                0)
              ;; Root owners, macro-local module texts and missing declarations
              ;; are left to the rendered comparison.
              (=
                (compiler-symbols-owner-compare-checked
                  (& symbols)
                  top
                  (ci.intern "Top"))
                -1)
              ;; Source cannot spell these owner modules, so the test rewrites
              ;; Point's owner lane: a module text with the macro-local prefix
              ;; is left to the rendered comparison, and a structural module
              ;; renders through its fallback text.
              (begin
                (set!
                  (array-ref owners point)
                  (ci.intern "__tl_macro_local$hidden"))
                (=
                  (compiler-symbols-owner-compare-checked
                    (& symbols)
                    point
                    (ci.intern "__tl_macro_local$hidden/Point"))
                  -1))
              (begin
                (set!
                  (array-ref owners point)
                  (ci.intern-composite-pair-id left-id point-id))
                (and
                  (=
                    (compiler-symbols-owner-compare-checked
                      (& symbols)
                      point
                      (ci.intern "<structural-module>/Point"))
                    1)
                  (=
                    (compiler-symbols-owner-compare-checked
                      (& symbols)
                      point
                      (ci.intern "left/Point"))
                    0)))
              (=
                (compiler-symbols-owner-compare-checked
                  (& symbols)
                  -1
                  (ci.intern "left/Point"))
                -1)
              (=
                (compiler-symbols-owner-compare-checked
                  (& symbols)
                  (csym.compiler-symbols-decl-count symbols)
                  (ci.intern "left/Point"))
                -1)))]
        [(Err _) false])]
    [(Err _) false]))

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
  (match (parser.parse-ast-source (compiler-symbols-module-scope-source))
    [(Ok program)
      (match (csym.build-compiler-symbols program)
        [(Ok symbols)
          (match (csym.build-compiler-registries program)
            [(Ok registries)
              (let
                [left-module-id : i64
                  (compiler-symbols-owner-module-id-at-index symbols 0)]
                [right-module-id : i64
                  (compiler-symbols-owner-module-id-at-index symbols 3)]
                [left-same-id : i64
                  (csym.compiler-symbols-decl-name-id-at-index symbols 0)]
                [right-same-id : i64
                  (csym.compiler-symbols-decl-name-id-at-index symbols 3)]
                [left-maybe-id : i64
                  (csym.compiler-symbols-decl-name-id-at-index symbols 1)]
                [left-none-id : i64
                  (compiler-symbols-variant-name-id-at-index symbols 1 0)]
                [right-some-id : i64
                  (compiler-symbols-variant-name-id-at-index symbols 4 1)]
                [left-point-id : i64
                  (csym.compiler-symbols-decl-name-id-at-index symbols 2)]
                [right-point-id : i64
                  (csym.compiler-symbols-decl-name-id-at-index symbols 5)]
                [left-x-id : i64
                  (compiler-symbols-field-name-id-at-index symbols 2 0)]
                [right-x-id : i64
                  (compiler-symbols-field-name-id-at-index symbols 5 0)]
                (and
                  (=
                    (compiler-symbol-lookup-score
                      (csym.compiler-symbols-lookup-value-in-module-id
                        symbols
                        left-module-id
                        left-same-id)
                      (csym.compiler-symbol-kind-value-define)
                      0)
                    1)
                  (=
                    (compiler-symbol-lookup-score
                      (csym.compiler-symbols-lookup-value-in-module-id
                        symbols
                        right-module-id
                        right-same-id)
                      (csym.compiler-symbol-kind-value-define)
                      3)
                    1)
                  (=
                    (compiler-symbol-lookup-score
                      (csym.compiler-symbols-lookup-type-in-module-id
                        symbols
                        left-module-id
                        left-maybe-id)
                      (csym.compiler-symbol-kind-defenum)
                      1)
                    1)
                  (=
                    (compiler-symbol-lookup-score
                      (csym.compiler-symbols-lookup-type-in-module-id
                        symbols
                        right-module-id
                        right-point-id)
                      (csym.compiler-symbol-kind-defstruct)
                      5)
                    1)
                  (=
                    (compiler-registry-lookup-score
                      (csym.compiler-registries-lookup-variant-key-id
                        registries
                        (csym.compiler-symbol-module-key-id-by-id
                          left-module-id
                          left-none-id))
                      (csym.compiler-symbol-kind-enum-variant)
                      1
                      0)
                    1)
                  (=
                    (compiler-registry-lookup-score
                      (csym.compiler-registries-lookup-variant-key-id
                        registries
                        (csym.compiler-symbol-module-key-id-by-id
                          right-module-id
                          right-some-id))
                      (csym.compiler-symbol-kind-enum-variant)
                      4
                      1)
                    1)
                  (=
                    (compiler-registry-lookup-score
                      (compiler-registries-lookup-field-in-module-id
                        registries
                        left-module-id
                        left-point-id
                        left-x-id)
                      (csym.compiler-symbol-kind-struct-field)
                      2
                      0)
                    1)
                  (=
                    (compiler-registry-lookup-score
                      (compiler-registries-lookup-field-in-module-id
                        registries
                        right-module-id
                        right-point-id
                        right-x-id)
                      (csym.compiler-symbol-kind-struct-field)
                      5
                      0)
                    1)))]
            [(Err _) false])]
        [(Err _) false])]
    [(Err _) false]))

;; A declaration's fallback error span is the first source-span wrapper around
;; its body, found through unary, annotation, cast and borrow nodes. With two
;; wrappers the outer span survives as the outer wrapper's ReSpan view, while
;; the node-owned canonical span is the inner one.
(define (compiler-symbols-span-is?
  [found : csym.CompilerSymbolsMaybeSpan]
  [want : ast.AstSourceSpan]) : bool
  (match found
    [(Some span) (ast.ast-source-span-eq? span want)]
    [(No) false]))

(define (compiler-symbols-decl-span-view-ok?) : bool
  (let
    [outer-span : ast.AstSourceSpan (ast.ast-source-span 3 1 3 30)]
    [inner-span : ast.AstSourceSpan (ast.ast-source-span 3 5 3 20)]
    [value : i64 (ast.ast-node-push (Literal (ast.ast-lit-int 7)))]
    [inner : i64 (ast.ast-expr-spanned value inner-span)]
    [outer : i64 (ast.ast-expr-spanned inner outer-span)]
    [negated : i64 (ast.ast-expr-unary Neg inner)]
    [bare : i64 (ast.ast-node-push (Literal (ast.ast-lit-int 8)))]
    [name : i64 (ci.intern-generated-name "span_view")]
    (and
      (compiler-symbols-span-is?
        (csym.compiler-symbols-decl-maybe-span
          (ast.ast-decl-def-id name No outer))
        outer-span)
      (compiler-symbols-span-is?
        (csym.compiler-symbols-decl-maybe-span
          (ast.ast-decl-def-id name No negated))
        inner-span)
      (match (csym.compiler-symbols-decl-maybe-span
        (ast.ast-decl-def-id name No bare))
        [(Some _) false]
        [(No) true])
      (match (ast.ast-expr-canonical-span outer)
        [(Some span) (ast.ast-source-span-eq? span inner-span)]
        [(No) false]))))

(define (compiler-symbols-structural-id-api-ok?) : bool
  (match (parser.parse-ast-source (compiler-symbols-module-scope-source))
    [(Ok program)
      (match (csym.build-compiler-symbols program)
        [(Ok symbols)
          (match (csym.build-compiler-registries program)
            [(Ok registries)
              (and
                (=
                  (compiler-symbol-lookup-score
                    (csym.compiler-symbols-lookup-value-id
                      symbols
                      cbi.compiler-builtin-id-fix-left_slash_same)
                    (csym.compiler-symbol-kind-value-define)
                    0)
                  1)
                (=
                  (compiler-symbol-lookup-score
                    (csym.compiler-symbols-lookup-value-in-module-id
                      symbols
                      cbi.compiler-builtin-id-fix-right
                      cbi.compiler-builtin-id-fix-same)
                    (csym.compiler-symbol-kind-value-define)
                    3)
                  1)
                (=
                  (compiler-symbol-lookup-score
                    (csym.compiler-symbols-lookup-type-in-module-id
                      symbols
                      cbi.compiler-builtin-id-fix-left
                      cbi.compiler-builtin-id-fix-Maybe)
                    (csym.compiler-symbol-kind-defenum)
                    1)
                  1)
                (=
                  (compiler-registry-lookup-score
                    (csym.compiler-registries-lookup-variant-id
                      registries
                      cbi.compiler-builtin-id-fix-right_slash_Some)
                    (csym.compiler-symbol-kind-enum-variant)
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
                    (csym.compiler-symbol-kind-struct-field)
                    2
                    0)
                  1))]
            [(Err _) false])]
        [(Err _) false])]
    [(Err _) false]))

(define (compiler-symbol-map-fast-path-ok?) : bool
  (let
    [map : csym.CompilerSymbolMap (csym.compiler-symbol-map-empty)]
    [direct-id : i64 7]
    [structural-a : i64 (csym.compiler-composite-pair-key-id 131073 262147)]
    [structural-b : i64 (csym.compiler-composite-pair-key-id 131074 262148)]
    (csym.compiler-symbol-map-bind-id! (&mut map) direct-id 101)
    (csym.compiler-symbol-map-bind-id! (&mut map) structural-a 201)
    (csym.compiler-symbol-map-bind-id! (&mut map) structural-b 202)
    (and
      (match (csym.compiler-symbol-map-lookup-id (& map) direct-id)
        [(Some handle) (= handle 101)]
        [(None) false])
      (match (csym.compiler-symbol-map-lookup-id (& map) structural-a)
        [(Some handle) (= handle 201)]
        [(None) false])
      (match (csym.compiler-symbol-map-lookup-id (& map) structural-b)
        [(Some handle) (= handle 202)]
        [(None) false])
      (csym.compiler-symbol-map-remove-id! (&mut map) structural-a)
      (match (csym.compiler-symbol-map-lookup-id (& map) structural-a)
        [(Some _) false]
        [(None) true])
      (match (csym.compiler-symbol-map-lookup-id (& map) structural-b)
        [(Some handle) (= handle 202)]
        [(None) false])
      (csym.compiler-symbol-map-remove-id! (&mut map) direct-id)
      (match (csym.compiler-symbol-map-lookup-id (& map) direct-id)
        [(Some _) false]
        [(None) true]))))

(define (compiler-symbols-direct-qualified-add-ok?) : bool
  (let
    [handle : i64
      (csym.compiler-symbol-make-handle
        (csym.compiler-symbol-kind-value-define)
        17)]
    [key-id : i64
      (csym.compiler-symbol-module-key-id-by-id
        cbi.compiler-builtin-id-fix-left
        cbi.compiler-builtin-id-fix-same)]
    (match (csym.compiler-symbols-add-value-id
      (csym.compiler-symbols-empty)
      key-id
      "left/same"
      handle)
      [(Ok symbols)
        (and
          (=
            (compiler-symbol-lookup-score
              (csym.compiler-symbols-lookup-value-id symbols key-id)
              (csym.compiler-symbol-kind-value-define)
              17)
            1)
          (=
            (compiler-symbol-lookup-score
              (csym.compiler-symbols-lookup-value-in-module-id
                symbols
                cbi.compiler-builtin-id-fix-left
                cbi.compiler-builtin-id-fix-same)
              (csym.compiler-symbol-kind-value-define)
              17)
            1))]
      [(Err _) false])))

(define (compiler-program-first-import-alias-id [program : ast.AstProgram]) : i64
  (match program
    [(Program decls-box)
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        [index : i64 0]
        [count : i64 (ast.ast-decl-list-len (& decls))]
        (while (< index count)
          (match (ast.ast-decl-list-get (& decls) index (ast.ast-decl-fallback))
            [(Import decl-meta (Spec _ _ _ (Some alias-id) _))
              (return alias-id)]
            [_ (set! index (+ index 1))]))
        -1)]))

(define (compiler-symbols-import-alias-ok?) : bool
  (match (parser.parse-ast-source
    "(module data)
(define answer : i64 7)
(define (get) : i64 answer)
(defmacro (all [args : bool ...]) : bool
  `(all-from (__all-args ,@args) 0))
(defmacro (all-from [carrier : Expr] [idx : Expr]) : bool
  (match idx
    [(Expr.Int i)
      (match carrier
        [(Expr.Call _ elems)
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
(import data as d)
(define (main) : i64 (d.get))")
    [(Ok program)
      (match (csym.build-compiler-symbols program)
        [(Ok symbols)
          (match (csym.build-compiler-registries program)
            [(Ok registries)
              (let
                [alias-id : i64
                  (compiler-program-first-import-alias-id program)]
                [get-id : i64
                  (csym.compiler-symbols-decl-name-id-at-index symbols 1)]
                [all-id : i64
                  (csym.compiler-symbols-decl-name-id-at-index symbols 2)]
                [point-id : i64
                  (csym.compiler-symbols-decl-name-id-at-index symbols 5)]
                [some-id : i64
                  (compiler-symbols-variant-name-id-at-index symbols 4 1)]
                [x-id : i64
                  (compiler-symbols-field-name-id-at-index symbols 5 0)]
                (and
                  (=
                    (compiler-symbols-miss-score
                      (csym.compiler-symbols-lookup-value-id
                        symbols
                        (csym.compiler-symbol-module-key-id-by-id
                          alias-id
                          get-id)))
                    1)
                  (=
                    (compiler-symbol-lookup-score
                      (csym.compiler-symbols-lookup-value-id symbols get-id)
                      (csym.compiler-symbol-kind-function-define)
                      1)
                    1)
                  (=
                    (compiler-symbols-miss-score
                      (csym.compiler-symbols-lookup-macro-id
                        symbols
                        (csym.compiler-symbol-module-key-id-by-id
                          alias-id
                          all-id)))
                    1)
                  (=
                    (compiler-symbols-miss-score
                      (csym.compiler-symbols-lookup-macro-id symbols all-id))
                    1)
                  (=
                    (compiler-symbols-miss-score
                      (csym.compiler-symbols-lookup-type-id
                        symbols
                        (csym.compiler-symbol-module-key-id-by-id
                          alias-id
                          point-id)))
                    1)
                  (=
                    (compiler-symbol-lookup-score
                      (csym.compiler-symbols-lookup-type-id symbols point-id)
                      (csym.compiler-symbol-kind-defstruct)
                      5)
                    1)
                  (=
                    (compiler-registry-miss-score
                      (csym.compiler-registries-lookup-variant-key-id
                        registries
                        (csym.compiler-symbol-module-key-id-by-id
                          alias-id
                          some-id)))
                    1)
                  (=
                    (compiler-registry-lookup-score
                      (csym.compiler-registries-lookup-variant-id
                        registries
                        some-id)
                      (csym.compiler-symbol-kind-enum-variant)
                      4
                      1)
                    1)
                  (=
                    (compiler-registry-miss-score
                      (compiler-registries-lookup-field-in-module-id
                        registries
                        alias-id
                        point-id
                        x-id))
                    1)))]
            [(Err _) false])]
        [(Err _) false])]
    [(Err _) false]))

(define (compiler-symbols-comptime-root-helper-alias-ok?) : bool
  (match (parser.parse-ast-source
    "(module stdlib.comptime)
(defenum Expr (Bool bool))
(define (string.int->string [value : i64]) : String \"\")
(define (string.append [left : String] [right : String]) : String left)
(define (string.concat [left : String] [right : String]) : String left)
(define (expr-bool [value : bool]) : Expr (Expr.Bool value))
(module main)
(defenum Expr (Bool i64))
(define (expr-bool [value : i64]) : i64 value)")
    [(Ok program)
      (match (csym.build-compiler-symbols program)
        [(Ok symbols)
          (let
            [comptime-module-id : i64
              (compiler-symbols-owner-module-id-at-index symbols 0)]
            [comptime-expr-id : i64
              (csym.compiler-symbols-decl-name-id-at-index symbols 0)]
            [int-to-string-id : i64
              (csym.compiler-symbols-decl-name-id-at-index symbols 1)]
            [append-id : i64
              (csym.compiler-symbols-decl-name-id-at-index symbols 2)]
            [concat-id : i64
              (csym.compiler-symbols-decl-name-id-at-index symbols 3)]
            [comptime-expr-bool-id : i64
              (csym.compiler-symbols-decl-name-id-at-index symbols 4)]
            [main-expr-id : i64
              (csym.compiler-symbols-decl-name-id-at-index symbols 5)]
            [main-expr-bool-id : i64
              (csym.compiler-symbols-decl-name-id-at-index symbols 6)]
            [main-expr-bool-variant-id : i64
              (compiler-symbols-variant-name-id-at-index symbols 5 0)]
            (and
              (=
                (compiler-symbol-lookup-score
                  (csym.compiler-symbols-lookup-value-in-module-id
                    symbols
                    comptime-module-id
                    int-to-string-id)
                  (csym.compiler-symbol-kind-function-define)
                  1)
                1)
              (=
                (compiler-symbol-lookup-score
                  (csym.compiler-symbols-lookup-value-in-module-id
                    symbols
                    comptime-module-id
                    append-id)
                  (csym.compiler-symbol-kind-function-define)
                  2)
                1)
              (=
                (compiler-symbol-lookup-score
                  (csym.compiler-symbols-lookup-value-in-module-id
                    symbols
                    comptime-module-id
                    concat-id)
                  (csym.compiler-symbol-kind-function-define)
                  3)
                1)
              (=
                (compiler-symbol-lookup-score
                  (csym.compiler-symbols-lookup-value-in-module-id
                    symbols
                    comptime-module-id
                    comptime-expr-bool-id)
                  (csym.compiler-symbol-kind-function-define)
                  4)
                1)
              (=
                (compiler-symbol-lookup-score
                  (csym.compiler-symbols-lookup-type-in-module-id
                    symbols
                    comptime-module-id
                    comptime-expr-id)
                  (csym.compiler-symbol-kind-defenum)
                  0)
                1)
              (=
                (compiler-symbols-miss-score
                  (csym.compiler-symbols-lookup-value-id
                    symbols
                    (cbi.compiler-builtin-ctfe "int->string")))
                1)
              (=
                (compiler-symbols-miss-score
                  (csym.compiler-symbols-lookup-value-id
                    symbols
                    (cbi.compiler-builtin-ctfe "string-append")))
                1)
              (=
                (compiler-symbols-miss-score
                  (csym.compiler-symbols-lookup-value-id
                    symbols
                    (cbi.compiler-builtin-ctfe "string-concat")))
                1)
              (=
                (compiler-symbol-lookup-score
                  (csym.compiler-symbols-lookup-value-id
                    symbols
                    main-expr-bool-id)
                  (csym.compiler-symbol-kind-function-define)
                  6)
                1)
              (=
                (compiler-symbol-lookup-score
                  (csym.compiler-symbols-lookup-type-id symbols main-expr-id)
                  (csym.compiler-symbol-kind-defenum)
                  5)
                1)
              (=
                (compiler-registry-lookup-score
                  (csym.compiler-symbols-lookup-value-id
                    symbols
                    main-expr-bool-variant-id)
                  (csym.compiler-symbol-kind-enum-variant)
                  5
                  0)
                1)))]
        [(Err _) false])]
    [(Err _) false]))

(define (compiler-symbol-map-structure-ok?) : bool
  (let
    [map : csym.CompilerSymbolMap (csym.compiler-symbol-map-with-capacity 4)]
    ;; These keys share low hash bits, exercising probing, growth, deletion,
    ;; tombstone reuse, and update without relying on compiler declarations.
    (csym.compiler-symbol-map-put! (&mut map) 0 10)
    (csym.compiler-symbol-map-put! (&mut map) 4 20)
    (csym.compiler-symbol-map-put! (&mut map) 8 30)
    (csym.compiler-symbol-map-put! (&mut map) 12 40)
    (csym.compiler-symbol-map-put! (&mut map) 4 21)
    (unless (csym.compiler-symbol-map-remove-id! (&mut map) 8) (return false))
    (csym.compiler-symbol-map-put! (&mut map) 16 50)
    (and
      (= (array-length map.keys) 8)
      (= map.len 4)
      (= map.deleted 0)
      (= (csym.compiler-symbol-map-lookup-handle-id (& map) 0) 10)
      (= (csym.compiler-symbol-map-lookup-handle-id (& map) 4) 21)
      (=
        (csym.compiler-symbol-map-lookup-handle-id (& map) 8)
        (csym.compiler-symbol-map-missing-handle))
      (= (csym.compiler-symbol-map-lookup-handle-id (& map) 12) 40)
      (= (csym.compiler-symbol-map-lookup-handle-id (& map) 16) 50)
      (not (csym.compiler-symbol-map-remove-id! (&mut map) 24)))))

(define (compiler-symbols-dotted-variant-id-paths-ok?) : bool
  (match (parser.parse-ast-source
    "(define deep : i64 a.b.Enum.Variant)
(define qualified : i64 q/a.b.Enum.Variant)")
    [(Ok program)
      (match (csym.build-compiler-symbols program)
        [(Ok symbols)
          (let
            [deep-id : i64
              (compiler-symbols-decl-value-source-id-at-index symbols 0)]
            [qualified-id : i64
              (compiler-symbols-decl-value-source-id-at-index symbols 1)]
            [deep-enum-path-id : i64 (ci.intern-dotted-prefix-id deep-id)]
            [deep-variant-id : i64 (ci.intern-dotted-final-id deep-id)]
            [deep-expected : i64
              (csym.compiler-symbol-module-key-id-by-id
                (ci.intern-dotted-prefix-id deep-enum-path-id)
                (csym.compiler-enum-qualified-variant-name-id
                  (ci.intern-dotted-final-id deep-enum-path-id)
                  deep-variant-id))]
            [qualified-base-id : i64 (ci.intern-qualified-base-id qualified-id)]
            [qualified-variant-id : i64
              (ci.intern-dotted-final-id qualified-base-id)]
            [qualified-expected : i64
              (csym.compiler-symbol-module-key-id-by-id
                (ci.intern-qualified-module-id qualified-id)
                (csym.compiler-enum-qualified-variant-name-id
                  (ci.intern-dotted-prefix-id qualified-base-id)
                  qualified-variant-id))]
            (and
              (match (csym.compiler-symbol-dotted-variant-key-id deep-id)
                [(Some key-id) (= key-id deep-expected)]
                [(None) false])
              (match (csym.compiler-symbol-dotted-variant-key-id qualified-id)
                [(Some key-id) (= key-id qualified-expected)]
                [(None) false])))]
        [(Err _) false])]
    [(Err _) false]))

(define (compiler-symbols-dotted-suffix-owner-module-id-ok?) : bool
  (let
    [source-full : i64 (ci.intern "root.branch.leaf")]
    [source-qualified-full : i64 (ci.intern "module/root.branch.leaf")]
    [source-branch-leaf : i64 (ci.intern "branch.leaf")]
    [source-leaf : i64 (ci.intern "leaf")]
    [source-modules : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind-id
        (sym_i64_env.sym-i64-bind-id (sym_i64_env.sym-i64-empty) source-leaf 12)
        source-branch-leaf
        11)]
    [source-leaf-only : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind-id (sym_i64_env.sym-i64-empty) source-leaf 12)]
    [source-full-only : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind-id (sym_i64_env.sym-i64-empty) source-full 10)]
    [generated-root : i64 (ci.intern-generated-name "root")]
    [generated-branch : i64 (ci.intern-generated-name "branch")]
    [generated-leaf : i64 (ci.intern-generated-name "leaf")]
    [generated-root-branch : i64
      (ci.intern-generated-dotted-name
        "root.branch"
        generated-root
        generated-root
        generated-branch)]
    [generated-branch-leaf : i64
      (ci.intern-generated-dotted-name
        "branch.leaf"
        generated-branch
        generated-branch
        generated-leaf)]
    [generated-full : i64
      (ci.intern-generated-dotted-name
        "root.branch.leaf"
        generated-root
        generated-root-branch
        generated-branch-leaf)]
    [generated-opaque-full : i64 (ci.intern-generated-name "root.branch.leaf")]
    [generated-modules : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind-id
        (sym_i64_env.sym-i64-bind-id
          (sym_i64_env.sym-i64-empty)
          generated-leaf
          22)
        generated-branch-leaf
        21)]
    [single : i64 (ci.intern "single")]
    [single-module : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind-id (sym_i64_env.sym-i64-empty) single 31)]
    [empty-modules : sym_i64_env.SymI64Env (sym_i64_env.sym-i64-empty)]
    (and
      (not (= source-branch-leaf generated-branch-leaf))
      (not (= source-leaf generated-leaf))
      (=
        (csym.compiler-symbols-dotted-suffix-owner-module-id
          source-modules
          source-full)
        11)
      (=
        (csym.compiler-symbols-dotted-suffix-owner-module-id
          source-leaf-only
          source-full)
        12)
      (=
        (csym.compiler-symbols-dotted-suffix-owner-module-id
          source-modules
          source-qualified-full)
        11)
      (=
        (csym.compiler-symbols-dotted-suffix-owner-module-id
          generated-modules
          generated-full)
        21)
      (=
        (csym.compiler-symbols-dotted-suffix-owner-module-id
          generated-modules
          generated-opaque-full)
        -1)
      (=
        (csym.compiler-symbols-dotted-suffix-owner-module-id
          source-modules
          generated-full)
        -1)
      (=
        (csym.compiler-symbols-dotted-suffix-owner-module-id
          generated-modules
          source-full)
        -1)
      (=
        (csym.compiler-symbols-dotted-suffix-owner-module-id
          source-full-only
          source-full)
        -1)
      (=
        (csym.compiler-symbols-dotted-suffix-owner-module-id
          single-module
          single)
        -1)
      (=
        (csym.compiler-symbols-dotted-suffix-owner-module-id
          empty-modules
          source-full)
        -1))))

(define (compiler-symbols-module-id-identity-ok?) : bool
  (let
    [generated-empty-id : i64 (ci.intern-generated-canonical-name "")]
    [generated-comptime-id : i64
      (ci.intern-generated-canonical-name "stdlib.comptime")]
    [struct-id : i64 cbi.compiler-builtin-id-fix-Point]
    [field-id : i64 cbi.compiler-builtin-id-fix-x]
    (and
      (csym.compiler-symbol-root-module-id?
        (csym.compiler-symbol-root-module-id))
      (csym.compiler-symbol-root-module-id? cbi.compiler-builtin-id-fix-empty)
      (not (csym.compiler-symbol-root-module-id? generated-empty-id))
      (csym.compiler-symbols-comptime-module-id?
        cbi.compiler-builtin-id-fix-stdlib_dot_comptime)
      (not
        (csym.compiler-symbols-comptime-module-id?
          (csym.compiler-symbol-root-module-id)))
      (not (csym.compiler-symbols-comptime-module-id? generated-comptime-id))
      (=
        (csym.compiler-struct-field-key-id-in-module-by-id
          cbi.compiler-builtin-id-fix-empty
          struct-id
          field-id)
        (csym.compiler-composite-pair-key-id struct-id field-id))
      (=
        (csym.compiler-struct-field-key-id-in-module-by-id
          generated-empty-id
          struct-id
          field-id)
        (csym.compiler-composite-triple-key-id
          generated-empty-id
          struct-id
          field-id)))))

(define (compiler-symbols-defining-provenance-survives-owner-rewrite-ok?) : bool
  (match (parser.parse-ast-source "(define chosen : i64 42)")
    [(Ok program)
      (let
        [paths : ast.AstDeclPathList (ast.ast-decl-path-list-new)]
        [modules : ast.AstDeclModuleList (ast.ast-decl-module-list-new)]
        [recorded-owner : i64 (ci.intern "dependency.source")]
        [rewritten-owner : i64 (ci.intern "consumer.visible")]
        [provenance : i64 (ci.intern "deps/example/src/lib.tl")]
        (ast.ast-decl-path-list-push-with-owner-and-provenance-id
          (&mut paths)
          "deps/example/src/lib.tl"
          recorded-owner
          provenance)
        (ast.ast-decl-module-list-push-id (&mut modules) rewritten-owner)
        (let
          [rewritten : ast.AstDeclPathList
            (ast.ast-decl-path-list-with-modules paths modules)]
          (match (csym.build-compiler-symbols-with-paths
            program
            (owned_view.compiler-owned-shared-view rewritten))
            [(Ok symbols)
              (and
                (=
                  (ast.ast-decl-path-list-owner-id (& rewritten) 0 -1)
                  rewritten-owner)
                (=
                  (csym.compiler-symbols-provenance-id-at-index-or symbols 0 -1)
                  provenance)
                (=
                  (ast.ast-decl-path-list-provenance-id (& rewritten) 0 -1)
                  provenance))]
            [(Err _) false])))]
    [(Err _) false]))

;; Registry handle bounds: members round-trip through the handle around index
;; 1000 and at the limits, distinct owners never share a handle, and a member
;; index past the limit is a registration error rather than a handle.
(define (compiler-registry-handle-roundtrip-ok?
  [owner-index : i64]
  [child-index : i64]) : bool
  (let
    [handle : i64
      (csym.compiler-registry-make-handle
        (csym.compiler-symbol-kind-struct-field)
        owner-index
        child-index)]
    (and
      (=
        (compiler-registry-handle-kind handle)
        (csym.compiler-symbol-kind-struct-field))
      (= (csym.compiler-registry-handle-owner-index handle) owner-index)
      (= (csym.compiler-registry-handle-child-index handle) child-index))))

(define (compiler-registry-handle-bounds-ok?) : bool
  (let
    [last-child : i64 (- (csym.compiler-registry-child-stride) 1)]
    [last-owner : i64 (- (csym.compiler-registry-owner-limit) 1)]
    (and
      (compiler-registry-handle-roundtrip-ok? 0 0)
      (compiler-registry-handle-roundtrip-ok? 5 999)
      (compiler-registry-handle-roundtrip-ok? 5 1000)
      (compiler-registry-handle-roundtrip-ok? 5 1001)
      (compiler-registry-handle-roundtrip-ok? 5 last-child)
      (compiler-registry-handle-roundtrip-ok? last-owner last-child)
      (not
        (=
          (csym.compiler-registry-make-handle
            (csym.compiler-symbol-kind-struct-field)
            5
            1001)
          (csym.compiler-registry-make-handle
            (csym.compiler-symbol-kind-struct-field)
            6
            1)))
      (csym.compiler-registry-indexes-encodable? last-owner last-child)
      (not
        (csym.compiler-registry-indexes-encodable?
          5
          (csym.compiler-registry-child-stride)))
      (not
        (csym.compiler-registry-indexes-encodable?
          (csym.compiler-registry-owner-limit)
          0))
      (not (csym.compiler-registry-indexes-encodable? -1 0))
      (not (csym.compiler-registry-indexes-encodable? 0 -1))
      (match (csym.compiler-registries-add-field-in-module-id
        (csym.compiler-registries-empty)
        cbi.compiler-builtin-id-fix-empty
        (ci.intern "Wide")
        (ci.intern "tail")
        5
        (csym.compiler-registry-child-stride))
        [(Err message)
          (string.eq
            message
            (str_cat.str-cat
              "symbols: struct Wide has more than "
              (string.int->string (csym.compiler-registry-child-stride))
              " fields; a struct or enum declares at most "
              (string.int->string (csym.compiler-registry-child-stride))
              " members"))]
        [(Ok _) false])
      (match (csym.compiler-registries-add-field-in-module-id
        (csym.compiler-registries-empty)
        cbi.compiler-builtin-id-fix-empty
        (ci.intern "Wide")
        (ci.intern "f0")
        (csym.compiler-registry-owner-limit)
        0)
        [(Err message)
          (string.eq
            message
            (str_cat.str-cat
              "symbols: struct Wide is beyond the "
              (string.int->string (csym.compiler-registry-owner-limit))
              "-declaration limit for structs and enums"))]
        [(Ok _) false])
      (match (csym.compiler-registries-add-variant-in-module-id
        (csym.compiler-registries-empty)
        cbi.compiler-builtin-id-fix-empty
        (ci.intern "Big")
        (ci.intern "Last")
        5
        (csym.compiler-registry-child-stride))
        [(Err message)
          (string.eq message (compiler-registry-variant-limit-message-for-test))]
        [(Ok _) false])
      (match (csym.compiler-symbols-add-variant-value-in-module-id
        (csym.compiler-symbols-empty)
        cbi.compiler-builtin-id-fix-empty
        (ci.intern "Big")
        (ci.intern "Last")
        5
        (csym.compiler-registry-child-stride))
        [(Err message)
          (string.eq message (compiler-registry-variant-limit-message-for-test))]
        [(Ok _) false]))))

(define (compiler-registry-variant-limit-message-for-test) : String
  (str_cat.str-cat
    "symbols: enum Big has more than "
    (string.int->string (csym.compiler-registry-child-stride))
    " variants; a struct or enum declares at most "
    (string.int->string (csym.compiler-registry-child-stride))
    " members"))

(define (compiler-symbols-self-test) : i64
  (cbi.compiler-builtin-refresh!)
  (match (parser.parse-ast-source
    "(import stdlib.test)
(defstruct Point (x i64) (y i64))
(defenum Maybe (None) (Some i64))
(extern (io.emit-string [arg0 : String]) : unit)
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
    [(Ok program)
      (match (csym.build-compiler-symbols program)
        [(Ok symbols)
          (match (csym.build-compiler-registries program)
            [(Ok registries)
              (let
                [ok : bool true]
                (set!
                  ok
                  (and
                    ok
                    (= (compiler-symbols-smoke-score symbols) 10)
                    (= (compiler-registries-smoke-score symbols registries) 8)
                    (compiler-registry-handle-bounds-ok?)
                    (compiler-symbols-duplicate-value-ok?)
                    (compiler-symbols-duplicate-type-ok?)
                    (compiler-symbols-module-duplicate-diagnostics-ok?)
                    (compiler-symbols-module-duplicate-with-paths-ok?)
                    (compiler-symbols-variant-value-collisions-ok?)
                    (compiler-symbols-root-shadows-imported-variant-ok?)
                    (compiler-symbols-struct-value-collisions-ok?)
                    (compiler-registries-duplicate-variant-ok?)
                    (compiler-registries-cross-enum-variant-ok?)
                    (compiler-registries-duplicate-field-ok?)
                    (compiler-registry-large-owner-handle-ok?)
                    (compiler-registry-shift-map-full-ok?)
                    (compiler-registries-incremental-splice-ok?)
                    (compiler-registries-lifetime-field-indexed-ok?)
                    (compiler-symbols-append-splice-ok?)
                    (compiler-symbols-append-external-macro-alias-ok?)
                    (compiler-symbols-nominal-decl-ok?)
                    (compiler-symbols-module-scope-ok?)
                    (compiler-symbols-owner-compare-ok?)
                    (compiler-symbols-structural-id-api-ok?)
                    (compiler-symbols-decl-span-view-ok?)
                    (compiler-symbol-map-fast-path-ok?)
                    (compiler-symbols-direct-qualified-add-ok?)
                    (compiler-symbols-import-alias-ok?)
                    (compiler-symbols-comptime-root-helper-alias-ok?)
                    (compiler-symbols-macro-namespace-ok?)
                    (compiler-symbols-duplicate-macro-ok?)
                    (compiler-symbols-value-macro-namespace-ok?)
                    (compiler-symbol-map-structure-ok?)
                    (compiler-symbols-dotted-variant-id-paths-ok?)
                    (compiler-symbols-dotted-suffix-owner-module-id-ok?)
                    (compiler-symbols-module-id-identity-ok?)
                    (compiler-symbols-defining-provenance-survives-owner-rewrite-ok?)))
                (if ok
                  42
                  (io.panic "symbols: smoke score mismatch")))]
            [(Err message) (io.panic message)])]
        [(Err message) (io.panic message)])]
    [(Err message) (io.panic message)]))