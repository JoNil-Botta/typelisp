;; compiler_intern_state.tl - explicit structural-intern session API.
;;
;; The authoritative table layout and lookup implementation live in
;; compiler_intern. This adapter gives worker code a nominal structural view of
;; an explicitly owned source-name session.
(import compiler_intern as ci)

(defstruct InternStructuralKey
  (value i64))

(defmacro (intern-structural-key-raw [key : Expr]) : i64
  `(__tl-project-field-name ,key "value"))

;; Arena-phase identities are internal structural records, never renderable
;; source-name ids. Each variant names both the role and the components that
;; participate in canonicalization, so consumers cannot accidentally decode a
;; marker as a region merely because its raw handle occupies a numeric lane.
(defenum InternArenaPhaseRecord
  (Region i64 i64)
  (CurrentRegionMarker i64)
  (TokenOwnerMarker i64)
  (TokenRegionMarker i64))

(defstruct InternArenaPhaseIdentity
  (value i64))

(defmacro (intern-arena-phase-identity-raw [identity : Expr]) : i64
  `(__tl-project-field-name ,identity "value"))

(defenum InternMaybeArenaPhaseRecord
  (No)
  (Some InternArenaPhaseRecord))

;; Nominal one-word structural view of the compile-intern session. Its address
;; points at compiler_intern's combined source-name/structural owner record.
(defstruct InternStructuralSessionHandle
  (address i64))

(define (intern-structural-session-handle-from-source-names
  [session : ci.InternSourceNameSessionHandle]) : InternStructuralSessionHandle
  (InternStructuralSessionHandle session.address))

(define (intern-structural-session-handle-session
  [handle : InternStructuralSessionHandle]) : ci.InternSourceNameSession
  (ci.intern-source-name-session-handle-session
    (ci.InternSourceNameSessionHandle handle.address)))

(define (intern-structural-session-valid?
  [handle : InternStructuralSessionHandle]) : bool
  (if (<= handle.address 0)
    false
    (let
      [session : ci.InternSourceNameSession
        (intern-structural-session-handle-session handle)]
      (if (not (= (array-ref session.table-id-cell 0) session.table-id))
        false
        (if (not
          (=
            (array-ref session.reset-generation-cell 0)
            session.reset-generation))
          false
          (=
            (__tl-project-field
              (array-ref session.structural-table-cell 0)
              owner)
            session.structural-owner))))))

(define (intern-structural-session-owner
  [handle : InternStructuralSessionHandle]) : i64
  (if (> handle.address 0)
    (__tl-project-field
      (intern-structural-session-handle-session handle)
      structural-owner)
    -1))

(define (intern-structural-session-current-reset-generation
  [handle : InternStructuralSessionHandle]) : i64
  (if (> handle.address 0)
    (let
      [session : ci.InternSourceNameSession
        (intern-structural-session-handle-session handle)]
      (array-ref session.reset-generation-cell 0))
    -1))

(define (intern-structural-session-key
  [handle : InternStructuralSessionHandle]
  [kind : i64]
  [left-id : i64]
  [middle-id : i64]
  [right-id : i64]) : InternStructuralKey
  (if (or
    (not (intern-structural-session-valid? handle))
    (not (ci.intern-structural-kind-valid? kind)))
    (ci.tl_oob_abort)
    (let
      [session : ci.InternSourceNameSession
        (intern-structural-session-handle-session handle)]
      [raw : i64
        (ci.intern-structural-table-intern
          session.structural-table-cell
          (array-ref session.persistent-arena-cell 0)
          kind
          left-id
          middle-id
          right-id)]
      (begin
        ;; An explicitly owned session can also be the installed compatibility
        ;; owner. Keep that owner's scalar/address snapshot coherent without
        ;; touching an unrelated installed table.
        (if (= (ci.intern-active-table-id) session.table-id)
          (ci.intern-active-structural-sync! session.structural-table-cell)
          unit)
        (InternStructuralKey raw)))))

(define (intern-structural-session-composite-pair-key
  [handle : InternStructuralSessionHandle]
  [left-id : i64]
  [right-id : i64]) : InternStructuralKey
  (intern-structural-session-key
    handle
    (ci.intern-structural-kind-pair)
    left-id
    0
    right-id))

(define (intern-structural-session-composite-triple-key
  [handle : InternStructuralSessionHandle]
  [left-id : i64]
  [middle-id : i64]
  [right-id : i64]) : InternStructuralKey
  (intern-structural-session-key
    handle
    (ci.intern-structural-kind-triple)
    left-id
    middle-id
    right-id))

