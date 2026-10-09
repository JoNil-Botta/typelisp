;; compiler_ast_types_smoke.tl - Runnable AST data-shape smoke.
(import stdlib.iterator)
(import stdlib.str_cat_runtime as str_cat)
(import compiler_ast_types as ast)
(import compiler_ast_types_tests as ast_tests)
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
    [(Literal lit)
      (match lit
        [(Int value _) (= value expected)]
        [_ false])]
    [_ false]))

(define (compiler-ast-state-type-i64?
  [pool : (& pool ast.AstTypeNodePoolState)]
  [id : i64]) : bool
  (match (ast.ast-type-node-pool-state-get pool id)
    [(I64) true]
    [_ false]))

(define (compiler-ast-state-type-string?
  [pool : ast.AstTypeNodePoolState]
  [id : i64]) : bool
  (match (ast.ast-type-node-pool-state-get pool id)
    [(String) true]
    [_ false]))

(define (compiler-ast-state-type-char?
  [pool : ast.AstTypeNodePoolState]
  [id : i64]) : bool
  (match (ast.ast-type-node-pool-state-get pool id)
    [(Char) true]
    [_ false]))

(define (compiler-ast-state-expr-push-pool
  [pool : ast.AstExprNodePoolState]
  [node : ast.AstExpr]) : ast.AstExprNodePoolState
  (match (ast.ast-expr-node-pool-state-push pool node)
    [(AstExprNodePoolPushOk next _) next]))

(define (compiler-ast-state-type-push-pool
  [pool : ast.AstTypeNodePoolState]
  [node : ast.AstType]) : ast.AstTypeNodePoolState
  (match (ast.ast-type-node-pool-state-push pool (& node))
    [(AstTypeNodePoolPushOk next _) next]))

(define (compiler-ast-state-owned-expr-pool-smoke?) : bool
  (let
    [a0 : ast.AstExprNodePoolState (ast.ast-expr-node-pool-state-create 1)]
    [aid0 : i64 (ast_tests.ast-expr-node-pool-state-mark a0)]
    [a1 : ast.AstExprNodePoolState
      (compiler-ast-state-expr-push-pool a0 (Literal (ast.ast-lit-int 1)))]
    [aid1 : i64 (ast_tests.ast-expr-node-pool-state-mark a1)]
    [a2 : ast.AstExprNodePoolState
      (compiler-ast-state-expr-push-pool a1 (Literal (ast.ast-lit-int 2)))]
    [b0 : ast.AstExprNodePoolState (ast.ast-expr-node-pool-state-create 1)]
    [bmark : i64 (ast_tests.ast-expr-node-pool-state-mark b0)]
    [bid0 : i64 (ast_tests.ast-expr-node-pool-state-mark b0)]
    [b1 : ast.AstExprNodePoolState
      (compiler-ast-state-expr-push-pool b0 (Literal (ast.ast-lit-int 10)))]
    [breset : ast.AstExprNodePoolState
      (ast_tests.ast-expr-node-pool-state-reset-to-mark b1 bmark)]
    [bid1 : i64 (ast_tests.ast-expr-node-pool-state-mark breset)]
    [b2 : ast.AstExprNodePoolState
      (compiler-ast-state-expr-push-pool breset (Literal (ast.ast-lit-int 11)))]
    [b3 : ast.AstExprNodePoolState
      (ast.ast-expr-node-pool-state-set! b2 bid1 (Literal (ast.ast-lit-int 12)))]
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
    [aid0 : i64 (ast_tests.ast-type-node-pool-state-mark a0)]
    [a1 : ast.AstTypeNodePoolState (compiler-ast-state-type-push-pool a0 (I64))]
    [aid1 : i64 (ast_tests.ast-type-node-pool-state-mark a1)]
    [a2 : ast.AstTypeNodePoolState
      (compiler-ast-state-type-push-pool a1 (String))]
    [b0 : ast.AstTypeNodePoolState (ast.ast-type-node-pool-state-create 1)]
    [bmark : i64 (ast_tests.ast-type-node-pool-state-mark b0)]
    [bid0 : i64 (ast_tests.ast-type-node-pool-state-mark b0)]
    [b1 : ast.AstTypeNodePoolState
      (compiler-ast-state-type-push-pool b0 (Bool))]
    [breset : ast.AstTypeNodePoolState
      (ast_tests.ast-type-node-pool-state-reset-to-mark b1 bmark)]
    [bid1 : i64 (ast_tests.ast-type-node-pool-state-mark breset)]
    [b2 : ast.AstTypeNodePoolState
      (compiler-ast-state-type-push-pool breset (I64))]
    [b3 : ast.AstTypeNodePoolState
      (ast_tests.ast-type-node-pool-state-set! b2 bid1 (Char))]
    (and
      (= aid0 0)
      (= aid1 1)
      (= bid0 0)
      (= bid1 0)
      (= (ast.ast-type-node-pool-state-len a2) 2)
      (= (ast.ast-type-node-pool-state-len b3) 1)
      (not (ast_tests.ast-type-node-pool-state-exhausted? a2))
      (compiler-ast-state-type-i64? a2 aid0)
      (compiler-ast-state-type-string? a2 aid1)
      (compiler-ast-state-type-char? b3 bid1))))

(define (compiler-ast-state-owned-type-dedup-reuse-smoke?) : bool
  (match (ast.ast-type-node-pool-state-push
    (ast.ast-type-node-pool-state-create 1)
    (& (I64)))
    [(AstTypeNodePoolPushOk p1 first-id)
      (match (ast.ast-type-node-pool-state-push p1 (& (I64)))
        [(AstTypeNodePoolPushOk p2 second-id)
          (and
            (= first-id 0)
            (= second-id first-id)
            (= (ast.ast-type-node-pool-state-len p2) 1)
            (compiler-ast-state-type-i64? p2 first-id))])]))

