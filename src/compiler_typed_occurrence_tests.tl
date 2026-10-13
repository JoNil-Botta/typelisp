;; Transaction tests for producer plumbing, not source ownership acceptance.
(import compiler_typed_occurrence as typed)
(import compiler_ownership_core as own)
(import compiler_ast_types as ast)
(import compiler_intern as ci)
(import compiler_symbols as symbols)
(import stdlib.test)
(import stdlib.io)
(import stdlib.string)

(define (typed-test-body [owner : u64]) : own.OwnershipBodyId
  (own.OwnershipBodyId owner (cast 4294967303 : u64) (cast 4294967311 : u64)))

(define (typed-test-lease
  [intern-state : (& intern-state ci.InternCompatState)]
  [owner : u64]) : (typed.TypedBodyLease intern-state)
  (let
    [_seed : i64 (ast.ast-node-push (ast.AstExpr.Literal (ast.ast-lit-int 42)))]
    (typed.TypedBodyLease
      (typed-test-body owner)
      (ast.ast-node-pool-context-capture-active)
      intern-state
      (typed-test-body (cast 4294967321 : u64))
      16
      (typed.typed-resolution-unavailable intern-state)
      true)))

(define (typed-test-limits) : typed.TypedLimits
  (typed.TypedLimits 32 64 8 1000000))

(define (typed-test-resolution-lease
  [state : (& context ci.InternCompatState)]
  [declarations : (& context symbols.CompilerSymbols)]
  [registries : (& context symbols.CompilerRegistries)]
  [owner : u64]) : (typed.TypedBodyLease context)
  (let
    [lease : (typed.TypedBodyLease context) (typed-test-lease state owner)]
    (set!
      lease.resolution-authority
      (typed.TypedResolutionAuthority.Symbols
        (symbols.compiler-resolution-lease-capture declarations registries)))
    lease))

(define (typed-test-store [lease : (& lease (typed.TypedBodyLease intern))]) : typed.TypedStore
  (match (typed.typed-store-new lease (typed-test-limits))
    [(typed.TypedStoreResult.Ok store) store]
    [(typed.TypedStoreResult.Err _)
      (io.panic "typed occurrence: fixture store")]))

(define (typed-test-type!
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [type : ast.AstType]) : typed.TypedTypeId
  (match (typed.typed-type-add! store lease type)
    [(typed.TypedTypeIdResult.Ok id) id]
    [(typed.TypedTypeIdResult.Err _)
      (io.panic "typed occurrence: fixture type")]))

(define (typed-test-origin!
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]) : typed.TypedOriginId
  (match (typed.typed-origin-add!
    store
    lease
    (own.OwnershipSource "fixture.tl" 7 11 "macro expansion"))
    [(typed.TypedOriginResult.Ok id) id]
    [(typed.TypedOriginResult.Err _)
      (io.panic "typed occurrence: fixture origin")]))

(define (typed-test-literal!
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [type : typed.TypedTypeId]
  [origin : typed.TypedOriginId]
  [syntax : typed.TypedSyntax]
  [value : i64]) : typed.TypedOccurrenceId
  (let
    [children : (__tl_dyn-array typed.TypedOccurrenceId)
      (__tl_make-array typed.TypedOccurrenceId 0)]
    (match (typed.typed-occurrence-add!
      store
      lease
      type
      syntax
      origin
      (typed.TypedOperation.Literal (ast.ast-lit-int value))
      (& children))
      [(typed.TypedOccurrenceResult.Ok id) id]
      [(typed.TypedOccurrenceResult.Err _)
        (io.panic "typed occurrence: fixture literal")])))

(define (typed-test-attempt!
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [mode : typed.TypedMode]) : typed.TypedAttemptId
  (match (typed.typed-attempt-begin! store lease mode)
    [(typed.TypedAttemptResult.Ok id) id]
    [(typed.TypedAttemptResult.Err _)
      (io.panic "typed occurrence: fixture attempt")]))

(define (typed-test-finish!
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [attempt : typed.TypedAttemptId]
  [commit? : bool]) : unit
  (match (typed.typed-attempt-finish! store lease attempt commit?)
    [(typed.TypedResult.Ok _) unit]
    [(typed.TypedResult.Err _) (io.panic "typed occurrence: fixture finish")]))

(define (typed-test-node-type?
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [id : typed.TypedOccurrenceId]
  [expected : typed.TypedTypeId]
  [value : i64]) : bool
  (match (typed.typed-occurrence-get! store lease id)
    [(typed.TypedNodeResult.Ok node)
      (and
        (= node.type.handle.index expected.handle.index)
        (= node.type.handle.serial expected.handle.serial)
        (match (& node.operation)
          [(typed.TypedOperation.Literal literal)
            (match literal
              [(ast.AstLiteral.Int actual _) (= actual value)]
              [_ false])]
          [_ false]))]
    [(typed.TypedNodeResult.Err _) false]))

(define (typed-test-child?
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [parent : typed.TypedOccurrenceId]
  [index : i64]
  [expected : typed.TypedOccurrenceId]) : bool
  (match (typed.typed-child-get! store lease parent index)
    [(typed.TypedChildResult.Ok child)
      (and
        (= child.handle.index expected.handle.index)
        (= child.handle.serial expected.handle.serial))]
    [(typed.TypedChildResult.Err _) false]))

(define (typed-test-children2
  [first : typed.TypedOccurrenceId]
  [second : typed.TypedOccurrenceId]) : (__tl_dyn-array typed.TypedOccurrenceId)
  (let
    [items : (__tl_dyn-array typed.TypedOccurrenceId)
      (__tl_make-array typed.TypedOccurrenceId 2)]
    (set! (array-ref items 0) first)
    (set! (array-ref items 1) second)
    items))

(define (typed-test-stale-node?
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [id : typed.TypedOccurrenceId]) : bool
  (match (typed.typed-occurrence-get! store lease id)
    [(typed.TypedNodeResult.Err error)
      (match error
        [(typed.TypedError.Stale) true]
        [_ false])]
    [_ false]))

(define (typed-test-unknown-type?
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [id : typed.TypedTypeId]) : bool
  (match (typed.typed-type-get! store lease id)
    [(typed.TypedTypeResult.Err error)
      (match error
        [(typed.TypedError.Unknown) true]
        [_ false])]
    [_ false]))

(define (typed-test-i32?
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [id : typed.TypedTypeId]) : bool
  (match (typed.typed-type-get! store lease id)
    [(typed.TypedTypeResult.Ok type)
      (match type
        [(ast.AstType.I32) true]
        [_ false])]
    [(typed.TypedTypeResult.Err _) false]))

(define (typed-test-selected-occurrences?) : bool
  (let
    [intern-state : ci.InternCompatState
      (ci.intern-compat-state-capture-active)]
    [lease : (typed.TypedBodyLease intern-state)
      (typed-test-lease (& intern-state) (cast 4294967357 : u64))]
    [store : typed.TypedStore (typed-test-store (& lease))]
    [origin : typed.TypedOriginId (typed-test-origin! (&mut store) (& lease))]
    [narrow : typed.TypedTypeId
      (typed-test-type! (&mut store) (& lease) ast.AstType.I32)]
    [wide : typed.TypedTypeId
      (typed-test-type! (&mut store) (& lease) ast.AstType.I64)]
    [first : typed.TypedOccurrenceId
      (typed-test-literal!
        (&mut store)
        (& lease)
        narrow
        origin
        (typed.TypedSyntax.Source 0)
        42)]
    [second : typed.TypedOccurrenceId
      (typed-test-literal!
        (&mut store)
        (& lease)
        wide
        origin
        (typed.TypedSyntax.Source 0)
        42)]
    [generated : typed.TypedOccurrenceId
      (typed-test-literal!
        (&mut store)
        (& lease)
        wide
        origin
        typed.TypedSyntax.Generated
        99)]
    [children : (__tl_dyn-array typed.TypedOccurrenceId)
      (__tl_make-array second generated first)]
    [parent : typed.TypedOccurrenceId
      (match (typed.typed-occurrence-add!
        (&mut store)
        (& lease)
        wide
        typed.TypedSyntax.Generated
        origin
        typed.TypedOperation.Sequence
        (& children))
        [(typed.TypedOccurrenceResult.Ok id) id]
        [(typed.TypedOccurrenceResult.Err _)
          (io.panic "typed occurrence: selected parent")])]
    (and
      (not (= first.handle.serial second.handle.serial))
      (typed-test-node-type? (&mut store) (& lease) first narrow 42)
      (typed-test-node-type? (&mut store) (& lease) second wide 42)
      (typed-test-node-type? (&mut store) (& lease) generated wide 99)
      (typed-test-child? (&mut store) (& lease) parent 0 second)
      (typed-test-child? (&mut store) (& lease) parent 1 generated)
      (typed-test-child? (&mut store) (& lease) parent 2 first)
      (typed-test-i32? (&mut store) (& lease) narrow)
      (match (typed.typed-child-get! (&mut store) (& lease) parent 3)
        [(typed.TypedChildResult.Err error)
          (match error
            [(typed.TypedError.Unknown) true]
            [_ false])]
        [_ false]))))

