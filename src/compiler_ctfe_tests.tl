;; compiler_ctfe_tests.tl - compiler_ctfe self-tests, main-less.
;;
;; compiler-ctfe-self-test runs every check; src/tests/compiler_ctfe_smoke.tl
;; and the frontend smoke suite call it, and its inline test runs in the
;; inline-test gate.
(import stdlib.iterator)
(import compiler_ctfe as ctfe)
(import stdlib.arena)
(import compiler_ast_types as ast)
(import compiler_builtin_ids as cbi)
(import compiler_intern as ci)
(import compiler_diagnostic as cdiag)
(import compiler_lzss as lzss)
(import stdlib.byte_buf_core)
(import stdlib.string)

(define (ctfe-reflect-info-must-use? [info : ctfe.CtfeReflectInfo]) : bool
  (match info
    [(Struct _ _ _ _ _ _ markers) (not (= (bit-and markers 1) 0))]
    [(Enum _ _ _ _ _ _ markers) (not (= (bit-and markers 1) 0))]))

(define (ctfe-env-with-layouts [layouts : ctfe.CtfeLayoutInfoList]) : ctfe.CtfeEnv
  (ctfe.ctfe-env-with-layouts-and-pools
    layouts
    (ast.ast-node-pool-context-capture-active)))

(define (ctfe-env-with-reflections [reflections : ctfe.CtfeReflectInfoList]) : ctfe.CtfeEnv
  (ctfe.ctfe-env-with-reflections-and-pools
    reflections
    (ast.ast-node-pool-context-capture-active)))

(define (ctfe-env-with-metadata-and-pools-and-source-names
  [layouts : ctfe.CtfeLayoutInfoList]
  [reflections : ctfe.CtfeReflectInfoList]
  [pools : ast.AstNodePoolContext]
  [source-names : ci.InternSourceNameSessionHandle]) : ctfe.CtfeEnv
  (ctfe.ctfe-env-new
    pools
    layouts
    reflections
    source-names
    (ctfe.compiler-ctfe-serial-macro-state)))

(define (ctfe-module-value-reflection-enable! [enabled : bool]) : unit
  (ctfe.ctfe-module-value-reflection-enable-for-state!
    (ctfe.compiler-ctfe-serial-macro-state)
    enabled))

(define (ctfe-module-value-reset!) : unit
  (ctfe.ctfe-module-value-reset-for-state!
    (ctfe.compiler-ctfe-serial-macro-state)))

(define (ctfe-module-value-add-id!
  [module-id : i64]
  [name-id : i64]
  [ty : ast.AstType]) : unit
  (ctfe.ctfe-module-value-add-id-for-state!
    (ctfe.compiler-ctfe-serial-macro-state)
    module-id
    name-id
    ty))

(define (ctfe-module-value-type-id [module-id : i64] [name-id : i64]) : ctfe.CtfeMaybeModuleValueType
  (ctfe.ctfe-module-value-type-id-for-state
    (ctfe.compiler-ctfe-serial-macro-state)
    module-id
    name-id))

(define (ctfe-value-type-name [value : ctfe.CompilerCtfeValue]) : String
  (match value
    [(I64 _) "i64"]
    [(F64 _) "f64"]
    [(F32 _) "f32"]
    [(Bool _) "bool"]
    [(Char _) "char"]
    [(String _ _) "String"]
    [(Name _ _) "String"]
    [(Unit) "unit"]
    [(Type _) "type"]
    [(Expr _ _) "Expr"]
    [(CapturedExpr _ _ _) "Expr"]
    [(ExprList _) "expr-list"]
    [(CapturedExprList _ _) "expr-list"]
    [(ExprClause _) "ExprClause"]
    [(CapturedExprClause _ _) "ExprClause"]
    [(ExprClauseList _) "ExprClauseList"]
    [(CapturedExprClauseList _ _) "ExprClauseList"]
    [(ExprBindingClause _) "ExprBindingClause"]
    [(ExprBindingClauseList _) "ExprBindingClauseList"]
    [(Pattern _) "Pattern"]
    [(PatternList _) "PatternList"]
    [(MatchArm _) "MatchArm"]
    [(MatchArmList _) "MatchArmList"]
    [(LetBinding _) "LetBinding"]
    [(LetBindingList _) "LetBindingList"]
    [(TypeInfo _) "TypeInfo"]
    [(TypeInfoBox _) "Box"]
    [(TypeInfoList _) "TypeInfoList"]
    [(TypeField _ _) "TypeField"]
    [(TypeFieldList _) "TypeFieldList"]
    [(TypeVariantPayload _) "TypeVariantPayload"]
    [(TypeVariantPayloadList _) "TypeVariantPayloadList"]
    [(TypeVariant _ _) "TypeVariant"]
    [(TypeVariantList _) "TypeVariantList"]))

(define (ctfe-expr-list-eq [a : ast.AstExprList] [b : ast.AstExprList]) : bool
  (ctfe.ctfe-expr-list-eq-in-env (ctfe.ctfe-env-empty) a b))

;; CONSTRUCTORS ----------------------------------------------------------------
(define (ctfe-expr-bool [b : bool]) : i64
  (ast.ast-node-push (Literal (Bool b))))

(define (ctfe-expr-var [name : String]) : i64
  (ast.ast-node-push (Var (ctfe.ctfe-materialize-generated-name-id name))))

(define (ctfe-expr-struct-get [target : i64] [field : String]) : i64
  (ast.ast-expr-struct-get-id
    target
    (ctfe.ctfe-materialize-generated-name-id field)))

(define (ctfe-expr-if [cond : i64] [then-branch : i64] [else-branch : i64]) : i64
  (ast.ast-expr-if cond then-branch else-branch))

;; LIST UTILITIES --------------------------------------------------------------
(define (ctfe-expr-list-singleton [e : i64]) : ast.AstExprList
  (ast.ast-expr-cons e (ast.ast-expr-list-new)))

(define (ctfe-expr-list-cons [head : i64] [tail : ast.AstExprList]) : ast.AstExprList
  (ast.ast-expr-cons head tail))

(define (ctfe-expr-list-empty? [lst : (& lst ast.AstExprList)]) : bool
  (ast.ast-expr-list-empty? lst))

(define (ctfe-expr-if? [e : i64]) : bool
  (ctfe.ctfe-expr-if-in-env? (ctfe.ctfe-env-empty) e))

(define (ctfe-expr-if-cond [e : i64]) : i64
  (ctfe.ctfe-expr-if-cond-in-env (ctfe.ctfe-env-empty) e))

(define (ctfe-expr-if-then [e : i64]) : i64
  (ctfe.ctfe-expr-if-then-in-env (ctfe.ctfe-env-empty) e))

(define (ctfe-expr-if-else [e : i64]) : i64
  (ctfe.ctfe-expr-if-else-in-env (ctfe.ctfe-env-empty) e))

(define (ctfe-expr-list-head [lst : ast.AstExprList]) : i64
  (if (ast.ast-expr-list-empty? (& lst))
    (ast.ast-node-push (Literal (Unit)))
    (ast.ast-expr-list-get (& lst) 0 0)))

(define (ctfe-expr-list-tail [lst : ast.AstExprList]) : ast.AstExprList
  (ast.ast-expr-list-tail lst))

(define (compiler-ctfe-type-literal-ok?) : bool
  (let
    [want : ast.AstType (ast.ast-ty-array (I64) 4)]
    [env : ctfe.CtfeEnv (ctfe.ctfe-env-empty)]
    (match (ctfe.compiler-ctfe-eval
      (TypeLiteral (ast.ty-node-push (clone want)))
      env
      (ctfe.ctfe-fuel-limit))
      [(Ok value _)
        (match (ctfe.ctfe-value-owned-copy (& value))
          [(Type actual)
            (and
              (ctfe.ctfe-type-eq actual want)
              (string.eq (ctfe-value-type-name value) "type"))]
          [_ false])]
      [(Err _) false])))

(define (compiler-ctfe-type-comparison-ok?) : bool
  (let
    [env : ctfe.CtfeEnv (ctfe.ctfe-env-empty)]
    (match (ctfe.compiler-ctfe-eval
      (Binary
        (Eq)
        (ast.ast-node-push (TypeLiteral (ast.ty-node-push (I64))))
        (ast.ast-node-push (TypeLiteral (ast.ty-node-push (I64)))))
      env
      (ctfe.ctfe-fuel-limit))
      [(Ok same _)
        (match same
          [(Bool same-ok)
            (match (ctfe.compiler-ctfe-eval
              (Binary
                (Eq)
                (ast.ast-node-push (TypeLiteral (ast.ty-node-push (I64))))
                (ast.ast-node-push (TypeLiteral (ast.ty-node-push (I32)))))
              env
              (ctfe.ctfe-fuel-limit))
              [(Ok different _)
                (match different
                  [(Bool different-ok) (and same-ok (not different-ok))]
                  [_ false])]
              [(Err _) false])]
          [_ false])]
      [(Err _) false])))

(define (compiler-ctfe-raw-pointer-type-comparison-ok?) : bool
  (let
    [env : ctfe.CtfeEnv (ctfe.ctfe-env-empty)]
    (match (ctfe.compiler-ctfe-eval
      (Binary
        (Eq)
        (ast.ast-node-push
          (TypeLiteral (ast.ty-node-push (ast.ast-ty-ptr (I64)))))
        (ast.ast-node-push
          (TypeLiteral (ast.ty-node-push (ast.ast-ty-ptr (I64))))))
      env
      (ctfe.ctfe-fuel-limit))
      [(Ok same _)
        (match same
          [(Bool same-ok)
            (match (ctfe.compiler-ctfe-eval
              (Binary
                (Eq)
                (ast.ast-node-push
                  (TypeLiteral (ast.ty-node-push (ast.ast-ty-ptr (I64)))))
                (ast.ast-node-push
                  (TypeLiteral (ast.ty-node-push (ast.ast-ty-mut-ptr (I64))))))
              env
              (ctfe.ctfe-fuel-limit))
              [(Ok different _)
                (match different
                  [(Bool different-ok) (and same-ok (not different-ok))]
                  [_ false])]
              [(Err _) false])]
          [_ false])]
      [(Err _) false])))

(define (compiler-ctfe-call1 [name-id : i64] [arg : i64]) : i64
  (ast.ast-expr-call
    (ast.ast-node-push (Var name-id))
    (ast.ast-expr-cons arg (ast.ast-expr-list-new))))

(define (compiler-ctfe-call2 [name-id : i64] [a : i64] [b : i64]) : i64
  (ast.ast-expr-call
    (ast.ast-node-push (Var name-id))
    (ast.ast-expr-cons a (ast.ast-expr-cons b (ast.ast-expr-list-new)))))

(define (compiler-ctfe-call3 [name-id : i64] [a : i64] [b : i64] [c : i64]) : i64
  (ast.ast-expr-call
    (ast.ast-node-push (Var name-id))
    (ast.ast-expr-cons
      a
      (ast.ast-expr-cons b (ast.ast-expr-cons c (ast.ast-expr-list-new))))))

(define (compiler-ctfe-call1-in-env
  [env : (& env ctfe.CtfeEnv)]
  [name-id : i64]
  [arg : i64]) : i64
  (ast.ast-expr-call-with-pools
    (ctfe.ctfe-env-pools env)
    (ctfe.ctfe-ast-push env (Var name-id))
    (ast.ast-expr-cons arg (ast.ast-expr-list-new))))

(define (compiler-ctfe-call2-in-env
  [env : (& env ctfe.CtfeEnv)]
  [name-id : i64]
  [a : i64]
  [b : i64]) : i64
  (ast.ast-expr-call-with-pools
    (ctfe.ctfe-env-pools env)
    (ctfe.ctfe-ast-push env (Var name-id))
    (ast.ast-expr-cons a (ast.ast-expr-cons b (ast.ast-expr-list-new)))))

(define (compiler-ctfe-call3-in-env
  [env : (& env ctfe.CtfeEnv)]
  [name-id : i64]
  [a : i64]
  [b : i64]
  [c : i64]) : i64
  (ast.ast-expr-call-with-pools
    (ctfe.ctfe-env-pools env)
    (ctfe.ctfe-ast-push env (Var name-id))
    (ast.ast-expr-cons
      a
      (ast.ast-expr-cons b (ast.ast-expr-cons c (ast.ast-expr-list-new))))))

(define (compiler-ctfe-fixed-type-head-name-provenance-ok?) : bool
  (let
    [env : ctfe.CtfeEnv (ctfe.ctfe-env-empty)]
    [i64-expr : i64 (ctfe.ctfe-ast-push env (Var (ctfe.ctfe-builtin "i64")))]
    [source-call : i64
      (compiler-ctfe-call1-in-env env (ctfe.ctfe-builtin "Array") i64-expr)]
    [generated-array : i64 (ctfe.ctfe-materialize-generated-name-id "Array")]
    [generated-call : i64
      (compiler-ctfe-call1-in-env env generated-array i64-expr)]
    [origin : ast.AstExpr (ctfe.ctfe-ast-get env source-call)]
    (and
      (match (ctfe.ctfe-expr-to-type
        (ctfe.ctfe-ast-get env source-call)
        (clone origin)
        env
        (ctfe.ctfe-fuel-limit))
        [(Ok actual _)
          (ctfe.ctfe-type-eq-in-env
            env
            actual
            (ast.ast-ty-dyn-array-with-pools (ctfe.ctfe-env-pools env) (I64)))]
        [(Err _) false])
      (match (ctfe.ctfe-expr-to-type
        (ctfe.ctfe-ast-get env generated-call)
        origin
        env
        (ctfe.ctfe-fuel-limit))
        [(Err _) true]
        [(Ok _ _) false]))))

(define (compiler-ctfe-type-expr-is?
  [env : (& env ctfe.CtfeEnv)]
  [expr-id : i64]
  [origin : ast.AstExpr]
  [expected : ast.AstType]) : bool
  (match (ctfe.ctfe-expr-to-type
    (ctfe.ctfe-ast-get env expr-id)
    origin
    (ctfe.ctfe-env-shared-view env)
    (ctfe.ctfe-fuel-limit))
    [(Ok actual _) (ctfe.ctfe-type-eq-in-env env actual expected)]
    [(Err _) false]))

(define (compiler-ctfe-type-expr-rejected?
  [env : (& env ctfe.CtfeEnv)]
  [expr-id : i64]
  [origin : ast.AstExpr]) : bool
  (match (ctfe.ctfe-expr-to-type
    (ctfe.ctfe-ast-get env expr-id)
    origin
    (ctfe.ctfe-env-shared-view env)
    (ctfe.ctfe-fuel-limit))
    [(Err _) true]
    [(Ok _ _) false]))

(define (compiler-ctfe-dyn-array-type-head-ok?) : bool
  (let
    [env : ctfe.CtfeEnv (ctfe.ctfe-env-empty)]
    [i64-expr : i64 (ctfe.ctfe-ast-push env (Var (ctfe.ctfe-builtin "i64")))]
    [count-expr : i64 (ctfe.ctfe-ast-push env (Literal (ast.ast-lit-int 2)))]
    [private-call : i64
      (compiler-ctfe-call1-in-env
        env
        (ctfe.ctfe-builtin "__tl_dyn-array")
        i64-expr)]
    [private-empty-call : i64
      (ast.ast-expr-call-with-pools
        (ctfe.ctfe-env-pools env)
        (ctfe.ctfe-ast-push env (Var (ctfe.ctfe-builtin "__tl_dyn-array")))
        (ast.ast-expr-list-new))]
    [private-two-call : i64
      (compiler-ctfe-call2-in-env
        env
        (ctfe.ctfe-builtin "__tl_dyn-array")
        i64-expr
        count-expr)]
    [fixed-call : i64
      (compiler-ctfe-call2-in-env
        env
        (ctfe.ctfe-builtin "Array")
        i64-expr
        count-expr)]
    [generated-private : i64
      (ctfe.ctfe-materialize-generated-name-id "__tl_dyn-array")]
    [generated-private-call : i64
      (compiler-ctfe-call1-in-env env generated-private i64-expr)]
    [dyn-array-ty : ast.AstType
      (ast.ast-ty-dyn-array-with-pools (ctfe.ctfe-env-pools env) (I64))]
    [fixed-array-ty : ast.AstType
      (ast.ast-ty-array-with-pools (ctfe.ctfe-env-pools env) (I64) 2)]
    [roundtrip-call : i64 (ctfe.ctfe-type-to-expr (clone dyn-array-ty) env)]
    [origin : ast.AstExpr (ctfe.ctfe-ast-get env private-call)]
    (and
      (compiler-ctfe-type-expr-is?
        env
        private-call
        (clone origin)
        (clone dyn-array-ty))
      (compiler-ctfe-type-expr-rejected? env private-empty-call (clone origin))
      (compiler-ctfe-type-expr-rejected? env private-two-call (clone origin))
      (compiler-ctfe-type-expr-is? env fixed-call (clone origin) fixed-array-ty)
      (compiler-ctfe-type-expr-rejected?
        env
        generated-private-call
        (clone origin))
      (compiler-ctfe-type-expr-is? env roundtrip-call origin dyn-array-ty)
      (match (ctfe.ctfe-expr-unspan env (ctfe.ctfe-ast-get env roundtrip-call))
        [(Call func-box args)
          (and
            (= args.len 1)
            (match (ctfe.ctfe-expr-unspan env (ctfe.ctfe-ast-get env func-box))
              [(Var name) (= name (ctfe.ctfe-builtin "__tl_dyn-array"))]
              [_ false]))]
        [_ false]))))

(define (compiler-ctfe-slice-type-head-ok?) : bool
  (let
    [env : ctfe.CtfeEnv (ctfe.ctfe-env-empty)]
    [i64-expr : i64 (ctfe.ctfe-ast-push env (Var (ctfe.ctfe-builtin "i64")))]
    [count-expr : i64 (ctfe.ctfe-ast-push env (Literal (ast.ast-lit-int 2)))]
    [slice-id : i64 cbi.compiler-builtin-id-comptime-type-info-slice-variant]
    [slice-call : i64 (compiler-ctfe-call1-in-env env slice-id i64-expr)]
    [slice-empty-call : i64
      (ast.ast-expr-call-with-pools
        (ctfe.ctfe-env-pools env)
        (ctfe.ctfe-ast-push env (Var slice-id))
        (ast.ast-expr-list-new))]
    [slice-two-call : i64
      (compiler-ctfe-call2-in-env env slice-id i64-expr count-expr)]
    [generated-slice-id : i64 (ctfe.ctfe-materialize-generated-name-id "Slice")]
    [generated-slice-call : i64
      (compiler-ctfe-call1-in-env env generated-slice-id i64-expr)]
    [slice-ty : ast.AstType
      (ast.ast-ty-slice-with-pools (ctfe.ctfe-env-pools env) I64)]
    [roundtrip-call : i64 (ctfe.ctfe-type-to-expr (clone slice-ty) env)]
    [origin : ast.AstExpr (ctfe.ctfe-ast-get env slice-call)]
    (and
      (compiler-ctfe-type-expr-is?
        env
        slice-call
        (clone origin)
        (clone slice-ty))
      (compiler-ctfe-type-expr-rejected? env slice-empty-call (clone origin))
      (compiler-ctfe-type-expr-rejected? env slice-two-call (clone origin))
      (compiler-ctfe-type-expr-rejected?
        env
        generated-slice-call
        (clone origin))
      (compiler-ctfe-type-expr-is? env roundtrip-call origin slice-ty)
      (match (ctfe.ctfe-expr-unspan env (ctfe.ctfe-ast-get env roundtrip-call))
        [(Call func-box args)
          (and
            (= args.len 1)
            (match (ctfe.ctfe-expr-unspan env (ctfe.ctfe-ast-get env func-box))
              [(Var name) (= name slice-id)]
              [_ false]))]
        [_ false]))))

(define (compiler-ctfe-eval-i64-ok?
  [expr : i64]
  [env : (& env ctfe.CtfeEnv)]
  [want : i64]) : bool
  (match (ctfe.compiler-ctfe-eval
    (ctfe.ctfe-ast-get env expr)
    env
    (ctfe.ctfe-fuel-limit))
    [(Ok value _)
      (match value
        [(I64 actual) (= actual want)]
        [_ false])]
    [(Err _) false]))