(define (compiler-ast-state-owned-type-dedup-isolated-smoke?) : bool
  (match (ast.ast-type-node-pool-state-push
    (ast.ast-type-node-pool-state-create 1)
    (& (I64)))
    [(AstTypeNodePoolPushOk a1 a-id)
      (match (ast.ast-type-node-pool-state-push
        (ast.ast-type-node-pool-state-create 1)
        (& (I64)))
        [(AstTypeNodePoolPushOk b1 b-id)
          (match (ast.ast-type-node-pool-state-push a1 (& (I64)))
            [(AstTypeNodePoolPushOk a2 a-dupe-id)
              (match (ast.ast-type-node-pool-state-push b1 (& (I64)))
                [(AstTypeNodePoolPushOk b2 b-dupe-id)
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
    (& (I64)))
    [(AstTypeNodePoolPushOk p1 i64-id)
      (match (ast.ast-type-node-pool-state-push p1 (& (String)))
        [(AstTypeNodePoolPushOk p2 string-id)
          (let
            [reset : ast.AstTypeNodePoolState
              (ast_tests.ast-type-node-pool-state-reset-to-mark p2 1)]
            (match (ast.ast-type-node-pool-state-push reset (& (String)))
              [(AstTypeNodePoolPushOk p3 string-id2)
                (and
                  (= i64-id 0)
                  (= string-id 1)
                  (= string-id2 1)
                  (= (ast.ast-type-node-pool-state-len p3) 2)
                  (compiler-ast-state-type-i64? p3 i64-id)
                  (compiler-ast-state-type-string? p3 string-id2))]))])]))

(define (compiler-ast-state-owned-type-dedup-budget-smoke?) : bool
  ;; Keep the source-macro self-host uniqueness budget from silently shrinking
  ;; (see `ast-type-node-pool-state-dedup-capacity`).
  (let
    [state : ast.AstTypeNodePoolState (ast.ast-type-node-pool-state-create 1)]
    (>= (ast.ty-node-dedup-table-capacity state.dedup-slots) 131072)))

;; At the half-load boundary a duplicate triggers growth but keeps its id.
;; The replacement descriptor and data must outlive the caller's scratch arena.
(define (compiler-ast-context-dedup-half-load-smoke?) : bool
  (let
    [active-before : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [decoy : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [retained-bases : i64 (ast.ast-node-pool-context-type-segment-bases pools)]
    [first : i64 (ast.ast-node-pool-context-type-push pools (I64))]
    [collision-a : i64 (ast.ast-node-pool-context-type-push pools (Var 0))]
    [collision-b : i64 (ast.ast-node-pool-context-type-push pools (Var 131072))]
    [decoy-first : i64 (ast.ast-node-pool-context-type-push decoy (Bool))]
    (for [index (iterator.range 0 65533)]
      (ast.ast-node-pool-context-type-push pools (Array first index))
      unit)
    (ast.ast-node-pool-context-install! decoy)
    (let
      [home : arena.Arena (arena.current)]
      [scratch : arena.Arena (arena.make)]
      [duplicate-node : ast.AstType (I64)]
      [duplicate : i64
        (in-arena
          scratch
          (ast.ast-node-pool-context-type-push pools duplicate-node))]
      [_destroy : unit
        (unsafe
          (arena.destroy scratch))]
      [state : ast.AstTypeNodePoolState
        (ast.ast-type-pool-cell-read pools.type-pool)]
      [count-at-hit : i64 state.count]
      [dedup-at-hit : i64 state.dedup-count]
      [capacity-at-hit : i64
        (ast.ty-node-dedup-table-capacity state.dedup-slots)]
      [new-id : i64 (ast.ast-node-pool-context-type-push pools (Char))]
      [ok : bool
        (and
          (= first 0)
          (= collision-a 1)
          (= collision-b 2)
          (= duplicate first)
          (= count-at-hit 65536)
          (= dedup-at-hit 65536)
          (= capacity-at-hit 262144)
          (= new-id 65536)
          (=
            (ast.ast-node-pool-context-type-segment-bases pools)
            retained-bases)
          (match (ast.ast-type-segment-bases-get retained-bases 65535)
            [(Array elem count) (and (= elem first) (= count 65532))]
            [_ false])
          (= (ast.ast-node-pool-context-type-push pools (Var 0)) collision-a)
          (=
            (ast.ast-node-pool-context-type-push pools (Var 131072))
            collision-b)
          (=
            (ast.ast-node-pool-context-type-push pools (Array first 65532))
            65535)
          (compiler-ast-context-type-i64? pools first)
          (compiler-ast-context-type-char? pools new-id)
          (= (ast.ast-node-pool-context-type-len pools) 65537)
          (= decoy-first 0)
          (= (ast.ast-node-pool-context-type-len decoy) 1)
          (= (ast.ty-node-push (& (Bool))) decoy-first)
          (ast.ast-node-pool-context-type-installed? decoy))]
      (unsafe
        (arena.set! home))
      (ast.ast-node-pool-context-install! pools)
      (set!
        ok
        (and
          ok
          (= (ast.ty-node-push (& (I64))) first)
          (= (ast.ty-node-push (& (Char))) new-id)
          (= (ast.ast-node-pool-context-type-len pools) 65537)))
      (ast.ty-node-pool-truncate! 1)
      (set!
        ok
        (and
          ok
          (= (ast.ast-node-pool-context-type-push pools (String)) 1)
          (= (ast.ast-node-pool-context-type-push pools (String)) 1)
          (= (ast.ast-node-pool-context-type-len pools) 2)
          (= (ast.ty-node-push (& (String))) 1)))
      (ast.ast-node-pool-context-install! active-before)
      ok)))

(test
  compiler-ast-context-dedup-half-load
  (tl_test.assert-true
    (compiler-ast-context-dedup-half-load-smoke?)
    "explicit dedup growth preserves ids, collisions, reset and arena ownership"))

;; Whether every table slot of POOLS' dedup array is empty and its log reset,
;; exactly as a full clear of the table leaves it.
(define (compiler-ast-type-dedup-table-empty? [pools : ast.AstNodePoolContext]) : bool
  (let
    [state : ast.AstTypeNodePoolState
      (ast.ast-type-pool-cell-read pools.type-pool)]
    [slots : (__tl_dyn-array i64) (ast.ast-place-shared-view state.dedup-slots)]
    [capacity : i64 (ast.ty-node-dedup-table-capacity slots)]
    [empty : bool (= (array-ref slots capacity) 0)]
    [i : i64 0]
    (while (and empty (< i capacity))
      (if (= (array-ref slots i) 0)
        unit
        (set! empty false))
      (+= i 1))
    empty))

;; Push COUNT distinct type variables starting at name START.
(define (compiler-ast-type-dedup-push-vars
  [pools : ast.AstNodePoolContext]
  [start : i64]
  [count : i64]) : unit
  (for [index (iterator.range 0 count)]
    (ast.ast-node-pool-context-type-push pools (Var (+ start index)))
    unit))

;; A dedup clear empties exactly the slots filled since the last one, whichever
;; alias filled them: clears at the current count and at an interior mark,
;; global-path inserts cleared through the context's stale state, an
;; overflowing log, and a table rehashed by a grow all leave the table as empty
;; as a full clear does, and deduplication keeps working afterwards.
(define (compiler-ast-type-dedup-logged-clear-smoke?) : bool
  (let
    [active-before : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [ok : bool true]
    (compiler-ast-type-dedup-push-vars pools 0 100)
    (ast.ast-node-pool-context-type-dedup-clear! pools)
    (set! ok (and ok (compiler-ast-type-dedup-table-empty? pools)))
    (compiler-ast-type-dedup-push-vars pools 1000 200)
    (ast.ast-node-pool-context-reset-to!
      pools
      (ast.ast-node-pool-context-expr-len pools)
      150)
    (set!
      ok
      (and
        ok
        (compiler-ast-type-dedup-table-empty? pools)
        (= (ast.ast-node-pool-context-type-len pools) 150)))
    (ast.ast-node-pool-context-install! pools)
    (for [index (iterator.range 0 300)]
      (ast.ty-node-push (& (Var (+ 5000 index))))
      unit)
    (ast.ast-node-pool-context-install! active-before)
    (ast.ast-node-pool-context-reset-to!
      pools
      (ast.ast-node-pool-context-expr-len pools)
      0)
    (set! ok (and ok (compiler-ast-type-dedup-table-empty? pools)))
    (compiler-ast-type-dedup-push-vars
      pools
      0
      (+ ast.ty-node-dedup-log-capacity 10))
    (ast.ast-node-pool-context-type-dedup-clear! pools)
    (set! ok (and ok (compiler-ast-type-dedup-table-empty? pools)))
    (compiler-ast-type-dedup-push-vars pools 100000 70000)
    (let
      [state : ast.AstTypeNodePoolState
        (ast.ast-type-pool-cell-read pools.type-pool)]
      (set!
        ok
        (and ok (= (ast.ty-node-dedup-table-capacity state.dedup-slots) 262144))))
    (ast.ast-node-pool-context-reset-to!
      pools
      (ast.ast-node-pool-context-expr-len pools)
      0)
    (set! ok (and ok (compiler-ast-type-dedup-table-empty? pools)))
    (let
      [bool-id : i64 (ast.ast-node-pool-context-type-push pools (Bool))]
      (and
        ok
        (= bool-id 0)
        (= (ast.ast-node-pool-context-type-push pools (Bool)) bool-id)
        (= (ast.ast-node-pool-context-type-len pools) 1)))))

;; Whether POOLS and its clone hold identical dedup arrays, log included.
(define (compiler-ast-type-dedup-clone-equal? [pools : ast.AstNodePoolContext]) : bool
  (let
    [clone : ast.AstNodePoolContext
      (ast.ast-node-pool-context-clone-types-only pools)]
    [source-state : ast.AstTypeNodePoolState
      (ast.ast-type-pool-cell-read pools.type-pool)]
    [clone-state : ast.AstTypeNodePoolState
      (ast.ast-type-pool-cell-read clone.type-pool)]
    [source : (__tl_dyn-array i64)
      (ast.ast-place-shared-view source-state.dedup-slots)]
    [copy : (__tl_dyn-array i64)
      (ast.ast-place-shared-view clone-state.dedup-slots)]
    [same : bool (= (array-length source) (array-length copy))]
    [i : i64 0]
    (while (and same (< i (array-length source)))
      (if (= (array-ref source i) (array-ref copy i))
        unit
        (set! same false))
      (+= i 1))
    same))

;; Cloning a context's types copies its dedup array exactly, from the log when
;; it is complete and in full when it overflowed.
(define (compiler-ast-type-dedup-clone-smoke?) : bool
  (let
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [ok : bool true]
    (compiler-ast-type-dedup-push-vars pools 0 500)
    (set! ok (and ok (compiler-ast-type-dedup-clone-equal? pools)))
    (compiler-ast-type-dedup-push-vars
      pools
      1000
      (+ ast.ty-node-dedup-log-capacity 10))
    (and ok (compiler-ast-type-dedup-clone-equal? pools))))

(test
  compiler-ast-type-dedup-clone
  (tl_test.assert-true
    (compiler-ast-type-dedup-clone-smoke?)
    "a types-only clone copies the dedup array exactly"))

(test
  compiler-ast-type-dedup-logged-clear
  (tl_test.assert-true
    (compiler-ast-type-dedup-logged-clear-smoke?)
    "a logged dedup clear leaves the table as empty as a full clear"))

;; Use a small real index with the existing bound temporarily set to its
;; capacity. This exercises the maximum-capacity fallback without an 8M-node
;; fixture; restore the bound and installed owner before reporting assertions.
(define (compiler-ast-context-dedup-max-capacity-smoke?) : bool
  (let
    [active-before : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
    [old-max : i64 ast.ty-node-dedup-max-capacity]
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [state : ast.AstTypeNodePoolState
      (ast.ast-type-pool-cell-read pools.type-pool)]
    [small : ast.AstTypeNodePoolState
      (ast.AstTypeNodePoolState
        state.segment-bases
        state.count
        state.base-arena
        state.exhausted
        (in-arena
          (arena.Arena state.base-arena)
          (ast.ty-node-dedup-slots-new 8))
        state.dedup-count
        state.storage-arena
        state.segment-count)]
    (ast.ast-type-pool-cell-write! pools.type-pool small)
    (ast.ast-node-pool-context-type-push pools (I64))
    (ast.ast-node-pool-context-type-push pools (Var 0))
    (ast.ast-node-pool-context-type-push pools (Var 8))
    (ast.ast-node-pool-context-type-push pools (Bool))
    (unsafe
      (ptr-write!
        (ptr-cast (ptr-addr-of ast.ty-node-dedup-max-capacity) : (MutPtr i64))
        8))
    (let
      [explicit : i64 (ast.ast-node-pool-context-type-push pools (I64))]
      [after-explicit : i64 (ast.ast-node-pool-context-type-len pools)]
      [_install : unit (ast.ast-node-pool-context-install! pools)]
      [installed : i64 (ast.ty-node-push (& (I64)))]
      [after-installed : i64 (ast.ast-node-pool-context-type-len pools)]
      [final-state : ast.AstTypeNodePoolState
        (ast.ast-type-pool-cell-read pools.type-pool)]
      [capacity : i64
        (ast.ty-node-dedup-table-capacity final-state.dedup-slots)]
      [dedup-count : i64 final-state.dedup-count]
      (unsafe
        (ptr-write!
          (ptr-cast (ptr-addr-of ast.ty-node-dedup-max-capacity) : (MutPtr i64))
          old-max))
      (ast.ast-node-pool-context-install! active-before)
      (and
        (= explicit 4)
        (= after-explicit 5)
        (= installed 5)
        (= after-installed 6)
        (= capacity 8)
        (= dedup-count 4)))))

(test
  compiler-ast-context-dedup-max-capacity
  (tl_test.assert-true
    (compiler-ast-context-dedup-max-capacity-smoke?)
    "both append APIs retain raw fallback at the dedup capacity bound"))

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
    [(I64) true]
    [_ false]))

(define (compiler-ast-context-type-char?
  [pools : (& pools ast.AstNodePoolContext)]
  [id : i64]) : bool
  (match (ast.ast-node-pool-context-type-get pools id)
    [(Char) true]
    [_ false]))

(define (compiler-ast-context-expr-int-lit?
  [pools : (& pools ast.AstNodePoolContext)]
  [id : i64]
  [expected : i64]) : bool
  (match (ast.ast-node-pool-context-expr-get pools id)
    [(Literal lit)
      (match lit
        [(Int value _) (= value expected)]
        [_ false])]
    [_ false]))

(define (compiler-ast-expr-int-lit-value? [expr : ast.AstExpr] [expected : i64]) : bool
  (match expr
    [(Literal lit)
      (match lit
        [(Int value _) (= value expected)]
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
      (ast.ast-node-pool-context-expr-push a (Literal (ast.ast-lit-int 11)))]
    [a-spanned : i64
      (ast.ast-node-pool-context-expr-push
        a
        (Spanned a-literal (ast.ast-source-span 1 1 1 2)))]
    [a-macro : i64
      (ast.ast-node-pool-context-expr-push a (MacroExpansion a-spanned 101 201))]
    [b-literal : i64
      (ast.ast-node-pool-context-expr-push b (Literal (ast.ast-lit-int 91)))]
    [b-spanned : i64
      (ast.ast-node-pool-context-expr-push
        b
        (Spanned b-literal (ast.ast-source-span 2 1 2 2)))]
    [b-macro : i64
      (ast.ast-node-pool-context-expr-push b (MacroExpansion b-spanned 102 202))]
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
            (& (ast.ast-node-pool-context-expr-get (& a) a-macro)))
          11)
        (compiler-ast-expr-int-lit-value?
          (ast.ast-expr-unspan-with-segment-bases
            b-bases
            (& (ast.ast-node-pool-context-expr-get (& b) b-macro)))
          91))]
    [_rewrite-inner : unit
      (ast.ast-node-pool-context-expr-set!
        a
        a-literal
        (& (Literal (ast.ast-lit-int 12))))]
    [rewrite-ok : bool
      (compiler-ast-expr-int-lit-value?
        (ast.ast-expr-unspan-with-segment-bases
          (ast.ast-node-pool-context-expr-segment-bases (& a))
          (& (ast.ast-node-pool-context-expr-get (& a) a-macro)))
        12)]
    [mark : i64 (ast.ast-node-pool-context-expr-len a)]
    [retired-literal : i64
      (ast.ast-node-pool-context-expr-push a (Literal (ast.ast-lit-int 13)))]
    [retired-wrapper : i64
      (ast.ast-node-pool-context-expr-push
        a
        (Spanned retired-literal (ast.ast-source-span 3 1 3 2)))]
    [retired-ok : bool
      (compiler-ast-expr-int-lit-value?
        (ast.ast-expr-unspan-with-segment-bases
          (ast.ast-node-pool-context-expr-segment-bases (& a))
          (& (ast.ast-node-pool-context-expr-get (& a) retired-wrapper)))
        13)]
    [_truncate : unit (ast.ast-node-pool-context-expr-truncate! a mark)]
    [replacement-literal : i64
      (ast.ast-node-pool-context-expr-push a (Literal (ast.ast-lit-int 14)))]
    [replacement-wrapper : i64
      (ast.ast-node-pool-context-expr-push
        a
        (MacroExpansion replacement-literal 103 203))]
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
            (& (ast.ast-node-pool-context-expr-get (& a) replacement-wrapper)))
          14)
        ;; The unrelated context must retain its own generation and rows.
        (compiler-ast-expr-int-lit-value?
          (ast.ast-expr-unspan-with-segment-bases
            (ast.ast-node-pool-context-expr-segment-bases (& b))
            (& (ast.ast-node-pool-context-expr-get (& b) b-macro)))
          91))]
    (ast.ast-node-pool-context-destroy-storage! a)
    (ast.ast-node-pool-context-destroy-storage! b)
    (and initial-ok rewrite-ok retired-ok reset-ok)))

(define (compiler-ast-context-base-arenas-match?
  [pools : (& pools ast.AstNodePoolContext)]) : bool
  (let
    [expr-pool : ast.AstExprNodePoolState
      (ast.ast-expr-pool-cell-read pools.expr-pool)]
    [type-pool : ast.AstTypeNodePoolState
      (ast.ast-type-pool-cell-read pools.type-pool)]
    (= expr-pool.base-arena type-pool.base-arena)))

(define (compiler-ast-context-clone-types-only-smoke?) : bool
  (let
    [source : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 1 1)]
    [expr-id : i64
      (ast.ast-node-pool-context-expr-push
        source
        (Literal (ast.ast-lit-int 17)))]
    [i64-id : i64 (ast.ast-node-pool-context-type-push source (I64))]
    [ptr-id : i64 (ast.ast-node-pool-context-type-push source (Ptr i64-id))]
    [ptr-dupe-id : i64
      (ast.ast-node-pool-context-type-push source (Ptr i64-id))]
    [cloned : ast.AstNodePoolContext
      (ast.ast-node-pool-context-clone-types-only source)]
    [cloned-ptr-id : i64
      (ast.ast-node-pool-context-type-push cloned (Ptr i64-id))]
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
        [(Ptr inner) (= inner i64-id)]
        [_ false]))))