(define (typed-test-rollback?) : bool
  (let
    [intern-state : ci.InternCompatState
      (ci.intern-compat-state-capture-active)]
    [lease : (typed.TypedBodyLease intern-state)
      (typed-test-lease (& intern-state) (cast 19 : u64))]
    [store : typed.TypedStore (typed-test-store (& lease))]
    [origin : typed.TypedOriginId (typed-test-origin! (&mut store) (& lease))]
    [type : typed.TypedTypeId
      (typed-test-type! (&mut store) (& lease) ast.AstType.I64)]
    [kept : typed.TypedOccurrenceId
      (typed-test-literal!
        (&mut store)
        (& lease)
        type
        origin
        typed.TypedSyntax.Generated
        1)]
    [outer : typed.TypedAttemptId
      (typed-test-attempt! (&mut store) (& lease) typed.TypedMode.Executable)]
    [child : typed.TypedOccurrenceId
      (typed-test-literal!
        (&mut store)
        (& lease)
        type
        origin
        typed.TypedSyntax.Generated
        2)]
    [inner : typed.TypedAttemptId
      (typed-test-attempt! (&mut store) (& lease) typed.TypedMode.Executable)]
    [discarded-type : typed.TypedTypeId
      (typed-test-type! (&mut store) (& lease) ast.AstType.Bool)]
    [discarded-origin : typed.TypedOriginId
      (typed-test-origin! (&mut store) (& lease))]
    [descendant : typed.TypedOccurrenceId
      (typed-test-literal!
        (&mut store)
        (& lease)
        type
        discarded-origin
        typed.TypedSyntax.Generated
        3)]
    [children : (__tl_dyn-array typed.TypedOccurrenceId)
      (typed-test-children2 child descendant)]
    [ordered-rejection : bool
      (match (typed.typed-attempt-finish! (&mut store) (& lease) outer false)
        [(typed.TypedResult.Err error)
          (match error
            [(typed.TypedError.Order) true]
            [_ false])]
        [_ false])]
    [_inner : unit (typed-test-finish! (&mut store) (& lease) inner true)]
    [failed-parent : bool
      (match (typed.typed-occurrence-add!
        (&mut store)
        (& lease)
        type
        typed.TypedSyntax.Generated
        origin
        typed.TypedOperation.If
        (& children))
        [(typed.TypedOccurrenceResult.Err error)
          (match error
            [(typed.TypedError.Shape) true]
            [_ false])]
        [_ false])]
    [before-work : i64 store.work]
    [_outer : unit (typed-test-finish! (&mut store) (& lease) outer false)]
    [replacement-type : typed.TypedTypeId
      (typed-test-type! (&mut store) (& lease) ast.AstType.I32)]
    [replacement-origin : typed.TypedOriginId
      (typed-test-origin! (&mut store) (& lease))]
    [replacement : typed.TypedOccurrenceId
      (typed-test-literal!
        (&mut store)
        (& lease)
        type
        replacement-origin
        typed.TypedSyntax.Generated
        4)]
    [retry : typed.TypedAttemptId
      (typed-test-attempt! (&mut store) (& lease) typed.TypedMode.Executable)]
    [stale-token : bool
      (match (typed.typed-attempt-finish! (&mut store) (& lease) outer false)
        [(typed.TypedResult.Err error)
          (match error
            [(typed.TypedError.Stale) true]
            [_ false])]
        [_ false])]
    [_retry : unit (typed-test-finish! (&mut store) (& lease) retry true)]
    (and
      ordered-rejection
      failed-parent
      stale-token
      (> store.work before-work)
      (= child.handle.index replacement.handle.index)
      (not (= child.handle.serial replacement.handle.serial))
      (= discarded-type.handle.index replacement-type.handle.index)
      (not (= discarded-type.handle.serial replacement-type.handle.serial))
      (= discarded-origin.handle.index replacement-origin.handle.index)
      (typed-test-node-type? (&mut store) (& lease) kept type 1)
      (typed-test-node-type? (&mut store) (& lease) replacement type 4)
      (typed-test-stale-node? (&mut store) (& lease) child)
      (typed-test-stale-node? (&mut store) (& lease) descendant)
      (typed-test-unknown-type? (&mut store) (& lease) discarded-type)
      (match (typed.typed-occurrence-add!
        (&mut store)
        (& lease)
        type
        typed.TypedSyntax.Generated
        discarded-origin
        typed.TypedOperation.Sequence
        (& children))
        [(typed.TypedOccurrenceResult.Err error)
          (match error
            [(typed.TypedError.Stale) true]
            [_ false])]
        [_ false]))))

(define (typed-test-query-and-budget?) : bool
  (let
    [intern-state : ci.InternCompatState
      (ci.intern-compat-state-capture-active)]
    [lease : (typed.TypedBodyLease intern-state)
      (typed-test-lease (& intern-state) (cast 23 : u64))]
    [store : typed.TypedStore (typed-test-store (& lease))]
    [origin : typed.TypedOriginId (typed-test-origin! (&mut store) (& lease))]
    [type : typed.TypedTypeId
      (typed-test-type! (&mut store) (& lease) ast.AstType.I64)]
    [literal : typed.TypedOccurrenceId
      (typed-test-literal!
        (&mut store)
        (& lease)
        type
        origin
        typed.TypedSyntax.Generated
        42)]
    [query : typed.TypedAttemptId
      (typed-test-attempt! (&mut store) (& lease) typed.TypedMode.Query)]
    [nested : typed.TypedAttemptId
      (typed-test-attempt! (&mut store) (& lease) typed.TypedMode.Query)]
    [empty : (__tl_dyn-array typed.TypedOccurrenceId)
      (__tl_make-array typed.TypedOccurrenceId 0)]
    [rejected : bool
      (and
        (match (typed.typed-occurrence-add!
          (&mut store)
          (& lease)
          type
          typed.TypedSyntax.Generated
          origin
          (typed.TypedOperation.Literal (ast.ast-lit-int 7))
          (& empty))
          [(typed.TypedOccurrenceResult.Err error)
            (match error
              [(typed.TypedError.Query) true]
              [_ false])]
          [_ false])
        (match (typed.typed-type-add! (&mut store) (& lease) ast.AstType.Bool)
          [(typed.TypedTypeIdResult.Err error)
            (match error
              [(typed.TypedError.Query) true]
              [_ false])]
          [_ false])
        (match (typed.typed-attempt-begin!
          (&mut store)
          (& lease)
          typed.TypedMode.Executable)
          [(typed.TypedAttemptResult.Err error)
            (match error
              [(typed.TypedError.Query) true]
              [_ false])]
          [_ false])
        (typed-test-node-type? (&mut store) (& lease) literal type 42))]
    [_nested : unit (typed-test-finish! (&mut store) (& lease) nested true)]
    [_query : unit (typed-test-finish! (&mut store) (& lease) query false)]
    [before : i64 store.work]
    [_limit : unit (set! store.limits.work (+ before 6))]
    [first : typed.TypedAttemptId
      (typed-test-attempt! (&mut store) (& lease) typed.TypedMode.Executable)]
    [_first : unit (typed-test-finish! (&mut store) (& lease) first false)]
    [second : typed.TypedAttemptId
      (typed-test-attempt! (&mut store) (& lease) typed.TypedMode.Executable)]
    [_second : unit (typed-test-finish! (&mut store) (& lease) second false)]
    (and
      rejected
      (= store.work (+ before 6))
      (match (typed.typed-attempt-begin!
        (&mut store)
        (& lease)
        typed.TypedMode.Executable)
        [(typed.TypedAttemptResult.Err error)
          (match error
            [(typed.TypedError.Budget) true]
            [_ false])]
        [_ false])
      (match (typed.typed-store-new
        (& lease)
        (typed.TypedLimits 65536 1048576 65536 1))
        [(typed.TypedStoreResult.Err error)
          (match error
            [(typed.TypedError.Budget) true]
            [_ false])]
        [_ false]))))

