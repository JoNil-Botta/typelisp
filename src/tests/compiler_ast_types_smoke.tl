;; compiler_ast_types_smoke.tl - Runnable AST data-shape smoke.
(import stdlib.str_cat_runtime as str_cat)
(import compiler_ast_types as ast)
(import compiler_builtin_ids as cbi)
(import compiler_intern as ci)
(import compiler_intern_state as cis)
(import compiler_owned_view as owned_view)
(import stdlib.arena)
(import stdlib.string)
(cfg test (import stdlib.test as tl_test))

(define (compiler-ast-test-fresh-local-id
  [ordinal : i64]
  [source-name-id : i64]) : i64
  (let
    [intern-state : ci.InternCompatState
      (ci.intern-compat-state-capture-active)]
    [session : cis.InternStructuralSessionHandle
      (cis.intern-structural-session-handle-from-source-names
        (ci.intern-source-name-session-handle-from-state intern-state))]
    (cis.intern-fresh-local-identity-raw
      (cis.intern-structural-session-fresh-local-identity
        session
        ordinal
        source-name-id))))

(define (compiler-ast-int-literal-source-bits-smoke?) : bool
  (let
    [i64-max : i64 (cast (shr (bit-not (cast 0 : u64)) (cast 1 : u64)) : i64)]
    [i64-min : i64 (cast (shl (cast 1 : u64) (cast 63 : u64)) : i64)]
    (and
      (=
        (ast.ast-int-literal-value-or-payload -1 "9223372036854775807")
        i64-max)
      (= (ast.ast-int-literal-value-or-payload -1 "0x7fffffffffffffff") i64-max)
      (=
        (ast.ast-int-literal-value-or-payload
          -1
          "0b0111111111111111111111111111111111111111111111111111111111111111")
        i64-max)
      (=
        (ast.ast-int-literal-value-or-payload 0 "-9223372036854775808")
        i64-min)
      (= (ast.ast-int-literal-value-or-payload 0 "-0x8000000000000000") i64-min)
      (=
        (ast.ast-int-literal-value-or-payload
          0
          "-0b1000000000000000000000000000000000000000000000000000000000000000")
        i64-min)
      (= (ast.ast-int-literal-value-or-payload 0 "18446744073709551615") -1)
      (= (ast.ast-int-literal-value-or-payload 0 "0xffffffffffffffff") -1)
      (= (ast.ast-int-literal-value-or-payload 73 "") 73))))

(define (compiler-ast-state-expr-int-lit?
  [pool : (& pool ast.AstExprNodePoolState)]
  [id : i64]
  [expected : i64]) : bool
  (match (ast.ast-expr-node-pool-state-get pool id)
    [(ast.AstExpr.Literal lit)
      (match lit
        [(ast.AstLiteral.Int value _) (= value expected)]
        [_ false])]
    [_ false]))

(define (compiler-ast-state-type-i64?
  [pool : ast.AstTypeNodePoolState]
  [id : i64]) : bool
  (match (ast.ast-type-node-pool-state-get pool id)
    [(ast.AstType.I64) true]
    [_ false]))

(define (compiler-ast-state-type-string?
  [pool : ast.AstTypeNodePoolState]
  [id : i64]) : bool
  (match (ast.ast-type-node-pool-state-get pool id)
    [(ast.AstType.String) true]
    [_ false]))

(define (compiler-ast-state-type-char?
  [pool : ast.AstTypeNodePoolState]
  [id : i64]) : bool
  (match (ast.ast-type-node-pool-state-get pool id)
    [(ast.AstType.Char) true]
    [_ false]))

(define (compiler-ast-state-expr-push-pool
  [pool : ast.AstExprNodePoolState]
  [node : ast.AstExpr]) : ast.AstExprNodePoolState
  (match (ast.ast-expr-node-pool-state-push pool node)
    [(ast.AstExprNodePoolPushOk next _) next]))

(define (compiler-ast-state-type-push-pool
  [pool : ast.AstTypeNodePoolState]
  [node : ast.AstType]) : ast.AstTypeNodePoolState
  (match (ast.ast-type-node-pool-state-push pool node)
    [(ast.AstTypeNodePoolPushOk next _) next]))

(define (compiler-ast-state-owned-expr-pool-smoke?) : bool
  (let
    [a0 : ast.AstExprNodePoolState (ast.ast-expr-node-pool-state-create 1)]
    [aid0 : i64 (ast.ast-expr-node-pool-state-mark a0)]
    [a1 : ast.AstExprNodePoolState
      (compiler-ast-state-expr-push-pool
        a0
        (ast.AstExpr.Literal (ast.ast-lit-int 1)))]
    [aid1 : i64 (ast.ast-expr-node-pool-state-mark a1)]
    [a2 : ast.AstExprNodePoolState
      (compiler-ast-state-expr-push-pool
        a1
        (ast.AstExpr.Literal (ast.ast-lit-int 2)))]
    [b0 : ast.AstExprNodePoolState (ast.ast-expr-node-pool-state-create 1)]
    [bmark : i64 (ast.ast-expr-node-pool-state-mark b0)]
    [bid0 : i64 (ast.ast-expr-node-pool-state-mark b0)]
    [b1 : ast.AstExprNodePoolState
      (compiler-ast-state-expr-push-pool
        b0
        (ast.AstExpr.Literal (ast.ast-lit-int 10)))]
    [breset : ast.AstExprNodePoolState
      (ast.ast-expr-node-pool-state-reset-to-mark b1 bmark)]
    [bid1 : i64 (ast.ast-expr-node-pool-state-mark breset)]
    [b2 : ast.AstExprNodePoolState
      (compiler-ast-state-expr-push-pool
        breset
        (ast.AstExpr.Literal (ast.ast-lit-int 11)))]
    [b3 : ast.AstExprNodePoolState
      (ast.ast-expr-node-pool-state-set!
        b2
        bid1
        (ast.AstExpr.Literal (ast.ast-lit-int 12)))]
    (and
      (= aid0 0)
      (= aid1 1)
      (= bid0 0)
      (= bid1 0)
      (= (ast.ast-expr-node-pool-state-len a2) 2)
      (= (ast.ast-expr-node-pool-state-len b3) 1)
      (compiler-ast-state-expr-int-lit? a2 aid0 1)
      (compiler-ast-state-expr-int-lit? a2 aid1 2)
      (compiler-ast-state-expr-int-lit? b3 bid1 12))))

(define (compiler-ast-state-owned-type-pool-smoke?) : bool
  (let
    [a0 : ast.AstTypeNodePoolState (ast.ast-type-node-pool-state-create 1)]
    [aid0 : i64
      (ast.ast-type-node-pool-state-mark
        (owned_view.compiler-owned-shared-view a0))]
    [a1 : ast.AstTypeNodePoolState
      (compiler-ast-state-type-push-pool a0 (ast.AstType.I64))]
    [aid1 : i64
      (ast.ast-type-node-pool-state-mark
        (owned_view.compiler-owned-shared-view a1))]
    [a2 : ast.AstTypeNodePoolState
      (compiler-ast-state-type-push-pool a1 (ast.AstType.String))]
    [b0 : ast.AstTypeNodePoolState (ast.ast-type-node-pool-state-create 1)]
    [bmark : i64
      (ast.ast-type-node-pool-state-mark
        (owned_view.compiler-owned-shared-view b0))]
    [bid0 : i64
      (ast.ast-type-node-pool-state-mark
        (owned_view.compiler-owned-shared-view b0))]
    [b1 : ast.AstTypeNodePoolState
      (compiler-ast-state-type-push-pool b0 (ast.AstType.Bool))]
    [breset : ast.AstTypeNodePoolState
      (ast.ast-type-node-pool-state-reset-to-mark b1 bmark)]
    [bid1 : i64
      (ast.ast-type-node-pool-state-mark
        (owned_view.compiler-owned-shared-view breset))]
    [b2 : ast.AstTypeNodePoolState
      (compiler-ast-state-type-push-pool breset (ast.AstType.I64))]
    [b3 : ast.AstTypeNodePoolState
      (ast.ast-type-node-pool-state-set! b2 bid1 (ast.AstType.Char))]
    (and
      (= aid0 0)
      (= aid1 1)
      (= bid0 0)
      (= bid1 0)
      (= (ast.ast-type-node-pool-state-len a2) 2)
      (= (ast.ast-type-node-pool-state-len b3) 1)
      (not (ast.ast-type-node-pool-state-exhausted? a2))
      (compiler-ast-state-type-i64?
        (owned_view.compiler-owned-shared-view a2)
        aid0)
      (compiler-ast-state-type-string? a2 aid1)
      (compiler-ast-state-type-char? b3 bid1))))

(define (compiler-ast-state-owned-type-dedup-reuse-smoke?) : bool
  (match (ast.ast-type-node-pool-state-push
    (ast.ast-type-node-pool-state-create 1)
    (ast.AstType.I64))
    [(ast.AstTypeNodePoolPushOk p1 first-id)
      (match (ast.ast-type-node-pool-state-push p1 (ast.AstType.I64))
        [(ast.AstTypeNodePoolPushOk p2 second-id)
          (and
            (= first-id 0)
            (= second-id first-id)
            (= (ast.ast-type-node-pool-state-len p2) 1)
            (compiler-ast-state-type-i64? p2 first-id))])]))

(define (compiler-ast-state-owned-type-dedup-isolated-smoke?) : bool
  (match (ast.ast-type-node-pool-state-push
    (ast.ast-type-node-pool-state-create 1)
    (ast.AstType.I64))
    [(ast.AstTypeNodePoolPushOk a1 a-id)
      (match (ast.ast-type-node-pool-state-push
        (ast.ast-type-node-pool-state-create 1)
        (ast.AstType.I64))
        [(ast.AstTypeNodePoolPushOk b1 b-id)
          (match (ast.ast-type-node-pool-state-push a1 (ast.AstType.I64))
            [(ast.AstTypeNodePoolPushOk a2 a-dupe-id)
              (match (ast.ast-type-node-pool-state-push b1 (ast.AstType.I64))
                [(ast.AstTypeNodePoolPushOk b2 b-dupe-id)
                  (and
                    (= a-id 0)
                    (= b-id 0)
                    (= a-dupe-id a-id)
                    (= b-dupe-id b-id)
                    (= (ast.ast-type-node-pool-state-len a2) 1)
                    (= (ast.ast-type-node-pool-state-len b2) 1)
                    (compiler-ast-state-type-i64? a2 a-id)
                    (compiler-ast-state-type-i64? b2 b-id))])])])]))

(define (compiler-ast-state-owned-type-dedup-reset-smoke?) : bool
  (match (ast.ast-type-node-pool-state-push
    (ast.ast-type-node-pool-state-create 1)
    (ast.AstType.I64))
    [(ast.AstTypeNodePoolPushOk p1 i64-id)
      (match (ast.ast-type-node-pool-state-push p1 (ast.AstType.String))
        [(ast.AstTypeNodePoolPushOk p2 string-id)
          (let
            [reset : ast.AstTypeNodePoolState
              (ast.ast-type-node-pool-state-reset-to-mark p2 1)]
            (match (ast.ast-type-node-pool-state-push
              reset
              (ast.AstType.String))
              [(ast.AstTypeNodePoolPushOk p3 string-id2)
                (and
                  (= i64-id 0)
                  (= string-id 1)
                  (= string-id2 1)
                  (= (ast.ast-type-node-pool-state-len p3) 2)
                  (compiler-ast-state-type-i64?
                    (owned_view.compiler-owned-shared-view p3)
                    i64-id)
                  (compiler-ast-state-type-string? p3 string-id2))]))])]))