(define (compiler-ast-active-context-sync-smoke?) : bool
  (let
    [active-before : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 1 1)]
    [ok : bool true]
    (ast.ast-node-pool-context-install! pools)
    (let
      [expr-a : i64 (ast.ast-node-push (Literal (ast.ast-lit-int 31)))]
      [expr-b : i64 (ast.ast-node-push (Literal (ast.ast-lit-int 32)))]
      [type-a : i64 (ast.ty-node-push (& (I64)))]
      [type-b : i64 (ast.ty-node-push (& (Char)))]
      ;; Var hashes differ by their name ids, so this 131,072 delta collides
      ;; in the initial power-of-two table after the odd slot multiplier.
      [type-collision-a : i64 (ast.ty-node-push (& (Var 0)))]
      [type-collision-b : i64 (ast.ty-node-push (& (Var 131072)))]
      [type-collision-a-again : i64 (ast.ty-node-push (& (Var 0)))]
      (set!
        ok
        (and
          ok
          (= expr-a 0)
          (= expr-b 1)
          (= type-a 0)
          (= type-b 1)
          (= type-collision-a 2)
          (= type-collision-b 3)
          (= type-collision-a-again type-collision-a)))
      ;; Force replacement of the installed context's dedup table. The hot
      ;; raw backing pointer must follow the new descriptor and continue to
      ;; return the existing ids rather than appending duplicates.
      (ast.ty-node-dedup-grow!)
      (set!
        ok
        (and
          ok
          (= (ast.ty-node-push (& (I64))) type-a)
          (= (ast.ty-node-push (& (Char))) type-b)
          (= (ast.ty-node-push (& (Var 0))) type-collision-a)
          (= (ast.ty-node-push (& (Var 131072))) type-collision-b)
          (= (ast.ast-node-pool-context-expr-len pools) 2)
          (= (ast.ast-node-pool-context-type-len pools) 4)
          (compiler-ast-context-expr-int-lit? pools expr-a 31)
          (compiler-ast-context-expr-int-lit? pools expr-b 32)
          (compiler-ast-context-type-i64? pools type-a)
          (compiler-ast-context-type-char? pools type-b)
          (compiler-ast-context-base-arenas-match? pools)))
      (ast.ast-node-pool-truncate! 1)
      (ast.ty-node-pool-truncate! 1)
      (set!
        ok
        (and
          ok
          (= (ast.ast-node-pool-context-expr-len pools) 1)
          (= (ast.ast-node-pool-context-type-len pools) 1)
          (compiler-ast-context-expr-int-lit? pools expr-a 31)
          (compiler-ast-context-type-i64? pools type-a)))
      (ast.ast-node-pool-context-install! active-before)
      ok)))

(define (compiler-ast-context-owner-identity-smoke?) : bool
  (let
    [active-before : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 1 1)]
    [owner : i64 (ast.ast-node-pool-context-owner-arena pools)]
    [base : i64 (ast.ast-node-pool-context-base-arena pools)]
    [copied : ast.AstNodePoolContext (ast.ast-node-pool-context-snapshot pools)]
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
      (ast.ast-node-pool-context-install! active-before)
      ok)))

(define (compiler-ast-context-shared-binary?
  [pools : (& pools ast.AstNodePoolContext)]
  [id : i64]
  [old-lit : i64]
  [old-span : i64]) : bool
  (match (ast.ast-node-pool-context-expr-get pools id)
    [(Binary _ left right)
      (if (= left right)
        (match (ast.ast-node-pool-context-expr-get pools left)
          [(Spanned inner span)
            (and
              (not (= left old-span))
              (not (= inner old-lit))
              (= (ast.ast-source-span-start-line span) 1)
              (= (ast.ast-source-span-start-col span) 2)
              (= (ast.ast-source-span-end-line span) 3)
              (= (ast.ast-source-span-end-col span) 4)
              (match (ast.ast-node-pool-context-expr-view-span pools left)
                [(Some sidecar-span)
                  (ast.ast-source-span-eq? span sidecar-span)]
                [_ false])
              (match (ast.ast-node-pool-context-expr-span-oracle pools left)
                [(CanonicalMatch) true]
                [_ false])
              (compiler-ast-context-expr-int-lit? pools inner 7))]
          [_ false])
        false)]
    [_ false]))

