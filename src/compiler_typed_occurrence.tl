;; Selected inference occurrences and bounded transactions for #8449.
;; This is producer plumbing, not an ownership certificate or source normalizer.
;; The caller owns the store, origins, and canonical pools throughout the lease.
;; It must retire the store BEFORE retiring those owners and must never reuse a
;; body owner/generation/revision for another lifetime. No global registry exists.
;; A store has ONE mutable owner: move it or borrow it, never retain a shallow
;; copy with independent counters over the same arrays. Each body revision gets
;; one store. The source checker enforces the ordinary owned-array move rule.
(import compiler_ast_types as ast)
(import compiler_intern as ci)
(import compiler_symbols as symbols)
(import compiler_ownership_core as own)
(import stdlib.string)

(defenum TypedResolutionAuthority
  (:lifetimes context)
  (None)
  (Symbols (symbols.CompilerResolutionLease context)))

(define (typed-resolution-unavailable
  [_state : (& context ci.InternCompatState)]) : (TypedResolutionAuthority
    context)
  TypedResolutionAuthority.None)

(defstruct TypedBodyLease
  (:lifetimes intern)
  (body own.OwnershipBodyId)
  (pools ast.AstNodePoolContext)
  (intern-state (& intern ci.InternCompatState))
  (resolutions own.OwnershipBodyId)
  (resolution-count i64)
  (resolution-authority (TypedResolutionAuthority intern))
  (live? bool))

(define (typed-resolution-authority-current?
  [authority : (& authority (TypedResolutionAuthority context))]) : bool
  (match authority
    [(TypedResolutionAuthority.None) true]
    [(TypedResolutionAuthority.Symbols lease)
      (symbols.compiler-resolution-lease-current? lease)]))

(define (typed-resolution-symbol-revision
  [authority : (& authority (TypedResolutionAuthority context))]) : symbols.CompilerSymbolMapRevision
  (match authority
    [(TypedResolutionAuthority.None)
      (symbols.CompilerSymbolMapRevision (cast 0 : u64) (cast 0 : u64))]
    [(TypedResolutionAuthority.Symbols lease)
      (symbols.CompilerSymbolMapRevision
        lease.symbol-revision.owner
        lease.symbol-revision.revision)]))

(define (typed-resolution-field-revision
  [authority : (& authority (TypedResolutionAuthority context))]) : symbols.CompilerSymbolMapRevision
  (match authority
    [(TypedResolutionAuthority.None)
      (symbols.CompilerSymbolMapRevision (cast 0 : u64) (cast 0 : u64))]
    [(TypedResolutionAuthority.Symbols lease)
      (symbols.CompilerSymbolMapRevision
        lease.field-revision.owner
        lease.field-revision.revision)]))

(define (typed-resolution-revision-equal?
  [left : (& left symbols.CompilerSymbolMapRevision)]
  [right : symbols.CompilerSymbolMapRevision]) : bool
  (and (= left.owner right.owner) (= left.revision right.revision)))

;; A serial is never rewound. Distinct typed wrappers prevent accidentally
;; passing a binder as a child, while serial checks reject cross-table forgery.
(defstruct TypedHandle
  (body own.OwnershipBodyId)
  (index i64)
  (serial u64))

(defstruct TypedOccurrenceId
  (handle TypedHandle))

(defstruct TypedBinderId
  (handle TypedHandle))

(defstruct TypedProjectionId
  (handle TypedHandle))

(defstruct TypedPlaceId
  (handle TypedHandle))

(defstruct TypedCallId
  (handle TypedHandle))

(defstruct TypedOriginId
  (handle TypedHandle))

(defstruct TypedAttemptId
  (handle TypedHandle))

;; Inference often synthesizes AstType values without a type-pool ID. Keep the
;; canonical value in body-owned storage under the lease, never append a shallow
;; scratch payload to a longer-lived pool. Generated expressions may omit IDs.
(defstruct TypedTypeId
  (handle TypedHandle))

(defenum TypedSyntax
  (Source i64)
  (Generated))

(defstruct TypedResolvedGlobal
  (owner u64)
  (generation u64)
  (revision u64)
  (index i64))

