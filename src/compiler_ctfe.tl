;; compiler_ctfe.tl - Selfhost compile-time function evaluation (CTFE) for
;; expression-position `(comptime expr)` (#719, scalar subset).
;;
;; Ports the scalar slice of the Rust reference `src/ctfe.rs`. Supported
;; compile-time value types are i64, f64/f32, bool, char, unit, type values, and
;; Expr / list aggregates (#1137).
;;
;; Evaluation is purely functional: the environment is an immutable cons list
;; threaded through recursion, and the step budget ("fuel") is threaded through
;; results so the evaluator stays deterministic without a mutable counter.
(import stdlib.io)
(import stdlib.hashmap)
(import "compiler_ast_types.tl")
(import "compiler_diagnostic.tl")
(import "compiler_float.tl")
(import stdlib.string)

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

;; A compile-time value. Scalar subset from #719; Expr / ExprList aggregates
;; from #1137 for macro transformers.
(defenum CompilerCtfeValue
  (CtfeI64 i64)
  (CtfeF64 f64)
  (CtfeF32 f64)
  (CtfeBool bool)
  (CtfeChar char)
  (CtfeString String)
  (CtfeUnit)
  (CtfeType AstType)
  ;; A user-facing `Expr` code fragment plus its internally checked produced
  ;; type. The type is not part of the source-level Expr type (#1135).
  (CtfeExpr i64 AstType)
  (CtfeExprList AstExprList)
  (CtfeExprClause AstExprClause)
  (CtfeExprClauseList AstExprClauseList)
  (CtfeExprBindingClause AstExprBindingClause)
  (CtfeExprBindingClauseList AstExprBindingClauseList))

(define (ctfe-untyped-expr-type-name) : String
  "__typelisp_untyped_expr")

(define (ctfe-untyped-expr-type) : AstType
  (AstTyVar (intern (ctfe-untyped-expr-type-name))))

(define (ctfe-untyped-expr-type? [ty : AstType]) : bool
  (match ty
    [(AstTyVar name)
      (string.string-eq (intern-str name) (ctfe-untyped-expr-type-name))]
    [_ false]))

(define (ctfe-captured-expr-type-name) : String
  "__typelisp_captured_expr")

(define (ctfe-captured-expr-type-with-pools
  [pools : AstNodePoolContext]
  [ty : AstType]) : AstType
  (AstTyRegion
    (ctfe-captured-expr-type-name)
    (ast-node-pool-context-type-push pools ty)))

(define (ctfe-captured-expr-type [ty : AstType]) : AstType
  (ctfe-captured-expr-type-with-pools (ast-node-pool-context-capture-active) ty))

(define (ctfe-captured-expr-type? [ty : AstType]) : bool
  (match ty
    [(AstTyRegion name _)
      (string.string-eq name (ctfe-captured-expr-type-name))]
    [_ false]))

(define (ctfe-captured-expr-type-inner-with-pools
  [pools : AstNodePoolContext]
  [ty : AstType]) : AstType
  (match ty
    [(AstTyRegion name inner)
      (if (string.string-eq name (ctfe-captured-expr-type-name))
        (ast-node-pool-context-type-get pools inner)
        ty)]
    [_ ty]))

(define (ctfe-captured-expr-type-inner [ty : AstType]) : AstType
  (ctfe-captured-expr-type-inner-with-pools
    (ast-node-pool-context-capture-active)
    ty))

(defenum CtfeValueList
  (CtfeValueNil)
  (CtfeValueCons CompilerCtfeValue (Box CtfeValueList)))

;; CTFE-owned type layout metadata. The typechecker/lowerer build this from
;; their `TcContext` without making CTFE import typecheck.
;;
;; Storage disposition (#2748):
;; - CtfeLayoutFieldList, CtfeLayoutInfoList, CtfeReflectFieldList,
;;   CtfeReflectVariantList, and CtfeReflectInfoList are vector-backed
;;   generated-collection families. The historical `List` names are retained so
;;   callers do not need a public naming churn while the representation changes.
;; - CtfeEnv remains a persistent cons chain because lexical shadowing and cheap
;;   push/pop are its primary operations.
;; - AST-owned lists such as AstExprList, AstTypeList, and AstParamList remain
;;   frontend data structures and are tracked separately by #2565.
(defenum CtfeLayoutField
  (CtfeLayoutField String i64))

(comptime-decl
  (:generated vector-family CtfeLayoutFieldList "CtfeLayoutField")
  (defstruct CtfeLayoutFieldList
    (slots (Array CtfeLayoutField))
    (len i64)))

(defenum CtfeLayoutInfo
  (CtfeLayoutInfo String bool i64 i64 CtfeLayoutFieldList))

(comptime-decl
  (:generated vector-family CtfeLayoutInfoList "CtfeLayoutInfo")
  (defstruct CtfeLayoutInfoList
    (slots (Array CtfeLayoutInfo))
    (len i64)))

(defenum CtfeMaybeLayoutInfo
  (CtfeNoLayoutInfo)
  (CtfeSomeLayoutInfo CtfeLayoutInfo))

(defenum CtfeMaybeFieldName
  (CtfeNoFieldName)
  (CtfeSomeFieldName String))

;; CTFE-owned type reflection metadata. Typecheck and specialization build this
;; from `AstProgram` and pass it into CTFE without making CTFE import either pass.
(defenum CtfeReflectField
  (CtfeReflectField String AstType))

(comptime-decl
  (:generated vector-family CtfeReflectFieldList "CtfeReflectField")
  (defstruct CtfeReflectFieldList
    (slots (Array CtfeReflectField))
    (len i64)))

(defenum CtfeReflectVariant
  (CtfeReflectVariant String AstTypeList))

(comptime-decl
  (:generated vector-family CtfeReflectVariantList "CtfeReflectVariant")
  (defstruct CtfeReflectVariantList
    (slots (Array CtfeReflectVariant))
    (len i64)))

(defenum CtfeReflectInfo
  (CtfeReflectStruct String String String CtfeReflectFieldList)
  (CtfeReflectEnum String String String CtfeReflectVariantList))

(comptime-decl
  (:generated vector-family CtfeReflectInfoList "CtfeReflectInfo")
  (defstruct CtfeReflectInfoList
    (slots (Array CtfeReflectInfo))
    (len i64)))

(defenum CtfeMaybeReflectInfo
  (CtfeNoReflectInfo)
  (CtfeSomeReflectInfo CtfeReflectInfo))

;; Immutable name -> value environment plus immutable type metadata tables. Newest
;; value binding sits at the front so lookup finds the most recent shadowing
;; binding first; metadata lives at the root and is shared by extensions.
(defenum CtfeEnv
  (CtfeEnvNil AstNodePoolContext CtfeLayoutInfoList CtfeReflectInfoList)
  (CtfeEnvCons String CompilerCtfeValue AstType (Box CtfeEnv)))

(define (ctfe-env-empty-with-pools [pools : AstNodePoolContext]) : CtfeEnv
  (CtfeEnvNil
    pools
    (ctfe-layout-info-list-empty)
    (ctfe-reflect-info-list-empty)))

(define (ctfe-env-empty) : CtfeEnv
  (ctfe-env-empty-with-pools (ast-node-pool-context-capture-active)))

(define (ctfe-env-with-layouts-and-pools
  [layouts : CtfeLayoutInfoList]
  [pools : AstNodePoolContext]) : CtfeEnv
  (CtfeEnvNil pools layouts (ctfe-reflect-info-list-empty)))

(define (ctfe-env-with-layouts [layouts : CtfeLayoutInfoList]) : CtfeEnv
  (ctfe-env-with-layouts-and-pools
    layouts
    (ast-node-pool-context-capture-active)))

(define (ctfe-env-with-reflections-and-pools
  [reflections : CtfeReflectInfoList]
  [pools : AstNodePoolContext]) : CtfeEnv
  (CtfeEnvNil pools (ctfe-layout-info-list-empty) reflections))

(define (ctfe-env-with-reflections [reflections : CtfeReflectInfoList]) : CtfeEnv
  (ctfe-env-with-reflections-and-pools
    reflections
    (ast-node-pool-context-capture-active)))

(define (ctfe-env-with-metadata-and-pools
  [layouts : CtfeLayoutInfoList]
  [reflections : CtfeReflectInfoList]
  [pools : AstNodePoolContext]) : CtfeEnv
  (CtfeEnvNil pools layouts reflections))

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
  (CtfeEnvCons name value (ctfe-value-default-cast-type value) (box env)))

(define (ctfe-env-extend-typed
  [env : CtfeEnv]
  [name : String]
  [value : CompilerCtfeValue]
  [ty : AstType]) : CtfeEnv
  (CtfeEnvCons name value ty (box env)))

(define (ctfe-layout-field-list-with-capacity [capacity : i64]) : CtfeLayoutFieldList
  (CtfeLayoutFieldList (make-array CtfeLayoutField capacity) 0))

(define (ctfe-layout-field-list-empty) : CtfeLayoutFieldList
  (ctfe-layout-field-list-with-capacity 0))

(define (ctfe-layout-field-list-ref [items : CtfeLayoutFieldList] [index : i64]) : CtfeLayoutField
  (array-ref (struct-get items slots) index))

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
  (CtfeLayoutInfoList (make-array CtfeLayoutInfo capacity) 0))

(define (ctfe-layout-info-list-empty) : CtfeLayoutInfoList
  (ctfe-layout-info-list-with-capacity 0))

(define (ctfe-layout-info-list-ref [items : CtfeLayoutInfoList] [index : i64]) : CtfeLayoutInfo
  (array-ref (struct-get items slots) index))

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
  (CtfeReflectFieldList (make-array CtfeReflectField capacity) 0))

(define (ctfe-reflect-field-list-empty) : CtfeReflectFieldList
  (ctfe-reflect-field-list-with-capacity 0))

(define (ctfe-reflect-field-list-ref
  [items : CtfeReflectFieldList]
  [index : i64]) : CtfeReflectField
  (array-ref (struct-get items slots) index))

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
  (CtfeReflectVariantList (make-array CtfeReflectVariant capacity) 0))

(define (ctfe-reflect-variant-list-empty) : CtfeReflectVariantList
  (ctfe-reflect-variant-list-with-capacity 0))

(define (ctfe-reflect-variant-list-ref
  [items : CtfeReflectVariantList]
  [index : i64]) : CtfeReflectVariant
  (array-ref (struct-get items slots) index))

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
  (CtfeReflectInfoList (make-array CtfeReflectInfo capacity) 0))

(define (ctfe-reflect-info-list-empty) : CtfeReflectInfoList
  (ctfe-reflect-info-list-with-capacity 0))

(define (ctfe-reflect-info-list-ref [items : CtfeReflectInfoList] [index : i64]) : CtfeReflectInfo
  (array-ref (struct-get items slots) index))

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
    [(CtfeLayoutInfo name _ _ _ _) name]))

;; Per-build dedup set of keys already added to the metadata list. The reflection
;; and layout builds each register every type under its key (and module alias);
;; checking membership against the old linked list was O(types^2). This hashset
;; keeps each `add-if-missing` O(1), so the whole build is O(types). Reset at the
;; start of each build (layouts then reflections run sequentially in tc-ctfe-env).
(define ctfe-build-seen-keys : hashmap.StringI64Map
  (hashmap.string-i64-map-with-capacity 1))

(define (ctfe-build-seen-reset!) : unit
  (set! ctfe-build-seen-keys (hashmap.string-i64-map-with-capacity 256)))

(define (ctfe-build-seen-add? [key : String]) : bool
  (if (hashmap.string-i64-map-contains? ctfe-build-seen-keys key)
    false
    (begin
      (set!
        ctfe-build-seen-keys
        (hashmap.string-i64-map-put ctfe-build-seen-keys key 1))
      true)))

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
    (CtfeNoLayoutInfo)
    (let
      [info : CtfeLayoutInfo (ctfe-layout-info-list-ref layouts index)]
      (if (string.string-eq (ctfe-layout-info-name info) name)
        (CtfeSomeLayoutInfo info)
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
        [(CtfeLayoutField field-name offset)
          (if (string.string-eq field-name name)
            offset
            (ctfe-layout-field-offset-from fields name (+ index 1)))]))))

(define (ctfe-layout-field-offset
  [fields : CtfeLayoutFieldList]
  [name : String]) : i64
  (ctfe-layout-field-offset-from fields name 0))

(define (ctfe-env-layouts [env : CtfeEnv]) : CtfeLayoutInfoList
  (match env
    [(CtfeEnvNil _ layouts _) layouts]
    [(CtfeEnvCons _ _ _ rest) (ctfe-env-layouts (box-get rest))]))

(define (ctfe-env-reflections [env : CtfeEnv]) : CtfeReflectInfoList
  (match env
    [(CtfeEnvNil _ _ reflections) reflections]
    [(CtfeEnvCons _ _ _ rest) (ctfe-env-reflections (box-get rest))]))

(define (ctfe-env-pools [env : CtfeEnv]) : AstNodePoolContext
  (match env
    [(CtfeEnvNil pools _ _) pools]
    [(CtfeEnvCons _ _ _ rest) (ctfe-env-pools (box-get rest))]))

(define (ctfe-env-rebase-pools [env : CtfeEnv] [pools : AstNodePoolContext]) : CtfeEnv
  (match env
    [(CtfeEnvNil _ layouts reflections) (CtfeEnvNil pools layouts reflections)]
    [(CtfeEnvCons key value ty rest)
      (CtfeEnvCons
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
    [(AstExprSpanned inner-id _)
      (ctfe-expr-unspan env (ctfe-ast-get env inner-id))]
    [_ expr]))

(define (ctfe-ty-get [env : CtfeEnv] [id : i64]) : AstType
  (ast-node-pool-context-type-get (ctfe-env-pools env) id))

(define (ctfe-ty-push [env : CtfeEnv] [node : AstType]) : i64
  (ast-node-pool-context-type-push (ctfe-env-pools env) node))

;; Lookup result for an environment probe.
(defenum CtfeMaybeValue
  (CtfeNoValue)
  (CtfeSomeValue CompilerCtfeValue))

(define (ctfe-env-lookup [env : CtfeEnv] [name : String]) : CtfeMaybeValue
  (match env
    [(CtfeEnvNil _ _ _) (CtfeNoValue)]
    [(CtfeEnvCons key value _ rest)
      (if (string.string-eq key name)
        (CtfeSomeValue value)
        (ctfe-env-lookup (box-get rest) name))]))

(define (ctfe-env-lookup-type [env : CtfeEnv] [name : String]) : AstMaybeType
  (match env
    [(CtfeEnvNil _ _ _) (AstNoType)]
    [(CtfeEnvCons key _ ty rest)
      (if (string.string-eq key name)
        (AstSomeType ty)
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
    (string.string-eq name "char-at")
    (string.string-eq name "length")))

(define (ctfe-hygiene-enabled-name) : String
  "__tl_macro_hygiene_enabled")

(define (ctfe-hygiene-template-prefix) : String
  "__tl_macro_template$")

(define (ctfe-hygiene-global-prefix) : String
  "__tl_macro_global$")

(define (ctfe-hygiene-enabled? [env : CtfeEnv]) : bool
  (match (ctfe-env-lookup env (ctfe-hygiene-enabled-name))
    [(CtfeSomeValue value)
      (match value
        [(CtfeBool enabled) enabled]
        [_ false])]
    [(CtfeNoValue) false]))

(define (ctfe-hygiene-template-name [name : String]) : String
  (if (ctfe-string-prefix? name (ctfe-hygiene-template-prefix))
    name
    (string.string-append (ctfe-hygiene-template-prefix) name)))

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

(define (ctfe-reflect-info-key [info : CtfeReflectInfo]) : String
  (match info
    [(CtfeReflectStruct key _ _ _) key]
    [(CtfeReflectEnum key _ _ _) key]))

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
    (CtfeNoReflectInfo)
    (let
      [info : CtfeReflectInfo (ctfe-reflect-info-list-ref infos index)]
      (if (string.string-eq (ctfe-reflect-info-key info) key)
        (CtfeSomeReflectInfo info)
        (ctfe-reflect-info-lookup-from infos key (- index 1))))))

(define (ctfe-reflect-info-lookup [infos : CtfeReflectInfoList] [key : String]) : CtfeMaybeReflectInfo
  (ctfe-reflect-info-lookup-from infos key (- (struct-get infos len) 1)))

(define (ctfe-reflect-field-def-count [fields : AstFieldDefList]) : i64
  (match fields
    [(AstFieldDefNil) 0]
    [(AstFieldDefCons _ rest)
      (+ 1 (ctfe-reflect-field-def-count (box-get rest)))]))

(define (ctfe-reflect-field-list-from-fields-into
  [fields : AstFieldDefList]
  [out : CtfeReflectFieldList]) : CtfeReflectFieldList
  (match fields
    [(AstFieldDefNil) out]
    [(AstFieldDefCons field rest)
      (let
        [rest : AstFieldDefList (box-get rest)]
        (match field
          [(AstFieldDef name ty _)
            (ctfe-reflect-field-list-from-fields-into
              rest
              (ctfe-reflect-field-list-push
                out
                (CtfeReflectField (intern-str name) ty)))]))]))

(define (ctfe-reflect-field-list-from-fields [fields : AstFieldDefList]) : CtfeReflectFieldList
  (ctfe-reflect-field-list-from-fields-into
    fields
    (ctfe-reflect-field-list-with-capacity
      (ctfe-reflect-field-def-count fields))))

(define (ctfe-reflect-variant-def-count [variants : AstVariantDefList]) : i64
  (match variants
    [(AstVariantDefNil) 0]
    [(AstVariantDefCons _ rest)
      (+ 1 (ctfe-reflect-variant-def-count (box-get rest)))]))

(define (ctfe-reflect-variant-list-from-variants-into
  [variants : AstVariantDefList]
  [out : CtfeReflectVariantList]) : CtfeReflectVariantList
  (match variants
    [(AstVariantDefNil) out]
    [(AstVariantDefCons variant rest)
      (let
        [rest : AstVariantDefList (box-get rest)]
        (match variant
          [(AstVariantDef name payloads _)
            (ctfe-reflect-variant-list-from-variants-into
              rest
              (ctfe-reflect-variant-list-push
                out
                (CtfeReflectVariant (intern-str name) payloads)))]))]))

(define (ctfe-reflect-variant-list-from-variants [variants : AstVariantDefList]) : CtfeReflectVariantList
  (ctfe-reflect-variant-list-from-variants-into
    variants
    (ctfe-reflect-variant-list-with-capacity
      (ctfe-reflect-variant-def-count variants))))

(define (ctfe-reflect-info-add-alias
  [infos : CtfeReflectInfoList]
  [info : CtfeReflectInfo]
  [alias : String]) : CtfeReflectInfoList
  (match info
    [(CtfeReflectStruct _ module name fields)
      (ctfe-reflect-info-list-add-if-missing
        infos
        (CtfeReflectStruct alias module name fields))]
    [(CtfeReflectEnum _ module name variants)
      (ctfe-reflect-info-list-add-if-missing
        infos
        (CtfeReflectEnum alias module name variants))]))

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

(define (ctfe-reflections-from-decls
  [decls : AstDeclList]
  [module : String]
  [infos : CtfeReflectInfoList]) : CtfeReflectInfoList
  (match decls
    [(AstDeclNil) infos]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclModule next-module)
            (ctfe-reflections-from-decls rest (intern-str next-module) infos)]
          [(AstDeclDefStruct name _ _ fields)
            (let
              [name-str : String (intern-str name)]
              [key : String
                (if (= (string.string-length module) 0)
                  name-str
                  (string.string-append
                    module
                    (string.string-append "/" name-str)))]
              [info : CtfeReflectInfo
                (CtfeReflectStruct
                  key
                  module
                  name-str
                  (ctfe-reflect-field-list-from-fields fields))]
              (ctfe-reflections-from-decls
                rest
                module
                (ctfe-reflect-info-add-names infos info name-str module)))]
          [(AstDeclDefStructLifetimes name _ _ _ fields)
            (let
              [name-str : String (intern-str name)]
              [key : String
                (if (= (string.string-length module) 0)
                  name-str
                  (string.string-append
                    module
                    (string.string-append "/" name-str)))]
              [info : CtfeReflectInfo
                (CtfeReflectStruct
                  key
                  module
                  name-str
                  (ctfe-reflect-field-list-from-fields fields))]
              (ctfe-reflections-from-decls
                rest
                module
                (ctfe-reflect-info-add-names infos info name-str module)))]
          [(AstDeclDefEnum name _ variants)
            (let
              [name-str : String (intern-str name)]
              [key : String
                (if (= (string.string-length module) 0)
                  name-str
                  (string.string-append
                    module
                    (string.string-append "/" name-str)))]
              [info : CtfeReflectInfo
                (CtfeReflectEnum
                  key
                  module
                  name-str
                  (ctfe-reflect-variant-list-from-variants variants))]
              (ctfe-reflections-from-decls
                rest
                module
                (ctfe-reflect-info-add-names infos info name-str module)))]
          [(AstDeclDefEnumLifetimes name _ _ variants)
            (let
              [name-str : String (intern-str name)]
              [key : String
                (if (= (string.string-length module) 0)
                  name-str
                  (string.string-append
                    module
                    (string.string-append "/" name-str)))]
              [info : CtfeReflectInfo
                (CtfeReflectEnum
                  key
                  module
                  name-str
                  (ctfe-reflect-variant-list-from-variants variants))]
              (ctfe-reflections-from-decls
                rest
                module
                (ctfe-reflect-info-add-names infos info name-str module)))]
          [(AstDeclComptimeDecl _ template-box)
            (let
              [template : AstDecl (box-get template-box)]
              (match template
                [(AstDeclDefStruct name _ _ fields)
                  (let
                    [name-str : String (intern-str name)]
                    [key : String
                      (if (= (string.string-length module) 0)
                        name-str
                        (string.string-append
                          module
                          (string.string-append "/" name-str)))]
                    [info : CtfeReflectInfo
                      (CtfeReflectStruct
                        key
                        module
                        name-str
                        (ctfe-reflect-field-list-from-fields fields))]
                    (ctfe-reflections-from-decls
                      rest
                      module
                      (ctfe-reflect-info-add-names infos info name-str module)))]
                [(AstDeclDefStructLifetimes name _ _ _ fields)
                  (let
                    [name-str : String (intern-str name)]
                    [key : String
                      (if (= (string.string-length module) 0)
                        name-str
                        (string.string-append
                          module
                          (string.string-append "/" name-str)))]
                    [info : CtfeReflectInfo
                      (CtfeReflectStruct
                        key
                        module
                        name-str
                        (ctfe-reflect-field-list-from-fields fields))]
                    (ctfe-reflections-from-decls
                      rest
                      module
                      (ctfe-reflect-info-add-names infos info name-str module)))]
                [(AstDeclDefEnum name _ variants)
                  (let
                    [name-str : String (intern-str name)]
                    [key : String
                      (if (= (string.string-length module) 0)
                        name-str
                        (string.string-append
                          module
                          (string.string-append "/" name-str)))]
                    [info : CtfeReflectInfo
                      (CtfeReflectEnum
                        key
                        module
                        name-str
                        (ctfe-reflect-variant-list-from-variants variants))]
                    (ctfe-reflections-from-decls
                      rest
                      module
                      (ctfe-reflect-info-add-names infos info name-str module)))]
                [(AstDeclDefEnumLifetimes name _ _ variants)
                  (let
                    [name-str : String (intern-str name)]
                    [key : String
                      (if (= (string.string-length module) 0)
                        name-str
                        (string.string-append
                          module
                          (string.string-append "/" name-str)))]
                    [info : CtfeReflectInfo
                      (CtfeReflectEnum
                        key
                        module
                        name-str
                        (ctfe-reflect-variant-list-from-variants variants))]
                    (ctfe-reflections-from-decls
                      rest
                      module
                      (ctfe-reflect-info-add-names infos info name-str module)))]
                [_ (ctfe-reflections-from-decls rest module infos)]))]
          [_ (ctfe-reflections-from-decls rest module infos)]))]))

(define (ctfe-metadata-decl-capacity [decls : AstDeclList]) : i64
  (match decls
    [(AstDeclNil) 1]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        [rest-capacity : i64 (ctfe-metadata-decl-capacity rest)]
        (match decl
          [(AstDeclDefStruct _ _ _ _) (+ rest-capacity 2)]
          [(AstDeclDefStructLifetimes _ _ _ _ _) (+ rest-capacity 2)]
          [(AstDeclDefEnum _ _ _) (+ rest-capacity 2)]
          [(AstDeclDefEnumLifetimes _ _ _ _) (+ rest-capacity 2)]
          [(AstDeclComptimeDecl _ template-box)
            (let
              [template : AstDecl (box-get template-box)]
              (match template
                [(AstDeclDefStruct _ _ _ _) (+ rest-capacity 2)]
                [(AstDeclDefStructLifetimes _ _ _ _ _) (+ rest-capacity 2)]
                [(AstDeclDefEnum _ _ _) (+ rest-capacity 2)]
                [(AstDeclDefEnumLifetimes _ _ _ _) (+ rest-capacity 2)]
                [_ rest-capacity]))]
          [_ rest-capacity]))]))

(define (ctfe-reflections-from-program [program : AstProgram]) : CtfeReflectInfoList
  (match program
    [(AstProgram decls-box)
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
  (OkCtfe CompilerCtfeValue i64)
  (ErrCtfe CompilerDiagnostic))

(defenum CtfePatternMatch
  (CtfeNoPatternMatch)
  (CtfePatternMatched CtfeEnv))

(defenum ResultCtfeQuoteExpr
  (OkCtfeQuoteExpr i64 AstType i64)
  (ErrCtfeQuoteExpr CompilerDiagnostic))

(defenum ResultCtfeQuoteExprList
  (OkCtfeQuoteExprList AstExprList i64)
  (ErrCtfeQuoteExprList CompilerDiagnostic))

(defenum ResultCtfeQuoteType
  (OkCtfeQuoteType AstType i64)
  (ErrCtfeQuoteType CompilerDiagnostic))

(defenum ResultCtfeQuoteTypeList
  (OkCtfeQuoteTypeList AstTypeList i64)
  (ErrCtfeQuoteTypeList CompilerDiagnostic))

(defenum ResultCtfeQuoteLifetimeList
  (OkCtfeQuoteLifetimeList AstLifetimeList)
  (ErrCtfeQuoteLifetimeList CompilerDiagnostic))

(defenum ResultCtfeQuoteMaybeType
  (OkCtfeQuoteMaybeType AstMaybeType i64)
  (ErrCtfeQuoteMaybeType CompilerDiagnostic))

(defenum ResultCtfeQuoteLetBindings
  (OkCtfeQuoteLetBindings AstLetBindingList i64)
  (ErrCtfeQuoteLetBindings CompilerDiagnostic))

(defenum ResultCtfeQuoteResourceBindings
  (OkCtfeQuoteResourceBindings AstResourceBindingList i64)
  (ErrCtfeQuoteResourceBindings CompilerDiagnostic))

(defenum ResultCtfeQuotePattern
  (OkCtfeQuotePattern AstPattern)
  (ErrCtfeQuotePattern CompilerDiagnostic))

(defenum ResultCtfeQuotePatternList
  (OkCtfeQuotePatternList AstPatternList)
  (ErrCtfeQuotePatternList CompilerDiagnostic))

(defenum ResultCtfeQuoteArms
  (OkCtfeQuoteArms AstMatchArmList i64)
  (ErrCtfeQuoteArms CompilerDiagnostic))

(define (ctfe-fuel-limit) : i64
  10000)

;; Build a diagnostic anchored at the (possibly spanned) expression.
(define (ctfe-diagnostic-at-expr [expr : AstExpr] [message : String]) : CompilerDiagnostic
  (match expr
    [(AstExprSpanned _ span)
      (compiler-diagnostic-from-ast-span "" span message)]
    [_ (compiler-diagnostic-at-start "" message)]))

;; Human-readable tag for the unsupported-form diagnostic, mirroring
;; `describe_expr` in src/ctfe.rs.
(define (ctfe-describe-expr [expr : AstExpr]) : String
  (match expr
    [(AstExprSpanned _ _) "expression"]
    [(AstExprLiteral _) "literal"]
    [(AstExprVar _) "variable reference"]
    [(AstExprBinary _ _ _) "binary operation"]
    [(AstExprUnary _ _) "unary operation"]
    [(AstExprCall _ _) "function call"]
    [(AstExprBracketClause _) "bracket clause"]
    [(AstExprTypeLiteral _) "type literal"]
    [(AstExprIf _ _ _) "if"]
    [(AstExprLet _) "let"]
    [(AstExprLambda _) "lambda"]
    [(AstExprTuple _) "tuple"]
    [(AstExprTupleRef _ _) "tuple-ref"]
    [(AstExprArray _) "array"]
    [(AstExprMakeArray _ _) "make-array"]
    [(AstExprArrayRef _ _) "array-ref"]
    [(AstExprArraySet _ _ _) "array-set!"]
    [(AstExprArrayPush _ _) "array-push!"]
    [(AstExprStringRef _ _) "string-ref"]
    [(AstExprWhile _ _) "while"]
    [(AstExprBegin _) "begin"]
    [(AstExprUnsafe _) "unsafe"]
    [(AstExprSet _ _) "set!"]
    [(AstExprAnn _ _) "type annotation"]
    [(AstExprCast _ _) "cast"]
    [(AstExprBorrow mutable _ _)
      (if mutable
        "mutable borrow"
        "borrow")]
    [(AstExprMatch _) "match"]
    [(AstExprForeach _) "foreach"]
    [(AstExprSpmdReduce _) "spmd-reduce"]
    [(AstExprSpmdScan _) "spmd-scan"]
    [(AstExprSpmdBroadcast _ _) "spmd-broadcast"]
    [(AstExprSpmdShuffle _ _) "spmd-shuffle"]
    [(AstExprSpmdProgramIndex) "program-index"]
    [(AstExprSpmdProgramCount) "program-count"]
    [(AstExprStructGet _ _) "struct-get"]
    [(AstExprStructSet _ _ _) "set!"]
    [(AstExprWithRegion _ _) "with-arena"]
    [(AstExprWithEscape _ _) "with-escape"]
    [(AstExprWithScratch _) "with-scratch"]
    [(AstExprInArena _ _) "in-arena"]
    [(AstExprWithResource _) "with"]
    [(AstExprTypeLiteral _) "type literal"]
    [(AstExprInit _) "init"]
    [(AstExprComptime _) "comptime"]
    [(AstExprQuote _) "quote"]
    [(AstExprQuasiquote _) "quasiquote"]
    [(AstExprUnquote _) "unquote"]
    [(AstExprUnquoteSplicing _) "unquote-splicing"]
    [(AstExprTry _) "try"]
    [(AstExprReturn _) "return"]
    [(AstExprPtrNull _) "ptr-null"]
    [(AstExprPtrNullCheck _) "ptr-null?"]
    [(AstExprPtrAddrOf _) "ptr-addr-of"]
    [(AstExprPtrRead _) "ptr-read"]
    [(AstExprPtrWrite _ _) "ptr-write!"]
    [(AstExprPtrOffset _ _) "ptr-offset"]
    [(AstExprPtrCast _ _) "ptr-cast"]
    [(AstExprPtrToInt _) "ptr->int"]
    [(AstExprIntToPtr _ _) "int->ptr"]
    [(AstExprBox _) "box"]
    [(AstExprBoxGet _) "box-get"]
    [(AstExprBoxTake _) "box-take"]
    [(AstExprBoxSet _ _) "set!"]
    [(AstExprStringData _) "string-data"]
    [(AstExprStringFromBytes _ _) "string-from-bytes"]
    [(AstExprArrayData _) "array-data"]
    [(AstExprBinaryData _) "binary-data"]
    [(AstExprSpmdProgramIndex) "program-index"]
    [(AstExprSpmdProgramCount) "program-count"]
    [(AstExprProgramArgc) "program-argc"]
    [(AstExprProgramArgv) "program-argv"]
    [(AstExprProgramEnvp) "program-envp"]
    [(AstExprCpuIdEax _ _) "cpuid-eax"]
    [(AstExprCpuIdEbx _ _) "cpuid-ebx"]
    [(AstExprCpuIdEcx _ _) "cpuid-ecx"]
    [(AstExprCpuIdEdx _ _) "cpuid-edx"]
    [(AstExprXgetbv _) "xgetbv"]
    [(AstExprSyscall _) "syscall"]))

(define (ctfe-value-type-name [value : CompilerCtfeValue]) : String
  (match value
    [(CtfeI64 _) "i64"]
    [(CtfeF64 _) "f64"]
    [(CtfeF32 _) "f32"]
    [(CtfeBool _) "bool"]
    [(CtfeChar _) "char"]
    [(CtfeString _) "String"]
    [(CtfeUnit) "unit"]
    [(CtfeType _) "type"]
    [(CtfeExpr _ _) "Expr"]
    [(CtfeExprList _) "expr-list"]
    [(CtfeExprClause _) "ExprClause"]
    [(CtfeExprClauseList _) "ExprClauseList"]
    [(CtfeExprBindingClause _) "ExprBindingClause"]
    [(CtfeExprBindingClauseList _) "ExprBindingClauseList"]))

;; Promote a char to its i64 code point so the i64 comparison primitives drive
;; char ordering/equality, matching Rust's code-point comparison.
(define (ctfe-char-code [c : char]) : i64
  (cast c : i64))

;; --- literals ---------------------------------------------------------------
(define (ctfe-eval-literal [lit : AstLiteral] [expr : AstExpr] [fuel : i64]) : ResultCtfe
  (match lit
    [(AstLitInt n _) (OkCtfe (CtfeI64 n) fuel)]
    [(AstLitBool b) (OkCtfe (CtfeBool b) fuel)]
    [(AstLitChar c) (OkCtfe (CtfeChar c) fuel)]
    [(AstLitUnit) (OkCtfe (CtfeUnit) fuel)]
    [(AstLitFloat text)
      (match (compiler-float-parse-f64 text)
        [(CompilerFloatSomeF64 value)
          (if (compiler-float-f64-finite? value)
            (OkCtfe (CtfeF64 value) fuel)
            (ErrCtfe
              (ctfe-diagnostic-at-expr
                expr
                "comptime: non-finite f64 literal is not supported")))]
        [(CompilerFloatNoF64)
          (if (compiler-float-decimal-syntax? text)
            (ErrCtfe
              (ctfe-diagnostic-at-expr
                expr
                "comptime: non-finite f64 literal is not supported"))
            (ErrCtfe
              (ctfe-diagnostic-at-expr expr "comptime: invalid f64 literal")))])]
    [(AstLitString text) (OkCtfe (CtfeString text) fuel)]))

;; --- binary operators -------------------------------------------------------
;; i64 arithmetic/bitwise/shift and i64 comparisons.
(define (ctfe-eval-bin-i64
  [op : AstBinOp]
  [a : i64]
  [b : i64]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (match op
    [(AstBinAdd) (OkCtfe (CtfeI64 (+ a b)) fuel)]
    [(AstBinSub) (OkCtfe (CtfeI64 (- a b)) fuel)]
    [(AstBinMul) (OkCtfe (CtfeI64 (* a b)) fuel)]
    [(AstBinDiv)
      (if (= b 0)
        (ErrCtfe (ctfe-diagnostic-at-expr expr "division by zero in comptime"))
        (OkCtfe (CtfeI64 (/ a b)) fuel))]
    [(AstBinMod)
      (if (= b 0)
        (ErrCtfe (ctfe-diagnostic-at-expr expr "modulo by zero in comptime"))
        (OkCtfe (CtfeI64 (% a b)) fuel))]
    [(AstBinEq) (OkCtfe (CtfeBool (= a b)) fuel)]
    [(AstBinNe) (OkCtfe (CtfeBool (!= a b)) fuel)]
    [(AstBinLt) (OkCtfe (CtfeBool (< a b)) fuel)]
    [(AstBinLe) (OkCtfe (CtfeBool (<= a b)) fuel)]
    [(AstBinGt) (OkCtfe (CtfeBool (> a b)) fuel)]
    [(AstBinGe) (OkCtfe (CtfeBool (>= a b)) fuel)]
    [(AstBinBitAnd) (OkCtfe (CtfeI64 (bit-and a b)) fuel)]
    [(AstBinBitOr) (OkCtfe (CtfeI64 (bit-or a b)) fuel)]
    [(AstBinBitXor) (OkCtfe (CtfeI64 (bit-xor a b)) fuel)]
    [(AstBinShl) (OkCtfe (CtfeI64 (shl a b)) fuel)]
    [(AstBinShr) (OkCtfe (CtfeI64 (shr a b)) fuel)]
    [(AstBinAnd)
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          "'and' in comptime requires bool operands"))]
    [(AstBinOr)
      (ErrCtfe
        (ctfe-diagnostic-at-expr expr "'or' in comptime requires bool operands"))]))

(define (ctfe-f64-result [value : f64] [expr : AstExpr] [fuel : i64]) : ResultCtfe
  (if (compiler-float-f64-finite? value)
    (OkCtfe (CtfeF64 value) fuel)
    (ErrCtfe
      (ctfe-diagnostic-at-expr
        expr
        "comptime: non-finite f64 result is not supported"))))

(define (ctfe-f32-result [value : f64] [expr : AstExpr] [fuel : i64]) : ResultCtfe
  (let
    [rounded : f64 (compiler-float-round-f32-as-f64 value)]
    (if (compiler-float-f64-finite? rounded)
      (OkCtfe (CtfeF32 rounded) fuel)
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          "comptime: non-finite f32 result is not supported")))))

;; Finite f64 arithmetic and comparisons. Non-finite results are rejected until
;; TypeLisp specifies NaN payload and infinity serialization across backends.
(define (ctfe-eval-bin-f64
  [op : AstBinOp]
  [a : f64]
  [b : f64]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (match op
    [(AstBinAdd) (ctfe-f64-result (+ a b) expr fuel)]
    [(AstBinSub) (ctfe-f64-result (- a b) expr fuel)]
    [(AstBinMul) (ctfe-f64-result (* a b) expr fuel)]
    [(AstBinDiv)
      (if (= b 0.0)
        (ErrCtfe
          (ctfe-diagnostic-at-expr expr "float division by zero in comptime"))
        (ctfe-f64-result (/ a b) expr fuel))]
    [(AstBinEq) (OkCtfe (CtfeBool (= a b)) fuel)]
    [(AstBinNe) (OkCtfe (CtfeBool (!= a b)) fuel)]
    [(AstBinLt) (OkCtfe (CtfeBool (< a b)) fuel)]
    [(AstBinLe) (OkCtfe (CtfeBool (<= a b)) fuel)]
    [(AstBinGt) (OkCtfe (CtfeBool (> a b)) fuel)]
    [(AstBinGe) (OkCtfe (CtfeBool (>= a b)) fuel)]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          "this operation is not supported on f64 in compile-time evaluation"))]))

(define (ctfe-eval-bin-f32
  [op : AstBinOp]
  [a : f64]
  [b : f64]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (match op
    [(AstBinAdd) (ctfe-f32-result (+ a b) expr fuel)]
    [(AstBinSub) (ctfe-f32-result (- a b) expr fuel)]
    [(AstBinMul) (ctfe-f32-result (* a b) expr fuel)]
    [(AstBinDiv)
      (if (= b 0.0)
        (ErrCtfe
          (ctfe-diagnostic-at-expr expr "float division by zero in comptime"))
        (ctfe-f32-result (/ a b) expr fuel))]
    [(AstBinEq) (OkCtfe (CtfeBool (= a b)) fuel)]
    [(AstBinNe) (OkCtfe (CtfeBool (!= a b)) fuel)]
    [(AstBinLt) (OkCtfe (CtfeBool (< a b)) fuel)]
    [(AstBinLe) (OkCtfe (CtfeBool (<= a b)) fuel)]
    [(AstBinGt) (OkCtfe (CtfeBool (> a b)) fuel)]
    [(AstBinGe) (OkCtfe (CtfeBool (>= a b)) fuel)]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          "this operation is not supported on f32 in compile-time evaluation"))]))

;; bool comparisons and boolean connectives.
(define (ctfe-eval-bin-bool
  [op : AstBinOp]
  [a : bool]
  [b : bool]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (match op
    [(AstBinEq) (OkCtfe (CtfeBool (or (and a b) (and (not a) (not b)))) fuel)]
    [(AstBinNe)
      (OkCtfe (CtfeBool (not (or (and a b) (and (not a) (not b))))) fuel)]
    [(AstBinAnd) (OkCtfe (CtfeBool (and a b)) fuel)]
    [(AstBinOr) (OkCtfe (CtfeBool (or a b)) fuel)]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          "this operation is not supported on bool in compile-time evaluation"))]))

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
      [(AstBinEq) (OkCtfe (CtfeBool (= ca cb)) fuel)]
      [(AstBinNe) (OkCtfe (CtfeBool (!= ca cb)) fuel)]
      [(AstBinLt) (OkCtfe (CtfeBool (< ca cb)) fuel)]
      [(AstBinLe) (OkCtfe (CtfeBool (<= ca cb)) fuel)]
      [(AstBinGt) (OkCtfe (CtfeBool (> ca cb)) fuel)]
      [(AstBinGe) (OkCtfe (CtfeBool (>= ca cb)) fuel)]
      [_
        (ErrCtfe
          (ctfe-diagnostic-at-expr
            expr
            "this operation is not supported on char in compile-time evaluation"))])))

;; string comparisons (only `==`/`!=`).
(define (ctfe-eval-bin-string
  [op : AstBinOp]
  [a : String]
  [b : String]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (match op
    [(AstBinEq) (OkCtfe (CtfeBool (string.string-eq a b)) fuel)]
    [(AstBinNe) (OkCtfe (CtfeBool (not (string.string-eq a b))) fuel)]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          "this operation is not supported on String in compile-time evaluation"))]))

;; unit comparisons (only `==`/`!=`).
(define (ctfe-eval-bin-unit [op : AstBinOp] [expr : AstExpr] [fuel : i64]) : ResultCtfe
  (match op
    [(AstBinEq) (OkCtfe (CtfeBool true) fuel)]
    [(AstBinNe) (OkCtfe (CtfeBool false) fuel)]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          "this operation is not supported on unit in compile-time evaluation"))]))

;; Dispatch a binary op over two already-evaluated operands.
(define (ctfe-apply-binop
  [op : AstBinOp]
  [lv : CompilerCtfeValue]
  [rv : CompilerCtfeValue]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match lv
    [(CtfeI64 a)
      (match rv
        [(CtfeI64 b) (ctfe-eval-bin-i64 op a b expr fuel)]
        [_
          (ErrCtfe
            (ctfe-diagnostic-at-expr
              expr
              "binary operation in comptime requires matching operand types"))])]
    [(CtfeF64 a)
      (match rv
        [(CtfeF64 b) (ctfe-eval-bin-f64 op a b expr fuel)]
        [_
          (ErrCtfe
            (ctfe-diagnostic-at-expr
              expr
              "binary operation in comptime requires matching operand types"))])]
    [(CtfeF32 a)
      (match rv
        [(CtfeF32 b) (ctfe-eval-bin-f32 op a b expr fuel)]
        [_
          (ErrCtfe
            (ctfe-diagnostic-at-expr
              expr
              "binary operation in comptime requires matching operand types"))])]
    [(CtfeBool a)
      (match rv
        [(CtfeBool b) (ctfe-eval-bin-bool op a b expr fuel)]
        [_
          (ErrCtfe
            (ctfe-diagnostic-at-expr
              expr
              "binary operation in comptime requires matching operand types"))])]
    [(CtfeChar a)
      (match rv
        [(CtfeChar b) (ctfe-eval-bin-char op a b expr fuel)]
        [_
          (ErrCtfe
            (ctfe-diagnostic-at-expr
              expr
              "binary operation in comptime requires matching operand types"))])]
    [(CtfeString a)
      (match rv
        [(CtfeString b) (ctfe-eval-bin-string op a b expr fuel)]
        [_
          (ErrCtfe
            (ctfe-diagnostic-at-expr
              expr
              "binary operation in comptime requires matching operand types"))])]
    [(CtfeUnit)
      (match rv
        [(CtfeUnit) (ctfe-eval-bin-unit op expr fuel)]
        [_
          (ErrCtfe
            (ctfe-diagnostic-at-expr
              expr
              "binary operation in comptime requires matching operand types"))])]
    [(CtfeType a)
      (match rv
        [(CtfeType b)
          (match op
            [(AstBinEq) (OkCtfe (CtfeBool (ctfe-type-eq-in-env env a b)) fuel)]
            [(AstBinNe)
              (OkCtfe (CtfeBool (not (ctfe-type-eq-in-env env a b))) fuel)]
            [_
              (ErrCtfe
                (ctfe-diagnostic-at-expr
                  expr
                  "this operation is not supported on type in compile-time evaluation"))])]
        [_
          (ErrCtfe
            (ctfe-diagnostic-at-expr
              expr
              "binary operation in comptime requires matching operand types"))])]
    [(CtfeExpr a a-ty)
      (match rv
        [(CtfeExpr b b-ty)
          (match op
            [(AstBinEq)
              (OkCtfe
                (CtfeBool
                  (and
                    (ctfe-expr-eq-in-env
                      env
                      (ctfe-ast-get env a)
                      (ctfe-ast-get env b))
                    (ctfe-type-eq-in-env env a-ty b-ty)))
                fuel)]
            [(AstBinNe)
              (OkCtfe
                (CtfeBool
                  (not
                    (and
                      (ctfe-expr-eq-in-env
                        env
                        (ctfe-ast-get env a)
                        (ctfe-ast-get env b))
                      (ctfe-type-eq-in-env env a-ty b-ty))))
                fuel)]
            [_
              (ErrCtfe
                (ctfe-diagnostic-at-expr
                  expr
                  "this operation is not supported on expr in compile-time evaluation"))])]
        [_
          (ErrCtfe
            (ctfe-diagnostic-at-expr
              expr
              "binary operation in comptime requires matching operand types"))])]
    [(CtfeExprList a)
      (match rv
        [(CtfeExprList b)
          (match op
            [(AstBinEq)
              (OkCtfe (CtfeBool (ctfe-expr-list-eq-in-env env a b)) fuel)]
            [(AstBinNe)
              (OkCtfe (CtfeBool (not (ctfe-expr-list-eq-in-env env a b))) fuel)]
            [_
              (ErrCtfe
                (ctfe-diagnostic-at-expr
                  expr
                  "this operation is not supported on expr-list in compile-time evaluation"))])]
        [_
          (ErrCtfe
            (ctfe-diagnostic-at-expr
              expr
              "binary operation in comptime requires matching operand types"))])]
    [(CtfeExprClause a)
      (match rv
        [(CtfeExprClause b)
          (match op
            [(AstBinEq)
              (OkCtfe (CtfeBool (ctfe-expr-clause-eq-in-env env a b)) fuel)]
            [(AstBinNe)
              (OkCtfe
                (CtfeBool (not (ctfe-expr-clause-eq-in-env env a b)))
                fuel)]
            [_
              (ErrCtfe
                (ctfe-diagnostic-at-expr
                  expr
                  "this operation is not supported on expr-clause in compile-time evaluation"))])]
        [_
          (ErrCtfe
            (ctfe-diagnostic-at-expr
              expr
              "binary operation in comptime requires matching operand types"))])]
    [(CtfeExprClauseList a)
      (match rv
        [(CtfeExprClauseList b)
          (match op
            [(AstBinEq)
              (OkCtfe (CtfeBool (ctfe-expr-clause-list-eq-in-env env a b)) fuel)]
            [(AstBinNe)
              (OkCtfe
                (CtfeBool (not (ctfe-expr-clause-list-eq-in-env env a b)))
                fuel)]
            [_
              (ErrCtfe
                (ctfe-diagnostic-at-expr
                  expr
                  "this operation is not supported on expr-clause-list in compile-time evaluation"))])]
        [_
          (ErrCtfe
            (ctfe-diagnostic-at-expr
              expr
              "binary operation in comptime requires matching operand types"))])]
    [(CtfeExprBindingClause a)
      (match rv
        [(CtfeExprBindingClause b)
          (match op
            [(AstBinEq)
              (OkCtfe
                (CtfeBool (ctfe-expr-binding-clause-eq-in-env env a b))
                fuel)]
            [(AstBinNe)
              (OkCtfe
                (CtfeBool (not (ctfe-expr-binding-clause-eq-in-env env a b)))
                fuel)]
            [_
              (ErrCtfe
                (ctfe-diagnostic-at-expr
                  expr
                  "this operation is not supported on expr-binding-clause in compile-time evaluation"))])]
        [_
          (ErrCtfe
            (ctfe-diagnostic-at-expr
              expr
              "binary operation in comptime requires matching operand types"))])]
    [(CtfeExprBindingClauseList a)
      (match rv
        [(CtfeExprBindingClauseList b)
          (match op
            [(AstBinEq)
              (OkCtfe
                (CtfeBool (ctfe-expr-binding-clause-list-eq-in-env env a b))
                fuel)]
            [(AstBinNe)
              (OkCtfe
                (CtfeBool
                  (not (ctfe-expr-binding-clause-list-eq-in-env env a b)))
                fuel)]
            [_
              (ErrCtfe
                (ctfe-diagnostic-at-expr
                  expr
                  "this operation is not supported on expr-binding-clause-list in compile-time evaluation"))])]
        [_
          (ErrCtfe
            (ctfe-diagnostic-at-expr
              expr
              "binary operation in comptime requires matching operand types"))])]))

;; --- unary operators --------------------------------------------------------
(define (ctfe-apply-unop
  [op : AstUnOp]
  [v : CompilerCtfeValue]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (match op
    [(AstUnNeg)
      (match v
        [(CtfeI64 n) (OkCtfe (CtfeI64 (- 0 n)) fuel)]
        [(CtfeF64 n) (ctfe-f64-result (- 0.0 n) expr fuel)]
        [(CtfeF32 n) (ctfe-f32-result (- 0.0 n) expr fuel)]
        [_
          (ErrCtfe
            (ctfe-diagnostic-at-expr
              expr
              "negation in comptime requires a numeric type"))])]
    [(AstUnNot)
      (match v
        [(CtfeBool b) (OkCtfe (CtfeBool (not b)) fuel)]
        [_
          (ErrCtfe
            (ctfe-diagnostic-at-expr expr "'not' in comptime requires bool"))])]
    [(AstUnBitNot)
      (match v
        [(CtfeI64 n) (OkCtfe (CtfeI64 (bit-not n)) fuel)]
        [_
          (ErrCtfe
            (ctfe-diagnostic-at-expr
              expr
              "bitwise not in comptime requires i64"))])]))

(define (ctfe-value-default-cast-type [value : CompilerCtfeValue]) : AstType
  (match value
    [(CtfeI64 _) (AstTyI64)]
    [(CtfeF64 _) (AstTyF64)]
    [(CtfeF32 _) (AstTyF32)]
    [(CtfeChar _) (AstTyChar)]
    [_ (AstTyUnit)]))

(define (ctfe-cast-source-type
  [inner : AstExpr]
  [value : CompilerCtfeValue]
  [env : CtfeEnv]) : AstType
  (match inner
    [(AstExprSpanned inner-box _)
      (ctfe-cast-source-type (ctfe-ast-get env inner-box) value env)]
    [(AstExprAnn _ ty) ty]
    [(AstExprCast _ ty) ty]
    [(AstExprVar name)
      (match (ctfe-env-lookup-type env (intern-str name))
        [(AstSomeType ty) ty]
        [(AstNoType) (ctfe-value-default-cast-type value)])]
    [_ (ctfe-value-default-cast-type value)]))

(define (ctfe-binding-type
  [maybe-ty : AstMaybeType]
  [fallback : AstType]
  [env : CtfeEnv]) : AstType
  (match maybe-ty
    [(AstSomeType ty)
      (ctfe-reflect-resolve-type-with-pools
        (ctfe-env-pools env)
        (ctfe-env-reflections env)
        ty)]
    [(AstNoType) fallback]))

(define (ctfe-finite-cast-input [value : CompilerCtfeValue]) : CompilerFiniteCastInput
  (match value
    [(CtfeI64 n) (CompilerFiniteCastInputI64 n)]
    [(CtfeF64 n) (CompilerFiniteCastInputF64 n)]
    [(CtfeF32 n) (CompilerFiniteCastInputF32 n)]
    [(CtfeChar c) (CompilerFiniteCastInputChar c)]
    [_ (CompilerFiniteCastNoInput)]))

(define (ctfe-finite-cast-result
  [result : CompilerFiniteCastResult]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (match result
    [(CompilerFiniteCastResultI64 n) (OkCtfe (CtfeI64 n) fuel)]
    [(CompilerFiniteCastResultChar c) (OkCtfe (CtfeChar c) fuel)]
    [(CompilerFiniteCastResultF64 n) (ctfe-f64-result n expr fuel)]
    [(CompilerFiniteCastResultF32 n) (ctfe-f32-result n expr fuel)]
    [(CompilerFiniteCastNoResult)
      (ErrCtfe (ctfe-diagnostic-at-expr expr "comptime: unsupported cast"))]))

(define (ctfe-apply-cast
  [value : CompilerCtfeValue]
  [from-ty : AstType]
  [ty : AstType]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (match ty
    [(AstTyF64)
      (match value
        [(CtfeF64 n) (ctfe-f64-result n expr fuel)]
        [(CtfeF32 n) (ctfe-f64-result n expr fuel)]
        [_
          (ctfe-finite-cast-result
            (compiler-finite-cast-fold
              (ctfe-finite-cast-input value)
              from-ty
              ty)
            expr
            fuel)])]
    [(AstTyF32)
      (match value
        [(CtfeF64 n) (ctfe-f32-result n expr fuel)]
        [(CtfeF32 n) (ctfe-f32-result n expr fuel)]
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
    [(OkCtfe value next-fuel)
      (ctfe-apply-cast
        value
        (ctfe-cast-source-type inner value env)
        ty
        expr
        next-fuel)]
    [(ErrCtfe diag) (ErrCtfe diag)]))

(defenum ResultCtfeStringLookup
  (OkCtfeStringLookup String)
  (ErrCtfeStringLookup String))

(defenum ResultCtfeTypeLookup
  (OkCtfeTypeLookup AstType)
  (ErrCtfeTypeLookup String))

(defenum ResultCtfeTypeListLookup
  (OkCtfeTypeListLookup AstTypeList)
  (ErrCtfeTypeListLookup String))

(defenum ResultCtfeTypeArg
  (OkCtfeTypeArg AstType i64)
  (ErrCtfeTypeArg CompilerDiagnostic))

(defenum ResultCtfeI64Arg
  (OkCtfeI64Arg i64 i64)
  (ErrCtfeI64Arg CompilerDiagnostic))

(defenum ResultCtfeStringArg
  (OkCtfeStringArg String i64)
  (ErrCtfeStringArg CompilerDiagnostic))

(define (ctfe-reflect-info-canonical-type [info : CtfeReflectInfo]) : AstType
  (match info
    [(CtfeReflectStruct key _ _ _) (AstTyStruct (intern key))]
    [(CtfeReflectEnum key _ _ _) (AstTyEnum (intern key))]))

(define (ctfe-reflect-resolve-type-list-with-pools
  [pools : AstNodePoolContext]
  [infos : CtfeReflectInfoList]
  [types : AstTypeList]) : AstTypeList
  (match types
    [(AstTypeNil) AstTypeNil]
    [(AstTypeCons head rest)
      (let
        [head : AstType (ast-node-pool-context-type-get pools head)]
        [rest : AstTypeList (box-get rest)]
        (ast-type-cons-with-pools
          pools
          (ctfe-reflect-resolve-type-with-pools pools infos head)
          (ctfe-reflect-resolve-type-list-with-pools pools infos rest)))]))

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
    [(AstTyFunc args ret)
      (ast-ty-func-with-pools
        pools
        (ctfe-reflect-resolve-type-list-with-pools pools infos (box-get args))
        (ctfe-reflect-resolve-type-with-pools
          pools
          infos
          (ast-node-pool-context-type-get pools ret)))]
    [(AstTyTuple elems)
      (ast-ty-tuple
        (ctfe-reflect-resolve-type-list-with-pools pools infos (box-get elems)))]
    [(AstTyArray elem len)
      (ast-ty-array-with-pools
        pools
        (ctfe-reflect-resolve-type-with-pools
          pools
          infos
          (ast-node-pool-context-type-get pools elem))
        len)]
    [(AstTyDynArray elem)
      (ast-ty-dyn-array-with-pools
        pools
        (ctfe-reflect-resolve-type-with-pools
          pools
          infos
          (ast-node-pool-context-type-get pools elem)))]
    [(AstTyBox elem)
      (ast-ty-box-with-pools
        pools
        (ctfe-reflect-resolve-type-with-pools
          pools
          infos
          (ast-node-pool-context-type-get pools elem)))]
    [(AstTyPtr elem)
      (ast-ty-ptr-with-pools
        pools
        (ctfe-reflect-resolve-type-with-pools
          pools
          infos
          (ast-node-pool-context-type-get pools elem)))]
    [(AstTyMutPtr elem)
      (ast-ty-mut-ptr-with-pools
        pools
        (ctfe-reflect-resolve-type-with-pools
          pools
          infos
          (ast-node-pool-context-type-get pools elem)))]
    [(AstTyRef region inner)
      (ast-ty-ref-with-pools
        pools
        region
        (ctfe-reflect-resolve-type-with-pools
          pools
          infos
          (ast-node-pool-context-type-get pools inner)))]
    [(AstTyMutRef region inner)
      (ast-ty-mut-ref-with-pools
        pools
        region
        (ctfe-reflect-resolve-type-with-pools
          pools
          infos
          (ast-node-pool-context-type-get pools inner)))]
    [(AstTyRegion region inner)
      (ast-ty-region-with-pools
        pools
        region
        (ctfe-reflect-resolve-type-with-pools
          pools
          infos
          (ast-node-pool-context-type-get pools inner)))]
    [(AstTyStruct name)
      (match (ctfe-reflect-info-lookup infos (intern-str name))
        [(CtfeSomeReflectInfo info) (ctfe-reflect-info-canonical-type info)]
        [(CtfeNoReflectInfo) ty])]
    [(AstTyEnum name)
      (match (ctfe-reflect-info-lookup infos (intern-str name))
        [(CtfeSomeReflectInfo info) (ctfe-reflect-info-canonical-type info)]
        [(CtfeNoReflectInfo) ty])]
    [(AstTyVar name)
      (match (ctfe-reflect-info-lookup infos (intern-str name))
        [(CtfeSomeReflectInfo info) (ctfe-reflect-info-canonical-type info)]
        [(CtfeNoReflectInfo) ty])]
    [_ ty]))

(define (ctfe-reflect-resolve-type [infos : CtfeReflectInfoList] [ty : AstType]) : AstType
  (ctfe-reflect-resolve-type-with-pools
    (ast-node-pool-context-capture-active)
    infos
    ty))

(define (ctfe-int-key [n : i64]) : String
  (if (< n 0)
    (string.string-append "m" (string.int->string (- 0 n)))
    (string.int->string n)))

(define (ctfe-type-list-key-with-pools
  [pools : AstNodePoolContext]
  [infos : CtfeReflectInfoList]
  [types : AstTypeList]) : String
  (match types
    [(AstTypeNil) "nil"]
    [(AstTypeCons head rest)
      (let
        [head : AstType (ast-node-pool-context-type-get pools head)]
        [rest : AstTypeList (box-get rest)]
        (string.string-append
          (ctfe-type-key-with-reflections-and-pools pools infos head)
          (string.string-append
            "_"
            (ctfe-type-list-key-with-pools pools infos rest))))]))

(define (ctfe-type-list-key [infos : CtfeReflectInfoList] [types : AstTypeList]) : String
  (ctfe-type-list-key-with-pools
    (ast-node-pool-context-capture-active)
    infos
    types))

(define (ctfe-lifetime-list-key [lifetimes : AstLifetimeList]) : String
  (match lifetimes
    [(AstLifetimeNil) "nil"]
    [(AstLifetimeCons head rest)
      (let
        [rest : AstLifetimeList (box-get rest)]
        (string.string-append
          head
          (string.string-append "_" (ctfe-lifetime-list-key rest))))]))

(define (ctfe-lifetime-list-eq [a : AstLifetimeList] [b : AstLifetimeList]) : bool
  (match a
    [(AstLifetimeNil)
      (match b
        [(AstLifetimeNil) true]
        [_ false])]
    [(AstLifetimeCons a-head a-rest)
      (let
        [a-rest : AstLifetimeList (box-get a-rest)]
        (match b
          [(AstLifetimeCons b-head b-rest)
            (let
              [b-rest : AstLifetimeList (box-get b-rest)]
              (and
                (string.string-eq a-head b-head)
                (ctfe-lifetime-list-eq a-rest b-rest)))]
          [_ false]))]))

(define (ctfe-type-key-with-reflections-and-pools
  [pools : AstNodePoolContext]
  [infos : CtfeReflectInfoList]
  [ty : AstType]) : String
  (match (ctfe-reflect-resolve-type-with-pools pools infos ty)
    [(AstTyI64) "i64"]
    [(AstTyI32) "i32"]
    [(AstTyI16) "i16"]
    [(AstTyI8) "i8"]
    [(AstTyU64) "u64"]
    [(AstTyU32) "u32"]
    [(AstTyU16) "u16"]
    [(AstTyU8) "u8"]
    [(AstTyF64) "f64"]
    [(AstTyF32) "f32"]
    [(AstTyBool) "bool"]
    [(AstTyChar) "char"]
    [(AstTyString) "String"]
    [(AstTyStr) "str"]
    [(AstTyBytes) "bytes"]
    [(AstTyExpr) "Expr"]
    [(AstTyExprList) "ExprList"]
    [(AstTyUnit) "unit"]
    [(AstTyNever) "never"]
    [(AstTyFunc args ret)
      (string.string-append
        "fn_"
        (string.string-append
          (ctfe-type-list-key-with-pools pools infos (box-get args))
          (string.string-append
            "_to_"
            (ctfe-type-key-with-reflections-and-pools
              pools
              infos
              (ast-node-pool-context-type-get pools ret)))))]
    [(AstTyTuple elems)
      (string.string-append
        "tuple_"
        (ctfe-type-list-key-with-pools pools infos (box-get elems)))]
    [(AstTyArray elem count)
      (string.string-append
        "array_"
        (string.string-append
          (ctfe-type-key-with-reflections-and-pools
            pools
            infos
            (ast-node-pool-context-type-get pools elem))
          (string.string-append "_" (ctfe-int-key count))))]
    [(AstTyDynArray elem)
      (string.string-append
        "dynarray_"
        (ctfe-type-key-with-reflections-and-pools
          pools
          infos
          (ast-node-pool-context-type-get pools elem)))]
    [(AstTyBox elem)
      (string.string-append
        "box_"
        (ctfe-type-key-with-reflections-and-pools
          pools
          infos
          (ast-node-pool-context-type-get pools elem)))]
    [(AstTyPtr elem)
      (string.string-append
        "ptr_"
        (ctfe-type-key-with-reflections-and-pools
          pools
          infos
          (ast-node-pool-context-type-get pools elem)))]
    [(AstTyMutPtr elem)
      (string.string-append
        "mutptr_"
        (ctfe-type-key-with-reflections-and-pools
          pools
          infos
          (ast-node-pool-context-type-get pools elem)))]
    [(AstTyRef region inner)
      (string.string-append
        "ref_"
        (string.string-append
          region
          (string.string-append
            "_"
            (ctfe-type-key-with-reflections-and-pools
              pools
              infos
              (ast-node-pool-context-type-get pools inner)))))]
    [(AstTyMutRef region inner)
      (string.string-append
        "mutref_"
        (string.string-append
          region
          (string.string-append
            "_"
            (ctfe-type-key-with-reflections-and-pools
              pools
              infos
              (ast-node-pool-context-type-get pools inner)))))]
    [(AstTyRegion region inner)
      (string.string-append
        "region_"
        (string.string-append
          region
          (string.string-append
            "_"
            (ctfe-type-key-with-reflections-and-pools
              pools
              infos
              (ast-node-pool-context-type-get pools inner)))))]
    [(AstTyEnum name) (string.string-append "enum_" (intern-str name))]
    [(AstTyEnumArgs name lifetimes)
      (string.string-append
        "enumargs_"
        (string.string-append
          (intern-str name)
          (string.string-append
            "_"
            (ctfe-lifetime-list-key (box-get lifetimes)))))]
    [(AstTyStruct name) (string.string-append "struct_" (intern-str name))]
    [(AstTyStructArgs name lifetimes)
      (string.string-append
        "structargs_"
        (string.string-append
          (intern-str name)
          (string.string-append
            "_"
            (ctfe-lifetime-list-key (box-get lifetimes)))))]
    [(AstTyVar name) (string.string-append "var_" (intern-str name))]
    [(AstTyVarArgs name lifetimes)
      (string.string-append
        "varargs_"
        (string.string-append
          (intern-str name)
          (string.string-append
            "_"
            (ctfe-lifetime-list-key (box-get lifetimes)))))]))

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
    [(AstTyI64) "i64"]
    [(AstTyI32) "i32"]
    [(AstTyI16) "i16"]
    [(AstTyI8) "i8"]
    [(AstTyU64) "u64"]
    [(AstTyU32) "u32"]
    [(AstTyU16) "u16"]
    [(AstTyU8) "u8"]
    [(AstTyF64) "f64"]
    [(AstTyF32) "f32"]
    [(AstTyBool) "bool"]
    [(AstTyChar) "char"]
    [(AstTyString) "string"]
    [(AstTyStr) "str"]
    [(AstTyBytes) "bytes"]
    [(AstTyExpr) "expr"]
    [(AstTyExprList) "expr-list"]
    [(AstTyUnit) "unit"]
    [(AstTyNever) "never"]
    [(AstTyFunc _ _) "function"]
    [(AstTyTuple _) "tuple"]
    [(AstTyArray _ _) "array"]
    [(AstTyDynArray _) "dyn-array"]
    [(AstTyBox _) "box"]
    [(AstTyPtr _) "ptr"]
    [(AstTyMutPtr _) "mut-ptr"]
    [(AstTyRef _ _) "ref"]
    [(AstTyMutRef _ _) "mut-ref"]
    [(AstTyRegion _ _) "region"]
    [(AstTyEnum _) "enum"]
    [(AstTyEnumArgs _ _) "enum"]
    [(AstTyStruct _) "struct"]
    [(AstTyStructArgs _ _) "struct"]
    [(AstTyVar _) "type-var"]
    [(AstTyVarArgs _ _) "type-var"]))

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
    [(ErrCtfe d) (ErrCtfeTypeArg d)]
    [(OkCtfe value arg-fuel)
      (match value
        [(CtfeType ty)
          (OkCtfeTypeArg
            (ctfe-reflect-resolve-type-with-pools
              (ctfe-env-pools env)
              (ctfe-env-reflections env)
              ty)
            arg-fuel)]
        [_
          (ErrCtfeTypeArg
            (ctfe-diagnostic-at-expr
              expr
              (string.string-append name " expects a type argument")))])]))

(define (ctfe-eval-i64-arg
  [arg : AstExpr]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]
  [name : String]) : ResultCtfeI64Arg
  (match (compiler-ctfe-eval arg env fuel)
    [(ErrCtfe d) (ErrCtfeI64Arg d)]
    [(OkCtfe value arg-fuel)
      (match value
        [(CtfeI64 n) (OkCtfeI64Arg n arg-fuel)]
        [_
          (ErrCtfeI64Arg
            (ctfe-diagnostic-at-expr
              expr
              (string.string-append name " expects an i64 index")))])]))

(define (ctfe-eval-string-arg
  [arg : AstExpr]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]
  [name : String]) : ResultCtfeStringArg
  (match (compiler-ctfe-eval arg env fuel)
    [(ErrCtfe d) (ErrCtfeStringArg d)]
    [(OkCtfe value arg-fuel)
      (match value
        [(CtfeString text) (OkCtfeStringArg text arg-fuel)]
        [_
          (ErrCtfeStringArg
            (ctfe-diagnostic-at-expr
              expr
              (string.string-append name " expects a String argument")))])]))

(define (ctfe-reflect-field-list-count [fields : CtfeReflectFieldList]) : i64
  (struct-get fields len))

(define (ctfe-reflect-field-name-at
  [fields : CtfeReflectFieldList]
  [index : i64]) : ResultCtfeStringLookup
  (if (if (< index 0)
    true
    (>= index (struct-get fields len)))
    (ErrCtfeStringLookup "index out of range")
    (match (ctfe-reflect-field-list-ref fields index)
      [(CtfeReflectField name _) (OkCtfeStringLookup name)])))

(define (ctfe-reflect-field-type-at
  [fields : CtfeReflectFieldList]
  [pools : AstNodePoolContext]
  [infos : CtfeReflectInfoList]
  [index : i64]) : ResultCtfeTypeLookup
  (if (if (< index 0)
    true
    (>= index (struct-get fields len)))
    (ErrCtfeTypeLookup "index out of range")
    (match (ctfe-reflect-field-list-ref fields index)
      [(CtfeReflectField _ ty)
        (OkCtfeTypeLookup (ctfe-reflect-resolve-type-with-pools pools infos ty))])))

(define (ctfe-reflect-variant-list-count [variants : CtfeReflectVariantList]) : i64
  (struct-get variants len))

(define (ctfe-reflect-variant-name-at
  [variants : CtfeReflectVariantList]
  [index : i64]) : ResultCtfeStringLookup
  (if (if (< index 0)
    true
    (>= index (struct-get variants len)))
    (ErrCtfeStringLookup "index out of range")
    (match (ctfe-reflect-variant-list-ref variants index)
      [(CtfeReflectVariant name _) (OkCtfeStringLookup name)])))

(define (ctfe-reflect-variant-payloads-at
  [variants : CtfeReflectVariantList]
  [index : i64]) : ResultCtfeTypeListLookup
  (if (if (< index 0)
    true
    (>= index (struct-get variants len)))
    (ErrCtfeTypeListLookup "index out of range")
    (match (ctfe-reflect-variant-list-ref variants index)
      [(CtfeReflectVariant _ payloads) (OkCtfeTypeListLookup payloads)])))

(define (ctfe-type-list-count [types : AstTypeList]) : i64
  (match types
    [(AstTypeNil) 0]
    [(AstTypeCons _ rest)
      (let
        [rest : AstTypeList (box-get rest)]
        (+ 1 (ctfe-type-list-count rest)))]))

(define (ctfe-type-list-ref-with-pools
  [types : AstTypeList]
  [pools : AstNodePoolContext]
  [infos : CtfeReflectInfoList]
  [index : i64]) : ResultCtfeTypeLookup
  (if (< index 0)
    (ErrCtfeTypeLookup "index out of range")
    (match types
      [(AstTypeNil) (ErrCtfeTypeLookup "index out of range")]
      [(AstTypeCons head rest)
        (let
          [head : AstType (ast-node-pool-context-type-get pools head)]
          [rest : AstTypeList (box-get rest)]
          (if (= index 0)
            (OkCtfeTypeLookup
              (ctfe-reflect-resolve-type-with-pools pools infos head))
            (ctfe-type-list-ref-with-pools rest pools infos (- index 1))))])))

(define (ctfe-type-list-ref
  [types : AstTypeList]
  [infos : CtfeReflectInfoList]
  [index : i64]) : ResultCtfeTypeLookup
  (ctfe-type-list-ref-with-pools
    types
    (ast-node-pool-context-capture-active)
    infos
    index))

;; --- core evaluator ---------------------------------------------------------
;; Evaluate `expr` under `env` with the given remaining `fuel`. Each call
;; charges one unit of fuel up front (mirroring `use_fuel`); when fuel is
;; exhausted the evaluation fails deterministically.
(define (compiler-ctfe-eval [expr : AstExpr] [env : CtfeEnv] [fuel : i64]) : ResultCtfe
  (if (<= fuel 0)
    (ErrCtfe
      (ctfe-diagnostic-at-expr expr "compile-time evaluation limit exceeded"))
    (ctfe-eval-node expr env (- fuel 1))))

(define (ctfe-eval-node [expr : AstExpr] [env : CtfeEnv] [fuel : i64]) : ResultCtfe
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (compiler-ctfe-eval inner env fuel))]
    [(AstExprComptime inner-box)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (compiler-ctfe-eval inner env fuel))]
    [(AstExprAnn inner-box _)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (compiler-ctfe-eval inner env fuel))]
    [(AstExprCast inner-box ty)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (ctfe-eval-cast inner ty expr env fuel))]
    [(AstExprTypeLiteral ty)
      (OkCtfe
        (CtfeType
          (ctfe-reflect-resolve-type-with-pools
            (ctfe-env-pools env)
            (ctfe-env-reflections env)
            ty))
        fuel)]
    [(AstExprInit _)
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          "comptime: init is a runtime-only expression"))]
    [(AstExprLiteral lit) (ctfe-eval-literal lit expr fuel)]
    [(AstExprVar name) (ctfe-eval-var (intern-str name) expr env fuel)]
    [(AstExprBinary op left-box right-box)
      (let
        [left : AstExpr (ctfe-ast-get env left-box)]
        [right : AstExpr (ctfe-ast-get env right-box)]
        (ctfe-eval-binary op left right expr env fuel))]
    [(AstExprUnary op inner-box)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (ctfe-eval-unary op inner expr env fuel))]
    [(AstExprIf cond-box then-branch-box else-branch-box)
      (let
        [cond : AstExpr (ctfe-ast-get env cond-box)]
        [then-branch : AstExpr (ctfe-ast-get env then-branch-box)]
        [else-branch : AstExpr (ctfe-ast-get env else-branch-box)]
        (ctfe-eval-if cond then-branch else-branch env fuel))]
    [(AstExprLet let-box)
      (match (box-get let-box)
        [(AstLet bindings body-box)
          (let
            [body : AstExpr (ctfe-ast-get env body-box)]
            (ctfe-eval-let bindings body env fuel))])]
    [(AstExprBegin exprs) (ctfe-eval-begin exprs env fuel)]
    [(AstExprUnsafe exprs) (ctfe-eval-begin exprs env fuel)]
    [(AstExprMatch match-box)
      (match (box-get match-box)
        [(AstMatch scrutinee-box arms)
          (let
            [scrutinee : AstExpr (ctfe-ast-get env scrutinee-box)]
            (ctfe-eval-match scrutinee arms expr env fuel))])]
    [(AstExprCall func-box args)
      (let
        [func : AstExpr (ctfe-ast-get env func-box)]
        (ctfe-eval-call func args expr env fuel))]
    [(AstExprQuote template-box)
      (let
        [template : AstExpr (ctfe-ast-get env template-box)]
        (ctfe-eval-quote template env fuel false))]
    [(AstExprQuasiquote template-box)
      (let
        [template : AstExpr (ctfe-ast-get env template-box)]
        (ctfe-eval-quote template env fuel true))]
    [(AstExprUnquote _)
      (ErrCtfe
        (ctfe-diagnostic-at-expr expr "unquote is only valid inside quasiquote"))]
    [(AstExprUnquoteSplicing _)
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          "unquote-splicing is only valid inside quasiquote"))]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          (string.string-append
            "'"
            (string.string-append
              (ctfe-describe-expr expr)
              "' is not supported in compile-time evaluation"))))]))

;; Type size / alignment in bytes for CTFE layout queries. Builtins mirror the
;; lowerer ABI; user-defined names come from the layout table carried in `env`.
;; Unresolved type variables without a table entry return -1 so callers can
;; produce a source-located diagnostic instead of inventing runtime metadata.
(define (ctfe-type-size-with-pools
  [pools : AstNodePoolContext]
  [layouts : CtfeLayoutInfoList]
  [ty : AstType]) : i64
  (match ty
    [(AstTyI64) 8]
    [(AstTyU64) 8]
    [(AstTyF64) 8]
    [(AstTyI32) 4]
    [(AstTyU32) 4]
    [(AstTyF32) 4]
    [(AstTyI16) 2]
    [(AstTyU16) 2]
    [(AstTyI8) 1]
    [(AstTyU8) 1]
    [(AstTyBool) 1]
    [(AstTyChar) 1]
    [(AstTyUnit) 0]
    [(AstTyNever) 0]
    [(AstTyStr) -1]
    [(AstTyBytes) -1]
    [(AstTyExpr) -1]
    [(AstTyExprList) -1]
    [(AstTyFunc _ _) 8]
    [(AstTyTuple _) 8]
    [(AstTyArray elem count)
      (let
        [elem-size : i64
          (ctfe-type-size-with-pools
            pools
            layouts
            (ast-node-pool-context-type-get pools elem))]
        (if (< elem-size 0)
          -1
          (* elem-size count)))]
    [(AstTyDynArray _) 8]
    [(AstTyBox _) 8]
    [(AstTyPtr _) 8]
    [(AstTyMutPtr _) 8]
    [(AstTyRef _ _) 8]
    [(AstTyMutRef _ _) 8]
    [(AstTyRegion _ inner)
      (ctfe-type-size-with-pools
        pools
        layouts
        (ast-node-pool-context-type-get pools inner))]
    [(AstTyEnum _) 8]
    [(AstTyEnumArgs _ _) 8]
    [(AstTyStruct name)
      (match (ctfe-layout-info-lookup layouts (intern-str name))
        [(CtfeSomeLayoutInfo info)
          (match info
            [(CtfeLayoutInfo _ _ size _ _) size])]
        [(CtfeNoLayoutInfo) 8])]
    [(AstTyStructArgs name _)
      (match (ctfe-layout-info-lookup layouts (intern-str name))
        [(CtfeSomeLayoutInfo info)
          (match info
            [(CtfeLayoutInfo _ _ size _ _) size])]
        [(CtfeNoLayoutInfo) 8])]
    [(AstTyString) 8]
    [(AstTyVar name)
      (match (ctfe-layout-info-lookup layouts (intern-str name))
        [(CtfeSomeLayoutInfo info)
          (match info
            [(CtfeLayoutInfo _ _ size _ _) size])]
        [(CtfeNoLayoutInfo) -1])]
    [(AstTyVarArgs name _)
      (match (ctfe-layout-info-lookup layouts (intern-str name))
        [(CtfeSomeLayoutInfo info)
          (match info
            [(CtfeLayoutInfo _ _ size _ _) size])]
        [(CtfeNoLayoutInfo) -1])]))

(define (ctfe-type-size [layouts : CtfeLayoutInfoList] [ty : AstType]) : i64
  (ctfe-type-size-with-pools (ast-node-pool-context-capture-active) layouts ty))

(define (ctfe-type-align-with-pools
  [pools : AstNodePoolContext]
  [layouts : CtfeLayoutInfoList]
  [ty : AstType]) : i64
  (match ty
    [(AstTyI64) 8]
    [(AstTyU64) 8]
    [(AstTyF64) 8]
    [(AstTyI32) 4]
    [(AstTyU32) 4]
    [(AstTyF32) 4]
    [(AstTyI16) 2]
    [(AstTyU16) 2]
    [(AstTyI8) 1]
    [(AstTyU8) 1]
    [(AstTyBool) 1]
    [(AstTyChar) 1]
    [(AstTyUnit) 1]
    [(AstTyNever) 1]
    [(AstTyStr) -1]
    [(AstTyBytes) -1]
    [(AstTyExpr) -1]
    [(AstTyExprList) -1]
    [(AstTyFunc _ _) 8]
    [(AstTyTuple _) 8]
    [(AstTyArray elem _)
      (ctfe-type-align-with-pools
        pools
        layouts
        (ast-node-pool-context-type-get pools elem))]
    [(AstTyDynArray _) 8]
    [(AstTyBox _) 8]
    [(AstTyPtr _) 8]
    [(AstTyMutPtr _) 8]
    [(AstTyRef _ _) 8]
    [(AstTyMutRef _ _) 8]
    [(AstTyRegion _ inner)
      (ctfe-type-align-with-pools
        pools
        layouts
        (ast-node-pool-context-type-get pools inner))]
    [(AstTyEnum _) 8]
    [(AstTyEnumArgs _ _) 8]
    [(AstTyStruct name)
      (match (ctfe-layout-info-lookup layouts (intern-str name))
        [(CtfeSomeLayoutInfo info)
          (match info
            [(CtfeLayoutInfo _ _ _ align _) align])]
        [(CtfeNoLayoutInfo) 8])]
    [(AstTyStructArgs name _)
      (match (ctfe-layout-info-lookup layouts (intern-str name))
        [(CtfeSomeLayoutInfo info)
          (match info
            [(CtfeLayoutInfo _ _ _ align _) align])]
        [(CtfeNoLayoutInfo) 8])]
    [(AstTyString) 8]
    [(AstTyVar name)
      (match (ctfe-layout-info-lookup layouts (intern-str name))
        [(CtfeSomeLayoutInfo info)
          (match info
            [(CtfeLayoutInfo _ _ _ align _) align])]
        [(CtfeNoLayoutInfo) -1])]
    [(AstTyVarArgs name _)
      (match (ctfe-layout-info-lookup layouts (intern-str name))
        [(CtfeSomeLayoutInfo info)
          (match info
            [(CtfeLayoutInfo _ _ _ align _) align])]
        [(CtfeNoLayoutInfo) -1])]))

(define (ctfe-type-align [layouts : CtfeLayoutInfoList] [ty : AstType]) : i64
  (ctfe-type-align-with-pools (ast-node-pool-context-capture-active) layouts ty))

(define (ctfe-layout-query-value-with-pools
  [pools : AstNodePoolContext]
  [name : String]
  [layouts : CtfeLayoutInfoList]
  [ty : AstType]) : i64
  (if (string.string-eq name "size-of")
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
  (match args
    [(AstExprCons arg rest)
      (let
        [arg : AstExpr (ctfe-ast-get env arg)]
        [rest : AstExprList (box-get rest)]
        (match rest
          [(AstExprNil)
            (match (compiler-ctfe-eval arg env fuel)
              [(ErrCtfe d) (ErrCtfe d)]
              [(OkCtfe value arg-fuel)
                (match value
                  [(CtfeType ty)
                    (let
                      [answer : i64
                        (ctfe-layout-query-value-with-pools
                          (ctfe-env-pools env)
                          name
                          (ctfe-env-layouts env)
                          ty)]
                      (if (< answer 0)
                        (ErrCtfe
                          (ctfe-diagnostic-at-expr
                            expr
                            (string.string-append
                              name
                              " expects a known type argument")))
                        (OkCtfe (CtfeI64 answer) arg-fuel)))]
                  [_
                    (ErrCtfe
                      (ctfe-diagnostic-at-expr
                        expr
                        (string.string-append name " expects a type argument")))])])]
          [_
            (ErrCtfe
              (ctfe-diagnostic-at-expr
                expr
                (string.string-append name " expects exactly one type argument")))]))]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          (string.string-append name " expects exactly one type argument")))]))

(define (ctfe-offset-field-name [expr : AstExpr] [env : CtfeEnv]) : CtfeMaybeFieldName
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (ctfe-offset-field-name inner env))]
    [(AstExprVar name) (CtfeSomeFieldName (intern-str name))]
    [_ (CtfeNoFieldName)]))

(define (ctfe-layout-info-for-type-with-pools
  [pools : AstNodePoolContext]
  [layouts : CtfeLayoutInfoList]
  [ty : AstType]) : CtfeMaybeLayoutInfo
  (match ty
    [(AstTyStruct name) (ctfe-layout-info-lookup layouts (intern-str name))]
    [(AstTyStructArgs name _)
      (ctfe-layout-info-lookup layouts (intern-str name))]
    [(AstTyEnum name) (ctfe-layout-info-lookup layouts (intern-str name))]
    [(AstTyEnumArgs name _) (ctfe-layout-info-lookup layouts (intern-str name))]
    [(AstTyVar name) (ctfe-layout-info-lookup layouts (intern-str name))]
    [(AstTyRegion _ inner)
      (ctfe-layout-info-for-type-with-pools
        pools
        layouts
        (ast-node-pool-context-type-get pools inner))]
    [_ (CtfeNoLayoutInfo)]))

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
    [(CtfeLayoutInfo _ repr-c? _ _ fields)
      (if repr-c?
        (let
          [offset : i64 (ctfe-layout-field-offset fields field-name)]
          (if (< offset 0)
            (ErrCtfe
              (ctfe-diagnostic-at-expr
                expr
                (string.string-append "offset-of unknown field " field-name)))
            (OkCtfe (CtfeI64 offset) fuel)))
        (ErrCtfe
          (ctfe-diagnostic-at-expr expr "offset-of requires struct layout type")))]))

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
    [(CtfeSomeLayoutInfo info)
      (ctfe-eval-offset-from-layout field-name info expr fuel)]
    [(CtfeNoLayoutInfo)
      (ErrCtfe
        (ctfe-diagnostic-at-expr expr "offset-of requires struct layout type"))]))

(define (ctfe-eval-offset-value
  [value : CompilerCtfeValue]
  [field-arg : AstExpr]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match value
    [(CtfeType ty)
      (match (ctfe-offset-field-name field-arg env)
        [(CtfeSomeFieldName field-name)
          (ctfe-eval-offset-from-type ty field-name expr env fuel)]
        [(CtfeNoFieldName)
          (ErrCtfe
            (ctfe-diagnostic-at-expr expr "offset-of expects a field name"))])]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr expr "offset-of expects a type argument"))]))

(define (ctfe-eval-offset-query
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons type-arg tail)
      (let
        [type-arg : AstExpr (ctfe-ast-get env type-arg)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprCons field-arg rest)
            (let
              [field-arg : AstExpr (ctfe-ast-get env field-arg)]
              [rest : AstExprList (box-get rest)]
              (match rest
                [(AstExprNil)
                  (match (compiler-ctfe-eval type-arg env fuel)
                    [(ErrCtfe d) (ErrCtfe d)]
                    [(OkCtfe value arg-fuel)
                      (ctfe-eval-offset-value value field-arg expr env arg-fuel)])]
                [_
                  (ErrCtfe
                    (ctfe-diagnostic-at-expr
                      expr
                      "offset-of expects exactly one type argument and one field name"))]))]
          [_
            (ErrCtfe
              (ctfe-diagnostic-at-expr
                expr
                "offset-of expects exactly one type argument and one field name"))]))]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          "offset-of expects exactly one type argument and one field name"))]))

(define (ctfe-reflection-query-name? [name : String]) : bool
  (cond
    [(string.string-eq name "type-kind") true]
    [(string.string-eq name "type-key") true]
    [(string.string-eq name "type-nominal-module") true]
    [(string.string-eq name "type-nominal-name") true]
    [(string.string-eq name "struct-field-count") true]
    [(string.string-eq name "struct-field-name") true]
    [(string.string-eq name "struct-field-type") true]
    [(string.string-eq name "enum-variant-count") true]
    [(string.string-eq name "enum-variant-name") true]
    [(string.string-eq name "enum-variant-payload-count") true]
    [(string.string-eq name "enum-variant-payload-type") true]
    [(string.string-eq name "array-element-type") true]
    [(string.string-eq name "array-length") true]
    [(string.string-eq name "array-dynamic?") true]
    [(string.string-eq name "function-param-count") true]
    [(string.string-eq name "function-param-type") true]
    [else (string.string-eq name "function-return-type")]))

(define (ctfe-eval-one-type-reflection
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons type-arg rest)
      (let
        [type-arg : AstExpr (ctfe-ast-get env type-arg)]
        [rest : AstExprList (box-get rest)]
        (match rest
          [(AstExprNil)
            (match (ctfe-eval-type-arg type-arg expr env fuel name)
              [(ErrCtfeTypeArg d) (ErrCtfe d)]
              [(OkCtfeTypeArg ty arg-fuel)
                (let
                  [infos : CtfeReflectInfoList (ctfe-env-reflections env)]
                  (cond
                    [(string.string-eq name "type-kind")
                      (OkCtfe
                        (CtfeString
                          (ctfe-type-kind-with-reflections-and-pools
                            (ctfe-env-pools env)
                            infos
                            ty))
                        arg-fuel)]
                    [(string.string-eq name "type-key")
                      (OkCtfe
                        (CtfeString
                          (ctfe-type-key-with-reflections-and-pools
                            (ctfe-env-pools env)
                            infos
                            ty))
                        arg-fuel)]
                    [(string.string-eq name "type-nominal-module")
                      (match (ctfe-reflect-info-lookup
                        infos
                        (ctfe-type-nominal-key ty))
                        [(CtfeSomeReflectInfo info)
                          (match info
                            [(CtfeReflectStruct _ module _ _)
                              (OkCtfe (CtfeString module) arg-fuel)]
                            [(CtfeReflectEnum _ module _ _)
                              (OkCtfe (CtfeString module) arg-fuel)])]
                        [(CtfeNoReflectInfo)
                          (ErrCtfe
                            (ctfe-diagnostic-at-expr
                              expr
                              "type-nominal-module requires struct or enum type"))])]
                    [(string.string-eq name "type-nominal-name")
                      (match (ctfe-reflect-info-lookup
                        infos
                        (ctfe-type-nominal-key ty))
                        [(CtfeSomeReflectInfo info)
                          (match info
                            [(CtfeReflectStruct _ _ nominal-name _)
                              (OkCtfe (CtfeString nominal-name) arg-fuel)]
                            [(CtfeReflectEnum _ _ nominal-name _)
                              (OkCtfe (CtfeString nominal-name) arg-fuel)])]
                        [(CtfeNoReflectInfo)
                          (ErrCtfe
                            (ctfe-diagnostic-at-expr
                              expr
                              "type-nominal-name requires struct or enum type"))])]
                    [(string.string-eq name "struct-field-count")
                      (match (ctfe-reflect-info-lookup
                        infos
                        (ctfe-type-nominal-key ty))
                        [(CtfeSomeReflectInfo info)
                          (match info
                            [(CtfeReflectStruct _ _ _ fields)
                              (OkCtfe
                                (CtfeI64 (ctfe-reflect-field-list-count fields))
                                arg-fuel)]
                            [_
                              (ErrCtfe
                                (ctfe-diagnostic-at-expr
                                  expr
                                  "struct-field-count requires struct type"))])]
                        [(CtfeNoReflectInfo)
                          (ErrCtfe
                            (ctfe-diagnostic-at-expr
                              expr
                              "struct-field-count requires struct type"))])]
                    [(string.string-eq name "enum-variant-count")
                      (match (ctfe-reflect-info-lookup
                        infos
                        (ctfe-type-nominal-key ty))
                        [(CtfeSomeReflectInfo info)
                          (match info
                            [(CtfeReflectEnum _ _ _ variants)
                              (OkCtfe
                                (CtfeI64
                                  (ctfe-reflect-variant-list-count variants))
                                arg-fuel)]
                            [_
                              (ErrCtfe
                                (ctfe-diagnostic-at-expr
                                  expr
                                  "enum-variant-count requires enum type"))])]
                        [(CtfeNoReflectInfo)
                          (ErrCtfe
                            (ctfe-diagnostic-at-expr
                              expr
                              "enum-variant-count requires enum type"))])]
                    [(string.string-eq name "array-element-type")
                      (match ty
                        [(AstTyArray elem _)
                          (OkCtfe (CtfeType (ctfe-ty-get env elem)) arg-fuel)]
                        [(AstTyDynArray elem)
                          (OkCtfe (CtfeType (ctfe-ty-get env elem)) arg-fuel)]
                        [_
                          (ErrCtfe
                            (ctfe-diagnostic-at-expr
                              expr
                              "array-element-type requires array type"))])]
                    [(string.string-eq name "array-length")
                      (match ty
                        [(AstTyArray _ count) (OkCtfe (CtfeI64 count) arg-fuel)]
                        [_
                          (ErrCtfe
                            (ctfe-diagnostic-at-expr
                              expr
                              "array-length requires fixed array type"))])]
                    [(string.string-eq name "array-dynamic?")
                      (match ty
                        [(AstTyArray _ _) (OkCtfe (CtfeBool false) arg-fuel)]
                        [(AstTyDynArray _) (OkCtfe (CtfeBool true) arg-fuel)]
                        [_
                          (ErrCtfe
                            (ctfe-diagnostic-at-expr
                              expr
                              "array-dynamic? requires array type"))])]
                    [(string.string-eq name "function-param-count")
                      (match ty
                        [(AstTyFunc params _)
                          (OkCtfe
                            (CtfeI64 (ctfe-type-list-count (box-get params)))
                            arg-fuel)]
                        [_
                          (ErrCtfe
                            (ctfe-diagnostic-at-expr
                              expr
                              "function-param-count requires function type"))])]
                    [(string.string-eq name "function-return-type")
                      (match ty
                        [(AstTyFunc _ ret)
                          (OkCtfe (CtfeType (ctfe-ty-get env ret)) arg-fuel)]
                        [_
                          (ErrCtfe
                            (ctfe-diagnostic-at-expr
                              expr
                              "function-return-type requires function type"))])]
                    [else (ctfe-unsupported-form expr)]))])]
          [_
            (ErrCtfe
              (ctfe-diagnostic-at-expr
                expr
                (string.string-append name " expects exactly one type argument")))]))]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          (string.string-append name " expects exactly one type argument")))]))

(define (ctfe-type-nominal-key [ty : AstType]) : String
  (match ty
    [(AstTyStruct name) (intern-str name)]
    [(AstTyStructArgs name _) (intern-str name)]
    [(AstTyEnum name) (intern-str name)]
    [(AstTyEnumArgs name _) (intern-str name)]
    [(AstTyVar name) (intern-str name)]
    [(AstTyVarArgs name _) (intern-str name)]
    [_ ""]))

(define (ctfe-struct-field-arity-error [name : String] [expr : AstExpr]) : ResultCtfe
  (ErrCtfe
    (ctfe-diagnostic-at-expr
      expr
      (string.string-append
        name
        " expects exactly one type argument and one index"))))

(define (ctfe-struct-field-kind-error [name : String] [expr : AstExpr]) : ResultCtfe
  (ErrCtfe
    (ctfe-diagnostic-at-expr
      expr
      (string.string-append name " requires struct type"))))

(define (ctfe-eval-struct-field-from-fields
  [name : String]
  [fields : CtfeReflectFieldList]
  [pools : AstNodePoolContext]
  [infos : CtfeReflectInfoList]
  [index : i64]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (if (string.string-eq name "struct-field-name")
    (match (ctfe-reflect-field-name-at fields index)
      [(OkCtfeStringLookup field-name) (OkCtfe (CtfeString field-name) fuel)]
      [(ErrCtfeStringLookup message)
        (ErrCtfe
          (ctfe-diagnostic-at-expr
            expr
            (string.string-append name (string.string-append " " message))))])
    (match (ctfe-reflect-field-type-at fields pools infos index)
      [(OkCtfeTypeLookup field-ty) (OkCtfe (CtfeType field-ty) fuel)]
      [(ErrCtfeTypeLookup message)
        (ErrCtfe
          (ctfe-diagnostic-at-expr
            expr
            (string.string-append name (string.string-append " " message))))])))

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
      [(CtfeSomeReflectInfo info)
        (match info
          [(CtfeReflectStruct _ _ _ fields)
            (ctfe-eval-struct-field-from-fields
              name
              fields
              (ctfe-env-pools env)
              infos
              index
              expr
              fuel)]
          [_ (ctfe-struct-field-kind-error name expr)])]
      [(CtfeNoReflectInfo) (ctfe-struct-field-kind-error name expr)])))

(define (ctfe-eval-struct-field-reflection
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons type-arg tail)
      (let
        [type-arg : AstExpr (ctfe-ast-get env type-arg)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprCons index-arg rest)
            (let
              [index-arg : AstExpr (ctfe-ast-get env index-arg)]
              [rest : AstExprList (box-get rest)]
              (match rest
                [(AstExprNil)
                  (match (ctfe-eval-type-arg type-arg expr env fuel name)
                    [(ErrCtfeTypeArg d) (ErrCtfe d)]
                    [(OkCtfeTypeArg ty type-fuel)
                      (match (ctfe-eval-i64-arg
                        index-arg
                        expr
                        env
                        type-fuel
                        name)
                        [(ErrCtfeI64Arg d) (ErrCtfe d)]
                        [(OkCtfeI64Arg index index-fuel)
                          (ctfe-eval-struct-field-from-type
                            name
                            ty
                            index
                            expr
                            env
                            index-fuel)])])]
                [_ (ctfe-struct-field-arity-error name expr)]))]
          [_ (ctfe-struct-field-arity-error name expr)]))]
    [_ (ctfe-struct-field-arity-error name expr)]))

(define (ctfe-enum-variant-arity-error [name : String] [expr : AstExpr]) : ResultCtfe
  (ErrCtfe
    (ctfe-diagnostic-at-expr
      expr
      (string.string-append
        name
        " expects exactly one type argument and one index"))))

(define (ctfe-enum-variant-kind-error [name : String] [expr : AstExpr]) : ResultCtfe
  (ErrCtfe
    (ctfe-diagnostic-at-expr
      expr
      (string.string-append name " requires enum type"))))

(define (ctfe-eval-enum-variant-from-variants
  [name : String]
  [variants : CtfeReflectVariantList]
  [index : i64]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (if (string.string-eq name "enum-variant-name")
    (match (ctfe-reflect-variant-name-at variants index)
      [(OkCtfeStringLookup variant-name)
        (OkCtfe (CtfeString variant-name) fuel)]
      [(ErrCtfeStringLookup message)
        (ErrCtfe
          (ctfe-diagnostic-at-expr
            expr
            (string.string-append name (string.string-append " " message))))])
    (match (ctfe-reflect-variant-payloads-at variants index)
      [(OkCtfeTypeListLookup payloads)
        (OkCtfe (CtfeI64 (ctfe-type-list-count payloads)) fuel)]
      [(ErrCtfeTypeListLookup message)
        (ErrCtfe
          (ctfe-diagnostic-at-expr
            expr
            (string.string-append name (string.string-append " " message))))])))

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
      [(CtfeSomeReflectInfo info)
        (match info
          [(CtfeReflectEnum _ _ _ variants)
            (ctfe-eval-enum-variant-from-variants name variants index expr fuel)]
          [_ (ctfe-enum-variant-kind-error name expr)])]
      [(CtfeNoReflectInfo) (ctfe-enum-variant-kind-error name expr)])))

(define (ctfe-eval-enum-variant-reflection
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons type-arg tail)
      (let
        [type-arg : AstExpr (ctfe-ast-get env type-arg)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprCons index-arg rest)
            (let
              [index-arg : AstExpr (ctfe-ast-get env index-arg)]
              [rest : AstExprList (box-get rest)]
              (match rest
                [(AstExprNil)
                  (match (ctfe-eval-type-arg type-arg expr env fuel name)
                    [(ErrCtfeTypeArg d) (ErrCtfe d)]
                    [(OkCtfeTypeArg ty type-fuel)
                      (match (ctfe-eval-i64-arg
                        index-arg
                        expr
                        env
                        type-fuel
                        name)
                        [(ErrCtfeI64Arg d) (ErrCtfe d)]
                        [(OkCtfeI64Arg index index-fuel)
                          (ctfe-eval-enum-variant-from-type
                            name
                            ty
                            index
                            expr
                            env
                            index-fuel)])])]
                [_ (ctfe-enum-variant-arity-error name expr)]))]
          [_ (ctfe-enum-variant-arity-error name expr)]))]
    [_ (ctfe-enum-variant-arity-error name expr)]))

(define (ctfe-enum-payload-type-arity-error [expr : AstExpr]) : ResultCtfe
  (ErrCtfe
    (ctfe-diagnostic-at-expr
      expr
      "enum-variant-payload-type expects exactly one type argument, one variant index, and one payload index")))

(define (ctfe-enum-payload-type-kind-error [expr : AstExpr]) : ResultCtfe
  (ErrCtfe
    (ctfe-diagnostic-at-expr
      expr
      "enum-variant-payload-type requires enum type")))

(define (ctfe-eval-enum-payload-type-from-variants
  [variants : CtfeReflectVariantList]
  [pools : AstNodePoolContext]
  [infos : CtfeReflectInfoList]
  [variant-index : i64]
  [payload-index : i64]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (match (ctfe-reflect-variant-payloads-at variants variant-index)
    [(OkCtfeTypeListLookup payloads)
      (match (ctfe-type-list-ref-with-pools payloads pools infos payload-index)
        [(OkCtfeTypeLookup payload-ty) (OkCtfe (CtfeType payload-ty) fuel)]
        [(ErrCtfeTypeLookup message)
          (ErrCtfe
            (ctfe-diagnostic-at-expr
              expr
              (string.string-append "enum-variant-payload-type " message)))])]
    [(ErrCtfeTypeListLookup message)
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          (string.string-append "enum-variant-payload-type " message)))]))

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
      [(CtfeSomeReflectInfo info)
        (match info
          [(CtfeReflectEnum _ _ _ variants)
            (ctfe-eval-enum-payload-type-from-variants
              variants
              (ctfe-env-pools env)
              infos
              variant-index
              payload-index
              expr
              fuel)]
          [_ (ctfe-enum-payload-type-kind-error expr)])]
      [(CtfeNoReflectInfo) (ctfe-enum-payload-type-kind-error expr)])))

(define (ctfe-eval-enum-payload-type-reflection
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons type-arg tail)
      (let
        [type-arg : AstExpr (ctfe-ast-get env type-arg)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprCons variant-arg rest1)
            (let
              [variant-arg : AstExpr (ctfe-ast-get env variant-arg)]
              [rest1 : AstExprList (box-get rest1)]
              (match rest1
                [(AstExprCons payload-arg rest2)
                  (let
                    [payload-arg : AstExpr (ctfe-ast-get env payload-arg)]
                    [rest2 : AstExprList (box-get rest2)]
                    (match rest2
                      [(AstExprNil)
                        (match (ctfe-eval-type-arg
                          type-arg
                          expr
                          env
                          fuel
                          "enum-variant-payload-type")
                          [(ErrCtfeTypeArg d) (ErrCtfe d)]
                          [(OkCtfeTypeArg ty type-fuel)
                            (match (ctfe-eval-i64-arg
                              variant-arg
                              expr
                              env
                              type-fuel
                              "enum-variant-payload-type")
                              [(ErrCtfeI64Arg d) (ErrCtfe d)]
                              [(OkCtfeI64Arg variant-index variant-fuel)
                                (match (ctfe-eval-i64-arg
                                  payload-arg
                                  expr
                                  env
                                  variant-fuel
                                  "enum-variant-payload-type")
                                  [(ErrCtfeI64Arg d) (ErrCtfe d)]
                                  [(OkCtfeI64Arg payload-index payload-fuel)
                                    (ctfe-eval-enum-payload-type-from-type
                                      ty
                                      variant-index
                                      payload-index
                                      expr
                                      env
                                      payload-fuel)])])])]
                      [_ (ctfe-enum-payload-type-arity-error expr)]))]
                [_ (ctfe-enum-payload-type-arity-error expr)]))]
          [_ (ctfe-enum-payload-type-arity-error expr)]))]
    [_ (ctfe-enum-payload-type-arity-error expr)]))

(define (ctfe-eval-function-param-type-reflection
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons type-arg tail)
      (let
        [type-arg : AstExpr (ctfe-ast-get env type-arg)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprCons index-arg rest)
            (let
              [index-arg : AstExpr (ctfe-ast-get env index-arg)]
              [rest : AstExprList (box-get rest)]
              (match rest
                [(AstExprNil)
                  (match (ctfe-eval-type-arg
                    type-arg
                    expr
                    env
                    fuel
                    "function-param-type")
                    [(ErrCtfeTypeArg d) (ErrCtfe d)]
                    [(OkCtfeTypeArg ty type-fuel)
                      (match (ctfe-eval-i64-arg
                        index-arg
                        expr
                        env
                        type-fuel
                        "function-param-type")
                        [(ErrCtfeI64Arg d) (ErrCtfe d)]
                        [(OkCtfeI64Arg index index-fuel)
                          (match ty
                            [(AstTyFunc params _)
                              (match (ctfe-type-list-ref-with-pools
                                (box-get params)
                                (ctfe-env-pools env)
                                (ctfe-env-reflections env)
                                index)
                                [(OkCtfeTypeLookup param-ty)
                                  (OkCtfe (CtfeType param-ty) index-fuel)]
                                [(ErrCtfeTypeLookup message)
                                  (ErrCtfe
                                    (ctfe-diagnostic-at-expr
                                      expr
                                      (string.string-append
                                        "function-param-type "
                                        message)))])]
                            [_
                              (ErrCtfe
                                (ctfe-diagnostic-at-expr
                                  expr
                                  "function-param-type requires function type"))])])])]
                [_
                  (ErrCtfe
                    (ctfe-diagnostic-at-expr
                      expr
                      "function-param-type expects exactly one type argument and one index"))]))]
          [_
            (ErrCtfe
              (ctfe-diagnostic-at-expr
                expr
                "function-param-type expects exactly one type argument and one index"))]))]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          "function-param-type expects exactly one type argument and one index"))]))

(define (ctfe-eval-reflection-query
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (cond
    [(or
        (string.string-eq name "type-kind")
        (string.string-eq name "type-key")
        (string.string-eq name "type-nominal-module")
        (string.string-eq name "type-nominal-name")
        (string.string-eq name "struct-field-count")
        (string.string-eq name "enum-variant-count")
        (string.string-eq name "array-element-type")
        (string.string-eq name "array-length")
        (string.string-eq name "array-dynamic?")
        (string.string-eq name "function-param-count")
        (string.string-eq name "function-return-type"))
      (ctfe-eval-one-type-reflection name args expr env fuel)]
    [(or
        (string.string-eq name "struct-field-name")
        (string.string-eq name "struct-field-type"))
      (ctfe-eval-struct-field-reflection name args expr env fuel)]
    [(or
        (string.string-eq name "enum-variant-name")
        (string.string-eq name "enum-variant-payload-count"))
      (ctfe-eval-enum-variant-reflection name args expr env fuel)]
    [(string.string-eq name "enum-variant-payload-type")
      (ctfe-eval-enum-payload-type-reflection args expr env fuel)]
    [(string.string-eq name "function-param-type")
      (ctfe-eval-function-param-type-reflection args expr env fuel)]
    [else (ctfe-unsupported-form expr)]))

(define (ctfe-eval-string-eq-call
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons left tail)
      (let
        [left : AstExpr (ctfe-ast-get env left)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprCons right rest)
            (let
              [right : AstExpr (ctfe-ast-get env right)]
              [rest : AstExprList (box-get rest)]
              (match rest
                [(AstExprNil)
                  (match (ctfe-eval-string-arg left expr env fuel name)
                    [(ErrCtfeStringArg d) (ErrCtfe d)]
                    [(OkCtfeStringArg l left-fuel)
                      (match (ctfe-eval-string-arg
                        right
                        expr
                        env
                        left-fuel
                        name)
                        [(ErrCtfeStringArg d) (ErrCtfe d)]
                        [(OkCtfeStringArg r right-fuel)
                          (OkCtfe (CtfeBool (string.string-eq l r)) right-fuel)])])]
                [_
                  (ErrCtfe
                    (ctfe-diagnostic-at-expr
                      expr
                      "string-eq expects two strings"))]))]
          [_
            (ErrCtfe
              (ctfe-diagnostic-at-expr expr "string-eq expects two strings"))]))]
    [_ (ErrCtfe (ctfe-diagnostic-at-expr expr "string-eq expects two strings"))]))

(define (ctfe-eval-string-append-call
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons left tail)
      (let
        [left : AstExpr (ctfe-ast-get env left)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprCons right rest)
            (let
              [right : AstExpr (ctfe-ast-get env right)]
              [rest : AstExprList (box-get rest)]
              (match rest
                [(AstExprNil)
                  (match (ctfe-eval-string-arg left expr env fuel name)
                    [(ErrCtfeStringArg d) (ErrCtfe d)]
                    [(OkCtfeStringArg l left-fuel)
                      (match (ctfe-eval-string-arg
                        right
                        expr
                        env
                        left-fuel
                        name)
                        [(ErrCtfeStringArg d) (ErrCtfe d)]
                        [(OkCtfeStringArg r right-fuel)
                          (OkCtfe
                            (CtfeString (string.string-append l r))
                            right-fuel)])])]
                [_
                  (ErrCtfe
                    (ctfe-diagnostic-at-expr
                      expr
                      "string-append expects two strings"))]))]
          [_
            (ErrCtfe
              (ctfe-diagnostic-at-expr expr "string-append expects two strings"))]))]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr expr "string-append expects two strings"))]))

(define (ctfe-eval-string-length-call
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons arg rest)
      (let
        [arg : AstExpr (ctfe-ast-get env arg)]
        [rest : AstExprList (box-get rest)]
        (match rest
          [(AstExprNil)
            (match (ctfe-eval-string-arg arg expr env fuel name)
              [(ErrCtfeStringArg d) (ErrCtfe d)]
              [(OkCtfeStringArg text arg-fuel)
                (OkCtfe (CtfeI64 (string.string-length text)) arg-fuel)])]
          [_
            (ErrCtfe
              (ctfe-diagnostic-at-expr expr "string-length expects one string"))]))]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr expr "string-length expects one string"))]))

(define (ctfe-eval-string-ref-call
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons text tail)
      (let
        [text : AstExpr (ctfe-ast-get env text)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprCons index rest)
            (let
              [index : AstExpr (ctfe-ast-get env index)]
              [rest : AstExprList (box-get rest)]
              (match rest
                [(AstExprNil)
                  (match (ctfe-eval-string-arg text expr env fuel name)
                    [(ErrCtfeStringArg d) (ErrCtfe d)]
                    [(OkCtfeStringArg s text-fuel)
                      (ctfe-eval-string-ref-index
                        s
                        index
                        expr
                        env
                        text-fuel
                        name)])]
                [_
                  (ErrCtfe
                    (ctfe-diagnostic-at-expr
                      expr
                      "string-ref expects a string and index"))]))]
          [_
            (ErrCtfe
              (ctfe-diagnostic-at-expr
                expr
                "string-ref expects a string and index"))]))]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr expr "string-ref expects a string and index"))]))

(define (ctfe-eval-string-ref-index
  [text : String]
  [index-expr : AstExpr]
  [origin : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]
  [name : String]) : ResultCtfe
  (match (ctfe-eval-i64-arg index-expr origin env fuel name)
    [(ErrCtfeI64Arg d) (ErrCtfe d)]
    [(OkCtfeI64Arg index index-fuel)
      (if (or (< index 0) (>= index (string.string-length text)))
        (ErrCtfe
          (ctfe-diagnostic-at-expr origin "string-ref index out of bounds"))
        (OkCtfe (CtfeChar (string.string-ref text index)) index-fuel))]))

(define (ctfe-eval-string-to-int-call
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons arg rest)
      (let
        [arg : AstExpr (ctfe-ast-get env arg)]
        [rest : AstExprList (box-get rest)]
        (match rest
          [(AstExprNil)
            (match (ctfe-eval-string-arg arg expr env fuel name)
              [(ErrCtfeStringArg d) (ErrCtfe d)]
              [(OkCtfeStringArg text arg-fuel)
                (OkCtfe (CtfeI64 (string.string->int text)) arg-fuel)])]
          [_
            (ErrCtfe
              (ctfe-diagnostic-at-expr expr "string->int expects one string"))]))]
    [_
      (ErrCtfe (ctfe-diagnostic-at-expr expr "string->int expects one string"))]))

(define (ctfe-eval-int-to-string-call
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons arg rest)
      (let
        [arg : AstExpr (ctfe-ast-get env arg)]
        [rest : AstExprList (box-get rest)]
        (match rest
          [(AstExprNil)
            (match (ctfe-eval-i64-arg arg expr env fuel "int->string")
              [(ErrCtfeI64Arg d) (ErrCtfe d)]
              [(OkCtfeI64Arg n arg-fuel)
                (OkCtfe (CtfeString (string.int->string n)) arg-fuel)])]
          [_
            (ErrCtfe
              (ctfe-diagnostic-at-expr expr "int->string expects one i64"))]))]
    [_ (ErrCtfe (ctfe-diagnostic-at-expr expr "int->string expects one i64"))]))

;; User-facing stdlib.comptime helpers. Constructors and dense sequence helpers
;; remain CTFE bridge calls while CTFE lacks general stdlib function calls and
;; syntax values still carry compiler-owned provenance/type metadata. Simple
;; public inspectors may also have ordinary stdlib bodies; the intercepts keep
;; existing macro code behavior-compatible until the representation migration is
;; complete (#2653).
(define (ctfe-stdlib-comptime-helper-name?
  [name : String]
  [qualified : bool]
  [base : String]) : bool
  (or
    (string.string-eq name base)
    (and
      qualified
      (or
        (string.string-eq name (string.string-append "comptime." base))
        (string.string-eq name (string.string-append "comptime/" base))
        (string.string-eq name (string.string-append "stdlib.comptime." base))
        (string.string-eq name (string.string-append "stdlib.comptime/" base))
        (string.string-eq name (string.string-append "stdlib/comptime." base))
        (string.string-eq name (string.string-append "stdlib/comptime/" base))))))

(define (ctfe-stdlib-string-helper-name? [name : String] [base : String]) : bool
  (and
    (ctfe-string-has-module-separator? name)
    (or
      (string.string-eq name (string.string-append "string." base))
      (string.string-eq name (string.string-append "string/" base))
      (string.string-eq name (string.string-append "stdlib.string." base))
      (string.string-eq name (string.string-append "stdlib.string/" base))
      (string.string-eq name (string.string-append "stdlib/string." base))
      (string.string-eq name (string.string-append "stdlib/string/" base))
      (string.string-eq name (string.string-append "stdlib/string.tl." base))
      (string.string-eq name (string.string-append "stdlib/string.tl/" base))
      (ctfe-string-suffix?
        name
        (string.string-append "/stdlib/string.tl." base))
      (ctfe-string-suffix?
        name
        (string.string-append "/stdlib/string.tl/" base)))))

(define (ctfe-string-eq-helper-name? [name : String]) : bool
  (or
    (string.string-eq name "__tl_string_eq")
    (string.string-eq name "string-eq")
    (string.string-eq name "string=?")
    (ctfe-stdlib-string-helper-name? name "string-eq")
    (ctfe-stdlib-string-helper-name? name "string=?")))

(define (ctfe-string-length-helper-name? [name : String]) : bool
  (or
    (string.string-eq name "__tl_string_length")
    (string.string-eq name "string-length")
    (ctfe-stdlib-string-helper-name? name "string-length")
    (string.string-eq name "length")))

(define (ctfe-string-ref-helper-name? [name : String]) : bool
  (or
    (string.string-eq name "__tl_string_ref")
    (string.string-eq name "string-ref")
    (string.string-eq name "char-at")
    (ctfe-stdlib-string-helper-name? name "string-ref")
    (ctfe-stdlib-string-helper-name? name "char-at")))

(define (ctfe-string-to-int-helper-name? [name : String]) : bool
  (or
    (string.string-eq name "__tl_string_to_int")
    (string.string-eq name "string->int")
    (ctfe-stdlib-string-helper-name? name "string->int")))

(define (ctfe-comptime-helper-call-name [name : String]) : String
  (let
    [qualified : bool (ctfe-string-has-module-separator? name)]
    (cond
      [(ctfe-stdlib-comptime-helper-name? name qualified "expr-bool")
        "expr-bool"]
      [(ctfe-stdlib-comptime-helper-name? name qualified "expr-int") "expr-int"]
      [(ctfe-stdlib-comptime-helper-name? name qualified "expr-var") "expr-var"]
      [(ctfe-stdlib-comptime-helper-name? name qualified "expr-struct-get")
        "expr-struct-get"]
      [(ctfe-stdlib-comptime-helper-name? name qualified "expr-splice")
        "expr-splice"]
      [(ctfe-stdlib-comptime-helper-name? name qualified "expr-if") "expr-if"]
      [(ctfe-stdlib-comptime-helper-name? name qualified "expr-type")
        "expr-type"]
      [(ctfe-stdlib-comptime-helper-name? name qualified "expr-bool?")
        "expr-bool?"]
      [(ctfe-stdlib-comptime-helper-name? name qualified "expr-bool-value")
        "expr-bool-value"]
      [(ctfe-stdlib-comptime-helper-name? name qualified "expr-if?") "expr-if?"]
      [(ctfe-stdlib-comptime-helper-name? name qualified "expr-if-cond")
        "expr-if-cond"]
      [(ctfe-stdlib-comptime-helper-name? name qualified "expr-if-then")
        "expr-if-then"]
      [(ctfe-stdlib-comptime-helper-name? name qualified "expr-if-else")
        "expr-if-else"]
      [(ctfe-stdlib-comptime-helper-name? name qualified "expr-list-empty?")
        "expr-list-empty?"]
      [(ctfe-stdlib-comptime-helper-name? name qualified "expr-list-length")
        "expr-list-length"]
      [(ctfe-stdlib-comptime-helper-name? name qualified "expr-list-head")
        "expr-list-head"]
      [(ctfe-stdlib-comptime-helper-name? name qualified "expr-list-tail")
        "expr-list-tail"]
      [(ctfe-stdlib-comptime-helper-name? name qualified "expr-list-nth")
        "expr-list-nth"]
      [(ctfe-stdlib-comptime-helper-name? name qualified "expr-clause-first")
        "expr-clause-first"]
      [(ctfe-stdlib-comptime-helper-name? name qualified "expr-clause-second")
        "expr-clause-second"]
      [(ctfe-stdlib-comptime-helper-name?
          name
          qualified
          "expr-clause-list-empty?")
        "expr-clause-list-empty?"]
      [(ctfe-stdlib-comptime-helper-name?
          name
          qualified
          "expr-clause-list-length")
        "expr-clause-list-length"]
      [(ctfe-stdlib-comptime-helper-name?
          name
          qualified
          "expr-clause-list-head")
        "expr-clause-list-head"]
      [(ctfe-stdlib-comptime-helper-name?
          name
          qualified
          "expr-clause-list-tail")
        "expr-clause-list-tail"]
      [(ctfe-stdlib-comptime-helper-name? name qualified "expr-clause-list-nth")
        "expr-clause-list-nth"]
      [(ctfe-stdlib-comptime-helper-name?
          name
          qualified
          "expr-clause-list->expr-list")
        "expr-clause-list->expr-list"]
      [(ctfe-stdlib-comptime-helper-name?
          name
          qualified
          "expr-binding-clause-name")
        "expr-binding-clause-name"]
      [(ctfe-stdlib-comptime-helper-name?
          name
          qualified
          "expr-binding-clause-has-type?")
        "expr-binding-clause-has-type?"]
      [(ctfe-stdlib-comptime-helper-name?
          name
          qualified
          "expr-binding-clause-type")
        "expr-binding-clause-type"]
      [(ctfe-stdlib-comptime-helper-name?
          name
          qualified
          "expr-binding-clause-init")
        "expr-binding-clause-init"]
      [(ctfe-stdlib-comptime-helper-name?
          name
          qualified
          "expr-binding-clause-list-empty?")
        "expr-binding-clause-list-empty?"]
      [(ctfe-stdlib-comptime-helper-name?
          name
          qualified
          "expr-binding-clause-list-length")
        "expr-binding-clause-list-length"]
      [(ctfe-stdlib-comptime-helper-name?
          name
          qualified
          "expr-binding-clause-list-head")
        "expr-binding-clause-list-head"]
      [(ctfe-stdlib-comptime-helper-name?
          name
          qualified
          "expr-binding-clause-list-tail")
        "expr-binding-clause-list-tail"]
      [(ctfe-stdlib-comptime-helper-name?
          name
          qualified
          "expr-binding-clause-list-nth")
        "expr-binding-clause-list-nth"]
      [(ctfe-stdlib-comptime-helper-name?
          name
          qualified
          "expr-binding-clause-list->expr-list")
        "expr-binding-clause-list->expr-list"]
      [(ctfe-stdlib-comptime-helper-name? name qualified "string-append")
        "string-append"]
      [(ctfe-stdlib-comptime-helper-name? name qualified "string-concat")
        "string-concat"]
      [(ctfe-stdlib-comptime-helper-name? name qualified "int->string")
        "int->string"]
      [else name])))

(define (ctfe-eval-expr-bool-call
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons arg rest)
      (let
        [arg : AstExpr (ctfe-ast-get env arg)]
        [rest : AstExprList (box-get rest)]
        (match rest
          [(AstExprNil)
            (match (compiler-ctfe-eval arg env fuel)
              [(OkCtfe value arg-fuel)
                (match value
                  [(CtfeBool b)
                    (OkCtfe
                      (CtfeExpr
                        (ctfe-ast-push env (AstExprLiteral (AstLitBool b)))
                        (AstTyBool))
                      arg-fuel)]
                  [_
                    (ErrCtfe
                      (ctfe-diagnostic-at-expr expr "expr-bool expects bool"))])]
              [(ErrCtfe diag) (ErrCtfe diag)])]
          [_
            (ErrCtfe
              (ctfe-diagnostic-at-expr expr "expr-bool expects exactly one arg"))]))]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr expr "expr-bool expects exactly one arg"))]))

(define (ctfe-eval-expr-splice-call
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons arg rest)
      (let
        [arg : AstExpr (ctfe-ast-get env arg)]
        [rest : AstExprList (box-get rest)]
        (match rest
          [(AstExprNil)
            (match (compiler-ctfe-eval arg env fuel)
              [(OkCtfe value arg-fuel)
                (match value
                  [(CtfeExpr node ty) (OkCtfe (CtfeExpr node ty) arg-fuel)]
                  [_
                    (ErrCtfe
                      (ctfe-diagnostic-at-expr expr "expr-splice expects Expr"))])]
              [(ErrCtfe diag) (ErrCtfe diag)])]
          [_
            (ErrCtfe
              (ctfe-diagnostic-at-expr
                expr
                "expr-splice expects exactly one arg"))]))]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr expr "expr-splice expects exactly one arg"))]))

;; `(expr-int n)` builds an i64 literal Expr from a comptime integer, letting a
;; macro splice a computed count or index as a literal (unquote requires an Expr,
;; so a bare i64 cannot be spliced directly).
(define (ctfe-eval-expr-int-call
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons arg rest)
      (let
        [arg : AstExpr (ctfe-ast-get env arg)]
        [rest : AstExprList (box-get rest)]
        (match rest
          [(AstExprNil)
            (match (compiler-ctfe-eval arg env fuel)
              [(OkCtfe value arg-fuel)
                (match value
                  [(CtfeI64 n)
                    (OkCtfe
                      (CtfeExpr
                        (ctfe-ast-push env (AstExprLiteral (ast-lit-int n)))
                        (AstTyI64))
                      arg-fuel)]
                  [_
                    (ErrCtfe
                      (ctfe-diagnostic-at-expr expr "expr-int expects i64"))])]
              [(ErrCtfe diag) (ErrCtfe diag)])]
          [_
            (ErrCtfe
              (ctfe-diagnostic-at-expr expr "expr-int expects exactly one arg"))]))]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr expr "expr-int expects exactly one arg"))]))

;; `(expr-var name)` builds a variable-reference Expr from a comptime string.
(define (ctfe-eval-expr-var-call
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons arg rest)
      (let
        [arg : AstExpr (ctfe-ast-get env arg)]
        [rest : AstExprList (box-get rest)]
        (match rest
          [(AstExprNil)
            (match (compiler-ctfe-eval arg env fuel)
              [(OkCtfe value arg-fuel)
                (match value
                  [(CtfeString name)
                    (OkCtfe
                      (CtfeExpr
                        (ctfe-ast-push env (AstExprVar (intern name)))
                        (ctfe-untyped-expr-type))
                      arg-fuel)]
                  [_
                    (ErrCtfe
                      (ctfe-diagnostic-at-expr expr "expr-var expects String"))])]
              [(ErrCtfe diag) (ErrCtfe diag)])]
          [_
            (ErrCtfe
              (ctfe-diagnostic-at-expr expr "expr-var expects exactly one arg"))]))]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr expr "expr-var expects exactly one arg"))]))

;; `(expr-struct-get target field)` builds a struct-get Expr whose field name is
;; computed at macro CTFE. The expanded program typechecks the field access.
(define (ctfe-eval-expr-struct-get-call
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons target-arg tail)
      (let
        [target-arg : AstExpr (ctfe-ast-get env target-arg)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprCons field-arg rest)
            (let
              [field-arg : AstExpr (ctfe-ast-get env field-arg)]
              [rest : AstExprList (box-get rest)]
              (match rest
                [(AstExprNil)
                  (match (compiler-ctfe-eval target-arg env fuel)
                    [(OkCtfe target-val target-fuel)
                      (match target-val
                        [(CtfeExpr target-node _)
                          (match (compiler-ctfe-eval field-arg env target-fuel)
                            [(OkCtfe field-val field-fuel)
                              (match field-val
                                [(CtfeString field)
                                  (OkCtfe
                                    (CtfeExpr
                                      (ast-expr-struct-get-with-pools
                                        (ctfe-env-pools env)
                                        target-node
                                        field)
                                      (ctfe-untyped-expr-type))
                                    field-fuel)]
                                [_
                                  (ErrCtfe
                                    (ctfe-diagnostic-at-expr
                                      expr
                                      "expr-struct-get field expects String"))])]
                            [(ErrCtfe diag) (ErrCtfe diag)])]
                        [_
                          (ErrCtfe
                            (ctfe-diagnostic-at-expr
                              expr
                              "expr-struct-get target expects Expr"))])]
                    [(ErrCtfe diag) (ErrCtfe diag)])]
                [_
                  (ErrCtfe
                    (ctfe-diagnostic-at-expr
                      expr
                      "expr-struct-get expects exactly two args"))]))]
          [_
            (ErrCtfe
              (ctfe-diagnostic-at-expr
                expr
                "expr-struct-get expects exactly two args"))]))]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          "expr-struct-get expects exactly two args"))]))

(define (ctfe-expr-inspector-name? [name : String]) : bool
  (or
    (string.string-eq name "expr-bool?")
    (string.string-eq name "expr-bool-value")
    (string.string-eq name "expr-if?")
    (string.string-eq name "expr-if-cond")
    (string.string-eq name "expr-if-then")
    (string.string-eq name "expr-if-else")))

(define (ctfe-eval-expr-type-call
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons arg rest)
      (let
        [arg : AstExpr (ctfe-ast-get env arg)]
        [rest : AstExprList (box-get rest)]
        (match rest
          [(AstExprNil)
            (match (compiler-ctfe-eval arg env fuel)
              [(OkCtfe value arg-fuel)
                (match value
                  [(CtfeExpr _ ty)
                    (let
                      [actual-ty : AstType
                        (ctfe-captured-expr-type-inner-with-pools
                          (ctfe-env-pools env)
                          ty)]
                      (if (ctfe-untyped-expr-type? actual-ty)
                        (ErrCtfe
                          (ctfe-diagnostic-at-expr
                            expr
                            "expr-type requires a typechecked Expr"))
                        (OkCtfe
                          (CtfeType
                            (ctfe-reflect-resolve-type-with-pools
                              (ctfe-env-pools env)
                              (ctfe-env-reflections env)
                              actual-ty))
                          arg-fuel)))]
                  [_
                    (ErrCtfe
                      (ctfe-diagnostic-at-expr expr "expr-type expects Expr"))])]
              [(ErrCtfe diag) (ErrCtfe diag)])]
          [_
            (ErrCtfe
              (ctfe-diagnostic-at-expr expr "expr-type expects exactly one arg"))]))]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr expr "expr-type expects exactly one arg"))]))

(define (ctfe-expr-list-inspector-name? [name : String]) : bool
  (or
    (string.string-eq name "expr-list-empty?")
    (string.string-eq name "expr-list-length")
    (string.string-eq name "expr-list-head")
    (string.string-eq name "expr-list-tail")
    (string.string-eq name "expr-list-nth")))

(define (ctfe-expr-clause-inspector-name? [name : String]) : bool
  (or
    (string.string-eq name "expr-clause-first")
    (string.string-eq name "expr-clause-second")))

(define (ctfe-expr-clause-list-inspector-name? [name : String]) : bool
  (or
    (string.string-eq name "expr-clause-list-empty?")
    (string.string-eq name "expr-clause-list-length")
    (string.string-eq name "expr-clause-list-head")
    (string.string-eq name "expr-clause-list-tail")
    (string.string-eq name "expr-clause-list-nth")
    (string.string-eq name "expr-clause-list->expr-list")))

(define (ctfe-expr-binding-clause-inspector-name? [name : String]) : bool
  (or
    (string.string-eq name "expr-binding-clause-name")
    (string.string-eq name "expr-binding-clause-has-type?")
    (string.string-eq name "expr-binding-clause-type")
    (string.string-eq name "expr-binding-clause-init")))

(define (ctfe-expr-binding-clause-list-inspector-name? [name : String]) : bool
  (or
    (string.string-eq name "expr-binding-clause-list-empty?")
    (string.string-eq name "expr-binding-clause-list-length")
    (string.string-eq name "expr-binding-clause-list-head")
    (string.string-eq name "expr-binding-clause-list-tail")
    (string.string-eq name "expr-binding-clause-list-nth")
    (string.string-eq name "expr-binding-clause-list->expr-list")))

(define (ctfe-eval-expr-list-nth-call
  [list-arg : AstExpr]
  [index-arg : AstExpr]
  [rest : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match rest
    [(AstExprNil)
      (match (compiler-ctfe-eval list-arg env fuel)
        [(OkCtfe value list-fuel)
          (match value
            [(CtfeExprList nodes)
              (match (ctfe-eval-i64-arg
                index-arg
                expr
                env
                list-fuel
                "expr-list-nth")
                [(ErrCtfeI64Arg d) (ErrCtfe d)]
                [(OkCtfeI64Arg index index-fuel)
                  (if (or (< index 0) (>= index (ctfe-expr-list-length nodes)))
                    (ErrCtfe
                      (ctfe-diagnostic-at-expr
                        expr
                        "expr-list-nth index out of range"))
                    (OkCtfe
                      (CtfeExpr
                        (ctfe-expr-list-nth nodes index)
                        (ctfe-untyped-expr-type))
                      index-fuel))])]
            [_
              (ErrCtfe
                (ctfe-diagnostic-at-expr expr "expr-list-nth expects ExprList"))])]
        [(ErrCtfe diag) (ErrCtfe diag)])]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr expr "expr-list-nth expects exactly two args"))]))

(define (ctfe-eval-expr-inspector-call
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons arg rest)
      (let
        [arg : AstExpr (ctfe-ast-get env arg)]
        [rest : AstExprList (box-get rest)]
        (match rest
          [(AstExprNil)
            (match (compiler-ctfe-eval arg env fuel)
              [(OkCtfe value arg-fuel)
                (match value
                  [(CtfeExpr node ty)
                    (cond
                      [(string.string-eq name "expr-bool?")
                        (OkCtfe
                          (CtfeBool (ctfe-expr-bool?-in-env env node))
                          arg-fuel)]
                      [(string.string-eq name "expr-bool-value")
                        (if (ctfe-expr-bool?-in-env env node)
                          (OkCtfe
                            (CtfeBool (ctfe-expr-bool-value-in-env env node))
                            arg-fuel)
                          (ErrCtfe
                            (ctfe-diagnostic-at-expr
                              expr
                              "expr-bool-value expects bool literal Expr")))]
                      [(string.string-eq name "expr-if?")
                        (OkCtfe
                          (CtfeBool (ctfe-expr-if?-in-env env node))
                          arg-fuel)]
                      [(ctfe-expr-if?-in-env env node)
                        (cond
                          [(string.string-eq name "expr-if-cond")
                            (OkCtfe
                              (CtfeExpr
                                (ctfe-expr-if-cond-in-env env node)
                                (AstTyBool))
                              arg-fuel)]
                          [(string.string-eq name "expr-if-then")
                            (OkCtfe
                              (CtfeExpr (ctfe-expr-if-then-in-env env node) ty)
                              arg-fuel)]
                          [(string.string-eq name "expr-if-else")
                            (OkCtfe
                              (CtfeExpr (ctfe-expr-if-else-in-env env node) ty)
                              arg-fuel)]
                          [else (ctfe-unsupported-form expr)])]
                      [else
                        (ErrCtfe
                          (ctfe-diagnostic-at-expr
                            expr
                            (string.string-append name " expects if Expr")))])]
                  [_
                    (ErrCtfe
                      (ctfe-diagnostic-at-expr
                        expr
                        (string.string-append name " expects Expr")))])]
              [(ErrCtfe diag) (ErrCtfe diag)])]
          [_
            (ErrCtfe
              (ctfe-diagnostic-at-expr
                expr
                (string.string-append name " expects exactly one arg")))]))]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          (string.string-append name " expects exactly one arg")))]))

(define (ctfe-eval-expr-list-inspector-call
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons arg rest)
      (let
        [arg : AstExpr (ctfe-ast-get env arg)]
        [rest : AstExprList (box-get rest)]
        (if (string.string-eq name "expr-list-nth")
          (match rest
            [(AstExprCons index-arg nth-rest)
              (ctfe-eval-expr-list-nth-call
                arg
                (ctfe-ast-get env index-arg)
                (box-get nth-rest)
                expr
                env
                fuel)]
            [_
              (ErrCtfe
                (ctfe-diagnostic-at-expr
                  expr
                  "expr-list-nth expects exactly two args"))])
          (match rest
            [(AstExprNil)
              (match (compiler-ctfe-eval arg env fuel)
                [(OkCtfe value arg-fuel)
                  (match value
                    [(CtfeExprList nodes)
                      (cond
                        [(string.string-eq name "expr-list-empty?")
                          (OkCtfe
                            (CtfeBool (ctfe-expr-list-empty? nodes))
                            arg-fuel)]
                        [(string.string-eq name "expr-list-length")
                          (OkCtfe
                            (CtfeI64 (ctfe-expr-list-length nodes))
                            arg-fuel)]
                        [(ctfe-expr-list-empty? nodes)
                          (ErrCtfe
                            (ctfe-diagnostic-at-expr
                              expr
                              (string.string-append
                                name
                                " expects non-empty ExprList")))]
                        [(string.string-eq name "expr-list-head")
                          (OkCtfe
                            (CtfeExpr
                              (ctfe-expr-list-head nodes)
                              (ctfe-untyped-expr-type))
                            arg-fuel)]
                        [(string.string-eq name "expr-list-tail")
                          (OkCtfe
                            (CtfeExprList (ctfe-expr-list-tail nodes))
                            arg-fuel)]
                        [else (ctfe-unsupported-form expr)])]
                    [_
                      (ErrCtfe
                        (ctfe-diagnostic-at-expr
                          expr
                          (string.string-append name " expects ExprList")))])]
                [(ErrCtfe diag) (ErrCtfe diag)])]
            [_
              (ErrCtfe
                (ctfe-diagnostic-at-expr
                  expr
                  (string.string-append name " expects exactly one arg")))])))]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          (string.string-append name " expects exactly one arg")))]))

(define (ctfe-eval-expr-clause-inspector-call
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons arg rest)
      (let
        [arg : AstExpr (ctfe-ast-get env arg)]
        [rest : AstExprList (box-get rest)]
        (match rest
          [(AstExprNil)
            (match (compiler-ctfe-eval arg env fuel)
              [(OkCtfe value arg-fuel)
                (match value
                  [(CtfeExprClause clause)
                    (if (string.string-eq name "expr-clause-first")
                      (OkCtfe
                        (CtfeExpr
                          (ctfe-expr-clause-first clause)
                          (ctfe-untyped-expr-type))
                        arg-fuel)
                      (if (string.string-eq name "expr-clause-second")
                        (OkCtfe
                          (CtfeExpr
                            (ctfe-expr-clause-second clause)
                            (ctfe-untyped-expr-type))
                          arg-fuel)
                        (ctfe-unsupported-form expr)))]
                  [_
                    (ErrCtfe
                      (ctfe-diagnostic-at-expr
                        expr
                        (string.string-append name " expects ExprClause")))])]
              [(ErrCtfe diag) (ErrCtfe diag)])]
          [_
            (ErrCtfe
              (ctfe-diagnostic-at-expr
                expr
                (string.string-append name " expects exactly one arg")))]))]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          (string.string-append name " expects exactly one arg")))]))

(define (ctfe-eval-expr-clause-list-nth-call
  [list-arg : AstExpr]
  [index-arg : AstExpr]
  [rest : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match rest
    [(AstExprNil)
      (match (compiler-ctfe-eval list-arg env fuel)
        [(OkCtfe value list-fuel)
          (match value
            [(CtfeExprClauseList clauses)
              (match (ctfe-eval-i64-arg
                index-arg
                expr
                env
                list-fuel
                "expr-clause-list-nth")
                [(ErrCtfeI64Arg d) (ErrCtfe d)]
                [(OkCtfeI64Arg index index-fuel)
                  (if (or
                    (< index 0)
                    (>= index (ctfe-expr-clause-list-length clauses)))
                    (ErrCtfe
                      (ctfe-diagnostic-at-expr
                        expr
                        "expr-clause-list-nth index out of range"))
                    (OkCtfe
                      (CtfeExprClause (ctfe-expr-clause-list-nth clauses index))
                      index-fuel))])]
            [_
              (ErrCtfe
                (ctfe-diagnostic-at-expr
                  expr
                  "expr-clause-list-nth expects ExprClauseList"))])]
        [(ErrCtfe diag) (ErrCtfe diag)])]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          "expr-clause-list-nth expects exactly two args"))]))

(define (ctfe-eval-expr-clause-list-inspector-call
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons arg rest)
      (let
        [arg : AstExpr (ctfe-ast-get env arg)]
        [rest : AstExprList (box-get rest)]
        (if (string.string-eq name "expr-clause-list-nth")
          (match rest
            [(AstExprCons index-arg nth-rest)
              (ctfe-eval-expr-clause-list-nth-call
                arg
                (ctfe-ast-get env index-arg)
                (box-get nth-rest)
                expr
                env
                fuel)]
            [_
              (ErrCtfe
                (ctfe-diagnostic-at-expr
                  expr
                  "expr-clause-list-nth expects exactly two args"))])
          (match rest
            [(AstExprNil)
              (match (compiler-ctfe-eval arg env fuel)
                [(OkCtfe value arg-fuel)
                  (match value
                    [(CtfeExprClauseList clauses)
                      (cond
                        [(string.string-eq name "expr-clause-list-empty?")
                          (OkCtfe
                            (CtfeBool (ctfe-expr-clause-list-empty? clauses))
                            arg-fuel)]
                        [(string.string-eq name "expr-clause-list-length")
                          (OkCtfe
                            (CtfeI64 (ctfe-expr-clause-list-length clauses))
                            arg-fuel)]
                        [(string.string-eq name "expr-clause-list->expr-list")
                          (OkCtfe
                            (CtfeExprList
                              (ctfe-expr-clause-list->expr-list-in-env
                                env
                                clauses))
                            arg-fuel)]
                        [(ctfe-expr-clause-list-empty? clauses)
                          (ErrCtfe
                            (ctfe-diagnostic-at-expr
                              expr
                              (string.string-append
                                name
                                " expects non-empty ExprClauseList")))]
                        [(string.string-eq name "expr-clause-list-head")
                          (OkCtfe
                            (CtfeExprClause
                              (ctfe-expr-clause-list-head clauses))
                            arg-fuel)]
                        [(string.string-eq name "expr-clause-list-tail")
                          (OkCtfe
                            (CtfeExprClauseList
                              (ctfe-expr-clause-list-tail clauses))
                            arg-fuel)]
                        [else (ctfe-unsupported-form expr)])]
                    [_
                      (ErrCtfe
                        (ctfe-diagnostic-at-expr
                          expr
                          (string.string-append name " expects ExprClauseList")))])]
                [(ErrCtfe diag) (ErrCtfe diag)])]
            [_
              (ErrCtfe
                (ctfe-diagnostic-at-expr
                  expr
                  (string.string-append name " expects exactly one arg")))])))]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          (string.string-append name " expects exactly one arg")))]))

(define (ctfe-eval-expr-binding-clause-inspector-call
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons arg rest)
      (let
        [arg : AstExpr (ctfe-ast-get env arg)]
        [rest : AstExprList (box-get rest)]
        (match rest
          [(AstExprNil)
            (match (compiler-ctfe-eval arg env fuel)
              [(OkCtfe value arg-fuel)
                (match value
                  [(CtfeExprBindingClause clause)
                    (cond
                      [(string.string-eq name "expr-binding-clause-name")
                        (OkCtfe
                          (CtfeString (ctfe-expr-binding-clause-name clause))
                          arg-fuel)]
                      [(string.string-eq name "expr-binding-clause-has-type?")
                        (OkCtfe
                          (CtfeBool (ctfe-expr-binding-clause-has-type? clause))
                          arg-fuel)]
                      [(string.string-eq name "expr-binding-clause-type")
                        (if (ctfe-expr-binding-clause-has-type? clause)
                          (OkCtfe
                            (CtfeExpr
                              (ctfe-expr-binding-clause-type clause)
                              (ctfe-untyped-expr-type))
                            arg-fuel)
                          (ErrCtfe
                            (ctfe-diagnostic-at-expr
                              expr
                              "expr-binding-clause-type expects typed ExprBindingClause")))]
                      [(string.string-eq name "expr-binding-clause-init")
                        (OkCtfe
                          (CtfeExpr
                            (ctfe-expr-binding-clause-init clause)
                            (ctfe-untyped-expr-type))
                          arg-fuel)]
                      [else (ctfe-unsupported-form expr)])]
                  [_
                    (ErrCtfe
                      (ctfe-diagnostic-at-expr
                        expr
                        (string.string-append name " expects ExprBindingClause")))])]
              [(ErrCtfe diag) (ErrCtfe diag)])]
          [_
            (ErrCtfe
              (ctfe-diagnostic-at-expr
                expr
                (string.string-append name " expects exactly one arg")))]))]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          (string.string-append name " expects exactly one arg")))]))

(define (ctfe-eval-expr-binding-clause-list-nth-call
  [list-arg : AstExpr]
  [index-arg : AstExpr]
  [rest : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match rest
    [(AstExprNil)
      (match (compiler-ctfe-eval list-arg env fuel)
        [(OkCtfe value list-fuel)
          (match value
            [(CtfeExprBindingClauseList clauses)
              (match (ctfe-eval-i64-arg
                index-arg
                expr
                env
                list-fuel
                "expr-binding-clause-list-nth")
                [(ErrCtfeI64Arg d) (ErrCtfe d)]
                [(OkCtfeI64Arg index index-fuel)
                  (if (or
                    (< index 0)
                    (>= index (ctfe-expr-binding-clause-list-length clauses)))
                    (ErrCtfe
                      (ctfe-diagnostic-at-expr
                        expr
                        "expr-binding-clause-list-nth index out of range"))
                    (OkCtfe
                      (CtfeExprBindingClause
                        (ctfe-expr-binding-clause-list-nth clauses index))
                      index-fuel))])]
            [_
              (ErrCtfe
                (ctfe-diagnostic-at-expr
                  expr
                  "expr-binding-clause-list-nth expects ExprBindingClauseList"))])]
        [(ErrCtfe diag) (ErrCtfe diag)])]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          "expr-binding-clause-list-nth expects exactly two args"))]))

(define (ctfe-eval-expr-binding-clause-list-inspector-call
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons arg rest)
      (let
        [arg : AstExpr (ctfe-ast-get env arg)]
        [rest : AstExprList (box-get rest)]
        (if (string.string-eq name "expr-binding-clause-list-nth")
          (match rest
            [(AstExprCons index-arg nth-rest)
              (ctfe-eval-expr-binding-clause-list-nth-call
                arg
                (ctfe-ast-get env index-arg)
                (box-get nth-rest)
                expr
                env
                fuel)]
            [_
              (ErrCtfe
                (ctfe-diagnostic-at-expr
                  expr
                  "expr-binding-clause-list-nth expects exactly two args"))])
          (match rest
            [(AstExprNil)
              (match (compiler-ctfe-eval arg env fuel)
                [(OkCtfe value arg-fuel)
                  (match value
                    [(CtfeExprBindingClauseList clauses)
                      (cond
                        [(string.string-eq
                            name
                            "expr-binding-clause-list-empty?")
                          (OkCtfe
                            (CtfeBool
                              (ctfe-expr-binding-clause-list-empty? clauses))
                            arg-fuel)]
                        [(string.string-eq
                            name
                            "expr-binding-clause-list-length")
                          (OkCtfe
                            (CtfeI64
                              (ctfe-expr-binding-clause-list-length clauses))
                            arg-fuel)]
                        [(string.string-eq
                            name
                            "expr-binding-clause-list->expr-list")
                          (OkCtfe
                            (CtfeExprList
                              (ctfe-expr-binding-clause-list->expr-list-in-env
                                env
                                clauses))
                            arg-fuel)]
                        [(ctfe-expr-binding-clause-list-empty? clauses)
                          (ErrCtfe
                            (ctfe-diagnostic-at-expr
                              expr
                              (string.string-append
                                name
                                " expects non-empty ExprBindingClauseList")))]
                        [(string.string-eq name "expr-binding-clause-list-head")
                          (OkCtfe
                            (CtfeExprBindingClause
                              (ctfe-expr-binding-clause-list-head clauses))
                            arg-fuel)]
                        [(string.string-eq name "expr-binding-clause-list-tail")
                          (OkCtfe
                            (CtfeExprBindingClauseList
                              (ctfe-expr-binding-clause-list-tail clauses))
                            arg-fuel)]
                        [else (ctfe-unsupported-form expr)])]
                    [_
                      (ErrCtfe
                        (ctfe-diagnostic-at-expr
                          expr
                          (string.string-append
                            name
                            " expects ExprBindingClauseList")))])]
                [(ErrCtfe diag) (ErrCtfe diag)])]
            [_
              (ErrCtfe
                (ctfe-diagnostic-at-expr
                  expr
                  (string.string-append name " expects exactly one arg")))])))]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          (string.string-append name " expects exactly one arg")))]))

(define (ctfe-eval-expr-if-call
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons cond-arg tail1)
      (let
        [cond-arg : AstExpr (ctfe-ast-get env cond-arg)]
        [tail1 : AstExprList (box-get tail1)]
        (match tail1
          [(AstExprCons then-arg tail2)
            (let
              [then-arg : AstExpr (ctfe-ast-get env then-arg)]
              [tail2 : AstExprList (box-get tail2)]
              (match tail2
                [(AstExprCons else-arg rest)
                  (let
                    [else-arg : AstExpr (ctfe-ast-get env else-arg)]
                    [rest : AstExprList (box-get rest)]
                    (match rest
                      [(AstExprNil)
                        (match (compiler-ctfe-eval cond-arg env fuel)
                          [(OkCtfe cond-val cond-fuel)
                            (match cond-val
                              [(CtfeExpr cond-node cond-ty)
                                (if (ctfe-type-eq-in-env
                                  env
                                  cond-ty
                                  (AstTyBool))
                                  (match (compiler-ctfe-eval
                                    then-arg
                                    env
                                    cond-fuel)
                                    [(OkCtfe then-val then-fuel)
                                      (match then-val
                                        [(CtfeExpr then-node then-ty)
                                          (match (compiler-ctfe-eval
                                            else-arg
                                            env
                                            then-fuel)
                                            [(OkCtfe else-val else-fuel)
                                              (match else-val
                                                [(CtfeExpr else-node else-ty)
                                                  (if (ctfe-type-eq-in-env
                                                    env
                                                    then-ty
                                                    else-ty)
                                                    (OkCtfe
                                                      (CtfeExpr
                                                        (ast-expr-if-with-pools
                                                          (ctfe-env-pools env)
                                                          cond-node
                                                          then-node
                                                          else-node)
                                                        then-ty)
                                                      else-fuel)
                                                    (ErrCtfe
                                                      (ctfe-diagnostic-at-expr
                                                        expr
                                                        "expr-if branch types must match")))]
                                                [_
                                                  (ErrCtfe
                                                    (ctfe-diagnostic-at-expr
                                                      expr
                                                      "expr-if else branch expects Expr"))])]
                                            [(ErrCtfe diag) (ErrCtfe diag)])]
                                        [_
                                          (ErrCtfe
                                            (ctfe-diagnostic-at-expr
                                              expr
                                              "expr-if then branch expects Expr"))])]
                                    [(ErrCtfe diag) (ErrCtfe diag)])
                                  (ErrCtfe
                                    (ctfe-diagnostic-at-expr
                                      expr
                                      "expr-if condition must produce bool")))]
                              [_
                                (ErrCtfe
                                  (ctfe-diagnostic-at-expr
                                    expr
                                    "expr-if condition expects Expr"))])]
                          [(ErrCtfe diag) (ErrCtfe diag)])]
                      [_
                        (ErrCtfe
                          (ctfe-diagnostic-at-expr
                            expr
                            "expr-if expects exactly three args"))]))]
                [_
                  (ErrCtfe
                    (ctfe-diagnostic-at-expr
                      expr
                      "expr-if expects exactly three args"))]))]
          [_
            (ErrCtfe
              (ctfe-diagnostic-at-expr
                expr
                "expr-if expects exactly three args"))]))]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr expr "expr-if expects exactly three args"))]))

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
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (ctfe-eval-call inner args expr env fuel))]
    [(AstExprVar name)
      (let
        [raw-name : String (intern-str name)]
        [lookup-name : String (ctfe-hygiene-global-call-name raw-name)]
        [call-name : String (ctfe-comptime-helper-call-name lookup-name)]
        [string-helper-candidate : bool
          (ctfe-string-helper-candidate-name? lookup-name)]
        (cond
          [(or
              (string.string-eq lookup-name "size-of")
              (string.string-eq lookup-name "align-of"))
            (ctfe-eval-size-align-query lookup-name args expr env fuel)]
          [(string.string-eq lookup-name "offset-of")
            (ctfe-eval-offset-query args expr env fuel)]
          [(ctfe-reflection-query-name? lookup-name)
            (ctfe-eval-reflection-query lookup-name args expr env fuel)]
          [(and
              string-helper-candidate
              (ctfe-string-eq-helper-name? lookup-name))
            (ctfe-eval-string-eq-call lookup-name args expr env fuel)]
          [(or
              (string.string-eq call-name "string-append")
              (string.string-eq call-name "string-concat"))
            (ctfe-eval-string-append-call call-name args expr env fuel)]
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
          [(string.string-eq call-name "int->string")
            (ctfe-eval-int-to-string-call args expr env fuel)]
          [(string.string-eq call-name "expr-bool")
            (ctfe-eval-expr-bool-call args expr env fuel)]
          [(string.string-eq call-name "expr-int")
            (ctfe-eval-expr-int-call args expr env fuel)]
          [(string.string-eq call-name "expr-var")
            (ctfe-eval-expr-var-call args expr env fuel)]
          [(string.string-eq call-name "expr-struct-get")
            (ctfe-eval-expr-struct-get-call args expr env fuel)]
          [(string.string-eq call-name "expr-splice")
            (ctfe-eval-expr-splice-call args expr env fuel)]
          [(string.string-eq call-name "expr-if")
            (ctfe-eval-expr-if-call args expr env fuel)]
          [(string.string-eq call-name "expr-type")
            (ctfe-eval-expr-type-call args expr env fuel)]
          [(ctfe-expr-inspector-name? call-name)
            (ctfe-eval-expr-inspector-call call-name args expr env fuel)]
          [(ctfe-expr-list-inspector-name? call-name)
            (ctfe-eval-expr-list-inspector-call call-name args expr env fuel)]
          [(ctfe-expr-clause-inspector-name? call-name)
            (ctfe-eval-expr-clause-inspector-call call-name args expr env fuel)]
          [(ctfe-expr-clause-list-inspector-name? call-name)
            (ctfe-eval-expr-clause-list-inspector-call
              call-name
              args
              expr
              env
              fuel)]
          [(ctfe-expr-binding-clause-inspector-name? call-name)
            (ctfe-eval-expr-binding-clause-inspector-call
              call-name
              args
              expr
              env
              fuel)]
          [(ctfe-expr-binding-clause-list-inspector-name? call-name)
            (ctfe-eval-expr-binding-clause-list-inspector-call
              call-name
              args
              expr
              env
              fuel)]
          [else (ctfe-unsupported-form expr)]))]
    [_ (ctfe-unsupported-form expr)]))

;; Shared "unsupported compile-time form" diagnostic for ordinary calls.
(define (ctfe-unsupported-form [expr : AstExpr]) : ResultCtfe
  (ErrCtfe
    (ctfe-diagnostic-at-expr
      expr
      (string.string-append
        "'"
        (string.string-append
          (ctfe-describe-expr expr)
          "' is not supported in compile-time evaluation")))))

(define (ctfe-eval-var
  [name : String]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match (ctfe-env-lookup env name)
    [(CtfeSomeValue value) (OkCtfe value fuel)]
    [(CtfeNoValue)
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          (string.string-append
            "compile-time evaluation cannot reference runtime variable '"
            (string.string-append name "'"))))]))

(define (ctfe-eval-binary
  [op : AstBinOp]
  [left : AstExpr]
  [right : AstExpr]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match (compiler-ctfe-eval left env fuel)
    [(OkCtfe lv left-fuel)
      (match (compiler-ctfe-eval right env left-fuel)
        [(OkCtfe rv right-fuel) (ctfe-apply-binop op lv rv expr env right-fuel)]
        [(ErrCtfe diag) (ErrCtfe diag)])]
    [(ErrCtfe diag) (ErrCtfe diag)]))

(define (ctfe-eval-unary
  [op : AstUnOp]
  [inner : AstExpr]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match (compiler-ctfe-eval inner env fuel)
    [(OkCtfe v inner-fuel) (ctfe-apply-unop op v expr inner-fuel)]
    [(ErrCtfe diag) (ErrCtfe diag)]))

(define (ctfe-eval-if
  [cond : AstExpr]
  [then-branch : AstExpr]
  [else-branch : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match (compiler-ctfe-eval cond env fuel)
    [(OkCtfe cond-value cond-fuel)
      (match cond-value
        [(CtfeBool b)
          (if b
            (compiler-ctfe-eval then-branch env cond-fuel)
            (compiler-ctfe-eval else-branch env cond-fuel))]
        [_
          (ErrCtfe
            (ctfe-diagnostic-at-expr
              cond
              "comptime 'if' condition must be bool"))])]
    [(ErrCtfe diag) (ErrCtfe diag)]))

;; Evaluate `let` bindings sequentially, threading both fuel and the extended
;; environment. The original `env` is preserved for siblings because each
;; binding extends a fresh copy threaded forward.
(define (ctfe-eval-let
  [bindings : AstLetBindingList]
  [body : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match bindings
    [(AstLetBindingNil) (compiler-ctfe-eval body env fuel)]
    [(AstLetBindingCons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding name maybe-ty value-expr-box)
            (let
              [value-expr : AstExpr (ctfe-ast-get env value-expr-box)]
              (match (compiler-ctfe-eval value-expr env fuel)
                [(OkCtfe value value-fuel)
                  (ctfe-eval-let
                    rest
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
                [(ErrCtfe diag) (ErrCtfe diag)]))]))]))

;; Evaluate a `begin` to the value of its last expression; an empty body is
;; unit.
(define (ctfe-eval-begin [exprs : AstExprList] [env : CtfeEnv] [fuel : i64]) : ResultCtfe
  (match exprs
    [(AstExprNil) (OkCtfe (CtfeUnit) fuel)]
    [(AstExprCons head rest)
      (let
        [head : AstExpr (ctfe-ast-get env head)]
        [rest : AstExprList (box-get rest)]
        (match (compiler-ctfe-eval head env fuel)
          [(OkCtfe value head-fuel)
            (match rest
              [(AstExprNil) (OkCtfe value head-fuel)]
              [_ (ctfe-eval-begin rest env head-fuel)])]
          [(ErrCtfe diag) (ErrCtfe diag)]))]))

;; Evaluate a small CTFE-owned `match` subset. Runtime enum/struct values still
;; have no CTFE representation; this covers scalar values and the public
;; stdlib.comptime syntax pseudo-values backed by CtfeExpr/CtfeExprList.
(define (ctfe-value-list-cons [head : CompilerCtfeValue] [tail : CtfeValueList]) : CtfeValueList
  (CtfeValueCons head (box tail)))

(define (ctfe-value-list1 [a : CompilerCtfeValue]) : CtfeValueList
  (ctfe-value-list-cons a CtfeValueNil))

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
      (string.string-eq
        (string.substring text (- text-len suffix-len) suffix-len)
        suffix))))

(define (ctfe-pattern-variant-name? [name : i64] [expected : String]) : bool
  (let
    [actual : String (intern-str name)]
    (or
      (string.string-eq actual expected)
      (ctfe-string-suffix? actual (string.string-append "." expected))
      (ctfe-string-suffix? actual (string.string-append "/" expected)))))

(define (ctfe-literal-matches-value?
  [lit : AstLiteral]
  [value : CompilerCtfeValue]) : bool
  (match lit
    [(AstLitInt n _)
      (match value
        [(CtfeI64 actual) (= actual n)]
        [_ false])]
    [(AstLitBool b)
      (match value
        [(CtfeBool actual) (= actual b)]
        [_ false])]
    [(AstLitChar c)
      (match value
        [(CtfeChar actual) (= actual c)]
        [_ false])]
    [(AstLitUnit)
      (match value
        [(CtfeUnit) true]
        [_ false])]
    [(AstLitFloat text)
      (match (compiler-float-parse-f64 text)
        [(CompilerFloatSomeF64 want)
          (match value
            [(CtfeF64 actual) (= actual want)]
            [(CtfeF32 actual) (= actual want)]
            [_ false])]
        [(CompilerFloatNoF64) false])]
    [(AstLitString text)
      (match value
        [(CtfeString actual) (string.string-eq actual text)]
        [_ false])]))

(define (ctfe-match-pattern-list
  [patterns : AstPatternList]
  [values : CtfeValueList]
  [env : CtfeEnv]) : CtfePatternMatch
  (match patterns
    [(AstPatternNil)
      (match values
        [(CtfeValueNil) (CtfePatternMatched env)]
        [_ (CtfeNoPatternMatch)])]
    [(AstPatternCons pattern rest-patterns)
      (let
        [pattern : AstPattern (box-get pattern)]
        [rest-patterns : AstPatternList (box-get rest-patterns)]
        (match values
          [(CtfeValueCons value rest-values)
            (match (ctfe-match-pattern
              pattern
              value
              (ctfe-value-default-cast-type value)
              env)
              [(CtfePatternMatched next-env)
                (ctfe-match-pattern-list
                  rest-patterns
                  (box-get rest-values)
                  next-env)]
              [(CtfeNoPatternMatch) (CtfeNoPatternMatch)])]
          [(CtfeValueNil) (CtfeNoPatternMatch)]))]))

(define (ctfe-match-expr-variant
  [variant : i64]
  [args : AstPatternList]
  [node : i64]
  [ty : AstType]
  [env : CtfeEnv]) : CtfePatternMatch
  (match (ctfe-expr-unspan env (ctfe-ast-get env node))
    [(AstExprLiteral lit)
      (match lit
        [(AstLitBool b)
          (if (ctfe-pattern-variant-name? variant "ExprBool")
            (ctfe-match-pattern-list args (ctfe-value-list1 (CtfeBool b)) env)
            (CtfeNoPatternMatch))]
        [(AstLitInt n _)
          (if (ctfe-pattern-variant-name? variant "ExprInt")
            (ctfe-match-pattern-list args (ctfe-value-list1 (CtfeI64 n)) env)
            (CtfeNoPatternMatch))]
        [_ (CtfeNoPatternMatch)])]
    [(AstExprVar name)
      (if (ctfe-pattern-variant-name? variant "ExprVar")
        (ctfe-match-pattern-list
          args
          (ctfe-value-list1 (CtfeString (intern-str name)))
          env)
        (CtfeNoPatternMatch))]
    [(AstExprIf cond then-branch else-branch)
      (if (ctfe-pattern-variant-name? variant "ExprIf")
        (ctfe-match-pattern-list
          args
          (ctfe-value-list3
            (CtfeExpr cond (AstTyBool))
            (CtfeExpr then-branch ty)
            (CtfeExpr else-branch ty))
          env)
        (CtfeNoPatternMatch))]
    [(AstExprCall callee args-list)
      (if (ctfe-pattern-variant-name? variant "ExprCall")
        (ctfe-match-pattern-list
          args
          (ctfe-value-list2
            (CtfeExpr callee (ctfe-untyped-expr-type))
            (CtfeExprList args-list))
          env)
        (CtfeNoPatternMatch))]
    [(AstExprBegin exprs)
      (if (ctfe-pattern-variant-name? variant "ExprBegin")
        (ctfe-match-pattern-list
          args
          (ctfe-value-list1 (CtfeExprList exprs))
          env)
        (CtfeNoPatternMatch))]
    [(AstExprQuote inner)
      (if (ctfe-pattern-variant-name? variant "ExprQuote")
        (ctfe-match-pattern-list
          args
          (ctfe-value-list1 (CtfeExpr inner (ctfe-untyped-expr-type)))
          env)
        (CtfeNoPatternMatch))]
    [(AstExprQuasiquote inner)
      (if (ctfe-pattern-variant-name? variant "ExprQuasiquote")
        (ctfe-match-pattern-list
          args
          (ctfe-value-list1 (CtfeExpr inner (ctfe-untyped-expr-type)))
          env)
        (CtfeNoPatternMatch))]
    [(AstExprUnquote inner)
      (if (ctfe-pattern-variant-name? variant "ExprUnquote")
        (ctfe-match-pattern-list
          args
          (ctfe-value-list1 (CtfeExpr inner (ctfe-untyped-expr-type)))
          env)
        (CtfeNoPatternMatch))]
    [(AstExprUnquoteSplicing inner)
      (if (ctfe-pattern-variant-name? variant "ExprUnquoteSplicing")
        (ctfe-match-pattern-list
          args
          (ctfe-value-list1 (CtfeExpr inner (ctfe-untyped-expr-type)))
          env)
        (CtfeNoPatternMatch))]
    [_ (CtfeNoPatternMatch)]))

(define (ctfe-match-pattern
  [pattern : AstPattern]
  [value : CompilerCtfeValue]
  [value-ty : AstType]
  [env : CtfeEnv]) : CtfePatternMatch
  (match pattern
    [(AstPatWildcard) (CtfePatternMatched env)]
    [(AstPatBinding name)
      (CtfePatternMatched
        (ctfe-env-extend-typed env (intern-str name) value value-ty))]
    [(AstPatVar name maybe-ty)
      (CtfePatternMatched
        (ctfe-env-extend-typed
          env
          (intern-str name)
          value
          (ctfe-binding-type maybe-ty value-ty env)))]
    [(AstPatLiteral lit)
      (if (ctfe-literal-matches-value? lit value)
        (CtfePatternMatched env)
        (CtfeNoPatternMatch))]
    [(AstPatVariant variant args-box)
      (let
        [args : AstPatternList (box-get args-box)]
        (match value
          [(CtfeExpr node ty)
            (ctfe-match-expr-variant variant args node ty env)]
          [(CtfeExprClause clause)
            (if (ctfe-pattern-variant-name? variant "ExprClause")
              (ctfe-match-pattern-list
                args
                (ctfe-value-list2
                  (CtfeExpr
                    (ctfe-expr-clause-first clause)
                    (ctfe-untyped-expr-type))
                  (CtfeExpr
                    (ctfe-expr-clause-second clause)
                    (ctfe-untyped-expr-type)))
                env)
              (CtfeNoPatternMatch))]
          [_ (CtfeNoPatternMatch)]))]
    [(AstPatTuple _) (CtfeNoPatternMatch)]))

(define (ctfe-eval-match-arms
  [value : CompilerCtfeValue]
  [value-ty : AstType]
  [arms : AstMatchArmList]
  [origin : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match arms
    [(AstMatchArmNil)
      (ErrCtfe
        (ctfe-diagnostic-at-expr origin "comptime: no matching match arm"))]
    [(AstMatchArmCons arm rest)
      (let
        [rest : AstMatchArmList (box-get rest)]
        (match arm
          [(AstMatchArm pattern body-box)
            (match (ctfe-match-pattern pattern value value-ty env)
              [(CtfePatternMatched arm-env)
                (compiler-ctfe-eval (ctfe-ast-get env body-box) arm-env fuel)]
              [(CtfeNoPatternMatch)
                (ctfe-eval-match-arms value value-ty rest origin env fuel)])]))]))

(define (ctfe-eval-match
  [scrutinee : AstExpr]
  [arms : AstMatchArmList]
  [origin : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match (compiler-ctfe-eval scrutinee env fuel)
    [(OkCtfe value scrutinee-fuel)
      (ctfe-eval-match-arms
        value
        (ctfe-cast-source-type scrutinee value env)
        arms
        origin
        env
        scrutinee-fuel)]
    [(ErrCtfe diag) (ErrCtfe diag)]))

;; --- quote / quasiquote -----------------------------------------------------
(define (ctfe-quote-literal-type [lit : AstLiteral]) : AstType
  (match lit
    [(AstLitInt _ _) (AstTyI64)]
    [(AstLitFloat _) (AstTyF64)]
    [(AstLitBool _) (AstTyBool)]
    [(AstLitChar _) (AstTyChar)]
    [(AstLitString _) (AstTyString)]
    [(AstLitUnit) (AstTyUnit)]))

(define (ctfe-expr-list-append [left : AstExprList] [right : AstExprList]) : AstExprList
  (match left
    [(AstExprNil) right]
    [(AstExprCons head rest)
      (let
        [rest-list : AstExprList (box-get rest)]
        (ast-expr-cons head (ctfe-expr-list-append rest-list right)))]))

(define (ctfe-quote-if-type
  [cond-ty : AstType]
  [then-ty : AstType]
  [else-ty : AstType]) : AstType
  (if (and (ctfe-type-eq cond-ty (AstTyBool)) (ctfe-type-eq then-ty else-ty))
    then-ty
    (AstTyExpr)))

(define (ctfe-eval-unquote-expr
  [inner : AstExpr]
  [origin : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfeQuoteExpr
  (match (compiler-ctfe-eval inner env fuel)
    [(OkCtfe value next-fuel)
      (match value
        [(CtfeExpr node ty) (OkCtfeQuoteExpr node ty next-fuel)]
        [(CtfeType ty)
          (OkCtfeQuoteExpr (ctfe-type-to-expr ty env) (AstTyExpr) next-fuel)]
        [_
          (ErrCtfeQuoteExpr
            (ctfe-diagnostic-at-expr origin "unquote expects Expr"))])]
    [(ErrCtfe diag) (ErrCtfeQuoteExpr diag)]))

(define (ctfe-eval-unquote-splice
  [inner : AstExpr]
  [origin : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfeQuoteExprList
  (match (compiler-ctfe-eval inner env fuel)
    [(OkCtfe value next-fuel)
      (match value
        [(CtfeExprList exprs) (OkCtfeQuoteExprList exprs next-fuel)]
        [_
          (ErrCtfeQuoteExprList
            (ctfe-diagnostic-at-expr origin "unquote-splicing expects ExprList"))])]
    [(ErrCtfe diag) (ErrCtfeQuoteExprList diag)]))

(define (ctfe-type-name-to-type [name : String]) : AstType
  (cond
    [(string.string-eq name "i64") (AstTyI64)]
    [(string.string-eq name "i32") (AstTyI32)]
    [(string.string-eq name "i16") (AstTyI16)]
    [(string.string-eq name "i8") (AstTyI8)]
    [(string.string-eq name "u64") (AstTyU64)]
    [(string.string-eq name "u32") (AstTyU32)]
    [(string.string-eq name "u16") (AstTyU16)]
    [(string.string-eq name "u8") (AstTyU8)]
    [(string.string-eq name "f64") (AstTyF64)]
    [(string.string-eq name "f32") (AstTyF32)]
    [(string.string-eq name "bool") (AstTyBool)]
    [(string.string-eq name "char") (AstTyChar)]
    [(string.string-eq name "String") (AstTyString)]
    [(string.string-eq name "str") (AstTyStr)]
    [(string.string-eq name "bytes") (AstTyBytes)]
    [(string.string-eq name "unit") (AstTyUnit)]
    [(string.string-eq name "never") (AstTyNever)]
    [(string.string-eq name "Expr") (AstTyExpr)]
    [(string.string-eq name "ExprList") (AstTyExprList)]
    [else (AstTyVar (intern name))]))

(define (ctfe-internal-resolved-struct-type-marker) : String
  "__typelisp internal resolved struct type")

(define (ctfe-internal-resolved-enum-type-marker) : String
  "__typelisp internal resolved enum type")

(define (ctfe-type-syntax-name [name : String] [env : CtfeEnv]) : i64
  (ctfe-ast-push env (AstExprVar (intern name))))

(define (ctfe-type-syntax-string [value : String] [env : CtfeEnv]) : i64
  (ctfe-ast-push env (AstExprLiteral (AstLitString value))))

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

(define (ctfe-type-list-to-expr-list [types : AstTypeList] [env : CtfeEnv]) : AstExprList
  (match types
    [(AstTypeNil) AstExprNil]
    [(AstTypeCons head rest)
      (ast-expr-cons
        (ctfe-type-to-expr (ctfe-ty-get env head) env)
        (ctfe-type-list-to-expr-list (box-get rest) env))]))

(define (ctfe-lifetime-list-to-expr-list
  [lifetimes : AstLifetimeList]
  [env : CtfeEnv]) : AstExprList
  (match lifetimes
    [(AstLifetimeNil) AstExprNil]
    [(AstLifetimeCons name rest)
      (ast-expr-cons
        (ctfe-type-syntax-name name env)
        (ctfe-lifetime-list-to-expr-list (box-get rest) env))]))

(define (ctfe-func-type-to-expr-list
  [args : AstTypeList]
  [ret : AstType]
  [env : CtfeEnv]) : AstExprList
  (match args
    [(AstTypeNil) (ast-expr-cons (ctfe-type-to-expr ret env) AstExprNil)]
    [(AstTypeCons head rest)
      (ast-expr-cons
        (ctfe-type-to-expr (ctfe-ty-get env head) env)
        (ctfe-func-type-to-expr-list (box-get rest) ret env))]))

(define (ctfe-type-to-expr [ty : AstType] [env : CtfeEnv]) : i64
  (match ty
    [(AstTyI64) (ctfe-type-syntax-name "i64" env)]
    [(AstTyI32) (ctfe-type-syntax-name "i32" env)]
    [(AstTyI16) (ctfe-type-syntax-name "i16" env)]
    [(AstTyI8) (ctfe-type-syntax-name "i8" env)]
    [(AstTyU64) (ctfe-type-syntax-name "u64" env)]
    [(AstTyU32) (ctfe-type-syntax-name "u32" env)]
    [(AstTyU16) (ctfe-type-syntax-name "u16" env)]
    [(AstTyU8) (ctfe-type-syntax-name "u8" env)]
    [(AstTyF64) (ctfe-type-syntax-name "f64" env)]
    [(AstTyF32) (ctfe-type-syntax-name "f32" env)]
    [(AstTyBool) (ctfe-type-syntax-name "bool" env)]
    [(AstTyChar) (ctfe-type-syntax-name "char" env)]
    [(AstTyString) (ctfe-type-syntax-name "String" env)]
    [(AstTyStr) (ctfe-type-syntax-name "str" env)]
    [(AstTyBytes) (ctfe-type-syntax-name "bytes" env)]
    [(AstTyUnit) (ctfe-type-syntax-name "unit" env)]
    [(AstTyNever) (ctfe-type-syntax-name "never" env)]
    [(AstTyExpr) (ctfe-type-syntax-name "Expr" env)]
    [(AstTyExprList) (ctfe-type-syntax-name "ExprList" env)]
    [(AstTyFunc args ret)
      (ctfe-type-syntax-call
        "->"
        (ctfe-func-type-to-expr-list (box-get args) (ctfe-ty-get env ret) env)
        env)]
    [(AstTyTuple elems)
      (ctfe-type-syntax-call
        "Tuple"
        (ctfe-type-list-to-expr-list (box-get elems) env)
        env)]
    [(AstTyArray elem count)
      (ctfe-type-syntax-call
        "Array"
        (ast-expr-cons
          (ctfe-type-to-expr (ctfe-ty-get env elem) env)
          (ast-expr-cons
            (ctfe-ast-push env (AstExprLiteral (ast-lit-int count)))
            AstExprNil))
        env)]
    [(AstTyDynArray elem)
      (ctfe-type-syntax-call
        "Array"
        (ast-expr-cons
          (ctfe-type-to-expr (ctfe-ty-get env elem) env)
          AstExprNil)
        env)]
    [(AstTyBox elem)
      (ctfe-type-syntax-call
        "Box"
        (ast-expr-cons
          (ctfe-type-to-expr (ctfe-ty-get env elem) env)
          AstExprNil)
        env)]
    [(AstTyPtr elem)
      (ctfe-type-syntax-call
        "Ptr"
        (ast-expr-cons
          (ctfe-type-to-expr (ctfe-ty-get env elem) env)
          AstExprNil)
        env)]
    [(AstTyMutPtr elem)
      (ctfe-type-syntax-call
        "MutPtr"
        (ast-expr-cons
          (ctfe-type-to-expr (ctfe-ty-get env elem) env)
          AstExprNil)
        env)]
    [(AstTyRef region elem)
      (ctfe-type-syntax-call
        "&"
        (ast-expr-cons
          (ctfe-type-syntax-name region env)
          (ast-expr-cons
            (ctfe-type-to-expr (ctfe-ty-get env elem) env)
            AstExprNil))
        env)]
    [(AstTyMutRef region elem)
      (ctfe-type-syntax-call
        "&mut"
        (ast-expr-cons
          (ctfe-type-syntax-name region env)
          (ast-expr-cons
            (ctfe-type-to-expr (ctfe-ty-get env elem) env)
            AstExprNil))
        env)]
    [(AstTyRegion region elem)
      (ctfe-type-syntax-call
        "in"
        (ast-expr-cons
          (ctfe-type-syntax-name region env)
          (ast-expr-cons
            (ctfe-type-to-expr (ctfe-ty-get env elem) env)
            AstExprNil))
        env)]
    [(AstTyEnum name)
      (ctfe-resolved-nominal-type-to-expr
        (ctfe-internal-resolved-enum-type-marker)
        (intern-str name)
        AstLifetimeNil
        env)]
    [(AstTyEnumArgs name lifetimes)
      (ctfe-resolved-nominal-type-to-expr
        (ctfe-internal-resolved-enum-type-marker)
        (intern-str name)
        (box-get lifetimes)
        env)]
    [(AstTyStruct name)
      (ctfe-resolved-nominal-type-to-expr
        (ctfe-internal-resolved-struct-type-marker)
        (intern-str name)
        AstLifetimeNil
        env)]
    [(AstTyStructArgs name lifetimes)
      (ctfe-resolved-nominal-type-to-expr
        (ctfe-internal-resolved-struct-type-marker)
        (intern-str name)
        (box-get lifetimes)
        env)]
    [(AstTyVar name) (ctfe-type-syntax-name (intern-str name) env)]
    [(AstTyVarArgs name lifetimes)
      (ctfe-type-syntax-call
        (intern-str name)
        (ctfe-lifetime-list-to-expr-list (box-get lifetimes) env)
        env)]))

(define (ctfe-type-expr-error [origin : AstExpr]) : ResultCtfeQuoteType
  (ErrCtfeQuoteType
    (ctfe-diagnostic-at-expr origin "type unquote expects a type expression")))

(define (ctfe-expr-list-to-type-list
  [exprs : AstExprList]
  [origin : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfeQuoteTypeList
  (match exprs
    [(AstExprNil) (OkCtfeQuoteTypeList AstTypeNil fuel)]
    [(AstExprCons head rest)
      (let
        [head-expr : AstExpr (ctfe-ast-get env head)]
        [rest : AstExprList (box-get rest)]
        (match (ctfe-expr-to-type head-expr origin env fuel)
          [(OkCtfeQuoteType head-ty head-fuel)
            (match (ctfe-expr-list-to-type-list rest origin env head-fuel)
              [(OkCtfeQuoteTypeList tail tail-fuel)
                (OkCtfeQuoteTypeList
                  (ast-type-cons-with-pools (ctfe-env-pools env) head-ty tail)
                  tail-fuel)]
              [(ErrCtfeQuoteTypeList diag) (ErrCtfeQuoteTypeList diag)])]
          [(ErrCtfeQuoteType diag) (ErrCtfeQuoteTypeList diag)]))]))

(define (ctfe-expr-unary-type
  [name : String]
  [args : AstExprList]
  [origin : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfeQuoteType
  (match args
    [(AstExprCons elem rest)
      (let
        [elem-expr : AstExpr (ctfe-ast-get env elem)]
        [rest : AstExprList (box-get rest)]
        (match rest
          [(AstExprNil)
            (match (ctfe-expr-to-type elem-expr origin env fuel)
              [(OkCtfeQuoteType elem-ty next-fuel)
                (OkCtfeQuoteType
                  (cond
                    [(string.string-eq name "Array")
                      (ast-ty-dyn-array-with-pools (ctfe-env-pools env) elem-ty)]
                    [(string.string-eq name "Box")
                      (ast-ty-box-with-pools (ctfe-env-pools env) elem-ty)]
                    [(string.string-eq name "Ptr")
                      (ast-ty-ptr-with-pools (ctfe-env-pools env) elem-ty)]
                    [(string.string-eq name "MutPtr")
                      (ast-ty-mut-ptr-with-pools (ctfe-env-pools env) elem-ty)]
                    [else elem-ty])
                  next-fuel)]
              [(ErrCtfeQuoteType diag) (ErrCtfeQuoteType diag)])]
          [_ (ctfe-type-expr-error origin)]))]
    [_ (ctfe-type-expr-error origin)]))

(define (ctfe-expr-array-type
  [args : AstExprList]
  [origin : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfeQuoteType
  (match args
    [(AstExprCons elem tail)
      (let
        [elem-expr : AstExpr (ctfe-ast-get env elem)]
        [tail : AstExprList (box-get tail)]
        (match (ctfe-expr-to-type elem-expr origin env fuel)
          [(OkCtfeQuoteType elem-ty elem-fuel)
            (match tail
              [(AstExprNil)
                (OkCtfeQuoteType
                  (ast-ty-dyn-array-with-pools (ctfe-env-pools env) elem-ty)
                  elem-fuel)]
              [(AstExprCons len-node end)
                (let
                  [len-expr : AstExpr (ctfe-ast-get env len-node)]
                  [end : AstExprList (box-get end)]
                  (match end
                    [(AstExprNil)
                      (match (ctfe-expr-unspan env len-expr)
                        [(AstExprLiteral (AstLitInt count _))
                          (OkCtfeQuoteType
                            (ast-ty-array-with-pools
                              (ctfe-env-pools env)
                              elem-ty
                              count)
                            elem-fuel)]
                        [_ (ctfe-type-expr-error origin)])]
                    [_ (ctfe-type-expr-error origin)]))]
              [_ (ctfe-type-expr-error origin)])]
          [(ErrCtfeQuoteType diag) (ErrCtfeQuoteType diag)]))]
    [_ (ctfe-type-expr-error origin)]))

(define (ctfe-expr-func-type
  [args : AstExprList]
  [origin : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfeQuoteType
  (match args
    [(AstExprCons head rest-box)
      (let
        [head-expr : AstExpr (ctfe-ast-get env head)]
        [rest : AstExprList (box-get rest-box)]
        (match rest
          [(AstExprNil)
            (match (ctfe-expr-to-type head-expr origin env fuel)
              [(OkCtfeQuoteType ret-ty next-fuel)
                (OkCtfeQuoteType
                  (ast-ty-func-with-pools
                    (ctfe-env-pools env)
                    AstTypeNil
                    ret-ty)
                  next-fuel)]
              [(ErrCtfeQuoteType diag) (ErrCtfeQuoteType diag)])]
          [_
            (match (ctfe-expr-to-type head-expr origin env fuel)
              [(OkCtfeQuoteType arg-ty arg-fuel)
                (match (ctfe-expr-func-type rest origin env arg-fuel)
                  [(OkCtfeQuoteType tail-fn next-fuel)
                    (match tail-fn
                      [(AstTyFunc tail-args ret)
                        (OkCtfeQuoteType
                          (ast-ty-func-with-pools
                            (ctfe-env-pools env)
                            (ast-type-cons-with-pools
                              (ctfe-env-pools env)
                              arg-ty
                              (box-get tail-args))
                            (ctfe-ty-get env ret))
                          next-fuel)]
                      [_ (ctfe-type-expr-error origin)])]
                  [(ErrCtfeQuoteType diag) (ErrCtfeQuoteType diag)])]
              [(ErrCtfeQuoteType diag) (ErrCtfeQuoteType diag)])]))]
    [_ (ctfe-type-expr-error origin)]))

(define (ctfe-expr-reference-type
  [args : AstExprList]
  [origin : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]
  [mutable : bool]) : ResultCtfeQuoteType
  (match args
    [(AstExprCons region-node tail)
      (let
        [region-expr : AstExpr (ctfe-ast-get env region-node)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprCons inner-node end)
            (let
              [inner-expr : AstExpr (ctfe-ast-get env inner-node)]
              [end : AstExprList (box-get end)]
              (match end
                [(AstExprNil)
                  (match (ctfe-expr-unspan env region-expr)
                    [(AstExprVar region)
                      (match (ctfe-expr-to-type inner-expr origin env fuel)
                        [(OkCtfeQuoteType inner-ty next-fuel)
                          (OkCtfeQuoteType
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
                        [(ErrCtfeQuoteType diag) (ErrCtfeQuoteType diag)])]
                    [_ (ctfe-type-expr-error origin)])]
                [_ (ctfe-type-expr-error origin)]))]
          [_ (ctfe-type-expr-error origin)]))]
    [_ (ctfe-type-expr-error origin)]))

(define (ctfe-expr-region-type
  [args : AstExprList]
  [origin : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfeQuoteType
  (match args
    [(AstExprCons region-node tail)
      (let
        [region-expr : AstExpr (ctfe-ast-get env region-node)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprCons inner-node end)
            (let
              [inner-expr : AstExpr (ctfe-ast-get env inner-node)]
              [end : AstExprList (box-get end)]
              (match end
                [(AstExprNil)
                  (match (ctfe-expr-unspan env region-expr)
                    [(AstExprVar region)
                      (match (ctfe-expr-to-type inner-expr origin env fuel)
                        [(OkCtfeQuoteType inner-ty next-fuel)
                          (OkCtfeQuoteType
                            (ast-ty-region-with-pools
                              (ctfe-env-pools env)
                              (intern-str region)
                              inner-ty)
                            next-fuel)]
                        [(ErrCtfeQuoteType diag) (ErrCtfeQuoteType diag)])]
                    [_ (ctfe-type-expr-error origin)])]
                [_ (ctfe-type-expr-error origin)]))]
          [_ (ctfe-type-expr-error origin)]))]
    [_ (ctfe-type-expr-error origin)]))

(define (ctfe-expr-list-to-lifetime-list
  [exprs : AstExprList]
  [env : CtfeEnv]
  [origin : AstExpr]) : ResultCtfeQuoteLifetimeList
  (match exprs
    [(AstExprNil) (OkCtfeQuoteLifetimeList AstLifetimeNil)]
    [(AstExprCons head rest)
      (let
        [head-expr : AstExpr (ctfe-ast-get env head)]
        [rest : AstExprList (box-get rest)]
        (match (ctfe-expr-unspan env head-expr)
          [(AstExprVar name)
            (match (ctfe-expr-list-to-lifetime-list rest env origin)
              [(OkCtfeQuoteLifetimeList tail)
                (OkCtfeQuoteLifetimeList
                  (ast-lifetime-cons (intern-str name) tail))]
              [(ErrCtfeQuoteLifetimeList diag) (ErrCtfeQuoteLifetimeList diag)])]
          [_
            (ErrCtfeQuoteLifetimeList
              (ctfe-diagnostic-at-expr
                origin
                "type unquote expects a type expression"))]))]))

(define (ctfe-expr-resolved-nominal-type
  [args : AstExprList]
  [origin : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]
  [is-struct : bool]) : ResultCtfeQuoteType
  (match args
    [(AstExprCons name-node lifetime-rest)
      (let
        [name-expr : AstExpr (ctfe-ast-get env name-node)]
        [lifetime-exprs : AstExprList (box-get lifetime-rest)]
        (match (ctfe-expr-unspan env name-expr)
          [(AstExprLiteral (AstLitString name))
            (match (ctfe-expr-list-to-lifetime-list lifetime-exprs env origin)
              [(OkCtfeQuoteLifetimeList lifetimes)
                (OkCtfeQuoteType
                  (if is-struct
                    (match lifetimes
                      [(AstLifetimeNil) (AstTyStruct (intern name))]
                      [_ (ast-ty-struct-args (intern name) lifetimes)])
                    (match lifetimes
                      [(AstLifetimeNil) (AstTyEnum (intern name))]
                      [_ (ast-ty-enum-args (intern name) lifetimes)]))
                  fuel)]
              [(ErrCtfeQuoteLifetimeList diag) (ErrCtfeQuoteType diag)])]
          [_ (ctfe-type-expr-error origin)]))]
    [_ (ctfe-type-expr-error origin)]))

(define (ctfe-expr-to-type
  [expr : AstExpr]
  [origin : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfeQuoteType
  (match (ctfe-expr-unspan env expr)
    [(AstExprTypeLiteral ty) (OkCtfeQuoteType ty fuel)]
    [(AstExprVar name)
      (OkCtfeQuoteType (ctfe-type-name-to-type (intern-str name)) fuel)]
    [(AstExprCall func-box args)
      (let
        [func : AstExpr (ctfe-ast-get env func-box)]
        (match (ctfe-expr-unspan env func)
          [(AstExprVar name)
            (let
              [head : String (intern-str name)]
              (cond
                [(string.string-eq
                    head
                    (ctfe-internal-resolved-struct-type-marker))
                  (ctfe-expr-resolved-nominal-type args origin env fuel true)]
                [(string.string-eq
                    head
                    (ctfe-internal-resolved-enum-type-marker))
                  (ctfe-expr-resolved-nominal-type args origin env fuel false)]
                [(string.string-eq head "->")
                  (ctfe-expr-func-type args origin env fuel)]
                [(string.string-eq head "Array")
                  (ctfe-expr-array-type args origin env fuel)]
                [(or
                    (string.string-eq head "Box")
                    (string.string-eq head "Ptr")
                    (string.string-eq head "MutPtr"))
                  (ctfe-expr-unary-type head args origin env fuel)]
                [(string.string-eq head "&")
                  (ctfe-expr-reference-type args origin env fuel false)]
                [(string.string-eq head "&mut")
                  (ctfe-expr-reference-type args origin env fuel true)]
                [(string.string-eq head "in")
                  (ctfe-expr-region-type args origin env fuel)]
                [(string.string-eq head "Tuple")
                  (match (ctfe-expr-list-to-type-list args origin env fuel)
                    [(OkCtfeQuoteTypeList elems next-fuel)
                      (OkCtfeQuoteType (ast-ty-tuple elems) next-fuel)]
                    [(ErrCtfeQuoteTypeList diag) (ErrCtfeQuoteType diag)])]
                [else (ctfe-type-expr-error origin)]))]
          [_ (ctfe-type-expr-error origin)]))]
    [_ (ctfe-type-expr-error origin)]))

(define (ctfe-quote-type-unquote
  [lifetimes : AstLifetimeList]
  [env : CtfeEnv]
  [origin : AstExpr]
  [fuel : i64]) : ResultCtfeQuoteType
  (match lifetimes
    [(AstLifetimeCons name rest)
      (match (box-get rest)
        [(AstLifetimeNil)
          (match (ctfe-env-lookup env name)
            [(CtfeSomeValue value)
              (match value
                [(CtfeType ty)
                  (OkCtfeQuoteType
                    (ctfe-reflect-resolve-type-with-pools
                      (ctfe-env-pools env)
                      (ctfe-env-reflections env)
                      ty)
                    fuel)]
                [(CtfeExpr node _)
                  (let
                    [node-expr : AstExpr (ctfe-ast-get env node)]
                    (ctfe-expr-to-type node-expr origin env fuel))]
                [_
                  (ErrCtfeQuoteType
                    (ctfe-diagnostic-at-expr
                      origin
                      "type unquote expects a type value"))])]
            [(CtfeNoValue)
              (ErrCtfeQuoteType
                (ctfe-diagnostic-at-expr
                  origin
                  "type unquote references an unbound type parameter"))])]
        [_
          (ErrCtfeQuoteType
            (ctfe-diagnostic-at-expr
              origin
              "type unquote expects exactly one type parameter"))])]
    [_ (ctfe-type-expr-error origin)]))

(define (ctfe-quote-type-list
  [types : AstTypeList]
  [env : CtfeEnv]
  [origin : AstExpr]
  [fuel : i64]) : ResultCtfeQuoteTypeList
  (match types
    [(AstTypeNil) (OkCtfeQuoteTypeList AstTypeNil fuel)]
    [(AstTypeCons head rest)
      (let
        [head : AstType (ctfe-ty-get env head)]
        [rest : AstTypeList (box-get rest)]
        (match (ctfe-quote-type head env origin fuel)
          [(OkCtfeQuoteType quoted-head head-fuel)
            (match (ctfe-quote-type-list rest env origin head-fuel)
              [(OkCtfeQuoteTypeList quoted-rest rest-fuel)
                (OkCtfeQuoteTypeList
                  (ast-type-cons-with-pools
                    (ctfe-env-pools env)
                    quoted-head
                    quoted-rest)
                  rest-fuel)]
              [(ErrCtfeQuoteTypeList diag) (ErrCtfeQuoteTypeList diag)])]
          [(ErrCtfeQuoteType diag) (ErrCtfeQuoteTypeList diag)]))]))

(define (ctfe-quote-type
  [ty : AstType]
  [env : CtfeEnv]
  [origin : AstExpr]
  [fuel : i64]) : ResultCtfeQuoteType
  (match ty
    [(AstTyFunc args ret)
      (match (ctfe-quote-type-list (box-get args) env origin fuel)
        [(OkCtfeQuoteTypeList quoted-args args-fuel)
          (match (ctfe-quote-type (ctfe-ty-get env ret) env origin args-fuel)
            [(OkCtfeQuoteType quoted-ret ret-fuel)
              (OkCtfeQuoteType
                (ast-ty-func-with-pools
                  (ctfe-env-pools env)
                  quoted-args
                  quoted-ret)
                ret-fuel)]
            [(ErrCtfeQuoteType diag) (ErrCtfeQuoteType diag)])]
        [(ErrCtfeQuoteTypeList diag) (ErrCtfeQuoteType diag)])]
    [(AstTyTuple elems)
      (match (ctfe-quote-type-list (box-get elems) env origin fuel)
        [(OkCtfeQuoteTypeList quoted next-fuel)
          (OkCtfeQuoteType (ast-ty-tuple quoted) next-fuel)]
        [(ErrCtfeQuoteTypeList diag) (ErrCtfeQuoteType diag)])]
    [(AstTyArray elem count)
      (match (ctfe-quote-type (ctfe-ty-get env elem) env origin fuel)
        [(OkCtfeQuoteType quoted next-fuel)
          (OkCtfeQuoteType
            (ast-ty-array-with-pools (ctfe-env-pools env) quoted count)
            next-fuel)]
        [(ErrCtfeQuoteType diag) (ErrCtfeQuoteType diag)])]
    [(AstTyDynArray elem)
      (match (ctfe-quote-type (ctfe-ty-get env elem) env origin fuel)
        [(OkCtfeQuoteType quoted next-fuel)
          (OkCtfeQuoteType
            (ast-ty-dyn-array-with-pools (ctfe-env-pools env) quoted)
            next-fuel)]
        [(ErrCtfeQuoteType diag) (ErrCtfeQuoteType diag)])]
    [(AstTyBox elem)
      (match (ctfe-quote-type (ctfe-ty-get env elem) env origin fuel)
        [(OkCtfeQuoteType quoted next-fuel)
          (OkCtfeQuoteType
            (ast-ty-box-with-pools (ctfe-env-pools env) quoted)
            next-fuel)]
        [(ErrCtfeQuoteType diag) (ErrCtfeQuoteType diag)])]
    [(AstTyPtr elem)
      (match (ctfe-quote-type (ctfe-ty-get env elem) env origin fuel)
        [(OkCtfeQuoteType quoted next-fuel)
          (OkCtfeQuoteType
            (ast-ty-ptr-with-pools (ctfe-env-pools env) quoted)
            next-fuel)]
        [(ErrCtfeQuoteType diag) (ErrCtfeQuoteType diag)])]
    [(AstTyMutPtr elem)
      (match (ctfe-quote-type (ctfe-ty-get env elem) env origin fuel)
        [(OkCtfeQuoteType quoted next-fuel)
          (OkCtfeQuoteType
            (ast-ty-mut-ptr-with-pools (ctfe-env-pools env) quoted)
            next-fuel)]
        [(ErrCtfeQuoteType diag) (ErrCtfeQuoteType diag)])]
    [(AstTyRef region inner)
      (match (ctfe-quote-type (ctfe-ty-get env inner) env origin fuel)
        [(OkCtfeQuoteType quoted next-fuel)
          (OkCtfeQuoteType
            (ast-ty-ref-with-pools (ctfe-env-pools env) region quoted)
            next-fuel)]
        [(ErrCtfeQuoteType diag) (ErrCtfeQuoteType diag)])]
    [(AstTyMutRef region inner)
      (match (ctfe-quote-type (ctfe-ty-get env inner) env origin fuel)
        [(OkCtfeQuoteType quoted next-fuel)
          (OkCtfeQuoteType
            (ast-ty-mut-ref-with-pools (ctfe-env-pools env) region quoted)
            next-fuel)]
        [(ErrCtfeQuoteType diag) (ErrCtfeQuoteType diag)])]
    [(AstTyRegion region inner)
      (match (ctfe-quote-type (ctfe-ty-get env inner) env origin fuel)
        [(OkCtfeQuoteType quoted next-fuel)
          (OkCtfeQuoteType
            (ast-ty-region-with-pools (ctfe-env-pools env) region quoted)
            next-fuel)]
        [(ErrCtfeQuoteType diag) (ErrCtfeQuoteType diag)])]
    [(AstTyVarArgs name lifetimes)
      (if (= name (intern "unquote"))
        (ctfe-quote-type-unquote (box-get lifetimes) env origin fuel)
        (OkCtfeQuoteType ty fuel))]
    [_ (OkCtfeQuoteType ty fuel)]))

(define (ctfe-quote-maybe-type
  [maybe-ty : AstMaybeType]
  [env : CtfeEnv]
  [origin : AstExpr]
  [fuel : i64]) : ResultCtfeQuoteMaybeType
  (match maybe-ty
    [(AstNoType) (OkCtfeQuoteMaybeType AstNoType fuel)]
    [(AstSomeType ty)
      (match (ctfe-quote-type ty env origin fuel)
        [(OkCtfeQuoteType quoted next-fuel)
          (OkCtfeQuoteMaybeType (AstSomeType quoted) next-fuel)]
        [(ErrCtfeQuoteType diag) (ErrCtfeQuoteMaybeType diag)])]))

(define (ctfe-quote-expr-list
  [exprs : AstExprList]
  [env : CtfeEnv]
  [fuel : i64]
  [quasiquote : bool]) : ResultCtfeQuoteExprList
  (match exprs
    [(AstExprNil) (OkCtfeQuoteExprList AstExprNil fuel)]
    [(AstExprCons head rest)
      (let
        [head : AstExpr (ctfe-ast-get env head)]
        [rest : AstExprList (box-get rest)]
        (match (ctfe-expr-unspan env head)
          [(AstExprUnquoteSplicing inner-box)
            (let
              [inner : AstExpr (ctfe-ast-get env inner-box)]
              (if quasiquote
                (match (ctfe-eval-unquote-splice inner head env fuel)
                  [(OkCtfeQuoteExprList splice splice-fuel)
                    (match (ctfe-quote-expr-list
                      rest
                      env
                      splice-fuel
                      quasiquote)
                      [(OkCtfeQuoteExprList quoted-rest rest-fuel)
                        (OkCtfeQuoteExprList
                          (ctfe-expr-list-append splice quoted-rest)
                          rest-fuel)]
                      [(ErrCtfeQuoteExprList diag) (ErrCtfeQuoteExprList diag)])]
                  [(ErrCtfeQuoteExprList diag) (ErrCtfeQuoteExprList diag)])
                (match (ctfe-quote-expr head env fuel quasiquote)
                  [(OkCtfeQuoteExpr quoted-head _ head-fuel)
                    (match (ctfe-quote-expr-list rest env head-fuel quasiquote)
                      [(OkCtfeQuoteExprList quoted-rest rest-fuel)
                        (OkCtfeQuoteExprList
                          (ast-expr-cons quoted-head quoted-rest)
                          rest-fuel)]
                      [(ErrCtfeQuoteExprList diag) (ErrCtfeQuoteExprList diag)])]
                  [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExprList diag)])))]
          [_
            (match (ctfe-quote-expr head env fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-head _ head-fuel)
                (match (ctfe-quote-expr-list rest env head-fuel quasiquote)
                  [(OkCtfeQuoteExprList quoted-rest rest-fuel)
                    (OkCtfeQuoteExprList
                      (ast-expr-cons quoted-head quoted-rest)
                      rest-fuel)]
                  [(ErrCtfeQuoteExprList diag) (ErrCtfeQuoteExprList diag)])]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExprList diag)])]))]))

(define (ctfe-quote-param-list [params : AstParamList] [env : CtfeEnv]) : AstParamList
  (match params
    [(AstParamNil) AstParamNil]
    [(AstParamCons param rest)
      (let
        [rest : AstParamList (box-get rest)]
        (match param
          [(AstParam name ty comptime?)
            (ast-param-cons
              (AstParam (ctfe-quote-name-id env name) ty comptime?)
              (ctfe-quote-param-list rest env))]))]))

(define (ctfe-quote-pattern-list [patterns : AstPatternList] [env : CtfeEnv]) : AstPatternList
  (match patterns
    [(AstPatternNil) AstPatternNil]
    [(AstPatternCons pattern rest)
      (let
        [pattern : AstPattern (box-get pattern)]
        [rest : AstPatternList (box-get rest)]
        (ast-pattern-cons
          (ctfe-quote-pattern pattern env)
          (ctfe-quote-pattern-list rest env)))]))

(define (ctfe-quote-pattern [pattern : AstPattern] [env : CtfeEnv]) : AstPattern
  (match pattern
    [(AstPatVar name maybe-ty)
      (AstPatVar (ctfe-quote-name-id env name) maybe-ty)]
    [(AstPatTuple patterns-box)
      (let
        [patterns : AstPatternList (box-get patterns-box)]
        (ast-pat-tuple (ctfe-quote-pattern-list patterns env)))]
    [(AstPatWildcard) AstPatWildcard]
    [(AstPatBinding name) (AstPatBinding (ctfe-quote-name-id env name))]
    [(AstPatVariant name args-box)
      (let
        [args : AstPatternList (box-get args-box)]
        (ast-pat-variant-id name (ctfe-quote-pattern-list args env)))]
    [(AstPatLiteral lit) (AstPatLiteral lit)]))

(define (ctfe-quote-let-binding-list
  [bindings : AstLetBindingList]
  [env : CtfeEnv]
  [fuel : i64]
  [quasiquote : bool]) : ResultCtfeQuoteLetBindings
  (match bindings
    [(AstLetBindingNil) (OkCtfeQuoteLetBindings AstLetBindingNil fuel)]
    [(AstLetBindingCons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding name maybe-ty init-box)
            (let
              [init : AstExpr (ctfe-ast-get env init-box)]
              (match (ctfe-quote-maybe-type maybe-ty env init fuel)
                [(OkCtfeQuoteMaybeType quoted-ty type-fuel)
                  (match (ctfe-quote-expr init env type-fuel quasiquote)
                    [(OkCtfeQuoteExpr quoted-init _ init-fuel)
                      (match (ctfe-quote-let-binding-list
                        rest
                        env
                        init-fuel
                        quasiquote)
                        [(OkCtfeQuoteLetBindings quoted-rest rest-fuel)
                          (OkCtfeQuoteLetBindings
                            (ast-let-binding-cons
                              (ast-let-binding-id
                                (ctfe-quote-name-id env name)
                                quoted-ty
                                quoted-init)
                              quoted-rest)
                            rest-fuel)]
                        [(ErrCtfeQuoteLetBindings diag)
                          (ErrCtfeQuoteLetBindings diag)])]
                    [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteLetBindings diag)])]
                [(ErrCtfeQuoteMaybeType diag) (ErrCtfeQuoteLetBindings diag)]))]))]))

(define (ctfe-quote-resource-binding-list
  [bindings : AstResourceBindingList]
  [env : CtfeEnv]
  [fuel : i64]
  [quasiquote : bool]) : ResultCtfeQuoteResourceBindings
  (match bindings
    [(AstResourceBindingNil)
      (OkCtfeQuoteResourceBindings AstResourceBindingNil fuel)]
    [(AstResourceBindingCons binding rest)
      (let
        [rest : AstResourceBindingList (box-get rest)]
        (match binding
          [(AstResourceBinding name init-box cleanup-box)
            (let
              [init : AstExpr (ctfe-ast-get env init-box)]
              [cleanup : AstExpr (ctfe-ast-get env cleanup-box)]
              (match (ctfe-quote-expr init env fuel quasiquote)
                [(OkCtfeQuoteExpr quoted-init _ init-fuel)
                  (match (ctfe-quote-expr cleanup env init-fuel quasiquote)
                    [(OkCtfeQuoteExpr quoted-cleanup _ cleanup-fuel)
                      (match (ctfe-quote-resource-binding-list
                        rest
                        env
                        cleanup-fuel
                        quasiquote)
                        [(OkCtfeQuoteResourceBindings quoted-rest rest-fuel)
                          (OkCtfeQuoteResourceBindings
                            (ast-resource-binding-cons
                              (ast-resource-binding-id
                                (ctfe-quote-name-id env name)
                                quoted-init
                                quoted-cleanup)
                              quoted-rest)
                            rest-fuel)]
                        [(ErrCtfeQuoteResourceBindings diag)
                          (ErrCtfeQuoteResourceBindings diag)])]
                    [(ErrCtfeQuoteExpr diag)
                      (ErrCtfeQuoteResourceBindings diag)])]
                [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteResourceBindings diag)]))]))]))

(define (ctfe-quote-arm-list
  [arms : AstMatchArmList]
  [env : CtfeEnv]
  [fuel : i64]
  [quasiquote : bool]) : ResultCtfeQuoteArms
  (match arms
    [(AstMatchArmNil) (OkCtfeQuoteArms AstMatchArmNil fuel)]
    [(AstMatchArmCons arm rest)
      (let
        [rest : AstMatchArmList (box-get rest)]
        (match arm
          [(AstMatchArm pattern body-box)
            (let
              [body : AstExpr (ctfe-ast-get env body-box)]
              (match (ctfe-quote-expr body env fuel quasiquote)
                [(OkCtfeQuoteExpr quoted-body _ body-fuel)
                  (match (ctfe-quote-arm-list rest env body-fuel quasiquote)
                    [(OkCtfeQuoteArms quoted-rest rest-fuel)
                      (OkCtfeQuoteArms
                        (ast-match-arm-cons
                          (ast-match-arm
                            (ctfe-quote-pattern pattern env)
                            quoted-body)
                          quoted-rest)
                        rest-fuel)]
                    [(ErrCtfeQuoteArms diag) (ErrCtfeQuoteArms diag)])]
                [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteArms diag)]))]))]))

(define (ctfe-quote-expr
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]
  [quasiquote : bool]) : ResultCtfeQuoteExpr
  (match expr
    [(AstExprSpanned inner-box span)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(OkCtfeQuoteExpr node ty next-fuel)
            (OkCtfeQuoteExpr
              (ast-expr-spanned-with-pools (ctfe-env-pools env) node span)
              ty
              next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprLiteral lit)
      (OkCtfeQuoteExpr
        (ctfe-ast-push env expr)
        (ctfe-quote-literal-type lit)
        fuel)]
    [(AstExprVar name)
      (OkCtfeQuoteExpr
        (ctfe-ast-push
          env
          (AstExprVar (intern (ctfe-quote-name env (intern-str name)))))
        (AstTyExpr)
        fuel)]
    [(AstExprBinary op left-box right-box)
      (let
        [left : AstExpr (ctfe-ast-get env left-box)]
        [right : AstExpr (ctfe-ast-get env right-box)]
        (match (ctfe-quote-expr left env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-left _ left-fuel)
            (match (ctfe-quote-expr right env left-fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-right _ right-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-binary-with-pools
                    (ctfe-env-pools env)
                    op
                    quoted-left
                    quoted-right)
                  (AstTyExpr)
                  right-fuel)]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprUnary op inner-box)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr
              (ast-expr-unary-with-pools (ctfe-env-pools env) op quoted)
              (AstTyExpr)
              next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprCall func-box args)
      (let
        [func : AstExpr (ctfe-ast-get env func-box)]
        (match (ctfe-quote-expr func env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-func _ func-fuel)
            (match (ctfe-quote-expr-list args env func-fuel quasiquote)
              [(OkCtfeQuoteExprList quoted-args args-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-call-with-pools
                    (ctfe-env-pools env)
                    quoted-func
                    quoted-args)
                  (AstTyExpr)
                  args-fuel)]
              [(ErrCtfeQuoteExprList diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprBracketClause items)
      (match (ctfe-quote-expr-list items env fuel quasiquote)
        [(OkCtfeQuoteExprList quoted-items next-fuel)
          (OkCtfeQuoteExpr
            (ast-expr-bracket-clause-with-pools
              (ctfe-env-pools env)
              quoted-items)
            (AstTyExpr)
            next-fuel)]
        [(ErrCtfeQuoteExprList diag) (ErrCtfeQuoteExpr diag)])]
    [(AstExprIf cond-box then-branch-box else-branch-box)
      (let
        [cond : AstExpr (ctfe-ast-get env cond-box)]
        [then-branch : AstExpr (ctfe-ast-get env then-branch-box)]
        [else-branch : AstExpr (ctfe-ast-get env else-branch-box)]
        (match (ctfe-quote-expr cond env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-cond cond-ty cond-fuel)
            (match (ctfe-quote-expr then-branch env cond-fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-then then-ty then-fuel)
                (match (ctfe-quote-expr else-branch env then-fuel quasiquote)
                  [(OkCtfeQuoteExpr quoted-else else-ty else-fuel)
                    (OkCtfeQuoteExpr
                      (ast-expr-if-with-pools
                        (ctfe-env-pools env)
                        quoted-cond
                        quoted-then
                        quoted-else)
                      (ctfe-quote-if-type cond-ty then-ty else-ty)
                      else-fuel)]
                  [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprLet let-box)
      (match (box-get let-box)
        [(AstLet bindings body-box)
          (let
            [body : AstExpr (ctfe-ast-get env body-box)]
            (match (ctfe-quote-let-binding-list bindings env fuel quasiquote)
              [(OkCtfeQuoteLetBindings quoted-bindings bindings-fuel)
                (match (ctfe-quote-expr body env bindings-fuel quasiquote)
                  [(OkCtfeQuoteExpr quoted-body body-ty body-fuel)
                    (OkCtfeQuoteExpr
                      (ast-expr-let-with-pools
                        (ctfe-env-pools env)
                        quoted-bindings
                        quoted-body)
                      body-ty
                      body-fuel)]
                  [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
              [(ErrCtfeQuoteLetBindings diag) (ErrCtfeQuoteExpr diag)]))])]
    [(AstExprLambda lambda-box)
      (match (box-get lambda-box)
        [(AstLambda params maybe-ret body-box)
          (let
            [body : AstExpr (ctfe-ast-get env body-box)]
            (match (ctfe-quote-expr body env fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-body _ next-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-lambda-with-pools
                    (ctfe-env-pools env)
                    (ctfe-quote-param-list params env)
                    maybe-ret
                    quoted-body)
                  (AstTyExpr)
                  next-fuel)]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))])]
    [(AstExprTuple exprs)
      (match (ctfe-quote-expr-list exprs env fuel quasiquote)
        [(OkCtfeQuoteExprList quoted next-fuel)
          (OkCtfeQuoteExpr
            (ctfe-ast-push env (AstExprTuple quoted))
            (AstTyExpr)
            next-fuel)]
        [(ErrCtfeQuoteExprList diag) (ErrCtfeQuoteExpr diag)])]
    [(AstExprArray exprs)
      (match (ctfe-quote-expr-list exprs env fuel quasiquote)
        [(OkCtfeQuoteExprList quoted next-fuel)
          (OkCtfeQuoteExpr
            (ctfe-ast-push env (AstExprArray quoted))
            (AstTyExpr)
            next-fuel)]
        [(ErrCtfeQuoteExprList diag) (ErrCtfeQuoteExpr diag)])]
    [(AstExprBegin exprs)
      (match (ctfe-quote-expr-list exprs env fuel quasiquote)
        [(OkCtfeQuoteExprList quoted next-fuel)
          (OkCtfeQuoteExpr
            (ctfe-ast-push env (AstExprBegin quoted))
            (AstTyExpr)
            next-fuel)]
        [(ErrCtfeQuoteExprList diag) (ErrCtfeQuoteExpr diag)])]
    [(AstExprUnsafe exprs)
      (match (ctfe-quote-expr-list exprs env fuel quasiquote)
        [(OkCtfeQuoteExprList quoted next-fuel)
          (OkCtfeQuoteExpr
            (ctfe-ast-push env (AstExprUnsafe quoted))
            (AstTyExpr)
            next-fuel)]
        [(ErrCtfeQuoteExprList diag) (ErrCtfeQuoteExpr diag)])]
    [(AstExprWhile cond-box body-box)
      (let
        [cond : AstExpr (ctfe-ast-get env cond-box)]
        [body : AstExpr (ctfe-ast-get env body-box)]
        (match (ctfe-quote-expr cond env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-cond _ cond-fuel)
            (match (ctfe-quote-expr body env cond-fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-body _ body-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-while-with-pools
                    (ctfe-env-pools env)
                    quoted-cond
                    quoted-body)
                  (AstTyExpr)
                  body-fuel)]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprSet name rhs-box)
      (let
        [rhs : AstExpr (ctfe-ast-get env rhs-box)]
        (match (ctfe-quote-expr rhs env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-rhs _ next-fuel)
            (OkCtfeQuoteExpr
              (ast-expr-set-id-with-pools
                (ctfe-env-pools env)
                (ctfe-quote-name-id env name)
                quoted-rhs)
              (AstTyExpr)
              next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprAnn inner-box ty)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ expr-fuel)
            (match (ctfe-quote-type ty env expr expr-fuel)
              [(OkCtfeQuoteType quoted-ty next-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-ann-with-pools
                    (ctfe-env-pools env)
                    quoted
                    quoted-ty)
                  quoted-ty
                  next-fuel)]
              [(ErrCtfeQuoteType diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprCast inner-box ty)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ expr-fuel)
            (match (ctfe-quote-type ty env expr expr-fuel)
              [(OkCtfeQuoteType quoted-ty next-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-cast-with-pools
                    (ctfe-env-pools env)
                    quoted
                    quoted-ty)
                  quoted-ty
                  next-fuel)]
              [(ErrCtfeQuoteType diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprTypeLiteral ty)
      (match (ctfe-quote-type ty env expr fuel)
        [(OkCtfeQuoteType quoted-ty next-fuel)
          (OkCtfeQuoteExpr
            (ctfe-ast-push env (AstExprTypeLiteral quoted-ty))
            (AstTyExpr)
            next-fuel)]
        [(ErrCtfeQuoteType diag) (ErrCtfeQuoteExpr diag)])]
    [(AstExprBorrow mutable lifetime place-box)
      (let
        [place : AstExpr (ctfe-ast-get env place-box)]
        (match (ctfe-quote-expr place env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-place _ next-fuel)
            (OkCtfeQuoteExpr
              (ast-expr-borrow-with-pools
                (ctfe-env-pools env)
                mutable
                lifetime
                quoted-place)
              (AstTyExpr)
              next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprMatch match-box)
      (match (box-get match-box)
        [(AstMatch scrut-box arms)
          (let
            [scrut : AstExpr (ctfe-ast-get env scrut-box)]
            (match (ctfe-quote-expr scrut env fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-scrut _ scrut-fuel)
                (match (ctfe-quote-arm-list arms env scrut-fuel quasiquote)
                  [(OkCtfeQuoteArms quoted-arms arms-fuel)
                    (OkCtfeQuoteExpr
                      (ast-expr-match-with-pools
                        (ctfe-env-pools env)
                        quoted-scrut
                        quoted-arms)
                      (AstTyExpr)
                      arms-fuel)]
                  [(ErrCtfeQuoteArms diag) (ErrCtfeQuoteExpr diag)])]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))])]
    [(AstExprForeach fe-box)
      (match (box-get fe-box)
        [(AstForeach index index-ty start-box end-box body-box)
          (let
            [start : AstExpr (ctfe-ast-get env start-box)]
            [end : AstExpr (ctfe-ast-get env end-box)]
            [body : AstExpr (ctfe-ast-get env body-box)]
            (match (ctfe-quote-expr start env fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-start _ start-fuel)
                (match (ctfe-quote-expr end env start-fuel quasiquote)
                  [(OkCtfeQuoteExpr quoted-end _ end-fuel)
                    (match (ctfe-quote-expr body env end-fuel quasiquote)
                      [(OkCtfeQuoteExpr quoted-body _ body-fuel)
                        (OkCtfeQuoteExpr
                          (ast-expr-foreach-id-with-pools
                            (ctfe-env-pools env)
                            (ctfe-quote-name-id env index)
                            index-ty
                            quoted-start
                            quoted-end
                            quoted-body)
                          (AstTyExpr)
                          body-fuel)]
                      [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
                  [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))])]
    [(AstExprSpmdReduce reduce-box)
      (match (box-get reduce-box)
        [(AstSpmdReduce op index index-ty start-box end-box init-box value-box)
          (let
            [start : AstExpr (ctfe-ast-get env start-box)]
            [end : AstExpr (ctfe-ast-get env end-box)]
            [init : AstExpr (ctfe-ast-get env init-box)]
            [value : AstExpr (ctfe-ast-get env value-box)]
            (match (ctfe-quote-expr start env fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-start _ start-fuel)
                (match (ctfe-quote-expr end env start-fuel quasiquote)
                  [(OkCtfeQuoteExpr quoted-end _ end-fuel)
                    (match (ctfe-quote-expr init env end-fuel quasiquote)
                      [(OkCtfeQuoteExpr quoted-init _ init-fuel)
                        (match (ctfe-quote-expr value env init-fuel quasiquote)
                          [(OkCtfeQuoteExpr quoted-value _ value-fuel)
                            (OkCtfeQuoteExpr
                              (ast-expr-spmd-reduce-id-with-pools
                                (ctfe-env-pools env)
                                op
                                (ctfe-quote-name-id env index)
                                index-ty
                                quoted-start
                                quoted-end
                                quoted-init
                                quoted-value)
                              (AstTyExpr)
                              value-fuel)]
                          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
                      [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
                  [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))])]
    [(AstExprSpmdScan scan-box)
      (match (box-get scan-box)
        [(AstSpmdScan
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
              [(OkCtfeQuoteExpr quoted-start _ start-fuel)
                (match (ctfe-quote-expr end env start-fuel quasiquote)
                  [(OkCtfeQuoteExpr quoted-end _ end-fuel)
                    (match (ctfe-quote-expr init env end-fuel quasiquote)
                      [(OkCtfeQuoteExpr quoted-init _ init-fuel)
                        (match (ctfe-quote-expr value env init-fuel quasiquote)
                          [(OkCtfeQuoteExpr quoted-value _ value-fuel)
                            (match (ctfe-quote-expr
                              body
                              env
                              value-fuel
                              quasiquote)
                              [(OkCtfeQuoteExpr quoted-body _ body-fuel)
                                (OkCtfeQuoteExpr
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
                                  (AstTyExpr)
                                  body-fuel)]
                              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
                          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
                      [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
                  [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))])]
    [(AstExprSpmdBroadcast value-box lane-box)
      (let
        [value : AstExpr (ctfe-ast-get env value-box)]
        [lane : AstExpr (ctfe-ast-get env lane-box)]
        (match (ctfe-quote-expr value env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-value _ value-fuel)
            (match (ctfe-quote-expr lane env value-fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-lane _ lane-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-spmd-broadcast-with-pools
                    (ctfe-env-pools env)
                    quoted-value
                    quoted-lane)
                  (AstTyExpr)
                  lane-fuel)]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprSpmdShuffle value-box lane-box)
      (let
        [value : AstExpr (ast-node-get value-box)]
        [lane : AstExpr (ast-node-get lane-box)]
        (match (ctfe-quote-expr value env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-value _ value-fuel)
            (match (ctfe-quote-expr lane env value-fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-lane _ lane-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-spmd-shuffle quoted-value quoted-lane)
                  (AstTyExpr)
                  lane-fuel)]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprSpmdProgramIndex)
      (OkCtfeQuoteExpr
        (ast-expr-spmd-program-index-with-pools (ctfe-env-pools env))
        (AstTyExpr)
        fuel)]
    [(AstExprSpmdProgramCount)
      (OkCtfeQuoteExpr
        (ast-expr-spmd-program-count-with-pools (ctfe-env-pools env))
        (AstTyExpr)
        fuel)]
    [(AstExprStructGet inner-box field)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr
              (ast-expr-struct-get-id-with-pools
                (ctfe-env-pools env)
                quoted
                field)
              (AstTyExpr)
              next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprStructSet inner-box field value-box)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        [value : AstExpr (ctfe-ast-get env value-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-inner _ inner-fuel)
            (match (ctfe-quote-expr value env inner-fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-value _ value-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-struct-set-id-with-pools
                    (ctfe-env-pools env)
                    quoted-inner
                    field
                    quoted-value)
                  (AstTyExpr)
                  value-fuel)]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprTupleRef tuple-expr-box index)
      (let
        [tuple-expr : AstExpr (ctfe-ast-get env tuple-expr-box)]
        (match (ctfe-quote-expr tuple-expr env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr
              (ast-expr-tuple-ref-with-pools (ctfe-env-pools env) quoted index)
              (AstTyExpr)
              next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprMakeArray ty len-box)
      (let
        [len : AstExpr (ctfe-ast-get env len-box)]
        (match (ctfe-quote-type ty env expr fuel)
          [(OkCtfeQuoteType quoted-ty type-fuel)
            (match (ctfe-quote-expr len env type-fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-len _ next-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-make-array-with-pools
                    (ctfe-env-pools env)
                    quoted-ty
                    quoted-len)
                  (AstTyExpr)
                  next-fuel)]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteType diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprArrayRef array-box index-box)
      (let
        [array : AstExpr (ctfe-ast-get env array-box)]
        [index : AstExpr (ctfe-ast-get env index-box)]
        (match (ctfe-quote-expr array env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-array _ array-fuel)
            (match (ctfe-quote-expr index env array-fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-index _ index-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-array-ref-with-pools
                    (ctfe-env-pools env)
                    quoted-array
                    quoted-index)
                  (AstTyExpr)
                  index-fuel)]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprArraySet array-box index-box value-box)
      (let
        [array : AstExpr (ctfe-ast-get env array-box)]
        [index : AstExpr (ctfe-ast-get env index-box)]
        [value : AstExpr (ctfe-ast-get env value-box)]
        (match (ctfe-quote-expr array env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-array _ array-fuel)
            (match (ctfe-quote-expr index env array-fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-index _ index-fuel)
                (match (ctfe-quote-expr value env index-fuel quasiquote)
                  [(OkCtfeQuoteExpr quoted-value _ value-fuel)
                    (OkCtfeQuoteExpr
                      (ast-expr-array-set-with-pools
                        (ctfe-env-pools env)
                        quoted-array
                        quoted-index
                        quoted-value)
                      (AstTyExpr)
                      value-fuel)]
                  [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprArrayPush array-box value-box)
      (let
        [array : AstExpr (ctfe-ast-get env array-box)]
        [value : AstExpr (ctfe-ast-get env value-box)]
        (match (ctfe-quote-expr array env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-array _ array-fuel)
            (match (ctfe-quote-expr value env array-fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-value _ value-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-array-push-with-pools
                    (ctfe-env-pools env)
                    quoted-array
                    quoted-value)
                  (AstTyExpr)
                  value-fuel)]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprStringRef text-box index-box)
      (let
        [text : AstExpr (ctfe-ast-get env text-box)]
        [index : AstExpr (ctfe-ast-get env index-box)]
        (match (ctfe-quote-expr text env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-text _ text-fuel)
            (match (ctfe-quote-expr index env text-fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-index _ index-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-string-ref-with-pools
                    (ctfe-env-pools env)
                    quoted-text
                    quoted-index)
                  (AstTyExpr)
                  index-fuel)]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprWithRegion name body)
      (match (ctfe-quote-expr-list body env fuel quasiquote)
        [(OkCtfeQuoteExprList quoted-body next-fuel)
          (OkCtfeQuoteExpr
            (ctfe-ast-push
              env
              (AstExprWithRegion (ctfe-quote-name env name) quoted-body))
            (AstTyExpr)
            next-fuel)]
        [(ErrCtfeQuoteExprList diag) (ErrCtfeQuoteExpr diag)])]
    [(AstExprWithEscape scratch-box body)
      (let
        [scratch : AstExpr (ctfe-ast-get env scratch-box)]
        (match (ctfe-quote-expr scratch env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-scratch _ scratch-fuel)
            (match (ctfe-quote-expr-list body env scratch-fuel quasiquote)
              [(OkCtfeQuoteExprList quoted-body body-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-with-escape-with-pools
                    (ctfe-env-pools env)
                    quoted-scratch
                    quoted-body)
                  (AstTyExpr)
                  body-fuel)]
              [(ErrCtfeQuoteExprList diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprWithScratch body)
      (match (ctfe-quote-expr-list body env fuel quasiquote)
        [(OkCtfeQuoteExprList quoted-body body-fuel)
          (OkCtfeQuoteExpr
            (ast-expr-with-scratch-with-pools (ctfe-env-pools env) quoted-body)
            (AstTyExpr)
            body-fuel)]
        [(ErrCtfeQuoteExprList diag) (ErrCtfeQuoteExpr diag)])]
    [(AstExprInArena arena-box body)
      (let
        [arena : AstExpr (ctfe-ast-get env arena-box)]
        (match (ctfe-quote-expr arena env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-arena _ arena-fuel)
            (match (ctfe-quote-expr-list body env arena-fuel quasiquote)
              [(OkCtfeQuoteExprList quoted-body body-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-in-arena-with-pools
                    (ctfe-env-pools env)
                    quoted-arena
                    quoted-body)
                  (AstTyExpr)
                  body-fuel)]
              [(ErrCtfeQuoteExprList diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprWithResource wr-box)
      (match (box-get wr-box)
        [(AstWithResource bindings body)
          (match (ctfe-quote-resource-binding-list bindings env fuel quasiquote)
            [(OkCtfeQuoteResourceBindings quoted-bindings bindings-fuel)
              (match (ctfe-quote-expr-list body env bindings-fuel quasiquote)
                [(OkCtfeQuoteExprList quoted-body body-fuel)
                  (OkCtfeQuoteExpr
                    (ctfe-ast-push
                      env
                      (AstExprWithResource
                        (box (AstWithResource quoted-bindings quoted-body))))
                    (AstTyExpr)
                    body-fuel)]
                [(ErrCtfeQuoteExprList diag) (ErrCtfeQuoteExpr diag)])]
            [(ErrCtfeQuoteResourceBindings diag) (ErrCtfeQuoteExpr diag)])])]
    [(AstExprBox inner-box)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr
              (ast-expr-box-with-pools (ctfe-env-pools env) quoted)
              (AstTyExpr)
              next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprBoxGet inner-box)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr
              (ast-expr-box-get-with-pools (ctfe-env-pools env) quoted)
              (AstTyExpr)
              next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprBoxTake inner-box)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr
              (ast-expr-box-take-with-pools (ctfe-env-pools env) quoted)
              (AstTyExpr)
              next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprBoxSet inner-box value-box)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        [value : AstExpr (ctfe-ast-get env value-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-inner _ inner-fuel)
            (match (ctfe-quote-expr value env inner-fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-value _ value-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-box-set-with-pools
                    (ctfe-env-pools env)
                    quoted-inner
                    quoted-value)
                  (AstTyExpr)
                  value-fuel)]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprComptime inner-box)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted ty next-fuel)
            (OkCtfeQuoteExpr
              (ast-expr-comptime-with-pools (ctfe-env-pools env) quoted)
              ty
              next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprReturn inner-box)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr
              (ast-expr-return-with-pools (ctfe-env-pools env) quoted)
              (AstTyExpr)
              next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprTry inner-box)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr
              (ast-expr-try-with-pools (ctfe-env-pools env) quoted)
              (AstTyExpr)
              next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprInit maybe-ty)
      (match (ctfe-quote-maybe-type maybe-ty env expr fuel)
        [(OkCtfeQuoteMaybeType quoted-ty next-fuel)
          (OkCtfeQuoteExpr
            (ast-expr-init-maybe-with-pools (ctfe-env-pools env) quoted-ty)
            (AstTyExpr)
            next-fuel)]
        [(ErrCtfeQuoteMaybeType diag) (ErrCtfeQuoteExpr diag)])]
    [(AstExprPtrNull ty)
      (match (ctfe-quote-type ty env expr fuel)
        [(OkCtfeQuoteType quoted-ty next-fuel)
          (OkCtfeQuoteExpr
            (ctfe-ast-push env (AstExprPtrNull quoted-ty))
            (AstTyExpr)
            next-fuel)]
        [(ErrCtfeQuoteType diag) (ErrCtfeQuoteExpr diag)])]
    [(AstExprPtrNullCheck ptr-box)
      (let
        [ptr : AstExpr (ctfe-ast-get env ptr-box)]
        (match (ctfe-quote-expr ptr env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr
              (ast-expr-ptr-null-check-with-pools (ctfe-env-pools env) quoted)
              (AstTyExpr)
              next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprPtrAddrOf name)
      (OkCtfeQuoteExpr
        (ast-expr-ptr-addr-of-id-with-pools
          (ctfe-env-pools env)
          (ctfe-quote-name-id env name))
        (AstTyExpr)
        fuel)]
    [(AstExprPtrRead ptr-box)
      (let
        [ptr : AstExpr (ctfe-ast-get env ptr-box)]
        (match (ctfe-quote-expr ptr env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr
              (ast-expr-ptr-read-with-pools (ctfe-env-pools env) quoted)
              (AstTyExpr)
              next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprPtrWrite ptr-box value-box)
      (let
        [ptr : AstExpr (ctfe-ast-get env ptr-box)]
        [value : AstExpr (ctfe-ast-get env value-box)]
        (match (ctfe-quote-expr ptr env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-ptr _ ptr-fuel)
            (match (ctfe-quote-expr value env ptr-fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-value _ value-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-ptr-write-with-pools
                    (ctfe-env-pools env)
                    quoted-ptr
                    quoted-value)
                  (AstTyExpr)
                  value-fuel)]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprPtrOffset ptr-box offset-box)
      (let
        [ptr : AstExpr (ctfe-ast-get env ptr-box)]
        [offset : AstExpr (ctfe-ast-get env offset-box)]
        (match (ctfe-quote-expr ptr env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-ptr _ ptr-fuel)
            (match (ctfe-quote-expr offset env ptr-fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-offset _ offset-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-ptr-offset-with-pools
                    (ctfe-env-pools env)
                    quoted-ptr
                    quoted-offset)
                  (AstTyExpr)
                  offset-fuel)]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprPtrCast ptr-box ty)
      (let
        [ptr : AstExpr (ctfe-ast-get env ptr-box)]
        (match (ctfe-quote-expr ptr env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ expr-fuel)
            (match (ctfe-quote-type ty env expr expr-fuel)
              [(OkCtfeQuoteType quoted-ty next-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-ptr-cast-with-pools
                    (ctfe-env-pools env)
                    quoted
                    quoted-ty)
                  (AstTyExpr)
                  next-fuel)]
              [(ErrCtfeQuoteType diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprPtrToInt ptr-box)
      (let
        [ptr : AstExpr (ctfe-ast-get env ptr-box)]
        (match (ctfe-quote-expr ptr env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr
              (ast-expr-ptr-to-int-with-pools (ctfe-env-pools env) quoted)
              (AstTyExpr)
              next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprIntToPtr value-box ty)
      (let
        [value : AstExpr (ctfe-ast-get env value-box)]
        (match (ctfe-quote-expr value env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ expr-fuel)
            (match (ctfe-quote-type ty env expr expr-fuel)
              [(OkCtfeQuoteType quoted-ty next-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-int-to-ptr-with-pools
                    (ctfe-env-pools env)
                    quoted
                    quoted-ty)
                  (AstTyExpr)
                  next-fuel)]
              [(ErrCtfeQuoteType diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprStringData inner-box)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr
              (ast-expr-string-data-with-pools (ctfe-env-pools env) quoted)
              (AstTyExpr)
              next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprStringFromBytes ptr-box len-box)
      (let
        [ptr : AstExpr (ctfe-ast-get env ptr-box)]
        [len : AstExpr (ctfe-ast-get env len-box)]
        (match (ctfe-quote-expr ptr env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-ptr _ ptr-fuel)
            (match (ctfe-quote-expr len env ptr-fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-len _ len-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-string-from-bytes-with-pools
                    (ctfe-env-pools env)
                    quoted-ptr
                    quoted-len)
                  (AstTyExpr)
                  len-fuel)]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprArrayData inner-box)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr
              (ast-expr-array-data-with-pools (ctfe-env-pools env) quoted)
              (AstTyExpr)
              next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprBinaryData bytes)
      (OkCtfeQuoteExpr
        (ctfe-ast-push env (AstExprBinaryData bytes))
        (AstTyExpr)
        fuel)]
    [(AstExprCpuIdEax leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ctfe-ast-get env leaf-box)]
        [subleaf : AstExpr (ctfe-ast-get env subleaf-box)]
        (match (ctfe-quote-expr leaf env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-leaf _ leaf-fuel)
            (match (ctfe-quote-expr subleaf env leaf-fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-subleaf _ subleaf-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-cpuid-eax-with-pools
                    (ctfe-env-pools env)
                    quoted-leaf
                    quoted-subleaf)
                  (AstTyExpr)
                  subleaf-fuel)]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprCpuIdEbx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ctfe-ast-get env leaf-box)]
        [subleaf : AstExpr (ctfe-ast-get env subleaf-box)]
        (match (ctfe-quote-expr leaf env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-leaf _ leaf-fuel)
            (match (ctfe-quote-expr subleaf env leaf-fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-subleaf _ subleaf-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-cpuid-ebx-with-pools
                    (ctfe-env-pools env)
                    quoted-leaf
                    quoted-subleaf)
                  (AstTyExpr)
                  subleaf-fuel)]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprCpuIdEcx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ctfe-ast-get env leaf-box)]
        [subleaf : AstExpr (ctfe-ast-get env subleaf-box)]
        (match (ctfe-quote-expr leaf env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-leaf _ leaf-fuel)
            (match (ctfe-quote-expr subleaf env leaf-fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-subleaf _ subleaf-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-cpuid-ecx-with-pools
                    (ctfe-env-pools env)
                    quoted-leaf
                    quoted-subleaf)
                  (AstTyExpr)
                  subleaf-fuel)]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprCpuIdEdx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ctfe-ast-get env leaf-box)]
        [subleaf : AstExpr (ctfe-ast-get env subleaf-box)]
        (match (ctfe-quote-expr leaf env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-leaf _ leaf-fuel)
            (match (ctfe-quote-expr subleaf env leaf-fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-subleaf _ subleaf-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-cpuid-edx-with-pools
                    (ctfe-env-pools env)
                    quoted-leaf
                    quoted-subleaf)
                  (AstTyExpr)
                  subleaf-fuel)]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprXgetbv index-box)
      (let
        [index : AstExpr (ctfe-ast-get env index-box)]
        (match (ctfe-quote-expr index env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-index _ index-fuel)
            (OkCtfeQuoteExpr
              (ast-expr-xgetbv-with-pools (ctfe-env-pools env) quoted-index)
              (AstTyExpr)
              index-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprSyscall args)
      (match (ctfe-quote-expr-list args env fuel quasiquote)
        [(OkCtfeQuoteExprList quoted-args args-fuel)
          (OkCtfeQuoteExpr
            (ast-expr-syscall-with-pools (ctfe-env-pools env) quoted-args)
            (AstTyExpr)
            args-fuel)]
        [(ErrCtfeQuoteExprList diag) (ErrCtfeQuoteExpr diag)])]
    [(AstExprUnquote inner-box)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (if quasiquote
          (ctfe-eval-unquote-expr inner expr env fuel)
          (match (ctfe-quote-expr inner env fuel quasiquote)
            [(OkCtfeQuoteExpr quoted _ next-fuel)
              (OkCtfeQuoteExpr
                (ast-expr-unquote-with-pools (ctfe-env-pools env) quoted)
                (AstTyExpr)
                next-fuel)]
            [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])))]
    [(AstExprUnquoteSplicing inner-box)
      (let
        [inner : AstExpr (ctfe-ast-get env inner-box)]
        (if quasiquote
          (ErrCtfeQuoteExpr
            (ctfe-diagnostic-at-expr
              expr
              "unquote-splicing is only valid in a quasiquote list"))
          (match (ctfe-quote-expr inner env fuel quasiquote)
            [(OkCtfeQuoteExpr quoted _ next-fuel)
              (OkCtfeQuoteExpr
                (ast-expr-unquote-splicing-with-pools
                  (ctfe-env-pools env)
                  quoted)
                (AstTyExpr)
                next-fuel)]
            [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])))]
    [_ (OkCtfeQuoteExpr (ctfe-ast-push env expr) (AstTyExpr) fuel)]))

(define (ctfe-eval-quote
  [template : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]
  [quasiquote : bool]) : ResultCtfe
  (match (ctfe-quote-expr template env fuel quasiquote)
    [(OkCtfeQuoteExpr node ty next-fuel) (OkCtfe (CtfeExpr node ty) next-fuel)]
    [(ErrCtfeQuoteExpr diag) (ErrCtfe diag)]))

;; --- expr constructors and inspectors (#1137) --------------------------------
;; Macro transformers need to build and pattern-match AST nodes at comptime.
;; These constructors / inspectors cover the forms needed by v1 macros
;; (and, or, when, unless, cond): literals, variables, if, and call.
;; EQ -------------------------------------------------------------------------
(define (ctfe-literal-eq [a : AstLiteral] [b : AstLiteral]) : bool
  (match a
    [(AstLitInt a-n _)
      (match b
        [(AstLitInt b-n _) (= a-n b-n)]
        [_ false])]
    [(AstLitBool a-b)
      (match b
        [(AstLitBool b-b) (= a-b b-b)]
        [_ false])]
    [(AstLitChar a-c)
      (match b
        [(AstLitChar b-c) (= a-c b-c)]
        [_ false])]
    [(AstLitFloat a-text)
      (match b
        [(AstLitFloat b-text) (string.string-eq a-text b-text)]
        [_ false])]
    [(AstLitString a-text)
      (match b
        [(AstLitString b-text) (string.string-eq a-text b-text)]
        [_ false])]
    [(AstLitUnit)
      (match b
        [(AstLitUnit) true]
        [_ false])]
    [_ false]))

(define (ctfe-borrow-lifetime-eq
  [a : AstBorrowLifetime]
  [b : AstBorrowLifetime]) : bool
  (match a
    [(AstBorrowLifetimeInferred)
      (match b
        [(AstBorrowLifetimeInferred) true]
        [_ false])]
    [(AstBorrowLifetimeNamed a-name)
      (match b
        [(AstBorrowLifetimeNamed b-name) (string.string-eq a-name b-name)]
        [_ false])]))

(define (ctfe-maybe-type-eq-in-env
  [env : CtfeEnv]
  [a : AstMaybeType]
  [b : AstMaybeType]) : bool
  (match a
    [(AstNoType)
      (match b
        [(AstNoType) true]
        [_ false])]
    [(AstSomeType a-ty)
      (match b
        [(AstSomeType b-ty) (ctfe-type-eq-in-env env a-ty b-ty)]
        [_ false])]))

(define (ctfe-param-eq-in-env [env : CtfeEnv] [a : AstParam] [b : AstParam]) : bool
  (match a
    [(AstParam a-name a-ty a-comptime)
      (match b
        [(AstParam b-name b-ty b-comptime)
          (and
            (= a-name b-name)
            (ctfe-type-eq-in-env env a-ty b-ty)
            (= a-comptime b-comptime))])]))

(define (ctfe-param-list-eq-in-env
  [env : CtfeEnv]
  [a : AstParamList]
  [b : AstParamList]) : bool
  (match a
    [(AstParamNil)
      (match b
        [(AstParamNil) true]
        [_ false])]
    [(AstParamCons a-head a-rest)
      (let
        [a-rest : AstParamList (box-get a-rest)]
        (match b
          [(AstParamCons b-head b-rest)
            (let
              [b-rest : AstParamList (box-get b-rest)]
              (and
                (ctfe-param-eq-in-env env a-head b-head)
                (ctfe-param-list-eq-in-env env a-rest b-rest)))]
          [_ false]))]))

(define (ctfe-pattern-eq-in-env
  [env : CtfeEnv]
  [a : AstPattern]
  [b : AstPattern]) : bool
  (match a
    [(AstPatVar a-name a-ty)
      (match b
        [(AstPatVar b-name b-ty)
          (and (= a-name b-name) (ctfe-maybe-type-eq-in-env env a-ty b-ty))]
        [_ false])]
    [(AstPatTuple a-items-box)
      (let
        [a-items : AstPatternList (box-get a-items-box)]
        (match b
          [(AstPatTuple b-items-box)
            (ctfe-pattern-list-eq-in-env env a-items (box-get b-items-box))]
          [_ false]))]
    [(AstPatWildcard)
      (match b
        [(AstPatWildcard) true]
        [_ false])]
    [(AstPatBinding a-name)
      (match b
        [(AstPatBinding b-name) (= a-name b-name)]
        [_ false])]
    [(AstPatVariant a-name a-items-box)
      (let
        [a-items : AstPatternList (box-get a-items-box)]
        (match b
          [(AstPatVariant b-name b-items-box)
            (and
              (= a-name b-name)
              (ctfe-pattern-list-eq-in-env env a-items (box-get b-items-box)))]
          [_ false]))]
    [(AstPatLiteral a-lit)
      (match b
        [(AstPatLiteral b-lit) (ctfe-literal-eq a-lit b-lit)]
        [_ false])]))

(define (ctfe-pattern-list-eq-in-env
  [env : CtfeEnv]
  [a : AstPatternList]
  [b : AstPatternList]) : bool
  (match a
    [(AstPatternNil)
      (match b
        [(AstPatternNil) true]
        [_ false])]
    [(AstPatternCons a-head a-tail)
      (let
        [a-head : AstPattern (box-get a-head)]
        [a-tail : AstPatternList (box-get a-tail)]
        (match b
          [(AstPatternCons b-head b-tail)
            (let
              [b-head : AstPattern (box-get b-head)]
              [b-tail : AstPatternList (box-get b-tail)]
              (and
                (ctfe-pattern-eq-in-env env a-head b-head)
                (ctfe-pattern-list-eq-in-env env a-tail b-tail)))]
          [_ false]))]))

(define (ctfe-let-binding-eq-in-env
  [env : CtfeEnv]
  [a : AstLetBinding]
  [b : AstLetBinding]) : bool
  (match a
    [(AstLetBinding a-name a-ty a-value-box)
      (let
        [a-value : AstExpr (ctfe-ast-get env a-value-box)]
        (match b
          [(AstLetBinding b-name b-ty b-value-box)
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
  (match a
    [(AstLetBindingNil)
      (match b
        [(AstLetBindingNil) true]
        [_ false])]
    [(AstLetBindingCons a-head a-tail)
      (let
        [a-tail : AstLetBindingList (box-get a-tail)]
        (match b
          [(AstLetBindingCons b-head b-tail)
            (let
              [b-tail : AstLetBindingList (box-get b-tail)]
              (and
                (ctfe-let-binding-eq-in-env env a-head b-head)
                (ctfe-let-binding-list-eq-in-env env a-tail b-tail)))]
          [_ false]))]))

(define (ctfe-resource-binding-eq-in-env
  [env : CtfeEnv]
  [a : AstResourceBinding]
  [b : AstResourceBinding]) : bool
  (match a
    [(AstResourceBinding a-name a-init-box a-cleanup-box)
      (let
        [a-init : AstExpr (ctfe-ast-get env a-init-box)]
        [a-cleanup : AstExpr (ctfe-ast-get env a-cleanup-box)]
        (match b
          [(AstResourceBinding b-name b-init-box b-cleanup-box)
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
  (match a
    [(AstResourceBindingNil)
      (match b
        [(AstResourceBindingNil) true]
        [_ false])]
    [(AstResourceBindingCons a-head a-tail)
      (let
        [a-tail : AstResourceBindingList (box-get a-tail)]
        (match b
          [(AstResourceBindingCons b-head b-tail)
            (let
              [b-tail : AstResourceBindingList (box-get b-tail)]
              (and
                (ctfe-resource-binding-eq-in-env env a-head b-head)
                (ctfe-resource-binding-list-eq-in-env env a-tail b-tail)))]
          [_ false]))]))

(define (ctfe-match-arm-eq-in-env
  [env : CtfeEnv]
  [a : AstMatchArm]
  [b : AstMatchArm]) : bool
  (match a
    [(AstMatchArm a-pattern a-body-box)
      (let
        [a-body : AstExpr (ctfe-ast-get env a-body-box)]
        (match b
          [(AstMatchArm b-pattern b-body-box)
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
  (match a
    [(AstMatchArmNil)
      (match b
        [(AstMatchArmNil) true]
        [_ false])]
    [(AstMatchArmCons a-head a-tail)
      (let
        [a-tail : AstMatchArmList (box-get a-tail)]
        (match b
          [(AstMatchArmCons b-head b-tail)
            (let
              [b-tail : AstMatchArmList (box-get b-tail)]
              (and
                (ctfe-match-arm-eq-in-env env a-head b-head)
                (ctfe-match-arm-list-eq-in-env env a-tail b-tail)))]
          [_ false]))]))

(define (ctfe-reduce-op-eq [a : AstReduceOp] [b : AstReduceOp]) : bool
  (match a
    [(AstReduceSum)
      (match b
        [(AstReduceSum) true]
        [_ false])]
    [(AstReduceMin)
      (match b
        [(AstReduceMin) true]
        [_ false])]
    [(AstReduceMax)
      (match b
        [(AstReduceMax) true]
        [_ false])]
    [(AstReduceAll)
      (match b
        [(AstReduceAll) true]
        [_ false])]
    [(AstReduceAny)
      (match b
        [(AstReduceAny) true]
        [_ false])]))

(define (ctfe-expr-eq-inner-in-env [env : CtfeEnv] [a : AstExpr] [b : AstExpr]) : bool
  (match a
    [(AstExprLiteral a-lit)
      (match b
        [(AstExprLiteral b-lit) (ctfe-literal-eq a-lit b-lit)]
        [_ false])]
    [(AstExprVar a-name)
      (match b
        [(AstExprVar b-name)
          (string.string-eq (intern-str a-name) (intern-str b-name))]
        [_ false])]
    [(AstExprBinary a-op a-l-box a-r-box)
      (let
        [a-l : AstExpr (ctfe-ast-get env a-l-box)]
        [a-r : AstExpr (ctfe-ast-get env a-r-box)]
        (match b
          [(AstExprBinary b-op b-l-box b-r-box)
            (let
              [b-l : AstExpr (ctfe-ast-get env b-l-box)]
              [b-r : AstExpr (ctfe-ast-get env b-r-box)]
              (and
                (ctfe-binop-eq a-op b-op)
                (ctfe-expr-eq-in-env env a-l b-l)
                (ctfe-expr-eq-in-env env a-r b-r)))]
          [_ false]))]
    [(AstExprUnary a-op a-in-box)
      (let
        [a-in : AstExpr (ctfe-ast-get env a-in-box)]
        (match b
          [(AstExprUnary b-op b-in-box)
            (let
              [b-in : AstExpr (ctfe-ast-get env b-in-box)]
              (and (ctfe-unop-eq a-op b-op) (ctfe-expr-eq-in-env env a-in b-in)))]
          [_ false]))]
    [(AstExprIf a-c-box a-t-box a-e-box)
      (let
        [a-c : AstExpr (ctfe-ast-get env a-c-box)]
        [a-t : AstExpr (ctfe-ast-get env a-t-box)]
        [a-e : AstExpr (ctfe-ast-get env a-e-box)]
        (match b
          [(AstExprIf b-c-box b-t-box b-e-box)
            (let
              [b-c : AstExpr (ctfe-ast-get env b-c-box)]
              [b-t : AstExpr (ctfe-ast-get env b-t-box)]
              [b-e : AstExpr (ctfe-ast-get env b-e-box)]
              (and
                (ctfe-expr-eq-in-env env a-c b-c)
                (ctfe-expr-eq-in-env env a-t b-t)
                (ctfe-expr-eq-in-env env a-e b-e)))]
          [_ false]))]
    [(AstExprLet a-let-box)
      (match (box-get a-let-box)
        [(AstLet a-bindings a-body-box)
          (let
            [a-body : AstExpr (ctfe-ast-get env a-body-box)]
            (match b
              [(AstExprLet b-let-box)
                (match (box-get b-let-box)
                  [(AstLet b-bindings b-body-box)
                    (let
                      [b-body : AstExpr (ctfe-ast-get env b-body-box)]
                      (and
                        (ctfe-let-binding-list-eq-in-env
                          env
                          a-bindings
                          b-bindings)
                        (ctfe-expr-eq-in-env env a-body b-body)))])]
              [_ false]))])]
    [(AstExprLambda a-lambda-box)
      (match (box-get a-lambda-box)
        [(AstLambda a-params a-ret a-body-box)
          (let
            [a-body : AstExpr (ctfe-ast-get env a-body-box)]
            (match b
              [(AstExprLambda b-lambda-box)
                (match (box-get b-lambda-box)
                  [(AstLambda b-params b-ret b-body-box)
                    (let
                      [b-body : AstExpr (ctfe-ast-get env b-body-box)]
                      (and
                        (ctfe-param-list-eq-in-env env a-params b-params)
                        (ctfe-maybe-type-eq-in-env env a-ret b-ret)
                        (ctfe-expr-eq-in-env env a-body b-body)))])]
              [_ false]))])]
    [(AstExprCall a-fun-box a-args)
      (let
        [a-fun : AstExpr (ctfe-ast-get env a-fun-box)]
        (match b
          [(AstExprCall b-fun-box b-args)
            (let
              [b-fun : AstExpr (ctfe-ast-get env b-fun-box)]
              (and
                (ctfe-expr-eq-in-env env a-fun b-fun)
                (ctfe-expr-list-eq-in-env env a-args b-args)))]
          [_ false]))]
    [(AstExprBracketClause a-items)
      (match b
        [(AstExprBracketClause b-items)
          (ctfe-expr-list-eq-in-env env a-items b-items)]
        [_ false])]
    [(AstExprTuple a-items)
      (match b
        [(AstExprTuple b-items) (ctfe-expr-list-eq-in-env env a-items b-items)]
        [_ false])]
    [(AstExprTupleRef a-inner-box a-index)
      (let
        [a-inner : AstExpr (ctfe-ast-get env a-inner-box)]
        (match b
          [(AstExprTupleRef b-inner-box b-index)
            (let
              [b-inner : AstExpr (ctfe-ast-get env b-inner-box)]
              (and
                (= a-index b-index)
                (ctfe-expr-eq-in-env env a-inner b-inner)))]
          [_ false]))]
    [(AstExprArray a-items)
      (match b
        [(AstExprArray b-items) (ctfe-expr-list-eq-in-env env a-items b-items)]
        [_ false])]
    [(AstExprMakeArray a-ty a-size-box)
      (let
        [a-size : AstExpr (ctfe-ast-get env a-size-box)]
        (match b
          [(AstExprMakeArray b-ty b-size-box)
            (let
              [b-size : AstExpr (ctfe-ast-get env b-size-box)]
              (and
                (ctfe-type-eq-in-env env a-ty b-ty)
                (ctfe-expr-eq-in-env env a-size b-size)))]
          [_ false]))]
    [(AstExprArrayRef a-target-box a-index-box)
      (let
        [a-target : AstExpr (ctfe-ast-get env a-target-box)]
        [a-index : AstExpr (ctfe-ast-get env a-index-box)]
        (match b
          [(AstExprArrayRef b-target-box b-index-box)
            (let
              [b-target : AstExpr (ctfe-ast-get env b-target-box)]
              [b-index : AstExpr (ctfe-ast-get env b-index-box)]
              (and
                (ctfe-expr-eq-in-env env a-target b-target)
                (ctfe-expr-eq-in-env env a-index b-index)))]
          [_ false]))]
    [(AstExprArraySet a-target-box a-index-box a-value-box)
      (let
        [a-target : AstExpr (ctfe-ast-get env a-target-box)]
        [a-index : AstExpr (ctfe-ast-get env a-index-box)]
        [a-value : AstExpr (ctfe-ast-get env a-value-box)]
        (match b
          [(AstExprArraySet b-target-box b-index-box b-value-box)
            (let
              [b-target : AstExpr (ctfe-ast-get env b-target-box)]
              [b-index : AstExpr (ctfe-ast-get env b-index-box)]
              [b-value : AstExpr (ctfe-ast-get env b-value-box)]
              (and
                (ctfe-expr-eq-in-env env a-target b-target)
                (ctfe-expr-eq-in-env env a-index b-index)
                (ctfe-expr-eq-in-env env a-value b-value)))]
          [_ false]))]
    [(AstExprArrayPush a-target-box a-value-box)
      (let
        [a-target : AstExpr (ctfe-ast-get env a-target-box)]
        [a-value : AstExpr (ctfe-ast-get env a-value-box)]
        (match b
          [(AstExprArrayPush b-target-box b-value-box)
            (let
              [b-target : AstExpr (ctfe-ast-get env b-target-box)]
              [b-value : AstExpr (ctfe-ast-get env b-value-box)]
              (and
                (ctfe-expr-eq-in-env env a-target b-target)
                (ctfe-expr-eq-in-env env a-value b-value)))]
          [_ false]))]
    [(AstExprStringRef a-target-box a-index-box)
      (let
        [a-target : AstExpr (ctfe-ast-get env a-target-box)]
        [a-index : AstExpr (ctfe-ast-get env a-index-box)]
        (match b
          [(AstExprStringRef b-target-box b-index-box)
            (let
              [b-target : AstExpr (ctfe-ast-get env b-target-box)]
              [b-index : AstExpr (ctfe-ast-get env b-index-box)]
              (and
                (ctfe-expr-eq-in-env env a-target b-target)
                (ctfe-expr-eq-in-env env a-index b-index)))]
          [_ false]))]
    [(AstExprWhile a-cond-box a-body-box)
      (let
        [a-cond : AstExpr (ctfe-ast-get env a-cond-box)]
        [a-body : AstExpr (ctfe-ast-get env a-body-box)]
        (match b
          [(AstExprWhile b-cond-box b-body-box)
            (let
              [b-cond : AstExpr (ctfe-ast-get env b-cond-box)]
              [b-body : AstExpr (ctfe-ast-get env b-body-box)]
              (and
                (ctfe-expr-eq-in-env env a-cond b-cond)
                (ctfe-expr-eq-in-env env a-body b-body)))]
          [_ false]))]
    [(AstExprBegin a-exprs)
      (match b
        [(AstExprBegin b-exprs) (ctfe-expr-list-eq-in-env env a-exprs b-exprs)]
        [_ false])]
    [(AstExprUnsafe a-exprs)
      (match b
        [(AstExprUnsafe b-exprs) (ctfe-expr-list-eq-in-env env a-exprs b-exprs)]
        [_ false])]
    [(AstExprSet a-name a-value-box)
      (let
        [a-value : AstExpr (ctfe-ast-get env a-value-box)]
        (match b
          [(AstExprSet b-name b-value-box)
            (let
              [b-value : AstExpr (ctfe-ast-get env b-value-box)]
              (and (= a-name b-name) (ctfe-expr-eq-in-env env a-value b-value)))]
          [_ false]))]
    [(AstExprAnn a-inner-box a-ty)
      (let
        [a-inner : AstExpr (ctfe-ast-get env a-inner-box)]
        (match b
          [(AstExprAnn b-inner-box b-ty)
            (let
              [b-inner : AstExpr (ctfe-ast-get env b-inner-box)]
              (and
                (ctfe-expr-eq-in-env env a-inner b-inner)
                (ctfe-type-eq-in-env env a-ty b-ty)))]
          [_ false]))]
    [(AstExprCast a-inner-box a-ty)
      (let
        [a-inner : AstExpr (ctfe-ast-get env a-inner-box)]
        (match b
          [(AstExprCast b-inner-box b-ty)
            (let
              [b-inner : AstExpr (ctfe-ast-get env b-inner-box)]
              (and
                (ctfe-expr-eq-in-env env a-inner b-inner)
                (ctfe-type-eq-in-env env a-ty b-ty)))]
          [_ false]))]
    [(AstExprBorrow a-mut a-life a-place-box)
      (let
        [a-place : AstExpr (ctfe-ast-get env a-place-box)]
        (match b
          [(AstExprBorrow b-mut b-life b-place-box)
            (let
              [b-place : AstExpr (ctfe-ast-get env b-place-box)]
              (and
                (= a-mut b-mut)
                (ctfe-borrow-lifetime-eq a-life b-life)
                (ctfe-expr-eq-in-env env a-place b-place)))]
          [_ false]))]
    [(AstExprMatch a-match-box)
      (match (box-get a-match-box)
        [(AstMatch a-scrut-box a-arms)
          (let
            [a-scrut : AstExpr (ctfe-ast-get env a-scrut-box)]
            (match b
              [(AstExprMatch b-match-box)
                (match (box-get b-match-box)
                  [(AstMatch b-scrut-box b-arms)
                    (let
                      [b-scrut : AstExpr (ctfe-ast-get env b-scrut-box)]
                      (and
                        (ctfe-expr-eq-in-env env a-scrut b-scrut)
                        (ctfe-match-arm-list-eq-in-env env a-arms b-arms)))])]
              [_ false]))])]
    [(AstExprForeach a-fe-box)
      (match (box-get a-fe-box)
        [(AstForeach a-name a-ty a-start-box a-end-box a-body-box)
          (let
            [a-start : AstExpr (ctfe-ast-get env a-start-box)]
            [a-end : AstExpr (ctfe-ast-get env a-end-box)]
            [a-body : AstExpr (ctfe-ast-get env a-body-box)]
            (match b
              [(AstExprForeach b-fe-box)
                (match (box-get b-fe-box)
                  [(AstForeach b-name b-ty b-start-box b-end-box b-body-box)
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
    [(AstExprSpmdReduce a-reduce-box)
      (match (box-get a-reduce-box)
        [(AstSpmdReduce
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
              [(AstExprSpmdReduce b-reduce-box)
                (match (box-get b-reduce-box)
                  [(AstSpmdReduce
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
    [(AstExprSpmdScan scan-box)
      (match (box-get scan-box)
        [(AstSpmdScan
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
              [(AstExprSpmdScan scan-box-2)
                (match (box-get scan-box-2)
                  [(AstSpmdScan
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
    [(AstExprSpmdBroadcast a-value-box a-lane-box)
      (let
        [a-value : AstExpr (ctfe-ast-get env a-value-box)]
        [a-lane : AstExpr (ctfe-ast-get env a-lane-box)]
        (match b
          [(AstExprSpmdBroadcast b-value-box b-lane-box)
            (let
              [b-value : AstExpr (ctfe-ast-get env b-value-box)]
              [b-lane : AstExpr (ctfe-ast-get env b-lane-box)]
              (and
                (ctfe-expr-eq-in-env env a-value b-value)
                (ctfe-expr-eq-in-env env a-lane b-lane)))]
          [_ false]))]
    [(AstExprSpmdShuffle a-value-box a-lane-box)
      (let
        [a-value : AstExpr (ast-node-get a-value-box)]
        [a-lane : AstExpr (ast-node-get a-lane-box)]
        (match b
          [(AstExprSpmdShuffle b-value-box b-lane-box)
            (let
              [b-value : AstExpr (ast-node-get b-value-box)]
              [b-lane : AstExpr (ast-node-get b-lane-box)]
              (and (ctfe-expr-eq a-value b-value) (ctfe-expr-eq a-lane b-lane)))]
          [_ false]))]
    [(AstExprSpmdProgramIndex)
      (match b
        [(AstExprSpmdProgramIndex) true]
        [_ false])]
    [(AstExprSpmdProgramCount)
      (match b
        [(AstExprSpmdProgramCount) true]
        [_ false])]
    [(AstExprStructGet a-inner-box a-field)
      (let
        [a-inner : AstExpr (ctfe-ast-get env a-inner-box)]
        (match b
          [(AstExprStructGet b-inner-box b-field)
            (let
              [b-inner : AstExpr (ctfe-ast-get env b-inner-box)]
              (and
                (= a-field b-field)
                (ctfe-expr-eq-in-env env a-inner b-inner)))]
          [_ false]))]
    [(AstExprStructSet a-inner-box a-field a-value-box)
      (let
        [a-inner : AstExpr (ctfe-ast-get env a-inner-box)]
        [a-value : AstExpr (ctfe-ast-get env a-value-box)]
        (match b
          [(AstExprStructSet b-inner-box b-field b-value-box)
            (let
              [b-inner : AstExpr (ctfe-ast-get env b-inner-box)]
              [b-value : AstExpr (ctfe-ast-get env b-value-box)]
              (and
                (= a-field b-field)
                (ctfe-expr-eq-in-env env a-inner b-inner)
                (ctfe-expr-eq-in-env env a-value b-value)))]
          [_ false]))]
    [(AstExprWithRegion a-name a-body)
      (match b
        [(AstExprWithRegion b-name b-body)
          (and
            (string.string-eq a-name b-name)
            (ctfe-expr-list-eq-in-env env a-body b-body))]
        [_ false])]
    [(AstExprWithEscape a-escape-box a-body)
      (let
        [a-escape : AstExpr (ctfe-ast-get env a-escape-box)]
        (match b
          [(AstExprWithEscape b-escape-box b-body)
            (let
              [b-escape : AstExpr (ctfe-ast-get env b-escape-box)]
              (and
                (ctfe-expr-eq-in-env env a-escape b-escape)
                (ctfe-expr-list-eq-in-env env a-body b-body)))]
          [_ false]))]
    [(AstExprWithScratch a-body)
      (match b
        [(AstExprWithScratch b-body)
          (ctfe-expr-list-eq-in-env env a-body b-body)]
        [_ false])]
    [(AstExprInArena a-arena-box a-body)
      (let
        [a-arena : AstExpr (ctfe-ast-get env a-arena-box)]
        (match b
          [(AstExprInArena b-arena-box b-body)
            (let
              [b-arena : AstExpr (ctfe-ast-get env b-arena-box)]
              (and
                (ctfe-expr-eq-in-env env a-arena b-arena)
                (ctfe-expr-list-eq-in-env env a-body b-body)))]
          [_ false]))]
    [(AstExprWithResource a-wr-box)
      (match (box-get a-wr-box)
        [(AstWithResource a-bindings a-body)
          (match b
            [(AstExprWithResource b-wr-box)
              (match (box-get b-wr-box)
                [(AstWithResource b-bindings b-body)
                  (and
                    (ctfe-resource-binding-list-eq-in-env
                      env
                      a-bindings
                      b-bindings)
                    (ctfe-expr-list-eq-in-env env a-body b-body))])]
            [_ false])])]
    [(AstExprPtrRead a-ptr-box)
      (let
        [a-ptr : AstExpr (ctfe-ast-get env a-ptr-box)]
        (match b
          [(AstExprPtrRead b-ptr-box)
            (let
              [b-ptr : AstExpr (ctfe-ast-get env b-ptr-box)]
              (ctfe-expr-eq-in-env env a-ptr b-ptr))]
          [_ false]))]
    [(AstExprPtrAddrOf a-name)
      (match b
        [(AstExprPtrAddrOf b-name) (= a-name b-name)]
        [_ false])]
    [(AstExprPtrWrite a-ptr-box a-value-box)
      (let
        [a-ptr : AstExpr (ctfe-ast-get env a-ptr-box)]
        [a-value : AstExpr (ctfe-ast-get env a-value-box)]
        (match b
          [(AstExprPtrWrite b-ptr-box b-value-box)
            (let
              [b-ptr : AstExpr (ctfe-ast-get env b-ptr-box)]
              [b-value : AstExpr (ctfe-ast-get env b-value-box)]
              (and
                (ctfe-expr-eq-in-env env a-ptr b-ptr)
                (ctfe-expr-eq-in-env env a-value b-value)))]
          [_ false]))]
    [(AstExprPtrOffset a-ptr-box a-offset-box)
      (let
        [a-ptr : AstExpr (ctfe-ast-get env a-ptr-box)]
        [a-offset : AstExpr (ctfe-ast-get env a-offset-box)]
        (match b
          [(AstExprPtrOffset b-ptr-box b-offset-box)
            (let
              [b-ptr : AstExpr (ctfe-ast-get env b-ptr-box)]
              [b-offset : AstExpr (ctfe-ast-get env b-offset-box)]
              (and
                (ctfe-expr-eq-in-env env a-ptr b-ptr)
                (ctfe-expr-eq-in-env env a-offset b-offset)))]
          [_ false]))]
    [(AstExprPtrCast a-ptr-box a-ty)
      (let
        [a-ptr : AstExpr (ctfe-ast-get env a-ptr-box)]
        (match b
          [(AstExprPtrCast b-ptr-box b-ty)
            (let
              [b-ptr : AstExpr (ctfe-ast-get env b-ptr-box)]
              (and
                (ctfe-expr-eq-in-env env a-ptr b-ptr)
                (ctfe-type-eq-in-env env a-ty b-ty)))]
          [_ false]))]
    [(AstExprPtrToInt a-ptr-box)
      (let
        [a-ptr : AstExpr (ctfe-ast-get env a-ptr-box)]
        (match b
          [(AstExprPtrToInt b-ptr-box)
            (let
              [b-ptr : AstExpr (ctfe-ast-get env b-ptr-box)]
              (ctfe-expr-eq-in-env env a-ptr b-ptr))]
          [_ false]))]
    [(AstExprIntToPtr a-value-box a-ty)
      (let
        [a-value : AstExpr (ctfe-ast-get env a-value-box)]
        (match b
          [(AstExprIntToPtr b-value-box b-ty)
            (let
              [b-value : AstExpr (ctfe-ast-get env b-value-box)]
              (and
                (ctfe-expr-eq-in-env env a-value b-value)
                (ctfe-type-eq-in-env env a-ty b-ty)))]
          [_ false]))]
    [(AstExprBox a-inner-box)
      (let
        [a-inner : AstExpr (ctfe-ast-get env a-inner-box)]
        (match b
          [(AstExprBox b-inner-box)
            (let
              [b-inner : AstExpr (ctfe-ast-get env b-inner-box)]
              (ctfe-expr-eq-in-env env a-inner b-inner))]
          [_ false]))]
    [(AstExprBoxGet a-inner-box)
      (let
        [a-inner : AstExpr (ctfe-ast-get env a-inner-box)]
        (match b
          [(AstExprBoxGet b-inner-box)
            (let
              [b-inner : AstExpr (ctfe-ast-get env b-inner-box)]
              (ctfe-expr-eq-in-env env a-inner b-inner))]
          [_ false]))]
    [(AstExprBoxTake a-inner-box)
      (let
        [a-inner : AstExpr (ctfe-ast-get env a-inner-box)]
        (match b
          [(AstExprBoxTake b-inner-box)
            (let
              [b-inner : AstExpr (ctfe-ast-get env b-inner-box)]
              (ctfe-expr-eq-in-env env a-inner b-inner))]
          [_ false]))]
    [(AstExprBoxSet a-inner-box a-value-box)
      (let
        [a-inner : AstExpr (ctfe-ast-get env a-inner-box)]
        [a-value : AstExpr (ctfe-ast-get env a-value-box)]
        (match b
          [(AstExprBoxSet b-inner-box b-value-box)
            (let
              [b-inner : AstExpr (ctfe-ast-get env b-inner-box)]
              [b-value : AstExpr (ctfe-ast-get env b-value-box)]
              (and
                (ctfe-expr-eq-in-env env a-inner b-inner)
                (ctfe-expr-eq-in-env env a-value b-value)))]
          [_ false]))]
    [(AstExprTypeLiteral a-ty)
      (match b
        [(AstExprTypeLiteral b-ty) (ctfe-type-eq-in-env env a-ty b-ty)]
        [_ false])]
    [(AstExprInit a-ty)
      (match b
        [(AstExprInit b-ty) (ctfe-maybe-type-eq-in-env env a-ty b-ty)]
        [_ false])]
    [(AstExprComptime a-inner-box)
      (let
        [a-inner : AstExpr (ctfe-ast-get env a-inner-box)]
        (match b
          [(AstExprComptime b-inner-box)
            (let
              [b-inner : AstExpr (ctfe-ast-get env b-inner-box)]
              (ctfe-expr-eq-in-env env a-inner b-inner))]
          [_ false]))]
    [(AstExprQuote a-inner-box)
      (let
        [a-inner : AstExpr (ctfe-ast-get env a-inner-box)]
        (match b
          [(AstExprQuote b-inner-box)
            (let
              [b-inner : AstExpr (ctfe-ast-get env b-inner-box)]
              (ctfe-expr-eq-in-env env a-inner b-inner))]
          [_ false]))]
    [(AstExprQuasiquote a-inner-box)
      (let
        [a-inner : AstExpr (ctfe-ast-get env a-inner-box)]
        (match b
          [(AstExprQuasiquote b-inner-box)
            (let
              [b-inner : AstExpr (ctfe-ast-get env b-inner-box)]
              (ctfe-expr-eq-in-env env a-inner b-inner))]
          [_ false]))]
    [(AstExprUnquote a-inner-box)
      (let
        [a-inner : AstExpr (ctfe-ast-get env a-inner-box)]
        (match b
          [(AstExprUnquote b-inner-box)
            (let
              [b-inner : AstExpr (ctfe-ast-get env b-inner-box)]
              (ctfe-expr-eq-in-env env a-inner b-inner))]
          [_ false]))]
    [(AstExprUnquoteSplicing a-inner-box)
      (let
        [a-inner : AstExpr (ctfe-ast-get env a-inner-box)]
        (match b
          [(AstExprUnquoteSplicing b-inner-box)
            (let
              [b-inner : AstExpr (ctfe-ast-get env b-inner-box)]
              (ctfe-expr-eq-in-env env a-inner b-inner))]
          [_ false]))]
    [(AstExprTry a-inner-box)
      (let
        [a-inner : AstExpr (ctfe-ast-get env a-inner-box)]
        (match b
          [(AstExprTry b-inner-box)
            (let
              [b-inner : AstExpr (ctfe-ast-get env b-inner-box)]
              (ctfe-expr-eq-in-env env a-inner b-inner))]
          [_ false]))]
    [(AstExprReturn a-inner-box)
      (let
        [a-inner : AstExpr (ctfe-ast-get env a-inner-box)]
        (match b
          [(AstExprReturn b-inner-box)
            (let
              [b-inner : AstExpr (ctfe-ast-get env b-inner-box)]
              (ctfe-expr-eq-in-env env a-inner b-inner))]
          [_ false]))]
    [(AstExprPtrNull a-ty)
      (match b
        [(AstExprPtrNull b-ty) (ctfe-type-eq-in-env env a-ty b-ty)]
        [_ false])]
    [(AstExprPtrNullCheck a-inner-box)
      (let
        [a-inner : AstExpr (ctfe-ast-get env a-inner-box)]
        (match b
          [(AstExprPtrNullCheck b-inner-box)
            (let
              [b-inner : AstExpr (ctfe-ast-get env b-inner-box)]
              (ctfe-expr-eq-in-env env a-inner b-inner))]
          [_ false]))]
    [(AstExprStringData a-inner-box)
      (let
        [a-inner : AstExpr (ctfe-ast-get env a-inner-box)]
        (match b
          [(AstExprStringData b-inner-box)
            (let
              [b-inner : AstExpr (ctfe-ast-get env b-inner-box)]
              (ctfe-expr-eq-in-env env a-inner b-inner))]
          [_ false]))]
    [(AstExprStringFromBytes a-ptr-box a-len-box)
      (let
        [a-ptr : AstExpr (ctfe-ast-get env a-ptr-box)]
        [a-len : AstExpr (ctfe-ast-get env a-len-box)]
        (match b
          [(AstExprStringFromBytes b-ptr-box b-len-box)
            (let
              [b-ptr : AstExpr (ctfe-ast-get env b-ptr-box)]
              [b-len : AstExpr (ctfe-ast-get env b-len-box)]
              (and
                (ctfe-expr-eq-in-env env a-ptr b-ptr)
                (ctfe-expr-eq-in-env env a-len b-len)))]
          [_ false]))]
    [(AstExprArrayData a-inner-box)
      (let
        [a-inner : AstExpr (ctfe-ast-get env a-inner-box)]
        (match b
          [(AstExprArrayData b-inner-box)
            (let
              [b-inner : AstExpr (ctfe-ast-get env b-inner-box)]
              (ctfe-expr-eq-in-env env a-inner b-inner))]
          [_ false]))]
    [(AstExprBinaryData a-bytes)
      (match b
        [(AstExprBinaryData b-bytes) (string.string-eq a-bytes b-bytes)]
        [_ false])]
    [(AstExprProgramArgc)
      (match b
        [(AstExprProgramArgc) true]
        [_ false])]
    [(AstExprProgramArgv)
      (match b
        [(AstExprProgramArgv) true]
        [_ false])]
    [(AstExprProgramEnvp)
      (match b
        [(AstExprProgramEnvp) true]
        [_ false])]
    [(AstExprCpuIdEax a-leaf-box a-subleaf-box)
      (let
        [a-leaf : AstExpr (ctfe-ast-get env a-leaf-box)]
        [a-subleaf : AstExpr (ctfe-ast-get env a-subleaf-box)]
        (match b
          [(AstExprCpuIdEax b-leaf-box b-subleaf-box)
            (let
              [b-leaf : AstExpr (ctfe-ast-get env b-leaf-box)]
              [b-subleaf : AstExpr (ctfe-ast-get env b-subleaf-box)]
              (and
                (ctfe-expr-eq-in-env env a-leaf b-leaf)
                (ctfe-expr-eq-in-env env a-subleaf b-subleaf)))]
          [_ false]))]
    [(AstExprCpuIdEbx a-leaf-box a-subleaf-box)
      (let
        [a-leaf : AstExpr (ctfe-ast-get env a-leaf-box)]
        [a-subleaf : AstExpr (ctfe-ast-get env a-subleaf-box)]
        (match b
          [(AstExprCpuIdEbx b-leaf-box b-subleaf-box)
            (let
              [b-leaf : AstExpr (ctfe-ast-get env b-leaf-box)]
              [b-subleaf : AstExpr (ctfe-ast-get env b-subleaf-box)]
              (and
                (ctfe-expr-eq-in-env env a-leaf b-leaf)
                (ctfe-expr-eq-in-env env a-subleaf b-subleaf)))]
          [_ false]))]
    [(AstExprCpuIdEcx a-leaf-box a-subleaf-box)
      (let
        [a-leaf : AstExpr (ctfe-ast-get env a-leaf-box)]
        [a-subleaf : AstExpr (ctfe-ast-get env a-subleaf-box)]
        (match b
          [(AstExprCpuIdEcx b-leaf-box b-subleaf-box)
            (let
              [b-leaf : AstExpr (ctfe-ast-get env b-leaf-box)]
              [b-subleaf : AstExpr (ctfe-ast-get env b-subleaf-box)]
              (and
                (ctfe-expr-eq-in-env env a-leaf b-leaf)
                (ctfe-expr-eq-in-env env a-subleaf b-subleaf)))]
          [_ false]))]
    [(AstExprCpuIdEdx a-leaf-box a-subleaf-box)
      (let
        [a-leaf : AstExpr (ctfe-ast-get env a-leaf-box)]
        [a-subleaf : AstExpr (ctfe-ast-get env a-subleaf-box)]
        (match b
          [(AstExprCpuIdEdx b-leaf-box b-subleaf-box)
            (let
              [b-leaf : AstExpr (ctfe-ast-get env b-leaf-box)]
              [b-subleaf : AstExpr (ctfe-ast-get env b-subleaf-box)]
              (and
                (ctfe-expr-eq-in-env env a-leaf b-leaf)
                (ctfe-expr-eq-in-env env a-subleaf b-subleaf)))]
          [_ false]))]
    [(AstExprXgetbv a-index-box)
      (let
        [a-index : AstExpr (ctfe-ast-get env a-index-box)]
        (match b
          [(AstExprXgetbv b-index-box)
            (let
              [b-index : AstExpr (ctfe-ast-get env b-index-box)]
              (ctfe-expr-eq-in-env env a-index b-index))]
          [_ false]))]
    [(AstExprSyscall a-args)
      (match b
        [(AstExprSyscall b-args) (ctfe-expr-list-eq-in-env env a-args b-args)]
        [_ false])]
    [(AstExprSpanned a-inner-box _)
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
  (match a
    [(AstExprNil)
      (match b
        [(AstExprNil) true]
        [_ false])]
    [(AstExprCons a-head a-tail)
      (let
        [a-head : AstExpr (ctfe-ast-get env a-head)]
        [a-tail : AstExprList (box-get a-tail)]
        (match b
          [(AstExprCons b-head b-tail)
            (let
              [b-head : AstExpr (ctfe-ast-get env b-head)]
              [b-tail : AstExprList (box-get b-tail)]
              (and
                (ctfe-expr-eq-in-env env a-head b-head)
                (ctfe-expr-list-eq-in-env env a-tail b-tail)))]
          [_ false]))]))

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
  (match a
    [(AstExprClauseNil)
      (match b
        [(AstExprClauseNil) true]
        [_ false])]
    [(AstExprClauseCons a-head a-tail)
      (let
        [a-tail : AstExprClauseList (box-get a-tail)]
        (match b
          [(AstExprClauseCons b-head b-tail)
            (let
              [b-tail : AstExprClauseList (box-get b-tail)]
              (and
                (ctfe-expr-clause-eq-in-env env a-head b-head)
                (ctfe-expr-clause-list-eq-in-env env a-tail b-tail)))]
          [_ false]))]))

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
  (match a
    [(AstExprBindingClauseNil)
      (match b
        [(AstExprBindingClauseNil) true]
        [_ false])]
    [(AstExprBindingClauseCons a-head a-tail)
      (let
        [a-tail : AstExprBindingClauseList (box-get a-tail)]
        (match b
          [(AstExprBindingClauseCons b-head b-tail)
            (let
              [b-tail : AstExprBindingClauseList (box-get b-tail)]
              (and
                (ctfe-expr-binding-clause-eq-in-env env a-head b-head)
                (ctfe-expr-binding-clause-list-eq-in-env env a-tail b-tail)))]
          [_ false]))]))

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
    [(AstBinAdd)
      (match b
        [(AstBinAdd) true]
        [_ false])]
    [(AstBinSub)
      (match b
        [(AstBinSub) true]
        [_ false])]
    [(AstBinMul)
      (match b
        [(AstBinMul) true]
        [_ false])]
    [(AstBinDiv)
      (match b
        [(AstBinDiv) true]
        [_ false])]
    [(AstBinMod)
      (match b
        [(AstBinMod) true]
        [_ false])]
    [(AstBinEq)
      (match b
        [(AstBinEq) true]
        [_ false])]
    [(AstBinNe)
      (match b
        [(AstBinNe) true]
        [_ false])]
    [(AstBinLt)
      (match b
        [(AstBinLt) true]
        [_ false])]
    [(AstBinLe)
      (match b
        [(AstBinLe) true]
        [_ false])]
    [(AstBinGt)
      (match b
        [(AstBinGt) true]
        [_ false])]
    [(AstBinGe)
      (match b
        [(AstBinGe) true]
        [_ false])]
    [(AstBinAnd)
      (match b
        [(AstBinAnd) true]
        [_ false])]
    [(AstBinOr)
      (match b
        [(AstBinOr) true]
        [_ false])]
    [(AstBinBitAnd)
      (match b
        [(AstBinBitAnd) true]
        [_ false])]
    [(AstBinBitOr)
      (match b
        [(AstBinBitOr) true]
        [_ false])]
    [(AstBinBitXor)
      (match b
        [(AstBinBitXor) true]
        [_ false])]
    [(AstBinShl)
      (match b
        [(AstBinShl) true]
        [_ false])]
    [(AstBinShr)
      (match b
        [(AstBinShr) true]
        [_ false])]))

(define (ctfe-unop-eq [a : AstUnOp] [b : AstUnOp]) : bool
  (match a
    [(AstUnNeg)
      (match b
        [(AstUnNeg) true]
        [_ false])]
    [(AstUnNot)
      (match b
        [(AstUnNot) true]
        [_ false])]
    [(AstUnBitNot)
      (match b
        [(AstUnBitNot) true]
        [_ false])]))

;; CONSTRUCTORS ----------------------------------------------------------------
(define (ctfe-expr-literal [lit : AstLiteral]) : i64
  (ast-node-push (AstExprLiteral lit)))

(define (ctfe-expr-bool [b : bool]) : i64
  (ast-node-push (AstExprLiteral (AstLitBool b))))

(define (ctfe-expr-var [name : String]) : i64
  (ast-node-push (AstExprVar (intern name))))

(define (ctfe-expr-struct-get [target : i64] [field : String]) : i64
  (ast-expr-struct-get target field))

(define (ctfe-expr-if [cond : i64] [then-branch : i64] [else-branch : i64]) : i64
  (ast-expr-if cond then-branch else-branch))

(define (ctfe-expr-call [func : i64] [args : AstExprList]) : i64
  (ast-expr-call func args))

(define (ctfe-expr-begin [exprs : AstExprList]) : i64
  (ast-node-push (AstExprBegin exprs)))

;; LIST UTILITIES --------------------------------------------------------------
(define (ctfe-expr-list-empty) : AstExprList
  AstExprNil)

(define (ctfe-expr-list-singleton [e : i64]) : AstExprList
  (ast-expr-cons e AstExprNil))

(define (ctfe-expr-list-cons [head : i64] [tail : AstExprList]) : AstExprList
  (ast-expr-cons head tail))

(define (ctfe-expr-list-length [lst : AstExprList]) : i64
  (match lst
    [(AstExprNil) 0]
    [(AstExprCons _ rest)
      (let
        [rest : AstExprList (box-get rest)]
        (+ 1 (ctfe-expr-list-length rest)))]))

(define (ctfe-expr-list-empty? [lst : AstExprList]) : bool
  (match lst
    [(AstExprNil) true]
    [_ false]))

(define (ctfe-expr-clause-first [clause : AstExprClause]) : i64
  (struct-get clause first))

(define (ctfe-expr-clause-second [clause : AstExprClause]) : i64
  (struct-get clause second))

(define (ctfe-expr-clause-list-length [lst : AstExprClauseList]) : i64
  (match lst
    [(AstExprClauseNil) 0]
    [(AstExprClauseCons _ rest)
      (let
        [rest : AstExprClauseList (box-get rest)]
        (+ 1 (ctfe-expr-clause-list-length rest)))]))

(define (ctfe-expr-clause-list-empty? [lst : AstExprClauseList]) : bool
  (match lst
    [(AstExprClauseNil) true]
    [_ false]))

(define (ctfe-expr-clause-list-head [lst : AstExprClauseList]) : AstExprClause
  (match lst
    [(AstExprClauseCons head _) head]
    [_
      (ast-expr-clause
        (ast-node-push (AstExprLiteral (AstLitUnit)))
        (ast-node-push (AstExprLiteral (AstLitUnit))))]))

(define (ctfe-expr-clause-list-tail [lst : AstExprClauseList]) : AstExprClauseList
  (match lst
    [(AstExprClauseCons _ tail)
      (let
        [tail : AstExprClauseList (box-get tail)]
        tail)]
    [_ AstExprClauseNil]))

(define (ctfe-expr-clause-list-nth [lst : AstExprClauseList] [index : i64]) : AstExprClause
  (match lst
    [(AstExprClauseCons head tail)
      (if (= index 0)
        head
        (ctfe-expr-clause-list-nth (box-get tail) (- index 1)))]
    [_
      (ast-expr-clause
        (ast-node-push (AstExprLiteral (AstLitUnit)))
        (ast-node-push (AstExprLiteral (AstLitUnit))))]))

(define (ctfe-expr-clause-as-bracket-expr-in-env
  [env : CtfeEnv]
  [clause : AstExprClause]) : i64
  (ast-expr-bracket-clause-with-pools
    (ctfe-env-pools env)
    (ast-expr-cons
      (ctfe-expr-clause-first clause)
      (ast-expr-cons (ctfe-expr-clause-second clause) AstExprNil))))

(define (ctfe-expr-clause-as-bracket-expr [clause : AstExprClause]) : i64
  (ctfe-expr-clause-as-bracket-expr-in-env (ctfe-env-empty) clause))

(define (ctfe-expr-clause-list->expr-list-in-env
  [env : CtfeEnv]
  [lst : AstExprClauseList]) : AstExprList
  (match lst
    [(AstExprClauseNil) AstExprNil]
    [(AstExprClauseCons head rest)
      (ast-expr-cons
        (ctfe-expr-clause-as-bracket-expr-in-env env head)
        (ctfe-expr-clause-list->expr-list-in-env env (box-get rest)))]))

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
  (match lst
    [(AstExprBindingClauseNil) 0]
    [(AstExprBindingClauseCons _ rest)
      (let
        [rest : AstExprBindingClauseList (box-get rest)]
        (+ 1 (ctfe-expr-binding-clause-list-length rest)))]))

(define (ctfe-expr-binding-clause-list-empty? [lst : AstExprBindingClauseList]) : bool
  (match lst
    [(AstExprBindingClauseNil) true]
    [_ false]))

(define (ctfe-expr-binding-clause-empty-default) : AstExprBindingClause
  (let
    [unit-expr : i64 (ast-node-push (AstExprLiteral (AstLitUnit)))]
    (ast-expr-binding-clause-id
      0
      false
      unit-expr
      unit-expr
      (AstSourceSpan 0 0 0 0))))

(define (ctfe-expr-binding-clause-list-head [lst : AstExprBindingClauseList]) : AstExprBindingClause
  (match lst
    [(AstExprBindingClauseCons head _) head]
    [_ (ctfe-expr-binding-clause-empty-default)]))

(define (ctfe-expr-binding-clause-list-tail [lst : AstExprBindingClauseList]) : AstExprBindingClauseList
  (match lst
    [(AstExprBindingClauseCons _ tail)
      (let
        [tail : AstExprBindingClauseList (box-get tail)]
        tail)]
    [_ AstExprBindingClauseNil]))

(define (ctfe-expr-binding-clause-list-nth
  [lst : AstExprBindingClauseList]
  [index : i64]) : AstExprBindingClause
  (match lst
    [(AstExprBindingClauseCons head tail)
      (if (= index 0)
        head
        (ctfe-expr-binding-clause-list-nth (box-get tail) (- index 1)))]
    [_ (ctfe-expr-binding-clause-empty-default)]))

(define (ctfe-expr-binding-clause-as-bracket-expr-in-env
  [env : CtfeEnv]
  [clause : AstExprBindingClause]) : i64
  (let
    [name-expr : i64 (ctfe-ast-push env (AstExprVar (struct-get clause name)))]
    [bracket : i64
      (if (struct-get clause has-type)
        (ast-expr-bracket-clause-with-pools
          (ctfe-env-pools env)
          (ast-expr-cons
            name-expr
            (ast-expr-cons
              (ctfe-ast-push env (AstExprVar (intern ":")))
              (ast-expr-cons
                (struct-get clause ty)
                (ast-expr-cons (struct-get clause init) AstExprNil)))))
        (ast-expr-bracket-clause-with-pools
          (ctfe-env-pools env)
          (ast-expr-cons
            name-expr
            (ast-expr-cons (struct-get clause init) AstExprNil))))]
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
  (match lst
    [(AstExprBindingClauseNil) AstExprNil]
    [(AstExprBindingClauseCons head rest)
      (ast-expr-cons
        (ctfe-expr-binding-clause-as-bracket-expr-in-env env head)
        (ctfe-expr-binding-clause-list->expr-list-in-env env (box-get rest)))]))

(define (ctfe-expr-binding-clause-list->expr-list
  [lst : AstExprBindingClauseList]) : AstExprList
  (ctfe-expr-binding-clause-list->expr-list-in-env (ctfe-env-empty) lst))

;; INSPECTORS (predicates) -----------------------------------------------------
(define (ctfe-expr-literal?-in-env [env : CtfeEnv] [e : i64]) : bool
  (match (ctfe-ast-get env e)
    [(AstExprLiteral _) true]
    [_ false]))

(define (ctfe-expr-bool?-in-env [env : CtfeEnv] [e : i64]) : bool
  (match (ctfe-ast-get env e)
    [(AstExprLiteral lit)
      (match lit
        [(AstLitBool _) true]
        [_ false])]
    [_ false]))

(define (ctfe-expr-bool-value-in-env [env : CtfeEnv] [e : i64]) : bool
  (match (ctfe-ast-get env e)
    [(AstExprLiteral lit)
      (match lit
        [(AstLitBool b) b]
        [_ false])]
    [_ false]))

(define (ctfe-expr-var?-in-env [env : CtfeEnv] [e : i64]) : bool
  (match (ctfe-ast-get env e)
    [(AstExprVar _) true]
    [_ false]))

(define (ctfe-expr-if?-in-env [env : CtfeEnv] [e : i64]) : bool
  (match (ctfe-ast-get env e)
    [(AstExprIf _ _ _) true]
    [_ false]))

(define (ctfe-expr-call?-in-env [env : CtfeEnv] [e : i64]) : bool
  (match (ctfe-ast-get env e)
    [(AstExprCall _ _) true]
    [_ false]))

;; INSPECTORS (extractors) -----------------------------------------------------
(define (ctfe-expr-literal-value-in-env [env : CtfeEnv] [e : i64]) : AstLiteral
  (match (ctfe-ast-get env e)
    [(AstExprLiteral lit) lit]
    [_ (AstLitUnit)]))

(define (ctfe-expr-var-name-in-env [env : CtfeEnv] [e : i64]) : String
  (match (ctfe-ast-get env e)
    [(AstExprVar name) (intern-str name)]
    [_ ""]))

(define (ctfe-expr-if-cond-in-env [env : CtfeEnv] [e : i64]) : i64
  (match (ctfe-ast-get env e)
    [(AstExprIf c _ _) c]
    [_ (ctfe-ast-push env (AstExprLiteral (AstLitUnit)))]))

(define (ctfe-expr-if-then-in-env [env : CtfeEnv] [e : i64]) : i64
  (match (ctfe-ast-get env e)
    [(AstExprIf _ t _) t]
    [_ (ctfe-ast-push env (AstExprLiteral (AstLitUnit)))]))

(define (ctfe-expr-if-else-in-env [env : CtfeEnv] [e : i64]) : i64
  (match (ctfe-ast-get env e)
    [(AstExprIf _ _ el) el]
    [_ (ctfe-ast-push env (AstExprLiteral (AstLitUnit)))]))

(define (ctfe-expr-call-func-in-env [env : CtfeEnv] [e : i64]) : i64
  (match (ctfe-ast-get env e)
    [(AstExprCall f _) f]
    [_ (ctfe-ast-push env (AstExprLiteral (AstLitUnit)))]))

(define (ctfe-expr-call-args-in-env [env : CtfeEnv] [e : i64]) : AstExprList
  (match (ctfe-ast-get env e)
    [(AstExprCall _ args) args]
    [_ AstExprNil]))

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
  (match lst
    [(AstExprCons head _) head]
    [_ (ast-node-push (AstExprLiteral (AstLitUnit)))]))

(define (ctfe-expr-list-tail [lst : AstExprList]) : AstExprList
  (match lst
    [(AstExprCons _ tail)
      (let
        [tail : AstExprList (box-get tail)]
        tail)]
    [_ AstExprNil]))

(define (ctfe-expr-list-nth [lst : AstExprList] [index : i64]) : i64
  (match lst
    [(AstExprCons head tail)
      (if (= index 0)
        head
        (ctfe-expr-list-nth (box-get tail) (- index 1)))]
    [_ (ast-node-push (AstExprLiteral (AstLitUnit)))]))

;; --- folding ----------------------------------------------------------------
;; Convert a folded compile-time value into the AST literal that lowering then
;; materializes through the ordinary literal path. Expr / ExprList values are
;; compile-time only and have no runtime literal form; this is used for scalar
;; value lowering.
(define (ctfe-value-to-literal [value : CompilerCtfeValue]) : AstLiteral
  (match value
    [(CtfeI64 n) (ast-lit-int n)]
    [(CtfeF64 n) (AstLitFloat (compiler-float-format-f64 n))]
    [(CtfeF32 n)
      (AstLitFloat
        (compiler-float-format-f64 (compiler-float-round-f32-as-f64 n)))]
    [(CtfeBool b) (AstLitBool b)]
    [(CtfeChar c) (AstLitChar c)]
    [(CtfeString text) (AstLitString text)]
    [(CtfeUnit) (AstLitUnit)]
    [(CtfeType _) (AstLitUnit)]
    [(CtfeExpr _ _) (AstLitUnit)]
    [(CtfeExprList _) (AstLitUnit)]
    [(CtfeExprClause _) (AstLitUnit)]
    [(CtfeExprClauseList _) (AstLitUnit)]
    [(CtfeExprBindingClause _) (AstLitUnit)]
    [(CtfeExprBindingClauseList _) (AstLitUnit)]))

(define (ctfe-value-to-literal-for-type
  [value : CompilerCtfeValue]
  [ty : AstType]) : AstLiteral
  (match ty
    [(AstTyF32)
      (match value
        [(CtfeF64 n)
          (AstLitFloat
            (compiler-float-format-f64 (compiler-float-round-f32-as-f64 n)))]
        [_ (ctfe-value-to-literal value)])]
    [(AstTyRegion _ inner)
      (ctfe-value-to-literal-for-type value (ty-node-get inner))]
    [_ (ctfe-value-to-literal value)]))

(define (ctfe-type-list-eq-in-env
  [env : CtfeEnv]
  [a : AstTypeList]
  [b : AstTypeList]) : bool
  (match a
    [(AstTypeNil)
      (match b
        [(AstTypeNil) true]
        [_ false])]
    [(AstTypeCons ah at)
      (let
        [ah : AstType (ctfe-ty-get env ah)]
        [at : AstTypeList (box-get at)]
        (match b
          [(AstTypeCons bh bt)
            (let
              [bh : AstType (ctfe-ty-get env bh)]
              [bt : AstTypeList (box-get bt)]
              (and
                (ctfe-type-eq-in-env env ah bh)
                (ctfe-type-list-eq-in-env env at bt)))]
          [_ false]))]))

(define (ctfe-type-eq-in-env [env : CtfeEnv] [a : AstType] [b : AstType]) : bool
  (match a
    [(AstTyI64)
      (match b
        [(AstTyI64) true]
        [_ false])]
    [(AstTyI32)
      (match b
        [(AstTyI32) true]
        [_ false])]
    [(AstTyI16)
      (match b
        [(AstTyI16) true]
        [_ false])]
    [(AstTyI8)
      (match b
        [(AstTyI8) true]
        [_ false])]
    [(AstTyU64)
      (match b
        [(AstTyU64) true]
        [_ false])]
    [(AstTyU32)
      (match b
        [(AstTyU32) true]
        [_ false])]
    [(AstTyU16)
      (match b
        [(AstTyU16) true]
        [_ false])]
    [(AstTyU8)
      (match b
        [(AstTyU8) true]
        [_ false])]
    [(AstTyF64)
      (match b
        [(AstTyF64) true]
        [_ false])]
    [(AstTyF32)
      (match b
        [(AstTyF32) true]
        [_ false])]
    [(AstTyBool)
      (match b
        [(AstTyBool) true]
        [_ false])]
    [(AstTyChar)
      (match b
        [(AstTyChar) true]
        [_ false])]
    [(AstTyString)
      (match b
        [(AstTyString) true]
        [_ false])]
    [(AstTyStr)
      (match b
        [(AstTyStr) true]
        [_ false])]
    [(AstTyBytes)
      (match b
        [(AstTyBytes) true]
        [_ false])]
    [(AstTyUnit)
      (match b
        [(AstTyUnit) true]
        [_ false])]
    [(AstTyNever)
      (match b
        [(AstTyNever) true]
        [_ false])]
    [(AstTyExpr)
      (match b
        [(AstTyExpr) true]
        [_ false])]
    [(AstTyExprList)
      (match b
        [(AstTyExprList) true]
        [_ false])]
    [(AstTyFunc a-args a-ret)
      (match b
        [(AstTyFunc b-args b-ret)
          (and
            (ctfe-type-list-eq-in-env env (box-get a-args) (box-get b-args))
            (ctfe-type-eq-in-env
              env
              (ctfe-ty-get env a-ret)
              (ctfe-ty-get env b-ret)))]
        [_ false])]
    [(AstTyTuple a-elems)
      (match b
        [(AstTyTuple b-elems)
          (ctfe-type-list-eq-in-env env (box-get a-elems) (box-get b-elems))]
        [_ false])]
    [(AstTyArray a-elem a-count)
      (match b
        [(AstTyArray b-elem b-count)
          (and
            (= a-count b-count)
            (ctfe-type-eq-in-env
              env
              (ctfe-ty-get env a-elem)
              (ctfe-ty-get env b-elem)))]
        [_ false])]
    [(AstTyDynArray a-elem)
      (match b
        [(AstTyDynArray b-elem)
          (ctfe-type-eq-in-env
            env
            (ctfe-ty-get env a-elem)
            (ctfe-ty-get env b-elem))]
        [_ false])]
    [(AstTyBox a-elem)
      (match b
        [(AstTyBox b-elem)
          (ctfe-type-eq-in-env
            env
            (ctfe-ty-get env a-elem)
            (ctfe-ty-get env b-elem))]
        [_ false])]
    [(AstTyPtr a-elem)
      (match b
        [(AstTyPtr b-elem)
          (ctfe-type-eq-in-env
            env
            (ctfe-ty-get env a-elem)
            (ctfe-ty-get env b-elem))]
        [_ false])]
    [(AstTyMutPtr a-elem)
      (match b
        [(AstTyMutPtr b-elem)
          (ctfe-type-eq-in-env
            env
            (ctfe-ty-get env a-elem)
            (ctfe-ty-get env b-elem))]
        [_ false])]
    [(AstTyRef a-region a-inner)
      (match b
        [(AstTyRef b-region b-inner)
          (and
            (string.string-eq a-region b-region)
            (ctfe-type-eq-in-env
              env
              (ctfe-ty-get env a-inner)
              (ctfe-ty-get env b-inner)))]
        [_ false])]
    [(AstTyMutRef a-region a-inner)
      (match b
        [(AstTyMutRef b-region b-inner)
          (and
            (string.string-eq a-region b-region)
            (ctfe-type-eq-in-env
              env
              (ctfe-ty-get env a-inner)
              (ctfe-ty-get env b-inner)))]
        [_ false])]
    [(AstTyRegion a-region a-inner)
      (match b
        [(AstTyRegion b-region b-inner)
          (and
            (string.string-eq a-region b-region)
            (ctfe-type-eq-in-env
              env
              (ctfe-ty-get env a-inner)
              (ctfe-ty-get env b-inner)))]
        [_ false])]
    [(AstTyEnum a-name)
      (match b
        [(AstTyEnum b-name) (= a-name b-name)]
        [_ false])]
    [(AstTyEnumArgs a-name a-lifetimes)
      (match b
        [(AstTyEnumArgs b-name b-lifetimes)
          (and
            (= a-name b-name)
            (ctfe-lifetime-list-eq (box-get a-lifetimes) (box-get b-lifetimes)))]
        [_ false])]
    [(AstTyStruct a-name)
      (match b
        [(AstTyStruct b-name) (= a-name b-name)]
        [_ false])]
    [(AstTyStructArgs a-name a-lifetimes)
      (match b
        [(AstTyStructArgs b-name b-lifetimes)
          (and
            (= a-name b-name)
            (ctfe-lifetime-list-eq (box-get a-lifetimes) (box-get b-lifetimes)))]
        [_ false])]
    [(AstTyVar a-name)
      (match b
        [(AstTyVar b-name) (= a-name b-name)]
        [_ false])]
    [(AstTyVarArgs a-name a-lifetimes)
      (match b
        [(AstTyVarArgs b-name b-lifetimes)
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
    [want : AstType (ast-ty-array (AstTyI64) 4)]
    (match (compiler-ctfe-eval
      (AstExprTypeLiteral want)
      (ctfe-env-empty)
      (ctfe-fuel-limit))
      [(OkCtfe value _)
        (match value
          [(CtfeType actual)
            (and
              (ctfe-type-eq actual want)
              (string.string-eq (ctfe-value-type-name value) "type"))]
          [_ false])]
      [(ErrCtfe _) false])))

(define (compiler-ctfe-type-comparison-ok?) : bool
  (match (compiler-ctfe-eval
    (AstExprBinary
      (AstBinEq)
      (ast-node-push (AstExprTypeLiteral (AstTyI64)))
      (ast-node-push (AstExprTypeLiteral (AstTyI64))))
    (ctfe-env-empty)
    (ctfe-fuel-limit))
    [(OkCtfe same _)
      (match same
        [(CtfeBool same-ok)
          (match (compiler-ctfe-eval
            (AstExprBinary
              (AstBinEq)
              (ast-node-push (AstExprTypeLiteral (AstTyI64)))
              (ast-node-push (AstExprTypeLiteral (AstTyI32))))
            (ctfe-env-empty)
            (ctfe-fuel-limit))
            [(OkCtfe different _)
              (match different
                [(CtfeBool different-ok) (and same-ok (not different-ok))]
                [_ false])]
            [(ErrCtfe _) false])]
        [_ false])]
    [(ErrCtfe _) false]))

(define (compiler-ctfe-raw-pointer-type-comparison-ok?) : bool
  (match (compiler-ctfe-eval
    (AstExprBinary
      (AstBinEq)
      (ast-node-push (AstExprTypeLiteral (ast-ty-ptr (AstTyI64))))
      (ast-node-push (AstExprTypeLiteral (ast-ty-ptr (AstTyI64)))))
    (ctfe-env-empty)
    (ctfe-fuel-limit))
    [(OkCtfe same _)
      (match same
        [(CtfeBool same-ok)
          (match (compiler-ctfe-eval
            (AstExprBinary
              (AstBinEq)
              (ast-node-push (AstExprTypeLiteral (ast-ty-ptr (AstTyI64))))
              (ast-node-push (AstExprTypeLiteral (ast-ty-mut-ptr (AstTyI64)))))
            (ctfe-env-empty)
            (ctfe-fuel-limit))
            [(OkCtfe different _)
              (match different
                [(CtfeBool different-ok) (and same-ok (not different-ok))]
                [_ false])]
            [(ErrCtfe _) false])]
        [_ false])]
    [(ErrCtfe _) false]))

(define (compiler-ctfe-call1 [name : String] [arg : i64]) : i64
  (ast-expr-call
    (ast-node-push (AstExprVar (intern name)))
    (ast-expr-cons arg AstExprNil)))

(define (compiler-ctfe-call2 [name : String] [a : i64] [b : i64]) : i64
  (ast-expr-call
    (ast-node-push (AstExprVar (intern name)))
    (ast-expr-cons a (ast-expr-cons b AstExprNil))))

(define (compiler-ctfe-call3 [name : String] [a : i64] [b : i64] [c : i64]) : i64
  (ast-expr-call
    (ast-node-push (AstExprVar (intern name)))
    (ast-expr-cons a (ast-expr-cons b (ast-expr-cons c AstExprNil)))))

(define (compiler-ctfe-call1-in-env [env : CtfeEnv] [name : String] [arg : i64]) : i64
  (ast-expr-call-with-pools
    (ctfe-env-pools env)
    (ctfe-ast-push env (AstExprVar (intern name)))
    (ast-expr-cons arg AstExprNil)))

(define (compiler-ctfe-call2-in-env
  [env : CtfeEnv]
  [name : String]
  [a : i64]
  [b : i64]) : i64
  (ast-expr-call-with-pools
    (ctfe-env-pools env)
    (ctfe-ast-push env (AstExprVar (intern name)))
    (ast-expr-cons a (ast-expr-cons b AstExprNil))))

(define (compiler-ctfe-call3-in-env
  [env : CtfeEnv]
  [name : String]
  [a : i64]
  [b : i64]
  [c : i64]) : i64
  (ast-expr-call-with-pools
    (ctfe-env-pools env)
    (ctfe-ast-push env (AstExprVar (intern name)))
    (ast-expr-cons a (ast-expr-cons b (ast-expr-cons c AstExprNil)))))

(define (compiler-ctfe-eval-i64-ok? [expr : i64] [env : CtfeEnv] [want : i64]) : bool
  (match (compiler-ctfe-eval (ctfe-ast-get env expr) env (ctfe-fuel-limit))
    [(OkCtfe value _)
      (match value
        [(CtfeI64 actual) (= actual want)]
        [_ false])]
    [(ErrCtfe _) false]))

(define (compiler-ctfe-eval-f64-ok? [expr : i64] [env : CtfeEnv] [want : f64]) : bool
  (match (compiler-ctfe-eval (ctfe-ast-get env expr) env (ctfe-fuel-limit))
    [(OkCtfe value _)
      (match value
        [(CtfeF64 actual) (= actual want)]
        [_ false])]
    [(ErrCtfe _) false]))

(define (compiler-ctfe-eval-f32-ok? [expr : i64] [env : CtfeEnv] [want : f64]) : bool
  (match (compiler-ctfe-eval (ctfe-ast-get env expr) env (ctfe-fuel-limit))
    [(OkCtfe value _)
      (match value
        [(CtfeF32 actual) (= actual want)]
        [_ false])]
    [(ErrCtfe _) false]))

(define (compiler-ctfe-eval-bool-ok? [expr : i64] [env : CtfeEnv] [want : bool]) : bool
  (match (compiler-ctfe-eval (ctfe-ast-get env expr) env (ctfe-fuel-limit))
    [(OkCtfe value _)
      (match value
        [(CtfeBool actual)
          (if want
            actual
            (not actual))]
        [_ false])]
    [(ErrCtfe _) false]))

(define (compiler-ctfe-eval-string-ok?
  [expr : i64]
  [env : CtfeEnv]
  [want : String]) : bool
  (match (compiler-ctfe-eval (ctfe-ast-get env expr) env (ctfe-fuel-limit))
    [(OkCtfe value _)
      (match value
        [(CtfeString actual) (string.string-eq actual want)]
        [_ false])]
    [(ErrCtfe _) false]))

(define (compiler-ctfe-eval-type-ok?
  [expr : i64]
  [env : CtfeEnv]
  [want : AstType]) : bool
  (match (compiler-ctfe-eval (ctfe-ast-get env expr) env (ctfe-fuel-limit))
    [(OkCtfe value _)
      (match value
        [(CtfeType actual) (ctfe-type-eq actual want)]
        [_ false])]
    [(ErrCtfe _) false]))

(define (compiler-ctfe-eval-error-ok?
  [expr : i64]
  [env : CtfeEnv]
  [want : String]) : bool
  (match (compiler-ctfe-eval (ctfe-ast-get env expr) env (ctfe-fuel-limit))
    [(ErrCtfe diag) (string.string-eq (compiler-diagnostic-message diag) want)]
    [(OkCtfe _ _) false]))

(define (compiler-ctfe-f64-ok?) : bool
  (let
    [one-five : i64 (ast-node-push (AstExprLiteral (AstLitFloat "1.5")))]
    [two-quarter : i64 (ast-node-push (AstExprLiteral (AstLitFloat "2.25")))]
    [zero : i64 (ast-node-push (AstExprLiteral (AstLitFloat "0.0")))]
    [neg-zero : i64 (ast-node-push (AstExprLiteral (AstLitFloat "-0.0")))]
    [one-f32 : i64 (ast-expr-cast one-five (AstTyF32))]
    [zero-f32 : i64 (ast-expr-cast zero (AstTyF32))]
    [sum-f32 : i64 (ast-node-push (AstExprBinary (AstBinAdd) one-f32 zero-f32))]
    [neg-f32 : i64 (ast-node-push (AstExprUnary (AstUnNeg) sum-f32))]
    [wide-f32 : i64 (ast-expr-cast one-f32 (AstTyF64))]
    [large-f32 : i64
      (ast-expr-cast
        (ast-node-push (AstExprLiteral (AstLitFloat "3.0e+38")))
        (AstTyF32))]
    [two-f32 : i64
      (ast-expr-cast
        (ast-node-push (AstExprLiteral (AstLitFloat "2.0")))
        (AstTyF32))]
    [overflow-f32 : i64
      (ast-node-push (AstExprBinary (AstBinMul) large-f32 two-f32))]
    [overflow-f32-cast : i64
      (ast-expr-cast
        (ast-node-push (AstExprLiteral (AstLitFloat "3.5e+38")))
        (AstTyF32))]
    [overflow-f64-left : i64
      (ast-node-push (AstExprLiteral (AstLitFloat "1e+308")))]
    [overflow-f64 : i64
      (ast-node-push
        (AstExprBinary (AstBinMul) overflow-f64-left overflow-f64-left))]
    [non-finite-f64-literal : i64
      (ast-node-push (AstExprLiteral (AstLitFloat "1e+309")))]
    [sum : i64 (ast-node-push (AstExprBinary (AstBinAdd) one-five two-quarter))]
    [neg : i64 (ast-node-push (AstExprUnary (AstUnNeg) sum))]
    [neg-int : i64 (ast-node-push (AstExprLiteral (ast-lit-int (- 0 42))))]
    [u64-max : i64
      (ast-expr-cast
        (ast-node-push (AstExprLiteral (ast-lit-int (- 0 1))))
        (AstTyU64))]
    [u64-max-f64 : i64 (ast-expr-cast u64-max (AstTyF64))]
    [u64-max-f32 : i64 (ast-expr-cast u64-max (AstTyF32))]
    [u64-var : i64 (ast-node-push (AstExprVar (intern "x")))]
    [typed-let-u64-max-f64 : i64
      (ast-expr-let
        (ast-let-binding-cons
          (ast-let-binding "x" (AstSomeType (AstTyU64)) u64-max)
          AstLetBindingNil)
        (ast-expr-cast u64-var (AstTyF64)))]
    [untyped-let-u64-max-f64 : i64
      (ast-expr-let
        (ast-let-binding-cons
          (ast-let-binding "x" (AstNoType) u64-max)
          AstLetBindingNil)
        (ast-expr-cast u64-var (AstTyF64)))]
    [match-u64-var : i64 (ast-node-push (AstExprVar (intern "m")))]
    [match-u64-max-f64 : i64
      (ast-expr-match
        u64-max
        (ast-match-arm-cons
          (ast-match-arm
            (ast-pat-binding "m")
            (ast-expr-cast match-u64-var (AstTyF64)))
          AstMatchArmNil))]
    [char-a : i64 (ast-node-push (AstExprLiteral (AstLitChar 'A')))]
    [char-a-f64 : i64 (ast-expr-cast char-a (AstTyF64))]
    [neg-int-f64 : i64 (ast-expr-cast neg-int (AstTyF64))]
    [rounded-int-f32 : i64
      (ast-expr-cast
        (ast-node-push (AstExprLiteral (ast-lit-int 16777217)))
        (AstTyF32))]
    [f64-to-i64 : i64 (ast-expr-cast sum (AstTyI64))]
    [f32-to-i64 : i64 (ast-expr-cast one-f32 (AstTyI64))]
    [f64-to-char-to-i64 : i64
      (ast-expr-cast
        (ast-expr-cast
          (ast-node-push (AstExprLiteral (AstLitFloat "65.9")))
          (AstTyChar))
        (AstTyI64))]
    [f64-out-of-i64 : i64
      (ast-expr-cast
        (ast-node-push (AstExprLiteral (AstLitFloat "9223372036854775808.0")))
        (AstTyI64))]
    [f64-out-of-u64-portable-range : i64
      (ast-expr-cast
        (ast-node-push (AstExprLiteral (AstLitFloat "9223372036854775808.0")))
        (AstTyU64))]
    [lt : i64
      (ast-node-push
        (AstExprBinary
          (AstBinLt)
          sum
          (ast-node-push (AstExprLiteral (AstLitFloat "4.0")))))]
    [div-zero : i64 (ast-node-push (AstExprBinary (AstBinDiv) one-five zero))]
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
      (ast-node-push (AstExprTypeLiteral (AstTyVar (intern "Packet"))))]
    [box-ty : i64
      (ast-node-push (AstExprTypeLiteral (AstTyVar (intern "Box"))))]
    [choice-ty : i64
      (ast-node-push (AstExprTypeLiteral (AstTyVar (intern "Choice"))))]
    [packet-fields : CtfeLayoutFieldList
      (ctfe-layout-field-list-push
        (ctfe-layout-field-list-push
          (ctfe-layout-field-list-with-capacity 2)
          (CtfeLayoutField "tag" 0))
        (CtfeLayoutField "count" 8))]
    [box-fields : CtfeLayoutFieldList
      (ctfe-layout-field-list-push
        (ctfe-layout-field-list-with-capacity 1)
        (CtfeLayoutField "x" 0))]
    [layouts : CtfeLayoutInfoList
      (ctfe-layout-info-list-push
        (ctfe-layout-info-list-push
          (ctfe-layout-info-list-push
            (ctfe-layout-info-list-with-capacity 3)
            (CtfeLayoutInfo "Packet" true 16 8 packet-fields))
          (CtfeLayoutInfo "Box" true 8 8 box-fields))
        (CtfeLayoutInfo "Choice" false 24 8 (ctfe-layout-field-list-empty)))]
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
          (ast-node-push (AstExprVar (intern "count"))))
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
          (ast-node-push (AstExprVar (intern "x"))))
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
          (ast-node-push (AstExprVar (intern "tag"))))
        env
        "offset-of requires struct layout type")
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-error-ok?
        (compiler-ctfe-call2
          "offset-of"
          packet-ty
          (ast-node-push (AstExprVar (intern "missing"))))
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
          (CtfeReflectField "x" (AstTyI64)))
        (CtfeReflectField "flag" (AstTyBool)))]
    [maybe-variants : CtfeReflectVariantList
      (ctfe-reflect-variant-list-push
        (ctfe-reflect-variant-list-push
          (ctfe-reflect-variant-list-with-capacity 2)
          (CtfeReflectVariant "None" AstTypeNil))
        (CtfeReflectVariant "Some" (ast-type-cons (AstTyString) AstTypeNil)))]
    [infos : CtfeReflectInfoList
      (ctfe-reflect-info-list-push
        (ctfe-reflect-info-list-push
          (ctfe-reflect-info-list-with-capacity 2)
          (CtfeReflectStruct "Point" "" "Point" point-fields))
        (CtfeReflectEnum "Maybe" "" "Maybe" maybe-variants))]
    (ctfe-env-with-reflections infos)))

(define (compiler-ctfe-reflection-query-ok?) : bool
  (let
    [env : CtfeEnv (compiler-ctfe-reflection-env)]
    [point-ty : i64
      (ast-node-push (AstExprTypeLiteral (AstTyVar (intern "Point"))))]
    [maybe-ty : i64
      (ast-node-push (AstExprTypeLiteral (AstTyVar (intern "Maybe"))))]
    [array-ty : i64
      (ast-node-push (AstExprTypeLiteral (ast-ty-array (AstTyI64) 4)))]
    [dyn-array-ty : i64
      (ast-node-push (AstExprTypeLiteral (ast-ty-dyn-array (AstTyBool))))]
    [str-ref-ty : i64
      (ast-node-push (AstExprTypeLiteral (ast-ty-ref "r" (AstTyStr))))]
    [fn-ty : i64
      (ast-node-push
        (AstExprTypeLiteral
          (ast-ty-func
            (ast-type-cons (AstTyI64) (ast-type-cons (AstTyBool) AstTypeNil))
            (AstTyString))))]
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
          (ast-node-push (AstExprTypeLiteral (AstTyI64))))
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
          (ast-node-push (AstExprLiteral (ast-lit-int 1))))
        env
        "flag")
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-type-ok?
        (compiler-ctfe-call2
          "struct-field-type"
          point-ty
          (ast-node-push (AstExprLiteral (ast-lit-int 0))))
        env
        (AstTyI64))
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
          (ast-node-push (AstExprLiteral (ast-lit-int 1))))
        env
        "Some")
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-i64-ok?
        (compiler-ctfe-call2
          "enum-variant-payload-count"
          maybe-ty
          (ast-node-push (AstExprLiteral (ast-lit-int 1))))
        env
        1)
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-type-ok?
        (compiler-ctfe-call3
          "enum-variant-payload-type"
          maybe-ty
          (ast-node-push (AstExprLiteral (ast-lit-int 1)))
          (ast-node-push (AstExprLiteral (ast-lit-int 0))))
        env
        (AstTyString))
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-type-ok?
        (compiler-ctfe-call1 "array-element-type" array-ty)
        env
        (AstTyI64))
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
        (compiler-ctfe-call1 "function-param-count" fn-ty)
        env
        2)
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-type-ok?
        (compiler-ctfe-call2
          "function-param-type"
          fn-ty
          (ast-node-push (AstExprLiteral (ast-lit-int 1))))
        env
        (AstTyBool))
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-type-ok?
        (compiler-ctfe-call1 "function-return-type" fn-ty)
        env
        (AstTyString))
        unit
        (set! ok false))
      ok)))

(define (compiler-ctfe-reflection-program) : AstProgram
  (let
    [fields : AstFieldDefList
      (AstFieldDefCons
        (AstFieldDef (intern "id") (AstTyI64) (AstFieldNoCleanup))
        (box
          (AstFieldDefCons
            (AstFieldDef (intern "label") (AstTyString) (AstFieldNoCleanup))
            (box AstFieldDefNil))))]
    [variants : AstVariantDefList
      (AstVariantDefCons
        (AstVariantDef (intern "Ready") AstTypeNil AstVariantPayloadCleanupNil)
        (box
          (AstVariantDefCons
            (AstVariantDef
              (intern "Failed")
              (ast-type-cons (AstTyString) AstTypeNil)
              AstVariantPayloadCleanupNil)
            (box AstVariantDefNil))))]
    (AstProgram
      (box
        (AstDeclCons
          (AstDeclDefStruct
            (intern "Record")
            (AstStructReprDefault)
            (AstStructNoCleanup)
            fields)
          (box
            (AstDeclCons
              (AstDeclDefEnum (intern "Status") (AstEnumNoCleanup) variants)
              (box AstDeclNil))))))))

(define (compiler-ctfe-reflection-from-program-ok?) : bool
  (let
    [env : CtfeEnv
      (ctfe-env-with-reflections
        (ctfe-reflections-from-program (compiler-ctfe-reflection-program)))]
    [record-ty : i64
      (ast-node-push (AstExprTypeLiteral (AstTyVar (intern "Record"))))]
    [status-ty : i64
      (ast-node-push (AstExprTypeLiteral (AstTyVar (intern "Status"))))]
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
          (ast-node-push (AstExprLiteral (ast-lit-int 1))))
        env
        "label")
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-type-ok?
        (compiler-ctfe-call3
          "enum-variant-payload-type"
          status-ty
          (ast-node-push (AstExprLiteral (ast-lit-int 1)))
          (ast-node-push (AstExprLiteral (ast-lit-int 0))))
        env
        (AstTyString))
        unit
        (set! ok false))
      ok)))

;; --- self-tests (#1137 additions) -------------------------------------------
;; Basic round-trip: build an `if` expression from bool literal constructors,
;; compare it structurally, extract its parts, and verify list ops.
;; Flat-AST test helper: the #1137 self-tests build exprs with i64-returning
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

(define (compiler-ctfe-checked-expr-constructors-ok?) : bool
  (let
    [env : CtfeEnv (ctfe-env-empty)]
    [true-lit : i64 (ctfe-ast-push env (AstExprLiteral (AstLitBool true)))]
    [false-lit : i64 (ctfe-ast-push env (AstExprLiteral (AstLitBool false)))]
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
      (ctfe-ast-push env (AstExprLiteral (AstLitString "point")))]
    [field-name-lit : i64
      (ctfe-ast-push env (AstExprLiteral (AstLitString "x")))]
    [point-expr : i64
      (compiler-ctfe-call1-in-env env "expr-var" point-name-lit)]
    [field-expr : i64
      (compiler-ctfe-call2-in-env
        env
        "expr-struct-get"
        point-expr
        field-name-lit)]
    [expected-field : i64
      (ast-expr-struct-get-with-pools
        (ctfe-env-pools env)
        (ctfe-ast-push env (AstExprVar (intern "point")))
        "x")]
    (and
      (match (compiler-ctfe-eval
        (ctfe-ast-get env if-expr)
        env
        (ctfe-fuel-limit))
        [(OkCtfe value _)
          (match value
            [(CtfeExpr node checked-ty)
              (and
                (ctfe-type-eq checked-ty (AstTyBool))
                (ctfe-test-expr-eq-in-env env node expected))]
            [_ false])]
        [(ErrCtfe _) false])
      (match (compiler-ctfe-eval
        (ctfe-ast-get env field-expr)
        env
        (ctfe-fuel-limit))
        [(OkCtfe value _)
          (match value
            [(CtfeExpr node checked-ty)
              (and
                (ctfe-untyped-expr-type? checked-ty)
                (ctfe-test-expr-eq-in-env env node expected-field))]
            [_ false])]
        [(ErrCtfe _) false]))))

(define (compiler-ctfe-checked-expr-inspectors-ok?) : bool
  (let
    [env : CtfeEnv (ctfe-env-empty)]
    [true-lit : i64 (ctfe-ast-push env (AstExprLiteral (AstLitBool true)))]
    [false-lit : i64 (ctfe-ast-push env (AstExprLiteral (AstLitBool false)))]
    [true-expr : i64 (compiler-ctfe-call1-in-env env "expr-bool" true-lit)]
    [false-expr : i64 (compiler-ctfe-call1-in-env env "expr-bool" false-lit)]
    [if-expr : i64
      (compiler-ctfe-call3-in-env env "expr-if" true-expr false-expr true-expr)]
    [if-predicate : i64 (compiler-ctfe-call1-in-env env "expr-if?" if-expr)]
    [bool-predicate : i64
      (compiler-ctfe-call1-in-env env "expr-bool?" true-expr)]
    [bool-value : i64
      (compiler-ctfe-call1-in-env env "expr-bool-value" false-expr)]
    [cond-expr : i64 (compiler-ctfe-call1-in-env env "expr-if-cond" if-expr)]
    [then-expr : i64 (compiler-ctfe-call1-in-env env "expr-if-then" if-expr)]
    [bad-cond-expr : i64
      (compiler-ctfe-call1-in-env env "expr-if-cond" true-expr)]
    (and
      (compiler-ctfe-eval-bool-ok? if-predicate env true)
      (compiler-ctfe-eval-bool-ok? bool-predicate env true)
      (compiler-ctfe-eval-bool-ok? bool-value env false)
      (match (compiler-ctfe-eval
        (ctfe-ast-get env cond-expr)
        env
        (ctfe-fuel-limit))
        [(OkCtfe value _)
          (match value
            [(CtfeExpr node checked-ty)
              (and
                (ctfe-type-eq checked-ty (AstTyBool))
                (ctfe-test-expr-eq-in-env env node true-lit))]
            [_ false])]
        [(ErrCtfe _) false])
      (match (compiler-ctfe-eval
        (ctfe-ast-get env then-expr)
        env
        (ctfe-fuel-limit))
        [(OkCtfe value _)
          (match value
            [(CtfeExpr node checked-ty)
              (and
                (ctfe-type-eq checked-ty (AstTyBool))
                (ctfe-test-expr-eq-in-env env node false-lit))]
            [_ false])]
        [(ErrCtfe _) false])
      (compiler-ctfe-eval-error-ok?
        bad-cond-expr
        env
        "expr-if-cond expects if Expr"))))

(define (compiler-ctfe-checked-expr-rejects-non-bool-cond-ok?) : bool
  (let
    [base-env : CtfeEnv (ctfe-env-empty)]
    [int-node : i64 (ctfe-ast-push base-env (AstExprLiteral (ast-lit-int 1)))]
    [int-expr-value : CompilerCtfeValue (CtfeExpr int-node (AstTyI64))]
    [env : CtfeEnv (ctfe-env-extend base-env "n" int-expr-value)]
    [spliced-int : i64
      (compiler-ctfe-call1-in-env
        env
        "expr-splice"
        (ctfe-ast-push env (AstExprVar (intern "n"))))]
    [true-expr : i64
      (compiler-ctfe-call1-in-env
        env
        "expr-bool"
        (ctfe-ast-push env (AstExprLiteral (AstLitBool true))))]
    [if-expr : i64
      (compiler-ctfe-call3-in-env env "expr-if" spliced-int true-expr true-expr)]
    (compiler-ctfe-eval-error-ok?
      if-expr
      env
      "expr-if condition must produce bool")))

(define (compiler-ctfe-quote-syntax-ok?) : bool
  (let
    [base-env : CtfeEnv (ctfe-env-empty)]
    [true-lit : i64 (ctfe-ast-push base-env (AstExprLiteral (AstLitBool true)))]
    [false-lit : i64
      (ctfe-ast-push base-env (AstExprLiteral (AstLitBool false)))]
    [flag-var : i64 (ctfe-ast-push base-env (AstExprVar (intern "flag")))]
    [spliced : AstExprList
      (ast-expr-cons true-lit (ast-expr-cons false-lit AstExprNil))]
    [env : CtfeEnv
      (ctfe-env-extend
        (ctfe-env-extend base-env "cond" (CtfeExpr flag-var (AstTyBool)))
        "xs"
        (CtfeExprList spliced))]
    [quoted-bool : i64
      (ast-expr-quote-with-pools (ctfe-env-pools env) true-lit)]
    [cond-var : i64 (ctfe-ast-push env (AstExprVar (intern "cond")))]
    [qq-if : i64
      (ast-expr-quasiquote-with-pools
        (ctfe-env-pools env)
        (ast-expr-if-with-pools
          (ctfe-env-pools env)
          (ast-expr-unquote-with-pools (ctfe-env-pools env) cond-var)
          true-lit
          false-lit))]
    [xs-var : i64 (ctfe-ast-push env (AstExprVar (intern "xs")))]
    [qq-splice : i64
      (ast-expr-quasiquote-with-pools
        (ctfe-env-pools env)
        (ctfe-ast-push
          env
          (AstExprBegin
            (ast-expr-cons
              (ast-expr-unquote-splicing-with-pools (ctfe-env-pools env) xs-var)
              AstExprNil))))]
    [expected-if : i64
      (ast-expr-if-with-pools (ctfe-env-pools env) flag-var true-lit false-lit)]
    [expected-begin : i64 (ctfe-ast-push env (AstExprBegin spliced))]
    (and
      (match (compiler-ctfe-eval
        (ctfe-ast-get env quoted-bool)
        env
        (ctfe-fuel-limit))
        [(OkCtfe value _)
          (match value
            [(CtfeExpr node ty)
              (and
                (ctfe-type-eq ty (AstTyBool))
                (ctfe-test-expr-eq-in-env env node true-lit))]
            [_ false])]
        [(ErrCtfe _) false])
      (match (compiler-ctfe-eval (ctfe-ast-get env qq-if) env (ctfe-fuel-limit))
        [(OkCtfe value _)
          (match value
            [(CtfeExpr node ty)
              (and
                (ctfe-type-eq ty (AstTyBool))
                (ctfe-test-expr-eq-in-env env node expected-if))]
            [_ false])]
        [(ErrCtfe _) false])
      (match (compiler-ctfe-eval
        (ctfe-ast-get env qq-splice)
        env
        (ctfe-fuel-limit))
        [(OkCtfe value _)
          (match value
            [(CtfeExpr node _)
              (ctfe-test-expr-eq-in-env env node expected-begin)]
            [_ false])]
        [(ErrCtfe _) false]))))

(define (compiler-ctfe-expr-pattern-match-int-ok?) : bool
  (let
    [base-env : CtfeEnv (ctfe-env-empty)]
    [subject-node : i64
      (ctfe-ast-push base-env (AstExprLiteral (ast-lit-int 7)))]
    [subject : CompilerCtfeValue (CtfeExpr subject-node (AstTyI64))]
    [env : CtfeEnv (ctfe-env-extend base-env "subject" subject)]
    [scrutinee : i64 (ctfe-ast-push env (AstExprVar (intern "subject")))]
    [int-pattern : AstPattern
      (ast-pat-variant
        "ExprInt"
        (ast-pattern-cons (ast-pat-binding "n") AstPatternNil))]
    [int-arm : AstMatchArm
      (ast-match-arm int-pattern (ctfe-ast-push env (AstExprVar (intern "n"))))]
    [fallback-arm : AstMatchArm
      (ast-match-arm
        AstPatWildcard
        (ctfe-ast-push env (AstExprLiteral (ast-lit-int 0))))]
    [match-expr : i64
      (ast-expr-match-with-pools
        (ctfe-env-pools env)
        scrutinee
        (ast-match-arm-cons
          int-arm
          (ast-match-arm-cons fallback-arm AstMatchArmNil)))]
    (compiler-ctfe-eval-i64-ok? match-expr env 7)))

(define (compiler-ctfe-expr-pattern-match-if-ok?) : bool
  (let
    [base-env : CtfeEnv (ctfe-env-empty)]
    [flag : i64 (ctfe-ast-push base-env (AstExprVar (intern "flag")))]
    [true-lit : i64 (ctfe-ast-push base-env (AstExprLiteral (AstLitBool true)))]
    [false-lit : i64
      (ctfe-ast-push base-env (AstExprLiteral (AstLitBool false)))]
    [if-node : i64
      (ast-expr-if-with-pools (ctfe-env-pools base-env) flag true-lit false-lit)]
    [subject : CompilerCtfeValue (CtfeExpr if-node (AstTyBool))]
    [env : CtfeEnv (ctfe-env-extend base-env "subject" subject)]
    [scrutinee : i64 (ctfe-ast-push env (AstExprVar (intern "subject")))]
    [if-pattern : AstPattern
      (ast-pat-variant
        "ExprIf"
        (ast-pattern-cons
          (ast-pat-binding "c")
          (ast-pattern-cons
            (ast-pat-binding "t")
            (ast-pattern-cons (ast-pat-binding "e") AstPatternNil))))]
    [swapped : i64
      (compiler-ctfe-call3-in-env
        env
        "expr-if"
        (ctfe-ast-push env (AstExprVar (intern "c")))
        (ctfe-ast-push env (AstExprVar (intern "e")))
        (ctfe-ast-push env (AstExprVar (intern "t"))))]
    [if-arm : AstMatchArm (ast-match-arm if-pattern swapped)]
    [fallback-arm : AstMatchArm (ast-match-arm AstPatWildcard scrutinee)]
    [match-expr : i64
      (ast-expr-match-with-pools
        (ctfe-env-pools env)
        scrutinee
        (ast-match-arm-cons
          if-arm
          (ast-match-arm-cons fallback-arm AstMatchArmNil)))]
    [expected : i64
      (ast-expr-if-with-pools (ctfe-env-pools env) flag false-lit true-lit)]
    (match (compiler-ctfe-eval
      (ctfe-ast-get env match-expr)
      env
      (ctfe-fuel-limit))
      [(OkCtfe value _)
        (match value
          [(CtfeExpr node ty)
            (and
              (ctfe-type-eq ty (AstTyBool))
              (ctfe-test-expr-eq-in-env env node expected))]
          [_ false])]
      [(ErrCtfe _) false])))

(define (compiler-ctfe-expr-pattern-match-ok?) : bool
  (and
    (compiler-ctfe-expr-pattern-match-int-ok?)
    (compiler-ctfe-expr-pattern-match-if-ok?)))

(define (compiler-ctfe-self-test) : i64
  (begin
    (unless (compiler-ctfe-type-literal-ok?) (return 1))
    (unless (compiler-ctfe-type-comparison-ok?) (return 1))
    (unless (compiler-ctfe-raw-pointer-type-comparison-ok?) (return 1))
    (unless (compiler-ctfe-f64-ok?) (return 1))
    (unless (compiler-ctfe-layout-query-ok?) (return 1))
    (unless (compiler-ctfe-reflection-query-ok?) (return 1))
    (unless (compiler-ctfe-reflection-from-program-ok?) (return 1))
    (unless (compiler-ctfe-expr-eq-ok?) (return 1))
    (unless (compiler-ctfe-expr-list-ok?) (return 1))
    (unless (compiler-ctfe-expr-list-fold-sketch-ok?) (return 1))
    (unless (compiler-ctfe-checked-expr-constructors-ok?) (return 1))
    (unless (compiler-ctfe-checked-expr-inspectors-ok?) (return 1))
    (unless (compiler-ctfe-checked-expr-rejects-non-bool-cond-ok?) (return 1))
    (unless (compiler-ctfe-quote-syntax-ok?) (return 1))
    (unless (compiler-ctfe-expr-pattern-match-ok?) (return 1))
    42))