(define (compiler-ctfe-eval-f64-ok?
  [expr : i64]
  [env : (& env ctfe.CtfeEnv)]
  [want : f64]) : bool
  (match (ctfe.compiler-ctfe-eval
    (ctfe.ctfe-ast-get env expr)
    env
    (ctfe.ctfe-fuel-limit))
    [(Ok value _)
      (match value
        [(F64 actual) (= actual want)]
        [_ false])]
    [(Err _) false]))

(define (compiler-ctfe-eval-f32-ok?
  [expr : i64]
  [env : (& env ctfe.CtfeEnv)]
  [want : f64]) : bool
  (match (ctfe.compiler-ctfe-eval
    (ctfe.ctfe-ast-get env expr)
    env
    (ctfe.ctfe-fuel-limit))
    [(Ok value _)
      (match value
        [(F32 actual) (= actual want)]
        [_ false])]
    [(Err _) false]))

(define (compiler-ctfe-eval-bool-ok?
  [expr : i64]
  [env : (& env ctfe.CtfeEnv)]
  [want : bool]) : bool
  (match (ctfe.compiler-ctfe-eval
    (ctfe.ctfe-ast-get env expr)
    env
    (ctfe.ctfe-fuel-limit))
    [(Ok value _)
      (match value
        [(Bool actual)
          (if want
            actual
            (not actual))]
        [_ false])]
    [(Err _) false]))

(define (compiler-ctfe-eval-string-ok?
  [expr : i64]
  [env : (& env ctfe.CtfeEnv)]
  [want : String]) : bool
  (match (ctfe.compiler-ctfe-eval
    (ctfe.ctfe-ast-get env expr)
    env
    (ctfe.ctfe-fuel-limit))
    [(Ok value _)
      (match value
        [(String actual _) (string.eq actual want)]
        [(Name actual _) (string.eq actual want)]
        [_ false])]
    [(Err _) false]))

(define (compiler-ctfe-eval-type-ok?
  [expr : i64]
  [env : (& env ctfe.CtfeEnv)]
  [want : ast.AstType]) : bool
  (match (ctfe.compiler-ctfe-eval
    (ctfe.ctfe-ast-get env expr)
    env
    (ctfe.ctfe-fuel-limit))
    [(Ok value _)
      (match value
        [(Type actual) (ctfe.ctfe-type-eq actual want)]
        [_ false])]
    [(Err _) false]))

(define (compiler-ctfe-eval-error-ok?
  [expr : i64]
  [env : (& env ctfe.CtfeEnv)]
  [want : String]) : bool
  (match (ctfe.compiler-ctfe-eval
    (ctfe.ctfe-ast-get env expr)
    env
    (ctfe.ctfe-fuel-limit))
    [(Err diag)
      (string.eq (cdiag.compiler-diagnostic-message (__tl-box-place diag)) want)]
    [(Ok _ _) false]))

(define (compiler-ctfe-f64-ok?) : bool
  (let
    [one-five : i64 (ast.ast-node-push (Literal (Float "1.5")))]
    [two-quarter : i64 (ast.ast-node-push (Literal (Float "2.25")))]
    [zero : i64 (ast.ast-node-push (Literal (Float "0.0")))]
    [neg-zero : i64 (ast.ast-node-push (Literal (Float "-0.0")))]
    [one-f32 : i64 (ast.ast-expr-cast one-five (F32))]
    [zero-f32 : i64 (ast.ast-expr-cast zero (F32))]
    [sum-f32 : i64 (ast.ast-node-push (Binary (Add) one-f32 zero-f32))]
    [neg-f32 : i64 (ast.ast-node-push (Unary (Neg) sum-f32))]
    [wide-f32 : i64 (ast.ast-expr-cast one-f32 (F64))]
    [large-f32 : i64
      (ast.ast-expr-cast (ast.ast-node-push (Literal (Float "3.0e+38"))) (F32))]
    [two-f32 : i64
      (ast.ast-expr-cast (ast.ast-node-push (Literal (Float "2.0"))) (F32))]
    [overflow-f32 : i64 (ast.ast-node-push (Binary (Mul) large-f32 two-f32))]
    [overflow-f32-cast : i64
      (ast.ast-expr-cast (ast.ast-node-push (Literal (Float "3.5e+38"))) (F32))]
    [overflow-f64-left : i64 (ast.ast-node-push (Literal (Float "1e+308")))]
    [overflow-f64 : i64
      (ast.ast-node-push (Binary (Mul) overflow-f64-left overflow-f64-left))]
    [non-finite-f64-literal : i64
      (ast.ast-node-push (Literal (Float "1e+309")))]
    [sum : i64 (ast.ast-node-push (Binary (Add) one-five two-quarter))]
    [neg : i64 (ast.ast-node-push (Unary (Neg) sum))]
    [neg-int : i64 (ast.ast-node-push (Literal (ast.ast-lit-int (- 0 42))))]
    [u64-max : i64
      (ast.ast-expr-cast
        (ast.ast-node-push (Literal (ast.ast-lit-int (- 0 1))))
        (U64))]
    [u64-max-f64 : i64 (ast.ast-expr-cast u64-max (F64))]
    [u64-max-f32 : i64 (ast.ast-expr-cast u64-max (F32))]
    [u64-f32-above-tie : i64
      (ast.ast-expr-cast
        (ast.ast-expr-cast
          (ast.ast-node-push
            (Literal (ast.ast-lit-int (- 0 9223371487098961919))))
          (U64))
        (F32))]
    [x-id : i64 (ctfe.ctfe-materialize-generated-name-id "x")]
    [u64-var : i64 (ast.ast-node-push (Var x-id))]
    [typed-let-u64-max-f64 : i64
      (ast.ast-expr-let
        (ast.ast-let-binding-cons
          (ast.ast-let-binding-id x-id (Some (U64)) u64-max)
          (ast.ast-let-binding-list-new))
        (ast.ast-expr-cast u64-var (F64)))]
    [untyped-let-u64-max-f64 : i64
      (ast.ast-expr-let
        (ast.ast-let-binding-cons
          (ast.ast-let-binding-id x-id (No) u64-max)
          (ast.ast-let-binding-list-new))
        (ast.ast-expr-cast u64-var (F64)))]
    [m-id : i64 (ctfe.ctfe-materialize-generated-name-id "m")]
    [match-u64-var : i64 (ast.ast-node-push (Var m-id))]
    [match-u64-max-f64 : i64
      (ast.ast-expr-match
        u64-max
        (ast.ast-match-arm-cons
          (ast.ast-match-arm
            (ast.ast-pat-binding-id m-id)
            (ast.ast-expr-cast match-u64-var (F64)))
          (ast.ast-match-arm-list-new)))]
    [char-a : i64 (ast.ast-node-push (Literal (Char 'A')))]
    [char-a-f64 : i64 (ast.ast-expr-cast char-a (F64))]
    [neg-int-f64 : i64 (ast.ast-expr-cast neg-int (F64))]
    [rounded-int-f32 : i64
      (ast.ast-expr-cast
        (ast.ast-node-push (Literal (ast.ast-lit-int 16777217)))
        (F32))]
    [f64-to-i64 : i64 (ast.ast-expr-cast sum (I64))]
    [f32-to-i64 : i64 (ast.ast-expr-cast one-f32 (I64))]
    [f64-to-char-to-i64 : i64
      (ast.ast-expr-cast
        (ast.ast-expr-cast (ast.ast-node-push (Literal (Float "65.9"))) (Char))
        (I64))]
    [f64-out-of-i64 : i64
      (ast.ast-expr-cast
        (ast.ast-node-push (Literal (Float "9223372036854775808.0")))
        (I64))]
    [f64-u64-high-bit : i64
      (ast.ast-expr-cast
        (ast.ast-node-push (Literal (Float "9223372036854775808.0")))
        (U64))]
    [lt : i64
      (ast.ast-node-push
        (Binary (Lt) sum (ast.ast-node-push (Literal (Float "4.0")))))]
    [div-zero : i64 (ast.ast-node-push (Binary (Div) one-five zero))]
    [env : ctfe.CtfeEnv (ctfe.ctfe-env-empty)]
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
      (compiler-ctfe-eval-f32-ok? u64-f32-above-tie env 9223373136366403584.0)
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
      (compiler-ctfe-eval-i64-ok? f64-u64-high-bit env -9223372036854775808)
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
    [qualified-status-id : i64
      (ci.intern-generated-qualified-name
        "stdlib/Status"
        cbi.compiler-builtin-id-fix-stdlib
        cbi.compiler-builtin-id-fix-Status)]
    [packet-ty : i64
      (ast.ast-node-push
        (TypeLiteral
          (ast.ty-node-push (Var cbi.compiler-builtin-id-fix-Packet))))]
    [box-ty : i64
      (ast.ast-node-push
        (TypeLiteral (ast.ty-node-push (Var cbi.compiler-builtin-id-fix-Box))))]
    [choice-ty : i64
      (ast.ast-node-push
        (TypeLiteral
          (ast.ty-node-push (Var cbi.compiler-builtin-id-fix-Choice))))]
    [qualified-status-ty : i64
      (ast.ast-node-push
        (TypeLiteral (ast.ty-node-push (Var qualified-status-id))))]
    [packet-fields : ctfe.CtfeLayoutFieldList
      (ctfe.ctfe-layout-field-list-push-id
        (ctfe.ctfe-layout-field-list-push-id
          (ctfe.ctfe-layout-field-list-with-capacity 2)
          (Field "tag" 0)
          cbi.compiler-builtin-id-fix-tag)
        (Field "count" 8)
        cbi.compiler-builtin-id-fix-count)]
    [box-fields : ctfe.CtfeLayoutFieldList
      (ctfe.ctfe-layout-field-list-push-id
        (ctfe.ctfe-layout-field-list-with-capacity 1)
        (Field "x" 0)
        cbi.compiler-builtin-id-fix-x)]
    [layouts : ctfe.CtfeLayoutInfoList
      (ctfe.ctfe-layout-info-list-push-id
        (ctfe.ctfe-layout-info-list-push-id
          (ctfe.ctfe-layout-info-list-push-id
            (ctfe.ctfe-layout-info-list-push-id
              (ctfe.ctfe-layout-info-list-with-capacity 4)
              (Info "Packet" true 16 8 packet-fields)
              cbi.compiler-builtin-id-fix-Packet)
            (Info "Box" true 8 8 box-fields)
            cbi.compiler-builtin-id-fix-Box)
          (Info "Choice" false 24 8 (ctfe.ctfe-layout-field-list-empty))
          cbi.compiler-builtin-id-fix-Choice)
        (Info "stdlib/Status" false 32 8 (ctfe.ctfe-layout-field-list-empty))
        (ctfe.ctfe-qualified-name-key-id
          cbi.compiler-builtin-id-fix-stdlib
          cbi.compiler-builtin-id-fix-Status))]
    [env : ctfe.CtfeEnv (ctfe-env-with-layouts layouts)]
    [ok : bool true]
    (if (compiler-ctfe-eval-i64-ok?
      (compiler-ctfe-call1 (ctfe.ctfe-builtin "size-of") packet-ty)
      env
      16)
      unit
      (set! ok false))
    (if (compiler-ctfe-eval-i64-ok?
      (compiler-ctfe-call1 (ctfe.ctfe-builtin "align-of") packet-ty)
      env
      8)
      unit
      (set! ok false))
    (if (compiler-ctfe-eval-i64-ok?
      (compiler-ctfe-call2
        (ctfe.ctfe-builtin "offset-of")
        packet-ty
        (ast.ast-node-push (Var cbi.compiler-builtin-id-fix-count)))
      env
      8)
      unit
      (set! ok false))
    (if (compiler-ctfe-eval-i64-ok?
      (compiler-ctfe-call1 (ctfe.ctfe-builtin "size-of") box-ty)
      env
      8)
      unit
      (set! ok false))
    (if (compiler-ctfe-eval-i64-ok?
      (compiler-ctfe-call2
        (ctfe.ctfe-builtin "offset-of")
        box-ty
        (ast.ast-node-push (Var cbi.compiler-builtin-id-fix-x)))
      env
      0)
      unit
      (set! ok false))
    (if (compiler-ctfe-eval-i64-ok?
      (compiler-ctfe-call1 (ctfe.ctfe-builtin "size-of") choice-ty)
      env
      24)
      unit
      (set! ok false))
    (if (compiler-ctfe-eval-i64-ok?
      (compiler-ctfe-call1 (ctfe.ctfe-builtin "align-of") choice-ty)
      env
      8)
      unit
      (set! ok false))
    (if (compiler-ctfe-eval-i64-ok?
      (compiler-ctfe-call1 (ctfe.ctfe-builtin "size-of") qualified-status-ty)
      env
      32)
      unit
      (set! ok false))
    (if (compiler-ctfe-eval-error-ok?
      (compiler-ctfe-call2
        (ctfe.ctfe-builtin "offset-of")
        choice-ty
        (ast.ast-node-push (Var cbi.compiler-builtin-id-fix-tag)))
      env
      "offset-of requires struct layout type")
      unit
      (set! ok false))
    (if (compiler-ctfe-eval-error-ok?
      (compiler-ctfe-call2
        (ctfe.ctfe-builtin "offset-of")
        packet-ty
        (ast.ast-node-push (Var cbi.compiler-builtin-id-fix-missing)))
      env
      "offset-of unknown field missing")
      unit
      (set! ok false))
    ok))

(define (compiler-ctfe-reflection-env) : ctfe.CtfeEnv
  (let
    [point-fields : ctfe.CtfeReflectFieldList
      (ctfe.ctfe-reflect-field-list-push
        (ctfe.ctfe-reflect-field-list-push
          (ctfe.ctfe-reflect-field-list-with-capacity 2)
          (Field cbi.compiler-builtin-id-fix-x (I64)))
        (Field cbi.compiler-builtin-id-fix-flag (Bool)))]
    [maybe-variants : ctfe.CtfeReflectVariantList
      (ctfe.ctfe-reflect-variant-list-push
        (ctfe.ctfe-reflect-variant-list-push
          (ctfe.ctfe-reflect-variant-list-with-capacity 2)
          (Variant (ctfe.ctfe-builtin "None") (ast.ast-type-list-new)))
        (Variant
          cbi.compiler-builtin-id-fix-Some
          (ast.ast-type-cons (String) (ast.ast-type-list-new))))]
    [infos : ctfe.CtfeReflectInfoList
      (ctfe.ctfe-reflect-info-list-push-id
        (ctfe.ctfe-reflect-info-list-push-id
          (ctfe.ctfe-reflect-info-list-push-id
            (ctfe.ctfe-reflect-info-list-with-capacity 3)
            (Struct
              "Point"
              ""
              "Point"
              cbi.compiler-builtin-id-fix-Point
              (Fn
                "cleanup-point"
                (ctfe.ctfe-materialize-generated-name-id "cleanup-point"))
              point-fields
              0)
            cbi.compiler-builtin-id-fix-Point)
          (Enum
            "Maybe"
            ""
            "Maybe"
            cbi.compiler-builtin-id-fix-Maybe
            No
            (clone maybe-variants)
            0)
          cbi.compiler-builtin-id-fix-Maybe)
        (Enum
          "stdlib/Status"
          "stdlib"
          "Status"
          (ctfe.ctfe-qualified-name-key-id
            cbi.compiler-builtin-id-fix-stdlib
            cbi.compiler-builtin-id-fix-Status)
          No
          maybe-variants
          0)
        (ctfe.ctfe-qualified-name-key-id
          cbi.compiler-builtin-id-fix-stdlib
          cbi.compiler-builtin-id-fix-Status))]
    ;; Point declares `(:align 16)` and its `flag` field `(:align 8)`.
    [point-repr : ast.AstStructRepr
      (ast.ast-struct-repr-with-field-align
        (C 16 (ast.ast-no-field-aligns))
        1
        8)]
    (ctfe-env-with-reflections
      (ctfe.ctfe-reflect-info-list-add-aligns
        infos
        cbi.compiler-builtin-id-fix-Point
        (& point-repr)
        2))))