(define (intern-structural-session-key-owned?
  [handle : InternStructuralSessionHandle]
  [key : InternStructuralKey]) : bool
  (if (not (intern-structural-session-valid? handle))
    false
    (let
      [session : ci.InternSourceNameSession
        (intern-structural-session-handle-session handle)]
      [table : ci.InternStructuralTable
        (array-ref session.structural-table-cell 0)]
      [raw : i64 (intern-structural-key-raw key)]
      [prefix : i64
        (+
          (ci.intern-structural-key-base)
          (* session.structural-owner (ci.intern-structural-key-owner-stride)))]
      [encoded-index : i64 (- raw prefix)]
      (and (> encoded-index 0) (<= encoded-index table.len)))))

(define (intern-structural-session-key-index [key : InternStructuralKey]) : i64
  (-
    (bit-and
      (intern-structural-key-raw key)
      (ci.intern-structural-key-index-mask))
    1))

(define (intern-structural-session-key-middle
  [handle : InternStructuralSessionHandle]
  [key : InternStructuralKey]) : i64
  (if (intern-structural-session-key-owned? handle key)
    (let
      [session : ci.InternSourceNameSession
        (intern-structural-session-handle-session handle)]
      (array-ref
        (__tl-project-field (array-ref session.structural-table-cell 0) middles)
        (intern-structural-session-key-index key)))
    (ci.tl_oob_abort)))

(define (intern-structural-session-arena-phase-identity-for-components
  [handle : InternStructuralSessionHandle]
  [role : i64]
  [first-id : i64]
  [second-id : i64]) : InternArenaPhaseIdentity
  (InternArenaPhaseIdentity
    (intern-structural-key-raw
      (intern-structural-session-key
        handle
        (ci.intern-structural-kind-arena-phase)
        role
        first-id
        second-id))))

(define (intern-structural-session-arena-phase-identity
  [handle : InternStructuralSessionHandle]
  [record : InternArenaPhaseRecord]) : InternArenaPhaseIdentity
  (match record
    [(InternArenaPhaseRecord.Region owner-id token-id)
      (intern-structural-session-arena-phase-identity-for-components
        handle
        0
        owner-id
        token-id)]
    [(InternArenaPhaseRecord.CurrentRegionMarker owner-id)
      (intern-structural-session-arena-phase-identity-for-components
        handle
        1
        owner-id
        0)]
    [(InternArenaPhaseRecord.TokenOwnerMarker token-id)
      (intern-structural-session-arena-phase-identity-for-components
        handle
        2
        token-id
        0)]
    [(InternArenaPhaseRecord.TokenRegionMarker token-id)
      (intern-structural-session-arena-phase-identity-for-components
        handle
        3
        token-id
        0)]))

(define (intern-structural-session-arena-phase-record
  [handle : InternStructuralSessionHandle]
  [identity : InternArenaPhaseIdentity]) : InternMaybeArenaPhaseRecord
  (let
    [key : InternStructuralKey
      (InternStructuralKey (intern-arena-phase-identity-raw identity))]
    (if (not (intern-structural-session-key-owned? handle key))
      InternMaybeArenaPhaseRecord.No
      (let
        [session : ci.InternSourceNameSession
          (intern-structural-session-handle-session handle)]
        [table : ci.InternStructuralTable
          (array-ref session.structural-table-cell 0)]
        [index : i64 (intern-structural-session-key-index key)]
        [kind : i64 (cast (array-ref table.kinds index) : i64)]
        [role : i64 (array-ref table.lefts index)]
        [first-id : i64 (array-ref table.middles index)]
        [second-id : i64 (array-ref table.rights index)]
        (if (not (= kind (ci.intern-structural-kind-arena-phase)))
          InternMaybeArenaPhaseRecord.No
          (cond
            [(= role 0)
              (InternMaybeArenaPhaseRecord.Some
                (InternArenaPhaseRecord.Region first-id second-id))]
            [(= role 1)
              (InternMaybeArenaPhaseRecord.Some
                (InternArenaPhaseRecord.CurrentRegionMarker first-id))]
            [(= role 2)
              (InternMaybeArenaPhaseRecord.Some
                (InternArenaPhaseRecord.TokenOwnerMarker first-id))]
            [(= role 3)
              (InternMaybeArenaPhaseRecord.Some
                (InternArenaPhaseRecord.TokenRegionMarker first-id))]
            [else InternMaybeArenaPhaseRecord.No]))))))

(define (intern-structural-session-arena-phase-record-for-raw
  [handle : InternStructuralSessionHandle]
  [raw : i64]) : InternMaybeArenaPhaseRecord
  (intern-structural-session-arena-phase-record
    handle
    (InternArenaPhaseIdentity raw)))