(defenum TypedBinderKind
  (Parameter)
  (Local)
  (Capture)
  (Global TypedResolvedGlobal)
  ;; A value expression's result held for a projection out of it, like
  ;; `(array-ref (f) i)`: a place rooted here takes, as FormPlace child 0, the
  ;; Initialize of this binder from the value, before any index.
  (Temporary)
  ;; A `let` binding of a cleanup-owning aggregate (SPEC 4.7.1): every exit of
  ;; its scope must find it discharged.
  (Owner)
  ;; A `with` binding (SPEC 5.19): its cleanup runs on every exit of its
  ;; scope, so no exit may find it moved. The expression id of its cleanup
  ;; function (-1 when none; -2 for a locally bound callable), whose effects
  ;; run at those exits (#7904).
  (WithOwner i64)
  ;; A move-aware `with` binding (as `for` binds a cleanup-owning item): an
  ;; ordinary local whose cleanup runs at an exit while it still owns its
  ;; value; the cleanup function's expression id as for `WithOwner`.
  (MoveAwareOwner i64)
  ;; A direct arena owner annotated with the bare `Arena` type, or an arena
  ;; phase token (SPEC 5.16): a Copy handle tracked as an owner, so a read of
  ;; the whole binder moves it. Borrowing reads go through a reference.
  (Affine)
  ;; A parameter declared `(:invalidate r T)`, with its lifetime `r`: the
  ;; function must end the arena brand `r` exactly once on every normal exit.
  (InvalidateParameter i64))

(defenum TypedProjectionKind
  (StructField TypedResolvedGlobal i64)
  (TupleElement i64)
  (FixedArrayElement i64)
  ;; The index is a selected value child of FormPlace, in root-to-leaf order.
  (ArrayElement)
  ;; The referent of a reference-typed place; the result type is the referent.
  (Deref)
  ;; A variant payload field of an enum place: the enum's declaration and the
  ;; field's ordinal among all variants' payload fields in declaration order
  ;; (one variant is live at a time; each field is its own place).
  (Payload TypedResolvedGlobal i64))

(defenum TypedPlaceKind
  (Root TypedBinderId)
  (Projection TypedPlaceId TypedProjectionId))

(defenum TypedOccurrenceCategory
  (Value)
  (Place TypedPlaceId))

(defenum TypedCallKind
  (Direct TypedResolvedGlobal)
  ;; A direct call to the function declaration with this canonical
  ;; module-qualified name key, selected before resolver authority exists for
  ;; calls. The key identifies the callee in dumps and diagnostics only; the
  ;; call's ownership contract is its checked signature type. No consumer may
  ;; treat it as a resolved symbol.
  (Declared i64)
  ;; A struct or enum variant constructor named directly: like a Declared
  ;; call, its children are the operands alone, moved into a fresh value.
  (Construct)
  ;; A direct call to the extern function declaration with this key (dumps
  ;; only, like Declared). A foreign declaration carries no ownership effect
  ;; (SPEC 4.3): its children are the operands alone, each read for the call
  ;; (a non-Copy place is lent as a shared borrow), and its result is fresh.
  (Foreign i64)
  ;; A call through a function value, its child 0. The expression id of the
  ;; callee when its name resolves at module level (a dispatcher, an extern,
  ;; a module value of function type), naming its effects (#7904); -1 for a
  ;; locally bound callable or any other value.
  (Indirect i64)
  ;; A call of its argument type's declared cleanup function (key as for
  ;; Declared): it discharges that value's cleanup obligation.
  (Discharge i64))

(defenum TypedMode
  (Executable)
  (Query))

(defenum TypedError
  (Lease)
  (Stale)
  (Unknown)
  (Query)
  (Order)
  (Shape)
  (Budget)
  (Exhausted))

(defenum TypedResult
  (Ok unit)
  (Err TypedError))

(defenum TypedOccurrenceResult
  (Ok TypedOccurrenceId)
  (Err TypedError))

(defenum TypedBinderResult
  (Ok TypedBinderId)
  (Err TypedError))

(defenum TypedCountResult
  (Ok i64)
  (Err TypedError))

(defenum TypedProjectionResult
  (Ok TypedProjectionId)
  (Err TypedError))

(defenum TypedPlaceResult
  (Ok TypedPlaceId)
  (Err TypedError))

(defenum TypedCallResult
  (Ok TypedCallId)
  (Err TypedError))

(defenum TypedOriginResult
  (Ok TypedOriginId)
  (Err TypedError))

(defenum TypedAttemptResult
  (Ok TypedAttemptId)
  (Err TypedError))

(defenum TypedTypeResult
  (:lifetimes store)
  (Ok (& store ast.AstType))
  (Err TypedError))

(defenum TypedTypeIdResult
  (Ok TypedTypeId)
  (Err TypedError))

(defenum TypedTypeValueResult
  (Ok ast.AstType)
  (Err TypedError))

(defenum TypedNodeResult
  (:lifetimes store)
  (Ok (& store TypedOccurrence))
  (Err TypedError))

(defenum TypedChildResult
  (Ok TypedOccurrenceId)
  (Err TypedError))

(defenum TypedOriginView
  (:lifetimes store)
  (Ok (& store own.OwnershipSource))
  (Err TypedError))

(defenum TypedBinderView
  (:lifetimes store)
  (Ok (& store TypedBinder))
  (Err TypedError))

(defenum TypedProjectionView
  (:lifetimes store)
  (Ok (& store TypedProjection))
  (Err TypedError))

(defenum TypedPlaceView
  (:lifetimes store)
  (Ok (& store TypedPlace))
  (Err TypedError))

(defenum TypedCallView
  (:lifetimes store)
  (Ok (& store TypedCall))
  (Err TypedError))

;; Value-level primitives with fixed operand counts. Each evaluates its value
;; operands left to right and produces a fresh value; none forms a place or
;; creates a loan. `PtrAddrOf` addresses a named place without evaluating or
;; reading it: raw addresses are unsafe capabilities outside ownership facts.
(defenum TypedPrimitive
  (Cast)
  (PtrNull)
  (PtrNullCheck)
  (PtrAddrOf)
  (PtrRead)
  (PtrWrite)
  (PtrOffset)
  (PtrCast)
  (PtrToInt)
  (IntToPtr)
  ;; A place reached through a raw pointer (`(deref p)` under struct-field,
  ;; tuple and array projections) lies outside ownership tracking, like the
  ;; whole pointee `ptr-read` and `ptr-write!` access. Children: the pointer,
  ;; then each dynamic index of the path from root to leaf (the count is the
  ;; arity). A read is a fresh bitwise copy of the place's value.
  (RawRead i64)
  ;; A store into such a place: the RawRead children, then the value moved in
  ;; (the count is the arity). The overwritten value is neither dropped nor
  ;; checked. The result is unit.
  (RawWrite i64)
  ;; A read-only builtin (its typechecker dispatch arm) of the given arity:
  ;; operands are borrowed places or evaluated values; the result is fresh.
  (Builtin i64 i64))

(define (typed-primitive-arity [primitive : (& primitive TypedPrimitive)]) : i64
  (match primitive
    [(TypedPrimitive.Cast) 1]
    [(TypedPrimitive.PtrNull) 0]
    [(TypedPrimitive.PtrNullCheck) 1]
    [(TypedPrimitive.PtrAddrOf) 0]
    [(TypedPrimitive.PtrRead) 1]
    [(TypedPrimitive.PtrWrite) 2]
    [(TypedPrimitive.PtrOffset) 2]
    [(TypedPrimitive.PtrCast) 1]
    [(TypedPrimitive.PtrToInt) 1]
    [(TypedPrimitive.IntToPtr) 1]
    [(TypedPrimitive.RawRead arity) arity]
    [(TypedPrimitive.RawWrite arity) arity]
    [(TypedPrimitive.Builtin _ arity) arity]))

;; Every admitted operation has an explicit child-shape rule below. Additional
;; source forms require a new variant and rule; there is no opaque/catch-all op.
;; One match arm's pattern node. In a by-value match a pattern's first child
;; forms its position's place (the scrutinee or a payload/element place) and
;; the rest are sub-patterns; in a borrowed match (through a reference) there
;; are no positions and binders are references derived from the scrutinee.
(defenum TypedPattern
  (Wildcard)
  ;; Binds the matched position (a by-value copy/move, or a reference).
  (Bind TypedBinderId)
  ;; Tests the enum variant ordinal; sub-patterns match its payload fields.
  (Variant i64)
  ;; Tests equality with a scalar literal.
  (Literal ast.AstLiteral)
  ;; Matches each element by its sub-pattern.
  (Tuple)
  ;; `(or p ...)` whose alternatives bind no names: a test of the position
  ;; with no sub-patterns (the alternatives only test it).
  (Or)
  ;; `(slice p ... [& rest])` through a reference: tests the view's length;
  ;; the sub-patterns match its elements in order, then the rest.
  (Slice)
  ;; An arm's `(or p ...)` whose alternatives bind names: one candidate
  ;; pattern per alternative, each forming its own positions and binding the
  ;; same binders. It has no position child of its own.
  (Alternatives))

(defenum TypedOperation
  (Literal ast.AstLiteral)
  (Read TypedBinderId)
  (Initialize TypedBinderId)
  (Assign TypedBinderId)
  (Project TypedProjectionId)
  ;; Forming a place does not read, copy, or move its aggregate contents.
  ;; Acquisitions consume that exact place result after its index effects.
  ;; The place consumer evaluates each dynamic index then applies/checks that
  ;; projection before the next index; the children are not an eager value list.
  (FormPlace TypedPlaceId)
  (CopyPlace TypedPlaceId)
  (MovePlace TypedPlaceId)
  ;; `(set! place value)` for a projected place: child 0 forms the place, child
  ;; 1 is the value moved into it. The result is unit.
  (AssignPlace TypedPlaceId)
  ;; `(replace! place replacement)`: child 0 forms the place, child 1 is the
  ;; replacement moved into it. The result is the place's old value.
  (ReplacePlace TypedPlaceId)
  (Call TypedCallId)
  (Unary ast.AstUnOp)
  (Binary ast.AstBinOp)
  (Sequence)
  (If)
  ;; Structured scalar control: exits target the nearest enclosing While body.
  ;; The condition is evaluated outside that body's control scope.
  (While)
  (Break)
  (Continue)
  (Return)
  (Primitive TypedPrimitive)
  ;; `(& place)` (false) or `(&mut place)` (true): child 0 forms the borrowed
  ;; place; the result is a reference to it, not a copy of its value.
  (Borrow bool)
  ;; Child 0 is the scrutinee: a formed place, an initialized synthetic binder
  ;; (by value), or a reference value (borrowed: true); then one Arm per arm.
  (Match bool)
  ;; Children: the arm's pattern and its body.
  (Arm)
  (Pattern TypedPattern)
  ;; A safe arena destroy or rewind ends the binder's value (it holds values
  ;; of the invalidated region): no child, and the result is unit.
  (Invalidate TypedBinderId)
  ;; A destroy of the brand an `:invalidate` parameter (the binder) declares,
  ;; or a call passing it to another `:invalidate` parameter, discharges that
  ;; parameter's obligation: no child, and the result is unit.
  (EndBrand TypedBinderId)
  ;; A value holding the region of an atomic arena owner (the binder) crossed
  ;; to another thread (a channel send, a spawned closure's capture): the owner
  ;; has users it cannot see. No child, and the result is unit.
  (ThreadUsers TypedBinderId)
  ;; Before a safe destroy or rewind of an atomic arena owner (the second
  ;; binder), the first must be released: the owner itself when it has no
  ;; thread users left, or a live thread handle holding its region when it was
  ;; joined. No child, and the result is unit.
  (RequireReleased TypedBinderId TypedBinderId)
  ;; Before a safe destroy (false) or rewind (true) of the arena the second
  ;; binder names, the first, a `with` cleanup owner holding values of that
  ;; arena, must no longer hold them (its scope-exit cleanup would read freed
  ;; storage). No child, and the result is unit.
  (RequireUnheld TypedBinderId TypedBinderId bool))

(defstruct TypedOccurrence
  (serial u64)
  (type TypedTypeId)
  (category TypedOccurrenceCategory)
  (syntax TypedSyntax)
  (origin TypedOriginId)
  (operation TypedOperation)
  (child-start i64)
  (child-count i64))

(defstruct TypedBinder
  (serial u64)
  (type TypedTypeId)
  (kind TypedBinderKind)
  (origin TypedOriginId)
  ;; The binder's source-visible name id for diagnostics, or -1. It plays no
  ;; part in identity: distinct binders may share a name (shadowing).
  (name i64))

(defstruct TypedProjection
  (serial u64)
  (container-type TypedTypeId)
  (result-type TypedTypeId)
  (kind TypedProjectionKind)
  ;; Distinct from an index child's origin: bounds/access failure belongs to
  ;; this projection even when a later index has not executed.
  (origin TypedOriginId))

(defstruct TypedPlace
  (serial u64)
  (type TypedTypeId)
  (kind TypedPlaceKind)
  ;; Number of index value children required by the complete parent path.
  (index-count i64))

(defstruct TypedCall
  (serial u64)
  (signature TypedTypeId)
  (kind TypedCallKind)
  (argument-count i64))

(defstruct TypedOrigin
  (serial u64)
  (source own.OwnershipSource))

(defstruct TypedType
  (serial u64)
  (value ast.AstType))

(defstruct TypedCheckpoint
  (serial u64)
  (occurrences i64)
  (binders i64)
  (projections i64)
  (places i64)
  (calls i64)
  (origins i64)
  (types i64)
  (children i64)
  (previous-mode TypedMode))

(defstruct TypedLimits
  (records i64)
  (children i64)
  (attempts i64)
  (work i64))

(defstruct TypedStore
  (body own.OwnershipBodyId)
  (expr-pool u64)
  (type-pool u64)
  (pool-owner i64)
  (intern-table i64)
  (intern-generation i64)
  (resolutions own.OwnershipBodyId)
  (resolution-count i64)
  (resolution-symbol symbols.CompilerSymbolMapRevision)
  (resolution-field symbols.CompilerSymbolMapRevision)
  (live? bool)
  (failed? bool)
  (failure TypedError)
  (mode TypedMode)
  (limits TypedLimits)
  (work i64)
  (next-serial u64)
  (occurrences (__tl_dyn-array TypedOccurrence))
  (binders (__tl_dyn-array TypedBinder))
  (projections (__tl_dyn-array TypedProjection))
  (places (__tl_dyn-array TypedPlace))
  (calls (__tl_dyn-array TypedCall))
  (origins (__tl_dyn-array TypedOrigin))
  (types (__tl_dyn-array TypedType))
  (children (__tl_dyn-array TypedOccurrenceId))
  (attempts (__tl_dyn-array TypedCheckpoint))
  (occurrence-count i64)
  (binder-count i64)
  (projection-count i64)
  (place-count i64)
  (call-count i64)
  (origin-count i64)
  (type-count i64)
  (child-count i64)
  (attempt-count i64)
  ;; Regions this body allocates in (arena owners' and `in-arena` regions):
  ;; a region tag naming one marks an arena allocation, not a value read
  ;; through a reference of that lifetime.
  (arena-regions (__tl_dyn-array i64)))

(defenum TypedStoreResult
  (Ok TypedStore)
  (Err TypedError))

(define (typed-body-valid? [body : (& body own.OwnershipBodyId)]) : bool
  (and (> body.owner 0) (> body.generation 0) (> body.revision 0)))

(define (typed-body-copy [body : (& body own.OwnershipBodyId)]) : own.OwnershipBodyId
  (own.OwnershipBodyId body.owner body.generation body.revision))

(define (typed-handle-copy [handle : (& handle TypedHandle)]) : TypedHandle
  (TypedHandle (typed-body-copy (& handle.body)) handle.index handle.serial))

(define (typed-handle-equal?
  [left : (& left TypedHandle)]
  [right : (& right TypedHandle)]) : bool
  (and
    (own.ownership-body-id-equal? (& left.body) (& right.body))
    (= left.index right.index)
    (= left.serial right.serial)))

(define (typed-mode-copy [mode : (& mode TypedMode)]) : TypedMode
  (match mode
    [(TypedMode.Executable) TypedMode.Executable]
    [(TypedMode.Query) TypedMode.Query]))

(define (typed-checkpoint-copy [point : (& point TypedCheckpoint)]) : TypedCheckpoint
  (TypedCheckpoint
    point.serial
    point.occurrences
    point.binders
    point.projections
    point.places
    point.calls
    point.origins
    point.types
    point.children
    (typed-mode-copy (& point.previous-mode))))

(define (typed-function-arity [value : (& value ast.AstType)]) : i64
  (match value
    [(ast.AstType.Func params _) (ast.ast-type-list-len params)]
    [_ -1]))

(define (typed-call-signature-arity
  [store : (& store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]
  [signature : (& signature TypedTypeId)]) : i64
  (match (typed-type-ok store lease signature)
    [(TypedResult.Err _) -1]
    [(TypedResult.Ok _)
      (match (& (array-ref store.types signature.handle.index).value)
        [(ast.AstType.Func _ _)
          (typed-function-arity
            (& (array-ref store.types signature.handle.index).value))]
        [(ast.AstType.CFunc inner _)
          (if (and
            (>= inner 0)
            (< inner (ast.ast-node-pool-context-type-len lease.pools)))
            (let
              [function : ast.AstType
                (ast.ast-node-pool-context-type-get (& lease.pools) inner)]
              (typed-function-arity (& function)))
            -1)]
        [_ -1])]))

;; Charge array initialization before allocating. The bounded capacities make
;; this byte-count arithmetic fit i64 independently of the caller's work limit.
(define (typed-setup-work [limits : (& limits TypedLimits)]) : i64
  (+
    1
    (+
      (*
        limits.records
        (+
          (comptime (size-of (type TypedOccurrence)))
          (+
            (comptime (size-of (type TypedBinder)))
            (+
              (comptime (size-of (type TypedProjection)))
              (+
                (+
                  (comptime (size-of (type TypedPlace)))
                  (comptime (size-of (type TypedCall))))
                (+
                  (comptime (size-of (type TypedOrigin)))
                  (comptime (size-of (type TypedType)))))))))
      (+
        (* limits.children (comptime (size-of (type TypedOccurrenceId))))
        (* limits.attempts (comptime (size-of (type TypedCheckpoint))))))))

(define (typed-store-new
  [lease : (& lease (TypedBodyLease intern))]
  [limits : TypedLimits]) : TypedStoreResult
  (typed-store-new-reserved lease limits limits))

;; Production inference does not know the selected occurrence count in advance.
;; Start small and charge later growth as it occurs, without traversing the AST
;; or replaying inference to predict storage. The configured maxima remain hard.
(define (typed-store-new-growing
  [lease : (& lease (TypedBodyLease intern))]
  [limits : TypedLimits]) : TypedStoreResult
  (typed-store-new-reserved
    lease
    limits
    (TypedLimits
      (if (< limits.records 16)
        limits.records
        16)
      (if (< limits.children 16)
        limits.children
        16)
      (if (< limits.attempts 16)
        limits.attempts
        16)
      limits.work)))

(define (typed-store-new-reserved
  [lease : (& lease (TypedBodyLease intern))]
  [limits : TypedLimits]
  [capacity : TypedLimits]) : TypedStoreResult
  (cond
    [(not
        (and
          lease.live?
          (typed-body-valid? (& lease.body))
          (typed-body-valid? (& lease.resolutions))
          (>= lease.resolution-count 0)
          (typed-resolution-authority-current? (& lease.resolution-authority))
          (> lease.pools.expr-pool 0)
          (> lease.pools.type-pool 0)
          (> lease.pools.owner-arena 0)))
      (TypedStoreResult.Err TypedError.Lease)]
    [(not
        (and
          (> limits.records 0)
          (<= limits.records 65536)
          (>= limits.children 0)
          (<= limits.children 1048576)
          (> limits.attempts 0)
          (<= limits.attempts 65536)
          (> capacity.records 0)
          (<= capacity.records limits.records)
          (>= capacity.children 0)
          (<= capacity.children limits.children)
          (> capacity.attempts 0)
          (<= capacity.attempts limits.attempts)
          (> limits.work 0)))
      (TypedStoreResult.Err TypedError.Budget)]
    [(> (typed-setup-work (& capacity)) limits.work)
      (TypedStoreResult.Err TypedError.Budget)]
    [else
      (TypedStoreResult.Ok
        (TypedStore
          (typed-body-copy (& lease.body))
          lease.pools.expr-pool
          lease.pools.type-pool
          lease.pools.owner-arena
          (ci.intern-compat-state-table-id lease.intern-state)
          (ci.intern-compat-state-generation lease.intern-state)
          (typed-body-copy (& lease.resolutions))
          lease.resolution-count
          (typed-resolution-symbol-revision (& lease.resolution-authority))
          (typed-resolution-field-revision (& lease.resolution-authority))
          true
          false
          TypedError.Budget
          TypedMode.Executable
          limits
          (typed-setup-work (& capacity))
          (cast 1 : u64)
          (__tl_make-array TypedOccurrence capacity.records)
          (__tl_make-array TypedBinder capacity.records)
          (__tl_make-array TypedProjection capacity.records)
          (__tl_make-array TypedPlace capacity.records)
          (__tl_make-array TypedCall capacity.records)
          (__tl_make-array TypedOrigin capacity.records)
          (__tl_make-array TypedType capacity.records)
          (__tl_make-array TypedOccurrenceId capacity.children)
          (__tl_make-array TypedCheckpoint capacity.attempts)
          0
          0
          0
          0
          0
          0
          0
          0
          0
          (__tl_make-array i64 0)))]))

;; Check scalar lease identity before looking at stored strings, canonical
;; types, or any pool cell. An active unrelated pool is never consulted.
(define (typed-count-valid? [count : i64] [capacity : i64] [limit : i64]) : bool
  (and (>= count 0) (<= count capacity) (<= count limit)))

;; Public checked consumers may receive malformed records. Validate every
;; logical table extent before a count can authorize an array access. This is
;; constant work and touches only the store's live array descriptors/scalars.
(define (typed-store-shape-ok? [store : (& store TypedStore)]) : bool
  (and
    (>= store.work 0)
    (<= store.work store.limits.work)
    (typed-count-valid?
      store.occurrence-count
      (array-length store.occurrences)
      store.limits.records)
    (typed-count-valid?
      store.binder-count
      (array-length store.binders)
      store.limits.records)
    (typed-count-valid?
      store.projection-count
      (array-length store.projections)
      store.limits.records)
    (typed-count-valid?
      store.place-count
      (array-length store.places)
      store.limits.records)
    (typed-count-valid?
      store.call-count
      (array-length store.calls)
      store.limits.records)
    (typed-count-valid?
      store.origin-count
      (array-length store.origins)
      store.limits.records)
    (typed-count-valid?
      store.type-count
      (array-length store.types)
      store.limits.records)
    (typed-count-valid?
      store.child-count
      (array-length store.children)
      store.limits.children)
    (typed-count-valid?
      store.attempt-count
      (array-length store.attempts)
      store.limits.attempts)))

(define (typed-lease-ok
  [store : (& store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]) : TypedResult
  (if (and
    store.live?
    lease.live?
    (own.ownership-body-id-equal? (& store.body) (& lease.body))
    (own.ownership-body-id-equal? (& store.resolutions) (& lease.resolutions))
    (= store.resolution-count lease.resolution-count)
    (typed-resolution-revision-equal?
      (& store.resolution-symbol)
      (typed-resolution-symbol-revision (& lease.resolution-authority)))
    (typed-resolution-revision-equal?
      (& store.resolution-field)
      (typed-resolution-field-revision (& lease.resolution-authority)))
    (typed-resolution-authority-current? (& lease.resolution-authority))
    (= store.expr-pool lease.pools.expr-pool)
    (= store.type-pool lease.pools.type-pool)
    (= store.pool-owner lease.pools.owner-arena)
    (= store.intern-table (ci.intern-compat-state-table-id lease.intern-state))
    (=
      store.intern-generation
      (ci.intern-compat-state-generation lease.intern-state)))
    (if (typed-store-shape-ok? store)
      (TypedResult.Ok unit)
      (TypedResult.Err TypedError.Shape))
    (TypedResult.Err TypedError.Lease)))

(define (typed-charge!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]
  [units : i64]) : TypedResult
  (try (typed-lease-ok (& store) lease))
  (cond
    [store.failed? (TypedResult.Err (typed-resource-error (& store.failure)))]
    [(or (< units 0) (> units (- store.limits.work store.work)))
      (typed-resource-fail! store TypedError.Budget)]
    [else
      (set! store.work (+ store.work units))
      (TypedResult.Ok unit)]))

;; Resource failure aborts the body transaction, not just one inference probe.
;; Rollback also costs work; exhaustion leaves the store readable only through
;; its scalar failure state until the caller unconditionally retires it.
(define (typed-resource-error [error : (& error TypedError)]) : TypedError
  (match error
    [(TypedError.Exhausted) TypedError.Exhausted]
    [_ TypedError.Budget]))

(define (typed-resource-fail!
  [store : (&mut store TypedStore)]
  [error : TypedError]) : TypedResult
  (set! store.failed? true)
  (set! store.failure error)
  (TypedResult.Err error))

(define (typed-executable? [store : (& store TypedStore)]) : bool
  (match (& store.mode)
    [(TypedMode.Executable) true]
    [(TypedMode.Query) false]))

(define (typed-empty-handle) : TypedHandle
  (TypedHandle
    (own.OwnershipBodyId (cast 0 : u64) (cast 0 : u64) (cast 0 : u64))
    0
    (cast 0 : u64)))

;; This bounded arithmetic is reached only after the requested count was checked
;; against the configured maximum. Storage growth never changes logical counts.
(define (typed-grown-capacity [old : i64] [needed : i64] [limit : i64]) : i64
  (let
    [capacity : i64
      (if (> old 0)
        old
        1)]
    (while (< capacity needed)
      (set!
        capacity
        (if (> capacity (/ limit 2))
          limit
          (* capacity 2))))
    capacity))

;; Move live rows, replacing each old slot before reusing its owner. Borrowed
;; views obey the normal rule: finish reading them before a mutable builder call.
;; No shallow store copy or second set of logical counters is created.
(define (typed-reserve-records!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]
  [needed : i64]) : TypedResult
  (try (typed-charge! store lease 1))
  (when
    (or (< needed 0) (> needed store.limits.records))
    (return (typed-resource-fail! store TypedError.Budget)))
  (let
    [old : i64 (array-length store.occurrences)]
    (when
      (> needed old)
      (let
        [capacity : i64 (typed-grown-capacity old needed store.limits.records)]
        ;; Upper-bound all live-row moves by the previous capacity. Both
        ;; initialization and movement are charged before any allocation.
        [charged : TypedLimits (TypedLimits (+ capacity old) 0 0 0)]
        [units : i64 (typed-setup-work (& charged))]
        (try (typed-charge! store lease units))
        (let
          [occurrences : (__tl_dyn-array TypedOccurrence)
            (__tl_make-array TypedOccurrence capacity)]
          [binders : (__tl_dyn-array TypedBinder)
            (__tl_make-array TypedBinder capacity)]
          [projections : (__tl_dyn-array TypedProjection)
            (__tl_make-array TypedProjection capacity)]
          [places : (__tl_dyn-array TypedPlace)
            (__tl_make-array TypedPlace capacity)]
          [calls : (__tl_dyn-array TypedCall)
            (__tl_make-array TypedCall capacity)]
          [origins : (__tl_dyn-array TypedOrigin)
            (__tl_make-array TypedOrigin capacity)]
          [types : (__tl_dyn-array TypedType)
            (__tl_make-array TypedType capacity)]
          [index : i64 0]
          (while (< index old)
            (when
              (< index store.occurrence-count)
              (set!
                (array-ref occurrences index)
                (replace!
                  (array-ref store.occurrences index)
                  (TypedOccurrence
                    (cast 0 : u64)
                    (TypedTypeId (typed-empty-handle))
                    TypedOccurrenceCategory.Value
                    TypedSyntax.Generated
                    (TypedOriginId (typed-empty-handle))
                    (TypedOperation.Literal ast.AstLiteral.Unit)
                    0
                    0))))
            (when
              (< index store.binder-count)
              (set!
                (array-ref binders index)
                (replace!
                  (array-ref store.binders index)
                  (TypedBinder
                    (cast 0 : u64)
                    (TypedTypeId (typed-empty-handle))
                    TypedBinderKind.Local
                    (TypedOriginId (typed-empty-handle))
                    -1))))
            (when
              (< index store.projection-count)
              (set!
                (array-ref projections index)
                (replace!
                  (array-ref store.projections index)
                  (TypedProjection
                    (cast 0 : u64)
                    (TypedTypeId (typed-empty-handle))
                    (TypedTypeId (typed-empty-handle))
                    (TypedProjectionKind.TupleElement 0)
                    (TypedOriginId (typed-empty-handle))))))
            (when
              (< index store.place-count)
              (set!
                (array-ref places index)
                (replace!
                  (array-ref store.places index)
                  (TypedPlace
                    (cast 0 : u64)
                    (TypedTypeId (typed-empty-handle))
                    (TypedPlaceKind.Root (TypedBinderId (typed-empty-handle)))
                    0))))
            (when
              (< index store.call-count)
              (set!
                (array-ref calls index)
                (replace!
                  (array-ref store.calls index)
                  (TypedCall
                    (cast 0 : u64)
                    (TypedTypeId (typed-empty-handle))
                    (TypedCallKind.Indirect -1)
                    0))))
            (when
              (< index store.origin-count)
              (set!
                (array-ref origins index)
                (replace!
                  (array-ref store.origins index)
                  (TypedOrigin (cast 0 : u64) (own.OwnershipSource "" 0 0 "")))))
            (when
              (< index store.type-count)
              (set!
                (array-ref types index)
                (replace!
                  (array-ref store.types index)
                  (TypedType (cast 0 : u64) ast.AstType.Unit))))
            (set! index (+ index 1)))
          (set! store.occurrences occurrences)
          (set! store.binders binders)
          (set! store.projections projections)
          (set! store.places places)
          (set! store.calls calls)
          (set! store.origins origins)
          (set! store.types types))))
    (TypedResult.Ok unit)))

(define (typed-reserve-children!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]
  [needed : i64]) : TypedResult
  (try (typed-charge! store lease 1))
  (when
    (or (< needed 0) (> needed store.limits.children))
    (return (typed-resource-fail! store TypedError.Budget)))
  (let
    [old : i64 (array-length store.children)]
    (when
      (> needed old)
      (let
        [capacity : i64 (typed-grown-capacity old needed store.limits.children)]
        (try
          (typed-charge!
            store
            lease
            (*
              (+ capacity store.child-count)
              (comptime (size-of (type TypedOccurrenceId))))))
        (let
          [children : (__tl_dyn-array TypedOccurrenceId)
            (__tl_make-array TypedOccurrenceId capacity)]
          [index : i64 0]
          (while (< index store.child-count)
            (set!
              (array-ref children index)
              (replace!
                (array-ref store.children index)
                (TypedOccurrenceId (typed-empty-handle))))
            (set! index (+ index 1)))
          (set! store.children children))))
    (TypedResult.Ok unit)))

(define (typed-reserve-attempts!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]
  [needed : i64]) : TypedResult
  (try (typed-charge! store lease 1))
  (when
    (or (< needed 0) (> needed store.limits.attempts))
    (return (typed-resource-fail! store TypedError.Budget)))
  (let
    [old : i64 (array-length store.attempts)]
    (when
      (> needed old)
      (let
        [capacity : i64 (typed-grown-capacity old needed store.limits.attempts)]
        (try
          (typed-charge!
            store
            lease
            (*
              (+ capacity store.attempt-count)
              (comptime (size-of (type TypedCheckpoint))))))
        (let
          [attempts : (__tl_dyn-array TypedCheckpoint)
            (__tl_make-array TypedCheckpoint capacity)]
          [index : i64 0]
          (while (< index store.attempt-count)
            (set!
              (array-ref attempts index)
              (replace!
                (array-ref store.attempts index)
                (TypedCheckpoint
                  (cast 0 : u64)
                  0
                  0
                  0
                  0
                  0
                  0
                  0
                  0
                  TypedMode.Executable)))
            (set! index (+ index 1)))
          (set! store.attempts attempts))))
    (TypedResult.Ok unit)))