(define (compiler-ctfe-reflection-query-ok?) : bool
  (let
    [env : ctfe.CtfeEnv (compiler-ctfe-reflection-env)]
    [qualified-status-id : i64
      (ci.intern-generated-qualified-name
        "stdlib/Status"
        cbi.compiler-builtin-id-fix-stdlib
        cbi.compiler-builtin-id-fix-Status)]
    [point-ty : i64
      (ast.ast-node-push
        (TypeLiteral (ast.ty-node-push (Var cbi.compiler-builtin-id-fix-Point))))]
    [maybe-ty : i64
      (ast.ast-node-push
        (TypeLiteral (ast.ty-node-push (Var cbi.compiler-builtin-id-fix-Maybe))))]
    [qualified-status-ty : i64
      (ast.ast-node-push
        (TypeLiteral (ast.ty-node-push (Var qualified-status-id))))]
    [array-ty : i64
      (ast.ast-node-push
        (TypeLiteral (ast.ty-node-push (ast.ast-ty-array (I64) 4))))]
    [dyn-array-ty : i64
      (ast.ast-node-push
        (TypeLiteral (ast.ty-node-push (ast.ast-ty-dyn-array (Bool)))))]
    [box-ty : i64
      (ast.ast-node-push
        (TypeLiteral (ast.ty-node-push (ast.ast-ty-box (String)))))]
    [tuple-ty : i64
      (ast.ast-node-push
        (TypeLiteral
          (ast.ty-node-push
            (ast.ast-ty-tuple
              (ast.ast-type-cons
                (I64)
                (ast.ast-type-cons (Bool) (ast.ast-type-list-new)))))))]
    [str-ref-ty : i64
      (ast.ast-node-push
        (TypeLiteral
          (ast.ty-node-push
            (ast.ast-ty-ref (ctfe.ctfe-materialize-generated-name-id "r") (Str)))))]
    [fn-ty : i64
      (ast.ast-node-push
        (TypeLiteral
          (ast.ty-node-push
            (ast.ast-ty-func
              (ast.ast-type-cons
                (I64)
                (ast.ast-type-cons (Bool) (ast.ast-type-list-new)))
              (String)))))]
    [ok : bool true]
    (if (compiler-ctfe-eval-string-ok?
      (compiler-ctfe-call1 (ctfe.ctfe-builtin "type-kind") point-ty)
      env
      "struct")
      unit
      (set! ok false))
    (if (compiler-ctfe-eval-string-ok?
      (compiler-ctfe-call1
        (ctfe.ctfe-builtin "type-key")
        (ast.ast-node-push (TypeLiteral (ast.ty-node-push (I64)))))
      env
      "i64")
      unit
      (set! ok false))
    (if (compiler-ctfe-eval-bool-ok?
      (compiler-ctfe-call1 (ctfe.ctfe-builtin "type-cleanup-owning?") point-ty)
      env
      true)
      unit
      (set! ok false))
    (if (compiler-ctfe-eval-string-ok?
      (compiler-ctfe-call1 (ctfe.ctfe-builtin "type-cleanup-function") point-ty)
      env
      "cleanup-point")
      unit
      (set! ok false))
    (if (compiler-ctfe-eval-string-ok?
      (compiler-ctfe-call1 (ctfe.ctfe-builtin "type-key") str-ref-ty)
      env
      "ref_r_str")
      unit
      (set! ok false))
    (if (compiler-ctfe-eval-string-ok?
      (compiler-ctfe-call1 (ctfe.ctfe-builtin "type-nominal-name") point-ty)
      env
      "Point")
      unit
      (set! ok false))
    (if (compiler-ctfe-eval-string-ok?
      (compiler-ctfe-call1
        (ctfe.ctfe-builtin "type-nominal-module")
        qualified-status-ty)
      env
      "stdlib")
      unit
      (set! ok false))
    (if (compiler-ctfe-eval-string-ok?
      (compiler-ctfe-call1
        (ctfe.ctfe-builtin "type-nominal-name")
        qualified-status-ty)
      env
      "Status")
      unit
      (set! ok false))
    (if (compiler-ctfe-eval-i64-ok?
      (compiler-ctfe-call1 (ctfe.ctfe-builtin "struct-field-count") point-ty)
      env
      2)
      unit
      (set! ok false))
    (if (compiler-ctfe-eval-string-ok?
      (compiler-ctfe-call2
        (ctfe.ctfe-builtin "struct-field-name")
        point-ty
        (ast.ast-node-push (Literal (ast.ast-lit-int 1))))
      env
      "flag")
      unit
      (set! ok false))
    (if (compiler-ctfe-eval-type-ok?
      (compiler-ctfe-call2
        (ctfe.ctfe-builtin "struct-field-type")
        point-ty
        (ast.ast-node-push (Literal (ast.ast-lit-int 0))))
      env
      (I64))
      unit
      (set! ok false))
    (if (compiler-ctfe-eval-i64-ok?
      (compiler-ctfe-call1 (ctfe.ctfe-builtin "type-declared-align") point-ty)
      env
      16)
      unit
      (set! ok false))
    (if (compiler-ctfe-eval-i64-ok?
      (compiler-ctfe-call1 (ctfe.ctfe-builtin "type-declared-align") maybe-ty)
      env
      0)
      unit
      (set! ok false))
    (if (compiler-ctfe-eval-i64-ok?
      (compiler-ctfe-call1 (ctfe.ctfe-builtin "type-declared-align") array-ty)
      env
      0)
      unit
      (set! ok false))
    (if (compiler-ctfe-eval-i64-ok?
      (compiler-ctfe-call2
        (ctfe.ctfe-builtin "struct-field-declared-align")
        point-ty
        (ast.ast-node-push (Literal (ast.ast-lit-int 1))))
      env
      8)
      unit
      (set! ok false))
    (if (compiler-ctfe-eval-i64-ok?
      (compiler-ctfe-call2
        (ctfe.ctfe-builtin "struct-field-declared-align")
        point-ty
        (ast.ast-node-push (Literal (ast.ast-lit-int 0))))
      env
      0)
      unit
      (set! ok false))
    (if (compiler-ctfe-eval-error-ok?
      (compiler-ctfe-call2
        (ctfe.ctfe-builtin "struct-field-declared-align")
        point-ty
        (ast.ast-node-push (Literal (ast.ast-lit-int 2))))
      env
      "struct-field-declared-align index out of range")
      unit
      (set! ok false))
    (if (compiler-ctfe-eval-error-ok?
      (compiler-ctfe-call2
        (ctfe.ctfe-builtin "struct-field-declared-align")
        maybe-ty
        (ast.ast-node-push (Literal (ast.ast-lit-int 0))))
      env
      "struct-field-declared-align requires struct type")
      unit
      (set! ok false))
    (if (compiler-ctfe-eval-i64-ok?
      (compiler-ctfe-call1 (ctfe.ctfe-builtin "enum-variant-count") maybe-ty)
      env
      2)
      unit
      (set! ok false))
    (if (compiler-ctfe-eval-string-ok?
      (compiler-ctfe-call2
        (ctfe.ctfe-builtin "enum-variant-name")
        maybe-ty
        (ast.ast-node-push (Literal (ast.ast-lit-int 1))))
      env
      "Some")
      unit
      (set! ok false))
    (if (compiler-ctfe-eval-i64-ok?
      (compiler-ctfe-call2
        (ctfe.ctfe-builtin "enum-variant-payload-count")
        maybe-ty
        (ast.ast-node-push (Literal (ast.ast-lit-int 1))))
      env
      1)
      unit
      (set! ok false))
    (if (compiler-ctfe-eval-type-ok?
      (compiler-ctfe-call3
        (ctfe.ctfe-builtin "enum-variant-payload-type")
        maybe-ty
        (ast.ast-node-push (Literal (ast.ast-lit-int 1)))
        (ast.ast-node-push (Literal (ast.ast-lit-int 0))))
      env
      (String))
      unit
      (set! ok false))
    (if (compiler-ctfe-eval-type-ok?
      (compiler-ctfe-call1 (ctfe.ctfe-builtin "array-element-type") array-ty)
      env
      (I64))
      unit
      (set! ok false))
    (if (compiler-ctfe-eval-type-ok?
      (compiler-ctfe-call1 (ctfe.ctfe-builtin "box-element-type") box-ty)
      env
      (String))
      unit
      (set! ok false))
    (if (compiler-ctfe-eval-i64-ok?
      (compiler-ctfe-call1 (ctfe.ctfe-builtin "array-length") array-ty)
      env
      4)
      unit
      (set! ok false))
    (if (compiler-ctfe-eval-bool-ok?
      (compiler-ctfe-call1 (ctfe.ctfe-builtin "array-dynamic?") dyn-array-ty)
      env
      true)
      unit
      (set! ok false))
    (if (compiler-ctfe-eval-i64-ok?
      (compiler-ctfe-call1 (ctfe.ctfe-builtin "tuple-element-count") tuple-ty)
      env
      2)
      unit
      (set! ok false))
    (if (compiler-ctfe-eval-type-ok?
      (compiler-ctfe-call2
        (ctfe.ctfe-builtin "tuple-element-type")
        tuple-ty
        (ast.ast-node-push (Literal (ast.ast-lit-int 1))))
      env
      (Bool))
      unit
      (set! ok false))
    (if (compiler-ctfe-eval-i64-ok?
      (compiler-ctfe-call1 (ctfe.ctfe-builtin "function-param-count") fn-ty)
      env
      2)
      unit
      (set! ok false))
    (if (compiler-ctfe-eval-type-ok?
      (compiler-ctfe-call2
        (ctfe.ctfe-builtin "function-param-type")
        fn-ty
        (ast.ast-node-push (Literal (ast.ast-lit-int 1))))
      env
      (Bool))
      unit
      (set! ok false))
    (if (compiler-ctfe-eval-type-ok?
      (compiler-ctfe-call1 (ctfe.ctfe-builtin "function-return-type") fn-ty)
      env
      (String))
      unit
      (set! ok false))
    ok))

(define (compiler-ctfe-module-value-query-ok?) : bool
  (let
    [module-id : i64 (ci.intern "ctfe.module.values")]
    [make-id : i64 (ci.intern "make")]
    [missing-id : i64 (ci.intern "missing")]
    [module-expr : i64 (ast.ast-node-push (Literal (String module-id)))]
    [make-expr : i64 (ast.ast-node-push (Literal (String make-id)))]
    [missing-expr : i64 (ast.ast-node-push (Literal (String missing-id)))]
    [signature : ast.AstType
      (ast.ast-ty-func (ast.ast-type-cons (I64) (ast.ast-type-list-new)) (Bool))]
    [shared-ref : i64
      (ast.ast-node-push
        (TypeLiteral
          (ast.ty-node-push
            (ast.ast-ty-ref (ci.intern "query_region") (String)))))]
    [mutable-ref : i64
      (ast.ast-node-push
        (TypeLiteral
          (ast.ty-node-push
            (ast.ast-ty-mut-ref (ci.intern "query_region") (I64)))))]
    [nested-referent : ast.AstType
      (ast.ast-ty-ref (ci.intern "inner_query_region") (Bool))]
    [nested-ref : i64
      (ast.ast-node-push
        (TypeLiteral
          (ast.ty-node-push
            (ast.ast-ty-ref
              (ci.intern "outer_query_region")
              (clone nested-referent)))))]
    [non-ref : i64 (ast.ast-node-push (TypeLiteral (ast.ty-node-push (Bool))))]
    [env : ctfe.CtfeEnv (ctfe.ctfe-env-empty)]
    (ctfe-module-value-reflection-enable! true)
    (ctfe-module-value-reset!)
    (ctfe-module-value-add-id! module-id make-id (clone signature))
    (let
      [ok : bool
        (and
          (compiler-ctfe-eval-bool-ok?
            (compiler-ctfe-call2
              (ctfe.ctfe-builtin "module-value?")
              module-expr
              make-expr)
            env
            true)
          (compiler-ctfe-eval-bool-ok?
            (compiler-ctfe-call2
              (ctfe.ctfe-builtin "module-value?")
              module-expr
              missing-expr)
            env
            false)
          (compiler-ctfe-eval-type-ok?
            (compiler-ctfe-call2
              (ctfe.ctfe-builtin "module-value-type")
              module-expr
              make-expr)
            env
            signature)
          (compiler-ctfe-eval-error-ok?
            (compiler-ctfe-call2
              (ctfe.ctfe-builtin "module-value-type")
              module-expr
              missing-expr)
            env
            "module-value-type: module ctfe.module.values does not define value missing")
          (compiler-ctfe-eval-type-ok?
            (compiler-ctfe-call1
              (ctfe.ctfe-builtin "reference-element-type")
              shared-ref)
            env
            (String))
          (compiler-ctfe-eval-type-ok?
            (compiler-ctfe-call1
              (ctfe.ctfe-builtin "reference-element-type")
              mutable-ref)
            env
            (I64))
          (compiler-ctfe-eval-type-ok?
            (compiler-ctfe-call1
              (ctfe.ctfe-builtin "reference-element-type")
              nested-ref)
            env
            nested-referent)
          (compiler-ctfe-eval-error-ok?
            (compiler-ctfe-call1
              (ctfe.ctfe-builtin "reference-element-type")
              non-ref)
            env
            "reference-element-type requires reference type"))]
      (ctfe-module-value-reflection-enable! false)
      ok)))

(define (compiler-ctfe-module-value-index-state-ok?) : bool
  (let
    [module-id : i64 (ci.intern "ctfe.module.index.state")]
    [name-id : i64 (ci.intern "value")]
    (ctfe-module-value-reflection-enable! false)
    (ctfe-module-value-reset!)
    (ctfe-module-value-add-id! module-id name-id (I64))
    (match (ctfe-module-value-type-id module-id name-id)
      [(Some _) false]
      [(None)
        (ctfe-module-value-reflection-enable! true)
        (ctfe-module-value-reset!)
        (ctfe-module-value-add-id! module-id name-id (I64))
        (match (ctfe-module-value-type-id module-id name-id)
          [(Some ty)
            (let
              [found : bool (ctfe.ctfe-type-eq ty (I64))]
              (ctfe-module-value-reflection-enable! false)
              (ctfe-module-value-reset!)
              (and
                found
                (match (ctfe-module-value-type-id module-id name-id)
                  [(Some _) false]
                  [(None) true])))]
          [(None) false])])))

;; `type-expr` must preserve every AstType shape as an opaque TypeLiteral and
;; make that node immediately consumable by ExprList reflection. Keeping this
;; test at the AstType layer covers internal/reserved shapes which source syntax
;; deliberately cannot spell yet (notably Slice and Region).
(define (compiler-ctfe-type-expr-roundtrip-one?
  [env : (& env ctfe.CtfeEnv)]
  [ty : ast.AstType]) : bool
  (let
    [pools : ast.AstNodePoolContext (ctfe.ctfe-env-pools env)]
    [infos : ctfe.CtfeReflectInfoList (ctfe.ctfe-env-reflections env)]
    [resolved : ast.AstType
      (ctfe.ctfe-reflect-resolve-type-with-pools pools infos (clone ty))]
    [arg : i64 (ast.ast-expr-type-literal-with-pools pools ty)]
    [call : i64
      (compiler-ctfe-call1-in-env env (ctfe.ctfe-builtin "type-expr") arg)]
    [origin : ast.AstExpr (ctfe.ctfe-ast-get env call)]
    (match (ctfe.compiler-ctfe-eval (clone origin) env (ctfe.ctfe-fuel-limit))
      [(Ok value _)
        (match value
          [(Expr node produced)
            (and
              (ctfe.ctfe-type-eq-in-env env produced (Expr))
              (match (ast.ast-node-pool-context-expr-get (& pools) node)
                [(TypeLiteral ty-id)
                  (ctfe.ctfe-type-eq-in-env
                    env
                    (ast.ast-node-pool-context-type-get (& pools) ty-id)
                    (clone resolved))]
                [_ false])
              (match (ctfe.ctfe-expr-list-type-nth
                (ExprList (ast.ast-expr-cons node (ast.ast-expr-list-new)))
                0
                pools)
                [(Ok reflected)
                  (match reflected
                    [(Type actual)
                      (ctfe.ctfe-type-eq-in-env env actual resolved)]
                    [_ false])]
                [(Err _) false]))]
          [_ false])]
      [(Err _) false])))

;; A captured type list can belong to a caller snapshot whose node pools do not
;; share storage with the transformer definition. `expr-list-type-nth` returns
;; the reflected AstType while the environment retains that captured syntax
;; pool. `type-expr` must therefore allocate the opaque node in the caller pool
;; and return a pool-bearing captured value; copying its child IDs to the base
;; pool would leave a dangling or aliased nested type.
(define (compiler-ctfe-type-expr-foreign-pool-ok?) : bool
  (let
    [base-env : ctfe.CtfeEnv (compiler-ctfe-reflection-env)]
    [base-pools : ast.AstNodePoolContext (ctfe.ctfe-env-pools base-env)]
    [foreign-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new
        (ast.ast-expr-node-pool-state-create 8)
        (ast.ast-type-node-pool-state-create 8)
        ;; Self-test scratch pool: never installed, owned by the caller arena.
        (arena.tl_arena_current))]
    [foreign-ty : ast.AstType (ast.ast-ty-box-with-pools foreign-pools (I64))]
    [foreign-node : i64
      (ast.ast-expr-type-literal-with-pools foreign-pools foreign-ty)]
    [items : ast.AstExprList
      (ast.ast-expr-cons foreign-node (ast.ast-expr-list-new))]
    [items-name : i64
      (ctfe.ctfe-materialize-generated-name-id "foreign-type-items")]
    [env : ctfe.CtfeEnv
      (ctfe.ctfe-env-extend-id
        base-env
        items-name
        (CapturedExprList items foreign-pools))]
    [items-expr : i64 (ctfe.ctfe-ast-push env (Var items-name))]
    [zero-expr : i64 (ctfe.ctfe-ast-push env (Literal (ast.ast-lit-int 0)))]
    [nth-call : i64
      (compiler-ctfe-call2-in-env
        env
        (ctfe.ctfe-builtin "expr-list-type-nth")
        items-expr
        zero-expr)]
    [type-expr-call : i64
      (compiler-ctfe-call1-in-env env (ctfe.ctfe-builtin "type-expr") nth-call)]
    (and
      (not (ctfe.ctfe-node-pools-share-storage? base-pools foreign-pools))
      (match (ctfe.compiler-ctfe-eval
        (ctfe.ctfe-ast-get env type-expr-call)
        env
        (ctfe.ctfe-fuel-limit))
        [(Ok value _)
          (match value
            [(CapturedExpr node (Expr) owner)
              (and
                (ctfe.ctfe-node-pools-share-storage? owner foreign-pools)
                (match (ast.ast-node-pool-context-expr-get (& owner) node)
                  [(TypeLiteral ty-id)
                    (match (ast.ast-node-pool-context-type-get (& owner) ty-id)
                      [(Box inner-id)
                        (match (ast.ast-node-pool-context-type-get
                          (& owner)
                          inner-id)
                          [(I64) true]
                          [_ false])]
                      [_ false])]
                  [_ false]))]
            [_ false])]
        [(Err _) false]))))

(define (compiler-ctfe-type-expr-roundtrip-ok?) : bool
  (let
    [env : ctfe.CtfeEnv (compiler-ctfe-reflection-env)]
    [pools : ast.AstNodePoolContext (ctfe.ctfe-env-pools env)]
    [region : i64 (ctfe.ctfe-materialize-generated-name-id "type-expr-region")]
    [unknown : i64 (ctfe.ctfe-materialize-generated-name-id "GeneratedType")]
    ;; Intern the same nominal spelling under two generated package modules in
    ;; reverse lexical order. Exact round-trip identity must follow the
    ;; qualified IDs, never the unqualified display spelling or intern order.
    [same-name : i64 (ctfe.ctfe-materialize-generated-name-id "Same")]
    [right-module : i64
      (ctfe.ctfe-materialize-generated-name-id "package.generated.right")]
    [left-module : i64
      (ctfe.ctfe-materialize-generated-name-id "package.generated.left")]
    [right-same : i64
      (ci.intern-generated-qualified-name
        "package.generated.right/Same"
        right-module
        same-name)]
    [left-same : i64
      (ci.intern-generated-qualified-name
        "package.generated.left/Same"
        left-module
        same-name)]
    [qualified-status : i64
      (ci.intern-generated-qualified-name
        "stdlib/Status"
        cbi.compiler-builtin-id-fix-stdlib
        cbi.compiler-builtin-id-fix-Status)]
    [lifetimes : ast.AstLifetimeList
      (ast.ast-lifetime-cons region (ast.ast-lifetime-list-new))]
    [pair : ast.AstTypeList
      (ast.ast-type-cons-with-pools
        pools
        (I64)
        (ast.ast-type-cons-with-pools pools (Bool) (ast.ast-type-list-new)))]
    [unit-expr : i64 (ctfe.ctfe-ast-push env (Literal (Unit)))]
    [empty-call : i64
      (ast.ast-expr-call-with-pools
        pools
        (ctfe.ctfe-ast-push env (Var (ctfe.ctfe-builtin "type-expr")))
        (ast.ast-expr-list-new))]
    [two-call : i64
      (compiler-ctfe-call2-in-env
        env
        (ctfe.ctfe-builtin "type-expr")
        unit-expr
        unit-expr)]
    (and
      (compiler-ctfe-type-expr-roundtrip-one? env (I64))
      (compiler-ctfe-type-expr-roundtrip-one? env (I32))
      (compiler-ctfe-type-expr-roundtrip-one? env (I16))
      (compiler-ctfe-type-expr-roundtrip-one? env (I8))
      (compiler-ctfe-type-expr-roundtrip-one? env (U64))
      (compiler-ctfe-type-expr-roundtrip-one? env (U32))
      (compiler-ctfe-type-expr-roundtrip-one? env (U16))
      (compiler-ctfe-type-expr-roundtrip-one? env (U8))
      (compiler-ctfe-type-expr-roundtrip-one? env (F64))
      (compiler-ctfe-type-expr-roundtrip-one? env (F32))
      (compiler-ctfe-type-expr-roundtrip-one? env (Bool))
      (compiler-ctfe-type-expr-roundtrip-one? env (Char))
      (compiler-ctfe-type-expr-roundtrip-one? env (String))
      (compiler-ctfe-type-expr-roundtrip-one? env (Str))
      (compiler-ctfe-type-expr-roundtrip-one? env (Bytes))
      (compiler-ctfe-type-expr-roundtrip-one? env (Unit))
      (compiler-ctfe-type-expr-roundtrip-one? env (Never))
      (compiler-ctfe-type-expr-roundtrip-one? env (Expr))
      (compiler-ctfe-type-expr-roundtrip-one? env (ExprList))
      (compiler-ctfe-type-expr-roundtrip-one?
        env
        (ast.ast-ty-func-with-pools pools (clone pair) (String)))
      (compiler-ctfe-type-expr-roundtrip-one? env (Tuple (box pair)))
      (compiler-ctfe-type-expr-roundtrip-one?
        env
        (ast.ast-ty-array-with-pools pools (Char) 17))
      (compiler-ctfe-type-expr-roundtrip-one?
        env
        (ast.ast-ty-dyn-array-with-pools pools (U8)))
      (compiler-ctfe-type-expr-roundtrip-one?
        env
        (ast.ast-ty-slice-with-pools pools (U16)))
      (compiler-ctfe-type-expr-roundtrip-one?
        env
        (ast.ast-ty-box-with-pools pools (String)))
      (compiler-ctfe-type-expr-roundtrip-one?
        env
        (ast.ast-ty-ptr-with-pools pools (I32)))
      (compiler-ctfe-type-expr-roundtrip-one?
        env
        (ast.ast-ty-mut-ptr-with-pools pools (I16)))
      (compiler-ctfe-type-expr-roundtrip-one?
        env
        (ast.ast-ty-region-with-pools pools region (Bool)))
      (compiler-ctfe-type-expr-roundtrip-one?
        env
        (ast.ast-ty-ref-with-pools pools region (Str)))
      (compiler-ctfe-type-expr-roundtrip-one?
        env
        (ast.ast-ty-mut-ref-with-pools pools region (I64)))
      (compiler-ctfe-type-expr-roundtrip-one?
        env
        (Struct cbi.compiler-builtin-id-fix-Point))
      (compiler-ctfe-type-expr-roundtrip-one?
        env
        (Enum cbi.compiler-builtin-id-fix-Maybe))
      (compiler-ctfe-type-expr-roundtrip-one?
        env
        (StructArgs cbi.compiler-builtin-id-fix-Point (box (clone lifetimes))))
      (compiler-ctfe-type-expr-roundtrip-one?
        env
        (EnumArgs cbi.compiler-builtin-id-fix-Maybe (box (clone lifetimes))))
      (compiler-ctfe-type-expr-roundtrip-one? env (Var unknown))
      (compiler-ctfe-type-expr-roundtrip-one? env (Var qualified-status))
      (compiler-ctfe-type-expr-roundtrip-one?
        env
        (VarArgs unknown (box lifetimes)))
      (not (= left-same right-same))
      (compiler-ctfe-type-expr-roundtrip-one? env (Struct right-same))
      (compiler-ctfe-type-expr-roundtrip-one? env (Struct left-same))
      (compiler-ctfe-eval-error-ok?
        (compiler-ctfe-call1-in-env
          env
          (ctfe.ctfe-builtin "type-expr")
          unit-expr)
        env
        "type-expr expects a type argument")
      (compiler-ctfe-eval-error-ok?
        empty-call
        env
        "type-expr expects exactly one type argument")
      (compiler-ctfe-eval-error-ok?
        two-call
        env
        "type-expr expects exactly one type argument"))))