(define (typed-test-leases?) : bool
  (let
    [intern-state : ci.InternCompatState
      (ci.intern-compat-state-capture-active)]
    [lease : (typed.TypedBodyLease intern-state)
      (typed-test-lease (& intern-state) (cast 29 : u64))]
    [store : typed.TypedStore (typed-test-store (& lease))]
    [origin : typed.TypedOriginId (typed-test-origin! (&mut store) (& lease))]
    [type : typed.TypedTypeId
      (typed-test-type! (&mut store) (& lease) ast.AstType.I64)]
    [literal : typed.TypedOccurrenceId
      (typed-test-literal!
        (&mut store)
        (& lease)
        type
        origin
        typed.TypedSyntax.Generated
        42)]
    [saved-expr-pool : u64 lease.pools.expr-pool]
    [foreign : typed.TypedOccurrenceId
      (typed.TypedOccurrenceId
        (typed.TypedHandle
          (typed-test-body (cast 4294967325 : u64))
          literal.handle.index
          literal.handle.serial))]
    [foreign-handle : bool
      (match (typed.typed-occurrence-get! (&mut store) (& lease) foreign)
        [(typed.TypedNodeResult.Err error)
          (match error
            [(typed.TypedError.Stale) true]
            [_ false])]
        [_ false])]
    [_revision : unit
      (set! lease.body.revision (+ lease.body.revision (cast 1 : u64)))]
    ;; Deliberately invalidate the pool pointer too: rejecting the lease must
    ;; happen before any canonical pool, type payload, or origin is accessed.
    [_pool : unit (set! lease.pools.expr-pool (cast 1 : u64))]
    [stale-lease : bool
      (match (typed.typed-type-get! (&mut store) (& lease) type)
        [(typed.TypedTypeResult.Err error)
          (match error
            [(typed.TypedError.Lease) true]
            [_ false])]
        [_ false])]
    [_retire : unit (typed.typed-store-retire! (&mut store))]
    [_restore : unit
      (set! lease.body.revision (- lease.body.revision (cast 1 : u64)))]
    [_restore-pool : unit (set! lease.pools.expr-pool saved-expr-pool)]
    [retired : bool
      (match (typed.typed-occurrence-get! (&mut store) (& lease) literal)
        [(typed.TypedNodeResult.Err error)
          (match error
            [(typed.TypedError.Lease) true]
            [_ false])]
        [_ false])]
    (and foreign-handle stale-lease retired)))

(define (typed-test-resource-terminal?) : bool
  (let
    [intern-state : ci.InternCompatState
      (ci.intern-compat-state-capture-active)]
    [lease : (typed.TypedBodyLease intern-state)
      (typed-test-lease (& intern-state) (cast 47 : u64))]
    [store : typed.TypedStore (typed-test-store (& lease))]
    [attempt : typed.TypedAttemptId
      (typed-test-attempt! (&mut store) (& lease) typed.TypedMode.Executable)]
    [_limit : unit (set! store.limits.work (+ store.work 1))]
    [expensive : bool
      (match (typed.typed-origin-add!
        (&mut store)
        (& lease)
        (own.OwnershipSource "too expensive" 1 1 ""))
        [(typed.TypedOriginResult.Err error)
          (match error
            [(typed.TypedError.Budget) true]
            [_ false])]
        [_ false])]
    [_raise : unit (set! store.limits.work (+ store.work 1000))]
    [no-resume : bool
      (match (typed.typed-type-add! (&mut store) (& lease) ast.AstType.I64)
        [(typed.TypedTypeIdResult.Err error)
          (match error
            [(typed.TypedError.Budget) true]
            [_ false])]
        [_ false])]
    [no-refund : bool
      (match (typed.typed-attempt-finish! (&mut store) (& lease) attempt false)
        [(typed.TypedResult.Err error)
          (match error
            [(typed.TypedError.Budget) true]
            [_ false])]
        [_ false])]
    [_retire : unit (typed.typed-store-retire! (&mut store))]
    [revoked : bool
      (match (typed.typed-type-add! (&mut store) (& lease) ast.AstType.I64)
        [(typed.TypedTypeIdResult.Err error)
          (match error
            [(typed.TypedError.Lease) true]
            [_ false])]
        [_ false])]
    [other-lease : (typed.TypedBodyLease intern-state)
      (typed-test-lease (& intern-state) (cast 53 : u64))]
    [other : typed.TypedStore (typed-test-store (& other-lease))]
    [_exhaust : unit (set! other.next-serial (cast 18446744073709551615 : u64))]
    [exhausted : bool
      (match (typed.typed-type-add!
        (&mut other)
        (& other-lease)
        ast.AstType.I64)
        [(typed.TypedTypeIdResult.Err error)
          (match error
            [(typed.TypedError.Exhausted) true]
            [_ false])]
        [_ false])]
    [_reuse : unit (set! other.next-serial (cast 1 : u64))]
    [no-wrap : bool
      (match (typed.typed-attempt-begin!
        (&mut other)
        (& other-lease)
        typed.TypedMode.Executable)
        [(typed.TypedAttemptResult.Err error)
          (match error
            [(typed.TypedError.Exhausted) true]
            [_ false])]
        [_ false])]
    (and
      expensive
      no-resume
      no-refund
      revoked
      exhausted
      no-wrap
      (= store.origin-count 0)
      (= store.attempt-count 1))))

(define (typed-test-global [index : i64]) : typed.TypedResolvedGlobal
  (typed.TypedResolvedGlobal
    (cast 4294967321 : u64)
    (cast 4294967303 : u64)
    (cast 4294967311 : u64)
    index))

(define (typed-test-binder!
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [type : typed.TypedTypeId]
  [kind : typed.TypedBinderKind]
  [origin : typed.TypedOriginId]) : typed.TypedBinderId
  (match (typed.typed-binder-add! store lease type kind origin -1)
    [(typed.TypedBinderResult.Ok id) id]
    [_ (io.panic "typed occurrence: fixture binder")]))

(define (typed-test-operation!
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [type : typed.TypedTypeId]
  [origin : typed.TypedOriginId]
  [operation : typed.TypedOperation]
  [children : (& children (__tl_dyn-array typed.TypedOccurrenceId))]) : typed.TypedOccurrenceId
  (match (typed.typed-occurrence-add!
    store
    lease
    type
    typed.TypedSyntax.Generated
    origin
    operation
    children)
    [(typed.TypedOccurrenceResult.Ok id) id]
    [_ (io.panic "typed occurrence: fixture operation")]))

(define (typed-test-stale-binder?
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [id : typed.TypedBinderId]) : bool
  (match (typed.typed-binder-get! store lease id)
    [(typed.TypedBinderView.Err error)
      (match error
        [(typed.TypedError.Stale) true]
        [_ false])]
    [_ false]))

(define (typed-test-stale-projection?
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [id : typed.TypedProjectionId]) : bool
  (match (typed.typed-projection-get! store lease id)
    [(typed.TypedProjectionView.Err error)
      (match error
        [(typed.TypedError.Stale) true]
        [_ false])]
    [_ false]))