(define (typed-mint-ok [store : (&mut store TypedStore)] [count : i64]) : TypedResult
  (cond
    [(not (typed-executable? (& store))) (TypedResult.Err TypedError.Query)]
    [(>= count store.limits.records)
      (typed-resource-fail! store TypedError.Budget)]
    [(= store.next-serial (cast 18446744073709551615 : u64))
      (typed-resource-fail! store TypedError.Exhausted)]
    [else (TypedResult.Ok unit)]))

(define (typed-fresh! [store : (&mut store TypedStore)] [index : i64]) : TypedHandle
  (let
    [serial : u64 store.next-serial]
    (set! store.next-serial (+ serial (cast 1 : u64)))
    (TypedHandle (typed-body-copy (& store.body)) index serial)))

(define (typed-handle-range?
  [store : (& store TypedStore)]
  [handle : (& handle TypedHandle)]
  [count : i64]) : bool
  (and
    (own.ownership-body-id-equal? (& store.body) (& handle.body))
    (>= handle.index 0)
    (< handle.index count)
    (> handle.serial 0)))

(define (typed-type-ok
  [store : (& store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]
  [type : (& type TypedTypeId)]) : TypedResult
  (try (typed-lease-ok store lease))
  (if (and
    (typed-handle-range? store (& type.handle) store.type-count)
    (= (array-ref store.types type.handle.index).serial type.handle.serial))
    (TypedResult.Ok unit)
    (TypedResult.Err TypedError.Unknown)))

(define (typed-type-add!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]
  [type : ast.AstType]) : TypedTypeIdResult
  (try (typed-charge! store lease 1))
  (try (typed-mint-ok store store.type-count))
  (try (typed-reserve-records! store lease (+ store.type-count 1)))
  (let
    [handle : TypedHandle (typed-fresh! store store.type-count)]
    (set!
      (array-ref store.types store.type-count)
      (TypedType handle.serial type))
    (set! store.type-count (+ store.type-count 1))
    (TypedTypeIdResult.Ok (TypedTypeId handle))))

