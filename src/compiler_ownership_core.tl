;; Typed, storage-independent ownership graph (#8449).
;; This is the initialization/move/loan/cleanup core, not a replacement for source checking
;; yet. The caller owns every array/string for the duration of validation and
;; solving. Nothing is retained in a global, intern table, or AST node pool.
(import stdlib.string)

;; Numeric indices have meaning only within one immutable body revision. No
;; arithmetic packs a source name, field ordinal, or pool id into an identity.
(defstruct OwnershipBodyId
  (owner u64)
  (generation u64)
  (revision u64))

(defstruct OwnershipLocalId
  (body OwnershipBodyId)
  (index i64))

(defstruct OwnershipTypeId
  (body OwnershipBodyId)
  (index i64))

(defstruct OwnershipPlaceId
  (body OwnershipBodyId)
  (index i64))

(defstruct OwnershipBlockId
  (body OwnershipBodyId)
  (index i64))

(defstruct OwnershipLoanId
  (body OwnershipBodyId)
  (index i64))

(defstruct OwnershipCleanupId
  (body OwnershipBodyId)
  (index i64))

(defstruct OwnershipObligationId
  (body OwnershipBodyId)
  (index i64))

(defstruct OwnershipSource
  (path String)
  (line i64)
  (column i64)
  ;; An owned expansion trace; no source-pool handles survive the handoff.
  (expansion String))

;; Array payloads sit in single-field structs. The published seed compiler
;; binds a borrowed enum payload to its slot's address rather than the array
;; descriptor stored there; a field borrow (`fields.items`) reads the
;; descriptor under every compiler that may build this module.
(defstruct OwnershipTypeIds
  (items (__tl_dyn-array OwnershipTypeId)))

(defenum OwnershipTypeKind
  (Scalar)
  (Boolean)
  (Product OwnershipTypeIds))

(defstruct OwnershipType
  (kind OwnershipTypeKind)
  (copy? bool))

(defstruct OwnershipLocal
  (type OwnershipTypeId)
  (parameter? bool)
  (source OwnershipSource))

(defenum OwnershipProjection
  (Root)
  (Field OwnershipPlaceId i64))

(defstruct OwnershipPlace
  (local OwnershipLocalId)
  (type OwnershipTypeId)
  (projection OwnershipProjection)
  (source OwnershipSource))

(defenum OwnershipLoanKind
  (Shared)
  (Exclusive))

(defenum OwnershipLoanOrigin
  (Direct)
  (Parent OwnershipLoanId))

;; Loan identities name static definitions. Backward analysis kills the old
;; instance unless a live descendant still retains it, or (for a definition on
;; a control-flow cycle) a holder may still carry it; forward transfer then
;; joins a shared reissue to a previous generation that remains active and
;; rejects an exclusive one.
(defstruct OwnershipLoan
  (place OwnershipPlaceId)
  (kind OwnershipLoanKind)
  (origin OwnershipLoanOrigin)
  (source OwnershipSource))

(defenum OwnershipAccess
  (Read)
  (Write))

(defstruct OwnershipCleanupField
  (ordinal i64)
  (cleanup OwnershipCleanupId))

;; These are explicit intrinsic contracts of the standalone ownership graph.
;; A source callee name or a same-typed function is not such a contract. Source
;; call admission remains unsupported until selected declaration evidence exists.
(defstruct OwnershipCleanupFields
  (items (__tl_dyn-array OwnershipCleanupField)))

(defenum OwnershipCleanupKind
  (Intrinsic)
  (Product OwnershipCleanupFields))

(defstruct OwnershipCleanup
  (type OwnershipTypeId)
  ;; Declared type ownership is separate from an explicit context-only hook.
  (type-owned? bool)
  (kind OwnershipCleanupKind)
  (source OwnershipSource))

(defenum OwnershipObligationMode
  (AutomaticRequired)
  (Discharge))

(defenum OwnershipObligationParent
  (Root)
  (Parent OwnershipObligationId))

;; Retained referents are real reads. Through reads additionally retain the
;; granting capability through the owner-consuming cleanup operation.
(defenum OwnershipCleanupUse
  (Read OwnershipPlaceId)
  (Through OwnershipLoanId OwnershipPlaceId))

(defstruct OwnershipObligation
  (parent OwnershipObligationParent)
  (place OwnershipPlaceId)
  (mode OwnershipObligationMode)
  (cleanup OwnershipCleanupId)
  (retained (__tl_dyn-array OwnershipCleanupUse))
  (source OwnershipSource))

;; Product places are complete: every field occurs exactly once. Distinct
;; fields of the same product are disjoint; an ancestor overlaps a descendant.
;; Reference, index, variant, and range projections must acquire their own
;; semantics before being admitted. They cannot be smuggled in as fields.
(defenum OwnershipOperation
  (Read OwnershipPlaceId)
  ;; Fresh initialization requires every destination leaf to be empty.
  (Initialize OwnershipPlaceId)
  ;; Ordinary assignment may overwrite non-cleanup storage.
  (Assign OwnershipPlaceId)
  (RequireEmpty OwnershipPlaceId)
  ;; Binding activation and value acquisition are one checked operation.
  (BindFresh OwnershipObligationId)
  ;; Construction acquires resources before a lexical binding becomes active.
  (BeginConstruction OwnershipObligationId)
  (BindComplete OwnershipObligationId)
  (BindMove OwnershipPlaceId OwnershipObligationId)
  (Leave OwnershipObligationId)
  (Cleanup OwnershipObligationId OwnershipCleanupId)
  (CleanupPlace OwnershipPlaceId OwnershipCleanupId)
  ;; A checked elaboration can retain an executable scope failure at its
  ;; original point, so it never masks an earlier value or loan failure.
  (CleanupFailure i64)
  (Consume OwnershipPlaceId)
  (Copy OwnershipPlaceId OwnershipPlaceId)
  (Move OwnershipPlaceId OwnershipPlaceId)
  ;; Storage/invalidation does not require an initialized value.
  (Invalidate OwnershipPlaceId)
  (Borrow OwnershipLoanId)
  (Reborrow OwnershipLoanId)
  ;; Capability retention only; this operation never accesses the referent.
  (UseLoan OwnershipLoanId)
  ;; A reference that may carry this loan is used here (its origin set
  ;; contains the loan). The loan is demanded if possibly active; unlike
  ;; UseLoan it need not be definitely active, since the reference may hold
  ;; another loan of its origin on this path. The place is the root place
  ;; whose value is read (the holder): the demand ends, going backward, where
  ;; a Copy or Move overwrites that whole root (`ownership-loan-liveness`).
  (MayUseLoan OwnershipLoanId OwnershipPlaceId)
  (AccessThrough OwnershipLoanId OwnershipPlaceId OwnershipAccess)
  ;; A checked consuming use, not a trusted promise that future uses vanish.
  (EndLoan OwnershipLoanId)
  (Unsupported String))

(defstruct OwnershipInstruction
  (operation OwnershipOperation)
  (source OwnershipSource))

(defstruct OwnershipPlaceIds
  (items (__tl_dyn-array OwnershipPlaceId)))

(defenum OwnershipTerminator
  (Goto OwnershipBlockId)
  (Branch OwnershipPlaceId OwnershipBlockId OwnershipBlockId)
  ;; Retained operands include returned values and implicit exit uses. They
  ;; are checked on this edge, never merged into another edge's fallthrough.
  (Return OwnershipPlaceIds)
  ;; Explicit by-value return. Discharge owners may transfer; With owners may
  ;; not escape. Ordinary Return above only carries retained reads.
  (ReturnOwned OwnershipPlaceIds)
  (Abort)
  (Unsupported String))

(defstruct OwnershipBlock
  (instructions (__tl_dyn-array OwnershipInstruction))
  (terminator OwnershipTerminator)
  (source OwnershipSource))

(defstruct OwnershipBody
  (id OwnershipBodyId)
  (types (__tl_dyn-array OwnershipType))
  (locals (__tl_dyn-array OwnershipLocal))
  (places (__tl_dyn-array OwnershipPlace))
  (loans (__tl_dyn-array OwnershipLoan))
  (cleanups (__tl_dyn-array OwnershipCleanup))
  (obligations (__tl_dyn-array OwnershipObligation))
  (blocks (__tl_dyn-array OwnershipBlock))
  (entry OwnershipBlockId))

(defenum OwnershipFailureKind
  (Structural)
  (Unsupported)
  (Uninitialized)
  (Loan)
  (Cleanup)
  (Resource))

(defstruct OwnershipFailure
  (kind OwnershipFailureKind)
  (block i64)
  (instruction i64)
  (place i64)
  (loan i64)
  (conflicting-loan i64)
  (source OwnershipSource)
  (message String))

(defenum OwnershipResult
  (Ok)
  (Err OwnershipFailure))

(defstruct OwnershipLimits
  (max-nodes i64)
  (max-state-cells i64)
  (max-work i64))

(define (ownership-default-limits) : OwnershipLimits
  (OwnershipLimits 1048576 16777216 67108864))

(define (ownership-body-id-equal?
  [a : (& a OwnershipBodyId)]
  [b : (& b OwnershipBodyId)]) : bool
  (and
    (= a.owner b.owner)
    (= a.generation b.generation)
    (= a.revision b.revision)))

(define (ownership-source-valid? [source : (& source OwnershipSource)]) : bool
  (and
    (> (string.string-length (& source.path)) 0)
    (> source.line 0)
    (> source.column 0)))

(define (ownership-charge! [work : (&mut work i64)] [limit : i64] [units : i64]) : bool
  (if (or (< units 0) (> units (- limit (deref work))))
    false
    (begin
      (set! (deref work) (+ (deref work) units))
      true)))

;; Diagnostic strings are owned output too. Charge every rendered occurrence,
;; including shared strings, so a small graph cannot amplify huge provenance
;; into an unbounded dump under a small work budget. One unit and both texts'
;; bytes are one charge: work only grows, so the sum runs out exactly when one
;; of its parts would.
(define (ownership-source-charge!
  [work : (&mut work i64)]
  [limit : i64]
  [source : (& source OwnershipSource)]) : bool
  (let
    [units : i64
      (+
        1
        (+
          (string.string-length (& source.path))
          (string.string-length (& source.expansion))))]
    (if (> units (- limit (deref work)))
      false
      (begin
        (set! (deref work) (+ (deref work) units))
        true))))

(defmacro (ownership-fail
  [kind : Expr]
  [block : Expr]
  [instruction : Expr]
  [place : Expr]
  [source : Expr]
  [message : Expr]) : Expr
  `(ownership-failure ,kind ,block ,instruction ,place (& ,source) ,message))

(define (ownership-failure
  [kind : OwnershipFailureKind]
  [block : i64]
  [instruction : i64]
  [place : i64]
  [source : (& source OwnershipSource)]
  [message : String]) : OwnershipResult
  (OwnershipResult.Err
    (OwnershipFailure
      kind
      block
      instruction
      place
      -1
      -1
      (OwnershipSource
        (string.copy (& source.path))
        source.line
        source.column
        (string.copy (& source.expansion)))
      message)))

(define (ownership-loan-failure
  [block : i64]
  [instruction : i64]
  [place : i64]
  [loan : i64]
  [conflicting : i64]
  [source : (& source OwnershipSource)]
  [message : String]) : OwnershipResult
  (match (ownership-failure
    OwnershipFailureKind.Loan
    block
    instruction
    place
    source
    message)
    [(OwnershipResult.Err failure)
      (set! failure.loan loan)
      (set! failure.conflicting-loan conflicting)
      (OwnershipResult.Err failure)]
    [(OwnershipResult.Ok) OwnershipResult.Ok]))

(define (ownership-index? [index : i64] [length : i64]) : bool
  (and (>= index 0) (< index length)))

(define (ownership-type-id?
  [body : (& body OwnershipBody)]
  [id : (& id OwnershipTypeId)]) : bool
  (and
    (= body.id.owner id.body.owner)
    (= body.id.generation id.body.generation)
    (= body.id.revision id.body.revision)
    (>= id.index 0)
    (< id.index (array-length body.types))))

(define (ownership-place-id?
  [body : (& body OwnershipBody)]
  [id : (& id OwnershipPlaceId)]) : bool
  (and
    (= body.id.owner id.body.owner)
    (= body.id.generation id.body.generation)
    (= body.id.revision id.body.revision)
    (>= id.index 0)
    (< id.index (array-length body.places))))

(define (ownership-block-id?
  [body : (& body OwnershipBody)]
  [id : (& id OwnershipBlockId)]) : bool
  (and
    (= body.id.owner id.body.owner)
    (= body.id.generation id.body.generation)
    (= body.id.revision id.body.revision)
    (>= id.index 0)
    (< id.index (array-length body.blocks))))

(define (ownership-loan-id?
  [body : (& body OwnershipBody)]
  [id : (& id OwnershipLoanId)]) : bool
  (and
    (= body.id.owner id.body.owner)
    (= body.id.generation id.body.generation)
    (= body.id.revision id.body.revision)
    (>= id.index 0)
    (< id.index (array-length body.loans))))

(define (ownership-cleanup-id?
  [body : (& body OwnershipBody)]
  [id : (& id OwnershipCleanupId)]) : bool
  (and
    (= body.id.owner id.body.owner)
    (= body.id.generation id.body.generation)
    (= body.id.revision id.body.revision)
    (>= id.index 0)
    (< id.index (array-length body.cleanups))))

(define (ownership-obligation-id?
  [body : (& body OwnershipBody)]
  [id : (& id OwnershipObligationId)]) : bool
  (and
    (= body.id.owner id.body.owner)
    (= body.id.generation id.body.generation)
    (= body.id.revision id.body.revision)
    (>= id.index 0)
    (< id.index (array-length body.obligations))))

(define (ownership-obligation-parent [owner : (& owner OwnershipObligation)]) : i64
  (match (& owner.parent)
    [(OwnershipObligationParent.Root) -1]
    [(OwnershipObligationParent.Parent parent) parent.index]))

(define (ownership-loan-parent [loan : (& loan OwnershipLoan)]) : i64
  (match (& loan.origin)
    [(OwnershipLoanOrigin.Direct) -1]
    [(OwnershipLoanOrigin.Parent parent) parent.index]))

(define (ownership-loan-exclusive? [loan : (& loan OwnershipLoan)]) : bool
  (match (& loan.kind)
    [(OwnershipLoanKind.Shared) false]
    [(OwnershipLoanKind.Exclusive) true]))

(define (ownership-loan-permits-access?
  [loan : (& loan OwnershipLoan)]
  [access : (& access OwnershipAccess)]) : bool
  (match access
    [(OwnershipAccess.Read) true]
    [(OwnershipAccess.Write) (ownership-loan-exclusive? loan)]))

(define (ownership-root? [place : (& place OwnershipPlace)]) : bool
  (match (& place.projection)
    [(OwnershipProjection.Root) true]
    [_ false]))

(define (ownership-parent [place : (& place OwnershipPlace)]) : i64
  (match (& place.projection)
    [(OwnershipProjection.Root) -1]
    [(OwnershipProjection.Field parent _) parent.index]))

;; Call only after structural validation. Parent indices strictly decrease.
(define (ownership-descendant?
  [body : (& body OwnershipBody)]
  [child : i64]
  [ancestor : i64]) : bool
  (let
    [cursor : i64 child]
    (while (> cursor ancestor)
      (set! cursor (ownership-parent (& (array-ref body.places cursor)))))
    (= cursor ancestor)))

(define (ownership-overlap? [body : (& body OwnershipBody)] [a : i64] [b : i64]) : bool
  (or (ownership-descendant? body a b) (ownership-descendant? body b a)))

;; The parent steps from `place` to its root, or 0 for an index outside the
;; body. Call after the places are validated (parents strictly decrease).
(define (ownership-place-depth [body : (& body OwnershipBody)] [place : i64]) : i64
  (if (or (< place 0) (>= place (array-length body.places)))
    0
    (let
      [cursor : i64 place]
      [depth : i64 0]
      (while (>= cursor 0)
        (set! cursor (ownership-parent (& (array-ref body.places cursor))))
        (set! depth (+ depth 1)))
      depth)))

(define (ownership-operation-charge!
  [work : (&mut work i64)]
  [limit : i64]
  [body : (& body OwnershipBody)]
  [op : (& op OwnershipOperation)]) : bool
  (and
    (ownership-charge! work limit 1)
    (match op
      [(OwnershipOperation.Move source dest)
        ;; Validation walks each operand's parent chain (`ownership-overlap?`):
        ;; charge the chains it can walk, measured by an equal walk.
        (and
          (ownership-charge!
            work
            limit
            (ownership-place-depth body source.index))
          (ownership-charge! work limit (ownership-place-depth body dest.index)))]
      [(OwnershipOperation.Unsupported reason)
        (ownership-charge! work limit (string.string-length reason))]
      [(OwnershipOperation.Read _) true]
      [(OwnershipOperation.Initialize _) true]
      [(OwnershipOperation.Assign _) true]
      [(OwnershipOperation.RequireEmpty _) true]
      [(OwnershipOperation.BindFresh _) true]
      [(OwnershipOperation.BeginConstruction _) true]
      [(OwnershipOperation.BindComplete _) true]
      [(OwnershipOperation.CleanupPlace _ _) true]
      [(OwnershipOperation.CleanupFailure _) true]
      [(OwnershipOperation.BindMove _ _) true]
      [(OwnershipOperation.Leave _) true]
      [(OwnershipOperation.Cleanup _ _) true]
      [(OwnershipOperation.Consume _) true]
      [(OwnershipOperation.Copy _ _) true]
      [(OwnershipOperation.Invalidate _) true]
      [(OwnershipOperation.Borrow _) true]
      [(OwnershipOperation.Reborrow _) true]
      [(OwnershipOperation.UseLoan _) true]
      [(OwnershipOperation.MayUseLoan _ _) true]
      [(OwnershipOperation.EndLoan _) true]
      [(OwnershipOperation.AccessThrough _ place _)
        (ownership-charge! work limit (ownership-place-depth body place.index))])))

(define (ownership-terminator-charge!
  [work : (&mut work i64)]
  [limit : i64]
  [term : (& term OwnershipTerminator)]) : bool
  (and
    (ownership-charge! work limit 1)
    (match term
      [(OwnershipTerminator.Return operands)
        (ownership-charge! work limit (array-length operands.items))]
      [(OwnershipTerminator.ReturnOwned operands)
        (ownership-charge! work limit (array-length operands.items))]
      [(OwnershipTerminator.Unsupported reason)
        (ownership-charge! work limit (string.string-length reason))]
      [(OwnershipTerminator.Goto _) true]
      [(OwnershipTerminator.Branch _ _ _) true]
      [(OwnershipTerminator.Abort) true])))

(define (ownership-operation-valid?
  [body : (& body OwnershipBody)]
  [op : (& op OwnershipOperation)]) : bool
  ;; Each variant has distinct operand and transfer semantics. No wildcard
  ;; accepts a newly added operation.
  (match op
    [(OwnershipOperation.Read place) (ownership-place-id? body (& place))]
    [(OwnershipOperation.Initialize place) (ownership-place-id? body (& place))]
    [(OwnershipOperation.Assign place) (ownership-place-id? body (& place))]
    [(OwnershipOperation.RequireEmpty place)
      (ownership-place-id? body (& place))]
    [(OwnershipOperation.BindFresh owner)
      (ownership-obligation-id? body (& owner))]
    [(OwnershipOperation.BeginConstruction owner)
      (ownership-obligation-id? body (& owner))]
    [(OwnershipOperation.BindComplete owner)
      (ownership-obligation-id? body (& owner))]
    [(OwnershipOperation.CleanupFailure code) (>= code 0)]
    [(OwnershipOperation.CleanupPlace place cleanup)
      (and
        (ownership-place-id? body (& place))
        (ownership-cleanup-id? body (& cleanup))
        (=
          (array-ref body.places place.index).type.index
          (array-ref body.cleanups cleanup.index).type.index))]
    [(OwnershipOperation.BindMove source owner)
      (and
        (ownership-place-id? body (& source))
        (ownership-obligation-id? body (& owner))
        (=
          (array-ref body.places source.index).type.index
          (array-ref
            body.places
            (array-ref body.obligations owner.index).place.index).type.index)
        (!= source.index (array-ref body.obligations owner.index).place.index))]
    [(OwnershipOperation.Leave owner) (ownership-obligation-id? body (& owner))]
    [(OwnershipOperation.Cleanup owner cleanup)
      (and
        (ownership-obligation-id? body (& owner))
        (ownership-cleanup-id? body (& cleanup))
        (= (array-ref body.obligations owner.index).cleanup.index cleanup.index))]
    [(OwnershipOperation.Consume place) (ownership-place-id? body (& place))]
    [(OwnershipOperation.Invalidate place) (ownership-place-id? body (& place))]
    [(OwnershipOperation.Copy source dest)
      (and
        (ownership-place-id? body (& source))
        (ownership-place-id? body (& dest))
        (=
          (array-ref body.places source.index).type.index
          (array-ref body.places dest.index).type.index)
        (array-ref body.types (array-ref body.places source.index).type.index).copy?)]
    [(OwnershipOperation.Move source dest)
      (and
        (ownership-place-id? body (& source))
        (ownership-place-id? body (& dest))
        (=
          (array-ref body.places source.index).type.index
          (array-ref body.places dest.index).type.index)
        (not (ownership-overlap? body source.index dest.index)))]
    [(OwnershipOperation.Borrow loan)
      (and
        (ownership-loan-id? body (& loan))
        (< (ownership-loan-parent (& (array-ref body.loans loan.index))) 0))]
    [(OwnershipOperation.Reborrow loan)
      (and
        (ownership-loan-id? body (& loan))
        (>= (ownership-loan-parent (& (array-ref body.loans loan.index))) 0))]
    [(OwnershipOperation.UseLoan loan) (ownership-loan-id? body (& loan))]
    [(OwnershipOperation.MayUseLoan loan holder)
      (and
        (ownership-loan-id? body (& loan))
        (ownership-place-id? body (& holder))
        (ownership-root-place? body holder.index))]
    [(OwnershipOperation.EndLoan loan) (ownership-loan-id? body (& loan))]
    [(OwnershipOperation.AccessThrough loan place access)
      (and
        (ownership-loan-id? body (& loan))
        (ownership-place-id? body (& place))
        (ownership-loan-permits-access?
          (& (array-ref body.loans loan.index))
          access)
        (ownership-descendant?
          body
          place.index
          (array-ref body.loans loan.index).place.index))]
    [(OwnershipOperation.Unsupported _) false]))

(define (ownership-terminator-valid?
  [body : (& body OwnershipBody)]
  [term : (& term OwnershipTerminator)]) : bool
  (match term
    [(OwnershipTerminator.Goto target) (ownership-block-id? body (& target))]
    [(OwnershipTerminator.Branch condition yes no)
      (and
        (ownership-place-id? body (& condition))
        (ownership-block-id? body (& yes))
        (ownership-block-id? body (& no))
        (match (&
          (array-ref
            body.types
            (array-ref body.places condition.index).type.index).kind)
          [(OwnershipTypeKind.Boolean) true]
          [_ false]))]
    [(OwnershipTerminator.Return operands)
      (let
        [i : i64 0]
        [valid? : bool true]
        (while (and valid? (< i (array-length operands.items)))
          (set!
            valid?
            (ownership-place-id? body (& (array-ref operands.items i))))
          (set! i (+ i 1)))
        valid?)]
    [(OwnershipTerminator.ReturnOwned operands)
      (let
        [i : i64 0]
        [valid? : bool true]
        (while (and valid? (< i (array-length operands.items)))
          (set!
            valid?
            (ownership-place-id? body (& (array-ref operands.items i))))
          (set! i (+ i 1)))
        valid?)]
    [(OwnershipTerminator.Abort) true]
    [(OwnershipTerminator.Unsupported _) false]))

(define (ownership-product-charge!
  [work : (&mut work i64)]
  [limit : i64]
  [a : i64]
  [b : i64]) : bool
  (and
    (>= a 0)
    (>= b 0)
    (or (= b 0) (<= a (/ (- limit (deref work)) b)))
    (ownership-charge! work limit (* a b))))

(define (ownership-loan-definition [op : (& op OwnershipOperation)]) : i64
  (match op
    [(OwnershipOperation.Borrow loan) loan.index]
    [(OwnershipOperation.Reborrow loan) loan.index]
    [(OwnershipOperation.Read _) -1]
    [(OwnershipOperation.Initialize _) -1]
    [(OwnershipOperation.Assign _) -1]
    [(OwnershipOperation.RequireEmpty _) -1]
    [(OwnershipOperation.BindFresh _) -1]
    [(OwnershipOperation.BeginConstruction _) -1]
    [(OwnershipOperation.BindComplete _) -1]
    [(OwnershipOperation.CleanupPlace _ _) -1]
    [(OwnershipOperation.CleanupFailure _) -1]
    [(OwnershipOperation.BindMove _ _) -1]
    [(OwnershipOperation.Leave _) -1]
    [(OwnershipOperation.Cleanup _ _) -1]
    [(OwnershipOperation.Consume _) -1]
    [(OwnershipOperation.Copy _ _) -1]
    [(OwnershipOperation.Move _ _) -1]
    [(OwnershipOperation.Invalidate _) -1]
    [(OwnershipOperation.UseLoan _) -1]
    [(OwnershipOperation.MayUseLoan _ _) -1]
    [(OwnershipOperation.AccessThrough _ _ _) -1]
    [(OwnershipOperation.EndLoan _) -1]
    [(OwnershipOperation.Unsupported _) -1]))

;; Called after the place forest is validated. Full definition identities are
;; checked before the single indexed census; a foreign ID never counts as a
;; definition of a local loan. All dimensions are reserved before allocation.
(define (ownership-validate-loans
  [body : (& body OwnershipBody)]
  [limits : OwnershipLimits]
  [work : (&mut work i64)]) : OwnershipResult
  (let
    [loans : i64 (array-length body.loans)]
    [blocks : i64 (array-length body.blocks)]
    [points : i64 blocks]
    [cells : i64 0]
    [i : i64 0]
    [fallback : OwnershipSource (OwnershipSource "<ownership-body>" 1 1 "")]
    (when (= loans 0) (return OwnershipResult.Ok))
    (while (< i blocks)
      (unless
        (and
          (ownership-charge! work limits.max-work 1)
          (ownership-charge!
            (&mut points)
            limits.max-nodes
            (array-length (array-ref body.blocks i).instructions)))
        (return
          (ownership-fail
            OwnershipFailureKind.Resource
            i
            -1
            -1
            fallback
            "ownership loan point budget exhausted")))
      (set! i (+ i 1)))
    (unless
      (and
        (ownership-product-charge!
          (&mut cells)
          limits.max-state-cells
          blocks
          (ownership-state-words (array-length body.places)))
        (ownership-product-charge!
          (&mut cells)
          limits.max-state-cells
          (array-length body.places)
          3)
        (ownership-product-charge!
          (&mut cells)
          limits.max-state-cells
          points
          loans)
        (ownership-product-charge!
          (&mut cells)
          limits.max-state-cells
          blocks
          loans)
        (ownership-product-charge! (&mut cells) limits.max-state-cells loans 3)
        (ownership-charge! (&mut cells) limits.max-state-cells blocks)
        (ownership-charge! (&mut cells) limits.max-state-cells 1)
        (ownership-charge! work limits.max-work cells))
      (return
        (ownership-fail
          OwnershipFailureKind.Resource
          -1
          -1
          -1
          fallback
          "ownership loan state budget exhausted")))
    (set! i 0)
    (while (< i loans)
      (let
        [loan : (& body OwnershipLoan) (& (array-ref body.loans i))]
        (unless
          (ownership-source-charge! work limits.max-work (& loan.source))
          (return
            (ownership-fail
              OwnershipFailureKind.Resource
              -1
              -1
              i
              fallback
              "ownership loan validation work exhausted")))
        (unless
          (and
            (ownership-source-valid? (& loan.source))
            (ownership-place-id? body (& loan.place)))
          (return
            (ownership-fail
              OwnershipFailureKind.Structural
              -1
              -1
              i
              loan.source
              "invalid loan place or provenance")))
        (match (& loan.origin)
          [(OwnershipLoanOrigin.Direct) unit]
          [(OwnershipLoanOrigin.Parent parent)
            (unless
              (and (ownership-loan-id? body (& parent)) (< parent.index i))
              (return
                (ownership-fail
                  OwnershipFailureKind.Structural
                  -1
                  -1
                  i
                  loan.source
                  "invalid reborrow parent or place")))
            (let
              [inside : i64
                (ownership-descendant-charged
                  body
                  loan.place.index
                  (array-ref body.loans parent.index).place.index
                  work
                  limits.max-work)]
              (when
                (< inside 0)
                (return
                  (ownership-fail
                    OwnershipFailureKind.Resource
                    -1
                    -1
                    i
                    loan.source
                    "ownership loan validation work exhausted")))
              (unless
                (= inside 1)
                (return
                  (ownership-fail
                    OwnershipFailureKind.Structural
                    -1
                    -1
                    i
                    loan.source
                    "invalid reborrow parent or place"))))
            (when
              (and
                (ownership-loan-exclusive? loan)
                (not
                  (ownership-loan-exclusive?
                    (& (array-ref body.loans parent.index)))))
              (return
                (ownership-fail
                  OwnershipFailureKind.Structural
                  -1
                  -1
                  i
                  loan.source
                  "shared loan cannot grant exclusive authority")))])
        (set! i (+ i 1))))
    (let
      [definitions : (__tl_dyn-array bool) (__tl_make-array bool loans)]
      [b : i64 0]
      (while (< b blocks)
        (let
          [j : i64 0]
          (unless
            (ownership-charge! work limits.max-work 1)
            (return
              (ownership-fail
                OwnershipFailureKind.Resource
                b
                -1
                -1
                fallback
                "ownership loan definition work exhausted")))
          (while (< j (array-length (array-ref body.blocks b).instructions))
            (let
              [instr : (& body OwnershipInstruction)
                (& (array-ref (array-ref body.blocks b).instructions j))]
              [definition : i64 (ownership-loan-definition (& instr.operation))]
              (unless
                (ownership-charge! work limits.max-work 1)
                (return
                  (ownership-fail
                    OwnershipFailureKind.Resource
                    b
                    j
                    -1
                    instr.source
                    "ownership loan definition work exhausted")))
              (when
                (match (& instr.operation)
                  [(OwnershipOperation.Borrow _) true]
                  [(OwnershipOperation.Reborrow _) true]
                  [_ false])
                (unless
                  (ownership-operation-valid? body (& instr.operation))
                  (return
                    (ownership-fail
                      OwnershipFailureKind.Structural
                      b
                      j
                      -1
                      instr.source
                      "invalid loan definition identity")))
                (when
                  (array-ref definitions definition)
                  (return
                    (ownership-fail
                      OwnershipFailureKind.Structural
                      b
                      j
                      definition
                      instr.source
                      "loan has multiple static definitions")))
                (set! (array-ref definitions definition) true))
              (set! j (+ j 1))))
          (set! b (+ b 1))))
      (set! i 0)
      (while (< i loans)
        (unless
          (ownership-charge! work limits.max-work 1)
          (return
            (ownership-fail
              OwnershipFailureKind.Resource
              -1
              -1
              i
              fallback
              "ownership loan definition work exhausted")))
        (unless
          (array-ref definitions i)
          (return
            (ownership-fail
              OwnershipFailureKind.Structural
              -1
              -1
              i
              (array-ref body.loans i).source
              "loan needs one static definition")))
        (set! i (+ i 1))))
    OwnershipResult.Ok))

(define (ownership-validate
  [body : (& body OwnershipBody)]
  [limits : OwnershipLimits]) : OwnershipResult
  (let
    [fallback : OwnershipSource (OwnershipSource "<ownership-body>" 1 1 "")]
    [types : i64 (array-length body.types)]
    [locals : i64 (array-length body.locals)]
    [places : i64 (array-length body.places)]
    [loans : i64 (array-length body.loans)]
    [blocks : i64 (array-length body.blocks)]
    [work : i64 0]
    [state-cells : i64 0]
    [i : i64 0]
    (when
      (or
        (<= limits.max-nodes 0)
        (<= limits.max-state-cells 0)
        (<= limits.max-work 0)
        (> types limits.max-nodes)
        (> locals limits.max-nodes)
        (> places limits.max-nodes)
        (> loans limits.max-nodes)
        (> blocks limits.max-nodes)
        (>
          (ownership-state-words places)
          (/
            limits.max-state-cells
            (if (> blocks 0)
              blocks
              1))))
      (return
        (ownership-fail
          OwnershipFailureKind.Resource
          -1
          -1
          -1
          fallback
          "ownership graph exceeds limits")))
    (when
      (not
        (and
          (ownership-product-charge!
            (&mut state-cells)
            limits.max-state-cells
            blocks
            (ownership-state-words places))
          (ownership-product-charge!
            (&mut state-cells)
            limits.max-state-cells
            places
            3)))
      (return
        (ownership-fail
          OwnershipFailureKind.Resource
          -1
          -1
          -1
          fallback
          "ownership place index exceeds limits")))
    (when
      (not
        (and
          (ownership-charge! (&mut work) limits.max-work types)
          (ownership-charge! (&mut work) limits.max-work locals)
          (ownership-charge! (&mut work) limits.max-work places)
          (ownership-charge! (&mut work) limits.max-work blocks)
          (ownership-charge!
            (&mut work)
            limits.max-work
            (* blocks (ownership-state-words places)))))
      (return
        (ownership-fail
          OwnershipFailureKind.Resource
          -1
          -1
          -1
          fallback
          "ownership graph initialization work exhausted")))
    (when
      (or
        (= body.id.owner (cast 0 : u64))
        (= body.id.generation (cast 0 : u64))
        (= body.id.revision (cast 0 : u64))
        (not (ownership-block-id? body (& body.entry))))
      (return
        (ownership-fail
          OwnershipFailureKind.Structural
          -1
          -1
          -1
          fallback
          "invalid body or entry identity")))
    ;; Field types precede their product type, making recursion finite without
    ;; relying on the machine stack or trusting an AST pool's numeric ids.
    (while (< i types)
      (begin
        (match (& (array-ref body.types i).kind)
          [(OwnershipTypeKind.Product fields)
            (let
              [j : i64 0]
              (when
                (> (array-length fields.items) limits.max-nodes)
                (return
                  (ownership-fail
                    OwnershipFailureKind.Resource
                    -1
                    -1
                    -1
                    fallback
                    "too many type fields")))
              (while (< j (array-length fields.items))
                (let
                  [field : OwnershipTypeId (array-ref fields.items j)]
                  (when
                    (not (ownership-charge! (&mut work) limits.max-work 1))
                    (return
                      (ownership-fail
                        OwnershipFailureKind.Resource
                        -1
                        -1
                        -1
                        fallback
                        "ownership validation work exhausted")))
                  (when
                    (or
                      (not (ownership-type-id? body (& field)))
                      (>= field.index i)
                      (and
                        (array-ref body.types i).copy?
                        (not (array-ref body.types field.index).copy?)))
                    (return
                      (ownership-fail
                        OwnershipFailureKind.Structural
                        -1
                        -1
                        -1
                        fallback
                        "invalid product type or Copy classification")))
                  (set! j (+ j 1)))))]
          [(OwnershipTypeKind.Scalar) unit]
          [(OwnershipTypeKind.Boolean)
            (when
              (not (array-ref body.types i).copy?)
              (return
                (ownership-fail
                  OwnershipFailureKind.Structural
                  -1
                  -1
                  -1
                  fallback
                  "boolean must be Copy")))])
        (set! i (+ i 1))))
    (set! i 0)
    (while (< i locals)
      (when
        (not
          (ownership-source-charge!
            (&mut work)
            limits.max-work
            (& (array-ref body.locals i).source)))
        (return
          (ownership-fail
            OwnershipFailureKind.Resource
            -1
            -1
            -1
            fallback
            "ownership provenance work exhausted")))
      (when
        (or
          (not (ownership-type-id? body (& (array-ref body.locals i).type)))
          (not (ownership-source-valid? (& (array-ref body.locals i).source))))
        (return
          (ownership-fail
            OwnershipFailureKind.Structural
            -1
            -1
            -1
            fallback
            "invalid local type or source")))
      (set! i (+ i 1)))
    (set! i 0)
    (while (< i places)
      (let
        [place : (& body OwnershipPlace) (& (array-ref body.places i))]
        (when
          (not
            (ownership-source-charge!
              (&mut work)
              limits.max-work
              (& place.source)))
          (return
            (ownership-fail
              OwnershipFailureKind.Resource
              -1
              -1
              i
              fallback
              "ownership provenance work exhausted")))
        (when
          (or
            (not (ownership-body-id-equal? (& body.id) (& place.local.body)))
            (not (ownership-index? place.local.index locals))
            (not (ownership-type-id? body (& place.type)))
            (not (ownership-source-valid? (& place.source))))
          (return
            (ownership-fail
              OwnershipFailureKind.Structural
              -1
              -1
              i
              fallback
              "invalid place identity, type, or source")))
        (match (& place.projection)
          [(OwnershipProjection.Root)
            (when
              (not
                (=
                  place.type.index
                  (array-ref body.locals place.local.index).type.index))
              (return
                (ownership-fail
                  OwnershipFailureKind.Structural
                  -1
                  -1
                  i
                  place.source
                  "root type differs from local type")))]
          [(OwnershipProjection.Field parent ordinal)
            (when
              (or
                (not (ownership-place-id? body (& parent)))
                (>= parent.index i)
                (not
                  (=
                    place.local.index
                    (array-ref body.places parent.index).local.index)))
              (return
                (ownership-fail
                  OwnershipFailureKind.Structural
                  -1
                  -1
                  i
                  place.source
                  "invalid projection parent")))
            (match (&
              (array-ref
                body.types
                (array-ref body.places parent.index).type.index).kind)
              [(OwnershipTypeKind.Product fields)
                (when
                  (or
                    (not (ownership-index? ordinal (array-length fields.items)))
                    (not
                      (=
                        place.type.index
                        (array-ref fields.items ordinal).index)))
                  (return
                    (ownership-fail
                      OwnershipFailureKind.Structural
                      -1
                      -1
                      i
                      place.source
                      "invalid field ordinal or type")))]
              [_
                (return
                  (ownership-fail
                    OwnershipFailureKind.Structural
                    -1
                    -1
                    i
                    place.source
                    "field projection of non-product"))])])
        (set! i (+ i 1))))
    ;; Cardinality plus valid, unique projections proves the place forest is
    ;; complete. Missing fields must not let a partial value appear initialized.
    (let
      [roots : (__tl_dyn-array i64) (__tl_make-array i64 locals)]
      [children : (__tl_dyn-array i64) (__tl_make-array i64 places)]
      (set! i 0)
      (while (< i locals)
        (set! (array-ref roots i) 0)
        (set! i (+ i 1)))
      (set! i 0)
      (while (< i places)
        (set! (array-ref children i) 0)
        (set! i (+ i 1)))
      (set! i 0)
      (while (< i places)
        (begin
          (match (& (array-ref body.places i).projection)
            [(OwnershipProjection.Root)
              (let
                [local : i64 (array-ref body.places i).local.index]
                (set! (array-ref roots local) (+ (array-ref roots local) 1)))]
            [(OwnershipProjection.Field parent _)
              (set!
                (array-ref children parent.index)
                (+ (array-ref children parent.index) 1))])
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i locals)
        ;; Two roots of one local are an alias disguised as a place.
        (when
          (> (array-ref roots i) 1)
          (return
            (ownership-fail
              OwnershipFailureKind.Structural
              -1
              -1
              -1
              (array-ref body.locals i).source
              "duplicate place")))
        (when
          (not (= (array-ref roots i) 1))
          (return
            (ownership-fail
              OwnershipFailureKind.Structural
              -1
              -1
              -1
              (array-ref body.locals i).source
              "missing local root")))
        (set! i (+ i 1)))
      (set! i 0)
      (while (< i places)
        (begin
          (match (&
            (array-ref body.types (array-ref body.places i).type.index).kind)
            ;; A product place has all its field places or none (an
            ;; unexpanded product is a leaf).
            [(OwnershipTypeKind.Product fields)
              (when
                (and
                  (!= (array-ref children i) 0)
                  (!= (array-ref children i) (array-length fields.items)))
                (return
                  (ownership-fail
                    OwnershipFailureKind.Structural
                    -1
                    -1
                    i
                    (array-ref body.places i).source
                    "incomplete product place")))]
            [_ unit])
          (set! i (+ i 1))))
      ;; A product place's fields then fill a range of slots (the count of
      ;; fields before it): a field ordinal met twice is an alias disguised
      ;; as a duplicate field. One pass over the places, not one per pair.
      (let
        [offsets : (__tl_dyn-array i64) (__tl_make-array i64 places)]
        [total : i64 0]
        (set! i 0)
        (while (< i places)
          (set! (array-ref offsets i) total)
          (set! total (+ total (array-ref children i)))
          (set! i (+ i 1)))
        (let
          [taken : (__tl_dyn-array bool) (__tl_make-array bool total)]
          (set! i 0)
          (while (< i total)
            (set! (array-ref taken i) false)
            (set! i (+ i 1)))
          (set! i 0)
          (while (< i places)
            (begin
              (when
                (not (ownership-charge! (&mut work) limits.max-work 1))
                (return
                  (ownership-fail
                    OwnershipFailureKind.Resource
                    -1
                    -1
                    i
                    (array-ref body.places i).source
                    "ownership validation work exhausted")))
              (match (& (array-ref body.places i).projection)
                [(OwnershipProjection.Field parent ordinal)
                  (let
                    [slot : i64 (+ (array-ref offsets parent.index) ordinal)]
                    (when
                      (array-ref taken slot)
                      (return
                        (ownership-fail
                          OwnershipFailureKind.Structural
                          -1
                          -1
                          i
                          (array-ref body.places i).source
                          "duplicate place")))
                    (set! (array-ref taken slot) true))]
                [(OwnershipProjection.Root) unit])
              (set! i (+ i 1)))))))
    (match (ownership-validate-loans body limits (&mut work))
      [(OwnershipResult.Err error) (return (OwnershipResult.Err error))]
      [(OwnershipResult.Ok) unit])
    (match (ownership-cleanup-metadata
      body
      limits
      (&mut work)
      (&mut state-cells))
      [(OwnershipResult.Err error) (return (OwnershipResult.Err error))]
      [(OwnershipResult.Ok) unit])
    (set! i 0)
    (while (< i blocks)
      (let
        [block : (& body OwnershipBlock) (& (array-ref body.blocks i))]
        [j : i64 0]
        (when
          (not
            (ownership-source-charge!
              (&mut work)
              limits.max-work
              (& block.source)))
          (return
            (ownership-fail
              OwnershipFailureKind.Resource
              i
              -1
              -1
              fallback
              "ownership provenance work exhausted")))
        (when
          (> (array-length block.instructions) limits.max-nodes)
          (return
            (ownership-fail
              OwnershipFailureKind.Resource
              i
              -1
              -1
              block.source
              "too many block instructions")))
        (when
          (not (ownership-source-valid? (& block.source)))
          (return
            (ownership-fail
              OwnershipFailureKind.Structural
              i
              -1
              -1
              block.source
              "invalid block source")))
        (while (< j (array-length block.instructions))
          (let
            [instr : (& body OwnershipInstruction)
              (& (array-ref block.instructions j))]
            [path : i64 (string.string-length (& instr.source.path))]
            ;; `ownership-source-charge!`
            [units : i64
              (+ 1 (+ path (string.string-length (& instr.source.expansion))))]
            (when
              (> units (- limits.max-work work))
              (return
                (ownership-fail
                  OwnershipFailureKind.Resource
                  i
                  j
                  -1
                  fallback
                  "ownership provenance work exhausted")))
            (set! work (+ work units))
            (when
              (not
                (ownership-operation-charge!
                  (&mut work)
                  limits.max-work
                  body
                  (& instr.operation)))
              (return
                (ownership-fail
                  OwnershipFailureKind.Resource
                  i
                  j
                  -1
                  instr.source
                  "ownership validation work exhausted")))
            (match (& instr.operation)
              [(OwnershipOperation.Unsupported reason)
                (return
                  (ownership-fail
                    OwnershipFailureKind.Unsupported
                    i
                    j
                    -1
                    instr.source
                    (string.copy reason)))]
              [_ unit])
            (when
              (or
                (not (ownership-source-valid? (& instr.source)))
                (not (ownership-operation-valid? body (& instr.operation))))
              (return
                (ownership-fail
                  OwnershipFailureKind.Structural
                  i
                  j
                  -1
                  instr.source
                  "invalid operation operands")))
            (set! j (+ j 1))))
        (when
          (not
            (ownership-terminator-charge!
              (&mut work)
              limits.max-work
              (& block.terminator)))
          (return
            (ownership-fail
              OwnershipFailureKind.Resource
              i
              j
              -1
              block.source
              "ownership terminator work exhausted")))
        (match (& block.terminator)
          [(OwnershipTerminator.Unsupported reason)
            (return
              (ownership-fail
                OwnershipFailureKind.Unsupported
                i
                j
                -1
                block.source
                (string.copy reason)))]
          [(OwnershipTerminator.Return operands)
            (when
              (> (array-length operands.items) limits.max-nodes)
              (return
                (ownership-fail
                  OwnershipFailureKind.Resource
                  i
                  j
                  -1
                  block.source
                  "too many return operands")))]
          [_ unit])
        (when
          (not (ownership-terminator-valid? body (& block.terminator)))
          (return
            (ownership-fail
              OwnershipFailureKind.Structural
              i
              j
              -1
              block.source
              "invalid terminator operands")))
        (set! i (+ i 1))))
    OwnershipResult.Ok))

;; Each place carries the union of possible leaf states: 1 = uninitialized,
;; 2 = initialized, 3 = either. Reachability is separate; 0 is never a reachable
;; cell. Parent states are the union of immediate child states. Joins are OR.
(define (ownership-state-join [a : i64] [b : i64]) : i64
  (bit-or a b))

(define (ownership-loan-state-join [a : i64] [b : i64]) : i64
  (bit-or a b))

;; Place states are packed four bits each, sixteen to an i64 word: a state row
;; is `ownership-state-words` words, and a block's input row starts at
;; `block * words`. Rows are copied and joined (OR) a word at a time, so a
;; block visit costs its words, not its places.
(define (ownership-state-words [places : i64]) : i64
  (/ (+ places 15) 16))

(define (ownership-state-get
  [cells : (& cells (__tl_dyn-array i64))]
  [base : i64]
  [place : i64]) : i64
  (bit-and
    (shr (array-ref cells (+ base (/ place 16))) (* 4 (bit-and place 15)))
    15))

(define (ownership-state-put!
  [cells : (&mut cells (__tl_dyn-array i64))]
  [base : i64]
  [place : i64]
  [value : i64]) : unit
  (let
    [cell : i64 (+ base (/ place 16))]
    [shift : i64 (* 4 (bit-and place 15))]
    (set!
      (array-ref cells cell)
      (bit-or
        (bit-and (array-ref cells cell) (bit-not (shl 15 shift)))
        (shl (bit-and value 15) shift)))))

;; A packed row of `places` states, each `value`.
(define (ownership-state-row [places : i64] [value : i64]) : (__tl_dyn-array
    i64)
  (let
    [row : (__tl_dyn-array i64)
      (__tl_make-array i64 (ownership-state-words places))]
    [i : i64 0]
    (while (< i (array-length row))
      (set! (array-ref row i) 0)
      (set! i (+ i 1)))
    (set! i 0)
    (while (< i places)
      (begin
        (ownership-state-put! (&mut row) 0 i value)
        (set! i (+ i 1))))
    row))

(define (ownership-state-readable? [state : i64]) : bool
  (= state 2))

(defstruct OwnershipLoanLiveness
  (offsets (__tl_dyn-array i64))
  ;; Words per row: one bit per loan, 64 loans to a word.
  (stride i64)
  ;; One row before each instruction and one before each terminator.
  (live (__tl_dyn-array i64)))

;; Loan sets are bit rows, 64 loans to an i64 word, so a liveness row is
;; joined and copied a word at a time.
(define (ownership-loan-words [loans : i64]) : i64
  (/ (+ loans 63) 64))

(define (ownership-loan-bit?
  [cells : (& cells (__tl_dyn-array i64))]
  [base : i64]
  [loan : i64]) : bool
  (!=
    (bit-and (shr (array-ref cells (+ base (/ loan 64))) (bit-and loan 63)) 1)
    0))

(define (ownership-loan-bit-set!
  [cells : (&mut cells (__tl_dyn-array i64))]
  [base : i64]
  [loan : i64]
  [on? : bool]) : unit
  (let
    [cell : i64 (+ base (/ loan 64))]
    [mask : i64 (shl 1 (bit-and loan 63))]
    (set!
      (array-ref cells cell)
      (if on?
        (bit-or (array-ref cells cell) mask)
        (bit-and (array-ref cells cell) (bit-not mask))))))

;; The forward walk keeps loan states as bit planes of W =
;; `ownership-loan-words` words each: plane 0 holds state bit 1 (not issued on
;; some path) of every loan, plane 1 bit 2 (active), plane 2 bit 4 (ended), and
;; plane 3 marks the exclusive loans. A block's input row is planes 0-2, so a
;; join, copy or expiry costs words, not loans.
(define (ownership-loan-code
  [state : (& state (__tl_dyn-array i64))]
  [loan : i64]) : i64
  (let
    [words : i64 (/ (array-length state) 4)]
    [cell : i64 (/ loan 64)]
    [shift : i64 (bit-and loan 63)]
    (bit-or
      (bit-and (shr (array-ref state cell) shift) 1)
      (bit-or
        (shl (bit-and (shr (array-ref state (+ words cell)) shift) 1) 1)
        (shl (bit-and (shr (array-ref state (+ (* 2 words) cell)) shift) 1) 2)))))

(define (ownership-loan-code-set!
  [state : (&mut state (__tl_dyn-array i64))]
  [loan : i64]
  [code : i64]) : unit
  (let
    [words : i64 (/ (array-length state) 4)]
    [plane : i64 0]
    (while (< plane 3)
      (ownership-loan-bit-set!
        state
        (* plane words)
        loan
        (!= (bit-and code (shl 1 plane)) 0))
      (set! plane (+ plane 1)))))

;; Planes for one state code per loan (1..7), with the exclusive loans of
;; `body` marked; `ownership-loan-codes!` reads them back.
(define (ownership-loan-planes
  [body : (& body OwnershipBody)]
  [codes : (& codes (__tl_dyn-array i64))]) : (__tl_dyn-array i64)
  (let
    [count : i64 (array-length codes)]
    [words : i64 (ownership-loan-words count)]
    [planes : (__tl_dyn-array i64) (__tl_make-array i64 (* 4 words))]
    [i : i64 0]
    (ownership-i64-fill! (&mut planes) 0)
    (while (< i count)
      (ownership-loan-code-set! (&mut planes) i (array-ref codes i))
      (when
        (and
          (< i (array-length body.loans))
          (ownership-loan-exclusive? (& (array-ref body.loans i))))
        (ownership-loan-bit-set! (&mut planes) (* 3 words) i true))
      (set! i (+ i 1)))
    planes))

(define (ownership-loan-codes!
  [planes : (& planes (__tl_dyn-array i64))]
  [codes : (&mut codes (__tl_dyn-array i64))]) : unit
  (let
    [i : i64 0]
    (while (< i (array-length codes))
      (set! (array-ref codes i) (ownership-loan-code planes i))
      (set! i (+ i 1)))))

;; Whether `loan` is demanded at liveness row `point`.
(define (ownership-loan-live?
  [liveness : (& liveness OwnershipLoanLiveness)]
  [point : i64]
  [loan : i64]) : bool
  (ownership-loan-bit? (& liveness.live) (* point liveness.stride) loan))

;; A one-row liveness demanding the loans whose `demands` entry is true (row 0),
;; for applying a transfer or an expiry directly.
(define (ownership-loan-liveness-row [demands : (__tl_dyn-array bool)]) : OwnershipLoanLiveness
  (let
    [stride : i64 (ownership-loan-words (array-length demands))]
    [row : (__tl_dyn-array i64) (__tl_make-array i64 stride)]
    [i : i64 0]
    (while (< i stride)
      (set! (array-ref row i) 0)
      (set! i (+ i 1)))
    (set! i 0)
    (while (< i (array-length demands))
      (when (array-ref demands i) (ownership-loan-bit-set! (&mut row) 0 i true))
      (set! i (+ i 1)))
    (OwnershipLoanLiveness (__tl_make-array i64 0) stride row)))

(defenum OwnershipLoanLivenessResult
  (Ok OwnershipLoanLiveness)
  (Err OwnershipFailure))

(define (ownership-loan-used [op : (& op OwnershipOperation)]) : i64
  (match op
    [(OwnershipOperation.UseLoan loan) loan.index]
    [(OwnershipOperation.MayUseLoan loan _) loan.index]
    [(OwnershipOperation.EndLoan loan) loan.index]
    [(OwnershipOperation.AccessThrough loan _ _) loan.index]
    [(OwnershipOperation.Read _) -1]
    [(OwnershipOperation.Initialize _) -1]
    [(OwnershipOperation.Assign _) -1]
    [(OwnershipOperation.RequireEmpty _) -1]
    [(OwnershipOperation.BindFresh _) -1]
    [(OwnershipOperation.BeginConstruction _) -1]
    [(OwnershipOperation.BindComplete _) -1]
    [(OwnershipOperation.CleanupPlace _ _) -1]
    [(OwnershipOperation.CleanupFailure _) -1]
    [(OwnershipOperation.BindMove _ _) -1]
    [(OwnershipOperation.Leave _) -1]
    [(OwnershipOperation.Cleanup _ _) -1]
    [(OwnershipOperation.Consume _) -1]
    [(OwnershipOperation.Copy _ _) -1]
    [(OwnershipOperation.Move _ _) -1]
    [(OwnershipOperation.Invalidate _) -1]
    [(OwnershipOperation.Borrow _) -1]
    [(OwnershipOperation.Reborrow _) -1]
    [(OwnershipOperation.Unsupported _) -1]))

(define (ownership-live-use!
  [body : (& body OwnershipBody)]
  [state : (&mut state (__tl_dyn-array i64))]
  [loan : i64]) : unit
  (let
    [cursor : i64 loan]
    (while (>= cursor 0)
      (begin
        (ownership-loan-bit-set! state 0 cursor true)
        (set! cursor (ownership-loan-parent (& (array-ref body.loans cursor))))))))

(define (ownership-live-join-row!
  [cells : (&mut cells (__tl_dyn-array i64))]
  [state : (& state (__tl_dyn-array i64))]
  [row : i64]) : bool
  (let
    [i : i64 0]
    [changed : bool false]
    (while (< i (array-length state))
      (let
        [prior : i64 (array-ref cells (+ row i))]
        [joined : i64 (bit-or prior (array-ref state i))]
        (when
          (!= joined prior)
          (set! (array-ref cells (+ row i)) joined)
          (set! changed true))
        (set! i (+ i 1))))
    changed))

(define (ownership-successor [term : (& term OwnershipTerminator)] [edge : i64]) : i64
  (match term
    [(OwnershipTerminator.Goto target)
      (if (= edge 0)
        target.index
        -1)]
    [(OwnershipTerminator.Branch _ yes no)
      (if (= edge 0)
        yes.index
        no.index)]
    [(OwnershipTerminator.Return _) -1]
    [(OwnershipTerminator.ReturnOwned _) -1]
    [(OwnershipTerminator.Abort) -1]
    [(OwnershipTerminator.Unsupported _) -1]))

;; Whether place `index` is a root place: a local's whole storage.
(define (ownership-root-place? [body : (& body OwnershipBody)] [index : i64]) : bool
  (and
    (ownership-index? index (array-length body.places))
    (match (& (array-ref body.places index).projection)
      [(OwnershipProjection.Root) true]
      [(OwnershipProjection.Field _ _) false])))

;; The root of place `index`: the place of its local's whole storage.
(define (ownership-place-root [body : (& body OwnershipBody)] [index : i64]) : i64
  (let
    [current : i64 index]
    [walking : bool true]
    (while walking
      (match (& (array-ref body.places current).projection)
        [(OwnershipProjection.Root) (set! walking false)]
        [(OwnershipProjection.Field parent _) (set! current parent.index)]))
    current))

;; The root place a Copy or Move overwrites whole, or -1.
(define (ownership-overwritten-root
  [body : (& body OwnershipBody)]
  [op : (& op OwnershipOperation)]) : i64
  (match op
    [(OwnershipOperation.Copy _ dest)
      (if (ownership-root-place? body dest.index)
        dest.index
        -1)]
    [(OwnershipOperation.Move _ dest)
      (if (ownership-root-place? body dest.index)
        dest.index
        -1)]
    [_ -1]))

;; The source place of a Copy or Move, or -1.
(define (ownership-transfer-source [op : (& op OwnershipOperation)]) : i64
  (match op
    [(OwnershipOperation.Copy source _) source.index]
    [(OwnershipOperation.Move source _) source.index]
    [_ -1]))

;; Whether each block lies on a cycle of the control-flow graph, by Tarjan's
;; strongly connected components (iterative, so a deep graph uses no stack). A
;; loan defined in such a block can be issued again while a reference still
;; holds its earlier issue. An empty result means the work limit was reached.
(define (ownership-cyclic-blocks
  [body : (& body OwnershipBody)]
  [work : (&mut work i64)]
  [limit : i64]) : (__tl_dyn-array bool)
  (let
    [blocks : i64 (array-length body.blocks)]
    [cyclic : (__tl_dyn-array bool) (__tl_make-array bool blocks)]
    [on-stack : (__tl_dyn-array bool) (__tl_make-array bool blocks)]
    [order : (__tl_dyn-array i64) (__tl_make-array i64 blocks)]
    [low : (__tl_dyn-array i64) (__tl_make-array i64 blocks)]
    [stack : (__tl_dyn-array i64) (__tl_make-array i64 blocks)]
    [frames : (__tl_dyn-array i64) (__tl_make-array i64 blocks)]
    [edges : (__tl_dyn-array i64) (__tl_make-array i64 blocks)]
    [top : i64 0]
    [depth : i64 0]
    [counter : i64 0]
    [root : i64 0]
    ;; Each block is entered, popped and scanned for once, and has two edges.
    (unless
      (ownership-charge! work limit (* 8 blocks))
      (return (__tl_make-array bool 0)))
    (while (< root blocks)
      (set! (array-ref cyclic root) false)
      (set! (array-ref on-stack root) false)
      (set! (array-ref order root) -1)
      (set! root (+ root 1)))
    (set! root 0)
    (while (< root blocks)
      (when
        (< (array-ref order root) 0)
        (set! (array-ref order root) counter)
        (set! (array-ref low root) counter)
        (set! counter (+ counter 1))
        (set! (array-ref stack top) root)
        (set! top (+ top 1))
        (set! (array-ref on-stack root) true)
        (set! (array-ref frames 0) root)
        (set! (array-ref edges 0) 0)
        (set! depth 1)
        (while (> depth 0)
          (let
            [v : i64 (array-ref frames (- depth 1))]
            [edge : i64 (array-ref edges (- depth 1))]
            (if (< edge 2)
              (let
                [w : i64
                  (ownership-successor
                    (& (array-ref body.blocks v).terminator)
                    edge)]
                (set! (array-ref edges (- depth 1)) (+ edge 1))
                (when (= w v) (set! (array-ref cyclic v) true))
                (cond
                  [(< w 0) unit]
                  [(< (array-ref order w) 0)
                    (set! (array-ref order w) counter)
                    (set! (array-ref low w) counter)
                    (set! counter (+ counter 1))
                    (set! (array-ref stack top) w)
                    (set! top (+ top 1))
                    (set! (array-ref on-stack w) true)
                    (set! (array-ref frames depth) w)
                    (set! (array-ref edges depth) 0)
                    (set! depth (+ depth 1))]
                  [(and
                      (array-ref on-stack w)
                      (< (array-ref order w) (array-ref low v)))
                    (set! (array-ref low v) (array-ref order w))]
                  [else unit]))
              (begin
                (set! depth (- depth 1))
                (when
                  (and
                    (> depth 0)
                    (<
                      (array-ref low v)
                      (array-ref low (array-ref frames (- depth 1)))))
                  (set!
                    (array-ref low (array-ref frames (- depth 1)))
                    (array-ref low v)))
                (when
                  (= (array-ref low v) (array-ref order v))
                  ;; v roots a component: the stack from v up. More than one
                  ;; member means each lies on a cycle through another.
                  (let
                    [base : i64 (- top 1)]
                    (while (!= (array-ref stack base) v)
                      (set! base (- base 1)))
                    (let
                      [many? : bool (> (- top base) 1)]
                      (while (> top base)
                        (set! top (- top 1))
                        (set! (array-ref on-stack (array-ref stack top)) false)
                        (when
                          many?
                          (set! (array-ref cyclic (array-ref stack top)) true)))))))))))
      (set! root (+ root 1)))
    cyclic))

;; The place an operation writes into without overwriting a whole root through
;; a Copy or Move: a part of a root, or a root an Assign or Initialize writes,
;; or a referent written through a reference. -1 for any other operation.
(define (ownership-written-place [op : (& op OwnershipOperation)]) : i64
  (match op
    [(OwnershipOperation.Copy _ dest) dest.index]
    [(OwnershipOperation.Move _ dest) dest.index]
    [(OwnershipOperation.Assign place) place.index]
    [(OwnershipOperation.Initialize place) place.index]
    [(OwnershipOperation.AccessThrough _ place access)
      (match access
        [(OwnershipAccess.Write) place.index]
        [(OwnershipAccess.Read) -1])]
    [_ -1]))

;; Holder-keyed demands of a body's MayUseLoan operations, for
;; `ownership-loan-liveness`. A pair is a (holder, loan) demand; a MayUseLoan
;; of any other holder stays a plain demand of its loan, which ends at the
;; loan's definition. A holder gets pairs when a Copy or Move overwrites it
;; whole somewhere, since that can end one. For a loan issued again on a
;; cycle (`reissued`) every holder gets pairs: a reference may still hold the
;; earlier issue there, so the definition ends none of them, and each ends
;; only where its holder is overwritten whole.
(defstruct OwnershipLoanDemands
  (pairs i64)
  (pair-holder (__tl_dyn-array i64))
  (pair-loan (__tl_dyn-array i64))
  ;; Per liveness point (block offset plus instruction): the pair its
  ;; MayUseLoan demands, or -1; the root overwritten whole there, or -1. That
  ;; is the destination of a Copy or Move, or a temporary's single Assign (a
  ;; root with no other write and no exclusive loan). Then the transfer's
  ;; source root (-1 for an Assign), and the first instruction of the
  ;; MayUseLoan run that reads that source just before the transfer, or -1.
  (point-pair (__tl_dyn-array i64))
  (point-kill (__tl_dyn-array i64))
  (point-source (__tl_dyn-array i64))
  (point-run (__tl_dyn-array i64))
  ;; The pairs of one holder (first per place, next per pair), and of one loan
  ;; (first per loan, next per pair).
  (holder-first (__tl_dyn-array i64))
  (holder-next (__tl_dyn-array i64))
  (loan-first (__tl_dyn-array i64))
  (loan-next (__tl_dyn-array i64))
  ;; Per loan: its definition lies in a block on a control-flow cycle.
  (reissued (__tl_dyn-array bool)))

(defenum OwnershipLoanDemandsResult
  (Ok OwnershipLoanDemands)
  (Err OwnershipFailure))

(define (ownership-liveness-exhausted
  [body : (& body OwnershipBody)]
  [block : i64]
  [instruction : i64]) : OwnershipFailure
  (let
    [source : OwnershipSource
      (if (ownership-index? block (array-length body.blocks))
        (ownership-source-copy (& (array-ref body.blocks block).source))
        (OwnershipSource "" 0 0 ""))]
    (OwnershipFailure
      OwnershipFailureKind.Resource
      block
      instruction
      -1
      -1
      -1
      source
      "ownership loan liveness work exhausted")))

(define (ownership-i64-fill!
  [cells : (&mut cells (__tl_dyn-array i64))]
  [value : i64]) : unit
  (let
    [i : i64 0]
    (while (< i (array-length cells))
      (set! (array-ref cells i) value)
      (set! i (+ i 1)))))

(define (ownership-bool-fill!
  [cells : (&mut cells (__tl_dyn-array bool))]
  [value : bool]) : unit
  (let
    [i : i64 0]
    (while (< i (array-length cells))
      (set! (array-ref cells i) value)
      (set! i (+ i 1)))))

(define (ownership-loan-demands
  [body : (& body OwnershipBody)]
  [offsets : (& offsets (__tl_dyn-array i64))]
  [points : i64]
  [work : (&mut work i64)]
  [limit : i64]) : OwnershipLoanDemandsResult
  (let
    [places : i64 (array-length body.places)]
    [loans : i64 (array-length body.loans)]
    [blocks : i64 (array-length body.blocks)]
    [killable : (__tl_dyn-array bool) (__tl_make-array bool places)]
    ;; Per root: its whole Assign operations, and whether anything else can
    ;; give it a value (any other write into it, or an exclusive loan of it).
    [assigns : (__tl_dyn-array i64) (__tl_make-array i64 places)]
    [tainted : (__tl_dyn-array bool) (__tl_make-array bool places)]
    [reissued : (__tl_dyn-array bool) (__tl_make-array bool loans)]
    [point-pair : (__tl_dyn-array i64) (__tl_make-array i64 points)]
    [point-kill : (__tl_dyn-array i64) (__tl_make-array i64 points)]
    [point-source : (__tl_dyn-array i64) (__tl_make-array i64 points)]
    [point-run : (__tl_dyn-array i64) (__tl_make-array i64 points)]
    [holder-first : (__tl_dyn-array i64) (__tl_make-array i64 places)]
    [loan-first : (__tl_dyn-array i64) (__tl_make-array i64 loans)]
    [cyclic : (__tl_dyn-array bool) (ownership-cyclic-blocks body work limit)]
    [candidates : i64 0]
    [pairs : i64 0]
    [b : i64 0]
    [j : i64 0]
    (unless
      (and
        (= (array-length cyclic) blocks)
        (ownership-charge! work limit (+ (* 4 places) (* 2 loans) (* 5 points))))
      (return
        (OwnershipLoanDemandsResult.Err (ownership-liveness-exhausted body 0 0))))
    (ownership-bool-fill! (&mut killable) false)
    (ownership-bool-fill! (&mut tainted) false)
    (ownership-bool-fill! (&mut reissued) false)
    (ownership-i64-fill! (&mut assigns) 0)
    (ownership-i64-fill! (&mut point-pair) -1)
    (ownership-i64-fill! (&mut point-kill) -1)
    (ownership-i64-fill! (&mut point-source) -1)
    (ownership-i64-fill! (&mut point-run) -1)
    (ownership-i64-fill! (&mut holder-first) -1)
    (ownership-i64-fill! (&mut loan-first) -1)
    ;; The overwritten roots and the runs before them, the other writes, the
    ;; loans issued on a cycle, and how many uses may need a pair.
    (while (< b blocks)
      (let
        [instructions : (& body (__tl_dyn-array OwnershipInstruction))
          (& (array-ref body.blocks b).instructions)]
        (set! j 0)
        (while (< j (array-length instructions))
          (unless
            (ownership-charge! work limit 1)
            (return
              (OwnershipLoanDemandsResult.Err
                (ownership-liveness-exhausted body b j))))
          (let
            [op : (& body OwnershipOperation)
              (& (array-ref instructions j).operation)]
            [point : i64 (+ (array-ref offsets b) j)]
            [root : i64 (ownership-overwritten-root body op)]
            [written : i64 (ownership-written-place op)]
            (cond
              [(>= root 0)
                (let
                  [source : i64
                    (ownership-place-root body (ownership-transfer-source op))]
                  [first : i64 j]
                  [reads-source? : bool false]
                  (unless
                    (ownership-charge!
                      work
                      limit
                      (+
                        1
                        (ownership-place-depth
                          body
                          (ownership-transfer-source op))))
                    (return
                      (OwnershipLoanDemandsResult.Err
                        (ownership-liveness-exhausted body b j))))
                  (set! (array-ref killable root) true)
                  (set! (array-ref point-kill point) root)
                  (set! (array-ref point-source point) source)
                  ;; Cleanup elaboration may place a RequireEmpty of the
                  ;; destination between the source's run and the transfer.
                  (while (and
                    (> first 0)
                    (match (& (array-ref instructions (- first 1)).operation)
                      [(OwnershipOperation.RequireEmpty _) true]
                      [_ false]))
                    (unless
                      (ownership-charge! work limit 1)
                      (return
                        (OwnershipLoanDemandsResult.Err
                          (ownership-liveness-exhausted body b j))))
                    (set! first (- first 1)))
                  (while (and
                    (> first 0)
                    (match (& (array-ref instructions (- first 1)).operation)
                      [(OwnershipOperation.MayUseLoan _ _) true]
                      [_ false]))
                    (unless
                      (ownership-charge! work limit 1)
                      (return
                        (OwnershipLoanDemandsResult.Err
                          (ownership-liveness-exhausted body b j))))
                    (set! first (- first 1))
                    (match (& (array-ref instructions first).operation)
                      [(OwnershipOperation.MayUseLoan _ via)
                        (when (= via.index source) (set! reads-source? true))]
                      [_ unit]))
                  (when reads-source? (set! (array-ref point-run point) first)))]
              [(>= written 0)
                (unless
                  (ownership-charge!
                    work
                    limit
                    (+ 1 (ownership-place-depth body written)))
                  (return
                    (OwnershipLoanDemandsResult.Err
                      (ownership-liveness-exhausted body b j))))
                (if (and
                  (ownership-root-place? body written)
                  (match op
                    [(OwnershipOperation.Assign _) true]
                    [_ false]))
                  (begin
                    (set!
                      (array-ref assigns written)
                      (+ (array-ref assigns written) 1))
                    (set! (array-ref point-kill point) written))
                  (set!
                    (array-ref tainted (ownership-place-root body written))
                    true))]
              [else unit])
            (let
              [definition : i64 (ownership-loan-definition op)]
              (when
                (>= definition 0)
                (set! (array-ref reissued definition) (array-ref cyclic b))))
            (match op
              [(OwnershipOperation.MayUseLoan _ _)
                (set! candidates (+ candidates 1))]
              [_ unit]))
          (set! j (+ j 1)))
        (set! b (+ b 1))))
    ;; An exclusive loan of a root, or a cleanup obligation on it, can also
    ;; give it a value.
    (set! j 0)
    (while (< j loans)
      (let
        [place : i64 (array-ref body.loans j).place.index]
        (unless
          (ownership-charge!
            work
            limit
            (+ 1 (ownership-place-depth body place)))
          (return
            (OwnershipLoanDemandsResult.Err
              (ownership-liveness-exhausted body 0 0))))
        (when
          (ownership-loan-exclusive? (& (array-ref body.loans j)))
          (set! (array-ref tainted (ownership-place-root body place)) true)))
      (set! j (+ j 1)))
    (set! j 0)
    (while (< j (array-length body.obligations))
      (let
        [place : i64 (array-ref body.obligations j).place.index]
        (unless
          (ownership-charge!
            work
            limit
            (+ 1 (ownership-place-depth body place)))
          (return
            (OwnershipLoanDemandsResult.Err
              (ownership-liveness-exhausted body 0 0))))
        (set! (array-ref tainted (ownership-place-root body place)) true))
      (set! j (+ j 1)))
    ;; An Assign overwrites a root whole only when it is that root's single
    ;; write: an indexed store may assign the root it updates in place.
    (set! j 0)
    (while (< j points)
      (let
        [root : i64 (array-ref point-kill j)]
        (when
          (and
            (>= root 0)
            (< (array-ref point-source j) 0)
            (not
              (and
                (= (array-ref assigns root) 1)
                (not (array-ref tainted root))
                (not (array-ref killable root)))))
          (set! (array-ref point-kill j) -1)))
      (set! j (+ j 1)))
    (let
      [pair-holder : (__tl_dyn-array i64) (__tl_make-array i64 candidates)]
      [pair-loan : (__tl_dyn-array i64) (__tl_make-array i64 candidates)]
      [holder-next : (__tl_dyn-array i64) (__tl_make-array i64 candidates)]
      [loan-next : (__tl_dyn-array i64) (__tl_make-array i64 candidates)]
      (unless
        (ownership-charge! work limit (* 4 candidates))
        (return
          (OwnershipLoanDemandsResult.Err
            (ownership-liveness-exhausted body 0 0))))
      ;; One pair per distinct (holder, loan): the loan's chain is searched.
      (set! b 0)
      (while (< b blocks)
        (let
          [instructions : (& body (__tl_dyn-array OwnershipInstruction))
            (& (array-ref body.blocks b).instructions)]
          (set! j 0)
          (while (< j (array-length instructions))
            (match (& (array-ref instructions j).operation)
              [(OwnershipOperation.MayUseLoan loan holder)
                (when
                  (or
                    (array-ref killable holder.index)
                    (array-ref reissued loan.index))
                  (let
                    [found : i64 -1]
                    [p : i64 (array-ref loan-first loan.index)]
                    (while (and (< found 0) (>= p 0))
                      (unless
                        (ownership-charge! work limit 1)
                        (return
                          (OwnershipLoanDemandsResult.Err
                            (ownership-liveness-exhausted body b j))))
                      (when
                        (= (array-ref pair-holder p) holder.index)
                        (set! found p))
                      (set! p (array-ref loan-next p)))
                    (when
                      (< found 0)
                      (set! found pairs)
                      (set! (array-ref pair-holder found) holder.index)
                      (set! (array-ref pair-loan found) loan.index)
                      (set!
                        (array-ref holder-next found)
                        (array-ref holder-first holder.index))
                      (set! (array-ref holder-first holder.index) found)
                      (set!
                        (array-ref loan-next found)
                        (array-ref loan-first loan.index))
                      (set! (array-ref loan-first loan.index) found)
                      (set! pairs (+ pairs 1)))
                    (set!
                      (array-ref point-pair (+ (array-ref offsets b) j))
                      found)))]
              [_ unit])
            (set! j (+ j 1)))
          (set! b (+ b 1))))
      (OwnershipLoanDemandsResult.Ok
        (OwnershipLoanDemands
          pairs
          pair-holder
          pair-loan
          point-pair
          point-kill
          point-source
          point-run
          holder-first
          holder-next
          loan-first
          loan-next
          reissued)))))

;; The reborrows of each loan in increasing index order: `children` holds the
;; first child of each loan, then each loan's next sibling (-1 for none).
(define (ownership-loan-children [body : (& body OwnershipBody)]) : (__tl_dyn-array
    i64)
  (let
    [loans : i64 (array-length body.loans)]
    [children : (__tl_dyn-array i64) (__tl_make-array i64 (* 2 loans))]
    [child : i64 loans]
    (ownership-i64-fill! (&mut children) -1)
    (while (> child 0)
      (set! child (- child 1))
      (let
        [parent : i64 (ownership-loan-parent (& (array-ref body.loans child)))]
        (when
          (>= parent 0)
          (set!
            (array-ref children (+ loans child))
            (array-ref children parent))
          (set! (array-ref children parent) child))))
    children))

(define (ownership-live-kill-definition!
  [body : (& body OwnershipBody)]
  [demands : (& demands OwnershipLoanDemands)]
  [children : (& children (__tl_dyn-array i64))]
  [state : (&mut state (__tl_dyn-array i64))]
  [definition : i64]
  [work : (&mut work i64)]
  [limit : i64]) : bool
  (let
    [loans : i64 (array-length body.loans)]
    [child : i64 (array-ref children definition)]
    ;; The later loans scanned for children so far, each one unit: every
    ;; loan after the definition up to the retaining child, or to the end.
    [scanned : i64 definition]
    [units : i64 0]
    [retained? : bool false]
    ;; Liveness is ancestor-closed. A demanded descendant therefore has a
    ;; demanded immediate child on this chain, directly or through a holder.
    ;; Removing only a leaf preserves that invariant and keeps the old
    ;; generation alive across parent reissue.
    (while (and (not retained?) (>= child 0))
      (set! units (+ units (- child scanned)))
      (set! scanned child)
      (when (ownership-loan-bit? state 0 child) (set! retained? true))
      (let
        [p : i64 (array-ref demands.loan-first child)]
        (while (and (not retained?) (>= p 0))
          (set! units (+ units 1))
          (when (ownership-loan-bit? state 0 (+ loans p)) (set! retained? true))
          (set! p (array-ref demands.loan-next p))))
      (set! child (array-ref children (+ loans child))))
    (unless retained? (set! units (+ units (- (- loans 1) scanned))))
    ;; Work only grows: the sum runs out exactly when a unit of it would.
    (unless (ownership-charge! work limit units) (return false))
    ;; The plain demands end here: each is the new issue's own (its retention
    ;; and its first uses), or comes with a holder's demand of the same use. A
    ;; holder's demand ends here only when the loan cannot be issued again: on
    ;; a cycle, the holder may still carry the earlier issue past this point.
    (unless
      retained?
      (ownership-loan-bit-set! state 0 definition false)
      (unless
        (array-ref demands.reissued definition)
        (let
          [p : i64 (array-ref demands.loan-first definition)]
          (while (>= p 0)
            (unless (ownership-charge! work limit 1) (return false))
            (ownership-loan-bit-set! state 0 (+ loans p) false)
            (set! p (array-ref demands.loan-next p))))))
    true))

;; The pair of `loan` through `holder`, or -1.
(define (ownership-demand-pair
  [demands : (& demands OwnershipLoanDemands)]
  [holder : i64]
  [loan : i64]
  [work : (&mut work i64)]
  [limit : i64]) : i64
  (let
    [p : i64 (array-ref demands.loan-first loan)]
    (while (>= p 0)
      (unless (ownership-charge! work limit 1) (return -2))
      (when (= (array-ref demands.pair-holder p) holder) (return p))
      (set! p (array-ref demands.loan-next p)))
    -1))

;; A Copy or Move at `instruction` overwrites its holder root whole: the value
;; a later use reads from it is the one stored here, so the demands of reads
;; through the holder end. A demanded loan the new value may carry must stay
;; demanded across the transfer itself, or the forward walk would expire it
;; at this point and stop checking it. A transfer the normalizer emits reads
;; its source, and that use's MayUseLoan operations, one per loan of the
;; source's origin, precede it (cleanup elaboration may put a RequireEmpty in
;; between). Each names the root holding its loan: the source, or for a loan
;; of a borrowed referent, the borrowed root. A demanded loan among them
;; continues as that MayUseLoan's own demand (another use's operations in the
;; same run only keep more loans), and one missing from them cannot be in the
;; new value and ends here.
;; Without such operations (a source with no recorded origin, or a Move
;; synthesized by cleanup elaboration) the loans the transfer carries are
;; unknown, so each demand continues as the source's demand of its loan if it
;; has one, or else as a plain demand. The single Assign of a temporary
;; overwrites it whole too; the operands it is computed from were read with
;; their own demands, and each demand of the temporary continues as a plain one.
(define (ownership-live-kill-holder!
  [body : (& body OwnershipBody)]
  [demands : (& demands OwnershipLoanDemands)]
  [state : (&mut state (__tl_dyn-array i64))]
  [block : i64]
  [instruction : i64]
  [offset : i64]
  [work : (&mut work i64)]
  [limit : i64]) : bool
  (let
    [loans : i64 (array-length body.loans)]
    [point : i64 (+ offset instruction)]
    [source : i64 (array-ref demands.point-source point)]
    [run : i64 (array-ref demands.point-run point)]
    [instructions : (& body (__tl_dyn-array OwnershipInstruction))
      (& (array-ref body.blocks block).instructions)]
    [p : i64
      (array-ref demands.holder-first (array-ref demands.point-kill point))]
    (while (>= p 0)
      (unless (ownership-charge! work limit 1) (return false))
      (when
        (ownership-loan-bit? state 0 (+ loans p))
        (ownership-loan-bit-set! state 0 (+ loans p) false)
        (let
          [loan : i64 (array-ref demands.pair-loan p)]
          (cond
            [(>= run 0)
              (let
                [k : i64 run]
                [found : bool false]
                (while (and (not found) (< k instruction))
                  (unless (ownership-charge! work limit 1) (return false))
                  (match (& (array-ref instructions k).operation)
                    [(OwnershipOperation.MayUseLoan used _)
                      (when
                        (= used.index loan)
                        (let
                          [bridge : i64
                            (array-ref demands.point-pair (+ offset k))]
                          (if (>= bridge 0)
                            (ownership-loan-bit-set!
                              state
                              0
                              (+ loans bridge)
                              true)
                            (ownership-live-use! body state loan)))
                        (set! found true))]
                    [_ unit])
                  (set! k (+ k 1))))]
            [(>= source 0)
              (let
                [bridge : i64
                  (ownership-demand-pair demands source loan work limit)]
                (when (= bridge -2) (return false))
                (if (>= bridge 0)
                  (ownership-loan-bit-set! state 0 (+ loans bridge) true)
                  (ownership-live-use! body state loan)))]
            [else (ownership-live-use! body state loan)])))
      (set! p (array-ref demands.holder-next p)))
    true))

;; One bit per loan from the demand rows: a loan is live where any of its
;; demands is.
(define (ownership-loan-liveness-project
  [demands : (& demands OwnershipLoanDemands)]
  [inner : (& inner (__tl_dyn-array i64))]
  [points : i64]
  [loans : i64]
  [wide : i64]
  [work : (&mut work i64)]
  [limit : i64]) : (__tl_dyn-array i64)
  (let
    [stride : i64 (ownership-loan-words loans)]
    [live : (__tl_dyn-array i64) (__tl_make-array i64 (* points stride))]
    [tail : i64 (bit-and loans 63)]
    [point : i64 0]
    (unless
      (ownership-product-charge! work limit points (+ stride demands.pairs))
      (return (__tl_make-array i64 0)))
    (while (< point points)
      (let
        [w : i64 0]
        (while (< w stride)
          (let
            [word : i64 (array-ref inner (+ (* point wide) w))]
            (set!
              (array-ref live (+ (* point stride) w))
              (if (and (= w (- stride 1)) (!= tail 0))
                (bit-and word (- (shl 1 tail) 1))
                word)))
          (set! w (+ w 1)))
        ;; Pair bits follow the loan bits; only the set ones are visited.
        (set! w (/ loans 64))
        (while (< w wide)
          (let
            [rest : i64
              (if (and (= w (/ loans 64)) (!= tail 0))
                (bit-and (array-ref inner (+ (* point wide) w)) (shl -1 tail))
                (array-ref inner (+ (* point wide) w)))]
            [p : i64 (- (* w 64) loans)]
            (while (!= rest 0)
              (if (= (bit-and rest 255) 0)
                (begin
                  (set! rest (bit-and (shr rest 8) 72057594037927935))
                  (set! p (+ p 8)))
                (begin
                  (when
                    (!= (bit-and rest 1) 0)
                    (ownership-loan-bit-set!
                      (&mut live)
                      (* point stride)
                      (array-ref demands.pair-loan p)
                      true))
                  (set! rest (bit-and (shr rest 1) 9223372036854775807))
                  (set! p (+ p 1))))))
          (set! w (+ w 1))))
      (set! point (+ point 1)))
    live))

;; Each block's two successors (-1 for none): `2b` and `2b + 1`.
(define (ownership-live-successors [body : (& body OwnershipBody)]) : (__tl_dyn-array
    i64)
  (let
    [successors : (__tl_dyn-array i64)
      (__tl_make-array i64 (* 2 (array-length body.blocks)))]
    [b : i64 0]
    (while (< b (array-length body.blocks))
      (set!
        (array-ref successors (* 2 b))
        (ownership-successor (& (array-ref body.blocks b).terminator) 0))
      (set!
        (array-ref successors (+ (* 2 b) 1))
        (ownership-successor (& (array-ref body.blocks b).terminator) 1))
      (set! b (+ b 1)))
    successors))

;; Whether block `b` has not been visited, or a successor's entry row changed
;; since its last visit (`ownership-loan-liveness`).
(define (ownership-live-stale?
  [successors : (& successors (__tl_dyn-array i64))]
  [seen : (& seen (__tl_dyn-array i64))]
  [stamp : (& stamp (__tl_dyn-array i64))]
  [b : i64]) : bool
  (let
    [first : i64 (array-ref successors (* 2 b))]
    [second : i64 (array-ref successors (+ (* 2 b) 1))]
    (or
      (< (array-ref seen b) 0)
      (and (>= first 0) (> (array-ref stamp first) (array-ref seen b)))
      (and (>= second 0) (> (array-ref stamp second) (array-ref seen b))))))

;; One visit of block `b` in the backward demand solve: the successors' entry
;; rows are joined, the instructions run backward, and each point's row joins
;; the state there. Bit 1 of `flags` reports a changed row, and bit 2 a changed
;; entry row (the block's first point). The result is -1, or the instruction
;; where the work budget ran out (the instruction count for the block's own
;; reservation). A reservation of one unit and `wide` words twice (four
;; times for the block) is a single sum: work only grows, so the sum runs out
;; exactly when one of its parts would.
(define (ownership-live-visit!
  [body : (& body OwnershipBody)]
  [demands : (& demands OwnershipLoanDemands)]
  [children : (& children (__tl_dyn-array i64))]
  [offsets : (& offsets (__tl_dyn-array i64))]
  [inner : (&mut inner (__tl_dyn-array i64))]
  [state : (&mut state (__tl_dyn-array i64))]
  [b : i64]
  [work : (&mut work i64)]
  [limit : i64]
  [flags : (&mut flags i64)]) : i64
  (let
    [loans : i64 (array-length body.loans)]
    [wide : i64 (array-length state)]
    [block : (& body OwnershipBlock) (& (array-ref body.blocks b))]
    [i : i64 0]
    [edge : i64 0]
    [j : i64 (array-length block.instructions)]
    [step : i64 (+ 1 (* 2 wide))]
    (unless (ownership-charge! work limit (+ 1 (* 4 wide))) (return j))
    (while (< i wide)
      (set! (array-ref state i) 0)
      (set! i (+ i 1)))
    (while (< edge 2)
      (let
        [target : i64 (ownership-successor (& block.terminator) edge)]
        (when
          (>= target 0)
          (set! i 0)
          (while (< i wide)
            (set!
              (array-ref state i)
              (bit-or
                (array-ref state i)
                (array-ref inner (+ (* (array-ref offsets target) wide) i))))
            (set! i (+ i 1))))
        (set! edge (+ edge 1))))
    (when
      (ownership-live-join-row!
        inner
        state
        (* (+ (array-ref offsets b) j) wide))
      (set!
        (deref flags)
        (if (= j 0)
          3
          1)))
    (while (> j 0)
      (set! j (- j 1))
      (unless (ownership-charge! work limit step) (return j))
      (let
        [op : (& body OwnershipOperation)
          (& (array-ref block.instructions j).operation)]
        [definition : i64 (ownership-loan-definition op)]
        [point : i64 (+ (array-ref offsets b) j)]
        [pair : i64 (array-ref demands.point-pair point)]
        [overwritten : i64 (array-ref demands.point-kill point)]
        (when
          (>= definition 0)
          (unless
            (ownership-live-kill-definition!
              body
              demands
              children
              state
              definition
              work
              limit)
            (return j))
          (ownership-live-use!
            body
            state
            (ownership-loan-parent (& (array-ref body.loans definition)))))
        (when
          (>= overwritten 0)
          (unless
            (ownership-live-kill-holder!
              body
              demands
              state
              b
              j
              (array-ref offsets b)
              work
              limit)
            (return j)))
        (if (>= pair 0)
          (begin
            ;; The pair holds the use itself; the loan's ancestors are
            ;; demanded as before.
            (ownership-loan-bit-set! state 0 (+ loans pair) true)
            (ownership-live-use!
              body
              state
              (ownership-loan-parent
                (& (array-ref body.loans (array-ref demands.pair-loan pair))))))
          (ownership-live-use! body state (ownership-loan-used op)))
        (when
          (ownership-live-join-row! inner state (* point wide))
          (set!
            (deref flags)
            (bit-or
              (deref flags)
              (if (= j 0)
                3
                1))))))
    -1))

;; The table is body-owned and solved from graph uses; no caller-supplied end
;; point or liveness fact is accepted. PRECONDITION: ownership-validate succeeded
;; for this immutable body and these limits; all dimensions were reserved there.
;;
;; Demands are solved backward. A loan's own bit is a demand that ends only at
;; the loan's definition: a UseLoan, EndLoan or AccessThrough, a reborrow's
;; parent, an ancestor of a used loan, or a MayUseLoan whose holder is never
;; overwritten whole. A pair bit is a MayUseLoan's demand through its holder,
;; the root whose value holds the loan. Like the liveness of the variable a Rust
;; reference lives in, it also ends where a Copy or Move overwrites that whole
;; root: the value read later was stored there, and the transfer is itself a
;; use of its source (`normalize-emit!` records it), whose loans are therefore
;; demanded before it. A reference joined from several branches in a loop thus
;; demands a branch's loan only on paths through that branch's assignment.
;;
;; A loan defined on a control-flow cycle is issued again on each trip, while
;; a reference may still hold the issue of an earlier trip and be read later
;; (`prev` in `(set! prev cur)` after `cur` borrows again). Its holder demands
;; therefore end only where the holder is overwritten whole, never at the
;; definition, which ends only the plain bit; the loan stays live across the
;; loop back edge exactly while such a reference may be read. The forward walk
;; then sees the loan active at its next definition: a shared issue joins the
;; held one, and an exclusive issue is rejected.
(define (ownership-loan-liveness
  [body : (& body OwnershipBody)]
  [limits : OwnershipLimits]) : OwnershipLoanLivenessResult
  (let
    [loans : i64 (array-length body.loans)]
    [blocks : i64 (array-length body.blocks)]
    (if (= loans 0)
      (OwnershipLoanLivenessResult.Ok
        (OwnershipLoanLiveness
          (__tl_make-array i64 0)
          0
          (__tl_make-array i64 0)))
      (let
        [offsets : (__tl_dyn-array i64) (__tl_make-array i64 (+ blocks 1))]
        [stride : i64 (ownership-loan-words loans)]
        [points : i64 0]
        [b : i64 0]
        [work : i64 0]
        (while (< b blocks)
          (set! (array-ref offsets b) points)
          (set!
            points
            (+ points 1 (array-length (array-ref body.blocks b).instructions)))
          (set! b (+ b 1)))
        (set! (array-ref offsets blocks) points)
        (match (ownership-loan-demands
          body
          (& offsets)
          points
          (&mut work)
          limits.max-work)
          [(OwnershipLoanDemandsResult.Err error)
            (OwnershipLoanLivenessResult.Err error)]
          [(OwnershipLoanDemandsResult.Ok demands)
            (let
              [wide : i64 (ownership-loan-words (+ loans demands.pairs))]
              [inner : (__tl_dyn-array i64)
                (__tl_make-array i64 (* points wide))]
              [state : (__tl_dyn-array i64) (__tl_make-array i64 wide)]
              [children : (__tl_dyn-array i64) (ownership-loan-children body)]
              ;; Per block: the clock at its last visit (-1 before any), the
              ;; clock when its entry row last changed, and the work its last
              ;; visit charged. The clock counts entry row changes.
              [seen : (__tl_dyn-array i64) (__tl_make-array i64 blocks)]
              [stamp : (__tl_dyn-array i64) (__tl_make-array i64 blocks)]
              ;; The successors of block `b` (-1 for none) at `2b` and `2b + 1`.
              [successors : (__tl_dyn-array i64)
                (ownership-live-successors body)]
              [cost : (__tl_dyn-array i64) (__tl_make-array i64 blocks)]
              [clock : i64 0]
              [flags : i64 0]
              [changed : bool true]
              (ownership-i64-fill! (&mut seen) -1)
              (while changed
                (set! changed false)
                (set! b blocks)
                (while (> b 0)
                  (set! b (- b 1))
                  ;; A block whose successors' entry rows are unchanged since
                  ;; its last visit would repeat that visit exactly: the same
                  ;; rows and the same work. The work is charged again without
                  ;; the visit; when that charge fails, the visit finds where.
                  (when
                    (or
                      (ownership-live-stale?
                        (& successors)
                        (& seen)
                        (& stamp)
                        b)
                      (not
                        (ownership-charge!
                          (&mut work)
                          limits.max-work
                          (array-ref cost b))))
                    (let
                      [before : i64 work]
                      [stop : i64 0]
                      (set! (array-ref seen b) clock)
                      (set! flags 0)
                      (set!
                        stop
                        (ownership-live-visit!
                          body
                          (& demands)
                          (& children)
                          (& offsets)
                          (&mut inner)
                          (&mut state)
                          b
                          (&mut work)
                          limits.max-work
                          (&mut flags)))
                      (when
                        (>= stop 0)
                        (return
                          (OwnershipLoanLivenessResult.Err
                            (ownership-liveness-exhausted body b stop))))
                      (set! (array-ref cost b) (- work before))
                      (when (!= flags 0) (set! changed true))
                      (when
                        (!= (bit-and flags 2) 0)
                        (set! clock (+ clock 1))
                        (set! (array-ref stamp b) clock))))))
              (if (= demands.pairs 0)
                (OwnershipLoanLivenessResult.Ok
                  (OwnershipLoanLiveness offsets stride inner))
                (let
                  [live : (__tl_dyn-array i64)
                    (ownership-loan-liveness-project
                      (& demands)
                      (& inner)
                      points
                      loans
                      wide
                      (&mut work)
                      limits.max-work)]
                  (if (= (array-length live) (* points stride))
                    (OwnershipLoanLivenessResult.Ok
                      (OwnershipLoanLiveness offsets stride live))
                    (OwnershipLoanLivenessResult.Err
                      (ownership-liveness-exhausted body 0 0))))))])))))

;; An active loan the graph no longer demands at `point` ends: its state bit 2
;; becomes bit 4, a word of loans at a time (`ownership-loan-code`).
(define (ownership-loan-expire-row!
  [state : (&mut state (__tl_dyn-array i64))]
  [liveness : (& liveness OwnershipLoanLiveness)]
  [point : i64]) : unit
  (let
    [words : i64 (/ (array-length state) 4)]
    [base : i64 (* point liveness.stride)]
    [w : i64 0]
    (while (< w words)
      (let
        [gone : i64
          (bit-and
            (array-ref state (+ words w))
            (bit-not (array-ref liveness.live (+ base w))))]
        (when
          (!= gone 0)
          (set!
            (array-ref state (+ words w))
            (bit-xor (array-ref state (+ words w)) gone))
          (set!
            (array-ref state (+ (* 2 words) w))
            (bit-or (array-ref state (+ (* 2 words) w)) gone))))
      (set! w (+ w 1)))))

;; The expiry on one state code per loan.
(define (ownership-loan-expire!
  [state : (&mut state (__tl_dyn-array i64))]
  [liveness : (& liveness OwnershipLoanLiveness)]
  [point : i64]) : unit
  (let
    [planes : (__tl_dyn-array i64)
      (__tl_make-array i64 (* 4 (ownership-loan-words (array-length state))))]
    [i : i64 0]
    (ownership-i64-fill! (&mut planes) 0)
    (while (< i (array-length state))
      (ownership-loan-code-set! (&mut planes) i (array-ref state i))
      (set! i (+ i 1)))
    (ownership-loan-expire-row! (&mut planes) liveness point)
    (ownership-loan-codes! (& planes) state)))

(define (ownership-loan-ancestor?
  [body : (& body OwnershipBody)]
  [ancestor : i64]
  [loan : i64]) : bool
  (let
    [cursor : i64 loan]
    (while (> cursor ancestor)
      (set! cursor (ownership-loan-parent (& (array-ref body.loans cursor)))))
    (and (>= ancestor 0) (= cursor ancestor))))

;; Charged relations return -1 on exhaustion, never a guessed false answer.
(define (ownership-descendant-charged
  [body : (& body OwnershipBody)]
  [child : i64]
  [ancestor : i64]
  [work : (&mut work i64)]
  [limit : i64]) : i64
  (let
    [cursor : i64 child]
    (while (> cursor ancestor)
      (unless (ownership-charge! work limit 1) (return -1))
      (set! cursor (ownership-parent (& (array-ref body.places cursor)))))
    (unless (ownership-charge! work limit 1) (return -1))
    (if (= cursor ancestor)
      1
      0)))

(define (ownership-loan-ancestor-charged
  [body : (& body OwnershipBody)]
  [ancestor : i64]
  [loan : i64]
  [work : (&mut work i64)]
  [limit : i64]) : i64
  (let
    [cursor : i64 loan]
    (when (< ancestor 0) (return 0))
    (while (> cursor ancestor)
      (unless (ownership-charge! work limit 1) (return -1))
      (set! cursor (ownership-loan-parent (& (array-ref body.loans cursor)))))
    (unless (ownership-charge! work limit 1) (return -1))
    (if (= cursor ancestor)
      1
      0)))

;; Only the granting chain is exempt. Every visited loan and parent link is
;; charged, so shallow/disjoint graphs pay for actual work rather than L*P.
;; -2 is resource exhaustion; -1 means no conflict.
;; The scan visits loans in index order up to the answer. Only an active loan
;; this access can conflict with (any for a write, an exclusive one for a
;; read) is examined, taken from the state's planes a word at a time; every
;; loan scanned counts one unit and each parent link visited one more. The
;; units are charged once, at the answer: work only grows, so the budget
;; runs out by then exactly when it would run out on some unit before it.
(define (ownership-loan-conflict
  [body : (& body OwnershipBody)]
  [state : (& state (__tl_dyn-array i64))]
  [place : i64]
  [grant : i64]
  [write? : bool]
  [work : (&mut work i64)]
  [limit : i64]) : i64
  (let
    [words : i64 (/ (array-length state) 4)]
    [w : i64 0]
    [scanned : i64 0]
    [units : i64 0]
    (while (< w words)
      (let
        [rest : i64 (array-ref state (+ words w))]
        [i : i64 (* w 64)]
        (unless
          write?
          (set! rest (bit-and rest (array-ref state (+ (* 3 words) w)))))
        (while (!= rest 0)
          (if (= (bit-and rest 255) 0)
            (begin
              (set! rest (bit-and (shr rest 8) 72057594037927935))
              (set! i (+ i 8)))
            (begin
              (when
                (!= (bit-and rest 1) 0)
                (set! units (+ units (- (+ i 1) scanned)))
                (set! scanned (+ i 1))
                (when
                  (and
                    (=
                      (ownership-loan-ancestor-charged
                        body
                        i
                        grant
                        (&mut units)
                        9223372036854775807)
                      0)
                    (or
                      (=
                        (ownership-descendant-charged
                          body
                          place
                          (array-ref body.loans i).place.index
                          (&mut units)
                          9223372036854775807)
                        1)
                      (=
                        (ownership-descendant-charged
                          body
                          (array-ref body.loans i).place.index
                          place
                          (&mut units)
                          9223372036854775807)
                        1)))
                  (return
                    (if (ownership-charge! work limit units)
                      i
                      -2))))
              (set! rest (bit-and (shr rest 1) 9223372036854775807))
              (set! i (+ i 1))))))
      (set! w (+ w 1)))
    (if (ownership-charge!
      work
      limit
      (+ units (- (array-length body.loans) scanned)))
      -1
      -2)))

(define (ownership-loan-access
  [body : (& body OwnershipBody)]
  [state : (& state (__tl_dyn-array i64))]
  [place : i64]
  [grant : i64]
  [write? : bool]
  [block : i64]
  [instruction : i64]
  [source : (& source OwnershipSource)]
  [work : (&mut work i64)]
  [limit : i64]) : OwnershipResult
  (let
    [conflict : i64
      (ownership-loan-conflict body state place grant write? work limit)]
    (cond
      [(= conflict -2)
        (ownership-failure
          OwnershipFailureKind.Resource
          block
          instruction
          place
          source
          "ownership loan access work exhausted")]
      [(>= conflict 0)
        (ownership-loan-failure
          block
          instruction
          place
          grant
          conflict
          source
          "access conflicts with a live loan")]
      [else OwnershipResult.Ok])))

(define (ownership-loan-active
  [body : (& body OwnershipBody)]
  [state : (& state (__tl_dyn-array i64))]
  [loan : i64]
  [block : i64]
  [instruction : i64]
  [source : (& source OwnershipSource)]) : OwnershipResult
  (if (= (ownership-loan-code state loan) 2)
    OwnershipResult.Ok
    (ownership-loan-failure
      block
      instruction
      (array-ref body.loans loan).place.index
      loan
      -1
      source
      "loan is not definitely active")))

(define (ownership-loan-check
  [body : (& body OwnershipBody)]
  [state : (&mut state (__tl_dyn-array i64))]
  [live : (& live OwnershipLoanLiveness)]
  [after : i64]
  [instr : (& instr OwnershipInstruction)]
  [block : i64]
  [index : i64]
  [work : (&mut work i64)]
  [limit : i64]) : OwnershipResult
  (let
    [definition : i64 (ownership-loan-definition (& instr.operation))]
    [used : i64 (ownership-loan-used (& instr.operation))]
    (when
      (>= definition 0)
      (let
        [loan : (& body OwnershipLoan) (& (array-ref body.loans definition))]
        [parent : i64 (ownership-loan-parent loan)]
        ;; A loan issued again on a cycle may still be held from its earlier
        ;; issue. A shared issue joins it, since both permit the same
        ;; accesses; an exclusive one would alias it.
        (when
          (and
            (!= (bit-and (ownership-loan-code state definition) 2) 0)
            (ownership-loan-exclusive? loan))
          (return
            (ownership-loan-failure
              block
              index
              loan.place.index
              definition
              definition
              (& instr.source)
              "loan definition is already active")))
        (when
          (>= parent 0)
          (begin
            (match (ownership-loan-active
              body
              state
              parent
              block
              index
              (& instr.source))
              [(OwnershipResult.Err error) (return (OwnershipResult.Err error))]
              [(OwnershipResult.Ok) unit])
            (when
              (and
                (ownership-loan-exclusive? loan)
                (not
                  (ownership-loan-exclusive? (& (array-ref body.loans parent)))))
              (return
                (ownership-loan-failure
                  block
                  index
                  loan.place.index
                  definition
                  parent
                  (& instr.source)
                  "shared loan cannot grant exclusive authority")))))
        (match (ownership-loan-access
          body
          state
          loan.place.index
          parent
          (ownership-loan-exclusive? loan)
          block
          index
          (& instr.source)
          work
          limit)
          [(OwnershipResult.Err error)
            (match (& error.kind)
              [(OwnershipFailureKind.Loan) (set! error.loan definition)]
              [_ unit])
            (return (OwnershipResult.Err error))]
          [(OwnershipResult.Ok) unit])
        (return OwnershipResult.Ok)))
    (when
      (and
        (>= used 0)
        (match (& instr.operation)
          [(OwnershipOperation.MayUseLoan _ _) false]
          [_ true]))
      (match (ownership-loan-active
        body
        state
        used
        block
        index
        (& instr.source))
        [(OwnershipResult.Err error) (return (OwnershipResult.Err error))]
        [(OwnershipResult.Ok) unit]))
    (match (& instr.operation)
      [(OwnershipOperation.Read place)
        (ownership-loan-access
          body
          state
          place.index
          -1
          false
          block
          index
          (& instr.source)
          work
          limit)]
      [(OwnershipOperation.Assign place)
        (ownership-loan-access
          body
          state
          place.index
          -1
          true
          block
          index
          (& instr.source)
          work
          limit)]
      [(OwnershipOperation.RequireEmpty _) OwnershipResult.Ok]
      [(OwnershipOperation.BindFresh _) OwnershipResult.Ok]
      [(OwnershipOperation.BeginConstruction _) OwnershipResult.Ok]
      [(OwnershipOperation.BindComplete _) OwnershipResult.Ok]
      [(OwnershipOperation.CleanupPlace _ _) OwnershipResult.Ok]
      [(OwnershipOperation.CleanupFailure _) OwnershipResult.Ok]
      [(OwnershipOperation.BindMove _ _) OwnershipResult.Ok]
      [(OwnershipOperation.Leave _) OwnershipResult.Ok]
      [(OwnershipOperation.Cleanup _ _) OwnershipResult.Ok]
      [(OwnershipOperation.Initialize place)
        (ownership-loan-access
          body
          state
          place.index
          -1
          true
          block
          index
          (& instr.source)
          work
          limit)]
      [(OwnershipOperation.Invalidate place)
        (ownership-loan-access
          body
          state
          place.index
          -1
          true
          block
          index
          (& instr.source)
          work
          limit)]
      [(OwnershipOperation.Consume place)
        (ownership-loan-access
          body
          state
          place.index
          -1
          (not
            (array-ref
              body.types
              (array-ref body.places place.index).type.index).copy?)
          block
          index
          (& instr.source)
          work
          limit)]
      [(OwnershipOperation.Copy source dest)
        (match (ownership-loan-access
          body
          state
          source.index
          -1
          false
          block
          index
          (& instr.source)
          work
          limit)
          [(OwnershipResult.Err error) (OwnershipResult.Err error)]
          [(OwnershipResult.Ok)
            (ownership-loan-access
              body
              state
              dest.index
              -1
              true
              block
              index
              (& instr.source)
              work
              limit)])]
      [(OwnershipOperation.Move source dest)
        (match (ownership-loan-access
          body
          state
          source.index
          -1
          (not
            (array-ref
              body.types
              (array-ref body.places source.index).type.index).copy?)
          block
          index
          (& instr.source)
          work
          limit)
          [(OwnershipResult.Err error) (OwnershipResult.Err error)]
          [(OwnershipResult.Ok)
            (ownership-loan-access
              body
              state
              dest.index
              -1
              true
              block
              index
              (& instr.source)
              work
              limit)])]
      [(OwnershipOperation.EndLoan loan)
        (if (ownership-loan-live? live after loan.index)
          (ownership-loan-failure
            block
            index
            (array-ref body.loans loan.index).place.index
            loan.index
            -1
            (& instr.source)
            "ending loan is still demanded by the graph")
          OwnershipResult.Ok)]
      [(OwnershipOperation.AccessThrough loan place access)
        (let
          [write? : bool
            (match access
              [(OwnershipAccess.Read) false]
              [(OwnershipAccess.Write) true])]
          (if (not
            (ownership-loan-permits-access?
              (& (array-ref body.loans loan.index))
              access))
            (ownership-loan-failure
              block
              index
              place.index
              loan.index
              -1
              (& instr.source)
              "shared loan cannot write")
            (ownership-loan-access
              body
              state
              place.index
              loan.index
              write?
              block
              index
              (& instr.source)
              work
              limit)))]
      [(OwnershipOperation.UseLoan _) OwnershipResult.Ok]
      [(OwnershipOperation.MayUseLoan _ _) OwnershipResult.Ok]
      [(OwnershipOperation.Borrow _) OwnershipResult.Ok]
      [(OwnershipOperation.Reborrow _) OwnershipResult.Ok]
      [(OwnershipOperation.Unsupported _) OwnershipResult.Ok])))

;; This is the single loan effect implementation used by admission and
;; diagnostic fixed-point inspection. The result remains an error even though
;; inspection may use the syntactic successor state of an invalid prefix.
;; PRECONDITION: immutable validated body/instruction, one nonempty mask (1..7)
;; per loan in the planes of `ownership-loan-code`, and a bounded liveness
;; table/row produced for that same body.
(define (ownership-loan-step!
  [body : (& body OwnershipBody)]
  [state : (&mut state (__tl_dyn-array i64))]
  [live : (& live OwnershipLoanLiveness)]
  [after : i64]
  [instr : (& instr OwnershipInstruction)]
  [block : i64]
  [index : i64]
  [work : (&mut work i64)]
  [limit : i64]) : OwnershipResult
  (let
    [checked : OwnershipResult
      (ownership-loan-check body state live after instr block index work limit)]
    [definition : i64 (ownership-loan-definition (& instr.operation))]
    (when (>= definition 0) (ownership-loan-code-set! state definition 2))
    (match (& instr.operation)
      [(OwnershipOperation.EndLoan loan)
        (ownership-loan-code-set! state loan.index 4)]
      [_ unit])
    (if (ownership-result-ok? (& checked))
      OwnershipResult.Ok
      checked)))

;; The same transfer on one state code per loan.
(define (ownership-loan-transfer!
  [body : (& body OwnershipBody)]
  [state : (&mut state (__tl_dyn-array i64))]
  [live : (& live OwnershipLoanLiveness)]
  [after : i64]
  [instr : (& instr OwnershipInstruction)]
  [block : i64]
  [index : i64]
  [work : (&mut work i64)]
  [limit : i64]) : OwnershipResult
  (let
    [planes : (__tl_dyn-array i64) (ownership-loan-planes body state)]
    [checked : OwnershipResult
      (ownership-loan-step!
        body
        (&mut planes)
        live
        after
        instr
        block
        index
        work
        limit)]
    (ownership-loan-codes! (& planes) state)
    checked))

;; Ephemeral adjacency built only after structural validation. Each node has
;; one parent and one sibling link; traversal never scans unrelated places.
(defstruct OwnershipPlaceIndex
  (parent (__tl_dyn-array i64))
  (first-child (__tl_dyn-array i64))
  (next-sibling (__tl_dyn-array i64)))

(define (ownership-place-index [body : (& body OwnershipBody)]) : OwnershipPlaceIndex
  (let
    [count : i64 (array-length body.places)]
    [parent : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [first : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [next : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [i : i64 0]
    (while (< i count)
      (set!
        (array-ref parent i)
        (ownership-parent (& (array-ref body.places i))))
      (set! (array-ref first i) -1)
      (set! (array-ref next i) -1)
      (set! i (+ i 1)))
    (while (> i 0)
      (set! i (- i 1))
      (let
        [owner : i64 (array-ref parent i)]
        (when
          (>= owner 0)
          (set! (array-ref next i) (array-ref first owner))
          (set! (array-ref first owner) i))))
    (OwnershipPlaceIndex parent first next)))

(define (ownership-state-set!
  [places : (& places OwnershipPlaceIndex)]
  [state : (&mut state (__tl_dyn-array i64))]
  [place : i64]
  [value : i64]
  [work : (&mut work i64)]
  [limit : i64]) : bool
  (let
    [cursor : i64 place]
    [parent : i64 (array-ref places.parent place)]
    ;; A whole local without fields is one charged cell.
    (when
      (and (< parent 0) (< (array-ref places.first-child place) 0))
      (unless (ownership-charge! work limit 1) (return false))
      (let
        [cell : i64 (/ place 16)]
        [shift : i64 (* 4 (bit-and place 15))]
        (set!
          (array-ref state cell)
          (bit-or
            (bit-and (array-ref state cell) (bit-not (shl 15 shift)))
            (shl (bit-and value 15) shift))))
      (return true))
    ;; Stackless subtree traversal. Every descent and ascent is bounded by
    ;; the validated tree and charged before touching the corresponding row.
    (while (>= cursor 0)
      (begin
        (unless (ownership-charge! work limit 1) (return false))
        (ownership-state-put! state 0 cursor value)
        (if (>= (array-ref places.first-child cursor) 0)
          (set! cursor (array-ref places.first-child cursor))
          (begin
            (while (and
              (!= cursor place)
              (< (array-ref places.next-sibling cursor) 0))
              (unless (ownership-charge! work limit 1) (return false))
              (set! cursor (array-ref places.parent cursor)))
            (set!
              cursor
              (if (= cursor place)
                -1
                (array-ref places.next-sibling cursor)))))))
    (while (>= parent 0)
      (let
        [child : i64 (array-ref places.first-child parent)]
        [joined : i64 0]
        (unless (ownership-charge! work limit 1) (return false))
        (while (>= child 0)
          (unless (ownership-charge! work limit 1) (return false))
          (set!
            joined
            (ownership-state-join joined (ownership-state-get state 0 child)))
          (set! child (array-ref places.next-sibling child)))
        (ownership-state-put! state 0 parent joined)
        (set! parent (array-ref places.parent parent))))
    true))

(define (ownership-set-result!
  [places : (& places OwnershipPlaceIndex)]
  [state : (&mut state (__tl_dyn-array i64))]
  [place : i64]
  [value : i64]
  [work : (&mut work i64)]
  [limit : i64]
  [block : i64]
  [instruction : i64]
  [source : (& source OwnershipSource)]) : OwnershipResult
  (if (ownership-state-set! places state place value work limit)
    OwnershipResult.Ok
    (ownership-fail
      OwnershipFailureKind.Resource
      block
      instruction
      place
      source
      "ownership place traversal work exhausted")))

(define (ownership-read
  [state : (& state (__tl_dyn-array i64))]
  [place : (& place OwnershipPlaceId)]
  [block : i64]
  [instruction : i64]
  [source : (& source OwnershipSource)]) : OwnershipResult
  (if (ownership-state-readable? (ownership-state-get state 0 place.index))
    OwnershipResult.Ok
    (ownership-fail
      OwnershipFailureKind.Uninitialized
      block
      instruction
      place.index
      source
      "value may be moved or uninitialized")))

(define (ownership-empty
  [state : (& state (__tl_dyn-array i64))]
  [place : (& place OwnershipPlaceId)]
  [block : i64]
  [instruction : i64]
  [source : (& source OwnershipSource)]) : OwnershipResult
  (if (= (ownership-state-get state 0 place.index) 1)
    OwnershipResult.Ok
    (ownership-failure
      OwnershipFailureKind.Cleanup
      block
      instruction
      place.index
      source
      "destination may already contain an initialized value")))

;; Whether place `inner` is `root` or one of its fields, transitively.
(define (ownership-place-under?
  [body : (& body OwnershipBody)]
  [inner : i64]
  [root : i64]) : bool
  (let
    [cursor : i64 inner]
    [found : bool (= inner root)]
    (while (and (not found) (>= cursor 0))
      (set!
        cursor
        (match (& (array-ref body.places cursor).projection)
          [(OwnershipProjection.Field parent _) parent.index]
          [_ -1]))
      (when (= cursor root) (set! found true)))
    found))

;; What the leaves of a place that should be empty still hold: 0 a value in
;; every leaf, 1 values in some leaves (the rest moved out), 2 a value on some
;; paths. Computed only for a failed check.
(define (ownership-held-summary
  [body : (& body OwnershipBody)]
  [state : (& state (__tl_dyn-array i64))]
  [root : i64]) : i64
  (let
    [count : i64 (array-length body.places)]
    [parent? : (__tl_dyn-array bool) (__tl_make-array bool count)]
    [index : i64 0]
    [held : bool false]
    [empty : bool false]
    [maybe : bool false]
    (while (< index count)
      (begin
        (match (& (array-ref body.places index).projection)
          [(OwnershipProjection.Field parent _)
            (set! (array-ref parent? parent.index) true)]
          [_ unit])
        (set! index (+ index 1))))
    (set! index 0)
    (while (< index count)
      (when
        (and
          (not (array-ref parent? index))
          (< (/ index 16) (array-length state))
          (ownership-place-under? body index root))
        (let
          [leaf : i64 (ownership-state-get state 0 index)]
          (cond
            [(= leaf 3) (set! maybe true)]
            [(= leaf 2) (set! held true)]
            [(= leaf 1) (set! empty true)]
            [else unit])))
      (set! index (+ index 1)))
    (cond [maybe 2] [(and held empty) 1] [else 0])))

;; A `RequireEmpty` failure says what the place still holds.
(define (ownership-require-empty
  [body : (& body OwnershipBody)]
  [state : (& state (__tl_dyn-array i64))]
  [place : (& place OwnershipPlaceId)]
  [block : i64]
  [instruction : i64]
  [source : (& source OwnershipSource)]) : OwnershipResult
  (if (= (ownership-state-get state 0 place.index) 1)
    OwnershipResult.Ok
    (ownership-failure
      OwnershipFailureKind.Cleanup
      block
      instruction
      place.index
      source
      (let
        [summary : i64 (ownership-held-summary body state place.index)]
        (cond
          [(= summary 2) "place that must be empty may hold a value"]
          [(= summary 1) "place that must be empty partly holds a value"]
          [else "place that must be empty holds a value"])))))

(define (ownership-unelaborated
  [block : i64]
  [instruction : i64]
  [source : (& source OwnershipSource)]) : OwnershipResult
  (ownership-failure
    OwnershipFailureKind.Structural
    block
    instruction
    -1
    source
    "cleanup operation requires checked scope elaboration"))

;; Checks and effects are separate so diagnostic inspection can continue a
;; rejected graph conservatively without inventing a second transfer model.
(define (ownership-initialization-check
  [body : (& body OwnershipBody)]
  [state : (& state (__tl_dyn-array i64))]
  [instr : (& instr OwnershipInstruction)]
  [block : i64]
  [index : i64]) : OwnershipResult
  (match (& instr.operation)
    [(OwnershipOperation.Read place)
      (ownership-read state (& place) block index (& instr.source))]
    [(OwnershipOperation.Initialize place)
      (ownership-empty state (& place) block index (& instr.source))]
    [(OwnershipOperation.RequireEmpty place)
      (ownership-require-empty
        body
        state
        (& place)
        block
        index
        (& instr.source))]
    [(OwnershipOperation.Consume place)
      (ownership-read state (& place) block index (& instr.source))]
    [(OwnershipOperation.Copy source _)
      (ownership-read state (& source) block index (& instr.source))]
    [(OwnershipOperation.Move source _)
      (ownership-read state (& source) block index (& instr.source))]
    [(OwnershipOperation.Borrow loan)
      (ownership-read
        state
        (& (array-ref body.loans loan.index).place)
        block
        index
        (& instr.source))]
    [(OwnershipOperation.Reborrow loan)
      (ownership-read
        state
        (& (array-ref body.loans loan.index).place)
        block
        index
        (& instr.source))]
    [(OwnershipOperation.AccessThrough _ place access)
      (match access
        [(OwnershipAccess.Read)
          (ownership-read state (& place) block index (& instr.source))]
        [(OwnershipAccess.Write) OwnershipResult.Ok])]
    [(OwnershipOperation.BindFresh _)
      (ownership-unelaborated block index (& instr.source))]
    [(OwnershipOperation.BeginConstruction _)
      (ownership-unelaborated block index (& instr.source))]
    [(OwnershipOperation.BindComplete _)
      (ownership-unelaborated block index (& instr.source))]
    [(OwnershipOperation.CleanupPlace _ _)
      (ownership-unelaborated block index (& instr.source))]
    [(OwnershipOperation.CleanupFailure _)
      (ownership-fail
        OwnershipFailureKind.Cleanup
        block
        index
        -1
        instr.source
        "invalid cleanup scope or resource transfer")]
    [(OwnershipOperation.BindMove _ _)
      (ownership-unelaborated block index (& instr.source))]
    [(OwnershipOperation.Leave _)
      (ownership-unelaborated block index (& instr.source))]
    [(OwnershipOperation.Cleanup _ _)
      (ownership-unelaborated block index (& instr.source))]
    [(OwnershipOperation.Assign _) OwnershipResult.Ok]
    [(OwnershipOperation.Invalidate _) OwnershipResult.Ok]
    [(OwnershipOperation.UseLoan _) OwnershipResult.Ok]
    [(OwnershipOperation.MayUseLoan _ _) OwnershipResult.Ok]
    [(OwnershipOperation.EndLoan _) OwnershipResult.Ok]
    [(OwnershipOperation.Unsupported reason)
      (ownership-fail
        OwnershipFailureKind.Unsupported
        block
        index
        -1
        instr.source
        (string.copy reason))]))

(define (ownership-initialization-effects!
  [body : (& body OwnershipBody)]
  [places : (& places OwnershipPlaceIndex)]
  [state : (&mut state (__tl_dyn-array i64))]
  [instr : (& instr OwnershipInstruction)]
  [block : i64]
  [index : i64]
  [work : (&mut work i64)]
  [limit : i64]) : OwnershipResult
  (match (& instr.operation)
    [(OwnershipOperation.Initialize place)
      (ownership-set-result!
        places
        state
        place.index
        2
        work
        limit
        block
        index
        (& instr.source))]
    [(OwnershipOperation.Assign place)
      (ownership-set-result!
        places
        state
        place.index
        2
        work
        limit
        block
        index
        (& instr.source))]
    [(OwnershipOperation.Invalidate place)
      (ownership-set-result!
        places
        state
        place.index
        1
        work
        limit
        block
        index
        (& instr.source))]
    [(OwnershipOperation.Consume place)
      (if (array-ref body.types (array-ref body.places place.index).type.index).copy?
        OwnershipResult.Ok
        (ownership-set-result!
          places
          state
          place.index
          1
          work
          limit
          block
          index
          (& instr.source)))]
    [(OwnershipOperation.Copy _ dest)
      (ownership-set-result!
        places
        state
        dest.index
        2
        work
        limit
        block
        index
        (& instr.source))]
    [(OwnershipOperation.Move source dest)
      (unless
        (array-ref body.types (array-ref body.places source.index).type.index).copy?
        (match (ownership-set-result!
          places
          state
          source.index
          1
          work
          limit
          block
          index
          (& instr.source))
          [(OwnershipResult.Err error) (return (OwnershipResult.Err error))]
          [(OwnershipResult.Ok) unit]))
      (ownership-set-result!
        places
        state
        dest.index
        2
        work
        limit
        block
        index
        (& instr.source))]
    [(OwnershipOperation.AccessThrough _ place access)
      (match access
        [(OwnershipAccess.Read) OwnershipResult.Ok]
        [(OwnershipAccess.Write)
          (ownership-set-result!
            places
            state
            place.index
            2
            work
            limit
            block
            index
            (& instr.source))])]
    [(OwnershipOperation.Read _) OwnershipResult.Ok]
    [(OwnershipOperation.RequireEmpty _) OwnershipResult.Ok]
    [(OwnershipOperation.Borrow _) OwnershipResult.Ok]
    [(OwnershipOperation.Reborrow _) OwnershipResult.Ok]
    [(OwnershipOperation.UseLoan _) OwnershipResult.Ok]
    [(OwnershipOperation.MayUseLoan _ _) OwnershipResult.Ok]
    [(OwnershipOperation.EndLoan _) OwnershipResult.Ok]
    [(OwnershipOperation.BindFresh _) OwnershipResult.Ok]
    [(OwnershipOperation.BeginConstruction _) OwnershipResult.Ok]
    [(OwnershipOperation.BindComplete _) OwnershipResult.Ok]
    [(OwnershipOperation.CleanupPlace _ _) OwnershipResult.Ok]
    [(OwnershipOperation.CleanupFailure _) OwnershipResult.Ok]
    [(OwnershipOperation.BindMove _ _) OwnershipResult.Ok]
    [(OwnershipOperation.Leave _) OwnershipResult.Ok]
    [(OwnershipOperation.Cleanup _ _) OwnershipResult.Ok]
    [(OwnershipOperation.Unsupported _) OwnershipResult.Ok]))

(define (ownership-transfer-indexed!
  [body : (& body OwnershipBody)]
  [places : (& places OwnershipPlaceIndex)]
  [state : (&mut state (__tl_dyn-array i64))]
  [instr : (& instr OwnershipInstruction)]
  [block : i64]
  [index : i64]
  [work : (&mut work i64)]
  [limit : i64]) : OwnershipResult
  (let
    [checked : OwnershipResult
      (ownership-initialization-check body state instr block index)]
    (if (ownership-result-ok? (& checked))
      (ownership-initialization-effects!
        body
        places
        state
        instr
        block
        index
        work
        limit)
      (match (ownership-initialization-effects!
        body
        places
        state
        instr
        block
        index
        work
        limit)
        [(OwnershipResult.Err error) (OwnershipResult.Err error)]
        [(OwnershipResult.Ok) checked]))))

;; This low-level transfer helper requires an already validated body, as before.
;; It creates the same adjacency used by the combined checker; it is not a
;; source admission API and does not independently discharge loan permissions.
(define (ownership-transfer!
  [body : (& body OwnershipBody)]
  [state : (&mut state (__tl_dyn-array i64))]
  [instr : (& instr OwnershipInstruction)]
  [block : i64]
  [index : i64]) : OwnershipResult
  (let
    [work : i64 0]
    [limits : OwnershipLimits (ownership-default-limits)]
    (unless
      (ownership-product-charge!
        (&mut work)
        limits.max-work
        (array-length body.places)
        6)
      (return
        (ownership-fail
          OwnershipFailureKind.Resource
          block
          index
          -1
          instr.source
          "ownership place index work exhausted")))
    ;; The caller's state holds one value per place; the transfer works on
    ;; a packed row (`ownership-state-get`), copied in and back out.
    (let
      [places : OwnershipPlaceIndex (ownership-place-index body)]
      [count : i64 (array-length body.places)]
      [packed : (__tl_dyn-array i64)
        (__tl_make-array i64 (ownership-state-words count))]
      [i : i64 0]
      (while (< i (array-length packed))
        (set! (array-ref packed i) 0)
        (set! i (+ i 1)))
      (set! i 0)
      (while (and (< i count) (< i (array-length state)))
        (begin
          (ownership-state-put! (&mut packed) 0 i (array-ref state i))
          (set! i (+ i 1))))
      (let
        [result : OwnershipResult
          (ownership-transfer-indexed!
            body
            (& places)
            (&mut packed)
            instr
            block
            index
            (&mut work)
            limits.max-work)]
        (set! i 0)
        (while (and (< i count) (< i (array-length state)))
          (set! (array-ref state i) (ownership-state-get (& packed) 0 i))
          (set! i (+ i 1)))
        result))))

;; The blocks reachable from the entry in reverse postorder: every block comes
;; before its successors except along a backedge. A branch's yes successor is
;; explored last, so its blocks come first (source order).
(define (ownership-reverse-postorder [body : (& body OwnershipBody)]) : (__tl_dyn-array
    i64)
  (let
    [blocks : i64 (array-length body.blocks)]
    [visited : (__tl_dyn-array bool) (__tl_make-array bool blocks)]
    [stack : (__tl_dyn-array i64) (__tl_make-array i64 blocks)]
    [edges : (__tl_dyn-array i64) (__tl_make-array i64 blocks)]
    [post : (__tl_dyn-array i64) (__tl_make-array i64 blocks)]
    [depth : i64 0]
    [count : i64 0]
    [i : i64 0]
    (while (< i blocks)
      (set! (array-ref visited i) false)
      (set! i (+ i 1)))
    (when
      (> blocks 0)
      (set! (array-ref stack 0) body.entry.index)
      (set! (array-ref edges 0) 0)
      (set! (array-ref visited body.entry.index) true)
      (set! depth 1))
    (while (> depth 0)
      (let
        [top : i64 (array-ref stack (- depth 1))]
        [edge : i64 (array-ref edges (- depth 1))]
        (if (< edge 2)
          (let
            [target : i64
              (ownership-successor
                (& (array-ref body.blocks top).terminator)
                (- 1 edge))]
            (set! (array-ref edges (- depth 1)) (+ edge 1))
            (when
              (and (>= target 0) (not (array-ref visited target)))
              (set! (array-ref visited target) true)
              (set! (array-ref stack depth) target)
              (set! (array-ref edges depth) 0)
              (set! depth (+ depth 1))))
          (begin
            (set! (array-ref post count) top)
            (set! count (+ count 1))
            (set! depth (- depth 1))))))
    (let
      [order : (__tl_dyn-array i64) (__tl_make-array i64 count)]
      (set! i 0)
      (while (< i count)
        (set! (array-ref order i) (array-ref post (- (- count 1) i)))
        (set! i (+ i 1)))
      order)))

(define (ownership-loan-step-charge!
  [work : (&mut work i64)]
  [limit : i64]
  [_places : i64]
  [loans : i64]) : bool
  (ownership-charge! work limit loans))

;; Diagnostic observations are not an admission certificate. If complete? is
;; false, rows are only a prefix. Complete rejected graphs contain conservative
;; syntactic continuations after errors; every failure remains sticky.
(defstruct OwnershipObservation
  (enabled? bool)
  (complete? bool)
  (offsets (__tl_dyn-array i64))
  (before-expiry (__tl_dyn-array i64))
  (before (__tl_dyn-array i64))
  (after (__tl_dyn-array i64))
  ;; One bitset per point: 1 uninitialized, 2 loan, 4 cleanup semantic failure.
  (failure-kinds (__tl_dyn-array i64))
  (live (__tl_dyn-array bool)))

(defstruct OwnershipInspection
  (result OwnershipResult)
  (observation OwnershipObservation))

(define (ownership-observation-new [enabled? : bool]) : OwnershipObservation
  (OwnershipObservation
    enabled?
    false
    (__tl_make-array i64 0)
    (__tl_make-array i64 0)
    (__tl_make-array i64 0)
    (__tl_make-array i64 0)
    (__tl_make-array i64 0)
    (__tl_make-array bool 0)))

(define (ownership-observation-prepare!
  [body : (& body OwnershipBody)]
  [live : (& live OwnershipLoanLiveness)]
  [observation : (&mut observation OwnershipObservation)]
  [limits : OwnershipLimits]
  [work : (&mut work i64)]) : bool
  (if (not observation.enabled?)
    true
    (let
      [blocks : i64 (array-length body.blocks)]
      [loans : i64 (array-length body.loans)]
      [places : i64 (array-length body.places)]
      [points : i64 blocks]
      [cells : i64 0]
      [b : i64 0]
      (while (< b blocks)
        (unless
          (and
            (ownership-charge! work limits.max-work 1)
            (ownership-charge!
              (&mut points)
              limits.max-nodes
              (array-length (array-ref body.blocks b).instructions)))
          (return false))
        (set! b (+ b 1)))
      (unless
        (and
          (ownership-product-charge!
            (&mut cells)
            limits.max-state-cells
            blocks
            places)
          (ownership-product-charge!
            (&mut cells)
            limits.max-state-cells
            places
            3)
          (ownership-product-charge!
            (&mut cells)
            limits.max-state-cells
            points
            loans)
          (ownership-product-charge!
            (&mut cells)
            limits.max-state-cells
            blocks
            loans)
          (ownership-product-charge!
            (&mut cells)
            limits.max-state-cells
            loans
            3)
          (ownership-charge! (&mut cells) limits.max-state-cells blocks)
          (ownership-charge! (&mut cells) limits.max-state-cells 1)
          ;; Three forward rows and the backward live row, plus owned offsets.
          (ownership-product-charge!
            (&mut cells)
            limits.max-state-cells
            points
            loans)
          (ownership-product-charge!
            (&mut cells)
            limits.max-state-cells
            points
            loans)
          (ownership-product-charge!
            (&mut cells)
            limits.max-state-cells
            points
            loans)
          (ownership-product-charge!
            (&mut cells)
            limits.max-state-cells
            points
            loans)
          (ownership-charge! (&mut cells) limits.max-state-cells blocks)
          (ownership-charge! (&mut cells) limits.max-state-cells 1)
          (ownership-charge! (&mut cells) limits.max-state-cells points)
          (ownership-charge! work limits.max-work cells))
        (return false))
      (set! observation.offsets (__tl_make-array i64 (+ blocks 1)))
      (set! observation.before-expiry (__tl_make-array i64 (* points loans)))
      (set! observation.before (__tl_make-array i64 (* points loans)))
      (set! observation.after (__tl_make-array i64 (* points loans)))
      (set! observation.live (__tl_make-array bool (* points loans)))
      (set! observation.failure-kinds (__tl_make-array i64 points))
      (set! points 0)
      (set! b 0)
      (while (< b blocks)
        (set! (array-ref observation.offsets b) points)
        (set!
          points
          (+ points 1 (array-length (array-ref body.blocks b).instructions)))
        (set! b (+ b 1)))
      (set! (array-ref observation.offsets blocks) points)
      (set! b 0)
      (while (< b (* points loans))
        (set!
          (array-ref observation.live b)
          (ownership-loan-live? live (/ b loans) (% b loans)))
        (set! b (+ b 1)))
      true)))

;; Rows keep one state code per loan, read from the walk's planes.
(define (ownership-observe-row!
  [observation : (&mut observation OwnershipObservation)]
  [state : (& state (__tl_dyn-array i64))]
  [loans : i64]
  [block : i64]
  [instruction : i64]
  [phase : i64]
  [work : (&mut work i64)]
  [limit : i64]) : bool
  (if (not observation.enabled?)
    true
    (let
      [row : i64
        (* (+ (array-ref observation.offsets block) instruction) loans)]
      [i : i64 0]
      (unless (ownership-charge! work limit loans) (return false))
      (while (< i loans)
        (let
          [code : i64 (ownership-loan-code state i)]
          (cond
            [(= phase 0)
              (set!
                (array-ref observation.before-expiry (+ row i))
                (ownership-loan-state-join
                  (array-ref observation.before-expiry (+ row i))
                  code))]
            [(= phase 1)
              (set!
                (array-ref observation.before (+ row i))
                (ownership-loan-state-join
                  (array-ref observation.before (+ row i))
                  code))]
            [else
              (set!
                (array-ref observation.after (+ row i))
                (ownership-loan-state-join
                  (array-ref observation.after (+ row i))
                  code))])
          (set! i (+ i 1))))
      true)))

(define (ownership-result-ok? [result : (& result OwnershipResult)]) : bool
  (match result
    [(OwnershipResult.Ok) true]
    [(OwnershipResult.Err _) false]))

;; Continue only semantic failures in diagnostic mode. The checked result is
;; never discarded: the first failure is returned after fixed-point completion.
;; Diagnostic allocations are charged too; at most one just-created error can
;; cross the budget boundary before inspection stops.
(define (ownership-record-result!
  [result : OwnershipResult]
  [observation : (&mut observation OwnershipObservation)]
  [first : (&mut first OwnershipResult)]
  [work : (&mut work i64)]
  [limit : i64]) : OwnershipResult
  (match result
    [(OwnershipResult.Ok) OwnershipResult.Ok]
    [(OwnershipResult.Err error)
      ;; A semantic failure is recorded and the walk continues with the
      ;; conservative continuation, so the final states (and the `RequireEmpty`
      ;; sweep) are complete; only an inspection keeps per-point tables.
      (if (match error.kind
        [(OwnershipFailureKind.Loan) true]
        [(OwnershipFailureKind.Uninitialized) true]
        [(OwnershipFailureKind.Cleanup) true]
        [_ false])
        (begin
          (when
            observation.enabled?
            (unless
              (and
                (ownership-source-charge! work limit (& error.source))
                (ownership-charge!
                  work
                  limit
                  (string.string-length (& error.message))))
              (set! error.kind OwnershipFailureKind.Resource)
              (set!
                error.message
                "ownership observation diagnostics budget exhausted")
              (return (OwnershipResult.Err error)))
            (unless
              (and
                (ownership-index?
                  error.block
                  (- (array-length observation.offsets) 1))
                (>= error.instruction 0)
                (<
                  error.instruction
                  (-
                    (array-ref observation.offsets (+ error.block 1))
                    (array-ref observation.offsets error.block))))
              (set! error.kind OwnershipFailureKind.Structural)
              (set! error.message "invalid diagnostic observation point")
              (return (OwnershipResult.Err error)))
            (let
              [point : i64
                (+
                  (array-ref observation.offsets error.block)
                  error.instruction)]
              [kind : i64
                (match error.kind
                  [(OwnershipFailureKind.Uninitialized) 1]
                  [(OwnershipFailureKind.Loan) 2]
                  [(OwnershipFailureKind.Cleanup) 4]
                  [_ 0])]
              (set!
                (array-ref observation.failure-kinds point)
                (bit-or (array-ref observation.failure-kinds point) kind))))
          (let
            [empty? : bool (ownership-result-ok? (& (deref first)))]
            (when empty? (set! (deref first) (OwnershipResult.Err error))))
          OwnershipResult.Ok)
        (OwnershipResult.Err error))]))

;; Whether `error` comes before the recorded failure in `first` (block, then
;; instruction), or nothing is recorded.
(define (ownership-failure-earlier?
  [error : (& error OwnershipFailure)]
  [first : (& first OwnershipResult)]) : bool
  (match first
    [(OwnershipResult.Ok) true]
    [(OwnershipResult.Err prior)
      (or
        (< error.block prior.block)
        (and
          (= error.block prior.block)
          (< error.instruction prior.instruction)))]))

;; A `RequireEmpty` failure found by the sweep is reported in place of the
;; walk's first failure when it comes earlier.
(define (ownership-record-earlier!
  [found : OwnershipResult]
  [first : (&mut first OwnershipResult)]) : unit
  (match found
    [(OwnershipResult.Ok) unit]
    [(OwnershipResult.Err error)
      (when
        (ownership-failure-earlier? (& error) first)
        (set! (deref first) (OwnershipResult.Err error)))]))

(define (ownership-check-recording
  [body : (& body OwnershipBody)]
  [limits : OwnershipLimits]
  [observation : (&mut observation OwnershipObservation)]) : OwnershipResult
  (let
    [first-failure : OwnershipResult OwnershipResult.Ok]
    ;; The first loan conflict an Invalidate raises (`ownership-defer-loan!`).
    [deferred : OwnershipResult OwnershipResult.Ok]
    [walked : OwnershipResult
      (ownership-check-walk
        body
        limits
        observation
        (&mut first-failure)
        (&mut deferred))]
    (match first-failure
      [(OwnershipResult.Err error)
        (ownership-prefer-deferred body error (& deferred))]
      [(OwnershipResult.Ok)
        (match walked
          [(OwnershipResult.Err error) (OwnershipResult.Err error)]
          [(OwnershipResult.Ok) deferred])])))

(define (ownership-check-walk
  [body : (& body OwnershipBody)]
  [limits : OwnershipLimits]
  [observation : (&mut observation OwnershipObservation)]
  [first-failure : (&mut first-failure OwnershipResult)]
  [deferred : (&mut deferred OwnershipResult)]) : OwnershipResult
  (match (ownership-validate body limits)
    [(OwnershipResult.Err error) (OwnershipResult.Err error)]
    [(OwnershipResult.Ok)
      (let
        [blocks : i64 (array-length body.blocks)]
        [places : i64 (array-length body.places)]
        [words : i64 (ownership-state-words (array-length body.places))]
        [loans : i64 (array-length body.loans)]
        [work : i64 0]
        [place-index : OwnershipPlaceIndex
          (begin
            (unless
              (ownership-product-charge! (&mut work) limits.max-work places 6)
              (return
                (ownership-fail
                  OwnershipFailureKind.Resource
                  -1
                  -1
                  -1
                  (array-ref body.blocks body.entry.index).source
                  "ownership place index work exhausted")))
            (ownership-place-index body))]
        [liveness : OwnershipLoanLiveness
          (match (ownership-loan-liveness body limits)
            [(OwnershipLoanLivenessResult.Err error)
              (return (ownership-prefer-deferred body error deferred))]
            [(OwnershipLoanLivenessResult.Ok value) value])]
        [_prepared : unit
          (unless
            (ownership-observation-prepare!
              body
              (& liveness)
              observation
              limits
              (&mut work))
            (return
              (ownership-fail
                OwnershipFailureKind.Resource
                -1
                -1
                -1
                (array-ref body.blocks body.entry.index).source
                "ownership observation budget exhausted")))]
        [inputs : (__tl_dyn-array i64) (__tl_make-array i64 (* blocks words))]
        ;; Loan states are planes (`ownership-loan-code`): a block's input
        ;; row holds planes 0-2, and the walk's state adds the exclusive plane.
        [loan-words : i64 (ownership-loan-words loans)]
        [loan-row : i64 (* 3 (ownership-loan-words loans))]
        [loan-inputs : (__tl_dyn-array i64)
          (__tl_make-array i64 (* blocks (* 3 (ownership-loan-words loans))))]
        [loan-state : (__tl_dyn-array i64)
          (__tl_make-array i64 (* 4 (ownership-loan-words loans)))]
        [reached : (__tl_dyn-array bool) (__tl_make-array bool blocks)]
        [queued : (__tl_dyn-array bool) (__tl_make-array bool blocks)]
        [order : (__tl_dyn-array i64)
          (begin
            (unless
              (ownership-product-charge! (&mut work) limits.max-work blocks 4)
              (return
                (ownership-fail
                  OwnershipFailureKind.Resource
                  -1
                  -1
                  -1
                  (array-ref body.blocks body.entry.index).source
                  "ownership solver work exhausted")))
            (ownership-reverse-postorder body))]
        [state : (__tl_dyn-array i64) (__tl_make-array i64 words)]
        [pending : i64 1]
        [i : i64 0]
        (while (< i (* blocks words))
          (set! (array-ref inputs i) 0)
          (set! i (+ i 1)))
        (set! i 0)
        (while (< i blocks)
          (set! (array-ref reached i) false)
          (set! (array-ref queued i) false)
          (set! i (+ i 1)))
        (set! i 0)
        (while (< i places)
          (begin
            (ownership-state-put!
              (&mut inputs)
              (* body.entry.index words)
              i
              (if (array-ref body.locals (array-ref body.places i).local.index).parameter?
                2
                1))
            (set! i (+ i 1))))
        (set! (array-ref reached body.entry.index) true)
        (set! i 0)
        (while (< i loans)
          (ownership-loan-bit-set!
            (&mut loan-inputs)
            (* body.entry.index loan-row)
            i
            true)
          (when
            (ownership-loan-exclusive? (& (array-ref body.loans i)))
            (ownership-loan-bit-set! (&mut loan-state) (* 3 loan-words) i true))
          (set! i (+ i 1)))
        (set! (array-ref queued body.entry.index) true)
        ;; Blocks are visited in reverse postorder, sweep after sweep, each
        ;; when its input changed (`queued`): an acyclic body is solved in
        ;; one sweep (every predecessor first), a loop in a few. A FIFO
        ;; worklist revisited nested joins once per inner arm.
        (while (> pending 0)
          (let
            [step : i64 0]
            (while (< step (array-length order))
              (let
                [block-id : i64 (array-ref order step)]
                (set! step (+ step 1))
                (when
                  (array-ref queued block-id)
                  (let
                    [block : (& body OwnershipBlock)
                      (& (array-ref body.blocks block-id))]
                    [j : i64 0]
                    [successors : (Array i64 2) (array -1 -1)]
                    (set! pending (- pending 1))
                    (set! (array-ref queued block-id) false)
                    ;; Reserve the state copy and two possible successor joins
                    ;; before any block work, including empty cyclic blocks.
                    (when
                      (not
                        (and
                          (ownership-charge! (&mut work) limits.max-work 1)
                          (ownership-charge! (&mut work) limits.max-work words)
                          (ownership-product-charge!
                            (&mut work)
                            limits.max-work
                            loans
                            4)
                          (ownership-charge! (&mut work) limits.max-work words)
                          (ownership-charge! (&mut work) limits.max-work words)
                          (ownership-terminator-charge!
                            (&mut work)
                            limits.max-work
                            (& block.terminator))))
                      (return
                        (ownership-fail
                          OwnershipFailureKind.Resource
                          block-id
                          -1
                          -1
                          block.source
                          "ownership solver work exhausted")))
                    (set! i 0)
                    (while (< i words)
                      (set!
                        (array-ref state i)
                        (array-ref inputs (+ (* block-id words) i)))
                      (set! i (+ i 1)))
                    (set! i 0)
                    (while (< i loan-row)
                      (set!
                        (array-ref loan-state i)
                        (array-ref loan-inputs (+ (* block-id loan-row) i)))
                      (set! i (+ i 1)))
                    (while (< j (array-length block.instructions))
                      (unless
                        (ownership-charge! (&mut work) limits.max-work 1)
                        (return
                          (ownership-fail
                            OwnershipFailureKind.Resource
                            block-id
                            j
                            -1
                            (array-ref block.instructions j).source
                            "ownership solver work exhausted")))
                      (unless
                        (or
                          (not observation.enabled?)
                          (ownership-observe-row!
                            observation
                            (& loan-state)
                            loans
                            block-id
                            j
                            0
                            (&mut work)
                            limits.max-work))
                        (return
                          (ownership-fail
                            OwnershipFailureKind.Resource
                            block-id
                            j
                            -1
                            block.source
                            "ownership observation work exhausted")))
                      (when
                        (> loans 0)
                        (begin
                          ;; `ownership-loan-step-charge!`
                          (unless
                            (ownership-charge!
                              (&mut work)
                              limits.max-work
                              loans)
                            (return
                              (ownership-fail
                                OwnershipFailureKind.Resource
                                block-id
                                j
                                -1
                                (array-ref block.instructions j).source
                                "ownership loan solver work exhausted")))
                          (ownership-loan-expire-row!
                            (&mut loan-state)
                            (& liveness)
                            (+ (array-ref liveness.offsets block-id) j))
                          (unless
                            (or
                              (not observation.enabled?)
                              (ownership-observe-row!
                                observation
                                (& loan-state)
                                loans
                                block-id
                                j
                                1
                                (&mut work)
                                limits.max-work))
                            (return
                              (ownership-fail
                                OwnershipFailureKind.Resource
                                block-id
                                j
                                -1
                                block.source
                                "ownership observation work exhausted")))
                          ;; Deferring and recording an Ok result are no-ops,
                          ;; and so is the transfer of a MayUseLoan.
                          (unless
                            (ownership-may-use-loan?
                              (& (array-ref block.instructions j)))
                            (let
                              [loaned : OwnershipResult
                                (ownership-loan-step!
                                  body
                                  (&mut loan-state)
                                  (& liveness)
                                  (+ (array-ref liveness.offsets block-id) j 1)
                                  (& (array-ref block.instructions j))
                                  block-id
                                  j
                                  (&mut work)
                                  limits.max-work)]
                              (unless
                                (ownership-result-ok? (& loaned))
                                (match (ownership-record-result!
                                  ;; An Invalidate's conflict is deferred before
                                  ;; it could be recorded (`ownership-defer-loan!`).
                                  (ownership-defer-loan!
                                    loaned
                                    deferred
                                    first-failure
                                    (ownership-invalidate?
                                      (& (array-ref block.instructions j))))
                                  observation
                                  first-failure
                                  (&mut work)
                                  limits.max-work)
                                  [(OwnershipResult.Err error)
                                    (return
                                      (ownership-prefer-deferred
                                        body
                                        error
                                        deferred))]
                                  [(OwnershipResult.Ok) unit]))))))
                      ;; A `RequireEmpty` has no effect; it is checked once the
                      ;; states are final, so its report says what a place
                      ;; holds on every path rather than on the paths joined so
                      ;; far. A MayUseLoan neither reads nor writes a place.
                      (unless
                        (or
                          (ownership-may-use-loan?
                            (& (array-ref block.instructions j)))
                          (ownership-require-empty?
                            (& (array-ref block.instructions j))))
                        (let
                          [moved : OwnershipResult
                            (ownership-transfer-indexed!
                              body
                              (& place-index)
                              (&mut state)
                              (& (array-ref block.instructions j))
                              block-id
                              j
                              (&mut work)
                              limits.max-work)]
                          (unless
                            (ownership-result-ok? (& moved))
                            (match (ownership-record-result!
                              moved
                              observation
                              first-failure
                              (&mut work)
                              limits.max-work)
                              [(OwnershipResult.Err error)
                                (return
                                  (ownership-prefer-deferred
                                    body
                                    error
                                    deferred))]
                              [(OwnershipResult.Ok) unit]))))
                      (unless
                        (or
                          (not observation.enabled?)
                          (ownership-observe-row!
                            observation
                            (& loan-state)
                            loans
                            block-id
                            j
                            2
                            (&mut work)
                            limits.max-work))
                        (return
                          (ownership-fail
                            OwnershipFailureKind.Resource
                            block-id
                            j
                            -1
                            block.source
                            "ownership observation work exhausted")))
                      (set! j (+ j 1)))
                    (unless
                      (or
                        (not observation.enabled?)
                        (ownership-observe-row!
                          observation
                          (& loan-state)
                          loans
                          block-id
                          j
                          0
                          (&mut work)
                          limits.max-work))
                      (return
                        (ownership-fail
                          OwnershipFailureKind.Resource
                          block-id
                          j
                          -1
                          block.source
                          "ownership observation work exhausted")))
                    (when
                      (> loans 0)
                      (ownership-loan-expire-row!
                        (&mut loan-state)
                        (& liveness)
                        (+ (array-ref liveness.offsets block-id) j)))
                    (unless
                      (or
                        (not observation.enabled?)
                        (ownership-observe-row!
                          observation
                          (& loan-state)
                          loans
                          block-id
                          j
                          1
                          (&mut work)
                          limits.max-work))
                      (return
                        (ownership-fail
                          OwnershipFailureKind.Resource
                          block-id
                          j
                          -1
                          block.source
                          "ownership observation work exhausted")))
                    (match (& block.terminator)
                      [(OwnershipTerminator.Goto target)
                        (set! (array-ref successors 0) target.index)]
                      [(OwnershipTerminator.Branch condition yes no)
                        (when
                          (not
                            (ownership-loan-step-charge!
                              (&mut work)
                              limits.max-work
                              places
                              loans))
                          (return
                            (ownership-fail
                              OwnershipFailureKind.Resource
                              block-id
                              j
                              -1
                              block.source
                              "ownership loan terminator work exhausted")))
                        (match (ownership-record-result!
                          (ownership-loan-access
                            body
                            (& loan-state)
                            condition.index
                            -1
                            false
                            block-id
                            j
                            (& block.source)
                            (&mut work)
                            limits.max-work)
                          observation
                          first-failure
                          (&mut work)
                          limits.max-work)
                          [(OwnershipResult.Err error)
                            (return
                              (ownership-prefer-deferred body error deferred))]
                          [(OwnershipResult.Ok) unit])
                        (match (ownership-record-result!
                          (ownership-read
                            (& state)
                            (& condition)
                            block-id
                            j
                            (& block.source))
                          observation
                          first-failure
                          (&mut work)
                          limits.max-work)
                          [(OwnershipResult.Err error)
                            (return
                              (ownership-prefer-deferred body error deferred))]
                          [(OwnershipResult.Ok) unit])
                        (set! (array-ref successors 0) yes.index)
                        (set! (array-ref successors 1) no.index)]
                      [(OwnershipTerminator.Return operands)
                        (let
                          [k : i64 0]
                          (while (< k (array-length operands.items))
                            (begin
                              (when
                                (not
                                  (ownership-loan-step-charge!
                                    (&mut work)
                                    limits.max-work
                                    places
                                    loans))
                                (return
                                  (ownership-fail
                                    OwnershipFailureKind.Resource
                                    block-id
                                    j
                                    -1
                                    block.source
                                    "ownership loan terminator work exhausted")))
                              (match (ownership-record-result!
                                (ownership-loan-access
                                  body
                                  (& loan-state)
                                  (array-ref operands.items k).index
                                  -1
                                  false
                                  block-id
                                  j
                                  (& block.source)
                                  (&mut work)
                                  limits.max-work)
                                observation
                                first-failure
                                (&mut work)
                                limits.max-work)
                                [(OwnershipResult.Err error)
                                  (return
                                    (ownership-prefer-deferred
                                      body
                                      error
                                      deferred))]
                                [(OwnershipResult.Ok) unit])
                              (match (ownership-record-result!
                                (ownership-read
                                  (& state)
                                  (& (array-ref operands.items k))
                                  block-id
                                  j
                                  (& block.source))
                                observation
                                first-failure
                                (&mut work)
                                limits.max-work)
                                [(OwnershipResult.Err error)
                                  (return
                                    (ownership-prefer-deferred
                                      body
                                      error
                                      deferred))]
                                [(OwnershipResult.Ok) unit])
                              (set! k (+ k 1)))))]
                      [(OwnershipTerminator.ReturnOwned _)
                        (return
                          (ownership-unelaborated block-id j (& block.source)))]
                      [(OwnershipTerminator.Abort) unit]
                      [(OwnershipTerminator.Unsupported reason)
                        (return
                          (ownership-fail
                            OwnershipFailureKind.Unsupported
                            block-id
                            j
                            -1
                            block.source
                            (string.copy reason)))])
                    (unless
                      (or
                        (not observation.enabled?)
                        (ownership-observe-row!
                          observation
                          (& loan-state)
                          loans
                          block-id
                          j
                          2
                          (&mut work)
                          limits.max-work))
                      (return
                        (ownership-fail
                          OwnershipFailureKind.Resource
                          block-id
                          j
                          -1
                          block.source
                          "ownership observation work exhausted")))
                    (set! j 0)
                    (while (< j 2)
                      (let
                        [target : i64 (array-ref successors j)]
                        (when
                          (>= target 0)
                          (let
                            [changed? : bool (not (array-ref reached target))]
                            (set! i 0)
                            (while (< i words)
                              (let
                                [cell : i64 (+ (* target words) i)]
                                [prior : i64 (array-ref inputs cell)]
                                [joined : i64
                                  (ownership-state-join
                                    prior
                                    (array-ref state i))]
                                (when
                                  (not (= joined prior))
                                  (set! (array-ref inputs cell) joined)
                                  (set! changed? true))
                                (set! i (+ i 1))))
                            (set! i 0)
                            (while (< i loan-row)
                              (let
                                [cell : i64 (+ (* target loan-row) i)]
                                [prior : i64 (array-ref loan-inputs cell)]
                                [joined : i64
                                  (ownership-loan-state-join
                                    prior
                                    (array-ref loan-state i))]
                                (when
                                  (!= prior joined)
                                  (set! (array-ref loan-inputs cell) joined)
                                  (set! changed? true))
                                (set! i (+ i 1))))
                            (set! (array-ref reached target) true)
                            (when
                              (and changed? (not (array-ref queued target)))
                              (set! pending (+ pending 1))
                              (set! (array-ref queued target) true))))
                        (set! j (+ j 1))))))))))
        (match (ownership-require-empty-sweep!
          body
          (& place-index)
          (& inputs)
          (& reached)
          (&mut state)
          observation
          first-failure
          (&mut work)
          limits.max-work)
          [(OwnershipResult.Err error)
            (return (ownership-prefer-deferred body error deferred))]
          [(OwnershipResult.Ok) unit])
        (set! observation.complete? true)
        OwnershipResult.Ok)]))

;; A loan conflict an Invalidate raises waits for the walk to finish: an
;; uninitialized use anywhere in the body is reported first. Invalidating an arena's values also ends the references into them,
;; so a later use of such a reference is the use of a moved value, as the
;; legacy move checker (which ran before the borrow checker) reported it.
(define (ownership-defer-loan!
  [result : OwnershipResult]
  [deferred : (&mut deferred OwnershipResult)]
  [first : (& first OwnershipResult)]
  [invalidate? : bool]) : OwnershipResult
  (match result
    [(OwnershipResult.Err error)
      (match error.kind
        [(OwnershipFailureKind.Loan)
          (if (not invalidate?)
            (OwnershipResult.Err error)
            (begin
              ;; Only a conflict before the walk's first failure is deferred:
              ;; the walk continues past a failure only to finish the states.
              (when
                (and
                  (ownership-result-ok? (& (deref deferred)))
                  (ownership-result-ok? first))
                (set! (deref deferred) (OwnershipResult.Err error)))
              OwnershipResult.Ok))]
        [_ (OwnershipResult.Err error)])]
    [(OwnershipResult.Ok) OwnershipResult.Ok]))

;; An uninitialized use of a reference holding the deferred conflict's loan
;; supersedes it (the use is preceded by its MayUseLoan of that loan); any
;; other failure is reported after the earlier conflict.
(define (ownership-prefer-deferred
  [body : (& body OwnershipBody)]
  [error : OwnershipFailure]
  [deferred : (& deferred OwnershipResult)]) : OwnershipResult
  (match deferred
    [(OwnershipResult.Err first)
      (if (and
        (match error.kind
          [(OwnershipFailureKind.Uninitialized) true]
          [_ false])
        (ownership-demands-loan-before?
          body
          error.block
          error.instruction
          first.loan
          first.conflicting-loan))
        (OwnershipResult.Err error)
        (OwnershipResult.Err
          ;; Only loan conflicts are deferred.
          (OwnershipFailure
            OwnershipFailureKind.Loan
            first.block
            first.instruction
            first.place
            first.loan
            first.conflicting-loan
            (ownership-source-copy (& first.source))
            (string.copy (& first.message)))))]
    [(OwnershipResult.Ok) (OwnershipResult.Err error)]))

;; Whether the loan uses immediately before (block, instruction) include
;; `loan` or `other`.
(define (ownership-demands-loan-before?
  [body : (& body OwnershipBody)]
  [block : i64]
  [instruction : i64]
  [loan : i64]
  [other : i64]) : bool
  (if (not (ownership-index? block (array-length body.blocks)))
    false
    (let
      [instructions : (& body (__tl_dyn-array OwnershipInstruction))
        (& (array-ref body.blocks block).instructions)]
      [index : i64
        (if (> instruction (array-length instructions))
          (array-length instructions)
          instruction)]
      [found : bool false]
      [scanning : bool true]
      (while (and scanning (not found) (> index 0))
        (set! index (- index 1))
        (match (& (array-ref instructions index).operation)
          [(OwnershipOperation.MayUseLoan used _)
            (when
              (or (= used.index loan) (= used.index other))
              (set! found true))]
          [(OwnershipOperation.UseLoan used)
            (when
              (or (= used.index loan) (= used.index other))
              (set! found true))]
          [_ (set! scanning false)]))
      found)))

(define (ownership-invalidate? [instr : (& instr OwnershipInstruction)]) : bool
  (match (& instr.operation)
    [(OwnershipOperation.Invalidate _) true]
    [_ false]))

(define (ownership-may-use-loan? [instr : (& instr OwnershipInstruction)]) : bool
  (match (& instr.operation)
    [(OwnershipOperation.MayUseLoan _ _) true]
    [_ false]))

(define (ownership-require-empty? [instr : (& instr OwnershipInstruction)]) : bool
  (match (& instr.operation)
    [(OwnershipOperation.RequireEmpty _) true]
    [_ false]))

;; Check every `RequireEmpty` against the solved states: each reached block is
;; replayed from its final entry state.
;; Whether a block holds a `RequireEmpty` check.
(define (ownership-block-requires-empty? [block : (& block OwnershipBlock)]) : bool
  (let
    [j : i64 0]
    [found : bool false]
    (while (and (not found) (< j (array-length block.instructions)))
      (when
        (ownership-require-empty? (& (array-ref block.instructions j)))
        (set! found true))
      (set! j (+ j 1)))
    found))

(define (ownership-require-empty-sweep!
  [body : (& body OwnershipBody)]
  [places : (& places OwnershipPlaceIndex)]
  [inputs : (& inputs (__tl_dyn-array i64))]
  [reached : (& reached (__tl_dyn-array bool))]
  [state : (&mut state (__tl_dyn-array i64))]
  [observation : (&mut observation OwnershipObservation)]
  [first : (&mut first OwnershipResult)]
  [work : (&mut work i64)]
  [limit : i64]) : OwnershipResult
  (let
    [count : i64 (ownership-state-words (array-length body.places))]
    [block-id : i64 0]
    (while (< block-id (array-length body.blocks))
      ;; Only a block with a `RequireEmpty` has a check to replay: every
      ;; block starts again from its final input row.
      (when
        (and
          (array-ref reached block-id)
          (ownership-block-requires-empty? (& (array-ref body.blocks block-id))))
        (let
          [block : (& body OwnershipBlock) (& (array-ref body.blocks block-id))]
          [i : i64 0]
          [j : i64 0]
          (unless
            (ownership-charge! work limit count)
            (return
              (ownership-fail
                OwnershipFailureKind.Resource
                block-id
                -1
                -1
                block.source
                "ownership solver work exhausted")))
          (while (< i count)
            (set!
              (array-ref state i)
              (array-ref inputs (+ (* block-id count) i)))
            (set! i (+ i 1)))
          (while (< j (array-length block.instructions))
            (let
              [instr : (& body OwnershipInstruction)
                (& (array-ref block.instructions j))]
              (unless
                (ownership-charge! work limit 1)
                (return
                  (ownership-fail
                    OwnershipFailureKind.Resource
                    block-id
                    j
                    -1
                    instr.source
                    "ownership solver work exhausted")))
              (match (if (ownership-require-empty? instr)
                (let
                  [found : OwnershipResult OwnershipResult.Ok]
                  (match (ownership-record-result!
                    (ownership-initialization-check body state instr block-id j)
                    observation
                    (&mut found)
                    work
                    limit)
                    [(OwnershipResult.Err error) (OwnershipResult.Err error)]
                    [(OwnershipResult.Ok)
                      (ownership-record-earlier! found first)
                      OwnershipResult.Ok]))
                (ownership-initialization-effects!
                  body
                  places
                  state
                  instr
                  block-id
                  j
                  work
                  limit))
                [(OwnershipResult.Err error)
                  (return (OwnershipResult.Err error))]
                [(OwnershipResult.Ok) unit])
              (set! j (+ j 1))))))
      (set! block-id (+ block-id 1)))
    OwnershipResult.Ok))

(define (ownership-check
  [body : (& body OwnershipBody)]
  [limits : OwnershipLimits]) : OwnershipResult
  (if (and
    (= (array-length body.cleanups) 0)
    (= (array-length body.obligations) 0))
    (let
      [observation : OwnershipObservation (ownership-observation-new false)]
      (ownership-check-recording body limits (&mut observation)))
    (match (ownership-cleanup-expand body limits)
      [(OwnershipCleanupExpansionResult.Err error) (OwnershipResult.Err error)]
      [(OwnershipCleanupExpansionResult.Ok expanded)
        (let
          [observation : OwnershipObservation (ownership-observation-new false)]
          (ownership-cleanup-remap-result
            body
            (& expanded.origins)
            (ownership-check-recording
              (& expanded.body)
              expanded.remaining
              (&mut observation))))])))

(define (ownership-inspect
  [body : (& body OwnershipBody)]
  [limits : OwnershipLimits]) : OwnershipInspection
  (if (and
    (= (array-length body.cleanups) 0)
    (= (array-length body.obligations) 0))
    (let
      [observation : OwnershipObservation (ownership-observation-new true)]
      [result : OwnershipResult
        (ownership-check-recording body limits (&mut observation))]
      (OwnershipInspection result observation))
    (let
      [checked : OwnershipCleanupChecked
        (ownership-cleanup-checked body limits)]
      checked.inspection)))

;; Cleanup elaboration preserves the canonical place/loan graph and lowers only
;; checked scope operations. Sources on generated instructions retain their
;; original point; actions are a static schedule, never a worklist-visit log.
(defstruct OwnershipCleanupAction
  (block i64)
  (instruction i64)
  (place OwnershipPlaceId)
  (cleanup OwnershipCleanupId))

(defstruct OwnershipCleanupInspection
  (result OwnershipResult)
  (complete? bool)
  (actions (__tl_dyn-array OwnershipCleanupAction))
  (offsets (__tl_dyn-array i64))
  (failure-kinds (__tl_dyn-array i64)))

(defstruct OwnershipScopePlan
  (offsets (__tl_dyn-array i64))
  (tops (__tl_dyn-array i64))
  (errors (__tl_dyn-array i64))
  ;; 0 absent, 1 under construction, 2 lexically bound.
  (phases (__tl_dyn-array i64)))

(defenum OwnershipScopePlanResult
  (Ok OwnershipScopePlan)
  (Err OwnershipFailure))

(define (ownership-cleanup-metadata
  [body : (& body OwnershipBody)]
  [limits : OwnershipLimits]
  [work : (&mut work i64)]
  [cells : (&mut cells i64)]) : OwnershipResult
  (let
    [count : i64 (array-length body.cleanups)]
    [owners : i64 (array-length body.obligations)]
    [fallback : OwnershipSource (OwnershipSource "<ownership-cleanup>" 1 1 "")]
    [i : i64 0]
    [canonical : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    [present : (__tl_dyn-array bool) (__tl_make-array bool 0)]
    (when (and (= count 0) (= owners 0)) (return OwnershipResult.Ok))
    (unless
      (and
        (ownership-charge!
          cells
          limits.max-state-cells
          (array-length body.types))
        (ownership-charge!
          cells
          limits.max-state-cells
          (array-length body.places))
        (ownership-charge! cells limits.max-state-cells owners)
        (ownership-charge! work limits.max-work (array-length body.types))
        (ownership-charge! work limits.max-work (array-length body.places)))
      (return
        (ownership-fail
          OwnershipFailureKind.Resource
          -1
          -1
          -1
          fallback
          "ownership cleanup metadata state budget exhausted")))
    (set! canonical (__tl_make-array i64 (array-length body.types)))
    (set! present (__tl_make-array bool (array-length body.places)))
    (while (< i (array-length canonical))
      (set! (array-ref canonical i) -1)
      (set! i (+ i 1)))
    (set! i 0)
    (when
      (or (> count limits.max-nodes) (> owners limits.max-nodes))
      (return
        (ownership-fail
          OwnershipFailureKind.Resource
          -1
          -1
          -1
          fallback
          "ownership cleanup metadata exceeds limits")))
    ;; Validate every identity before following any contract reference.
    (while (< i count)
      (let
        [cleanup : (& body OwnershipCleanup) (& (array-ref body.cleanups i))]
        (unless
          (ownership-source-charge! work limits.max-work (& cleanup.source))
          (return
            (ownership-fail
              OwnershipFailureKind.Resource
              -1
              -1
              -1
              fallback
              "ownership cleanup validation work exhausted")))
        (unless
          (and
            (ownership-type-id? body (& cleanup.type))
            (ownership-source-valid? (& cleanup.source)))
          (return
            (ownership-fail
              OwnershipFailureKind.Structural
              -1
              -1
              -1
              cleanup.source
              "invalid cleanup type or source")))
        (when
          cleanup.type-owned?
          (when
            (or
              (array-ref body.types cleanup.type.index).copy?
              (>= (array-ref canonical cleanup.type.index) 0))
            (return
              (ownership-fail
                OwnershipFailureKind.Structural
                -1
                -1
                -1
                cleanup.source
                "type-owned cleanup requires one canonical MoveOnly contract")))
          (set! (array-ref canonical cleanup.type.index) i))
        (set! i (+ i 1))))
    (set! i 0)
    (while (< i (array-length body.types))
      (begin
        (match (& (array-ref body.types i).kind)
          [(OwnershipTypeKind.Product fields)
            (let
              [j : i64 0]
              (while (< j (array-length fields.items))
                (unless
                  (ownership-charge! work limits.max-work 1)
                  (return
                    (ownership-fail
                      OwnershipFailureKind.Resource
                      -1
                      -1
                      -1
                      fallback
                      "ownership aggregate contract work exhausted")))
                (when
                  (and
                    (>=
                      (array-ref canonical (array-ref fields.items j).index)
                      0)
                    (< (array-ref canonical i) 0))
                  (return
                    (ownership-fail
                      OwnershipFailureKind.Structural
                      -1
                      -1
                      -1
                      fallback
                      "ordinary aggregate cannot contain a type-owned field")))
                (set! j (+ j 1))))]
          [_ unit])
        (set! i (+ i 1))))
    (set! i 0)
    (while (< i count)
      (let
        [cleanup : (& body OwnershipCleanup) (& (array-ref body.cleanups i))]
        (match (& cleanup.kind)
          [(OwnershipCleanupKind.Intrinsic)
            (match (& (array-ref body.types cleanup.type.index).kind)
              [(OwnershipTypeKind.Product _)
                (return
                  (ownership-fail
                    OwnershipFailureKind.Unsupported
                    -1
                    -1
                    -1
                    cleanup.source
                    "intrinsic cleanup currently supports scalar resources only"))]
              [_ unit])]
          [(OwnershipCleanupKind.Product fields)
            (match (& (array-ref body.types cleanup.type.index).kind)
              [(OwnershipTypeKind.Product types)
                (let
                  [j : i64 0]
                  [last : i64 -1]
                  (when
                    (> (array-length fields.items) limits.max-nodes)
                    (return
                      (ownership-fail
                        OwnershipFailureKind.Resource
                        -1
                        -1
                        -1
                        cleanup.source
                        "ownership cleanup field budget exhausted")))
                  (while (< j (array-length fields.items))
                    (let
                      [field : (& fields OwnershipCleanupField)
                        (& (array-ref fields.items j))]
                      (unless
                        (ownership-charge! work limits.max-work 1)
                        (return
                          (ownership-fail
                            OwnershipFailureKind.Resource
                            -1
                            -1
                            -1
                            cleanup.source
                            "ownership cleanup validation work exhausted")))
                      (unless
                        (and
                          (> field.ordinal last)
                          (ownership-index?
                            field.ordinal
                            (array-length types.items))
                          (ownership-cleanup-id? body (& field.cleanup))
                          (=
                            (array-ref body.cleanups field.cleanup.index).type.index
                            (array-ref types.items field.ordinal).index))
                        (return
                          (ownership-fail
                            OwnershipFailureKind.Structural
                            -1
                            -1
                            -1
                            cleanup.source
                            "invalid cleanup field contract or declaration order")))
                      (set! last field.ordinal)
                      (set! j (+ j 1))))
                  (set! j 0)
                  (let
                    [k : i64 0]
                    (while (< j (array-length types.items))
                      (unless
                        (ownership-charge! work limits.max-work 1)
                        (return
                          (ownership-fail
                            OwnershipFailureKind.Resource
                            -1
                            -1
                            -1
                            cleanup.source
                            "ownership cleanup completeness work exhausted")))
                      (let
                        [required : i64
                          (array-ref canonical (array-ref types.items j).index)]
                        [actual : i64
                          (if (and
                            (< k (array-length fields.items))
                            (= (array-ref fields.items k).ordinal j))
                            (array-ref fields.items k).cleanup.index
                            -1)]
                        (when
                          (and (>= required 0) (!= actual required))
                          (return
                            (ownership-fail
                              OwnershipFailureKind.Structural
                              -1
                              -1
                              -1
                              cleanup.source
                              "product omits or substitutes an owned field cleanup")))
                        (when (>= actual 0) (set! k (+ k 1))))
                      (set! j (+ j 1)))))]
              [_
                (return
                  (ownership-fail
                    OwnershipFailureKind.Structural
                    -1
                    -1
                    -1
                    cleanup.source
                    "product cleanup requires a product type"))])])
        (set! i (+ i 1))))
    (set! i 0)
    (while (< i owners)
      (let
        [owner : (& body OwnershipObligation)
          (& (array-ref body.obligations i))]
        (unless
          (ownership-source-charge! work limits.max-work (& owner.source))
          (return
            (ownership-fail
              OwnershipFailureKind.Resource
              -1
              -1
              -1
              fallback
              "ownership obligation validation work exhausted")))
        (unless
          (and
            (ownership-place-id? body (& owner.place))
            (ownership-cleanup-id? body (& owner.cleanup))
            (ownership-source-valid? (& owner.source))
            (ownership-root? (& (array-ref body.places owner.place.index)))
            (not
              (array-ref
                body.locals
                (array-ref body.places owner.place.index).local.index).parameter?)
            (=
              (array-ref body.cleanups owner.cleanup.index).type.index
              (array-ref body.places owner.place.index).type.index)
            (match (& owner.parent)
              [(OwnershipObligationParent.Root) true]
              [(OwnershipObligationParent.Parent parent)
                (and
                  (ownership-obligation-id? body (& parent))
                  (!= parent.index i))]))
          (return
            (ownership-fail
              OwnershipFailureKind.Structural
              -1
              -1
              i
              owner.source
              "invalid obligation identity, root, or contract")))
        (when
          (and
            (>=
              (array-ref
                canonical
                (array-ref body.places owner.place.index).type.index)
              0)
            (!=
              (array-ref
                canonical
                (array-ref body.places owner.place.index).type.index)
              owner.cleanup.index))
          (return
            (ownership-fail
              OwnershipFailureKind.Structural
              -1
              -1
              owner.place.index
              owner.source
              "obligation substitutes the type's declared cleanup contract")))
        (set! (array-ref present owner.place.index) true)
        ;; Copy values may have explicit With cleanup. This standalone
        ;; type-owned slice has not yet represented that separate contract.
        (when
          (array-ref
            body.types
            (array-ref body.places owner.place.index).type.index).copy?
          (return
            (ownership-fail
              OwnershipFailureKind.Unsupported
              -1
              -1
              owner.place.index
              owner.source
              "explicit cleanup on Copy bindings requires a separate contract")))
        (when
          (> (array-length owner.retained) limits.max-nodes)
          (return
            (ownership-fail
              OwnershipFailureKind.Resource
              -1
              -1
              i
              owner.source
              "ownership retained operand budget exhausted")))
        (let
          [j : i64 0]
          (while (< j (array-length owner.retained))
            (unless
              (ownership-charge! work limits.max-work 1)
              (return
                (ownership-fail
                  OwnershipFailureKind.Resource
                  -1
                  -1
                  i
                  owner.source
                  "ownership retained operand work exhausted")))
            (unless
              (match (& (array-ref owner.retained j))
                [(OwnershipCleanupUse.Read place)
                  (ownership-place-id? body (& place))]
                [(OwnershipCleanupUse.Through loan place)
                  (and
                    (ownership-loan-id? body (& loan))
                    (ownership-place-id? body (& place))
                    (let
                      [contained : i64
                        (ownership-descendant-charged
                          body
                          place.index
                          (array-ref body.loans loan.index).place.index
                          work
                          limits.max-work)]
                      (when
                        (< contained 0)
                        (return
                          (ownership-fail
                            OwnershipFailureKind.Resource
                            -1
                            -1
                            i
                            owner.source
                            "ownership retained operand ancestry work exhausted")))
                      (= contained 1)))])
              (return
                (ownership-fail
                  OwnershipFailureKind.Structural
                  -1
                  -1
                  i
                  owner.source
                  "invalid retained cleanup operand")))
            (set! j (+ j 1))))
        (set! i (+ i 1))))
    (set! i 0)
    (while (< i (array-length body.places))
      (unless
        (ownership-charge! work limits.max-work 1)
        (return
          (ownership-fail
            OwnershipFailureKind.Resource
            -1
            -1
            i
            fallback
            "ownership root contract work exhausted")))
      (when
        (and
          (ownership-root? (& (array-ref body.places i)))
          (>= (array-ref canonical (array-ref body.places i).type.index) 0))
        (when
          (array-ref body.locals (array-ref body.places i).local.index).parameter?
          (return
            (ownership-fail
              OwnershipFailureKind.Unsupported
              -1
              -1
              i
              (array-ref body.places i).source
              "type-owned parameter obligations are not represented")))
        (unless
          (array-ref present i)
          (return
            (ownership-fail
              OwnershipFailureKind.Structural
              -1
              -1
              i
              (array-ref body.places i).source
              "type-owned root has no declared cleanup obligation"))))
      (set! i (+ i 1)))
    ;; Parent identities are arbitrary table indices. Cycle detection uses a
    ;; bounded color walk rather than assigning lexical meaning to ID order.
    (unless
      (and
        (ownership-charge! work limits.max-work owners)
        (<= owners limits.max-state-cells))
      (return
        (ownership-fail
          OwnershipFailureKind.Resource
          -1
          -1
          -1
          fallback
          "ownership scope parent budget exhausted")))
    (let
      [colors : (__tl_dyn-array i64) (__tl_make-array i64 owners)]
      (set! i 0)
      (while (< i owners)
        (let
          [cursor : i64 i]
          (while (and (>= cursor 0) (= (array-ref colors cursor) 0))
            (unless
              (ownership-charge! work limits.max-work 1)
              (return
                (ownership-fail
                  OwnershipFailureKind.Resource
                  -1
                  -1
                  i
                  fallback
                  "ownership scope parent work exhausted")))
            (set! (array-ref colors cursor) 1)
            (set!
              cursor
              (ownership-obligation-parent
                (& (array-ref body.obligations cursor)))))
          (when
            (and (>= cursor 0) (= (array-ref colors cursor) 1))
            (return
              (ownership-fail
                OwnershipFailureKind.Structural
                -1
                -1
                i
                (array-ref body.obligations i).source
                "cyclic obligation parents")))
          (set! cursor i)
          (while (and (>= cursor 0) (= (array-ref colors cursor) 1))
            (unless
              (ownership-charge! work limits.max-work 1)
              (return
                (ownership-fail
                  OwnershipFailureKind.Resource
                  -1
                  -1
                  i
                  fallback
                  "ownership scope parent work exhausted")))
            (set! (array-ref colors cursor) 2)
            (set!
              cursor
              (ownership-obligation-parent
                (& (array-ref body.obligations cursor)))))
          (set! i (+ i 1)))))
    OwnershipResult.Ok))

(define (ownership-source-copy [source : (& source OwnershipSource)]) : OwnershipSource
  (OwnershipSource
    (ownership-text-copy (& source.path))
    source.line
    source.column
    (ownership-text-copy (& source.expansion))))

;; An owned copy of provenance text. Most expansion traces are empty, and an
;; empty copy needs no allocation.
(define (ownership-text-copy [text : (& text str)]) : String
  (if (= (string.string-length text) 0)
    ""
    (string.copy text)))

(defmacro (ownership-scope-fail
  [kind : Expr]
  [block : Expr]
  [instruction : Expr]
  [source : Expr]
  [message : Expr]) : Expr
  `(OwnershipScopePlanResult.Err
    (OwnershipFailure
      ,kind
      ,block
      ,instruction
      -1
      -1
      -1
      (ownership-source-copy (& ,source))
      ,message)))

;; Structural scope flow has an exact state. A join cannot merge two different
;; lexical stacks and later invent a conditional destructor. Each block is
;; visited once; a subsequent incoming edge must match its complete input.
(define (ownership-scope-plan
  [body : (& body OwnershipBody)]
  [limits : OwnershipLimits]
  [work : (&mut work i64)]
  [cells : (&mut cells i64)]) : OwnershipScopePlanResult
  (let
    [blocks : i64 (array-length body.blocks)]
    [owners : i64 (array-length body.obligations)]
    [points : i64 0]
    [b : i64 0]
    (while (< b blocks)
      (unless
        (and
          (ownership-charge! work limits.max-work 1)
          (ownership-charge!
            (&mut points)
            limits.max-nodes
            (+ (array-length (array-ref body.blocks b).instructions) 1)))
        (return
          (ownership-scope-fail
            OwnershipFailureKind.Resource
            b
            -1
            (array-ref body.blocks b).source
            "ownership scope point budget exhausted")))
      (set! b (+ b 1)))
    (unless
      (and
        (ownership-product-charge! cells limits.max-state-cells points owners)
        (ownership-product-charge! cells limits.max-state-cells blocks owners)
        (ownership-product-charge! cells limits.max-state-cells blocks 5)
        (ownership-charge!
          cells
          limits.max-state-cells
          (+ (* points 2) owners 1))
        (ownership-product-charge! work limits.max-work points owners)
        (ownership-product-charge! work limits.max-work blocks owners)
        (ownership-charge!
          work
          limits.max-work
          (+ (* blocks 5) (* points 2) owners 1)))
      (return
        (ownership-scope-fail
          OwnershipFailureKind.Resource
          -1
          -1
          (array-ref body.blocks body.entry.index).source
          "ownership scope state budget exhausted")))
    (let
      [offsets : (__tl_dyn-array i64) (__tl_make-array i64 (+ blocks 1))]
      [tops : (__tl_dyn-array i64) (__tl_make-array i64 points)]
      [errors : (__tl_dyn-array i64) (__tl_make-array i64 points)]
      [phases : (__tl_dyn-array i64) (__tl_make-array i64 (* points owners))]
      [inputs : (__tl_dyn-array i64) (__tl_make-array i64 (* blocks owners))]
      [input-tops : (__tl_dyn-array i64) (__tl_make-array i64 blocks)]
      [reached : (__tl_dyn-array bool) (__tl_make-array bool blocks)]
      [queue : (__tl_dyn-array i64) (__tl_make-array i64 blocks)]
      [state : (__tl_dyn-array i64) (__tl_make-array i64 owners)]
      [head : i64 0]
      [tail : i64 1]
      [top : i64 -1]
      [position : i64 0]
      (set! b 0)
      (while (< b blocks)
        (set! (array-ref offsets b) position)
        (set!
          position
          (+ position (array-length (array-ref body.blocks b).instructions) 1))
        (set! (array-ref input-tops b) -1)
        (set! b (+ b 1)))
      (set! (array-ref offsets blocks) position)
      (set! position 0)
      (while (< position points)
        (set! (array-ref tops position) -2)
        (set! position (+ position 1)))
      (set! (array-ref queue 0) body.entry.index)
      (set! (array-ref reached body.entry.index) true)
      (while (< head tail)
        (let
          [block : i64 (array-ref queue head)]
          [instructions : (& body (__tl_dyn-array OwnershipInstruction))
            (& (array-ref body.blocks block).instructions)]
          [i : i64 0]
          [j : i64 0]
          (set! head (+ head 1))
          (set! top (array-ref input-tops block))
          (unless
            (ownership-charge! work limits.max-work owners)
            (return
              (ownership-scope-fail
                OwnershipFailureKind.Resource
                block
                -1
                (array-ref body.blocks block).source
                "ownership scope traversal work exhausted")))
          (while (< i owners)
            (set! (array-ref state i) (array-ref inputs (+ (* block owners) i)))
            (set! i (+ i 1)))
          (while (<= j (array-length instructions))
            (unless
              (ownership-charge! work limits.max-work (+ owners 1))
              (return
                (ownership-scope-fail
                  OwnershipFailureKind.Resource
                  block
                  j
                  (array-ref body.blocks block).source
                  "ownership scope traversal work exhausted")))
            (set! position (+ (array-ref offsets block) j))
            (set! (array-ref tops position) top)
            (set! i 0)
            (while (< i owners)
              (set!
                (array-ref phases (+ (* position owners) i))
                (array-ref state i))
              (set! i (+ i 1)))
            (when
              (< j (array-length instructions))
              (let
                [instr : (& instructions OwnershipInstruction)
                  (& (array-ref instructions j))]
                [owner : i64 -1]
                [action : i64 0]
                (match (& instr.operation)
                  [(OwnershipOperation.BeginConstruction id)
                    (set! owner id.index)
                    (set! action 1)]
                  [(OwnershipOperation.BindFresh id)
                    (set! owner id.index)
                    (set! action 2)]
                  [(OwnershipOperation.BindMove _ id)
                    (set! owner id.index)
                    (set! action 2)]
                  [(OwnershipOperation.BindComplete id)
                    (set! owner id.index)
                    (set! action 3)]
                  [(OwnershipOperation.Leave id)
                    (set! owner id.index)
                    (set! action 4)]
                  [(OwnershipOperation.Cleanup id _)
                    (set! owner id.index)
                    (set! action 5)]
                  [_ unit])
                (when
                  (> action 0)
                  (let
                    [problem : i64
                      (cond
                        [(<= action 2)
                          (cond
                            [(!= (array-ref state owner) 0) 1]
                            [(!=
                                (ownership-obligation-parent
                                  (& (array-ref body.obligations owner)))
                                top)
                              2]
                            [else 0])]
                        [(= action 3)
                          (if (and (= top owner) (= (array-ref state owner) 1))
                            0
                            3)]
                        [(= action 4)
                          (if (= top owner)
                            0
                            4)]
                        [else
                          (if (> (array-ref state owner) 0)
                            0
                            5)])]
                    (when
                      (and (<= action 2) (= problem 0))
                      (let
                        [active : i64 top]
                        (while (>= active 0)
                          (unless
                            (ownership-charge! work limits.max-work 1)
                            (return
                              (ownership-scope-fail
                                OwnershipFailureKind.Resource
                                block
                                j
                                instr.source
                                "ownership active root work exhausted")))
                          (when
                            (=
                              (array-ref body.obligations active).place.index
                              (array-ref body.obligations owner).place.index)
                            (set! problem 6))
                          (set!
                            active
                            (ownership-obligation-parent
                              (& (array-ref body.obligations active)))))))
                    (if (> problem 0)
                      (set! (array-ref errors position) problem)
                      (cond
                        [(<= action 2)
                          (set! (array-ref state owner) action)
                          (set! top owner)]
                        [(= action 3) (set! (array-ref state owner) 2)]
                        [(= action 4)
                          (set! (array-ref state owner) 0)
                          (set!
                            top
                            (ownership-obligation-parent
                              (& (array-ref body.obligations owner))))]
                        [else unit]))))))
            (set! j (+ j 1)))
          (set! j 0)
          (while (< j 2)
            (let
              [target : i64
                (ownership-successor
                  (& (array-ref body.blocks block).terminator)
                  j)]
              (when
                (>= target 0)
                (unless
                  (ownership-charge! work limits.max-work (+ owners 1))
                  (return
                    (ownership-scope-fail
                      OwnershipFailureKind.Resource
                      block
                      -1
                      (array-ref body.blocks block).source
                      "ownership scope edge work exhausted")))
                (if (array-ref reached target)
                  (begin
                    (unless
                      (= (array-ref input-tops target) top)
                      (return
                        (ownership-scope-fail
                          OwnershipFailureKind.Structural
                          block
                          (array-length instructions)
                          (array-ref body.blocks block).source
                          "control-flow predecessors disagree on the scope stack")))
                    (set! i 0)
                    (while (< i owners)
                      (unless
                        (=
                          (array-ref inputs (+ (* target owners) i))
                          (array-ref state i))
                        (return
                          (ownership-scope-fail
                            OwnershipFailureKind.Structural
                            block
                            (array-length instructions)
                            (array-ref body.blocks block).source
                            "control-flow predecessors disagree on binding activation")))
                      (set! i (+ i 1))))
                  (begin
                    (set! (array-ref reached target) true)
                    (set! (array-ref input-tops target) top)
                    (set! i 0)
                    (while (< i owners)
                      (set!
                        (array-ref inputs (+ (* target owners) i))
                        (array-ref state i))
                      (set! i (+ i 1)))
                    (set! (array-ref queue tail) target)
                    (set! tail (+ tail 1)))))
              (set! j (+ j 1))))))
      (OwnershipScopePlanResult.Ok
        (OwnershipScopePlan offsets tops errors phases)))))

;; Payload copies retain body-relative IDs while owning every generated array
;; and diagnostic string. No borrowed input descriptor becomes an output owner.
(define (ownership-body-id-copy [id : (& id OwnershipBodyId)]) : OwnershipBodyId
  (OwnershipBodyId id.owner id.generation id.revision))

(define (ownership-place-id-copy [id : (& id OwnershipPlaceId)]) : OwnershipPlaceId
  (OwnershipPlaceId (ownership-body-id-copy (& id.body)) id.index))

(define (ownership-loan-id-copy [id : (& id OwnershipLoanId)]) : OwnershipLoanId
  (OwnershipLoanId (ownership-body-id-copy (& id.body)) id.index))

(define (ownership-cleanup-id-copy [id : (& id OwnershipCleanupId)]) : OwnershipCleanupId
  (OwnershipCleanupId (ownership-body-id-copy (& id.body)) id.index))

(define (ownership-obligation-id-copy [id : (& id OwnershipObligationId)]) : OwnershipObligationId
  (OwnershipObligationId (ownership-body-id-copy (& id.body)) id.index))

(define (ownership-type-id-copy [id : (& id OwnershipTypeId)]) : OwnershipTypeId
  (OwnershipTypeId (ownership-body-id-copy (& id.body)) id.index))

(define (ownership-local-id-copy [id : (& id OwnershipLocalId)]) : OwnershipLocalId
  (OwnershipLocalId (ownership-body-id-copy (& id.body)) id.index))

(define (ownership-block-id-copy [id : (& id OwnershipBlockId)]) : OwnershipBlockId
  (OwnershipBlockId (ownership-body-id-copy (& id.body)) id.index))

(define (ownership-operation-copy [op : (& op OwnershipOperation)]) : OwnershipOperation
  (match op
    [(OwnershipOperation.Read p)
      (OwnershipOperation.Read (ownership-place-id-copy p))]
    [(OwnershipOperation.Initialize p)
      (OwnershipOperation.Initialize (ownership-place-id-copy p))]
    [(OwnershipOperation.Assign p)
      (OwnershipOperation.Assign (ownership-place-id-copy p))]
    [(OwnershipOperation.RequireEmpty p)
      (OwnershipOperation.RequireEmpty (ownership-place-id-copy p))]
    [(OwnershipOperation.BindFresh o)
      (OwnershipOperation.BindFresh (ownership-obligation-id-copy o))]
    [(OwnershipOperation.BeginConstruction o)
      (OwnershipOperation.BeginConstruction (ownership-obligation-id-copy o))]
    [(OwnershipOperation.BindComplete o)
      (OwnershipOperation.BindComplete (ownership-obligation-id-copy o))]
    [(OwnershipOperation.BindMove p o)
      (OwnershipOperation.BindMove
        (ownership-place-id-copy p)
        (ownership-obligation-id-copy o))]
    [(OwnershipOperation.Leave o)
      (OwnershipOperation.Leave (ownership-obligation-id-copy o))]
    [(OwnershipOperation.Cleanup o c)
      (OwnershipOperation.Cleanup
        (ownership-obligation-id-copy o)
        (ownership-cleanup-id-copy c))]
    [(OwnershipOperation.CleanupPlace p c)
      (OwnershipOperation.CleanupPlace
        (ownership-place-id-copy p)
        (ownership-cleanup-id-copy c))]
    [(OwnershipOperation.CleanupFailure code)
      (OwnershipOperation.CleanupFailure code)]
    [(OwnershipOperation.Consume p)
      (OwnershipOperation.Consume (ownership-place-id-copy p))]
    [(OwnershipOperation.Copy a b)
      (OwnershipOperation.Copy
        (ownership-place-id-copy a)
        (ownership-place-id-copy b))]
    [(OwnershipOperation.Move a b)
      (OwnershipOperation.Move
        (ownership-place-id-copy a)
        (ownership-place-id-copy b))]
    [(OwnershipOperation.Invalidate p)
      (OwnershipOperation.Invalidate (ownership-place-id-copy p))]
    [(OwnershipOperation.Borrow l)
      (OwnershipOperation.Borrow (ownership-loan-id-copy l))]
    [(OwnershipOperation.Reborrow l)
      (OwnershipOperation.Reborrow (ownership-loan-id-copy l))]
    [(OwnershipOperation.UseLoan l)
      (OwnershipOperation.UseLoan (ownership-loan-id-copy l))]
    [(OwnershipOperation.MayUseLoan l holder)
      (OwnershipOperation.MayUseLoan
        (ownership-loan-id-copy l)
        (ownership-place-id-copy holder))]
    [(OwnershipOperation.AccessThrough l p a)
      (OwnershipOperation.AccessThrough
        (ownership-loan-id-copy l)
        (ownership-place-id-copy p)
        (match a
          [(OwnershipAccess.Read) OwnershipAccess.Read]
          [(OwnershipAccess.Write) OwnershipAccess.Write]))]
    [(OwnershipOperation.EndLoan l)
      (OwnershipOperation.EndLoan (ownership-loan-id-copy l))]
    [(OwnershipOperation.Unsupported reason)
      (OwnershipOperation.Unsupported (string.copy reason))]))

(defstruct OwnershipCleanupEmission
  (instructions (__tl_dyn-array OwnershipInstruction))
  (origins (__tl_dyn-array i64))
  (actions (__tl_dyn-array OwnershipCleanupAction))
  (instruction-count i64)
  (action-count i64)
  (writing? bool))

(define (ownership-cleanup-emit!
  [output : (&mut output OwnershipCleanupEmission)]
  [operation : OwnershipOperation]
  [source : (& source OwnershipSource)]
  [origin : i64]
  [work : (&mut work i64)]
  [limits : OwnershipLimits]) : bool
  (if (or
    (not (ownership-charge! work limits.max-work 1))
    (>= output.instruction-count limits.max-nodes))
    false
    (begin
      (when
        output.writing?
        (unless
          (and
            (< output.instruction-count (array-length output.instructions))
            (ownership-source-charge! work limits.max-work source))
          (return false))
        (set!
          (array-ref output.instructions output.instruction-count)
          (OwnershipInstruction operation (ownership-source-copy source)))
        (set! (array-ref output.origins output.instruction-count) origin))
      (set! output.instruction-count (+ output.instruction-count 1))
      true)))

(define (ownership-cleanup-action!
  [output : (&mut output OwnershipCleanupEmission)]
  [block : i64]
  [instruction : i64]
  [place : OwnershipPlaceId]
  [cleanup : OwnershipCleanupId]
  [work : (&mut work i64)]
  [limits : OwnershipLimits]) : bool
  (if (or
    (not (ownership-charge! work limits.max-work 1))
    (>= output.action-count limits.max-nodes))
    false
    (begin
      (when
        output.writing?
        (unless
          (< output.action-count (array-length output.actions))
          (return false))
        (set!
          (array-ref output.actions output.action-count)
          (OwnershipCleanupAction block instruction place cleanup)))
      (set! output.action-count (+ output.action-count 1))
      true)))

(define (ownership-cleanup-phase
  [body : (& body OwnershipBody)]
  [plan : (& plan OwnershipScopePlan)]
  [point : i64]
  [owner : i64]) : i64
  (array-ref plan.phases (+ (* point (array-length body.obligations)) owner)))

;; -1 means ordinary storage, -2 inactive declared owner, -3 exhausted.
(define (ownership-cleanup-place-owner
  [body : (& body OwnershipBody)]
  [plan : (& plan OwnershipScopePlan)]
  [point : i64]
  [place : i64]
  [work : (&mut work i64)]
  [limit : i64]) : i64
  (let
    [i : i64 0]
    [inactive : bool false]
    (while (< i (array-length body.obligations))
      (unless (ownership-charge! work limit 1) (return -3))
      ;; Obligation places are roots; a local identity decides containment.
      (when
        (=
          (array-ref body.places place).local.index
          (array-ref body.places (array-ref body.obligations i).place.index).local.index)
        (if (> (ownership-cleanup-phase body plan point i) 0)
          (return i)
          (set! inactive true)))
      (set! i (+ i 1)))
    (if inactive
      -2
      -1)))

;; Resolve a descendant's exact declared cleanup, never merely a same-typed
;; hook. A product's ordinary fields return -1. Contracts decrease type index
;; at each descent, so this walk cannot cycle.
(define (ownership-cleanup-place-contract
  [body : (& body OwnershipBody)]
  [places : (& places OwnershipPlaceIndex)]
  [owner : i64]
  [place : i64]
  [work : (&mut work i64)]
  [limit : i64]) : i64
  (let
    [cursor : i64 (array-ref body.obligations owner).place.index]
    [contract : i64 (array-ref body.obligations owner).cleanup.index]
    (while (!= cursor place)
      (unless (ownership-charge! work limit 1) (return -2))
      (match (& (array-ref body.cleanups contract).kind)
        [(OwnershipCleanupKind.Intrinsic) (return -1)]
        [(OwnershipCleanupKind.Product fields)
          (let
            [child : i64 place]
            [ordinal : i64 -1]
            [found : i64 -1]
            [i : i64 0]
            (while (!= (array-ref places.parent child) cursor)
              (unless (ownership-charge! work limit 1) (return -2))
              (set! child (array-ref places.parent child)))
            (match (& (array-ref body.places child).projection)
              [(OwnershipProjection.Field _ number) (set! ordinal number)]
              [_ unit])
            (while (< i (array-length fields.items))
              (unless (ownership-charge! work limit 1) (return -2))
              (when
                (= (array-ref fields.items i).ordinal ordinal)
                (set! found (array-ref fields.items i).cleanup.index))
              (set! i (+ i 1)))
            (when (< found 0) (return -1))
            (set! cursor child)
            (set! contract found))]))
    contract))

(define (ownership-cleanup-inspect
  [body : (& body OwnershipBody)]
  [limits : OwnershipLimits]) : OwnershipCleanupInspection
  (let
    [checked : OwnershipCleanupChecked (ownership-cleanup-checked body limits)]
    (OwnershipCleanupInspection
      checked.inspection.result
      checked.inspection.observation.complete?
      checked.actions
      checked.inspection.observation.offsets
      checked.inspection.observation.failure-kinds)))

(defenum OwnershipCleanupBodyResult
  (Ok OwnershipBody)
  (Err OwnershipFailure))

(defmacro (ownership-cleanup-body-fail [source : Expr]) : Expr
  `(OwnershipCleanupBodyResult.Err
    (OwnershipFailure
      OwnershipFailureKind.Resource
      -1
      -1
      -1
      -1
      -1
      (ownership-source-copy (& ,source))
      "ownership cleanup expansion budget exhausted")))

(define (ownership-cleanup-body
  [body : (& body OwnershipBody)]
  [blocks : (__tl_dyn-array OwnershipBlock)]
  [work : (&mut work i64)]
  [cells : (&mut cells i64)]
  [limits : OwnershipLimits]) : OwnershipCleanupBodyResult
  (let
    [owners : i64 (array-length body.obligations)]
    [type-count : i64 (array-length body.types)]
    [local-count : i64 (array-length body.locals)]
    [place-count : i64 (array-length body.places)]
    [loan-count : i64 (array-length body.loans)]
    [source : (& body OwnershipSource)
      (& (array-ref body.blocks body.entry.index).source)]
    [units : i64
      (+ type-count 1 local-count owners place-count owners loan-count)]
    (unless
      (and
        (< type-count limits.max-nodes)
        (<= owners (- limits.max-nodes local-count))
        (<= owners (- limits.max-nodes place-count))
        (ownership-charge! cells limits.max-state-cells units)
        (ownership-charge! work limits.max-work units))
      (return (ownership-cleanup-body-fail source)))
    (let
      [types : (__tl_dyn-array OwnershipType)
        (__tl_make-array OwnershipType (+ type-count 1))]
      [locals : (__tl_dyn-array OwnershipLocal)
        (__tl_make-array OwnershipLocal (+ local-count owners))]
      [places : (__tl_dyn-array OwnershipPlace)
        (__tl_make-array OwnershipPlace (+ place-count owners))]
      [loans : (__tl_dyn-array OwnershipLoan)
        (__tl_make-array OwnershipLoan loan-count)]
      [i : i64 0]
      (while (< i type-count)
        (let
          [kind : OwnershipTypeKind
            (match (& (array-ref body.types i).kind)
              [(OwnershipTypeKind.Scalar) OwnershipTypeKind.Scalar]
              [(OwnershipTypeKind.Boolean) OwnershipTypeKind.Boolean]
              [(OwnershipTypeKind.Product fields)
                (unless
                  (and
                    (ownership-charge!
                      cells
                      limits.max-state-cells
                      (array-length fields.items))
                    (ownership-charge!
                      work
                      limits.max-work
                      (array-length fields.items)))
                  (return (ownership-cleanup-body-fail source)))
                (let
                  [copy : (__tl_dyn-array OwnershipTypeId)
                    (__tl_make-array
                      OwnershipTypeId
                      (array-length fields.items))]
                  [j : i64 0]
                  (while (< j (array-length fields.items))
                    (set!
                      (array-ref copy j)
                      (ownership-type-id-copy (& (array-ref fields.items j))))
                    (set! j (+ j 1)))
                  (OwnershipTypeKind.Product (OwnershipTypeIds copy)))])]
          (set!
            (array-ref types i)
            (OwnershipType kind (array-ref body.types i).copy?))
          (set! i (+ i 1))))
      (set!
        (array-ref types type-count)
        (OwnershipType OwnershipTypeKind.Boolean true))
      (set! i 0)
      (while (< i local-count)
        (let
          [local : (& body OwnershipLocal) (& (array-ref body.locals i))]
          (unless
            (ownership-source-charge! work limits.max-work (& local.source))
            (return (ownership-cleanup-body-fail source)))
          (set!
            (array-ref locals i)
            (OwnershipLocal
              (ownership-type-id-copy (& local.type))
              local.parameter?
              (ownership-source-copy (& local.source))))
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i place-count)
        (let
          [place : (& body OwnershipPlace) (& (array-ref body.places i))]
          (unless
            (ownership-source-charge! work limits.max-work (& place.source))
            (return (ownership-cleanup-body-fail source)))
          (set!
            (array-ref places i)
            (OwnershipPlace
              (ownership-local-id-copy (& place.local))
              (ownership-type-id-copy (& place.type))
              (match (& place.projection)
                [(OwnershipProjection.Root) OwnershipProjection.Root]
                [(OwnershipProjection.Field parent ordinal)
                  (OwnershipProjection.Field
                    (ownership-place-id-copy parent)
                    ordinal)])
              (ownership-source-copy (& place.source))))
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i loan-count)
        (let
          [loan : (& body OwnershipLoan) (& (array-ref body.loans i))]
          (unless
            (ownership-source-charge! work limits.max-work (& loan.source))
            (return (ownership-cleanup-body-fail source)))
          (set!
            (array-ref loans i)
            (OwnershipLoan
              (ownership-place-id-copy (& loan.place))
              (match (& loan.kind)
                [(OwnershipLoanKind.Shared) OwnershipLoanKind.Shared]
                [(OwnershipLoanKind.Exclusive) OwnershipLoanKind.Exclusive])
              (match (& loan.origin)
                [(OwnershipLoanOrigin.Direct) OwnershipLoanOrigin.Direct]
                [(OwnershipLoanOrigin.Parent parent)
                  (OwnershipLoanOrigin.Parent (ownership-loan-id-copy parent))])
              (ownership-source-copy (& loan.source))))
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i owners)
        (let
          [owner : (& body OwnershipObligation)
            (& (array-ref body.obligations i))]
          (unless
            (and
              (ownership-source-charge! work limits.max-work (& owner.source))
              (ownership-source-charge! work limits.max-work (& owner.source)))
            (return (ownership-cleanup-body-fail source)))
          (set!
            (array-ref locals (+ local-count i))
            (OwnershipLocal
              (OwnershipTypeId (ownership-body-id-copy (& body.id)) type-count)
              false
              (ownership-source-copy (& owner.source))))
          (set!
            (array-ref places (+ place-count i))
            (OwnershipPlace
              (OwnershipLocalId
                (ownership-body-id-copy (& body.id))
                (+ local-count i))
              (OwnershipTypeId (ownership-body-id-copy (& body.id)) type-count)
              OwnershipProjection.Root
              (ownership-source-copy (& owner.source))))
          (set! i (+ i 1))))
      (OwnershipCleanupBodyResult.Ok
        (OwnershipBody
          (ownership-body-id-copy (& body.id))
          types
          locals
          places
          loans
          (__tl_make-array OwnershipCleanup 0)
          (__tl_make-array OwnershipObligation 0)
          blocks
          (ownership-block-id-copy (& body.entry)))))))

(defstruct OwnershipCleanupWorkspace
  (places OwnershipPlaceIndex)
  (stack-places (__tl_dyn-array i64))
  (stack-contracts (__tl_dyn-array i64)))

(define (ownership-cleanup-actions!
  [body : (& body OwnershipBody)]
  [workspace : (&mut workspace OwnershipCleanupWorkspace)]
  [output : (&mut output OwnershipCleanupEmission)]
  [place : i64]
  [contract : i64]
  [block : i64]
  [instruction : i64]
  [work : (&mut work i64)]
  [limits : OwnershipLimits]) : bool
  (let
    [depth : i64 1]
    (set! (array-ref workspace.stack-places 0) place)
    (set! (array-ref workspace.stack-contracts 0) contract)
    (while (> depth 0)
      (unless (ownership-charge! work limits.max-work 1) (return false))
      (set! depth (- depth 1))
      (let
        [parent : i64 (array-ref workspace.stack-places depth)]
        [current : i64 (array-ref workspace.stack-contracts depth)]
        (match (& (array-ref body.cleanups current).kind)
          [(OwnershipCleanupKind.Intrinsic)
            (unless
              (ownership-cleanup-action!
                output
                block
                instruction
                (OwnershipPlaceId (ownership-body-id-copy (& body.id)) parent)
                (OwnershipCleanupId
                  (ownership-body-id-copy (& body.id))
                  current)
                work
                limits)
              (return false))]
          [(OwnershipCleanupKind.Product fields)
            (let
              [i : i64 0]
              ;; Ascending push gives reverse declaration order on pop;
              ;; a nested product finishes before its previous sibling.
              (while (< i (array-length fields.items))
                (let
                  [child : i64 (array-ref workspace.places.first-child parent)]
                  [found : i64 -1]
                  (while (>= child 0)
                    (begin
                      (unless
                        (ownership-charge! work limits.max-work 1)
                        (return false))
                      (match (& (array-ref body.places child).projection)
                        [(OwnershipProjection.Field _ ordinal)
                          (when
                            (= ordinal (array-ref fields.items i).ordinal)
                            (set! found child))]
                        [_ unit])
                      (set!
                        child
                        (array-ref workspace.places.next-sibling child))))
                  (unless
                    (and
                      (>= found 0)
                      (< depth (array-length workspace.stack-places)))
                    (return false))
                  (set! (array-ref workspace.stack-places depth) found)
                  (set!
                    (array-ref workspace.stack-contracts depth)
                    (array-ref fields.items i).cleanup.index)
                  (set! depth (+ depth 1))
                  (set! i (+ i 1)))))])))
    true))

(define (ownership-cleanup-marker [body : (& body OwnershipBody)] [owner : i64]) : OwnershipPlaceId
  (OwnershipPlaceId
    (ownership-body-id-copy (& body.id))
    (+ (array-length body.places) owner)))

(define (ownership-cleanup-retained!
  [body : (& body OwnershipBody)]
  [output : (&mut output OwnershipCleanupEmission)]
  [owner : i64]
  [source : (& source OwnershipSource)]
  [origin : i64]
  [work : (&mut work i64)]
  [limits : OwnershipLimits]) : bool
  (let
    [i : i64 0]
    (while (< i (array-length (array-ref body.obligations owner).retained))
      (unless (ownership-charge! work limits.max-work 1) (return false))
      (unless
        (ownership-cleanup-emit!
          output
          (match (& (array-ref (array-ref body.obligations owner).retained i))
            [(OwnershipCleanupUse.Read place)
              (OwnershipOperation.Read (ownership-place-id-copy place))]
            [(OwnershipCleanupUse.Through loan place)
              (OwnershipOperation.AccessThrough
                (ownership-loan-id-copy loan)
                (ownership-place-id-copy place)
                OwnershipAccess.Read)])
          source
          origin
          work
          limits)
        (return false))
      (set! i (+ i 1)))
    true))

(define (ownership-cleanup-whole!
  [body : (& body OwnershipBody)]
  [workspace : (&mut workspace OwnershipCleanupWorkspace)]
  [output : (&mut output OwnershipCleanupEmission)]
  [owner : i64]
  [place : i64]
  [contract : i64]
  [block : i64]
  [instruction : i64]
  [source : (& source OwnershipSource)]
  [work : (&mut work i64)]
  [limits : OwnershipLimits]) : bool
  (and
    (ownership-cleanup-emit!
      output
      (OwnershipOperation.Read
        (OwnershipPlaceId (ownership-body-id-copy (& body.id)) place))
      source
      instruction
      work
      limits)
    (or
      (< owner 0)
      (ownership-cleanup-retained!
        body
        output
        owner
        source
        instruction
        work
        limits))
    (ownership-cleanup-emit!
      output
      (OwnershipOperation.Invalidate
        (OwnershipPlaceId (ownership-body-id-copy (& body.id)) place))
      source
      instruction
      work
      limits)
    (ownership-cleanup-actions!
      body
      workspace
      output
      place
      contract
      block
      instruction
      work
      limits)))

(define (ownership-cleanup-discharge? [owner : (& owner OwnershipObligation)]) : bool
  (match (& owner.mode)
    [(OwnershipObligationMode.AutomaticRequired) false]
    [(OwnershipObligationMode.Discharge) true]))

(define (ownership-cleanup-partial!
  [body : (& body OwnershipBody)]
  [plan : (& plan OwnershipScopePlan)]
  [output : (&mut output OwnershipCleanupEmission)]
  [point : i64]
  [owner : i64]
  [place : i64]
  [source : (& source OwnershipSource)]
  [instruction : i64]
  [work : (&mut work i64)]
  [limits : OwnershipLimits]) : bool
  (or
    (< owner 0)
    (!= (ownership-cleanup-phase body plan point owner) 2)
    (not (ownership-cleanup-discharge? (& (array-ref body.obligations owner))))
    (ownership-cleanup-emit!
      output
      (if (= (array-ref body.obligations owner).place.index place)
        (OwnershipOperation.Assign (ownership-cleanup-marker body owner))
        (OwnershipOperation.Invalidate (ownership-cleanup-marker body owner)))
      source
      instruction
      work
      limits)))

(define (ownership-cleanup-leave!
  [body : (& body OwnershipBody)]
  [plan : (& plan OwnershipScopePlan)]
  [workspace : (&mut workspace OwnershipCleanupWorkspace)]
  [output : (&mut output OwnershipCleanupEmission)]
  [point : i64]
  [owner : i64]
  [block : i64]
  [instruction : i64]
  [source : (& source OwnershipSource)]
  [work : (&mut work i64)]
  [limits : OwnershipLimits]) : bool
  (let
    [binding : (& body OwnershipObligation)
      (& (array-ref body.obligations owner))]
    (if (or
      (= (ownership-cleanup-phase body plan point owner) 1)
      (ownership-cleanup-discharge? binding))
      (and
        (ownership-cleanup-emit!
          output
          (OwnershipOperation.RequireEmpty
            (ownership-place-id-copy (& binding.place)))
          source
          instruction
          work
          limits)
        (or
          (= (ownership-cleanup-phase body plan point owner) 1)
          (ownership-cleanup-emit!
            output
            (OwnershipOperation.Read (ownership-cleanup-marker body owner))
            source
            instruction
            work
            limits)))
      (ownership-cleanup-whole!
        body
        workspace
        output
        owner
        binding.place.index
        binding.cleanup.index
        block
        instruction
        source
        work
        limits))))

(define (ownership-cleanup-reject!
  [output : (&mut output OwnershipCleanupEmission)]
  [source : (& source OwnershipSource)]
  [instruction : i64]
  [work : (&mut work i64)]
  [limits : OwnershipLimits]) : bool
  (ownership-cleanup-emit!
    output
    (OwnershipOperation.CleanupFailure 0)
    source
    instruction
    work
    limits))

(define (ownership-cleanup-move!
  [body : (& body OwnershipBody)]
  [plan : (& plan OwnershipScopePlan)]
  [workspace : (&mut workspace OwnershipCleanupWorkspace)]
  [output : (&mut output OwnershipCleanupEmission)]
  [point : i64]
  [source-place : i64]
  [destination : i64]
  [destination-owner : i64]
  [source : (& source OwnershipSource)]
  [instruction : i64]
  [work : (&mut work i64)]
  [limits : OwnershipLimits]) : bool
  (let
    [from : i64
      (ownership-cleanup-place-owner
        body
        plan
        point
        source-place
        work
        limits.max-work)]
    [into : i64
      (if (>= destination-owner 0)
        destination-owner
        (ownership-cleanup-place-owner
          body
          plan
          point
          destination
          work
          limits.max-work))]
    [copy? : bool
      (array-ref body.types (array-ref body.places source-place).type.index).copy?]
    (when (or (= from -3) (= into -3)) (return false))
    (when
      (or (= from -2) (= into -2))
      (return (ownership-cleanup-reject! output source instruction work limits)))
    (let
      [source-contract : i64
        (if (>= from 0)
          (ownership-cleanup-place-contract
            body
            (& workspace.places)
            from
            source-place
            work
            limits.max-work)
          -1)]
      [destination-contract : i64
        (if (>= into 0)
          (ownership-cleanup-place-contract
            body
            (& workspace.places)
            into
            destination
            work
            limits.max-work)
          -1)]
      (when
        (or (= source-contract -2) (= destination-contract -2))
        (return false))
      (when
        (and
          (not copy?)
          (>= source-contract 0)
          (!= source-contract destination-contract))
        (return
          (ownership-cleanup-reject! output source instruction work limits)))
      (unless
        copy?
        (let
          [dependencies : i64
            (ownership-cleanup-dependencies body from into work limits.max-work)]
          (when (< dependencies 0) (return false))
          (when
            (= dependencies 0)
            (return
              (ownership-cleanup-reject! output source instruction work limits)))))
      (and
        (or
          (< destination-contract 0)
          (ownership-cleanup-emit!
            output
            (OwnershipOperation.RequireEmpty
              (OwnershipPlaceId
                (ownership-body-id-copy (& body.id))
                destination))
            source
            instruction
            work
            limits))
        (ownership-cleanup-emit!
          output
          (OwnershipOperation.Move
            (OwnershipPlaceId (ownership-body-id-copy (& body.id)) source-place)
            (OwnershipPlaceId (ownership-body-id-copy (& body.id)) destination))
          source
          instruction
          work
          limits)
        (or
          copy?
          (ownership-cleanup-partial!
            body
            plan
            output
            point
            from
            source-place
            source
            instruction
            work
            limits))))))

(define (ownership-cleanup-instruction!
  [body : (& body OwnershipBody)]
  [plan : (& plan OwnershipScopePlan)]
  [workspace : (&mut workspace OwnershipCleanupWorkspace)]
  [output : (&mut output OwnershipCleanupEmission)]
  [block : i64]
  [index : i64]
  [work : (&mut work i64)]
  [limits : OwnershipLimits]) : bool
  (let
    [instr : (& body OwnershipInstruction)
      (& (array-ref (array-ref body.blocks block).instructions index))]
    [point : i64 (+ (array-ref plan.offsets block) index)]
    (when
      (> (array-ref plan.errors point) 0)
      (return
        (ownership-cleanup-reject! output (& instr.source) index work limits)))
    ;; Dead blocks retain loan definitions and ordinary operations for full
    ;; structural validation, but cannot manufacture an active lexical owner.
    (when
      (= (array-ref plan.tops point) -2)
      (return
        (ownership-cleanup-emit!
          output
          (match (& instr.operation)
            [(OwnershipOperation.BindFresh _)
              (OwnershipOperation.CleanupFailure 0)]
            [(OwnershipOperation.BindMove _ _)
              (OwnershipOperation.CleanupFailure 0)]
            [(OwnershipOperation.BeginConstruction _)
              (OwnershipOperation.CleanupFailure 0)]
            [(OwnershipOperation.BindComplete _)
              (OwnershipOperation.CleanupFailure 0)]
            [(OwnershipOperation.Leave _) (OwnershipOperation.CleanupFailure 0)]
            [(OwnershipOperation.Cleanup _ _)
              (OwnershipOperation.CleanupFailure 0)]
            [(OwnershipOperation.CleanupPlace _ _)
              (OwnershipOperation.CleanupFailure 0)]
            [_ (ownership-operation-copy (& instr.operation))])
          (& instr.source)
          index
          work
          limits)))
    (match (& instr.operation)
      [(OwnershipOperation.BindFresh owner)
        (and
          (ownership-cleanup-emit!
            output
            (OwnershipOperation.Initialize
              (ownership-place-id-copy
                (& (array-ref body.obligations owner.index).place)))
            (& instr.source)
            index
            work
            limits)
          (ownership-cleanup-emit!
            output
            (OwnershipOperation.Assign
              (ownership-cleanup-marker body owner.index))
            (& instr.source)
            index
            work
            limits))]
      [(OwnershipOperation.BeginConstruction owner)
        (and
          (ownership-cleanup-emit!
            output
            (OwnershipOperation.RequireEmpty
              (ownership-place-id-copy
                (& (array-ref body.obligations owner.index).place)))
            (& instr.source)
            index
            work
            limits)
          (ownership-cleanup-emit!
            output
            (OwnershipOperation.Assign
              (ownership-cleanup-marker body owner.index))
            (& instr.source)
            index
            work
            limits))]
      [(OwnershipOperation.BindComplete owner)
        (and
          (ownership-cleanup-emit!
            output
            (OwnershipOperation.Read
              (ownership-place-id-copy
                (& (array-ref body.obligations owner.index).place)))
            (& instr.source)
            index
            work
            limits)
          (ownership-cleanup-emit!
            output
            (OwnershipOperation.Assign
              (ownership-cleanup-marker body owner.index))
            (& instr.source)
            index
            work
            limits))]
      [(OwnershipOperation.BindMove source owner)
        (and
          (ownership-cleanup-move!
            body
            plan
            workspace
            output
            point
            source.index
            (array-ref body.obligations owner.index).place.index
            owner.index
            (& instr.source)
            index
            work
            limits)
          (ownership-cleanup-emit!
            output
            (OwnershipOperation.Assign
              (ownership-cleanup-marker body owner.index))
            (& instr.source)
            index
            work
            limits))]
      [(OwnershipOperation.Move source dest)
        (ownership-cleanup-move!
          body
          plan
          workspace
          output
          point
          source.index
          dest.index
          -1
          (& instr.source)
          index
          work
          limits)]
      [(OwnershipOperation.Leave owner)
        (ownership-cleanup-leave!
          body
          plan
          workspace
          output
          point
          owner.index
          block
          index
          (& instr.source)
          work
          limits)]
      [(OwnershipOperation.Cleanup owner contract)
        (and
          (ownership-cleanup-whole!
            body
            workspace
            output
            owner.index
            (array-ref body.obligations owner.index).place.index
            contract.index
            block
            index
            (& instr.source)
            work
            limits)
          (ownership-cleanup-partial!
            body
            plan
            output
            point
            owner.index
            (array-ref body.obligations owner.index).place.index
            (& instr.source)
            index
            work
            limits))]
      [(OwnershipOperation.CleanupPlace place contract)
        (let
          [owner : i64
            (ownership-cleanup-place-owner
              body
              plan
              point
              place.index
              work
              limits.max-work)]
          (cond
            [(= owner -3) false]
            [(< owner 0)
              (ownership-cleanup-reject!
                output
                (& instr.source)
                index
                work
                limits)]
            [else
              (let
                [actual : i64
                  (ownership-cleanup-place-contract
                    body
                    (& workspace.places)
                    owner
                    place.index
                    work
                    limits.max-work)]
                (cond
                  [(= actual -2) false]
                  [(!= actual contract.index)
                    (ownership-cleanup-reject!
                      output
                      (& instr.source)
                      index
                      work
                      limits)]
                  [else
                    (and
                      (ownership-cleanup-whole!
                        body
                        workspace
                        output
                        owner
                        place.index
                        contract.index
                        block
                        index
                        (& instr.source)
                        work
                        limits)
                      (ownership-cleanup-partial!
                        body
                        plan
                        output
                        point
                        owner
                        place.index
                        (& instr.source)
                        index
                        work
                        limits))]))]))]
      [_
        (let
          [write : i64
            (match (& instr.operation)
              [(OwnershipOperation.Initialize place) place.index]
              [(OwnershipOperation.Assign place) place.index]
              [(OwnershipOperation.Copy _ place) place.index]
              [(OwnershipOperation.AccessThrough _ place access)
                (match access
                  [(OwnershipAccess.Write) place.index]
                  [(OwnershipAccess.Read) -1])]
              [_ -1])]
          [remove : i64
            (match (& instr.operation)
              [(OwnershipOperation.Invalidate place) place.index]
              [(OwnershipOperation.Consume place)
                (if (array-ref
                  body.types
                  (array-ref body.places place.index).type.index).copy?
                  -1
                  place.index)]
              [_ -1])]
          [owner : i64 -1]
          (when
            (>= write 0)
            (set!
              owner
              (ownership-cleanup-place-owner
                body
                plan
                point
                write
                work
                limits.max-work))
            (when (= owner -3) (return false))
            (when
              (= owner -2)
              (return
                (ownership-cleanup-reject!
                  output
                  (& instr.source)
                  index
                  work
                  limits)))
            (when
              (>= owner 0)
              (let
                [contract : i64
                  (ownership-cleanup-place-contract
                    body
                    (& workspace.places)
                    owner
                    write
                    work
                    limits.max-work)]
                (when (= contract -2) (return false))
                (when
                  (>= contract 0)
                  (unless
                    (ownership-cleanup-emit!
                      output
                      (OwnershipOperation.RequireEmpty
                        (OwnershipPlaceId
                          (ownership-body-id-copy (& body.id))
                          write))
                      (& instr.source)
                      index
                      work
                      limits)
                    (return false))))))
          (when
            (>= remove 0)
            (set!
              owner
              (ownership-cleanup-place-owner
                body
                plan
                point
                remove
                work
                limits.max-work))
            (when (= owner -3) (return false))
            (when
              (= owner -2)
              (return
                (ownership-cleanup-reject!
                  output
                  (& instr.source)
                  index
                  work
                  limits)))
            (when
              (>= owner 0)
              (let
                [contract : i64
                  (ownership-cleanup-place-contract
                    body
                    (& workspace.places)
                    owner
                    remove
                    work
                    limits.max-work)]
                (when (= contract -2) (return false))
                (when
                  (>= contract 0)
                  (return
                    (ownership-cleanup-reject!
                      output
                      (& instr.source)
                      index
                      work
                      limits))))))
          (and
            (ownership-cleanup-emit!
              output
              (ownership-operation-copy (& instr.operation))
              (& instr.source)
              index
              work
              limits)
            (or
              (< remove 0)
              (ownership-cleanup-partial!
                body
                plan
                output
                point
                owner
                remove
                (& instr.source)
                index
                work
                limits))))])))

(define (ownership-cleanup-return-owned!
  [body : (& body OwnershipBody)]
  [plan : (& plan OwnershipScopePlan)]
  [output : (&mut output OwnershipCleanupEmission)]
  [point : i64]
  [place : i64]
  [source : (& source OwnershipSource)]
  [instruction : i64]
  [work : (&mut work i64)]
  [limits : OwnershipLimits]) : bool
  (let
    [owner : i64
      (ownership-cleanup-place-owner body plan point place work limits.max-work)]
    [copy? : bool
      (array-ref body.types (array-ref body.places place).type.index).copy?]
    (when (= owner -3) (return false))
    (when
      (or
        (= owner -2)
        (and
          (not copy?)
          (>= owner 0)
          (or
            (!= (array-ref body.obligations owner).place.index place)
            (> (array-length (array-ref body.obligations owner).retained) 0)
            (and
              (= (ownership-cleanup-phase body plan point owner) 2)
              (not
                (ownership-cleanup-discharge?
                  (& (array-ref body.obligations owner))))))))
      (return (ownership-cleanup-reject! output source instruction work limits)))
    (and
      (ownership-cleanup-emit!
        output
        (OwnershipOperation.Consume
          (OwnershipPlaceId (ownership-body-id-copy (& body.id)) place))
        source
        instruction
        work
        limits)
      (or
        copy?
        (ownership-cleanup-partial!
          body
          plan
          output
          point
          owner
          place
          source
          instruction
          work
          limits)))))

(define (ownership-cleanup-terminator!
  [body : (& body OwnershipBody)]
  [plan : (& plan OwnershipScopePlan)]
  [workspace : (&mut workspace OwnershipCleanupWorkspace)]
  [output : (&mut output OwnershipCleanupEmission)]
  [block : i64]
  [work : (&mut work i64)]
  [limits : OwnershipLimits]) : bool
  (let
    [original : (& body OwnershipBlock) (& (array-ref body.blocks block))]
    [instruction : i64 (array-length original.instructions)]
    [point : i64 (+ (array-ref plan.offsets block) instruction)]
    [normal? : bool false]
    (match (& original.terminator)
      [(OwnershipTerminator.Return operands)
        (let
          [i : i64 0]
          (while (< i (array-length operands.items))
            (unless
              (ownership-cleanup-emit!
                output
                (OwnershipOperation.Read
                  (ownership-place-id-copy (& (array-ref operands.items i))))
                (& original.source)
                instruction
                work
                limits)
              (return false))
            (set! i (+ i 1)))
          (set! normal? true))]
      [(OwnershipTerminator.ReturnOwned operands)
        (let
          [i : i64 0]
          (while (< i (array-length operands.items))
            (unless
              (ownership-cleanup-return-owned!
                body
                plan
                output
                point
                (array-ref operands.items i).index
                (& original.source)
                instruction
                work
                limits)
              (return false))
            (set! i (+ i 1)))
          (set! normal? true))]
      [_ unit])
    (when
      normal?
      (let
        [owner : i64 (array-ref plan.tops point)]
        (while (>= owner 0)
          (unless
            (and
              (ownership-charge! work limits.max-work 1)
              (ownership-cleanup-leave!
                body
                plan
                workspace
                output
                point
                owner
                block
                instruction
                (& original.source)
                work
                limits))
            (return false))
          (set!
            owner
            (ownership-obligation-parent (& (array-ref body.obligations owner)))))))
    true))

(define (ownership-cleanup-final-terminator
  [term : (& term OwnershipTerminator)]) : OwnershipTerminator
  (match term
    [(OwnershipTerminator.Goto target)
      (OwnershipTerminator.Goto (ownership-block-id-copy target))]
    [(OwnershipTerminator.Branch place yes no)
      (OwnershipTerminator.Branch
        (ownership-place-id-copy place)
        (ownership-block-id-copy yes)
        (ownership-block-id-copy no))]
    [(OwnershipTerminator.Return _)
      (OwnershipTerminator.Return
        (OwnershipPlaceIds (__tl_make-array OwnershipPlaceId 0)))]
    [(OwnershipTerminator.ReturnOwned _)
      (OwnershipTerminator.Return
        (OwnershipPlaceIds (__tl_make-array OwnershipPlaceId 0)))]
    [(OwnershipTerminator.Abort) OwnershipTerminator.Abort]
    [(OwnershipTerminator.Unsupported reason)
      (OwnershipTerminator.Unsupported (string.copy reason))]))

(define (ownership-cleanup-emit-block!
  [body : (& body OwnershipBody)]
  [plan : (& plan OwnershipScopePlan)]
  [workspace : (&mut workspace OwnershipCleanupWorkspace)]
  [output : (&mut output OwnershipCleanupEmission)]
  [block : i64]
  [work : (&mut work i64)]
  [limits : OwnershipLimits]) : bool
  (let
    [i : i64 0]
    (while (< i (array-length (array-ref body.blocks block).instructions))
      (unless
        (ownership-cleanup-instruction!
          body
          plan
          workspace
          output
          block
          i
          work
          limits)
        (return false))
      (set! i (+ i 1)))
    (ownership-cleanup-terminator! body plan workspace output block work limits)))

(define (ownership-cleanup-use-equal?
  [a : (& a OwnershipCleanupUse)]
  [b : (& b OwnershipCleanupUse)]) : bool
  (match a
    [(OwnershipCleanupUse.Read p)
      (match b
        [(OwnershipCleanupUse.Read q) (= p.index q.index)]
        [_ false])]
    [(OwnershipCleanupUse.Through loan place)
      (match b
        [(OwnershipCleanupUse.Through other target)
          (and (= loan.index other.index) (= place.index target.index))]
        [_ false])]))

;; Dependencies are not erased by a same-typed destination or a same cleanup
;; function. Until projection-specific origins exist, a field transfer retains
;; its whole source dependency set conservatively.
;; 1 preserved, 0 missing, -1 resource exhaustion.
(define (ownership-cleanup-dependencies
  [body : (& body OwnershipBody)]
  [source : i64]
  [destination : i64]
  [work : (&mut work i64)]
  [limit : i64]) : i64
  (if (< source 0)
    1
    (let
      [i : i64 0]
      (while (< i (array-length (array-ref body.obligations source).retained))
        (let
          [j : i64 0]
          [found : bool false]
          (unless (ownership-charge! work limit 1) (return -1))
          (when (< destination 0) (return 0))
          (while (<
            j
            (array-length (array-ref body.obligations destination).retained))
            (unless (ownership-charge! work limit 1) (return -1))
            (when
              (ownership-cleanup-use-equal?
                (& (array-ref (array-ref body.obligations source).retained i))
                (&
                  (array-ref
                    (array-ref body.obligations destination).retained
                    j)))
              (set! found true))
            (set! j (+ j 1)))
          (unless found (return 0))
          (set! i (+ i 1))))
      1)))

(defstruct OwnershipCleanupExpansion
  (body OwnershipBody)
  (origins (__tl_dyn-array (__tl_dyn-array i64)))
  (offsets (__tl_dyn-array i64))
  (actions (__tl_dyn-array OwnershipCleanupAction))
  (remaining OwnershipLimits))

(defenum OwnershipCleanupExpansionResult
  (Ok OwnershipCleanupExpansion)
  (Err OwnershipFailure))

(defmacro (ownership-cleanup-expansion-fail [source : Expr]) : Expr
  `(OwnershipCleanupExpansionResult.Err
    (OwnershipFailure
      OwnershipFailureKind.Resource
      -1
      -1
      -1
      -1
      -1
      (ownership-source-copy (& ,source))
      "ownership cleanup expansion budget exhausted")))

(define (ownership-cleanup-expand
  [body : (& body OwnershipBody)]
  [limits : OwnershipLimits]) : OwnershipCleanupExpansionResult
  (match (ownership-validate body limits)
    [(OwnershipResult.Err error)
      (return (OwnershipCleanupExpansionResult.Err error))]
    [(OwnershipResult.Ok) unit])
  (let
    [work : i64 0]
    [cells : i64 0]
    [block-count : i64 (array-length body.blocks)]
    [place-count : i64 (array-length body.places)]
    [source : (& body OwnershipSource)
      (& (array-ref body.blocks body.entry.index).source)]
    ;; Account for retained validation scratch in addition to all output and
    ;; expansion scratch. These reservations are independent of solver state.
    [_reserved : unit
      (unless
        (and
          (ownership-charge!
            (&mut cells)
            limits.max-state-cells
            (array-length body.types))
          (ownership-product-charge!
            (&mut cells)
            limits.max-state-cells
            place-count
            2)
          (ownership-charge!
            (&mut cells)
            limits.max-state-cells
            (array-length body.obligations))
          (ownership-charge!
            (&mut cells)
            limits.max-state-cells
            (array-length body.locals))
          (ownership-charge!
            (&mut cells)
            limits.max-state-cells
            (array-length body.loans)))
        (return (ownership-cleanup-expansion-fail source)))]
    [plan : OwnershipScopePlan
      (match (ownership-scope-plan body limits (&mut work) (&mut cells))
        [(OwnershipScopePlanResult.Err error)
          (return (OwnershipCleanupExpansionResult.Err error))]
        [(OwnershipScopePlanResult.Ok value) value])]
    [_workspace-reserved : unit
      (unless
        (and
          (ownership-product-charge!
            (&mut cells)
            limits.max-state-cells
            place-count
            8)
          (ownership-product-charge! (&mut work) limits.max-work place-count 8)
          (ownership-product-charge!
            (&mut cells)
            limits.max-state-cells
            block-count
            4)
          (ownership-product-charge! (&mut work) limits.max-work block-count 4))
        (return (ownership-cleanup-expansion-fail source)))]
    [workspace : OwnershipCleanupWorkspace
      (OwnershipCleanupWorkspace
        (ownership-place-index body)
        (__tl_make-array i64 place-count)
        (__tl_make-array i64 place-count))]
    [instruction-counts : (__tl_dyn-array i64)
      (__tl_make-array i64 block-count)]
    [action-counts : (__tl_dyn-array i64) (__tl_make-array i64 block-count)]
    [total-points : i64 block-count]
    [total-actions : i64 0]
    [b : i64 0]
    ;; Count and generate through the same routine. No fixed worst-case
    ;; product allocation or source-shape estimate authorizes the output.
    (while (< b block-count)
      (let
        [dry : OwnershipCleanupEmission
          (OwnershipCleanupEmission
            (__tl_make-array OwnershipInstruction 0)
            (__tl_make-array i64 0)
            (__tl_make-array OwnershipCleanupAction 0)
            0
            0
            false)]
        (unless
          (and
            (ownership-cleanup-emit-block!
              body
              (& plan)
              (&mut workspace)
              (&mut dry)
              b
              (&mut work)
              limits)
            (ownership-charge!
              (&mut total-points)
              limits.max-nodes
              dry.instruction-count)
            (ownership-charge!
              (&mut total-actions)
              limits.max-nodes
              dry.action-count))
          (return (ownership-cleanup-expansion-fail source)))
        (set! (array-ref instruction-counts b) dry.instruction-count)
        (set! (array-ref action-counts b) dry.action-count)
        (set! b (+ b 1))))
    (unless
      (and
        (ownership-product-charge!
          (&mut cells)
          limits.max-state-cells
          (- total-points block-count)
          2)
        (ownership-product-charge!
          (&mut cells)
          limits.max-state-cells
          total-actions
          2)
        (ownership-product-charge!
          (&mut work)
          limits.max-work
          (- total-points block-count)
          2)
        (ownership-product-charge! (&mut work) limits.max-work total-actions 2))
      (return (ownership-cleanup-expansion-fail source)))
    (let
      [blocks : (__tl_dyn-array OwnershipBlock)
        (__tl_make-array OwnershipBlock block-count)]
      [origins : (__tl_dyn-array (__tl_dyn-array i64))
        (__tl_make-array (__tl_dyn-array i64) block-count)]
      [actions : (__tl_dyn-array OwnershipCleanupAction)
        (__tl_make-array OwnershipCleanupAction total-actions)]
      [action-position : i64 0]
      (set! b 0)
      (while (< b block-count)
        (let
          [output : OwnershipCleanupEmission
            (OwnershipCleanupEmission
              (__tl_make-array
                OwnershipInstruction
                (array-ref instruction-counts b))
              (__tl_make-array i64 (array-ref instruction-counts b))
              (__tl_make-array
                OwnershipCleanupAction
                (array-ref action-counts b))
              0
              0
              true)]
          (unless
            (and
              (ownership-cleanup-emit-block!
                body
                (& plan)
                (&mut workspace)
                (&mut output)
                b
                (&mut work)
                limits)
              (= output.instruction-count (array-ref instruction-counts b))
              (= output.action-count (array-ref action-counts b))
              (ownership-source-charge!
                (&mut work)
                limits.max-work
                (& (array-ref body.blocks b).source)))
            (return (ownership-cleanup-expansion-fail source)))
          (let
            [i : i64 0]
            (while (< i output.action-count)
              (let
                [action : (& output OwnershipCleanupAction)
                  (& (array-ref output.actions i))]
                (unless
                  (ownership-charge! (&mut work) limits.max-work 1)
                  (return (ownership-cleanup-expansion-fail source)))
                (set!
                  (array-ref actions action-position)
                  (OwnershipCleanupAction
                    action.block
                    action.instruction
                    (ownership-place-id-copy (& action.place))
                    (ownership-cleanup-id-copy (& action.cleanup))))
                (set! action-position (+ action-position 1))
                (set! i (+ i 1)))))
          (set!
            (array-ref blocks b)
            (OwnershipBlock
              output.instructions
              (ownership-cleanup-final-terminator
                (& (array-ref body.blocks b).terminator))
              (ownership-source-copy (& (array-ref body.blocks b).source))))
          (set! (array-ref origins b) output.origins)
          (set! b (+ b 1))))
      (let
        [expanded : OwnershipBody
          (match (ownership-cleanup-body
            body
            blocks
            (&mut work)
            (&mut cells)
            limits)
            [(OwnershipCleanupBodyResult.Err error)
              (return (OwnershipCleanupExpansionResult.Err error))]
            [(OwnershipCleanupBodyResult.Ok value) value])]
        (when
          (or (>= work limits.max-work) (>= cells limits.max-state-cells))
          (return (ownership-cleanup-expansion-fail source)))
        (OwnershipCleanupExpansionResult.Ok
          (OwnershipCleanupExpansion
            expanded
            origins
            plan.offsets
            actions
            (OwnershipLimits
              limits.max-nodes
              (- limits.max-state-cells cells)
              (- limits.max-work work))))))))

(define (ownership-cleanup-remap-result
  [original : (& original OwnershipBody)]
  [origins : (& origins (__tl_dyn-array (__tl_dyn-array i64)))]
  [result : OwnershipResult]) : OwnershipResult
  (match result
    [(OwnershipResult.Ok) OwnershipResult.Ok]
    [(OwnershipResult.Err error)
      (when
        (and
          (>= error.block 0)
          (< error.block (array-length origins))
          (>= error.instruction 0))
        (set!
          error.instruction
          (if (<
            error.instruction
            (array-length (array-ref origins error.block)))
            (array-ref (array-ref origins error.block) error.instruction)
            (array-length (array-ref original.blocks error.block).instructions))))
      (when
        (>= error.place (array-length original.places))
        (let
          [owner : i64 (- error.place (array-length original.places))]
          (when
            (< owner (array-length original.obligations))
            (set!
              error.place
              (array-ref original.obligations owner).place.index)
            (let
              [partial? : bool
                (match (& error.kind)
                  [(OwnershipFailureKind.Uninitialized) true]
                  [_ false])]
              (when
                partial?
                (set! error.kind OwnershipFailureKind.Cleanup)
                (set!
                  error.message
                  "cleanup obligation has an unresolved partial transfer"))))))
      (OwnershipResult.Err error)]))

(defstruct OwnershipCleanupChecked
  (inspection OwnershipInspection)
  (actions (__tl_dyn-array OwnershipCleanupAction)))

(define (ownership-cleanup-observation-failure
  [source : (& source OwnershipSource)]) : OwnershipCleanupChecked
  (OwnershipCleanupChecked
    (OwnershipInspection
      (ownership-fail
        OwnershipFailureKind.Resource
        -1
        -1
        -1
        source
        "ownership cleanup observation budget exhausted")
      (ownership-observation-new true))
    (__tl_make-array OwnershipCleanupAction 0)))

(define (ownership-cleanup-checked
  [body : (& body OwnershipBody)]
  [limits : OwnershipLimits]) : OwnershipCleanupChecked
  (match (ownership-cleanup-expand body limits)
    [(OwnershipCleanupExpansionResult.Err error)
      (OwnershipCleanupChecked
        (OwnershipInspection
          (OwnershipResult.Err error)
          (ownership-observation-new true))
        (__tl_make-array OwnershipCleanupAction 0))]
    [(OwnershipCleanupExpansionResult.Ok expanded)
      (let
        [blocks : i64 (array-length body.blocks)]
        [points : i64 (array-ref expanded.offsets blocks)]
        [loans : i64 (array-length body.loans)]
        [cells : i64 0]
        [work : i64 0]
        [source : (& body OwnershipSource)
          (& (array-ref body.blocks body.entry.index).source)]
        [_reserved : unit
          (unless
            (and
              (ownership-product-charge!
                (&mut cells)
                expanded.remaining.max-state-cells
                points
                loans)
              (ownership-product-charge!
                (&mut cells)
                expanded.remaining.max-state-cells
                points
                loans)
              (ownership-product-charge!
                (&mut cells)
                expanded.remaining.max-state-cells
                points
                loans)
              (ownership-product-charge!
                (&mut cells)
                expanded.remaining.max-state-cells
                points
                loans)
              (ownership-charge!
                (&mut cells)
                expanded.remaining.max-state-cells
                points)
              (ownership-charge!
                (&mut cells)
                expanded.remaining.max-state-cells
                (+ blocks 1))
              (ownership-charge! (&mut work) expanded.remaining.max-work cells))
            (return (ownership-cleanup-observation-failure source)))]
        [_mapping-work : unit
          (let
            [b : i64 0]
            (while (< b blocks)
              (unless
                (ownership-charge!
                  (&mut work)
                  expanded.remaining.max-work
                  (+ (array-length (array-ref expanded.origins b)) 1))
                (return (ownership-cleanup-observation-failure source)))
              (set! b (+ b 1))))]
        [inner-limits : OwnershipLimits
          (OwnershipLimits
            expanded.remaining.max-nodes
            (- expanded.remaining.max-state-cells cells)
            (- expanded.remaining.max-work work))]
        [inner : OwnershipObservation (ownership-observation-new true)]
        [result : OwnershipResult
          (ownership-check-recording
            (& expanded.body)
            inner-limits
            (&mut inner))]
        [output : OwnershipObservation
          (OwnershipObservation
            true
            inner.complete?
            expanded.offsets
            (__tl_make-array i64 (* points loans))
            (__tl_make-array i64 (* points loans))
            (__tl_make-array i64 (* points loans))
            (__tl_make-array i64 points)
            (__tl_make-array bool (* points loans)))]
        [b : i64 0]
        ;; Resource/structural failure may stop before rows are allocated. Such
        ;; a prefix is explicitly incomplete and never a state certificate.
        (when
          (= (array-length inner.offsets) (+ blocks 1))
          (while (< b blocks)
            (let
              [original-count : i64
                (array-length (array-ref body.blocks b).instructions)]
              [generated-count : i64
                (array-length (array-ref expanded.origins b))]
              [cursor : i64 0]
              [i : i64 0]
              (while (<= i original-count)
                (let
                  [first : i64 cursor]
                  [last : i64 cursor]
                  [bits : i64 0]
                  (while (and
                    (< cursor generated-count)
                    (= (array-ref (array-ref expanded.origins b) cursor) i))
                    (let
                      [failures : i64
                        (array-ref
                          inner.failure-kinds
                          (+ (array-ref inner.offsets b) cursor))]
                      (match (&
                        (array-ref
                          (array-ref expanded.body.blocks b).instructions
                          cursor).operation)
                        [(OwnershipOperation.Read place)
                          (when
                            (and
                              (>= place.index (array-length body.places))
                              (!= (bit-and failures 1) 0))
                            (set! failures (bit-or (bit-and failures 6) 4)))]
                        [_ unit])
                      (set! bits (bit-or bits failures))
                      (set! last cursor)
                      (set! cursor (+ cursor 1))))
                  (when
                    (= i original-count)
                    (set! last generated-count)
                    (set!
                      bits
                      (bit-or
                        bits
                        (array-ref
                          inner.failure-kinds
                          (+ (array-ref inner.offsets b) generated-count)))))
                  (set!
                    (array-ref
                      output.failure-kinds
                      (+ (array-ref output.offsets b) i))
                    bits)
                  (let
                    [from-first : i64
                      (* (+ (array-ref inner.offsets b) first) loans)]
                    [from-last : i64
                      (* (+ (array-ref inner.offsets b) last) loans)]
                    [into : i64 (* (+ (array-ref output.offsets b) i) loans)]
                    [loan : i64 0]
                    (while (< loan loans)
                      (set!
                        (array-ref output.before-expiry (+ into loan))
                        (array-ref inner.before-expiry (+ from-first loan)))
                      (set!
                        (array-ref output.before (+ into loan))
                        (array-ref inner.before (+ from-first loan)))
                      (set!
                        (array-ref output.after (+ into loan))
                        (array-ref inner.after (+ from-last loan)))
                      (set!
                        (array-ref output.live (+ into loan))
                        (array-ref inner.live (+ from-first loan)))
                      (set! loan (+ loan 1))))
                  (set! i (+ i 1))))
              (set! b (+ b 1)))))
        (OwnershipCleanupChecked
          (OwnershipInspection
            (ownership-cleanup-remap-result body (& expanded.origins) result)
            output)
          expanded.actions))]))