(define (typed-test-stale-call?
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [id : typed.TypedCallId]) : bool
  (match (typed.typed-call-get! store lease id)
    [(typed.TypedCallView.Err error)
      (match error
        [(typed.TypedError.Stale) true]
        [_ false])]
    [_ false]))

(define (typed-test-resolved-identities?) : bool
  (let
    [intern-state : ci.InternCompatState
      (ci.intern-compat-state-capture-active)]
    [declarations : symbols.CompilerSymbols
      (symbols.compiler-symbols-empty-with-decls 16)]
    [registries : symbols.CompilerRegistries
      (symbols.compiler-registries-empty)]
    [lease : (typed.TypedBodyLease registries)
      (typed-test-resolution-lease
        (& intern-state)
        (& declarations)
        (& registries)
        (cast 37 : u64))]
    [store : typed.TypedStore (typed-test-store (& lease))]
    [origin : typed.TypedOriginId (typed-test-origin! (&mut store) (& lease))]
    [type : typed.TypedTypeId
      (typed-test-type! (&mut store) (& lease) ast.AstType.I64)]
    [unit-type : typed.TypedTypeId
      (typed-test-type! (&mut store) (& lease) ast.AstType.Unit)]
    [array-type : typed.TypedTypeId
      (typed-test-type!
        (&mut store)
        (& lease)
        (ast.ast-ty-array (& (ast.AstType.I64)) 2))]
    [params : ast.AstTypeList (ast.ast-type-list-new)]
    [_param : unit
      (ast.ast-type-list-push
        (&mut params)
        (ast.ty-node-push (& (ast.AstType.I64))))]
    [signature : typed.TypedTypeId
      (typed-test-type!
        (&mut store)
        (& lease)
        (ast.ast-ty-func params (& (ast.AstType.I64))))]
    [local : typed.TypedBinderId
      (typed-test-binder!
        (&mut store)
        (& lease)
        type
        typed.TypedBinderKind.Local
        origin)]
    [array-local : typed.TypedBinderId
      (typed-test-binder!
        (&mut store)
        (& lease)
        array-type
        typed.TypedBinderKind.Parameter
        origin)]
    [global : typed.TypedBinderId
      (typed-test-binder!
        (&mut store)
        (& lease)
        signature
        (typed.TypedBinderKind.Global (typed-test-global 3))
        origin)]
    [attempt : typed.TypedAttemptId
      (typed-test-attempt! (&mut store) (& lease) typed.TypedMode.Executable)]
    [temporary : typed.TypedBinderId
      (typed-test-binder!
        (&mut store)
        (& lease)
        type
        typed.TypedBinderKind.Local
        origin)]
    [projection : typed.TypedProjectionId
      (match (typed.typed-projection-add!
        (&mut store)
        (& lease)
        array-type
        type
        (typed.TypedProjectionKind.FixedArrayElement 1)
        origin)
        [(typed.TypedProjectionResult.Ok id) id]
        [_ (io.panic "typed occurrence: fixture projection")])]
    [call : typed.TypedCallId
      (match (typed.typed-call-add!
        (&mut store)
        (& lease)
        signature
        (typed.TypedCallKind.Direct (typed-test-global 3))
        1)
        [(typed.TypedCallResult.Ok id) id]
        [_ (io.panic "typed occurrence: fixture call")])]
    [empty : (__tl_dyn-array typed.TypedOccurrenceId)
      (__tl_make-array typed.TypedOccurrenceId 0)]
    [value : typed.TypedOccurrenceId
      (typed-test-literal!
        (&mut store)
        (& lease)
        type
        origin
        typed.TypedSyntax.Generated
        42)]
    [single : (__tl_dyn-array typed.TypedOccurrenceId) (__tl_make-array value)]
    [assignment : typed.TypedOccurrenceId
      (typed-test-operation!
        (&mut store)
        (& lease)
        unit-type
        origin
        (typed.TypedOperation.Assign local)
        (& single))]
    [target : typed.TypedOccurrenceId
      (typed-test-operation!
        (&mut store)
        (& lease)
        signature
        origin
        (typed.TypedOperation.Read global)
        (& empty))]
    [callee-children : (__tl_dyn-array typed.TypedOccurrenceId)
      (typed-test-children2 assignment target)]
    [callee : typed.TypedOccurrenceId
      (typed-test-operation!
        (&mut store)
        (& lease)
        signature
        origin
        typed.TypedOperation.Sequence
        (& callee-children))]
    [call-children : (__tl_dyn-array typed.TypedOccurrenceId)
      (typed-test-children2 callee value)]
    [called : typed.TypedOccurrenceId
      (typed-test-operation!
        (&mut store)
        (& lease)
        type
        origin
        (typed.TypedOperation.Call call)
        (& call-children))]
    [receiver : typed.TypedOccurrenceId
      (typed-test-operation!
        (&mut store)
        (& lease)
        array-type
        origin
        (typed.TypedOperation.Read array-local)
        (& empty))]
    [receiver-child : (__tl_dyn-array typed.TypedOccurrenceId)
      (__tl_make-array receiver)]
    [projected : typed.TypedOccurrenceId
      (typed-test-operation!
        (&mut store)
        (& lease)
        type
        origin
        (typed.TypedOperation.Project projection)
        (& receiver-child))]
    [preserved : bool
      (and
        (typed-test-child? (&mut store) (& lease) called 0 callee)
        (typed-test-child? (&mut store) (& lease) called 1 value)
        (typed-test-child? (&mut store) (& lease) callee 0 assignment)
        (typed-test-child? (&mut store) (& lease) projected 0 receiver)
        (match (typed.typed-occurrence-add!
          (&mut store)
          (& lease)
          type
          typed.TypedSyntax.Generated
          origin
          (typed.TypedOperation.Call call)
          (& single))
          [(typed.TypedOccurrenceResult.Err error)
            (match error
              [(typed.TypedError.Shape) true]
              [_ false])]
          [_ false]))]
    [_abort : unit (typed-test-finish! (&mut store) (& lease) attempt false)]
    [replacement : typed.TypedBinderId
      (typed-test-binder!
        (&mut store)
        (& lease)
        type
        typed.TypedBinderKind.Local
        origin)]
    [reused-projection : bool
      (match (typed.typed-projection-add!
        (&mut store)
        (& lease)
        array-type
        type
        (typed.TypedProjectionKind.FixedArrayElement 0)
        origin)
        [(typed.TypedProjectionResult.Ok id)
          (= id.handle.index projection.handle.index)]
        [_ false])]
    [reused-call : bool
      (match (typed.typed-call-add!
        (&mut store)
        (& lease)
        signature
        typed.TypedCallKind.Indirect
        1)
        [(typed.TypedCallResult.Ok id) (= id.handle.index call.handle.index)]
        [_ false])]
    (and
      preserved
      reused-projection
      reused-call
      (= temporary.handle.index replacement.handle.index)
      (typed-test-stale-binder? (&mut store) (& lease) temporary)
      (typed-test-stale-projection? (&mut store) (& lease) projection)
      (typed-test-stale-call? (&mut store) (& lease) call)
      (match (typed.typed-binder-add!
        (&mut store)
        (& lease)
        type
        (typed.TypedBinderKind.Global (typed-test-global 16))
        origin
        -1)
        [(typed.TypedBinderResult.Err error)
          (match error
            [(typed.TypedError.Unknown) true]
            [_ false])]
        [_ false])
      (match (typed.typed-call-add!
        (&mut store)
        (& lease)
        type
        typed.TypedCallKind.Indirect
        0)
        [(typed.TypedCallResult.Err error)
          (match error
            [(typed.TypedError.Shape) true]
            [_ false])]
        [_ false]))))

(defstruct TypedInternFixture
  (store typed.TypedStore)
  (type typed.TypedTypeId)
  (literal typed.TypedOccurrenceId))