(define (typed-origin-ok
  [store : (& store TypedStore)]
  [id : (& id TypedOriginId)]) : TypedResult
  (if (and
    (typed-handle-range? store (& id.handle) store.origin-count)
    (= (array-ref store.origins id.handle.index).serial id.handle.serial))
    (TypedResult.Ok unit)
    (TypedResult.Err TypedError.Stale)))

(define (typed-occurrence-ok
  [store : (& store TypedStore)]
  [id : (& id TypedOccurrenceId)]) : TypedResult
  (if (and
    (typed-handle-range? store (& id.handle) store.occurrence-count)
    (= (array-ref store.occurrences id.handle.index).serial id.handle.serial))
    (TypedResult.Ok unit)
    (TypedResult.Err TypedError.Stale)))

(define (typed-binder-ok
  [store : (& store TypedStore)]
  [id : (& id TypedBinderId)]) : TypedResult
  (if (and
    (typed-handle-range? store (& id.handle) store.binder-count)
    (= (array-ref store.binders id.handle.index).serial id.handle.serial))
    (TypedResult.Ok unit)
    (TypedResult.Err TypedError.Stale)))

(define (typed-projection-ok
  [store : (& store TypedStore)]
  [id : (& id TypedProjectionId)]) : TypedResult
  (if (and
    (typed-handle-range? store (& id.handle) store.projection-count)
    (= (array-ref store.projections id.handle.index).serial id.handle.serial))
    (typed-origin-ok
      store
      (& (array-ref store.projections id.handle.index).origin))
    (TypedResult.Err TypedError.Stale)))