(define (compiler-ast-global-shared-binary? [id : i64] [ptr-ty-id : i64]) : bool
  (and
    (match (ast.ast-node-get id)
      [(Binary _ left right)
        (if (= left right)
          (match (ast.ast-node-get left)
            [(Spanned inner _)
              (match (ast.ast-node-get inner)
                [(Literal lit)
                  (match lit
                    [(Int value _) (= value 7)]
                    [_ false])]
                [_ false])]
            [_ false])
          false)]
      [_ false])
    (match (ast.ty-node-get ptr-ty-id)
      [(Ptr inner)
        (match (ast.ty-node-get inner)
          [(I64) true]
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
    [(Program decls-box)
      (match (ast.ast-decl-list-step (deref decls-box))
        [(Cons first rest-box)
          (match first
            [(Def _ _ maybe-ty first-body)
              (match (ast.ast-decl-list-step rest-box)
                [(Cons second tail-box)
                  (match second
                    [(Test _ second-body metadata _)
                      (and
                        (= first-body second-body)
                        (not (= first-body source-body))
                        (ast.ast-test-metadata-slow? metadata)
                        (match (ast.ast-test-metadata-ignore-reason metadata)
                          [(Some reason) (string.eq reason "compaction reason")]
                          [_ false])
                        (= (ast.ast-node-pool-context-expr-len pools) 4)
                        (= (ast.ast-node-pool-context-type-len pools) 2)
                        (compiler-ast-context-shared-binary?
                          pools
                          first-body
                          source-lit
                          source-span)
                        (match maybe-ty
                          [(Some ty)
                            (match ty
                              [(Array ptr-id count)
                                (and
                                  (= count 4)
                                  (match (ast.ast-node-pool-context-type-get
                                    pools
                                    ptr-id)
                                    [(Ptr inner)
                                      (match (ast.ast-node-pool-context-type-get
                                        pools
                                        inner)
                                        [(I64) true]
                                        [_ false])]
                                    [_ false]))]
                              [_ false])]
                          [_ false])
                        (match (ast.ast-decl-list-step tail-box)
                          [(Cons third final-box)
                            (match third
                              [(Def _ _ _ make-body)
                                (and
                                  (not (= make-body source-make))
                                  (match (ast.ast-node-pool-context-expr-get
                                    pools
                                    make-body)
                                    [(FixedMakeArray _ size-body)
                                      (= size-body first-body)]
                                    [_ false])
                                  (match (ast.ast-decl-list-step final-box)
                                    [(Nil) true]
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
        (& (ast.ast-expr-node-pool-state-create 8))
        (& (ast.ast-type-node-pool-state-create 8))
        ;; Smoke-local scratch pool: never installed, caller-arena owned.
        (arena.tl_arena_current))]
    [dest-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new
        (& (ast.ast-expr-node-pool-state-create 8))
        (& (ast.ast-type-node-pool-state-create 8))
        ;; Smoke-local scratch pool: never installed, caller-arena owned.
        (arena.tl_arena_current))]
    [active-before : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
    [source-decoy-expr : i64
      (ast.ast-node-pool-context-expr-push
        source-pools
        (Literal (ast.ast-lit-int 999)))]
    [source-decoy-ty : i64
      (ast.ast-node-pool-context-type-push source-pools (Char))]
    [source-i64-ty : i64
      (ast.ast-node-pool-context-type-push source-pools (I64))]
    [source-ptr-ty : i64
      (ast.ast-node-pool-context-type-push source-pools (Ptr source-i64-ty))]
    [array-ty : ast.AstType (Array source-ptr-ty 4)]
    [source-lit : i64
      (ast.ast-node-pool-context-expr-push
        source-pools
        (Literal (ast.ast-lit-int 7)))]
    [source-span : i64
      (ast.ast-node-pool-context-expr-push
        source-pools
        (Spanned source-lit (ast.ast-source-span 1 2 3 4)))]
    [source-body : i64
      (ast.ast-node-pool-context-expr-push
        source-pools
        (Binary (Add) source-span source-span))]
    [source-make : i64
      (ast.ast-node-pool-context-expr-push
        source-pools
        (FixedMakeArray
          (ast.ast-node-pool-context-type-push source-pools (Ptr source-i64-ty))
          source-body))]
    [value-name-id : i64 (ci.intern-generated-name "value")]
    [same-name-id : i64 (ci.intern-generated-name "same")]
    [array-name-id : i64 (ci.intern-generated-name "array")]
    [program : ast.AstProgram
      (ast.ast-program
        (ast.ast-decl-cons
          (& (ast.ast-decl-def-id value-name-id (Some array-ty) source-body))
          (&
            (ast.ast-decl-cons
              (&
                (ast.ast-decl-test-metadata-id
                  same-name-id
                  source-body
                  (ast.ast-test-metadata-new (Some "compaction reason") true)
                  (ast.ast-source-span 5 6 7 8)))
              (&
                (ast.ast-decl-cons
                  (& (ast.ast-decl-def-id array-name-id No source-make))
                  (& (ast.ast-decl-list-new))))))))]
    [dest-decoy-expr : i64
      (ast.ast-node-pool-context-expr-push
        dest-pools
        (Literal (ast.ast-lit-int 1234)))]
    [dest-decoy-ty : i64
      (ast.ast-node-pool-context-type-push dest-pools (Bool))]
    [compacted : ast.AstProgramCompaction
      (ast.ast-program-compact-with-pools source-pools dest-pools (& program))]
    (match compacted
      [(AstProgramCompaction out-program out-pools)
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
              [(Program decls-box)
                (match (ast.ast-decl-list-step (deref decls-box))
                  [(Cons first _)
                    (match first
                      [(Def _ _ maybe-ty body)
                        (match maybe-ty
                          [(Some ty)
                            (match ty
                              [(Array ptr-id _)
                                (ast.ast-node-pool-context-install! out-pools)
                                (compiler-ast-global-shared-binary? body ptr-id)]
                              [_ false])]
                          [_ false])]
                      [_ false])]
                  [_ false])])]
          (ast.ast-node-pool-context-install! active-before)
          (and shape-ok installed-ok))])))

(define (compiler-ast-generated-key-decl
  [name : String]
  [key : String]
  [body : i64]) : ast.AstDecl
  (ast.ast-decl-comptime-decl-with-meta
    (Some
      "stdlib.clone/synthesize-helpers"
      (string.copy (& name))
      (ast.ast-expr-list-new)
      key)
    (ast.ast-decl-def-id (ci.intern-generated-name (& name)) No body)))

(define (compiler-ast-generated-key-at [decls : ast.AstDeclList] [index : i64]) : String
  (let
    [decl : ast.AstDecl (ast.ast-decl-list-get (& decls) index (Module 0))]
    (match (ast.ast-decl-generated-meta (& decl))
      [(Some _ _ _ key) key]
      [(No) "missing"])))

;; The declarations one macro expansion generates share their identity-key
;; String. Compaction copies that key once and gives all of them the copy; an
;; equal key with its own storage still gets its own copy.
(define (compiler-ast-generated-key-shared-compaction-smoke?) : bool
  (let
    [active-before : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
    [source-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new
        (& (ast.ast-expr-node-pool-state-create 8))
        (& (ast.ast-type-node-pool-state-create 8))
        ;; Smoke-local scratch pool: never installed, caller-arena owned.
        (arena.tl_arena_current))]
    [dest-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new
        (& (ast.ast-expr-node-pool-state-create 8))
        (& (ast.ast-type-node-pool-state-create 8))
        ;; Smoke-local scratch pool: never installed, caller-arena owned.
        (arena.tl_arena_current))]
    [body : i64
      (ast.ast-node-pool-context-expr-push
        source-pools
        (Literal (ast.ast-lit-int 7)))]
    [key : String (string.copy "decls:stdlib.clone/Clone(root-a root-b)")]
    [twin : String (string.copy "decls:stdlib.clone/Clone(root-a root-b)")]
    [program : ast.AstProgram
      (ast.ast-program
        (ast.ast-decl-cons
          (&
            (compiler-ast-generated-key-decl
              "clone-a"
              (owned_view.compiler-owned-shared-view key)
              body))
          (&
            (ast.ast-decl-cons
              (&
                (compiler-ast-generated-key-decl
                  "clone-b"
                  (owned_view.compiler-owned-shared-view key)
                  body))
              (&
                (ast.ast-decl-cons
                  (&
                    (compiler-ast-generated-key-decl
                      "clone-c"
                      (owned_view.compiler-owned-shared-view twin)
                      body))
                  (& (ast.ast-decl-list-new))))))))]
    (match (ast.ast-program-compact-with-pools
      source-pools
      dest-pools
      (& program))
      [(AstProgramCompaction out-program _)
        (match out-program
          [(Program decls-box)
            (let
              [decls : ast.AstDeclList (deref decls-box)]
              [first : String
                (compiler-ast-generated-key-at
                  (owned_view.compiler-owned-shared-view decls)
                  0)]
              [second : String
                (compiler-ast-generated-key-at
                  (owned_view.compiler-owned-shared-view decls)
                  1)]
              [third : String (compiler-ast-generated-key-at decls 2)]
              (ast.ast-node-pool-context-install! active-before)
              (and
                (string.eq first key)
                (string.eq third key)
                (ast.ast-string-same-storage? (& first) (& second))
                (not (ast.ast-string-same-storage? (& first) (& key)))
                (not (ast.ast-string-same-storage? (& first) (& third)))
                (not (ast.ast-string-same-storage? (& third) (& twin)))))])])))

(define (compiler-ast-macro-type-kind-dense-compaction-smoke?) : bool
  (let
    [source : ast.AstMacroTypeKindList
      (ast.ast-macro-type-kind-list-with-length 3)]
    (ast.ast-macro-type-kind-list-set! (&mut source) 0 11)
    (ast.ast-macro-type-kind-list-set! (&mut source) 1 22)
    (ast.ast-macro-type-kind-list-set! (&mut source) 2 33)
    (let
      [copied : ast.AstMacroTypeKindList
        (ast.ast-compaction-copy-macro-type-kind-list (& source))]
      ;; Compaction owns an independent dense allocation, so mutating the
      ;; source after the copy must not alter its ordered constraints.
      (ast.ast-macro-type-kind-list-set! (&mut source) 0 99)
      (and
        (= (ast.ast-macro-type-kind-list-len (& copied)) 3)
        (= (ast.ast-macro-type-kind-list-get (& copied) 0 0) 11)
        (= (ast.ast-macro-type-kind-list-get (& copied) 1 0) 22)
        (= (ast.ast-macro-type-kind-list-get (& copied) 2 0) 33)
        (not (ast.ast-macro-type-kind-list-eq? (& source) (& copied)))))))

(define (compiler-ast-program-copy-append-smoke?) : bool
  (let
    [source-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 4 4)]
    [dest-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 4 4)]
    [_dest-expr : i64
      (ast.ast-node-pool-context-expr-push
        dest-pools
        (Literal (ast.ast-lit-int 111)))]
    [_dest-type : i64 (ast.ast-node-pool-context-type-push dest-pools (Bool))]
    [_source-decoy : i64
      (ast.ast-node-pool-context-expr-push
        source-pools
        (Literal (ast.ast-lit-int 999)))]
    [source-expr : i64
      (ast.ast-node-pool-context-expr-push
        source-pools
        (Literal (ast.ast-lit-int 222)))]
    [source-type : i64 (ast.ast-node-pool-context-type-push source-pools (I64))]
    [appended-name-id : i64 (ci.intern-generated-name "appended")]
    [program : ast.AstProgram
      (ast.ast-program
        (ast.ast-decl-cons
          (&
            (ast.ast-decl-def-id
              appended-name-id
              (Some (Ptr source-type))
              source-expr))
          (& (ast.ast-decl-list-new))))]
    [copied : ast.AstProgramCompaction
      (ast.ast-program-copy-append-with-pools
        source-pools
        dest-pools
        (& program))]
    (match copied
      [(AstProgramCompaction out-program out-pools)
        (and
          (= (ast.ast-node-pool-context-expr-len out-pools) 2)
          (= (ast.ast-node-pool-context-type-len out-pools) 2)
          (compiler-ast-context-expr-int-lit? out-pools 0 111)
          (match out-program
            [(Program decls-box)
              (match (ast.ast-decl-list-step (deref decls-box))
                [(Cons decl rest)
                  (match decl
                    [(Def _ _ maybe-type body)
                      (and
                        (compiler-ast-context-expr-int-lit? out-pools body 222)
                        (match maybe-type
                          [(Some (Ptr inner))
                            (compiler-ast-context-type-i64? out-pools inner)]
                          [_ false])
                        (match (ast.ast-decl-list-step rest)
                          [(Nil) true]
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
    [var-id : i64 (ast.ast-node-pool-context-expr-push source-pools (Var name))]
    [spanned-id : i64
      (ast.ast-node-pool-context-expr-push
        source-pools
        (Spanned var-id (ast.ast-source-span 1 1 1 2)))]
    [borrow-id : i64
      (ast.ast-node-pool-context-expr-push
        source-pools
        (Borrow false (ast.ast-borrow-lifetime-to-id Inferred) spanned-id))]
    [program : ast.AstProgram
      (ast.ast-program
        (ast.ast-decl-cons
          (& (ast.ast-decl-def-id name No borrow-id))
          (& (ast.ast-decl-list-new))))]
    [compacted : ast.AstProgramCompaction
      (ast.ast-program-compact-with-pools source-pools dest-pools (& program))]
    (match compacted
      [(AstProgramCompaction out-program out-pools)
        (match out-program
          [(Program decls-box)
            (match (ast.ast-decl-list-step (deref decls-box))
              [(Cons decl _)
                (match decl
                  [(Def _ _ _ body)
                    (match (ast.ast-node-pool-context-expr-get out-pools body)
                      [(Borrow mutable lifetime-id inner)
                        (and
                          (not mutable)
                          (match (ast.ast-borrow-lifetime-from-id lifetime-id)
                            [(Inferred) true]
                            [_ false])
                          (match (ast.ast-node-pool-context-expr-get
                            out-pools
                            inner)
                            [(Spanned var _)
                              (match (ast.ast-node-pool-context-expr-get
                                out-pools
                                var)
                                [(Var got-name) (= got-name name)]
                                [_ false])]
                            [_ false]))]
                      [_ false])]
                  [_ false])]
              [_ false])])])))

(define (compiler-ast-compaction-string-def-ok?
  [pools : (& pools ast.AstNodePoolContext)]
  [decl : ast.AstDecl]) : bool
  (match decl
    [(Def _ _ maybe-ty value)
      (and
        (match maybe-ty
          [(Some ty)
            (match ty
              [(Ref region inner)
                (and
                  (= region cbi.compiler-builtin-id-fix-value)
                  (match (ast.ast-node-pool-context-type-get pools inner)
                    [(I64) true]
                    [_ false]))]
              [_ false])]
          [_ false])
        (match (ast.ast-node-pool-context-expr-get pools value)
          [(Literal (String string-id))
            (string.eq (ast_tests.ast-lit-string-text string-id) "hello")]
          [_ false]))]
    [_ false]))

(define (compiler-ast-compaction-binary-def-ok?
  [pools : (& pools ast.AstNodePoolContext)]
  [decl : ast.AstDecl]) : bool
  (match decl
    [(Def _ _ (No) value)
      (match (ast.ast-node-pool-context-expr-get pools value)
        [(BinaryData text) (string.eq text "bytes")]
        [_ false])]
    [_ false]))

(define (compiler-ast-compaction-import-ok? [decl : ast.AstDecl]) : bool
  (match decl
    [(Import _ (Spec (Module) path module-name alias _))
      (and
        (string.eq path "pkg.module")
        (match module-name
          [(Some name) (string.eq (ci.intern-str name) "pkg.module")]
          [_ false])
        (match alias
          [(Some name) (string.eq (ci.intern-str name) "pkg")]
          [_ false]))]
    [_ false]))

(define (compiler-ast-compaction-macro-call-ok?
  [pools : (& pools ast.AstNodePoolContext)]
  [call : i64]) : bool
  (match (ast.ast-node-pool-context-expr-get pools call)
    [(Call func args)
      (and
        (match (ast.ast-node-pool-context-expr-get pools func)
          [(Var _) true]
          [_ false])
        (= (ast.ast-expr-list-len (& args)) 1))]
    [_ false]))

(define (compiler-ast-compaction-macro-import-ok?
  [pools : (& pools ast.AstNodePoolContext)]
  [decl : ast.AstDecl]
  [decls-kind? : bool]) : bool
  (match decl
    [(Import _ (Spec kind _ _ _ _))
      (match kind
        [(Macro call _)
          (and
            (not decls-kind?)
            (compiler-ast-compaction-macro-call-ok? pools call))]
        [(MacroDecls call _)
          (and decls-kind? (compiler-ast-compaction-macro-call-ok? pools call))]
        [_ false])]
    [_ false]))

(define (compiler-ast-compaction-extern-ok? [decl : ast.AstDecl]) : bool
  (match decl
    [(Extern _ _ _ metadata _)
      (match (__tl-box-place metadata)
        [(Metadata (C) symbol links flags _)
          (and
            (ast.ast-extern-metadata-flags-explicit-abi? flags)
            (not (ast.ast-extern-metadata-flags-symbol-matches-source? flags))
            (string.eq (ci.intern-id-str symbol) "native_symbol")
            (match (ast.ast-extern-link-input-list-get
              (& links)
              0
              (ast.ast-extern-link-input-fallback))
              [(Lib name) (string.eq name "m")]
              [_ false]))]
        [_ false])]
    [_ false]))

(define (compiler-ast-compaction-dispatch-ok? [decl : ast.AstDecl]) : bool
  (match decl
    [(DefDispatch _ _ variants)
      (match (ast.ast-dispatch-variant-list-get
        (& variants)
        0
        (ast.ast-dispatch-variant-fallback))
        [(Variant (Avx2) name) (string.eq (ci.intern-str name) "fast")]
        [_ false])]
    [_ false]))

(define (compiler-ast-compaction-lifetimes-ok? [decl : ast.AstDecl]) : bool
  (match decl
    [(DefStructLifetimes _ _ lifetimes _ _ _)
      (=
        (ast.ast-lifetime-list-get (& lifetimes) 0 (ast.ast-lifetime-fallback))
        cbi.compiler-builtin-id-fix-n)]
    [_ false]))

(define (compiler-ast-compaction-include-ok? [decl : ast.AstDecl]) : bool
  (match decl
    [(IncludeStr name path)
      (and (string.eq (ci.intern-str name) "inc") (string.eq path "data.txt"))]
    [_ false]))

(define (compiler-ast-program-compaction-string-payloads-smoke?) : bool
  (let
    [include-name-id : i64 (ci.intern-generated-name "inc")]
    [macro-func-name-id : i64 (ci.intern-generated-name "emit")]
    [source-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new
        (& (ast.ast-expr-node-pool-state-create 8))
        (& (ast.ast-type-node-pool-state-create 8))
        ;; Smoke-local scratch pool: never installed, caller-arena owned.
        (arena.tl_arena_current))]
    [dest-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new
        (& (ast.ast-expr-node-pool-state-create 8))
        (& (ast.ast-type-node-pool-state-create 8))
        ;; Smoke-local scratch pool: never installed, caller-arena owned.
        (arena.tl_arena_current))]
    [source-i64-ty : i64
      (ast.ast-node-pool-context-type-push source-pools (I64))]
    [_source-decoy : i64
      (ast.ast-node-pool-context-expr-push
        source-pools
        (Literal (ast.ast-lit-int 999)))]
    [text-expr : i64
      (ast.ast-node-pool-context-expr-push
        source-pools
        (Literal (ast.ast-lit-generated-string "hello")))]
    [binary-expr : i64
      (ast.ast-node-pool-context-expr-push source-pools (BinaryData "bytes"))]
    [macro-func : i64
      (ast.ast-node-pool-context-expr-push
        source-pools
        (Var macro-func-name-id))]
    [macro-call : i64
      (ast.ast-node-pool-context-expr-push
        source-pools
        (Call
          macro-func
          (ast.ast-expr-cons text-expr (& (ast.ast-expr-list-new)))))]
    [links : ast.AstExternLinkInputList
      (let
        [items : ast.AstExternLinkInputList
          (ast.ast-extern-link-input-list-new)]
        (ast.ast-extern-link-input-list-push
          (&mut items)
          (ast.AstExternLinkInput.Lib "m"))
        items)]
    [variants : ast.AstDispatchVariantList
      (let
        [items : ast.AstDispatchVariantList (ast.ast-dispatch-variant-list-new)]
        (ast.ast-dispatch-variant-list-push
          (&mut items)
          (ast.AstDispatchVariant.Variant
            (Avx2)
            (ci.intern-generated-name "fast")))
        items)]
    [lifetimes : ast.AstLifetimeList
      (let
        [items : ast.AstLifetimeList (ast.ast-lifetime-list-new)]
        (ast.ast-lifetime-list-push (&mut items) cbi.compiler-builtin-id-fix-n)
        items)]
    [text-name-id : i64 (ci.intern-generated-name "text")]
    [bin-name-id : i64 (ci.intern-generated-name "bin")]
    [native-name-id : i64 (ci.intern-generated-name "native")]
    [dispatch-name-id : i64 (ci.intern-generated-name "dispatch")]
    [program : ast.AstProgram
      (ast.ast-program
        (ast.ast-decl-cons
          (&
            (ast.ast-decl-def-id
              text-name-id
              (Some (Ref cbi.compiler-builtin-id-fix-value source-i64-ty))
              text-expr))
          (&
            (ast.ast-decl-cons
              (& (ast.ast-decl-def-id bin-name-id No binary-expr))
              (&
                (ast.ast-decl-cons
                  (&
                    (Import
                      (ast.ast-decl-meta-runtime-shared-view)
                      (Spec
                        (Module)
                        "pkg.module"
                        (Some (ci.intern-generated-name "pkg.module"))
                        (Some (ci.intern-generated-name "pkg"))
                        (box (ast.ast-source-span 1 1 1 1)))))
                  (&
                    (ast.ast-decl-cons
                      (&
                        (ast.ast-decl-extern-id
                          native-name-id
                          (Function)
                          (Metadata
                            (C)
                            (ci.intern-id-from-renderable
                              (ci.intern-generated-name "native_symbol"))
                            links
                            (ast.ast-extern-metadata-flags true false)
                            No)
                          (I64)))
                      (&
                        (ast.ast-decl-cons
                          (&
                            (Import
                              (ast.ast-decl-meta-runtime-shared-view)
                              (Spec
                                (Macro macro-call No)
                                ""
                                No
                                No
                                (box (ast.ast-source-span 2 1 2 1)))))
                          (&
                            (ast.ast-decl-cons
                              (&
                                (Import
                                  (ast.ast-decl-meta-runtime-shared-view)
                                  (Spec
                                    (MacroDecls macro-call No)
                                    ""
                                    No
                                    No
                                    (box (ast.ast-source-span 3 1 3 1)))))
                              (&
                                (ast.ast-decl-cons
                                  (&
                                    (ast.ast-decl-def-dispatch-id
                                      dispatch-name-id
                                      variants))
                                  (&
                                    (ast.ast-decl-cons
                                      (&
                                        (DefStructLifetimes
                                          (ast.ast-decl-meta-runtime-shared-view)
                                          0
                                          lifetimes
                                          (Default)
                                          (No)
                                          (ast.ast-field-def-list-new)))
                                      (&
                                        (ast.ast-decl-cons
                                          (&
                                            (IncludeStr
                                              include-name-id
                                              "data.txt"))
                                          (& (ast.ast-decl-list-new))))))))))))))))))))]
    [compacted : ast.AstProgramCompaction
      (ast.ast-program-compact-with-pools source-pools dest-pools (& program))]
    (match compacted
      [(AstProgramCompaction out-program out-pools)
        (match out-program
          [(Program decls-box)
            (let
              [decls : ast.AstDeclList (deref decls-box)]
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
    [(Module name) (string.eq (ci.intern-str name) expected)]
    [_ false]))

(define (compiler-ast-decl-cons-growth-smoke?) : bool
  (let
    [i : i64 15]
    [decls : ast.AstDeclList (ast.ast-decl-list-new)]
    [paths : ast.AstDeclPathList (ast.ast-decl-path-list-new)]
    [modules : ast.AstDeclModuleList (ast.ast-decl-module-list-new)]
    (while (>= i 0)
      (let
        [suffix : String (string.int->string i)]
        [module : String
          (str_cat.str-cat "m" (owned_view.compiler-owned-shared-view suffix))]
        [module-id : i64 (ci.intern-generated-name (& module))]
        [path : String (str_cat.str-cat "p" suffix)]
        (set!
          decls
          (ast.ast-decl-cons (& (ast.ast-decl-module-id module-id)) (& decls)))
        (set! paths (ast.ast-decl-root-path-cons path paths))
        (set!
          modules
          (ast.ast-decl-module-list-prepend-builder-id module-id modules))
        (-= i 1)))
    (let
      [tail : ast.AstDeclList (ast_tests.ast-decl-list-tail decls)]
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
        (string.eq (ast_tests.ast-decl-module-list-get (& modules) 0 "") "m0")
        (string.eq (ast_tests.ast-decl-module-list-get (& modules) 15 "") "m15")))))

(define (compiler-ast-decl-cons-pure-smoke?) : bool
  (let
    [tail-id : i64 (ci.intern-generated-name "tail")]
    [left-id : i64 (ci.intern-generated-name "left")]
    [right-id : i64 (ci.intern-generated-name "right")]
    [tail : ast.AstDeclList
      (ast.ast-decl-cons
        (& (ast.ast-decl-module-id tail-id))
        (& (ast.ast-decl-list-new)))]
    [left : ast.AstDeclList
      (ast.ast-decl-cons (& (ast.ast-decl-module-id left-id)) (& tail))]
    [right : ast.AstDeclList
      (ast.ast-decl-cons (& (ast.ast-decl-module-id right-id)) (& tail))]
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
        (Var -3)
        (ast.ast-source-span 1 1 1 2)))
    (ast.ast-expr-binding-clause-list-push
      (&mut bindings)
      (ast.ast-expr-binding-clause-id
        (ci.intern-syntax-id-from-raw 11)
        false
        0
        101
        (Var -3)
        (ast.ast-source-span 2 1 2 2)))
    (ast.ast-expr-binding-clause-list-push
      (&mut bindings)
      (ast.ast-expr-binding-clause-id
        (ci.intern-syntax-id-from-raw 12)
        false
        0
        102
        (Var -3)
        (ast.ast-source-span 3 1 3 2)))
    (let
      [clause-tail : ast.AstExprClauseList
        (ast_tests.ast-expr-clause-list-tail clauses)]
      [binding-tail : ast.AstExprBindingClauseList
        (ast_tests.ast-expr-binding-clause-list-tail bindings)]
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
        (= first-binding.init 101)))))

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
      (ast.ast-decl-path-list-with-modules
        paths
        (& (ast.ast-decl-module-list-new)))]
    (= (ast.ast-decl-path-list-owner-id (& with-modules) 0 -1) path-id)))

;; Rewriters select an owned AST-pool context while the process-global active
;; pool may hold an unrelated compilation. `ast-node-set!` must update that
;; selected context just like `ast-node-get` and `ast-node-push` do.
(define (compiler-ast-compat-context-set-smoke?) : bool
  (let
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 1 1)]
    (ast.ast-node-pool-compat-context-use! pools)
    (let
      [id : i64 (ast.ast-node-push (Literal (ast.ast-lit-int 7)))]
      (ast.ast-node-set! id (Literal (ast.ast-lit-int 42)))
      (ast.ast-node-pool-compat-context-clear!)
      (and (= id 0) (compiler-ast-context-expr-int-lit? pools id 42)))))

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
      (ast.ast-node-pool-context-expr-push pools (Literal (ast.ast-lit-int 73)))]
    [body : ast.AstExprList (ast.ast-expr-list-new)]
    [_push-child : unit (ast.ast-expr-list-push (&mut body) child)]
    [unsafe-id : i64 (ast.ast-node-pool-context-expr-push pools (Unsafe body))]
    [_restore-home : unit
      (unsafe
        (arena.set! home))]
    [_destroy-source : unit
      (unsafe
        (arena.destroy source))]
    [ok : bool
      (match (ast.ast-node-pool-context-expr-get pools unsafe-id)
        [(Unsafe exprs)
          (let
            [retained-child : i64 (ast.ast-expr-list-get (& exprs) 0 -1)]
            (and
              (= retained-child child)
              (compiler-ast-context-expr-int-lit? pools retained-child 73)))]
        [_ false])]
    (ast.ast-node-pool-context-destroy-storage! pools)
    (unsafe
      (arena.destroy dest))
    ok))

(define (compiler-ast-maybe-span-start-line?
  [value : ast.AstMaybeSourceSpan]
  [line : i64]) : bool
  (match value
    [(Some span) (= (ast.ast-source-span-start-line span) line)]
    [(No) false]))

;; Shallow pool snapshots share the dense span-slot table but retain their own
;; canonical record generation. A slot from a newer generation must be treated
;; as missing rather than indexing beyond the restored record array.
(define (compiler-ast-stale-canonical-span-slot-recovery-smoke?) : bool
  (match (ast.ast-expr-node-pool-state-push
    (ast.ast-expr-node-pool-state-create 1)
    (Literal (ast.ast-lit-int 17)))
    [(AstExprNodePoolPushOk literal-pool literal)
      (ast.ast-expr-span-slot-set-in-bases!
        literal-pool.span-slot-segment-bases
        literal
        65)
      (match (ast.ast-expr-node-pool-state-push
        literal-pool
        (Spanned literal (ast.ast-source-span 7 1 7 3)))
        [(AstExprNodePoolPushOk recovered view)
          (and
            (= view 1)
            (=
              (ast.ast-expr-node-pool-state-canonical-span-count (& recovered))
              1)
            (match (ast.ast-expr-node-pool-state-span-oracle recovered view)
              [(CanonicalMatch) true]
              [_ false]))])]))

;; Canonical provenance is first-write/innermost.  A later wrapper with a
;; different source location gets a sparse per-use ReSpan, while an identical
;; wrapper shares the canonical record.  Truncation retires only suffix-owned
;; records and clears reused slots before the next generation writes them.
(define (compiler-ast-expression-span-sidecar-smoke?) : bool
  (let
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 1 1)]
    [literal : i64
      (ast.ast-node-pool-context-expr-push pools (Literal (ast.ast-lit-int 7)))]
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
    [_reset-suffix : unit (ast.ast-node-pool-context-expr-truncate! pools mark)]
    [reused : i64
      (ast.ast-node-pool-context-expr-push pools (Literal (ast.ast-lit-int 11)))]
    [prefix-ok : bool
      (and
        (= literal 0)
        (= inner-view 1)
        (= same-view 2)
        (= outer-view 3)
        (= later-view 4)
        (= reused later-view)
        (=
          (ast.ast-node-pool-context-expr-source-owner pools literal)
          inner-view)
        (=
          (ast.ast-node-pool-context-expr-source-owner pools same-view)
          inner-view)
        (=
          (ast.ast-node-pool-context-expr-source-owner pools outer-view)
          outer-view)
        (= (ast.ast-node-pool-context-expr-source-owner pools reused) -1)
        (= (ast.ast-node-pool-context-expr-source-owner pools -1) -1)
        (= (ast.ast-node-pool-context-expr-source-owner pools 999999) -1)
        (= (ast.ast-node-pool-context-expr-canonical-span-count pools) 1)
        (= (ast.ast-node-pool-context-expr-respan-count pools) 1)
        (ast.ast-node-pool-context-expr-span-oracle-ok? pools)
        (compiler-ast-maybe-span-start-line?
          (ast_tests.ast-node-pool-context-expr-canonical-span pools outer-view)
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
          [(No) true]
          [_ false])
        (match (ast.ast-node-pool-context-expr-span-oracle pools inner-view)
          [(CanonicalMatch) true]
          [_ false])
        (match (ast.ast-node-pool-context-expr-span-oracle pools outer-view)
          [(ReSpanMatch) true]
          [_ false]))]
    ;; If an exceptional per-use wrapper is rewritten into a semantic node,
    ;; its view becomes the new identity's original provenance.  Keeping the
    ;; negative ReSpan slot would make canonical reads fail after the rewrite.
    (ast.ast-node-pool-context-expr-set!
      pools
      outer-view
      (& (Literal (ast.ast-lit-int 99))))
    (let
      [rewrite-ok : bool
        (and
          (= (ast.ast-node-pool-context-expr-canonical-span-count pools) 2)
          (compiler-ast-maybe-span-start-line?
            (ast_tests.ast-node-pool-context-expr-canonical-span
              pools
              outer-view)
            9)
          (compiler-ast-maybe-span-start-line?
            (ast.ast-node-pool-context-expr-view-span pools outer-view)
            9))]
      (ast.ast-node-pool-context-expr-truncate! pools 0)
      (let
        [new-literal : i64
          (ast.ast-node-pool-context-expr-push
            pools
            (Literal (ast.ast-lit-int 13)))]
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
            (ast_tests.ast-node-pool-context-expr-canonical-span
              pools
              new-literal)
            20))))))

;; The in-place expression-pool path grows both sparse provenance tables. Keep
;; records immediately before and after the initial 64-row boundary readable.
(define (compiler-ast-span-record-growth-smoke?) : bool
  (let
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 1 1)]
    [base-literal : i64 -1]
    [canonical-63 : i64 -1]
    [canonical-64 : i64 -1]
    [respan-63 : i64 -1]
    [respan-64 : i64 -1]
    (for [canonical-index (iterator.range 0 65)]
      (let
        [literal : i64
          (ast.ast-node-pool-context-expr-push
            pools
            (Literal (ast.ast-lit-int canonical-index)))]
        [line : i64 (+ canonical-index 1)]
        [view : i64
          (ast.ast-expr-spanned-with-pools
            pools
            literal
            (ast.ast-source-span line 1 line 2))]
        (if (= canonical-index 0)
          (set! base-literal literal)
          unit)
        (if (= canonical-index 63)
          (set! canonical-63 view)
          unit)
        (if (= canonical-index 64)
          (set! canonical-64 view)
          unit)))
    (for [respan-index (iterator.range 0 65)]
      (let
        [line : i64 (+ respan-index 100)]
        [view : i64
          (ast.ast-expr-spanned-with-pools
            pools
            base-literal
            (ast.ast-source-span line 3 line 4))]
        (if (= respan-index 63)
          (set! respan-63 view)
          unit)
        (if (= respan-index 64)
          (set! respan-64 view)
          unit)))
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
        164))))

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
    [a-last-expr : i64 -1]
    [b-last-expr : i64 -1]
    [a-last-type : i64 -1]
    [b-last-type : i64 -1]
    (for [expr-index (iterator.range 0 (+ 131072 1))]
      (set!
        a-last-expr
        (ast.ast-node-pool-context-expr-push
          a
          (Literal (ast.ast-lit-int expr-index))))
      (if (<= expr-index 65536)
        (set!
          b-last-expr
          (ast.ast-node-pool-context-expr-push
            b
            (Literal (ast.ast-lit-int (- 0 expr-index)))))
        unit))
    (for [type-index (iterator.range 0 (+ 2048 1))]
      (set!
        a-last-type
        (ast.ast-node-pool-context-type-push a (Var type-index)))
      (if (<= type-index 1024)
        (set!
          b-last-type
          (ast.ast-node-pool-context-type-push b (Var (+ type-index 10000))))
        unit))
    (let
      [a-growth-view : i64
        (ast.ast-expr-spanned-with-pools
          a
          a-last-expr
          (ast.ast-source-span 31 1 31 4))]
      [a-dupe-type : i64 (ast.ast-node-pool-context-type-push a (Var 1024))]
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
              (& (ast.ast-node-pool-context-expr-get (& a) a-growth-view)))
            131072)
          (match (ast.ast-node-pool-context-type-get a 1024)
            [(Var name) (= name 1024)]
            [_ false])
          (match (ast.ast-node-pool-context-type-get a 2048)
            [(Var name) (= name 2048)]
            [_ false])
          (match (ast.ast-node-pool-context-type-get b 1024)
            [(Var name) (= name 11024)]
            [_ false])
          (not (= a-base b-base))
          (not
            (=
              (ast.ast-node-pool-context-expr-storage-arena a)
              (ast.ast-node-pool-context-expr-storage-arena b))))]
      (unsafe
        (arena.set! home))
      (ast.ast-node-pool-context-destroy-storage! a)
      (ast.ast-node-pool-context-destroy-storage! b)
      (unsafe
        (arena.tl_arena_destroy a-base)
        (arena.tl_arena_destroy b-base))
      ok)))

