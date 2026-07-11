;; compiler_ctfe.tl - Selfhost compile-time function evaluation (CTFE) for
;; expression-position `(comptime expr)`.
;;
;; Ports the scalar slice of the Rust reference `src/ctfe.rs`. Supported
;; compile-time value types are i64, f64/f32, bool, char, unit, type values, and
;; Expr / list aggregates.
;;
;; Evaluation is purely functional: the environment is an immutable cons list
;; threaded through recursion, and the step budget ("fuel") is threaded through
;; results so the evaluator stays deterministic without a mutable counter.
(cfg (any test selfhost-compile-manifest) (import stdlib.hashmap))
(import (hashmap String i64) as ctfe_key_map)
(import stdlib.array)
(import "compiler_ast_types.tl")
(import "compiler_diagnostic.tl")
(import "compiler_float.tl")
(import stdlib.string)
(import stdlib.result)

;; Reset-aware intern ids for fixed CTFE dispatch names. Dispatch compares
;; intern ids; reset hooks force the fixed names back through the current
;; compile's intern table instead of relying on process lifetime alone.
(define ctfe-builtin-generation : i64
  -1)
(define ctfe-builtin-ready : bool
  false)
(define ctfe-builtin-ids : (Array i64)
  (array.make-array i64 101))

(define (ctfe-builtin-reset!) : unit
  (begin
    (set! ctfe-builtin-ready false)
    (set! ctfe-builtin-generation -1)))

(define (ctfe-builtin-set! [index : i64] [name : String]) : unit
  (array-set! ctfe-builtin-ids index (intern name)))

(define (ctfe-builtin-refresh!) : unit
  (if (and ctfe-builtin-ready (= ctfe-builtin-generation (intern-generation)))
    unit
    (begin
      (ctfe-builtin-set! 0 "size-of")
      (ctfe-builtin-set! 1 "align-of")
      (ctfe-builtin-set! 2 "offset-of")
      (ctfe-builtin-set! 3 "__tl_string_eq")
      (ctfe-builtin-set! 4 "string-eq")
      (ctfe-builtin-set! 5 "string=?")
      (ctfe-builtin-set! 6 "__tl_string_length")
      (ctfe-builtin-set! 7 "string-length")
      (ctfe-builtin-set! 8 "length")
      (ctfe-builtin-set! 9 "__tl_string_ref")
      (ctfe-builtin-set! 10 "string-ref")
      (ctfe-builtin-set! 11 "char-at")
      (ctfe-builtin-set! 12 "__tl_string_to_int")
      (ctfe-builtin-set! 13 "string->int")
      (ctfe-builtin-set! 14 "string-append")
      (ctfe-builtin-set! 15 "string-concat")
      (ctfe-builtin-set! 16 "int->string")
      (ctfe-builtin-set! 17 "comptime-error")
      (ctfe-builtin-set! 18 "error")
      (ctfe-builtin-set! 19 "expr-bool?")
      (ctfe-builtin-set! 20 "expr-bool-value")
      (ctfe-builtin-set! 21 "expr-if?")
      (ctfe-builtin-set! 22 "expr-if-cond")
      (ctfe-builtin-set! 23 "expr-if-then")
      (ctfe-builtin-set! 24 "expr-if-else")
      (ctfe-builtin-set! 25 "expr-clause-first")
      (ctfe-builtin-set! 26 "expr-clause-second")
      (ctfe-builtin-set! 27 "expr-bool")
      (ctfe-builtin-set! 28 "expr-int")
      (ctfe-builtin-set! 29 "expr-string")
      (ctfe-builtin-set! 30 "expr-var")
      (ctfe-builtin-set! 31 "expr-struct-get")
      (ctfe-builtin-set! 32 "expr-tuple-ref")
      (ctfe-builtin-set! 33 "expr-struct-set")
      (ctfe-builtin-set! 34 "expr-splice")
      (ctfe-builtin-set! 35 "expr-if")
      (ctfe-builtin-set! 36 "pattern-wildcard")
      (ctfe-builtin-set! 37 "pattern-binding")
      (ctfe-builtin-set! 38 "pattern-variant")
      (ctfe-builtin-set! 39 "pattern-list-empty")
      (ctfe-builtin-set! 40 "pattern-list-cons")
      (ctfe-builtin-set! 41 "match-arm")
      (ctfe-builtin-set! 42 "match-arm-list-empty")
      (ctfe-builtin-set! 43 "match-arm-list-cons")
      (ctfe-builtin-set! 44 "expr-match")
      (ctfe-builtin-set! 45 "expr-type")
      (ctfe-builtin-set! 46 "type-info")
      (ctfe-builtin-set! 47 "module-name")
      (ctfe-builtin-set! 48 "module-export-macro?")
      (ctfe-builtin-set! 49 "module-hook")
      (ctfe-builtin-set! 50 "expr-list-empty?")
      (ctfe-builtin-set! 51 "expr-list-length")
      (ctfe-builtin-set! 52 "expr-list-head")
      (ctfe-builtin-set! 53 "expr-list-tail")
      (ctfe-builtin-set! 54 "expr-list-nth")
      (ctfe-builtin-set! 55 "expr-clause-list-empty?")
      (ctfe-builtin-set! 56 "expr-clause-list-length")
      (ctfe-builtin-set! 57 "expr-clause-list-head")
      (ctfe-builtin-set! 58 "expr-clause-list-tail")
      (ctfe-builtin-set! 59 "expr-clause-list-nth")
      (ctfe-builtin-set! 60 "expr-clause-list->expr-list")
      (ctfe-builtin-set! 61 "expr-binding-clause-name")
      (ctfe-builtin-set! 62 "expr-binding-clause-has-type?")
      (ctfe-builtin-set! 63 "expr-binding-clause-type")
      (ctfe-builtin-set! 64 "expr-binding-clause-init")
      (ctfe-builtin-set! 65 "expr-binding-clause-list-empty?")
      (ctfe-builtin-set! 66 "expr-binding-clause-list-length")
      (ctfe-builtin-set! 67 "expr-binding-clause-list-head")
      (ctfe-builtin-set! 68 "expr-binding-clause-list-tail")
      (ctfe-builtin-set! 69 "expr-binding-clause-list-nth")
      (ctfe-builtin-set! 70 "expr-binding-clause-list->expr-list")
      (ctfe-builtin-set! 71 "type-kind")
      (ctfe-builtin-set! 72 "type-key")
      (ctfe-builtin-set! 73 "type-nominal-module")
      (ctfe-builtin-set! 74 "type-nominal-name")
      (ctfe-builtin-set! 75 "struct-field-count")
      (ctfe-builtin-set! 76 "struct-field-name")
      (ctfe-builtin-set! 77 "struct-field-type")
      (ctfe-builtin-set! 78 "enum-variant-count")
      (ctfe-builtin-set! 79 "enum-variant-name")
      (ctfe-builtin-set! 80 "enum-variant-payload-count")
      (ctfe-builtin-set! 81 "enum-variant-payload-type")
      (ctfe-builtin-set! 82 "array-element-type")
      (ctfe-builtin-set! 83 "array-length")
      (ctfe-builtin-set! 84 "array-dynamic?")
      (ctfe-builtin-set! 85 "tuple-element-count")
      (ctfe-builtin-set! 86 "tuple-element-type")
      (ctfe-builtin-set! 87 "function-param-count")
      (ctfe-builtin-set! 88 "function-param-type")
      (ctfe-builtin-set! 89 "function-return-type")
      (ctfe-builtin-set! 90 "pattern-list-bindings")
      (ctfe-builtin-set! 91 "expr-string?")
      (ctfe-builtin-set! 92 "expr-string-value")
      (ctfe-builtin-set! 93 "string-slice")
      (ctfe-builtin-set! 94 "expr-mut-borrow")
      (ctfe-builtin-set! 95 "expr-call")
      (ctfe-builtin-set! 96 "expr-list-empty")
      (ctfe-builtin-set! 97 "expr-list-cons")
      (ctfe-builtin-set! 98 "expr-mut-call0")
      (ctfe-builtin-set! 99 "expr-mut-call1")
      (ctfe-builtin-set! 100 "expr-mut-call2")
      (set! ctfe-builtin-generation (intern-generation))
      (set! ctfe-builtin-ready true))))

(defmacro (ctfe-builtin-ref [index : i64]) : i64
  `(__tl_array-ref ctfe-builtin-ids ,index))

(define (ctfe-builtin-id-any2? [name-id : i64] [a : i64] [b : i64]) : bool
  (or (= name-id a) (= name-id b)))

(define (ctfe-builtin-id-any3? [name-id : i64] [a : i64] [b : i64] [c : i64]) : bool
  (or (= name-id a) (ctfe-builtin-id-any2? name-id b c)))

(define (ctfe-builtin-id-any4?
  [name-id : i64]
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]) : bool
  (or (= name-id a) (ctfe-builtin-id-any3? name-id b c d)))

(define (ctfe-builtin-size-align-id? [name-id : i64]) : bool
  (begin
    (ctfe-builtin-refresh!)
    (ctfe-builtin-id-any2? name-id (ctfe-builtin-ref 0) (ctfe-builtin-ref 1))))

(define (ctfe-builtin-offset-of-id? [name-id : i64]) : bool
  (begin
    (ctfe-builtin-refresh!)
    (= name-id (ctfe-builtin-ref 2))))

(define (ctfe-builtin-string-eq-id? [name-id : i64]) : bool
  (begin
    (ctfe-builtin-refresh!)
    (ctfe-builtin-id-any3?
      name-id
      (ctfe-builtin-ref 3)
      (ctfe-builtin-ref 4)
      (ctfe-builtin-ref 5))))

(define (ctfe-builtin-string-length-id? [name-id : i64]) : bool
  (begin
    (ctfe-builtin-refresh!)
    (ctfe-builtin-id-any3?
      name-id
      (ctfe-builtin-ref 6)
      (ctfe-builtin-ref 7)
      (ctfe-builtin-ref 8))))

(define (ctfe-builtin-string-ref-id? [name-id : i64]) : bool
  (begin
    (ctfe-builtin-refresh!)
    (ctfe-builtin-id-any3?
      name-id
      (ctfe-builtin-ref 9)
      (ctfe-builtin-ref 10)
      (ctfe-builtin-ref 11))))

(define (ctfe-builtin-string-to-int-id? [name-id : i64]) : bool
  (begin
    (ctfe-builtin-refresh!)
    (ctfe-builtin-id-any2? name-id (ctfe-builtin-ref 12) (ctfe-builtin-ref 13))))

(define (ctfe-builtin-string-build-id? [name-id : i64]) : bool
  (begin
    (ctfe-builtin-refresh!)
    (ctfe-builtin-id-any2? name-id (ctfe-builtin-ref 14) (ctfe-builtin-ref 15))))

(define (ctfe-builtin-int-to-string-id? [name-id : i64]) : bool
  (begin
    (ctfe-builtin-refresh!)
    (= name-id (ctfe-builtin-ref 16))))

(define (ctfe-builtin-comptime-error-id? [name-id : i64]) : bool
  (begin
    (ctfe-builtin-refresh!)
    (= name-id (ctfe-builtin-ref 17))))

(define (ctfe-builtin-error-id? [name-id : i64]) : bool
  (begin
    (ctfe-builtin-refresh!)
    (= name-id (ctfe-builtin-ref 18))))

(define (ctfe-builtin-reflection-primary-id? [name-id : i64]) : bool
  (begin
    (ctfe-builtin-refresh!)
    (or
      (ctfe-builtin-id-any4?
        name-id
        (ctfe-builtin-ref 46)
        (ctfe-builtin-ref 71)
        (ctfe-builtin-ref 72)
        (ctfe-builtin-ref 73))
      (ctfe-builtin-id-any4?
        name-id
        (ctfe-builtin-ref 74)
        (ctfe-builtin-ref 75)
        (ctfe-builtin-ref 78)
        (ctfe-builtin-ref 82))
      (ctfe-builtin-id-any4?
        name-id
        (ctfe-builtin-ref 83)
        (ctfe-builtin-ref 84)
        (ctfe-builtin-ref 85)
        (ctfe-builtin-ref 87))
      (= name-id (ctfe-builtin-ref 89)))))

(define (ctfe-builtin-reflection-secondary-id? [name-id : i64]) : bool
  (begin
    (ctfe-builtin-refresh!)
    (or
      (ctfe-builtin-id-any4?
        name-id
        (ctfe-builtin-ref 76)
        (ctfe-builtin-ref 77)
        (ctfe-builtin-ref 79)
        (ctfe-builtin-ref 80))
      (ctfe-builtin-id-any3?
        name-id
        (ctfe-builtin-ref 81)
        (ctfe-builtin-ref 86)
        (ctfe-builtin-ref 88)))))

(define (ctfe-builtin-reflection-id? [name-id : i64]) : bool
  (or
    (ctfe-builtin-reflection-primary-id? name-id)
    (ctfe-builtin-reflection-secondary-id? name-id)))

(define (ctfe-builtin-source-helper-id? [name-id : i64]) : bool
  (begin
    (ctfe-builtin-refresh!)
    (or
      (ctfe-builtin-id-any4?
        name-id
        (ctfe-builtin-ref 19)
        (ctfe-builtin-ref 20)
        (ctfe-builtin-ref 21)
        (ctfe-builtin-ref 22))
      (ctfe-builtin-id-any4?
        name-id
        (ctfe-builtin-ref 23)
        (ctfe-builtin-ref 24)
        (ctfe-builtin-ref 25)
        (ctfe-builtin-ref 26))
      (ctfe-builtin-id-any4?
        name-id
        (ctfe-builtin-ref 51)
        (ctfe-builtin-ref 54)
        (ctfe-builtin-ref 56)
        (ctfe-builtin-ref 59))
      (ctfe-builtin-id-any4?
        name-id
        (ctfe-builtin-ref 61)
        (ctfe-builtin-ref 62)
        (ctfe-builtin-ref 63)
        (ctfe-builtin-ref 64))
      (ctfe-builtin-id-any2?
        name-id
        (ctfe-builtin-ref 66)
        (ctfe-builtin-ref 69)))))

(define (ctfe-builtin-sequence-length-id? [name-id : i64]) : bool
  (begin
    (ctfe-builtin-refresh!)
    (ctfe-builtin-id-any3?
      name-id
      (ctfe-builtin-ref 51)
      (ctfe-builtin-ref 56)
      (ctfe-builtin-ref 66))))

(define (ctfe-builtin-sequence-nth-id? [name-id : i64]) : bool
  (begin
    (ctfe-builtin-refresh!)
    (ctfe-builtin-id-any3?
      name-id
      (ctfe-builtin-ref 54)
      (ctfe-builtin-ref 59)
      (ctfe-builtin-ref 69))))

(define (ctfe-builtin-expr-clause-list-inspector-id? [name-id : i64]) : bool
  (begin
    (ctfe-builtin-refresh!)
    (= name-id (ctfe-builtin-ref 60))))

(define (ctfe-builtin-expr-binding-clause-list-inspector-id? [name-id : i64]) : bool
  (begin
    (ctfe-builtin-refresh!)
    (= name-id (ctfe-builtin-ref 70))))

(defmacro (ctfe-private-string-length [text : Expr]) : i64
  (cfg
    feature-compiler-private-string-intrinsics
    `(__tl_string_length ,text)
    `(string.string-length ,text)))

(defmacro (ctfe-private-string-ref [text : Expr] [index : Expr]) : char
  (cfg
    feature-compiler-private-string-intrinsics
    `(__tl_string_ref ,text ,index)
    `(string.string-ref ,text ,index)))

;; A compile-time value. Scalars; Expr / ExprList aggregates
;; for macro transformers; TypeInfo pseudo-values back the
;; stdlib-owned reflection surface.
(defenum CompilerCtfeValue
  (I64 i64)
  (F64 f64)
  (F32 f64)
  (Bool bool)
  (Char char)
  (String String)
  (Unit)
  (Type AstType)
  ;; A user-facing `Expr` code fragment plus its internally checked produced
  ;; type. The type is not part of the source-level Expr type.
  (Expr i64 AstType)
  (ExprList AstExprList)
  (ExprClause AstExprClause)
  (ExprClauseList AstExprClauseList)
  (ExprBindingClause AstExprBindingClause)
  (ExprBindingClauseList AstExprBindingClauseList)
  (Pattern AstPattern)
  (PatternList AstPatternList)
  (MatchArm AstMatchArm)
  (MatchArmList AstMatchArmList)
  (TypeInfo AstType)
  (TypeInfoBox AstType)
  (TypeInfoList AstTypeList)
  (TypeField String AstType)
  (TypeFieldList CtfeReflectFieldList)
  (TypeVariantPayload AstType)
  (TypeVariantPayloadList AstTypeList)
  (TypeVariant String AstTypeList)
  (TypeVariantList CtfeReflectVariantList))

(define (ctfe-untyped-expr-type-name) : String
  "__typelisp_untyped_expr")

(define (ctfe-untyped-expr-type) : AstType
  (AstType.Var (intern (ctfe-untyped-expr-type-name))))

(define (ctfe-untyped-expr-type? [ty : AstType]) : bool
  (match ty
    [(AstType.Var name)
      (string.eq (intern-str name) (ctfe-untyped-expr-type-name))]
    [_ false]))

(define (ctfe-captured-expr-type-name) : String
  "__typelisp_captured_expr")

(define (ctfe-captured-expr-type-with-pools
  [pools : AstNodePoolContext]
  [ty : AstType]) : AstType
  (AstType.Region
    (ctfe-captured-expr-type-name)
    (ast-node-pool-context-type-push pools ty)))

(define (ctfe-captured-expr-type [ty : AstType]) : AstType
  (ctfe-captured-expr-type-with-pools (ast-node-pool-context-capture-active) ty))

(define (ctfe-captured-expr-type? [ty : AstType]) : bool
  (match ty
    [(AstType.Region name _) (string.eq name (ctfe-captured-expr-type-name))]
    [_ false]))

(define (ctfe-captured-expr-type-inner-with-pools
  [pools : AstNodePoolContext]
  [ty : AstType]) : AstType
  (match ty
    [(AstType.Region name inner)
      (if (string.eq name (ctfe-captured-expr-type-name))
        (ast-node-pool-context-type-get pools inner)
        ty)]
    [_ ty]))

(define (ctfe-captured-expr-type-inner [ty : AstType]) : AstType
  (ctfe-captured-expr-type-inner-with-pools
    (ast-node-pool-context-capture-active)
    ty))

(define (ctfe-stdlib-comptime-type-key [name : String]) : String
  (string.append "stdlib.comptime/" name))

(define (ctfe-stdlib-comptime-type [name : String]) : AstType
  (AstType.Var (intern (ctfe-stdlib-comptime-type-key name))))

(define (ctfe-type-info-source-type) : AstType
  (ctfe-stdlib-comptime-type "TypeInfo"))

(define (ctfe-type-info-box-source-type) : AstType
  (ast-ty-box (ctfe-type-info-source-type)))

(defenum CtfeValueList
  (Nil)
  (Cons CompilerCtfeValue (Box CtfeValueList)))

;; CTFE-owned type layout metadata. The typechecker/lowerer build this from
;; their `TcContext` without making CTFE import typecheck.
;;
;; Storage disposition:
;; - CtfeLayoutFieldList, CtfeLayoutInfoList, CtfeReflectFieldList,
;;   CtfeReflectVariantList, and CtfeReflectInfoList are vector-backed
;;   generated-collection families. The historical `List` names are retained so
;;   callers do not need a public naming churn while the representation changes.
;; - CtfeEnv remains a persistent cons chain because lexical shadowing and cheap
;;   push/pop are its primary operations.
;; - AST-owned lists such as AstExprList, AstTypeList, and AstParamList remain
;;   frontend data structures and are tracked separately.
(defenum CtfeLayoutField
  (Field String i64))

(defstruct CtfeLayoutFieldList
  (slots (Array CtfeLayoutField))
  (len i64))

(defenum CtfeLayoutInfo
  (Info String bool i64 i64 CtfeLayoutFieldList))

(defstruct CtfeLayoutInfoList
  (slots (Array CtfeLayoutInfo))
  (len i64))

(defenum CtfeMaybeLayoutInfo
  (None)
  (Some CtfeLayoutInfo))

(defenum CtfeMaybeFieldName
  (None)
  (Some String))

;; CTFE-owned type reflection metadata. Typecheck and specialization build this
;; from `AstProgram` and pass it into CTFE without making CTFE import either pass.
(defenum CtfeReflectField
  (Field String AstType))

(defstruct CtfeReflectFieldList
  (slots (Array CtfeReflectField))
  (len i64))

(defenum CtfeReflectVariant
  (Variant String AstTypeList))

(defstruct CtfeReflectVariantList
  (slots (Array CtfeReflectVariant))
  (len i64))

(defenum CtfeReflectInfo
  (Struct String String String CtfeReflectFieldList)
  (Enum String String String CtfeReflectVariantList))

(defstruct CtfeReflectInfoList
  (slots (Array CtfeReflectInfo))
  (len i64))

(defenum CtfeMaybeReflectInfo
  (None)
  (Some CtfeReflectInfo))

;; Immutable name -> value environment plus immutable type metadata tables. Newest
;; value binding sits at the front so lookup finds the most recent shadowing
;; binding first; metadata lives at the root and is shared by extensions.
(defenum CtfeEnv
  (Nil AstNodePoolContext CtfeLayoutInfoList CtfeReflectInfoList)
  (Cons String CompilerCtfeValue AstType (Box CtfeEnv)))

(define (ctfe-env-empty-with-pools [pools : AstNodePoolContext]) : CtfeEnv
  (CtfeEnv.Nil
    pools
    (ctfe-layout-info-list-empty)
    (ctfe-reflect-info-list-empty)))

(define (ctfe-env-empty) : CtfeEnv
  (ctfe-env-empty-with-pools (ast-node-pool-context-capture-active)))

(define (ctfe-env-with-layouts-and-pools
  [layouts : CtfeLayoutInfoList]
  [pools : AstNodePoolContext]) : CtfeEnv
  (CtfeEnv.Nil pools layouts (ctfe-reflect-info-list-empty)))

(define (ctfe-env-with-layouts [layouts : CtfeLayoutInfoList]) : CtfeEnv
  (ctfe-env-with-layouts-and-pools
    layouts
    (ast-node-pool-context-capture-active)))

(define (ctfe-env-with-reflections-and-pools
  [reflections : CtfeReflectInfoList]
  [pools : AstNodePoolContext]) : CtfeEnv
  (CtfeEnv.Nil pools (ctfe-layout-info-list-empty) reflections))

(define (ctfe-env-with-reflections [reflections : CtfeReflectInfoList]) : CtfeEnv
  (ctfe-env-with-reflections-and-pools
    reflections
    (ast-node-pool-context-capture-active)))

(define (ctfe-env-with-metadata-and-pools
  [layouts : CtfeLayoutInfoList]
  [reflections : CtfeReflectInfoList]
  [pools : AstNodePoolContext]) : CtfeEnv
  (CtfeEnv.Nil pools layouts reflections))

(define (ctfe-env-with-metadata
  [layouts : CtfeLayoutInfoList]
  [reflections : CtfeReflectInfoList]) : CtfeEnv
  (ctfe-env-with-metadata-and-pools
    layouts
    reflections
    (ast-node-pool-context-capture-active)))

(define (ctfe-env-extend
  [env : CtfeEnv]
  [name : String]
  [value : CompilerCtfeValue]) : CtfeEnv
  (CtfeEnv.Cons name value (ctfe-value-default-cast-type value) (box env)))

(define (ctfe-env-extend-typed
  [env : CtfeEnv]
  [name : String]
  [value : CompilerCtfeValue]
  [ty : AstType]) : CtfeEnv
  (CtfeEnv.Cons name value ty (box env)))

(define (ctfe-layout-field-list-with-capacity [capacity : i64]) : CtfeLayoutFieldList
  (CtfeLayoutFieldList (array.make-array CtfeLayoutField capacity) 0))

(define (ctfe-layout-field-list-empty) : CtfeLayoutFieldList
  (ctfe-layout-field-list-with-capacity 0))

(define (ctfe-layout-field-list-ref [items : CtfeLayoutFieldList] [index : i64]) : CtfeLayoutField
  (array.ref (struct-get items slots) index))

(define (ctfe-layout-field-list-push
  [items : CtfeLayoutFieldList]
  [value : CtfeLayoutField]) : CtfeLayoutFieldList
  (let
    [n : i64 (struct-get items len)]
    [slots : (Array CtfeLayoutField) (struct-get items slots)]
    (begin
      (array-set! slots n value)
      (CtfeLayoutFieldList slots (+ n 1)))))

(define (ctfe-layout-info-list-with-capacity [capacity : i64]) : CtfeLayoutInfoList
  (CtfeLayoutInfoList (array.make-array CtfeLayoutInfo capacity) 0))

(define (ctfe-layout-info-list-empty) : CtfeLayoutInfoList
  (ctfe-layout-info-list-with-capacity 0))

(define (ctfe-layout-info-list-ref [items : CtfeLayoutInfoList] [index : i64]) : CtfeLayoutInfo
  (array.ref (struct-get items slots) index))

(define (ctfe-layout-info-list-push
  [items : CtfeLayoutInfoList]
  [value : CtfeLayoutInfo]) : CtfeLayoutInfoList
  (let
    [n : i64 (struct-get items len)]
    [slots : (Array CtfeLayoutInfo) (struct-get items slots)]
    (begin
      (array-set! slots n value)
      (CtfeLayoutInfoList slots (+ n 1)))))

(define (ctfe-reflect-field-list-with-capacity [capacity : i64]) : CtfeReflectFieldList
  (CtfeReflectFieldList (array.make-array CtfeReflectField capacity) 0))

(define (ctfe-reflect-field-list-empty) : CtfeReflectFieldList
  (ctfe-reflect-field-list-with-capacity 0))

(define (ctfe-reflect-field-list-ref
  [items : CtfeReflectFieldList]
  [index : i64]) : CtfeReflectField
  (array.ref (struct-get items slots) index))

(define (ctfe-reflect-field-list-push
  [items : CtfeReflectFieldList]
  [value : CtfeReflectField]) : CtfeReflectFieldList
  (let
    [n : i64 (struct-get items len)]
    [slots : (Array CtfeReflectField) (struct-get items slots)]
    (begin
      (array-set! slots n value)
      (CtfeReflectFieldList slots (+ n 1)))))

(define (ctfe-reflect-variant-list-with-capacity [capacity : i64]) : CtfeReflectVariantList
  (CtfeReflectVariantList (array.make-array CtfeReflectVariant capacity) 0))

(define (ctfe-reflect-variant-list-empty) : CtfeReflectVariantList
  (ctfe-reflect-variant-list-with-capacity 0))

(define (ctfe-reflect-variant-list-ref
  [items : CtfeReflectVariantList]
  [index : i64]) : CtfeReflectVariant
  (array.ref (struct-get items slots) index))

(define (ctfe-reflect-variant-list-push
  [items : CtfeReflectVariantList]
  [value : CtfeReflectVariant]) : CtfeReflectVariantList
  (let
    [n : i64 (struct-get items len)]
    [slots : (Array CtfeReflectVariant) (struct-get items slots)]
    (begin
      (array-set! slots n value)
      (CtfeReflectVariantList slots (+ n 1)))))

(define (ctfe-reflect-info-list-with-capacity [capacity : i64]) : CtfeReflectInfoList
  (CtfeReflectInfoList (array.make-array CtfeReflectInfo capacity) 0))

(define (ctfe-reflect-info-list-empty) : CtfeReflectInfoList
  (ctfe-reflect-info-list-with-capacity 0))

(define (ctfe-reflect-info-list-ref [items : CtfeReflectInfoList] [index : i64]) : CtfeReflectInfo
  (array.ref (struct-get items slots) index))

(define (ctfe-reflect-info-list-push
  [items : CtfeReflectInfoList]
  [value : CtfeReflectInfo]) : CtfeReflectInfoList
  (let
    [n : i64 (struct-get items len)]
    [slots : (Array CtfeReflectInfo) (struct-get items slots)]
    (begin
      (array-set! slots n value)
      (CtfeReflectInfoList slots (+ n 1)))))

(define (ctfe-layout-info-name [info : CtfeLayoutInfo]) : String
  (match info
    [(CtfeLayoutInfo.Info name _ _ _ _) name]))

;; Per-build dedup set of keys already added to the metadata list. The reflection
;; and layout builds each register every type under its key (and module alias);
;; checking membership against the old linked list was O(types^2). This hashset
;; keeps each `add-if-missing` O(1), so the whole build is O(types). Reset at the
;; start of each build (layouts then reflections run sequentially in tc-ctfe-env).
(define ctfe-build-seen-keys : (Box ctfe_key_map.Map)
  (box (ctfe_key_map.with-capacity 1)))

(define (ctfe-build-seen-reset!) : unit
  (set! (box-get ctfe-build-seen-keys) (ctfe_key_map.with-capacity 256)))

(define (ctfe-build-seen-add? [key : String]) : bool
  (ctfe_key_map.insert-if-absent? (&mut (box-get ctfe-build-seen-keys)) key 1))

(define (ctfe-layout-info-list-add-if-missing
  [layouts : CtfeLayoutInfoList]
  [info : CtfeLayoutInfo]) : CtfeLayoutInfoList
  (if (ctfe-build-seen-add? (ctfe-layout-info-name info))
    (ctfe-layout-info-list-push layouts info)
    layouts))

(define (ctfe-layout-info-lookup-from
  [layouts : CtfeLayoutInfoList]
  [name : String]
  [index : i64]) : CtfeMaybeLayoutInfo
  (if (< index 0)
    (CtfeMaybeLayoutInfo.None)
    (let
      [info : CtfeLayoutInfo (ctfe-layout-info-list-ref layouts index)]
      (if (string.eq (ctfe-layout-info-name info) name)
        (CtfeMaybeLayoutInfo.Some info)
        (ctfe-layout-info-lookup-from layouts name (- index 1))))))

(define (ctfe-layout-info-lookup [layouts : CtfeLayoutInfoList] [name : String]) : CtfeMaybeLayoutInfo
  (ctfe-layout-info-lookup-from layouts name (- (struct-get layouts len) 1)))

(define (ctfe-layout-field-offset-from
  [fields : CtfeLayoutFieldList]
  [name : String]
  [index : i64]) : i64
  (if (>= index (struct-get fields len))
    -1
    (let
      [field : CtfeLayoutField (ctfe-layout-field-list-ref fields index)]
      (match field
        [(CtfeLayoutField.Field field-name offset)
          (if (string.eq field-name name)
            offset
            (ctfe-layout-field-offset-from fields name (+ index 1)))]))))

(define (ctfe-layout-field-offset
  [fields : CtfeLayoutFieldList]
  [name : String]) : i64
  (ctfe-layout-field-offset-from fields name 0))

(define (ctfe-env-layouts [env : CtfeEnv]) : CtfeLayoutInfoList
  (match env
    [(CtfeEnv.Nil _ layouts _) layouts]
    [(CtfeEnv.Cons _ _ _ rest) (ctfe-env-layouts (box-get rest))]))

(define (ctfe-env-reflections [env : CtfeEnv]) : CtfeReflectInfoList
  (match env
    [(CtfeEnv.Nil _ _ reflections) reflections]
    [(CtfeEnv.Cons _ _ _ rest) (ctfe-env-reflections (box-get rest))]))

(define (ctfe-env-pools [env : CtfeEnv]) : AstNodePoolContext
  (match env
    [(CtfeEnv.Nil pools _ _) pools]
    [(CtfeEnv.Cons _ _ _ rest) (ctfe-env-pools (box-get rest))]))

(define (ctfe-env-rebase-pools [env : CtfeEnv] [pools : AstNodePoolContext]) : CtfeEnv
  (match env
    [(CtfeEnv.Nil _ layouts reflections)
      (CtfeEnv.Nil pools layouts reflections)]
    [(CtfeEnv.Cons key value ty rest)
      (CtfeEnv.Cons
        key
        value
        ty
        (box (ctfe-env-rebase-pools (box-get rest) pools)))]))

(define (ctfe-ast-get [env : CtfeEnv] [id : i64]) : AstExpr
  (ast-node-pool-context-expr-get (ctfe-env-pools env) id))

(define (ctfe-ast-push [env : CtfeEnv] [node : AstExpr]) : i64
  (ast-node-pool-context-expr-push (ctfe-env-pools env) node))

(define (ctfe-expr-unspan [env : CtfeEnv] [expr : AstExpr]) : AstExpr
  (match expr
    [(AstExpr.Spanned inner-id _)
      (ctfe-expr-unspan env (ctfe-ast-get env inner-id))]
    [_ expr]))

(define (ctfe-ty-get [env : CtfeEnv] [id : i64]) : AstType
  (ast-node-pool-context-type-get (ctfe-env-pools env) id))

(define (ctfe-ty-push [env : CtfeEnv] [node : AstType]) : i64
  (ast-node-pool-context-type-push (ctfe-env-pools env) node))

;; Lookup result for an environment probe.
(defenum CtfeMaybeValue
  (None)
  (Some CompilerCtfeValue))

(define (ctfe-env-lookup [env : CtfeEnv] [name : String]) : CtfeMaybeValue
  (match env
    [(CtfeEnv.Nil _ _ _) (CtfeMaybeValue.None)]
    [(CtfeEnv.Cons key value _ rest)
      (if (string.eq key name)
        (CtfeMaybeValue.Some value)
        (ctfe-env-lookup (box-get rest) name))]))

(define (ctfe-env-lookup-type [env : CtfeEnv] [name : String]) : AstMaybeType
  (match env
    [(CtfeEnv.Nil _ _ _) (AstMaybeType.No)]
    [(CtfeEnv.Cons key _ ty rest)
      (if (string.eq key name)
        (AstMaybeType.Some ty)
        (ctfe-env-lookup-type (box-get rest) name))]))

(define (ctfe-string-prefix? [text : String] [prefix : String]) : bool
  (let
    [text-len : i64 (ctfe-private-string-length text)]
    [prefix-len : i64 (ctfe-private-string-length prefix)]
    (if (< text-len prefix-len)
      false
      (let
        [i : i64 0]
        [same : bool true]
        (begin
          (while (and same (< i prefix-len))
            (if (=
              (cast (ctfe-private-string-ref text i) : i64)
              (cast (ctfe-private-string-ref prefix i) : i64))
              (set! i (+ i 1))
              (set! same false)))
          same)))))

(define (ctfe-string-slice-eq? [text : String] [start : i64] [needle : String]) : bool
  (let
    [text-len : i64 (ctfe-private-string-length text)]
    [needle-len : i64 (ctfe-private-string-length needle)]
    (if (or (< start 0) (> (+ start needle-len) text-len))
      false
      (let
        [i : i64 0]
        [same : bool true]
        (begin
          (while (and same (< i needle-len))
            (if (=
              (cast (ctfe-private-string-ref text (+ start i)) : i64)
              (cast (ctfe-private-string-ref needle i) : i64))
              (set! i (+ i 1))
              (set! same false)))
          same)))))

(define (ctfe-string-eq-after-prefix?
  [name : String]
  [prefix : String]
  [base : String]) : bool
  (let
    [name-len : i64 (ctfe-private-string-length name)]
    [prefix-len : i64 (ctfe-private-string-length prefix)]
    [base-len : i64 (ctfe-private-string-length base)]
    (and
      (= name-len (+ prefix-len base-len))
      (ctfe-string-prefix? name prefix)
      (ctfe-string-slice-eq? name prefix-len base))))

(define (ctfe-string-suffix-with-prefix?
  [name : String]
  [prefix : String]
  [base : String]) : bool
  (let
    [name-len : i64 (ctfe-private-string-length name)]
    [prefix-len : i64 (ctfe-private-string-length prefix)]
    [base-len : i64 (ctfe-private-string-length base)]
    [start : i64 (- name-len (+ prefix-len base-len))]
    (and
      (>= start 0)
      (ctfe-string-slice-eq? name start prefix)
      (ctfe-string-slice-eq? name (+ start prefix-len) base))))

(define (ctfe-string-has-module-separator? [name : String]) : bool
  (let
    [i : i64 0]
    [n : i64 (ctfe-private-string-length name)]
    [found : bool false]
    (begin
      (while (and (not found) (< i n))
        (let
          [c : i64 (cast (ctfe-private-string-ref name i) : i64)]
          (if (or (= c 46) (= c 47))
            (set! found true)
            (set! i (+ i 1)))))
      found)))

(define (ctfe-string-contains-string-token? [name : String]) : bool
  (let
    [i : i64 0]
    [n : i64 (ctfe-private-string-length name)]
    [found : bool false]
    (begin
      (while (and (not found) (<= (+ i 6) n))
        (if (and
          (= (cast (ctfe-private-string-ref name i) : i64) 115)
          (= (cast (ctfe-private-string-ref name (+ i 1)) : i64) 116)
          (= (cast (ctfe-private-string-ref name (+ i 2)) : i64) 114)
          (= (cast (ctfe-private-string-ref name (+ i 3)) : i64) 105)
          (= (cast (ctfe-private-string-ref name (+ i 4)) : i64) 110)
          (= (cast (ctfe-private-string-ref name (+ i 5)) : i64) 103))
          (set! found true)
          (set! i (+ i 1))))
      found)))

(define (ctfe-string-helper-candidate-name? [name : String]) : bool
  (or
    (ctfe-string-contains-string-token? name)
    (ctfe-builtin-string-ref-id? (intern name))
    (ctfe-builtin-string-length-id? (intern name))))

(define (ctfe-hygiene-enabled-name) : String
  "__tl_macro_hygiene_enabled")

(define (ctfe-hygiene-template-prefix) : String
  "__tl_macro_template$")

(define (ctfe-hygiene-global-prefix) : String
  "__tl_macro_global$")

(define (ctfe-hygiene-enabled? [env : CtfeEnv]) : bool
  (match (ctfe-env-lookup env (ctfe-hygiene-enabled-name))
    [(CtfeMaybeValue.Some value)
      (match value
        [(CompilerCtfeValue.Bool enabled) enabled]
        [_ false])]
    [(CtfeMaybeValue.None) false]))

(define (ctfe-hygiene-template-name [name : String]) : String
  (if (ctfe-string-prefix? name (ctfe-hygiene-template-prefix))
    name
    (string.append (ctfe-hygiene-template-prefix) name)))

(define (ctfe-quote-name [env : CtfeEnv] [name : String]) : String
  (if (ctfe-hygiene-enabled? env)
    (ctfe-hygiene-template-name name)
    name))

(define (ctfe-quote-name-id [env : CtfeEnv] [name : i64]) : i64
  (intern (ctfe-quote-name env (intern-str name))))

(define (ctfe-hygiene-global-name? [name : String]) : bool
  (ctfe-string-prefix? name (ctfe-hygiene-global-prefix)))

(define (ctfe-hygiene-global-base [name : String]) : String
  (string.substring
    name
    (ctfe-private-string-length (ctfe-hygiene-global-prefix))
    (-
      (ctfe-private-string-length name)
      (ctfe-private-string-length (ctfe-hygiene-global-prefix)))))

(define (ctfe-hygiene-context-separator-index [payload : String]) : i64
  (let
    [i : i64 0]
    [n : i64 (ctfe-private-string-length payload)]
    [found : i64 -1]
    (begin
      (while (and (< i n) (< found 0))
        (if (= (cast (ctfe-private-string-ref payload i) : i64) 124)
          (set! found i)
          (set! i (+ i 1))))
      found)))

(define (ctfe-hygiene-global-call-name [name : String]) : String
  (if (ctfe-hygiene-global-name? name)
    (let
      [payload : String (ctfe-hygiene-global-base name)]
      [sep : i64 (ctfe-hygiene-context-separator-index payload)]
      (if (< sep 0)
        payload
        (let
          [start : i64 (+ sep 1)]
          (string.substring
            payload
            start
            (- (ctfe-private-string-length payload) start)))))
    name))

(define (ctfe-symbol-module-key [module : String] [name : String]) : String
  (if (= (ctfe-private-string-length module) 0)
    name
    (string.append module (string.append "/" name))))

(define (ctfe-hygiene-global-symbol-name [module : String] [name : String]) : String
  (string.append
    (ctfe-hygiene-global-prefix)
    (ctfe-symbol-module-key module name)))

(define ctfe-module-macro-export-keys : (Box ctfe_key_map.Map)
  (box (ctfe_key_map.with-capacity 1)))

(define (ctfe-module-macro-export-key [module : String] [name : String]) : String
  (string.append module (string.append "|" name)))

(define (ctfe-module-macro-export-reset!) : unit
  (set!
    (box-get ctfe-module-macro-export-keys)
    (ctfe_key_map.with-capacity 256)))

(define (ctfe-module-macro-export-add! [module : String] [name : String]) : unit
  (ctfe_key_map.insert
    (&mut (box-get ctfe-module-macro-export-keys))
    (ctfe-module-macro-export-key module name)
    1))

(define (ctfe-module-macro-export? [module : String] [name : String]) : bool
  (let
    [key : String (ctfe-module-macro-export-key module name)]
    (ctfe_key_map.contains-borrowed?
      (& (box-get ctfe-module-macro-export-keys))
      (& key))))

(define (ctfe-reflect-info-key [info : CtfeReflectInfo]) : String
  (match info
    [(CtfeReflectInfo.Struct key _ _ _) key]
    [(CtfeReflectInfo.Enum key _ _ _) key]))

(define (ctfe-reflect-info-list-add-if-missing
  [infos : CtfeReflectInfoList]
  [info : CtfeReflectInfo]) : CtfeReflectInfoList
  (if (ctfe-build-seen-add? (ctfe-reflect-info-key info))
    (ctfe-reflect-info-list-push infos info)
    infos))

(define (ctfe-reflect-info-lookup-from
  [infos : CtfeReflectInfoList]
  [key : String]
  [index : i64]) : CtfeMaybeReflectInfo
  (if (< index 0)
    (CtfeMaybeReflectInfo.None)
    (let
      [info : CtfeReflectInfo (ctfe-reflect-info-list-ref infos index)]
      (if (string.eq (ctfe-reflect-info-key info) key)
        (CtfeMaybeReflectInfo.Some info)
        (ctfe-reflect-info-lookup-from infos key (- index 1))))))

(define (ctfe-reflect-info-lookup [infos : CtfeReflectInfoList] [key : String]) : CtfeMaybeReflectInfo
  (ctfe-reflect-info-lookup-from infos key (- (struct-get infos len) 1)))

(define (ctfe-reflect-field-def-count [fields : AstFieldDefList]) : i64
  (struct-get (& fields) len))

(define (ctfe-reflect-field-list-from-fields-into
  [fields : (& fields AstFieldDefList)]
  [index : i64]
  [out : CtfeReflectFieldList]) : CtfeReflectFieldList
  (if (>= index (struct-get fields len))
    out
    (match (ast-field-def-list-get fields index (ast-field-def-fallback))
      [(AstFieldDef.Def name ty _)
        (ctfe-reflect-field-list-from-fields-into
          fields
          (+ index 1)
          (ctfe-reflect-field-list-push
            out
            (CtfeReflectField.Field (intern-str name) ty)))])))

(define (ctfe-reflect-field-list-from-fields [fields : AstFieldDefList]) : CtfeReflectFieldList
  (ctfe-reflect-field-list-from-fields-into
    (& fields)
    0
    (ctfe-reflect-field-list-with-capacity
      (ctfe-reflect-field-def-count fields))))

(define (ctfe-reflect-variant-def-count [variants : AstVariantDefList]) : i64
  (struct-get (& variants) len))

(define (ctfe-reflect-variant-list-from-variants-into
  [variants : (& variants AstVariantDefList)]
  [index : i64]
  [out : CtfeReflectVariantList]) : CtfeReflectVariantList
  (if (>= index (struct-get variants len))
    out
    (match (ast-variant-def-list-get variants index (ast-variant-def-fallback))
      [(AstVariantDef.Def name payloads _)
        (ctfe-reflect-variant-list-from-variants-into
          variants
          (+ index 1)
          (ctfe-reflect-variant-list-push
            out
            (CtfeReflectVariant.Variant (intern-str name) payloads)))])))

(define (ctfe-reflect-variant-list-from-variants [variants : AstVariantDefList]) : CtfeReflectVariantList
  (ctfe-reflect-variant-list-from-variants-into
    (& variants)
    0
    (ctfe-reflect-variant-list-with-capacity
      (ctfe-reflect-variant-def-count variants))))

(define (ctfe-reflect-info-add-alias
  [infos : CtfeReflectInfoList]
  [info : CtfeReflectInfo]
  [alias : String]) : CtfeReflectInfoList
  (match info
    [(CtfeReflectInfo.Struct _ module name fields)
      (ctfe-reflect-info-list-add-if-missing
        infos
        (CtfeReflectInfo.Struct alias module name fields))]
    [(CtfeReflectInfo.Enum _ module name variants)
      (ctfe-reflect-info-list-add-if-missing
        infos
        (CtfeReflectInfo.Enum alias module name variants))]))

(define (ctfe-reflect-info-add-names
  [infos : CtfeReflectInfoList]
  [info : CtfeReflectInfo]
  [name : String]
  [module : String]) : CtfeReflectInfoList
  (let
    [with-key : CtfeReflectInfoList
      (ctfe-reflect-info-list-add-if-missing infos info)]
    (if (= (string.string-length module) 0)
      with-key
      (ctfe-reflect-info-add-alias with-key info name))))

(define (ctfe-reflections-add-struct
  [infos : CtfeReflectInfoList]
  [module : String]
  [name : i64]
  [fields : AstFieldDefList]) : CtfeReflectInfoList
  (let
    [name-str : String (intern-str name)]
    [key : String
      (if (= (string.string-length module) 0)
        name-str
        (string.append module (string.append "/" name-str)))]
    [info : CtfeReflectInfo
      (CtfeReflectInfo.Struct
        key
        module
        name-str
        (ctfe-reflect-field-list-from-fields fields))]
    (ctfe-reflect-info-add-names infos info name-str module)))

(define (ctfe-reflections-add-enum
  [infos : CtfeReflectInfoList]
  [module : String]
  [name : i64]
  [variants : AstVariantDefList]) : CtfeReflectInfoList
  (let
    [name-str : String (intern-str name)]
    [key : String
      (if (= (string.string-length module) 0)
        name-str
        (string.append module (string.append "/" name-str)))]
    [info : CtfeReflectInfo
      (CtfeReflectInfo.Enum
        key
        module
        name-str
        (ctfe-reflect-variant-list-from-variants variants))]
    (ctfe-reflect-info-add-names infos info name-str module)))

(define (ctfe-reflections-add-template
  [infos : CtfeReflectInfoList]
  [module : String]
  [template : AstDecl]) : CtfeReflectInfoList
  (match template
    [(AstDecl.DefStruct name _ _ fields)
      (ctfe-reflections-add-struct infos module name fields)]
    [(AstDecl.DefStructLifetimes name _ _ _ fields)
      (ctfe-reflections-add-struct infos module name fields)]
    [(AstDecl.DefEnum name _ variants)
      (ctfe-reflections-add-enum infos module name variants)]
    [(AstDecl.DefEnumLifetimes name _ _ variants)
      (ctfe-reflections-add-enum infos module name variants)]
    [_ infos]))

(define (ctfe-reflections-from-decls
  [decls : AstDeclList]
  [module : String]
  [infos : CtfeReflectInfoList]) : CtfeReflectInfoList
  (let
    [count : i64 (ast-decl-list-len (& decls))]
    [index : i64 0]
    [current-module : String module]
    [current-infos : CtfeReflectInfoList infos]
    (begin
      (while (< index count)
        (begin
          (if (match (ast-decl-list-ref-borrowed (& decls) index)
            [(AstDecl.Module _) true]
            [(AstDecl.DefStruct _ _ _ _) true]
            [(AstDecl.DefStructLifetimes _ _ _ _ _) true]
            [(AstDecl.DefEnum _ _ _) true]
            [(AstDecl.DefEnumLifetimes _ _ _ _) true]
            [(AstDecl.ComptimeDecl _ _) true]
            [_ false])
            (match (ast-decl-list-ref decls index)
              [(AstDecl.Module next-module)
                (set! current-module (intern-str next-module))]
              [(AstDecl.DefStruct name _ _ fields)
                (set!
                  current-infos
                  (ctfe-reflections-add-struct
                    current-infos
                    current-module
                    name
                    fields))]
              [(AstDecl.DefStructLifetimes name _ _ _ fields)
                (set!
                  current-infos
                  (ctfe-reflections-add-struct
                    current-infos
                    current-module
                    name
                    fields))]
              [(AstDecl.DefEnum name _ variants)
                (set!
                  current-infos
                  (ctfe-reflections-add-enum
                    current-infos
                    current-module
                    name
                    variants))]
              [(AstDecl.DefEnumLifetimes name _ _ variants)
                (set!
                  current-infos
                  (ctfe-reflections-add-enum
                    current-infos
                    current-module
                    name
                    variants))]
              [(AstDecl.ComptimeDecl _ template-box)
                (set!
                  current-infos
                  (ctfe-reflections-add-template
                    current-infos
                    current-module
                    (box-get template-box)))]
              [_ unit])
            unit)
          (set! index (+ index 1))))
      current-infos)))

(define (ctfe-metadata-decl-capacity [decls : AstDeclList]) : i64
  (let
    [count : i64 (ast-decl-list-len (& decls))]
    [index : i64 0]
    [capacity : i64 1]
    (begin
      (while (< index count)
        (begin
          (match (ast-decl-list-ref-borrowed (& decls) index)
            [(AstDecl.DefStruct _ _ _ _) (set! capacity (+ capacity 2))]
            [(AstDecl.DefStructLifetimes _ _ _ _ _)
              (set! capacity (+ capacity 2))]
            [(AstDecl.DefEnum _ _ _) (set! capacity (+ capacity 2))]
            [(AstDecl.DefEnumLifetimes _ _ _ _) (set! capacity (+ capacity 2))]
            [(AstDecl.ComptimeDecl _ _)
              ;; Borrow the common declaration cases. Copy only the uncommon
              ;; boxed template whose payload must be dereferenced.
              (match (ast-decl-list-ref decls index)
                [(AstDecl.ComptimeDecl _ template-box)
                  (match (box-get template-box)
                    [(AstDecl.DefStruct _ _ _ _) (set! capacity (+ capacity 2))]
                    [(AstDecl.DefStructLifetimes _ _ _ _ _)
                      (set! capacity (+ capacity 2))]
                    [(AstDecl.DefEnum _ _ _) (set! capacity (+ capacity 2))]
                    [(AstDecl.DefEnumLifetimes _ _ _ _)
                      (set! capacity (+ capacity 2))]
                    [_ unit])]
                [_ unit])]
            [_ unit])
          (set! index (+ index 1))))
      capacity)))

(define (ctfe-reflections-from-program [program : AstProgram]) : CtfeReflectInfoList
  (match program
    [(AstProgram.Program decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        (begin
          (ctfe-build-seen-reset!)
          (ctfe-reflections-from-decls
            decls
            ""
            (ctfe-reflect-info-list-with-capacity
              (ctfe-metadata-decl-capacity decls)))))]))

;; Result of evaluating a sub-expression: either a value (carrying the remaining
;; fuel) or a diagnostic. Fuel is threaded so each evaluation step decrements a
;; shared budget across all sub-evaluations, matching the spirit of the Rust
;; evaluator's per-step 10_000 fuel cap.
(defenum ResultCtfe
  (Ok CompilerCtfeValue i64)
  (Err (Box CompilerDiagnostic)))

(defenum CtfePatternMatch
  (No)
  (Matched CtfeEnv))

(defenum ResultCtfeQuoteExpr
  (Ok i64 AstType i64)
  (Err (Box CompilerDiagnostic)))

(defenum ResultCtfeQuoteExprList
  (Ok AstExprList i64)
  (Err (Box CompilerDiagnostic)))

(defenum ResultCtfeQuoteType
  (Ok AstType i64)
  (Err (Box CompilerDiagnostic)))

(defenum ResultCtfeQuoteTypeList
  (Ok AstTypeList i64)
  (Err (Box CompilerDiagnostic)))

(defenum ResultCtfeQuoteLifetimeList
  (Ok AstLifetimeList)
  (Err (Box CompilerDiagnostic)))

(defenum ResultCtfeQuoteMaybeType
  (Ok AstMaybeType i64)
  (Err (Box CompilerDiagnostic)))

(defenum ResultCtfeQuoteLetBindings
  (Ok AstLetBindingList i64)
  (Err (Box CompilerDiagnostic)))

(defenum ResultCtfeQuoteLetBindingsBuild
  (Ok i64)
  (Err (Box CompilerDiagnostic)))

(defenum ResultCtfeQuoteResourceBindings
  (Ok AstResourceBindingList i64)
  (Err (Box CompilerDiagnostic)))

(defenum ResultCtfeQuoteResourceBindingsBuild
  (Ok i64)
  (Err (Box CompilerDiagnostic)))

(defenum ResultCtfeQuotePattern
  (Ok AstPattern)
  (Err (Box CompilerDiagnostic)))

(defenum ResultCtfeQuotePatternList
  (Ok AstPatternList)
  (Err (Box CompilerDiagnostic)))

(defenum ResultCtfeQuoteArms
  (Ok AstMatchArmList i64)
  (Err (Box CompilerDiagnostic)))

(defenum ResultCtfeQuoteArmsBuild
  (Ok i64)
  (Err (Box CompilerDiagnostic)))

(define (ctfe-fuel-limit) : i64
  10000)

;; Build a diagnostic anchored at the (possibly spanned) expression.
(define (ctfe-diagnostic-at-expr [expr : AstExpr] [message : String]) : CompilerDiagnostic
  (match expr
    [(AstExpr.Spanned _ span)
      (compiler-diagnostic-from-ast-span "" span message)]
    [_ (compiler-diagnostic-at-start "" message)]))

;; Human-readable tag for the unsupported-form diagnostic, mirroring
;; `describe_expr` in src/ctfe.rs.
(define (ctfe-describe-expr [expr : AstExpr]) : String
  (match expr
    [(AstExpr.Spanned _ _) "expression"]
    [(AstExpr.Literal _) "literal"]
    [(AstExpr.Var _) "variable reference"]
    [(AstExpr.Binary _ _ _) "binary operation"]
    [(AstExpr.Unary _ _) "unary operation"]
    [(AstExpr.Call _ _) "function call"]
    [(AstExpr.BracketClause _) "bracket clause"]
    [(AstExpr.TypeLiteral _) "type literal"]
    [(AstExpr.If _ _ _) "if"]
    [(AstExpr.Let _) "let"]
    [(AstExpr.Lambda _) "lambda"]
    [(AstExpr.Tuple _) "tuple"]
    [(AstExpr.TupleRef _ _) "tuple-ref"]
    [(AstExpr.Array _) "array"]
    [(AstExpr.DynArray _) "make-array"]
    [(AstExpr.MakeArray _ _) "make-array"]
    [(AstExpr.ArrayRef _ _) "array-ref"]
    [(AstExpr.ArraySet _ _ _) "array-set!"]
    [(AstExpr.ArrayTake _ _ _) "array-take!"]
    [(AstExpr.ArrayPush _ _) "array-push!"]
    [(AstExpr.StringRef _ _) "string-ref"]
    [(AstExpr.While _ _) "while"]
    [(AstExpr.Begin _) "begin"]
    [(AstExpr.Unsafe _) "unsafe"]
    [(AstExpr.Set _ _) "set!"]
    [(AstExpr.Ann _ _) "type annotation"]
    [(AstExpr.Cast _ _) "cast"]
    [(AstExpr.Borrow mutable _ _)
      (if mutable
        "mutable borrow"
        "borrow")]
    [(AstExpr.Match _) "match"]
    [(AstExpr.Foreach _) "foreach"]
    [(AstExpr.SpmdReduce _) "spmd-reduce"]
    [(AstExpr.SpmdScan _) "spmd-scan"]
    [(AstExpr.SpmdBroadcast _ _) "spmd-broadcast"]
    [(AstExpr.SpmdShuffle _ _) "spmd-shuffle"]
    [(AstExpr.SpmdProgramIndex) "program-index"]
    [(AstExpr.SpmdProgramCount) "program-count"]
    [(AstExpr.StructGet _ _) "struct-get"]
    [(AstExpr.StructSet _ _ _) "set!"]
    [(AstExpr.WithRegion _ _) "with-arena"]
    [(AstExpr.WithEscape _ _) "with-escape"]
    [(AstExpr.WithScratch _) "with-scratch"]
    [(AstExpr.InArena _ _) "in-arena"]
    [(AstExpr.WithResource _) "with"]
    [(AstExpr.TypeLiteral _) "type literal"]
    [(AstExpr.Init _) "init"]
    [(AstExpr.Comptime _) "comptime"]
    [(AstExpr.Quote _) "quote"]
    [(AstExpr.Quasiquote _) "quasiquote"]
    [(AstExpr.Unquote _) "unquote"]
    [(AstExpr.UnquoteSplicing _) "unquote-splicing"]
    [(AstExpr.Try _) "try"]
    [(AstExpr.Return _) "return"]
    [(AstExpr.Break) "break"]
    [(AstExpr.Continue) "continue"]
    [(AstExpr.PtrNull _) "ptr-null"]
    [(AstExpr.PtrNullCheck _) "ptr-null?"]
    [(AstExpr.PtrAddrOf _) "ptr-addr-of"]
    [(AstExpr.PtrRead _) "ptr-read"]
    [(AstExpr.PtrWrite _ _) "ptr-write!"]
    [(AstExpr.PtrOffset _ _) "ptr-offset"]
    [(AstExpr.PtrCast _ _) "ptr-cast"]
    [(AstExpr.PtrToInt _) "ptr->int"]
    [(AstExpr.IntToPtr _ _) "int->ptr"]
    [(AstExpr.Box _) "box"]
    [(AstExpr.BoxGet _) "box-get"]
    [(AstExpr.BoxTake _) "box-take"]
    [(AstExpr.BoxSet _ _) "set!"]
    [(AstExpr.StringData _) "string-data"]
    [(AstExpr.StringFromBytes _ _) "string-from-bytes"]
    [(AstExpr.ArrayData _) "array-data"]
    [(AstExpr.BinaryData _) "binary-data"]
    [(AstExpr.SpmdProgramIndex) "program-index"]
    [(AstExpr.SpmdProgramCount) "program-count"]
    [(AstExpr.ProgramArgc) "program-argc"]
    [(AstExpr.ProgramArgv) "program-argv"]
    [(AstExpr.ProgramEnvp) "program-envp"]
    [(AstExpr.CpuIdEax _ _) "cpuid-eax"]
    [(AstExpr.CpuIdEbx _ _) "cpuid-ebx"]
    [(AstExpr.CpuIdEcx _ _) "cpuid-ecx"]
    [(AstExpr.CpuIdEdx _ _) "cpuid-edx"]
    [(AstExpr.Xgetbv _) "xgetbv"]
    [(AstExpr.Syscall _) "syscall"]))

(define (ctfe-value-type-name [value : CompilerCtfeValue]) : String
  (match value
    [(CompilerCtfeValue.I64 _) "i64"]
    [(CompilerCtfeValue.F64 _) "f64"]
    [(CompilerCtfeValue.F32 _) "f32"]
    [(CompilerCtfeValue.Bool _) "bool"]
    [(CompilerCtfeValue.Char _) "char"]
    [(CompilerCtfeValue.String _) "String"]
    [(CompilerCtfeValue.Unit) "unit"]
    [(CompilerCtfeValue.Type _) "type"]
    [(CompilerCtfeValue.Expr _ _) "Expr"]
    [(CompilerCtfeValue.ExprList _) "expr-list"]
    [(CompilerCtfeValue.ExprClause _) "ExprClause"]
    [(CompilerCtfeValue.ExprClauseList _) "ExprClauseList"]
    [(CompilerCtfeValue.ExprBindingClause _) "ExprBindingClause"]
    [(CompilerCtfeValue.ExprBindingClauseList _) "ExprBindingClauseList"]
    [(CompilerCtfeValue.Pattern _) "Pattern"]
    [(CompilerCtfeValue.PatternList _) "PatternList"]
    [(CompilerCtfeValue.MatchArm _) "MatchArm"]
    [(CompilerCtfeValue.MatchArmList _) "MatchArmList"]
    [(CompilerCtfeValue.TypeInfo _) "TypeInfo"]
    [(CompilerCtfeValue.TypeInfoBox _) "Box"]
    [(CompilerCtfeValue.TypeInfoList _) "TypeInfoList"]
    [(CompilerCtfeValue.TypeField _ _) "TypeField"]
    [(CompilerCtfeValue.TypeFieldList _) "TypeFieldList"]
    [(CompilerCtfeValue.TypeVariantPayload _) "TypeVariantPayload"]
    [(CompilerCtfeValue.TypeVariantPayloadList _) "TypeVariantPayloadList"]
    [(CompilerCtfeValue.TypeVariant _ _) "TypeVariant"]
    [(CompilerCtfeValue.TypeVariantList _) "TypeVariantList"]))

;; Promote a char to its i64 code point so the i64 comparison primitives drive
;; char ordering/equality, matching Rust's code-point comparison.
(define (ctfe-char-code [c : char]) : i64
  (cast c : i64))

;; --- literals ---------------------------------------------------------------
(define (ctfe-eval-literal [lit : AstLiteral] [expr : AstExpr] [fuel : i64]) : ResultCtfe
  (match lit
    [(AstLiteral.Int n _) (ResultCtfe.Ok (CompilerCtfeValue.I64 n) fuel)]
    [(AstLiteral.Bool b) (ResultCtfe.Ok (CompilerCtfeValue.Bool b) fuel)]
    [(AstLiteral.Char c) (ResultCtfe.Ok (CompilerCtfeValue.Char c) fuel)]
    [(AstLiteral.Unit) (ResultCtfe.Ok (CompilerCtfeValue.Unit) fuel)]
    [(AstLiteral.Float text)
      (match (compiler-float-parse-f64 text)
        [(CompilerFloatSomeF64 value)
          (if (compiler-float-f64-finite? value)
            (ResultCtfe.Ok (CompilerCtfeValue.F64 value) fuel)
            (ResultCtfe.Err
              (box
                (ctfe-diagnostic-at-expr
                  expr
                  "comptime: non-finite f64 literal is not supported"))))]
        [(CompilerFloatNoF64)
          (if (compiler-float-decimal-syntax? text)
            (ResultCtfe.Err
              (box
                (ctfe-diagnostic-at-expr
                  expr
                  "comptime: non-finite f64 literal is not supported")))
            (ResultCtfe.Err
              (box
                (ctfe-diagnostic-at-expr expr "comptime: invalid f64 literal"))))])]
    [(AstLiteral.String text)
      (ResultCtfe.Ok (CompilerCtfeValue.String text) fuel)]))

;; --- binary operators -------------------------------------------------------
;; i64 arithmetic/bitwise/shift and i64 comparisons.
(define (ctfe-eval-bin-i64
  [op : AstBinOp]
  [a : i64]
  [b : i64]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (match op
    [(AstBinOp.Add) (ResultCtfe.Ok (CompilerCtfeValue.I64 (+ a b)) fuel)]
    [(AstBinOp.Sub) (ResultCtfe.Ok (CompilerCtfeValue.I64 (- a b)) fuel)]
    [(AstBinOp.Mul) (ResultCtfe.Ok (CompilerCtfeValue.I64 (* a b)) fuel)]
    [(AstBinOp.Div)
      (if (= b 0)
        (ResultCtfe.Err
          (box (ctfe-diagnostic-at-expr expr "division by zero in comptime")))
        (ResultCtfe.Ok (CompilerCtfeValue.I64 (/ a b)) fuel))]
    [(AstBinOp.Mod)
      (if (= b 0)
        (ResultCtfe.Err
          (box (ctfe-diagnostic-at-expr expr "modulo by zero in comptime")))
        (ResultCtfe.Ok (CompilerCtfeValue.I64 (% a b)) fuel))]
    [(AstBinOp.Eq) (ResultCtfe.Ok (CompilerCtfeValue.Bool (= a b)) fuel)]
    [(AstBinOp.Ne) (ResultCtfe.Ok (CompilerCtfeValue.Bool (!= a b)) fuel)]
    [(AstBinOp.Lt) (ResultCtfe.Ok (CompilerCtfeValue.Bool (< a b)) fuel)]
    [(AstBinOp.Le) (ResultCtfe.Ok (CompilerCtfeValue.Bool (<= a b)) fuel)]
    [(AstBinOp.Gt) (ResultCtfe.Ok (CompilerCtfeValue.Bool (> a b)) fuel)]
    [(AstBinOp.Ge) (ResultCtfe.Ok (CompilerCtfeValue.Bool (>= a b)) fuel)]
    [(AstBinOp.BitAnd)
      (ResultCtfe.Ok (CompilerCtfeValue.I64 (bit-and a b)) fuel)]
    [(AstBinOp.BitOr) (ResultCtfe.Ok (CompilerCtfeValue.I64 (bit-or a b)) fuel)]
    [(AstBinOp.BitXor)
      (ResultCtfe.Ok (CompilerCtfeValue.I64 (bit-xor a b)) fuel)]
    [(AstBinOp.Shl) (ResultCtfe.Ok (CompilerCtfeValue.I64 (shl a b)) fuel)]
    [(AstBinOp.Shr) (ResultCtfe.Ok (CompilerCtfeValue.I64 (shr a b)) fuel)]
    [(AstBinOp.And)
      (ResultCtfe.Err
        (box
          (ctfe-diagnostic-at-expr
            expr
            "'and' in comptime requires bool operands")))]
    [(AstBinOp.Or)
      (ResultCtfe.Err
        (box
          (ctfe-diagnostic-at-expr
            expr
            "'or' in comptime requires bool operands")))]))

(define (ctfe-f64-result [value : f64] [expr : AstExpr] [fuel : i64]) : ResultCtfe
  (if (compiler-float-f64-finite? value)
    (ResultCtfe.Ok (CompilerCtfeValue.F64 value) fuel)
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          "comptime: non-finite f64 result is not supported")))))

(define (ctfe-f32-result [value : f64] [expr : AstExpr] [fuel : i64]) : ResultCtfe
  (let
    [rounded : f64 (compiler-float-round-f32-as-f64 value)]
    (if (compiler-float-f64-finite? rounded)
      (ResultCtfe.Ok (CompilerCtfeValue.F32 rounded) fuel)
      (ResultCtfe.Err
        (box
          (ctfe-diagnostic-at-expr
            expr
            "comptime: non-finite f32 result is not supported"))))))

;; Finite f64 arithmetic and comparisons. Non-finite results are rejected until
;; TypeLisp specifies NaN payload and infinity serialization across backends.
(define (ctfe-eval-bin-f64
  [op : AstBinOp]
  [a : f64]
  [b : f64]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (match op
    [(AstBinOp.Add) (ctfe-f64-result (+ a b) expr fuel)]
    [(AstBinOp.Sub) (ctfe-f64-result (- a b) expr fuel)]
    [(AstBinOp.Mul) (ctfe-f64-result (* a b) expr fuel)]
    [(AstBinOp.Div)
      (if (= b 0.0)
        (ResultCtfe.Err
          (box
            (ctfe-diagnostic-at-expr expr "float division by zero in comptime")))
        (ctfe-f64-result (/ a b) expr fuel))]
    [(AstBinOp.Eq) (ResultCtfe.Ok (CompilerCtfeValue.Bool (= a b)) fuel)]
    [(AstBinOp.Ne) (ResultCtfe.Ok (CompilerCtfeValue.Bool (!= a b)) fuel)]
    [(AstBinOp.Lt) (ResultCtfe.Ok (CompilerCtfeValue.Bool (< a b)) fuel)]
    [(AstBinOp.Le) (ResultCtfe.Ok (CompilerCtfeValue.Bool (<= a b)) fuel)]
    [(AstBinOp.Gt) (ResultCtfe.Ok (CompilerCtfeValue.Bool (> a b)) fuel)]
    [(AstBinOp.Ge) (ResultCtfe.Ok (CompilerCtfeValue.Bool (>= a b)) fuel)]
    [_
      (ResultCtfe.Err
        (box
          (ctfe-diagnostic-at-expr
            expr
            "this operation is not supported on f64 in compile-time evaluation")))]))

(define (ctfe-eval-bin-f32
  [op : AstBinOp]
  [a : f64]
  [b : f64]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (match op
    [(AstBinOp.Add) (ctfe-f32-result (+ a b) expr fuel)]
    [(AstBinOp.Sub) (ctfe-f32-result (- a b) expr fuel)]
    [(AstBinOp.Mul) (ctfe-f32-result (* a b) expr fuel)]
    [(AstBinOp.Div)
      (if (= b 0.0)
        (ResultCtfe.Err
          (box
            (ctfe-diagnostic-at-expr expr "float division by zero in comptime")))
        (ctfe-f32-result (/ a b) expr fuel))]
    [(AstBinOp.Eq) (ResultCtfe.Ok (CompilerCtfeValue.Bool (= a b)) fuel)]
    [(AstBinOp.Ne) (ResultCtfe.Ok (CompilerCtfeValue.Bool (!= a b)) fuel)]
    [(AstBinOp.Lt) (ResultCtfe.Ok (CompilerCtfeValue.Bool (< a b)) fuel)]
    [(AstBinOp.Le) (ResultCtfe.Ok (CompilerCtfeValue.Bool (<= a b)) fuel)]
    [(AstBinOp.Gt) (ResultCtfe.Ok (CompilerCtfeValue.Bool (> a b)) fuel)]
    [(AstBinOp.Ge) (ResultCtfe.Ok (CompilerCtfeValue.Bool (>= a b)) fuel)]
    [_
      (ResultCtfe.Err
        (box
          (ctfe-diagnostic-at-expr
            expr
            "this operation is not supported on f32 in compile-time evaluation")))]))

;; bool comparisons and boolean connectives.
(define (ctfe-eval-bin-bool
  [op : AstBinOp]
  [a : bool]
  [b : bool]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (match op
    [(AstBinOp.Eq)
      (ResultCtfe.Ok
        (CompilerCtfeValue.Bool (or (and a b) (and (not a) (not b))))
        fuel)]
    [(AstBinOp.Ne)
      (ResultCtfe.Ok
        (CompilerCtfeValue.Bool (not (or (and a b) (and (not a) (not b)))))
        fuel)]
    [(AstBinOp.And) (ResultCtfe.Ok (CompilerCtfeValue.Bool (and a b)) fuel)]
    [(AstBinOp.Or) (ResultCtfe.Ok (CompilerCtfeValue.Bool (or a b)) fuel)]
    [_
      (ResultCtfe.Err
        (box
          (ctfe-diagnostic-at-expr
            expr
            "this operation is not supported on bool in compile-time evaluation")))]))

;; char comparisons via code-point ordering.
(define (ctfe-eval-bin-char
  [op : AstBinOp]
  [a : char]
  [b : char]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (let
    [ca : i64 (ctfe-char-code a)]
    [cb : i64 (ctfe-char-code b)]
    (match op
      [(AstBinOp.Eq) (ResultCtfe.Ok (CompilerCtfeValue.Bool (= ca cb)) fuel)]
      [(AstBinOp.Ne) (ResultCtfe.Ok (CompilerCtfeValue.Bool (!= ca cb)) fuel)]
      [(AstBinOp.Lt) (ResultCtfe.Ok (CompilerCtfeValue.Bool (< ca cb)) fuel)]
      [(AstBinOp.Le) (ResultCtfe.Ok (CompilerCtfeValue.Bool (<= ca cb)) fuel)]
      [(AstBinOp.Gt) (ResultCtfe.Ok (CompilerCtfeValue.Bool (> ca cb)) fuel)]
      [(AstBinOp.Ge) (ResultCtfe.Ok (CompilerCtfeValue.Bool (>= ca cb)) fuel)]
      [_
        (ResultCtfe.Err
          (box
            (ctfe-diagnostic-at-expr
              expr
              "this operation is not supported on char in compile-time evaluation")))])))

;; string comparisons (only `==`/`!=`).
(define (ctfe-eval-bin-string
  [op : AstBinOp]
  [a : String]
  [b : String]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (match op
    [(AstBinOp.Eq)
      (ResultCtfe.Ok (CompilerCtfeValue.Bool (string.eq a b)) fuel)]
    [(AstBinOp.Ne)
      (ResultCtfe.Ok (CompilerCtfeValue.Bool (not (string.eq a b))) fuel)]
    [_
      (ResultCtfe.Err
        (box
          (ctfe-diagnostic-at-expr
            expr
            "this operation is not supported on String in compile-time evaluation")))]))

;; unit comparisons (only `==`/`!=`).
(define (ctfe-eval-bin-unit [op : AstBinOp] [expr : AstExpr] [fuel : i64]) : ResultCtfe
  (match op
    [(AstBinOp.Eq) (ResultCtfe.Ok (CompilerCtfeValue.Bool true) fuel)]
    [(AstBinOp.Ne) (ResultCtfe.Ok (CompilerCtfeValue.Bool false) fuel)]
    [_
      (ResultCtfe.Err
        (box
          (ctfe-diagnostic-at-expr
            expr
            "this operation is not supported on unit in compile-time evaluation")))]))

(define (ctfe-eval-bin-type-info
  [op : AstBinOp]
  [a : AstType]
  [b : AstType]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match op
    [(AstBinOp.Eq)
      (ResultCtfe.Ok
        (CompilerCtfeValue.Bool (ctfe-type-eq-in-env env a b))
        fuel)]
    [(AstBinOp.Ne)
      (ResultCtfe.Ok
        (CompilerCtfeValue.Bool (not (ctfe-type-eq-in-env env a b)))
        fuel)]
    [_
      (ResultCtfe.Err
        (box
          (ctfe-diagnostic-at-expr
            expr
            "this operation is not supported on TypeInfo in compile-time evaluation")))]))

(define (ctfe-eval-bin-comptime-metadata [label : String] [expr : AstExpr]) : ResultCtfe
  (ResultCtfe.Err
    (box
      (ctfe-diagnostic-at-expr
        expr
        (string.append
          "this operation is not supported on "
          (string.append label " in compile-time evaluation"))))))

;; Dispatch a binary op over two already-evaluated operands.
(define (ctfe-apply-binop
  [op : AstBinOp]
  [lv : CompilerCtfeValue]
  [rv : CompilerCtfeValue]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match lv
    [(CompilerCtfeValue.I64 a)
      (match rv
        [(CompilerCtfeValue.I64 b) (ctfe-eval-bin-i64 op a b expr fuel)]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                "binary operation in comptime requires matching operand types")))])]
    [(CompilerCtfeValue.F64 a)
      (match rv
        [(CompilerCtfeValue.F64 b) (ctfe-eval-bin-f64 op a b expr fuel)]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                "binary operation in comptime requires matching operand types")))])]
    [(CompilerCtfeValue.F32 a)
      (match rv
        [(CompilerCtfeValue.F32 b) (ctfe-eval-bin-f32 op a b expr fuel)]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                "binary operation in comptime requires matching operand types")))])]
    [(CompilerCtfeValue.Bool a)
      (match rv
        [(CompilerCtfeValue.Bool b) (ctfe-eval-bin-bool op a b expr fuel)]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                "binary operation in comptime requires matching operand types")))])]
    [(CompilerCtfeValue.Char a)
      (match rv
        [(CompilerCtfeValue.Char b) (ctfe-eval-bin-char op a b expr fuel)]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                "binary operation in comptime requires matching operand types")))])]
    [(CompilerCtfeValue.String a)
      (match rv
        [(CompilerCtfeValue.String b) (ctfe-eval-bin-string op a b expr fuel)]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                "binary operation in comptime requires matching operand types")))])]
    [(CompilerCtfeValue.Unit)
      (match rv
        [(CompilerCtfeValue.Unit) (ctfe-eval-bin-unit op expr fuel)]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                "binary operation in comptime requires matching operand types")))])]
    [(CompilerCtfeValue.Type a)
      (match rv
        [(CompilerCtfeValue.Type b)
          (match op
            [(AstBinOp.Eq)
              (ResultCtfe.Ok
                (CompilerCtfeValue.Bool (ctfe-type-eq-in-env env a b))
                fuel)]
            [(AstBinOp.Ne)
              (ResultCtfe.Ok
                (CompilerCtfeValue.Bool (not (ctfe-type-eq-in-env env a b)))
                fuel)]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "this operation is not supported on type in compile-time evaluation")))])]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                "binary operation in comptime requires matching operand types")))])]
    [(CompilerCtfeValue.Expr a a-ty)
      (match rv
        [(CompilerCtfeValue.Expr b b-ty)
          (match op
            [(AstBinOp.Eq)
              (ResultCtfe.Ok
                (CompilerCtfeValue.Bool
                  (and
                    (ctfe-expr-eq-in-env
                      env
                      (ctfe-ast-get env a)
                      (ctfe-ast-get env b))
                    (ctfe-type-eq-in-env env a-ty b-ty)))
                fuel)]
            [(AstBinOp.Ne)
              (ResultCtfe.Ok
                (CompilerCtfeValue.Bool
                  (not
                    (and
                      (ctfe-expr-eq-in-env
                        env
                        (ctfe-ast-get env a)
                        (ctfe-ast-get env b))
                      (ctfe-type-eq-in-env env a-ty b-ty))))
                fuel)]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "this operation is not supported on expr in compile-time evaluation")))])]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                "binary operation in comptime requires matching operand types")))])]
    [(CompilerCtfeValue.ExprList a)
      (match rv
        [(CompilerCtfeValue.ExprList b)
          (match op
            [(AstBinOp.Eq)
              (ResultCtfe.Ok
                (CompilerCtfeValue.Bool (ctfe-expr-list-eq-in-env env a b))
                fuel)]
            [(AstBinOp.Ne)
              (ResultCtfe.Ok
                (CompilerCtfeValue.Bool
                  (not (ctfe-expr-list-eq-in-env env a b)))
                fuel)]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "this operation is not supported on expr-list in compile-time evaluation")))])]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                "binary operation in comptime requires matching operand types")))])]
    [(CompilerCtfeValue.ExprClause a)
      (match rv
        [(CompilerCtfeValue.ExprClause b)
          (match op
            [(AstBinOp.Eq)
              (ResultCtfe.Ok
                (CompilerCtfeValue.Bool (ctfe-expr-clause-eq-in-env env a b))
                fuel)]
            [(AstBinOp.Ne)
              (ResultCtfe.Ok
                (CompilerCtfeValue.Bool
                  (not (ctfe-expr-clause-eq-in-env env a b)))
                fuel)]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "this operation is not supported on expr-clause in compile-time evaluation")))])]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                "binary operation in comptime requires matching operand types")))])]
    [(CompilerCtfeValue.ExprClauseList a)
      (match rv
        [(CompilerCtfeValue.ExprClauseList b)
          (match op
            [(AstBinOp.Eq)
              (ResultCtfe.Ok
                (CompilerCtfeValue.Bool
                  (ctfe-expr-clause-list-eq-in-env env a b))
                fuel)]
            [(AstBinOp.Ne)
              (ResultCtfe.Ok
                (CompilerCtfeValue.Bool
                  (not (ctfe-expr-clause-list-eq-in-env env a b)))
                fuel)]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "this operation is not supported on expr-clause-list in compile-time evaluation")))])]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                "binary operation in comptime requires matching operand types")))])]
    [(CompilerCtfeValue.ExprBindingClause a)
      (match rv
        [(CompilerCtfeValue.ExprBindingClause b)
          (match op
            [(AstBinOp.Eq)
              (ResultCtfe.Ok
                (CompilerCtfeValue.Bool
                  (ctfe-expr-binding-clause-eq-in-env env a b))
                fuel)]
            [(AstBinOp.Ne)
              (ResultCtfe.Ok
                (CompilerCtfeValue.Bool
                  (not (ctfe-expr-binding-clause-eq-in-env env a b)))
                fuel)]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "this operation is not supported on expr-binding-clause in compile-time evaluation")))])]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                "binary operation in comptime requires matching operand types")))])]
    [(CompilerCtfeValue.ExprBindingClauseList a)
      (match rv
        [(CompilerCtfeValue.ExprBindingClauseList b)
          (match op
            [(AstBinOp.Eq)
              (ResultCtfe.Ok
                (CompilerCtfeValue.Bool
                  (ctfe-expr-binding-clause-list-eq-in-env env a b))
                fuel)]
            [(AstBinOp.Ne)
              (ResultCtfe.Ok
                (CompilerCtfeValue.Bool
                  (not (ctfe-expr-binding-clause-list-eq-in-env env a b)))
                fuel)]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "this operation is not supported on expr-binding-clause-list in compile-time evaluation")))])]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                "binary operation in comptime requires matching operand types")))])]
    [(CompilerCtfeValue.Pattern _)
      (ctfe-eval-bin-comptime-metadata "Pattern" expr)]
    [(CompilerCtfeValue.PatternList _)
      (ctfe-eval-bin-comptime-metadata "PatternList" expr)]
    [(CompilerCtfeValue.MatchArm _)
      (ctfe-eval-bin-comptime-metadata "MatchArm" expr)]
    [(CompilerCtfeValue.MatchArmList _)
      (ctfe-eval-bin-comptime-metadata "MatchArmList" expr)]
    [(CompilerCtfeValue.TypeInfo a)
      (match rv
        [(CompilerCtfeValue.TypeInfo b)
          (ctfe-eval-bin-type-info op a b expr env fuel)]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                "binary operation in comptime requires matching operand types")))])]
    [(CompilerCtfeValue.TypeInfoBox a)
      (match rv
        [(CompilerCtfeValue.TypeInfoBox b)
          (ctfe-eval-bin-type-info op a b expr env fuel)]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                "binary operation in comptime requires matching operand types")))])]
    [(CompilerCtfeValue.TypeInfoList _)
      (ctfe-eval-bin-comptime-metadata "TypeInfoList" expr)]
    [(CompilerCtfeValue.TypeField _ _)
      (ctfe-eval-bin-comptime-metadata "TypeField" expr)]
    [(CompilerCtfeValue.TypeFieldList _)
      (ctfe-eval-bin-comptime-metadata "TypeFieldList" expr)]
    [(CompilerCtfeValue.TypeVariantPayload _)
      (ctfe-eval-bin-comptime-metadata "TypeVariantPayload" expr)]
    [(CompilerCtfeValue.TypeVariantPayloadList _)
      (ctfe-eval-bin-comptime-metadata "TypeVariantPayloadList" expr)]
    [(CompilerCtfeValue.TypeVariant _ _)
      (ctfe-eval-bin-comptime-metadata "TypeVariant" expr)]
    [(CompilerCtfeValue.TypeVariantList _)
      (ctfe-eval-bin-comptime-metadata "TypeVariantList" expr)]))

;; --- unary operators --------------------------------------------------------
(define (ctfe-apply-unop
  [op : AstUnOp]
  [v : CompilerCtfeValue]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (match op
    [(AstUnOp.Neg)
      (match v
        [(CompilerCtfeValue.I64 n)
          (ResultCtfe.Ok (CompilerCtfeValue.I64 (- 0 n)) fuel)]
        [(CompilerCtfeValue.F64 n) (ctfe-f64-result (- 0.0 n) expr fuel)]
        [(CompilerCtfeValue.F32 n) (ctfe-f32-result (- 0.0 n) expr fuel)]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                "negation in comptime requires a numeric type")))])]
    [(AstUnOp.Not)
      (match v
        [(CompilerCtfeValue.Bool b)
          (ResultCtfe.Ok (CompilerCtfeValue.Bool (not b)) fuel)]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr expr "'not' in comptime requires bool")))])]
    [(AstUnOp.BitNot)
      (match v
        [(CompilerCtfeValue.I64 n)
          (ResultCtfe.Ok (CompilerCtfeValue.I64 (bit-not n)) fuel)]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                "bitwise not in comptime requires i64")))])]))

(define (ctfe-value-default-cast-type [value : CompilerCtfeValue]) : AstType
  (match value
    [(CompilerCtfeValue.I64 _) (AstType.I64)]
    [(CompilerCtfeValue.F64 _) (AstType.F64)]
    [(CompilerCtfeValue.F32 _) (AstType.F32)]
    [(CompilerCtfeValue.Char _) (AstType.Char)]
    [(CompilerCtfeValue.Pattern _) (ctfe-stdlib-comptime-type "Pattern")]
    [(CompilerCtfeValue.PatternList _)
      (ctfe-stdlib-comptime-type "PatternList")]
    [(CompilerCtfeValue.MatchArm _) (ctfe-stdlib-comptime-type "MatchArm")]
    [(CompilerCtfeValue.MatchArmList _)
      (ctfe-stdlib-comptime-type "MatchArmList")]
    [(CompilerCtfeValue.TypeInfo _) (ctfe-type-info-source-type)]
    [(CompilerCtfeValue.TypeInfoBox _) (ctfe-type-info-box-source-type)]
    [(CompilerCtfeValue.TypeInfoList _)
      (ctfe-stdlib-comptime-type "TypeInfoList")]
    [(CompilerCtfeValue.TypeField _ _) (ctfe-stdlib-comptime-type "TypeField")]
    [(CompilerCtfeValue.TypeFieldList _)
      (ctfe-stdlib-comptime-type "TypeFieldList")]
    [(CompilerCtfeValue.TypeVariantPayload _)
      (ctfe-stdlib-comptime-type "TypeVariantPayload")]
    [(CompilerCtfeValue.TypeVariantPayloadList _)
      (ctfe-stdlib-comptime-type "TypeVariantPayloadList")]
    [(CompilerCtfeValue.TypeVariant _ _)
      (ctfe-stdlib-comptime-type "TypeVariant")]
    [(CompilerCtfeValue.TypeVariantList _)
      (ctfe-stdlib-comptime-type "TypeVariantList")]
    [_ (AstType.Unit)]))

(define (ctfe-cast-source-type
  [inner : AstExpr]
  [value : CompilerCtfeValue]
  [env : CtfeEnv]) : AstType
  (match inner
    [(AstExpr.Spanned inner-box _)
      (ctfe-cast-source-type (ctfe-ast-get env inner-box) value env)]
    [(AstExpr.Ann _ ty) ty]
    [(AstExpr.Cast _ ty) ty]
    [(AstExpr.Var name)
      (match (ctfe-env-lookup-type env (intern-str name))
        [(AstMaybeType.Some ty) ty]
        [(AstMaybeType.No) (ctfe-value-default-cast-type value)])]
    [_ (ctfe-value-default-cast-type value)]))

(define (ctfe-binding-type
  [maybe-ty : AstMaybeType]
  [fallback : AstType]
  [env : CtfeEnv]) : AstType
  (match maybe-ty
    [(AstMaybeType.Some ty)
      (ctfe-reflect-resolve-type-with-pools
        (ctfe-env-pools env)
        (ctfe-env-reflections env)
        ty)]
    [(AstMaybeType.No) fallback]))

(define (ctfe-finite-cast-input [value : CompilerCtfeValue]) : CompilerFiniteCastInput
  (match value
    [(CompilerCtfeValue.I64 n) (CompilerFiniteCastInputI64 n)]
    [(CompilerCtfeValue.F64 n) (CompilerFiniteCastInputF64 n)]
    [(CompilerCtfeValue.F32 n) (CompilerFiniteCastInputF32 n)]
    [(CompilerCtfeValue.Char c) (CompilerFiniteCastInputChar c)]
    [_ (CompilerFiniteCastNoInput)]))

(define (ctfe-finite-cast-result
  [result : CompilerFiniteCastResult]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (match result
    [(CompilerFiniteCastResultI64 n)
      (ResultCtfe.Ok (CompilerCtfeValue.I64 n) fuel)]
    [(CompilerFiniteCastResultChar c)
      (ResultCtfe.Ok (CompilerCtfeValue.Char c) fuel)]
    [(CompilerFiniteCastResultF64 n) (ctfe-f64-result n expr fuel)]
    [(CompilerFiniteCastResultF32 n) (ctfe-f32-result n expr fuel)]
    [(CompilerFiniteCastNoResult)
      (ResultCtfe.Err
        (box (ctfe-diagnostic-at-expr expr "comptime: unsupported cast")))]))

(define (ctfe-apply-cast
  [value : CompilerCtfeValue]
  [from-ty : AstType]
  [ty : AstType]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (match ty
    [(AstType.F64)
      (match value
        [(CompilerCtfeValue.F64 n) (ctfe-f64-result n expr fuel)]
        [(CompilerCtfeValue.F32 n) (ctfe-f64-result n expr fuel)]
        [_
          (ctfe-finite-cast-result
            (compiler-finite-cast-fold
              (ctfe-finite-cast-input value)
              from-ty
              ty)
            expr
            fuel)])]
    [(AstType.F32)
      (match value
        [(CompilerCtfeValue.F64 n) (ctfe-f32-result n expr fuel)]
        [(CompilerCtfeValue.F32 n) (ctfe-f32-result n expr fuel)]
        [_
          (ctfe-finite-cast-result
            (compiler-finite-cast-fold
              (ctfe-finite-cast-input value)
              from-ty
              ty)
            expr
            fuel)])]
    [_
      (ctfe-finite-cast-result
        (compiler-finite-cast-fold (ctfe-finite-cast-input value) from-ty ty)
        expr
        fuel)]))

(define (ctfe-eval-cast
  [inner : AstExpr]
  [ty : AstType]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match (compiler-ctfe-eval inner env fuel)
    [(ResultCtfe.Ok value next-fuel)
      (ctfe-apply-cast
        value
        (ctfe-cast-source-type inner value env)
        ty
        expr
        next-fuel)]
    [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))

(defenum ResultCtfeStringLookup
  (Ok String)
  (Err String))

(defenum ResultCtfeTypeLookup
  (Ok AstType)
  (Err String))

(defenum ResultCtfeTypeListLookup
  (Ok AstTypeList)
  (Err String))

(defenum ResultCtfeTypeArg
  (Ok AstType i64)
  (Err (Box CompilerDiagnostic)))

(defstruct CtfeI64Arg
  (value i64)
  (fuel i64))

(import (result CtfeI64Arg (Box CompilerDiagnostic)) as result_ctfe_i64_arg)

(defenum ResultCtfeStringArg
  (Ok String i64)
  (Err (Box CompilerDiagnostic)))

(define (ctfe-reflect-info-canonical-type [info : CtfeReflectInfo]) : AstType
  (match info
    [(CtfeReflectInfo.Struct key _ _ _) (AstType.Struct (intern key))]
    [(CtfeReflectInfo.Enum key _ _ _) (AstType.Enum (intern key))]))

(define (ctfe-reflect-resolve-type-list-with-pools
  [pools : AstNodePoolContext]
  [infos : CtfeReflectInfoList]
  [types : AstTypeList]) : AstTypeList
  (let
    [out : AstTypeList
      (ast-type-list-with-capacity (ast-type-list-len (& types)))]
    (begin
      (ctfe-reflect-resolve-type-list-with-pools-into
        pools
        infos
        (& types)
        (&mut out)
        0)
      out)))

(define (ctfe-reflect-resolve-type-list-with-pools-into
  [pools : AstNodePoolContext]
  [infos : CtfeReflectInfoList]
  [types : (& types AstTypeList)]
  [out : (&mut out AstTypeList)]
  [index : i64]) : unit
  (if (>= index (ast-type-list-len types))
    unit
    (begin
      (ast-type-list-push
        out
        (ast-node-pool-context-type-push
          pools
          (ctfe-reflect-resolve-type-with-pools
            pools
            infos
            (ast-node-pool-context-type-get
              pools
              (ast-type-list-get types index (ast-type-id-fallback))))))
      (ctfe-reflect-resolve-type-list-with-pools-into
        pools
        infos
        types
        out
        (+ index 1)))))

(define (ctfe-reflect-resolve-type-list
  [infos : CtfeReflectInfoList]
  [types : AstTypeList]) : AstTypeList
  (ctfe-reflect-resolve-type-list-with-pools
    (ast-node-pool-context-capture-active)
    infos
    types))

(define (ctfe-reflect-resolve-type-with-pools
  [pools : AstNodePoolContext]
  [infos : CtfeReflectInfoList]
  [ty : AstType]) : AstType
  (match ty
    [(AstType.Func args ret)
      (ast-ty-func-with-pools
        pools
        (ctfe-reflect-resolve-type-list-with-pools pools infos (box-get args))
        (ctfe-reflect-resolve-type-with-pools
          pools
          infos
          (ast-node-pool-context-type-get pools ret)))]
    [(AstType.Tuple elems)
      (ast-ty-tuple
        (ctfe-reflect-resolve-type-list-with-pools pools infos (box-get elems)))]
    [(AstType.Array elem len)
      (ast-ty-array-with-pools
        pools
        (ctfe-reflect-resolve-type-with-pools
          pools
          infos
          (ast-node-pool-context-type-get pools elem))
        len)]
    [(AstType.DynArray elem)
      (ast-ty-dyn-array-with-pools
        pools
        (ctfe-reflect-resolve-type-with-pools
          pools
          infos
          (ast-node-pool-context-type-get pools elem)))]
    [(AstType.Box elem)
      (ast-ty-box-with-pools
        pools
        (ctfe-reflect-resolve-type-with-pools
          pools
          infos
          (ast-node-pool-context-type-get pools elem)))]
    [(AstType.Ptr elem)
      (ast-ty-ptr-with-pools
        pools
        (ctfe-reflect-resolve-type-with-pools
          pools
          infos
          (ast-node-pool-context-type-get pools elem)))]
    [(AstType.MutPtr elem)
      (ast-ty-mut-ptr-with-pools
        pools
        (ctfe-reflect-resolve-type-with-pools
          pools
          infos
          (ast-node-pool-context-type-get pools elem)))]
    [(AstType.Ref region inner)
      (ast-ty-ref-with-pools
        pools
        region
        (ctfe-reflect-resolve-type-with-pools
          pools
          infos
          (ast-node-pool-context-type-get pools inner)))]
    [(AstType.MutRef region inner)
      (ast-ty-mut-ref-with-pools
        pools
        region
        (ctfe-reflect-resolve-type-with-pools
          pools
          infos
          (ast-node-pool-context-type-get pools inner)))]
    [(AstType.Region region inner)
      (ast-ty-region-with-pools
        pools
        region
        (ctfe-reflect-resolve-type-with-pools
          pools
          infos
          (ast-node-pool-context-type-get pools inner)))]
    [(AstType.Struct name)
      (match (ctfe-reflect-info-lookup infos (intern-str name))
        [(CtfeMaybeReflectInfo.Some info)
          (ctfe-reflect-info-canonical-type info)]
        [(CtfeMaybeReflectInfo.None) ty])]
    [(AstType.Enum name)
      (match (ctfe-reflect-info-lookup infos (intern-str name))
        [(CtfeMaybeReflectInfo.Some info)
          (ctfe-reflect-info-canonical-type info)]
        [(CtfeMaybeReflectInfo.None) ty])]
    [(AstType.Var name)
      (match (ctfe-reflect-info-lookup infos (intern-str name))
        [(CtfeMaybeReflectInfo.Some info)
          (ctfe-reflect-info-canonical-type info)]
        [(CtfeMaybeReflectInfo.None) ty])]
    [_ ty]))

(define (ctfe-reflect-resolve-type [infos : CtfeReflectInfoList] [ty : AstType]) : AstType
  (ctfe-reflect-resolve-type-with-pools
    (ast-node-pool-context-capture-active)
    infos
    ty))

(define (ctfe-int-key [n : i64]) : String
  (if (< n 0)
    (string.append "m" (string.int->string (- 0 n)))
    (string.int->string n)))

(define (ctfe-type-list-key-with-pools
  [pools : AstNodePoolContext]
  [infos : CtfeReflectInfoList]
  [types : AstTypeList]) : String
  (ctfe-type-list-key-with-pools-at pools infos (& types) 0))

(define (ctfe-type-list-key-with-pools-at
  [pools : AstNodePoolContext]
  [infos : CtfeReflectInfoList]
  [types : (& types AstTypeList)]
  [index : i64]) : String
  (if (>= index (ast-type-list-len types))
    "nil"
    (string.append
      (ctfe-type-key-with-reflections-and-pools
        pools
        infos
        (ast-node-pool-context-type-get
          pools
          (ast-type-list-get types index (ast-type-id-fallback))))
      (string.append
        "_"
        (ctfe-type-list-key-with-pools-at pools infos types (+ index 1))))))

(define (ctfe-type-list-key [infos : CtfeReflectInfoList] [types : AstTypeList]) : String
  (ctfe-type-list-key-with-pools
    (ast-node-pool-context-capture-active)
    infos
    types))

(define (ctfe-lifetime-list-key-at
  [lifetimes : (& lifetimes AstLifetimeList)]
  [index : i64]) : String
  (if (>= index (ast-lifetime-list-len lifetimes))
    "nil"
    (string.append
      (ast-lifetime-list-get lifetimes index (ast-lifetime-fallback))
      (string.append "_" (ctfe-lifetime-list-key-at lifetimes (+ index 1))))))

(define (ctfe-lifetime-list-key [lifetimes : AstLifetimeList]) : String
  (ctfe-lifetime-list-key-at (& lifetimes) 0))

(define (ctfe-lifetime-list-eq-at
  [a : (& a AstLifetimeList)]
  [b : (& b AstLifetimeList)]
  [index : i64]) : bool
  (if (>= index (ast-lifetime-list-len a))
    true
    (and
      (string.eq
        (ast-lifetime-list-get a index (ast-lifetime-fallback))
        (ast-lifetime-list-get b index (ast-lifetime-fallback)))
      (ctfe-lifetime-list-eq-at a b (+ index 1)))))

(define (ctfe-lifetime-list-eq [a : AstLifetimeList] [b : AstLifetimeList]) : bool
  (and
    (= (ast-lifetime-list-len (& a)) (ast-lifetime-list-len (& b)))
    (ctfe-lifetime-list-eq-at (& a) (& b) 0)))

(define (ctfe-type-key-with-reflections-and-pools
  [pools : AstNodePoolContext]
  [infos : CtfeReflectInfoList]
  [ty : AstType]) : String
  (match (ctfe-reflect-resolve-type-with-pools pools infos ty)
    [(AstType.I64) "i64"]
    [(AstType.I32) "i32"]
    [(AstType.I16) "i16"]
    [(AstType.I8) "i8"]
    [(AstType.U64) "u64"]
    [(AstType.U32) "u32"]
    [(AstType.U16) "u16"]
    [(AstType.U8) "u8"]
    [(AstType.F64) "f64"]
    [(AstType.F32) "f32"]
    [(AstType.Bool) "bool"]
    [(AstType.Char) "char"]
    [(AstType.String) "String"]
    [(AstType.Str) "str"]
    [(AstType.Bytes) "bytes"]
    [(AstType.Expr) "Expr"]
    [(AstType.ExprList) "ExprList"]
    [(AstType.Unit) "unit"]
    [(AstType.Never) "never"]
    [(AstType.Func args ret)
      (string.append
        "fn_"
        (string.append
          (ctfe-type-list-key-with-pools pools infos (box-get args))
          (string.append
            "_to_"
            (ctfe-type-key-with-reflections-and-pools
              pools
              infos
              (ast-node-pool-context-type-get pools ret)))))]
    [(AstType.Tuple elems)
      (string.append
        "tuple_"
        (ctfe-type-list-key-with-pools pools infos (box-get elems)))]
    [(AstType.Array elem count)
      (string.append
        "array_"
        (string.append
          (ctfe-type-key-with-reflections-and-pools
            pools
            infos
            (ast-node-pool-context-type-get pools elem))
          (string.append "_" (ctfe-int-key count))))]
    [(AstType.DynArray elem)
      (string.append
        "dynarray_"
        (ctfe-type-key-with-reflections-and-pools
          pools
          infos
          (ast-node-pool-context-type-get pools elem)))]
    [(AstType.Box elem)
      (string.append
        "box_"
        (ctfe-type-key-with-reflections-and-pools
          pools
          infos
          (ast-node-pool-context-type-get pools elem)))]
    [(AstType.Ptr elem)
      (string.append
        "ptr_"
        (ctfe-type-key-with-reflections-and-pools
          pools
          infos
          (ast-node-pool-context-type-get pools elem)))]
    [(AstType.MutPtr elem)
      (string.append
        "mutptr_"
        (ctfe-type-key-with-reflections-and-pools
          pools
          infos
          (ast-node-pool-context-type-get pools elem)))]
    [(AstType.Ref region inner)
      (string.append
        "ref_"
        (string.append
          region
          (string.append
            "_"
            (ctfe-type-key-with-reflections-and-pools
              pools
              infos
              (ast-node-pool-context-type-get pools inner)))))]
    [(AstType.MutRef region inner)
      (string.append
        "mutref_"
        (string.append
          region
          (string.append
            "_"
            (ctfe-type-key-with-reflections-and-pools
              pools
              infos
              (ast-node-pool-context-type-get pools inner)))))]
    [(AstType.Region region inner)
      (string.append
        "region_"
        (string.append
          region
          (string.append
            "_"
            (ctfe-type-key-with-reflections-and-pools
              pools
              infos
              (ast-node-pool-context-type-get pools inner)))))]
    [(AstType.Enum name) (string.append "enum_" (intern-str name))]
    [(AstType.EnumArgs name lifetimes)
      (string.append
        "enumargs_"
        (string.append
          (intern-str name)
          (string.append "_" (ctfe-lifetime-list-key (box-get lifetimes)))))]
    [(AstType.Struct name) (string.append "struct_" (intern-str name))]
    [(AstType.StructArgs name lifetimes)
      (string.append
        "structargs_"
        (string.append
          (intern-str name)
          (string.append "_" (ctfe-lifetime-list-key (box-get lifetimes)))))]
    [(AstType.Var name) (string.append "var_" (intern-str name))]
    [(AstType.VarArgs name lifetimes)
      (string.append
        "varargs_"
        (string.append
          (intern-str name)
          (string.append "_" (ctfe-lifetime-list-key (box-get lifetimes)))))]))

(define (ctfe-type-key-with-reflections
  [infos : CtfeReflectInfoList]
  [ty : AstType]) : String
  (ctfe-type-key-with-reflections-and-pools
    (ast-node-pool-context-capture-active)
    infos
    ty))

(define (ctfe-type-key [ty : AstType]) : String
  (ctfe-type-key-with-reflections (ctfe-reflect-info-list-empty) ty))

(define (ctfe-type-kind-with-reflections-and-pools
  [pools : AstNodePoolContext]
  [infos : CtfeReflectInfoList]
  [ty : AstType]) : String
  (match (ctfe-reflect-resolve-type-with-pools pools infos ty)
    [(AstType.I64) "i64"]
    [(AstType.I32) "i32"]
    [(AstType.I16) "i16"]
    [(AstType.I8) "i8"]
    [(AstType.U64) "u64"]
    [(AstType.U32) "u32"]
    [(AstType.U16) "u16"]
    [(AstType.U8) "u8"]
    [(AstType.F64) "f64"]
    [(AstType.F32) "f32"]
    [(AstType.Bool) "bool"]
    [(AstType.Char) "char"]
    [(AstType.String) "string"]
    [(AstType.Str) "str"]
    [(AstType.Bytes) "bytes"]
    [(AstType.Expr) "expr"]
    [(AstType.ExprList) "expr-list"]
    [(AstType.Unit) "unit"]
    [(AstType.Never) "never"]
    [(AstType.Func _ _) "function"]
    [(AstType.Tuple _) "tuple"]
    [(AstType.Array _ _) "array"]
    [(AstType.DynArray _) "dyn-array"]
    [(AstType.Box _) "box"]
    [(AstType.Ptr _) "ptr"]
    [(AstType.MutPtr _) "mut-ptr"]
    [(AstType.Ref _ _) "ref"]
    [(AstType.MutRef _ _) "mut-ref"]
    [(AstType.Region _ _) "region"]
    [(AstType.Enum _) "enum"]
    [(AstType.EnumArgs _ _) "enum"]
    [(AstType.Struct _) "struct"]
    [(AstType.StructArgs _ _) "struct"]
    [(AstType.Var _) "type-var"]
    [(AstType.VarArgs _ _) "type-var"]))

(define (ctfe-type-kind-with-reflections
  [infos : CtfeReflectInfoList]
  [ty : AstType]) : String
  (ctfe-type-kind-with-reflections-and-pools
    (ast-node-pool-context-capture-active)
    infos
    ty))

(define (ctfe-eval-type-arg
  [arg : AstExpr]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]
  [name : String]) : ResultCtfeTypeArg
  (match (compiler-ctfe-eval arg env fuel)
    [(ResultCtfe.Err d) (ResultCtfeTypeArg.Err d)]
    [(ResultCtfe.Ok value arg-fuel)
      (match value
        [(CompilerCtfeValue.Type ty)
          (ResultCtfeTypeArg.Ok
            (ctfe-reflect-resolve-type-with-pools
              (ctfe-env-pools env)
              (ctfe-env-reflections env)
              ty)
            arg-fuel)]
        [_
          (ResultCtfeTypeArg.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                (string.append name " expects a type argument"))))])]))

(define (ctfe-eval-i64-arg
  [arg : AstExpr]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]
  [name : String]) : result_ctfe_i64_arg.Result
  (match (compiler-ctfe-eval arg env fuel)
    [(ResultCtfe.Err d) (result_ctfe_i64_arg.Err d)]
    [(ResultCtfe.Ok value arg-fuel)
      (match value
        [(CompilerCtfeValue.I64 n)
          (result_ctfe_i64_arg.Ok (CtfeI64Arg n arg-fuel))]
        [_
          (result_ctfe_i64_arg.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                (string.append name " expects an i64 index"))))])]))

(define (ctfe-eval-string-arg
  [arg : AstExpr]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]
  [name : String]) : ResultCtfeStringArg
  (match (compiler-ctfe-eval arg env fuel)
    [(ResultCtfe.Err d) (ResultCtfeStringArg.Err d)]
    [(ResultCtfe.Ok value arg-fuel)
      (match value
        [(CompilerCtfeValue.String text) (ResultCtfeStringArg.Ok text arg-fuel)]
        [_
          (ResultCtfeStringArg.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                (string.append name " expects a String argument"))))])]))

(define (ctfe-expr-arg-count [args : AstExprList]) : i64
  (struct-get (& args) len))

(define (ctfe-expr-arg [args : AstExprList] [index : i64] [env : CtfeEnv]) : AstExpr
  (ctfe-ast-get env (ast-expr-list-get (& args) index 0)))

(define (ctfe-reflect-field-list-count [fields : CtfeReflectFieldList]) : i64
  (struct-get fields len))

(define (ctfe-reflect-field-name-at
  [fields : CtfeReflectFieldList]
  [index : i64]) : ResultCtfeStringLookup
  (if (if (< index 0)
    true
    (>= index (struct-get fields len)))
    (ResultCtfeStringLookup.Err "index out of range")
    (match (ctfe-reflect-field-list-ref fields index)
      [(CtfeReflectField.Field name _) (ResultCtfeStringLookup.Ok name)])))

(define (ctfe-reflect-field-type-at
  [fields : CtfeReflectFieldList]
  [pools : AstNodePoolContext]
  [infos : CtfeReflectInfoList]
  [index : i64]) : ResultCtfeTypeLookup
  (if (if (< index 0)
    true
    (>= index (struct-get fields len)))
    (ResultCtfeTypeLookup.Err "index out of range")
    (match (ctfe-reflect-field-list-ref fields index)
      [(CtfeReflectField.Field _ ty)
        (ResultCtfeTypeLookup.Ok
          (ctfe-reflect-resolve-type-with-pools pools infos ty))])))

(define (ctfe-reflect-variant-list-count [variants : CtfeReflectVariantList]) : i64
  (struct-get variants len))

(define (ctfe-reflect-variant-name-at
  [variants : CtfeReflectVariantList]
  [index : i64]) : ResultCtfeStringLookup
  (if (if (< index 0)
    true
    (>= index (struct-get variants len)))
    (ResultCtfeStringLookup.Err "index out of range")
    (match (ctfe-reflect-variant-list-ref variants index)
      [(CtfeReflectVariant.Variant name _) (ResultCtfeStringLookup.Ok name)])))

(define (ctfe-reflect-variant-payloads-at
  [variants : CtfeReflectVariantList]
  [index : i64]) : ResultCtfeTypeListLookup
  (if (if (< index 0)
    true
    (>= index (struct-get variants len)))
    (ResultCtfeTypeListLookup.Err "index out of range")
    (match (ctfe-reflect-variant-list-ref variants index)
      [(CtfeReflectVariant.Variant _ payloads)
        (ResultCtfeTypeListLookup.Ok payloads)])))

(define (ctfe-type-list-count [types : AstTypeList]) : i64
  (ast-type-list-len (& types)))

(define (ctfe-type-list-ref-with-pools
  [types : AstTypeList]
  [pools : AstNodePoolContext]
  [infos : CtfeReflectInfoList]
  [index : i64]) : ResultCtfeTypeLookup
  (if (< index 0)
    (ResultCtfeTypeLookup.Err "index out of range")
    (if (>= index (ast-type-list-len (& types)))
      (ResultCtfeTypeLookup.Err "index out of range")
      (ResultCtfeTypeLookup.Ok
        (ctfe-reflect-resolve-type-with-pools
          pools
          infos
          (ast-node-pool-context-type-get
            pools
            (ast-type-list-get (& types) index (ast-type-id-fallback))))))))

(define (ctfe-type-list-ref
  [types : AstTypeList]
  [infos : CtfeReflectInfoList]
  [index : i64]) : ResultCtfeTypeLookup
  (ctfe-type-list-ref-with-pools
    types
    (ast-node-pool-context-capture-active)
    infos
    index))

(define (ctfe-type-info-builtin-kind? [kind : String]) : bool
  (cond
    [(string.eq kind "i64") true]
    [(string.eq kind "i32") true]
    [(string.eq kind "i16") true]
    [(string.eq kind "i8") true]
    [(string.eq kind "u64") true]
    [(string.eq kind "u32") true]
    [(string.eq kind "u16") true]
    [(string.eq kind "u8") true]
    [(string.eq kind "f64") true]
    [(string.eq kind "f32") true]
    [(string.eq kind "bool") true]
    [(string.eq kind "char") true]
    [(string.eq kind "string") true]
    [(string.eq kind "unit") true]
    [else (string.eq kind "never")]))

(define (ctfe-type-info-key-in-env [env : CtfeEnv] [ty : AstType]) : String
  (ctfe-type-key-with-reflections-and-pools
    (ctfe-env-pools env)
    (ctfe-env-reflections env)
    ty))

(define (ctfe-match-type-info-opaque
  [variant : i64]
  [args : AstPatternList]
  [ty : AstType]
  [env : CtfeEnv]) : CtfePatternMatch
  (if (ctfe-pattern-variant-name? variant "TypeInfoOpaque")
    (ctfe-match-pattern-list
      args
      (ctfe-value-list1
        (CompilerCtfeValue.String (ctfe-type-info-key-in-env env ty)))
      env)
    (CtfePatternMatch.No)))

(define (ctfe-match-type-info-nominal
  [variant : i64]
  [args : AstPatternList]
  [ty : AstType]
  [env : CtfeEnv]
  [want-struct : bool]) : CtfePatternMatch
  (let
    [infos : CtfeReflectInfoList (ctfe-env-reflections env)]
    [key : String (ctfe-type-nominal-key ty)]
    (match (ctfe-reflect-info-lookup infos key)
      [(CtfeMaybeReflectInfo.Some info)
        (match info
          [(CtfeReflectInfo.Struct _ _ _ fields)
            (if want-struct
              (if (ctfe-pattern-variant-name? variant "TypeInfoStruct")
                (ctfe-match-pattern-list
                  args
                  (ctfe-value-list2
                    (CompilerCtfeValue.String
                      (ctfe-type-info-key-in-env env ty))
                    (CompilerCtfeValue.TypeFieldList fields))
                  env)
                (CtfePatternMatch.No))
              (CtfePatternMatch.No))]
          [(CtfeReflectInfo.Enum _ _ _ variants)
            (if want-struct
              (CtfePatternMatch.No)
              (if (ctfe-pattern-variant-name? variant "TypeInfoEnum")
                (ctfe-match-pattern-list
                  args
                  (ctfe-value-list2
                    (CompilerCtfeValue.String
                      (ctfe-type-info-key-in-env env ty))
                    (CompilerCtfeValue.TypeVariantList variants))
                  env)
                (CtfePatternMatch.No)))])]
      [(CtfeMaybeReflectInfo.None)
        (ctfe-match-type-info-opaque variant args ty env)])))

(define (ctfe-match-type-info-variant
  [variant : i64]
  [args : AstPatternList]
  [ty : AstType]
  [env : CtfeEnv]) : CtfePatternMatch
  (let
    [pools : AstNodePoolContext (ctfe-env-pools env)]
    [infos : CtfeReflectInfoList (ctfe-env-reflections env)]
    [resolved : AstType (ctfe-reflect-resolve-type-with-pools pools infos ty)]
    [kind : String
      (ctfe-type-kind-with-reflections-and-pools pools infos resolved)]
    (match resolved
      [(AstType.Array elem count)
        (if (ctfe-pattern-variant-name? variant "TypeInfoArray")
          (ctfe-match-pattern-list
            args
            (ctfe-value-list2
              (CompilerCtfeValue.TypeInfoBox
                (ast-node-pool-context-type-get pools elem))
              (CompilerCtfeValue.I64 count))
            env)
          (CtfePatternMatch.No))]
      [(AstType.DynArray elem)
        (if (ctfe-pattern-variant-name? variant "TypeInfoDynArray")
          (ctfe-match-pattern-list
            args
            (ctfe-value-list1
              (CompilerCtfeValue.TypeInfoBox
                (ast-node-pool-context-type-get pools elem)))
            env)
          (CtfePatternMatch.No))]
      [(AstType.Func params ret)
        (if (ctfe-pattern-variant-name? variant "TypeInfoFunction")
          (ctfe-match-pattern-list
            args
            (ctfe-value-list2
              (CompilerCtfeValue.TypeInfoList (box-get params))
              (CompilerCtfeValue.TypeInfoBox
                (ast-node-pool-context-type-get pools ret)))
            env)
          (CtfePatternMatch.No))]
      [(AstType.Tuple elems)
        (if (ctfe-pattern-variant-name? variant "TypeInfoTuple")
          (ctfe-match-pattern-list
            args
            (ctfe-value-list1 (CompilerCtfeValue.TypeInfoList (box-get elems)))
            env)
          (CtfePatternMatch.No))]
      [(AstType.Struct _)
        (ctfe-match-type-info-nominal variant args resolved env true)]
      [(AstType.StructArgs _ _)
        (ctfe-match-type-info-nominal variant args resolved env true)]
      [(AstType.Enum _)
        (ctfe-match-type-info-nominal variant args resolved env false)]
      [(AstType.EnumArgs _ _)
        (ctfe-match-type-info-nominal variant args resolved env false)]
      [_
        (if (ctfe-type-info-builtin-kind? kind)
          (if (ctfe-pattern-variant-name? variant "TypeInfoBuiltin")
            (ctfe-match-pattern-list
              args
              (ctfe-value-list1 (CompilerCtfeValue.String kind))
              env)
            (CtfePatternMatch.No))
          (ctfe-match-type-info-opaque variant args resolved env))])))

;; --- core evaluator ---------------------------------------------------------
;; Evaluate `expr` under `env` with the given remaining `fuel`. Each call
;; charges one unit of fuel up front (mirroring `use_fuel`); when fuel is
;; exhausted the evaluation fails deterministically.
(define (compiler-ctfe-eval [expr : AstExpr] [env : CtfeEnv] [fuel : i64]) : ResultCtfe
  (if (<= fuel 0)
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr expr "compile-time evaluation limit exceeded")))
    (ctfe-eval-node expr env (- fuel 1))))

(define (ctfe-eval-node [expr : AstExpr] [env : CtfeEnv] [fuel : i64]) : ResultCtfe
  (match expr
    [(AstExpr.Spanned inner-box _)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (compiler-ctfe-eval inner env fuel))]
    [(AstExpr.Comptime inner-box)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (compiler-ctfe-eval inner env fuel))]
    [(AstExpr.Ann inner-box _)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (compiler-ctfe-eval inner env fuel))]
    [(AstExpr.Cast inner-box ty)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (ctfe-eval-cast inner ty expr env fuel))]
    [(AstExpr.TypeLiteral ty)
      (ResultCtfe.Ok
        (CompilerCtfeValue.Type
          (ctfe-reflect-resolve-type-with-pools
            (ctfe-env-pools env)
            (ctfe-env-reflections env)
            ty))
        fuel)]
    [(AstExpr.Init _)
      (ResultCtfe.Err
        (box
          (ctfe-diagnostic-at-expr
            expr
            "comptime: init is a runtime-only expression")))]
    [(AstExpr.Literal lit) (ctfe-eval-literal lit expr fuel)]
    [(AstExpr.Var name) (ctfe-eval-var (intern-str name) expr env fuel)]
    [(AstExpr.Binary op left-box right-box)
      (let
        [left : AstExpr (ctfe-ast-get env left-box)]
        [right : AstExpr (ctfe-ast-get env right-box)]
        (ctfe-eval-binary op left right expr env fuel))]
    [(AstExpr.Unary op inner-box)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (ctfe-eval-unary op inner expr env fuel))]
    [(AstExpr.If cond-box then-branch-box else-branch-box)
      (let
        [cond : AstExpr (ctfe-ast-get env cond-box)]
        [then-branch : AstExpr (ctfe-ast-get env then-branch-box)]
        [else-branch : AstExpr (ctfe-ast-get env else-branch-box)]
        (ctfe-eval-if cond then-branch else-branch env fuel))]
    [(AstExpr.Let let-box)
      (match (box-get let-box)
        [(AstLet.Let bindings body-box)
          (let
            [body : AstExpr (ctfe-ast-get env body-box)]
            (ctfe-eval-let bindings body env fuel))])]
    [(AstExpr.Begin exprs) (ctfe-eval-begin exprs env fuel)]
    [(AstExpr.Unsafe exprs) (ctfe-eval-begin exprs env fuel)]
    [(AstExpr.Match match-box)
      (match (box-get match-box)
        [(AstMatch.Match scrutinee-box arms)
          (let
            [scrutinee : AstExpr (ctfe-ast-get env scrutinee-box)]
            (ctfe-eval-match scrutinee arms expr env fuel))])]
    [(AstExpr.Call func-box args)
      (let
        [func : AstExpr (ctfe-ast-get env func-box)]
        (ctfe-eval-call func args expr env fuel))]
    [(AstExpr.BoxGet inner-box)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (ctfe-eval-box-get inner expr env fuel))]
    [(AstExpr.BoxTake inner-box)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (ctfe-eval-box-get inner expr env fuel))]
    [(AstExpr.StructGet inner-box field)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (ctfe-eval-struct-get inner field expr env fuel))]
    [(AstExpr.ArrayRef array-box index-box)
      (let
        [array : AstExpr (ctfe-ast-get env array-box)]
        [index : AstExpr (ctfe-ast-get env index-box)]
        (ctfe-eval-array-ref array index expr env fuel))]
    [(AstExpr.Quote template-box)
      (let
        [template : AstExpr (ctfe-ast-get env template-box)]
        (ctfe-eval-quote template env fuel false))]
    [(AstExpr.Quasiquote template-box)
      (let
        [template : AstExpr (ctfe-ast-get env template-box)]
        (ctfe-eval-quote template env fuel true))]
    [(AstExpr.Unquote _)
      (ResultCtfe.Err
        (box
          (ctfe-diagnostic-at-expr
            expr
            "unquote is only valid inside quasiquote")))]
    [(AstExpr.UnquoteSplicing _)
      (ResultCtfe.Err
        (box
          (ctfe-diagnostic-at-expr
            expr
            "unquote-splicing is only valid inside quasiquote")))]
    [_
      (ResultCtfe.Err
        (box
          (ctfe-diagnostic-at-expr
            expr
            (string.append
              "'"
              (string.append
                (ctfe-describe-expr expr)
                "' is not supported in compile-time evaluation")))))]))

;; Type size / alignment in bytes for CTFE layout queries. Builtins mirror the
;; lowerer ABI; user-defined names come from the layout table carried in `env`.
;; Unresolved type variables without a table entry return -1 so callers can
;; produce a source-located diagnostic instead of inventing runtime metadata.
(define (ctfe-type-size-with-pools
  [pools : AstNodePoolContext]
  [layouts : CtfeLayoutInfoList]
  [ty : AstType]) : i64
  (match ty
    [(AstType.I64) 8]
    [(AstType.U64) 8]
    [(AstType.F64) 8]
    [(AstType.I32) 4]
    [(AstType.U32) 4]
    [(AstType.F32) 4]
    [(AstType.I16) 2]
    [(AstType.U16) 2]
    [(AstType.I8) 1]
    [(AstType.U8) 1]
    [(AstType.Bool) 1]
    [(AstType.Char) 1]
    [(AstType.Unit) 0]
    [(AstType.Never) 0]
    [(AstType.Str) -1]
    [(AstType.Bytes) -1]
    [(AstType.Expr) -1]
    [(AstType.ExprList) -1]
    [(AstType.Func _ _) 8]
    [(AstType.Tuple _) 8]
    [(AstType.Array elem count)
      (let
        [elem-size : i64
          (ctfe-type-size-with-pools
            pools
            layouts
            (ast-node-pool-context-type-get pools elem))]
        (if (< elem-size 0)
          -1
          (* elem-size count)))]
    [(AstType.DynArray _) 8]
    [(AstType.Box _) 8]
    [(AstType.Ptr _) 8]
    [(AstType.MutPtr _) 8]
    [(AstType.Ref _ _) 8]
    [(AstType.MutRef _ _) 8]
    [(AstType.Region _ inner)
      (ctfe-type-size-with-pools
        pools
        layouts
        (ast-node-pool-context-type-get pools inner))]
    [(AstType.Enum _) 8]
    [(AstType.EnumArgs _ _) 8]
    [(AstType.Struct name)
      (match (ctfe-layout-info-lookup layouts (intern-str name))
        [(CtfeMaybeLayoutInfo.Some info)
          (match info
            [(CtfeLayoutInfo.Info _ _ size _ _) size])]
        [(CtfeMaybeLayoutInfo.None) 8])]
    [(AstType.StructArgs name _)
      (match (ctfe-layout-info-lookup layouts (intern-str name))
        [(CtfeMaybeLayoutInfo.Some info)
          (match info
            [(CtfeLayoutInfo.Info _ _ size _ _) size])]
        [(CtfeMaybeLayoutInfo.None) 8])]
    [(AstType.String) 8]
    [(AstType.Var name)
      (match (ctfe-layout-info-lookup layouts (intern-str name))
        [(CtfeMaybeLayoutInfo.Some info)
          (match info
            [(CtfeLayoutInfo.Info _ _ size _ _) size])]
        [(CtfeMaybeLayoutInfo.None) -1])]
    [(AstType.VarArgs name _)
      (match (ctfe-layout-info-lookup layouts (intern-str name))
        [(CtfeMaybeLayoutInfo.Some info)
          (match info
            [(CtfeLayoutInfo.Info _ _ size _ _) size])]
        [(CtfeMaybeLayoutInfo.None) -1])]))

(define (ctfe-type-size [layouts : CtfeLayoutInfoList] [ty : AstType]) : i64
  (ctfe-type-size-with-pools (ast-node-pool-context-capture-active) layouts ty))

(define (ctfe-type-align-with-pools
  [pools : AstNodePoolContext]
  [layouts : CtfeLayoutInfoList]
  [ty : AstType]) : i64
  (match ty
    [(AstType.I64) 8]
    [(AstType.U64) 8]
    [(AstType.F64) 8]
    [(AstType.I32) 4]
    [(AstType.U32) 4]
    [(AstType.F32) 4]
    [(AstType.I16) 2]
    [(AstType.U16) 2]
    [(AstType.I8) 1]
    [(AstType.U8) 1]
    [(AstType.Bool) 1]
    [(AstType.Char) 1]
    [(AstType.Unit) 1]
    [(AstType.Never) 1]
    [(AstType.Str) -1]
    [(AstType.Bytes) -1]
    [(AstType.Expr) -1]
    [(AstType.ExprList) -1]
    [(AstType.Func _ _) 8]
    [(AstType.Tuple _) 8]
    [(AstType.Array elem _)
      (ctfe-type-align-with-pools
        pools
        layouts
        (ast-node-pool-context-type-get pools elem))]
    [(AstType.DynArray _) 8]
    [(AstType.Box _) 8]
    [(AstType.Ptr _) 8]
    [(AstType.MutPtr _) 8]
    [(AstType.Ref _ _) 8]
    [(AstType.MutRef _ _) 8]
    [(AstType.Region _ inner)
      (ctfe-type-align-with-pools
        pools
        layouts
        (ast-node-pool-context-type-get pools inner))]
    [(AstType.Enum _) 8]
    [(AstType.EnumArgs _ _) 8]
    [(AstType.Struct name)
      (match (ctfe-layout-info-lookup layouts (intern-str name))
        [(CtfeMaybeLayoutInfo.Some info)
          (match info
            [(CtfeLayoutInfo.Info _ _ _ align _) align])]
        [(CtfeMaybeLayoutInfo.None) 8])]
    [(AstType.StructArgs name _)
      (match (ctfe-layout-info-lookup layouts (intern-str name))
        [(CtfeMaybeLayoutInfo.Some info)
          (match info
            [(CtfeLayoutInfo.Info _ _ _ align _) align])]
        [(CtfeMaybeLayoutInfo.None) 8])]
    [(AstType.String) 8]
    [(AstType.Var name)
      (match (ctfe-layout-info-lookup layouts (intern-str name))
        [(CtfeMaybeLayoutInfo.Some info)
          (match info
            [(CtfeLayoutInfo.Info _ _ _ align _) align])]
        [(CtfeMaybeLayoutInfo.None) -1])]
    [(AstType.VarArgs name _)
      (match (ctfe-layout-info-lookup layouts (intern-str name))
        [(CtfeMaybeLayoutInfo.Some info)
          (match info
            [(CtfeLayoutInfo.Info _ _ _ align _) align])]
        [(CtfeMaybeLayoutInfo.None) -1])]))

(define (ctfe-type-align [layouts : CtfeLayoutInfoList] [ty : AstType]) : i64
  (ctfe-type-align-with-pools (ast-node-pool-context-capture-active) layouts ty))

(define (ctfe-layout-query-value-with-pools
  [pools : AstNodePoolContext]
  [name : String]
  [layouts : CtfeLayoutInfoList]
  [ty : AstType]) : i64
  (if (string.eq name "size-of")
    (ctfe-type-size-with-pools pools layouts ty)
    (ctfe-type-align-with-pools pools layouts ty)))

(define (ctfe-layout-query-value
  [name : String]
  [layouts : CtfeLayoutInfoList]
  [ty : AstType]) : i64
  (ctfe-layout-query-value-with-pools
    (ast-node-pool-context-capture-active)
    name
    layouts
    ty))

;; Evaluate `(size-of (type T))` / `(align-of (type T))` to an `i64` in comptime.
(define (ctfe-eval-size-align-query
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [arg : AstExpr (ctfe-expr-arg args 0 env)]
      (match (compiler-ctfe-eval arg env fuel)
        [(ResultCtfe.Err d) (ResultCtfe.Err d)]
        [(ResultCtfe.Ok value arg-fuel)
          (match value
            [(CompilerCtfeValue.Type ty)
              (let
                [answer : i64
                  (ctfe-layout-query-value-with-pools
                    (ctfe-env-pools env)
                    name
                    (ctfe-env-layouts env)
                    ty)]
                (if (< answer 0)
                  (ResultCtfe.Err
                    (box
                      (ctfe-diagnostic-at-expr
                        expr
                        (string.append name " expects a known type argument"))))
                  (ResultCtfe.Ok (CompilerCtfeValue.I64 answer) arg-fuel)))]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    (string.append name " expects a type argument"))))])]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          (string.append name " expects exactly one type argument"))))))

(define (ctfe-offset-field-name [expr : AstExpr] [env : CtfeEnv]) : CtfeMaybeFieldName
  (match expr
    [(AstExpr.Spanned inner-box _)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (ctfe-offset-field-name inner env))]
    [(AstExpr.Var name) (CtfeMaybeFieldName.Some (intern-str name))]
    [_ (CtfeMaybeFieldName.None)]))

(define (ctfe-layout-info-for-type-with-pools
  [pools : AstNodePoolContext]
  [layouts : CtfeLayoutInfoList]
  [ty : AstType]) : CtfeMaybeLayoutInfo
  (match ty
    [(AstType.Struct name) (ctfe-layout-info-lookup layouts (intern-str name))]
    [(AstType.StructArgs name _)
      (ctfe-layout-info-lookup layouts (intern-str name))]
    [(AstType.Enum name) (ctfe-layout-info-lookup layouts (intern-str name))]
    [(AstType.EnumArgs name _)
      (ctfe-layout-info-lookup layouts (intern-str name))]
    [(AstType.Var name) (ctfe-layout-info-lookup layouts (intern-str name))]
    [(AstType.Region _ inner)
      (ctfe-layout-info-for-type-with-pools
        pools
        layouts
        (ast-node-pool-context-type-get pools inner))]
    [_ (CtfeMaybeLayoutInfo.None)]))

(define (ctfe-layout-info-for-type
  [layouts : CtfeLayoutInfoList]
  [ty : AstType]) : CtfeMaybeLayoutInfo
  (ctfe-layout-info-for-type-with-pools
    (ast-node-pool-context-capture-active)
    layouts
    ty))

;; Evaluate `(offset-of (type Struct) field)` to the field byte offset.
;; The field name is intentionally syntactic: a bare variable names the field
;; and is not resolved as a runtime/comptime variable.
(define (ctfe-eval-offset-from-layout
  [field-name : String]
  [info : CtfeLayoutInfo]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (match info
    [(CtfeLayoutInfo.Info _ repr-c? _ _ fields)
      (if repr-c?
        (let
          [offset : i64 (ctfe-layout-field-offset fields field-name)]
          (if (< offset 0)
            (ResultCtfe.Err
              (box
                (ctfe-diagnostic-at-expr
                  expr
                  (string.append "offset-of unknown field " field-name))))
            (ResultCtfe.Ok (CompilerCtfeValue.I64 offset) fuel)))
        (ResultCtfe.Err
          (box
            (ctfe-diagnostic-at-expr
              expr
              "offset-of requires struct layout type"))))]))

(define (ctfe-eval-offset-from-type
  [ty : AstType]
  [field-name : String]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match (ctfe-layout-info-for-type-with-pools
    (ctfe-env-pools env)
    (ctfe-env-layouts env)
    ty)
    [(CtfeMaybeLayoutInfo.Some info)
      (ctfe-eval-offset-from-layout field-name info expr fuel)]
    [(CtfeMaybeLayoutInfo.None)
      (ResultCtfe.Err
        (box
          (ctfe-diagnostic-at-expr expr "offset-of requires struct layout type")))]))

(define (ctfe-eval-offset-value
  [value : CompilerCtfeValue]
  [field-arg : AstExpr]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match value
    [(CompilerCtfeValue.Type ty)
      (match (ctfe-offset-field-name field-arg env)
        [(CtfeMaybeFieldName.Some field-name)
          (ctfe-eval-offset-from-type ty field-name expr env fuel)]
        [(CtfeMaybeFieldName.None)
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr expr "offset-of expects a field name")))])]
    [_
      (ResultCtfe.Err
        (box (ctfe-diagnostic-at-expr expr "offset-of expects a type argument")))]))

(define (ctfe-eval-offset-query
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [type-arg : AstExpr (ctfe-expr-arg args 0 env)]
      [field-arg : AstExpr (ctfe-expr-arg args 1 env)]
      (match (compiler-ctfe-eval type-arg env fuel)
        [(ResultCtfe.Err d) (ResultCtfe.Err d)]
        [(ResultCtfe.Ok value arg-fuel)
          (ctfe-eval-offset-value value field-arg expr env arg-fuel)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          "offset-of expects exactly one type argument and one field name")))))

(define (ctfe-reflection-query-name? [name : String]) : bool
  (ctfe-builtin-reflection-id? (intern name)))

(define (ctfe-eval-one-type-reflection
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [type-arg : AstExpr (ctfe-expr-arg args 0 env)]
      (match (ctfe-eval-type-arg type-arg expr env fuel name)
        [(ResultCtfeTypeArg.Err d) (ResultCtfe.Err d)]
        [(ResultCtfeTypeArg.Ok ty arg-fuel)
          (let
            [infos : CtfeReflectInfoList (ctfe-env-reflections env)]
            (cond
              [(string.eq name "type-info")
                (ResultCtfe.Ok
                  (CompilerCtfeValue.TypeInfo
                    (ctfe-reflect-resolve-type-with-pools
                      (ctfe-env-pools env)
                      infos
                      ty))
                  arg-fuel)]
              [(string.eq name "type-kind")
                (ResultCtfe.Ok
                  (CompilerCtfeValue.String
                    (ctfe-type-kind-with-reflections-and-pools
                      (ctfe-env-pools env)
                      infos
                      ty))
                  arg-fuel)]
              [(string.eq name "type-key")
                (ResultCtfe.Ok
                  (CompilerCtfeValue.String
                    (ctfe-type-key-with-reflections-and-pools
                      (ctfe-env-pools env)
                      infos
                      ty))
                  arg-fuel)]
              [(string.eq name "type-nominal-module")
                (match (ctfe-reflect-info-lookup
                  infos
                  (ctfe-type-nominal-key ty))
                  [(CtfeMaybeReflectInfo.Some info)
                    (match info
                      [(CtfeReflectInfo.Struct _ module _ _)
                        (ResultCtfe.Ok
                          (CompilerCtfeValue.String module)
                          arg-fuel)]
                      [(CtfeReflectInfo.Enum _ module _ _)
                        (ResultCtfe.Ok
                          (CompilerCtfeValue.String module)
                          arg-fuel)])]
                  [(CtfeMaybeReflectInfo.None)
                    (ResultCtfe.Err
                      (box
                        (ctfe-diagnostic-at-expr
                          expr
                          "type-nominal-module requires struct or enum type")))])]
              [(string.eq name "type-nominal-name")
                (match (ctfe-reflect-info-lookup
                  infos
                  (ctfe-type-nominal-key ty))
                  [(CtfeMaybeReflectInfo.Some info)
                    (match info
                      [(CtfeReflectInfo.Struct _ _ nominal-name _)
                        (ResultCtfe.Ok
                          (CompilerCtfeValue.String nominal-name)
                          arg-fuel)]
                      [(CtfeReflectInfo.Enum _ _ nominal-name _)
                        (ResultCtfe.Ok
                          (CompilerCtfeValue.String nominal-name)
                          arg-fuel)])]
                  [(CtfeMaybeReflectInfo.None)
                    (ResultCtfe.Err
                      (box
                        (ctfe-diagnostic-at-expr
                          expr
                          "type-nominal-name requires struct or enum type")))])]
              [(string.eq name "struct-field-count")
                (match (ctfe-reflect-info-lookup
                  infos
                  (ctfe-type-nominal-key ty))
                  [(CtfeMaybeReflectInfo.Some info)
                    (match info
                      [(CtfeReflectInfo.Struct _ _ _ fields)
                        (ResultCtfe.Ok
                          (CompilerCtfeValue.I64
                            (ctfe-reflect-field-list-count fields))
                          arg-fuel)]
                      [_
                        (ResultCtfe.Err
                          (box
                            (ctfe-diagnostic-at-expr
                              expr
                              "struct-field-count requires struct type")))])]
                  [(CtfeMaybeReflectInfo.None)
                    (ResultCtfe.Err
                      (box
                        (ctfe-diagnostic-at-expr
                          expr
                          "struct-field-count requires struct type")))])]
              [(string.eq name "enum-variant-count")
                (match (ctfe-reflect-info-lookup
                  infos
                  (ctfe-type-nominal-key ty))
                  [(CtfeMaybeReflectInfo.Some info)
                    (match info
                      [(CtfeReflectInfo.Enum _ _ _ variants)
                        (ResultCtfe.Ok
                          (CompilerCtfeValue.I64
                            (ctfe-reflect-variant-list-count variants))
                          arg-fuel)]
                      [_
                        (ResultCtfe.Err
                          (box
                            (ctfe-diagnostic-at-expr
                              expr
                              "enum-variant-count requires enum type")))])]
                  [(CtfeMaybeReflectInfo.None)
                    (ResultCtfe.Err
                      (box
                        (ctfe-diagnostic-at-expr
                          expr
                          "enum-variant-count requires enum type")))])]
              [(string.eq name "array-element-type")
                (match ty
                  [(AstType.Array elem _)
                    (ResultCtfe.Ok
                      (CompilerCtfeValue.Type (ctfe-ty-get env elem))
                      arg-fuel)]
                  [(AstType.DynArray elem)
                    (ResultCtfe.Ok
                      (CompilerCtfeValue.Type (ctfe-ty-get env elem))
                      arg-fuel)]
                  [_
                    (ResultCtfe.Err
                      (box
                        (ctfe-diagnostic-at-expr
                          expr
                          "array-element-type requires array type")))])]
              [(string.eq name "array-length")
                (match ty
                  [(AstType.Array _ count)
                    (ResultCtfe.Ok (CompilerCtfeValue.I64 count) arg-fuel)]
                  [_
                    (ResultCtfe.Err
                      (box
                        (ctfe-diagnostic-at-expr
                          expr
                          "array-length requires fixed array type")))])]
              [(string.eq name "array-dynamic?")
                (match ty
                  [(AstType.Array _ _)
                    (ResultCtfe.Ok (CompilerCtfeValue.Bool false) arg-fuel)]
                  [(AstType.DynArray _)
                    (ResultCtfe.Ok (CompilerCtfeValue.Bool true) arg-fuel)]
                  [_
                    (ResultCtfe.Err
                      (box
                        (ctfe-diagnostic-at-expr
                          expr
                          "array-dynamic? requires array type")))])]
              [(string.eq name "tuple-element-count")
                (match (ctfe-reflect-resolve-type-with-pools
                  (ctfe-env-pools env)
                  infos
                  ty)
                  [(AstType.Tuple elems)
                    (ResultCtfe.Ok
                      (CompilerCtfeValue.I64
                        (ctfe-type-list-count (box-get elems)))
                      arg-fuel)]
                  [_
                    (ResultCtfe.Err
                      (box
                        (ctfe-diagnostic-at-expr
                          expr
                          "tuple-element-count requires tuple type")))])]
              [(string.eq name "function-param-count")
                (match ty
                  [(AstType.Func params _)
                    (ResultCtfe.Ok
                      (CompilerCtfeValue.I64
                        (ctfe-type-list-count (box-get params)))
                      arg-fuel)]
                  [_
                    (ResultCtfe.Err
                      (box
                        (ctfe-diagnostic-at-expr
                          expr
                          "function-param-count requires function type")))])]
              [(string.eq name "function-return-type")
                (match ty
                  [(AstType.Func _ ret)
                    (ResultCtfe.Ok
                      (CompilerCtfeValue.Type (ctfe-ty-get env ret))
                      arg-fuel)]
                  [_
                    (ResultCtfe.Err
                      (box
                        (ctfe-diagnostic-at-expr
                          expr
                          "function-return-type requires function type")))])]
              [else (ctfe-unsupported-form expr)]))]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          (string.append name " expects exactly one type argument"))))))

(define (ctfe-type-nominal-key [ty : AstType]) : String
  (match ty
    [(AstType.Struct name) (intern-str name)]
    [(AstType.StructArgs name _) (intern-str name)]
    [(AstType.Enum name) (intern-str name)]
    [(AstType.EnumArgs name _) (intern-str name)]
    [(AstType.Var name) (intern-str name)]
    [(AstType.VarArgs name _) (intern-str name)]
    [_ ""]))

(define (ctfe-struct-field-arity-error [name : String] [expr : AstExpr]) : ResultCtfe
  (ResultCtfe.Err
    (box
      (ctfe-diagnostic-at-expr
        expr
        (string.append name " expects exactly one type argument and one index")))))

(define (ctfe-struct-field-kind-error [name : String] [expr : AstExpr]) : ResultCtfe
  (ResultCtfe.Err
    (box
      (ctfe-diagnostic-at-expr
        expr
        (string.append name " requires struct type")))))

(define (ctfe-eval-struct-field-from-fields
  [name : String]
  [fields : CtfeReflectFieldList]
  [pools : AstNodePoolContext]
  [infos : CtfeReflectInfoList]
  [index : i64]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (if (string.eq name "struct-field-name")
    (match (ctfe-reflect-field-name-at fields index)
      [(ResultCtfeStringLookup.Ok field-name)
        (ResultCtfe.Ok (CompilerCtfeValue.String field-name) fuel)]
      [(ResultCtfeStringLookup.Err message)
        (ResultCtfe.Err
          (box
            (ctfe-diagnostic-at-expr
              expr
              (string.append name (string.append " " message)))))])
    (match (ctfe-reflect-field-type-at fields pools infos index)
      [(ResultCtfeTypeLookup.Ok field-ty)
        (ResultCtfe.Ok (CompilerCtfeValue.Type field-ty) fuel)]
      [(ResultCtfeTypeLookup.Err message)
        (ResultCtfe.Err
          (box
            (ctfe-diagnostic-at-expr
              expr
              (string.append name (string.append " " message)))))])))

(define (ctfe-eval-struct-field-from-type
  [name : String]
  [ty : AstType]
  [index : i64]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (let
    [infos : CtfeReflectInfoList (ctfe-env-reflections env)]
    (match (ctfe-reflect-info-lookup infos (ctfe-type-nominal-key ty))
      [(CtfeMaybeReflectInfo.Some info)
        (match info
          [(CtfeReflectInfo.Struct _ _ _ fields)
            (ctfe-eval-struct-field-from-fields
              name
              fields
              (ctfe-env-pools env)
              infos
              index
              expr
              fuel)]
          [_ (ctfe-struct-field-kind-error name expr)])]
      [(CtfeMaybeReflectInfo.None) (ctfe-struct-field-kind-error name expr)])))

(define (ctfe-eval-struct-field-reflection
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [type-arg : AstExpr (ctfe-expr-arg args 0 env)]
      [index-arg : AstExpr (ctfe-expr-arg args 1 env)]
      (match (ctfe-eval-type-arg type-arg expr env fuel name)
        [(ResultCtfeTypeArg.Err d) (ResultCtfe.Err d)]
        [(ResultCtfeTypeArg.Ok ty type-fuel)
          (match (ctfe-eval-i64-arg index-arg expr env type-fuel name)
            [(result_ctfe_i64_arg.Err d) (ResultCtfe.Err d)]
            [(result_ctfe_i64_arg.Ok index-arg-value)
              (ctfe-eval-struct-field-from-type
                name
                ty
                (struct-get index-arg-value value)
                expr
                env
                (struct-get index-arg-value fuel))])]))
    (ctfe-struct-field-arity-error name expr)))

(define (ctfe-enum-variant-arity-error [name : String] [expr : AstExpr]) : ResultCtfe
  (ResultCtfe.Err
    (box
      (ctfe-diagnostic-at-expr
        expr
        (string.append name " expects exactly one type argument and one index")))))

(define (ctfe-enum-variant-kind-error [name : String] [expr : AstExpr]) : ResultCtfe
  (ResultCtfe.Err
    (box
      (ctfe-diagnostic-at-expr expr (string.append name " requires enum type")))))

(define (ctfe-eval-enum-variant-from-variants
  [name : String]
  [variants : CtfeReflectVariantList]
  [index : i64]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (if (string.eq name "enum-variant-name")
    (match (ctfe-reflect-variant-name-at variants index)
      [(ResultCtfeStringLookup.Ok variant-name)
        (ResultCtfe.Ok (CompilerCtfeValue.String variant-name) fuel)]
      [(ResultCtfeStringLookup.Err message)
        (ResultCtfe.Err
          (box
            (ctfe-diagnostic-at-expr
              expr
              (string.append name (string.append " " message)))))])
    (match (ctfe-reflect-variant-payloads-at variants index)
      [(ResultCtfeTypeListLookup.Ok payloads)
        (ResultCtfe.Ok
          (CompilerCtfeValue.I64 (ctfe-type-list-count payloads))
          fuel)]
      [(ResultCtfeTypeListLookup.Err message)
        (ResultCtfe.Err
          (box
            (ctfe-diagnostic-at-expr
              expr
              (string.append name (string.append " " message)))))])))

(define (ctfe-eval-enum-variant-from-type
  [name : String]
  [ty : AstType]
  [index : i64]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (let
    [infos : CtfeReflectInfoList (ctfe-env-reflections env)]
    (match (ctfe-reflect-info-lookup infos (ctfe-type-nominal-key ty))
      [(CtfeMaybeReflectInfo.Some info)
        (match info
          [(CtfeReflectInfo.Enum _ _ _ variants)
            (ctfe-eval-enum-variant-from-variants name variants index expr fuel)]
          [_ (ctfe-enum-variant-kind-error name expr)])]
      [(CtfeMaybeReflectInfo.None) (ctfe-enum-variant-kind-error name expr)])))

(define (ctfe-eval-enum-variant-reflection
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [type-arg : AstExpr (ctfe-expr-arg args 0 env)]
      [index-arg : AstExpr (ctfe-expr-arg args 1 env)]
      (match (ctfe-eval-type-arg type-arg expr env fuel name)
        [(ResultCtfeTypeArg.Err d) (ResultCtfe.Err d)]
        [(ResultCtfeTypeArg.Ok ty type-fuel)
          (match (ctfe-eval-i64-arg index-arg expr env type-fuel name)
            [(result_ctfe_i64_arg.Err d) (ResultCtfe.Err d)]
            [(result_ctfe_i64_arg.Ok index-arg-value)
              (ctfe-eval-enum-variant-from-type
                name
                ty
                (struct-get index-arg-value value)
                expr
                env
                (struct-get index-arg-value fuel))])]))
    (ctfe-enum-variant-arity-error name expr)))

(define (ctfe-enum-payload-type-arity-error [expr : AstExpr]) : ResultCtfe
  (ResultCtfe.Err
    (box
      (ctfe-diagnostic-at-expr
        expr
        "enum-variant-payload-type expects exactly one type argument, one variant index, and one payload index"))))

(define (ctfe-enum-payload-type-kind-error [expr : AstExpr]) : ResultCtfe
  (ResultCtfe.Err
    (box
      (ctfe-diagnostic-at-expr
        expr
        "enum-variant-payload-type requires enum type"))))

(define (ctfe-eval-enum-payload-type-from-variants
  [variants : CtfeReflectVariantList]
  [pools : AstNodePoolContext]
  [infos : CtfeReflectInfoList]
  [variant-index : i64]
  [payload-index : i64]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (match (ctfe-reflect-variant-payloads-at variants variant-index)
    [(ResultCtfeTypeListLookup.Ok payloads)
      (match (ctfe-type-list-ref-with-pools payloads pools infos payload-index)
        [(ResultCtfeTypeLookup.Ok payload-ty)
          (ResultCtfe.Ok (CompilerCtfeValue.Type payload-ty) fuel)]
        [(ResultCtfeTypeLookup.Err message)
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                (string.append "enum-variant-payload-type " message))))])]
    [(ResultCtfeTypeListLookup.Err message)
      (ResultCtfe.Err
        (box
          (ctfe-diagnostic-at-expr
            expr
            (string.append "enum-variant-payload-type " message))))]))

(define (ctfe-eval-enum-payload-type-from-type
  [ty : AstType]
  [variant-index : i64]
  [payload-index : i64]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (let
    [infos : CtfeReflectInfoList (ctfe-env-reflections env)]
    (match (ctfe-reflect-info-lookup infos (ctfe-type-nominal-key ty))
      [(CtfeMaybeReflectInfo.Some info)
        (match info
          [(CtfeReflectInfo.Enum _ _ _ variants)
            (ctfe-eval-enum-payload-type-from-variants
              variants
              (ctfe-env-pools env)
              infos
              variant-index
              payload-index
              expr
              fuel)]
          [_ (ctfe-enum-payload-type-kind-error expr)])]
      [(CtfeMaybeReflectInfo.None) (ctfe-enum-payload-type-kind-error expr)])))

(define (ctfe-eval-enum-payload-type-reflection
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 3)
    (let
      [type-arg : AstExpr (ctfe-expr-arg args 0 env)]
      [variant-arg : AstExpr (ctfe-expr-arg args 1 env)]
      [payload-arg : AstExpr (ctfe-expr-arg args 2 env)]
      (match (ctfe-eval-type-arg
        type-arg
        expr
        env
        fuel
        "enum-variant-payload-type")
        [(ResultCtfeTypeArg.Err d) (ResultCtfe.Err d)]
        [(ResultCtfeTypeArg.Ok ty type-fuel)
          (match (ctfe-eval-i64-arg
            variant-arg
            expr
            env
            type-fuel
            "enum-variant-payload-type")
            [(result_ctfe_i64_arg.Err d) (ResultCtfe.Err d)]
            [(result_ctfe_i64_arg.Ok variant-arg-value)
              (match (ctfe-eval-i64-arg
                payload-arg
                expr
                env
                (struct-get variant-arg-value fuel)
                "enum-variant-payload-type")
                [(result_ctfe_i64_arg.Err d) (ResultCtfe.Err d)]
                [(result_ctfe_i64_arg.Ok payload-arg-value)
                  (ctfe-eval-enum-payload-type-from-type
                    ty
                    (struct-get variant-arg-value value)
                    (struct-get payload-arg-value value)
                    expr
                    env
                    (struct-get payload-arg-value fuel))])])]))
    (ctfe-enum-payload-type-arity-error expr)))

(define (ctfe-eval-function-param-type-reflection
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [type-arg : AstExpr (ctfe-expr-arg args 0 env)]
      [index-arg : AstExpr (ctfe-expr-arg args 1 env)]
      (match (ctfe-eval-type-arg type-arg expr env fuel "function-param-type")
        [(ResultCtfeTypeArg.Err d) (ResultCtfe.Err d)]
        [(ResultCtfeTypeArg.Ok ty type-fuel)
          (match (ctfe-eval-i64-arg
            index-arg
            expr
            env
            type-fuel
            "function-param-type")
            [(result_ctfe_i64_arg.Err d) (ResultCtfe.Err d)]
            [(result_ctfe_i64_arg.Ok index-arg-value)
              (match ty
                [(AstType.Func params _)
                  (match (ctfe-type-list-ref-with-pools
                    (box-get params)
                    (ctfe-env-pools env)
                    (ctfe-env-reflections env)
                    (struct-get index-arg-value value))
                    [(ResultCtfeTypeLookup.Ok param-ty)
                      (ResultCtfe.Ok
                        (CompilerCtfeValue.Type param-ty)
                        (struct-get index-arg-value fuel))]
                    [(ResultCtfeTypeLookup.Err message)
                      (ResultCtfe.Err
                        (box
                          (ctfe-diagnostic-at-expr
                            expr
                            (string.append "function-param-type " message))))])]
                [_
                  (ResultCtfe.Err
                    (box
                      (ctfe-diagnostic-at-expr
                        expr
                        "function-param-type requires function type")))])])]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          "function-param-type expects exactly one type argument and one index")))))

(define (ctfe-tuple-element-type-arity-error [expr : AstExpr]) : ResultCtfe
  (ResultCtfe.Err
    (box
      (ctfe-diagnostic-at-expr
        expr
        "tuple-element-type expects exactly one type argument and one index"))))

(define (ctfe-tuple-element-type-kind-error [expr : AstExpr]) : ResultCtfe
  (ResultCtfe.Err
    (box
      (ctfe-diagnostic-at-expr expr "tuple-element-type requires tuple type"))))

(define (ctfe-eval-tuple-element-type-from-type
  [ty : AstType]
  [index : i64]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match (ctfe-reflect-resolve-type-with-pools
    (ctfe-env-pools env)
    (ctfe-env-reflections env)
    ty)
    [(AstType.Tuple elems)
      (match (ctfe-type-list-ref-with-pools
        (box-get elems)
        (ctfe-env-pools env)
        (ctfe-env-reflections env)
        index)
        [(ResultCtfeTypeLookup.Ok element-ty)
          (ResultCtfe.Ok (CompilerCtfeValue.Type element-ty) fuel)]
        [(ResultCtfeTypeLookup.Err message)
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                (string.append "tuple-element-type " message))))])]
    [_ (ctfe-tuple-element-type-kind-error expr)]))

(define (ctfe-eval-tuple-element-type-reflection
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [type-arg : AstExpr (ctfe-expr-arg args 0 env)]
      [index-arg : AstExpr (ctfe-expr-arg args 1 env)]
      (match (ctfe-eval-type-arg type-arg expr env fuel "tuple-element-type")
        [(ResultCtfeTypeArg.Err d) (ResultCtfe.Err d)]
        [(ResultCtfeTypeArg.Ok ty type-fuel)
          (match (ctfe-eval-i64-arg
            index-arg
            expr
            env
            type-fuel
            "tuple-element-type")
            [(result_ctfe_i64_arg.Err d) (ResultCtfe.Err d)]
            [(result_ctfe_i64_arg.Ok index-arg-value)
              (ctfe-eval-tuple-element-type-from-type
                ty
                (struct-get index-arg-value value)
                expr
                env
                (struct-get index-arg-value fuel))])]))
    (ctfe-tuple-element-type-arity-error expr)))

(define (ctfe-eval-reflection-query
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (let
    [_ctfe-builtin-refresh : unit (ctfe-builtin-refresh!)]
    [name-id : i64 (intern name)]
    (cond
      [(ctfe-builtin-reflection-primary-id? name-id)
        (ctfe-eval-one-type-reflection name args expr env fuel)]
      [(ctfe-builtin-id-any2?
          name-id
          (ctfe-builtin-ref 76)
          (ctfe-builtin-ref 77))
        (ctfe-eval-struct-field-reflection name args expr env fuel)]
      [(ctfe-builtin-id-any2?
          name-id
          (ctfe-builtin-ref 79)
          (ctfe-builtin-ref 80))
        (ctfe-eval-enum-variant-reflection name args expr env fuel)]
      [(= name-id (ctfe-builtin-ref 81))
        (ctfe-eval-enum-payload-type-reflection args expr env fuel)]
      [(= name-id (ctfe-builtin-ref 86))
        (ctfe-eval-tuple-element-type-reflection args expr env fuel)]
      [(= name-id (ctfe-builtin-ref 88))
        (ctfe-eval-function-param-type-reflection args expr env fuel)]
      [else (ctfe-unsupported-form expr)])))

(define (ctfe-eval-string-eq-call
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [left : AstExpr (ctfe-expr-arg args 0 env)]
      [right : AstExpr (ctfe-expr-arg args 1 env)]
      (match (ctfe-eval-string-arg left expr env fuel name)
        [(ResultCtfeStringArg.Err d) (ResultCtfe.Err d)]
        [(ResultCtfeStringArg.Ok l left-fuel)
          (match (ctfe-eval-string-arg right expr env left-fuel name)
            [(ResultCtfeStringArg.Err d) (ResultCtfe.Err d)]
            [(ResultCtfeStringArg.Ok r right-fuel)
              (ResultCtfe.Ok
                (CompilerCtfeValue.Bool (string.eq l r))
                right-fuel)])]))
    (ResultCtfe.Err
      (box (ctfe-diagnostic-at-expr expr "string-eq expects two strings")))))

(define (ctfe-eval-string-append-call
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [left : AstExpr (ctfe-expr-arg args 0 env)]
      [right : AstExpr (ctfe-expr-arg args 1 env)]
      (match (ctfe-eval-string-arg left expr env fuel name)
        [(ResultCtfeStringArg.Err d) (ResultCtfe.Err d)]
        [(ResultCtfeStringArg.Ok l left-fuel)
          (match (ctfe-eval-string-arg right expr env left-fuel name)
            [(ResultCtfeStringArg.Err d) (ResultCtfe.Err d)]
            [(ResultCtfeStringArg.Ok r right-fuel)
              (ResultCtfe.Ok
                (CompilerCtfeValue.String (string.append l r))
                right-fuel)])]))
    (ResultCtfe.Err
      (box (ctfe-diagnostic-at-expr expr "string-append expects two strings")))))

;; `comptime.string-slice` is the bounded byte-range operation needed by
;; literal-parsing macros. It operates only on comptime strings, never on a
;; runtime String value.
(define (ctfe-eval-comptime-string-slice-call
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 3)
    (let
      [text-arg : AstExpr (ctfe-expr-arg args 0 env)]
      [start-arg : AstExpr (ctfe-expr-arg args 1 env)]
      [len-arg : AstExpr (ctfe-expr-arg args 2 env)]
      (match (ctfe-eval-string-arg text-arg expr env fuel "string-slice")
        [(ResultCtfeStringArg.Err d) (ResultCtfe.Err d)]
        [(ResultCtfeStringArg.Ok text text-fuel)
          (match (ctfe-eval-i64-arg start-arg expr env text-fuel "string-slice")
            [(result_ctfe_i64_arg.Err d) (ResultCtfe.Err d)]
            [(result_ctfe_i64_arg.Ok start-value)
              (match (ctfe-eval-i64-arg
                len-arg
                expr
                env
                (struct-get start-value fuel)
                "string-slice")
                [(result_ctfe_i64_arg.Err d) (ResultCtfe.Err d)]
                [(result_ctfe_i64_arg.Ok len-value)
                  (let
                    [start : i64 (struct-get start-value value)]
                    [len : i64 (struct-get len-value value)]
                    [text-len : i64 (string.string-length text)]
                    (if (or (< start 0) (< len 0) (> (+ start len) text-len))
                      (ResultCtfe.Err
                        (box
                          (ctfe-diagnostic-at-expr
                            expr
                            "string-slice range out of bounds")))
                      (ResultCtfe.Ok
                        (CompilerCtfeValue.String
                          (string.substring text start len))
                        (struct-get len-value fuel))))])])]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          "string-slice expects a string, start, and length")))))

(define (ctfe-eval-string-length-call
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [arg : AstExpr (ctfe-expr-arg args 0 env)]
      (match (ctfe-eval-string-arg arg expr env fuel name)
        [(ResultCtfeStringArg.Err d) (ResultCtfe.Err d)]
        [(ResultCtfeStringArg.Ok text arg-fuel)
          (ResultCtfe.Ok
            (CompilerCtfeValue.I64 (string.string-length text))
            arg-fuel)]))
    (ResultCtfe.Err
      (box (ctfe-diagnostic-at-expr expr "string-length expects one string")))))

(define (ctfe-eval-string-ref-call
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [text : AstExpr (ctfe-expr-arg args 0 env)]
      [index : AstExpr (ctfe-expr-arg args 1 env)]
      (match (ctfe-eval-string-arg text expr env fuel name)
        [(ResultCtfeStringArg.Err d) (ResultCtfe.Err d)]
        [(ResultCtfeStringArg.Ok s text-fuel)
          (ctfe-eval-string-ref-index s index expr env text-fuel name)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr expr "string-ref expects a string and index")))))

(define (ctfe-eval-string-ref-index
  [text : String]
  [index-expr : AstExpr]
  [origin : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]
  [name : String]) : ResultCtfe
  (match (ctfe-eval-i64-arg index-expr origin env fuel name)
    [(result_ctfe_i64_arg.Err d) (ResultCtfe.Err d)]
    [(result_ctfe_i64_arg.Ok index-arg-value)
      (if (or
        (< (struct-get index-arg-value value) 0)
        (>= (struct-get index-arg-value value) (string.string-length text)))
        (ResultCtfe.Err
          (box
            (ctfe-diagnostic-at-expr origin "string-ref index out of bounds")))
        (ResultCtfe.Ok
          (CompilerCtfeValue.Char
            (string.string-ref text (struct-get index-arg-value value)))
          (struct-get index-arg-value fuel)))]))

(define (ctfe-eval-string-to-int-call
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [arg : AstExpr (ctfe-expr-arg args 0 env)]
      (match (ctfe-eval-string-arg arg expr env fuel name)
        [(ResultCtfeStringArg.Err d) (ResultCtfe.Err d)]
        [(ResultCtfeStringArg.Ok text arg-fuel)
          (ResultCtfe.Ok (CompilerCtfeValue.I64 (string.>int text)) arg-fuel)]))
    (ResultCtfe.Err
      (box (ctfe-diagnostic-at-expr expr "string->int expects one string")))))

(define (ctfe-eval-int-to-string-call
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [arg : AstExpr (ctfe-expr-arg args 0 env)]
      (match (ctfe-eval-i64-arg arg expr env fuel "string.int->string")
        [(result_ctfe_i64_arg.Err d) (ResultCtfe.Err d)]
        [(result_ctfe_i64_arg.Ok arg-value)
          (ResultCtfe.Ok
            (CompilerCtfeValue.String
              (string.int->string (struct-get arg-value value)))
            (struct-get arg-value fuel))]))
    (ResultCtfe.Err
      (box (ctfe-diagnostic-at-expr expr "string.int->string expects one i64")))))

;; User-facing stdlib.comptime helpers. Constructors, dense sequence helpers,
;; and provenance-sensitive reflection helpers remain CTFE bridge calls while
;; CTFE lacks general stdlib function calls and syntax values still carry
;; compiler-owned provenance/type metadata. Simple public inspectors are routed
;; through source-shaped match bodies below so their behavior follows the
;; ordinary stdlib.comptime definitions.
(define (ctfe-stdlib-string-helper-name? [name : String] [base : String]) : bool
  (and
    (ctfe-string-has-module-separator? name)
    (or
      (ctfe-string-eq-after-prefix? name "string." base)
      (ctfe-string-eq-after-prefix? name "string/" base)
      (ctfe-string-eq-after-prefix? name "stdlib.string." base)
      (ctfe-string-eq-after-prefix? name "stdlib.string/" base)
      (ctfe-string-eq-after-prefix? name "stdlib/string." base)
      (ctfe-string-eq-after-prefix? name "stdlib/string/" base)
      (ctfe-string-eq-after-prefix? name "stdlib/string.tl." base)
      (ctfe-string-eq-after-prefix? name "stdlib/string.tl/" base)
      (ctfe-string-suffix-with-prefix? name "/stdlib/string.tl." base)
      (ctfe-string-suffix-with-prefix? name "/stdlib/string.tl/" base))))

(define (ctfe-comptime-helper-base-after-prefix
  [name : String]
  [prefix : String]) : String
  (string.substring
    name
    (ctfe-private-string-length prefix)
    (- (ctfe-private-string-length name) (ctfe-private-string-length prefix))))

(define (ctfe-comptime-helper-lookup-name [name : String]) : String
  (cond
    [(ctfe-string-prefix? name "comptime.")
      (ctfe-comptime-helper-base-after-prefix name "comptime.")]
    [(ctfe-string-prefix? name "comptime/")
      (ctfe-comptime-helper-base-after-prefix name "comptime/")]
    [(ctfe-string-prefix? name "stdlib.comptime.")
      (ctfe-comptime-helper-base-after-prefix name "stdlib.comptime.")]
    [(ctfe-string-prefix? name "stdlib.comptime/")
      (ctfe-comptime-helper-base-after-prefix name "stdlib.comptime/")]
    [(ctfe-string-prefix? name "stdlib/comptime.")
      (ctfe-comptime-helper-base-after-prefix name "stdlib/comptime.")]
    [(ctfe-string-prefix? name "stdlib/comptime/")
      (ctfe-comptime-helper-base-after-prefix name "stdlib/comptime/")]
    [else name]))

(define (ctfe-comptime-error-helper-name? [name : String]) : bool
  (and
    (ctfe-string-has-module-separator? name)
    (ctfe-builtin-error-id? (intern (ctfe-comptime-helper-lookup-name name)))))

(define (ctfe-string-eq-helper-name? [name : String]) : bool
  (or
    (ctfe-builtin-string-eq-id? (intern name))
    (ctfe-stdlib-string-helper-name? name "eq")
    (ctfe-stdlib-string-helper-name? name "string-eq")
    (ctfe-stdlib-string-helper-name? name "string=?")))

(define (ctfe-string-length-helper-name? [name : String]) : bool
  (or
    (ctfe-builtin-string-length-id? (intern name))
    (ctfe-stdlib-string-helper-name? name "string-length")))

(define (ctfe-string-ref-helper-name? [name : String]) : bool
  (or
    (ctfe-builtin-string-ref-id? (intern name))
    (ctfe-stdlib-string-helper-name? name "string-ref")
    (ctfe-stdlib-string-helper-name? name "char-at")))

(define (ctfe-string-to-int-helper-name? [name : String]) : bool
  (or
    (ctfe-builtin-string-to-int-id? (intern name))
    (ctfe-stdlib-string-helper-name? name ">int")
    (ctfe-stdlib-string-helper-name? name "string->int")))

(define (ctfe-comptime-source-helper-call-name [name : String]) : String
  (let
    [_ctfe-builtin-refresh : unit (ctfe-builtin-refresh!)]
    [lookup-name : String (ctfe-comptime-helper-lookup-name name)]
    [lookup-id : i64 (intern lookup-name)]
    (cond
      [(= lookup-id (ctfe-builtin-ref 19)) "expr-bool?"]
      [(= lookup-id (ctfe-builtin-ref 20)) "expr-bool-value"]
      [(= lookup-id (ctfe-builtin-ref 21)) "expr-if?"]
      [(= lookup-id (ctfe-builtin-ref 22)) "expr-if-cond"]
      [(= lookup-id (ctfe-builtin-ref 23)) "expr-if-then"]
      [(= lookup-id (ctfe-builtin-ref 24)) "expr-if-else"]
      [(= lookup-id (ctfe-builtin-ref 25)) "expr-clause-first"]
      [(= lookup-id (ctfe-builtin-ref 26)) "expr-clause-second"]
      [(= lookup-id (ctfe-builtin-ref 50)) "expr-list-empty?"]
      [(= lookup-id (ctfe-builtin-ref 51)) "expr-list-length"]
      [(= lookup-id (ctfe-builtin-ref 52)) "expr-list-head"]
      [(= lookup-id (ctfe-builtin-ref 54)) "expr-list-nth"]
      [(= lookup-id (ctfe-builtin-ref 55)) "expr-clause-list-empty?"]
      [(= lookup-id (ctfe-builtin-ref 56)) "expr-clause-list-length"]
      [(= lookup-id (ctfe-builtin-ref 57)) "expr-clause-list-head"]
      [(= lookup-id (ctfe-builtin-ref 59)) "expr-clause-list-nth"]
      [(= lookup-id (ctfe-builtin-ref 61)) "expr-binding-clause-name"]
      [(= lookup-id (ctfe-builtin-ref 62)) "expr-binding-clause-has-type?"]
      [(= lookup-id (ctfe-builtin-ref 63)) "expr-binding-clause-type"]
      [(= lookup-id (ctfe-builtin-ref 64)) "expr-binding-clause-init"]
      [(= lookup-id (ctfe-builtin-ref 65)) "expr-binding-clause-list-empty?"]
      [(= lookup-id (ctfe-builtin-ref 66)) "expr-binding-clause-list-length"]
      [(= lookup-id (ctfe-builtin-ref 67)) "expr-binding-clause-list-head"]
      [(= lookup-id (ctfe-builtin-ref 69)) "expr-binding-clause-list-nth"]
      [else name])))

;; Names recognized as comptime helper/accessor calls. `expr-list-length` and
;; `expr-list-nth` (and their clause/binding-clause variants) are handled by the
;; direct builtins in `ctfe-eval-call`, which intercept them before the
;; source-helper fallback; they stay listed here so the typechecker still
;; recognizes them as comptime syntax operations. The list-like `empty?`/`head`/
;; `tail` operations were removed in favor of `length`/`nth` indexed access.
(define (ctfe-comptime-source-helper-name? [name : String]) : bool
  (ctfe-builtin-source-helper-id? (intern name)))

(define (ctfe-comptime-helper-call-name [name : String]) : String
  (let
    [lookup-name : String (ctfe-comptime-helper-lookup-name name)]
    (cond
      [(ctfe-stdlib-string-helper-name? lookup-name "append") "string-append"]
      [(ctfe-stdlib-string-helper-name? lookup-name "concat") "string-concat"]
      [(ctfe-stdlib-string-helper-name? lookup-name "int->string")
        "int->string"]
      [(ctfe-stdlib-string-helper-name? lookup-name ">int") "string->int"]
      [(ctfe-stdlib-string-helper-name? lookup-name "string->int")
        "string->int"]
      [(ctfe-comptime-error-helper-name? name) "comptime-error"]
      [else lookup-name])))

(define (ctfe-eval-comptime-error-call
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [message-arg : AstExpr (ctfe-expr-arg args 0 env)]
      (match (ctfe-eval-string-arg message-arg expr env fuel "comptime-error")
        [(ResultCtfeStringArg.Ok message _next-fuel)
          (ResultCtfe.Err (box (ctfe-diagnostic-at-expr expr message)))]
        [(ResultCtfeStringArg.Err d) (ResultCtfe.Err d)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr expr "comptime-error expects exactly one arg")))))

(define (ctfe-eval-expr-bool-call
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [arg : AstExpr (ctfe-expr-arg args 0 env)]
      (match (compiler-ctfe-eval arg env fuel)
        [(ResultCtfe.Ok value arg-fuel)
          (match value
            [(CompilerCtfeValue.Bool b)
              (ResultCtfe.Ok
                (CompilerCtfeValue.Expr
                  (ctfe-ast-push env (AstExpr.Literal (AstLiteral.Bool b)))
                  (AstType.Bool))
                arg-fuel)]
            [_
              (ResultCtfe.Err
                (box (ctfe-diagnostic-at-expr expr "expr-bool expects bool")))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box (ctfe-diagnostic-at-expr expr "expr-bool expects exactly one arg")))))

(define (ctfe-eval-expr-splice-call
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [arg : AstExpr (ctfe-expr-arg args 0 env)]
      (match (compiler-ctfe-eval arg env fuel)
        [(ResultCtfe.Ok value arg-fuel)
          (match value
            [(CompilerCtfeValue.Expr node ty)
              (ResultCtfe.Ok (CompilerCtfeValue.Expr node ty) arg-fuel)]
            [_
              (ResultCtfe.Err
                (box (ctfe-diagnostic-at-expr expr "expr-splice expects Expr")))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box (ctfe-diagnostic-at-expr expr "expr-splice expects exactly one arg")))))

;; `(expr-int n)` builds an i64 literal Expr from a comptime integer, letting a
;; macro splice a computed count or index as a literal (unquote requires an Expr,
;; so a bare i64 cannot be spliced directly).
(define (ctfe-eval-expr-int-call
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [arg : AstExpr (ctfe-expr-arg args 0 env)]
      (match (compiler-ctfe-eval arg env fuel)
        [(ResultCtfe.Ok value arg-fuel)
          (match value
            [(CompilerCtfeValue.I64 n)
              (ResultCtfe.Ok
                (CompilerCtfeValue.Expr
                  (ctfe-ast-push env (AstExpr.Literal (ast-lit-int n)))
                  (AstType.I64))
                arg-fuel)]
            [_
              (ResultCtfe.Err
                (box (ctfe-diagnostic-at-expr expr "expr-int expects i64")))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box (ctfe-diagnostic-at-expr expr "expr-int expects exactly one arg")))))

;; `(expr-string text)` builds a String literal Expr from a comptime string.
(define (ctfe-eval-expr-string-call
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [arg : AstExpr (ctfe-expr-arg args 0 env)]
      (match (compiler-ctfe-eval arg env fuel)
        [(ResultCtfe.Ok value arg-fuel)
          (match value
            [(CompilerCtfeValue.String text)
              (ResultCtfe.Ok
                (CompilerCtfeValue.Expr
                  (ctfe-ast-push env (AstExpr.Literal (AstLiteral.String text)))
                  (AstType.String))
                arg-fuel)]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr expr "expr-string expects String")))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box (ctfe-diagnostic-at-expr expr "expr-string expects exactly one arg")))))

;; String-literal inspection intentionally uses helpers instead of growing the
;; verified public `Expr` enum. This keeps older stage0 compilers able to read
;; the declaration while exposing only the stable literal surface macros need.
(define (ctfe-eval-expr-string-inspector-call
  [extract? : bool]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [arg : AstExpr (ctfe-expr-arg args 0 env)]
      (match (compiler-ctfe-eval arg env fuel)
        [(ResultCtfe.Ok value arg-fuel)
          (match value
            [(CompilerCtfeValue.String text)
              (if extract?
                (ResultCtfe.Ok (CompilerCtfeValue.String text) arg-fuel)
                (ResultCtfe.Ok (CompilerCtfeValue.Bool true) arg-fuel))]
            [(CompilerCtfeValue.Expr node _)
              (match (ctfe-expr-unspan env (ctfe-ast-get env node))
                [(AstExpr.Literal (AstLiteral.String text))
                  (if extract?
                    (ResultCtfe.Ok (CompilerCtfeValue.String text) arg-fuel)
                    (ResultCtfe.Ok (CompilerCtfeValue.Bool true) arg-fuel))]
                [_
                  (if extract?
                    (ResultCtfe.Err
                      (box
                        (ctfe-diagnostic-at-expr
                          expr
                          "expr-string-value expects a string literal Expr")))
                    (ResultCtfe.Ok (CompilerCtfeValue.Bool false) arg-fuel))])]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "expr-string inspector expects Expr")))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          "expr-string inspector expects exactly one arg")))))

;; `(expr-var name)` builds a variable-reference Expr from a comptime string.
(define (ctfe-eval-expr-var-call
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [arg : AstExpr (ctfe-expr-arg args 0 env)]
      (match (compiler-ctfe-eval arg env fuel)
        [(ResultCtfe.Ok value arg-fuel)
          (match value
            [(CompilerCtfeValue.String name)
              (ResultCtfe.Ok
                (CompilerCtfeValue.Expr
                  (ctfe-ast-push env (AstExpr.Var (intern name)))
                  (ctfe-untyped-expr-type))
                arg-fuel)]
            [_
              (ResultCtfe.Err
                (box (ctfe-diagnostic-at-expr expr "expr-var expects String")))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box (ctfe-diagnostic-at-expr expr "expr-var expects exactly one arg")))))

(define (ctfe-eval-module-name-call
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [arg : AstExpr (ctfe-expr-arg args 0 env)]
      (match (ctfe-eval-string-arg arg expr env fuel "module-name")
        [(ResultCtfeStringArg.Ok module next-fuel)
          (ResultCtfe.Ok (CompilerCtfeValue.String module) next-fuel)]
        [(ResultCtfeStringArg.Err d) (ResultCtfe.Err d)]))
    (ResultCtfe.Err
      (box (ctfe-diagnostic-at-expr expr "module-name expects exactly one arg")))))

(define (ctfe-eval-module-export-macro-call
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [module-arg : AstExpr (ctfe-expr-arg args 0 env)]
      [name-arg : AstExpr (ctfe-expr-arg args 1 env)]
      (match (ctfe-eval-string-arg
        module-arg
        expr
        env
        fuel
        "module-export-macro?")
        [(ResultCtfeStringArg.Ok module module-fuel)
          (match (ctfe-eval-string-arg
            name-arg
            expr
            env
            module-fuel
            "module-export-macro?")
            [(ResultCtfeStringArg.Ok name name-fuel)
              (ResultCtfe.Ok
                (CompilerCtfeValue.Bool
                  (or
                    (string.eq module "")
                    (ctfe-module-macro-export? module name)))
                name-fuel)]
            [(ResultCtfeStringArg.Err d) (ResultCtfe.Err d)])]
        [(ResultCtfeStringArg.Err d) (ResultCtfe.Err d)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          "module-export-macro? expects exactly two args")))))

(define (ctfe-eval-module-hook-call
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [module-arg : AstExpr (ctfe-expr-arg args 0 env)]
      [name-arg : AstExpr (ctfe-expr-arg args 1 env)]
      (match (ctfe-eval-string-arg module-arg expr env fuel "module-hook")
        [(ResultCtfeStringArg.Ok module module-fuel)
          (match (ctfe-eval-string-arg
            name-arg
            expr
            env
            module-fuel
            "module-hook")
            [(ResultCtfeStringArg.Ok name name-fuel)
              (if (or
                (string.eq module "")
                (ctfe-module-macro-export? module name))
                (ResultCtfe.Ok
                  (CompilerCtfeValue.Expr
                    (ctfe-ast-push
                      env
                      (AstExpr.Var
                        (intern (ctfe-hygiene-global-symbol-name module name))))
                    (ctfe-untyped-expr-type))
                  name-fuel)
                (ResultCtfe.Err
                  (box
                    (ctfe-diagnostic-at-expr
                      expr
                      (string.append
                        "typecheck: strategy module "
                        (string.append
                          module
                          (string.append " does not export hook " name)))))))]
            [(ResultCtfeStringArg.Err d) (ResultCtfe.Err d)])]
        [(ResultCtfeStringArg.Err d) (ResultCtfe.Err d)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr expr "module-hook expects exactly two args")))))

;; `(expr-struct-get target field)` builds a struct-get Expr whose field name is
;; computed at macro CTFE. The expanded program typechecks the field access.
(define (ctfe-eval-expr-struct-get-call
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [target-arg : AstExpr (ctfe-expr-arg args 0 env)]
      [field-arg : AstExpr (ctfe-expr-arg args 1 env)]
      (match (compiler-ctfe-eval target-arg env fuel)
        [(ResultCtfe.Ok target-val target-fuel)
          (match target-val
            [(CompilerCtfeValue.Expr target-node _)
              (match (compiler-ctfe-eval field-arg env target-fuel)
                [(ResultCtfe.Ok field-val field-fuel)
                  (match field-val
                    [(CompilerCtfeValue.String field)
                      (ResultCtfe.Ok
                        (CompilerCtfeValue.Expr
                          (ast-expr-struct-get-with-pools
                            (ctfe-env-pools env)
                            target-node
                            field)
                          (ctfe-untyped-expr-type))
                        field-fuel)]
                    [_
                      (ResultCtfe.Err
                        (box
                          (ctfe-diagnostic-at-expr
                            expr
                            "expr-struct-get field expects String")))])]
                [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "expr-struct-get target expects Expr")))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          "expr-struct-get expects exactly two args")))))

;; `(expr-tuple-ref target index)` builds a tuple-ref Expr whose index is
;; computed at macro CTFE. The expanded program typechecks the tuple access.
(define (ctfe-eval-expr-tuple-ref-call
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [target-arg : AstExpr (ctfe-expr-arg args 0 env)]
      [index-arg : AstExpr (ctfe-expr-arg args 1 env)]
      (match (compiler-ctfe-eval target-arg env fuel)
        [(ResultCtfe.Ok target-val target-fuel)
          (match target-val
            [(CompilerCtfeValue.Expr target-node _)
              (match (compiler-ctfe-eval index-arg env target-fuel)
                [(ResultCtfe.Ok index-val index-fuel)
                  (match index-val
                    [(CompilerCtfeValue.I64 index)
                      (ResultCtfe.Ok
                        (CompilerCtfeValue.Expr
                          (ast-expr-tuple-ref-with-pools
                            (ctfe-env-pools env)
                            target-node
                            index)
                          (ctfe-untyped-expr-type))
                        index-fuel)]
                    [_
                      (ResultCtfe.Err
                        (box
                          (ctfe-diagnostic-at-expr
                            expr
                            "expr-tuple-ref index expects i64")))])]
                [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "expr-tuple-ref target expects Expr")))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr expr "expr-tuple-ref expects exactly two args")))))

;; `(expr-struct-set target field value)` builds a struct field assignment whose
;; field name is computed at macro CTFE. The expanded program typechecks the
;; assignment target and value.
(define (ctfe-eval-expr-struct-set-call
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 3)
    (let
      [target-arg : AstExpr (ctfe-expr-arg args 0 env)]
      [field-arg : AstExpr (ctfe-expr-arg args 1 env)]
      [value-arg : AstExpr (ctfe-expr-arg args 2 env)]
      (match (compiler-ctfe-eval target-arg env fuel)
        [(ResultCtfe.Ok target-val target-fuel)
          (match target-val
            [(CompilerCtfeValue.Expr target-node _)
              (match (compiler-ctfe-eval field-arg env target-fuel)
                [(ResultCtfe.Ok field-val field-fuel)
                  (match field-val
                    [(CompilerCtfeValue.String field)
                      (match (compiler-ctfe-eval value-arg env field-fuel)
                        [(ResultCtfe.Ok value-val value-fuel)
                          (match value-val
                            [(CompilerCtfeValue.Expr value-node _)
                              (ResultCtfe.Ok
                                (CompilerCtfeValue.Expr
                                  (ast-expr-struct-set-with-pools
                                    (ctfe-env-pools env)
                                    target-node
                                    field
                                    value-node)
                                  (AstType.Unit))
                                value-fuel)]
                            [_
                              (ResultCtfe.Err
                                (box
                                  (ctfe-diagnostic-at-expr
                                    expr
                                    "expr-struct-set value expects Expr")))])]
                        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
                    [_
                      (ResultCtfe.Err
                        (box
                          (ctfe-diagnostic-at-expr
                            expr
                            "expr-struct-set field expects String")))])]
                [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "expr-struct-set target expects Expr")))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          "expr-struct-set expects exactly three args")))))

;; `(expr-mut-borrow place)` builds an explicit inferred-lifetime `(&mut place)`
;; syntax node. The generated program owns the ordinary place and borrow checks.
(define (ctfe-eval-expr-mut-borrow-call
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [place-arg : AstExpr (ctfe-expr-arg args 0 env)]
      (match (compiler-ctfe-eval place-arg env fuel)
        [(ResultCtfe.Ok place-value place-fuel)
          (match place-value
            [(CompilerCtfeValue.Expr place-node _)
              (ResultCtfe.Ok
                (CompilerCtfeValue.Expr
                  (ast-expr-borrow-with-pools
                    (ctfe-env-pools env)
                    true
                    AstBorrowLifetime.Inferred
                    place-node)
                  (ctfe-untyped-expr-type))
                place-fuel)]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr expr "expr-mut-borrow expects Expr")))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr expr "expr-mut-borrow expects exactly one arg")))))

;; Build the ordered, persistent syntax-list values used by expression calls.
(define (ctfe-eval-expr-list-empty-call
  [args : AstExprList]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 0)
    (ResultCtfe.Ok (CompilerCtfeValue.ExprList (ast-expr-list-new)) fuel)
    (ResultCtfe.Err
      (box (ctfe-diagnostic-at-expr expr "expr-list-empty expects no args")))))

(define (ctfe-eval-expr-list-cons-call
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [head-arg : AstExpr (ctfe-expr-arg args 0 env)]
      [tail-arg : AstExpr (ctfe-expr-arg args 1 env)]
      (match (compiler-ctfe-eval head-arg env fuel)
        [(ResultCtfe.Ok head-value head-fuel)
          (match head-value
            [(CompilerCtfeValue.Expr head-node _)
              (match (compiler-ctfe-eval tail-arg env head-fuel)
                [(ResultCtfe.Ok tail-value tail-fuel)
                  (match tail-value
                    [(CompilerCtfeValue.ExprList tail)
                      (ResultCtfe.Ok
                        (CompilerCtfeValue.ExprList
                          (ast-expr-cons head-node tail))
                        tail-fuel)]
                    [_
                      (ResultCtfe.Err
                        (box
                          (ctfe-diagnostic-at-expr
                            expr
                            "expr-list-cons tail expects ExprList")))])]
                [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "expr-list-cons head expects Expr")))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr expr "expr-list-cons expects exactly two args")))))

;; `(expr-call callee args)` preserves the supplied argument order and builds
;; ordinary call syntax. Typechecking of that call happens after macro expansion.
(define (ctfe-eval-expr-call-call
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [callee-arg : AstExpr (ctfe-expr-arg args 0 env)]
      [args-arg : AstExpr (ctfe-expr-arg args 1 env)]
      (match (compiler-ctfe-eval callee-arg env fuel)
        [(ResultCtfe.Ok callee-value callee-fuel)
          (match callee-value
            [(CompilerCtfeValue.Expr callee-node _)
              (match (compiler-ctfe-eval args-arg env callee-fuel)
                [(ResultCtfe.Ok args-value args-fuel)
                  (match args-value
                    [(CompilerCtfeValue.ExprList call-args)
                      (ResultCtfe.Ok
                        (CompilerCtfeValue.Expr
                          (ast-expr-call-with-pools
                            (ctfe-env-pools env)
                            callee-node
                            call-args)
                          (ctfe-untyped-expr-type))
                        args-fuel)]
                    [_
                      (ResultCtfe.Err
                        (box
                          (ctfe-diagnostic-at-expr
                            expr
                            "expr-call args expects ExprList")))])]
                [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr expr "expr-call callee expects Expr")))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box (ctfe-diagnostic-at-expr expr "expr-call expects exactly two args")))))

;; Build a call whose receiver is an explicit inferred-lifetime mutable borrow.
(define (ctfe-expr-mut-call-result
  [callee : i64]
  [place : i64]
  [tail : AstExprList]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (ResultCtfe.Ok
    (CompilerCtfeValue.Expr
      (ast-expr-call-with-pools
        (ctfe-env-pools env)
        callee
        (ast-expr-cons
          (ast-expr-borrow-with-pools
            (ctfe-env-pools env)
            true
            AstBorrowLifetime.Inferred
            place)
          tail))
      (ctfe-untyped-expr-type))
    fuel))

;; Fixed public arities avoid temporary ExprList values in generated macro
;; bodies while evaluating every captured expression in source order.
(define (ctfe-eval-expr-mut-call
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]
  [ordinary-count : i64]
  [arity-message : String]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) (+ ordinary-count 2))
    (let
      [callee-arg : AstExpr (ctfe-expr-arg args 0 env)]
      [place-arg : AstExpr (ctfe-expr-arg args 1 env)]
      (match (compiler-ctfe-eval callee-arg env fuel)
        [(ResultCtfe.Ok callee-value callee-fuel)
          (match callee-value
            [(CompilerCtfeValue.Expr callee _)
              (match (compiler-ctfe-eval place-arg env callee-fuel)
                [(ResultCtfe.Ok place-value place-fuel)
                  (match place-value
                    [(CompilerCtfeValue.Expr place _)
                      (if (= ordinary-count 0)
                        (ctfe-expr-mut-call-result
                          callee
                          place
                          (ast-expr-list-new)
                          env
                          place-fuel)
                        (match (compiler-ctfe-eval
                          (ctfe-expr-arg args 2 env)
                          env
                          place-fuel)
                          [(ResultCtfe.Ok first-value first-fuel)
                            (match first-value
                              [(CompilerCtfeValue.Expr first _)
                                (if (= ordinary-count 1)
                                  (ctfe-expr-mut-call-result
                                    callee
                                    place
                                    (ast-expr-cons first (ast-expr-list-new))
                                    env
                                    first-fuel)
                                  (match (compiler-ctfe-eval
                                    (ctfe-expr-arg args 3 env)
                                    env
                                    first-fuel)
                                    [(ResultCtfe.Ok second-value second-fuel)
                                      (match second-value
                                        [(CompilerCtfeValue.Expr second _)
                                          (ctfe-expr-mut-call-result
                                            callee
                                            place
                                            (ast-expr-cons
                                              first
                                              (ast-expr-cons
                                                second
                                                (ast-expr-list-new)))
                                            env
                                            second-fuel)]
                                        [_
                                          (ResultCtfe.Err
                                            (box
                                              (ctfe-diagnostic-at-expr
                                                expr
                                                "expr-mut-call arguments expect Expr")))])]
                                    [(ResultCtfe.Err diag)
                                      (ResultCtfe.Err diag)]))]
                              [_
                                (ResultCtfe.Err
                                  (box
                                    (ctfe-diagnostic-at-expr
                                      expr
                                      "expr-mut-call arguments expect Expr")))])]
                          [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))]
                    [_
                      (ResultCtfe.Err
                        (box
                          (ctfe-diagnostic-at-expr
                            expr
                            "expr-mut-call place expects Expr")))])]
                [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "expr-mut-call callee expects Expr")))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err (box (ctfe-diagnostic-at-expr expr arity-message)))))

(define (ctfe-eval-expr-type-call
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [arg : AstExpr (ctfe-expr-arg args 0 env)]
      (match (compiler-ctfe-eval arg env fuel)
        [(ResultCtfe.Ok value arg-fuel)
          (match value
            [(CompilerCtfeValue.Expr _ ty)
              (let
                [actual-ty : AstType
                  (ctfe-captured-expr-type-inner-with-pools
                    (ctfe-env-pools env)
                    ty)]
                (if (ctfe-untyped-expr-type? actual-ty)
                  (ResultCtfe.Err
                    (box
                      (ctfe-diagnostic-at-expr
                        expr
                        "expr-type requires a typechecked Expr")))
                  (ResultCtfe.Ok
                    (CompilerCtfeValue.Type
                      (ctfe-reflect-resolve-type-with-pools
                        (ctfe-env-pools env)
                        (ctfe-env-reflections env)
                        actual-ty))
                    arg-fuel)))]
            [_
              (ResultCtfe.Err
                (box (ctfe-diagnostic-at-expr expr "expr-type expects Expr")))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box (ctfe-diagnostic-at-expr expr "expr-type expects exactly one arg")))))

(define (ctfe-expr-clause-list-inspector-name? [name : String]) : bool
  (ctfe-builtin-expr-clause-list-inspector-id? (intern name)))

(define (ctfe-expr-binding-clause-list-inspector-name? [name : String]) : bool
  (ctfe-builtin-expr-binding-clause-list-inspector-id? (intern name)))

(define (ctfe-eval-expr-clause-list-inspector-call
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [arg : AstExpr (ctfe-expr-arg args 0 env)]
      (match (compiler-ctfe-eval arg env fuel)
        [(ResultCtfe.Ok value arg-fuel)
          (match value
            [(CompilerCtfeValue.ExprClauseList clauses)
              (ResultCtfe.Ok
                (CompilerCtfeValue.ExprList
                  (ctfe-expr-clause-list->expr-list-in-env env clauses))
                arg-fuel)]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    (string.append name " expects ExprClauseList"))))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          (string.append name " expects exactly one arg"))))))

(define (ctfe-eval-expr-binding-clause-list-inspector-call
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [arg : AstExpr (ctfe-expr-arg args 0 env)]
      (match (compiler-ctfe-eval arg env fuel)
        [(ResultCtfe.Ok value arg-fuel)
          (match value
            [(CompilerCtfeValue.ExprBindingClauseList clauses)
              (ResultCtfe.Ok
                (CompilerCtfeValue.ExprList
                  (ctfe-expr-binding-clause-list->expr-list-in-env env clauses))
                arg-fuel)]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    (string.append name " expects ExprBindingClauseList"))))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          (string.append name " expects exactly one arg"))))))

;; `(expr-list-length seq)` and its clause/binding-clause variants return the
;; element count as a comptime i64, exactly matching `(struct-get seq len)`.
;; Exposed as a direct builtin so macros get O(1) length without rebuilding and
;; re-interpreting a `struct-get` AST on every call (the slow source-helper path).
;; The produced value is identical to the source-helper result for every valid
;; sequence, so this is byte-identical to interpreting the mirror body.
(define (ctfe-eval-comptime-sequence-length-call
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [arg : AstExpr (ctfe-expr-arg args 0 env)]
      (match (compiler-ctfe-eval arg env fuel)
        [(ResultCtfe.Ok value arg-fuel)
          (match value
            [(CompilerCtfeValue.ExprList nodes)
              (ResultCtfe.Ok
                (CompilerCtfeValue.I64 (ctfe-expr-list-length nodes))
                arg-fuel)]
            [(CompilerCtfeValue.ExprClauseList clauses)
              (ResultCtfe.Ok
                (CompilerCtfeValue.I64 (ctfe-expr-clause-list-length clauses))
                arg-fuel)]
            [(CompilerCtfeValue.ExprBindingClauseList clauses)
              (ResultCtfe.Ok
                (CompilerCtfeValue.I64
                  (ctfe-expr-binding-clause-list-length clauses))
                arg-fuel)]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    (string.append name " expects a comptime sequence"))))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          (string.append name " expects exactly one arg"))))))

;; `(expr-list-nth seq index)` and its clause/binding-clause variants return the
;; indexed element, exactly matching `(array-ref (struct-get seq items) index)`.
;; Delegates to `ctfe-eval-array-ref-value`, which already produces the correct
;; Expr / ExprClause / ExprBindingClause value with bounds checking, so this is a
;; direct O(1) builtin equivalent to interpreting the mirror body. Arguments are
;; evaluated sequence-then-index, matching the source-helper fuel threading.
(define (ctfe-eval-comptime-sequence-nth-call
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [seq-arg : AstExpr (ctfe-expr-arg args 0 env)]
      [index-arg : AstExpr (ctfe-expr-arg args 1 env)]
      (match (compiler-ctfe-eval seq-arg env fuel)
        [(ResultCtfe.Ok seq-value seq-fuel)
          (match (compiler-ctfe-eval index-arg env seq-fuel)
            [(ResultCtfe.Ok index-value index-fuel)
              (match index-value
                [(CompilerCtfeValue.I64 index)
                  (ctfe-eval-array-ref-value
                    seq-value
                    index
                    expr
                    env
                    index-fuel)]
                [_
                  (ResultCtfe.Err
                    (box
                      (ctfe-diagnostic-at-expr
                        expr
                        (string.append name " index must be i64"))))])]
            [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          (string.append name " expects a sequence and an index"))))))

(define (ctfe-comptime-sequence-length-name? [name : String]) : bool
  (ctfe-builtin-sequence-length-id? (intern name)))

(define (ctfe-comptime-sequence-nth-name? [name : String]) : bool
  (ctfe-builtin-sequence-nth-id? (intern name)))

(define (ctfe-eval-expr-if-call
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 3)
    (let
      [cond-arg : AstExpr (ctfe-expr-arg args 0 env)]
      [then-arg : AstExpr (ctfe-expr-arg args 1 env)]
      [else-arg : AstExpr (ctfe-expr-arg args 2 env)]
      (match (compiler-ctfe-eval cond-arg env fuel)
        [(ResultCtfe.Ok cond-val cond-fuel)
          (match cond-val
            [(CompilerCtfeValue.Expr cond-node cond-ty)
              (if (ctfe-type-eq-in-env env cond-ty (AstType.Bool))
                (match (compiler-ctfe-eval then-arg env cond-fuel)
                  [(ResultCtfe.Ok then-val then-fuel)
                    (match then-val
                      [(CompilerCtfeValue.Expr then-node then-ty)
                        (match (compiler-ctfe-eval else-arg env then-fuel)
                          [(ResultCtfe.Ok else-val else-fuel)
                            (match else-val
                              [(CompilerCtfeValue.Expr else-node else-ty)
                                (if (ctfe-type-eq-in-env env then-ty else-ty)
                                  (ResultCtfe.Ok
                                    (CompilerCtfeValue.Expr
                                      (ast-expr-if-with-pools
                                        (ctfe-env-pools env)
                                        cond-node
                                        then-node
                                        else-node)
                                      then-ty)
                                    else-fuel)
                                  (ResultCtfe.Err
                                    (box
                                      (ctfe-diagnostic-at-expr
                                        expr
                                        "expr-if branch types must match"))))]
                              [_
                                (ResultCtfe.Err
                                  (box
                                    (ctfe-diagnostic-at-expr
                                      expr
                                      "expr-if else branch expects Expr")))])]
                          [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
                      [_
                        (ResultCtfe.Err
                          (box
                            (ctfe-diagnostic-at-expr
                              expr
                              "expr-if then branch expects Expr")))])]
                  [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])
                (ResultCtfe.Err
                  (box
                    (ctfe-diagnostic-at-expr
                      expr
                      "expr-if condition must produce bool"))))]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "expr-if condition expects Expr")))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box (ctfe-diagnostic-at-expr expr "expr-if expects exactly three args")))))

(define (ctfe-eval-pattern-wildcard-call
  [args : AstExprList]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 0)
    (ResultCtfe.Ok (CompilerCtfeValue.Pattern AstPattern.Wildcard) fuel)
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          "pattern-wildcard expects exactly zero args")))))

(define (ctfe-eval-pattern-binding-call
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [name-arg : AstExpr (ctfe-expr-arg args 0 env)]
      (match (ctfe-eval-string-arg name-arg expr env fuel "pattern-binding")
        [(ResultCtfeStringArg.Ok name next-fuel)
          (ResultCtfe.Ok
            (CompilerCtfeValue.Pattern (ast-pat-binding name))
            next-fuel)]
        [(ResultCtfeStringArg.Err d) (ResultCtfe.Err d)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr expr "pattern-binding expects exactly one arg")))))

(define (ctfe-eval-pattern-variant-call
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [name-arg : AstExpr (ctfe-expr-arg args 0 env)]
      [payloads-arg : AstExpr (ctfe-expr-arg args 1 env)]
      (match (ctfe-eval-string-arg name-arg expr env fuel "pattern-variant")
        [(ResultCtfeStringArg.Ok name name-fuel)
          (match (compiler-ctfe-eval payloads-arg env name-fuel)
            [(ResultCtfe.Ok payloads-val payloads-fuel)
              (match payloads-val
                [(CompilerCtfeValue.PatternList payloads)
                  (ResultCtfe.Ok
                    (CompilerCtfeValue.Pattern (ast-pat-variant name payloads))
                    payloads-fuel)]
                [_
                  (ResultCtfe.Err
                    (box
                      (ctfe-diagnostic-at-expr
                        expr
                        "pattern-variant expects PatternList payloads")))])]
            [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
        [(ResultCtfeStringArg.Err d) (ResultCtfe.Err d)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          "pattern-variant expects exactly two args")))))

(define (ctfe-eval-pattern-list-empty-call
  [args : AstExprList]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 0)
    (ResultCtfe.Ok (CompilerCtfeValue.PatternList (ast-pattern-list-new)) fuel)
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          "pattern-list-empty expects exactly zero args")))))

(define (ctfe-eval-pattern-list-cons-call
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [head-arg : AstExpr (ctfe-expr-arg args 0 env)]
      [rest-arg : AstExpr (ctfe-expr-arg args 1 env)]
      (match (compiler-ctfe-eval head-arg env fuel)
        [(ResultCtfe.Ok head-val head-fuel)
          (match head-val
            [(CompilerCtfeValue.Pattern head-pattern)
              (match (compiler-ctfe-eval rest-arg env head-fuel)
                [(ResultCtfe.Ok rest-val rest-fuel)
                  (match rest-val
                    [(CompilerCtfeValue.PatternList rest-patterns)
                      (ResultCtfe.Ok
                        (CompilerCtfeValue.PatternList
                          (ast-pattern-cons head-pattern rest-patterns))
                        rest-fuel)]
                    [_
                      (ResultCtfe.Err
                        (box
                          (ctfe-diagnostic-at-expr
                            expr
                            "pattern-list-cons tail expects PatternList")))])]
                [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "pattern-list-cons head expects Pattern")))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          "pattern-list-cons expects exactly two args")))))

(define (ctfe-pattern-list-bindings-build [prefix : String] [count : i64]) : AstPatternList
  (let
    [patterns : AstPatternList (ast-pattern-list-with-capacity count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (ast-pattern-list-push
            (&mut patterns)
            (ast-pat-binding (string.append prefix (string.int->string index))))
          (set! index (+ index 1))))
      patterns)))

(define (ctfe-eval-pattern-list-bindings-call
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [prefix-arg : AstExpr (ctfe-expr-arg args 0 env)]
      [count-arg : AstExpr (ctfe-expr-arg args 1 env)]
      (match (ctfe-eval-string-arg
        prefix-arg
        expr
        env
        fuel
        "pattern-list-bindings")
        [(ResultCtfeStringArg.Ok prefix prefix-fuel)
          (match (ctfe-eval-i64-arg
            count-arg
            expr
            env
            prefix-fuel
            "pattern-list-bindings")
            [(result_ctfe_i64_arg.Ok count-value)
              (let
                [count : i64 (struct-get count-value value)]
                [count-fuel : i64 (struct-get count-value fuel)]
                (cond
                  [(< count 0)
                    (ResultCtfe.Err
                      (box
                        (ctfe-diagnostic-at-expr
                          expr
                          "pattern-list-bindings count must be non-negative")))]
                  [(> count count-fuel)
                    (ResultCtfe.Err
                      (box
                        (ctfe-diagnostic-at-expr
                          expr
                          "compile-time evaluation limit exceeded")))]
                  [else
                    (ResultCtfe.Ok
                      (CompilerCtfeValue.PatternList
                        (ctfe-pattern-list-bindings-build prefix count))
                      (- count-fuel count))]))]
            [(result_ctfe_i64_arg.Err diag) (ResultCtfe.Err diag)])]
        [(ResultCtfeStringArg.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          "pattern-list-bindings expects exactly two args")))))

(define (ctfe-eval-match-arm-call
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [pattern-arg : AstExpr (ctfe-expr-arg args 0 env)]
      [body-arg : AstExpr (ctfe-expr-arg args 1 env)]
      (match (compiler-ctfe-eval pattern-arg env fuel)
        [(ResultCtfe.Ok pattern-val pattern-fuel)
          (match pattern-val
            [(CompilerCtfeValue.Pattern pattern)
              (match (compiler-ctfe-eval body-arg env pattern-fuel)
                [(ResultCtfe.Ok body-val body-fuel)
                  (match body-val
                    [(CompilerCtfeValue.Expr body-node _)
                      (ResultCtfe.Ok
                        (CompilerCtfeValue.MatchArm
                          (ast-match-arm pattern body-node))
                        body-fuel)]
                    [_
                      (ResultCtfe.Err
                        (box
                          (ctfe-diagnostic-at-expr
                            expr
                            "match-arm body expects Expr")))])]
                [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "match-arm pattern expects Pattern")))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box (ctfe-diagnostic-at-expr expr "match-arm expects exactly two args")))))

(define (ctfe-eval-match-arm-list-empty-call
  [args : AstExprList]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 0)
    (ResultCtfe.Ok
      (CompilerCtfeValue.MatchArmList (ast-match-arm-list-new))
      fuel)
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          "match-arm-list-empty expects exactly zero args")))))

(define (ctfe-eval-match-arm-list-cons-call
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [head-arg : AstExpr (ctfe-expr-arg args 0 env)]
      [rest-arg : AstExpr (ctfe-expr-arg args 1 env)]
      (match (compiler-ctfe-eval head-arg env fuel)
        [(ResultCtfe.Ok head-val head-fuel)
          (match head-val
            [(CompilerCtfeValue.MatchArm head-arm)
              (match (compiler-ctfe-eval rest-arg env head-fuel)
                [(ResultCtfe.Ok rest-val rest-fuel)
                  (match rest-val
                    [(CompilerCtfeValue.MatchArmList rest-arms)
                      (ResultCtfe.Ok
                        (CompilerCtfeValue.MatchArmList
                          (ast-match-arm-cons head-arm rest-arms))
                        rest-fuel)]
                    [_
                      (ResultCtfe.Err
                        (box
                          (ctfe-diagnostic-at-expr
                            expr
                            "match-arm-list-cons tail expects MatchArmList")))])]
                [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "match-arm-list-cons head expects MatchArm")))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          "match-arm-list-cons expects exactly two args")))))

(define (ctfe-eval-expr-match-call
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [scrutinee-arg : AstExpr (ctfe-expr-arg args 0 env)]
      [arms-arg : AstExpr (ctfe-expr-arg args 1 env)]
      (match (compiler-ctfe-eval scrutinee-arg env fuel)
        [(ResultCtfe.Ok scrutinee-val scrutinee-fuel)
          (match scrutinee-val
            [(CompilerCtfeValue.Expr scrutinee-node _)
              (match (compiler-ctfe-eval arms-arg env scrutinee-fuel)
                [(ResultCtfe.Ok arms-val arms-fuel)
                  (match arms-val
                    [(CompilerCtfeValue.MatchArmList arms)
                      (ResultCtfe.Ok
                        (CompilerCtfeValue.Expr
                          (ast-expr-match-with-pools
                            (ctfe-env-pools env)
                            scrutinee-node
                            arms)
                          (ctfe-untyped-expr-type))
                        arms-fuel)]
                    [_
                      (ResultCtfe.Err
                        (box
                          (ctfe-diagnostic-at-expr
                            expr
                            "expr-match arms expects MatchArmList")))])]
                [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "expr-match scrutinee expects Expr")))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box (ctfe-diagnostic-at-expr expr "expr-match expects exactly two args")))))

(define (ctfe-source-helper-var [env : CtfeEnv] [name : String]) : i64
  (ctfe-ast-push env (AstExpr.Var (intern name))))

(define (ctfe-source-helper-bool [env : CtfeEnv] [value : bool]) : i64
  (ctfe-ast-push env (AstExpr.Literal (AstLiteral.Bool value))))

(define (ctfe-source-helper-i64 [env : CtfeEnv] [value : i64]) : i64
  (ctfe-ast-push env (AstExpr.Literal (ast-lit-int value))))

(define (ctfe-source-helper-string [env : CtfeEnv] [value : String]) : i64
  (ctfe-ast-push env (AstExpr.Literal (AstLiteral.String value))))

(define (ctfe-source-helper-struct-get
  [env : CtfeEnv]
  [target : i64]
  [field : String]) : i64
  (ast-expr-struct-get-with-pools (ctfe-env-pools env) target field))

(define (ctfe-source-helper-array-ref
  [env : CtfeEnv]
  [target : i64]
  [index : i64]) : i64
  (ast-expr-array-ref-with-pools (ctfe-env-pools env) target index))

(define (ctfe-source-helper-binary
  [env : CtfeEnv]
  [op : AstBinOp]
  [left : i64]
  [right : i64]) : i64
  (ast-expr-binary-with-pools (ctfe-env-pools env) op left right))

(define (ctfe-source-helper-if
  [env : CtfeEnv]
  [cond : i64]
  [then-expr : i64]
  [else-expr : i64]) : i64
  (ast-expr-if-with-pools (ctfe-env-pools env) cond then-expr else-expr))

(define (ctfe-source-helper-call1 [env : CtfeEnv] [name : String] [arg : i64]) : i64
  (ast-expr-call-with-pools
    (ctfe-env-pools env)
    (ctfe-source-helper-var env name)
    (ast-expr-cons arg (ast-expr-list-new))))

(define (ctfe-source-helper-comptime-error [env : CtfeEnv] [message : String]) : i64
  (ctfe-source-helper-call1
    env
    "comptime-error"
    (ctfe-source-helper-string env message)))

(define (ctfe-source-helper-sequence-len [env : CtfeEnv] [items : i64]) : i64
  (ctfe-source-helper-struct-get env items "len"))

(define (ctfe-source-helper-sequence-items [env : CtfeEnv] [items : i64]) : i64
  (ctfe-source-helper-struct-get env items "items"))

(define (ctfe-source-helper-sequence-empty? [env : CtfeEnv] [items : i64]) : i64
  (ctfe-source-helper-binary
    env
    (AstBinOp.Eq)
    (ctfe-source-helper-sequence-len env items)
    (ctfe-source-helper-i64 env 0)))

(define (ctfe-source-helper-sequence-head
  [env : CtfeEnv]
  [items : i64]
  [message : String]) : i64
  (let
    [zero : i64 (ctfe-source-helper-i64 env 0)]
    [has-items : i64
      (ctfe-source-helper-binary
        env
        (AstBinOp.Gt)
        (ctfe-source-helper-sequence-len env items)
        zero)]
    [head : i64
      (ctfe-source-helper-array-ref
        env
        (ctfe-source-helper-sequence-items env items)
        zero)]
    [err : i64 (ctfe-source-helper-comptime-error env message)]
    (ctfe-source-helper-if env has-items head err)))

(define (ctfe-source-helper-sequence-nth
  [env : CtfeEnv]
  [items : i64]
  [index : i64]
  [message : String]) : i64
  (let
    [zero : i64 (ctfe-source-helper-i64 env 0)]
    [negative : i64 (ctfe-source-helper-binary env (AstBinOp.Lt) index zero)]
    [too-large : i64
      (ctfe-source-helper-binary
        env
        (AstBinOp.Ge)
        index
        (ctfe-source-helper-sequence-len env items))]
    [value : i64
      (ctfe-source-helper-array-ref
        env
        (ctfe-source-helper-sequence-items env items)
        index)]
    [err : i64 (ctfe-source-helper-comptime-error env message)]
    [non-negative : i64 (ctfe-source-helper-if env too-large err value)]
    (ctfe-source-helper-if env negative err non-negative)))

(define (ctfe-source-helper-match-with-fallback
  [env : CtfeEnv]
  [scrutinee : i64]
  [pattern : AstPattern]
  [body : i64]
  [fallback : i64]) : i64
  (ast-expr-match-with-pools
    (ctfe-env-pools env)
    scrutinee
    (ast-match-arm-cons
      (ast-match-arm pattern body)
      (ast-match-arm-cons
        (ast-match-arm AstPattern.Wildcard fallback)
        (ast-match-arm-list-new)))))

(define (ctfe-source-helper-match-single
  [env : CtfeEnv]
  [scrutinee : i64]
  [pattern : AstPattern]
  [body : i64]) : i64
  (ast-expr-match-with-pools
    (ctfe-env-pools env)
    scrutinee
    (ast-match-arm-cons (ast-match-arm pattern body) (ast-match-arm-list-new))))

(define (ctfe-source-helper-expr-bool-pattern [arg : AstPattern]) : AstPattern
  (ast-pat-variant "ExprBool" (ast-pattern-cons arg (ast-pattern-list-new))))

(define (ctfe-source-helper-expr-if-pattern
  [cond : AstPattern]
  [then-expr : AstPattern]
  [else-expr : AstPattern]) : AstPattern
  (ast-pat-variant
    "ExprIf"
    (ast-pattern-cons
      cond
      (ast-pattern-cons
        then-expr
        (ast-pattern-cons else-expr (ast-pattern-list-new))))))

(define (ctfe-source-helper-expr-clause-pattern
  [first : AstPattern]
  [second : AstPattern]) : AstPattern
  (ast-pat-variant
    "ExprClause"
    (ast-pattern-cons first (ast-pattern-cons second (ast-pattern-list-new)))))

(define (ctfe-comptime-source-helper-nth-name? [name : String]) : bool
  (or
    (string.eq name "expr-list-nth")
    (string.eq name "expr-clause-list-nth")
    (string.eq name "expr-binding-clause-list-nth")))

(define (ctfe-comptime-source-helper-arity [name : String]) : i64
  (if (ctfe-comptime-source-helper-nth-name? name)
    2
    1))

(define (ctfe-comptime-source-helper-param-name [name : String]) : String
  (cond
    [(or
        (string.eq name "expr-clause-first")
        (string.eq name "expr-clause-second")
        (string.eq name "expr-binding-clause-name")
        (string.eq name "expr-binding-clause-has-type?")
        (string.eq name "expr-binding-clause-type")
        (string.eq name "expr-binding-clause-init"))
      "clause"]
    [(or
        (string.eq name "expr-list-empty?")
        (string.eq name "expr-list-length")
        (string.eq name "expr-list-head")
        (string.eq name "expr-list-nth")
        (string.eq name "expr-clause-list-empty?")
        (string.eq name "expr-clause-list-length")
        (string.eq name "expr-clause-list-head")
        (string.eq name "expr-clause-list-nth")
        (string.eq name "expr-binding-clause-list-empty?")
        (string.eq name "expr-binding-clause-list-length")
        (string.eq name "expr-binding-clause-list-head")
        (string.eq name "expr-binding-clause-list-nth"))
      "items"]
    [else "value"]))

(define (ctfe-comptime-source-helper-body [name : String] [env : CtfeEnv]) : i64
  (let
    [param : String (ctfe-comptime-source-helper-param-name name)]
    [scrutinee : i64 (ctfe-source-helper-var env param)]
    (cond
      [(string.eq name "expr-bool?")
        (ctfe-source-helper-match-with-fallback
          env
          scrutinee
          (ctfe-source-helper-expr-bool-pattern AstPattern.Wildcard)
          (ctfe-source-helper-bool env true)
          (ctfe-source-helper-bool env false))]
      [(string.eq name "expr-bool-value")
        (ctfe-source-helper-match-with-fallback
          env
          scrutinee
          (ctfe-source-helper-expr-bool-pattern (ast-pat-binding "found"))
          (ctfe-source-helper-var env "found")
          (ctfe-source-helper-bool env false))]
      [(string.eq name "expr-if?")
        (ctfe-source-helper-match-with-fallback
          env
          scrutinee
          (ctfe-source-helper-expr-if-pattern
            AstPattern.Wildcard
            AstPattern.Wildcard
            AstPattern.Wildcard)
          (ctfe-source-helper-bool env true)
          (ctfe-source-helper-bool env false))]
      [(string.eq name "expr-if-cond")
        (ctfe-source-helper-match-with-fallback
          env
          scrutinee
          (ctfe-source-helper-expr-if-pattern
            (ast-pat-binding "cond")
            AstPattern.Wildcard
            AstPattern.Wildcard)
          (ctfe-source-helper-var env "cond")
          scrutinee)]
      [(string.eq name "expr-if-then")
        (ctfe-source-helper-match-with-fallback
          env
          scrutinee
          (ctfe-source-helper-expr-if-pattern
            AstPattern.Wildcard
            (ast-pat-binding "then-expr")
            AstPattern.Wildcard)
          (ctfe-source-helper-var env "then-expr")
          scrutinee)]
      [(string.eq name "expr-if-else")
        (ctfe-source-helper-match-with-fallback
          env
          scrutinee
          (ctfe-source-helper-expr-if-pattern
            AstPattern.Wildcard
            AstPattern.Wildcard
            (ast-pat-binding "else-expr"))
          (ctfe-source-helper-var env "else-expr")
          scrutinee)]
      [(string.eq name "expr-clause-first")
        (ctfe-source-helper-match-single
          env
          scrutinee
          (ctfe-source-helper-expr-clause-pattern
            (ast-pat-binding "first")
            AstPattern.Wildcard)
          (ctfe-source-helper-var env "first"))]
      [(string.eq name "expr-clause-second")
        (ctfe-source-helper-match-single
          env
          scrutinee
          (ctfe-source-helper-expr-clause-pattern
            AstPattern.Wildcard
            (ast-pat-binding "second"))
          (ctfe-source-helper-var env "second"))]
      [(string.eq name "expr-list-empty?")
        (ctfe-source-helper-sequence-empty? env scrutinee)]
      [(string.eq name "expr-list-length")
        (ctfe-source-helper-sequence-len env scrutinee)]
      [(string.eq name "expr-list-head")
        (ctfe-source-helper-sequence-head
          env
          scrutinee
          "expr-list-head expects non-empty ExprList")]
      [(string.eq name "expr-list-nth")
        (ctfe-source-helper-sequence-nth
          env
          scrutinee
          (ctfe-source-helper-var env "index")
          "expr-list-nth index out of range")]
      [(string.eq name "expr-clause-list-empty?")
        (ctfe-source-helper-sequence-empty? env scrutinee)]
      [(string.eq name "expr-clause-list-length")
        (ctfe-source-helper-sequence-len env scrutinee)]
      [(string.eq name "expr-clause-list-head")
        (ctfe-source-helper-sequence-head
          env
          scrutinee
          "expr-clause-list-head expects non-empty ExprClauseList")]
      [(string.eq name "expr-clause-list-nth")
        (ctfe-source-helper-sequence-nth
          env
          scrutinee
          (ctfe-source-helper-var env "index")
          "expr-clause-list-nth index out of range")]
      [(string.eq name "expr-binding-clause-name")
        (ctfe-source-helper-struct-get env scrutinee "name")]
      [(string.eq name "expr-binding-clause-has-type?")
        (ctfe-source-helper-struct-get env scrutinee "has-type")]
      [(string.eq name "expr-binding-clause-type")
        (ctfe-source-helper-struct-get env scrutinee "ty")]
      [(string.eq name "expr-binding-clause-init")
        (ctfe-source-helper-struct-get env scrutinee "init")]
      [(string.eq name "expr-binding-clause-list-empty?")
        (ctfe-source-helper-sequence-empty? env scrutinee)]
      [(string.eq name "expr-binding-clause-list-length")
        (ctfe-source-helper-sequence-len env scrutinee)]
      [(string.eq name "expr-binding-clause-list-head")
        (ctfe-source-helper-sequence-head
          env
          scrutinee
          "expr-binding-clause-list-head expects non-empty ExprBindingClauseList")]
      [(string.eq name "expr-binding-clause-list-nth")
        (ctfe-source-helper-sequence-nth
          env
          scrutinee
          (ctfe-source-helper-var env "index")
          "expr-binding-clause-list-nth index out of range")]
      [else scrutinee])))

(define (ctfe-comptime-source-helper-arity-message [name : String]) : String
  (if (= (ctfe-comptime-source-helper-arity name) 1)
    (string.append name " expects exactly one arg")
    (string.append name " expects exactly two args")))

(define (ctfe-comptime-source-helper-arity-error
  [name : String]
  [expr : AstExpr]) : ResultCtfe
  (ResultCtfe.Err
    (box
      (ctfe-diagnostic-at-expr
        expr
        (ctfe-comptime-source-helper-arity-message name)))))

(define (ctfe-eval-comptime-source-helper-body
  [name : String]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (let
    [body : i64 (ctfe-comptime-source-helper-body name env)]
    (compiler-ctfe-eval (ctfe-ast-get env body) env fuel)))

(define (ctfe-eval-comptime-source-helper-index
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [arg-env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [index-arg : AstExpr (ctfe-expr-arg args 1 env)]
      (match (compiler-ctfe-eval index-arg env fuel)
        [(ResultCtfe.Ok index-value index-fuel)
          (let
            [body-env : CtfeEnv (ctfe-env-extend arg-env "index" index-value)]
            (ctfe-eval-comptime-source-helper-body name body-env index-fuel))]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ctfe-comptime-source-helper-arity-error name expr)))

(define (ctfe-eval-comptime-source-helper-call
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (let
    [arity : i64 (ctfe-comptime-source-helper-arity name)]
    (if (= (ctfe-expr-arg-count args) arity)
      (let
        [arg : AstExpr (ctfe-expr-arg args 0 env)]
        (match (compiler-ctfe-eval arg env fuel)
          [(ResultCtfe.Ok value arg-fuel)
            (let
              [arg-env : CtfeEnv
                (ctfe-env-extend
                  env
                  (ctfe-comptime-source-helper-param-name name)
                  value)]
              (if (= arity 1)
                (ctfe-eval-comptime-source-helper-body name arg-env arg-fuel)
                (ctfe-eval-comptime-source-helper-index
                  name
                  args
                  expr
                  env
                  arg-env
                  arg-fuel)))]
          [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
      (ctfe-comptime-source-helper-arity-error name expr))))

;; Dispatch a comptime call. Layout and reflection queries are compile-time-only
;; compiler metadata; selected String and Expr helpers make that metadata usable
;; in generator decisions without lowering it as runtime values.
(define (ctfe-eval-call
  [func : AstExpr]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match func
    [(AstExpr.Spanned inner-box _)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (ctfe-eval-call inner args expr env fuel))]
    [(AstExpr.Var name)
      (let
        [_ctfe-builtin-refresh : unit (ctfe-builtin-refresh!)]
        [raw-name : String (intern-str name)]
        [lookup-name : String (ctfe-hygiene-global-call-name raw-name)]
        [lookup-id : i64 (intern lookup-name)]
        [source-call-name : String
          (ctfe-comptime-source-helper-call-name lookup-name)]
        [source-call-id : i64 (intern source-call-name)]
        [call-name : String (ctfe-comptime-helper-call-name lookup-name)]
        [call-id : i64 (intern call-name)]
        [string-helper-candidate : bool
          (ctfe-string-helper-candidate-name? lookup-name)]
        (cond
          [(ctfe-builtin-size-align-id? lookup-id)
            (ctfe-eval-size-align-query lookup-name args expr env fuel)]
          [(ctfe-builtin-offset-of-id? lookup-id)
            (ctfe-eval-offset-query args expr env fuel)]
          [(ctfe-builtin-reflection-id? call-id)
            (ctfe-eval-reflection-query call-name args expr env fuel)]
          [(and
              string-helper-candidate
              (ctfe-string-eq-helper-name? lookup-name))
            (ctfe-eval-string-eq-call lookup-name args expr env fuel)]
          [(ctfe-builtin-string-build-id? call-id)
            (ctfe-eval-string-append-call call-name args expr env fuel)]
          [(= call-id (ctfe-builtin-ref 93))
            (ctfe-eval-comptime-string-slice-call args expr env fuel)]
          [(and
              string-helper-candidate
              (ctfe-string-length-helper-name? lookup-name))
            (ctfe-eval-string-length-call lookup-name args expr env fuel)]
          [(and
              string-helper-candidate
              (ctfe-string-ref-helper-name? lookup-name))
            (ctfe-eval-string-ref-call lookup-name args expr env fuel)]
          [(and
              string-helper-candidate
              (ctfe-string-to-int-helper-name? lookup-name))
            (ctfe-eval-string-to-int-call lookup-name args expr env fuel)]
          [(ctfe-builtin-int-to-string-id? call-id)
            (ctfe-eval-int-to-string-call args expr env fuel)]
          [(= call-id (ctfe-builtin-ref 27))
            (ctfe-eval-expr-bool-call args expr env fuel)]
          [(= call-id (ctfe-builtin-ref 28))
            (ctfe-eval-expr-int-call args expr env fuel)]
          [(= call-id (ctfe-builtin-ref 29))
            (ctfe-eval-expr-string-call args expr env fuel)]
          [(= call-id (ctfe-builtin-ref 91))
            (ctfe-eval-expr-string-inspector-call false args expr env fuel)]
          [(= call-id (ctfe-builtin-ref 92))
            (ctfe-eval-expr-string-inspector-call true args expr env fuel)]
          [(= call-id (ctfe-builtin-ref 30))
            (ctfe-eval-expr-var-call args expr env fuel)]
          [(= call-id (ctfe-builtin-ref 31))
            (ctfe-eval-expr-struct-get-call args expr env fuel)]
          [(= call-id (ctfe-builtin-ref 32))
            (ctfe-eval-expr-tuple-ref-call args expr env fuel)]
          [(= call-id (ctfe-builtin-ref 33))
            (ctfe-eval-expr-struct-set-call args expr env fuel)]
          [(= call-id (ctfe-builtin-ref 94))
            (ctfe-eval-expr-mut-borrow-call args expr env fuel)]
          [(= call-id (ctfe-builtin-ref 95))
            (ctfe-eval-expr-call-call args expr env fuel)]
          [(= call-id (ctfe-builtin-ref 96))
            (ctfe-eval-expr-list-empty-call args expr fuel)]
          [(= call-id (ctfe-builtin-ref 97))
            (ctfe-eval-expr-list-cons-call args expr env fuel)]
          [(= call-id (ctfe-builtin-ref 98))
            (ctfe-eval-expr-mut-call
              args
              expr
              env
              fuel
              0
              "expr-mut-call0 expects exactly two args")]
          [(= call-id (ctfe-builtin-ref 99))
            (ctfe-eval-expr-mut-call
              args
              expr
              env
              fuel
              1
              "expr-mut-call1 expects exactly three args")]
          [(= call-id (ctfe-builtin-ref 100))
            (ctfe-eval-expr-mut-call
              args
              expr
              env
              fuel
              2
              "expr-mut-call2 expects exactly four args")]
          [(= call-id (ctfe-builtin-ref 34))
            (ctfe-eval-expr-splice-call args expr env fuel)]
          [(= call-id (ctfe-builtin-ref 35))
            (ctfe-eval-expr-if-call args expr env fuel)]
          [(= call-id (ctfe-builtin-ref 36))
            (ctfe-eval-pattern-wildcard-call args expr fuel)]
          [(= call-id (ctfe-builtin-ref 37))
            (ctfe-eval-pattern-binding-call args expr env fuel)]
          [(= call-id (ctfe-builtin-ref 38))
            (ctfe-eval-pattern-variant-call args expr env fuel)]
          [(= call-id (ctfe-builtin-ref 39))
            (ctfe-eval-pattern-list-empty-call args expr fuel)]
          [(= call-id (ctfe-builtin-ref 40))
            (ctfe-eval-pattern-list-cons-call args expr env fuel)]
          [(= call-id (ctfe-builtin-ref 90))
            (ctfe-eval-pattern-list-bindings-call args expr env fuel)]
          [(= call-id (ctfe-builtin-ref 41))
            (ctfe-eval-match-arm-call args expr env fuel)]
          [(= call-id (ctfe-builtin-ref 42))
            (ctfe-eval-match-arm-list-empty-call args expr fuel)]
          [(= call-id (ctfe-builtin-ref 43))
            (ctfe-eval-match-arm-list-cons-call args expr env fuel)]
          [(= call-id (ctfe-builtin-ref 44))
            (ctfe-eval-expr-match-call args expr env fuel)]
          [(= call-id (ctfe-builtin-ref 45))
            (ctfe-eval-expr-type-call args expr env fuel)]
          [(= call-id (ctfe-builtin-ref 47))
            (ctfe-eval-module-name-call args expr env fuel)]
          [(= call-id (ctfe-builtin-ref 48))
            (ctfe-eval-module-export-macro-call args expr env fuel)]
          [(= call-id (ctfe-builtin-ref 49))
            (ctfe-eval-module-hook-call args expr env fuel)]
          [(ctfe-builtin-sequence-length-id? call-id)
            (ctfe-eval-comptime-sequence-length-call
              call-name
              args
              expr
              env
              fuel)]
          [(ctfe-builtin-sequence-nth-id? call-id)
            (ctfe-eval-comptime-sequence-nth-call call-name args expr env fuel)]
          [(ctfe-builtin-source-helper-id? source-call-id)
            (ctfe-eval-comptime-source-helper-call
              source-call-name
              args
              expr
              env
              fuel)]
          [(ctfe-builtin-expr-clause-list-inspector-id? call-id)
            (ctfe-eval-expr-clause-list-inspector-call
              call-name
              args
              expr
              env
              fuel)]
          [(ctfe-builtin-expr-binding-clause-list-inspector-id? call-id)
            (ctfe-eval-expr-binding-clause-list-inspector-call
              call-name
              args
              expr
              env
              fuel)]
          [(ctfe-builtin-comptime-error-id? call-id)
            (ctfe-eval-comptime-error-call args expr env fuel)]
          [else (ctfe-unsupported-form expr)]))]
    [_ (ctfe-unsupported-form expr)]))

;; Shared "unsupported compile-time form" diagnostic for ordinary calls.
(define (ctfe-unsupported-form [expr : AstExpr]) : ResultCtfe
  (ResultCtfe.Err
    (box
      (ctfe-diagnostic-at-expr
        expr
        (string.append
          "'"
          (string.append
            (ctfe-describe-expr expr)
            "' is not supported in compile-time evaluation"))))))

(define (ctfe-eval-var
  [name : String]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match (ctfe-env-lookup env name)
    [(CtfeMaybeValue.Some value) (ResultCtfe.Ok value fuel)]
    [(CtfeMaybeValue.None)
      (ResultCtfe.Err
        (box
          (ctfe-diagnostic-at-expr
            expr
            (string.append
              "compile-time evaluation cannot reference runtime variable '"
              (string.append name "'")))))]))

(define (ctfe-eval-box-get-value
  [value : CompilerCtfeValue]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (match value
    [(CompilerCtfeValue.TypeInfoBox ty)
      (ResultCtfe.Ok (CompilerCtfeValue.TypeInfo ty) fuel)]
    [_
      (ResultCtfe.Err
        (box
          (ctfe-diagnostic-at-expr
            expr
            "box-get in compile-time evaluation requires a TypeInfo box")))]))

(define (ctfe-eval-box-get
  [inner : AstExpr]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match (compiler-ctfe-eval inner env fuel)
    [(ResultCtfe.Ok value next-fuel)
      (ctfe-eval-box-get-value value expr next-fuel)]
    [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))

(define (ctfe-comptime-field-name? [field : i64] [want : String]) : bool
  (string.eq (intern-str field) want))

(define (ctfe-comptime-field-error [field : i64] [expr : AstExpr]) : ResultCtfe
  (ResultCtfe.Err
    (box
      (ctfe-diagnostic-at-expr
        expr
        (string.append
          "unsupported stdlib.comptime field '"
          (string.append (intern-str field) "'"))))))

(define (ctfe-comptime-struct-get-type-error [expr : AstExpr]) : ResultCtfe
  (ResultCtfe.Err
    (box
      (ctfe-diagnostic-at-expr
        expr
        "struct-get in compile-time evaluation requires a stdlib.comptime well-known value"))))

(define (ctfe-pattern-list-length [lst : AstPatternList]) : i64
  (struct-get (& lst) len))

(define (ctfe-pattern-list-nth [lst : AstPatternList] [index : i64]) : AstPattern
  (ast-pattern-list-get (& lst) index AstPattern.Wildcard))

(define (ctfe-match-arm-empty-default [env : CtfeEnv]) : AstMatchArm
  (ast-match-arm
    AstPattern.Wildcard
    (ctfe-ast-push env (AstExpr.Literal (AstLiteral.Unit)))))

(define (ctfe-match-arm-list-length [lst : AstMatchArmList]) : i64
  (struct-get (& lst) len))

(define (ctfe-match-arm-list-nth
  [lst : AstMatchArmList]
  [index : i64]
  [env : CtfeEnv]) : AstMatchArm
  (ast-match-arm-list-get (& lst) index (ctfe-match-arm-empty-default env)))

(define (ctfe-eval-struct-get-value
  [value : CompilerCtfeValue]
  [field : i64]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (match value
    [(CompilerCtfeValue.ExprList nodes)
      (cond
        [(ctfe-comptime-field-name? field "items")
          (ResultCtfe.Ok (CompilerCtfeValue.ExprList nodes) fuel)]
        [(ctfe-comptime-field-name? field "len")
          (ResultCtfe.Ok
            (CompilerCtfeValue.I64 (ctfe-expr-list-length nodes))
            fuel)]
        [else (ctfe-comptime-field-error field expr)])]
    [(CompilerCtfeValue.ExprClause clause)
      (cond
        [(ctfe-comptime-field-name? field "first")
          (ResultCtfe.Ok
            (CompilerCtfeValue.Expr
              (ctfe-expr-clause-first clause)
              (ctfe-untyped-expr-type))
            fuel)]
        [(ctfe-comptime-field-name? field "second")
          (ResultCtfe.Ok
            (CompilerCtfeValue.Expr
              (ctfe-expr-clause-second clause)
              (ctfe-untyped-expr-type))
            fuel)]
        [else (ctfe-comptime-field-error field expr)])]
    [(CompilerCtfeValue.ExprClauseList clauses)
      (cond
        [(ctfe-comptime-field-name? field "items")
          (ResultCtfe.Ok (CompilerCtfeValue.ExprClauseList clauses) fuel)]
        [(ctfe-comptime-field-name? field "len")
          (ResultCtfe.Ok
            (CompilerCtfeValue.I64 (ctfe-expr-clause-list-length clauses))
            fuel)]
        [else (ctfe-comptime-field-error field expr)])]
    [(CompilerCtfeValue.ExprBindingClause clause)
      (cond
        [(ctfe-comptime-field-name? field "name")
          (ResultCtfe.Ok
            (CompilerCtfeValue.String (ctfe-expr-binding-clause-name clause))
            fuel)]
        [(ctfe-comptime-field-name? field "has-type")
          (ResultCtfe.Ok
            (CompilerCtfeValue.Bool (ctfe-expr-binding-clause-has-type? clause))
            fuel)]
        [(ctfe-comptime-field-name? field "ty")
          (ResultCtfe.Ok
            (CompilerCtfeValue.Expr
              (ctfe-expr-binding-clause-type clause)
              (ctfe-untyped-expr-type))
            fuel)]
        [(ctfe-comptime-field-name? field "init")
          (ResultCtfe.Ok
            (CompilerCtfeValue.Expr
              (ctfe-expr-binding-clause-init clause)
              (ctfe-untyped-expr-type))
            fuel)]
        [else (ctfe-comptime-field-error field expr)])]
    [(CompilerCtfeValue.ExprBindingClauseList clauses)
      (cond
        [(ctfe-comptime-field-name? field "items")
          (ResultCtfe.Ok (CompilerCtfeValue.ExprBindingClauseList clauses) fuel)]
        [(ctfe-comptime-field-name? field "len")
          (ResultCtfe.Ok
            (CompilerCtfeValue.I64
              (ctfe-expr-binding-clause-list-length clauses))
            fuel)]
        [else (ctfe-comptime-field-error field expr)])]
    [(CompilerCtfeValue.PatternList patterns)
      (cond
        [(ctfe-comptime-field-name? field "items")
          (ResultCtfe.Ok (CompilerCtfeValue.PatternList patterns) fuel)]
        [(ctfe-comptime-field-name? field "len")
          (ResultCtfe.Ok
            (CompilerCtfeValue.I64 (ctfe-pattern-list-length patterns))
            fuel)]
        [else (ctfe-comptime-field-error field expr)])]
    [(CompilerCtfeValue.MatchArm arm)
      (match arm
        [(AstMatchArm.Arm pattern body)
          (cond
            [(ctfe-comptime-field-name? field "pattern")
              (ResultCtfe.Ok (CompilerCtfeValue.Pattern pattern) fuel)]
            [(ctfe-comptime-field-name? field "body")
              (ResultCtfe.Ok
                (CompilerCtfeValue.Expr body (ctfe-untyped-expr-type))
                fuel)]
            [else (ctfe-comptime-field-error field expr)])])]
    [(CompilerCtfeValue.MatchArmList arms)
      (cond
        [(ctfe-comptime-field-name? field "items")
          (ResultCtfe.Ok (CompilerCtfeValue.MatchArmList arms) fuel)]
        [(ctfe-comptime-field-name? field "len")
          (ResultCtfe.Ok
            (CompilerCtfeValue.I64 (ctfe-match-arm-list-length arms))
            fuel)]
        [else (ctfe-comptime-field-error field expr)])]
    [(CompilerCtfeValue.TypeInfoList items)
      (cond
        [(ctfe-comptime-field-name? field "items")
          (ResultCtfe.Ok (CompilerCtfeValue.TypeInfoList items) fuel)]
        [(ctfe-comptime-field-name? field "len")
          (ResultCtfe.Ok
            (CompilerCtfeValue.I64 (ctfe-type-list-count items))
            fuel)]
        [else (ctfe-comptime-field-error field expr)])]
    [(CompilerCtfeValue.TypeField name ty)
      (cond
        [(ctfe-comptime-field-name? field "name")
          (ResultCtfe.Ok (CompilerCtfeValue.String name) fuel)]
        [(ctfe-comptime-field-name? field "ty")
          (ResultCtfe.Ok (CompilerCtfeValue.TypeInfo ty) fuel)]
        [else (ctfe-comptime-field-error field expr)])]
    [(CompilerCtfeValue.TypeFieldList fields)
      (cond
        [(ctfe-comptime-field-name? field "items")
          (ResultCtfe.Ok (CompilerCtfeValue.TypeFieldList fields) fuel)]
        [(ctfe-comptime-field-name? field "len")
          (ResultCtfe.Ok
            (CompilerCtfeValue.I64 (ctfe-reflect-field-list-count fields))
            fuel)]
        [else (ctfe-comptime-field-error field expr)])]
    [(CompilerCtfeValue.TypeVariantPayload ty)
      (if (ctfe-comptime-field-name? field "ty")
        (ResultCtfe.Ok (CompilerCtfeValue.TypeInfo ty) fuel)
        (ctfe-comptime-field-error field expr))]
    [(CompilerCtfeValue.TypeVariantPayloadList payloads)
      (cond
        [(ctfe-comptime-field-name? field "items")
          (ResultCtfe.Ok
            (CompilerCtfeValue.TypeVariantPayloadList payloads)
            fuel)]
        [(ctfe-comptime-field-name? field "len")
          (ResultCtfe.Ok
            (CompilerCtfeValue.I64 (ctfe-type-list-count payloads))
            fuel)]
        [else (ctfe-comptime-field-error field expr)])]
    [(CompilerCtfeValue.TypeVariant name payloads)
      (cond
        [(ctfe-comptime-field-name? field "name")
          (ResultCtfe.Ok (CompilerCtfeValue.String name) fuel)]
        [(ctfe-comptime-field-name? field "payloads")
          (ResultCtfe.Ok
            (CompilerCtfeValue.TypeVariantPayloadList payloads)
            fuel)]
        [else (ctfe-comptime-field-error field expr)])]
    [(CompilerCtfeValue.TypeVariantList variants)
      (cond
        [(ctfe-comptime-field-name? field "items")
          (ResultCtfe.Ok (CompilerCtfeValue.TypeVariantList variants) fuel)]
        [(ctfe-comptime-field-name? field "len")
          (ResultCtfe.Ok
            (CompilerCtfeValue.I64 (ctfe-reflect-variant-list-count variants))
            fuel)]
        [else (ctfe-comptime-field-error field expr)])]
    [_ (ctfe-comptime-struct-get-type-error expr)]))

(define (ctfe-eval-struct-get
  [inner : AstExpr]
  [field : i64]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match (compiler-ctfe-eval inner env fuel)
    [(ResultCtfe.Ok value next-fuel)
      (ctfe-eval-struct-get-value value field expr next-fuel)]
    [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))

(define (ctfe-comptime-array-index-error [expr : AstExpr]) : ResultCtfe
  (ResultCtfe.Err
    (box (ctfe-diagnostic-at-expr expr "array-ref index out of range"))))

(define (ctfe-comptime-array-type-error [expr : AstExpr]) : ResultCtfe
  (ResultCtfe.Err
    (box
      (ctfe-diagnostic-at-expr
        expr
        "array-ref in compile-time evaluation requires stdlib.comptime sequence items"))))

(define (ctfe-eval-array-ref-value
  [array : CompilerCtfeValue]
  [index : i64]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match array
    [(CompilerCtfeValue.ExprList nodes)
      (if (or (< index 0) (>= index (ctfe-expr-list-length nodes)))
        (ctfe-comptime-array-index-error expr)
        (ResultCtfe.Ok
          (CompilerCtfeValue.Expr
            (ctfe-expr-list-nth nodes index)
            (ctfe-untyped-expr-type))
          fuel))]
    [(CompilerCtfeValue.ExprClauseList clauses)
      (if (or (< index 0) (>= index (ctfe-expr-clause-list-length clauses)))
        (ctfe-comptime-array-index-error expr)
        (ResultCtfe.Ok
          (CompilerCtfeValue.ExprClause
            (ctfe-expr-clause-list-nth clauses index))
          fuel))]
    [(CompilerCtfeValue.ExprBindingClauseList clauses)
      (if (or
        (< index 0)
        (>= index (ctfe-expr-binding-clause-list-length clauses)))
        (ctfe-comptime-array-index-error expr)
        (ResultCtfe.Ok
          (CompilerCtfeValue.ExprBindingClause
            (ctfe-expr-binding-clause-list-nth clauses index))
          fuel))]
    [(CompilerCtfeValue.PatternList patterns)
      (if (or (< index 0) (>= index (ctfe-pattern-list-length patterns)))
        (ctfe-comptime-array-index-error expr)
        (ResultCtfe.Ok
          (CompilerCtfeValue.Pattern (ctfe-pattern-list-nth patterns index))
          fuel))]
    [(CompilerCtfeValue.MatchArmList arms)
      (if (or (< index 0) (>= index (ctfe-match-arm-list-length arms)))
        (ctfe-comptime-array-index-error expr)
        (ResultCtfe.Ok
          (CompilerCtfeValue.MatchArm (ctfe-match-arm-list-nth arms index env))
          fuel))]
    [(CompilerCtfeValue.TypeInfoList items)
      (match (ctfe-type-list-ref-with-pools
        items
        (ctfe-env-pools env)
        (ctfe-env-reflections env)
        index)
        [(ResultCtfeTypeLookup.Ok ty)
          (ResultCtfe.Ok (CompilerCtfeValue.TypeInfo ty) fuel)]
        [(ResultCtfeTypeLookup.Err _) (ctfe-comptime-array-index-error expr)])]
    [(CompilerCtfeValue.TypeFieldList fields)
      (if (or (< index 0) (>= index (ctfe-reflect-field-list-count fields)))
        (ctfe-comptime-array-index-error expr)
        (match (ctfe-reflect-field-list-ref fields index)
          [(CtfeReflectField.Field name ty)
            (ResultCtfe.Ok
              (CompilerCtfeValue.TypeField
                name
                (ctfe-reflect-resolve-type-with-pools
                  (ctfe-env-pools env)
                  (ctfe-env-reflections env)
                  ty))
              fuel)]))]
    [(CompilerCtfeValue.TypeVariantPayloadList payloads)
      (match (ctfe-type-list-ref-with-pools
        payloads
        (ctfe-env-pools env)
        (ctfe-env-reflections env)
        index)
        [(ResultCtfeTypeLookup.Ok ty)
          (ResultCtfe.Ok (CompilerCtfeValue.TypeVariantPayload ty) fuel)]
        [(ResultCtfeTypeLookup.Err _) (ctfe-comptime-array-index-error expr)])]
    [(CompilerCtfeValue.TypeVariantList variants)
      (if (or (< index 0) (>= index (ctfe-reflect-variant-list-count variants)))
        (ctfe-comptime-array-index-error expr)
        (match (ctfe-reflect-variant-list-ref variants index)
          [(CtfeReflectVariant.Variant name payloads)
            (ResultCtfe.Ok (CompilerCtfeValue.TypeVariant name payloads) fuel)]))]
    [_ (ctfe-comptime-array-type-error expr)]))

(define (ctfe-eval-array-ref
  [array : AstExpr]
  [index : AstExpr]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match (compiler-ctfe-eval array env fuel)
    [(ResultCtfe.Ok array-value array-fuel)
      (match (compiler-ctfe-eval index env array-fuel)
        [(ResultCtfe.Ok index-value index-fuel)
          (match index-value
            [(CompilerCtfeValue.I64 index)
              (ctfe-eval-array-ref-value array-value index expr env index-fuel)]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "array-ref index must be i64 in compile-time evaluation")))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
    [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))

(define (ctfe-eval-binary
  [op : AstBinOp]
  [left : AstExpr]
  [right : AstExpr]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match (compiler-ctfe-eval left env fuel)
    [(ResultCtfe.Ok lv left-fuel)
      (match (compiler-ctfe-eval right env left-fuel)
        [(ResultCtfe.Ok rv right-fuel)
          (ctfe-apply-binop op lv rv expr env right-fuel)]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
    [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))

(define (ctfe-eval-unary
  [op : AstUnOp]
  [inner : AstExpr]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match (compiler-ctfe-eval inner env fuel)
    [(ResultCtfe.Ok v inner-fuel) (ctfe-apply-unop op v expr inner-fuel)]
    [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))

(define (ctfe-eval-if
  [cond : AstExpr]
  [then-branch : AstExpr]
  [else-branch : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match (compiler-ctfe-eval cond env fuel)
    [(ResultCtfe.Ok cond-value cond-fuel)
      (match cond-value
        [(CompilerCtfeValue.Bool b)
          (if b
            (compiler-ctfe-eval then-branch env cond-fuel)
            (compiler-ctfe-eval else-branch env cond-fuel))]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                cond
                "comptime 'if' condition must be bool")))])]
    [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))

;; Evaluate `let` bindings sequentially, threading both fuel and the extended
;; environment. The original `env` is preserved for siblings because each
;; binding extends a fresh copy threaded forward.
(define (ctfe-eval-let
  [bindings : AstLetBindingList]
  [body : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (ctfe-eval-let-at (& bindings) 0 body env fuel))

(define (ctfe-eval-let-at
  [bindings : (& bindings AstLetBindingList)]
  [index : i64]
  [body : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (>= index (ast-let-binding-list-len bindings))
    (compiler-ctfe-eval body env fuel)
    (match (ast-let-binding-list-get bindings index (ast-let-binding-fallback))
      [(AstLetBinding.Binding name maybe-ty value-expr-box)
        (let
          [value-expr : AstExpr (ctfe-ast-get env value-expr-box)]
          (match (compiler-ctfe-eval value-expr env fuel)
            [(ResultCtfe.Ok value value-fuel)
              (ctfe-eval-let-at
                bindings
                (+ index 1)
                body
                (ctfe-env-extend-typed
                  env
                  (intern-str name)
                  value
                  (ctfe-binding-type
                    maybe-ty
                    (ctfe-cast-source-type value-expr value env)
                    env))
                value-fuel)]
            [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))])))

;; Evaluate a `begin` to the value of its last expression; an empty body is
;; unit.
(define (ctfe-eval-begin-at
  [exprs : (& exprs AstExprList)]
  [index : i64]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (>= index (struct-get exprs len))
    (ResultCtfe.Ok (CompilerCtfeValue.Unit) fuel)
    (let
      [head : AstExpr (ctfe-ast-get env (ast-expr-list-get exprs index 0))]
      (match (compiler-ctfe-eval head env fuel)
        [(ResultCtfe.Ok value head-fuel)
          (if (= (+ index 1) (struct-get exprs len))
            (ResultCtfe.Ok value head-fuel)
            (ctfe-eval-begin-at exprs (+ index 1) env head-fuel))]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))))

(define (ctfe-eval-begin [exprs : AstExprList] [env : CtfeEnv] [fuel : i64]) : ResultCtfe
  (ctfe-eval-begin-at (& exprs) 0 env fuel))

;; Evaluate a small CTFE-owned `match` subset. Runtime enum/struct values still
;; have no CTFE representation; this covers scalar values and the public
;; stdlib.comptime syntax pseudo-values backed by CompilerCtfeValue.Expr/CompilerCtfeValue.ExprList.
(define (ctfe-value-list-cons [head : CompilerCtfeValue] [tail : CtfeValueList]) : CtfeValueList
  (CtfeValueList.Cons head (box tail)))

(define (ctfe-value-list1 [a : CompilerCtfeValue]) : CtfeValueList
  (ctfe-value-list-cons a CtfeValueList.Nil))

(define (ctfe-value-list2 [a : CompilerCtfeValue] [b : CompilerCtfeValue]) : CtfeValueList
  (ctfe-value-list-cons a (ctfe-value-list1 b)))

(define (ctfe-value-list3
  [a : CompilerCtfeValue]
  [b : CompilerCtfeValue]
  [c : CompilerCtfeValue]) : CtfeValueList
  (ctfe-value-list-cons a (ctfe-value-list2 b c)))

(define (ctfe-string-suffix? [text : String] [suffix : String]) : bool
  (let
    [text-len : i64 (string.string-length text)]
    [suffix-len : i64 (string.string-length suffix)]
    (if (< text-len suffix-len)
      false
      (string.eq
        (string.substring text (- text-len suffix-len) suffix-len)
        suffix))))

(define (ctfe-pattern-variant-name? [name : i64] [expected : String]) : bool
  (let
    [actual : String (intern-str name)]
    (or
      (string.eq actual expected)
      (ctfe-string-suffix? actual (string.append "." expected))
      (ctfe-string-suffix? actual (string.append "/" expected)))))

(define (ctfe-literal-matches-value?
  [lit : AstLiteral]
  [value : CompilerCtfeValue]) : bool
  (match lit
    [(AstLiteral.Int n _)
      (match value
        [(CompilerCtfeValue.I64 actual) (= actual n)]
        [_ false])]
    [(AstLiteral.Bool b)
      (match value
        [(CompilerCtfeValue.Bool actual) (= actual b)]
        [_ false])]
    [(AstLiteral.Char c)
      (match value
        [(CompilerCtfeValue.Char actual) (= actual c)]
        [_ false])]
    [(AstLiteral.Unit)
      (match value
        [(CompilerCtfeValue.Unit) true]
        [_ false])]
    [(AstLiteral.Float text)
      (match (compiler-float-parse-f64 text)
        [(CompilerFloatSomeF64 want)
          (match value
            [(CompilerCtfeValue.F64 actual) (= actual want)]
            [(CompilerCtfeValue.F32 actual) (= actual want)]
            [_ false])]
        [(CompilerFloatNoF64) false])]
    [(AstLiteral.String text)
      (match value
        [(CompilerCtfeValue.String actual) (string.eq actual text)]
        [_ false])]))

(define (ctfe-match-pattern-list
  [patterns : AstPatternList]
  [values : CtfeValueList]
  [env : CtfeEnv]) : CtfePatternMatch
  (ctfe-match-pattern-list-at (& patterns) 0 values env))

(define (ctfe-match-pattern-list-at
  [patterns : (& patterns AstPatternList)]
  [index : i64]
  [values : CtfeValueList]
  [env : CtfeEnv]) : CtfePatternMatch
  (if (>= index (struct-get patterns len))
    (match values
      [(CtfeValueList.Nil) (CtfePatternMatch.Matched env)]
      [_ (CtfePatternMatch.No)])
    (match values
      [(CtfeValueList.Cons value rest-values)
        (match (ctfe-match-pattern
          (ast-pattern-list-get patterns index (ast-pattern-fallback))
          value
          (ctfe-value-default-cast-type value)
          env)
          [(CtfePatternMatch.Matched next-env)
            (ctfe-match-pattern-list-at
              patterns
              (+ index 1)
              (box-get rest-values)
              next-env)]
          [(CtfePatternMatch.No) (CtfePatternMatch.No)])]
      [(CtfeValueList.Nil) (CtfePatternMatch.No)])))

(define (ctfe-match-expr-variant
  [variant : i64]
  [args : AstPatternList]
  [node : i64]
  [ty : AstType]
  [env : CtfeEnv]) : CtfePatternMatch
  (match (ctfe-expr-unspan env (ctfe-ast-get env node))
    [(AstExpr.Literal lit)
      (match lit
        [(AstLiteral.Bool b)
          (if (ctfe-pattern-variant-name? variant "ExprBool")
            (ctfe-match-pattern-list
              args
              (ctfe-value-list1 (CompilerCtfeValue.Bool b))
              env)
            (CtfePatternMatch.No))]
        [(AstLiteral.Int n _)
          (if (ctfe-pattern-variant-name? variant "ExprInt")
            (ctfe-match-pattern-list
              args
              (ctfe-value-list1 (CompilerCtfeValue.I64 n))
              env)
            (CtfePatternMatch.No))]
        [_ (CtfePatternMatch.No)])]
    [(AstExpr.Var name)
      (if (ctfe-pattern-variant-name? variant "ExprVar")
        (ctfe-match-pattern-list
          args
          (ctfe-value-list1 (CompilerCtfeValue.String (intern-str name)))
          env)
        (CtfePatternMatch.No))]
    [(AstExpr.If cond then-branch else-branch)
      (if (ctfe-pattern-variant-name? variant "ExprIf")
        (ctfe-match-pattern-list
          args
          (ctfe-value-list3
            (CompilerCtfeValue.Expr cond (AstType.Bool))
            (CompilerCtfeValue.Expr then-branch ty)
            (CompilerCtfeValue.Expr else-branch ty))
          env)
        (CtfePatternMatch.No))]
    [(AstExpr.Call callee args-list)
      (if (ctfe-pattern-variant-name? variant "ExprCall")
        (ctfe-match-pattern-list
          args
          (ctfe-value-list2
            (CompilerCtfeValue.Expr callee (ctfe-untyped-expr-type))
            (CompilerCtfeValue.ExprList args-list))
          env)
        (CtfePatternMatch.No))]
    [(AstExpr.Begin exprs)
      (if (ctfe-pattern-variant-name? variant "ExprBegin")
        (ctfe-match-pattern-list
          args
          (ctfe-value-list1 (CompilerCtfeValue.ExprList exprs))
          env)
        (CtfePatternMatch.No))]
    [(AstExpr.Quote inner)
      (if (ctfe-pattern-variant-name? variant "ExprQuote")
        (ctfe-match-pattern-list
          args
          (ctfe-value-list1
            (CompilerCtfeValue.Expr inner (ctfe-untyped-expr-type)))
          env)
        (CtfePatternMatch.No))]
    [(AstExpr.Quasiquote inner)
      (if (ctfe-pattern-variant-name? variant "ExprQuasiquote")
        (ctfe-match-pattern-list
          args
          (ctfe-value-list1
            (CompilerCtfeValue.Expr inner (ctfe-untyped-expr-type)))
          env)
        (CtfePatternMatch.No))]
    [(AstExpr.Unquote inner)
      (if (ctfe-pattern-variant-name? variant "ExprUnquote")
        (ctfe-match-pattern-list
          args
          (ctfe-value-list1
            (CompilerCtfeValue.Expr inner (ctfe-untyped-expr-type)))
          env)
        (CtfePatternMatch.No))]
    [(AstExpr.UnquoteSplicing inner)
      (if (ctfe-pattern-variant-name? variant "ExprUnquoteSplicing")
        (ctfe-match-pattern-list
          args
          (ctfe-value-list1
            (CompilerCtfeValue.Expr inner (ctfe-untyped-expr-type)))
          env)
        (CtfePatternMatch.No))]
    [_ (CtfePatternMatch.No)]))

(define (ctfe-match-pattern
  [pattern : AstPattern]
  [value : CompilerCtfeValue]
  [value-ty : AstType]
  [env : CtfeEnv]) : CtfePatternMatch
  (match pattern
    [(AstPattern.Wildcard) (CtfePatternMatch.Matched env)]
    [(AstPattern.Binding name)
      (CtfePatternMatch.Matched
        (ctfe-env-extend-typed env (intern-str name) value value-ty))]
    [(AstPattern.Var name maybe-ty)
      (CtfePatternMatch.Matched
        (ctfe-env-extend-typed
          env
          (intern-str name)
          value
          (ctfe-binding-type maybe-ty value-ty env)))]
    [(AstPattern.Literal lit)
      (if (ctfe-literal-matches-value? lit value)
        (CtfePatternMatch.Matched env)
        (CtfePatternMatch.No))]
    [(AstPattern.Variant variant args-box)
      (let
        [args : AstPatternList (box-get args-box)]
        (match value
          [(CompilerCtfeValue.Expr node ty)
            (ctfe-match-expr-variant variant args node ty env)]
          [(CompilerCtfeValue.TypeInfo ty)
            (ctfe-match-type-info-variant variant args ty env)]
          [(CompilerCtfeValue.TypeInfoBox ty)
            (if (ctfe-pattern-variant-name? variant "box")
              (ctfe-match-pattern-list
                args
                (ctfe-value-list1 (CompilerCtfeValue.TypeInfo ty))
                env)
              (CtfePatternMatch.No))]
          [(CompilerCtfeValue.ExprClause clause)
            (if (ctfe-pattern-variant-name? variant "ExprClause")
              (ctfe-match-pattern-list
                args
                (ctfe-value-list2
                  (CompilerCtfeValue.Expr
                    (ctfe-expr-clause-first clause)
                    (ctfe-untyped-expr-type))
                  (CompilerCtfeValue.Expr
                    (ctfe-expr-clause-second clause)
                    (ctfe-untyped-expr-type)))
                env)
              (CtfePatternMatch.No))]
          [_ (CtfePatternMatch.No)]))]
    [(AstPattern.Tuple _) (CtfePatternMatch.No)]))

(define (ctfe-eval-match-arms
  [value : CompilerCtfeValue]
  [value-ty : AstType]
  [arms : AstMatchArmList]
  [origin : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (ctfe-eval-match-arms-at value value-ty (& arms) 0 origin env fuel))

(define (ctfe-eval-match-arms-at
  [value : CompilerCtfeValue]
  [value-ty : AstType]
  [arms : (& arms AstMatchArmList)]
  [index : i64]
  [origin : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (>= index (struct-get arms len))
    (ResultCtfe.Err
      (box (ctfe-diagnostic-at-expr origin "comptime: no matching match arm")))
    (match (ast-match-arm-list-get arms index (ast-match-arm-fallback))
      [(AstMatchArm.Arm pattern body-box)
        (match (ctfe-match-pattern pattern value value-ty env)
          [(CtfePatternMatch.Matched arm-env)
            (compiler-ctfe-eval (ctfe-ast-get env body-box) arm-env fuel)]
          [(CtfePatternMatch.No)
            (ctfe-eval-match-arms-at
              value
              value-ty
              arms
              (+ index 1)
              origin
              env
              fuel)])])))

(define (ctfe-eval-match
  [scrutinee : AstExpr]
  [arms : AstMatchArmList]
  [origin : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match (compiler-ctfe-eval scrutinee env fuel)
    [(ResultCtfe.Ok value scrutinee-fuel)
      (ctfe-eval-match-arms
        value
        (ctfe-cast-source-type scrutinee value env)
        arms
        origin
        env
        scrutinee-fuel)]
    [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))

;; --- quote / quasiquote -----------------------------------------------------
(define (ctfe-quote-literal-type [lit : AstLiteral]) : AstType
  (match lit
    [(AstLiteral.Int _ _) (AstType.I64)]
    [(AstLiteral.Float _) (AstType.F64)]
    [(AstLiteral.Bool _) (AstType.Bool)]
    [(AstLiteral.Char _) (AstType.Char)]
    [(AstLiteral.String _) (AstType.String)]
    [(AstLiteral.Unit) (AstType.Unit)]))

(define (ctfe-expr-list-append [left : AstExprList] [right : AstExprList]) : AstExprList
  (let
    [out : AstExprList
      (ast-expr-list-with-capacity
        (+ (struct-get (& left) len) (struct-get (& right) len)))]
    (begin
      (ast-expr-list-append-from (&mut out) (& left) 0)
      (ast-expr-list-append-from (&mut out) (& right) 0)
      out)))

(define (ctfe-quote-if-type
  [cond-ty : AstType]
  [then-ty : AstType]
  [else-ty : AstType]) : AstType
  (if (and (ctfe-type-eq cond-ty (AstType.Bool)) (ctfe-type-eq then-ty else-ty))
    then-ty
    (AstType.Expr)))

(define (ctfe-eval-unquote-expr
  [inner : AstExpr]
  [origin : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfeQuoteExpr
  (match (compiler-ctfe-eval inner env fuel)
    [(ResultCtfe.Ok value next-fuel)
      (match value
        [(CompilerCtfeValue.Expr node ty)
          (ResultCtfeQuoteExpr.Ok node ty next-fuel)]
        [(CompilerCtfeValue.Type ty)
          (ResultCtfeQuoteExpr.Ok
            (ctfe-type-to-expr ty env)
            (AstType.Expr)
            next-fuel)]
        [_
          (ResultCtfeQuoteExpr.Err
            (box (ctfe-diagnostic-at-expr origin "unquote expects Expr")))])]
    [(ResultCtfe.Err diag) (ResultCtfeQuoteExpr.Err diag)]))

(define (ctfe-eval-unquote-splice
  [inner : AstExpr]
  [origin : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfeQuoteExprList
  (match (compiler-ctfe-eval inner env fuel)
    [(ResultCtfe.Ok value next-fuel)
      (match value
        [(CompilerCtfeValue.ExprList exprs)
          (ResultCtfeQuoteExprList.Ok exprs next-fuel)]
        [_
          (ResultCtfeQuoteExprList.Err
            (box
              (ctfe-diagnostic-at-expr
                origin
                "unquote-splicing expects ExprList")))])]
    [(ResultCtfe.Err diag) (ResultCtfeQuoteExprList.Err diag)]))

(define (ctfe-type-name-to-type [name : String]) : AstType
  (cond
    [(string.eq name "i64") (AstType.I64)]
    [(string.eq name "i32") (AstType.I32)]
    [(string.eq name "i16") (AstType.I16)]
    [(string.eq name "i8") (AstType.I8)]
    [(string.eq name "u64") (AstType.U64)]
    [(string.eq name "u32") (AstType.U32)]
    [(string.eq name "u16") (AstType.U16)]
    [(string.eq name "u8") (AstType.U8)]
    [(string.eq name "f64") (AstType.F64)]
    [(string.eq name "f32") (AstType.F32)]
    [(string.eq name "bool") (AstType.Bool)]
    [(string.eq name "char") (AstType.Char)]
    [(string.eq name "String") (AstType.String)]
    [(string.eq name "str") (AstType.Str)]
    [(string.eq name "bytes") (AstType.Bytes)]
    [(string.eq name "unit") (AstType.Unit)]
    [(string.eq name "never") (AstType.Never)]
    [(string.eq name "Expr") (AstType.Expr)]
    [(string.eq name "ExprList") (AstType.ExprList)]
    [else (AstType.Var (intern name))]))

(define (ctfe-internal-resolved-struct-type-marker) : String
  "__typelisp internal resolved struct type")

(define (ctfe-internal-resolved-enum-type-marker) : String
  "__typelisp internal resolved enum type")

(define (ctfe-type-syntax-name [name : String] [env : CtfeEnv]) : i64
  (ctfe-ast-push env (AstExpr.Var (intern name))))

(define (ctfe-type-syntax-string [value : String] [env : CtfeEnv]) : i64
  (ctfe-ast-push env (AstExpr.Literal (AstLiteral.String value))))

(define (ctfe-type-syntax-call
  [name : String]
  [args : AstExprList]
  [env : CtfeEnv]) : i64
  (ast-expr-call-with-pools
    (ctfe-env-pools env)
    (ctfe-type-syntax-name name env)
    args))

(define (ctfe-resolved-nominal-type-to-expr
  [marker : String]
  [name : String]
  [lifetimes : AstLifetimeList]
  [env : CtfeEnv]) : i64
  (ctfe-type-syntax-call
    marker
    (ast-expr-cons
      (ctfe-type-syntax-string name env)
      (ctfe-lifetime-list-to-expr-list lifetimes env))
    env))

(define (ctfe-type-list-to-expr-list-at
  [types : (& types AstTypeList)]
  [env : CtfeEnv]
  [index : i64]) : AstExprList
  (if (>= index (ast-type-list-len types))
    (ast-expr-list-new)
    (ast-expr-cons
      (ctfe-type-to-expr
        (ctfe-ty-get env (ast-type-list-get types index (ast-type-id-fallback)))
        env)
      (ctfe-type-list-to-expr-list-at types env (+ index 1)))))

(define (ctfe-type-list-to-expr-list [types : AstTypeList] [env : CtfeEnv]) : AstExprList
  (ctfe-type-list-to-expr-list-at (& types) env 0))

(define (ctfe-lifetime-list-to-expr-list
  [lifetimes : AstLifetimeList]
  [env : CtfeEnv]) : AstExprList
  (ctfe-lifetime-list-to-expr-list-at (& lifetimes) env 0))

(define (ctfe-lifetime-list-to-expr-list-at
  [lifetimes : (& lifetimes AstLifetimeList)]
  [env : CtfeEnv]
  [index : i64]) : AstExprList
  (if (>= index (ast-lifetime-list-len lifetimes))
    (ast-expr-list-new)
    (ast-expr-cons
      (ctfe-type-syntax-name
        (ast-lifetime-list-get lifetimes index (ast-lifetime-fallback))
        env)
      (ctfe-lifetime-list-to-expr-list-at lifetimes env (+ index 1)))))

(define (ctfe-func-type-to-expr-list
  [args : AstTypeList]
  [ret : AstType]
  [env : CtfeEnv]) : AstExprList
  (ctfe-func-type-to-expr-list-at (& args) ret env 0))

(define (ctfe-func-type-to-expr-list-at
  [args : (& args AstTypeList)]
  [ret : AstType]
  [env : CtfeEnv]
  [index : i64]) : AstExprList
  (if (>= index (ast-type-list-len args))
    (ast-expr-cons (ctfe-type-to-expr ret env) (ast-expr-list-new))
    (ast-expr-cons
      (ctfe-type-to-expr
        (ctfe-ty-get env (ast-type-list-get args index (ast-type-id-fallback)))
        env)
      (ctfe-func-type-to-expr-list-at args ret env (+ index 1)))))

(define (ctfe-type-to-expr [ty : AstType] [env : CtfeEnv]) : i64
  (match ty
    [(AstType.I64) (ctfe-type-syntax-name "i64" env)]
    [(AstType.I32) (ctfe-type-syntax-name "i32" env)]
    [(AstType.I16) (ctfe-type-syntax-name "i16" env)]
    [(AstType.I8) (ctfe-type-syntax-name "i8" env)]
    [(AstType.U64) (ctfe-type-syntax-name "u64" env)]
    [(AstType.U32) (ctfe-type-syntax-name "u32" env)]
    [(AstType.U16) (ctfe-type-syntax-name "u16" env)]
    [(AstType.U8) (ctfe-type-syntax-name "u8" env)]
    [(AstType.F64) (ctfe-type-syntax-name "f64" env)]
    [(AstType.F32) (ctfe-type-syntax-name "f32" env)]
    [(AstType.Bool) (ctfe-type-syntax-name "bool" env)]
    [(AstType.Char) (ctfe-type-syntax-name "char" env)]
    [(AstType.String) (ctfe-type-syntax-name "String" env)]
    [(AstType.Str) (ctfe-type-syntax-name "str" env)]
    [(AstType.Bytes) (ctfe-type-syntax-name "bytes" env)]
    [(AstType.Unit) (ctfe-type-syntax-name "unit" env)]
    [(AstType.Never) (ctfe-type-syntax-name "never" env)]
    [(AstType.Expr) (ctfe-type-syntax-name "Expr" env)]
    [(AstType.ExprList) (ctfe-type-syntax-name "ExprList" env)]
    [(AstType.Func args ret)
      (ctfe-type-syntax-call
        "->"
        (ctfe-func-type-to-expr-list (box-get args) (ctfe-ty-get env ret) env)
        env)]
    [(AstType.Tuple elems)
      (ctfe-type-syntax-call
        "Tuple"
        (ctfe-type-list-to-expr-list (box-get elems) env)
        env)]
    [(AstType.Array elem count)
      (ctfe-type-syntax-call
        "Array"
        (ast-expr-cons
          (ctfe-type-to-expr (ctfe-ty-get env elem) env)
          (ast-expr-cons
            (ctfe-ast-push env (AstExpr.Literal (ast-lit-int count)))
            (ast-expr-list-new)))
        env)]
    [(AstType.DynArray elem)
      (ctfe-type-syntax-call
        "Array"
        (ast-expr-cons
          (ctfe-type-to-expr (ctfe-ty-get env elem) env)
          (ast-expr-list-new))
        env)]
    [(AstType.Box elem)
      (ctfe-type-syntax-call
        "Box"
        (ast-expr-cons
          (ctfe-type-to-expr (ctfe-ty-get env elem) env)
          (ast-expr-list-new))
        env)]
    [(AstType.Ptr elem)
      (ctfe-type-syntax-call
        "Ptr"
        (ast-expr-cons
          (ctfe-type-to-expr (ctfe-ty-get env elem) env)
          (ast-expr-list-new))
        env)]
    [(AstType.MutPtr elem)
      (ctfe-type-syntax-call
        "MutPtr"
        (ast-expr-cons
          (ctfe-type-to-expr (ctfe-ty-get env elem) env)
          (ast-expr-list-new))
        env)]
    [(AstType.Ref region elem)
      (ctfe-type-syntax-call
        "&"
        (ast-expr-cons
          (ctfe-type-syntax-name region env)
          (ast-expr-cons
            (ctfe-type-to-expr (ctfe-ty-get env elem) env)
            (ast-expr-list-new)))
        env)]
    [(AstType.MutRef region elem)
      (ctfe-type-syntax-call
        "&mut"
        (ast-expr-cons
          (ctfe-type-syntax-name region env)
          (ast-expr-cons
            (ctfe-type-to-expr (ctfe-ty-get env elem) env)
            (ast-expr-list-new)))
        env)]
    [(AstType.Region region elem)
      (ctfe-type-syntax-call
        "in"
        (ast-expr-cons
          (ctfe-type-syntax-name region env)
          (ast-expr-cons
            (ctfe-type-to-expr (ctfe-ty-get env elem) env)
            (ast-expr-list-new)))
        env)]
    [(AstType.Enum name)
      (ctfe-resolved-nominal-type-to-expr
        (ctfe-internal-resolved-enum-type-marker)
        (intern-str name)
        (ast-lifetime-list-new)
        env)]
    [(AstType.EnumArgs name lifetimes)
      (ctfe-resolved-nominal-type-to-expr
        (ctfe-internal-resolved-enum-type-marker)
        (intern-str name)
        (box-get lifetimes)
        env)]
    [(AstType.Struct name)
      (ctfe-resolved-nominal-type-to-expr
        (ctfe-internal-resolved-struct-type-marker)
        (intern-str name)
        (ast-lifetime-list-new)
        env)]
    [(AstType.StructArgs name lifetimes)
      (ctfe-resolved-nominal-type-to-expr
        (ctfe-internal-resolved-struct-type-marker)
        (intern-str name)
        (box-get lifetimes)
        env)]
    [(AstType.Var name) (ctfe-type-syntax-name (intern-str name) env)]
    [(AstType.VarArgs name lifetimes)
      (ctfe-type-syntax-call
        (intern-str name)
        (ctfe-lifetime-list-to-expr-list (box-get lifetimes) env)
        env)]))

(define (ctfe-type-expr-error [origin : AstExpr]) : ResultCtfeQuoteType
  (ResultCtfeQuoteType.Err
    (box
      (ctfe-diagnostic-at-expr origin "type unquote expects a type expression"))))

(define (ctfe-expr-list-to-type-list
  [exprs : AstExprList]
  [origin : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfeQuoteTypeList
  (ctfe-expr-list-to-type-list-at (& exprs) 0 origin env fuel))

(define (ctfe-expr-list-to-type-list-at
  [exprs : (& exprs AstExprList)]
  [index : i64]
  [origin : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfeQuoteTypeList
  (if (>= index (struct-get exprs len))
    (ResultCtfeQuoteTypeList.Ok (ast-type-list-new) fuel)
    (let
      [head-expr : AstExpr (ctfe-ast-get env (ast-expr-list-get exprs index 0))]
      (match (ctfe-expr-to-type head-expr origin env fuel)
        [(ResultCtfeQuoteType.Ok head-ty head-fuel)
          (match (ctfe-expr-list-to-type-list-at
            exprs
            (+ index 1)
            origin
            env
            head-fuel)
            [(ResultCtfeQuoteTypeList.Ok tail tail-fuel)
              (ResultCtfeQuoteTypeList.Ok
                (ast-type-cons-with-pools (ctfe-env-pools env) head-ty tail)
                tail-fuel)]
            [(ResultCtfeQuoteTypeList.Err diag)
              (ResultCtfeQuoteTypeList.Err diag)])]
        [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteTypeList.Err diag)]))))

(define (ctfe-expr-unary-type
  [name : String]
  [args : AstExprList]
  [origin : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfeQuoteType
  (if (= (struct-get (& args) len) 1)
    (let
      [elem-expr : AstExpr (ctfe-ast-get env (ast-expr-list-get (& args) 0 0))]
      (match (ctfe-expr-to-type elem-expr origin env fuel)
        [(ResultCtfeQuoteType.Ok elem-ty next-fuel)
          (ResultCtfeQuoteType.Ok
            (cond
              [(string.eq name "Array")
                (ast-ty-dyn-array-with-pools (ctfe-env-pools env) elem-ty)]
              [(string.eq name "Box")
                (ast-ty-box-with-pools (ctfe-env-pools env) elem-ty)]
              [(string.eq name "Ptr")
                (ast-ty-ptr-with-pools (ctfe-env-pools env) elem-ty)]
              [(string.eq name "MutPtr")
                (ast-ty-mut-ptr-with-pools (ctfe-env-pools env) elem-ty)]
              [else elem-ty])
            next-fuel)]
        [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteType.Err diag)]))
    (ctfe-type-expr-error origin)))

(define (ctfe-expr-array-type
  [args : AstExprList]
  [origin : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfeQuoteType
  (if (or (= (struct-get (& args) len) 1) (= (struct-get (& args) len) 2))
    (let
      [elem-expr : AstExpr (ctfe-ast-get env (ast-expr-list-get (& args) 0 0))]
      (match (ctfe-expr-to-type elem-expr origin env fuel)
        [(ResultCtfeQuoteType.Ok elem-ty elem-fuel)
          (if (= (struct-get (& args) len) 1)
            (ResultCtfeQuoteType.Ok
              (ast-ty-dyn-array-with-pools (ctfe-env-pools env) elem-ty)
              elem-fuel)
            (let
              [len-expr : AstExpr
                (ctfe-ast-get env (ast-expr-list-get (& args) 1 0))]
              (match (ctfe-expr-unspan env len-expr)
                [(AstExpr.Literal (AstLiteral.Int count _))
                  (ResultCtfeQuoteType.Ok
                    (ast-ty-array-with-pools (ctfe-env-pools env) elem-ty count)
                    elem-fuel)]
                [_ (ctfe-type-expr-error origin)])))]
        [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteType.Err diag)]))
    (ctfe-type-expr-error origin)))

(define (ctfe-expr-func-type
  [args : AstExprList]
  [origin : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfeQuoteType
  (ctfe-expr-func-type-at (& args) 0 origin env fuel))

(define (ctfe-expr-func-type-at
  [args : (& args AstExprList)]
  [index : i64]
  [origin : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfeQuoteType
  (if (>= index (struct-get args len))
    (ctfe-type-expr-error origin)
    (let
      [head-expr : AstExpr (ctfe-ast-get env (ast-expr-list-get args index 0))]
      (if (= (+ index 1) (struct-get args len))
        (match (ctfe-expr-to-type head-expr origin env fuel)
          [(ResultCtfeQuoteType.Ok ret-ty next-fuel)
            (ResultCtfeQuoteType.Ok
              (ast-ty-func-with-pools
                (ctfe-env-pools env)
                (ast-type-list-new)
                ret-ty)
              next-fuel)]
          [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteType.Err diag)])
        (match (ctfe-expr-to-type head-expr origin env fuel)
          [(ResultCtfeQuoteType.Ok arg-ty arg-fuel)
            (match (ctfe-expr-func-type-at args (+ index 1) origin env arg-fuel)
              [(ResultCtfeQuoteType.Ok tail-fn next-fuel)
                (match tail-fn
                  [(AstType.Func tail-args ret)
                    (ResultCtfeQuoteType.Ok
                      (ast-ty-func-with-pools
                        (ctfe-env-pools env)
                        (ast-type-cons-with-pools
                          (ctfe-env-pools env)
                          arg-ty
                          (box-get tail-args))
                        (ctfe-ty-get env ret))
                      next-fuel)]
                  [_ (ctfe-type-expr-error origin)])]
              [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteType.Err diag)])]
          [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteType.Err diag)])))))

(define (ctfe-expr-reference-type
  [args : AstExprList]
  [origin : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]
  [mutable : bool]) : ResultCtfeQuoteType
  (if (= (struct-get (& args) len) 2)
    (let
      [region-expr : AstExpr
        (ctfe-ast-get env (ast-expr-list-get (& args) 0 0))]
      [inner-expr : AstExpr (ctfe-ast-get env (ast-expr-list-get (& args) 1 0))]
      (match (ctfe-expr-unspan env region-expr)
        [(AstExpr.Var region)
          (match (ctfe-expr-to-type inner-expr origin env fuel)
            [(ResultCtfeQuoteType.Ok inner-ty next-fuel)
              (ResultCtfeQuoteType.Ok
                (if mutable
                  (ast-ty-mut-ref-with-pools
                    (ctfe-env-pools env)
                    (intern-str region)
                    inner-ty)
                  (ast-ty-ref-with-pools
                    (ctfe-env-pools env)
                    (intern-str region)
                    inner-ty))
                next-fuel)]
            [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteType.Err diag)])]
        [_ (ctfe-type-expr-error origin)]))
    (ctfe-type-expr-error origin)))

(define (ctfe-expr-region-type
  [args : AstExprList]
  [origin : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfeQuoteType
  (if (= (struct-get (& args) len) 2)
    (let
      [region-expr : AstExpr
        (ctfe-ast-get env (ast-expr-list-get (& args) 0 0))]
      [inner-expr : AstExpr (ctfe-ast-get env (ast-expr-list-get (& args) 1 0))]
      (match (ctfe-expr-unspan env region-expr)
        [(AstExpr.Var region)
          (match (ctfe-expr-to-type inner-expr origin env fuel)
            [(ResultCtfeQuoteType.Ok inner-ty next-fuel)
              (ResultCtfeQuoteType.Ok
                (ast-ty-region-with-pools
                  (ctfe-env-pools env)
                  (intern-str region)
                  inner-ty)
                next-fuel)]
            [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteType.Err diag)])]
        [_ (ctfe-type-expr-error origin)]))
    (ctfe-type-expr-error origin)))

(define (ctfe-expr-list-to-lifetime-list
  [exprs : AstExprList]
  [env : CtfeEnv]
  [origin : AstExpr]) : ResultCtfeQuoteLifetimeList
  (ctfe-expr-list-to-lifetime-list-at (& exprs) 0 env origin))

(define (ctfe-expr-list-to-lifetime-list-at
  [exprs : (& exprs AstExprList)]
  [index : i64]
  [env : CtfeEnv]
  [origin : AstExpr]) : ResultCtfeQuoteLifetimeList
  (if (>= index (struct-get exprs len))
    (ResultCtfeQuoteLifetimeList.Ok (ast-lifetime-list-new))
    (let
      [head-expr : AstExpr (ctfe-ast-get env (ast-expr-list-get exprs index 0))]
      (match (ctfe-expr-unspan env head-expr)
        [(AstExpr.Var name)
          (match (ctfe-expr-list-to-lifetime-list-at
            exprs
            (+ index 1)
            env
            origin)
            [(ResultCtfeQuoteLifetimeList.Ok tail)
              (ResultCtfeQuoteLifetimeList.Ok
                (ast-lifetime-cons (intern-str name) tail))]
            [(ResultCtfeQuoteLifetimeList.Err diag)
              (ResultCtfeQuoteLifetimeList.Err diag)])]
        [_
          (ResultCtfeQuoteLifetimeList.Err
            (box
              (ctfe-diagnostic-at-expr
                origin
                "type unquote expects a type expression")))]))))

(define (ctfe-expr-resolved-nominal-type
  [args : AstExprList]
  [origin : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]
  [is-struct : bool]) : ResultCtfeQuoteType
  (if (> (struct-get (& args) len) 0)
    (let
      [name-expr : AstExpr (ctfe-ast-get env (ast-expr-list-get (& args) 0 0))]
      [lifetime-exprs : AstExprList (ast-expr-list-tail-from-ref (& args) 1)]
      (match (ctfe-expr-unspan env name-expr)
        [(AstExpr.Literal (AstLiteral.String name))
          (match (ctfe-expr-list-to-lifetime-list lifetime-exprs env origin)
            [(ResultCtfeQuoteLifetimeList.Ok lifetimes)
              (ResultCtfeQuoteType.Ok
                (if is-struct
                  (if (ast-lifetime-list-empty? (& lifetimes))
                    (AstType.Struct (intern name))
                    (ast-ty-struct-args (intern name) lifetimes))
                  (if (ast-lifetime-list-empty? (& lifetimes))
                    (AstType.Enum (intern name))
                    (ast-ty-enum-args (intern name) lifetimes)))
                fuel)]
            [(ResultCtfeQuoteLifetimeList.Err diag)
              (ResultCtfeQuoteType.Err diag)])]
        [_ (ctfe-type-expr-error origin)]))
    (ctfe-type-expr-error origin)))

(define (ctfe-expr-to-type
  [expr : AstExpr]
  [origin : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfeQuoteType
  (match (ctfe-expr-unspan env expr)
    [(AstExpr.TypeLiteral ty) (ResultCtfeQuoteType.Ok ty fuel)]
    [(AstExpr.Var name)
      (ResultCtfeQuoteType.Ok (ctfe-type-name-to-type (intern-str name)) fuel)]
    [(AstExpr.Call func-box args)
      (let
        [func : AstExpr (ctfe-ast-get env func-box)]
        (match (ctfe-expr-unspan env func)
          [(AstExpr.Var name)
            (let
              [head : String (intern-str name)]
              (cond
                [(string.eq head (ctfe-internal-resolved-struct-type-marker))
                  (ctfe-expr-resolved-nominal-type args origin env fuel true)]
                [(string.eq head (ctfe-internal-resolved-enum-type-marker))
                  (ctfe-expr-resolved-nominal-type args origin env fuel false)]
                [(string.eq head "->")
                  (ctfe-expr-func-type args origin env fuel)]
                [(string.eq head "Array")
                  (ctfe-expr-array-type args origin env fuel)]
                [(or
                    (string.eq head "Box")
                    (string.eq head "Ptr")
                    (string.eq head "MutPtr"))
                  (ctfe-expr-unary-type head args origin env fuel)]
                [(string.eq head "&")
                  (ctfe-expr-reference-type args origin env fuel false)]
                [(string.eq head "&mut")
                  (ctfe-expr-reference-type args origin env fuel true)]
                [(string.eq head "in")
                  (ctfe-expr-region-type args origin env fuel)]
                [(string.eq head "Tuple")
                  (match (ctfe-expr-list-to-type-list args origin env fuel)
                    [(ResultCtfeQuoteTypeList.Ok elems next-fuel)
                      (ResultCtfeQuoteType.Ok (ast-ty-tuple elems) next-fuel)]
                    [(ResultCtfeQuoteTypeList.Err diag)
                      (ResultCtfeQuoteType.Err diag)])]
                [else (ctfe-type-expr-error origin)]))]
          [_ (ctfe-type-expr-error origin)]))]
    [_ (ctfe-type-expr-error origin)]))

(define (ctfe-quote-type-unquote
  [lifetimes : AstLifetimeList]
  [env : CtfeEnv]
  [origin : AstExpr]
  [fuel : i64]) : ResultCtfeQuoteType
  (if (= (ast-lifetime-list-len (& lifetimes)) 1)
    (let
      [name : String
        (ast-lifetime-list-get (& lifetimes) 0 (ast-lifetime-fallback))]
      (match (ctfe-env-lookup env name)
        [(CtfeMaybeValue.Some value)
          (match value
            [(CompilerCtfeValue.Type ty) (ResultCtfeQuoteType.Ok ty fuel)]
            [(CompilerCtfeValue.Expr node _)
              (let
                [node-expr : AstExpr (ctfe-ast-get env node)]
                (ctfe-expr-to-type node-expr origin env fuel))]
            [_
              (ResultCtfeQuoteType.Err
                (box
                  (ctfe-diagnostic-at-expr
                    origin
                    "type unquote expects a type value")))])]
        [(CtfeMaybeValue.None)
          (ResultCtfeQuoteType.Err
            (box
              (ctfe-diagnostic-at-expr
                origin
                "type unquote references an unbound type parameter")))]))
    (if (= (ast-lifetime-list-len (& lifetimes)) 0)
      (ctfe-type-expr-error origin)
      (ResultCtfeQuoteType.Err
        (box
          (ctfe-diagnostic-at-expr
            origin
            "type unquote expects exactly one type parameter"))))))

(define (ctfe-quote-type-var [name : i64] [env : CtfeEnv] [fuel : i64]) : ResultCtfeQuoteType
  (match (ctfe-env-lookup env (intern-str name))
    [(CtfeMaybeValue.Some value)
      (match value
        [(CompilerCtfeValue.Type ty) (ResultCtfeQuoteType.Ok ty fuel)]
        [_ (ResultCtfeQuoteType.Ok (AstType.Var name) fuel)])]
    [(CtfeMaybeValue.None) (ResultCtfeQuoteType.Ok (AstType.Var name) fuel)]))

(define (ctfe-quote-type-list
  [types : AstTypeList]
  [env : CtfeEnv]
  [origin : AstExpr]
  [fuel : i64]) : ResultCtfeQuoteTypeList
  (ctfe-quote-type-list-at (& types) env origin fuel 0))

(define (ctfe-quote-type-list-at
  [types : (& types AstTypeList)]
  [env : CtfeEnv]
  [origin : AstExpr]
  [fuel : i64]
  [index : i64]) : ResultCtfeQuoteTypeList
  (if (>= index (ast-type-list-len types))
    (ResultCtfeQuoteTypeList.Ok (ast-type-list-new) fuel)
    (let
      [head : AstType
        (ctfe-ty-get env (ast-type-list-get types index (ast-type-id-fallback)))]
      (match (ctfe-quote-type head env origin fuel)
        [(ResultCtfeQuoteType.Ok quoted-head head-fuel)
          (match (ctfe-quote-type-list-at
            types
            env
            origin
            head-fuel
            (+ index 1))
            [(ResultCtfeQuoteTypeList.Ok quoted-rest rest-fuel)
              (ResultCtfeQuoteTypeList.Ok
                (ast-type-cons-with-pools
                  (ctfe-env-pools env)
                  quoted-head
                  quoted-rest)
                rest-fuel)]
            [(ResultCtfeQuoteTypeList.Err diag)
              (ResultCtfeQuoteTypeList.Err diag)])]
        [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteTypeList.Err diag)]))))

(define (ctfe-quote-type
  [ty : AstType]
  [env : CtfeEnv]
  [origin : AstExpr]
  [fuel : i64]) : ResultCtfeQuoteType
  (match ty
    [(AstType.Func args ret)
      (match (ctfe-quote-type-list (box-get args) env origin fuel)
        [(ResultCtfeQuoteTypeList.Ok quoted-args args-fuel)
          (match (ctfe-quote-type (ctfe-ty-get env ret) env origin args-fuel)
            [(ResultCtfeQuoteType.Ok quoted-ret ret-fuel)
              (ResultCtfeQuoteType.Ok
                (ast-ty-func-with-pools
                  (ctfe-env-pools env)
                  quoted-args
                  quoted-ret)
                ret-fuel)]
            [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteType.Err diag)])]
        [(ResultCtfeQuoteTypeList.Err diag) (ResultCtfeQuoteType.Err diag)])]
    [(AstType.Tuple elems)
      (match (ctfe-quote-type-list (box-get elems) env origin fuel)
        [(ResultCtfeQuoteTypeList.Ok quoted next-fuel)
          (ResultCtfeQuoteType.Ok (ast-ty-tuple quoted) next-fuel)]
        [(ResultCtfeQuoteTypeList.Err diag) (ResultCtfeQuoteType.Err diag)])]
    [(AstType.Array elem count)
      (match (ctfe-quote-type (ctfe-ty-get env elem) env origin fuel)
        [(ResultCtfeQuoteType.Ok quoted next-fuel)
          (ResultCtfeQuoteType.Ok
            (ast-ty-array-with-pools (ctfe-env-pools env) quoted count)
            next-fuel)]
        [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteType.Err diag)])]
    [(AstType.DynArray elem)
      (match (ctfe-quote-type (ctfe-ty-get env elem) env origin fuel)
        [(ResultCtfeQuoteType.Ok quoted next-fuel)
          (ResultCtfeQuoteType.Ok
            (ast-ty-dyn-array-with-pools (ctfe-env-pools env) quoted)
            next-fuel)]
        [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteType.Err diag)])]
    [(AstType.Box elem)
      (match (ctfe-quote-type (ctfe-ty-get env elem) env origin fuel)
        [(ResultCtfeQuoteType.Ok quoted next-fuel)
          (ResultCtfeQuoteType.Ok
            (ast-ty-box-with-pools (ctfe-env-pools env) quoted)
            next-fuel)]
        [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteType.Err diag)])]
    [(AstType.Ptr elem)
      (match (ctfe-quote-type (ctfe-ty-get env elem) env origin fuel)
        [(ResultCtfeQuoteType.Ok quoted next-fuel)
          (ResultCtfeQuoteType.Ok
            (ast-ty-ptr-with-pools (ctfe-env-pools env) quoted)
            next-fuel)]
        [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteType.Err diag)])]
    [(AstType.MutPtr elem)
      (match (ctfe-quote-type (ctfe-ty-get env elem) env origin fuel)
        [(ResultCtfeQuoteType.Ok quoted next-fuel)
          (ResultCtfeQuoteType.Ok
            (ast-ty-mut-ptr-with-pools (ctfe-env-pools env) quoted)
            next-fuel)]
        [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteType.Err diag)])]
    [(AstType.Ref region inner)
      (match (ctfe-quote-type (ctfe-ty-get env inner) env origin fuel)
        [(ResultCtfeQuoteType.Ok quoted next-fuel)
          (ResultCtfeQuoteType.Ok
            (ast-ty-ref-with-pools (ctfe-env-pools env) region quoted)
            next-fuel)]
        [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteType.Err diag)])]
    [(AstType.MutRef region inner)
      (match (ctfe-quote-type (ctfe-ty-get env inner) env origin fuel)
        [(ResultCtfeQuoteType.Ok quoted next-fuel)
          (ResultCtfeQuoteType.Ok
            (ast-ty-mut-ref-with-pools (ctfe-env-pools env) region quoted)
            next-fuel)]
        [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteType.Err diag)])]
    [(AstType.Region region inner)
      (match (ctfe-quote-type (ctfe-ty-get env inner) env origin fuel)
        [(ResultCtfeQuoteType.Ok quoted next-fuel)
          (ResultCtfeQuoteType.Ok
            (ast-ty-region-with-pools (ctfe-env-pools env) region quoted)
            next-fuel)]
        [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteType.Err diag)])]
    [(AstType.VarArgs name lifetimes)
      (if (= name (intern "unquote"))
        (ctfe-quote-type-unquote (box-get lifetimes) env origin fuel)
        (ResultCtfeQuoteType.Ok ty fuel))]
    [(AstType.Var name) (ctfe-quote-type-var name env fuel)]
    [_ (ResultCtfeQuoteType.Ok ty fuel)]))

(define (ctfe-quote-maybe-type
  [maybe-ty : AstMaybeType]
  [env : CtfeEnv]
  [origin : AstExpr]
  [fuel : i64]) : ResultCtfeQuoteMaybeType
  (match maybe-ty
    [(AstMaybeType.No) (ResultCtfeQuoteMaybeType.Ok AstMaybeType.No fuel)]
    [(AstMaybeType.Some ty)
      (match (ctfe-quote-type ty env origin fuel)
        [(ResultCtfeQuoteType.Ok quoted next-fuel)
          (ResultCtfeQuoteMaybeType.Ok (AstMaybeType.Some quoted) next-fuel)]
        [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteMaybeType.Err diag)])]))

(define (ctfe-quote-expr-list
  [exprs : AstExprList]
  [env : CtfeEnv]
  [fuel : i64]
  [quasiquote : bool]) : ResultCtfeQuoteExprList
  (ctfe-quote-expr-list-at (& exprs) 0 env fuel quasiquote))

(define (ctfe-quote-expr-list-at
  [exprs : (& exprs AstExprList)]
  [index : i64]
  [env : CtfeEnv]
  [fuel : i64]
  [quasiquote : bool]) : ResultCtfeQuoteExprList
  (if (>= index (struct-get exprs len))
    (ResultCtfeQuoteExprList.Ok (ast-expr-list-new) fuel)
    (let
      [head : AstExpr (ctfe-ast-get env (ast-expr-list-get exprs index 0))]
      (match (ctfe-expr-unspan env head)
        [(AstExpr.UnquoteSplicing inner-box)
          (let
            [inner : AstExpr (ctfe-ast-get env inner-box)]
            (if quasiquote
              (match (ctfe-eval-unquote-splice inner head env fuel)
                [(ResultCtfeQuoteExprList.Ok splice splice-fuel)
                  (match (ctfe-quote-expr-list-at
                    exprs
                    (+ index 1)
                    env
                    splice-fuel
                    quasiquote)
                    [(ResultCtfeQuoteExprList.Ok quoted-rest rest-fuel)
                      (ResultCtfeQuoteExprList.Ok
                        (ctfe-expr-list-append splice quoted-rest)
                        rest-fuel)]
                    [(ResultCtfeQuoteExprList.Err diag)
                      (ResultCtfeQuoteExprList.Err diag)])]
                [(ResultCtfeQuoteExprList.Err diag)
                  (ResultCtfeQuoteExprList.Err diag)])
              (match (ctfe-quote-expr head env fuel quasiquote)
                [(ResultCtfeQuoteExpr.Ok quoted-head _ head-fuel)
                  (match (ctfe-quote-expr-list-at
                    exprs
                    (+ index 1)
                    env
                    head-fuel
                    quasiquote)
                    [(ResultCtfeQuoteExprList.Ok quoted-rest rest-fuel)
                      (ResultCtfeQuoteExprList.Ok
                        (ast-expr-cons quoted-head quoted-rest)
                        rest-fuel)]
                    [(ResultCtfeQuoteExprList.Err diag)
                      (ResultCtfeQuoteExprList.Err diag)])]
                [(ResultCtfeQuoteExpr.Err diag)
                  (ResultCtfeQuoteExprList.Err diag)])))]
        [_
          (match (ctfe-quote-expr head env fuel quasiquote)
            [(ResultCtfeQuoteExpr.Ok quoted-head _ head-fuel)
              (match (ctfe-quote-expr-list-at
                exprs
                (+ index 1)
                env
                head-fuel
                quasiquote)
                [(ResultCtfeQuoteExprList.Ok quoted-rest rest-fuel)
                  (ResultCtfeQuoteExprList.Ok
                    (ast-expr-cons quoted-head quoted-rest)
                    rest-fuel)]
                [(ResultCtfeQuoteExprList.Err diag)
                  (ResultCtfeQuoteExprList.Err diag)])]
            [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExprList.Err diag)])]))))

(define (ctfe-quote-param-list [params : AstParamList] [env : CtfeEnv]) : AstParamList
  (let
    [out : AstParamList
      (ast-param-list-with-capacity (ast-param-list-len (& params)))]
    (begin
      (ctfe-quote-param-list-into (& params) 0 env (&mut out))
      out)))

(define (ctfe-quote-param-list-into
  [params : (& params AstParamList)]
  [index : i64]
  [env : CtfeEnv]
  [out : (&mut out AstParamList)]) : unit
  (if (>= index (ast-param-list-len params))
    unit
    (begin
      (match (ast-param-list-get params index (ast-param-fallback))
        [(AstParam.Param name ty comptime?)
          (ast-param-list-push
            out
            (AstParam.Param (ctfe-quote-name-id env name) ty comptime?))])
      (ctfe-quote-param-list-into params (+ index 1) env out))))

(define (ctfe-quote-pattern-list [patterns : AstPatternList] [env : CtfeEnv]) : AstPatternList
  (let
    [out : AstPatternList
      (ast-pattern-list-with-capacity (struct-get (& patterns) len))]
    (begin
      (ctfe-quote-pattern-list-into (& patterns) 0 env (&mut out))
      out)))

(define (ctfe-quote-pattern-list-into
  [patterns : (& patterns AstPatternList)]
  [index : i64]
  [env : CtfeEnv]
  [out : (&mut out AstPatternList)]) : unit
  (if (>= index (struct-get patterns len))
    unit
    (begin
      (ast-pattern-list-push
        out
        (ctfe-quote-pattern
          (ast-pattern-list-get patterns index (ast-pattern-fallback))
          env))
      (ctfe-quote-pattern-list-into patterns (+ index 1) env out))))

(define (ctfe-quote-pattern [pattern : AstPattern] [env : CtfeEnv]) : AstPattern
  (match pattern
    [(AstPattern.Var name maybe-ty)
      (AstPattern.Var (ctfe-quote-name-id env name) maybe-ty)]
    [(AstPattern.Tuple patterns-box)
      (let
        [patterns : AstPatternList (box-get patterns-box)]
        (ast-pat-tuple (ctfe-quote-pattern-list patterns env)))]
    [(AstPattern.Wildcard) AstPattern.Wildcard]
    [(AstPattern.Binding name)
      (AstPattern.Binding (ctfe-quote-name-id env name))]
    [(AstPattern.Variant name args-box)
      (let
        [args : AstPatternList (box-get args-box)]
        (ast-pat-variant-id name (ctfe-quote-pattern-list args env)))]
    [(AstPattern.Literal lit) (AstPattern.Literal lit)]))

(define (ctfe-quote-let-binding-list
  [bindings : AstLetBindingList]
  [env : CtfeEnv]
  [fuel : i64]
  [quasiquote : bool]) : ResultCtfeQuoteLetBindings
  (let
    [out : AstLetBindingList
      (ast-let-binding-list-with-capacity
        (ast-let-binding-list-len (& bindings)))]
    (match (ctfe-quote-let-binding-list-into
      (& bindings)
      0
      env
      fuel
      quasiquote
      (&mut out))
      [(ResultCtfeQuoteLetBindingsBuild.Ok out-fuel)
        (ResultCtfeQuoteLetBindings.Ok out out-fuel)]
      [(ResultCtfeQuoteLetBindingsBuild.Err diag)
        (ResultCtfeQuoteLetBindings.Err diag)])))

(define (ctfe-quote-let-binding-list-into
  [bindings : (& bindings AstLetBindingList)]
  [index : i64]
  [env : CtfeEnv]
  [fuel : i64]
  [quasiquote : bool]
  [out : (&mut out AstLetBindingList)]) : ResultCtfeQuoteLetBindingsBuild
  (if (>= index (ast-let-binding-list-len bindings))
    (ResultCtfeQuoteLetBindingsBuild.Ok fuel)
    (match (ast-let-binding-list-get bindings index (ast-let-binding-fallback))
      [(AstLetBinding.Binding name maybe-ty init-box)
        (let
          [init : AstExpr (ctfe-ast-get env init-box)]
          (match (ctfe-quote-maybe-type maybe-ty env init fuel)
            [(ResultCtfeQuoteMaybeType.Ok quoted-ty type-fuel)
              (match (ctfe-quote-expr init env type-fuel quasiquote)
                [(ResultCtfeQuoteExpr.Ok quoted-init _ init-fuel)
                  (begin
                    (ast-let-binding-list-push
                      out
                      (ast-let-binding-id
                        (ctfe-quote-name-id env name)
                        quoted-ty
                        quoted-init))
                    (ctfe-quote-let-binding-list-into
                      bindings
                      (+ index 1)
                      env
                      init-fuel
                      quasiquote
                      out))]
                [(ResultCtfeQuoteExpr.Err diag)
                  (ResultCtfeQuoteLetBindingsBuild.Err diag)])]
            [(ResultCtfeQuoteMaybeType.Err diag)
              (ResultCtfeQuoteLetBindingsBuild.Err diag)]))])))

(define (ctfe-quote-resource-binding-list
  [bindings : AstResourceBindingList]
  [env : CtfeEnv]
  [fuel : i64]
  [quasiquote : bool]) : ResultCtfeQuoteResourceBindings
  (let
    [out : AstResourceBindingList
      (ast-resource-binding-list-with-capacity
        (ast-resource-binding-list-len (& bindings)))]
    (match (ctfe-quote-resource-binding-list-into
      (& bindings)
      0
      env
      fuel
      quasiquote
      (&mut out))
      [(ResultCtfeQuoteResourceBindingsBuild.Ok out-fuel)
        (ResultCtfeQuoteResourceBindings.Ok out out-fuel)]
      [(ResultCtfeQuoteResourceBindingsBuild.Err diag)
        (ResultCtfeQuoteResourceBindings.Err diag)])))

(define (ctfe-quote-resource-binding-list-into
  [bindings : (& bindings AstResourceBindingList)]
  [index : i64]
  [env : CtfeEnv]
  [fuel : i64]
  [quasiquote : bool]
  [out : (&mut out AstResourceBindingList)]) : ResultCtfeQuoteResourceBindingsBuild
  (if (>= index (ast-resource-binding-list-len bindings))
    (ResultCtfeQuoteResourceBindingsBuild.Ok fuel)
    (match (ast-resource-binding-list-get
      bindings
      index
      (ast-resource-binding-fallback))
      [(AstResourceBinding.Binding name init-box cleanup-box)
        (let
          [init : AstExpr (ctfe-ast-get env init-box)]
          [cleanup : AstExpr (ctfe-ast-get env cleanup-box)]
          (match (ctfe-quote-expr init env fuel quasiquote)
            [(ResultCtfeQuoteExpr.Ok quoted-init _ init-fuel)
              (match (ctfe-quote-expr cleanup env init-fuel quasiquote)
                [(ResultCtfeQuoteExpr.Ok quoted-cleanup _ cleanup-fuel)
                  (begin
                    (ast-resource-binding-list-push
                      out
                      (ast-resource-binding-id
                        (ctfe-quote-name-id env name)
                        quoted-init
                        quoted-cleanup))
                    (ctfe-quote-resource-binding-list-into
                      bindings
                      (+ index 1)
                      env
                      cleanup-fuel
                      quasiquote
                      out))]
                [(ResultCtfeQuoteExpr.Err diag)
                  (ResultCtfeQuoteResourceBindingsBuild.Err diag)])]
            [(ResultCtfeQuoteExpr.Err diag)
              (ResultCtfeQuoteResourceBindingsBuild.Err diag)]))])))

(define (ctfe-quote-arm-list
  [arms : AstMatchArmList]
  [env : CtfeEnv]
  [fuel : i64]
  [quasiquote : bool]) : ResultCtfeQuoteArms
  (let
    [out : AstMatchArmList
      (ast-match-arm-list-with-capacity (struct-get (& arms) len))]
    (match (ctfe-quote-arm-list-into (& arms) 0 env fuel quasiquote (&mut out))
      [(ResultCtfeQuoteArmsBuild.Ok out-fuel)
        (ResultCtfeQuoteArms.Ok out out-fuel)]
      [(ResultCtfeQuoteArmsBuild.Err diag) (ResultCtfeQuoteArms.Err diag)])))

(define (ctfe-quote-arm-list-into
  [arms : (& arms AstMatchArmList)]
  [index : i64]
  [env : CtfeEnv]
  [fuel : i64]
  [quasiquote : bool]
  [out : (&mut out AstMatchArmList)]) : ResultCtfeQuoteArmsBuild
  (if (>= index (struct-get arms len))
    (ResultCtfeQuoteArmsBuild.Ok fuel)
    (match (ast-match-arm-list-get arms index (ast-match-arm-fallback))
      [(AstMatchArm.Arm pattern body-box)
        (let
          [body : AstExpr (ctfe-ast-get env body-box)]
          (match (ctfe-quote-expr body env fuel quasiquote)
            [(ResultCtfeQuoteExpr.Ok quoted-body _ body-fuel)
              (begin
                (ast-match-arm-list-push
                  out
                  (ast-match-arm (ctfe-quote-pattern pattern env) quoted-body))
                (ctfe-quote-arm-list-into
                  arms
                  (+ index 1)
                  env
                  body-fuel
                  quasiquote
                  out))]
            [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteArmsBuild.Err diag)]))])))

(define (ctfe-quote-preserve-unquoted-source-span?
  [template : AstExpr]
  [result-node : i64]
  [env : CtfeEnv]) : bool
  (match (ctfe-expr-unspan env template)
    [(AstExpr.Unquote _)
      (match (ctfe-ast-get env result-node)
        [(AstExpr.Spanned _ _) true]
        [_ false])]
    [_ false]))

(define (ctfe-quote-expr
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]
  [quasiquote : bool]) : ResultCtfeQuoteExpr
  (match expr
    [(AstExpr.Spanned inner-box span)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok node ty next-fuel)
            ;; An unquoted macro argument is already source-spanned at its
            ;; call site. Preserve that origin rather than covering it with
            ;; the template's quasiquote span, while retaining the template
            ;; span for synthetic expressions with no caller origin.
            (if (and
              quasiquote
              (ctfe-quote-preserve-unquoted-source-span? inner node env))
              (ResultCtfeQuoteExpr.Ok node ty next-fuel)
              (ResultCtfeQuoteExpr.Ok
                (ast-expr-spanned-with-pools (ctfe-env-pools env) node span)
                ty
                next-fuel))]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.Literal lit)
      (ResultCtfeQuoteExpr.Ok
        (ctfe-ast-push env expr)
        (ctfe-quote-literal-type lit)
        fuel)]
    [(AstExpr.Var name)
      (ResultCtfeQuoteExpr.Ok
        (ctfe-ast-push
          env
          (AstExpr.Var (intern (ctfe-quote-name env (intern-str name)))))
        (AstType.Expr)
        fuel)]
    [(AstExpr.Binary op left-box right-box)
      (let
        [left : AstExpr (ctfe-ast-get env left-box)]
        [right : AstExpr (ctfe-ast-get env right-box)]
        (match (ctfe-quote-expr left env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted-left _ left-fuel)
            (match (ctfe-quote-expr right env left-fuel quasiquote)
              [(ResultCtfeQuoteExpr.Ok quoted-right _ right-fuel)
                (ResultCtfeQuoteExpr.Ok
                  (ast-expr-binary-with-pools
                    (ctfe-env-pools env)
                    op
                    quoted-left
                    quoted-right)
                  (AstType.Expr)
                  right-fuel)]
              [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.Unary op inner-box)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted _ next-fuel)
            (ResultCtfeQuoteExpr.Ok
              (ast-expr-unary-with-pools (ctfe-env-pools env) op quoted)
              (AstType.Expr)
              next-fuel)]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.Call func-box args)
      (let
        [func : AstExpr (ctfe-ast-get env func-box)]
        (match (ctfe-quote-expr func env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted-func _ func-fuel)
            (match (ctfe-quote-expr-list args env func-fuel quasiquote)
              [(ResultCtfeQuoteExprList.Ok quoted-args args-fuel)
                (ResultCtfeQuoteExpr.Ok
                  (ast-expr-call-with-pools
                    (ctfe-env-pools env)
                    quoted-func
                    quoted-args)
                  (AstType.Expr)
                  args-fuel)]
              [(ResultCtfeQuoteExprList.Err diag)
                (ResultCtfeQuoteExpr.Err diag)])]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.BracketClause items)
      (match (ctfe-quote-expr-list items env fuel quasiquote)
        [(ResultCtfeQuoteExprList.Ok quoted-items next-fuel)
          (ResultCtfeQuoteExpr.Ok
            (ast-expr-bracket-clause-with-pools
              (ctfe-env-pools env)
              quoted-items)
            (AstType.Expr)
            next-fuel)]
        [(ResultCtfeQuoteExprList.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
    [(AstExpr.If cond-box then-branch-box else-branch-box)
      (let
        [cond : AstExpr (ctfe-ast-get env cond-box)]
        [then-branch : AstExpr (ctfe-ast-get env then-branch-box)]
        [else-branch : AstExpr (ctfe-ast-get env else-branch-box)]
        (match (ctfe-quote-expr cond env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted-cond cond-ty cond-fuel)
            (match (ctfe-quote-expr then-branch env cond-fuel quasiquote)
              [(ResultCtfeQuoteExpr.Ok quoted-then then-ty then-fuel)
                (match (ctfe-quote-expr else-branch env then-fuel quasiquote)
                  [(ResultCtfeQuoteExpr.Ok quoted-else else-ty else-fuel)
                    (ResultCtfeQuoteExpr.Ok
                      (ast-expr-if-with-pools
                        (ctfe-env-pools env)
                        quoted-cond
                        quoted-then
                        quoted-else)
                      (ctfe-quote-if-type cond-ty then-ty else-ty)
                      else-fuel)]
                  [(ResultCtfeQuoteExpr.Err diag)
                    (ResultCtfeQuoteExpr.Err diag)])]
              [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.Let let-box)
      (match (box-get let-box)
        [(AstLet.Let bindings body-box)
          (let
            [body : AstExpr (ctfe-ast-get env body-box)]
            (match (ctfe-quote-let-binding-list bindings env fuel quasiquote)
              [(ResultCtfeQuoteLetBindings.Ok quoted-bindings bindings-fuel)
                (match (ctfe-quote-expr body env bindings-fuel quasiquote)
                  [(ResultCtfeQuoteExpr.Ok quoted-body body-ty body-fuel)
                    (ResultCtfeQuoteExpr.Ok
                      (ast-expr-let-with-pools
                        (ctfe-env-pools env)
                        quoted-bindings
                        quoted-body)
                      body-ty
                      body-fuel)]
                  [(ResultCtfeQuoteExpr.Err diag)
                    (ResultCtfeQuoteExpr.Err diag)])]
              [(ResultCtfeQuoteLetBindings.Err diag)
                (ResultCtfeQuoteExpr.Err diag)]))])]
    [(AstExpr.Lambda lambda-box)
      (match (box-get lambda-box)
        [(AstLambda.Lambda params maybe-ret body-box)
          (let
            [body : AstExpr (ctfe-ast-get env body-box)]
            (match (ctfe-quote-expr body env fuel quasiquote)
              [(ResultCtfeQuoteExpr.Ok quoted-body _ next-fuel)
                (ResultCtfeQuoteExpr.Ok
                  (ast-expr-lambda-with-pools
                    (ctfe-env-pools env)
                    (ctfe-quote-param-list params env)
                    maybe-ret
                    quoted-body)
                  (AstType.Expr)
                  next-fuel)]
              [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))])]
    [(AstExpr.Tuple exprs)
      (match (ctfe-quote-expr-list exprs env fuel quasiquote)
        [(ResultCtfeQuoteExprList.Ok quoted next-fuel)
          (ResultCtfeQuoteExpr.Ok
            (ctfe-ast-push env (AstExpr.Tuple quoted))
            (AstType.Expr)
            next-fuel)]
        [(ResultCtfeQuoteExprList.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
    [(AstExpr.Array exprs)
      (match (ctfe-quote-expr-list exprs env fuel quasiquote)
        [(ResultCtfeQuoteExprList.Ok quoted next-fuel)
          (ResultCtfeQuoteExpr.Ok
            (ctfe-ast-push env (AstExpr.Array quoted))
            (AstType.Expr)
            next-fuel)]
        [(ResultCtfeQuoteExprList.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
    [(AstExpr.DynArray exprs)
      (match (ctfe-quote-expr-list exprs env fuel quasiquote)
        [(ResultCtfeQuoteExprList.Ok quoted next-fuel)
          (ResultCtfeQuoteExpr.Ok
            (ctfe-ast-push env (AstExpr.DynArray quoted))
            (AstType.Expr)
            next-fuel)]
        [(ResultCtfeQuoteExprList.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
    [(AstExpr.Begin exprs)
      (match (ctfe-quote-expr-list exprs env fuel quasiquote)
        [(ResultCtfeQuoteExprList.Ok quoted next-fuel)
          (ResultCtfeQuoteExpr.Ok
            (ctfe-ast-push env (AstExpr.Begin quoted))
            (AstType.Expr)
            next-fuel)]
        [(ResultCtfeQuoteExprList.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
    [(AstExpr.Unsafe exprs)
      (match (ctfe-quote-expr-list exprs env fuel quasiquote)
        [(ResultCtfeQuoteExprList.Ok quoted next-fuel)
          (ResultCtfeQuoteExpr.Ok
            (ctfe-ast-push env (AstExpr.Unsafe quoted))
            (AstType.Expr)
            next-fuel)]
        [(ResultCtfeQuoteExprList.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
    [(AstExpr.While cond-box body-box)
      (let
        [cond : AstExpr (ctfe-ast-get env cond-box)]
        [body : AstExpr (ctfe-ast-get env body-box)]
        (match (ctfe-quote-expr cond env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted-cond _ cond-fuel)
            (match (ctfe-quote-expr body env cond-fuel quasiquote)
              [(ResultCtfeQuoteExpr.Ok quoted-body _ body-fuel)
                (ResultCtfeQuoteExpr.Ok
                  (ast-expr-while-with-pools
                    (ctfe-env-pools env)
                    quoted-cond
                    quoted-body)
                  (AstType.Expr)
                  body-fuel)]
              [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.Set name rhs-box)
      (let
        [rhs : AstExpr (ctfe-ast-get env rhs-box)]
        (match (ctfe-quote-expr rhs env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted-rhs _ next-fuel)
            (ResultCtfeQuoteExpr.Ok
              (ast-expr-set-id-with-pools
                (ctfe-env-pools env)
                (ctfe-quote-name-id env name)
                quoted-rhs)
              (AstType.Expr)
              next-fuel)]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.Ann inner-box ty)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted _ expr-fuel)
            (match (ctfe-quote-type ty env expr expr-fuel)
              [(ResultCtfeQuoteType.Ok quoted-ty next-fuel)
                (ResultCtfeQuoteExpr.Ok
                  (ast-expr-ann-with-pools
                    (ctfe-env-pools env)
                    quoted
                    quoted-ty)
                  quoted-ty
                  next-fuel)]
              [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.Cast inner-box ty)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted _ expr-fuel)
            (match (ctfe-quote-type ty env expr expr-fuel)
              [(ResultCtfeQuoteType.Ok quoted-ty next-fuel)
                (ResultCtfeQuoteExpr.Ok
                  (ast-expr-cast-with-pools
                    (ctfe-env-pools env)
                    quoted
                    quoted-ty)
                  quoted-ty
                  next-fuel)]
              [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.TypeLiteral ty)
      (match (ctfe-quote-type ty env expr fuel)
        [(ResultCtfeQuoteType.Ok quoted-ty next-fuel)
          (ResultCtfeQuoteExpr.Ok
            (ctfe-ast-push env (AstExpr.TypeLiteral quoted-ty))
            (AstType.Expr)
            next-fuel)]
        [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
    [(AstExpr.Borrow mutable lifetime place-box)
      (let
        [place : AstExpr (ctfe-ast-get env place-box)]
        (match (ctfe-quote-expr place env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted-place _ next-fuel)
            (ResultCtfeQuoteExpr.Ok
              (ast-expr-borrow-with-pools
                (ctfe-env-pools env)
                mutable
                lifetime
                quoted-place)
              (AstType.Expr)
              next-fuel)]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.Match match-box)
      (match (box-get match-box)
        [(AstMatch.Match scrut-box arms)
          (let
            [scrut : AstExpr (ctfe-ast-get env scrut-box)]
            (match (ctfe-quote-expr scrut env fuel quasiquote)
              [(ResultCtfeQuoteExpr.Ok quoted-scrut _ scrut-fuel)
                (match (ctfe-quote-arm-list arms env scrut-fuel quasiquote)
                  [(ResultCtfeQuoteArms.Ok quoted-arms arms-fuel)
                    (ResultCtfeQuoteExpr.Ok
                      (ast-expr-match-with-pools
                        (ctfe-env-pools env)
                        quoted-scrut
                        quoted-arms)
                      (AstType.Expr)
                      arms-fuel)]
                  [(ResultCtfeQuoteArms.Err diag)
                    (ResultCtfeQuoteExpr.Err diag)])]
              [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))])]
    [(AstExpr.Foreach fe-box)
      (match (box-get fe-box)
        [(AstForeach.Foreach index index-ty start-box end-box body-box)
          (let
            [start : AstExpr (ctfe-ast-get env start-box)]
            [end : AstExpr (ctfe-ast-get env end-box)]
            [body : AstExpr (ctfe-ast-get env body-box)]
            (match (ctfe-quote-expr start env fuel quasiquote)
              [(ResultCtfeQuoteExpr.Ok quoted-start _ start-fuel)
                (match (ctfe-quote-expr end env start-fuel quasiquote)
                  [(ResultCtfeQuoteExpr.Ok quoted-end _ end-fuel)
                    (match (ctfe-quote-expr body env end-fuel quasiquote)
                      [(ResultCtfeQuoteExpr.Ok quoted-body _ body-fuel)
                        (ResultCtfeQuoteExpr.Ok
                          (ast-expr-foreach-id-with-pools
                            (ctfe-env-pools env)
                            (ctfe-quote-name-id env index)
                            index-ty
                            quoted-start
                            quoted-end
                            quoted-body)
                          (AstType.Expr)
                          body-fuel)]
                      [(ResultCtfeQuoteExpr.Err diag)
                        (ResultCtfeQuoteExpr.Err diag)])]
                  [(ResultCtfeQuoteExpr.Err diag)
                    (ResultCtfeQuoteExpr.Err diag)])]
              [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))])]
    [(AstExpr.SpmdReduce reduce-box)
      (match (box-get reduce-box)
        [(AstSpmdReduce.Reduce
            op
            index
            index-ty
            start-box
            end-box
            init-box
            value-box)
          (let
            [start : AstExpr (ctfe-ast-get env start-box)]
            [end : AstExpr (ctfe-ast-get env end-box)]
            [init : AstExpr (ctfe-ast-get env init-box)]
            [value : AstExpr (ctfe-ast-get env value-box)]
            (match (ctfe-quote-expr start env fuel quasiquote)
              [(ResultCtfeQuoteExpr.Ok quoted-start _ start-fuel)
                (match (ctfe-quote-expr end env start-fuel quasiquote)
                  [(ResultCtfeQuoteExpr.Ok quoted-end _ end-fuel)
                    (match (ctfe-quote-expr init env end-fuel quasiquote)
                      [(ResultCtfeQuoteExpr.Ok quoted-init _ init-fuel)
                        (match (ctfe-quote-expr value env init-fuel quasiquote)
                          [(ResultCtfeQuoteExpr.Ok quoted-value _ value-fuel)
                            (ResultCtfeQuoteExpr.Ok
                              (ast-expr-spmd-reduce-id-with-pools
                                (ctfe-env-pools env)
                                op
                                (ctfe-quote-name-id env index)
                                index-ty
                                quoted-start
                                quoted-end
                                quoted-init
                                quoted-value)
                              (AstType.Expr)
                              value-fuel)]
                          [(ResultCtfeQuoteExpr.Err diag)
                            (ResultCtfeQuoteExpr.Err diag)])]
                      [(ResultCtfeQuoteExpr.Err diag)
                        (ResultCtfeQuoteExpr.Err diag)])]
                  [(ResultCtfeQuoteExpr.Err diag)
                    (ResultCtfeQuoteExpr.Err diag)])]
              [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))])]
    [(AstExpr.SpmdScan scan-box)
      (match (box-get scan-box)
        [(AstSpmdScan.Scan
            op
            index
            index-ty
            start-box
            end-box
            prefix
            prefix-ty
            init-box
            value-box
            body-box)
          (let
            [start : AstExpr (ctfe-ast-get env start-box)]
            [end : AstExpr (ctfe-ast-get env end-box)]
            [init : AstExpr (ctfe-ast-get env init-box)]
            [value : AstExpr (ctfe-ast-get env value-box)]
            [body : AstExpr (ctfe-ast-get env body-box)]
            (match (ctfe-quote-expr start env fuel quasiquote)
              [(ResultCtfeQuoteExpr.Ok quoted-start _ start-fuel)
                (match (ctfe-quote-expr end env start-fuel quasiquote)
                  [(ResultCtfeQuoteExpr.Ok quoted-end _ end-fuel)
                    (match (ctfe-quote-expr init env end-fuel quasiquote)
                      [(ResultCtfeQuoteExpr.Ok quoted-init _ init-fuel)
                        (match (ctfe-quote-expr value env init-fuel quasiquote)
                          [(ResultCtfeQuoteExpr.Ok quoted-value _ value-fuel)
                            (match (ctfe-quote-expr
                              body
                              env
                              value-fuel
                              quasiquote)
                              [(ResultCtfeQuoteExpr.Ok quoted-body _ body-fuel)
                                (ResultCtfeQuoteExpr.Ok
                                  (ast-expr-spmd-scan-id-with-pools
                                    (ctfe-env-pools env)
                                    op
                                    (ctfe-quote-name-id env index)
                                    index-ty
                                    quoted-start
                                    quoted-end
                                    (ctfe-quote-name-id env prefix)
                                    prefix-ty
                                    quoted-init
                                    quoted-value
                                    quoted-body)
                                  (AstType.Expr)
                                  body-fuel)]
                              [(ResultCtfeQuoteExpr.Err diag)
                                (ResultCtfeQuoteExpr.Err diag)])]
                          [(ResultCtfeQuoteExpr.Err diag)
                            (ResultCtfeQuoteExpr.Err diag)])]
                      [(ResultCtfeQuoteExpr.Err diag)
                        (ResultCtfeQuoteExpr.Err diag)])]
                  [(ResultCtfeQuoteExpr.Err diag)
                    (ResultCtfeQuoteExpr.Err diag)])]
              [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))])]
    [(AstExpr.SpmdBroadcast value-box lane-box)
      (let
        [value : AstExpr (ctfe-ast-get env value-box)]
        [lane : AstExpr (ctfe-ast-get env lane-box)]
        (match (ctfe-quote-expr value env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted-value _ value-fuel)
            (match (ctfe-quote-expr lane env value-fuel quasiquote)
              [(ResultCtfeQuoteExpr.Ok quoted-lane _ lane-fuel)
                (ResultCtfeQuoteExpr.Ok
                  (ast-expr-spmd-broadcast-with-pools
                    (ctfe-env-pools env)
                    quoted-value
                    quoted-lane)
                  (AstType.Expr)
                  lane-fuel)]
              [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.SpmdShuffle value-box lane-box)
      (let
        [value : AstExpr (ast-node-get value-box)]
        [lane : AstExpr (ast-node-get lane-box)]
        (match (ctfe-quote-expr value env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted-value _ value-fuel)
            (match (ctfe-quote-expr lane env value-fuel quasiquote)
              [(ResultCtfeQuoteExpr.Ok quoted-lane _ lane-fuel)
                (ResultCtfeQuoteExpr.Ok
                  (ast-expr-spmd-shuffle quoted-value quoted-lane)
                  (AstType.Expr)
                  lane-fuel)]
              [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.SpmdProgramIndex)
      (ResultCtfeQuoteExpr.Ok
        (ast-expr-spmd-program-index-with-pools (ctfe-env-pools env))
        (AstType.Expr)
        fuel)]
    [(AstExpr.SpmdProgramCount)
      (ResultCtfeQuoteExpr.Ok
        (ast-expr-spmd-program-count-with-pools (ctfe-env-pools env))
        (AstType.Expr)
        fuel)]
    [(AstExpr.StructGet inner-box field)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted _ next-fuel)
            (ResultCtfeQuoteExpr.Ok
              (ast-expr-struct-get-id-with-pools
                (ctfe-env-pools env)
                quoted
                field)
              (AstType.Expr)
              next-fuel)]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.StructSet inner-box field value-box)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        [value : AstExpr (ctfe-ast-get env value-box)]
        (if (= field (ast-expr-unquote-set-target-field-id))
          (match (ctfe-expr-unspan env inner)
            [(AstExpr.Unquote target-box)
              (if quasiquote
                (let
                  [target : AstExpr (ctfe-ast-get env target-box)]
                  (match (ctfe-eval-unquote-expr target inner env fuel)
                    [(ResultCtfeQuoteExpr.Ok quoted-target _ target-fuel)
                      (match (ctfe-quote-expr value env target-fuel quasiquote)
                        [(ResultCtfeQuoteExpr.Ok quoted-value _ value-fuel)
                          (match (ctfe-expr-unspan
                            env
                            (ctfe-ast-get env quoted-target))
                            [(AstExpr.Var name)
                              (ResultCtfeQuoteExpr.Ok
                                (ast-expr-set-id-with-pools
                                  (ctfe-env-pools env)
                                  name
                                  quoted-value)
                                (AstType.Expr)
                                value-fuel)]
                            [(AstExpr.StructGet receiver-box target-field)
                              (ResultCtfeQuoteExpr.Ok
                                (ast-expr-struct-set-id-with-pools
                                  (ctfe-env-pools env)
                                  receiver-box
                                  target-field
                                  quoted-value)
                                (AstType.Expr)
                                value-fuel)]
                            [(AstExpr.BoxGet receiver-box)
                              (ResultCtfeQuoteExpr.Ok
                                (ast-expr-box-set-with-pools
                                  (ctfe-env-pools env)
                                  receiver-box
                                  quoted-value)
                                (AstType.Expr)
                                value-fuel)]
                            [_
                              (ResultCtfeQuoteExpr.Err
                                (box
                                  (ctfe-diagnostic-at-expr
                                    inner
                                    "quasiquote set! target must evaluate to a name, struct field place, or box place")))])]
                        [(ResultCtfeQuoteExpr.Err diag)
                          (ResultCtfeQuoteExpr.Err diag)])]
                    [(ResultCtfeQuoteExpr.Err diag)
                      (ResultCtfeQuoteExpr.Err diag)]))
                (ResultCtfeQuoteExpr.Err
                  (box
                    (ctfe-diagnostic-at-expr
                      inner
                      "unquote set! target is only valid inside quasiquote"))))]
            [_
              (ResultCtfeQuoteExpr.Err
                (box
                  (ctfe-diagnostic-at-expr
                    inner
                    "internal unquote set! target must be an unquote form")))])
          (match (ctfe-quote-expr inner env fuel quasiquote)
            [(ResultCtfeQuoteExpr.Ok quoted-inner _ inner-fuel)
              (match (ctfe-quote-expr value env inner-fuel quasiquote)
                [(ResultCtfeQuoteExpr.Ok quoted-value _ value-fuel)
                  (ResultCtfeQuoteExpr.Ok
                    (ast-expr-struct-set-id-with-pools
                      (ctfe-env-pools env)
                      quoted-inner
                      field
                      quoted-value)
                    (AstType.Expr)
                    value-fuel)]
                [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
            [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)])))]
    [(AstExpr.TupleRef tuple-expr-box index)
      (let
        [tuple-expr : AstExpr (ctfe-ast-get env tuple-expr-box)]
        (match (ctfe-quote-expr tuple-expr env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted _ next-fuel)
            (ResultCtfeQuoteExpr.Ok
              (ast-expr-tuple-ref-with-pools (ctfe-env-pools env) quoted index)
              (AstType.Expr)
              next-fuel)]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.MakeArray ty len-box)
      (let
        [len : AstExpr (ctfe-ast-get env len-box)]
        (match (ctfe-quote-type ty env expr fuel)
          [(ResultCtfeQuoteType.Ok quoted-ty type-fuel)
            (match (ctfe-quote-expr len env type-fuel quasiquote)
              [(ResultCtfeQuoteExpr.Ok quoted-len _ next-fuel)
                (ResultCtfeQuoteExpr.Ok
                  (ast-expr-make-array-with-pools
                    (ctfe-env-pools env)
                    quoted-ty
                    quoted-len)
                  (AstType.Expr)
                  next-fuel)]
              [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
          [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.ArrayRef array-box index-box)
      (let
        [array : AstExpr (ctfe-ast-get env array-box)]
        [index : AstExpr (ctfe-ast-get env index-box)]
        (match (ctfe-quote-expr array env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted-array _ array-fuel)
            (match (ctfe-quote-expr index env array-fuel quasiquote)
              [(ResultCtfeQuoteExpr.Ok quoted-index _ index-fuel)
                (ResultCtfeQuoteExpr.Ok
                  (ast-expr-array-ref-with-pools
                    (ctfe-env-pools env)
                    quoted-array
                    quoted-index)
                  (AstType.Expr)
                  index-fuel)]
              [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.ArraySet array-box index-box value-box)
      (let
        [array : AstExpr (ctfe-ast-get env array-box)]
        [index : AstExpr (ctfe-ast-get env index-box)]
        [value : AstExpr (ctfe-ast-get env value-box)]
        (match (ctfe-quote-expr array env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted-array _ array-fuel)
            (match (ctfe-quote-expr index env array-fuel quasiquote)
              [(ResultCtfeQuoteExpr.Ok quoted-index _ index-fuel)
                (match (ctfe-quote-expr value env index-fuel quasiquote)
                  [(ResultCtfeQuoteExpr.Ok quoted-value _ value-fuel)
                    (ResultCtfeQuoteExpr.Ok
                      (ast-expr-array-set-with-pools
                        (ctfe-env-pools env)
                        quoted-array
                        quoted-index
                        quoted-value)
                      (AstType.Expr)
                      value-fuel)]
                  [(ResultCtfeQuoteExpr.Err diag)
                    (ResultCtfeQuoteExpr.Err diag)])]
              [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.ArrayTake array-box live-box index-box)
      (let
        [array : AstExpr (ctfe-ast-get env array-box)]
        [live : AstExpr (ctfe-ast-get env live-box)]
        [index : AstExpr (ctfe-ast-get env index-box)]
        (match (ctfe-quote-expr array env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted-array _ array-fuel)
            (match (ctfe-quote-expr live env array-fuel quasiquote)
              [(ResultCtfeQuoteExpr.Ok quoted-live _ live-fuel)
                (match (ctfe-quote-expr index env live-fuel quasiquote)
                  [(ResultCtfeQuoteExpr.Ok quoted-index _ index-fuel)
                    (ResultCtfeQuoteExpr.Ok
                      (ast-expr-array-take-with-pools
                        (ctfe-env-pools env)
                        quoted-array
                        quoted-live
                        quoted-index)
                      (AstType.Expr)
                      index-fuel)]
                  [(ResultCtfeQuoteExpr.Err diag)
                    (ResultCtfeQuoteExpr.Err diag)])]
              [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.ArrayPush array-box value-box)
      (let
        [array : AstExpr (ctfe-ast-get env array-box)]
        [value : AstExpr (ctfe-ast-get env value-box)]
        (match (ctfe-quote-expr array env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted-array _ array-fuel)
            (match (ctfe-quote-expr value env array-fuel quasiquote)
              [(ResultCtfeQuoteExpr.Ok quoted-value _ value-fuel)
                (ResultCtfeQuoteExpr.Ok
                  (ast-expr-array-push-with-pools
                    (ctfe-env-pools env)
                    quoted-array
                    quoted-value)
                  (AstType.Expr)
                  value-fuel)]
              [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.StringRef text-box index-box)
      (let
        [text : AstExpr (ctfe-ast-get env text-box)]
        [index : AstExpr (ctfe-ast-get env index-box)]
        (match (ctfe-quote-expr text env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted-text _ text-fuel)
            (match (ctfe-quote-expr index env text-fuel quasiquote)
              [(ResultCtfeQuoteExpr.Ok quoted-index _ index-fuel)
                (ResultCtfeQuoteExpr.Ok
                  (ast-expr-string-ref-with-pools
                    (ctfe-env-pools env)
                    quoted-text
                    quoted-index)
                  (AstType.Expr)
                  index-fuel)]
              [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.WithRegion name body)
      (match (ctfe-quote-expr-list body env fuel quasiquote)
        [(ResultCtfeQuoteExprList.Ok quoted-body next-fuel)
          (ResultCtfeQuoteExpr.Ok
            (ctfe-ast-push
              env
              (AstExpr.WithRegion (ctfe-quote-name env name) quoted-body))
            (AstType.Expr)
            next-fuel)]
        [(ResultCtfeQuoteExprList.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
    [(AstExpr.WithEscape scratch-box body)
      (let
        [scratch : AstExpr (ctfe-ast-get env scratch-box)]
        (match (ctfe-quote-expr scratch env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted-scratch _ scratch-fuel)
            (match (ctfe-quote-expr-list body env scratch-fuel quasiquote)
              [(ResultCtfeQuoteExprList.Ok quoted-body body-fuel)
                (ResultCtfeQuoteExpr.Ok
                  (ast-expr-with-escape-with-pools
                    (ctfe-env-pools env)
                    quoted-scratch
                    quoted-body)
                  (AstType.Expr)
                  body-fuel)]
              [(ResultCtfeQuoteExprList.Err diag)
                (ResultCtfeQuoteExpr.Err diag)])]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.WithScratch body)
      (match (ctfe-quote-expr-list body env fuel quasiquote)
        [(ResultCtfeQuoteExprList.Ok quoted-body body-fuel)
          (ResultCtfeQuoteExpr.Ok
            (ast-expr-with-scratch-with-pools (ctfe-env-pools env) quoted-body)
            (AstType.Expr)
            body-fuel)]
        [(ResultCtfeQuoteExprList.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
    [(AstExpr.InArena arena-box body)
      (let
        [arena : AstExpr (ctfe-ast-get env arena-box)]
        (match (ctfe-quote-expr arena env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted-arena _ arena-fuel)
            (match (ctfe-quote-expr-list body env arena-fuel quasiquote)
              [(ResultCtfeQuoteExprList.Ok quoted-body body-fuel)
                (ResultCtfeQuoteExpr.Ok
                  (ast-expr-in-arena-with-pools
                    (ctfe-env-pools env)
                    quoted-arena
                    quoted-body)
                  (AstType.Expr)
                  body-fuel)]
              [(ResultCtfeQuoteExprList.Err diag)
                (ResultCtfeQuoteExpr.Err diag)])]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.WithResource wr-box)
      (match (box-get wr-box)
        [(AstWithResource.WithResource bindings body)
          (match (ctfe-quote-resource-binding-list bindings env fuel quasiquote)
            [(ResultCtfeQuoteResourceBindings.Ok quoted-bindings bindings-fuel)
              (match (ctfe-quote-expr-list body env bindings-fuel quasiquote)
                [(ResultCtfeQuoteExprList.Ok quoted-body body-fuel)
                  (ResultCtfeQuoteExpr.Ok
                    (ctfe-ast-push
                      env
                      (AstExpr.WithResource
                        (box
                          (AstWithResource.WithResource
                            quoted-bindings
                            quoted-body))))
                    (AstType.Expr)
                    body-fuel)]
                [(ResultCtfeQuoteExprList.Err diag)
                  (ResultCtfeQuoteExpr.Err diag)])]
            [(ResultCtfeQuoteResourceBindings.Err diag)
              (ResultCtfeQuoteExpr.Err diag)])])]
    [(AstExpr.Box inner-box)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted _ next-fuel)
            (ResultCtfeQuoteExpr.Ok
              (ast-expr-box-with-pools (ctfe-env-pools env) quoted)
              (AstType.Expr)
              next-fuel)]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.BoxGet inner-box)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted _ next-fuel)
            (ResultCtfeQuoteExpr.Ok
              (ast-expr-box-get-with-pools (ctfe-env-pools env) quoted)
              (AstType.Expr)
              next-fuel)]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.BoxTake inner-box)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted _ next-fuel)
            (ResultCtfeQuoteExpr.Ok
              (ast-expr-box-take-with-pools (ctfe-env-pools env) quoted)
              (AstType.Expr)
              next-fuel)]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.BoxSet inner-box value-box)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        [value : AstExpr (ctfe-ast-get env value-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted-inner _ inner-fuel)
            (match (ctfe-quote-expr value env inner-fuel quasiquote)
              [(ResultCtfeQuoteExpr.Ok quoted-value _ value-fuel)
                (ResultCtfeQuoteExpr.Ok
                  (ast-expr-box-set-with-pools
                    (ctfe-env-pools env)
                    quoted-inner
                    quoted-value)
                  (AstType.Expr)
                  value-fuel)]
              [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.Comptime inner-box)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted ty next-fuel)
            (ResultCtfeQuoteExpr.Ok
              (ast-expr-comptime-with-pools (ctfe-env-pools env) quoted)
              ty
              next-fuel)]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.Return inner-box)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted _ next-fuel)
            (ResultCtfeQuoteExpr.Ok
              (ast-expr-return-with-pools (ctfe-env-pools env) quoted)
              (AstType.Expr)
              next-fuel)]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.Try inner-box)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted _ next-fuel)
            (ResultCtfeQuoteExpr.Ok
              (ast-expr-try-with-pools (ctfe-env-pools env) quoted)
              (AstType.Expr)
              next-fuel)]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.Break)
      (ResultCtfeQuoteExpr.Ok
        (ast-expr-break-with-pools (ctfe-env-pools env))
        (AstType.Expr)
        fuel)]
    [(AstExpr.Continue)
      (ResultCtfeQuoteExpr.Ok
        (ast-expr-continue-with-pools (ctfe-env-pools env))
        (AstType.Expr)
        fuel)]
    [(AstExpr.Init maybe-ty)
      (match (ctfe-quote-maybe-type maybe-ty env expr fuel)
        [(ResultCtfeQuoteMaybeType.Ok quoted-ty next-fuel)
          (ResultCtfeQuoteExpr.Ok
            (ast-expr-init-maybe-with-pools (ctfe-env-pools env) quoted-ty)
            (AstType.Expr)
            next-fuel)]
        [(ResultCtfeQuoteMaybeType.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
    [(AstExpr.PtrNull ty)
      (match (ctfe-quote-type ty env expr fuel)
        [(ResultCtfeQuoteType.Ok quoted-ty next-fuel)
          (ResultCtfeQuoteExpr.Ok
            (ctfe-ast-push env (AstExpr.PtrNull quoted-ty))
            (AstType.Expr)
            next-fuel)]
        [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
    [(AstExpr.PtrNullCheck ptr-box)
      (let
        [ptr : AstExpr (ctfe-ast-get env ptr-box)]
        (match (ctfe-quote-expr ptr env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted _ next-fuel)
            (ResultCtfeQuoteExpr.Ok
              (ast-expr-ptr-null-check-with-pools (ctfe-env-pools env) quoted)
              (AstType.Expr)
              next-fuel)]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.PtrAddrOf place-box)
      (let
        [place : AstExpr (ctfe-ast-get env place-box)]
        (match (ctfe-quote-expr place env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted _ next-fuel)
            (ResultCtfeQuoteExpr.Ok
              (ast-expr-ptr-addr-of-id-with-pools (ctfe-env-pools env) quoted)
              (AstType.Expr)
              next-fuel)]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.PtrRead ptr-box)
      (let
        [ptr : AstExpr (ctfe-ast-get env ptr-box)]
        (match (ctfe-quote-expr ptr env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted _ next-fuel)
            (ResultCtfeQuoteExpr.Ok
              (ast-expr-ptr-read-with-pools (ctfe-env-pools env) quoted)
              (AstType.Expr)
              next-fuel)]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.PtrWrite ptr-box value-box)
      (let
        [ptr : AstExpr (ctfe-ast-get env ptr-box)]
        [value : AstExpr (ctfe-ast-get env value-box)]
        (match (ctfe-quote-expr ptr env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted-ptr _ ptr-fuel)
            (match (ctfe-quote-expr value env ptr-fuel quasiquote)
              [(ResultCtfeQuoteExpr.Ok quoted-value _ value-fuel)
                (ResultCtfeQuoteExpr.Ok
                  (ast-expr-ptr-write-with-pools
                    (ctfe-env-pools env)
                    quoted-ptr
                    quoted-value)
                  (AstType.Expr)
                  value-fuel)]
              [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.PtrOffset ptr-box offset-box)
      (let
        [ptr : AstExpr (ctfe-ast-get env ptr-box)]
        [offset : AstExpr (ctfe-ast-get env offset-box)]
        (match (ctfe-quote-expr ptr env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted-ptr _ ptr-fuel)
            (match (ctfe-quote-expr offset env ptr-fuel quasiquote)
              [(ResultCtfeQuoteExpr.Ok quoted-offset _ offset-fuel)
                (ResultCtfeQuoteExpr.Ok
                  (ast-expr-ptr-offset-with-pools
                    (ctfe-env-pools env)
                    quoted-ptr
                    quoted-offset)
                  (AstType.Expr)
                  offset-fuel)]
              [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.PtrCast ptr-box ty)
      (let
        [ptr : AstExpr (ctfe-ast-get env ptr-box)]
        (match (ctfe-quote-expr ptr env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted _ expr-fuel)
            (match (ctfe-quote-type ty env expr expr-fuel)
              [(ResultCtfeQuoteType.Ok quoted-ty next-fuel)
                (ResultCtfeQuoteExpr.Ok
                  (ast-expr-ptr-cast-with-pools
                    (ctfe-env-pools env)
                    quoted
                    quoted-ty)
                  (AstType.Expr)
                  next-fuel)]
              [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.PtrToInt ptr-box)
      (let
        [ptr : AstExpr (ctfe-ast-get env ptr-box)]
        (match (ctfe-quote-expr ptr env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted _ next-fuel)
            (ResultCtfeQuoteExpr.Ok
              (ast-expr-ptr-to-int-with-pools (ctfe-env-pools env) quoted)
              (AstType.Expr)
              next-fuel)]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.IntToPtr value-box ty)
      (let
        [value : AstExpr (ctfe-ast-get env value-box)]
        (match (ctfe-quote-expr value env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted _ expr-fuel)
            (match (ctfe-quote-type ty env expr expr-fuel)
              [(ResultCtfeQuoteType.Ok quoted-ty next-fuel)
                (ResultCtfeQuoteExpr.Ok
                  (ast-expr-int-to-ptr-with-pools
                    (ctfe-env-pools env)
                    quoted
                    quoted-ty)
                  (AstType.Expr)
                  next-fuel)]
              [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.StringData inner-box)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted _ next-fuel)
            (ResultCtfeQuoteExpr.Ok
              (ast-expr-string-data-with-pools (ctfe-env-pools env) quoted)
              (AstType.Expr)
              next-fuel)]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.StringFromBytes ptr-box len-box)
      (let
        [ptr : AstExpr (ctfe-ast-get env ptr-box)]
        [len : AstExpr (ctfe-ast-get env len-box)]
        (match (ctfe-quote-expr ptr env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted-ptr _ ptr-fuel)
            (match (ctfe-quote-expr len env ptr-fuel quasiquote)
              [(ResultCtfeQuoteExpr.Ok quoted-len _ len-fuel)
                (ResultCtfeQuoteExpr.Ok
                  (ast-expr-string-from-bytes-with-pools
                    (ctfe-env-pools env)
                    quoted-ptr
                    quoted-len)
                  (AstType.Expr)
                  len-fuel)]
              [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.ArrayData inner-box)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted _ next-fuel)
            (ResultCtfeQuoteExpr.Ok
              (ast-expr-array-data-with-pools (ctfe-env-pools env) quoted)
              (AstType.Expr)
              next-fuel)]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.BinaryData bytes)
      (ResultCtfeQuoteExpr.Ok
        (ctfe-ast-push env (AstExpr.BinaryData bytes))
        (AstType.Expr)
        fuel)]
    [(AstExpr.CpuIdEax leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ctfe-ast-get env leaf-box)]
        [subleaf : AstExpr (ctfe-ast-get env subleaf-box)]
        (match (ctfe-quote-expr leaf env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted-leaf _ leaf-fuel)
            (match (ctfe-quote-expr subleaf env leaf-fuel quasiquote)
              [(ResultCtfeQuoteExpr.Ok quoted-subleaf _ subleaf-fuel)
                (ResultCtfeQuoteExpr.Ok
                  (ast-expr-cpuid-eax-with-pools
                    (ctfe-env-pools env)
                    quoted-leaf
                    quoted-subleaf)
                  (AstType.Expr)
                  subleaf-fuel)]
              [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.CpuIdEbx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ctfe-ast-get env leaf-box)]
        [subleaf : AstExpr (ctfe-ast-get env subleaf-box)]
        (match (ctfe-quote-expr leaf env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted-leaf _ leaf-fuel)
            (match (ctfe-quote-expr subleaf env leaf-fuel quasiquote)
              [(ResultCtfeQuoteExpr.Ok quoted-subleaf _ subleaf-fuel)
                (ResultCtfeQuoteExpr.Ok
                  (ast-expr-cpuid-ebx-with-pools
                    (ctfe-env-pools env)
                    quoted-leaf
                    quoted-subleaf)
                  (AstType.Expr)
                  subleaf-fuel)]
              [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.CpuIdEcx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ctfe-ast-get env leaf-box)]
        [subleaf : AstExpr (ctfe-ast-get env subleaf-box)]
        (match (ctfe-quote-expr leaf env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted-leaf _ leaf-fuel)
            (match (ctfe-quote-expr subleaf env leaf-fuel quasiquote)
              [(ResultCtfeQuoteExpr.Ok quoted-subleaf _ subleaf-fuel)
                (ResultCtfeQuoteExpr.Ok
                  (ast-expr-cpuid-ecx-with-pools
                    (ctfe-env-pools env)
                    quoted-leaf
                    quoted-subleaf)
                  (AstType.Expr)
                  subleaf-fuel)]
              [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.CpuIdEdx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ctfe-ast-get env leaf-box)]
        [subleaf : AstExpr (ctfe-ast-get env subleaf-box)]
        (match (ctfe-quote-expr leaf env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted-leaf _ leaf-fuel)
            (match (ctfe-quote-expr subleaf env leaf-fuel quasiquote)
              [(ResultCtfeQuoteExpr.Ok quoted-subleaf _ subleaf-fuel)
                (ResultCtfeQuoteExpr.Ok
                  (ast-expr-cpuid-edx-with-pools
                    (ctfe-env-pools env)
                    quoted-leaf
                    quoted-subleaf)
                  (AstType.Expr)
                  subleaf-fuel)]
              [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.Xgetbv index-box)
      (let
        [index : AstExpr (ctfe-ast-get env index-box)]
        (match (ctfe-quote-expr index env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted-index _ index-fuel)
            (ResultCtfeQuoteExpr.Ok
              (ast-expr-xgetbv-with-pools (ctfe-env-pools env) quoted-index)
              (AstType.Expr)
              index-fuel)]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(AstExpr.Syscall args)
      (match (ctfe-quote-expr-list args env fuel quasiquote)
        [(ResultCtfeQuoteExprList.Ok quoted-args args-fuel)
          (ResultCtfeQuoteExpr.Ok
            (ast-expr-syscall-with-pools (ctfe-env-pools env) quoted-args)
            (AstType.Expr)
            args-fuel)]
        [(ResultCtfeQuoteExprList.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
    [(AstExpr.Unquote inner-box)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (if quasiquote
          (ctfe-eval-unquote-expr inner expr env fuel)
          (match (ctfe-quote-expr inner env fuel quasiquote)
            [(ResultCtfeQuoteExpr.Ok quoted _ next-fuel)
              (ResultCtfeQuoteExpr.Ok
                (ast-expr-unquote-with-pools (ctfe-env-pools env) quoted)
                (AstType.Expr)
                next-fuel)]
            [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)])))]
    [(AstExpr.UnquoteSplicing inner-box)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (if quasiquote
          (ResultCtfeQuoteExpr.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                "unquote-splicing is only valid in a quasiquote list")))
          (match (ctfe-quote-expr inner env fuel quasiquote)
            [(ResultCtfeQuoteExpr.Ok quoted _ next-fuel)
              (ResultCtfeQuoteExpr.Ok
                (ast-expr-unquote-splicing-with-pools
                  (ctfe-env-pools env)
                  quoted)
                (AstType.Expr)
                next-fuel)]
            [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)])))]
    [_ (ResultCtfeQuoteExpr.Ok (ctfe-ast-push env expr) (AstType.Expr) fuel)]))

(define (ctfe-eval-quote
  [template : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]
  [quasiquote : bool]) : ResultCtfe
  (match (ctfe-quote-expr template env fuel quasiquote)
    [(ResultCtfeQuoteExpr.Ok node ty next-fuel)
      (ResultCtfe.Ok (CompilerCtfeValue.Expr node ty) next-fuel)]
    [(ResultCtfeQuoteExpr.Err diag) (ResultCtfe.Err diag)]))

;; --- expr constructors and inspectors ----------------------------------------
;; Macro transformers need to build and pattern-match AST nodes at comptime.
;; These constructors / inspectors cover the forms needed by v1 macros
;; (and, or, when, unless, cond): literals, variables, if, and call.
;; EQ -------------------------------------------------------------------------
(define (ctfe-literal-eq [a : AstLiteral] [b : AstLiteral]) : bool
  (match a
    [(AstLiteral.Int a-n _)
      (match b
        [(AstLiteral.Int b-n _) (= a-n b-n)]
        [_ false])]
    [(AstLiteral.Bool a-b)
      (match b
        [(AstLiteral.Bool b-b) (= a-b b-b)]
        [_ false])]
    [(AstLiteral.Char a-c)
      (match b
        [(AstLiteral.Char b-c) (= a-c b-c)]
        [_ false])]
    [(AstLiteral.Float a-text)
      (match b
        [(AstLiteral.Float b-text) (string.eq a-text b-text)]
        [_ false])]
    [(AstLiteral.String a-text)
      (match b
        [(AstLiteral.String b-text) (string.eq a-text b-text)]
        [_ false])]
    [(AstLiteral.Unit)
      (match b
        [(AstLiteral.Unit) true]
        [_ false])]
    [_ false]))

(define (ctfe-borrow-lifetime-eq
  [a : AstBorrowLifetime]
  [b : AstBorrowLifetime]) : bool
  (match a
    [(AstBorrowLifetime.Inferred)
      (match b
        [(AstBorrowLifetime.Inferred) true]
        [_ false])]
    [(AstBorrowLifetime.Named a-name)
      (match b
        [(AstBorrowLifetime.Named b-name) (string.eq a-name b-name)]
        [_ false])]))

(define (ctfe-maybe-type-eq-in-env
  [env : CtfeEnv]
  [a : AstMaybeType]
  [b : AstMaybeType]) : bool
  (match a
    [(AstMaybeType.No)
      (match b
        [(AstMaybeType.No) true]
        [_ false])]
    [(AstMaybeType.Some a-ty)
      (match b
        [(AstMaybeType.Some b-ty) (ctfe-type-eq-in-env env a-ty b-ty)]
        [_ false])]))

(define (ctfe-param-eq-in-env [env : CtfeEnv] [a : AstParam] [b : AstParam]) : bool
  (match a
    [(AstParam.Param a-name a-ty a-comptime)
      (match b
        [(AstParam.Param b-name b-ty b-comptime)
          (and
            (= a-name b-name)
            (ctfe-type-eq-in-env env a-ty b-ty)
            (= a-comptime b-comptime))])]))

(define (ctfe-param-list-eq-in-env
  [env : CtfeEnv]
  [a : AstParamList]
  [b : AstParamList]) : bool
  (let
    [len : i64 (ast-param-list-len (& a))]
    (and
      (= len (ast-param-list-len (& b)))
      (ctfe-param-list-eq-in-env-at env (& a) (& b) len 0))))

(define (ctfe-param-list-eq-in-env-at
  [env : CtfeEnv]
  [a : (& a AstParamList)]
  [b : (& b AstParamList)]
  [len : i64]
  [index : i64]) : bool
  (if (>= index len)
    true
    (and
      (ctfe-param-eq-in-env
        env
        (ast-param-list-get a index (ast-param-fallback))
        (ast-param-list-get b index (ast-param-fallback)))
      (ctfe-param-list-eq-in-env-at env a b len (+ index 1)))))

(define (ctfe-pattern-eq-in-env
  [env : CtfeEnv]
  [a : AstPattern]
  [b : AstPattern]) : bool
  (match a
    [(AstPattern.Var a-name a-ty)
      (match b
        [(AstPattern.Var b-name b-ty)
          (and (= a-name b-name) (ctfe-maybe-type-eq-in-env env a-ty b-ty))]
        [_ false])]
    [(AstPattern.Tuple a-items-box)
      (let
        [a-items : AstPatternList (box-get a-items-box)]
        (match b
          [(AstPattern.Tuple b-items-box)
            (ctfe-pattern-list-eq-in-env env a-items (box-get b-items-box))]
          [_ false]))]
    [(AstPattern.Wildcard)
      (match b
        [(AstPattern.Wildcard) true]
        [_ false])]
    [(AstPattern.Binding a-name)
      (match b
        [(AstPattern.Binding b-name) (= a-name b-name)]
        [_ false])]
    [(AstPattern.Variant a-name a-items-box)
      (let
        [a-items : AstPatternList (box-get a-items-box)]
        (match b
          [(AstPattern.Variant b-name b-items-box)
            (and
              (= a-name b-name)
              (ctfe-pattern-list-eq-in-env env a-items (box-get b-items-box)))]
          [_ false]))]
    [(AstPattern.Literal a-lit)
      (match b
        [(AstPattern.Literal b-lit) (ctfe-literal-eq a-lit b-lit)]
        [_ false])]))

(define (ctfe-pattern-list-eq-in-env
  [env : CtfeEnv]
  [a : AstPatternList]
  [b : AstPatternList]) : bool
  (and
    (= (struct-get (& a) len) (struct-get (& b) len))
    (ctfe-pattern-list-eq-in-env-at env (& a) (& b) 0)))

(define (ctfe-pattern-list-eq-in-env-at
  [env : CtfeEnv]
  [a : (& a AstPatternList)]
  [b : (& b AstPatternList)]
  [index : i64]) : bool
  (if (>= index (struct-get a len))
    true
    (and
      (ctfe-pattern-eq-in-env
        env
        (ast-pattern-list-get a index (ast-pattern-fallback))
        (ast-pattern-list-get b index (ast-pattern-fallback)))
      (ctfe-pattern-list-eq-in-env-at env a b (+ index 1)))))

(define (ctfe-let-binding-eq-in-env
  [env : CtfeEnv]
  [a : AstLetBinding]
  [b : AstLetBinding]) : bool
  (match a
    [(AstLetBinding.Binding a-name a-ty a-value-box)
      (let
        [a-value : AstExpr (ctfe-ast-get env a-value-box)]
        (match b
          [(AstLetBinding.Binding b-name b-ty b-value-box)
            (let
              [b-value : AstExpr (ctfe-ast-get env b-value-box)]
              (and
                (= a-name b-name)
                (ctfe-maybe-type-eq-in-env env a-ty b-ty)
                (ctfe-expr-eq-in-env env a-value b-value)))]
          [_ false]))]))

(define (ctfe-let-binding-list-eq-in-env
  [env : CtfeEnv]
  [a : AstLetBindingList]
  [b : AstLetBindingList]) : bool
  (and
    (= (ast-let-binding-list-len (& a)) (ast-let-binding-list-len (& b)))
    (ctfe-let-binding-list-eq-in-env-at env (& a) (& b) 0)))

(define (ctfe-let-binding-list-eq-in-env-at
  [env : CtfeEnv]
  [a : (& a AstLetBindingList)]
  [b : (& b AstLetBindingList)]
  [index : i64]) : bool
  (if (>= index (ast-let-binding-list-len a))
    true
    (and
      (ctfe-let-binding-eq-in-env
        env
        (ast-let-binding-list-get a index (ast-let-binding-fallback))
        (ast-let-binding-list-get b index (ast-let-binding-fallback)))
      (ctfe-let-binding-list-eq-in-env-at env a b (+ index 1)))))

(define (ctfe-resource-binding-eq-in-env
  [env : CtfeEnv]
  [a : AstResourceBinding]
  [b : AstResourceBinding]) : bool
  (match a
    [(AstResourceBinding.Binding a-name a-init-box a-cleanup-box)
      (let
        [a-init : AstExpr (ctfe-ast-get env a-init-box)]
        [a-cleanup : AstExpr (ctfe-ast-get env a-cleanup-box)]
        (match b
          [(AstResourceBinding.Binding b-name b-init-box b-cleanup-box)
            (let
              [b-init : AstExpr (ctfe-ast-get env b-init-box)]
              [b-cleanup : AstExpr (ctfe-ast-get env b-cleanup-box)]
              (and
                (= a-name b-name)
                (ctfe-expr-eq-in-env env a-init b-init)
                (ctfe-expr-eq-in-env env a-cleanup b-cleanup)))]
          [_ false]))]))

(define (ctfe-resource-binding-list-eq-in-env
  [env : CtfeEnv]
  [a : AstResourceBindingList]
  [b : AstResourceBindingList]) : bool
  (and
    (=
      (ast-resource-binding-list-len (& a))
      (ast-resource-binding-list-len (& b)))
    (ctfe-resource-binding-list-eq-in-env-at env (& a) (& b) 0)))

(define (ctfe-resource-binding-list-eq-in-env-at
  [env : CtfeEnv]
  [a : (& a AstResourceBindingList)]
  [b : (& b AstResourceBindingList)]
  [index : i64]) : bool
  (if (>= index (ast-resource-binding-list-len a))
    true
    (and
      (ctfe-resource-binding-eq-in-env
        env
        (ast-resource-binding-list-get a index (ast-resource-binding-fallback))
        (ast-resource-binding-list-get b index (ast-resource-binding-fallback)))
      (ctfe-resource-binding-list-eq-in-env-at env a b (+ index 1)))))

(define (ctfe-match-arm-eq-in-env
  [env : CtfeEnv]
  [a : AstMatchArm]
  [b : AstMatchArm]) : bool
  (match a
    [(AstMatchArm.Arm a-pattern a-body-box)
      (let
        [a-body : AstExpr (ctfe-ast-get env a-body-box)]
        (match b
          [(AstMatchArm.Arm b-pattern b-body-box)
            (let
              [b-body : AstExpr (ctfe-ast-get env b-body-box)]
              (and
                (ctfe-pattern-eq-in-env env a-pattern b-pattern)
                (ctfe-expr-eq-in-env env a-body b-body)))]
          [_ false]))]))

(define (ctfe-match-arm-list-eq-in-env
  [env : CtfeEnv]
  [a : AstMatchArmList]
  [b : AstMatchArmList]) : bool
  (and
    (= (struct-get (& a) len) (struct-get (& b) len))
    (ctfe-match-arm-list-eq-in-env-at env (& a) (& b) 0)))

(define (ctfe-match-arm-list-eq-in-env-at
  [env : CtfeEnv]
  [a : (& a AstMatchArmList)]
  [b : (& b AstMatchArmList)]
  [index : i64]) : bool
  (if (>= index (struct-get a len))
    true
    (and
      (ctfe-match-arm-eq-in-env
        env
        (ast-match-arm-list-get a index (ast-match-arm-fallback))
        (ast-match-arm-list-get b index (ast-match-arm-fallback)))
      (ctfe-match-arm-list-eq-in-env-at env a b (+ index 1)))))

(define (ctfe-reduce-op-eq [a : AstReduceOp] [b : AstReduceOp]) : bool
  (match a
    [(AstReduceOp.Sum)
      (match b
        [(AstReduceOp.Sum) true]
        [_ false])]
    [(AstReduceOp.Min)
      (match b
        [(AstReduceOp.Min) true]
        [_ false])]
    [(AstReduceOp.Max)
      (match b
        [(AstReduceOp.Max) true]
        [_ false])]
    [(AstReduceOp.All)
      (match b
        [(AstReduceOp.All) true]
        [_ false])]
    [(AstReduceOp.Any)
      (match b
        [(AstReduceOp.Any) true]
        [_ false])]))

(define (ctfe-expr-eq-inner-in-env [env : CtfeEnv] [a : AstExpr] [b : AstExpr]) : bool
  (match a
    [(AstExpr.Literal a-lit)
      (match b
        [(AstExpr.Literal b-lit) (ctfe-literal-eq a-lit b-lit)]
        [_ false])]
    [(AstExpr.Var a-name)
      (match b
        [(AstExpr.Var b-name)
          (string.eq (intern-str a-name) (intern-str b-name))]
        [_ false])]
    [(AstExpr.Binary a-op a-l-box a-r-box)
      (let
        [a-l : AstExpr (ctfe-ast-get env a-l-box)]
        [a-r : AstExpr (ctfe-ast-get env a-r-box)]
        (match b
          [(AstExpr.Binary b-op b-l-box b-r-box)
            (let
              [b-l : AstExpr (ctfe-ast-get env b-l-box)]
              [b-r : AstExpr (ctfe-ast-get env b-r-box)]
              (and
                (ctfe-binop-eq a-op b-op)
                (ctfe-expr-eq-in-env env a-l b-l)
                (ctfe-expr-eq-in-env env a-r b-r)))]
          [_ false]))]
    [(AstExpr.Unary a-op a-in-box)
      (let
        [a-in : AstExpr (ctfe-ast-get env a-in-box)]
        (match b
          [(AstExpr.Unary b-op b-in-box)
            (let
              [b-in : AstExpr (ctfe-ast-get env b-in-box)]
              (and (ctfe-unop-eq a-op b-op) (ctfe-expr-eq-in-env env a-in b-in)))]
          [_ false]))]
    [(AstExpr.If a-c-box a-t-box a-e-box)
      (let
        [a-c : AstExpr (ctfe-ast-get env a-c-box)]
        [a-t : AstExpr (ctfe-ast-get env a-t-box)]
        [a-e : AstExpr (ctfe-ast-get env a-e-box)]
        (match b
          [(AstExpr.If b-c-box b-t-box b-e-box)
            (let
              [b-c : AstExpr (ctfe-ast-get env b-c-box)]
              [b-t : AstExpr (ctfe-ast-get env b-t-box)]
              [b-e : AstExpr (ctfe-ast-get env b-e-box)]
              (and
                (ctfe-expr-eq-in-env env a-c b-c)
                (ctfe-expr-eq-in-env env a-t b-t)
                (ctfe-expr-eq-in-env env a-e b-e)))]
          [_ false]))]
    [(AstExpr.Let a-let-box)
      (match (box-get a-let-box)
        [(AstLet.Let a-bindings a-body-box)
          (let
            [a-body : AstExpr (ctfe-ast-get env a-body-box)]
            (match b
              [(AstExpr.Let b-let-box)
                (match (box-get b-let-box)
                  [(AstLet.Let b-bindings b-body-box)
                    (let
                      [b-body : AstExpr (ctfe-ast-get env b-body-box)]
                      (and
                        (ctfe-let-binding-list-eq-in-env
                          env
                          a-bindings
                          b-bindings)
                        (ctfe-expr-eq-in-env env a-body b-body)))])]
              [_ false]))])]
    [(AstExpr.Lambda a-lambda-box)
      (match (box-get a-lambda-box)
        [(AstLambda.Lambda a-params a-ret a-body-box)
          (let
            [a-body : AstExpr (ctfe-ast-get env a-body-box)]
            (match b
              [(AstExpr.Lambda b-lambda-box)
                (match (box-get b-lambda-box)
                  [(AstLambda.Lambda b-params b-ret b-body-box)
                    (let
                      [b-body : AstExpr (ctfe-ast-get env b-body-box)]
                      (and
                        (ctfe-param-list-eq-in-env env a-params b-params)
                        (ctfe-maybe-type-eq-in-env env a-ret b-ret)
                        (ctfe-expr-eq-in-env env a-body b-body)))])]
              [_ false]))])]
    [(AstExpr.Call a-fun-box a-args)
      (let
        [a-fun : AstExpr (ctfe-ast-get env a-fun-box)]
        (match b
          [(AstExpr.Call b-fun-box b-args)
            (let
              [b-fun : AstExpr (ctfe-ast-get env b-fun-box)]
              (and
                (ctfe-expr-eq-in-env env a-fun b-fun)
                (ctfe-expr-list-eq-in-env env a-args b-args)))]
          [_ false]))]
    [(AstExpr.BracketClause a-items)
      (match b
        [(AstExpr.BracketClause b-items)
          (ctfe-expr-list-eq-in-env env a-items b-items)]
        [_ false])]
    [(AstExpr.Tuple a-items)
      (match b
        [(AstExpr.Tuple b-items) (ctfe-expr-list-eq-in-env env a-items b-items)]
        [_ false])]
    [(AstExpr.TupleRef a-inner-box a-index)
      (let
        [a-inner : AstExpr (ctfe-ast-get env a-inner-box)]
        (match b
          [(AstExpr.TupleRef b-inner-box b-index)
            (let
              [b-inner : AstExpr (ctfe-ast-get env b-inner-box)]
              (and
                (= a-index b-index)
                (ctfe-expr-eq-in-env env a-inner b-inner)))]
          [_ false]))]
    [(AstExpr.Array a-items)
      (match b
        [(AstExpr.Array b-items) (ctfe-expr-list-eq-in-env env a-items b-items)]
        [_ false])]
    [(AstExpr.DynArray a-items)
      (match b
        [(AstExpr.DynArray b-items)
          (ctfe-expr-list-eq-in-env env a-items b-items)]
        [_ false])]
    [(AstExpr.MakeArray a-ty a-size-box)
      (let
        [a-size : AstExpr (ctfe-ast-get env a-size-box)]
        (match b
          [(AstExpr.MakeArray b-ty b-size-box)
            (let
              [b-size : AstExpr (ctfe-ast-get env b-size-box)]
              (and
                (ctfe-type-eq-in-env env a-ty b-ty)
                (ctfe-expr-eq-in-env env a-size b-size)))]
          [_ false]))]
    [(AstExpr.ArrayRef a-target-box a-index-box)
      (let
        [a-target : AstExpr (ctfe-ast-get env a-target-box)]
        [a-index : AstExpr (ctfe-ast-get env a-index-box)]
        (match b
          [(AstExpr.ArrayRef b-target-box b-index-box)
            (let
              [b-target : AstExpr (ctfe-ast-get env b-target-box)]
              [b-index : AstExpr (ctfe-ast-get env b-index-box)]
              (and
                (ctfe-expr-eq-in-env env a-target b-target)
                (ctfe-expr-eq-in-env env a-index b-index)))]
          [_ false]))]
    [(AstExpr.ArraySet a-target-box a-index-box a-value-box)
      (let
        [a-target : AstExpr (ctfe-ast-get env a-target-box)]
        [a-index : AstExpr (ctfe-ast-get env a-index-box)]
        [a-value : AstExpr (ctfe-ast-get env a-value-box)]
        (match b
          [(AstExpr.ArraySet b-target-box b-index-box b-value-box)
            (let
              [b-target : AstExpr (ctfe-ast-get env b-target-box)]
              [b-index : AstExpr (ctfe-ast-get env b-index-box)]
              [b-value : AstExpr (ctfe-ast-get env b-value-box)]
              (and
                (ctfe-expr-eq-in-env env a-target b-target)
                (ctfe-expr-eq-in-env env a-index b-index)
                (ctfe-expr-eq-in-env env a-value b-value)))]
          [_ false]))]
    [(AstExpr.ArrayTake a-target-box a-live-box a-index-box)
      (let
        [a-target : AstExpr (ctfe-ast-get env a-target-box)]
        [a-live : AstExpr (ctfe-ast-get env a-live-box)]
        [a-index : AstExpr (ctfe-ast-get env a-index-box)]
        (match b
          [(AstExpr.ArrayTake b-target-box b-live-box b-index-box)
            (let
              [b-target : AstExpr (ctfe-ast-get env b-target-box)]
              [b-live : AstExpr (ctfe-ast-get env b-live-box)]
              [b-index : AstExpr (ctfe-ast-get env b-index-box)]
              (and
                (ctfe-expr-eq-in-env env a-target b-target)
                (ctfe-expr-eq-in-env env a-live b-live)
                (ctfe-expr-eq-in-env env a-index b-index)))]
          [_ false]))]
    [(AstExpr.ArrayPush a-target-box a-value-box)
      (let
        [a-target : AstExpr (ctfe-ast-get env a-target-box)]
        [a-value : AstExpr (ctfe-ast-get env a-value-box)]
        (match b
          [(AstExpr.ArrayPush b-target-box b-value-box)
            (let
              [b-target : AstExpr (ctfe-ast-get env b-target-box)]
              [b-value : AstExpr (ctfe-ast-get env b-value-box)]
              (and
                (ctfe-expr-eq-in-env env a-target b-target)
                (ctfe-expr-eq-in-env env a-value b-value)))]
          [_ false]))]
    [(AstExpr.StringRef a-target-box a-index-box)
      (let
        [a-target : AstExpr (ctfe-ast-get env a-target-box)]
        [a-index : AstExpr (ctfe-ast-get env a-index-box)]
        (match b
          [(AstExpr.StringRef b-target-box b-index-box)
            (let
              [b-target : AstExpr (ctfe-ast-get env b-target-box)]
              [b-index : AstExpr (ctfe-ast-get env b-index-box)]
              (and
                (ctfe-expr-eq-in-env env a-target b-target)
                (ctfe-expr-eq-in-env env a-index b-index)))]
          [_ false]))]
    [(AstExpr.While a-cond-box a-body-box)
      (let
        [a-cond : AstExpr (ctfe-ast-get env a-cond-box)]
        [a-body : AstExpr (ctfe-ast-get env a-body-box)]
        (match b
          [(AstExpr.While b-cond-box b-body-box)
            (let
              [b-cond : AstExpr (ctfe-ast-get env b-cond-box)]
              [b-body : AstExpr (ctfe-ast-get env b-body-box)]
              (and
                (ctfe-expr-eq-in-env env a-cond b-cond)
                (ctfe-expr-eq-in-env env a-body b-body)))]
          [_ false]))]
    [(AstExpr.Begin a-exprs)
      (match b
        [(AstExpr.Begin b-exprs) (ctfe-expr-list-eq-in-env env a-exprs b-exprs)]
        [_ false])]
    [(AstExpr.Unsafe a-exprs)
      (match b
        [(AstExpr.Unsafe b-exprs)
          (ctfe-expr-list-eq-in-env env a-exprs b-exprs)]
        [_ false])]
    [(AstExpr.Set a-name a-value-box)
      (let
        [a-value : AstExpr (ctfe-ast-get env a-value-box)]
        (match b
          [(AstExpr.Set b-name b-value-box)
            (let
              [b-value : AstExpr (ctfe-ast-get env b-value-box)]
              (and (= a-name b-name) (ctfe-expr-eq-in-env env a-value b-value)))]
          [_ false]))]
    [(AstExpr.Ann a-inner-box a-ty)
      (let
        [a-inner : AstExpr (ctfe-ast-get env a-inner-box)]
        (match b
          [(AstExpr.Ann b-inner-box b-ty)
            (let
              [b-inner : AstExpr (ctfe-ast-get env b-inner-box)]
              (and
                (ctfe-expr-eq-in-env env a-inner b-inner)
                (ctfe-type-eq-in-env env a-ty b-ty)))]
          [_ false]))]
    [(AstExpr.Cast a-inner-box a-ty)
      (let
        [a-inner : AstExpr (ctfe-ast-get env a-inner-box)]
        (match b
          [(AstExpr.Cast b-inner-box b-ty)
            (let
              [b-inner : AstExpr (ctfe-ast-get env b-inner-box)]
              (and
                (ctfe-expr-eq-in-env env a-inner b-inner)
                (ctfe-type-eq-in-env env a-ty b-ty)))]
          [_ false]))]
    [(AstExpr.Borrow a-mut a-life a-place-box)
      (let
        [a-place : AstExpr (ctfe-ast-get env a-place-box)]
        (match b
          [(AstExpr.Borrow b-mut b-life b-place-box)
            (let
              [b-place : AstExpr (ctfe-ast-get env b-place-box)]
              (and
                (= a-mut b-mut)
                (ctfe-borrow-lifetime-eq a-life b-life)
                (ctfe-expr-eq-in-env env a-place b-place)))]
          [_ false]))]
    [(AstExpr.Match a-match-box)
      (match (box-get a-match-box)
        [(AstMatch.Match a-scrut-box a-arms)
          (let
            [a-scrut : AstExpr (ctfe-ast-get env a-scrut-box)]
            (match b
              [(AstExpr.Match b-match-box)
                (match (box-get b-match-box)
                  [(AstMatch.Match b-scrut-box b-arms)
                    (let
                      [b-scrut : AstExpr (ctfe-ast-get env b-scrut-box)]
                      (and
                        (ctfe-expr-eq-in-env env a-scrut b-scrut)
                        (ctfe-match-arm-list-eq-in-env env a-arms b-arms)))])]
              [_ false]))])]
    [(AstExpr.Foreach a-fe-box)
      (match (box-get a-fe-box)
        [(AstForeach.Foreach a-name a-ty a-start-box a-end-box a-body-box)
          (let
            [a-start : AstExpr (ctfe-ast-get env a-start-box)]
            [a-end : AstExpr (ctfe-ast-get env a-end-box)]
            [a-body : AstExpr (ctfe-ast-get env a-body-box)]
            (match b
              [(AstExpr.Foreach b-fe-box)
                (match (box-get b-fe-box)
                  [(AstForeach.Foreach
                      b-name
                      b-ty
                      b-start-box
                      b-end-box
                      b-body-box)
                    (let
                      [b-start : AstExpr (ctfe-ast-get env b-start-box)]
                      [b-end : AstExpr (ctfe-ast-get env b-end-box)]
                      [b-body : AstExpr (ctfe-ast-get env b-body-box)]
                      (and
                        (= a-name b-name)
                        (ctfe-type-eq-in-env env a-ty b-ty)
                        (ctfe-expr-eq-in-env env a-start b-start)
                        (ctfe-expr-eq-in-env env a-end b-end)
                        (ctfe-expr-eq-in-env env a-body b-body)))])]
              [_ false]))])]
    [(AstExpr.SpmdReduce a-reduce-box)
      (match (box-get a-reduce-box)
        [(AstSpmdReduce.Reduce
            a-op
            a-name
            a-ty
            a-start-box
            a-end-box
            a-init-box
            a-value-box)
          (let
            [a-start : AstExpr (ctfe-ast-get env a-start-box)]
            [a-end : AstExpr (ctfe-ast-get env a-end-box)]
            [a-init : AstExpr (ctfe-ast-get env a-init-box)]
            [a-value : AstExpr (ctfe-ast-get env a-value-box)]
            (match b
              [(AstExpr.SpmdReduce b-reduce-box)
                (match (box-get b-reduce-box)
                  [(AstSpmdReduce.Reduce
                      b-op
                      b-name
                      b-ty
                      b-start-box
                      b-end-box
                      b-init-box
                      b-value-box)
                    (let
                      [b-start : AstExpr (ctfe-ast-get env b-start-box)]
                      [b-end : AstExpr (ctfe-ast-get env b-end-box)]
                      [b-init : AstExpr (ctfe-ast-get env b-init-box)]
                      [b-value : AstExpr (ctfe-ast-get env b-value-box)]
                      (and
                        (ctfe-reduce-op-eq a-op b-op)
                        (= a-name b-name)
                        (ctfe-type-eq-in-env env a-ty b-ty)
                        (ctfe-expr-eq-in-env env a-start b-start)
                        (ctfe-expr-eq-in-env env a-end b-end)
                        (ctfe-expr-eq-in-env env a-init b-init)
                        (ctfe-expr-eq-in-env env a-value b-value)))])]
              [_ false]))])]
    [(AstExpr.SpmdScan scan-box)
      (match (box-get scan-box)
        [(AstSpmdScan.Scan
            a-op
            a-index
            a-index-ty
            a-start-box
            a-end-box
            a-prefix
            a-prefix-ty
            a-init-box
            a-value-box
            a-body-box)
          (let
            [a-start : AstExpr (ctfe-ast-get env a-start-box)]
            [a-end : AstExpr (ctfe-ast-get env a-end-box)]
            [a-init : AstExpr (ctfe-ast-get env a-init-box)]
            [a-value : AstExpr (ctfe-ast-get env a-value-box)]
            [a-body : AstExpr (ctfe-ast-get env a-body-box)]
            (match b
              [(AstExpr.SpmdScan scan-box-2)
                (match (box-get scan-box-2)
                  [(AstSpmdScan.Scan
                      b-op
                      b-index
                      b-index-ty
                      b-start-box
                      b-end-box
                      b-prefix
                      b-prefix-ty
                      b-init-box
                      b-value-box
                      b-body-box)
                    (let
                      [b-start : AstExpr (ctfe-ast-get env b-start-box)]
                      [b-end : AstExpr (ctfe-ast-get env b-end-box)]
                      [b-init : AstExpr (ctfe-ast-get env b-init-box)]
                      [b-value : AstExpr (ctfe-ast-get env b-value-box)]
                      [b-body : AstExpr (ctfe-ast-get env b-body-box)]
                      (and
                        (ctfe-reduce-op-eq a-op b-op)
                        (= a-index b-index)
                        (ctfe-type-eq-in-env env a-index-ty b-index-ty)
                        (ctfe-expr-eq-in-env env a-start b-start)
                        (ctfe-expr-eq-in-env env a-end b-end)
                        (= a-prefix b-prefix)
                        (ctfe-type-eq-in-env env a-prefix-ty b-prefix-ty)
                        (ctfe-expr-eq-in-env env a-init b-init)
                        (ctfe-expr-eq-in-env env a-value b-value)
                        (ctfe-expr-eq-in-env env a-body b-body)))])]
              [_ false]))])]
    [(AstExpr.SpmdBroadcast a-value-box a-lane-box)
      (let
        [a-value : AstExpr (ctfe-ast-get env a-value-box)]
        [a-lane : AstExpr (ctfe-ast-get env a-lane-box)]
        (match b
          [(AstExpr.SpmdBroadcast b-value-box b-lane-box)
            (let
              [b-value : AstExpr (ctfe-ast-get env b-value-box)]
              [b-lane : AstExpr (ctfe-ast-get env b-lane-box)]
              (and
                (ctfe-expr-eq-in-env env a-value b-value)
                (ctfe-expr-eq-in-env env a-lane b-lane)))]
          [_ false]))]
    [(AstExpr.SpmdShuffle a-value-box a-lane-box)
      (let
        [a-value : AstExpr (ast-node-get a-value-box)]
        [a-lane : AstExpr (ast-node-get a-lane-box)]
        (match b
          [(AstExpr.SpmdShuffle b-value-box b-lane-box)
            (let
              [b-value : AstExpr (ast-node-get b-value-box)]
              [b-lane : AstExpr (ast-node-get b-lane-box)]
              (and (ctfe-expr-eq a-value b-value) (ctfe-expr-eq a-lane b-lane)))]
          [_ false]))]
    [(AstExpr.SpmdProgramIndex)
      (match b
        [(AstExpr.SpmdProgramIndex) true]
        [_ false])]
    [(AstExpr.SpmdProgramCount)
      (match b
        [(AstExpr.SpmdProgramCount) true]
        [_ false])]
    [(AstExpr.StructGet a-inner-box a-field)
      (let
        [a-inner : AstExpr (ctfe-ast-get env a-inner-box)]
        (match b
          [(AstExpr.StructGet b-inner-box b-field)
            (let
              [b-inner : AstExpr (ctfe-ast-get env b-inner-box)]
              (and
                (= a-field b-field)
                (ctfe-expr-eq-in-env env a-inner b-inner)))]
          [_ false]))]
    [(AstExpr.StructSet a-inner-box a-field a-value-box)
      (let
        [a-inner : AstExpr (ctfe-ast-get env a-inner-box)]
        [a-value : AstExpr (ctfe-ast-get env a-value-box)]
        (match b
          [(AstExpr.StructSet b-inner-box b-field b-value-box)
            (let
              [b-inner : AstExpr (ctfe-ast-get env b-inner-box)]
              [b-value : AstExpr (ctfe-ast-get env b-value-box)]
              (and
                (= a-field b-field)
                (ctfe-expr-eq-in-env env a-inner b-inner)
                (ctfe-expr-eq-in-env env a-value b-value)))]
          [_ false]))]
    [(AstExpr.WithRegion a-name a-body)
      (match b
        [(AstExpr.WithRegion b-name b-body)
          (and
            (string.eq a-name b-name)
            (ctfe-expr-list-eq-in-env env a-body b-body))]
        [_ false])]
    [(AstExpr.WithEscape a-escape-box a-body)
      (let
        [a-escape : AstExpr (ctfe-ast-get env a-escape-box)]
        (match b
          [(AstExpr.WithEscape b-escape-box b-body)
            (let
              [b-escape : AstExpr (ctfe-ast-get env b-escape-box)]
              (and
                (ctfe-expr-eq-in-env env a-escape b-escape)
                (ctfe-expr-list-eq-in-env env a-body b-body)))]
          [_ false]))]
    [(AstExpr.WithScratch a-body)
      (match b
        [(AstExpr.WithScratch b-body)
          (ctfe-expr-list-eq-in-env env a-body b-body)]
        [_ false])]
    [(AstExpr.InArena a-arena-box a-body)
      (let
        [a-arena : AstExpr (ctfe-ast-get env a-arena-box)]
        (match b
          [(AstExpr.InArena b-arena-box b-body)
            (let
              [b-arena : AstExpr (ctfe-ast-get env b-arena-box)]
              (and
                (ctfe-expr-eq-in-env env a-arena b-arena)
                (ctfe-expr-list-eq-in-env env a-body b-body)))]
          [_ false]))]
    [(AstExpr.WithResource a-wr-box)
      (match (box-get a-wr-box)
        [(AstWithResource.WithResource a-bindings a-body)
          (match b
            [(AstExpr.WithResource b-wr-box)
              (match (box-get b-wr-box)
                [(AstWithResource.WithResource b-bindings b-body)
                  (and
                    (ctfe-resource-binding-list-eq-in-env
                      env
                      a-bindings
                      b-bindings)
                    (ctfe-expr-list-eq-in-env env a-body b-body))])]
            [_ false])])]
    [(AstExpr.PtrRead a-ptr-box)
      (let
        [a-ptr : AstExpr (ctfe-ast-get env a-ptr-box)]
        (match b
          [(AstExpr.PtrRead b-ptr-box)
            (let
              [b-ptr : AstExpr (ctfe-ast-get env b-ptr-box)]
              (ctfe-expr-eq-in-env env a-ptr b-ptr))]
          [_ false]))]
    [(AstExpr.PtrAddrOf a-place-box)
      (let
        [a-place : AstExpr (ctfe-ast-get env a-place-box)]
        (match b
          [(AstExpr.PtrAddrOf b-place-box)
            (let
              [b-place : AstExpr (ctfe-ast-get env b-place-box)]
              (ctfe-expr-eq-in-env env a-place b-place))]
          [_ false]))]
    [(AstExpr.PtrWrite a-ptr-box a-value-box)
      (let
        [a-ptr : AstExpr (ctfe-ast-get env a-ptr-box)]
        [a-value : AstExpr (ctfe-ast-get env a-value-box)]
        (match b
          [(AstExpr.PtrWrite b-ptr-box b-value-box)
            (let
              [b-ptr : AstExpr (ctfe-ast-get env b-ptr-box)]
              [b-value : AstExpr (ctfe-ast-get env b-value-box)]
              (and
                (ctfe-expr-eq-in-env env a-ptr b-ptr)
                (ctfe-expr-eq-in-env env a-value b-value)))]
          [_ false]))]
    [(AstExpr.PtrOffset a-ptr-box a-offset-box)
      (let
        [a-ptr : AstExpr (ctfe-ast-get env a-ptr-box)]
        [a-offset : AstExpr (ctfe-ast-get env a-offset-box)]
        (match b
          [(AstExpr.PtrOffset b-ptr-box b-offset-box)
            (let
              [b-ptr : AstExpr (ctfe-ast-get env b-ptr-box)]
              [b-offset : AstExpr (ctfe-ast-get env b-offset-box)]
              (and
                (ctfe-expr-eq-in-env env a-ptr b-ptr)
                (ctfe-expr-eq-in-env env a-offset b-offset)))]
          [_ false]))]
    [(AstExpr.PtrCast a-ptr-box a-ty)
      (let
        [a-ptr : AstExpr (ctfe-ast-get env a-ptr-box)]
        (match b
          [(AstExpr.PtrCast b-ptr-box b-ty)
            (let
              [b-ptr : AstExpr (ctfe-ast-get env b-ptr-box)]
              (and
                (ctfe-expr-eq-in-env env a-ptr b-ptr)
                (ctfe-type-eq-in-env env a-ty b-ty)))]
          [_ false]))]
    [(AstExpr.PtrToInt a-ptr-box)
      (let
        [a-ptr : AstExpr (ctfe-ast-get env a-ptr-box)]
        (match b
          [(AstExpr.PtrToInt b-ptr-box)
            (let
              [b-ptr : AstExpr (ctfe-ast-get env b-ptr-box)]
              (ctfe-expr-eq-in-env env a-ptr b-ptr))]
          [_ false]))]
    [(AstExpr.IntToPtr a-value-box a-ty)
      (let
        [a-value : AstExpr (ctfe-ast-get env a-value-box)]
        (match b
          [(AstExpr.IntToPtr b-value-box b-ty)
            (let
              [b-value : AstExpr (ctfe-ast-get env b-value-box)]
              (and
                (ctfe-expr-eq-in-env env a-value b-value)
                (ctfe-type-eq-in-env env a-ty b-ty)))]
          [_ false]))]
    [(AstExpr.Box a-inner-box)
      (let
        [a-inner : AstExpr (ctfe-ast-get env a-inner-box)]
        (match b
          [(AstExpr.Box b-inner-box)
            (let
              [b-inner : AstExpr (ctfe-ast-get env b-inner-box)]
              (ctfe-expr-eq-in-env env a-inner b-inner))]
          [_ false]))]
    [(AstExpr.BoxGet a-inner-box)
      (let
        [a-inner : AstExpr (ctfe-ast-get env a-inner-box)]
        (match b
          [(AstExpr.BoxGet b-inner-box)
            (let
              [b-inner : AstExpr (ctfe-ast-get env b-inner-box)]
              (ctfe-expr-eq-in-env env a-inner b-inner))]
          [_ false]))]
    [(AstExpr.BoxTake a-inner-box)
      (let
        [a-inner : AstExpr (ctfe-ast-get env a-inner-box)]
        (match b
          [(AstExpr.BoxTake b-inner-box)
            (let
              [b-inner : AstExpr (ctfe-ast-get env b-inner-box)]
              (ctfe-expr-eq-in-env env a-inner b-inner))]
          [_ false]))]
    [(AstExpr.BoxSet a-inner-box a-value-box)
      (let
        [a-inner : AstExpr (ctfe-ast-get env a-inner-box)]
        [a-value : AstExpr (ctfe-ast-get env a-value-box)]
        (match b
          [(AstExpr.BoxSet b-inner-box b-value-box)
            (let
              [b-inner : AstExpr (ctfe-ast-get env b-inner-box)]
              [b-value : AstExpr (ctfe-ast-get env b-value-box)]
              (and
                (ctfe-expr-eq-in-env env a-inner b-inner)
                (ctfe-expr-eq-in-env env a-value b-value)))]
          [_ false]))]
    [(AstExpr.TypeLiteral a-ty)
      (match b
        [(AstExpr.TypeLiteral b-ty) (ctfe-type-eq-in-env env a-ty b-ty)]
        [_ false])]
    [(AstExpr.Init a-ty)
      (match b
        [(AstExpr.Init b-ty) (ctfe-maybe-type-eq-in-env env a-ty b-ty)]
        [_ false])]
    [(AstExpr.Comptime a-inner-box)
      (let
        [a-inner : AstExpr (ctfe-ast-get env a-inner-box)]
        (match b
          [(AstExpr.Comptime b-inner-box)
            (let
              [b-inner : AstExpr (ctfe-ast-get env b-inner-box)]
              (ctfe-expr-eq-in-env env a-inner b-inner))]
          [_ false]))]
    [(AstExpr.Quote a-inner-box)
      (let
        [a-inner : AstExpr (ctfe-ast-get env a-inner-box)]
        (match b
          [(AstExpr.Quote b-inner-box)
            (let
              [b-inner : AstExpr (ctfe-ast-get env b-inner-box)]
              (ctfe-expr-eq-in-env env a-inner b-inner))]
          [_ false]))]
    [(AstExpr.Quasiquote a-inner-box)
      (let
        [a-inner : AstExpr (ctfe-ast-get env a-inner-box)]
        (match b
          [(AstExpr.Quasiquote b-inner-box)
            (let
              [b-inner : AstExpr (ctfe-ast-get env b-inner-box)]
              (ctfe-expr-eq-in-env env a-inner b-inner))]
          [_ false]))]
    [(AstExpr.Unquote a-inner-box)
      (let
        [a-inner : AstExpr (ctfe-ast-get env a-inner-box)]
        (match b
          [(AstExpr.Unquote b-inner-box)
            (let
              [b-inner : AstExpr (ctfe-ast-get env b-inner-box)]
              (ctfe-expr-eq-in-env env a-inner b-inner))]
          [_ false]))]
    [(AstExpr.UnquoteSplicing a-inner-box)
      (let
        [a-inner : AstExpr (ctfe-ast-get env a-inner-box)]
        (match b
          [(AstExpr.UnquoteSplicing b-inner-box)
            (let
              [b-inner : AstExpr (ctfe-ast-get env b-inner-box)]
              (ctfe-expr-eq-in-env env a-inner b-inner))]
          [_ false]))]
    [(AstExpr.Try a-inner-box)
      (let
        [a-inner : AstExpr (ctfe-ast-get env a-inner-box)]
        (match b
          [(AstExpr.Try b-inner-box)
            (let
              [b-inner : AstExpr (ctfe-ast-get env b-inner-box)]
              (ctfe-expr-eq-in-env env a-inner b-inner))]
          [_ false]))]
    [(AstExpr.Return a-inner-box)
      (let
        [a-inner : AstExpr (ctfe-ast-get env a-inner-box)]
        (match b
          [(AstExpr.Return b-inner-box)
            (let
              [b-inner : AstExpr (ctfe-ast-get env b-inner-box)]
              (ctfe-expr-eq-in-env env a-inner b-inner))]
          [_ false]))]
    [(AstExpr.Break)
      (match b
        [(AstExpr.Break) true]
        [_ false])]
    [(AstExpr.Continue)
      (match b
        [(AstExpr.Continue) true]
        [_ false])]
    [(AstExpr.PtrNull a-ty)
      (match b
        [(AstExpr.PtrNull b-ty) (ctfe-type-eq-in-env env a-ty b-ty)]
        [_ false])]
    [(AstExpr.PtrNullCheck a-inner-box)
      (let
        [a-inner : AstExpr (ctfe-ast-get env a-inner-box)]
        (match b
          [(AstExpr.PtrNullCheck b-inner-box)
            (let
              [b-inner : AstExpr (ctfe-ast-get env b-inner-box)]
              (ctfe-expr-eq-in-env env a-inner b-inner))]
          [_ false]))]
    [(AstExpr.StringData a-inner-box)
      (let
        [a-inner : AstExpr (ctfe-ast-get env a-inner-box)]
        (match b
          [(AstExpr.StringData b-inner-box)
            (let
              [b-inner : AstExpr (ctfe-ast-get env b-inner-box)]
              (ctfe-expr-eq-in-env env a-inner b-inner))]
          [_ false]))]
    [(AstExpr.StringFromBytes a-ptr-box a-len-box)
      (let
        [a-ptr : AstExpr (ctfe-ast-get env a-ptr-box)]
        [a-len : AstExpr (ctfe-ast-get env a-len-box)]
        (match b
          [(AstExpr.StringFromBytes b-ptr-box b-len-box)
            (let
              [b-ptr : AstExpr (ctfe-ast-get env b-ptr-box)]
              [b-len : AstExpr (ctfe-ast-get env b-len-box)]
              (and
                (ctfe-expr-eq-in-env env a-ptr b-ptr)
                (ctfe-expr-eq-in-env env a-len b-len)))]
          [_ false]))]
    [(AstExpr.ArrayData a-inner-box)
      (let
        [a-inner : AstExpr (ctfe-ast-get env a-inner-box)]
        (match b
          [(AstExpr.ArrayData b-inner-box)
            (let
              [b-inner : AstExpr (ctfe-ast-get env b-inner-box)]
              (ctfe-expr-eq-in-env env a-inner b-inner))]
          [_ false]))]
    [(AstExpr.BinaryData a-bytes)
      (match b
        [(AstExpr.BinaryData b-bytes) (string.eq a-bytes b-bytes)]
        [_ false])]
    [(AstExpr.ProgramArgc)
      (match b
        [(AstExpr.ProgramArgc) true]
        [_ false])]
    [(AstExpr.ProgramArgv)
      (match b
        [(AstExpr.ProgramArgv) true]
        [_ false])]
    [(AstExpr.ProgramEnvp)
      (match b
        [(AstExpr.ProgramEnvp) true]
        [_ false])]
    [(AstExpr.CpuIdEax a-leaf-box a-subleaf-box)
      (let
        [a-leaf : AstExpr (ctfe-ast-get env a-leaf-box)]
        [a-subleaf : AstExpr (ctfe-ast-get env a-subleaf-box)]
        (match b
          [(AstExpr.CpuIdEax b-leaf-box b-subleaf-box)
            (let
              [b-leaf : AstExpr (ctfe-ast-get env b-leaf-box)]
              [b-subleaf : AstExpr (ctfe-ast-get env b-subleaf-box)]
              (and
                (ctfe-expr-eq-in-env env a-leaf b-leaf)
                (ctfe-expr-eq-in-env env a-subleaf b-subleaf)))]
          [_ false]))]
    [(AstExpr.CpuIdEbx a-leaf-box a-subleaf-box)
      (let
        [a-leaf : AstExpr (ctfe-ast-get env a-leaf-box)]
        [a-subleaf : AstExpr (ctfe-ast-get env a-subleaf-box)]
        (match b
          [(AstExpr.CpuIdEbx b-leaf-box b-subleaf-box)
            (let
              [b-leaf : AstExpr (ctfe-ast-get env b-leaf-box)]
              [b-subleaf : AstExpr (ctfe-ast-get env b-subleaf-box)]
              (and
                (ctfe-expr-eq-in-env env a-leaf b-leaf)
                (ctfe-expr-eq-in-env env a-subleaf b-subleaf)))]
          [_ false]))]
    [(AstExpr.CpuIdEcx a-leaf-box a-subleaf-box)
      (let
        [a-leaf : AstExpr (ctfe-ast-get env a-leaf-box)]
        [a-subleaf : AstExpr (ctfe-ast-get env a-subleaf-box)]
        (match b
          [(AstExpr.CpuIdEcx b-leaf-box b-subleaf-box)
            (let
              [b-leaf : AstExpr (ctfe-ast-get env b-leaf-box)]
              [b-subleaf : AstExpr (ctfe-ast-get env b-subleaf-box)]
              (and
                (ctfe-expr-eq-in-env env a-leaf b-leaf)
                (ctfe-expr-eq-in-env env a-subleaf b-subleaf)))]
          [_ false]))]
    [(AstExpr.CpuIdEdx a-leaf-box a-subleaf-box)
      (let
        [a-leaf : AstExpr (ctfe-ast-get env a-leaf-box)]
        [a-subleaf : AstExpr (ctfe-ast-get env a-subleaf-box)]
        (match b
          [(AstExpr.CpuIdEdx b-leaf-box b-subleaf-box)
            (let
              [b-leaf : AstExpr (ctfe-ast-get env b-leaf-box)]
              [b-subleaf : AstExpr (ctfe-ast-get env b-subleaf-box)]
              (and
                (ctfe-expr-eq-in-env env a-leaf b-leaf)
                (ctfe-expr-eq-in-env env a-subleaf b-subleaf)))]
          [_ false]))]
    [(AstExpr.Xgetbv a-index-box)
      (let
        [a-index : AstExpr (ctfe-ast-get env a-index-box)]
        (match b
          [(AstExpr.Xgetbv b-index-box)
            (let
              [b-index : AstExpr (ctfe-ast-get env b-index-box)]
              (ctfe-expr-eq-in-env env a-index b-index))]
          [_ false]))]
    [(AstExpr.Syscall a-args)
      (match b
        [(AstExpr.Syscall b-args) (ctfe-expr-list-eq-in-env env a-args b-args)]
        [_ false])]
    [(AstExpr.Spanned a-inner-box _)
      (let
        [a-inner : AstExpr (ctfe-ast-get env a-inner-box)]
        (ctfe-expr-eq-in-env env a-inner b))]
    [_ false]))

(define (ctfe-expr-eq-in-env [env : CtfeEnv] [a : AstExpr] [b : AstExpr]) : bool
  (ctfe-expr-eq-inner-in-env
    env
    (ctfe-expr-unspan env a)
    (ctfe-expr-unspan env b)))

(define (ctfe-expr-list-eq-in-env
  [env : CtfeEnv]
  [a : AstExprList]
  [b : AstExprList]) : bool
  (if (= (struct-get (& a) len) (struct-get (& b) len))
    (ctfe-expr-list-eq-at-in-env env (& a) (& b) 0)
    false))

(define (ctfe-expr-list-eq-at-in-env
  [env : CtfeEnv]
  [a : (& a AstExprList)]
  [b : (& b AstExprList)]
  [index : i64]) : bool
  (if (>= index (struct-get a len))
    true
    (and
      (ctfe-expr-eq-in-env
        env
        (ctfe-ast-get env (ast-expr-list-get a index 0))
        (ctfe-ast-get env (ast-expr-list-get b index 0)))
      (ctfe-expr-list-eq-at-in-env env a b (+ index 1)))))

(define (ctfe-expr-clause-eq-in-env
  [env : CtfeEnv]
  [a : AstExprClause]
  [b : AstExprClause]) : bool
  (and
    (ctfe-expr-eq-in-env
      env
      (ctfe-ast-get env (ctfe-expr-clause-first a))
      (ctfe-ast-get env (ctfe-expr-clause-first b)))
    (ctfe-expr-eq-in-env
      env
      (ctfe-ast-get env (ctfe-expr-clause-second a))
      (ctfe-ast-get env (ctfe-expr-clause-second b)))))

(define (ctfe-expr-clause-list-eq-in-env
  [env : CtfeEnv]
  [a : AstExprClauseList]
  [b : AstExprClauseList]) : bool
  (if (= (struct-get (& a) len) (struct-get (& b) len))
    (ctfe-expr-clause-list-eq-at-in-env env (& a) (& b) 0)
    false))

(define (ctfe-expr-clause-list-eq-at-in-env
  [env : CtfeEnv]
  [a : (& a AstExprClauseList)]
  [b : (& b AstExprClauseList)]
  [index : i64]) : bool
  (if (>= index (struct-get a len))
    true
    (and
      (ctfe-expr-clause-eq-in-env
        env
        (ast-expr-clause-list-get a index (ast-expr-clause-fallback))
        (ast-expr-clause-list-get b index (ast-expr-clause-fallback)))
      (ctfe-expr-clause-list-eq-at-in-env env a b (+ index 1)))))

(define (ctfe-expr-binding-clause-eq-in-env
  [env : CtfeEnv]
  [a : AstExprBindingClause]
  [b : AstExprBindingClause]) : bool
  (and
    (= (struct-get a name) (struct-get b name))
    (= (struct-get a has-type) (struct-get b has-type))
    (ctfe-expr-eq-in-env
      env
      (ctfe-ast-get env (struct-get a ty))
      (ctfe-ast-get env (struct-get b ty)))
    (ctfe-expr-eq-in-env
      env
      (ctfe-ast-get env (struct-get a init))
      (ctfe-ast-get env (struct-get b init)))))

(define (ctfe-expr-binding-clause-list-eq-in-env
  [env : CtfeEnv]
  [a : AstExprBindingClauseList]
  [b : AstExprBindingClauseList]) : bool
  (if (= (struct-get (& a) len) (struct-get (& b) len))
    (ctfe-expr-binding-clause-list-eq-at-in-env env (& a) (& b) 0)
    false))

(define (ctfe-expr-binding-clause-list-eq-at-in-env
  [env : CtfeEnv]
  [a : (& a AstExprBindingClauseList)]
  [b : (& b AstExprBindingClauseList)]
  [index : i64]) : bool
  (if (>= index (struct-get a len))
    true
    (and
      (ctfe-expr-binding-clause-eq-in-env
        env
        (ast-expr-binding-clause-list-get
          a
          index
          (ast-expr-binding-clause-fallback))
        (ast-expr-binding-clause-list-get
          b
          index
          (ast-expr-binding-clause-fallback)))
      (ctfe-expr-binding-clause-list-eq-at-in-env env a b (+ index 1)))))

(define (ctfe-expr-eq [a : AstExpr] [b : AstExpr]) : bool
  (ctfe-expr-eq-in-env (ctfe-env-empty) a b))

(define (ctfe-expr-list-eq [a : AstExprList] [b : AstExprList]) : bool
  (ctfe-expr-list-eq-in-env (ctfe-env-empty) a b))

(define (ctfe-expr-clause-eq [a : AstExprClause] [b : AstExprClause]) : bool
  (ctfe-expr-clause-eq-in-env (ctfe-env-empty) a b))

(define (ctfe-expr-clause-list-eq
  [a : AstExprClauseList]
  [b : AstExprClauseList]) : bool
  (ctfe-expr-clause-list-eq-in-env (ctfe-env-empty) a b))

(define (ctfe-expr-binding-clause-eq
  [a : AstExprBindingClause]
  [b : AstExprBindingClause]) : bool
  (ctfe-expr-binding-clause-eq-in-env (ctfe-env-empty) a b))

(define (ctfe-expr-binding-clause-list-eq
  [a : AstExprBindingClauseList]
  [b : AstExprBindingClauseList]) : bool
  (ctfe-expr-binding-clause-list-eq-in-env (ctfe-env-empty) a b))

(define (ctfe-binop-eq [a : AstBinOp] [b : AstBinOp]) : bool
  (match a
    [(AstBinOp.Add)
      (match b
        [(AstBinOp.Add) true]
        [_ false])]
    [(AstBinOp.Sub)
      (match b
        [(AstBinOp.Sub) true]
        [_ false])]
    [(AstBinOp.Mul)
      (match b
        [(AstBinOp.Mul) true]
        [_ false])]
    [(AstBinOp.Div)
      (match b
        [(AstBinOp.Div) true]
        [_ false])]
    [(AstBinOp.Mod)
      (match b
        [(AstBinOp.Mod) true]
        [_ false])]
    [(AstBinOp.Eq)
      (match b
        [(AstBinOp.Eq) true]
        [_ false])]
    [(AstBinOp.Ne)
      (match b
        [(AstBinOp.Ne) true]
        [_ false])]
    [(AstBinOp.Lt)
      (match b
        [(AstBinOp.Lt) true]
        [_ false])]
    [(AstBinOp.Le)
      (match b
        [(AstBinOp.Le) true]
        [_ false])]
    [(AstBinOp.Gt)
      (match b
        [(AstBinOp.Gt) true]
        [_ false])]
    [(AstBinOp.Ge)
      (match b
        [(AstBinOp.Ge) true]
        [_ false])]
    [(AstBinOp.And)
      (match b
        [(AstBinOp.And) true]
        [_ false])]
    [(AstBinOp.Or)
      (match b
        [(AstBinOp.Or) true]
        [_ false])]
    [(AstBinOp.BitAnd)
      (match b
        [(AstBinOp.BitAnd) true]
        [_ false])]
    [(AstBinOp.BitOr)
      (match b
        [(AstBinOp.BitOr) true]
        [_ false])]
    [(AstBinOp.BitXor)
      (match b
        [(AstBinOp.BitXor) true]
        [_ false])]
    [(AstBinOp.Shl)
      (match b
        [(AstBinOp.Shl) true]
        [_ false])]
    [(AstBinOp.Shr)
      (match b
        [(AstBinOp.Shr) true]
        [_ false])]))

(define (ctfe-unop-eq [a : AstUnOp] [b : AstUnOp]) : bool
  (match a
    [(AstUnOp.Neg)
      (match b
        [(AstUnOp.Neg) true]
        [_ false])]
    [(AstUnOp.Not)
      (match b
        [(AstUnOp.Not) true]
        [_ false])]
    [(AstUnOp.BitNot)
      (match b
        [(AstUnOp.BitNot) true]
        [_ false])]))

;; CONSTRUCTORS ----------------------------------------------------------------
(define (ctfe-expr-literal [lit : AstLiteral]) : i64
  (ast-node-push (AstExpr.Literal lit)))

(define (ctfe-expr-bool [b : bool]) : i64
  (ast-node-push (AstExpr.Literal (AstLiteral.Bool b))))

(define (ctfe-expr-var [name : String]) : i64
  (ast-node-push (AstExpr.Var (intern name))))

(define (ctfe-expr-struct-get [target : i64] [field : String]) : i64
  (ast-expr-struct-get target field))

(define (ctfe-expr-tuple-ref [target : i64] [index : i64]) : i64
  (ast-expr-tuple-ref target index))

(define (ctfe-expr-if [cond : i64] [then-branch : i64] [else-branch : i64]) : i64
  (ast-expr-if cond then-branch else-branch))

(define (ctfe-expr-call [func : i64] [args : AstExprList]) : i64
  (ast-expr-call func args))

(define (ctfe-expr-begin [exprs : AstExprList]) : i64
  (ast-node-push (AstExpr.Begin exprs)))

;; LIST UTILITIES --------------------------------------------------------------
(define (ctfe-expr-list-empty) : AstExprList
  (ast-expr-list-new))

(define (ctfe-expr-list-singleton [e : i64]) : AstExprList
  (ast-expr-cons e (ast-expr-list-new)))

(define (ctfe-expr-list-cons [head : i64] [tail : AstExprList]) : AstExprList
  (ast-expr-cons head tail))

(define (ctfe-expr-list-length [lst : AstExprList]) : i64
  (struct-get (& lst) len))

(define (ctfe-expr-list-empty? [lst : AstExprList]) : bool
  (ast-expr-list-empty? (& lst)))

(define (ctfe-expr-clause-first [clause : AstExprClause]) : i64
  (struct-get clause first))

(define (ctfe-expr-clause-second [clause : AstExprClause]) : i64
  (struct-get clause second))

(define (ctfe-expr-clause-list-length [lst : AstExprClauseList]) : i64
  (struct-get (& lst) len))

(define (ctfe-expr-clause-list-empty? [lst : AstExprClauseList]) : bool
  (ast-expr-clause-list-empty? (& lst)))

;; Vector `get` fallbacks are eager. Avoid node-creating fallbacks on valid
;; accesses: a no-pool `ast-node-push` can overwrite a captured CTFE pool slot
;; that shares the active pool storage but has an independent node count.
(define (ctfe-expr-clause-list-head [lst : AstExprClauseList]) : AstExprClause
  (if (ast-expr-clause-list-empty? (& lst))
    (ast-expr-clause
      (ast-node-push (AstExpr.Literal (AstLiteral.Unit)))
      (ast-node-push (AstExpr.Literal (AstLiteral.Unit))))
    (ast-expr-clause-list-get (& lst) 0 (ast-expr-clause-fallback))))

(define (ctfe-expr-clause-list-tail [lst : AstExprClauseList]) : AstExprClauseList
  (ast-expr-clause-list-tail lst))

(define (ctfe-expr-clause-list-nth [lst : AstExprClauseList] [index : i64]) : AstExprClause
  (if (or (< index 0) (>= index (struct-get (& lst) len)))
    (ast-expr-clause
      (ast-node-push (AstExpr.Literal (AstLiteral.Unit)))
      (ast-node-push (AstExpr.Literal (AstLiteral.Unit))))
    (ast-expr-clause-list-get (& lst) index (ast-expr-clause-fallback))))

(define (ctfe-expr-clause-as-bracket-expr-in-env
  [env : CtfeEnv]
  [clause : AstExprClause]) : i64
  (ast-expr-bracket-clause-with-pools
    (ctfe-env-pools env)
    (ast-expr-cons
      (ctfe-expr-clause-first clause)
      (ast-expr-cons (ctfe-expr-clause-second clause) (ast-expr-list-new)))))

(define (ctfe-expr-clause-as-bracket-expr [clause : AstExprClause]) : i64
  (ctfe-expr-clause-as-bracket-expr-in-env (ctfe-env-empty) clause))

(define (ctfe-expr-clause-list->expr-list-in-env
  [env : CtfeEnv]
  [lst : AstExprClauseList]) : AstExprList
  (let
    [out : AstExprList (ast-expr-list-with-capacity (struct-get (& lst) len))]
    (begin
      (ctfe-expr-clause-list->expr-list-into env (& lst) 0 (&mut out))
      out)))

(define (ctfe-expr-clause-list->expr-list-into
  [env : CtfeEnv]
  [lst : (& lst AstExprClauseList)]
  [index : i64]
  [out : (&mut out AstExprList)]) : unit
  (if (>= index (struct-get lst len))
    unit
    (begin
      (ast-expr-list-push
        out
        (ctfe-expr-clause-as-bracket-expr-in-env
          env
          (ast-expr-clause-list-get lst index (ast-expr-clause-fallback))))
      (ctfe-expr-clause-list->expr-list-into env lst (+ index 1) out))))

(define (ctfe-expr-clause-list->expr-list [lst : AstExprClauseList]) : AstExprList
  (ctfe-expr-clause-list->expr-list-in-env (ctfe-env-empty) lst))

(define (ctfe-expr-binding-clause-name [clause : AstExprBindingClause]) : String
  (intern-str (struct-get clause name)))

(define (ctfe-expr-binding-clause-has-type? [clause : AstExprBindingClause]) : bool
  (struct-get clause has-type))

(define (ctfe-expr-binding-clause-type [clause : AstExprBindingClause]) : i64
  (struct-get clause ty))

(define (ctfe-expr-binding-clause-init [clause : AstExprBindingClause]) : i64
  (struct-get clause init))

(define (ctfe-expr-binding-clause-list-length [lst : AstExprBindingClauseList]) : i64
  (struct-get (& lst) len))

(define (ctfe-expr-binding-clause-list-empty? [lst : AstExprBindingClauseList]) : bool
  (ast-expr-binding-clause-list-empty? (& lst)))

(define (ctfe-expr-binding-clause-empty-default) : AstExprBindingClause
  (let
    [unit-expr : i64 (ast-node-push (AstExpr.Literal (AstLiteral.Unit)))]
    (ast-expr-binding-clause-id
      0
      false
      unit-expr
      unit-expr
      (ast-source-span 0 0 0 0))))

(define (ctfe-expr-binding-clause-list-head [lst : AstExprBindingClauseList]) : AstExprBindingClause
  (if (ast-expr-binding-clause-list-empty? (& lst))
    (ctfe-expr-binding-clause-empty-default)
    (ast-expr-binding-clause-list-get
      (& lst)
      0
      (ast-expr-binding-clause-fallback))))

(define (ctfe-expr-binding-clause-list-tail [lst : AstExprBindingClauseList]) : AstExprBindingClauseList
  (ast-expr-binding-clause-list-tail lst))

(define (ctfe-expr-binding-clause-list-nth
  [lst : AstExprBindingClauseList]
  [index : i64]) : AstExprBindingClause
  (if (or (< index 0) (>= index (struct-get (& lst) len)))
    (ctfe-expr-binding-clause-empty-default)
    (ast-expr-binding-clause-list-get
      (& lst)
      index
      (ast-expr-binding-clause-fallback))))

(define (ctfe-expr-binding-clause-as-bracket-expr-in-env
  [env : CtfeEnv]
  [clause : AstExprBindingClause]) : i64
  (let
    [name-expr : i64 (ctfe-ast-push env (AstExpr.Var (struct-get clause name)))]
    [bracket : i64
      (if (struct-get clause has-type)
        (ast-expr-bracket-clause-with-pools
          (ctfe-env-pools env)
          (ast-expr-cons
            name-expr
            (ast-expr-cons
              (ctfe-ast-push env (AstExpr.Var (intern ":")))
              (ast-expr-cons
                (struct-get clause ty)
                (ast-expr-cons (struct-get clause init) (ast-expr-list-new))))))
        (ast-expr-bracket-clause-with-pools
          (ctfe-env-pools env)
          (ast-expr-cons
            name-expr
            (ast-expr-cons (struct-get clause init) (ast-expr-list-new)))))]
    (ast-expr-spanned-with-pools
      (ctfe-env-pools env)
      bracket
      (struct-get clause span))))

(define (ctfe-expr-binding-clause-as-bracket-expr
  [clause : AstExprBindingClause]) : i64
  (ctfe-expr-binding-clause-as-bracket-expr-in-env (ctfe-env-empty) clause))

(define (ctfe-expr-binding-clause-list->expr-list-in-env
  [env : CtfeEnv]
  [lst : AstExprBindingClauseList]) : AstExprList
  (let
    [out : AstExprList (ast-expr-list-with-capacity (struct-get (& lst) len))]
    (begin
      (ctfe-expr-binding-clause-list->expr-list-into env (& lst) 0 (&mut out))
      out)))

(define (ctfe-expr-binding-clause-list->expr-list-into
  [env : CtfeEnv]
  [lst : (& lst AstExprBindingClauseList)]
  [index : i64]
  [out : (&mut out AstExprList)]) : unit
  (if (>= index (struct-get lst len))
    unit
    (begin
      (ast-expr-list-push
        out
        (ctfe-expr-binding-clause-as-bracket-expr-in-env
          env
          (ast-expr-binding-clause-list-get
            lst
            index
            (ast-expr-binding-clause-fallback))))
      (ctfe-expr-binding-clause-list->expr-list-into env lst (+ index 1) out))))

(define (ctfe-expr-binding-clause-list->expr-list
  [lst : AstExprBindingClauseList]) : AstExprList
  (ctfe-expr-binding-clause-list->expr-list-in-env (ctfe-env-empty) lst))

;; INSPECTORS (predicates) -----------------------------------------------------
(define (ctfe-expr-literal?-in-env [env : CtfeEnv] [e : i64]) : bool
  (match (ctfe-ast-get env e)
    [(AstExpr.Literal _) true]
    [_ false]))

(define (ctfe-expr-bool?-in-env [env : CtfeEnv] [e : i64]) : bool
  (match (ctfe-ast-get env e)
    [(AstExpr.Literal lit)
      (match lit
        [(AstLiteral.Bool _) true]
        [_ false])]
    [_ false]))

(define (ctfe-expr-bool-value-in-env [env : CtfeEnv] [e : i64]) : bool
  (match (ctfe-ast-get env e)
    [(AstExpr.Literal lit)
      (match lit
        [(AstLiteral.Bool b) b]
        [_ false])]
    [_ false]))

(define (ctfe-expr-var?-in-env [env : CtfeEnv] [e : i64]) : bool
  (match (ctfe-ast-get env e)
    [(AstExpr.Var _) true]
    [_ false]))

(define (ctfe-expr-if?-in-env [env : CtfeEnv] [e : i64]) : bool
  (match (ctfe-ast-get env e)
    [(AstExpr.If _ _ _) true]
    [_ false]))

(define (ctfe-expr-call?-in-env [env : CtfeEnv] [e : i64]) : bool
  (match (ctfe-ast-get env e)
    [(AstExpr.Call _ _) true]
    [_ false]))

;; INSPECTORS (extractors) -----------------------------------------------------
(define (ctfe-expr-literal-value-in-env [env : CtfeEnv] [e : i64]) : AstLiteral
  (match (ctfe-ast-get env e)
    [(AstExpr.Literal lit) lit]
    [_ (AstLiteral.Unit)]))

(define (ctfe-expr-var-name-in-env [env : CtfeEnv] [e : i64]) : String
  (match (ctfe-ast-get env e)
    [(AstExpr.Var name) (intern-str name)]
    [_ ""]))

(define (ctfe-expr-if-cond-in-env [env : CtfeEnv] [e : i64]) : i64
  (match (ctfe-ast-get env e)
    [(AstExpr.If c _ _) c]
    [_ (ctfe-ast-push env (AstExpr.Literal (AstLiteral.Unit)))]))

(define (ctfe-expr-if-then-in-env [env : CtfeEnv] [e : i64]) : i64
  (match (ctfe-ast-get env e)
    [(AstExpr.If _ t _) t]
    [_ (ctfe-ast-push env (AstExpr.Literal (AstLiteral.Unit)))]))

(define (ctfe-expr-if-else-in-env [env : CtfeEnv] [e : i64]) : i64
  (match (ctfe-ast-get env e)
    [(AstExpr.If _ _ el) el]
    [_ (ctfe-ast-push env (AstExpr.Literal (AstLiteral.Unit)))]))

(define (ctfe-expr-call-func-in-env [env : CtfeEnv] [e : i64]) : i64
  (match (ctfe-ast-get env e)
    [(AstExpr.Call f _) f]
    [_ (ctfe-ast-push env (AstExpr.Literal (AstLiteral.Unit)))]))

(define (ctfe-expr-call-args-in-env [env : CtfeEnv] [e : i64]) : AstExprList
  (match (ctfe-ast-get env e)
    [(AstExpr.Call _ args) args]
    [_ (ast-expr-list-new)]))

(define (ctfe-expr-literal? [e : i64]) : bool
  (ctfe-expr-literal?-in-env (ctfe-env-empty) e))

(define (ctfe-expr-bool? [e : i64]) : bool
  (ctfe-expr-bool?-in-env (ctfe-env-empty) e))

(define (ctfe-expr-bool-value [e : i64]) : bool
  (ctfe-expr-bool-value-in-env (ctfe-env-empty) e))

(define (ctfe-expr-var? [e : i64]) : bool
  (ctfe-expr-var?-in-env (ctfe-env-empty) e))

(define (ctfe-expr-if? [e : i64]) : bool
  (ctfe-expr-if?-in-env (ctfe-env-empty) e))

(define (ctfe-expr-call? [e : i64]) : bool
  (ctfe-expr-call?-in-env (ctfe-env-empty) e))

(define (ctfe-expr-literal-value [e : i64]) : AstLiteral
  (ctfe-expr-literal-value-in-env (ctfe-env-empty) e))

(define (ctfe-expr-var-name [e : i64]) : String
  (ctfe-expr-var-name-in-env (ctfe-env-empty) e))

(define (ctfe-expr-if-cond [e : i64]) : i64
  (ctfe-expr-if-cond-in-env (ctfe-env-empty) e))

(define (ctfe-expr-if-then [e : i64]) : i64
  (ctfe-expr-if-then-in-env (ctfe-env-empty) e))

(define (ctfe-expr-if-else [e : i64]) : i64
  (ctfe-expr-if-else-in-env (ctfe-env-empty) e))

(define (ctfe-expr-call-func [e : i64]) : i64
  (ctfe-expr-call-func-in-env (ctfe-env-empty) e))

(define (ctfe-expr-call-args [e : i64]) : AstExprList
  (ctfe-expr-call-args-in-env (ctfe-env-empty) e))

(define (ctfe-expr-list-head [lst : AstExprList]) : i64
  (if (ast-expr-list-empty? (& lst))
    (ast-node-push (AstExpr.Literal (AstLiteral.Unit)))
    (ast-expr-list-get (& lst) 0 0)))

(define (ctfe-expr-list-tail [lst : AstExprList]) : AstExprList
  (ast-expr-list-tail lst))

(define (ctfe-expr-list-nth [lst : AstExprList] [index : i64]) : i64
  (if (or (< index 0) (>= index (struct-get (& lst) len)))
    (ast-node-push (AstExpr.Literal (AstLiteral.Unit)))
    (ast-expr-list-get (& lst) index 0)))

;; --- folding ----------------------------------------------------------------
;; Convert a folded compile-time value into the AST literal that lowering then
;; materializes through the ordinary literal path. Expr / ExprList values are
;; compile-time only and have no runtime literal form; this is used for scalar
;; value lowering.
(define (ctfe-value-to-literal [value : CompilerCtfeValue]) : AstLiteral
  (match value
    [(CompilerCtfeValue.I64 n) (ast-lit-int n)]
    [(CompilerCtfeValue.F64 n) (AstLiteral.Float (compiler-float-format-f64 n))]
    [(CompilerCtfeValue.F32 n)
      (AstLiteral.Float
        (compiler-float-format-f64 (compiler-float-round-f32-as-f64 n)))]
    [(CompilerCtfeValue.Bool b) (AstLiteral.Bool b)]
    [(CompilerCtfeValue.Char c) (AstLiteral.Char c)]
    [(CompilerCtfeValue.String text) (AstLiteral.String text)]
    [(CompilerCtfeValue.Unit) (AstLiteral.Unit)]
    [(CompilerCtfeValue.Type _) (AstLiteral.Unit)]
    [(CompilerCtfeValue.Expr _ _) (AstLiteral.Unit)]
    [(CompilerCtfeValue.ExprList _) (AstLiteral.Unit)]
    [(CompilerCtfeValue.ExprClause _) (AstLiteral.Unit)]
    [(CompilerCtfeValue.ExprClauseList _) (AstLiteral.Unit)]
    [(CompilerCtfeValue.ExprBindingClause _) (AstLiteral.Unit)]
    [(CompilerCtfeValue.ExprBindingClauseList _) (AstLiteral.Unit)]
    [(CompilerCtfeValue.Pattern _) (AstLiteral.Unit)]
    [(CompilerCtfeValue.PatternList _) (AstLiteral.Unit)]
    [(CompilerCtfeValue.MatchArm _) (AstLiteral.Unit)]
    [(CompilerCtfeValue.MatchArmList _) (AstLiteral.Unit)]
    [(CompilerCtfeValue.TypeInfo _) (AstLiteral.Unit)]
    [(CompilerCtfeValue.TypeInfoBox _) (AstLiteral.Unit)]
    [(CompilerCtfeValue.TypeInfoList _) (AstLiteral.Unit)]
    [(CompilerCtfeValue.TypeField _ _) (AstLiteral.Unit)]
    [(CompilerCtfeValue.TypeFieldList _) (AstLiteral.Unit)]
    [(CompilerCtfeValue.TypeVariantPayload _) (AstLiteral.Unit)]
    [(CompilerCtfeValue.TypeVariantPayloadList _) (AstLiteral.Unit)]
    [(CompilerCtfeValue.TypeVariant _ _) (AstLiteral.Unit)]
    [(CompilerCtfeValue.TypeVariantList _) (AstLiteral.Unit)]))

(define (ctfe-value-to-literal-for-type
  [value : CompilerCtfeValue]
  [ty : AstType]) : AstLiteral
  (match ty
    [(AstType.F32)
      (match value
        [(CompilerCtfeValue.F64 n)
          (AstLiteral.Float
            (compiler-float-format-f64 (compiler-float-round-f32-as-f64 n)))]
        [_ (ctfe-value-to-literal value)])]
    [(AstType.Region _ inner)
      (ctfe-value-to-literal-for-type value (ty-node-get inner))]
    [_ (ctfe-value-to-literal value)]))

(define (ctfe-type-list-eq-in-env
  [env : CtfeEnv]
  [a : AstTypeList]
  [b : AstTypeList]) : bool
  (and
    (= (ast-type-list-len (& a)) (ast-type-list-len (& b)))
    (ctfe-type-list-eq-in-env-at env (& a) (& b) 0)))

(define (ctfe-type-list-eq-in-env-at
  [env : CtfeEnv]
  [a : (& a AstTypeList)]
  [b : (& b AstTypeList)]
  [index : i64]) : bool
  (if (>= index (ast-type-list-len a))
    true
    (and
      (ctfe-type-eq-in-env
        env
        (ctfe-ty-get env (ast-type-list-get a index (ast-type-id-fallback)))
        (ctfe-ty-get env (ast-type-list-get b index (ast-type-id-fallback))))
      (ctfe-type-list-eq-in-env-at env a b (+ index 1)))))

(define (ctfe-type-eq-in-env [env : CtfeEnv] [a : AstType] [b : AstType]) : bool
  (match a
    [(AstType.I64)
      (match b
        [(AstType.I64) true]
        [_ false])]
    [(AstType.I32)
      (match b
        [(AstType.I32) true]
        [_ false])]
    [(AstType.I16)
      (match b
        [(AstType.I16) true]
        [_ false])]
    [(AstType.I8)
      (match b
        [(AstType.I8) true]
        [_ false])]
    [(AstType.U64)
      (match b
        [(AstType.U64) true]
        [_ false])]
    [(AstType.U32)
      (match b
        [(AstType.U32) true]
        [_ false])]
    [(AstType.U16)
      (match b
        [(AstType.U16) true]
        [_ false])]
    [(AstType.U8)
      (match b
        [(AstType.U8) true]
        [_ false])]
    [(AstType.F64)
      (match b
        [(AstType.F64) true]
        [_ false])]
    [(AstType.F32)
      (match b
        [(AstType.F32) true]
        [_ false])]
    [(AstType.Bool)
      (match b
        [(AstType.Bool) true]
        [_ false])]
    [(AstType.Char)
      (match b
        [(AstType.Char) true]
        [_ false])]
    [(AstType.String)
      (match b
        [(AstType.String) true]
        [_ false])]
    [(AstType.Str)
      (match b
        [(AstType.Str) true]
        [_ false])]
    [(AstType.Bytes)
      (match b
        [(AstType.Bytes) true]
        [_ false])]
    [(AstType.Unit)
      (match b
        [(AstType.Unit) true]
        [_ false])]
    [(AstType.Never)
      (match b
        [(AstType.Never) true]
        [_ false])]
    [(AstType.Expr)
      (match b
        [(AstType.Expr) true]
        [_ false])]
    [(AstType.ExprList)
      (match b
        [(AstType.ExprList) true]
        [_ false])]
    [(AstType.Func a-args a-ret)
      (match b
        [(AstType.Func b-args b-ret)
          (and
            (ctfe-type-list-eq-in-env env (box-get a-args) (box-get b-args))
            (ctfe-type-eq-in-env
              env
              (ctfe-ty-get env a-ret)
              (ctfe-ty-get env b-ret)))]
        [_ false])]
    [(AstType.Tuple a-elems)
      (match b
        [(AstType.Tuple b-elems)
          (ctfe-type-list-eq-in-env env (box-get a-elems) (box-get b-elems))]
        [_ false])]
    [(AstType.Array a-elem a-count)
      (match b
        [(AstType.Array b-elem b-count)
          (and
            (= a-count b-count)
            (ctfe-type-eq-in-env
              env
              (ctfe-ty-get env a-elem)
              (ctfe-ty-get env b-elem)))]
        [_ false])]
    [(AstType.DynArray a-elem)
      (match b
        [(AstType.DynArray b-elem)
          (ctfe-type-eq-in-env
            env
            (ctfe-ty-get env a-elem)
            (ctfe-ty-get env b-elem))]
        [_ false])]
    [(AstType.Box a-elem)
      (match b
        [(AstType.Box b-elem)
          (ctfe-type-eq-in-env
            env
            (ctfe-ty-get env a-elem)
            (ctfe-ty-get env b-elem))]
        [_ false])]
    [(AstType.Ptr a-elem)
      (match b
        [(AstType.Ptr b-elem)
          (ctfe-type-eq-in-env
            env
            (ctfe-ty-get env a-elem)
            (ctfe-ty-get env b-elem))]
        [_ false])]
    [(AstType.MutPtr a-elem)
      (match b
        [(AstType.MutPtr b-elem)
          (ctfe-type-eq-in-env
            env
            (ctfe-ty-get env a-elem)
            (ctfe-ty-get env b-elem))]
        [_ false])]
    [(AstType.Ref a-region a-inner)
      (match b
        [(AstType.Ref b-region b-inner)
          (and
            (string.eq a-region b-region)
            (ctfe-type-eq-in-env
              env
              (ctfe-ty-get env a-inner)
              (ctfe-ty-get env b-inner)))]
        [_ false])]
    [(AstType.MutRef a-region a-inner)
      (match b
        [(AstType.MutRef b-region b-inner)
          (and
            (string.eq a-region b-region)
            (ctfe-type-eq-in-env
              env
              (ctfe-ty-get env a-inner)
              (ctfe-ty-get env b-inner)))]
        [_ false])]
    [(AstType.Region a-region a-inner)
      (match b
        [(AstType.Region b-region b-inner)
          (and
            (string.eq a-region b-region)
            (ctfe-type-eq-in-env
              env
              (ctfe-ty-get env a-inner)
              (ctfe-ty-get env b-inner)))]
        [_ false])]
    [(AstType.Enum a-name)
      (match b
        [(AstType.Enum b-name) (= a-name b-name)]
        [_ false])]
    [(AstType.EnumArgs a-name a-lifetimes)
      (match b
        [(AstType.EnumArgs b-name b-lifetimes)
          (and
            (= a-name b-name)
            (ctfe-lifetime-list-eq (box-get a-lifetimes) (box-get b-lifetimes)))]
        [_ false])]
    [(AstType.Struct a-name)
      (match b
        [(AstType.Struct b-name) (= a-name b-name)]
        [_ false])]
    [(AstType.StructArgs a-name a-lifetimes)
      (match b
        [(AstType.StructArgs b-name b-lifetimes)
          (and
            (= a-name b-name)
            (ctfe-lifetime-list-eq (box-get a-lifetimes) (box-get b-lifetimes)))]
        [_ false])]
    [(AstType.Var a-name)
      (match b
        [(AstType.Var b-name) (= a-name b-name)]
        [_ false])]
    [(AstType.VarArgs a-name a-lifetimes)
      (match b
        [(AstType.VarArgs b-name b-lifetimes)
          (and
            (= a-name b-name)
            (ctfe-lifetime-list-eq (box-get a-lifetimes) (box-get b-lifetimes)))]
        [_ false])]))

(define (ctfe-type-list-eq [a : AstTypeList] [b : AstTypeList]) : bool
  (ctfe-type-list-eq-in-env (ctfe-env-empty) a b))

(define (ctfe-type-eq [a : AstType] [b : AstType]) : bool
  (ctfe-type-eq-in-env (ctfe-env-empty) a b))

(define (compiler-ctfe-type-literal-ok?) : bool
  (let
    [want : AstType (ast-ty-array (AstType.I64) 4)]
    (match (compiler-ctfe-eval
      (AstExpr.TypeLiteral want)
      (ctfe-env-empty)
      (ctfe-fuel-limit))
      [(ResultCtfe.Ok value _)
        (match value
          [(CompilerCtfeValue.Type actual)
            (and
              (ctfe-type-eq actual want)
              (string.eq (ctfe-value-type-name value) "type"))]
          [_ false])]
      [(ResultCtfe.Err _) false])))

(define (compiler-ctfe-type-comparison-ok?) : bool
  (match (compiler-ctfe-eval
    (AstExpr.Binary
      (AstBinOp.Eq)
      (ast-node-push (AstExpr.TypeLiteral (AstType.I64)))
      (ast-node-push (AstExpr.TypeLiteral (AstType.I64))))
    (ctfe-env-empty)
    (ctfe-fuel-limit))
    [(ResultCtfe.Ok same _)
      (match same
        [(CompilerCtfeValue.Bool same-ok)
          (match (compiler-ctfe-eval
            (AstExpr.Binary
              (AstBinOp.Eq)
              (ast-node-push (AstExpr.TypeLiteral (AstType.I64)))
              (ast-node-push (AstExpr.TypeLiteral (AstType.I32))))
            (ctfe-env-empty)
            (ctfe-fuel-limit))
            [(ResultCtfe.Ok different _)
              (match different
                [(CompilerCtfeValue.Bool different-ok)
                  (and same-ok (not different-ok))]
                [_ false])]
            [(ResultCtfe.Err _) false])]
        [_ false])]
    [(ResultCtfe.Err _) false]))

(define (compiler-ctfe-raw-pointer-type-comparison-ok?) : bool
  (match (compiler-ctfe-eval
    (AstExpr.Binary
      (AstBinOp.Eq)
      (ast-node-push (AstExpr.TypeLiteral (ast-ty-ptr (AstType.I64))))
      (ast-node-push (AstExpr.TypeLiteral (ast-ty-ptr (AstType.I64)))))
    (ctfe-env-empty)
    (ctfe-fuel-limit))
    [(ResultCtfe.Ok same _)
      (match same
        [(CompilerCtfeValue.Bool same-ok)
          (match (compiler-ctfe-eval
            (AstExpr.Binary
              (AstBinOp.Eq)
              (ast-node-push (AstExpr.TypeLiteral (ast-ty-ptr (AstType.I64))))
              (ast-node-push
                (AstExpr.TypeLiteral (ast-ty-mut-ptr (AstType.I64)))))
            (ctfe-env-empty)
            (ctfe-fuel-limit))
            [(ResultCtfe.Ok different _)
              (match different
                [(CompilerCtfeValue.Bool different-ok)
                  (and same-ok (not different-ok))]
                [_ false])]
            [(ResultCtfe.Err _) false])]
        [_ false])]
    [(ResultCtfe.Err _) false]))

(define (compiler-ctfe-call1 [name : String] [arg : i64]) : i64
  (ast-expr-call
    (ast-node-push (AstExpr.Var (intern name)))
    (ast-expr-cons arg (ast-expr-list-new))))

(define (compiler-ctfe-call2 [name : String] [a : i64] [b : i64]) : i64
  (ast-expr-call
    (ast-node-push (AstExpr.Var (intern name)))
    (ast-expr-cons a (ast-expr-cons b (ast-expr-list-new)))))

(define (compiler-ctfe-call3 [name : String] [a : i64] [b : i64] [c : i64]) : i64
  (ast-expr-call
    (ast-node-push (AstExpr.Var (intern name)))
    (ast-expr-cons a (ast-expr-cons b (ast-expr-cons c (ast-expr-list-new))))))

(define (compiler-ctfe-call1-in-env [env : CtfeEnv] [name : String] [arg : i64]) : i64
  (ast-expr-call-with-pools
    (ctfe-env-pools env)
    (ctfe-ast-push env (AstExpr.Var (intern name)))
    (ast-expr-cons arg (ast-expr-list-new))))

(define (compiler-ctfe-call2-in-env
  [env : CtfeEnv]
  [name : String]
  [a : i64]
  [b : i64]) : i64
  (ast-expr-call-with-pools
    (ctfe-env-pools env)
    (ctfe-ast-push env (AstExpr.Var (intern name)))
    (ast-expr-cons a (ast-expr-cons b (ast-expr-list-new)))))

(define (compiler-ctfe-call3-in-env
  [env : CtfeEnv]
  [name : String]
  [a : i64]
  [b : i64]
  [c : i64]) : i64
  (ast-expr-call-with-pools
    (ctfe-env-pools env)
    (ctfe-ast-push env (AstExpr.Var (intern name)))
    (ast-expr-cons a (ast-expr-cons b (ast-expr-cons c (ast-expr-list-new))))))

(define (compiler-ctfe-eval-i64-ok? [expr : i64] [env : CtfeEnv] [want : i64]) : bool
  (match (compiler-ctfe-eval (ctfe-ast-get env expr) env (ctfe-fuel-limit))
    [(ResultCtfe.Ok value _)
      (match value
        [(CompilerCtfeValue.I64 actual) (= actual want)]
        [_ false])]
    [(ResultCtfe.Err _) false]))

(define (compiler-ctfe-eval-f64-ok? [expr : i64] [env : CtfeEnv] [want : f64]) : bool
  (match (compiler-ctfe-eval (ctfe-ast-get env expr) env (ctfe-fuel-limit))
    [(ResultCtfe.Ok value _)
      (match value
        [(CompilerCtfeValue.F64 actual) (= actual want)]
        [_ false])]
    [(ResultCtfe.Err _) false]))

(define (compiler-ctfe-eval-f32-ok? [expr : i64] [env : CtfeEnv] [want : f64]) : bool
  (match (compiler-ctfe-eval (ctfe-ast-get env expr) env (ctfe-fuel-limit))
    [(ResultCtfe.Ok value _)
      (match value
        [(CompilerCtfeValue.F32 actual) (= actual want)]
        [_ false])]
    [(ResultCtfe.Err _) false]))

(define (compiler-ctfe-eval-bool-ok? [expr : i64] [env : CtfeEnv] [want : bool]) : bool
  (match (compiler-ctfe-eval (ctfe-ast-get env expr) env (ctfe-fuel-limit))
    [(ResultCtfe.Ok value _)
      (match value
        [(CompilerCtfeValue.Bool actual)
          (if want
            actual
            (not actual))]
        [_ false])]
    [(ResultCtfe.Err _) false]))

(define (compiler-ctfe-eval-string-ok?
  [expr : i64]
  [env : CtfeEnv]
  [want : String]) : bool
  (match (compiler-ctfe-eval (ctfe-ast-get env expr) env (ctfe-fuel-limit))
    [(ResultCtfe.Ok value _)
      (match value
        [(CompilerCtfeValue.String actual) (string.eq actual want)]
        [_ false])]
    [(ResultCtfe.Err _) false]))

(define (compiler-ctfe-eval-type-ok?
  [expr : i64]
  [env : CtfeEnv]
  [want : AstType]) : bool
  (match (compiler-ctfe-eval (ctfe-ast-get env expr) env (ctfe-fuel-limit))
    [(ResultCtfe.Ok value _)
      (match value
        [(CompilerCtfeValue.Type actual) (ctfe-type-eq actual want)]
        [_ false])]
    [(ResultCtfe.Err _) false]))

(define (compiler-ctfe-eval-error-ok?
  [expr : i64]
  [env : CtfeEnv]
  [want : String]) : bool
  (match (compiler-ctfe-eval (ctfe-ast-get env expr) env (ctfe-fuel-limit))
    [(ResultCtfe.Err diag)
      (string.eq (compiler-diagnostic-message (box-get diag)) want)]
    [(ResultCtfe.Ok _ _) false]))

(define (compiler-ctfe-f64-ok?) : bool
  (let
    [one-five : i64 (ast-node-push (AstExpr.Literal (AstLiteral.Float "1.5")))]
    [two-quarter : i64
      (ast-node-push (AstExpr.Literal (AstLiteral.Float "2.25")))]
    [zero : i64 (ast-node-push (AstExpr.Literal (AstLiteral.Float "0.0")))]
    [neg-zero : i64 (ast-node-push (AstExpr.Literal (AstLiteral.Float "-0.0")))]
    [one-f32 : i64 (ast-expr-cast one-five (AstType.F32))]
    [zero-f32 : i64 (ast-expr-cast zero (AstType.F32))]
    [sum-f32 : i64
      (ast-node-push (AstExpr.Binary (AstBinOp.Add) one-f32 zero-f32))]
    [neg-f32 : i64 (ast-node-push (AstExpr.Unary (AstUnOp.Neg) sum-f32))]
    [wide-f32 : i64 (ast-expr-cast one-f32 (AstType.F64))]
    [large-f32 : i64
      (ast-expr-cast
        (ast-node-push (AstExpr.Literal (AstLiteral.Float "3.0e+38")))
        (AstType.F32))]
    [two-f32 : i64
      (ast-expr-cast
        (ast-node-push (AstExpr.Literal (AstLiteral.Float "2.0")))
        (AstType.F32))]
    [overflow-f32 : i64
      (ast-node-push (AstExpr.Binary (AstBinOp.Mul) large-f32 two-f32))]
    [overflow-f32-cast : i64
      (ast-expr-cast
        (ast-node-push (AstExpr.Literal (AstLiteral.Float "3.5e+38")))
        (AstType.F32))]
    [overflow-f64-left : i64
      (ast-node-push (AstExpr.Literal (AstLiteral.Float "1e+308")))]
    [overflow-f64 : i64
      (ast-node-push
        (AstExpr.Binary (AstBinOp.Mul) overflow-f64-left overflow-f64-left))]
    [non-finite-f64-literal : i64
      (ast-node-push (AstExpr.Literal (AstLiteral.Float "1e+309")))]
    [sum : i64
      (ast-node-push (AstExpr.Binary (AstBinOp.Add) one-five two-quarter))]
    [neg : i64 (ast-node-push (AstExpr.Unary (AstUnOp.Neg) sum))]
    [neg-int : i64 (ast-node-push (AstExpr.Literal (ast-lit-int (- 0 42))))]
    [u64-max : i64
      (ast-expr-cast
        (ast-node-push (AstExpr.Literal (ast-lit-int (- 0 1))))
        (AstType.U64))]
    [u64-max-f64 : i64 (ast-expr-cast u64-max (AstType.F64))]
    [u64-max-f32 : i64 (ast-expr-cast u64-max (AstType.F32))]
    [u64-var : i64 (ast-node-push (AstExpr.Var (intern "x")))]
    [typed-let-u64-max-f64 : i64
      (ast-expr-let
        (ast-let-binding-cons
          (ast-let-binding "x" (AstMaybeType.Some (AstType.U64)) u64-max)
          (ast-let-binding-list-new))
        (ast-expr-cast u64-var (AstType.F64)))]
    [untyped-let-u64-max-f64 : i64
      (ast-expr-let
        (ast-let-binding-cons
          (ast-let-binding "x" (AstMaybeType.No) u64-max)
          (ast-let-binding-list-new))
        (ast-expr-cast u64-var (AstType.F64)))]
    [match-u64-var : i64 (ast-node-push (AstExpr.Var (intern "m")))]
    [match-u64-max-f64 : i64
      (ast-expr-match
        u64-max
        (ast-match-arm-cons
          (ast-match-arm
            (ast-pat-binding "m")
            (ast-expr-cast match-u64-var (AstType.F64)))
          (ast-match-arm-list-new)))]
    [char-a : i64 (ast-node-push (AstExpr.Literal (AstLiteral.Char 'A')))]
    [char-a-f64 : i64 (ast-expr-cast char-a (AstType.F64))]
    [neg-int-f64 : i64 (ast-expr-cast neg-int (AstType.F64))]
    [rounded-int-f32 : i64
      (ast-expr-cast
        (ast-node-push (AstExpr.Literal (ast-lit-int 16777217)))
        (AstType.F32))]
    [f64-to-i64 : i64 (ast-expr-cast sum (AstType.I64))]
    [f32-to-i64 : i64 (ast-expr-cast one-f32 (AstType.I64))]
    [f64-to-char-to-i64 : i64
      (ast-expr-cast
        (ast-expr-cast
          (ast-node-push (AstExpr.Literal (AstLiteral.Float "65.9")))
          (AstType.Char))
        (AstType.I64))]
    [f64-out-of-i64 : i64
      (ast-expr-cast
        (ast-node-push
          (AstExpr.Literal (AstLiteral.Float "9223372036854775808.0")))
        (AstType.I64))]
    [f64-out-of-u64-portable-range : i64
      (ast-expr-cast
        (ast-node-push
          (AstExpr.Literal (AstLiteral.Float "9223372036854775808.0")))
        (AstType.U64))]
    [lt : i64
      (ast-node-push
        (AstExpr.Binary
          (AstBinOp.Lt)
          sum
          (ast-node-push (AstExpr.Literal (AstLiteral.Float "4.0")))))]
    [div-zero : i64
      (ast-node-push (AstExpr.Binary (AstBinOp.Div) one-five zero))]
    [env : CtfeEnv (ctfe-env-empty)]
    (and
      (compiler-ctfe-eval-f64-ok? one-five env 1.5)
      (compiler-ctfe-eval-f64-ok? neg-zero env -0.0)
      (compiler-ctfe-eval-f64-ok? sum env 3.75)
      (compiler-ctfe-eval-f64-ok? neg env -3.75)
      (compiler-ctfe-eval-f32-ok? one-f32 env 1.5)
      (compiler-ctfe-eval-f32-ok? sum-f32 env 1.5)
      (compiler-ctfe-eval-f32-ok? neg-f32 env -1.5)
      (compiler-ctfe-eval-f64-ok? wide-f32 env 1.5)
      (compiler-ctfe-eval-bool-ok? lt env true)
      (compiler-ctfe-eval-f64-ok? neg-int-f64 env -42.0)
      (compiler-ctfe-eval-f64-ok? char-a-f64 env 65.0)
      (compiler-ctfe-eval-f64-ok? u64-max-f64 env 18446744073709551616.0)
      (compiler-ctfe-eval-f32-ok? u64-max-f32 env 18446744073709551616.0)
      (compiler-ctfe-eval-f64-ok?
        typed-let-u64-max-f64
        env
        18446744073709551616.0)
      (compiler-ctfe-eval-f64-ok?
        untyped-let-u64-max-f64
        env
        18446744073709551616.0)
      (compiler-ctfe-eval-f64-ok? match-u64-max-f64 env 18446744073709551616.0)
      (compiler-ctfe-eval-f32-ok? rounded-int-f32 env 16777216.0)
      (compiler-ctfe-eval-i64-ok? f64-to-i64 env 3)
      (compiler-ctfe-eval-i64-ok? f32-to-i64 env 1)
      (compiler-ctfe-eval-i64-ok? f64-to-char-to-i64 env 65)
      (compiler-ctfe-eval-error-ok?
        f64-out-of-i64
        env
        "comptime: unsupported cast")
      (compiler-ctfe-eval-error-ok?
        f64-out-of-u64-portable-range
        env
        "comptime: unsupported cast")
      (compiler-ctfe-eval-error-ok?
        div-zero
        env
        "float division by zero in comptime")
      (compiler-ctfe-eval-error-ok?
        non-finite-f64-literal
        env
        "comptime: non-finite f64 literal is not supported")
      (compiler-ctfe-eval-error-ok?
        overflow-f64
        env
        "comptime: non-finite f64 result is not supported")
      (compiler-ctfe-eval-error-ok?
        overflow-f32
        env
        "comptime: non-finite f32 result is not supported")
      (compiler-ctfe-eval-error-ok?
        overflow-f32-cast
        env
        "comptime: non-finite f32 result is not supported"))))

(define (compiler-ctfe-layout-query-ok?) : bool
  (let
    [packet-ty : i64
      (ast-node-push (AstExpr.TypeLiteral (AstType.Var (intern "Packet"))))]
    [box-ty : i64
      (ast-node-push (AstExpr.TypeLiteral (AstType.Var (intern "Box"))))]
    [choice-ty : i64
      (ast-node-push (AstExpr.TypeLiteral (AstType.Var (intern "Choice"))))]
    [packet-fields : CtfeLayoutFieldList
      (ctfe-layout-field-list-push
        (ctfe-layout-field-list-push
          (ctfe-layout-field-list-with-capacity 2)
          (CtfeLayoutField.Field "tag" 0))
        (CtfeLayoutField.Field "count" 8))]
    [box-fields : CtfeLayoutFieldList
      (ctfe-layout-field-list-push
        (ctfe-layout-field-list-with-capacity 1)
        (CtfeLayoutField.Field "x" 0))]
    [layouts : CtfeLayoutInfoList
      (ctfe-layout-info-list-push
        (ctfe-layout-info-list-push
          (ctfe-layout-info-list-push
            (ctfe-layout-info-list-with-capacity 3)
            (CtfeLayoutInfo.Info "Packet" true 16 8 packet-fields))
          (CtfeLayoutInfo.Info "Box" true 8 8 box-fields))
        (CtfeLayoutInfo.Info "Choice" false 24 8 (ctfe-layout-field-list-empty)))]
    [env : CtfeEnv (ctfe-env-with-layouts layouts)]
    [ok : bool true]
    (begin
      (if (compiler-ctfe-eval-i64-ok?
        (compiler-ctfe-call1 "size-of" packet-ty)
        env
        16)
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-i64-ok?
        (compiler-ctfe-call1 "align-of" packet-ty)
        env
        8)
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-i64-ok?
        (compiler-ctfe-call2
          "offset-of"
          packet-ty
          (ast-node-push (AstExpr.Var (intern "count"))))
        env
        8)
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-i64-ok?
        (compiler-ctfe-call1 "size-of" box-ty)
        env
        8)
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-i64-ok?
        (compiler-ctfe-call2
          "offset-of"
          box-ty
          (ast-node-push (AstExpr.Var (intern "x"))))
        env
        0)
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-i64-ok?
        (compiler-ctfe-call1 "size-of" choice-ty)
        env
        24)
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-i64-ok?
        (compiler-ctfe-call1 "align-of" choice-ty)
        env
        8)
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-error-ok?
        (compiler-ctfe-call2
          "offset-of"
          choice-ty
          (ast-node-push (AstExpr.Var (intern "tag"))))
        env
        "offset-of requires struct layout type")
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-error-ok?
        (compiler-ctfe-call2
          "offset-of"
          packet-ty
          (ast-node-push (AstExpr.Var (intern "missing"))))
        env
        "offset-of unknown field missing")
        unit
        (set! ok false))
      ok)))

(define (compiler-ctfe-reflection-env) : CtfeEnv
  (let
    [point-fields : CtfeReflectFieldList
      (ctfe-reflect-field-list-push
        (ctfe-reflect-field-list-push
          (ctfe-reflect-field-list-with-capacity 2)
          (CtfeReflectField.Field "x" (AstType.I64)))
        (CtfeReflectField.Field "flag" (AstType.Bool)))]
    [maybe-variants : CtfeReflectVariantList
      (ctfe-reflect-variant-list-push
        (ctfe-reflect-variant-list-push
          (ctfe-reflect-variant-list-with-capacity 2)
          (CtfeReflectVariant.Variant "None" (ast-type-list-new)))
        (CtfeReflectVariant.Variant
          "Some"
          (ast-type-cons (AstType.String) (ast-type-list-new))))]
    [infos : CtfeReflectInfoList
      (ctfe-reflect-info-list-push
        (ctfe-reflect-info-list-push
          (ctfe-reflect-info-list-with-capacity 2)
          (CtfeReflectInfo.Struct "Point" "" "Point" point-fields))
        (CtfeReflectInfo.Enum "Maybe" "" "Maybe" maybe-variants))]
    (ctfe-env-with-reflections infos)))

(define (compiler-ctfe-reflection-query-ok?) : bool
  (let
    [env : CtfeEnv (compiler-ctfe-reflection-env)]
    [point-ty : i64
      (ast-node-push (AstExpr.TypeLiteral (AstType.Var (intern "Point"))))]
    [maybe-ty : i64
      (ast-node-push (AstExpr.TypeLiteral (AstType.Var (intern "Maybe"))))]
    [array-ty : i64
      (ast-node-push (AstExpr.TypeLiteral (ast-ty-array (AstType.I64) 4)))]
    [dyn-array-ty : i64
      (ast-node-push (AstExpr.TypeLiteral (ast-ty-dyn-array (AstType.Bool))))]
    [tuple-ty : i64
      (ast-node-push
        (AstExpr.TypeLiteral
          (ast-ty-tuple
            (ast-type-cons
              (AstType.I64)
              (ast-type-cons (AstType.Bool) (ast-type-list-new))))))]
    [str-ref-ty : i64
      (ast-node-push (AstExpr.TypeLiteral (ast-ty-ref "r" (AstType.Str))))]
    [fn-ty : i64
      (ast-node-push
        (AstExpr.TypeLiteral
          (ast-ty-func
            (ast-type-cons
              (AstType.I64)
              (ast-type-cons (AstType.Bool) (ast-type-list-new)))
            (AstType.String))))]
    [ok : bool true]
    (begin
      (if (compiler-ctfe-eval-string-ok?
        (compiler-ctfe-call1 "type-kind" point-ty)
        env
        "struct")
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-string-ok?
        (compiler-ctfe-call1
          "type-key"
          (ast-node-push (AstExpr.TypeLiteral (AstType.I64))))
        env
        "i64")
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-string-ok?
        (compiler-ctfe-call1 "type-key" str-ref-ty)
        env
        "ref_r_str")
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-string-ok?
        (compiler-ctfe-call1 "type-nominal-name" point-ty)
        env
        "Point")
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-i64-ok?
        (compiler-ctfe-call1 "struct-field-count" point-ty)
        env
        2)
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-string-ok?
        (compiler-ctfe-call2
          "struct-field-name"
          point-ty
          (ast-node-push (AstExpr.Literal (ast-lit-int 1))))
        env
        "flag")
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-type-ok?
        (compiler-ctfe-call2
          "struct-field-type"
          point-ty
          (ast-node-push (AstExpr.Literal (ast-lit-int 0))))
        env
        (AstType.I64))
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-i64-ok?
        (compiler-ctfe-call1 "enum-variant-count" maybe-ty)
        env
        2)
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-string-ok?
        (compiler-ctfe-call2
          "enum-variant-name"
          maybe-ty
          (ast-node-push (AstExpr.Literal (ast-lit-int 1))))
        env
        "Some")
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-i64-ok?
        (compiler-ctfe-call2
          "enum-variant-payload-count"
          maybe-ty
          (ast-node-push (AstExpr.Literal (ast-lit-int 1))))
        env
        1)
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-type-ok?
        (compiler-ctfe-call3
          "enum-variant-payload-type"
          maybe-ty
          (ast-node-push (AstExpr.Literal (ast-lit-int 1)))
          (ast-node-push (AstExpr.Literal (ast-lit-int 0))))
        env
        (AstType.String))
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-type-ok?
        (compiler-ctfe-call1 "array-element-type" array-ty)
        env
        (AstType.I64))
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-i64-ok?
        (compiler-ctfe-call1 "array-length" array-ty)
        env
        4)
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-bool-ok?
        (compiler-ctfe-call1 "array-dynamic?" dyn-array-ty)
        env
        true)
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-i64-ok?
        (compiler-ctfe-call1 "tuple-element-count" tuple-ty)
        env
        2)
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-type-ok?
        (compiler-ctfe-call2
          "tuple-element-type"
          tuple-ty
          (ast-node-push (AstExpr.Literal (ast-lit-int 1))))
        env
        (AstType.Bool))
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-i64-ok?
        (compiler-ctfe-call1 "function-param-count" fn-ty)
        env
        2)
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-type-ok?
        (compiler-ctfe-call2
          "function-param-type"
          fn-ty
          (ast-node-push (AstExpr.Literal (ast-lit-int 1))))
        env
        (AstType.Bool))
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-type-ok?
        (compiler-ctfe-call1 "function-return-type" fn-ty)
        env
        (AstType.String))
        unit
        (set! ok false))
      ok)))

(define (compiler-ctfe-reflection-program) : AstProgram
  (let
    [fields : AstFieldDefList
      (ast-field-def-cons
        (AstFieldDef.Def (intern "id") (AstType.I64) (AstFieldCleanup.No))
        (ast-field-def-cons
          (AstFieldDef.Def
            (intern "label")
            (AstType.String)
            (AstFieldCleanup.No))
          (ast-field-def-list-new)))]
    [variants : AstVariantDefList
      (ast-variant-def-cons
        (AstVariantDef.Def
          (intern "Ready")
          (ast-type-list-new)
          (ast-variant-payload-cleanup-list-new))
        (ast-variant-def-cons
          (AstVariantDef.Def
            (intern "Failed")
            (ast-type-cons (AstType.String) (ast-type-list-new))
            (ast-variant-payload-cleanup-list-new))
          (ast-variant-def-list-new)))]
    (AstProgram.Program
      (box
        (ast-decl-cons-boxed
          (AstDecl.DefStruct
            (intern "Record")
            (AstStructRepr.Default)
            (AstStructCleanup.No)
            fields)
          (box
            (ast-decl-cons-boxed
              (AstDecl.DefEnum (intern "Status") (AstEnumCleanup.No) variants)
              (box (ast-decl-list-new)))))))))

(define (compiler-ctfe-reflection-from-program-ok?) : bool
  (let
    [env : CtfeEnv
      (ctfe-env-with-reflections
        (ctfe-reflections-from-program (compiler-ctfe-reflection-program)))]
    [record-ty : i64
      (ast-node-push (AstExpr.TypeLiteral (AstType.Var (intern "Record"))))]
    [status-ty : i64
      (ast-node-push (AstExpr.TypeLiteral (AstType.Var (intern "Status"))))]
    [ok : bool true]
    (begin
      (if (compiler-ctfe-eval-i64-ok?
        (compiler-ctfe-call1 "struct-field-count" record-ty)
        env
        2)
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-string-ok?
        (compiler-ctfe-call2
          "struct-field-name"
          record-ty
          (ast-node-push (AstExpr.Literal (ast-lit-int 1))))
        env
        "label")
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-type-ok?
        (compiler-ctfe-call3
          "enum-variant-payload-type"
          status-ty
          (ast-node-push (AstExpr.Literal (ast-lit-int 1)))
          (ast-node-push (AstExpr.Literal (ast-lit-int 0))))
        env
        (AstType.String))
        unit
        (set! ok false))
      ok)))

(define (compiler-ctfe-env-string-eq?
  [env : CtfeEnv]
  [name : String]
  [want : String]) : bool
  (match (ctfe-env-lookup env name)
    [(CtfeMaybeValue.Some value)
      (match value
        [(CompilerCtfeValue.String actual) (string.eq actual want)]
        [_ false])]
    [(CtfeMaybeValue.None) false]))

(define (compiler-ctfe-env-i64-eq? [env : CtfeEnv] [name : String] [want : i64]) : bool
  (match (ctfe-env-lookup env name)
    [(CtfeMaybeValue.Some value)
      (match value
        [(CompilerCtfeValue.I64 actual) (= actual want)]
        [_ false])]
    [(CtfeMaybeValue.None) false]))

(define (compiler-ctfe-type-info-builtin-kind?
  [env : CtfeEnv]
  [ty : AstType]
  [want : String]) : bool
  (match (ctfe-match-type-info-variant
    (intern "TypeInfoBuiltin")
    (ast-pattern-cons (ast-pat-binding "kind") (ast-pattern-list-new))
    ty
    env)
    [(CtfePatternMatch.Matched matched)
      (compiler-ctfe-env-string-eq? matched "kind" want)]
    [(CtfePatternMatch.No) false]))

(define (compiler-ctfe-env-type-info-box-builtin-kind?
  [env : CtfeEnv]
  [name : String]
  [want : String]) : bool
  (match (ctfe-env-lookup env name)
    [(CtfeMaybeValue.Some value)
      (match value
        [(CompilerCtfeValue.TypeInfoBox ty)
          (compiler-ctfe-type-info-builtin-kind? env ty want)]
        [_ false])]
    [(CtfeMaybeValue.None) false]))

(define (compiler-ctfe-type-info-list-ref-builtin-kind?
  [env : CtfeEnv]
  [items : CompilerCtfeValue]
  [index : i64]
  [want : String]) : bool
  (match (ctfe-eval-array-ref-value
    items
    index
    (AstExpr.Literal (AstLiteral.Unit))
    env
    (ctfe-fuel-limit))
    [(ResultCtfe.Ok value _)
      (match value
        [(CompilerCtfeValue.TypeInfo ty)
          (compiler-ctfe-type-info-builtin-kind? env ty want)]
        [(CompilerCtfeValue.TypeVariantPayload ty)
          (compiler-ctfe-type-info-builtin-kind? env ty want)]
        [_ false])]
    [(ResultCtfe.Err _) false]))

(define (compiler-ctfe-env-type-info-list-ref-builtin-kind?
  [env : CtfeEnv]
  [name : String]
  [index : i64]
  [want : String]) : bool
  (match (ctfe-env-lookup env name)
    [(CtfeMaybeValue.Some value)
      (compiler-ctfe-type-info-list-ref-builtin-kind? env value index want)]
    [(CtfeMaybeValue.None) false]))

(define (compiler-ctfe-type-info-field-list-ok?
  [env : CtfeEnv]
  [fields-value : CompilerCtfeValue]) : bool
  (match (ctfe-eval-array-ref-value
    fields-value
    0
    (AstExpr.Literal (AstLiteral.Unit))
    env
    (ctfe-fuel-limit))
    [(ResultCtfe.Ok field-value _)
      (match field-value
        [(CompilerCtfeValue.TypeField name ty)
          (and
            (string.eq name "id")
            (compiler-ctfe-type-info-builtin-kind? env ty "i64"))]
        [_ false])]
    [(ResultCtfe.Err _) false]))

(define (compiler-ctfe-type-info-variant-list-ok?
  [env : CtfeEnv]
  [variants-value : CompilerCtfeValue]) : bool
  (match (ctfe-eval-array-ref-value
    variants-value
    1
    (AstExpr.Literal (AstLiteral.Unit))
    env
    (ctfe-fuel-limit))
    [(ResultCtfe.Ok variant-value _)
      (match variant-value
        [(CompilerCtfeValue.TypeVariant name payloads)
          (and
            (string.eq name "Failed")
            (compiler-ctfe-type-info-list-ref-builtin-kind?
              env
              (CompilerCtfeValue.TypeVariantPayloadList payloads)
              0
              "string"))]
        [_ false])]
    [(ResultCtfe.Err _) false]))

(define (compiler-ctfe-type-info-source-match-ok? [env : CtfeEnv]) : bool
  (let
    [match-env : CtfeEnv
      (ctfe-env-extend env "info" (CompilerCtfeValue.TypeInfo (AstType.I64)))]
    [scrutinee : i64 (ctfe-ast-push match-env (AstExpr.Var (intern "info")))]
    [true-lit : i64
      (ctfe-ast-push match-env (AstExpr.Literal (AstLiteral.Bool true)))]
    [false-lit : i64
      (ctfe-ast-push match-env (AstExpr.Literal (AstLiteral.Bool false)))]
    [builtin-arm : AstMatchArm
      (ast-match-arm
        (ast-pat-variant
          "TypeInfoBuiltin"
          (ast-pattern-cons (ast-pat-binding "kind") (ast-pattern-list-new)))
        true-lit)]
    [fallback-arm : AstMatchArm (ast-match-arm AstPattern.Wildcard false-lit)]
    [match-expr : i64
      (ast-expr-match-with-pools
        (ctfe-env-pools match-env)
        scrutinee
        (ast-match-arm-cons
          builtin-arm
          (ast-match-arm-cons fallback-arm (ast-match-arm-list-new))))]
    (match (compiler-ctfe-eval
      (ctfe-ast-get match-env match-expr)
      match-env
      (ctfe-fuel-limit))
      [(ResultCtfe.Ok value _)
        (match value
          [(CompilerCtfeValue.Bool actual) actual]
          [_ false])]
      [(ResultCtfe.Err _) false])))

(define (compiler-ctfe-type-info-reflection-ok?) : bool
  (let
    [env : CtfeEnv
      (ctfe-env-with-reflections
        (ctfe-reflections-from-program (compiler-ctfe-reflection-program)))]
    [i64-ty : i64 (ctfe-ast-push env (AstExpr.TypeLiteral (AstType.I64)))]
    [array-ty : i64
      (ctfe-ast-push env (AstExpr.TypeLiteral (ast-ty-array (AstType.I64) 4)))]
    [dyn-array-ty : i64
      (ctfe-ast-push
        env
        (AstExpr.TypeLiteral (ast-ty-dyn-array (AstType.Bool))))]
    [tuple-ty : i64
      (ctfe-ast-push
        env
        (AstExpr.TypeLiteral
          (ast-ty-tuple
            (ast-type-cons
              (AstType.I64)
              (ast-type-cons (AstType.Bool) (ast-type-list-new))))))]
    [fn-ty : i64
      (ctfe-ast-push
        env
        (AstExpr.TypeLiteral
          (ast-ty-func
            (ast-type-cons
              (AstType.I64)
              (ast-type-cons (AstType.Bool) (ast-type-list-new)))
            (AstType.String))))]
    [record-ty : i64
      (ctfe-ast-push env (AstExpr.TypeLiteral (AstType.Var (intern "Record"))))]
    [status-ty : i64
      (ctfe-ast-push env (AstExpr.TypeLiteral (AstType.Var (intern "Status"))))]
    [ok : bool true]
    (begin
      (match (compiler-ctfe-eval
        (ctfe-ast-get env (compiler-ctfe-call1-in-env env "type-info" i64-ty))
        env
        (ctfe-fuel-limit))
        [(ResultCtfe.Ok value _)
          (match value
            [(CompilerCtfeValue.TypeInfo ty)
              (if (compiler-ctfe-type-info-builtin-kind? env ty "i64")
                unit
                (set! ok false))]
            [_ (set! ok false)])]
        [(ResultCtfe.Err _) (set! ok false)])
      (match (compiler-ctfe-eval
        (ctfe-ast-get env (compiler-ctfe-call1-in-env env "type-info" array-ty))
        env
        (ctfe-fuel-limit))
        [(ResultCtfe.Ok value _)
          (match value
            [(CompilerCtfeValue.TypeInfo ty)
              (match (ctfe-match-type-info-variant
                (intern "TypeInfoArray")
                (ast-pattern-cons
                  (ast-pat-binding "elem")
                  (ast-pattern-cons
                    (ast-pat-binding "len")
                    (ast-pattern-list-new)))
                ty
                env)
                [(CtfePatternMatch.Matched matched)
                  (if (and
                    (compiler-ctfe-env-i64-eq? matched "len" 4)
                    (compiler-ctfe-env-type-info-box-builtin-kind?
                      matched
                      "elem"
                      "i64"))
                    unit
                    (set! ok false))]
                [(CtfePatternMatch.No) (set! ok false)])]
            [_ (set! ok false)])]
        [(ResultCtfe.Err _) (set! ok false)])
      (match (compiler-ctfe-eval
        (ctfe-ast-get
          env
          (compiler-ctfe-call1-in-env env "type-info" dyn-array-ty))
        env
        (ctfe-fuel-limit))
        [(ResultCtfe.Ok value _)
          (match value
            [(CompilerCtfeValue.TypeInfo ty)
              (match (ctfe-match-type-info-variant
                (intern "TypeInfoDynArray")
                (ast-pattern-cons
                  (ast-pat-binding "elem")
                  (ast-pattern-list-new))
                ty
                env)
                [(CtfePatternMatch.Matched matched)
                  (if (compiler-ctfe-env-type-info-box-builtin-kind?
                    matched
                    "elem"
                    "bool")
                    unit
                    (set! ok false))]
                [(CtfePatternMatch.No) (set! ok false)])]
            [_ (set! ok false)])]
        [(ResultCtfe.Err _) (set! ok false)])
      (match (compiler-ctfe-eval
        (ctfe-ast-get env (compiler-ctfe-call1-in-env env "type-info" tuple-ty))
        env
        (ctfe-fuel-limit))
        [(ResultCtfe.Ok value _)
          (match value
            [(CompilerCtfeValue.TypeInfo ty)
              (match (ctfe-match-type-info-variant
                (intern "TypeInfoTuple")
                (ast-pattern-cons
                  (ast-pat-binding "items")
                  (ast-pattern-list-new))
                ty
                env)
                [(CtfePatternMatch.Matched matched)
                  (if (compiler-ctfe-env-type-info-list-ref-builtin-kind?
                    matched
                    "items"
                    1
                    "bool")
                    unit
                    (set! ok false))]
                [(CtfePatternMatch.No) (set! ok false)])]
            [_ (set! ok false)])]
        [(ResultCtfe.Err _) (set! ok false)])
      (match (compiler-ctfe-eval
        (ctfe-ast-get env (compiler-ctfe-call1-in-env env "type-info" fn-ty))
        env
        (ctfe-fuel-limit))
        [(ResultCtfe.Ok value _)
          (match value
            [(CompilerCtfeValue.TypeInfo ty)
              (match (ctfe-match-type-info-variant
                (intern "TypeInfoFunction")
                (ast-pattern-cons
                  (ast-pat-binding "params")
                  (ast-pattern-cons
                    (ast-pat-binding "ret")
                    (ast-pattern-list-new)))
                ty
                env)
                [(CtfePatternMatch.Matched matched)
                  (if (and
                    (compiler-ctfe-env-type-info-list-ref-builtin-kind?
                      matched
                      "params"
                      1
                      "bool")
                    (compiler-ctfe-env-type-info-box-builtin-kind?
                      matched
                      "ret"
                      "string"))
                    unit
                    (set! ok false))]
                [(CtfePatternMatch.No) (set! ok false)])]
            [_ (set! ok false)])]
        [(ResultCtfe.Err _) (set! ok false)])
      (match (compiler-ctfe-eval
        (ctfe-ast-get
          env
          (compiler-ctfe-call1-in-env env "type-info" record-ty))
        env
        (ctfe-fuel-limit))
        [(ResultCtfe.Ok value _)
          (match value
            [(CompilerCtfeValue.TypeInfo ty)
              (match (ctfe-match-type-info-variant
                (intern "TypeInfoStruct")
                (ast-pattern-cons
                  (ast-pat-binding "key")
                  (ast-pattern-cons
                    (ast-pat-binding "fields")
                    (ast-pattern-list-new)))
                ty
                env)
                [(CtfePatternMatch.Matched matched)
                  (if (and
                    (compiler-ctfe-env-string-eq?
                      matched
                      "key"
                      (ctfe-type-info-key-in-env env ty))
                    (match (ctfe-env-lookup matched "fields")
                      [(CtfeMaybeValue.Some fields-value)
                        (compiler-ctfe-type-info-field-list-ok?
                          matched
                          fields-value)]
                      [(CtfeMaybeValue.None) false]))
                    unit
                    (set! ok false))]
                [(CtfePatternMatch.No) (set! ok false)])]
            [_ (set! ok false)])]
        [(ResultCtfe.Err _) (set! ok false)])
      (match (compiler-ctfe-eval
        (ctfe-ast-get
          env
          (compiler-ctfe-call1-in-env env "type-info" status-ty))
        env
        (ctfe-fuel-limit))
        [(ResultCtfe.Ok value _)
          (match value
            [(CompilerCtfeValue.TypeInfo ty)
              (match (ctfe-match-type-info-variant
                (intern "TypeInfoEnum")
                (ast-pattern-cons
                  (ast-pat-binding "key")
                  (ast-pattern-cons
                    (ast-pat-binding "variants")
                    (ast-pattern-list-new)))
                ty
                env)
                [(CtfePatternMatch.Matched matched)
                  (if (and
                    (compiler-ctfe-env-string-eq?
                      matched
                      "key"
                      (ctfe-type-info-key-in-env env ty))
                    (match (ctfe-env-lookup matched "variants")
                      [(CtfeMaybeValue.Some variants-value)
                        (compiler-ctfe-type-info-variant-list-ok?
                          matched
                          variants-value)]
                      [(CtfeMaybeValue.None) false]))
                    unit
                    (set! ok false))]
                [(CtfePatternMatch.No) (set! ok false)])]
            [_ (set! ok false)])]
        [(ResultCtfe.Err _) (set! ok false)])
      (unless (compiler-ctfe-type-info-source-match-ok? env) (set! ok false))
      ok)))

;; --- self-tests ---------------------------------------------------------------
;; Basic round-trip: build an `if` expression from bool literal constructors,
;; compare it structurally, extract its parts, and verify list ops.
;; Flat-AST test helper: the self-tests build exprs with i64-returning
;; constructors; ctfe-expr-eq takes AstExpr, so wrap node ids for the tests.
(define (ctfe-test-expr-eq-in-env [env : CtfeEnv] [a : i64] [b : i64]) : bool
  (ctfe-expr-eq-in-env env (ctfe-ast-get env a) (ctfe-ast-get env b)))

(define (ctfe-test-expr-eq [a : i64] [b : i64]) : bool
  (ctfe-test-expr-eq-in-env (ctfe-env-empty) a b))

(define (compiler-ctfe-expr-eq-ok?) : bool
  (let
    [true-lit : i64 (ctfe-expr-bool true)]
    [false-lit : i64 (ctfe-expr-bool false)]
    [var-x : i64 (ctfe-expr-var "x")]
    [field-x : i64 (ctfe-expr-struct-get var-x "value")]
    [field-x-again : i64 (ctfe-expr-struct-get var-x "value")]
    [field-y : i64 (ctfe-expr-struct-get var-x "other")]
    [if1 : i64 (ctfe-expr-if var-x true-lit false-lit)]
    [if2 : i64 (ctfe-expr-if var-x true-lit false-lit)]
    [if3 : i64 (ctfe-expr-if true-lit var-x false-lit)]
    (and
      (ctfe-test-expr-eq if1 if2)
      (not (ctfe-test-expr-eq if1 if3))
      (ctfe-test-expr-eq field-x field-x-again)
      (not (ctfe-test-expr-eq field-x field-y))
      (ctfe-expr-if? if1)
      (ctfe-test-expr-eq (ctfe-expr-if-cond if1) var-x)
      (ctfe-test-expr-eq (ctfe-expr-if-then if1) true-lit)
      (ctfe-test-expr-eq (ctfe-expr-if-else if1) false-lit))))

(define (compiler-ctfe-expr-list-ok?) : bool
  (let
    [a : i64 (ctfe-expr-bool true)]
    [b : i64 (ctfe-expr-bool false)]
    [lst1 : AstExprList (ctfe-expr-list-cons a (ctfe-expr-list-singleton b))]
    [lst2 : AstExprList (ctfe-expr-list-cons a (ctfe-expr-list-singleton b))]
    [lst3 : AstExprList (ctfe-expr-list-singleton a)]
    (and
      (ctfe-expr-list-eq lst1 lst2)
      (not (ctfe-expr-list-eq lst1 lst3))
      (= (ctfe-expr-list-length lst1) 2)
      (not (ctfe-expr-list-empty? lst1))
      (ctfe-test-expr-eq (ctfe-expr-list-head lst1) a)
      (ctfe-test-expr-eq (ctfe-expr-list-head (ctfe-expr-list-tail lst1)) b)
      (ctfe-test-expr-eq (ctfe-expr-list-nth lst1 1) b))))

(define (compiler-ctfe-expr-list-fold-sketch-ok?) : bool
  ;; Simulate the core list-recursion a macro transformer does: build a
  ;; right-leaning `if` chain from a list of conditions and a final else.
  (let
    [cond1 : i64 (ctfe-expr-var "a")]
    [cond2 : i64 (ctfe-expr-var "b")]
    [else-expr : i64 (ctfe-expr-bool false)]
    [_conds : AstExprList
      (ctfe-expr-list-cons cond1 (ctfe-expr-list-singleton cond2))]
    ;; fold helper: single cond -> (if cond true else)
    [folded1 : i64 (ctfe-expr-if cond2 (ctfe-expr-bool true) else-expr)]
    ;; next: (if cond1 true (if cond2 true else))
    [folded2 : i64 (ctfe-expr-if cond1 (ctfe-expr-bool true) folded1)]
    [expected : i64
      (ctfe-expr-if
        cond1
        (ctfe-expr-bool true)
        (ctfe-expr-if cond2 (ctfe-expr-bool true) else-expr))]
    (ctfe-test-expr-eq folded2 expected)))

(define (compiler-ctfe-builtin-dispatch-reset-ok?) : bool
  (let
    [_cache-reset-before : unit (ctfe-builtin-reset!)]
    [_cache-warm : unit (ctfe-builtin-refresh!)]
    [_cache-reset-after : unit (ctfe-builtin-reset!)]
    [env : CtfeEnv (ctfe-env-empty)]
    [true-lit : i64
      (ctfe-ast-push env (AstExpr.Literal (AstLiteral.Bool true)))]
    [false-lit : i64
      (ctfe-ast-push env (AstExpr.Literal (AstLiteral.Bool false)))]
    [items : AstExprList
      (ctfe-expr-list-cons true-lit (ctfe-expr-list-singleton false-lit))]
    [list-env : CtfeEnv
      (ctfe-env-extend env "items" (CompilerCtfeValue.ExprList items))]
    [items-var : i64 (ctfe-ast-push list-env (AstExpr.Var (intern "items")))]
    [len-call : i64
      (compiler-ctfe-call1-in-env list-env "expr-list-length" items-var)]
    (compiler-ctfe-eval-i64-ok? len-call list-env 2)))

(define (compiler-ctfe-pattern-list-bindings-ok?) : bool
  (let
    [env : CtfeEnv (ctfe-env-empty)]
    [prefix : i64
      (ctfe-ast-push env (AstExpr.Literal (AstLiteral.String "payload")))]
    [count : i64 (ctfe-ast-push env (AstExpr.Literal (AstLiteral.Int 9 "")))]
    [call : i64
      (compiler-ctfe-call2-in-env env "pattern-list-bindings" prefix count)]
    [negative-count : i64
      (ctfe-ast-push env (AstExpr.Literal (AstLiteral.Int -1 "")))]
    [negative-call : i64
      (compiler-ctfe-call2-in-env
        env
        "pattern-list-bindings"
        prefix
        negative-count)]
    [huge-count : i64
      (ctfe-ast-push env (AstExpr.Literal (AstLiteral.Int 10000 "")))]
    [huge-call : i64
      (compiler-ctfe-call2-in-env env "pattern-list-bindings" prefix huge-count)]
    (and
      (match (compiler-ctfe-eval (ctfe-ast-get env call) env (ctfe-fuel-limit))
        [(ResultCtfe.Ok value _)
          (match value
            [(CompilerCtfeValue.PatternList patterns)
              (and
                (= (ast-pattern-list-len (& patterns)) 9)
                (match (ast-pattern-list-get
                  (& patterns)
                  0
                  (ast-pattern-fallback))
                  [(AstPattern.Binding name)
                    (string.eq (intern-str name) "payload0")]
                  [_ false])
                (match (ast-pattern-list-get
                  (& patterns)
                  8
                  (ast-pattern-fallback))
                  [(AstPattern.Binding name)
                    (string.eq (intern-str name) "payload8")]
                  [_ false]))]
            [_ false])]
        [(ResultCtfe.Err _) false])
      (compiler-ctfe-eval-error-ok?
        negative-call
        env
        "pattern-list-bindings count must be non-negative")
      (compiler-ctfe-eval-error-ok?
        huge-call
        env
        "compile-time evaluation limit exceeded"))))

(define (compiler-ctfe-checked-expr-constructors-ok?) : bool
  (let
    [env : CtfeEnv (ctfe-env-empty)]
    [true-lit : i64
      (ctfe-ast-push env (AstExpr.Literal (AstLiteral.Bool true)))]
    [false-lit : i64
      (ctfe-ast-push env (AstExpr.Literal (AstLiteral.Bool false)))]
    [true-expr : i64 (compiler-ctfe-call1-in-env env "expr-bool" true-lit)]
    [false-expr : i64 (compiler-ctfe-call1-in-env env "expr-bool" false-lit)]
    [spliced-false : i64
      (compiler-ctfe-call1-in-env env "expr-splice" false-expr)]
    [if-expr : i64
      (compiler-ctfe-call3-in-env
        env
        "expr-if"
        true-expr
        spliced-false
        true-expr)]
    [expected : i64
      (ast-expr-if-with-pools (ctfe-env-pools env) true-lit false-lit true-lit)]
    [point-name-lit : i64
      (ctfe-ast-push env (AstExpr.Literal (AstLiteral.String "point")))]
    [field-name-lit : i64
      (ctfe-ast-push env (AstExpr.Literal (AstLiteral.String "x")))]
    [name-lit : i64
      (ctfe-ast-push env (AstExpr.Literal (AstLiteral.String "Ada")))]
    [name-expr : i64 (compiler-ctfe-call1-in-env env "expr-string" name-lit)]
    [expected-name : i64
      (ctfe-ast-push env (AstExpr.Literal (AstLiteral.String "Ada")))]
    [point-expr : i64
      (compiler-ctfe-call1-in-env env "expr-var" point-name-lit)]
    [field-expr : i64
      (compiler-ctfe-call2-in-env
        env
        "expr-struct-get"
        point-expr
        field-name-lit)]
    [tuple-index-lit : i64
      (ctfe-ast-push env (AstExpr.Literal (AstLiteral.Int 1 "")))]
    [tuple-ref-expr : i64
      (compiler-ctfe-call2-in-env
        env
        "expr-tuple-ref"
        point-expr
        tuple-index-lit)]
    [field-set-expr : i64
      (compiler-ctfe-call3-in-env
        env
        "expr-struct-set"
        point-expr
        field-name-lit
        true-expr)]
    [helper-name-lit : i64
      (ctfe-ast-push
        env
        (AstExpr.Literal (AstLiteral.String "counter.push-ref")))]
    [helper-expr : i64
      (compiler-ctfe-call1-in-env env "expr-var" helper-name-lit)]
    [mut-borrow-expr : i64
      (compiler-ctfe-call1-in-env env "expr-mut-borrow" point-expr)]
    [empty-call-args : i64
      (ast-expr-call-with-pools
        (ctfe-env-pools env)
        (ctfe-ast-push env (AstExpr.Var (intern "expr-list-empty")))
        (ast-expr-list-new))]
    [value-tail : i64
      (compiler-ctfe-call2-in-env
        env
        "expr-list-cons"
        true-expr
        empty-call-args)]
    [call-args : i64
      (compiler-ctfe-call2-in-env
        env
        "expr-list-cons"
        mut-borrow-expr
        value-tail)]
    [built-call : i64
      (compiler-ctfe-call2-in-env env "expr-call" helper-expr call-args)]
    [expected-field : i64
      (ast-expr-struct-get-with-pools
        (ctfe-env-pools env)
        (ctfe-ast-push env (AstExpr.Var (intern "point")))
        "x")]
    [expected-tuple-ref : i64
      (ast-expr-tuple-ref-with-pools
        (ctfe-env-pools env)
        (ctfe-ast-push env (AstExpr.Var (intern "point")))
        1)]
    [expected-field-set : i64
      (ast-expr-struct-set-with-pools
        (ctfe-env-pools env)
        (ctfe-ast-push env (AstExpr.Var (intern "point")))
        "x"
        true-lit)]
    [expected-mut-borrow : i64
      (ast-expr-borrow-with-pools
        (ctfe-env-pools env)
        true
        AstBorrowLifetime.Inferred
        (ctfe-ast-push env (AstExpr.Var (intern "point"))))]
    [expected-call : i64
      (ast-expr-call-with-pools
        (ctfe-env-pools env)
        (ctfe-ast-push env (AstExpr.Var (intern "counter.push-ref")))
        (ast-expr-cons
          expected-mut-borrow
          (ast-expr-cons true-lit (ast-expr-list-new))))]
    (and
      (match (compiler-ctfe-eval
        (ctfe-ast-get env if-expr)
        env
        (ctfe-fuel-limit))
        [(ResultCtfe.Ok value _)
          (match value
            [(CompilerCtfeValue.Expr node checked-ty)
              (and
                (ctfe-type-eq checked-ty (AstType.Bool))
                (ctfe-test-expr-eq-in-env env node expected))]
            [_ false])]
        [(ResultCtfe.Err _) false])
      (match (compiler-ctfe-eval
        (ctfe-ast-get env name-expr)
        env
        (ctfe-fuel-limit))
        [(ResultCtfe.Ok value _)
          (match value
            [(CompilerCtfeValue.Expr node checked-ty)
              (and
                (ctfe-type-eq checked-ty (AstType.String))
                (ctfe-test-expr-eq-in-env env node expected-name))]
            [_ false])]
        [(ResultCtfe.Err _) false])
      (match (compiler-ctfe-eval
        (ctfe-ast-get env field-expr)
        env
        (ctfe-fuel-limit))
        [(ResultCtfe.Ok value _)
          (match value
            [(CompilerCtfeValue.Expr node checked-ty)
              (and
                (ctfe-untyped-expr-type? checked-ty)
                (ctfe-test-expr-eq-in-env env node expected-field))]
            [_ false])]
        [(ResultCtfe.Err _) false])
      (match (compiler-ctfe-eval
        (ctfe-ast-get env tuple-ref-expr)
        env
        (ctfe-fuel-limit))
        [(ResultCtfe.Ok value _)
          (match value
            [(CompilerCtfeValue.Expr node checked-ty)
              (and
                (ctfe-untyped-expr-type? checked-ty)
                (ctfe-test-expr-eq-in-env env node expected-tuple-ref))]
            [_ false])]
        [(ResultCtfe.Err _) false])
      (match (compiler-ctfe-eval
        (ctfe-ast-get env field-set-expr)
        env
        (ctfe-fuel-limit))
        [(ResultCtfe.Ok value _)
          (match value
            [(CompilerCtfeValue.Expr node checked-ty)
              (and
                (ctfe-type-eq checked-ty (AstType.Unit))
                (ctfe-test-expr-eq-in-env env node expected-field-set))]
            [_ false])]
        [(ResultCtfe.Err _) false])
      (match (compiler-ctfe-eval
        (ctfe-ast-get env mut-borrow-expr)
        env
        (ctfe-fuel-limit))
        [(ResultCtfe.Ok value _)
          (match value
            [(CompilerCtfeValue.Expr node checked-ty)
              (and
                (ctfe-untyped-expr-type? checked-ty)
                (ctfe-test-expr-eq-in-env env node expected-mut-borrow))]
            [_ false])]
        [(ResultCtfe.Err _) false])
      (match (compiler-ctfe-eval
        (ctfe-ast-get env built-call)
        env
        (ctfe-fuel-limit))
        [(ResultCtfe.Ok value _)
          (match value
            [(CompilerCtfeValue.Expr node checked-ty)
              (and
                (ctfe-untyped-expr-type? checked-ty)
                (ctfe-test-expr-eq-in-env env node expected-call))]
            [_ false])]
        [(ResultCtfe.Err _) false]))))

(define (compiler-ctfe-checked-expr-inspectors-ok?) : bool
  (let
    [env : CtfeEnv (ctfe-env-empty)]
    [true-lit : i64
      (ctfe-ast-push env (AstExpr.Literal (AstLiteral.Bool true)))]
    [false-lit : i64
      (ctfe-ast-push env (AstExpr.Literal (AstLiteral.Bool false)))]
    [true-expr : i64 (compiler-ctfe-call1-in-env env "expr-bool" true-lit)]
    [false-expr : i64 (compiler-ctfe-call1-in-env env "expr-bool" false-lit)]
    [if-expr : i64
      (compiler-ctfe-call3-in-env env "expr-if" true-expr false-expr true-expr)]
    [if-predicate : i64 (compiler-ctfe-call1-in-env env "expr-if?" if-expr)]
    [not-if-predicate : i64
      (compiler-ctfe-call1-in-env env "expr-if?" true-expr)]
    [bool-predicate : i64
      (compiler-ctfe-call1-in-env env "expr-bool?" true-expr)]
    [not-bool-predicate : i64
      (compiler-ctfe-call1-in-env env "expr-bool?" if-expr)]
    [bool-value : i64
      (compiler-ctfe-call1-in-env env "expr-bool-value" false-expr)]
    [bool-value-fallback : i64
      (compiler-ctfe-call1-in-env env "expr-bool-value" if-expr)]
    [cond-expr : i64 (compiler-ctfe-call1-in-env env "expr-if-cond" if-expr)]
    [then-expr : i64 (compiler-ctfe-call1-in-env env "expr-if-then" if-expr)]
    [else-expr : i64 (compiler-ctfe-call1-in-env env "expr-if-else" if-expr)]
    [fallback-cond-expr : i64
      (compiler-ctfe-call1-in-env env "expr-if-cond" true-expr)]
    [clause : AstExprClause (AstExprClause true-lit false-lit)]
    [clause-env : CtfeEnv
      (ctfe-env-extend env "arm" (CompilerCtfeValue.ExprClause clause))]
    [clause-var : i64 (ctfe-ast-push clause-env (AstExpr.Var (intern "arm")))]
    [clause-first : i64
      (compiler-ctfe-call1-in-env clause-env "expr-clause-first" clause-var)]
    [clause-second : i64
      (compiler-ctfe-call1-in-env clause-env "expr-clause-second" clause-var)]
    (and
      (compiler-ctfe-eval-bool-ok? if-predicate env true)
      (compiler-ctfe-eval-bool-ok? not-if-predicate env false)
      (compiler-ctfe-eval-bool-ok? bool-predicate env true)
      (compiler-ctfe-eval-bool-ok? not-bool-predicate env false)
      (compiler-ctfe-eval-bool-ok? bool-value env false)
      (compiler-ctfe-eval-bool-ok? bool-value-fallback env false)
      (match (compiler-ctfe-eval
        (ctfe-ast-get env cond-expr)
        env
        (ctfe-fuel-limit))
        [(ResultCtfe.Ok value _)
          (match value
            [(CompilerCtfeValue.Expr node checked-ty)
              (and
                (ctfe-type-eq checked-ty (AstType.Bool))
                (ctfe-test-expr-eq-in-env env node true-lit))]
            [_ false])]
        [(ResultCtfe.Err _) false])
      (match (compiler-ctfe-eval
        (ctfe-ast-get env then-expr)
        env
        (ctfe-fuel-limit))
        [(ResultCtfe.Ok value _)
          (match value
            [(CompilerCtfeValue.Expr node checked-ty)
              (and
                (ctfe-type-eq checked-ty (AstType.Bool))
                (ctfe-test-expr-eq-in-env env node false-lit))]
            [_ false])]
        [(ResultCtfe.Err _) false])
      (match (compiler-ctfe-eval
        (ctfe-ast-get env else-expr)
        env
        (ctfe-fuel-limit))
        [(ResultCtfe.Ok value _)
          (match value
            [(CompilerCtfeValue.Expr node checked-ty)
              (and
                (ctfe-type-eq checked-ty (AstType.Bool))
                (ctfe-test-expr-eq-in-env env node true-lit))]
            [_ false])]
        [(ResultCtfe.Err _) false])
      (match (compiler-ctfe-eval
        (ctfe-ast-get env fallback-cond-expr)
        env
        (ctfe-fuel-limit))
        [(ResultCtfe.Ok value _)
          (match value
            [(CompilerCtfeValue.Expr node checked-ty)
              (and
                (ctfe-type-eq checked-ty (AstType.Bool))
                (ctfe-test-expr-eq-in-env env node true-lit))]
            [_ false])]
        [(ResultCtfe.Err _) false])
      (match (compiler-ctfe-eval
        (ctfe-ast-get clause-env clause-first)
        clause-env
        (ctfe-fuel-limit))
        [(ResultCtfe.Ok value _)
          (match value
            [(CompilerCtfeValue.Expr node _)
              (ctfe-test-expr-eq-in-env clause-env node true-lit)]
            [_ false])]
        [(ResultCtfe.Err _) false])
      (match (compiler-ctfe-eval
        (ctfe-ast-get clause-env clause-second)
        clause-env
        (ctfe-fuel-limit))
        [(ResultCtfe.Ok value _)
          (match value
            [(CompilerCtfeValue.Expr node _)
              (ctfe-test-expr-eq-in-env clause-env node false-lit)]
            [_ false])]
        [(ResultCtfe.Err _) false]))))

(define (compiler-ctfe-checked-expr-rejects-non-bool-cond-ok?) : bool
  (let
    [base-env : CtfeEnv (ctfe-env-empty)]
    [int-node : i64 (ctfe-ast-push base-env (AstExpr.Literal (ast-lit-int 1)))]
    [int-expr-value : CompilerCtfeValue
      (CompilerCtfeValue.Expr int-node (AstType.I64))]
    [env : CtfeEnv (ctfe-env-extend base-env "n" int-expr-value)]
    [spliced-int : i64
      (compiler-ctfe-call1-in-env
        env
        "expr-splice"
        (ctfe-ast-push env (AstExpr.Var (intern "n"))))]
    [true-expr : i64
      (compiler-ctfe-call1-in-env
        env
        "expr-bool"
        (ctfe-ast-push env (AstExpr.Literal (AstLiteral.Bool true))))]
    [if-expr : i64
      (compiler-ctfe-call3-in-env env "expr-if" spliced-int true-expr true-expr)]
    (compiler-ctfe-eval-error-ok?
      if-expr
      env
      "expr-if condition must produce bool")))

(define (compiler-ctfe-quote-syntax-ok?) : bool
  (let
    [base-env : CtfeEnv (ctfe-env-empty)]
    [true-lit : i64
      (ctfe-ast-push base-env (AstExpr.Literal (AstLiteral.Bool true)))]
    [false-lit : i64
      (ctfe-ast-push base-env (AstExpr.Literal (AstLiteral.Bool false)))]
    [flag-var : i64 (ctfe-ast-push base-env (AstExpr.Var (intern "flag")))]
    [spliced : AstExprList
      (ast-expr-cons true-lit (ast-expr-cons false-lit (ast-expr-list-new)))]
    [env : CtfeEnv
      (ctfe-env-extend
        (ctfe-env-extend
          base-env
          "cond"
          (CompilerCtfeValue.Expr flag-var (AstType.Bool)))
        "xs"
        (CompilerCtfeValue.ExprList spliced))]
    [quoted-bool : i64
      (ast-expr-quote-with-pools (ctfe-env-pools env) true-lit)]
    [cond-var : i64 (ctfe-ast-push env (AstExpr.Var (intern "cond")))]
    [qq-if : i64
      (ast-expr-quasiquote-with-pools
        (ctfe-env-pools env)
        (ast-expr-if-with-pools
          (ctfe-env-pools env)
          (ast-expr-unquote-with-pools (ctfe-env-pools env) cond-var)
          true-lit
          false-lit))]
    [xs-var : i64 (ctfe-ast-push env (AstExpr.Var (intern "xs")))]
    [qq-splice : i64
      (ast-expr-quasiquote-with-pools
        (ctfe-env-pools env)
        (ctfe-ast-push
          env
          (AstExpr.Begin
            (ast-expr-cons
              (ast-expr-unquote-splicing-with-pools (ctfe-env-pools env) xs-var)
              (ast-expr-list-new)))))]
    [record-var : i64 (ctfe-ast-push env (AstExpr.Var (intern "record")))]
    [field-place : i64
      (ast-expr-struct-get-id-with-pools
        (ctfe-env-pools env)
        record-var
        (intern "field"))]
    [set-target-var : i64 (ctfe-ast-push env (AstExpr.Var (intern "target")))]
    [set-env : CtfeEnv
      (ctfe-env-extend
        env
        "target"
        (CompilerCtfeValue.Expr field-place (AstType.Expr)))]
    [qq-set : i64
      (ast-expr-quasiquote-with-pools
        (ctfe-env-pools set-env)
        (ast-expr-struct-set-id-with-pools
          (ctfe-env-pools set-env)
          (ast-expr-unquote-with-pools (ctfe-env-pools set-env) set-target-var)
          (ast-expr-unquote-set-target-field-id)
          true-lit))]
    [expected-if : i64
      (ast-expr-if-with-pools (ctfe-env-pools env) flag-var true-lit false-lit)]
    [expected-begin : i64 (ctfe-ast-push env (AstExpr.Begin spliced))]
    [expected-set : i64
      (ast-expr-struct-set-id-with-pools
        (ctfe-env-pools set-env)
        record-var
        (intern "field")
        true-lit)]
    (and
      (match (compiler-ctfe-eval
        (ctfe-ast-get env quoted-bool)
        env
        (ctfe-fuel-limit))
        [(ResultCtfe.Ok value _)
          (match value
            [(CompilerCtfeValue.Expr node ty)
              (and
                (ctfe-type-eq ty (AstType.Bool))
                (ctfe-test-expr-eq-in-env env node true-lit))]
            [_ false])]
        [(ResultCtfe.Err _) false])
      (match (compiler-ctfe-eval (ctfe-ast-get env qq-if) env (ctfe-fuel-limit))
        [(ResultCtfe.Ok value _)
          (match value
            [(CompilerCtfeValue.Expr node ty)
              (and
                (ctfe-type-eq ty (AstType.Bool))
                (ctfe-test-expr-eq-in-env env node expected-if))]
            [_ false])]
        [(ResultCtfe.Err _) false])
      (match (compiler-ctfe-eval
        (ctfe-ast-get env qq-splice)
        env
        (ctfe-fuel-limit))
        [(ResultCtfe.Ok value _)
          (match value
            [(CompilerCtfeValue.Expr node _)
              (ctfe-test-expr-eq-in-env env node expected-begin)]
            [_ false])]
        [(ResultCtfe.Err _) false])
      (match (compiler-ctfe-eval
        (ctfe-ast-get set-env qq-set)
        set-env
        (ctfe-fuel-limit))
        [(ResultCtfe.Ok value _)
          (match value
            [(CompilerCtfeValue.Expr node _)
              (ctfe-test-expr-eq-in-env set-env node expected-set)]
            [_ false])]
        [(ResultCtfe.Err _) false]))))

(define (compiler-ctfe-expr-pattern-match-int-ok?) : bool
  (let
    [base-env : CtfeEnv (ctfe-env-empty)]
    [subject-node : i64
      (ctfe-ast-push base-env (AstExpr.Literal (ast-lit-int 7)))]
    [subject : CompilerCtfeValue
      (CompilerCtfeValue.Expr subject-node (AstType.I64))]
    [env : CtfeEnv (ctfe-env-extend base-env "subject" subject)]
    [scrutinee : i64 (ctfe-ast-push env (AstExpr.Var (intern "subject")))]
    [int-pattern : AstPattern
      (ast-pat-variant
        "ExprInt"
        (ast-pattern-cons (ast-pat-binding "n") (ast-pattern-list-new)))]
    [int-arm : AstMatchArm
      (ast-match-arm int-pattern (ctfe-ast-push env (AstExpr.Var (intern "n"))))]
    [fallback-arm : AstMatchArm
      (ast-match-arm
        AstPattern.Wildcard
        (ctfe-ast-push env (AstExpr.Literal (ast-lit-int 0))))]
    [match-expr : i64
      (ast-expr-match-with-pools
        (ctfe-env-pools env)
        scrutinee
        (ast-match-arm-cons
          int-arm
          (ast-match-arm-cons fallback-arm (ast-match-arm-list-new))))]
    (compiler-ctfe-eval-i64-ok? match-expr env 7)))

(define (compiler-ctfe-expr-pattern-match-if-ok?) : bool
  (let
    [base-env : CtfeEnv (ctfe-env-empty)]
    [flag : i64 (ctfe-ast-push base-env (AstExpr.Var (intern "flag")))]
    [true-lit : i64
      (ctfe-ast-push base-env (AstExpr.Literal (AstLiteral.Bool true)))]
    [false-lit : i64
      (ctfe-ast-push base-env (AstExpr.Literal (AstLiteral.Bool false)))]
    [if-node : i64
      (ast-expr-if-with-pools (ctfe-env-pools base-env) flag true-lit false-lit)]
    [subject : CompilerCtfeValue
      (CompilerCtfeValue.Expr if-node (AstType.Bool))]
    [env : CtfeEnv (ctfe-env-extend base-env "subject" subject)]
    [scrutinee : i64 (ctfe-ast-push env (AstExpr.Var (intern "subject")))]
    [if-pattern : AstPattern
      (ast-pat-variant
        "ExprIf"
        (ast-pattern-cons
          (ast-pat-binding "c")
          (ast-pattern-cons
            (ast-pat-binding "t")
            (ast-pattern-cons (ast-pat-binding "e") (ast-pattern-list-new)))))]
    [swapped : i64
      (compiler-ctfe-call3-in-env
        env
        "expr-if"
        (ctfe-ast-push env (AstExpr.Var (intern "c")))
        (ctfe-ast-push env (AstExpr.Var (intern "e")))
        (ctfe-ast-push env (AstExpr.Var (intern "t"))))]
    [if-arm : AstMatchArm (ast-match-arm if-pattern swapped)]
    [fallback-arm : AstMatchArm (ast-match-arm AstPattern.Wildcard scrutinee)]
    [match-expr : i64
      (ast-expr-match-with-pools
        (ctfe-env-pools env)
        scrutinee
        (ast-match-arm-cons
          if-arm
          (ast-match-arm-cons fallback-arm (ast-match-arm-list-new))))]
    [expected : i64
      (ast-expr-if-with-pools (ctfe-env-pools env) flag false-lit true-lit)]
    (match (compiler-ctfe-eval
      (ctfe-ast-get env match-expr)
      env
      (ctfe-fuel-limit))
      [(ResultCtfe.Ok value _)
        (match value
          [(CompilerCtfeValue.Expr node ty)
            (and
              (ctfe-type-eq ty (AstType.Bool))
              (ctfe-test-expr-eq-in-env env node expected))]
          [_ false])]
      [(ResultCtfe.Err _) false])))

(define (compiler-ctfe-expr-pattern-match-clause-ok?) : bool
  (let
    [base-env : CtfeEnv (ctfe-env-empty)]
    [true-lit : i64
      (ctfe-ast-push base-env (AstExpr.Literal (AstLiteral.Bool true)))]
    [false-lit : i64
      (ctfe-ast-push base-env (AstExpr.Literal (AstLiteral.Bool false)))]
    [clause : AstExprClause (AstExprClause true-lit false-lit)]
    [subject : CompilerCtfeValue (CompilerCtfeValue.ExprClause clause)]
    [env : CtfeEnv (ctfe-env-extend base-env "subject" subject)]
    [scrutinee : i64 (ctfe-ast-push env (AstExpr.Var (intern "subject")))]
    [clause-pattern : AstPattern
      (ast-pat-variant
        "ExprClause"
        (ast-pattern-cons
          (ast-pat-binding "first")
          (ast-pattern-cons (ast-pat-binding "second") (ast-pattern-list-new))))]
    [clause-arm : AstMatchArm
      (ast-match-arm
        clause-pattern
        (ctfe-ast-push env (AstExpr.Var (intern "second"))))]
    [match-expr : i64
      (ast-expr-match-with-pools
        (ctfe-env-pools env)
        scrutinee
        (ast-match-arm-cons clause-arm (ast-match-arm-list-new)))]
    (match (compiler-ctfe-eval
      (ctfe-ast-get env match-expr)
      env
      (ctfe-fuel-limit))
      [(ResultCtfe.Ok value _)
        (match value
          [(CompilerCtfeValue.Expr node _)
            (ctfe-test-expr-eq-in-env env node false-lit)]
          [_ false])]
      [(ResultCtfe.Err _) false])))

(define (compiler-ctfe-expr-pattern-match-ok?) : bool
  (and
    (compiler-ctfe-expr-pattern-match-int-ok?)
    (compiler-ctfe-expr-pattern-match-if-ok?)
    (compiler-ctfe-expr-pattern-match-clause-ok?)))

(define (compiler-ctfe-self-test) : i64
  (begin
    (unless (compiler-ctfe-type-literal-ok?) (return 1))
    (unless (compiler-ctfe-type-comparison-ok?) (return 1))
    (unless (compiler-ctfe-raw-pointer-type-comparison-ok?) (return 1))
    (unless (compiler-ctfe-f64-ok?) (return 1))
    (unless (compiler-ctfe-layout-query-ok?) (return 1))
    (unless (compiler-ctfe-reflection-query-ok?) (return 1))
    (unless (compiler-ctfe-reflection-from-program-ok?) (return 1))
    (unless (compiler-ctfe-type-info-reflection-ok?) (return 1))
    (unless (compiler-ctfe-expr-eq-ok?) (return 1))
    (unless (compiler-ctfe-expr-list-ok?) (return 1))
    (unless (compiler-ctfe-expr-list-fold-sketch-ok?) (return 1))
    (unless (compiler-ctfe-builtin-dispatch-reset-ok?) (return 1))
    (unless (compiler-ctfe-pattern-list-bindings-ok?) (return 1))
    (unless (compiler-ctfe-checked-expr-constructors-ok?) (return 1))
    (unless (compiler-ctfe-checked-expr-inspectors-ok?) (return 1))
    (unless (compiler-ctfe-checked-expr-rejects-non-bool-cond-ok?) (return 1))
    (unless (compiler-ctfe-quote-syntax-ok?) (return 1))
    (unless (compiler-ctfe-expr-pattern-match-ok?) (return 1))
    42))

(cfg
  test
  (test
    compiler-ctfe-self-test
    (if (= (compiler-ctfe-self-test) 42)
      unit
      (begin
        (/ 1 0)
        unit))))