(define (typed-call-ok [store : (& store TypedStore)] [id : (& id TypedCallId)]) : TypedResult
  (if (and
    (typed-handle-range? store (& id.handle) store.call-count)
    (= (array-ref store.calls id.handle.index).serial id.handle.serial))
    (TypedResult.Ok unit)
    (TypedResult.Err TypedError.Stale)))

(define (typed-place-ok
  [store : (& store TypedStore)]
  [id : (& id TypedPlaceId)]) : TypedResult
  (if (and
    (typed-handle-range? store (& id.handle) store.place-count)
    (= (array-ref store.places id.handle.index).serial id.handle.serial))
    (TypedResult.Ok unit)
    (TypedResult.Err TypedError.Stale)))

(define (typed-projection-index-count [kind : (& kind TypedProjectionKind)]) : i64
  (match kind
    [(TypedProjectionKind.StructField _ _) 0]
    [(TypedProjectionKind.TupleElement _) 0]
    [(TypedProjectionKind.FixedArrayElement _) 0]
    [(TypedProjectionKind.ArrayElement) 1]
    [(TypedProjectionKind.Deref) 0]
    [(TypedProjectionKind.Payload _ _) 0]))

;; Validate the immediate prefix before exposing a place. Prefix handles must
;; precede their descendant, so forged cycles cannot masquerade as a path.
(define (typed-place-shape-ok
  [store : (& store TypedStore)]
  [id : (& id TypedPlaceId)]) : TypedResult
  (try (typed-place-ok store id))
  (let
    [place : (& store TypedPlace) (& (array-ref store.places id.handle.index))]
    (if (match (& place.kind)
      [(TypedPlaceKind.Root binder)
        (try (typed-binder-ok store binder))
        (and
          ;; A temporary's initialization is its places' first child.
          (=
            place.index-count
            (if (typed-binder-temporary? store binder)
              1
              0))
          (typed-handle-equal?
            (& place.type.handle)
            (& (array-ref store.binders binder.handle.index).type.handle)))]
      [(TypedPlaceKind.Projection parent projection)
        (try (typed-place-ok store parent))
        (try (typed-projection-ok store projection))
        (let
          [prefix : (& store TypedPlace)
            (& (array-ref store.places parent.handle.index))]
          [step : (& store TypedProjection)
            (& (array-ref store.projections projection.handle.index))]
          (and
            (< parent.handle.index id.handle.index)
            (>= prefix.index-count 0)
            (<= prefix.index-count store.limits.children)
            (=
              place.index-count
              (+
                prefix.index-count
                (typed-projection-index-count (& step.kind))))
            (<= place.index-count store.limits.children)
            (typed-handle-equal?
              (& prefix.type.handle)
              (& step.container-type.handle))
            (typed-handle-equal?
              (& place.type.handle)
              (& step.result-type.handle))))])
      (TypedResult.Ok unit)
      (TypedResult.Err TypedError.Shape))))

(define (typed-global-valid?
  [lease : (& lease (TypedBodyLease intern))]
  [id : (& id TypedResolvedGlobal)]) : bool
  (and
    (match (& lease.resolution-authority)
      [(TypedResolutionAuthority.None) false]
      [(TypedResolutionAuthority.Symbols authority)
        (symbols.compiler-resolution-lease-current? authority)])
    (= id.owner lease.resolutions.owner)
    (= id.generation lease.resolutions.generation)
    (= id.revision lease.resolutions.revision)
    (>= id.index 0)
    (< id.index lease.resolution-count)))

(define (typed-literal-ok!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]
  [literal : (& literal ast.AstLiteral)]) : TypedResult
  (try (typed-lease-ok (& store) lease))
  (match literal
    [(ast.AstLiteral.Int _ text)
      (typed-charge! store lease (string.string-length text))]
    [(ast.AstLiteral.Float text)
      (typed-charge! store lease (string.string-length text))]
    [(ast.AstLiteral.String id)
      (if (or
        (and
          (>= id 0)
          (< id (ci.intern-compat-state-pool-len lease.intern-state)))
        (ci.intern-compat-state-generated-id-active? lease.intern-state id))
        (typed-charge!
          store
          lease
          (string.string-length
            (ci.intern-compat-state-str lease.intern-state id)))
        (TypedResult.Err TypedError.Unknown))]
    [(ast.AstLiteral.Bool _) (TypedResult.Ok unit)]
    [(ast.AstLiteral.Char _) (TypedResult.Ok unit)]
    [(ast.AstLiteral.Unit) (TypedResult.Ok unit)]))

(define (typed-operation-payload-ok!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]
  [operation : (& operation TypedOperation)]) : TypedResult
  (match operation
    [(TypedOperation.Literal literal) (typed-literal-ok! store lease literal)]
    [(TypedOperation.Pattern (TypedPattern.Literal literal))
      (typed-literal-ok! store lease literal)]
    ;; The remaining operations carry scalar IDs/operators, not leased bytes.
    [_ (TypedResult.Ok unit)]))

;; Resolved declarations are supplied by inference, never looked up by surface
;; spelling here. Registration makes their body-local identities known.
(define (typed-origin-add!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]
  [source : own.OwnershipSource]) : TypedOriginResult
  (try (typed-charge! store lease 1))
  (try (typed-mint-ok store store.origin-count))
  (try (typed-reserve-records! store lease (+ store.origin-count 1)))
  (unless
    (own.ownership-source-valid? (& source))
    (return (TypedOriginResult.Err TypedError.Shape)))
  (try (typed-charge! store lease (string.string-length (& source.path))))
  (try (typed-charge! store lease (string.string-length (& source.expansion))))
  (let
    [handle : TypedHandle (typed-fresh! store store.origin-count)]
    (set!
      (array-ref store.origins store.origin-count)
      (TypedOrigin handle.serial source))
    (set! store.origin-count (+ store.origin-count 1))
    (TypedOriginResult.Ok (TypedOriginId handle))))