(define (typed-test-call-arity?) : bool
  (let
    [intern-state : ci.InternCompatState
      (ci.intern-compat-state-capture-active)]
    [declarations : symbols.CompilerSymbols
      (symbols.compiler-symbols-empty-with-decls 16)]
    [registries : symbols.CompilerRegistries
      (symbols.compiler-registries-empty)]
    [lease : (typed.TypedBodyLease registries)
      (typed-test-resolution-lease
        (& intern-state)
        (& declarations)
        (& registries)
        (cast 59 : u64))]
    [store : typed.TypedStore (typed-test-store (& lease))]
    [pools : ast.AstNodePoolContext
      (ast.AstNodePoolContext
        lease.pools.expr-pool
        lease.pools.type-pool
        lease.pools.owner-arena)]
    [function-id : i64
      (ast.ast-node-pool-context-type-push
        pools
        (ast.ast-ty-func (ast.ast-type-list-new) (& (ast.AstType.I64))))]
    [c-function : typed.TypedTypeId
      (typed-test-type!
        (&mut store)
        (& lease)
        (ast.AstType.CFunc function-id ast.AstCFunctionMode.NonNull))]
    [function : typed.TypedTypeId
      (typed-test-type!
        (&mut store)
        (& lease)
        (ast.ast-ty-func (ast.ast-type-list-new) (& (ast.AstType.I64))))]
    [unknown : typed.TypedTypeId
      (typed-test-type!
        (&mut store)
        (& lease)
        (ast.AstType.CFunc 9223372036854775807 ast.AstCFunctionMode.NonNull))]
    (and
      (match (typed.typed-call-add!
        (&mut store)
        (& lease)
        c-function
        typed.TypedCallKind.Indirect
        0)
        [(typed.TypedCallResult.Ok _) true]
        [_ false])
      (match (typed.typed-call-add!
        (&mut store)
        (& lease)
        c-function
        typed.TypedCallKind.Indirect
        1)
        [(typed.TypedCallResult.Err error)
          (match error
            [(typed.TypedError.Shape) true]
            [_ false])]
        [_ false])
      (match (typed.typed-call-add!
        (&mut store)
        (& lease)
        function
        (typed.TypedCallKind.Direct (typed-test-global 1))
        0)
        [(typed.TypedCallResult.Ok _) true]
        [_ false])
      (match (typed.typed-call-add!
        (&mut store)
        (& lease)
        function
        (typed.TypedCallKind.Direct (typed-test-global 1))
        1)
        [(typed.TypedCallResult.Err error)
          (match error
            [(typed.TypedError.Shape) true]
            [_ false])]
        [_ false])
      (match (typed.typed-call-add!
        (&mut store)
        (& lease)
        unknown
        typed.TypedCallKind.Indirect
        0)
        [(typed.TypedCallResult.Err error)
          (match error
            [(typed.TypedError.Shape) true]
            [_ false])]
        [_ false]))))

(define (typed-test-string-fixture
  [state : (& state ci.InternCompatState)]
  [pools : ast.AstNodePoolContext]
  [string-id : i64]) : TypedInternFixture
  (let
    [lease : (typed.TypedBodyLease state)
      (typed.TypedBodyLease
        (typed-test-body (cast 41 : u64))
        pools
        state
        (typed-test-body (cast 4294967321 : u64))
        16
        (typed.typed-resolution-unavailable state)
        true)]
    [store : typed.TypedStore (typed-test-store (& lease))]
    [origin : typed.TypedOriginId (typed-test-origin! (&mut store) (& lease))]
    [type : typed.TypedTypeId
      (typed-test-type! (&mut store) (& lease) ast.AstType.String)]
    [children : (__tl_dyn-array typed.TypedOccurrenceId)
      (__tl_make-array typed.TypedOccurrenceId 0)]
    [literal : typed.TypedOccurrenceId
      (typed-test-operation!
        (&mut store)
        (& lease)
        type
        origin
        (typed.TypedOperation.Literal (ast.AstLiteral.String string-id))
        (& children))]
    (TypedInternFixture store type literal)))

(define (typed-test-explicit-string?
  [fixture : (&mut fixture TypedInternFixture)]
  [state : (& state ci.InternCompatState)]
  [pools : ast.AstNodePoolContext]) : bool
  (let
    [lease : (typed.TypedBodyLease state)
      (typed.TypedBodyLease
        (typed-test-body (cast 41 : u64))
        pools
        state
        (typed-test-body (cast 4294967321 : u64))
        16
        (typed.typed-resolution-unavailable state)
        true)]
    [id : typed.TypedOccurrenceId
      (typed.TypedOccurrenceId
        (typed.typed-handle-copy (& fixture.literal.handle)))]
    (match (typed.typed-occurrence-get! (&mut fixture.store) (& lease) id)
      [(typed.TypedNodeResult.Ok node)
        (match (& node.operation)
          [(typed.TypedOperation.Literal literal)
            (match literal
              [(ast.AstLiteral.String id)
                (string.eq (ci.intern-compat-state-str state id) "owner-a")]
              [_ false])]
          [_ false])]
      [(typed.TypedNodeResult.Err _) false])))

(define (typed-test-reset-interner?
  [fixture : (&mut fixture TypedInternFixture)]
  [state : (& state ci.InternCompatState)]
  [pools : ast.AstNodePoolContext]) : bool
  (let
    [lease : (typed.TypedBodyLease state)
      (typed.TypedBodyLease
        (typed-test-body (cast 41 : u64))
        pools
        state
        (typed-test-body (cast 4294967321 : u64))
        16
        (typed.typed-resolution-unavailable state)
        true)]
    [id : typed.TypedTypeId
      (typed.TypedTypeId (typed.typed-handle-copy (& fixture.type.handle)))]
    (match (typed.typed-type-get! (&mut fixture.store) (& lease) id)
      [(typed.TypedTypeResult.Err error)
        (match error
          [(typed.TypedError.Lease) true]
          [_ false])]
      [_ false])))

(define (typed-test-interner?) : bool
  (let
    [saved : ci.InternCompatState (ci.intern-compat-state-capture-active)]
    [state-a : ci.InternCompatState (ci.intern-compat-state-new)]
    [state-b : ci.InternCompatState (ci.intern-compat-state-new)]
    [id-a : i64 (ci.intern-compat-state-intern (&mut state-a) "owner-a")]
    [id-b : i64 (ci.intern-compat-state-intern (&mut state-b) "owner-b")]
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [fixture : TypedInternFixture
      (typed-test-string-fixture (& state-a) pools id-a)]
    [_install : unit (ci.intern-compat-state-install! (& state-b))]
    [unrelated : bool
      (and
        (= id-a id-b)
        (typed-test-explicit-string? (&mut fixture) (& state-a) pools))]
    [foreign : bool
      (typed-test-reset-interner? (&mut fixture) (& state-b) pools)]
    [_reset : unit (ci.intern-compat-state-reset! (&mut state-a))]
    [_replacement : i64
      (ci.intern-compat-state-intern (&mut state-a) "replacement")]
    [stale : bool (typed-test-reset-interner? (&mut fixture) (& state-a) pools)]
    [_restore : unit (ci.intern-compat-state-install! (& saved))]
    (and unrelated foreign stale)))

