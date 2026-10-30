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

;; A lease is a value fixed at construction. A different body, pool, interner
;; or resolver is a different lease, built by `typed-body-lease` with a fresh
;; serial; a store validates a lease in full before it first accepts that
;; serial (`typed-lease-bind!`). Serials are never reused; zero never binds.
(defstruct TypedBodyLease
  (:lifetimes intern)
  (body own.OwnershipBodyId)
  (pools ast.AstNodePoolContext)
  (intern-state (& intern ci.InternCompatState))
  (resolutions own.OwnershipBodyId)
  (resolution-count i64)
  (resolution-authority (TypedResolutionAuthority intern))
  (live? bool)
  (serial u64))

(define typed-lease-next-serial : u64
  (cast 1 : u64))

(define (typed-body-lease
  [body : own.OwnershipBodyId]
  [pools : ast.AstNodePoolContext]
  [intern-state : (& intern ci.InternCompatState)]
  [resolutions : own.OwnershipBodyId]
  [resolution-count : i64]
  [authority : (TypedResolutionAuthority intern)]) : (TypedBodyLease intern)
  (let
    [serial : u64 typed-lease-next-serial]
    (if (= serial (cast 18446744073709551615 : u64))
      (set! serial (cast 0 : u64))
      (set! typed-lease-next-serial (+ serial (cast 1 : u64))))
    (TypedBodyLease
      body
      pools
      intern-state
      resolutions
      resolution-count
      authority
      true
      serial)))

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

;; The store's pinned resolver stamps equal the lease's, and the lease's are
;; current in the live maps (no authority pins zero stamps and is current).
(define (typed-resolution-stamps-ok?
  [store : (& store TypedStore)]
  [authority : (& authority (TypedResolutionAuthority context))]) : bool
  (match authority
    [(TypedResolutionAuthority.None)
      (and
        (= store.resolution-symbol.owner (cast 0 : u64))
        (= store.resolution-symbol.revision (cast 0 : u64))
        (= store.resolution-field.owner (cast 0 : u64))
        (= store.resolution-field.revision (cast 0 : u64)))]
    [(TypedResolutionAuthority.Symbols lease)
      (and
        (= store.resolution-symbol.owner lease.symbol-revision.owner)
        (= store.resolution-symbol.revision lease.symbol-revision.revision)
        (= store.resolution-field.owner lease.field-revision.owner)
        (= store.resolution-field.revision lease.field-revision.revision)
        (symbols.compiler-resolution-lease-current? lease))]))

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
  ;; First, so a record table's fresh cells (an operation's default variant)
  ;; are all zero bytes and allocate by zeroing, not cell by cell.
  (Sequence)
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
  ;; Before an end of the arena the second binder names (0 a safe destroy, 1
  ;; a safe rewind, 2 a call passing it to an `:invalidate` parameter), the
  ;; first, a `with` cleanup owner holding values of that arena, must no
  ;; longer hold them (its scope-exit cleanup would read freed storage). No
  ;; child, and the result is unit.
  (RequireUnheld TypedBinderId TypedBinderId i64))

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
  (arena-regions (__tl_dyn-array i64))
  ;; The serial of the lease validated against this store
  ;; (`typed-lease-bound?`): the opening lease, or one bound since.
  (lease-serial u64)
  ;; The record capacity charged so far, shared by the seven record tables
  ;; (`typed-reserve-records!`).
  (record-capacity i64))

(defenum TypedStoreResult
  (Ok TypedStore)
  (Err TypedError))

(define (typed-body-valid? [body : (& body own.OwnershipBodyId)]) : bool
  (and (> body.owner 0) (> body.generation 0) (> body.revision 0)))

(define (typed-body-copy [body : (& body own.OwnershipBodyId)]) : own.OwnershipBodyId
  (own.OwnershipBodyId body.owner body.generation body.revision))

;; Handles are copied and compared on every access: spell their words out
;; rather than calling the body-id helpers.
(define (typed-handle-copy [handle : (& handle TypedHandle)]) : TypedHandle
  (TypedHandle
    (own.OwnershipBodyId
      handle.body.owner
      handle.body.generation
      handle.body.revision)
    handle.index
    handle.serial))