(define (typed-binder-add!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]
  [type : TypedTypeId]
  [kind : TypedBinderKind]
  [origin : TypedOriginId]
  [name : i64]) : TypedBinderResult
  (try (typed-charge! store lease 1))
  (try (typed-mint-ok store store.binder-count))
  (try (typed-reserve-records! store lease (+ store.binder-count 1)))
  (try (typed-type-ok (& store) lease (& type)))
  (try (typed-origin-ok (& store) (& origin)))
  (match (& kind)
    [(TypedBinderKind.Global global)
      (unless
        (typed-global-valid? lease global)
        (return (TypedBinderResult.Err TypedError.Unknown)))]
    [_ unit])
  (let
    [handle : TypedHandle (typed-fresh! store store.binder-count)]
    (set!
      (array-ref store.binders store.binder-count)
      (TypedBinder handle.serial type kind origin name))
    (set! store.binder-count (+ store.binder-count 1))
    (TypedBinderResult.Ok (TypedBinderId handle))))

(define (typed-projection-add!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]
  [container : TypedTypeId]
  [result : TypedTypeId]
  [kind : TypedProjectionKind]
  [origin : TypedOriginId]) : TypedProjectionResult
  (try (typed-charge! store lease 1))
  (try (typed-mint-ok store store.projection-count))
  (try (typed-reserve-records! store lease (+ store.projection-count 1)))
  (try (typed-type-ok (& store) lease (& container)))
  (try (typed-type-ok (& store) lease (& result)))
  (try (typed-origin-ok (& store) (& origin)))
  (unless
    (match (& kind)
      [(TypedProjectionKind.StructField global ordinal)
        (and (typed-global-valid? lease global) (>= ordinal 0))]
      [(TypedProjectionKind.TupleElement ordinal) (>= ordinal 0)]
      [(TypedProjectionKind.FixedArrayElement index) (>= index 0)]
      [(TypedProjectionKind.ArrayElement) true]
      [(TypedProjectionKind.Deref) true]
      [(TypedProjectionKind.Payload global ordinal)
        (and (typed-global-valid? lease global) (>= ordinal 0))])
    (return (TypedProjectionResult.Err TypedError.Unknown)))
  (let
    [handle : TypedHandle (typed-fresh! store store.projection-count)]
    (set!
      (array-ref store.projections store.projection-count)
      (TypedProjection handle.serial container result kind origin))
    (set! store.projection-count (+ store.projection-count 1))
    (TypedProjectionResult.Ok (TypedProjectionId handle))))

;; Records `region` as one this body allocates in (see `arena-regions`).
(define (typed-arena-region-note!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]
  [region : i64]) : TypedResult
  (try (typed-charge! store lease 1))
  (unless
    (typed-arena-region? (& store) region)
    (__tl_array-push! store.arena-regions region))
  (TypedResult.Ok unit))

(define (typed-arena-regions-copy [store : (& store TypedStore)]) : (__tl_dyn-array
    i64)
  (clone store.arena-regions))

(define (typed-arena-region? [store : (& store TypedStore)] [region : i64]) : bool
  (let
    [index : i64 0]
    [found : bool false]
    (while (and (not found) (< index (array-length store.arena-regions)))
      (when (= (array-ref store.arena-regions index) region) (set! found true))
      (set! index (+ index 1)))
    found))

;; A binder is checked (`typed-binder-ok`) before this kind query.
(define (typed-binder-temporary?
  [store : (& store TypedStore)]
  [binder : (& binder TypedBinderId)]) : bool
  (match (& (array-ref store.binders binder.handle.index).kind)
    [(TypedBinderKind.Temporary) true]
    [_ false]))

(define (typed-place-add!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]
  [kind : TypedPlaceKind]) : TypedPlaceResult
  (try (typed-charge! store lease 1))
  (try (typed-mint-ok store store.place-count))
  (try (typed-reserve-records! store lease (+ store.place-count 1)))
  (let
    [index-count : i64 0]
    [type : TypedTypeId
      (match (& kind)
        [(TypedPlaceKind.Root binder)
          (try (typed-binder-ok (& store) binder))
          (when (typed-binder-temporary? (& store) binder) (set! index-count 1))
          (TypedTypeId
            (typed-handle-copy
              (& (array-ref store.binders binder.handle.index).type.handle)))]
        [(TypedPlaceKind.Projection parent projection)
          (try (typed-place-shape-ok (& store) parent))
          (try (typed-projection-ok (& store) projection))
          (let
            [prefix : (& store TypedPlace)
              (& (array-ref store.places parent.handle.index))]
            [step : (& store TypedProjection)
              (& (array-ref store.projections projection.handle.index))]
            (unless
              (typed-handle-equal?
                (& prefix.type.handle)
                (& step.container-type.handle))
              (return (TypedPlaceResult.Err TypedError.Shape)))
            (set!
              index-count
              (+
                prefix.index-count
                (typed-projection-index-count (& step.kind))))
            (TypedTypeId (typed-handle-copy (& step.result-type.handle))))])]
    (when
      (> index-count store.limits.children)
      (try (typed-resource-fail! store TypedError.Budget)))
    (try (typed-type-ok (& store) lease (& type)))
    (let
      [handle : TypedHandle (typed-fresh! store store.place-count)]
      (set!
        (array-ref store.places store.place-count)
        (TypedPlace handle.serial type kind index-count))
      (set! store.place-count (+ store.place-count 1))
      (TypedPlaceResult.Ok (TypedPlaceId handle)))))

(define (typed-call-add!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]
  [signature : TypedTypeId]
  [kind : TypedCallKind]
  [argument-count : i64]) : TypedCallResult
  (try (typed-charge! store lease 1))
  (try (typed-mint-ok store store.call-count))
  (try (typed-reserve-records! store lease (+ store.call-count 1)))
  (try (typed-type-ok (& store) lease (& signature)))
  (unless
    (and (>= argument-count 0) (<= argument-count store.limits.children))
    (return (TypedCallResult.Err TypedError.Shape)))
  (match (& kind)
    [(TypedCallKind.Direct global)
      (unless
        (typed-global-valid? lease global)
        (return (TypedCallResult.Err TypedError.Unknown)))]
    [(TypedCallKind.Declared key)
      (unless (>= key 0) (return (TypedCallResult.Err TypedError.Unknown)))]
    [(TypedCallKind.Construct) unit]
    [(TypedCallKind.Foreign key)
      (unless (>= key 0) (return (TypedCallResult.Err TypedError.Unknown)))]
    [(TypedCallKind.Indirect _) unit]
    [(TypedCallKind.Discharge key)
      (unless (>= key 0) (return (TypedCallResult.Err TypedError.Unknown)))])
  (unless
    (=
      (typed-call-signature-arity (& store) lease (& signature))
      argument-count)
    (return (TypedCallResult.Err TypedError.Shape)))
  (let
    [handle : TypedHandle (typed-fresh! store store.call-count)]
    (set!
      (array-ref store.calls store.call-count)
      (TypedCall handle.serial signature kind argument-count))
    (set! store.call-count (+ store.call-count 1))
    (TypedCallResult.Ok (TypedCallId handle))))