(define (compiler-ctfe-reflection-program) : ast.AstProgram
  (let
    [fields : ast.AstFieldDefList
      (ast.ast-field-def-cons
        (Def
          (ci.intern-syntax-id-from-raw cbi.compiler-builtin-id-fix-id)
          (I64)
          (No))
        (ast.ast-field-def-cons
          (Def
            (ci.intern-syntax-id-from-raw cbi.compiler-builtin-id-fix-label)
            (String)
            (No))
          (ast.ast-field-def-list-new)))]
    [variants : ast.AstVariantDefList
      (ast.ast-variant-def-cons
        (Def
          cbi.compiler-builtin-id-fix-Ready
          (ast.ast-type-list-new)
          (ast.ast-variant-payload-cleanup-list-new))
        (ast.ast-variant-def-cons
          (Def
            cbi.compiler-builtin-id-fix-Failed
            (ast.ast-type-cons (String) (ast.ast-type-list-new))
            (ast.ast-variant-payload-cleanup-list-new))
          (ast.ast-variant-def-list-new)))]
    (Program
      (box
        (ast.ast-decl-cons-boxed
          (DefStruct
            (ast.AstDeclMeta (box (ast.AstDeclMetaValue.Runtime 1)))
            cbi.compiler-builtin-id-fix-Record
            (Default)
            (No)
            fields)
          (box
            (ast.ast-decl-cons-boxed
              (DefEnum
                (ast.AstDeclMeta (box (ast.AstDeclMetaValue.Runtime 1)))
                cbi.compiler-builtin-id-fix-Status
                (No)
                variants)
              (box (ast.ast-decl-list-new)))))))))

(define (compiler-ctfe-reflection-from-program-ok?) : bool
  (let
    [env : ctfe.CtfeEnv
      (ctfe-env-with-reflections
        (ctfe.ctfe-reflections-from-program (compiler-ctfe-reflection-program)))]
    [record-ty : i64
      (ast.ast-node-push
        (TypeLiteral
          (ast.ty-node-push (Var cbi.compiler-builtin-id-fix-Record))))]
    [status-ty : i64
      (ast.ast-node-push
        (TypeLiteral
          (ast.ty-node-push (Var cbi.compiler-builtin-id-fix-Status))))]
    [infos : ctfe.CtfeReflectInfoList (ctfe.ctfe-env-reflections env)]
    [alias-id : i64 (ctfe.ctfe-materialize-generated-name-id "RecordAlias")]
    [ok : bool true]
    (match (ctfe.ctfe-reflect-info-lookup-name-id
      infos
      cbi.compiler-builtin-id-fix-Record)
      [(Some info)
        (unless (ctfe-reflect-info-must-use? (clone info)) (set! ok false))
        (let
          [alias-infos : ctfe.CtfeReflectInfoList
            (ctfe.ctfe-reflect-info-add-alias
              (clone infos)
              info
              "RecordAlias"
              alias-id)]
          (match (ctfe.ctfe-reflect-info-lookup-name-id alias-infos alias-id)
            [(Some alias-info)
              (unless (ctfe-reflect-info-must-use? alias-info) (set! ok false))]
            [(None) (set! ok false)]))]
      [(None) (set! ok false)])
    (match (ctfe.ctfe-reflect-info-lookup-name-id
      infos
      cbi.compiler-builtin-id-fix-Status)
      [(Some info) (unless (ctfe-reflect-info-must-use? info) (set! ok false))]
      [(None) (set! ok false)])
    (if (compiler-ctfe-eval-i64-ok?
      (compiler-ctfe-call1 (ctfe.ctfe-builtin "struct-field-count") record-ty)
      env
      2)
      unit
      (set! ok false))
    (if (compiler-ctfe-eval-string-ok?
      (compiler-ctfe-call2
        (ctfe.ctfe-builtin "struct-field-name")
        record-ty
        (ast.ast-node-push (Literal (ast.ast-lit-int 1))))
      env
      "label")
      unit
      (set! ok false))
    (if (compiler-ctfe-eval-type-ok?
      (compiler-ctfe-call3
        (ctfe.ctfe-builtin "enum-variant-payload-type")
        status-ty
        (ast.ast-node-push (Literal (ast.ast-lit-int 1)))
        (ast.ast-node-push (Literal (ast.ast-lit-int 0))))
      env
      (String))
      unit
      (set! ok false))
    ok))

(define (compiler-ctfe-env-string-eq?
  [env : (& env ctfe.CtfeEnv)]
  [name-id : i64]
  [want : String]) : bool
  (match (ctfe.ctfe-env-lookup-id env name-id)
    [(Some value)
      (match value
        [(String actual _) (string.eq actual want)]
        [(Name actual _) (string.eq actual want)]
        [_ false])]
    [(None) false]))

(define (compiler-ctfe-env-i64-eq?
  [env : (& env ctfe.CtfeEnv)]
  [name-id : i64]
  [want : i64]) : bool
  (match (ctfe.ctfe-env-lookup-id env name-id)
    [(Some value)
      (match value
        [(I64 actual) (= actual want)]
        [_ false])]
    [(None) false]))

(define (compiler-ctfe-type-info-builtin-kind?
  [env : (& env ctfe.CtfeEnv)]
  [ty : ast.AstType]
  [want : String]) : bool
  (let
    [kind-id : i64 (ctfe.ctfe-materialize-generated-name-id "kind")]
    (match (ctfe.ctfe-match-type-info-variant
      cbi.compiler-builtin-id-comptime-type-info-builtin-variant
      (ast.ast-pattern-cons
        (ast.ast-pat-binding-id kind-id)
        (ast.ast-pattern-list-new))
      ty
      (ctfe.ctfe-env-shared-view env))
      [(Matched matched) (compiler-ctfe-env-string-eq? matched kind-id want)]
      [(No) false])))

(define (compiler-ctfe-env-type-info-box-builtin-kind?
  [env : (& env ctfe.CtfeEnv)]
  [name-id : i64]
  [want : String]) : bool
  (match (ctfe.ctfe-env-lookup-id env name-id)
    [(Some value)
      (match value
        [(TypeInfoBox ty) (compiler-ctfe-type-info-builtin-kind? env ty want)]
        [_ false])]
    [(None) false]))

(define (compiler-ctfe-type-info-list-ref-builtin-kind?
  [env : (& env ctfe.CtfeEnv)]
  [items : ctfe.CompilerCtfeValue]
  [index : i64]
  [want : String]) : bool
  (match (ctfe.ctfe-eval-array-ref-value
    items
    index
    (Literal (Unit))
    (ctfe.ctfe-env-shared-view env)
    (ctfe.ctfe-fuel-limit))
    [(Ok value _)
      (match value
        [(TypeInfo ty) (compiler-ctfe-type-info-builtin-kind? env ty want)]
        [(TypeVariantPayload ty)
          (compiler-ctfe-type-info-builtin-kind? env ty want)]
        [_ false])]
    [(Err _) false]))

(define (compiler-ctfe-env-type-info-list-ref-builtin-kind?
  [env : (& env ctfe.CtfeEnv)]
  [name-id : i64]
  [index : i64]
  [want : String]) : bool
  (match (ctfe.ctfe-env-lookup-id env name-id)
    [(Some value)
      (compiler-ctfe-type-info-list-ref-builtin-kind? env value index want)]
    [(None) false]))

(define (compiler-ctfe-type-info-field-list-ok?
  [env : ctfe.CtfeEnv]
  [fields-value : ctfe.CompilerCtfeValue]) : bool
  (match (ctfe.ctfe-eval-array-ref-value
    fields-value
    0
    (Literal (Unit))
    env
    (ctfe.ctfe-fuel-limit))
    [(Ok field-value _)
      (match field-value
        [(TypeField name ty)
          (and
            (string.eq name "id")
            (compiler-ctfe-type-info-builtin-kind? env ty "i64"))]
        [_ false])]
    [(Err _) false]))

(define (compiler-ctfe-type-info-variant-list-ok?
  [env : ctfe.CtfeEnv]
  [variants-value : ctfe.CompilerCtfeValue]) : bool
  (match (ctfe.ctfe-eval-array-ref-value
    variants-value
    1
    (Literal (Unit))
    env
    (ctfe.ctfe-fuel-limit))
    [(Ok variant-value _)
      (match variant-value
        [(TypeVariant name payloads)
          (and
            (string.eq name "Failed")
            (compiler-ctfe-type-info-list-ref-builtin-kind?
              env
              (TypeVariantPayloadList payloads)
              0
              "string"))]
        [_ false])]
    [(Err _) false]))

(define (compiler-ctfe-type-info-source-match-ok? [env : ctfe.CtfeEnv]) : bool
  (let
    [match-env : ctfe.CtfeEnv
      (ctfe.ctfe-env-extend-id
        env
        cbi.compiler-builtin-id-fix-info
        (TypeInfo (I64)))]
    [scrutinee : i64
      (ctfe.ctfe-ast-push match-env (Var cbi.compiler-builtin-id-fix-info))]
    [true-lit : i64 (ctfe.ctfe-ast-push match-env (Literal (Bool true)))]
    [false-lit : i64 (ctfe.ctfe-ast-push match-env (Literal (Bool false)))]
    [builtin-arm : ast.AstMatchArm
      (ast.ast-match-arm
        (ast.ast-pat-variant-id
          cbi.compiler-builtin-id-comptime-type-info-builtin-variant
          (ast.ast-pattern-cons Wildcard (ast.ast-pattern-list-new)))
        true-lit)]
    [fallback-arm : ast.AstMatchArm (ast.ast-match-arm Wildcard false-lit)]
    [match-expr : i64
      (ast.ast-expr-match-with-pools
        (ctfe.ctfe-env-pools match-env)
        scrutinee
        (ast.ast-match-arm-cons
          builtin-arm
          (ast.ast-match-arm-cons fallback-arm (ast.ast-match-arm-list-new))))]
    (match (ctfe.compiler-ctfe-eval
      (ctfe.ctfe-ast-get match-env match-expr)
      match-env
      (ctfe.ctfe-fuel-limit))
      [(Ok value _)
        (match value
          [(Bool actual) actual]
          [_ false])]
      [(Err _) false])))

;; A captured CTFE pool snapshot has independent cursor cells but can share its
;; current physical segment with the installed legacy pool. Default source-type
;; construction must append through the snapshot: a legacy append at the older
;; installed cursor would overwrite the snapshot's newest node.
(define (compiler-ctfe-type-info-box-pool-coherency-ok?) : bool
  (if (ast.ast-node-pool-compat-context-active?)
    false
    (let
      [installed : ast.AstNodePoolContext
        (ast.ast-node-pool-context-new-with-capacities 4 8)]
      [_install : unit (ast.ast-node-pool-compat-context-use! installed)]
      [snapshot : ast.AstNodePoolContext
        (ast.ast-node-pool-context-capture-active)]
      [installed-cursor : i64 (ast.ast-node-pool-context-type-len installed)]
      [sentinel-name : i64
        (ctfe.ctfe-materialize-generated-name-id "ctfe-pool-snapshot-sentinel")]
      [binding-name : i64
        (ctfe.ctfe-materialize-generated-name-id "ctfe-pool-type-info-box")]
      [sentinel-id : i64
        (ast.ast-node-pool-context-type-push snapshot (Var sentinel-name))]
      [env : ctfe.CtfeEnv (ctfe.ctfe-env-empty-with-pools snapshot)]
      [bound : ctfe.CtfeEnv
        (ctfe.ctfe-env-extend-id env binding-name (TypeInfoBox (Bool)))]
      [source-ok : bool
        (match (ctfe.ctfe-env-lookup-type-id bound binding-name)
          [(Some (Box child-id))
            (and
              (= child-id (+ installed-cursor 1))
              (match (ast.ast-node-pool-context-type-get snapshot child-id)
                [(Var name-id)
                  (=
                    name-id
                    (ctfe.ctfe-qualified-name-key-id
                      cbi.compiler-builtin-id-fix-stdlib_dot_comptime
                      cbi.compiler-builtin-id-fix-TypeInfo))]
                [_ false]))]
          [_ false])]
      [sentinel-ok : bool
        (match (ast.ast-node-pool-context-type-get snapshot sentinel-id)
          [(Var name-id) (= name-id sentinel-name)]
          [_ false])]
      [cursor-ok : bool
        (and
          (= sentinel-id installed-cursor)
          (= (ast.ast-node-pool-context-type-len installed) installed-cursor)
          (=
            (ast.ast-node-pool-context-type-len snapshot)
            (+ installed-cursor 2)))]
      (ast.ast-node-pool-compat-context-clear!)
      (and sentinel-ok source-ok cursor-ok))))