(define (compiler-ast-state-owned-type-dedup-budget-smoke?) : bool
  ;; Keep the source-macro self-host uniqueness budget from silently shrinking
  ;; back below the measured 37.5K-node surface.
  (>=
    (array-length
      (__tl-project-field (ast.ast-type-node-pool-state-create 1) dedup-slots))
    131072))

(define (compiler-ast-state-owned-node-pools-smoke?) : bool
  (and
    (compiler-ast-state-owned-expr-pool-smoke?)
    (compiler-ast-state-owned-type-pool-smoke?)
    (compiler-ast-state-owned-type-dedup-reuse-smoke?)
    (compiler-ast-state-owned-type-dedup-isolated-smoke?)
    (compiler-ast-state-owned-type-dedup-reset-smoke?)
    (compiler-ast-state-owned-type-dedup-budget-smoke?)))

(define (compiler-ast-context-type-i64?
  [pools : (& pools ast.AstNodePoolContext)]
  [id : i64]) : bool
  (match (ast.ast-node-pool-context-type-get pools id)
    [(ast.AstType.I64) true]
    [_ false]))

(define (compiler-ast-context-type-char?
  [pools : (& pools ast.AstNodePoolContext)]
  [id : i64]) : bool
  (match (ast.ast-node-pool-context-type-get pools id)
    [(ast.AstType.Char) true]
    [_ false]))

(define (compiler-ast-context-expr-int-lit?
  [pools : (& pools ast.AstNodePoolContext)]
  [id : i64]
  [expected : i64]) : bool
  (match (ast.ast-node-pool-context-expr-get pools id)
    [(ast.AstExpr.Literal lit)
      (match lit
        [(ast.AstLiteral.Int value _) (= value expected)]
        [_ false])]
    [_ false]))

(define (compiler-ast-expr-int-lit-value? [expr : ast.AstExpr] [expected : i64]) : bool
  (match expr
    [(ast.AstExpr.Literal lit)
      (match lit
        [(ast.AstLiteral.Int value _) (= value expected)]
        [_ false])]
    [_ false]))

;; The stable-segment walkers consume each row view immediately. Exercise the
;; boundaries that end one view and require a fresh read: exact-row rewrite,
;; truncation/reuse, and selecting another context with the same numeric ids.
(define (compiler-ast-stable-expr-row-view-boundaries-smoke?) : bool
  (let
    [a : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 1 1)]
    [b : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 1 1)]
    [a-literal : i64
      (ast.ast-node-pool-context-expr-push
        (owned_view.compiler-owned-shared-view a)
        (ast.AstExpr.Literal (ast.ast-lit-int 11)))]
    [a-spanned : i64
      (ast.ast-node-pool-context-expr-push
        (owned_view.compiler-owned-shared-view a)
        (ast.AstExpr.Spanned a-literal (ast.ast-source-span 1 1 1 2)))]
    [a-macro : i64
      (ast.ast-node-pool-context-expr-push
        (owned_view.compiler-owned-shared-view a)
        (ast.AstExpr.MacroExpansion a-spanned 101 201))]
    [b-literal : i64
      (ast.ast-node-pool-context-expr-push
        (owned_view.compiler-owned-shared-view b)
        (ast.AstExpr.Literal (ast.ast-lit-int 91)))]
    [b-spanned : i64
      (ast.ast-node-pool-context-expr-push
        (owned_view.compiler-owned-shared-view b)
        (ast.AstExpr.Spanned b-literal (ast.ast-source-span 2 1 2 2)))]
    [b-macro : i64
      (ast.ast-node-pool-context-expr-push
        (owned_view.compiler-owned-shared-view b)
        (ast.AstExpr.MacroExpansion b-spanned 102 202))]
    [a-bases : i64 (ast.ast-node-pool-context-expr-segment-bases (& a))]
    [b-bases : i64 (ast.ast-node-pool-context-expr-segment-bases (& b))]
    [initial-ok : bool
      (and
        (= a-literal b-literal)
        (= a-spanned b-spanned)
        (= a-macro b-macro)
        (not (= a-bases b-bases))
        (= (ast.ast-expr-semantic-node-from-bases a-bases 3 a-macro) a-literal)
        (= (ast.ast-expr-semantic-node-from-bases b-bases 3 b-macro) b-literal)
        (compiler-ast-expr-int-lit-value?
          (ast.ast-expr-unspan-with-segment-bases
            a-bases
            (ast.ast-node-pool-context-expr-get (& a) a-macro))
          11)
        (compiler-ast-expr-int-lit-value?
          (ast.ast-expr-unspan-with-segment-bases
            b-bases
            (ast.ast-node-pool-context-expr-get (& b) b-macro))
          91))]
    [_rewrite-inner : unit
      (ast.ast-node-pool-context-expr-set!
        (owned_view.compiler-owned-shared-view a)
        a-literal
        (ast.AstExpr.Literal (ast.ast-lit-int 12)))]
    [rewrite-ok : bool
      (compiler-ast-expr-int-lit-value?
        (ast.ast-expr-unspan-with-segment-bases
          (ast.ast-node-pool-context-expr-segment-bases (& a))
          (ast.ast-node-pool-context-expr-get (& a) a-macro))
        12)]
    [mark : i64 (ast.ast-node-pool-context-expr-len a)]
    [retired-literal : i64
      (ast.ast-node-pool-context-expr-push
        (owned_view.compiler-owned-shared-view a)
        (ast.AstExpr.Literal (ast.ast-lit-int 13)))]
    [retired-wrapper : i64
      (ast.ast-node-pool-context-expr-push
        (owned_view.compiler-owned-shared-view a)
        (ast.AstExpr.Spanned retired-literal (ast.ast-source-span 3 1 3 2)))]
    [retired-ok : bool
      (compiler-ast-expr-int-lit-value?
        (ast.ast-expr-unspan-with-segment-bases
          (ast.ast-node-pool-context-expr-segment-bases (& a))
          (ast.ast-node-pool-context-expr-get (& a) retired-wrapper))
        13)]
    [_truncate : unit
      (ast.ast-node-pool-context-expr-truncate!
        (owned_view.compiler-owned-shared-view a)
        mark)]
    [replacement-literal : i64
      (ast.ast-node-pool-context-expr-push
        (owned_view.compiler-owned-shared-view a)
        (ast.AstExpr.Literal (ast.ast-lit-int 14)))]
    [replacement-wrapper : i64
      (ast.ast-node-pool-context-expr-push
        (owned_view.compiler-owned-shared-view a)
        (ast.AstExpr.MacroExpansion replacement-literal 103 203))]
    [reset-ok : bool
      (and
        (= replacement-literal retired-literal)
        (= replacement-wrapper retired-wrapper)
        (=
          (ast.ast-expr-semantic-node-from-bases
            (ast.ast-node-pool-context-expr-segment-bases (& a))
            (ast.ast-node-pool-context-expr-len a)
            replacement-wrapper)
          replacement-literal)
        (compiler-ast-expr-int-lit-value?
          (ast.ast-expr-unspan-with-segment-bases
            (ast.ast-node-pool-context-expr-segment-bases (& a))
            (ast.ast-node-pool-context-expr-get (& a) replacement-wrapper))
          14)
        ;; The unrelated context must retain its own generation and rows.
        (compiler-ast-expr-int-lit-value?
          (ast.ast-expr-unspan-with-segment-bases
            (ast.ast-node-pool-context-expr-segment-bases (& b))
            (ast.ast-node-pool-context-expr-get (& b) b-macro))
          91))]
    (begin
      (ast.ast-node-pool-context-destroy-storage! a)
      (ast.ast-node-pool-context-destroy-storage! b)
      (and initial-ok rewrite-ok retired-ok reset-ok))))

(define (compiler-ast-context-base-arenas-match?
  [pools : (& pools ast.AstNodePoolContext)]) : bool
  (let
    [expr-pool : ast.AstExprNodePoolState (clone (array-ref pools.expr-pool 0))]
    [type-pool : ast.AstTypeNodePoolState (clone (array-ref pools.type-pool 0))]
    (= expr-pool.base-arena type-pool.base-arena)))

(define (compiler-ast-context-clone-types-only-smoke?) : bool
  (let
    [source : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 1 1)]
    [expr-id : i64
      (ast.ast-node-pool-context-expr-push
        (owned_view.compiler-owned-shared-view source)
        (ast.AstExpr.Literal (ast.ast-lit-int 17)))]
    [i64-id : i64
      (ast.ast-node-pool-context-type-push
        (owned_view.compiler-owned-shared-view source)
        (ast.AstType.I64))]
    [ptr-id : i64
      (ast.ast-node-pool-context-type-push
        (owned_view.compiler-owned-shared-view source)
        (ast.AstType.Ptr i64-id))]
    [ptr-dupe-id : i64
      (ast.ast-node-pool-context-type-push
        (owned_view.compiler-owned-shared-view source)
        (ast.AstType.Ptr i64-id))]
    [cloned : ast.AstNodePoolContext
      (ast.ast-node-pool-context-clone-types-only
        (owned_view.compiler-owned-shared-view source))]
    [cloned-ptr-id : i64
      (ast.ast-node-pool-context-type-push
        (owned_view.compiler-owned-shared-view cloned)
        (ast.AstType.Ptr i64-id))]
    (and
      (= expr-id 0)
      (= i64-id 0)
      (= ptr-id 1)
      (= ptr-dupe-id ptr-id)
      (= cloned-ptr-id ptr-id)
      (= (ast.ast-node-pool-context-expr-len cloned) 0)
      (= (ast.ast-node-pool-context-type-len cloned) 2)
      (compiler-ast-context-type-i64? cloned i64-id)
      (match (ast.ast-node-pool-context-type-get cloned ptr-id)
        [(ast.AstType.Ptr inner) (= inner i64-id)]
        [_ false]))))