(define (typed-test-growing?) : bool
  (let
    [intern-state : ci.InternCompatState
      (ci.intern-compat-state-capture-active)]
    [lease : (typed.TypedBodyLease intern-state)
      (typed-test-lease (& intern-state) (cast 71 : u64))]
    [limits : typed.TypedLimits (typed.TypedLimits 128 256 64 1000000)]
    [store : typed.TypedStore
      (match (typed.typed-store-new-growing (& lease) limits)
        [(typed.TypedStoreResult.Ok value) value]
        [_ (io.panic "typed occurrence: growing store")])]
    [initial-small : bool
      (and
        (= (array-length store.types) 16)
        (= (array-length store.children) 16)
        (= (array-length store.attempts) 16)
        (< store.work (typed.typed-setup-work (& limits))))]
    [type : typed.TypedTypeId
      (typed-test-type! (&mut store) (& lease) ast.AstType.I64)]
    [origin : typed.TypedOriginId (typed-test-origin! (&mut store) (& lease))]
    [first : typed.TypedOccurrenceId
      (typed-test-literal!
        (&mut store)
        (& lease)
        type
        origin
        typed.TypedSyntax.Generated
        42)]
    [outer : typed.TypedAttemptId
      (typed-test-attempt! (&mut store) (& lease) typed.TypedMode.Executable)]
    [discarded : typed.TypedOccurrenceId
      (typed-test-literal!
        (&mut store)
        (& lease)
        type
        origin
        typed.TypedSyntax.Generated
        99)]
    [attempts : (__tl_dyn-array typed.TypedAttemptId)
      (__tl_make-array typed.TypedAttemptId 40)]
    [children : (__tl_dyn-array typed.TypedOccurrenceId)
      (__tl_make-array typed.TypedOccurrenceId 40)]
    [index : i64 0]
    [ok : bool initial-small]
    (while (< index 40)
      (set!
        (array-ref attempts index)
        (typed-test-attempt! (&mut store) (& lease) typed.TypedMode.Executable))
      (let
        [child-type : typed.TypedTypeId
          (typed-test-type! (&mut store) (& lease) ast.AstType.I64)]
        [child-origin : typed.TypedOriginId
          (typed-test-origin! (&mut store) (& lease))]
        (set!
          (array-ref children index)
          (typed-test-literal!
            (&mut store)
            (& lease)
            child-type
            child-origin
            typed.TypedSyntax.Generated
            index)))
      (set! index (+ index 1)))
    (let
      [sequence : typed.TypedOccurrenceId
        (match (typed.typed-occurrence-add!
          (&mut store)
          (& lease)
          type
          typed.TypedSyntax.Generated
          origin
          typed.TypedOperation.Sequence
          (& children))
          [(typed.TypedOccurrenceResult.Ok id) id]
          [_ (io.panic "typed occurrence: growing sequence")])]
      (set!
        ok
        (and
          ok
          (= store.type-count 41)
          (= store.origin-count 41)
          (= (array-length store.types) 64)
          (= (array-length store.attempts) 64)
          (= (array-length store.children) 64)
          (typed-test-node-type? (&mut store) (& lease) first type 42)))
      (while (> index 0)
        (set! index (- index 1))
        (typed-test-finish!
          (&mut store)
          (& lease)
          (array-ref attempts index)
          true))
      (let
        [charged : i64 store.work]
        (typed-test-finish! (&mut store) (& lease) outer false)
        (set!
          ok
          (and
            ok
            (> store.work charged)
            (= store.occurrence-count 1)
            (= store.type-count 1)
            (= store.origin-count 1)
            (= store.child-count 0)
            (= (array-length store.types) 64)))
        (let
          [replacement : typed.TypedOccurrenceId
            (typed-test-literal!
              (&mut store)
              (& lease)
              type
              origin
              typed.TypedSyntax.Generated
              7)]
          [stale : bool
            (match (typed.typed-occurrence-get!
              (&mut store)
              (& lease)
              discarded)
              [(typed.TypedNodeResult.Err _) true]
              [_ false])]
          [stale-parent : bool
            (match (typed.typed-occurrence-get! (&mut store) (& lease) sequence)
              [(typed.TypedNodeResult.Err _) true]
              [_ false])]
          (set!
            ok
            (and
              ok
              stale
              stale-parent
              (typed-test-node-type? (&mut store) (& lease) replacement type 7)))))
      ;; Refusal must happen before allocation or moving existing rows.
      (set! store.limits.work (+ store.work 1))
      (let
        [refused : bool
          (match (typed.typed-reserve-records! (&mut store) (& lease) 65)
            [(typed.TypedResult.Err error)
              (match error
                [(typed.TypedError.Budget) true]
                [_ false])]
            [_ false])]
        (set!
          ok
          (and ok refused store.failed? (= (array-length store.types) 64)))
        (typed.typed-store-retire! (&mut store))
        ok))))

(define (typed-test-child-shape-error?
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [parent : typed.TypedOccurrenceId]) : bool
  (match (typed.typed-child-get! store lease parent 0)
    [(typed.TypedChildResult.Err error)
      (match error
        [(typed.TypedError.Shape) true]
        [_ false])]
    [_ false]))

(define (typed-test-malformed-storage?) : bool
  (let
    [intern-state : ci.InternCompatState
      (ci.intern-compat-state-capture-active)]
    [lease : (typed.TypedBodyLease intern-state)
      (typed-test-lease (& intern-state) (cast 79 : u64))]
    [store : typed.TypedStore (typed-test-store (& lease))]
    [type : typed.TypedTypeId
      (typed-test-type! (&mut store) (& lease) ast.AstType.I64)]
    [origin : typed.TypedOriginId (typed-test-origin! (&mut store) (& lease))]
    [child : typed.TypedOccurrenceId
      (typed-test-literal!
        (&mut store)
        (& lease)
        type
        origin
        typed.TypedSyntax.Generated
        42)]
    [children : (__tl_dyn-array typed.TypedOccurrenceId)
      (__tl_make-array typed.TypedOccurrenceId 1)]
    [_child : unit (set! (array-ref children 0) child)]
    [parent : typed.TypedOccurrenceId
      (match (typed.typed-occurrence-add!
        (&mut store)
        (& lease)
        type
        typed.TypedSyntax.Generated
        origin
        typed.TypedOperation.Sequence
        (& children))
        [(typed.TypedOccurrenceResult.Ok id) id]
        [_ (io.panic "typed occurrence: malformed-storage fixture")])]
    [_negative : unit
      (set! (array-ref store.occurrences parent.handle.index).child-start -1)]
    [negative : bool
      (typed-test-child-shape-error? (&mut store) (& lease) parent)]
    [_overflow : unit
      (set!
        (array-ref store.occurrences parent.handle.index).child-start
        9223372036854775807)]
    [overflow : bool
      (typed-test-child-shape-error? (&mut store) (& lease) parent)]
    [_start : unit
      (set! (array-ref store.occurrences parent.handle.index).child-start 0)]
    [_count : unit
      (set!
        (array-ref store.occurrences parent.handle.index).child-count
        9223372036854775807)]
    [overrun : bool
      (typed-test-child-shape-error? (&mut store) (& lease) parent)]
    [_restore : unit
      (set! (array-ref store.occurrences parent.handle.index).child-count 1)]
    [_table : unit (set! store.type-count (+ (array-length store.types) 1))]
    [bad-table : bool
      (match (typed.typed-type-get! (&mut store) (& lease) type)
        [(typed.TypedTypeResult.Err error)
          (match error
            [(typed.TypedError.Shape) true]
            [_ false])]
        [_ false])]
    [_types : unit (set! store.type-count 1)]
    [_edges : unit (set! store.child-count (+ (array-length store.children) 1))]
    [bad-edges : bool
      (typed-test-child-shape-error? (&mut store) (& lease) parent)]
    [_edge-restore : unit (set! store.child-count 1)]
    [valid : bool
      (match (typed.typed-child-get! (&mut store) (& lease) parent 0)
        [(typed.TypedChildResult.Ok id)
          (= id.handle.serial child.handle.serial)]
        [_ false])]
    [_work : unit (set! store.work -1)]
    [bad-work : bool
      (match (typed.typed-type-get! (&mut store) (& lease) type)
        [(typed.TypedTypeResult.Err error)
          (match error
            [(typed.TypedError.Shape) true]
            [_ false])]
        [_ false])]
    (typed.typed-store-retire! (&mut store))
    (and negative overflow overrun bad-table bad-edges valid bad-work)))

(define (typed-test-place!
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [kind : typed.TypedPlaceKind]) : typed.TypedPlaceId
  (match (typed.typed-place-add! store lease kind)
    [(typed.TypedPlaceResult.Ok id) id]
    [_ (io.panic "typed place: fixture path")]))

(define (typed-test-place-node!
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [type : typed.TypedTypeId]
  [origin : typed.TypedOriginId]
  [operation : typed.TypedOperation]
  [children : (& children (__tl_dyn-array typed.TypedOccurrenceId))]) : typed.TypedOccurrenceId
  (match (typed.typed-occurrence-add!
    store
    lease
    type
    typed.TypedSyntax.Generated
    origin
    operation
    children)
    [(typed.TypedOccurrenceResult.Ok id) id]
    [_ (io.panic "typed place: fixture occurrence")]))