(define (compiler-ctfe-type-info-reflection-ok?) : bool
  (let
    [env : ctfe.CtfeEnv
      (ctfe-env-with-reflections
        (ctfe.ctfe-reflections-from-program (compiler-ctfe-reflection-program)))]
    [elem-id : i64 (ctfe.ctfe-materialize-generated-name-id "elem")]
    [params-id : i64 (ctfe.ctfe-materialize-generated-name-id "params")]
    [ret-id : i64 (ctfe.ctfe-materialize-generated-name-id "ret")]
    [key-id : i64 (ctfe.ctfe-materialize-generated-name-id "key")]
    [fields-id : i64 (ctfe.ctfe-materialize-generated-name-id "fields")]
    [variants-id : i64 (ctfe.ctfe-materialize-generated-name-id "variants")]
    [i64-ty : i64
      (ctfe.ctfe-ast-push env (TypeLiteral (ctfe.ctfe-ty-push env (I64))))]
    [array-ty : i64
      (ctfe.ctfe-ast-push
        env
        (TypeLiteral (ctfe.ctfe-ty-push env (ast.ast-ty-array (I64) 4))))]
    [dyn-array-ty : i64
      (ctfe.ctfe-ast-push
        env
        (TypeLiteral (ctfe.ctfe-ty-push env (ast.ast-ty-dyn-array (Bool)))))]
    [slice-ty : i64
      (ctfe.ctfe-ast-push
        env
        (TypeLiteral
          (ctfe.ctfe-ty-push
            env
            (ast.ast-ty-slice-with-pools (ctfe.ctfe-env-pools env) (Bool)))))]
    [tuple-ty : i64
      (ctfe.ctfe-ast-push
        env
        (TypeLiteral
          (ctfe.ctfe-ty-push
            env
            (ast.ast-ty-tuple
              (ast.ast-type-cons
                (I64)
                (ast.ast-type-cons (Bool) (ast.ast-type-list-new)))))))]
    [fn-ty : i64
      (ctfe.ctfe-ast-push
        env
        (TypeLiteral
          (ctfe.ctfe-ty-push
            env
            (ast.ast-ty-func
              (ast.ast-type-cons
                (I64)
                (ast.ast-type-cons (Bool) (ast.ast-type-list-new)))
              (String)))))]
    [record-ty : i64
      (ctfe.ctfe-ast-push
        env
        (TypeLiteral
          (ctfe.ctfe-ty-push env (Var cbi.compiler-builtin-id-fix-Record))))]
    [status-ty : i64
      (ctfe.ctfe-ast-push
        env
        (TypeLiteral
          (ctfe.ctfe-ty-push env (Var cbi.compiler-builtin-id-fix-Status))))]
    [ok : bool true]
    (match (ctfe.compiler-ctfe-eval
      (ctfe.ctfe-ast-get
        env
        (compiler-ctfe-call1-in-env env (ctfe.ctfe-builtin "type-info") i64-ty))
      env
      (ctfe.ctfe-fuel-limit))
      [(Ok value _)
        (match value
          [(TypeInfo ty)
            (if (compiler-ctfe-type-info-builtin-kind? env ty "i64")
              unit
              (set! ok false))]
          [_ (set! ok false)])]
      [(Err _) (set! ok false)])
    (match (ctfe.compiler-ctfe-eval
      (ctfe.ctfe-ast-get
        env
        (compiler-ctfe-call1-in-env
          env
          (ctfe.ctfe-builtin "type-info")
          array-ty))
      env
      (ctfe.ctfe-fuel-limit))
      [(Ok value _)
        (match value
          [(TypeInfo ty)
            (match (ctfe.ctfe-match-type-info-variant
              cbi.compiler-builtin-id-comptime-type-info-array-variant
              (ast.ast-pattern-cons
                (ast.ast-pat-binding-id elem-id)
                (ast.ast-pattern-cons
                  (ast.ast-pat-binding-id cbi.compiler-builtin-id-fix-len)
                  (ast.ast-pattern-list-new)))
              (clone ty)
              env)
              [(Matched matched)
                (if (and
                  (compiler-ctfe-env-i64-eq?
                    matched
                    cbi.compiler-builtin-id-fix-len
                    4)
                  (compiler-ctfe-env-type-info-box-builtin-kind?
                    matched
                    elem-id
                    "i64"))
                  unit
                  (set! ok false))]
              [(No) (set! ok false)])]
          [_ (set! ok false)])]
      [(Err _) (set! ok false)])
    (match (ctfe.compiler-ctfe-eval
      (ctfe.ctfe-ast-get
        env
        (compiler-ctfe-call1-in-env
          env
          (ctfe.ctfe-builtin "type-info")
          dyn-array-ty))
      env
      (ctfe.ctfe-fuel-limit))
      [(Ok value _)
        (match value
          [(TypeInfo ty)
            (match (ctfe.ctfe-match-type-info-variant
              cbi.compiler-builtin-id-comptime-type-info-dyn-array-variant
              (ast.ast-pattern-cons
                (ast.ast-pat-binding-id elem-id)
                (ast.ast-pattern-list-new))
              ty
              env)
              [(Matched matched)
                (if (compiler-ctfe-env-type-info-box-builtin-kind?
                  matched
                  elem-id
                  "bool")
                  unit
                  (set! ok false))]
              [(No) (set! ok false)])]
          [_ (set! ok false)])]
      [(Err _) (set! ok false)])
    (match (ctfe.compiler-ctfe-eval
      (ctfe.ctfe-ast-get
        env
        (compiler-ctfe-call1-in-env
          env
          (ctfe.ctfe-builtin "type-info")
          slice-ty))
      env
      (ctfe.ctfe-fuel-limit))
      [(Ok value _)
        (match value
          [(TypeInfo ty)
            (match (ctfe.ctfe-match-type-info-variant
              cbi.compiler-builtin-id-comptime-type-info-slice-variant
              (ast.ast-pattern-cons
                (ast.ast-pat-binding-id cbi.compiler-builtin-id-fix-items)
                (ast.ast-pattern-list-new))
              ty
              env)
              [(Matched matched)
                (if (compiler-ctfe-env-type-info-box-builtin-kind?
                  matched
                  cbi.compiler-builtin-id-fix-items
                  "bool")
                  unit
                  (set! ok false))]
              [(No) (set! ok false)])]
          [_ (set! ok false)])]
      [(Err _) (set! ok false)])
    (match (ctfe.compiler-ctfe-eval
      (ctfe.ctfe-ast-get
        env
        (compiler-ctfe-call1-in-env
          env
          (ctfe.ctfe-builtin "type-kind")
          slice-ty))
      env
      (ctfe.ctfe-fuel-limit))
      [(Ok value _)
        (match value
          [(String kind _)
            (if (string.eq kind "slice")
              unit
              (set! ok false))]
          [_ (set! ok false)])]
      [(Err _) (set! ok false)])
    (match (ctfe.compiler-ctfe-eval
      (ctfe.ctfe-ast-get
        env
        (compiler-ctfe-call1-in-env env (ctfe.ctfe-builtin "type-key") slice-ty))
      env
      (ctfe.ctfe-fuel-limit))
      [(Ok value _)
        (match value
          [(String key _)
            (if (string.eq key "slice_bool")
              unit
              (set! ok false))]
          [_ (set! ok false)])]
      [(Err _) (set! ok false)])
    (match (ctfe.compiler-ctfe-eval
      (ctfe.ctfe-ast-get
        env
        (compiler-ctfe-call1-in-env
          env
          (ctfe.ctfe-builtin "array-element-type")
          slice-ty))
      env
      (ctfe.ctfe-fuel-limit))
      [(Ok value _)
        (match value
          [(Type ty)
            (match ty
              [(Bool) unit]
              [_ (set! ok false)])]
          [_ (set! ok false)])]
      [(Err _) (set! ok false)])
    (match (ctfe.compiler-ctfe-eval
      (ctfe.ctfe-ast-get
        env
        (compiler-ctfe-call1-in-env
          env
          (ctfe.ctfe-builtin "type-info")
          tuple-ty))
      env
      (ctfe.ctfe-fuel-limit))
      [(Ok value _)
        (match value
          [(TypeInfo ty)
            (match (ctfe.ctfe-match-type-info-variant
              cbi.compiler-builtin-id-comptime-type-info-tuple-variant
              (ast.ast-pattern-cons
                (ast.ast-pat-binding-id cbi.compiler-builtin-id-fix-items)
                (ast.ast-pattern-list-new))
              ty
              env)
              [(Matched matched)
                (if (compiler-ctfe-env-type-info-list-ref-builtin-kind?
                  matched
                  cbi.compiler-builtin-id-fix-items
                  1
                  "bool")
                  unit
                  (set! ok false))]
              [(No) (set! ok false)])]
          [_ (set! ok false)])]
      [(Err _) (set! ok false)])
    (match (ctfe.compiler-ctfe-eval
      (ctfe.ctfe-ast-get
        env
        (compiler-ctfe-call1-in-env env (ctfe.ctfe-builtin "type-info") fn-ty))
      env
      (ctfe.ctfe-fuel-limit))
      [(Ok value _)
        (match value
          [(TypeInfo ty)
            (match (ctfe.ctfe-match-type-info-variant
              cbi.compiler-builtin-id-comptime-type-info-function-variant
              (ast.ast-pattern-cons
                (ast.ast-pat-binding-id params-id)
                (ast.ast-pattern-cons
                  (ast.ast-pat-binding-id ret-id)
                  (ast.ast-pattern-list-new)))
              ty
              env)
              [(Matched matched)
                (if (and
                  (compiler-ctfe-env-type-info-list-ref-builtin-kind?
                    matched
                    params-id
                    1
                    "bool")
                  (compiler-ctfe-env-type-info-box-builtin-kind?
                    matched
                    ret-id
                    "string"))
                  unit
                  (set! ok false))]
              [(No) (set! ok false)])]
          [_ (set! ok false)])]
      [(Err _) (set! ok false)])
    (match (ctfe.compiler-ctfe-eval
      (ctfe.ctfe-ast-get
        env
        (compiler-ctfe-call1-in-env
          env
          (ctfe.ctfe-builtin "type-info")
          record-ty))
      env
      (ctfe.ctfe-fuel-limit))
      [(Ok value _)
        (match value
          [(TypeInfo ty)
            (match (ctfe.ctfe-match-type-info-variant
              cbi.compiler-builtin-id-comptime-type-info-struct-variant
              (ast.ast-pattern-cons
                (ast.ast-pat-binding-id key-id)
                (ast.ast-pattern-cons
                  (ast.ast-pat-binding-id fields-id)
                  (ast.ast-pattern-list-new)))
              (clone ty)
              env)
              [(Matched matched)
                (if (and
                  (compiler-ctfe-env-string-eq?
                    matched
                    key-id
                    (ctfe.ctfe-type-info-key-in-env env ty))
                  (match (ctfe.ctfe-env-lookup-id matched fields-id)
                    [(Some fields-value)
                      (compiler-ctfe-type-info-field-list-ok?
                        matched
                        fields-value)]
                    [(None) false]))
                  unit
                  (set! ok false))]
              [(No) (set! ok false)])]
          [_ (set! ok false)])]
      [(Err _) (set! ok false)])
    (match (ctfe.compiler-ctfe-eval
      (ctfe.ctfe-ast-get
        env
        (compiler-ctfe-call1-in-env
          env
          (ctfe.ctfe-builtin "type-info")
          status-ty))
      env
      (ctfe.ctfe-fuel-limit))
      [(Ok value _)
        (match value
          [(TypeInfo ty)
            (match (ctfe.ctfe-match-type-info-variant
              cbi.compiler-builtin-id-comptime-type-info-enum-variant
              (ast.ast-pattern-cons
                (ast.ast-pat-binding-id key-id)
                (ast.ast-pattern-cons
                  (ast.ast-pat-binding-id variants-id)
                  (ast.ast-pattern-list-new)))
              (clone ty)
              env)
              [(Matched matched)
                (if (and
                  (compiler-ctfe-env-string-eq?
                    matched
                    key-id
                    (ctfe.ctfe-type-info-key-in-env env ty))
                  (match (ctfe.ctfe-env-lookup-id matched variants-id)
                    [(Some variants-value)
                      (compiler-ctfe-type-info-variant-list-ok?
                        matched
                        variants-value)]
                    [(None) false]))
                  unit
                  (set! ok false))]
              [(No) (set! ok false)])]
          [_ (set! ok false)])]
      [(Err _) (set! ok false)])
    (unless (compiler-ctfe-type-info-source-match-ok? env) (set! ok false))
    ok))

;; --- self-tests ---------------------------------------------------------------
;; Basic round-trip: build an `if` expression from bool literal constructors,
;; compare it structurally, extract its parts, and verify list ops.
;; Flat-AST test helper: the self-tests build exprs with i64-returning
;; constructors; ctfe-expr-eq takes AstExpr, so wrap node ids for the tests.
(define (ctfe-test-expr-eq-in-env
  [env : (& env ctfe.CtfeEnv)]
  [a : i64]
  [b : i64]) : bool
  (ctfe.ctfe-expr-eq-in-env
    (ctfe.ctfe-env-shared-view env)
    (ctfe.ctfe-ast-get env a)
    (ctfe.ctfe-ast-get env b)))

(define (ctfe-test-expr-eq [a : i64] [b : i64]) : bool
  (let
    [env : ctfe.CtfeEnv (ctfe.ctfe-env-empty)]
    (ctfe-test-expr-eq-in-env env a b)))

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
    [lst1 : ast.AstExprList
      (ctfe-expr-list-cons a (ctfe-expr-list-singleton b))]
    [lst2 : ast.AstExprList
      (ctfe-expr-list-cons a (ctfe-expr-list-singleton b))]
    [lst3 : ast.AstExprList (ctfe-expr-list-singleton a)]
    (and
      (ctfe-expr-list-eq (clone lst1) (clone lst2))
      (not (ctfe-expr-list-eq (clone lst1) lst3))
      (= (ctfe.ctfe-expr-list-length lst1) 2)
      (not (ctfe-expr-list-empty? lst1))
      (ctfe-test-expr-eq (ctfe-expr-list-head (clone lst1)) a)
      (ctfe-test-expr-eq
        (ctfe-expr-list-head (ctfe-expr-list-tail (clone lst1)))
        b)
      (ctfe-test-expr-eq (ctfe.ctfe-expr-list-nth lst1 1) b))))