;; Operation-specific shape rules are deliberately separate from ownership
;; legality. A shaped Read can still read an uninitialized/moved binder.
(define (typed-operation-ok
  [store : (& store TypedStore)]
  [operation : (& operation TypedOperation)]
  [count : i64]) : TypedResult
  (let
    [shape : bool
      (match operation
        [(TypedOperation.Literal _) (= count 0)]
        [(TypedOperation.Read id)
          (try (typed-binder-ok store id))
          (= count 0)]
        [(TypedOperation.Initialize id)
          (try (typed-binder-ok store id))
          (= count 1)]
        [(TypedOperation.Assign id)
          (try (typed-binder-ok store id))
          (= count 1)]
        [(TypedOperation.Project id)
          (try (typed-projection-ok store id))
          (= count 1)]
        [(TypedOperation.FormPlace id)
          (try (typed-place-shape-ok store id))
          (= count (array-ref store.places id.handle.index).index-count)]
        [(TypedOperation.CopyPlace id)
          (try (typed-place-shape-ok store id))
          (= count 1)]
        [(TypedOperation.MovePlace id)
          (try (typed-place-shape-ok store id))
          (= count 1)]
        [(TypedOperation.AssignPlace id)
          (try (typed-place-shape-ok store id))
          (= count 2)]
        [(TypedOperation.ReplacePlace id)
          (try (typed-place-shape-ok store id))
          (= count 2)]
        [(TypedOperation.Call id)
          (try (typed-call-ok store id))
          (let
            [call : (& store TypedCall)
              (& (array-ref store.calls id.handle.index))]
            ;; Every call retains child 0 as the evaluated callee, followed by
            ;; arguments in source order. A known direct target never erases
            ;; effects in a wrapped callee or changes its evaluation position.
            ;; A Declared callee is a bare declaration name: it has no
            ;; evaluation, so its children are the arguments alone.
            (=
              count
              (+
                call.argument-count
                (match (& call.kind)
                  [(TypedCallKind.Declared _) 0]
                  [(TypedCallKind.Construct) 0]
                  [(TypedCallKind.Foreign _) 0]
                  [(TypedCallKind.Discharge _) 0]
                  [_ 1]))))]
        [(TypedOperation.Unary _) (= count 1)]
        [(TypedOperation.Binary _) (= count 2)]
        [(TypedOperation.Sequence) (> count 0)]
        [(TypedOperation.If) (= count 3)]
        [(TypedOperation.While) (= count 2)]
        [(TypedOperation.Break) (= count 0)]
        [(TypedOperation.Continue) (= count 0)]
        [(TypedOperation.Return) (<= count 1)]
        [(TypedOperation.Primitive primitive)
          (= count (typed-primitive-arity primitive))]
        [(TypedOperation.Borrow _) (= count 1)]
        [(TypedOperation.Invalidate id)
          (try (typed-binder-ok store id))
          (= count 0)]
        [(TypedOperation.EndBrand id)
          (try (typed-binder-ok store id))
          (= count 0)]
        [(TypedOperation.ThreadUsers id)
          (try (typed-binder-ok store id))
          (= count 0)]
        [(TypedOperation.RequireReleased checked owner)
          (try (typed-binder-ok store checked))
          (try (typed-binder-ok store owner))
          (= count 0)]
        [(TypedOperation.RequireUnheld checked arena _)
          (try (typed-binder-ok store checked))
          (try (typed-binder-ok store arena))
          (= count 0)]
        [(TypedOperation.Match _) (>= count 2)]
        [(TypedOperation.Arm) (= count 2)]
        [(TypedOperation.Pattern pattern)
          (match pattern
            [(TypedPattern.Bind id)
              (try (typed-binder-ok store id))
              (<= count 1)]
            [(TypedPattern.Wildcard) (<= count 1)]
            [(TypedPattern.Literal _) (<= count 1)]
            [(TypedPattern.Or) (<= count 1)]
            [(TypedPattern.Alternatives) (>= count 2)]
            [_ true])])]
    (if shape
      (TypedResult.Ok unit)
      (TypedResult.Err TypedError.Shape))))

(define (typed-place-operation-type-ok
  [store : (& store TypedStore)]
  [place : (& place TypedPlaceId)]
  [type : (& type TypedTypeId)]) : TypedResult
  (try (typed-place-shape-ok store place))
  (if (typed-handle-equal?
    (& type.handle)
    (& (array-ref store.places place.handle.index).type.handle))
    (TypedResult.Ok unit)
    (TypedResult.Err TypedError.Shape)))

(define (typed-category-ok
  [store : (& store TypedStore)]
  [node : (& node TypedOccurrence)]) : TypedResult
  (match (& node.operation)
    [(TypedOperation.FormPlace place)
      (try (typed-place-operation-type-ok store place (& node.type)))
      (if (match (& node.category)
        [(TypedOccurrenceCategory.Place actual)
          (typed-handle-equal? (& actual.handle) (& place.handle))]
        [(TypedOccurrenceCategory.Value) false])
        (TypedResult.Ok unit)
        (TypedResult.Err TypedError.Shape))]
    [_
      (if (match (& node.category)
        [(TypedOccurrenceCategory.Value) true]
        [(TypedOccurrenceCategory.Place _) false])
        (TypedResult.Ok unit)
        (TypedResult.Err TypedError.Shape))]))

(define (typed-acquisition-child-ok
  [place : (& place TypedPlaceId)]
  [child : (& child TypedOccurrence)]) : TypedResult
  (if (match (& child.category)
    [(TypedOccurrenceCategory.Place actual)
      (typed-handle-equal? (& actual.handle) (& place.handle))]
    [(TypedOccurrenceCategory.Value) false])
    (TypedResult.Ok unit)
    (TypedResult.Err TypedError.Shape)))

(define (typed-child-category-ok
  [store : (& store TypedStore)]
  [operation : (& operation TypedOperation)]
  [child : (& child TypedOccurrence)]) : TypedResult
  (try (typed-category-ok store child))
  (match operation
    [(TypedOperation.CopyPlace place) (typed-acquisition-child-ok place child)]
    [(TypedOperation.MovePlace place) (typed-acquisition-child-ok place child)]
    ;; The formed place, then the assigned value.
    [(TypedOperation.AssignPlace _) (TypedResult.Ok unit)]
    [(TypedOperation.ReplacePlace _) (TypedResult.Ok unit)]
    [(TypedOperation.Borrow _)
      (match (& child.category)
        [(TypedOccurrenceCategory.Place _) (TypedResult.Ok unit)]
        [(TypedOccurrenceCategory.Value) (TypedResult.Err TypedError.Shape)])]
    ;; A scrutinee or pattern position may be a formed place.
    [(TypedOperation.Match _) (TypedResult.Ok unit)]
    [(TypedOperation.Pattern _) (TypedResult.Ok unit)]
    ;; An element moved out of a `for` loop's private array (builtin form
    ;; 152) takes the array's formed place.
    [(TypedOperation.Primitive (TypedPrimitive.Builtin code _))
      (if (or
        (= code 152)
        (match (& child.category)
          [(TypedOccurrenceCategory.Value) true]
          [(TypedOccurrenceCategory.Place _) false]))
        (TypedResult.Ok unit)
        (TypedResult.Err TypedError.Shape))]
    [_
      (if (match (& child.category)
        [(TypedOccurrenceCategory.Value) true]
        [(TypedOccurrenceCategory.Place _) false])
        (TypedResult.Ok unit)
        (TypedResult.Err TypedError.Shape))]))

(define (typed-occurrence-add!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]
  [type : TypedTypeId]
  [syntax : TypedSyntax]
  [origin : TypedOriginId]
  [operation : TypedOperation]
  [children : (& children (__tl_dyn-array TypedOccurrenceId))]) : TypedOccurrenceResult
  (try (typed-charge! store lease 1))
  (try (typed-mint-ok store store.occurrence-count))
  (try (typed-reserve-records! store lease (+ store.occurrence-count 1)))
  (try (typed-type-ok (& store) lease (& type)))
  (try (typed-origin-ok (& store) (& origin)))
  (try (typed-operation-payload-ok! store lease (& operation)))
  (match (& operation)
    [(TypedOperation.FormPlace place)
      (try (typed-place-operation-type-ok (& store) place (& type)))]
    [(TypedOperation.CopyPlace place)
      (try (typed-place-operation-type-ok (& store) place (& type)))]
    [(TypedOperation.MovePlace place)
      (try (typed-place-operation-type-ok (& store) place (& type)))]
    [_ unit])
  (match (& syntax)
    [(TypedSyntax.Source index)
      (unless
        (and
          (>= index 0)
          (< index (ast.ast-node-pool-context-expr-len lease.pools)))
        (return (TypedOccurrenceResult.Err TypedError.Unknown)))]
    [(TypedSyntax.Generated) unit])
  (let
    [count : i64 (array-length children)]
    (try (typed-operation-ok (& store) (& operation) count))
    (unless
      (<= count (- store.limits.children store.child-count))
      (try (typed-resource-fail! store TypedError.Budget)))
    (try (typed-charge! store lease count))
    (try (typed-reserve-children! store lease (+ store.child-count count)))
    (let
      [index : i64 0]
      (while (< index count)
        (begin
          (try (typed-occurrence-ok (& store) (& (array-ref children index))))
          (try
            (typed-child-category-ok
              (& store)
              (& operation)
              (&
                (array-ref
                  store.occurrences
                  (array-ref children index).handle.index))))
          (set! index (+ index 1)))))
    ;; All checks precede mutation; a rejected parent cannot publish edges.
    (let
      [category : TypedOccurrenceCategory
        (match (& operation)
          [(TypedOperation.FormPlace place)
            (TypedOccurrenceCategory.Place
              (TypedPlaceId (typed-handle-copy (& place.handle))))]
          [_ TypedOccurrenceCategory.Value])]
      [handle : TypedHandle (typed-fresh! store store.occurrence-count)]
      [index : i64 0]
      (while (< index count)
        (set!
          (array-ref store.children (+ store.child-count index))
          (TypedOccurrenceId
            (typed-handle-copy (& (array-ref children index).handle))))
        (set! index (+ index 1)))
      (set!
        (array-ref store.occurrences store.occurrence-count)
        (TypedOccurrence
          handle.serial
          type
          category
          syntax
          origin
          operation
          store.child-count
          count))
      (set! store.child-count (+ store.child-count count))
      (set! store.occurrence-count (+ store.occurrence-count 1))
      (TypedOccurrenceResult.Ok (TypedOccurrenceId handle)))))