(define (typed-test-places?) : bool
  (let
    [intern-state : ci.InternCompatState
      (ci.intern-compat-state-capture-active)]
    [lease : (typed.TypedBodyLease intern-state)
      (typed-test-lease (& intern-state) (cast 4294967991 : u64))]
    [store : typed.TypedStore
      (match (typed.typed-store-new-growing (& lease) (typed-test-limits))
        [(typed.TypedStoreResult.Ok value) value]
        [_ (io.panic "typed place: growing store")])]
    [origin : typed.TypedOriginId (typed-test-origin! (&mut store) (& lease))]
    [scalar : typed.TypedTypeId
      (typed-test-type! (&mut store) (& lease) ast.AstType.I64)]
    [row : typed.TypedTypeId
      (typed-test-type!
        (&mut store)
        (& lease)
        (ast.ast-ty-array (& (ast.AstType.I64)) 2))]
    [matrix : typed.TypedTypeId
      (typed-test-type!
        (&mut store)
        (& lease)
        (ast.ast-ty-array (& (ast.ast-ty-array (& (ast.AstType.I64)) 2)) 2))]
    [binder : typed.TypedBinderId
      (match (typed.typed-binder-add!
        (&mut store)
        (& lease)
        matrix
        typed.TypedBinderKind.Local
        origin
        -1)
        [(typed.TypedBinderResult.Ok id) id]
        [_ (io.panic "typed place: fixture binder")])]
    [first-projection : typed.TypedProjectionId
      (match (typed.typed-projection-add!
        (&mut store)
        (& lease)
        matrix
        row
        typed.TypedProjectionKind.ArrayElement
        origin)
        [(typed.TypedProjectionResult.Ok id) id]
        [_ (io.panic "typed place: first projection")])]
    [second-projection : typed.TypedProjectionId
      (match (typed.typed-projection-add!
        (&mut store)
        (& lease)
        row
        scalar
        typed.TypedProjectionKind.ArrayElement
        origin)
        [(typed.TypedProjectionResult.Ok id) id]
        [_ (io.panic "typed place: second projection")])]
    [root : typed.TypedPlaceId
      (typed-test-place!
        (&mut store)
        (& lease)
        (typed.TypedPlaceKind.Root binder))]
    [middle : typed.TypedPlaceId
      (typed-test-place!
        (&mut store)
        (& lease)
        (typed.TypedPlaceKind.Projection root first-projection))]
    [place : typed.TypedPlaceId
      (typed-test-place!
        (&mut store)
        (& lease)
        (typed.TypedPlaceKind.Projection middle second-projection))]
    [first : typed.TypedOccurrenceId
      (typed-test-literal!
        (&mut store)
        (& lease)
        scalar
        origin
        typed.TypedSyntax.Generated
        0)]
    [second : typed.TypedOccurrenceId
      (typed-test-literal!
        (&mut store)
        (& lease)
        scalar
        origin
        typed.TypedSyntax.Generated
        1)]
    [indices : (__tl_dyn-array typed.TypedOccurrenceId)
      (typed-test-children2 first second)]
    [formation : typed.TypedOccurrenceId
      (typed-test-place-node!
        (&mut store)
        (& lease)
        scalar
        origin
        (typed.TypedOperation.FormPlace place)
        (& indices))]
    [formed : (__tl_dyn-array typed.TypedOccurrenceId)
      (__tl_make-array formation)]
    [copied : typed.TypedOccurrenceId
      (typed-test-place-node!
        (&mut store)
        (& lease)
        scalar
        origin
        (typed.TypedOperation.CopyPlace place)
        (& formed))]
    [moved : typed.TypedOccurrenceId
      (typed-test-place-node!
        (&mut store)
        (& lease)
        scalar
        origin
        (typed.TypedOperation.MovePlace place)
        (& formed))]
    [formation-category : bool
      (match (typed.typed-occurrence-get! (&mut store) (& lease) formation)
        [(typed.TypedNodeResult.Ok node)
          (match (& node.category)
            [(typed.TypedOccurrenceCategory.Place id)
              (typed.typed-handle-equal? (& id.handle) (& place.handle))]
            [_ false])]
        [_ false])]
    [value-category : bool
      (match (typed.typed-occurrence-get! (&mut store) (& lease) copied)
        [(typed.TypedNodeResult.Ok node)
          (match (& node.category)
            [(typed.TypedOccurrenceCategory.Value) true]
            [_ false])]
        [_ false])]
    [order : bool
      (and
        (typed-test-child? (&mut store) (& lease) formation 0 first)
        (typed-test-child? (&mut store) (& lease) formation 1 second)
        (typed-test-child? (&mut store) (& lease) moved 0 formation))]
    [bad-value : bool
      (match (typed.typed-occurrence-add!
        (&mut store)
        (& lease)
        scalar
        typed.TypedSyntax.Generated
        origin
        (typed.TypedOperation.Unary ast.AstUnOp.Neg)
        (& formed))
        [(typed.TypedOccurrenceResult.Err error)
          (match error
            [(typed.TypedError.Shape) true]
            [_ false])]
        [_ false])]
    [bad-acquisition : bool
      (match (typed.typed-occurrence-add!
        (&mut store)
        (& lease)
        row
        typed.TypedSyntax.Generated
        origin
        (typed.TypedOperation.CopyPlace middle)
        (& formed))
        [(typed.TypedOccurrenceResult.Err error)
          (match error
            [(typed.TypedError.Shape) true]
            [_ false])]
        [_ false])]
    [bad-result-type : bool
      (match (typed.typed-occurrence-add!
        (&mut store)
        (& lease)
        row
        typed.TypedSyntax.Generated
        origin
        (typed.TypedOperation.CopyPlace place)
        (& formed))
        [(typed.TypedOccurrenceResult.Err error)
          (match error
            [(typed.TypedError.Shape) true]
            [_ false])]
        [_ false])]
    [bad-arity : bool
      (match (typed.typed-occurrence-add!
        (&mut store)
        (& lease)
        scalar
        typed.TypedSyntax.Generated
        origin
        (typed.TypedOperation.FormPlace place)
        (& formed))
        [(typed.TypedOccurrenceResult.Err error)
          (match error
            [(typed.TypedError.Shape) true]
            [_ false])]
        [_ false])]
    [bad-container : bool
      (match (typed.typed-place-add!
        (&mut store)
        (& lease)
        (typed.TypedPlaceKind.Projection root second-projection))
        [(typed.TypedPlaceResult.Err error)
          (match error
            [(typed.TypedError.Shape) true]
            [_ false])]
        [_ false])]
    [before : i64 store.work]
    [outer : typed.TypedAttemptId
      (typed-test-attempt! (&mut store) (& lease) typed.TypedMode.Executable)]
    [discarded : typed.TypedPlaceId
      (typed-test-place!
        (&mut store)
        (& lease)
        (typed.TypedPlaceKind.Root binder))]
    [inner : typed.TypedAttemptId
      (typed-test-attempt! (&mut store) (& lease) typed.TypedMode.Executable)]
    [discarded-child : typed.TypedPlaceId
      (typed-test-place!
        (&mut store)
        (& lease)
        (typed.TypedPlaceKind.Projection discarded first-projection))]
    [_rollback : unit
      (begin
        (typed-test-finish! (&mut store) (& lease) inner true)
        (typed-test-finish! (&mut store) (& lease) outer false))]
    [replacement : typed.TypedPlaceId
      (typed-test-place!
        (&mut store)
        (& lease)
        (typed.TypedPlaceKind.Root binder))]
    [stale : bool
      (match (typed.typed-place-get! (&mut store) (& lease) discarded)
        [(typed.TypedPlaceView.Err error)
          (match error
            [(typed.TypedError.Stale) true]
            [_ false])]
        [_ false])]
    [stale-child : bool
      (match (typed.typed-place-get! (&mut store) (& lease) discarded-child)
        [(typed.TypedPlaceView.Err error)
          (match error
            [(typed.TypedError.Stale) true]
            [_ false])]
        [_ false])]
    [foreign : typed.TypedPlaceId
      (typed.TypedPlaceId (typed.typed-handle-copy (& place.handle)))]
    [_foreign : unit
      (set!
        foreign.handle.body.owner
        (+ foreign.handle.body.owner (cast 1 : u64)))]
    [wrong-owner : bool
      (match (typed.typed-place-get! (&mut store) (& lease) foreign)
        [(typed.TypedPlaceView.Err error)
          (match error
            [(typed.TypedError.Stale) true]
            [_ false])]
        [_ false])]
    [query : typed.TypedAttemptId
      (typed-test-attempt! (&mut store) (& lease) typed.TypedMode.Query)]
    [query-refused : bool
      (match (typed.typed-place-add!
        (&mut store)
        (& lease)
        (typed.TypedPlaceKind.Root binder))
        [(typed.TypedPlaceResult.Err error)
          (match error
            [(typed.TypedError.Query) true]
            [_ false])]
        [_ false])]
    [_query : unit (typed-test-finish! (&mut store) (& lease) query false)]
    [_category : unit
      (set!
        (array-ref store.occurrences first.handle.index).category
        (typed.TypedOccurrenceCategory.Place place))]
    [forged-category : bool
      (match (typed.typed-occurrence-get! (&mut store) (& lease) first)
        [(typed.TypedNodeResult.Err error)
          (match error
            [(typed.TypedError.Shape) true]
            [_ false])]
        [_ false])]
    [_category-restore : unit
      (set!
        (array-ref store.occurrences first.handle.index).category
        typed.TypedOccurrenceCategory.Value)]
    [_origin-forge : unit
      (set!
        (array-ref store.projections first-projection.handle.index).origin.handle.serial
        (+ origin.handle.serial (cast 1 : u64)))]
    [forged-origin : bool
      (match (typed.typed-projection-get!
        (&mut store)
        (& lease)
        first-projection)
        [(typed.TypedProjectionView.Err error)
          (match error
            [(typed.TypedError.Stale) true]
            [_ false])]
        [_ false])]
    [_origin-restore : unit
      (set!
        (array-ref store.projections first-projection.handle.index).origin.handle.serial
        origin.handle.serial)]
    [_malform : unit
      (set!
        (array-ref store.places place.handle.index).kind
        (typed.TypedPlaceKind.Projection place second-projection))]
    [cycle : bool
      (match (typed.typed-place-get! (&mut store) (& lease) place)
        [(typed.TypedPlaceView.Err error)
          (match error
            [(typed.TypedError.Shape) true]
            [_ false])]
        [_ false])]
    (typed.typed-store-retire! (&mut store))
    (and
      formation-category
      value-category
      order
      bad-value
      bad-acquisition
      bad-result-type
      bad-arity
      bad-container
      stale
      stale-child
      wrong-owner
      query-refused
      forged-origin
      cycle
      (= store.place-count 4)
      forged-category
      (= discarded.handle.index replacement.handle.index)
      (< discarded.handle.serial replacement.handle.serial)
      (> store.work before))))