(define (compiler-ctfe-expr-list-fold-sketch-ok?) : bool
  ;; Simulate the core list-recursion a macro transformer does: build a
  ;; right-leaning `if` chain from a list of conditions and a final else.
  (let
    [cond1 : i64 (ctfe-expr-var "a")]
    [cond2 : i64 (ctfe-expr-var "b")]
    [else-expr : i64 (ctfe-expr-bool false)]
    [_conds : ast.AstExprList
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
    [_cache-reset-before : unit (ctfe.ctfe-builtin-reset!)]
    [_cache-warm : unit (ctfe.ctfe-builtin-refresh!)]
    [_cache-reset-after : unit (ctfe.ctfe-builtin-reset!)]
    [env : ctfe.CtfeEnv (ctfe.ctfe-env-empty)]
    [true-lit : i64 (ctfe.ctfe-ast-push env (Literal (Bool true)))]
    [false-lit : i64 (ctfe.ctfe-ast-push env (Literal (Bool false)))]
    [items : ast.AstExprList
      (ctfe-expr-list-cons true-lit (ctfe-expr-list-singleton false-lit))]
    [list-env : ctfe.CtfeEnv
      (ctfe.ctfe-env-extend-id
        env
        cbi.compiler-builtin-id-fix-items
        (ExprList items))]
    [items-var : i64
      (ctfe.ctfe-ast-push list-env (Var cbi.compiler-builtin-id-fix-items))]
    [len-call : i64
      (compiler-ctfe-call1-in-env
        list-env
        (ctfe.ctfe-builtin "expr-list-length")
        items-var)]
    (compiler-ctfe-eval-i64-ok? len-call list-env 2)))

(define (compiler-ctfe-pattern-list-bindings-ok?) : bool
  (let
    [env : ctfe.CtfeEnv (ctfe.ctfe-env-empty)]
    [prefix : i64
      (ctfe.ctfe-ast-push
        env
        (Literal (ast.ast-lit-generated-string "payload")))]
    [count : i64 (ctfe.ctfe-ast-push env (Literal (Int 9 "")))]
    [call : i64
      (compiler-ctfe-call2-in-env
        env
        (ctfe.ctfe-builtin "pattern-list-bindings")
        prefix
        count)]
    [negative-count : i64 (ctfe.ctfe-ast-push env (Literal (Int -1 "")))]
    [negative-call : i64
      (compiler-ctfe-call2-in-env
        env
        (ctfe.ctfe-builtin "pattern-list-bindings")
        prefix
        negative-count)]
    [huge-count : i64
      (ctfe.ctfe-ast-push env (Literal (Int (ctfe.ctfe-fuel-limit) "")))]
    [huge-call : i64
      (compiler-ctfe-call2-in-env
        env
        (ctfe.ctfe-builtin "pattern-list-bindings")
        prefix
        huge-count)]
    (and
      (match (ctfe.compiler-ctfe-eval
        (ctfe.ctfe-ast-get env call)
        env
        (ctfe.ctfe-fuel-limit))
        [(Ok value _)
          (match value
            [(PatternList patterns)
              (and
                (= (ast.ast-pattern-list-len (& patterns)) 9)
                (match (ast.ast-pattern-list-get
                  (& patterns)
                  0
                  (ast.ast-pattern-fallback))
                  [(Binding name) (string.eq (ci.intern-str name) "payload0")]
                  [_ false])
                (match (ast.ast-pattern-list-get
                  (& patterns)
                  8
                  (ast.ast-pattern-fallback))
                  [(Binding name) (string.eq (ci.intern-str name) "payload8")]
                  [_ false]))]
            [_ false])]
        [(Err _) false])
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
    [env : ctfe.CtfeEnv (ctfe.ctfe-env-empty)]
    [x-id : i64 (ctfe.ctfe-materialize-generated-name-id "x")]
    [point-id : i64 (ctfe.ctfe-materialize-generated-name-id "point")]
    [helper-id : i64
      (ctfe.ctfe-materialize-generated-name-id "counter.push-ref")]
    [x-syntax-id : i64
      (ctfe.ctfe-string-syntax-name-id
        (ctfe.ctfe-env-source-names env)
        "x"
        x-id)]
    [point-syntax-id : i64
      (ctfe.ctfe-string-syntax-name-id
        (ctfe.ctfe-env-source-names env)
        "point"
        point-id)]
    [helper-syntax-id : i64
      (ctfe.ctfe-string-syntax-name-id
        (ctfe.ctfe-env-source-names env)
        "counter.push-ref"
        helper-id)]
    [true-lit : i64 (ctfe.ctfe-ast-push env (Literal (Bool true)))]
    [false-lit : i64 (ctfe.ctfe-ast-push env (Literal (Bool false)))]
    [true-expr : i64
      (compiler-ctfe-call1-in-env env (ctfe.ctfe-builtin "expr-bool") true-lit)]
    [false-expr : i64
      (compiler-ctfe-call1-in-env env (ctfe.ctfe-builtin "expr-bool") false-lit)]
    [spliced-false : i64
      (compiler-ctfe-call1-in-env
        env
        (ctfe.ctfe-builtin "expr-splice")
        false-expr)]
    [if-expr : i64
      (compiler-ctfe-call3-in-env
        env
        (ctfe.ctfe-builtin "expr-if")
        true-expr
        spliced-false
        true-expr)]
    [expected : i64
      (ast.ast-expr-if-with-pools
        (ctfe.ctfe-env-pools env)
        true-lit
        false-lit
        true-lit)]
    [point-name-lit : i64
      (ctfe.ctfe-ast-push env (Literal (ast.ast-lit-generated-string "point")))]
    [field-name-lit : i64
      (ctfe.ctfe-ast-push env (Literal (ast.ast-lit-generated-string "x")))]
    [name-lit : i64
      (ctfe.ctfe-ast-push env (Literal (ast.ast-lit-generated-string "Ada")))]
    [name-expr : i64
      (compiler-ctfe-call1-in-env
        env
        (ctfe.ctfe-builtin "expr-string")
        name-lit)]
    [expected-name : i64
      (ctfe.ctfe-ast-push env (Literal (ast.ast-lit-generated-string "Ada")))]
    [binary-expr : i64
      (compiler-ctfe-call1-in-env
        env
        (ctfe.ctfe-builtin "expr-binary-data")
        name-lit)]
    [expected-binary : i64 (ctfe.ctfe-ast-push env (BinaryData "Ada"))]
    [point-expr : i64
      (compiler-ctfe-call1-in-env
        env
        (ctfe.ctfe-builtin "expr-var")
        point-name-lit)]
    [field-expr : i64
      (compiler-ctfe-call2-in-env
        env
        (ctfe.ctfe-builtin "expr-struct-get")
        point-expr
        field-name-lit)]
    [tuple-index-lit : i64 (ctfe.ctfe-ast-push env (Literal (Int 1 "")))]
    [tuple-ref-expr : i64
      (compiler-ctfe-call2-in-env
        env
        (ctfe.ctfe-builtin "expr-tuple-ref")
        point-expr
        tuple-index-lit)]
    [field-set-expr : i64
      (compiler-ctfe-call3-in-env
        env
        (ctfe.ctfe-builtin "expr-struct-set")
        point-expr
        field-name-lit
        true-expr)]
    [helper-name-lit : i64
      (ctfe.ctfe-ast-push env (Literal (ast.ast-lit-string-id helper-id)))]
    [helper-expr : i64
      (compiler-ctfe-call1-in-env
        env
        (ctfe.ctfe-builtin "expr-var")
        helper-name-lit)]
    [mut-borrow-expr : i64
      (compiler-ctfe-call1-in-env
        env
        (ctfe.ctfe-builtin "expr-mut-borrow")
        point-expr)]
    [empty-call-args : i64
      (ast.ast-expr-call-with-pools
        (ctfe.ctfe-env-pools env)
        (ctfe.ctfe-ast-push env (Var (ctfe.ctfe-builtin "expr-list-empty")))
        (ast.ast-expr-list-new))]
    [value-tail : i64
      (compiler-ctfe-call2-in-env
        env
        (ctfe.ctfe-builtin "expr-list-cons")
        true-expr
        empty-call-args)]
    [call-args : i64
      (compiler-ctfe-call2-in-env
        env
        (ctfe.ctfe-builtin "expr-list-cons")
        mut-borrow-expr
        value-tail)]
    [built-call : i64
      (compiler-ctfe-call2-in-env
        env
        (ctfe.ctfe-builtin "expr-call")
        helper-expr
        call-args)]
    [expected-field : i64
      (ast.ast-expr-struct-get-id-with-pools
        (ctfe.ctfe-env-pools env)
        (ctfe.ctfe-ast-push env (Var point-syntax-id))
        x-syntax-id)]
    [expected-tuple-ref : i64
      (ast.ast-expr-tuple-ref-with-pools
        (ctfe.ctfe-env-pools env)
        (ctfe.ctfe-ast-push env (Var point-syntax-id))
        1)]
    [expected-field-set : i64
      (ast.ast-expr-struct-set-id-with-pools
        (ctfe.ctfe-env-pools env)
        (ctfe.ctfe-ast-push env (Var point-syntax-id))
        x-syntax-id
        true-lit)]
    [expected-mut-borrow : i64
      (ast.ast-expr-borrow-with-pools
        (ctfe.ctfe-env-pools env)
        true
        Inferred
        (ctfe.ctfe-ast-push env (Var point-syntax-id)))]
    [expected-call : i64
      (ast.ast-expr-call-with-pools
        (ctfe.ctfe-env-pools env)
        (ctfe.ctfe-ast-push env (Var helper-syntax-id))
        (ast.ast-expr-cons
          expected-mut-borrow
          (ast.ast-expr-cons true-lit (ast.ast-expr-list-new))))]
    (and
      (match (ctfe.compiler-ctfe-eval
        (ctfe.ctfe-ast-get env if-expr)
        env
        (ctfe.ctfe-fuel-limit))
        [(Ok value _)
          (match value
            [(Expr node checked-ty)
              (and
                (ctfe.ctfe-type-eq checked-ty (Bool))
                (ctfe-test-expr-eq-in-env env node expected))]
            [_ false])]
        [(Err _) false])
      (match (ctfe.compiler-ctfe-eval
        (ctfe.ctfe-ast-get env name-expr)
        env
        (ctfe.ctfe-fuel-limit))
        [(Ok value _)
          (match value
            [(Expr node checked-ty)
              (and
                (ctfe.ctfe-type-eq checked-ty (String))
                (ctfe-test-expr-eq-in-env env node expected-name))]
            [_ false])]
        [(Err _) false])
      (match (ctfe.compiler-ctfe-eval
        (ctfe.ctfe-ast-get env binary-expr)
        env
        (ctfe.ctfe-fuel-limit))
        [(Ok value _)
          (match value
            [(Expr node checked-ty)
              (and
                (ctfe.ctfe-type-eq
                  checked-ty
                  (ast.ast-ty-dyn-array-with-pools
                    (ctfe.ctfe-env-pools env)
                    (U8)))
                (ctfe-test-expr-eq-in-env env node expected-binary))]
            [_ false])]
        [(Err _) false])
      (match (ctfe.compiler-ctfe-eval
        (ctfe.ctfe-ast-get env field-expr)
        env
        (ctfe.ctfe-fuel-limit))
        [(Ok value _)
          (match value
            [(Expr node checked-ty)
              (and
                (ctfe.ctfe-untyped-expr-type? checked-ty)
                (ctfe-test-expr-eq-in-env env node expected-field))]
            [_ false])]
        [(Err _) false])
      (match (ctfe.compiler-ctfe-eval
        (ctfe.ctfe-ast-get env tuple-ref-expr)
        env
        (ctfe.ctfe-fuel-limit))
        [(Ok value _)
          (match value
            [(Expr node checked-ty)
              (and
                (ctfe.ctfe-untyped-expr-type? checked-ty)
                (ctfe-test-expr-eq-in-env env node expected-tuple-ref))]
            [_ false])]
        [(Err _) false])
      (match (ctfe.compiler-ctfe-eval
        (ctfe.ctfe-ast-get env field-set-expr)
        env
        (ctfe.ctfe-fuel-limit))
        [(Ok value _)
          (match value
            [(Expr node checked-ty)
              (and
                (ctfe.ctfe-type-eq checked-ty (Unit))
                (ctfe-test-expr-eq-in-env env node expected-field-set))]
            [_ false])]
        [(Err _) false])
      (match (ctfe.compiler-ctfe-eval
        (ctfe.ctfe-ast-get env mut-borrow-expr)
        env
        (ctfe.ctfe-fuel-limit))
        [(Ok value _)
          (match value
            [(Expr node checked-ty)
              (and
                (ctfe.ctfe-untyped-expr-type? checked-ty)
                (ctfe-test-expr-eq-in-env env node expected-mut-borrow))]
            [_ false])]
        [(Err _) false])
      (match (ctfe.compiler-ctfe-eval
        (ctfe.ctfe-ast-get env built-call)
        env
        (ctfe.ctfe-fuel-limit))
        [(Ok value _)
          (match value
            [(Expr node checked-ty)
              (and
                (ctfe.ctfe-untyped-expr-type? checked-ty)
                (ctfe-test-expr-eq-in-env env node expected-call))]
            [_ false])]
        [(Err _) false]))))

(define (compiler-ctfe-checked-expr-inspectors-ok?) : bool
  (let
    [env : ctfe.CtfeEnv (ctfe.ctfe-env-empty)]
    [true-lit : i64 (ctfe.ctfe-ast-push env (Literal (Bool true)))]
    [false-lit : i64 (ctfe.ctfe-ast-push env (Literal (Bool false)))]
    [true-expr : i64
      (compiler-ctfe-call1-in-env env (ctfe.ctfe-builtin "expr-bool") true-lit)]
    [false-expr : i64
      (compiler-ctfe-call1-in-env env (ctfe.ctfe-builtin "expr-bool") false-lit)]
    [if-expr : i64
      (compiler-ctfe-call3-in-env
        env
        (ctfe.ctfe-builtin "expr-if")
        true-expr
        false-expr
        true-expr)]
    [if-predicate : i64
      (compiler-ctfe-call1-in-env env (ctfe.ctfe-builtin "expr-if?") if-expr)]
    [not-if-predicate : i64
      (compiler-ctfe-call1-in-env env (ctfe.ctfe-builtin "expr-if?") true-expr)]
    [bool-predicate : i64
      (compiler-ctfe-call1-in-env
        env
        (ctfe.ctfe-builtin "expr-bool?")
        true-expr)]
    [not-bool-predicate : i64
      (compiler-ctfe-call1-in-env env (ctfe.ctfe-builtin "expr-bool?") if-expr)]
    [bool-value : i64
      (compiler-ctfe-call1-in-env
        env
        (ctfe.ctfe-builtin "expr-bool-value")
        false-expr)]
    [bool-value-fallback : i64
      (compiler-ctfe-call1-in-env
        env
        (ctfe.ctfe-builtin "expr-bool-value")
        if-expr)]
    [cond-expr : i64
      (compiler-ctfe-call1-in-env
        env
        (ctfe.ctfe-builtin "expr-if-cond")
        if-expr)]
    [then-expr : i64
      (compiler-ctfe-call1-in-env
        env
        (ctfe.ctfe-builtin "expr-if-then")
        if-expr)]
    [else-expr : i64
      (compiler-ctfe-call1-in-env
        env
        (ctfe.ctfe-builtin "expr-if-else")
        if-expr)]
    [fallback-cond-expr : i64
      (compiler-ctfe-call1-in-env
        env
        (ctfe.ctfe-builtin "expr-if-cond")
        true-expr)]
    [non-expr-string-predicate : i64
      (compiler-ctfe-call1-in-env
        env
        (ctfe.ctfe-builtin "expr-string?")
        true-lit)]
    [clause : ast.AstExprClause (ast.AstExprClause true-lit false-lit)]
    [clause-env : ctfe.CtfeEnv
      (ctfe.ctfe-env-extend-id
        env
        cbi.compiler-builtin-id-fix-arm
        (ExprClause clause))]
    [clause-var : i64
      (ctfe.ctfe-ast-push clause-env (Var cbi.compiler-builtin-id-fix-arm))]
    [clause-first : i64
      (compiler-ctfe-call1-in-env
        clause-env
        (ctfe.ctfe-builtin "expr-clause-first")
        clause-var)]
    [clause-second : i64
      (compiler-ctfe-call1-in-env
        clause-env
        (ctfe.ctfe-builtin "expr-clause-second")
        clause-var)]
    (and
      (compiler-ctfe-eval-bool-ok? if-predicate env true)
      (compiler-ctfe-eval-bool-ok? not-if-predicate env false)
      (compiler-ctfe-eval-bool-ok? bool-predicate env true)
      (compiler-ctfe-eval-bool-ok? not-bool-predicate env false)
      (compiler-ctfe-eval-bool-ok? bool-value env false)
      (compiler-ctfe-eval-bool-ok? bool-value-fallback env false)
      (compiler-ctfe-eval-bool-ok? non-expr-string-predicate env false)
      (match (ctfe.compiler-ctfe-eval
        (ctfe.ctfe-ast-get env cond-expr)
        env
        (ctfe.ctfe-fuel-limit))
        [(Ok value _)
          (match value
            [(Expr node checked-ty)
              (and
                (ctfe.ctfe-type-eq checked-ty (Bool))
                (ctfe-test-expr-eq-in-env env node true-lit))]
            [_ false])]
        [(Err _) false])
      (match (ctfe.compiler-ctfe-eval
        (ctfe.ctfe-ast-get env then-expr)
        env
        (ctfe.ctfe-fuel-limit))
        [(Ok value _)
          (match value
            [(Expr node checked-ty)
              (and
                (ctfe.ctfe-type-eq checked-ty (Bool))
                (ctfe-test-expr-eq-in-env env node false-lit))]
            [_ false])]
        [(Err _) false])
      (match (ctfe.compiler-ctfe-eval
        (ctfe.ctfe-ast-get env else-expr)
        env
        (ctfe.ctfe-fuel-limit))
        [(Ok value _)
          (match value
            [(Expr node checked-ty)
              (and
                (ctfe.ctfe-type-eq checked-ty (Bool))
                (ctfe-test-expr-eq-in-env env node true-lit))]
            [_ false])]
        [(Err _) false])
      (match (ctfe.compiler-ctfe-eval
        (ctfe.ctfe-ast-get env fallback-cond-expr)
        env
        (ctfe.ctfe-fuel-limit))
        [(Ok value _)
          (match value
            [(Expr node checked-ty)
              (and
                (ctfe.ctfe-type-eq checked-ty (Bool))
                (ctfe-test-expr-eq-in-env env node true-lit))]
            [_ false])]
        [(Err _) false])
      (match (ctfe.compiler-ctfe-eval
        (ctfe.ctfe-ast-get clause-env clause-first)
        clause-env
        (ctfe.ctfe-fuel-limit))
        [(Ok value _)
          (match value
            [(Expr node _) (ctfe-test-expr-eq-in-env clause-env node true-lit)]
            [_ false])]
        [(Err _) false])
      (match (ctfe.compiler-ctfe-eval
        (ctfe.ctfe-ast-get clause-env clause-second)
        clause-env
        (ctfe.ctfe-fuel-limit))
        [(Ok value _)
          (match value
            [(Expr node _) (ctfe-test-expr-eq-in-env clause-env node false-lit)]
            [_ false])]
        [(Err _) false]))))

(define (compiler-ctfe-checked-expr-rejects-non-bool-cond-ok?) : bool
  (let
    [base-env : ctfe.CtfeEnv (ctfe.ctfe-env-empty)]
    [int-node : i64 (ctfe.ctfe-ast-push base-env (Literal (ast.ast-lit-int 1)))]
    [int-expr-value : ctfe.CompilerCtfeValue (Expr int-node (I64))]
    [env : ctfe.CtfeEnv
      (ctfe.ctfe-env-extend-id
        base-env
        cbi.compiler-builtin-id-fix-n
        int-expr-value)]
    [spliced-int : i64
      (compiler-ctfe-call1-in-env
        env
        (ctfe.ctfe-builtin "expr-splice")
        (ctfe.ctfe-ast-push env (Var cbi.compiler-builtin-id-fix-n)))]
    [true-expr : i64
      (compiler-ctfe-call1-in-env
        env
        (ctfe.ctfe-builtin "expr-bool")
        (ctfe.ctfe-ast-push env (Literal (Bool true))))]
    [if-expr : i64
      (compiler-ctfe-call3-in-env
        env
        (ctfe.ctfe-builtin "expr-if")
        spliced-int
        true-expr
        true-expr)]
    (compiler-ctfe-eval-error-ok?
      if-expr
      env
      "expr-if condition must produce bool")))

(define (compiler-ctfe-quote-syntax-ok?) : bool
  (let
    [base-env : ctfe.CtfeEnv (ctfe.ctfe-env-empty)]
    [true-lit : i64 (ctfe.ctfe-ast-push base-env (Literal (Bool true)))]
    [false-lit : i64 (ctfe.ctfe-ast-push base-env (Literal (Bool false)))]
    [flag-var : i64
      (ctfe.ctfe-ast-push base-env (Var cbi.compiler-builtin-id-fix-flag))]
    [spliced : ast.AstExprList
      (ast.ast-expr-cons
        true-lit
        (ast.ast-expr-cons false-lit (ast.ast-expr-list-new)))]
    [env : ctfe.CtfeEnv
      (ctfe.ctfe-env-extend-id
        (ctfe.ctfe-env-extend-id
          base-env
          cbi.compiler-builtin-id-fix-cond
          (Expr flag-var (Bool)))
        cbi.compiler-builtin-id-fix-xs
        (ExprList (clone spliced)))]
    [quoted-bool : i64
      (ast.ast-expr-quote-with-pools (ctfe.ctfe-env-pools env) true-lit)]
    [cond-var : i64
      (ctfe.ctfe-ast-push env (Var cbi.compiler-builtin-id-fix-cond))]
    [qq-if : i64
      (ast.ast-expr-quasiquote-with-pools
        (ctfe.ctfe-env-pools env)
        (ast.ast-expr-if-with-pools
          (ctfe.ctfe-env-pools env)
          (ast.ast-expr-unquote-with-pools (ctfe.ctfe-env-pools env) cond-var)
          true-lit
          false-lit))]
    [xs-var : i64 (ctfe.ctfe-ast-push env (Var cbi.compiler-builtin-id-fix-xs))]
    [qq-splice : i64
      (ast.ast-expr-quasiquote-with-pools
        (ctfe.ctfe-env-pools env)
        (ctfe.ctfe-ast-push
          env
          (Begin
            (ast.ast-expr-cons
              (ast.ast-expr-unquote-splicing-with-pools
                (ctfe.ctfe-env-pools env)
                xs-var)
              (ast.ast-expr-list-new)))))]
    [record-var : i64
      (ctfe.ctfe-ast-push env (Var cbi.compiler-builtin-id-fix-record))]
    [field-place : i64
      (ast.ast-expr-struct-get-id-with-pools
        (ctfe.ctfe-env-pools env)
        record-var
        cbi.compiler-builtin-id-fix-field)]
    [set-target-var : i64
      (ctfe.ctfe-ast-push env (Var cbi.compiler-builtin-id-fix-target))]
    [set-env : ctfe.CtfeEnv
      (ctfe.ctfe-env-extend-id
        env
        cbi.compiler-builtin-id-fix-target
        (Expr field-place (Expr)))]
    [qq-set : i64
      (ast.ast-expr-quasiquote-with-pools
        (ctfe.ctfe-env-pools set-env)
        (ast.ast-expr-struct-set-id-with-pools
          (ctfe.ctfe-env-pools set-env)
          (ast.ast-expr-unquote-with-pools
            (ctfe.ctfe-env-pools set-env)
            set-target-var)
          (ast.ast-expr-unquote-set-target-field-id)
          true-lit))]
    [expected-if : i64
      (ast.ast-expr-if-with-pools
        (ctfe.ctfe-env-pools env)
        flag-var
        true-lit
        false-lit)]
    [expected-begin : i64 (ctfe.ctfe-ast-push env (Begin spliced))]
    [expected-set : i64
      (ast.ast-expr-struct-set-id-with-pools
        (ctfe.ctfe-env-pools set-env)
        record-var
        cbi.compiler-builtin-id-fix-field
        true-lit)]
    (and
      (match (ctfe.compiler-ctfe-eval
        (ctfe.ctfe-ast-get env quoted-bool)
        env
        (ctfe.ctfe-fuel-limit))
        [(Ok value _)
          (match value
            [(Expr node ty)
              (and
                (ctfe.ctfe-type-eq ty (Bool))
                (ctfe-test-expr-eq-in-env env node true-lit))]
            [_ false])]
        [(Err _) false])
      (match (ctfe.compiler-ctfe-eval
        (ctfe.ctfe-ast-get env qq-if)
        env
        (ctfe.ctfe-fuel-limit))
        [(Ok value _)
          (match value
            [(Expr node ty)
              (and
                (ctfe.ctfe-type-eq ty (Bool))
                (ctfe-test-expr-eq-in-env env node expected-if))]
            [_ false])]
        [(Err _) false])
      (match (ctfe.compiler-ctfe-eval
        (ctfe.ctfe-ast-get env qq-splice)
        env
        (ctfe.ctfe-fuel-limit))
        [(Ok value _)
          (match value
            [(Expr node _) (ctfe-test-expr-eq-in-env env node expected-begin)]
            [_ false])]
        [(Err _) false])
      (match (ctfe.compiler-ctfe-eval
        (ctfe.ctfe-ast-get set-env qq-set)
        set-env
        (ctfe.ctfe-fuel-limit))
        [(Ok value _)
          (match value
            [(Expr node _) (ctfe-test-expr-eq-in-env set-env node expected-set)]
            [_ false])]
        [(Err _) false]))))

;; Type-position unquotes in lambda annotations preserve the resolved tuple's
;; heterogeneous references, nominal identity, and lifetime names. Refs #6868.
(define (compiler-ctfe-quote-lambda-type-unquote-ok?) : bool
  (let
    [base-env : ctfe.CtfeEnv (ctfe.ctfe-env-empty)]
    [pools : ast.AstNodePoolContext (ctfe.ctfe-env-pools (& base-env))]
    [type-name : i64 (ctfe.ctfe-materialize-generated-name-id "LambdaType")]
    [param-name : i64 (ctfe.ctfe-materialize-generated-name-id "values")]
    [owner-name : i64 (ctfe.ctfe-materialize-generated-name-id "Owner")]
    [owner-region : i64
      (ctfe.ctfe-materialize-generated-name-id "owner-region")]
    [text-region : i64 (ctfe.ctfe-materialize-generated-name-id "text-region")]
    [expected : ast.AstType
      (ast.ast-ty-tuple
        (ast.ast-type-cons-with-pools
          pools
          (ast.ast-ty-ref-with-pools pools owner-region (Var owner-name))
          (ast.ast-type-cons-with-pools
            pools
            (ast.ast-ty-ref-with-pools pools text-region (Str))
            (ast.ast-type-list-new))))]
    [env : ctfe.CtfeEnv
      (ctfe.ctfe-env-extend-id base-env type-name (Type (clone expected)))]
    [type-unquote : ast.AstType
      (ast.ast-ty-var-args
        cbi.compiler-builtin-id-fix-unquote
        (ast.ast-lifetime-cons type-name (ast.ast-lifetime-list-new)))]
    [body : i64 (ctfe.ctfe-ast-push env (Var param-name))]
    [lambda-node : i64
      (ast.ast-expr-lambda-with-pools
        pools
        (ast.ast-param-cons
          (Param param-name (clone type-unquote) false)
          (ast.ast-param-list-new))
        (Some type-unquote)
        body)]
    [quasiquoted : i64 (ast.ast-expr-quasiquote-with-pools pools lambda-node)]
    (match (ctfe.compiler-ctfe-eval
      (ctfe.ctfe-ast-get env quasiquoted)
      env
      (ctfe.ctfe-fuel-limit))
      [(Ok value _)
        (match value
          [(Expr node (Expr))
            (match (ctfe.ctfe-ast-get env node)
              [(Lambda lambda-box)
                (match (__tl-box-place lambda-box)
                  [(Lambda params maybe-ret _)
                    (and
                      (= (ast.ast-param-list-len (& params)) 1)
                      (match (ast.ast-param-list-get
                        (& params)
                        0
                        (ast.ast-param-fallback))
                        [(Param _ actual false)
                          (ctfe.ctfe-type-eq-in-env env actual (clone expected))]
                        [_ false])
                      (match maybe-ret
                        [(Some actual)
                          (ctfe.ctfe-type-eq-in-env env actual expected)]
                        [(No) false]))])]
              [_ false])]
          [_ false])]
      [(Err _) false])))

;; A computed body can project the parameter before `expr-lambda1` attaches
;; its reflected tuple type. The same fresh Name value must bind and refer to
;; the parameter, including heterogeneous reference lifetimes. Refs #6868.
(define (compiler-ctfe-expr-lambda1-status) : i64
  (let
    [base-env : ctfe.CtfeEnv (ctfe.ctfe-env-empty)]
    [pools : ast.AstNodePoolContext (ctfe.ctfe-env-pools base-env)]
    [name-binding : i64
      (ctfe.ctfe-materialize-generated-name-id "lambda1-name-value")]
    [type-binding : i64
      (ctfe.ctfe-materialize-generated-name-id "lambda1-type-value")]
    [parameter-name : i64
      (ctfe.ctfe-materialize-generated-name-id "lambda1-values")]
    [owner-name : i64 (ctfe.ctfe-materialize-generated-name-id "Lambda1Owner")]
    [owner-region : i64
      (ctfe.ctfe-materialize-generated-name-id "lambda1-owner-region")]
    [text-region : i64
      (ctfe.ctfe-materialize-generated-name-id "lambda1-text-region")]
    [parameter-type : ast.AstType
      (ast.ast-ty-tuple
        (ast.ast-type-cons-with-pools
          pools
          (ast.ast-ty-ref-with-pools pools owner-region (Var owner-name))
          (ast.ast-type-cons-with-pools
            pools
            (ast.ast-ty-ref-with-pools pools text-region (Str))
            (ast.ast-type-list-new))))]
    [env : ctfe.CtfeEnv
      (ctfe.ctfe-env-extend-id
        (ctfe.ctfe-env-extend-id
          base-env
          name-binding
          (Name "lambda1-values" parameter-name))
        type-binding
        (Type (clone parameter-type)))]
    [name-value : i64 (ctfe.ctfe-ast-push env (Var name-binding))]
    [type-value : i64 (ctfe.ctfe-ast-push env (Var type-binding))]
    [target : i64
      (compiler-ctfe-call1-in-env env (ctfe.ctfe-builtin "expr-var") name-value)]
    [index : i64 (ctfe.ctfe-ast-push env (Literal (ast.ast-lit-int 1)))]
    [body : i64
      (compiler-ctfe-call2-in-env
        env
        (ctfe.ctfe-builtin "expr-tuple-ref")
        target
        index)]
    [lambda-call : i64
      (compiler-ctfe-call3-in-env
        env
        (ctfe.ctfe-builtin "expr-lambda1")
        name-value
        type-value
        body)]
    [unit-expr : i64 (ctfe.ctfe-ast-push env (Literal (Unit)))]
    [status : i64 0]
    (match (ctfe.compiler-ctfe-eval
      (ctfe.ctfe-ast-get env lambda-call)
      env
      (ctfe.ctfe-fuel-limit))
      [(Ok value _)
        (match value
          [(Expr node produced)
            (unless (ctfe.ctfe-untyped-expr-type? produced) (set! status 2))
            (match (ctfe.ctfe-ast-get env node)
              [(Lambda lambda-box)
                (match (__tl-box-place lambda-box)
                  [(Lambda params maybe-ret body-node)
                    (unless
                      (= (ast.ast-param-list-len (& params)) 1)
                      (set! status 4))
                    (match (ast.ast-param-list-get
                      (& params)
                      0
                      (ast.ast-param-fallback))
                      [(Param actual-name actual-type false)
                        (unless
                          (and
                            (= actual-name parameter-name)
                            (ctfe.ctfe-type-eq-in-env
                              env
                              actual-type
                              parameter-type))
                          (set! status 5))]
                      [_ (set! status 5)])
                    (match maybe-ret
                      [(No) unit]
                      [(Some _) (set! status 6)])
                    (match (ctfe.ctfe-ast-get env body-node)
                      [(TupleRef target-node 1)
                        (match (ctfe.ctfe-ast-get env target-node)
                          [(Var actual-name)
                            (unless
                              (= actual-name parameter-name)
                              (set! status 9))]
                          [_ (set! status 8)])]
                      [_ (set! status 7)])])]
              [_ (set! status 3)])]
          [_ (set! status 2)])]
      [(Err _) (set! status 1)])
    (if (!= status 0)
      status
      (if (compiler-ctfe-eval-error-ok?
        (compiler-ctfe-call3-in-env
          env
          (ctfe.ctfe-builtin "expr-lambda1")
          name-value
          type-value
          unit-expr)
        env
        "expr-lambda1 body expects Expr")
        0
        10))))

(define (compiler-ctfe-expr-lambda1-ok?) : bool
  (= (compiler-ctfe-expr-lambda1-status) 0))

(define (compiler-ctfe-captured-quote-syntax-ok?) : bool
  (let
    [base-env : ctfe.CtfeEnv (ctfe.ctfe-env-empty)]
    [pools : ast.AstNodePoolContext (ctfe.ctfe-env-pools base-env)]
    [expr-name : i64
      (ctfe.ctfe-materialize-generated-name-id "captured-quote-expr")]
    [list-name : i64
      (ctfe.ctfe-materialize-generated-name-id "captured-quote-list")]
    [value-node : i64 (ctfe.ctfe-ast-push base-env (Literal (Bool true)))]
    [values : ast.AstExprList
      (ast.ast-expr-cons value-node (ast.ast-expr-list-new))]
    [env : ctfe.CtfeEnv
      (ctfe.ctfe-env-extend-id
        (ctfe.ctfe-env-extend-id
          base-env
          expr-name
          (CapturedExpr value-node (Bool) pools))
        list-name
        (CapturedExprList values pools))]
    [expr-var : ast.AstExpr (Var expr-name)]
    [list-var : ast.AstExpr (Var list-name)]
    [foreign-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new
        (ast.ast-expr-node-pool-state-create 2)
        (ast.ast-type-node-pool-state-create 2)
        ;; Self-test scratch pool: never installed, owned by the caller arena.
        (arena.tl_arena_current))]
    (and
      (ctfe.ctfe-node-pools-share-storage? pools pools)
      (not (ctfe.ctfe-node-pools-share-storage? pools foreign-pools))
      (match (ctfe.ctfe-eval-unquote-expr
        (clone expr-var)
        expr-var
        env
        (ctfe.ctfe-fuel-limit))
        [(Ok node ty _) (and (= node value-node) (ctfe.ctfe-type-eq ty (Bool)))]
        [(Err _) false])
      (match (ctfe.ctfe-eval-unquote-splice
        (clone list-var)
        list-var
        env
        (ctfe.ctfe-fuel-limit))
        [(Ok quoted _)
          (and
            (= quoted.len 1)
            (= (ast.ast-expr-list-get (& quoted) 0 0) value-node))]
        [(Err _) false]))))

(define (compiler-ctfe-expr-pattern-match-int-ok?) : bool
  (let
    [base-env : ctfe.CtfeEnv (ctfe.ctfe-env-empty)]
    [subject-node : i64
      (ctfe.ctfe-ast-push base-env (Literal (ast.ast-lit-int 7)))]
    [subject : ctfe.CompilerCtfeValue (Expr subject-node (I64))]
    [env : ctfe.CtfeEnv
      (ctfe.ctfe-env-extend-id
        base-env
        cbi.compiler-builtin-id-fix-subject
        subject)]
    [scrutinee : i64
      (ctfe.ctfe-ast-push env (Var cbi.compiler-builtin-id-fix-subject))]
    [int-pattern : ast.AstPattern
      (ast.ast-pat-variant-id
        cbi.compiler-builtin-id-comptime-expr-int-variant
        (ast.ast-pattern-cons
          (ast.ast-pat-binding-id cbi.compiler-builtin-id-fix-n)
          (ast.ast-pattern-list-new)))]
    [int-arm : ast.AstMatchArm
      (ast.ast-match-arm
        int-pattern
        (ctfe.ctfe-ast-push env (Var cbi.compiler-builtin-id-fix-n)))]
    [fallback-arm : ast.AstMatchArm
      (ast.ast-match-arm
        Wildcard
        (ctfe.ctfe-ast-push env (Literal (ast.ast-lit-int 0))))]
    [match-expr : i64
      (ast.ast-expr-match-with-pools
        (ctfe.ctfe-env-pools env)
        scrutinee
        (ast.ast-match-arm-cons
          int-arm
          (ast.ast-match-arm-cons fallback-arm (ast.ast-match-arm-list-new))))]
    (compiler-ctfe-eval-i64-ok? match-expr env 7)))

(define (compiler-ctfe-expr-pattern-match-if-ok?) : bool
  (let
    [base-env : ctfe.CtfeEnv (ctfe.ctfe-env-empty)]
    [flag : i64
      (ctfe.ctfe-ast-push base-env (Var cbi.compiler-builtin-id-fix-flag))]
    [true-lit : i64 (ctfe.ctfe-ast-push base-env (Literal (Bool true)))]
    [false-lit : i64 (ctfe.ctfe-ast-push base-env (Literal (Bool false)))]
    [if-node : i64
      (ast.ast-expr-if-with-pools
        (ctfe.ctfe-env-pools base-env)
        flag
        true-lit
        false-lit)]
    [subject : ctfe.CompilerCtfeValue (Expr if-node (Bool))]
    [env : ctfe.CtfeEnv
      (ctfe.ctfe-env-extend-id
        base-env
        cbi.compiler-builtin-id-fix-subject
        subject)]
    [scrutinee : i64
      (ctfe.ctfe-ast-push env (Var cbi.compiler-builtin-id-fix-subject))]
    [if-pattern : ast.AstPattern
      (ast.ast-pat-variant-id
        cbi.compiler-builtin-id-comptime-expr-if-variant
        (ast.ast-pattern-cons
          (ast.ast-pat-binding-id cbi.compiler-builtin-id-fix-c)
          (ast.ast-pattern-cons
            (ast.ast-pat-binding-id cbi.compiler-builtin-id-fix-t)
            (ast.ast-pattern-cons
              (ast.ast-pat-binding-id cbi.compiler-builtin-id-fix-e)
              (ast.ast-pattern-list-new)))))]
    [swapped : i64
      (compiler-ctfe-call3-in-env
        env
        (ctfe.ctfe-builtin "expr-if")
        (ctfe.ctfe-ast-push env (Var cbi.compiler-builtin-id-fix-c))
        (ctfe.ctfe-ast-push env (Var cbi.compiler-builtin-id-fix-e))
        (ctfe.ctfe-ast-push env (Var cbi.compiler-builtin-id-fix-t)))]
    [if-arm : ast.AstMatchArm (ast.ast-match-arm if-pattern swapped)]
    [fallback-arm : ast.AstMatchArm (ast.ast-match-arm Wildcard scrutinee)]
    [match-expr : i64
      (ast.ast-expr-match-with-pools
        (ctfe.ctfe-env-pools env)
        scrutinee
        (ast.ast-match-arm-cons
          if-arm
          (ast.ast-match-arm-cons fallback-arm (ast.ast-match-arm-list-new))))]
    [expected : i64
      (ast.ast-expr-if-with-pools
        (ctfe.ctfe-env-pools env)
        flag
        false-lit
        true-lit)]
    (match (ctfe.compiler-ctfe-eval
      (ctfe.ctfe-ast-get env match-expr)
      env
      (ctfe.ctfe-fuel-limit))
      [(Ok value _)
        (match value
          [(Expr node ty)
            (and
              (ctfe.ctfe-type-eq ty (Bool))
              (ctfe-test-expr-eq-in-env env node expected))]
          [_ false])]
      [(Err _) false])))

(define (compiler-ctfe-expr-pattern-match-clause-ok?) : bool
  (let
    [base-env : ctfe.CtfeEnv (ctfe.ctfe-env-empty)]
    [true-lit : i64 (ctfe.ctfe-ast-push base-env (Literal (Bool true)))]
    [false-lit : i64 (ctfe.ctfe-ast-push base-env (Literal (Bool false)))]
    [clause : ast.AstExprClause (ast.AstExprClause true-lit false-lit)]
    [subject : ctfe.CompilerCtfeValue (ExprClause clause)]
    [env : ctfe.CtfeEnv
      (ctfe.ctfe-env-extend-id
        base-env
        cbi.compiler-builtin-id-fix-subject
        subject)]
    [scrutinee : i64
      (ctfe.ctfe-ast-push env (Var cbi.compiler-builtin-id-fix-subject))]
    [clause-pattern : ast.AstPattern
      (ast.ast-pat-variant-id
        cbi.compiler-builtin-id-fix-ExprClause
        (ast.ast-pattern-cons
          (ast.ast-pat-binding-id cbi.compiler-builtin-id-fix-first)
          (ast.ast-pattern-cons
            (ast.ast-pat-binding-id cbi.compiler-builtin-id-fix-second)
            (ast.ast-pattern-list-new))))]
    [clause-arm : ast.AstMatchArm
      (ast.ast-match-arm
        clause-pattern
        (ctfe.ctfe-ast-push env (Var cbi.compiler-builtin-id-fix-second)))]
    [match-expr : i64
      (ast.ast-expr-match-with-pools
        (ctfe.ctfe-env-pools env)
        scrutinee
        (ast.ast-match-arm-cons clause-arm (ast.ast-match-arm-list-new)))]
    (match (ctfe.compiler-ctfe-eval
      (ctfe.ctfe-ast-get env match-expr)
      env
      (ctfe.ctfe-fuel-limit))
      [(Ok value _)
        (match value
          [(Expr node _) (ctfe-test-expr-eq-in-env env node false-lit)]
          [_ false])]
      [(Err _) false])))

(define (compiler-ctfe-expr-pattern-match-ok?) : bool
  (and
    (compiler-ctfe-expr-pattern-match-int-ok?)
    (compiler-ctfe-expr-pattern-match-if-ok?)
    (compiler-ctfe-expr-pattern-match-clause-ok?)))

(define (compiler-ctfe-local-while-ok?) : bool
  (let
    [env : ctfe.CtfeEnv (ctfe.ctfe-env-empty)]
    [pools : ast.AstNodePoolContext (ctfe.ctfe-env-pools env)]
    [zero : i64 (ctfe.ctfe-ast-push env (Literal (ast.ast-lit-int 0)))]
    [one : i64 (ctfe.ctfe-ast-push env (Literal (ast.ast-lit-int 1)))]
    [three : i64 (ctfe.ctfe-ast-push env (Literal (ast.ast-lit-int 3)))]
    [i-id : i64 (ctfe.ctfe-materialize-generated-name-id "i")]
    [i-var : i64 (ctfe.ctfe-ast-push env (Var i-id))]
    [loop-cond : i64 (ast.ast-expr-binary-with-pools pools (Lt) i-var three)]
    [increment : i64 (ast.ast-expr-binary-with-pools pools (Add) i-var one)]
    [set-i : i64 (ast.ast-expr-set-id-with-pools pools i-id increment)]
    [loop : i64
      (ctfe.ctfe-ast-push
        env
        (While
          loop-cond
          (ast.ast-expr-cons
            set-i
            (ast.ast-expr-cons
              (ctfe.ctfe-ast-push env (Literal Unit))
              (ast.ast-expr-list-new)))))]
    [loop-result : i64 (ctfe.ctfe-ast-push env (Var i-id))]
    [loop-body-result : i64
      (ctfe.ctfe-ast-push
        env
        (Begin
          (ast.ast-expr-cons
            loop
            (ast.ast-expr-cons loop-result (ast.ast-expr-list-new)))))]
    [loop-bindings : ast.AstLetBindingList
      (ast.ast-let-binding-cons
        (ast.ast-let-binding-id i-id (Some (I64)) zero)
        (ast.ast-let-binding-list-new))]
    [loop-let : i64
      (ast.ast-expr-let-with-pools pools loop-bindings loop-body-result)]
    [outer-id : i64 (ctfe.ctfe-materialize-generated-name-id "outer")]
    [immutable-env : ctfe.CtfeEnv
      (ctfe.ctfe-env-extend-id env outer-id (I64 0))]
    [immutable-set : i64 (ast.ast-expr-set-id-with-pools pools outer-id one)]
    [true-lit : i64 (ctfe.ctfe-ast-push env (Literal (Bool true)))]
    [unit-lit : i64 (ctfe.ctfe-ast-push env (Literal Unit))]
    [infinite-loop : i64
      (ast.ast-expr-while-with-pools pools true-lit unit-lit)]
    (and
      (compiler-ctfe-eval-i64-ok? loop-let env 3)
      (compiler-ctfe-eval-error-ok?
        immutable-set
        immutable-env
        "comptime set! requires a local let binding")
      (match (ctfe.compiler-ctfe-eval
        (ctfe.ctfe-ast-get env infinite-loop)
        env
        3)
        [(Err diag)
          (string.eq
            (cdiag.compiler-diagnostic-message (__tl-box-place diag))
            "compile-time evaluation limit exceeded")]
        [(Ok _ _) false]))))

(define (compiler-ctfe-env-i64-value-ok?
  [env : (& env ctfe.CtfeEnv)]
  [name-id : i64]
  [expected : i64]) : bool
  (match (ctfe.ctfe-env-lookup-id env name-id)
    [(Some value)
      (match value
        [(I64 actual) (= actual expected)]
        [_ false])]
    [(None) false]))

(define (compiler-ctfe-env-value-missing?
  [env : (& env ctfe.CtfeEnv)]
  [name-id : i64]) : bool
  (match (ctfe.ctfe-env-lookup-id env name-id)
    [(None) true]
    [(Some _) false]))

(define (compiler-ctfe-env-type-ok?
  [env : ctfe.CtfeEnv]
  [name-id : i64]
  [expected : ast.AstType]) : bool
  (match (ctfe.ctfe-env-lookup-type-id env name-id)
    [(Some actual) (ctfe.ctfe-type-eq actual expected)]
    [(No) false]))

;; Arena snapshots may branch and may outlive backing-array growth. Each branch
;; must continue following the parent index captured when its head was appended.
(define (compiler-ctfe-env-arena-snapshots-ok?) : bool
  (let
    [base : ctfe.CtfeEnv (ctfe.ctfe-env-empty)]
    [shared-id : i64 (ctfe.ctfe-materialize-generated-name-id "arena-shared")]
    [left-id : i64 (ctfe.ctfe-materialize-generated-name-id "arena-left")]
    [right-id : i64 (ctfe.ctfe-materialize-generated-name-id "arena-right")]
    [shared : ctfe.CtfeEnv
      (ctfe.ctfe-env-extend-typed-id base shared-id (I64 1) (I64))]
    [left : ctfe.CtfeEnv (ctfe.ctfe-env-extend-id shared left-id (I64 2))]
    [right : ctfe.CtfeEnv (ctfe.ctfe-env-extend-id shared right-id (I64 3))]
    [grown : ctfe.CtfeEnv right]
    ;; Exceed the initial capacity after both branches exist.
    (for [index (iterator.range 0 16)]
      (set! grown (ctfe.ctfe-env-extend-id grown (+ 100000 index) (I64 index))))
    (and
      (compiler-ctfe-env-value-missing? base shared-id)
      (compiler-ctfe-env-i64-value-ok? shared shared-id 1)
      (compiler-ctfe-env-type-ok? shared shared-id (I64))
      (compiler-ctfe-env-i64-value-ok? left left-id 2)
      (compiler-ctfe-env-i64-value-ok? left shared-id 1)
      (compiler-ctfe-env-value-missing? left right-id)
      (compiler-ctfe-env-i64-value-ok? grown (+ 100000 15) 15)
      (compiler-ctfe-env-i64-value-ok? grown right-id 3)
      (compiler-ctfe-env-i64-value-ok? grown shared-id 1)
      (compiler-ctfe-env-value-missing? grown left-id))))

;; Local identity belongs to a stable slot. Descendant snapshots retain that
;; identity, a newer local gets a different slot, and an immutable shadow stops
;; mutation before an older local with the same name.
(define (compiler-ctfe-env-arena-mutation-ok?) : bool
  (let
    [base : ctfe.CtfeEnv (ctfe.ctfe-env-empty)]
    [name-id : i64 (ctfe.ctfe-materialize-generated-name-id "arena-local")]
    [other-id : i64 (ctfe.ctfe-materialize-generated-name-id "arena-other")]
    [local : ctfe.CtfeEnv
      (ctfe.ctfe-env-extend-local-typed-id base name-id (I64 1) (I64))]
    [descendant : ctfe.CtfeEnv (ctfe.ctfe-env-extend-id local other-id (I64 9))]
    [updated-through-descendant? : bool
      (ctfe.ctfe-env-set-local-id! descendant name-id (I64 2))]
    [immutable-shadow : ctfe.CtfeEnv
      (ctfe.ctfe-env-extend-id descendant name-id (I64 3))]
    [immutable-stopped? : bool
      (not (ctfe.ctfe-env-set-local-id! immutable-shadow name-id (I64 4)))]
    [local-shadow : ctfe.CtfeEnv
      (ctfe.ctfe-env-extend-local-typed-id descendant name-id (I64 5) (I64))]
    [local-shadow-updated? : bool
      (ctfe.ctfe-env-set-local-id! local-shadow name-id (I64 6))]
    (and
      updated-through-descendant?
      immutable-stopped?
      local-shadow-updated?
      (compiler-ctfe-env-i64-value-ok? local name-id 2)
      (compiler-ctfe-env-i64-value-ok? descendant name-id 2)
      (compiler-ctfe-env-i64-value-ok? immutable-shadow name-id 3)
      (compiler-ctfe-env-i64-value-ok? local-shadow name-id 6)
      (compiler-ctfe-env-type-ok? local-shadow name-id (I64)))))

;; Rebasing changes only the definition pools. Bindings and root metadata stay
;; shared, while a captured value's newer syntax pools remain snapshot-local.
(define (compiler-ctfe-env-arena-provenance-ok?) : bool
  (let
    [definition-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new
        (ast.ast-expr-node-pool-state-create 8)
        (ast.ast-type-node-pool-state-create 8)
        ;; Self-test scratch pool: never installed, owned by the caller arena.
        (arena.tl_arena_current))]
    [rebased-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new
        (ast.ast-expr-node-pool-state-create 8)
        (ast.ast-type-node-pool-state-create 8)
        ;; Self-test scratch pool: never installed, owned by the caller arena.
        (arena.tl_arena_current))]
    [syntax-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new
        (ast.ast-expr-node-pool-state-create 8)
        (ast.ast-type-node-pool-state-create 8)
        ;; Self-test scratch pool: never installed, owned by the caller arena.
        (arena.tl_arena_current))]
    [layout-name : i64 cbi.compiler-builtin-id-fix-Packet]
    [layouts : ctfe.CtfeLayoutInfoList
      (ctfe.ctfe-layout-info-list-push-id
        (ctfe.ctfe-layout-info-list-with-capacity 1)
        (Info "Packet" true 8 8 (ctfe.ctfe-layout-field-list-empty))
        layout-name)]
    [reflection-env : ctfe.CtfeEnv (compiler-ctfe-reflection-env)]
    [source-names : ci.InternSourceNameSessionHandle
      (ci.intern-source-name-session-capture-active-handle)]
    [base : ctfe.CtfeEnv
      (ctfe-env-with-metadata-and-pools-and-source-names
        layouts
        (ctfe.ctfe-env-reflections reflection-env)
        definition-pools
        source-names)]
    [binding-id : i64 (ctfe.ctfe-materialize-generated-name-id "arena-rebase")]
    [bound : ctfe.CtfeEnv (ctfe.ctfe-env-extend-id base binding-id (I64 7))]
    [rebased : ctfe.CtfeEnv (ctfe.ctfe-env-rebase-pools bound rebased-pools)]
    [captured-node : i64
      (ast.ast-node-pool-context-expr-push syntax-pools (Literal (Bool true)))]
    [captured : ctfe.CtfeEnv
      (ctfe.ctfe-env-extend-id
        bound
        (+ binding-id 1)
        (CapturedExpr captured-node (Bool) syntax-pools))]
    [captured-child : ctfe.CtfeEnv
      (ctfe.ctfe-env-extend-id captured (+ binding-id 2) (I64 8))]
    [captured-rebased : ctfe.CtfeEnv
      (ctfe.ctfe-env-rebase-pools captured-child rebased-pools)]
    [rebased-reflections : ctfe.CtfeReflectInfoList
      (ctfe.ctfe-env-reflections rebased)]
    (and
      (compiler-ctfe-env-i64-value-ok? rebased binding-id 7)
      (ctfe.ctfe-node-pools-share-storage?
        (ctfe.ctfe-env-pools bound)
        definition-pools)
      (ctfe.ctfe-node-pools-share-storage?
        (ctfe.ctfe-env-pools rebased)
        rebased-pools)
      (not
        (ctfe.ctfe-node-pools-share-storage?
          (ctfe.ctfe-env-pools bound)
          (ctfe.ctfe-env-pools rebased)))
      (ctfe.ctfe-node-pools-share-storage?
        (ctfe.ctfe-env-syntax-pool-context captured)
        syntax-pools)
      (ctfe.ctfe-node-pools-share-storage?
        (ctfe.ctfe-env-syntax-pool-context captured-child)
        syntax-pools)
      (ctfe.ctfe-node-pools-share-storage?
        (ctfe.ctfe-env-syntax-pool-context captured-rebased)
        syntax-pools)
      (=
        (__tl-project-field (ctfe.ctfe-env-source-names rebased) address)
        source-names.address)
      (match (ctfe.ctfe-layout-info-lookup-name-id
        (ctfe.ctfe-env-layouts rebased)
        layout-name)
        [(Some _) true]
        [(None) false])
      (match (ctfe.ctfe-reflect-info-lookup-name-id
        rebased-reflections
        cbi.compiler-builtin-id-fix-Point)
        [(Some _) true]
        [(None) false]))))