(define (compiler-ast-cleanup-syntax-id-round-trip?
  [expected : ci.InternSyntaxId]) : bool
  (and
    (match (ast.AstFieldCleanup.Fn expected)
      [(Fn name) (ci.intern-syntax-id-eq? name expected)]
      [_ false])
    (match (ast.AstStructCleanup.Fn expected)
      [(Fn name) (ci.intern-syntax-id-eq? name expected)]
      [_ false])
    (match (ast.AstEnumCleanup.Fn expected)
      [(Fn name) (ci.intern-syntax-id-eq? name expected)]
      [_ false])
    (match (ast.AstVariantPayloadCleanup.Fn expected)
      [(Fn name) (ci.intern-syntax-id-eq? name expected)]
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
  (match (ast.AstFieldDef.Def expected (I64) No)
    [(Def name _ _) (ci.intern-syntax-id-eq? name expected)]))

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
        (Var -3)
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
    (for [index (iterator.range 0 17)]
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
          (ast.AstExternLinkInput.Search "native"))))
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
        [(Owned) true]
        [_ false])
      (match (ast.ast-variant-payload-cleanup-list-get
        (& cleanup-copy)
        16
        ast.AstVariantPayloadCleanup.Owned)
        [(No) true]
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
        [(Lib value) (string.eq value "m")]
        [_ false])
      (match (ast.ast-extern-link-input-list-get
        (& links)
        17
        (ast.AstExternLinkInput.Arg "fallback"))
        [(Arg value) (string.eq value "fallback")]
        [_ false]))))