(define (typed-attempt-begin!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]
  [mode : TypedMode]) : TypedAttemptResult
  (try (typed-charge! store lease 1))
  (when
    (and
      (not (typed-executable? (& store)))
      (match (& mode)
        [(TypedMode.Executable) true]
        [(TypedMode.Query) false]))
    (return (TypedAttemptResult.Err TypedError.Query)))
  (when
    (>= store.attempt-count store.limits.attempts)
    (try (typed-resource-fail! store TypedError.Budget)))
  (when
    (= store.next-serial (cast 18446744073709551615 : u64))
    (try (typed-resource-fail! store TypedError.Exhausted)))
  (try (typed-reserve-attempts! store lease (+ store.attempt-count 1)))
  (let
    [handle : TypedHandle (typed-fresh! store store.attempt-count)]
    (set!
      (array-ref store.attempts store.attempt-count)
      (TypedCheckpoint
        handle.serial
        store.occurrence-count
        store.binder-count
        store.projection-count
        store.place-count
        store.call-count
        store.origin-count
        store.type-count
        store.child-count
        (typed-mode-copy (& store.mode))))
    (set! store.attempt-count (+ store.attempt-count 1))
    (set! store.mode mode)
    (TypedAttemptResult.Ok (TypedAttemptId handle))))

(define (typed-attempt-finish!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]
  [id : TypedAttemptId]
  [commit? : bool]) : TypedResult
  (try (typed-charge! store lease 1))
  (unless
    (typed-handle-range? (& store) (& id.handle) store.attempt-count)
    (return (TypedResult.Err TypedError.Stale)))
  (unless
    (= id.handle.index (- store.attempt-count 1))
    (return (TypedResult.Err TypedError.Order)))
  (let
    [checkpoint : TypedCheckpoint
      (typed-checkpoint-copy (& (array-ref store.attempts id.handle.index)))]
    (unless
      (= checkpoint.serial id.handle.serial)
      (return (TypedResult.Err TypedError.Stale)))
    (unless
      commit?
      (set! store.occurrence-count checkpoint.occurrences)
      (set! store.binder-count checkpoint.binders)
      (set! store.projection-count checkpoint.projections)
      (set! store.place-count checkpoint.places)
      (set! store.call-count checkpoint.calls)
      (set! store.origin-count checkpoint.origins)
      (set! store.type-count checkpoint.types)
      (set! store.child-count checkpoint.children))
    (set! store.mode checkpoint.previous-mode)
    (set! store.attempt-count (- store.attempt-count 1))
    (TypedResult.Ok unit)))

(define (typed-occurrence-get!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]
  [id : TypedOccurrenceId]) : (TypedNodeResult store)
  (try (typed-charge! store lease 1))
  (try (typed-occurrence-ok (& store) (& id)))
  (try
    (typed-category-ok
      (& store)
      (& (array-ref store.occurrences id.handle.index))))
  (TypedNodeResult.Ok (& (array-ref store.occurrences id.handle.index))))

(define (typed-place-get!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]
  [id : TypedPlaceId]) : (TypedPlaceView store)
  (try (typed-charge! store lease 1))
  (try (typed-place-shape-ok (& store) (& id)))
  (try
    (typed-type-ok
      (& store)
      lease
      (& (array-ref store.places id.handle.index).type)))
  (TypedPlaceView.Ok (& (array-ref store.places id.handle.index))))

(define (typed-child-get!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]
  [id : TypedOccurrenceId]
  [index : i64]) : TypedChildResult
  (try (typed-charge! store lease 1))
  (try (typed-occurrence-ok (& store) (& id)))
  (let
    [node : (& store TypedOccurrence)
      (& (array-ref store.occurrences id.handle.index))]
    (try (typed-category-ok (& store) node))
    ;; Subtraction follows nonnegative/start-bound checks, so neither a
    ;; forged span nor a full-width ordinal can overflow before rejection.
    (if (not
      (and
        (>= node.child-start 0)
        (>= node.child-count 0)
        (<= node.child-start store.child-count)
        (<= node.child-count (- store.child-count node.child-start))))
      (TypedChildResult.Err TypedError.Shape)
      (if (and (>= index 0) (< index node.child-count))
        (TypedChildResult.Ok
          (TypedOccurrenceId
            (typed-handle-copy
              (& (array-ref store.children (+ node.child-start index)).handle))))
        (TypedChildResult.Err TypedError.Unknown)))))

(define (typed-type-get!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]
  [id : TypedTypeId]) : (TypedTypeResult store)
  (try (typed-charge! store lease 1))
  (try (typed-type-ok (& store) lease (& id)))
  (TypedTypeResult.Ok (& (array-ref store.types id.handle.index).value)))

;; Revocation is unconditional and allocation-free, including after exhaustion.
;; It does not dereference any leased payload and cannot publish a result.
(define (typed-store-retire! [store : (&mut store TypedStore)]) : unit
  (set! store.live? false))

(define (typed-origin-get!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]
  [id : TypedOriginId]) : (TypedOriginView store)
  (try (typed-charge! store lease 1))
  (try (typed-origin-ok (& store) (& id)))
  (TypedOriginView.Ok (& (array-ref store.origins id.handle.index).source)))

(define (typed-binder-get!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]
  [id : TypedBinderId]) : (TypedBinderView store)
  (try (typed-charge! store lease 1))
  (try (typed-binder-ok (& store) (& id)))
  (TypedBinderView.Ok (& (array-ref store.binders id.handle.index))))

;; Type records in publication order. Ownership normalization classifies each
;; one before it reads the body; a rolled-back attempt's records are already
;; truncated from the count.
(define (typed-type-count!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]) : TypedCountResult
  (try (typed-charge! store lease 1))
  (TypedCountResult.Ok store.type-count))

(define (typed-type-at!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]
  [index : i64]) : TypedTypeIdResult
  (try (typed-charge! store lease 1))
  (if (and (>= index 0) (< index store.type-count))
    (TypedTypeIdResult.Ok
      (TypedTypeId
        (TypedHandle
          (typed-body-copy (& store.body))
          index
          (array-ref store.types index).serial)))
    (TypedTypeIdResult.Err TypedError.Unknown)))

;; An owned copy of one type record's canonical value, for a consumer that
;; classifies it outside the lease (ownership type classes).
(define (typed-type-value-at!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]
  [index : i64]) : TypedTypeValueResult
  (try (typed-charge! store lease 1))
  (if (and (>= index 0) (< index store.type-count))
    (TypedTypeValueResult.Ok (clone (array-ref store.types index).value))
    (TypedTypeValueResult.Err TypedError.Unknown)))

;; Signature consumers must see unused parameters as well as referenced ones.
;; Enumeration is leased, bounded by the published count, and preserves the
;; original serial rather than manufacturing a new binding identity.
(define (typed-place-count!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]) : TypedCountResult
  (try (typed-charge! store lease 1))
  (TypedCountResult.Ok store.place-count))

(define (typed-place-at!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]
  [index : i64]) : TypedPlaceResult
  (try (typed-charge! store lease 1))
  (if (and (>= index 0) (< index store.place-count))
    (TypedPlaceResult.Ok
      (TypedPlaceId
        (TypedHandle
          (typed-body-copy (& store.body))
          index
          (array-ref store.places index).serial)))
    (TypedPlaceResult.Err TypedError.Unknown)))

(define (typed-binder-count!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]) : TypedCountResult
  (try (typed-charge! store lease 1))
  (TypedCountResult.Ok store.binder-count))

(define (typed-binder-at!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]
  [index : i64]) : TypedBinderResult
  (try (typed-charge! store lease 1))
  (if (and (>= index 0) (< index store.binder-count))
    (TypedBinderResult.Ok
      (TypedBinderId
        (TypedHandle
          (typed-body-copy (& store.body))
          index
          (array-ref store.binders index).serial)))
    (TypedBinderResult.Err TypedError.Unknown)))

(define (typed-projection-get!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]
  [id : TypedProjectionId]) : (TypedProjectionView store)
  (try (typed-charge! store lease 1))
  (try (typed-projection-ok (& store) (& id)))
  (TypedProjectionView.Ok (& (array-ref store.projections id.handle.index))))

(define (typed-call-count!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]) : TypedCountResult
  (try (typed-charge! store lease 1))
  (TypedCountResult.Ok store.call-count))

(define (typed-call-at!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]
  [index : i64]) : TypedCallResult
  (try (typed-charge! store lease 1))
  (if (and (>= index 0) (< index store.call-count))
    (TypedCallResult.Ok
      (TypedCallId
        (TypedHandle
          (typed-body-copy (& store.body))
          index
          (array-ref store.calls index).serial)))
    (TypedCallResult.Err TypedError.Unknown)))

;; The body's occurrences in record order, as the call records are listed.
(define (typed-occurrence-count!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]) : TypedCountResult
  (try (typed-charge! store lease 1))
  (TypedCountResult.Ok store.occurrence-count))

(define (typed-occurrence-at!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]
  [index : i64]) : TypedOccurrenceResult
  (try (typed-charge! store lease 1))
  (if (and (>= index 0) (< index store.occurrence-count))
    (TypedOccurrenceResult.Ok
      (TypedOccurrenceId
        (TypedHandle
          (typed-body-copy (& store.body))
          index
          (array-ref store.occurrences index).serial)))
    (TypedOccurrenceResult.Err TypedError.Unknown)))

(define (typed-call-get!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]
  [id : TypedCallId]) : (TypedCallView store)
  (try (typed-charge! store lease 1))
  (try (typed-call-ok (& store) (& id)))
  (TypedCallView.Ok (& (array-ref store.calls id.handle.index))))