(define (compiler-ctfe-env-arena-ok?) : bool
  (and
    (compiler-ctfe-env-arena-snapshots-ok?)
    (compiler-ctfe-env-arena-mutation-ok?)
    (compiler-ctfe-env-arena-provenance-ok?)))

(define (compiler-ctfe-generated-dotted-suffix-id-ok?) : bool
  (match (ctfe.ctfe-generated-string-append-value
    "."
    -1
    "Some"
    cbi.compiler-builtin-id-fix-Some)
    [(String suffix suffix-id)
      (if (and
        (string.eq suffix ".Some")
        (= (ci.intern-first-dot suffix-id) 0)
        (=
          (ci.intern-dotted-tail-id suffix-id)
          cbi.compiler-builtin-id-fix-Some))
        (match (ctfe.ctfe-generated-string-append-value
          "Maybe"
          cbi.compiler-builtin-id-fix-Maybe
          suffix
          suffix-id)
          [(String full full-id)
            (and
              (string.eq full "Maybe.Some")
              (=
                (ci.intern-leading-dot-id full-id)
                cbi.compiler-builtin-id-fix-Maybe)
              (=
                (ci.intern-dotted-tail-id full-id)
                cbi.compiler-builtin-id-fix-Some))]
          [_ false])
        false)]
    [_ false]))