(define (typed-test-resolver-revisions?) : bool
  (let
    [map : symbols.CompilerSymbolMap
      (symbols.compiler-symbol-map-with-capacity 4)]
    [_insert : unit (symbols.compiler-symbol-map-put! (&mut map) 1 10)]
    [stamp : symbols.CompilerSymbolMapRevision
      (symbols.compiler-symbol-map-revision (& map))]
    [read-only : bool
      (and
        (= (symbols.compiler-symbol-map-lookup-handle-id (& map) 1) 10)
        (symbols.compiler-symbol-map-revision-current? (& map) (& stamp)))]
    [_replace : unit (symbols.compiler-symbol-map-put! (&mut map) 1 20)]
    [replacement : bool
      (and
        (= map.len 1)
        (not (symbols.compiler-symbol-map-revision-current? (& map) (& stamp))))]
    [other : symbols.CompilerSymbolMap
      (symbols.compiler-symbol-map-with-capacity 4)]
    [current : symbols.CompilerSymbolMapRevision
      (symbols.compiler-symbol-map-revision (& map))]
    [wrong-owner : bool
      (not
        (symbols.compiler-symbol-map-revision-current? (& other) (& current)))]
    [_exhaust : unit
      (set! (deref map.revision) (cast 18446744073709551615 : u64))]
    [last : symbols.CompilerSymbolMapRevision
      (symbols.compiler-symbol-map-revision (& map))]
    [_bump : unit (symbols.compiler-symbol-map-mutated! (&mut map))]
    [exhaustion : bool
      (and
        (= (deref map.revision) (cast 0 : u64))
        (not (symbols.compiler-symbol-map-revision-current? (& map) (& last))))]
    [state : ci.InternCompatState (ci.intern-compat-state-capture-active)]
    [declarations : symbols.CompilerSymbols
      (symbols.compiler-symbols-empty-with-decls 1)]
    [registries : symbols.CompilerRegistries
      (symbols.compiler-registries-empty)]
    [lease : (typed.TypedBodyLease registries)
      (typed-test-resolution-lease
        (& state)
        (& declarations)
        (& registries)
        (cast 83 : u64))]
    [store : typed.TypedStore (typed-test-store (& lease))]
    [id : typed.TypedTypeId
      (typed-test-type! (&mut store) (& lease) ast.AstType.I64)]
    ;; Exercise the canonical same-count declaration mutator through an
    ;; intentional internal alias, as compiler append/rebuild code can do.
    [_changed : symbols.CompilerSymbols
      (symbols.compiler-symbols-index-decl
        (symbols.compiler-symbols-shared-view (& declarations))
        (ast.ast-decl-def-id
          (ci.intern "resolver-replaced")
          ast.AstMaybeType.No
          0)
        0
        0
        0)]
    [stale : bool
      (match (typed.typed-type-get! (&mut store) (& lease) id)
        [(typed.TypedTypeResult.Err error)
          (match error
            [(typed.TypedError.Lease) true]
            [_ false])]
        [_ false])]
    [restamped : (typed.TypedBodyLease registries)
      (typed-test-resolution-lease
        (& state)
        (& declarations)
        (& registries)
        (cast 83 : u64))]
    [no-restamp : bool
      (match (typed.typed-type-get! (&mut store) (& restamped) id)
        [(typed.TypedTypeResult.Err error)
          (match error
            [(typed.TypedError.Lease) true]
            [_ false])]
        [_ false])]
    (typed.typed-store-retire! (&mut store))
    (and read-only replacement wrong-owner exhaustion stale no-restamp)))

(define (compiler-typed-occurrence-self-test) : i64
  (test.assert-true
    (typed-test-selected-occurrences?)
    "typed occurrence: contextual/generated selected children")
  (test.assert-true
    (typed-test-rollback?)
    "typed occurrence: nested rollback and reused handles")
  (test.assert-true
    (typed-test-query-and-budget?)
    "typed occurrence: query isolation and cumulative work")
  (test.assert-true
    (typed-test-leases?)
    "typed occurrence: stale owner and lease")
  (test.assert-true
    (typed-test-resolved-identities?)
    "typed occurrence: resolved bindings, projections and call order")
  (test.assert-true
    (typed-test-interner?)
    "typed occurrence: explicit interner owner and reset generation")
  (test.assert-true
    (typed-test-resource-terminal?)
    "typed occurrence: terminal resource failure and serial exhaustion")
  (test.assert-true
    (typed-test-call-arity?)
    "typed occurrence: canonical Func/CFunc arity")
  (test.assert-true
    (typed-test-growing?)
    "typed occurrence: charged growth, retained handles and rollback")
  (test.assert-true
    (typed-test-malformed-storage?)
    "typed occurrence: malformed extents fail before array access")
  (test.assert-true
    (typed-test-places?)
    "typed place: ordered formation, distinct value acquisition and transactional identities")
  (test.assert-true
    (typed-test-resolver-revisions?)
    "typed resolver: read stability, replacement, owner, exhaustion and no restamping")
  42)