(test
  compiler-ast-generated-dense-list-operations
  (tl_test.assert-true
    (compiler-ast-generated-dense-list-operations-smoke?)
    "generated AST dense lists preserve capacity, order, and fallbacks"))

;; Whole-program compaction reserves the destination's canonical span records
;; from the source's record count, so the records are allocated once instead of
;; through doubling copies. These rows build `count` literals, each under one
;; distinct span (line = index + 1), and compact a program that reaches the
;; first `reach` views.
(define (compiler-ast-reserve-source-views
  [pools : ast.AstNodePoolContext]
  [count : i64]
  [first-line : i64]) : ast.AstExprList
  (let
    [views : ast.AstExprList (ast.ast-expr-list-new)]
    (for [index (iterator.range 0 count)]
      (let
        [literal : i64
          (ast.ast-node-pool-context-expr-push
            pools
            (Literal (ast.ast-lit-int index)))]
        [line : i64 (+ first-line index)]
        (ast.ast-expr-list-push
          (&mut views)
          (ast.ast-expr-spanned-with-pools
            (& pools)
            literal
            (ast.ast-source-span line 1 line 2)))))
    views))

(define (compiler-ast-reserve-program
  [pools : ast.AstNodePoolContext]
  [views : (& views ast.AstExprList)]
  [reach : i64]) : ast.AstProgram
  (let
    [body : ast.AstExprList (ast.ast-expr-list-new)]
    (for [index (iterator.range 0 reach)]
      (ast.ast-expr-list-push
        (&mut body)
        (ast.ast-expr-list-get views index -1)))
    (ast.ast-program
      (ast.ast-decl-cons
        (&
          (ast.ast-decl-def-id
            (ci.intern-generated-name "reserve")
            No
            (ast.ast-node-pool-context-expr-push pools (Unsafe body))))
        (& (ast.ast-decl-list-new))))))