(define (compiler-ast-active-context-sync-smoke?) : bool
  (let
    [active-before : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 1 1)]
    [ok : bool true]
    (begin
      (ast.ast-node-pool-context-install!
        (owned_view.compiler-owned-shared-view pools))
      (let
        [expr-a : i64
          (ast.ast-node-push (ast.AstExpr.Literal (ast.ast-lit-int 31)))]
        [expr-b : i64
          (ast.ast-node-push (ast.AstExpr.Literal (ast.ast-lit-int 32)))]
        [type-a : i64 (ast.ty-node-push (ast.AstType.I64))]
        [type-b : i64 (ast.ty-node-push (ast.AstType.Char))]
        ;; Var hashes differ by their name ids, so this 131,072 delta collides
        ;; in the initial power-of-two table after the odd slot multiplier.
        [type-collision-a : i64 (ast.ty-node-push (ast.AstType.Var 0))]
        [type-collision-b : i64 (ast.ty-node-push (ast.AstType.Var 131072))]
        [type-collision-a-again : i64 (ast.ty-node-push (ast.AstType.Var 0))]
        (begin
          (unless (= expr-a 0) (set! ok false))
          (unless (= expr-b 1) (set! ok false))
          (unless (= type-a 0) (set! ok false))
          (unless (= type-b 1) (set! ok false))
          (unless (= type-collision-a 2) (set! ok false))
          (unless (= type-collision-b 3) (set! ok false))
          (unless (= type-collision-a-again type-collision-a) (set! ok false))
          ;; Force replacement of the installed context's dedup table. The hot
          ;; raw backing pointer must follow the new descriptor and continue to
          ;; return the existing ids rather than appending duplicates.
          (ast.ty-node-dedup-grow!)
          (unless
            (= (ast.ty-node-push (ast.AstType.I64)) type-a)
            (set! ok false))
          (unless
            (= (ast.ty-node-push (ast.AstType.Char)) type-b)
            (set! ok false))
          (unless
            (= (ast.ty-node-push (ast.AstType.Var 0)) type-collision-a)
            (set! ok false))
          (unless
            (= (ast.ty-node-push (ast.AstType.Var 131072)) type-collision-b)
            (set! ok false))
          (unless
            (= (ast.ast-node-pool-context-expr-len pools) 2)
            (set! ok false))
          (unless
            (= (ast.ast-node-pool-context-type-len pools) 4)
            (set! ok false))
          (unless
            (compiler-ast-context-expr-int-lit? pools expr-a 31)
            (set! ok false))
          (unless
            (compiler-ast-context-expr-int-lit? pools expr-b 32)
            (set! ok false))
          (unless (compiler-ast-context-type-i64? pools type-a) (set! ok false))
          (unless
            (compiler-ast-context-type-char? pools type-b)
            (set! ok false))
          (unless
            (compiler-ast-context-base-arenas-match? pools)
            (set! ok false))
          (ast.ast-node-pool-truncate! 1)
          (ast.ty-node-pool-truncate! 1)
          (unless
            (= (ast.ast-node-pool-context-expr-len pools) 1)
            (set! ok false))
          (unless
            (= (ast.ast-node-pool-context-type-len pools) 1)
            (set! ok false))
          (unless
            (compiler-ast-context-expr-int-lit? pools expr-a 31)
            (set! ok false))
          (unless (compiler-ast-context-type-i64? pools type-a) (set! ok false))
          (ast.ast-node-pool-context-install! active-before)
          ok)))))

(define (compiler-ast-context-owner-identity-smoke?) : bool
  (let
    [active-before : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 1 1)]
    [owner : i64 (ast.ast-node-pool-context-owner-arena pools)]
    [base : i64 (ast.ast-node-pool-context-base-arena pools)]
    [copied : ast.AstNodePoolContext (ast.ast-node-pool-context-snapshot pools)]
    (begin
      ;; Context snapshots keep the pool's stable root identity. Physical arena
      ;; growth does not require publishing a replacement head into either cell.
      (ast.ast-node-pool-context-install!
        (ast.ast-node-pool-context-shared-view (& copied)))
      (let
        [ok : bool
          (and
            (= owner base)
            (=
              (ast.ast-node-pool-context-owner-arena
                (ast.ast-node-pool-context-shared-view (& copied)))
              owner)
            (= (ast.ast-node-pool-owner-arena-handle) owner)
            (=
              (ast.ast-node-pool-context-base-arena
                (ast.ast-node-pool-context-shared-view (& copied)))
              base)
            (= (ast.ast-node-pool-base-arena-handle) base))]
        (begin
          (ast.ast-node-pool-context-install! active-before)
          ok)))))

(define (compiler-ast-context-shared-binary?
  [pools : (& pools ast.AstNodePoolContext)]
  [id : i64]
  [old-lit : i64]
  [old-span : i64]) : bool
  (match (ast.ast-node-pool-context-expr-get pools id)
    [(ast.AstExpr.Binary _ left right)
      (if (= left right)
        (match (ast.ast-node-pool-context-expr-get pools left)
          [(ast.AstExpr.Spanned inner span)
            (and
              (not (= left old-span))
              (not (= inner old-lit))
              (= (ast.ast-source-span-start-line span) 1)
              (= (ast.ast-source-span-start-col span) 2)
              (= (ast.ast-source-span-end-line span) 3)
              (= (ast.ast-source-span-end-col span) 4)
              (match (ast.ast-node-pool-context-expr-view-span pools left)
                [(ast.AstMaybeSourceSpan.Some sidecar-span)
                  (ast.ast-source-span-eq? span sidecar-span)]
                [_ false])
              (match (ast.ast-node-pool-context-expr-span-oracle pools left)
                [(ast.AstExprSpanOracleResult.CanonicalMatch) true]
                [_ false])
              (compiler-ast-context-expr-int-lit? pools inner 7))]
          [_ false])
        false)]
    [_ false]))

(define (compiler-ast-global-shared-binary? [id : i64] [ptr-ty-id : i64]) : bool
  (and
    (match (ast.ast-node-get id)
      [(ast.AstExpr.Binary _ left right)
        (if (= left right)
          (match (ast.ast-node-get left)
            [(ast.AstExpr.Spanned inner _)
              (match (ast.ast-node-get inner)
                [(ast.AstExpr.Literal lit)
                  (match lit
                    [(ast.AstLiteral.Int value _) (= value 7)]
                    [_ false])]
                [_ false])]
            [_ false])
          false)]
      [_ false])
    (match (ast.ty-node-get ptr-ty-id)
      [(ast.AstType.Ptr inner)
        (match (ast.ty-node-get inner)
          [(ast.AstType.I64) true]
          [_ false])]
      [_ false])))

(define (compiler-ast-compaction-program-shape-ok?
  [pools : (& pools ast.AstNodePoolContext)]
  [program : ast.AstProgram]
  [source-body : i64]
  [source-lit : i64]
  [source-span : i64]
  [source-make : i64]) : bool
  (match program
    [(ast.AstProgram.Program decls-box)
      (match (ast.ast-decl-list-step
        (ast.ast-decl-list-box-shared-view decls-box))
        [(ast.AstDeclListStep.Cons first rest-box)
          (match first
            [(ast.AstDecl.Def _ _ maybe-ty first-body)
              (match (ast.ast-decl-list-step rest-box)
                [(ast.AstDeclListStep.Cons second tail-box)
                  (match second
                    [(ast.AstDecl.Test _ second-body metadata _)
                      (and
                        (= first-body second-body)
                        (not (= first-body source-body))
                        (ast.ast-test-metadata-slow?
                          (owned_view.compiler-owned-shared-view metadata))
                        (match (ast.ast-test-metadata-ignore-reason metadata)
                          [(ast.AstTestIgnoreReason.Some reason)
                            (string.eq reason "compaction reason")]
                          [_ false])
                        (= (ast.ast-node-pool-context-expr-len pools) 4)
                        (= (ast.ast-node-pool-context-type-len pools) 2)
                        (compiler-ast-context-shared-binary?
                          pools
                          first-body
                          source-lit
                          source-span)
                        (match maybe-ty
                          [(ast.AstMaybeType.Some ty)
                            (match ty
                              [(ast.AstType.Array ptr-id count)
                                (and
                                  (= count 4)
                                  (match (ast.ast-node-pool-context-type-get
                                    pools
                                    ptr-id)
                                    [(ast.AstType.Ptr inner)
                                      (match (ast.ast-node-pool-context-type-get
                                        pools
                                        inner)
                                        [(ast.AstType.I64) true]
                                        [_ false])]
                                    [_ false]))]
                              [_ false])]
                          [_ false])
                        (match (ast.ast-decl-list-step tail-box)
                          [(ast.AstDeclListStep.Cons third final-box)
                            (match third
                              [(ast.AstDecl.Def _ _ _ make-body)
                                (and
                                  (not (= make-body source-make))
                                  (match (ast.ast-node-pool-context-expr-get
                                    pools
                                    make-body)
                                    [(ast.AstExpr.FixedMakeArray _ size-body)
                                      (= size-body first-body)]
                                    [_ false])
                                  (match (ast.ast-decl-list-step final-box)
                                    [(ast.AstDeclListStep.Nil) true]
                                    [_ false]))]
                              [_ false])]
                          [_ false]))]
                    [_ false])]
                [_ false])]
            [_ false])]
        [_ false])]))

(define (compiler-ast-program-compaction-smoke?) : bool
  (let
    [source-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new
        (ast.ast-expr-node-pool-state-create 8)
        (ast.ast-type-node-pool-state-create 8)
        ;; Smoke-local scratch pool: never installed, caller-arena owned.
        (arena.tl_arena_current))]
    [dest-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new
        (ast.ast-expr-node-pool-state-create 8)
        (ast.ast-type-node-pool-state-create 8)
        ;; Smoke-local scratch pool: never installed, caller-arena owned.
        (arena.tl_arena_current))]
    [active-before : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
    [source-decoy-expr : i64
      (ast.ast-node-pool-context-expr-push
        (owned_view.compiler-owned-shared-view source-pools)
        (ast.AstExpr.Literal (ast.ast-lit-int 999)))]
    [source-decoy-ty : i64
      (ast.ast-node-pool-context-type-push
        (owned_view.compiler-owned-shared-view source-pools)
        (ast.AstType.Char))]
    [source-i64-ty : i64
      (ast.ast-node-pool-context-type-push
        (owned_view.compiler-owned-shared-view source-pools)
        (ast.AstType.I64))]
    [source-ptr-ty : i64
      (ast.ast-node-pool-context-type-push
        (owned_view.compiler-owned-shared-view source-pools)
        (ast.AstType.Ptr source-i64-ty))]
    [array-ty : ast.AstType (ast.AstType.Array source-ptr-ty 4)]
    [source-lit : i64
      (ast.ast-node-pool-context-expr-push
        (owned_view.compiler-owned-shared-view source-pools)
        (ast.AstExpr.Literal (ast.ast-lit-int 7)))]
    [source-span : i64
      (ast.ast-node-pool-context-expr-push
        (owned_view.compiler-owned-shared-view source-pools)
        (ast.AstExpr.Spanned source-lit (ast.ast-source-span 1 2 3 4)))]
    [source-body : i64
      (ast.ast-node-pool-context-expr-push
        (owned_view.compiler-owned-shared-view source-pools)
        (ast.AstExpr.Binary (ast.AstBinOp.Add) source-span source-span))]
    [source-make : i64
      (ast.ast-node-pool-context-expr-push
        (owned_view.compiler-owned-shared-view source-pools)
        (ast.AstExpr.FixedMakeArray
          (ast.ast-node-pool-context-type-push
            (owned_view.compiler-owned-shared-view source-pools)
            (ast.AstType.Ptr source-i64-ty))
          source-body))]
    [value-name-id : i64 (ci.intern-generated-name "value")]
    [same-name-id : i64 (ci.intern-generated-name "same")]
    [array-name-id : i64 (ci.intern-generated-name "array")]
    [program : ast.AstProgram
      (ast.ast-program
        (ast.ast-decl-cons
          (ast.ast-decl-def-id
            value-name-id
            (ast.AstMaybeType.Some array-ty)
            source-body)
          (ast.ast-decl-cons
            (ast.ast-decl-test-metadata-id
              same-name-id
              source-body
              (ast.ast-test-metadata-new
                (ast.AstTestIgnoreReason.Some "compaction reason")
                true)
              (ast.ast-source-span 5 6 7 8))
            (ast.ast-decl-cons
              (ast.ast-decl-def-id
                array-name-id
                ast.AstMaybeType.No
                source-make)
              (ast.ast-decl-list-new)))))]
    [dest-decoy-expr : i64
      (ast.ast-node-pool-context-expr-push
        (owned_view.compiler-owned-shared-view dest-pools)
        (ast.AstExpr.Literal (ast.ast-lit-int 1234)))]
    [dest-decoy-ty : i64
      (ast.ast-node-pool-context-type-push
        (owned_view.compiler-owned-shared-view dest-pools)
        (ast.AstType.Bool))]
    [compacted : ast.AstProgramCompaction
      (ast.ast-program-compact-with-pools source-pools dest-pools program)]
    (match compacted
      [(ast.AstProgramCompaction out-program out-pools)
        (let
          [shape-ok : bool
            (and
              (= source-decoy-expr 0)
              (= source-decoy-ty 0)
              (= dest-decoy-expr 0)
              (= dest-decoy-ty 0)
              (compiler-ast-compaction-program-shape-ok?
                out-pools
                (owned_view.compiler-owned-shared-view out-program)
                source-body
                source-lit
                source-span
                source-make))]
          [installed-ok : bool
            (match out-program
              [(ast.AstProgram.Program decls-box)
                (match (ast.ast-decl-list-step
                  (ast.ast-decl-list-box-shared-view decls-box))
                  [(ast.AstDeclListStep.Cons first _)
                    (match first
                      [(ast.AstDecl.Def _ _ maybe-ty body)
                        (match maybe-ty
                          [(ast.AstMaybeType.Some ty)
                            (match ty
                              [(ast.AstType.Array ptr-id _)
                                (begin
                                  (ast.ast-node-pool-context-install! out-pools)
                                  (compiler-ast-global-shared-binary?
                                    body
                                    ptr-id))]
                              [_ false])]
                          [_ false])]
                      [_ false])]
                  [_ false])])]
          (begin
            (ast.ast-node-pool-context-install! active-before)
            (and shape-ok installed-ok)))])))

