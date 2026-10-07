;; The specialization substitution walk applies type and value bindings
;; together (#7534). It reports what the former type-then-value passes did and
;; rebuilds each expression row once.
(import compiler_specialize as spec)
(import compiler_ast_types as ast)
(import compiler_builtin_ids as cbi)
(import compiler_intern as ci)
(import compiler_parse_core as parser)
(import compiler_diagnostic as diagnostic)
(import stdlib.string)
(import stdlib.test)

(define (specialize-rejects-with? [source : String] [message : String]) : bool
  (match (parser.parse-ast-source source)
    [(Ok program)
      (match (spec.compiler-specialize-program program)
        [(Err boxed-diag)
          (let
            [diag : diagnostic.CompilerDiagnostic
              (diagnostic.compiler-diagnostic-box-shared-view boxed-diag)]
            (string.eq diag.message message))]
        [(Ok _) false])]
    [(Err _) false]))

(test
  substitution-type-failure-outranks-earlier-value-failure
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (test.assert-true
      (specialize-rejects-with?
        "(define (bad [comptime T : type] [comptime n : i64]) : i64
           (begin (set! n 1) T))
         (define (main) : i64 (bad (type i64) 3))"
        "type-valued comptime parameter 'T' cannot be used as a runtime value")
      "a later runtime use of a type parameter wins over an earlier assignment")
    (test.assert-true
      (specialize-rejects-with?
        "(define (bad [comptime T : type] [comptime m : i64]) : i64
           (begin (ptr-addr-of m) (set! T 1)))
         (define (main) : i64 (bad (type i64) 3))"
        "type-valued comptime parameter 'T' cannot be assigned")
      "a later assignment to a type parameter wins over an earlier address-of")
    (test.assert-true
      (specialize-rejects-with?
        "(define (bad [comptime T : type] [comptime s : String]) : i64
           (begin s T))
         (define (main) : i64 (bad (type i64) \"text\"))"
        "type-valued comptime parameter 'T' cannot be used as a runtime value")
      "a type failure wins over a value with no runtime form")))

(test
  substitution-type-failure-inside-value-failure-wins
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (test.assert-true
      (specialize-rejects-with?
        "(define (bad [comptime T : type] [comptime n : i64]) : i64
           (set! n T))
         (define (main) : i64 (bad (type i64) 3))"
        "type-valued comptime parameter 'T' cannot be used as a runtime value")
      "the assigned value is still checked for type failures")
    (test.assert-true
      (specialize-rejects-with?
        "(define (bad [comptime T : type] [comptime n : i64]) : i64
           (ptr-addr-of (array-ref n T)))
         (define (main) : i64 (bad (type i64) 3))"
        "type-valued comptime parameter 'T' cannot be used as a runtime value")
      "the address-of place is still checked for type failures")))

(test
  substitution-first-value-failure-without-type-failure
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (test.assert-true
      (specialize-rejects-with?
        "(define (bad [comptime T : type] [comptime n : i64] [comptime m : i64]) : T
           (begin (set! n 1) (ptr-addr-of m)))
         (define (main) : i64 (bad (type i64) 3 4))"
        "cannot assign to comptime parameter 'n'")
      "the first value failure in walk order is reported")
    (test.assert-true
      (specialize-rejects-with?
        "(define (bad [comptime n : i64] [comptime m : i64]) : i64
           (begin (ptr-addr-of m) (set! n 1)))
         (define (main) : i64 (bad 3 4))"
        "cannot take address of comptime value parameter 'm'")
      "an earlier address-of wins over a later assignment")
    (test.assert-true
      (specialize-rejects-with?
        "(define (bad [comptime T : type] [comptime n : i64]) : i64
           (begin (set! n 1) (let [T : i64 2] T)))
         (define (main) : i64 (bad (type i64) 3))"
        "cannot assign to comptime parameter 'n'")
      "a binder shadows the type parameter, so the value failure stands")))