;; The compacted views, in program order.
(define (compiler-ast-reserve-compacted-views
  [pools : (& pools ast.AstNodePoolContext)]
  [program : ast.AstProgram]) : ast.AstExprList
  (match program
    [(Program decls-box)
      (match (ast.ast-decl-list-get
        (& (deref decls-box))
        0
        (ast.ast-decl-fallback))
        [(Def _ _ _ body)
          (match (ast.ast-node-pool-context-expr-get pools body)
            [(Unsafe exprs) exprs]
            [_ (ast.ast-expr-list-new)])]
        [_ (ast.ast-expr-list-new)])]))

(define (compiler-ast-canonical-span-capacity
  [pools : (& pools ast.AstNodePoolContext)]) : i64
  (let
    [state : ast.AstExprNodePoolState
      (ast.ast-expr-pool-cell-read pools.expr-pool)]
    (array-length state.canonical-span-records)))

(define (compiler-ast-reserve-view-line?
  [pools : (& pools ast.AstNodePoolContext)]
  [views : (& views ast.AstExprList)]
  [index : i64]
  [line : i64]) : bool
  (compiler-ast-maybe-span-start-line?
    (ast.ast-node-pool-context-expr-view-span
      pools
      (ast.ast-expr-list-get views index -1))
    line))