(define (compiler-ast-macro-type-kind-dense-compaction-smoke?) : bool
  (let
    [source : ast.AstMacroTypeKindList
      (ast.ast-macro-type-kind-list-with-length 3)]
    (begin
      (ast.ast-macro-type-kind-list-set! (&mut source) 0 11)
      (ast.ast-macro-type-kind-list-set! (&mut source) 1 22)
      (ast.ast-macro-type-kind-list-set! (&mut source) 2 33)
      (let
        [copied : ast.AstMacroTypeKindList
          (ast.ast-compaction-copy-macro-type-kind-list (& source))]
        (begin
          ;; Compaction owns an independent dense allocation, so mutating the
          ;; source after the copy must not alter its ordered constraints.
          (ast.ast-macro-type-kind-list-set! (&mut source) 0 99)
          (and
            (= (ast.ast-macro-type-kind-list-len (& copied)) 3)
            (= (ast.ast-macro-type-kind-list-get (& copied) 0 0) 11)
            (= (ast.ast-macro-type-kind-list-get (& copied) 1 0) 22)
            (= (ast.ast-macro-type-kind-list-get (& copied) 2 0) 33)
            (not (ast.ast-macro-type-kind-list-eq? (& source) (& copied)))))))))

(define (compiler-ast-program-copy-append-smoke?) : bool
  (let
    [source-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 4 4)]
    [dest-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 4 4)]
    [_dest-expr : i64
      (ast.ast-node-pool-context-expr-push
        (owned_view.compiler-owned-shared-view dest-pools)
        (ast.AstExpr.Literal (ast.ast-lit-int 111)))]
    [_dest-type : i64
      (ast.ast-node-pool-context-type-push
        (owned_view.compiler-owned-shared-view dest-pools)
        (ast.AstType.Bool))]
    [_source-decoy : i64
      (ast.ast-node-pool-context-expr-push
        (owned_view.compiler-owned-shared-view source-pools)
        (ast.AstExpr.Literal (ast.ast-lit-int 999)))]
    [source-expr : i64
      (ast.ast-node-pool-context-expr-push
        (owned_view.compiler-owned-shared-view source-pools)
        (ast.AstExpr.Literal (ast.ast-lit-int 222)))]
    [source-type : i64
      (ast.ast-node-pool-context-type-push
        (owned_view.compiler-owned-shared-view source-pools)
        (ast.AstType.I64))]
    [appended-name-id : i64 (ci.intern-generated-name "appended")]
    [program : ast.AstProgram
      (ast.ast-program
        (ast.ast-decl-cons
          (ast.ast-decl-def-id
            appended-name-id
            (ast.AstMaybeType.Some (ast.AstType.Ptr source-type))
            source-expr)
          (ast.ast-decl-list-new)))]
    [copied : ast.AstProgramCompaction
      (ast.ast-program-copy-append-with-pools source-pools dest-pools program)]
    (match copied
      [(ast.AstProgramCompaction out-program out-pools)
        (and
          (= (ast.ast-node-pool-context-expr-len out-pools) 2)
          (= (ast.ast-node-pool-context-type-len out-pools) 2)
          (compiler-ast-context-expr-int-lit? out-pools 0 111)
          (match out-program
            [(ast.AstProgram.Program decls-box)
              (match (ast.ast-decl-list-step
                (ast.ast-decl-list-box-shared-view decls-box))
                [(ast.AstDeclListStep.Cons decl rest)
                  (match decl
                    [(ast.AstDecl.Def _ _ maybe-type body)
                      (and
                        (compiler-ast-context-expr-int-lit? out-pools body 222)
                        (match maybe-type
                          [(ast.AstMaybeType.Some (ast.AstType.Ptr inner))
                            (compiler-ast-context-type-i64? out-pools inner)]
                          [_ false])
                        (match (ast.ast-decl-list-step rest)
                          [(ast.AstDeclListStep.Nil) true]
                          [_ false]))]
                    [_ false])]
                [_ false])]))])))

(define (compiler-ast-compaction-borrow-child-smoke?) : bool
  (let
    [source-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 4 1)]
    [dest-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 4 1)]
    [name : i64 (ci.intern-generated-name "borrow-child")]
    [var-id : i64
      (ast.ast-node-pool-context-expr-push
        (owned_view.compiler-owned-shared-view source-pools)
        (ast.AstExpr.Var name))]
    [spanned-id : i64
      (ast.ast-node-pool-context-expr-push
        (owned_view.compiler-owned-shared-view source-pools)
        (ast.AstExpr.Spanned var-id (ast.ast-source-span 1 1 1 2)))]
    [borrow-id : i64
      (ast.ast-node-pool-context-expr-push
        (owned_view.compiler-owned-shared-view source-pools)
        (ast.AstExpr.Borrow
          false
          (ast.ast-borrow-lifetime-to-id ast.AstBorrowLifetime.Inferred)
          spanned-id))]
    [program : ast.AstProgram
      (ast.ast-program
        (ast.ast-decl-cons
          (ast.ast-decl-def-id name ast.AstMaybeType.No borrow-id)
          (ast.ast-decl-list-new)))]
    [compacted : ast.AstProgramCompaction
      (ast.ast-program-compact-with-pools source-pools dest-pools program)]
    (match compacted
      [(ast.AstProgramCompaction out-program out-pools)
        (match out-program
          [(ast.AstProgram.Program decls-box)
            (match (ast.ast-decl-list-step
              (ast.ast-decl-list-box-shared-view decls-box))
              [(ast.AstDeclListStep.Cons decl _)
                (match decl
                  [(ast.AstDecl.Def _ _ _ body)
                    (match (ast.ast-node-pool-context-expr-get out-pools body)
                      [(ast.AstExpr.Borrow mutable lifetime-id inner)
                        (and
                          (not mutable)
                          (match (ast.ast-borrow-lifetime-from-id lifetime-id)
                            [(ast.AstBorrowLifetime.Inferred) true]
                            [_ false])
                          (match (ast.ast-node-pool-context-expr-get
                            out-pools
                            inner)
                            [(ast.AstExpr.Spanned var _)
                              (match (ast.ast-node-pool-context-expr-get
                                out-pools
                                var)
                                [(ast.AstExpr.Var got-name) (= got-name name)]
                                [_ false])]
                            [_ false]))]
                      [_ false])]
                  [_ false])]
              [_ false])])])))

(define (compiler-ast-compaction-string-def-ok?
  [pools : (& pools ast.AstNodePoolContext)]
  [decl : ast.AstDecl]) : bool
  (match decl
    [(ast.AstDecl.Def _ _ maybe-ty value)
      (and
        (match maybe-ty
          [(ast.AstMaybeType.Some ty)
            (match ty
              [(ast.AstType.Ref region inner)
                (and
                  (= region cbi.compiler-builtin-id-fix-value)
                  (match (ast.ast-node-pool-context-type-get pools inner)
                    [(ast.AstType.I64) true]
                    [_ false]))]
              [_ false])]
          [_ false])
        (match (ast.ast-node-pool-context-expr-get pools value)
          [(ast.AstExpr.Literal (ast.AstLiteral.String string-id))
            (string.eq (ast.ast-lit-string-text string-id) "hello")]
          [_ false]))]
    [_ false]))

(define (compiler-ast-compaction-binary-def-ok?
  [pools : (& pools ast.AstNodePoolContext)]
  [decl : ast.AstDecl]) : bool
  (match decl
    [(ast.AstDecl.Def _ _ ast.AstMaybeType.No value)
      (match (ast.ast-node-pool-context-expr-get pools value)
        [(ast.AstExpr.BinaryData text) (string.eq text "bytes")]
        [_ false])]
    [_ false]))

(define (compiler-ast-compaction-import-ok? [decl : ast.AstDecl]) : bool
  (match decl
    [(ast.AstDecl.Import
        _
        (ast.AstImportSpec.Spec
          (ast.AstImportKind.Module)
          path
          module-name
          alias
          _))
      (and
        (string.eq path "pkg.module")
        (match module-name
          [(ast.AstMaybeModuleName.Some name)
            (string.eq (ci.intern-str name) "pkg.module")]
          [_ false])
        (match alias
          [(ast.AstMaybeImportAlias.Some name)
            (string.eq (ci.intern-str name) "pkg")]
          [_ false]))]
    [_ false]))

(define (compiler-ast-compaction-macro-call-ok?
  [pools : (& pools ast.AstNodePoolContext)]
  [call : i64]) : bool
  (match (ast.ast-node-pool-context-expr-get pools call)
    [(ast.AstExpr.Call func args)
      (and
        (match (ast.ast-node-pool-context-expr-get pools func)
          [(ast.AstExpr.Var _) true]
          [_ false])
        (= (ast.ast-expr-list-len (& args)) 1))]
    [_ false]))

(define (compiler-ast-compaction-macro-import-ok?
  [pools : (& pools ast.AstNodePoolContext)]
  [decl : ast.AstDecl]
  [decls-kind? : bool]) : bool
  (match decl
    [(ast.AstDecl.Import _ (ast.AstImportSpec.Spec kind _ _ _ _))
      (match kind
        [(ast.AstImportKind.Macro call _)
          (and
            (not decls-kind?)
            (compiler-ast-compaction-macro-call-ok? pools call))]
        [(ast.AstImportKind.MacroDecls call _)
          (and decls-kind? (compiler-ast-compaction-macro-call-ok? pools call))]
        [_ false])]
    [_ false]))