(define (typed-handle-equal?
  [left : (& left TypedHandle)]
  [right : (& right TypedHandle)]) : bool
  (and
    (= left.serial right.serial)
    (= left.index right.index)
    (= left.body.owner right.body.owner)
    (= left.body.generation right.body.generation)
    (= left.body.revision right.body.revision)))

(define (typed-mode-copy [mode : (& mode TypedMode)]) : TypedMode
  (match mode
    [(TypedMode.Executable) TypedMode.Executable]
    [(TypedMode.Query) TypedMode.Query]))

(define (typed-function-arity [value : (& value ast.AstType)]) : i64
  (match value
    [(ast.AstType.Func params-signature-box)
      (let
        [params-signature
          (ast.ast-function-signature-view (deref params-signature-box))]
        (ast.ast-type-list-len (& params-signature.params)))]
    [_ -1]))

(define (typed-call-signature-arity
  [store : (& store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]
  [signature : (& signature TypedTypeId)]) : i64
  (match (typed-type-ok store signature)
    [(TypedResult.Err _) -1]
    [(TypedResult.Ok _)
      (match (& (array-ref store.types signature.handle.index).value)
        [(ast.AstType.Func _)
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
          (> lease.serial (cast 0 : u64))
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
          ;; Each record table is allocated when it is first needed
          ;; (`typed-reserve-records!`), within the charged capacity.
          (__tl_make-array TypedOccurrence 0)
          (__tl_make-array TypedBinder 0)
          (__tl_make-array TypedProjection 0)
          (__tl_make-array TypedPlace 0)
          (__tl_make-array TypedCall 0)
          (__tl_make-array TypedOrigin 0)
          (__tl_make-array TypedType 0)
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
          (__tl_make-array i64 0)
          ;; Bound at open: the checks above validated this lease, and the
          ;; store's identity is copied from it.
          lease.serial
          capacity.records))]))

;; The full check of a store against a lease, run once when a store binds a
;; lease: liveness, every identity the store pinned at open (body,
;; resolutions and count, resolver stamps, pools, interner table and
;; generation) and the resolver's live revisions. A body binds its lease once:
;; the store is leased for the whole body and nothing the check reads changes
;; while the body is checked, so later accesses compare only the serial. The
;; store's own mutators keep every count within its array (and `array-ref`
;; bounds every index), so its table extents are not checked here either.
(define (typed-store-validate
  [store : (& store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]) : TypedResult
  (if (and
    store.live?
    lease.live?
    (> lease.serial (cast 0 : u64))
    (own.ownership-body-id-equal? (& store.body) (& lease.body))
    (own.ownership-body-id-equal? (& store.resolutions) (& lease.resolutions))
    (= store.resolution-count lease.resolution-count)
    (typed-resolution-stamps-ok? store (& lease.resolution-authority))
    (= store.expr-pool lease.pools.expr-pool)
    (= store.type-pool lease.pools.type-pool)
    (= store.pool-owner lease.pools.owner-arena)
    (= store.intern-table (ci.intern-compat-state-table-id lease.intern-state))
    (=
      store.intern-generation
      (ci.intern-compat-state-generation lease.intern-state)))
    (TypedResult.Ok unit)
    (TypedResult.Err TypedError.Lease)))

;; A bound lease: the store is live and the presented lease is the one the
;; full check accepted (lease fields are fixed at construction, so a serial
;; names them all). A different lease binds only after its own full check.
(define (typed-lease-bound?
  [store : (& store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]) : bool
  (and store.live? (= store.lease-serial lease.serial)))

(define (typed-lease-ok
  [store : (& store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]) : TypedResult
  (if (typed-lease-bound? store lease)
    (TypedResult.Ok unit)
    (typed-store-validate store lease)))

;; Bind the presented lease: the full check unless it is already bound.
(define (typed-lease-bind!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]) : TypedResult
  (if (typed-lease-bound? (& store) lease)
    (TypedResult.Ok unit)
    (begin
      (try (typed-store-validate (& store) lease))
      (set! store.lease-serial lease.serial)
      (TypedResult.Ok unit))))

;; Every write charges here, so its common case is one flat test: a bound
;; lease (`typed-lease-bound?`, spelled out so no call or frame is needed), no
;; latched failure, and units within the budget. That is exactly when
;; `typed-charge-checked!` would bind nothing, fail nothing and add the units,
;; so the result and the store's state are the same.
(define (typed-charge!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]
  [units : i64]) : TypedResult
  (if (and
    store.live?
    (= store.lease-serial lease.serial)
    (not store.failed?)
    (>= units 0)
    (<= units (- store.limits.work store.work)))
    (begin
      (set! store.work (+ store.work units))
      (TypedResult.Ok unit))
    (typed-charge-checked! store lease units)))

(define (typed-charge-checked!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]
  [units : i64]) : TypedResult
  (try (typed-lease-bind! store lease))
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

;; Replaces `cells` with an array of `capacity` cells whose first `count` hold
;; its live rows, moved bitwise: the old array is dropped as it is replaced,
;; so no row keeps two owners, and no placeholder is built to fill the slots
;; it vacates. The cells past `count` are never read before a row is written.
(defmacro (typed-grow-cells!
  [cells : Expr]
  [count : Expr]
  [capacity : Expr]
  ;; Spliced into the array's element type.
  ;; lint-allow: unused-variable
  [item-ty : Expr]) : Expr
  `(let
    [grown : (__tl_dyn-array ,item-ty) (__tl_make-array ,item-ty ,capacity)]
    [at : i64 0]
    (while (< at ,count)
      (set!
        (array-ref grown at)
        (unsafe
          (ptr-read (ptr-offset (__tl_array-data ,cells) at))))
      (set! at (+ at 1)))
    (set! ,cells grown)))

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
;; The seven record tables share one charged capacity, `record-capacity`:
;; growing it charges the initialization and moves of all seven tables, as
;; when they were allocated together. Each table is allocated only when a
;; record of it needs room, at the shared capacity, so a table a body barely
;; uses is never grown with the others. The charges are those of growing all
;; seven at once; the bytes allocated never exceed them.
(defenum TypedTable
  (Occurrences)
  (Binders)
  (Projections)
  (Places)
  (Calls)
  (Origins)
  (Types))

(define (typed-table-length
  [store : (& store TypedStore)]
  [table : (& table TypedTable)]) : i64
  (match table
    [(TypedTable.Occurrences) (array-length store.occurrences)]
    [(TypedTable.Binders) (array-length store.binders)]
    [(TypedTable.Projections) (array-length store.projections)]
    [(TypedTable.Places) (array-length store.places)]
    [(TypedTable.Calls) (array-length store.calls)]
    [(TypedTable.Origins) (array-length store.origins)]
    [(TypedTable.Types) (array-length store.types)]))

(define (typed-reserve-records!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]
  [needed : i64]
  [table : TypedTable]) : TypedResult
  (try (typed-charge! store lease 1))
  (cond
    [(or (< needed 0) (> needed store.limits.records))
      (typed-resource-fail! store TypedError.Budget)]
    [(> needed store.record-capacity)
      (typed-grow-records! store lease needed table)]
    [(> needed (typed-table-length (& store) (& table)))
      (typed-grow-table! store (& table))]
    [else (TypedResult.Ok unit)]))

;; Growth runs out of line, so a reservation that fits needs no frame for it.
(define (typed-grow-records!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]
  [needed : i64]
  [table : TypedTable]) : TypedResult
  (let
    [old : i64 store.record-capacity]
    [capacity : i64 (typed-grown-capacity old needed store.limits.records)]
    ;; Upper-bound all live-row moves by the previous capacity. Both
    ;; initialization and movement are charged before any allocation.
    [charged : TypedLimits (TypedLimits (+ capacity old) 0 0 0)]
    (try (typed-charge! store lease (typed-setup-work (& charged))))
    (set! store.record-capacity capacity)
    (typed-grow-table! store (& table))))

;; Grows one table to the shared capacity, already charged.
(define (typed-grow-table!
  [store : (&mut store TypedStore)]
  [table : (& table TypedTable)]) : TypedResult
  (let
    [capacity : i64 store.record-capacity]
    (match table
      [(TypedTable.Occurrences)
        (typed-grow-cells!
          store.occurrences
          store.occurrence-count
          capacity
          TypedOccurrence)]
      [(TypedTable.Binders)
        (typed-grow-cells!
          store.binders
          store.binder-count
          capacity
          TypedBinder)]
      [(TypedTable.Projections)
        (typed-grow-cells!
          store.projections
          store.projection-count
          capacity
          TypedProjection)]
      [(TypedTable.Places)
        (typed-grow-cells! store.places store.place-count capacity TypedPlace)]
      [(TypedTable.Calls)
        (typed-grow-cells! store.calls store.call-count capacity TypedCall)]
      [(TypedTable.Origins)
        (typed-grow-cells!
          store.origins
          store.origin-count
          capacity
          TypedOrigin)]
      [(TypedTable.Types)
        (typed-grow-cells! store.types store.type-count capacity TypedType)])
    (TypedResult.Ok unit)))

(define (typed-reserve-children!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]
  [needed : i64]) : TypedResult
  (try (typed-charge! store lease 1))
  (cond
    [(or (< needed 0) (> needed store.limits.children))
      (typed-resource-fail! store TypedError.Budget)]
    [(> needed (array-length store.children))
      (typed-grow-children! store lease needed)]
    [else (TypedResult.Ok unit)]))

;; Growth runs out of line, so a reservation that fits needs no frame for it.
(define (typed-grow-children!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]
  [needed : i64]) : TypedResult
  (let
    [capacity : i64
      (typed-grown-capacity
        (array-length store.children)
        needed
        store.limits.children)]
    (try
      (typed-charge!
        store
        lease
        (*
          (+ capacity store.child-count)
          (comptime (size-of (type TypedOccurrenceId))))))
    (typed-grow-cells!
      store.children
      store.child-count
      capacity
      TypedOccurrenceId)
    (TypedResult.Ok unit)))

(define (typed-reserve-attempts!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]
  [needed : i64]) : TypedResult
  (try (typed-charge! store lease 1))
  (cond
    [(or (< needed 0) (> needed store.limits.attempts))
      (typed-resource-fail! store TypedError.Budget)]
    [(> needed (array-length store.attempts))
      (typed-grow-attempts! store lease needed)]
    [else (TypedResult.Ok unit)]))

;; Growth runs out of line, so a reservation that fits needs no frame for it.
(define (typed-grow-attempts!
  [store : (&mut store TypedStore)]
  [lease : (& lease (TypedBodyLease intern))]
  [needed : i64]) : TypedResult
  (let
    [capacity : i64
      (typed-grown-capacity
        (array-length store.attempts)
        needed
        store.limits.attempts)]
    (try
      (typed-charge!
        store
        lease
        (*
          (+ capacity store.attempt-count)
          (comptime (size-of (type TypedCheckpoint))))))
    (typed-grow-cells!
      store.attempts
      store.attempt-count
      capacity
      TypedCheckpoint)
    (TypedResult.Ok unit)))

(define (typed-mint-ok [store : (&mut store TypedStore)] [count : i64]) : TypedResult
  (cond
    [(match (& store.mode)
        [(TypedMode.Executable) false]
        [(TypedMode.Query) true])
      (TypedResult.Err TypedError.Query)]
    [(>= count store.limits.records)
      (typed-resource-fail! store TypedError.Budget)]
    [(= store.next-serial (cast 18446744073709551615 : u64))
      (typed-resource-fail! store TypedError.Exhausted)]
    [else (TypedResult.Ok unit)]))

(define (typed-fresh! [store : (&mut store TypedStore)] [index : i64]) : TypedHandle
  (let
    [serial : u64 store.next-serial]
    (set! store.next-serial (+ serial (cast 1 : u64)))
    (TypedHandle
      (own.OwnershipBodyId
        store.body.owner
        store.body.generation
        store.body.revision)
      index
      serial)))

(define (typed-handle-range?
  [store : (& store TypedStore)]
  [handle : (& handle TypedHandle)]
  [count : i64]) : bool
  (and
    (= store.body.owner handle.body.owner)
    (= store.body.generation handle.body.generation)
    (= store.body.revision handle.body.revision)
    (>= handle.index 0)
    (< handle.index count)
    (> handle.serial 0)))

;; Like the record checks below (`typed-origin-ok`, `typed-binder-ok`, ...),
;; this runs inside an operation that bound its lease at entry
;; (`typed-charge!`); no event can intervene before it, so it does not check
;; the lease again.
(define (typed-type-ok
  [store : (& store TypedStore)]
  [type : (& type TypedTypeId)]) : TypedResult
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
  (try
    (typed-reserve-records! store lease (+ store.type-count 1) TypedTable.Types))
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
  ;; Reached only from `typed-occurrence-add!`, after its entry charge bound
  ;; the lease, so the interner read below is the validated one.
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
  (try
    (typed-reserve-records!
      store
      lease
      (+ store.origin-count 1)
      TypedTable.Origins))
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
  (try
    (typed-reserve-records!
      store
      lease
      (+ store.binder-count 1)
      TypedTable.Binders))
  (try (typed-type-ok (& store) (& type)))
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
  (try
    (typed-reserve-records!
      store
      lease
      (+ store.projection-count 1)
      TypedTable.Projections))
  (try (typed-type-ok (& store) (& container)))
  (try (typed-type-ok (& store) (& result)))
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
  (try
    (typed-reserve-records!
      store
      lease
      (+ store.place-count 1)
      TypedTable.Places))
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
    (try (typed-type-ok (& store) (& type)))
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
  (try
    (typed-reserve-records! store lease (+ store.call-count 1) TypedTable.Calls))
  (try (typed-type-ok (& store) (& signature)))
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
  (try
    (typed-reserve-records!
      store
      lease
      (+ store.occurrence-count 1)
      TypedTable.Occurrences))
  (try (typed-type-ok (& store) (& type)))
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
  ;; The checkpoint's scalars are read in place, one at a time.
  (let
    [index : i64 id.handle.index]
    (unless
      (= (array-ref store.attempts index).serial id.handle.serial)
      (return (TypedResult.Err TypedError.Stale)))
    (unless
      commit?
      (set! store.occurrence-count (array-ref store.attempts index).occurrences)
      (set! store.binder-count (array-ref store.attempts index).binders)
      (set! store.projection-count (array-ref store.attempts index).projections)
      (set! store.place-count (array-ref store.attempts index).places)
      (set! store.call-count (array-ref store.attempts index).calls)
      (set! store.origin-count (array-ref store.attempts index).origins)
      (set! store.type-count (array-ref store.attempts index).types)
      (set! store.child-count (array-ref store.attempts index).children))
    (set!
      store.mode
      (match (& (array-ref store.attempts index).previous-mode)
        [(TypedMode.Executable) TypedMode.Executable]
        [(TypedMode.Query) TypedMode.Query]))
    (set! store.attempt-count (- store.attempt-count 1))
    (TypedResult.Ok unit)))

;; Reads trust the store. Every record, and every handle a record holds, was
;; checked when it was written (`typed-occurrence-add!` and the other adds), a
;; handle returned by an add or an enumeration names a written record, and
;; this module's mutators keep each count within its array, so a read checks
;; none of that again; `array-ref` still bounds every index. Nor does a read
;; charge work: the store's budget bounds what inference writes, and the phase
;; reading the store bounds its own reads (normalization charges its budget).
;; A read reads no leased payload, so it needs no lease check; it still
;; refuses a retired store, whose records may sit in reclaimed storage.
(define (typed-occurrence-get!
  [store : (&mut store TypedStore)]
  [_lease : (& lease (TypedBodyLease intern))]
  [id : TypedOccurrenceId]) : (TypedNodeResult store)
  (if store.live?
    (TypedNodeResult.Ok (& (array-ref store.occurrences id.handle.index)))
    (TypedNodeResult.Err TypedError.Lease)))

(define (typed-place-get!
  [store : (&mut store TypedStore)]
  [_lease : (& lease (TypedBodyLease intern))]
  [id : TypedPlaceId]) : (TypedPlaceView store)
  (if store.live?
    (TypedPlaceView.Ok (& (array-ref store.places id.handle.index)))
    (TypedPlaceView.Err TypedError.Lease)))

;; `index` is the caller's, not a record's: it is checked against the node's
;; written child span.
(define (typed-child-get!
  [store : (&mut store TypedStore)]
  [_lease : (& lease (TypedBodyLease intern))]
  [id : TypedOccurrenceId]
  [index : i64]) : TypedChildResult
  (if (not store.live?)
    (TypedChildResult.Err TypedError.Lease)
    (let
      [node : (& store TypedOccurrence)
        (& (array-ref store.occurrences id.handle.index))]
      (if (and (>= index 0) (< index node.child-count))
        (TypedChildResult.Ok
          (TypedOccurrenceId
            (typed-handle-copy
              (& (array-ref store.children (+ node.child-start index)).handle))))
        (TypedChildResult.Err TypedError.Unknown)))))

(define (typed-type-get!
  [store : (&mut store TypedStore)]
  [_lease : (& lease (TypedBodyLease intern))]
  [id : TypedTypeId]) : (TypedTypeResult store)
  (if store.live?
    (TypedTypeResult.Ok (& (array-ref store.types id.handle.index).value))
    (TypedTypeResult.Err TypedError.Lease)))

;; Revocation is unconditional and allocation-free, including after exhaustion.
;; It does not dereference any leased payload and cannot publish a result.
(define (typed-store-retire! [store : (&mut store TypedStore)]) : unit
  (set! store.live? false))

(define (typed-origin-get!
  [store : (&mut store TypedStore)]
  [_lease : (& lease (TypedBodyLease intern))]
  [id : TypedOriginId]) : (TypedOriginView store)
  (if store.live?
    (TypedOriginView.Ok (& (array-ref store.origins id.handle.index).source))
    (TypedOriginView.Err TypedError.Lease)))

(define (typed-binder-get!
  [store : (&mut store TypedStore)]
  [_lease : (& lease (TypedBodyLease intern))]
  [id : TypedBinderId]) : (TypedBinderView store)
  (if store.live?
    (TypedBinderView.Ok (& (array-ref store.binders id.handle.index)))
    (TypedBinderView.Err TypedError.Lease)))

;; Enumeration is bounded by the published count (a rolled-back attempt's
;; records are already truncated from it) and preserves each record's serial
;; rather than manufacturing a new identity. Signature consumers must see
;; unused parameters as well as referenced ones.
(define (typed-count-result [store : (& store TypedStore)] [count : i64]) : TypedCountResult
  (if store.live?
    (TypedCountResult.Ok count)
    (TypedCountResult.Err TypedError.Lease)))

(define (typed-index-ok?
  [store : (& store TypedStore)]
  [index : i64]
  [count : i64]) : bool
  (and store.live? (>= index 0) (< index count)))

(define (typed-type-count!
  [store : (&mut store TypedStore)]
  [_lease : (& lease (TypedBodyLease intern))]) : TypedCountResult
  (typed-count-result (& store) store.type-count))

(define (typed-type-at!
  [store : (&mut store TypedStore)]
  [_lease : (& lease (TypedBodyLease intern))]
  [index : i64]) : TypedTypeIdResult
  (if (typed-index-ok? (& store) index store.type-count)
    (TypedTypeIdResult.Ok
      (TypedTypeId
        (typed-fresh-at (& store) index (array-ref store.types index).serial)))
    (TypedTypeIdResult.Err (typed-index-error (& store)))))

;; An owned copy of one type record's canonical value, for a consumer that
;; classifies it outside the lease (ownership type classes).
(define (typed-type-value-at!
  [store : (&mut store TypedStore)]
  [_lease : (& lease (TypedBodyLease intern))]
  [index : i64]) : TypedTypeValueResult
  (if (typed-index-ok? (& store) index store.type-count)
    (TypedTypeValueResult.Ok (clone (array-ref store.types index).value))
    (TypedTypeValueResult.Err (typed-index-error (& store)))))

(define (typed-place-count!
  [store : (&mut store TypedStore)]
  [_lease : (& lease (TypedBodyLease intern))]) : TypedCountResult
  (typed-count-result (& store) store.place-count))

(define (typed-place-at!
  [store : (&mut store TypedStore)]
  [_lease : (& lease (TypedBodyLease intern))]
  [index : i64]) : TypedPlaceResult
  (if (typed-index-ok? (& store) index store.place-count)
    (TypedPlaceResult.Ok
      (TypedPlaceId
        (typed-fresh-at (& store) index (array-ref store.places index).serial)))
    (TypedPlaceResult.Err (typed-index-error (& store)))))

(define (typed-binder-count!
  [store : (&mut store TypedStore)]
  [_lease : (& lease (TypedBodyLease intern))]) : TypedCountResult
  (typed-count-result (& store) store.binder-count))

(define (typed-binder-at!
  [store : (&mut store TypedStore)]
  [_lease : (& lease (TypedBodyLease intern))]
  [index : i64]) : TypedBinderResult
  (if (typed-index-ok? (& store) index store.binder-count)
    (TypedBinderResult.Ok
      (TypedBinderId
        (typed-fresh-at (& store) index (array-ref store.binders index).serial)))
    (TypedBinderResult.Err (typed-index-error (& store)))))

(define (typed-projection-get!
  [store : (&mut store TypedStore)]
  [_lease : (& lease (TypedBodyLease intern))]
  [id : TypedProjectionId]) : (TypedProjectionView store)
  (if store.live?
    (TypedProjectionView.Ok (& (array-ref store.projections id.handle.index)))
    (TypedProjectionView.Err TypedError.Lease)))

(define (typed-call-count!
  [store : (&mut store TypedStore)]
  [_lease : (& lease (TypedBodyLease intern))]) : TypedCountResult
  (typed-count-result (& store) store.call-count))

(define (typed-call-at!
  [store : (&mut store TypedStore)]
  [_lease : (& lease (TypedBodyLease intern))]
  [index : i64]) : TypedCallResult
  (if (typed-index-ok? (& store) index store.call-count)
    (TypedCallResult.Ok
      (TypedCallId
        (typed-fresh-at (& store) index (array-ref store.calls index).serial)))
    (TypedCallResult.Err (typed-index-error (& store)))))

;; The body's occurrences in record order, as the call records are listed.
(define (typed-occurrence-count!
  [store : (&mut store TypedStore)]
  [_lease : (& lease (TypedBodyLease intern))]) : TypedCountResult
  (typed-count-result (& store) store.occurrence-count))

(define (typed-occurrence-at!
  [store : (&mut store TypedStore)]
  [_lease : (& lease (TypedBodyLease intern))]
  [index : i64]) : TypedOccurrenceResult
  (if (typed-index-ok? (& store) index store.occurrence-count)
    (TypedOccurrenceResult.Ok
      (TypedOccurrenceId
        (typed-fresh-at
          (& store)
          index
          (array-ref store.occurrences index).serial)))
    (TypedOccurrenceResult.Err (typed-index-error (& store)))))

(define (typed-call-get!
  [store : (&mut store TypedStore)]
  [_lease : (& lease (TypedBodyLease intern))]
  [id : TypedCallId]) : (TypedCallView store)
  (if store.live?
    (TypedCallView.Ok (& (array-ref store.calls id.handle.index)))
    (TypedCallView.Err TypedError.Lease)))

;; A handle to an existing record of this store.
(define (typed-fresh-at
  [store : (& store TypedStore)]
  [index : i64]
  [serial : u64]) : TypedHandle
  (TypedHandle
    (own.OwnershipBodyId
      store.body.owner
      store.body.generation
      store.body.revision)
    index
    serial))

;; An enumeration index out of range, or a retired store.
(define (typed-index-error [store : (& store TypedStore)]) : TypedError
  (if store.live?
    TypedError.Unknown
    TypedError.Lease))