;; Every view renders its own line, `first-line` onward.
(define (compiler-ast-reserve-views-render?
  [pools : (& pools ast.AstNodePoolContext)]
  [views : (& views ast.AstExprList)]
  [first-line : i64]) : bool
  (let
    [index : i64 0]
    [ok : bool true]
    (while (and ok (< index (ast.ast-expr-list-len views)))
      (set!
        ok
        (compiler-ast-reserve-view-line? pools views index (+ first-line index)))
      (+= index 1))
    ok))

;; `extra` more spanned literals pushed into the destination after compaction
;; exercise the checked growth past the reservation.
(define (compiler-ast-canonical-reserve-row?
  [count : i64]
  [reach : i64]
  [extra : i64]
  [expected-capacity : i64]) : bool
  (let
    [source-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [dest-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [views : ast.AstExprList
      (compiler-ast-reserve-source-views source-pools count 1)]
    [program : ast.AstProgram
      (compiler-ast-reserve-program source-pools (& views) reach)]
    (match (ast.ast-program-compact-with-pools
      source-pools
      dest-pools
      (& program))
      [(AstProgramCompaction out-program out-pools)
        (let
          [out-views : ast.AstExprList
            (compiler-ast-reserve-compacted-views (& out-pools) out-program)]
          [compacted-ok : bool
            (and
              (= (ast.ast-expr-list-len (& out-views)) reach)
              (=
                (ast.ast-node-pool-context-expr-canonical-span-count out-pools)
                reach)
              (= (ast.ast-node-pool-context-expr-respan-count out-pools) 0)
              (compiler-ast-reserve-views-render? (& out-pools) (& out-views) 1))]
          [extra-views : ast.AstExprList
            (compiler-ast-reserve-source-views dest-pools extra (+ reach 1))]
          (and
            compacted-ok
            (=
              (ast.ast-node-pool-context-expr-canonical-span-count dest-pools)
              (+ reach extra))
            (=
              (compiler-ast-canonical-span-capacity (& dest-pools))
              expected-capacity)
            (compiler-ast-reserve-views-render? (& dest-pools) (& out-views) 1)
            (compiler-ast-reserve-views-render?
              (& dest-pools)
              (& extra-views)
              (+ reach 1))))])))

;; Traversal can pick a different first span than the source's canonical one.
;; Here the canonical owner (span 1) is unreachable and view B (span 2) comes
;; first, so the two later span-1 views each need a destination ReSpan: one
;; canonical record and two ReSpans from a source holding one of each, as the
;; unreserved compactor produced. The shared view B is copied once.
(define (compiler-ast-canonical-reserve-reordered-first-span?) : bool
  (let
    [source-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [dest-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [literal : i64
      (ast.ast-node-pool-context-expr-push
        source-pools
        (Literal (ast.ast-lit-int 5)))]
    [span-a : ast.AstSourceSpan (ast.ast-source-span 1 1 1 2)]
    [_unreachable-owner : i64
      (ast.ast-expr-spanned-with-pools source-pools literal span-a)]
    [view-b : i64
      (ast.ast-expr-spanned-with-pools
        source-pools
        literal
        (ast.ast-source-span 2 1 2 2))]
    [view-a1 : i64
      (ast.ast-expr-spanned-with-pools source-pools literal span-a)]
    [view-a2 : i64
      (ast.ast-expr-spanned-with-pools source-pools literal span-a)]
    [views : ast.AstExprList (ast.ast-expr-list-new)]
    [_views : unit
      (begin
        (ast.ast-expr-list-push (&mut views) view-b)
        (ast.ast-expr-list-push (&mut views) view-a1)
        (ast.ast-expr-list-push (&mut views) view-a2)
        (ast.ast-expr-list-push (&mut views) view-b))]
    [source-counts-ok : bool
      (and
        (= (ast.ast-node-pool-context-expr-canonical-span-count source-pools) 1)
        (= (ast.ast-node-pool-context-expr-respan-count source-pools) 1))]
    [program : ast.AstProgram
      (compiler-ast-reserve-program source-pools (& views) 4)]
    (match (ast.ast-program-compact-with-pools
      source-pools
      dest-pools
      (& program))
      [(AstProgramCompaction out-program out-pools)
        (let
          [out : ast.AstExprList
            (compiler-ast-reserve-compacted-views (& out-pools) out-program)]
          (and
            source-counts-ok
            (=
              (ast.ast-node-pool-context-expr-canonical-span-count out-pools)
              1)
            (= (ast.ast-node-pool-context-expr-respan-count out-pools) 2)
            (=
              (ast.ast-expr-list-get (& out) 0 -1)
              (ast.ast-expr-list-get (& out) 3 -2))
            (compiler-ast-reserve-view-line? (& out-pools) (& out) 0 2)
            (compiler-ast-reserve-view-line? (& out-pools) (& out) 1 1)
            (compiler-ast-reserve-view-line? (& out-pools) (& out) 2 1)
            (ast.ast-node-pool-context-expr-span-oracle-ok? out-pools)
            (= (compiler-ast-canonical-span-capacity (& out-pools)) 64)))])))

;; A destination reused for a second, smaller compaction keeps the larger
;; reservation, and the first generation's dense slots must not leak into the
;; second. The source lives in its own arena and is destroyed before the
;; destination is read: the reserved records belong to the destination.
(define (compiler-ast-canonical-reserve-reuse-and-owners?) : bool
  (let
    [home : arena.Arena (arena.current)]
    [dest : arena.Arena (arena.make)]
    [dest-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities-in-arena
        8
        8
        (arena.raw-handle dest))]
    [first-ok : bool
      (let
        [source-pools : ast.AstNodePoolContext
          (ast.ast-node-pool-context-new-with-capacities 8 8)]
        [views : ast.AstExprList
          (compiler-ast-reserve-source-views source-pools 150 1)]
        [program : ast.AstProgram
          (compiler-ast-reserve-program source-pools (& views) 150)]
        (match (ast.ast-program-compact-with-pools
          source-pools
          dest-pools
          (& program))
          [(AstProgramCompaction _ out-pools)
            (and
              (=
                (ast.ast-node-pool-context-expr-canonical-span-count out-pools)
                150)
              (= (compiler-ast-canonical-span-capacity (& out-pools)) 150))]))]
    [source : arena.Arena (arena.make)]
    [source-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities-in-arena
        8
        8
        (arena.raw-handle source))]
    [views : ast.AstExprList
      (compiler-ast-reserve-source-views source-pools 70 1000)]
    [program : ast.AstProgram
      (compiler-ast-reserve-program source-pools (& views) 70)]
    [compacted : ast.AstProgramCompaction
      (ast.ast-program-compact-with-pools source-pools dest-pools (& program))]
    [_destroy-source : unit
      (begin
        (ast.ast-node-pool-context-destroy-storage! source-pools)
        (unsafe
          (arena.destroy source)))]
    [ok : bool
      (match compacted
        [(AstProgramCompaction out-program out-pools)
          (let
            [out : ast.AstExprList
              (compiler-ast-reserve-compacted-views (& out-pools) out-program)]
            (and
              first-ok
              (= (ast.ast-expr-list-len (& out)) 70)
              (=
                (ast.ast-node-pool-context-expr-canonical-span-count out-pools)
                70)
              (= (compiler-ast-canonical-span-capacity (& out-pools)) 150)
              (compiler-ast-reserve-views-render? (& out-pools) (& out) 1000)
              (ast.ast-node-pool-context-expr-span-oracle-ok? out-pools)))])]
    (unsafe
      (arena.set! home))
    (ast.ast-node-pool-context-destroy-storage! dest-pools)
    (unsafe
      (arena.destroy dest))
    ok))

(define (compiler-ast-canonical-reserve-smoke?) : bool
  (and
    ;; count reach extra capacity: no records keep the initial 64 rows; 64
    ;; fit them; 65 and 200 are reserved once where doubling gave 128 and
    ;; 256; an unreachable tail reserves at most the source count; growth past
    ;; the reservation doubles it.
    (compiler-ast-canonical-reserve-row? 0 0 0 64)
    (compiler-ast-canonical-reserve-row? 64 64 0 64)
    (compiler-ast-canonical-reserve-row? 65 65 0 65)
    (compiler-ast-canonical-reserve-row? 200 200 0 200)
    (compiler-ast-canonical-reserve-row? 200 3 0 200)
    (compiler-ast-canonical-reserve-row? 65 65 1 130)
    (compiler-ast-canonical-reserve-reordered-first-span?)
    (compiler-ast-canonical-reserve-reuse-and-owners?)))

(test
  compiler-ast-canonical-reserve
  (tl_test.assert-true
    (compiler-ast-canonical-reserve-smoke?)
    "compaction reserves canonical span records once and keeps growth checked"))

(define (main) : i64
  (unless (= (ast_tests.compiler-ast-smoke) 23) (return 2))
  (unless (compiler-ast-int-literal-source-bits-smoke?) (return 18))
  (unless (compiler-ast-state-owned-node-pools-smoke?) (return 3))
  (unless (compiler-ast-active-context-sync-smoke?) (return 4))
  (unless (compiler-ast-context-dedup-half-load-smoke?) (return 28))
  (unless (compiler-ast-context-dedup-max-capacity-smoke?) (return 29))
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
  (unless (compiler-ast-stale-canonical-span-slot-recovery-smoke?) (return 20))
  (unless (compiler-ast-expression-span-sidecar-smoke?) (return 19))
  (unless (compiler-ast-span-record-growth-smoke?) (return 22))
  (unless (compiler-ast-segmented-growth-isolation-smoke?) (return 15))
  (unless (compiler-ast-macro-type-kind-dense-compaction-smoke?) (return 16))
  (unless (compiler-ast-generated-key-shared-compaction-smoke?) (return 26))
  (unless (compiler-ast-cleanup-syntax-identity-smoke?) (return 20))
  (unless (compiler-ast-field-syntax-identity-smoke?) (return 21))
  (unless (compiler-ast-expr-binding-clause-syntax-identity-smoke?) (return 23))
  (unless (compiler-ast-generated-dense-list-operations-smoke?) (return 25))
  (unless (compiler-ast-canonical-reserve-smoke?) (return 27))
  42)