(define (compiler-ast-compaction-extern-ok? [decl : ast.AstDecl]) : bool
  (match decl
    [(ast.AstDecl.Extern _ _ _ metadata _)
      (match (__tl-box-place metadata)
        [(ast.AstExternMetadata.Metadata
            (ast.AstExternAbi.C)
            symbol
            links
            flags
            _)
          (and
            (ast.ast-extern-metadata-flags-explicit-abi? flags)
            (not (ast.ast-extern-metadata-flags-symbol-matches-source? flags))
            (string.eq (ci.intern-id-str symbol) "native_symbol")
            (match (ast.ast-extern-link-input-list-get
              (& links)
              0
              (ast.ast-extern-link-input-fallback))
              [(ast.AstExternLinkInput.Lib name) (string.eq name "m")]
              [_ false]))]
        [_ false])]
    [_ false]))

(define (compiler-ast-compaction-dispatch-ok? [decl : ast.AstDecl]) : bool
  (match decl
    [(ast.AstDecl.DefDispatch _ _ variants)
      (match (ast.ast-dispatch-variant-list-get
        (& variants)
        0
        (ast.ast-dispatch-variant-fallback))
        [(ast.AstDispatchVariant.Variant (ast.AstDispatchIsa.Avx2) name)
          (string.eq (ci.intern-str name) "fast")]
        [_ false])]
    [_ false]))

(define (compiler-ast-compaction-lifetimes-ok? [decl : ast.AstDecl]) : bool
  (match decl
    [(ast.AstDecl.DefStructLifetimes _ _ lifetimes _ _ _)
      (=
        (ast.ast-lifetime-list-get (& lifetimes) 0 (ast.ast-lifetime-fallback))
        cbi.compiler-builtin-id-fix-n)]
    [_ false]))

(define (compiler-ast-compaction-include-ok? [decl : ast.AstDecl]) : bool
  (match decl
    [(ast.AstDecl.IncludeStr name path)
      (and (string.eq (ci.intern-str name) "inc") (string.eq path "data.txt"))]
    [_ false]))

(define (compiler-ast-program-compaction-string-payloads-smoke?) : bool
  (let
    [include-name-id : i64 (ci.intern-generated-name "inc")]
    [macro-func-name-id : i64 (ci.intern-generated-name "emit")]
    [source-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new
        (ast.ast-expr-node-pool-state-create 8)
        (ast.ast-type-node-pool-state-create 8)
        ;; Smoke-local scratch pool: never installed, caller-arena owned.
        (arena.tl_arena_current))]
    [dest-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new
        (ast.ast-expr-node-pool-state-create 8)
        (ast.ast-type-node-pool-state-create 8)
        ;; Smoke-local scratch pool: never installed, caller-arena owned.
        (arena.tl_arena_current))]
    [source-i64-ty : i64
      (ast.ast-node-pool-context-type-push
        (owned_view.compiler-owned-shared-view source-pools)
        (ast.AstType.I64))]
    [_source-decoy : i64
      (ast.ast-node-pool-context-expr-push
        (owned_view.compiler-owned-shared-view source-pools)
        (ast.AstExpr.Literal (ast.ast-lit-int 999)))]
    [text-expr : i64
      (ast.ast-node-pool-context-expr-push
        (owned_view.compiler-owned-shared-view source-pools)
        (ast.AstExpr.Literal (ast.ast-lit-generated-string "hello")))]
    [binary-expr : i64
      (ast.ast-node-pool-context-expr-push
        (owned_view.compiler-owned-shared-view source-pools)
        (ast.AstExpr.BinaryData "bytes"))]
    [macro-func : i64
      (ast.ast-node-pool-context-expr-push
        (owned_view.compiler-owned-shared-view source-pools)
        (ast.AstExpr.Var macro-func-name-id))]
    [macro-call : i64
      (ast.ast-node-pool-context-expr-push
        (owned_view.compiler-owned-shared-view source-pools)
        (ast.AstExpr.Call
          macro-func
          (ast.ast-expr-cons text-expr (ast.ast-expr-list-new))))]
    [links : ast.AstExternLinkInputList
      (let
        [items : ast.AstExternLinkInputList
          (ast.ast-extern-link-input-list-new)]
        (begin
          (ast.ast-extern-link-input-list-push
            (&mut items)
            (ast.AstExternLinkInput.Lib "m"))
          items))]
    [variants : ast.AstDispatchVariantList
      (let
        [items : ast.AstDispatchVariantList (ast.ast-dispatch-variant-list-new)]
        (begin
          (ast.ast-dispatch-variant-list-push
            (&mut items)
            (ast.AstDispatchVariant.Variant
              (ast.AstDispatchIsa.Avx2)
              (ci.intern-generated-name "fast")))
          items))]
    [lifetimes : ast.AstLifetimeList
      (let
        [items : ast.AstLifetimeList (ast.ast-lifetime-list-new)]
        (begin
          (ast.ast-lifetime-list-push
            (&mut items)
            cbi.compiler-builtin-id-fix-n)
          items))]
    [text-name-id : i64 (ci.intern-generated-name "text")]
    [bin-name-id : i64 (ci.intern-generated-name "bin")]
    [native-name-id : i64 (ci.intern-generated-name "native")]
    [dispatch-name-id : i64 (ci.intern-generated-name "dispatch")]
    [program : ast.AstProgram
      (ast.ast-program
        (ast.ast-decl-cons
          (ast.ast-decl-def-id
            text-name-id
            (ast.AstMaybeType.Some
              (ast.AstType.Ref cbi.compiler-builtin-id-fix-value source-i64-ty))
            text-expr)
          (ast.ast-decl-cons
            (ast.ast-decl-def-id bin-name-id ast.AstMaybeType.No binary-expr)
            (ast.ast-decl-cons
              (ast.AstDecl.Import
                (ast.ast-decl-meta-runtime-shared-view)
                (ast.AstImportSpec.Spec
                  (ast.AstImportKind.Module)
                  "pkg.module"
                  (ast.AstMaybeModuleName.Some
                    (ci.intern-generated-name "pkg.module"))
                  (ast.AstMaybeImportAlias.Some
                    (ci.intern-generated-name "pkg"))
                  (box (ast.ast-source-span 1 1 1 1))))
              (ast.ast-decl-cons
                (ast.ast-decl-extern-id
                  native-name-id
                  (ast.AstExternKind.Function)
                  (ast.AstExternMetadata.Metadata
                    (ast.AstExternAbi.C)
                    (ci.intern-id-from-renderable
                      (ci.intern-generated-name "native_symbol"))
                    links
                    (ast.ast-extern-metadata-flags true false)
                    ast.AstImportedSpmdMetadata.No)
                  (ast.AstType.I64))
                (ast.ast-decl-cons
                  (ast.AstDecl.Import
                    (ast.ast-decl-meta-runtime-shared-view)
                    (ast.AstImportSpec.Spec
                      (ast.AstImportKind.Macro
                        macro-call
                        ast.AstMaybeModuleName.No)
                      ""
                      ast.AstMaybeModuleName.No
                      ast.AstMaybeImportAlias.No
                      (box (ast.ast-source-span 2 1 2 1))))
                  (ast.ast-decl-cons
                    (ast.AstDecl.Import
                      (ast.ast-decl-meta-runtime-shared-view)
                      (ast.AstImportSpec.Spec
                        (ast.AstImportKind.MacroDecls
                          macro-call
                          ast.AstMaybeModuleName.No)
                        ""
                        ast.AstMaybeModuleName.No
                        ast.AstMaybeImportAlias.No
                        (box (ast.ast-source-span 3 1 3 1))))
                    (ast.ast-decl-cons
                      (ast.ast-decl-def-dispatch-id dispatch-name-id variants)
                      (ast.ast-decl-cons
                        (ast.AstDecl.DefStructLifetimes
                          (ast.ast-decl-meta-runtime-shared-view)
                          0
                          lifetimes
                          (ast.AstStructRepr.Default)
                          (ast.AstStructCleanup.No)
                          (ast.ast-field-def-list-new))
                        (ast.ast-decl-cons
                          (ast.AstDecl.IncludeStr include-name-id "data.txt")
                          (ast.ast-decl-list-new)))))))))))]
    [compacted : ast.AstProgramCompaction
      (ast.ast-program-compact-with-pools source-pools dest-pools program)]
    (match compacted
      [(ast.AstProgramCompaction out-program out-pools)
        (match out-program
          [(ast.AstProgram.Program decls-box)
            (let
              [decls : ast.AstDeclList
                (ast.ast-decl-list-box-shared-view decls-box)]
              (and
                (compiler-ast-compaction-string-def-ok?
                  out-pools
                  (ast.ast-decl-list-get (& decls) 0 (ast.ast-decl-fallback)))
                (compiler-ast-compaction-binary-def-ok?
                  out-pools
                  (ast.ast-decl-list-get (& decls) 1 (ast.ast-decl-fallback)))
                (compiler-ast-compaction-import-ok?
                  (ast.ast-decl-list-get (& decls) 2 (ast.ast-decl-fallback)))
                (compiler-ast-compaction-extern-ok?
                  (ast.ast-decl-list-get (& decls) 3 (ast.ast-decl-fallback)))
                (compiler-ast-compaction-macro-import-ok?
                  out-pools
                  (ast.ast-decl-list-get (& decls) 4 (ast.ast-decl-fallback))
                  false)
                (compiler-ast-compaction-macro-import-ok?
                  out-pools
                  (ast.ast-decl-list-get (& decls) 5 (ast.ast-decl-fallback))
                  true)
                (compiler-ast-compaction-dispatch-ok?
                  (ast.ast-decl-list-get (& decls) 6 (ast.ast-decl-fallback)))
                (compiler-ast-compaction-lifetimes-ok?
                  (ast.ast-decl-list-get (& decls) 7 (ast.ast-decl-fallback)))
                (compiler-ast-compaction-include-ok?
                  (ast.ast-decl-list-get (& decls) 8 (ast.ast-decl-fallback)))))])])))

(define (compiler-ast-decl-list-module-name?
  [decls : (& decls ast.AstDeclList)]
  [index : i64]
  [expected : String]) : bool
  (match (ast.ast-decl-list-get decls index (ast.ast-decl-fallback))
    [(ast.AstDecl.Module name) (string.eq (ci.intern-str name) expected)]
    [_ false]))

(define (compiler-ast-decl-cons-growth-smoke?) : bool
  (let
    [i : i64 15]
    [decls : ast.AstDeclList (ast.ast-decl-list-new)]
    [paths : ast.AstDeclPathList (ast.ast-decl-path-list-new)]
    [modules : ast.AstDeclModuleList (ast.ast-decl-module-list-new)]
    (begin
      (while (>= i 0)
        (let
          [suffix : String (string.int->string i)]
          [module : String
            (str_cat.str-cat "m" (owned_view.compiler-owned-shared-view suffix))]
          [module-id : i64 (ci.intern-generated-name module)]
          [path : String (str_cat.str-cat "p" suffix)]
          (begin
            (set!
              decls
              (ast.ast-decl-cons (ast.ast-decl-module-id module-id) decls))
            (set! paths (ast.ast-decl-root-path-cons path paths))
            (set!
              modules
              (ast.ast-decl-module-list-prepend-builder-id module-id modules))
            (set! i (- i 1)))))
      (let
        [tail : ast.AstDeclList
          (ast.ast-decl-list-tail (owned_view.compiler-owned-shared-view decls))]
        (and
          (= (ast.ast-decl-list-len (& decls)) 16)
          (= (ast.ast-decl-path-list-len (& paths)) 16)
          (= (ast.ast-decl-module-list-len (& modules)) 16)
          (compiler-ast-decl-list-module-name? decls 0 "m0")
          (compiler-ast-decl-list-module-name? decls 7 "m7")
          (compiler-ast-decl-list-module-name? decls 15 "m15")
          (compiler-ast-decl-list-module-name? tail 0 "m1")
          (string.eq (ast.ast-decl-path-list-get (& paths) 0 "") "p0")
          (string.eq (ast.ast-decl-path-list-get (& paths) 15 "") "p15")
          (string.eq (ast.ast-decl-module-list-get (& modules) 0 "") "m0")
          (string.eq (ast.ast-decl-module-list-get (& modules) 15 "") "m15"))))))