(cfg
  test
  (define (compiler-ctfe-structural-field-ok?
    [value : ctfe.CompilerCtfeValue]
    [field-id : i64]
    [expr : (& expr ast.AstExpr)]) : bool
    (match (ctfe.ctfe-eval-struct-get-value
      value
      field-id
      (ctfe.ctfe-expr-shared-view expr)
      7)
      [(Ok _ next-fuel) (= next-fuel 7)]
      [(Err _) false])))

(cfg
  test
  (define (compiler-ctfe-comptime-structural-fields-ok?) : bool
    (let
      [env : ctfe.CtfeEnv (ctfe.ctfe-env-empty)]
      [pools : ast.AstNodePoolContext (ctfe.ctfe-env-pools env)]
      [expr : ast.AstExpr (Literal (Unit))]
      [exprs : ast.AstExprList (ast.ast-expr-list-new)]
      [clause : ast.AstExprClause (ast.ast-expr-clause 0 0)]
      [clauses : ast.AstExprClauseList (ast.ast-expr-clause-list-new)]
      [binding : ast.AstExprBindingClause
        (ast.ast-expr-binding-clause-id
          (ci.intern-syntax-id-from-raw cbi.compiler-builtin-id-fix-name)
          false
          0
          0
          (ctfe.ctfe-untyped-expr-type)
          (ast.ast-source-span 0 0 0 0))]
      [bindings : ast.AstExprBindingClauseList
        (ast.ast-expr-binding-clause-list-new)]
      [patterns : ast.AstPatternList (ast.ast-pattern-list-new)]
      [arm : ast.AstMatchArm (ast.ast-match-arm Wildcard 0)]
      [arms : ast.AstMatchArmList (ast.ast-match-arm-list-new)]
      [types : ast.AstTypeList (ast.ast-type-list-new)]
      [fields : ctfe.CtfeReflectFieldList
        (ctfe.ctfe-reflect-field-list-with-capacity 0)]
      [variants : ctfe.CtfeReflectVariantList
        (ctfe.ctfe-reflect-variant-list-with-capacity 0)]
      [generated-items : i64 (ci.intern-generated-canonical-name "items")]
      (and
        (ci.intern-syntax-id-eq?
          (ctfe.ctfe-expr-binding-clause-name-id (clone binding))
          (ci.intern-syntax-id-from-raw cbi.compiler-builtin-id-fix-name))
        (compiler-ctfe-structural-field-ok?
          (ExprList (clone exprs))
          cbi.compiler-builtin-id-fix-items
          expr)
        (compiler-ctfe-structural-field-ok?
          (ExprList (clone exprs))
          cbi.compiler-builtin-id-fix-len
          expr)
        (compiler-ctfe-structural-field-ok?
          (CapturedExprList
            (clone exprs)
            (ast.ast-node-pool-context-clone pools))
          cbi.compiler-builtin-id-fix-items
          expr)
        (compiler-ctfe-structural-field-ok?
          (CapturedExprList
            (clone exprs)
            (ast.ast-node-pool-context-clone pools))
          cbi.compiler-builtin-id-fix-len
          expr)
        (compiler-ctfe-structural-field-ok?
          (ExprClause (clone clause))
          cbi.compiler-builtin-id-fix-first
          expr)
        (compiler-ctfe-structural-field-ok?
          (ExprClause (clone clause))
          cbi.compiler-builtin-id-fix-second
          expr)
        (compiler-ctfe-structural-field-ok?
          (CapturedExprClause
            (clone clause)
            (ast.ast-node-pool-context-clone pools))
          cbi.compiler-builtin-id-fix-first
          expr)
        (compiler-ctfe-structural-field-ok?
          (CapturedExprClause
            (clone clause)
            (ast.ast-node-pool-context-clone pools))
          cbi.compiler-builtin-id-fix-second
          expr)
        (compiler-ctfe-structural-field-ok?
          (ExprClauseList (clone clauses))
          cbi.compiler-builtin-id-fix-items
          expr)
        (compiler-ctfe-structural-field-ok?
          (ExprClauseList (clone clauses))
          cbi.compiler-builtin-id-fix-len
          expr)
        (compiler-ctfe-structural-field-ok?
          (CapturedExprClauseList
            (clone clauses)
            (ast.ast-node-pool-context-clone pools))
          cbi.compiler-builtin-id-fix-items
          expr)
        (compiler-ctfe-structural-field-ok?
          (CapturedExprClauseList
            (clone clauses)
            (ast.ast-node-pool-context-clone pools))
          cbi.compiler-builtin-id-fix-len
          expr)
        (compiler-ctfe-structural-field-ok?
          (ExprBindingClause (clone binding))
          cbi.compiler-builtin-id-fix-name
          expr)
        (compiler-ctfe-structural-field-ok?
          (ExprBindingClause (clone binding))
          cbi.compiler-builtin-id-fix-has_type
          expr)
        (compiler-ctfe-structural-field-ok?
          (ExprBindingClause (clone binding))
          cbi.compiler-builtin-id-fix-ty
          expr)
        (compiler-ctfe-structural-field-ok?
          (ExprBindingClause (clone binding))
          cbi.compiler-builtin-id-fix-init
          expr)
        (compiler-ctfe-structural-field-ok?
          (ExprBindingClauseList (clone bindings))
          cbi.compiler-builtin-id-fix-items
          expr)
        (compiler-ctfe-structural-field-ok?
          (ExprBindingClauseList (clone bindings))
          cbi.compiler-builtin-id-fix-len
          expr)
        (compiler-ctfe-structural-field-ok?
          (PatternList (clone patterns))
          cbi.compiler-builtin-id-fix-items
          expr)
        (compiler-ctfe-structural-field-ok?
          (PatternList (clone patterns))
          cbi.compiler-builtin-id-fix-len
          expr)
        (compiler-ctfe-structural-field-ok?
          (MatchArm (clone arm))
          cbi.compiler-builtin-id-fix-pattern
          expr)
        (compiler-ctfe-structural-field-ok?
          (MatchArm (clone arm))
          cbi.compiler-builtin-id-fix-body
          expr)
        (compiler-ctfe-structural-field-ok?
          (MatchArmList (clone arms))
          cbi.compiler-builtin-id-fix-items
          expr)
        (compiler-ctfe-structural-field-ok?
          (MatchArmList (clone arms))
          cbi.compiler-builtin-id-fix-len
          expr)
        (compiler-ctfe-structural-field-ok?
          (TypeInfoList (clone types))
          cbi.compiler-builtin-id-fix-items
          expr)
        (compiler-ctfe-structural-field-ok?
          (TypeInfoList (clone types))
          cbi.compiler-builtin-id-fix-len
          expr)
        (compiler-ctfe-structural-field-ok?
          (TypeField "value" (I64))
          cbi.compiler-builtin-id-fix-name
          expr)
        (compiler-ctfe-structural-field-ok?
          (TypeField "value" (I64))
          cbi.compiler-builtin-id-fix-ty
          expr)
        (compiler-ctfe-structural-field-ok?
          (TypeFieldList (clone fields))
          cbi.compiler-builtin-id-fix-items
          expr)
        (compiler-ctfe-structural-field-ok?
          (TypeFieldList (clone fields))
          cbi.compiler-builtin-id-fix-len
          expr)
        (compiler-ctfe-structural-field-ok?
          (TypeVariantPayload (I64))
          cbi.compiler-builtin-id-fix-ty
          expr)
        (compiler-ctfe-structural-field-ok?
          (TypeVariantPayloadList (clone types))
          cbi.compiler-builtin-id-fix-items
          expr)
        (compiler-ctfe-structural-field-ok?
          (TypeVariantPayloadList (clone types))
          cbi.compiler-builtin-id-fix-len
          expr)
        (compiler-ctfe-structural-field-ok?
          (TypeVariant "Some" (clone types))
          cbi.compiler-builtin-id-fix-name
          expr)
        (compiler-ctfe-structural-field-ok?
          (TypeVariant "Some" (clone types))
          cbi.compiler-builtin-id-fix-payloads
          expr)
        (compiler-ctfe-structural-field-ok?
          (TypeVariantList (clone variants))
          cbi.compiler-builtin-id-fix-items
          expr)
        (compiler-ctfe-structural-field-ok?
          (TypeVariantList (clone variants))
          cbi.compiler-builtin-id-fix-len
          expr)
        (match (ctfe.ctfe-eval-struct-get-value
          (ExprList exprs)
          generated-items
          expr
          7)
          [(Err diag)
            (string.eq
              (cdiag.compiler-diagnostic-message (__tl-box-place diag))
              "unsupported stdlib.comptime field 'items'")]
          [(Ok _ _) false])))))

;; Compress `source` as an `include-str-lzss` payload and decode it with the
;; runtime decoder. Returns the token-stream length, or -1 unless the decoded
;; bytes are exactly `source`.
(define (compiler-ctfe-lzss-roundtrip-length [source : String]) : i64
  (let
    [envelope : String
      (ctfe.ctfe-embedded-stdlib-binary-data-bytes (clone source))]
    [envelope-len : i64 (string.string-length envelope)]
    [source-len : i64 (string.string-length source)]
    [header-len : i64
      (+
        (string.string-length (ctfe.ctfe-embedded-stdlib-compressed-prefix))
        (string.string-length (string.int->string source-len))
        1)]
    [payload : (__tl_dyn-array u8) (__tl_make-array u8 envelope-len)]
    (for [index (iterator.range 0 envelope-len)]
      (set!
        (array-ref payload index)
        (cast (string.string-ref envelope index) : u8)))
    (match (lzss.compiler-lzss-decode (& payload) source-len)
      [(Ok bytes)
        (let
          [same : bool (= (array-length bytes) source-len)]
          [cursor : i64 0]
          (while (and same (< cursor source-len))
            (unless
              (=
                (array-ref bytes cursor)
                (cast (string.string-ref source cursor) : u8))
              (set! same false))
            (+= cursor 1))
          (if same
            (- envelope-len header-len)
            -1))]
      [(Err _) -1])))

;; Append `count` pseudo-random bytes below `alphabet`, seeded by `seed`.
(define (compiler-ctfe-lzss-push-noise!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [count : i64]
  [alphabet : i64]
  [seed : i64]) : unit
  (let
    [state : i64 seed]
    (for [index (iterator.range 0 count)]
      (set! state (bit-and (+ (* state 1103515245) 12345) 2147483647))
      (byte_buf_core.byte-buf-builder-push
        (&mut out)
        (cast (% (shr state 16) alphabet) : u8)))))

;; `marker`, `gap` noise bytes, `marker` again, then the same with `gap` + 1:
;; the first pair of copies is exactly 4096 bytes apart, the widest offset a
;; token encodes, and the second pair is one byte too far.
(define (compiler-ctfe-lzss-window-source [marker : String]) : String
  (let
    [gap : i64 (- 4096 (string.string-length marker))]
    [out : byte_buf_core.ByteBufBuilder
      (byte_buf_core.byte-buf-builder-with-capacity 8400)]
    (byte_buf_core.byte-buf-builder-append-string (&mut out) (clone marker))
    (compiler-ctfe-lzss-push-noise! (&mut out) gap 256 7)
    (byte_buf_core.byte-buf-builder-append-string (&mut out) (clone marker))
    (compiler-ctfe-lzss-push-noise! (&mut out) (+ gap 1) 256 11)
    (byte_buf_core.byte-buf-builder-append-string (&mut out) marker)
    (byte_buf_core.byte-buf-builder-to-string (& out))))

(define (compiler-ctfe-lzss-noise-source [count : i64] [alphabet : i64]) : String
  (let
    [out : byte_buf_core.ByteBufBuilder
      (byte_buf_core.byte-buf-builder-with-capacity count)]
    (compiler-ctfe-lzss-push-noise! (&mut out) count alphabet 12345)
    (byte_buf_core.byte-buf-builder-to-string (& out))))

;; The compressor's tokens decode to the exact source at every parse
;; boundary. "abc" at 15 matches 3 bytes, "bcdefghijk" at 16 matches 10: greedy
;; parsing spends 22 bytes, the lazy step a literal and one 10-byte match (21).
(define (compiler-ctfe-lzss-roundtrip-ok?) : bool
  (and
    (= (compiler-ctfe-lzss-roundtrip-length "") 0)
    (= (compiler-ctfe-lzss-roundtrip-length "ab") 3)
    (let
      [lazy : i64
        (compiler-ctfe-lzss-roundtrip-length "abcZbcdefghijk_abcdefghijk")]
      (and (> lazy 0) (<= lazy 21)))
    ;; Two deferrals in a row: "abc" < "bcde" < "cdefghijkl".
    (>
      (compiler-ctfe-lzss-roundtrip-length "abcQbcdeRcdefghijkl_abcdefghijkl")
      0)
    ;; A 5-byte match looks ahead to a longer one, a 6-byte match does not.
    (> (compiler-ctfe-lzss-roundtrip-length "abcdeQbcdefghij_abcdefghij") 0)
    (> (compiler-ctfe-lzss-roundtrip-length "abcdefQbcdefghijk_abcdefghijk") 0)
    ;; Matches one byte short of and at the 18-byte maximum.
    (>
      (compiler-ctfe-lzss-roundtrip-length
        "0123456789abcdefg#0123456789abcdefgh")
      0)
    (>
      (compiler-ctfe-lzss-roundtrip-length
        "0123456789abcdefgh#0123456789abcdefgh")
      0)
    (>
      (compiler-ctfe-lzss-roundtrip-length
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
      0)
    (>
      (compiler-ctfe-lzss-roundtrip-length
        (compiler-ctfe-lzss-window-source "<marker:0123456789>"))
      0)
    ;; Three symbols put about 150 window positions on every chain, past the
    ;; 64-link walk cap.
    (>
      (compiler-ctfe-lzss-roundtrip-length
        (compiler-ctfe-lzss-noise-source 6000 3))
      0)))

(define (compiler-ctfe-self-test) : i64
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (unless (compiler-ctfe-type-literal-ok?) (return 1))
    (unless (compiler-ctfe-type-comparison-ok?) (return 1))
    (unless (compiler-ctfe-raw-pointer-type-comparison-ok?) (return 1))
    (unless (compiler-ctfe-fixed-type-head-name-provenance-ok?) (return 1))
    (unless (compiler-ctfe-dyn-array-type-head-ok?) (return 1))
    (unless (compiler-ctfe-slice-type-head-ok?) (return 1))
    (unless (compiler-ctfe-f64-ok?) (return 1))
    (unless (compiler-ctfe-layout-query-ok?) (return 1))
    (unless (compiler-ctfe-reflection-query-ok?) (return 1))
    (unless (compiler-ctfe-type-expr-foreign-pool-ok?) (return 1))
    (unless (compiler-ctfe-type-expr-roundtrip-ok?) (return 1))
    (unless (compiler-ctfe-module-value-index-state-ok?) (return 1))
    (unless (compiler-ctfe-module-value-query-ok?) (return 1))
    (unless (compiler-ctfe-reflection-from-program-ok?) (return 1))
    (unless (compiler-ctfe-type-info-box-pool-coherency-ok?) (return 1))
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
    (unless (compiler-ctfe-quote-lambda-type-unquote-ok?) (return 1))
    (unless (compiler-ctfe-expr-lambda1-ok?) (return 1))
    (unless (compiler-ctfe-captured-quote-syntax-ok?) (return 1))
    (unless (compiler-ctfe-expr-pattern-match-ok?) (return 1))
    (unless (compiler-ctfe-local-while-ok?) (return 1))
    (unless (compiler-ctfe-env-arena-ok?) (return 1))
    (unless (compiler-ctfe-generated-dotted-suffix-id-ok?) (return 1))
    (unless (compiler-ctfe-lzss-roundtrip-ok?) (return 1))
    (cfg
      test
      (unless (compiler-ctfe-comptime-structural-fields-ok?) (return 1))
      unit)
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