(define (literal-five? [owner : (& owner spec.SpecOwnerContext)] [id : i64]) : bool
  (match (spec.spec-owner-expr-get owner id)
    [(Literal literal)
      (match literal
        [(Int n _) (= n 5)]
        [_ false])]
    [_ false]))

(define (i64-type? [owner : (& owner spec.SpecOwnerContext)] [id : i64]) : bool
  (match (spec.spec-owner-type-get owner id)
    [(I64) true]
    [_ false]))

;; `(begin (ann x : T) (cast x : T) x)` with value parameter x = 5 and type
;; parameter T = i64 becomes `(begin (ann 5 : i64) (cast 5 : i64) 5)`.
(define (rewritten-begin-ok?
  [owner : (& owner spec.SpecOwnerContext)]
  [id : i64]) : bool
  (match (spec.spec-owner-expr-get owner id)
    [(Begin items)
      (and
        (= items.len 3)
        (match (spec.spec-owner-expr-get
          owner
          (ast.ast-expr-list-get (& items) 0 0))
          [(Ann inner ty)
            (and (literal-five? owner inner) (i64-type? owner ty))]
          [_ false])
        (match (spec.spec-owner-expr-get
          owner
          (ast.ast-expr-list-get (& items) 1 0))
          [(Cast inner ty)
            (and (literal-five? owner inner) (i64-type? owner ty))]
          [_ false])
        (literal-five? owner (ast.ast-expr-list-get (& items) 2 0)))]
    [_ false]))

(test
  substitution-rebuilds-each-row-once
  (let
    [_builtins : unit (cbi.compiler-builtin-initialize-for-parse!)]
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 32 32)]
    [owner : spec.SpecOwnerContext
      (let
        [intern-state (ci.intern-compat-state-capture-active)]
        (spec.spec-owner-context-new pools intern-state))]
    [rows-before-body : i64 (ast.ast-node-pool-context-expr-len pools)]
    [ty : i64
      (spec.spec-owner-type-push (& owner) (Var cbi.compiler-builtin-id-fix-T))]
    [items : ast.AstExprList (ast.ast-expr-list-new)]
    (ast.ast-expr-list-push
      (&mut items)
      (spec.spec-owner-expr-push
        (& owner)
        (Ann
          (spec.spec-owner-expr-push
            (& owner)
            (Var cbi.compiler-builtin-id-fix-x))
          ty)))
    (ast.ast-expr-list-push
      (&mut items)
      (spec.spec-owner-expr-push
        (& owner)
        (Cast
          (spec.spec-owner-expr-push
            (& owner)
            (Var cbi.compiler-builtin-id-fix-x))
          ty)))
    (ast.ast-expr-list-push
      (&mut items)
      (spec.spec-owner-expr-push (& owner) (Var cbi.compiler-builtin-id-fix-x)))
    (let
      [body : ast.AstExpr (Begin items)]
      [body-rows : i64
        (+ (- (ast.ast-node-pool-context-expr-len pools) rows-before-body) 1)]
      [subs : spec.SpecSubst
        (spec.SpecSubst
          (spec.spec-type-subst-cons
            cbi.compiler-builtin-id-fix-T
            (I64)
            (spec.spec-type-subst-new))
          (spec.spec-value-subst-cons
            cbi.compiler-builtin-id-fix-x
            (I64 5)
            (spec.spec-value-subst-new)))]
      [rows-before-walk : i64 (ast.ast-node-pool-context-expr-len pools)]
      (match (spec.spec-substitute-expr-with-owner (& owner) body (& subs))
        [(Ok result)
          (begin
            (test.assert-true
              (rewritten-begin-ok? (& owner) result)
              "the body is rewritten with both bindings")
            (test.assert-i64-eq
              (- (ast.ast-node-pool-context-expr-len pools) rows-before-walk)
              body-rows
              "one expression row per body row, not one per pass"))]
        [_ (test.assert-true false "substitution succeeds")]))))