(define (compiler-ast-decl-cons-pure-smoke?) : bool
  (let
    [tail-id : i64 (ci.intern-generated-name "tail")]
    [left-id : i64 (ci.intern-generated-name "left")]
    [right-id : i64 (ci.intern-generated-name "right")]
    [tail : ast.AstDeclList
      (ast.ast-decl-cons
        (ast.ast-decl-module-id tail-id)
        (ast.ast-decl-list-new))]
    [left : ast.AstDeclList
      (ast.ast-decl-cons
        (ast.ast-decl-module-id left-id)
        (owned_view.compiler-owned-shared-view tail))]
    [right : ast.AstDeclList
      (ast.ast-decl-cons (ast.ast-decl-module-id right-id) tail)]
    (and
      (compiler-ast-decl-list-module-name? left 0 "left")
      (compiler-ast-decl-list-module-name? left 1 "tail")
      (compiler-ast-decl-list-module-name? right 0 "right")
      (compiler-ast-decl-list-module-name? right 1 "tail"))))

(define (compiler-ast-clause-list-tail-smoke?) : bool
  (let
    [clauses : ast.AstExprClauseList (ast.ast-expr-clause-list-new)]
    [bindings : ast.AstExprBindingClauseList
      (ast.ast-expr-binding-clause-list-new)]
    (begin
      (ast.ast-expr-clause-list-push (&mut clauses) (ast.ast-expr-clause 1 2))
      (ast.ast-expr-clause-list-push (&mut clauses) (ast.ast-expr-clause 3 4))
      (ast.ast-expr-clause-list-push (&mut clauses) (ast.ast-expr-clause 5 6))
      (ast.ast-expr-binding-clause-list-push
        (&mut bindings)
        (ast.ast-expr-binding-clause-id
          (ci.intern-syntax-id-from-raw 10)
          false
          0
          100
          (ast.AstType.Var -3)
          (ast.ast-source-span 1 1 1 2)))
      (ast.ast-expr-binding-clause-list-push
        (&mut bindings)
        (ast.ast-expr-binding-clause-id
          (ci.intern-syntax-id-from-raw 11)
          false
          0
          101
          (ast.AstType.Var -3)
          (ast.ast-source-span 2 1 2 2)))
      (ast.ast-expr-binding-clause-list-push
        (&mut bindings)
        (ast.ast-expr-binding-clause-id
          (ci.intern-syntax-id-from-raw 12)
          false
          0
          102
          (ast.AstType.Var -3)
          (ast.ast-source-span 3 1 3 2)))
      (let
        [clause-tail : ast.AstExprClauseList
          (ast.ast-expr-clause-list-tail clauses)]
        [binding-tail : ast.AstExprBindingClauseList
          (ast.ast-expr-binding-clause-list-tail bindings)]
        [first-clause : ast.AstExprClause
          (ast.ast-expr-clause-list-get
            (& clause-tail)
            0
            (ast.ast-expr-clause-fallback))]
        [first-binding : ast.AstExprBindingClause
          (ast.ast-expr-binding-clause-list-get
            (& binding-tail)
            0
            (ast.ast-expr-binding-clause-fallback))]
        (and
          (= clause-tail.len 2)
          (= first-clause.first 3)
          (= first-clause.second 4)
          (= binding-tail.len 2)
          (ci.intern-syntax-id-eq?
            first-binding.name
            (ci.intern-syntax-id-from-raw 11))
          (= first-binding.init 101))))))

(define (compiler-ast-generated-path-owner-smoke?) : bool
  (let
    [path : String "<generated ast smoke path>"]
    [path-id : i64
      (ci.intern-generated-canonical-name
        (owned_view.compiler-owned-shared-view path))]
    [paths : ast.AstDeclPathList
      (ast.ast-decl-path-list-prepend-builder-with-owner-id
        path
        path-id
        (ast.ast-decl-path-list-new))]
    [with-modules : ast.AstDeclPathList
      (ast.ast-decl-path-list-with-modules paths (ast.ast-decl-module-list-new))]
    (= (ast.ast-decl-path-list-owner-id (& with-modules) 0 -1) path-id)))

;; Rewriters select an owned AST-pool context while the process-global active
;; pool may hold an unrelated compilation. `ast-node-set!` must update that
;; selected context just like `ast-node-get` and `ast-node-push` do.
(define (compiler-ast-compat-context-set-smoke?) : bool
  (let
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 1 1)]
    (begin
      (ast.ast-node-pool-compat-context-use!
        (owned_view.compiler-owned-shared-view pools))
      (let
        [id : i64 (ast.ast-node-push (ast.AstExpr.Literal (ast.ast-lit-int 7)))]
        (begin
          (ast.ast-node-set! id (ast.AstExpr.Literal (ast.ast-lit-int 42)))
          (ast.ast-node-pool-compat-context-clear!)
          (and (= id 0) (compiler-ast-context-expr-int-lit? pools id 42)))))))

;; Creating a retained pool while a source arena is active must not allocate the
;; context's mutable cells in that source arena. The compiler destroys the
;; source immediately after AST compaction, then continues using this context.
(define (compiler-ast-context-owned-arena-smoke?) : bool
  (let
    [home : arena.Arena (arena.current)]
    [source : arena.Arena (arena.make)]
    [dest : arena.Arena (arena.make)]
    [_set-source : unit
      (unsafe
        (arena.set! source))]
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities-in-arena
        4
        4
        (arena.raw-handle dest))]
    [_set-dest : unit
      (unsafe
        (arena.set! dest))]
    [child : i64
      (ast.ast-node-pool-context-expr-push
        (owned_view.compiler-owned-shared-view pools)
        (ast.AstExpr.Literal (ast.ast-lit-int 73)))]
    [body : ast.AstExprList (ast.ast-expr-list-new)]
    [_push-child : unit (ast.ast-expr-list-push (&mut body) child)]
    [unsafe-id : i64
      (ast.ast-node-pool-context-expr-push
        (owned_view.compiler-owned-shared-view pools)
        (ast.AstExpr.Unsafe body))]
    [_restore-home : unit
      (unsafe
        (arena.set! home))]
    [_destroy-source : unit
      (unsafe
        (arena.destroy source))]
    [ok : bool
      (match (ast.ast-node-pool-context-expr-get pools unsafe-id)
        [(ast.AstExpr.Unsafe exprs)
          (let
            [retained-child : i64 (ast.ast-expr-list-get (& exprs) 0 -1)]
            (and
              (= retained-child child)
              (compiler-ast-context-expr-int-lit? pools retained-child 73)))]
        [_ false])]
    (begin
      (ast.ast-node-pool-context-destroy-storage! pools)
      (unsafe
        (arena.destroy dest))
      ok)))

(define (compiler-ast-maybe-span-start-line?
  [value : ast.AstMaybeSourceSpan]
  [line : i64]) : bool
  (match value
    [(ast.AstMaybeSourceSpan.Some span)
      (= (ast.ast-source-span-start-line span) line)]
    [(ast.AstMaybeSourceSpan.No) false]))

;; Shallow pool snapshots share the dense span-slot table but retain their own
;; canonical record generation. A slot from a newer generation must be treated
;; as missing rather than indexing beyond the restored record array.
(define (compiler-ast-stale-canonical-span-slot-recovery-smoke?) : bool
  (match (ast.ast-expr-node-pool-state-push
    (ast.ast-expr-node-pool-state-create 1)
    (ast.AstExpr.Literal (ast.ast-lit-int 17)))
    [(ast.AstExprNodePoolPushOk literal-pool literal)
      (begin
        (ast.ast-expr-span-slot-set-in-bases!
          literal-pool.span-slot-segment-bases
          literal
          65)
        (match (ast.ast-expr-node-pool-state-push
          literal-pool
          (ast.AstExpr.Spanned literal (ast.ast-source-span 7 1 7 3)))
          [(ast.AstExprNodePoolPushOk recovered view)
            (and
              (= view 1)
              (=
                (ast.ast-expr-node-pool-state-canonical-span-count
                  (owned_view.compiler-owned-shared-view recovered))
                1)
              (match (ast.ast-expr-node-pool-state-span-oracle recovered view)
                [(ast.AstExprSpanOracleResult.CanonicalMatch) true]
                [_ false]))]))]))

;; Canonical provenance is first-write/innermost.  A later wrapper with a
;; different source location gets a sparse per-use ReSpan, while an identical
;; wrapper shares the canonical record.  Truncation retires only suffix-owned
;; records and clears reused slots before the next generation writes them.
(define (compiler-ast-expression-span-sidecar-smoke?) : bool
  (let
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 1 1)]
    [literal : i64
      (ast.ast-node-pool-context-expr-push
        (owned_view.compiler-owned-shared-view pools)
        (ast.AstExpr.Literal (ast.ast-lit-int 7)))]
    [inner-span : ast.AstSourceSpan (ast.ast-source-span 2 3 2 8)]
    [outer-span : ast.AstSourceSpan (ast.ast-source-span 9 1 9 6)]
    [inner-view : i64
      (ast.ast-expr-spanned-with-pools pools literal inner-span)]
    [same-view : i64
      (ast.ast-expr-spanned-with-pools pools inner-view inner-span)]
    [outer-view : i64
      (ast.ast-expr-spanned-with-pools pools same-view outer-span)]
    [mark : i64 (ast.ast-node-pool-context-expr-len pools)]
    [later-view : i64
      (ast.ast-expr-spanned-with-pools
        pools
        outer-view
        (ast.ast-source-span 12 1 12 2))]
    [_reset-suffix : unit
      (ast.ast-node-pool-context-expr-truncate!
        (owned_view.compiler-owned-shared-view pools)
        mark)]
    [reused : i64
      (ast.ast-node-pool-context-expr-push
        (owned_view.compiler-owned-shared-view pools)
        (ast.AstExpr.Literal (ast.ast-lit-int 11)))]
    [prefix-ok : bool
      (and
        (= literal 0)
        (= inner-view 1)
        (= same-view 2)
        (= outer-view 3)
        (= later-view 4)
        (= reused later-view)
        (= (ast.ast-node-pool-context-expr-canonical-span-count pools) 1)
        (= (ast.ast-node-pool-context-expr-respan-count pools) 1)
        (ast.ast-node-pool-context-expr-span-oracle-ok? pools)
        (compiler-ast-maybe-span-start-line?
          (ast.ast-node-pool-context-expr-canonical-span pools outer-view)
          2)
        (compiler-ast-maybe-span-start-line?
          (ast.ast-node-pool-context-expr-view-span pools inner-view)
          2)
        (compiler-ast-maybe-span-start-line?
          (ast.ast-node-pool-context-expr-view-span pools same-view)
          2)
        (compiler-ast-maybe-span-start-line?
          (ast.ast-node-pool-context-expr-view-span pools outer-view)
          9)
        (match (ast.ast-node-pool-context-expr-view-span pools reused)
          [(ast.AstMaybeSourceSpan.No) true]
          [_ false])
        (match (ast.ast-node-pool-context-expr-span-oracle pools inner-view)
          [(ast.AstExprSpanOracleResult.CanonicalMatch) true]
          [_ false])
        (match (ast.ast-node-pool-context-expr-span-oracle pools outer-view)
          [(ast.AstExprSpanOracleResult.ReSpanMatch) true]
          [_ false]))]
    (begin
      ;; If an exceptional per-use wrapper is rewritten into a semantic node,
      ;; its view becomes the new identity's original provenance.  Keeping the
      ;; negative ReSpan slot would make canonical reads fail after the rewrite.
      (ast.ast-node-pool-context-expr-set!
        (owned_view.compiler-owned-shared-view pools)
        outer-view
        (ast.AstExpr.Literal (ast.ast-lit-int 99)))
      (let
        [rewrite-ok : bool
          (and
            (= (ast.ast-node-pool-context-expr-canonical-span-count pools) 2)
            (compiler-ast-maybe-span-start-line?
              (ast.ast-node-pool-context-expr-canonical-span pools outer-view)
              9)
            (compiler-ast-maybe-span-start-line?
              (ast.ast-node-pool-context-expr-view-span pools outer-view)
              9))]
        (ast.ast-node-pool-context-expr-truncate!
          (owned_view.compiler-owned-shared-view pools)
          0)
        (let
          [new-literal : i64
            (ast.ast-node-pool-context-expr-push
              (owned_view.compiler-owned-shared-view pools)
              (ast.AstExpr.Literal (ast.ast-lit-int 13)))]
          [new-view : i64
            (ast.ast-expr-spanned-with-pools
              pools
              new-literal
              (ast.ast-source-span 20 1 20 3))]
          (and
            prefix-ok
            rewrite-ok
            (= new-literal 0)
            (= new-view 1)
            (= (ast.ast-node-pool-context-expr-canonical-span-count pools) 1)
            (= (ast.ast-node-pool-context-expr-respan-count pools) 0)
            (ast.ast-node-pool-context-expr-span-oracle-ok? pools)
            (compiler-ast-maybe-span-start-line?
              (ast.ast-node-pool-context-expr-canonical-span pools new-literal)
              20)))))))

;; The in-place expression-pool path grows both sparse provenance tables. Keep
;; records immediately before and after the initial 64-row boundary readable.
(define (compiler-ast-span-record-growth-smoke?) : bool
  (let
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 1 1)]
    [canonical-index : i64 0]
    [base-literal : i64 -1]
    [canonical-63 : i64 -1]
    [canonical-64 : i64 -1]
    [respan-index : i64 0]
    [respan-63 : i64 -1]
    [respan-64 : i64 -1]
    (begin
      (while (< canonical-index 65)
        (let
          [literal : i64
            (ast.ast-node-pool-context-expr-push
              (owned_view.compiler-owned-shared-view pools)
              (ast.AstExpr.Literal (ast.ast-lit-int canonical-index)))]
          [line : i64 (+ canonical-index 1)]
          [view : i64
            (ast.ast-expr-spanned-with-pools
              pools
              literal
              (ast.ast-source-span line 1 line 2))]
          (begin
            (if (= canonical-index 0)
              (set! base-literal literal)
              unit)
            (if (= canonical-index 63)
              (set! canonical-63 view)
              unit)
            (if (= canonical-index 64)
              (set! canonical-64 view)
              unit)
            (set! canonical-index (+ canonical-index 1)))))
      (while (< respan-index 65)
        (let
          [line : i64 (+ respan-index 100)]
          [view : i64
            (ast.ast-expr-spanned-with-pools
              pools
              base-literal
              (ast.ast-source-span line 3 line 4))]
          (begin
            (if (= respan-index 63)
              (set! respan-63 view)
              unit)
            (if (= respan-index 64)
              (set! respan-64 view)
              unit)
            (set! respan-index (+ respan-index 1)))))
      (and
        (= (ast.ast-node-pool-context-expr-len pools) 195)
        (= (ast.ast-node-pool-context-expr-canonical-span-count pools) 65)
        (= (ast.ast-node-pool-context-expr-respan-count pools) 65)
        (ast.ast-node-pool-context-expr-span-oracle-ok? pools)
        (compiler-ast-maybe-span-start-line?
          (ast.ast-node-pool-context-expr-view-span pools canonical-63)
          64)
        (compiler-ast-maybe-span-start-line?
          (ast.ast-node-pool-context-expr-view-span pools canonical-64)
          65)
        (compiler-ast-maybe-span-start-line?
          (ast.ast-node-pool-context-expr-view-span pools respan-63)
          163)
        (compiler-ast-maybe-span-start-line?
          (ast.ast-node-pool-context-expr-view-span pools respan-64)
          164)))))

;; Force several fixed-size expression and type segments in two independently
;; owned contexts. Boundary ids must continue to address their original nodes,
;; hash-consing must survive type-segment growth, and neither context may alias
;; the other's backing storage.
(define (compiler-ast-segmented-growth-isolation-smoke?) : bool
  (let
    [home : arena.Arena (arena.current)]
    [a-arena : arena.Arena (arena.make)]
    [b-arena : arena.Arena (arena.make)]
    [a : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities-in-arena
        1
        1
        (arena.raw-handle a-arena))]
    [b : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities-in-arena
        1
        1
        (arena.raw-handle b-arena))]
    [a-expr-bases-before : i64
      (ast.ast-node-pool-context-expr-segment-bases (& a))]
    [b-expr-bases-before : i64
      (ast.ast-node-pool-context-expr-segment-bases (& b))]
    [expr-index : i64 0]
    [type-index : i64 0]
    [a-last-expr : i64 -1]
    [b-last-expr : i64 -1]
    [a-last-type : i64 -1]
    [b-last-type : i64 -1]
    (begin
      (while (<= expr-index 131072)
        (begin
          (set!
            a-last-expr
            (ast.ast-node-pool-context-expr-push
              (owned_view.compiler-owned-shared-view a)
              (ast.AstExpr.Literal (ast.ast-lit-int expr-index))))
          (if (<= expr-index 65536)
            (set!
              b-last-expr
              (ast.ast-node-pool-context-expr-push
                (owned_view.compiler-owned-shared-view b)
                (ast.AstExpr.Literal (ast.ast-lit-int (- 0 expr-index)))))
            unit)
          (set! expr-index (+ expr-index 1))))
      (while (<= type-index 2048)
        (begin
          (set!
            a-last-type
            (ast.ast-node-pool-context-type-push
              (owned_view.compiler-owned-shared-view a)
              (ast.AstType.Var type-index)))
          (if (<= type-index 1024)
            (set!
              b-last-type
              (ast.ast-node-pool-context-type-push
                (owned_view.compiler-owned-shared-view b)
                (ast.AstType.Var (+ type-index 10000))))
            unit)
          (set! type-index (+ type-index 1))))
      (let
        [a-growth-view : i64
          (ast.ast-expr-spanned-with-pools
            a
            a-last-expr
            (ast.ast-source-span 31 1 31 4))]
        [a-dupe-type : i64
          (ast.ast-node-pool-context-type-push
            (owned_view.compiler-owned-shared-view a)
            (ast.AstType.Var 1024))]
        [a-base : i64 (ast.ast-node-pool-context-base-arena a)]
        [b-base : i64 (ast.ast-node-pool-context-base-arena b)]
        [ok : bool
          (and
            (= a-last-expr 131072)
            (= b-last-expr 65536)
            (= a-last-type 2048)
            (= b-last-type 1024)
            (= a-growth-view 131073)
            (= a-dupe-type 1024)
            (= (ast.ast-node-pool-context-expr-segment-count a) 3)
            (= (ast.ast-node-pool-context-expr-segment-count b) 2)
            (= (ast.ast-node-pool-context-type-segment-count a) 3)
            (= (ast.ast-node-pool-context-type-segment-count b) 2)
            (=
              a-expr-bases-before
              (ast.ast-node-pool-context-expr-segment-bases (& a)))
            (=
              b-expr-bases-before
              (ast.ast-node-pool-context-expr-segment-bases (& b)))
            (compiler-ast-context-expr-int-lit? a 0 0)
            (compiler-ast-context-expr-int-lit? a 65535 65535)
            (compiler-ast-context-expr-int-lit? a 65536 65536)
            (compiler-ast-context-expr-int-lit? a 131072 131072)
            (compiler-ast-context-expr-int-lit? b 65536 -65536)
            (= (ast.ast-node-pool-context-expr-canonical-span-count a) 1)
            (= (ast.ast-node-pool-context-expr-respan-count a) 0)
            (compiler-ast-maybe-span-start-line?
              (ast.ast-node-pool-context-expr-view-span a a-growth-view)
              31)
            (=
              (ast.ast-expr-semantic-node-from-bases
                a-expr-bases-before
                (ast.ast-node-pool-context-expr-len a)
                a-growth-view)
              a-last-expr)
            (compiler-ast-expr-int-lit-value?
              (ast.ast-expr-unspan-with-segment-bases
                a-expr-bases-before
                (ast.ast-node-pool-context-expr-get (& a) a-growth-view))
              131072)
            (match (ast.ast-node-pool-context-type-get a 1024)
              [(ast.AstType.Var name) (= name 1024)]
              [_ false])
            (match (ast.ast-node-pool-context-type-get a 2048)
              [(ast.AstType.Var name) (= name 2048)]
              [_ false])
            (match (ast.ast-node-pool-context-type-get b 1024)
              [(ast.AstType.Var name) (= name 11024)]
              [_ false])
            (not (= a-base b-base))
            (not
              (=
                (ast.ast-node-pool-context-expr-storage-arena a)
                (ast.ast-node-pool-context-expr-storage-arena b))))]
        (begin
          (unsafe
            (arena.set! home))
          (ast.ast-node-pool-context-destroy-storage! a)
          (ast.ast-node-pool-context-destroy-storage! b)
          (unsafe
            (begin
              (arena.tl_arena_destroy a-base)
              (arena.tl_arena_destroy b-base)))
          ok)))))

(define (compiler-ast-cleanup-syntax-id-round-trip?
  [expected : ci.InternSyntaxId]) : bool
  (and
    (match (ast.AstFieldCleanup.Fn expected)
      [(ast.AstFieldCleanup.Fn name) (ci.intern-syntax-id-eq? name expected)]
      [_ false])
    (match (ast.AstStructCleanup.Fn expected)
      [(ast.AstStructCleanup.Fn name) (ci.intern-syntax-id-eq? name expected)]
      [_ false])
    (match (ast.AstEnumCleanup.Fn expected)
      [(ast.AstEnumCleanup.Fn name) (ci.intern-syntax-id-eq? name expected)]
      [_ false])
    (match (ast.AstVariantPayloadCleanup.Fn expected)
      [(ast.AstVariantPayloadCleanup.Fn name)
        (ci.intern-syntax-id-eq? name expected)]
      [_ false])))

(define (compiler-ast-cleanup-syntax-identity-smoke?) : bool
  (let
    [source-id : i64 (ci.intern "cleanup-source")]
    [module-id : i64 (ci.intern "cleanup-module")]
    [base-id : i64 (ci.intern "cleanup-base")]
    [source : ci.InternSyntaxId (ci.intern-syntax-id-from-raw source-id)]
    [generated : ci.InternSyntaxId
      (ci.intern-syntax-id-from-raw
        (ci.intern-generated-name "cleanup-generated"))]
    [qualified : ci.InternSyntaxId
      (ci.intern-syntax-id-from-raw
        (ci.intern-generated-qualified-name
          "cleanup-module/cleanup-base"
          module-id
          base-id))]
    [builtin : ci.InternSyntaxId
      (ci.intern-syntax-id-from-raw cbi.compiler-builtin-id-fix-main)]
    [hygiene : ci.InternSyntaxId
      (ci.intern-syntax-id-from-raw
        (compiler-ast-test-fresh-local-id 7 source-id))]
    [structural : ci.InternSyntaxId
      (ci.intern-syntax-id-from-raw
        (ci.intern-composite-pair-id module-id base-id))]
    (and
      (compiler-ast-cleanup-syntax-id-round-trip? source)
      (compiler-ast-cleanup-syntax-id-round-trip? generated)
      (compiler-ast-cleanup-syntax-id-round-trip? qualified)
      (compiler-ast-cleanup-syntax-id-round-trip? builtin)
      (compiler-ast-cleanup-syntax-id-round-trip? hygiene)
      (compiler-ast-cleanup-syntax-id-round-trip? structural))))

(define (compiler-ast-field-syntax-id-round-trip?
  [expected : ci.InternSyntaxId]) : bool
  (match (ast.AstFieldDef.Def expected (ast.AstType.I64) ast.AstFieldCleanup.No)
    [(ast.AstFieldDef.Def name _ _) (ci.intern-syntax-id-eq? name expected)]))

(define (compiler-ast-field-syntax-identity-smoke?) : bool
  (let
    [source-id : i64 (ci.intern "field-source")]
    [module-id : i64 (ci.intern "field-module")]
    [base-id : i64 (ci.intern "field-base")]
    [source : ci.InternSyntaxId (ci.intern-syntax-id-from-raw source-id)]
    [generated : ci.InternSyntaxId
      (ci.intern-syntax-id-from-raw
        (ci.intern-generated-name "field-generated"))]
    [qualified : ci.InternSyntaxId
      (ci.intern-syntax-id-from-raw
        (ci.intern-generated-qualified-name
          "field-module/field-base"
          module-id
          base-id))]
    [builtin : ci.InternSyntaxId
      (ci.intern-syntax-id-from-raw cbi.compiler-builtin-id-fix-x)]
    [hygiene : ci.InternSyntaxId
      (ci.intern-syntax-id-from-raw
        (compiler-ast-test-fresh-local-id 11 source-id))]
    [structural : ci.InternSyntaxId
      (ci.intern-syntax-id-from-raw
        (ci.intern-composite-pair-id module-id base-id))]
    (and
      (compiler-ast-field-syntax-id-round-trip? source)
      (compiler-ast-field-syntax-id-round-trip? generated)
      (compiler-ast-field-syntax-id-round-trip? qualified)
      (compiler-ast-field-syntax-id-round-trip? builtin)
      (compiler-ast-field-syntax-id-round-trip? hygiene)
      (compiler-ast-field-syntax-id-round-trip? structural))))

(define (compiler-ast-expr-binding-clause-syntax-id-round-trip?
  [expected : ci.InternSyntaxId]) : bool
  (let
    [clause : ast.AstExprBindingClause
      (ast.ast-expr-binding-clause-id
        expected
        false
        0
        0
        (ast.AstType.Var -3)
        (ast.ast-source-span 0 0 0 0))]
    (ci.intern-syntax-id-eq? clause.name expected)))

(define (compiler-ast-expr-binding-clause-syntax-identity-smoke?) : bool
  (let
    [source-id : i64 (ci.intern "binding-clause-source")]
    [module-id : i64 (ci.intern "binding-clause-module")]
    [base-id : i64 (ci.intern "binding-clause-base")]
    [source : ci.InternSyntaxId (ci.intern-syntax-id-from-raw source-id)]
    [generated : ci.InternSyntaxId
      (ci.intern-syntax-id-from-raw
        (ci.intern-generated-name "binding-clause-generated"))]
    [qualified : ci.InternSyntaxId
      (ci.intern-syntax-id-from-raw
        (ci.intern-generated-qualified-name
          "binding-clause-module/binding-clause-base"
          module-id
          base-id))]
    [builtin : ci.InternSyntaxId
      (ci.intern-syntax-id-from-raw cbi.compiler-builtin-id-fix-name)]
    [hygiene : ci.InternSyntaxId
      (ci.intern-syntax-id-from-raw
        (compiler-ast-test-fresh-local-id 13 source-id))]
    [structural : ci.InternSyntaxId
      (ci.intern-syntax-id-from-raw
        (ci.intern-composite-pair-id module-id base-id))]
    (and
      (compiler-ast-expr-binding-clause-syntax-id-round-trip? source)
      (compiler-ast-expr-binding-clause-syntax-id-round-trip? generated)
      (compiler-ast-expr-binding-clause-syntax-id-round-trip? qualified)
      (compiler-ast-expr-binding-clause-syntax-id-round-trip? builtin)
      (compiler-ast-expr-binding-clause-syntax-id-round-trip? hygiene)
      (compiler-ast-expr-binding-clause-syntax-id-round-trip? structural))))

;; These three generated families cover the important storage shapes: a small
;; enum with shared zero-capacity backing, an inline aggregate, and an enum with
;; String payload ownership. Grow each through several capacities and verify
;; that both source and appended values retain their logical contents.
(define (compiler-ast-generated-dense-list-operations-smoke?) : bool
  (let
    [cleanups : ast.AstVariantPayloadCleanupList
      (ast.ast-variant-payload-cleanup-list-new)]
    [cleanup-copy : ast.AstVariantPayloadCleanupList
      (ast.ast-variant-payload-cleanup-list-new)]
    [clauses : ast.AstExprClauseList (ast.ast-expr-clause-list-new)]
    [links : ast.AstExternLinkInputList (ast.ast-extern-link-input-list-new)]
    [zero-params : ast.AstParamList (ast.ast-param-list-with-capacity -1)]
    [minimum-field-defs : ast.AstFieldDefList
      (ast.ast-field-def-list-with-capacity -1)]
    [index : i64 0]
    (begin
      (while (< index 17)
        (begin
          (ast.ast-variant-payload-cleanup-list-push
            (&mut cleanups)
            (if (= (bit-and index 1) 0)
              ast.AstVariantPayloadCleanup.No
              ast.AstVariantPayloadCleanup.Owned))
          (ast.ast-expr-clause-list-push
            (&mut clauses)
            (ast.ast-expr-clause index (* index 3)))
          (ast.ast-extern-link-input-list-push
            (&mut links)
            (if (= (bit-and index 1) 0)
              (ast.AstExternLinkInput.Lib "m")
              (ast.AstExternLinkInput.Search "native")))
          (set! index (+ index 1))))
      (ast.ast-variant-payload-cleanup-list-append-from
        (&mut cleanup-copy)
        (& cleanups)
        0)
      (and
        (= (array-length zero-params.slots) 0)
        (= (array-length minimum-field-defs.slots) 1)
        (= (array-length cleanups.slots) 32)
        (= (array-length cleanup-copy.slots) 32)
        (= (array-length clauses.slots) 32)
        (= (array-length links.slots) 32)
        (= (ast.ast-variant-payload-cleanup-list-len (& cleanups)) 17)
        (= (ast.ast-variant-payload-cleanup-list-len (& cleanup-copy)) 17)
        (= clauses.len 17)
        (= (ast.ast-extern-link-input-list-len (& links)) 17)
        (match (ast.ast-variant-payload-cleanup-list-get
          (& cleanups)
          1
          ast.AstVariantPayloadCleanup.No)
          [(ast.AstVariantPayloadCleanup.Owned) true]
          [_ false])
        (match (ast.ast-variant-payload-cleanup-list-get
          (& cleanup-copy)
          16
          ast.AstVariantPayloadCleanup.Owned)
          [(ast.AstVariantPayloadCleanup.No) true]
          [_ false])
        (let
          [clause : ast.AstExprClause
            (ast.ast-expr-clause-list-get
              (& clauses)
              16
              (ast.ast-expr-clause-fallback))]
          (and (= clause.first 16) (= clause.second 48)))
        (match (ast.ast-extern-link-input-list-get
          (& links)
          0
          (ast.AstExternLinkInput.Arg "fallback"))
          [(ast.AstExternLinkInput.Lib value) (string.eq value "m")]
          [_ false])
        (match (ast.ast-extern-link-input-list-get
          (& links)
          17
          (ast.AstExternLinkInput.Arg "fallback"))
          [(ast.AstExternLinkInput.Arg value) (string.eq value "fallback")]
          [_ false])))))

(test
  compiler-ast-generated-dense-list-operations
  (tl_test.assert-true
    (compiler-ast-generated-dense-list-operations-smoke?)
    "generated AST dense lists preserve capacity, order, and fallbacks"))

(define (main) : i64
  (begin
    (unless (= (ast.compiler-ast-smoke) 23) (return 2))
    (unless (compiler-ast-int-literal-source-bits-smoke?) (return 18))
    (unless (compiler-ast-state-owned-node-pools-smoke?) (return 3))
    (unless (compiler-ast-active-context-sync-smoke?) (return 4))
    (unless (compiler-ast-context-owner-identity-smoke?) (return 17))
    (unless (compiler-ast-program-compaction-smoke?) (return 5))
    (unless (compiler-ast-program-copy-append-smoke?) (return 13))
    (unless (compiler-ast-decl-cons-growth-smoke?) (return 6))
    (unless (compiler-ast-decl-cons-pure-smoke?) (return 7))
    (unless (compiler-ast-program-compaction-string-payloads-smoke?) (return 8))
    (unless (compiler-ast-compat-context-set-smoke?) (return 9))
    (unless (compiler-ast-context-clone-types-only-smoke?) (return 10))
    (unless (compiler-ast-clause-list-tail-smoke?) (return 11))
    (unless (compiler-ast-generated-path-owner-smoke?) (return 12))
    (unless (compiler-ast-context-owned-arena-smoke?) (return 13))
    (unless (compiler-ast-compaction-borrow-child-smoke?) (return 14))
    (unless (compiler-ast-stable-expr-row-view-boundaries-smoke?) (return 24))
    (unless
      (compiler-ast-stale-canonical-span-slot-recovery-smoke?)
      (return 20))
    (unless (compiler-ast-expression-span-sidecar-smoke?) (return 19))
    (unless (compiler-ast-span-record-growth-smoke?) (return 22))
    (unless (compiler-ast-segmented-growth-isolation-smoke?) (return 15))
    (unless (compiler-ast-macro-type-kind-dense-compaction-smoke?) (return 16))
    (unless (compiler-ast-cleanup-syntax-identity-smoke?) (return 20))
    (unless (compiler-ast-field-syntax-identity-smoke?) (return 21))
    (unless
      (compiler-ast-expr-binding-clause-syntax-identity-smoke?)
      (return 23))
    (unless (compiler-ast-generated-dense-list-operations-smoke?) (return 25))
    42))