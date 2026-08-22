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

(defstruct InternStructuralRecord
  (kind i64)
  (left-id i64)
  (middle-id i64)
  (right-id i64))

(defenum InternMaybeStructuralRecord
  (No)
  (Some InternStructuralRecord))

;; Hygienic identities cross raw i64 AST/environment fields only at compatibility
;; boundaries. Inside the structural API each family has a nominal one-word key,
;; and decoding always proves both session ownership and record kind.
(defstruct InternMacroDefinitionIdentity
  (value i64))

(defmacro (intern-macro-definition-identity-raw [identity : Expr]) : i64
  `(__tl-project-field-name ,identity "value"))

(defstruct InternMacroGlobalIdentity
  (value i64))

(defmacro (intern-macro-global-identity-raw [identity : Expr]) : i64
  `(__tl-project-field-name ,identity "value"))

(defstruct InternMacroLocalIdentity
  (value i64))

(defmacro (intern-macro-local-identity-raw [identity : Expr]) : i64
  `(__tl-project-field-name ,identity "value"))

(defenum InternMacroGlobalRole
  (Legacy)
  (Context))

(defstruct InternMacroDefinitionRecord
  (definition-module-id i64)
  (macro-name-id i64))

(defstruct InternMacroGlobalRecord
  (role InternMacroGlobalRole)
  (definition-module-id i64)
  (source-name-id i64))

(defstruct InternMacroLocalRecord
  (macro-definition InternMacroDefinitionIdentity)
  (lexical-depth i64)
  (source-name-id i64))

(defenum InternMaybeMacroDefinitionRecord
  (No)
  (Some InternMacroDefinitionRecord))

(defenum InternMaybeMacroGlobalRecord
  (No)
  (Some InternMacroGlobalRecord))

(defenum InternMaybeMacroLocalRecord
  (No)
  (Some InternMacroLocalRecord))

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
  ;; Ordinary renderable, fresh-local, and other pre-table identities dominate
  ;; mixed AST/name fields. Reject them before dereferencing the session; kind
  ;; and components for every possible table handle still come from its owned
  ;; record rather than a numeric subrange.
  (if (< (intern-structural-key-raw key) (ci.intern-structural-key-base))
    false
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
        (and (> encoded-index 0) (<= encoded-index table.len))))))

(define (intern-structural-session-key-index [key : InternStructuralKey]) : i64
  (-
    (bit-and
      (intern-structural-key-raw key)
      (ci.intern-structural-key-index-mask))
    1))

(define (intern-structural-session-record-for-raw
  [handle : InternStructuralSessionHandle]
  [raw : i64]) : InternMaybeStructuralRecord
  ;; This is the pervasive mixed-name boundary. Keep all safety checks, but do
  ;; them in one pass: layering record -> ownership -> validity repeatedly
  ;; materialized the large session value and table record at every level.
  (if (or (< raw (ci.intern-structural-key-base)) (<= handle.address 0))
    InternMaybeStructuralRecord.No
    (let
      [session-ptr : (Ptr ci.InternSourceNameSession)
        (unsafe
          (int->ptr
            (cast handle.address : u64)
            : (Ptr ci.InternSourceNameSession)))]
      ;; Focused projections from the handle avoid copying the combined
      ;; source-name session (ten arrays) and structural table (nine arrays).
      [structural-owner : i64
        (unsafe
          (__tl-project-field (ptr-read session-ptr) structural-owner))]
      [table-cell : (__tl_dyn-array ci.InternStructuralTable)
        (unsafe
          (__tl-project-field (ptr-read session-ptr) structural-table-cell))]
      [table-ptr : (Ptr ci.InternStructuralTable)
        (unsafe
          (ptr-cast
            (__tl_array-data table-cell)
            : (Ptr ci.InternStructuralTable)))]
      [table-owner : i64
        (unsafe
          (__tl-project-field (ptr-read table-ptr) owner))]
      [table-len : i64
        (unsafe
          (__tl-project-field (ptr-read table-ptr) len))]
      [prefix : i64
        (+
          (ci.intern-structural-key-base)
          (* structural-owner (ci.intern-structural-key-owner-stride)))]
      [encoded-index : i64 (- raw prefix)]
      (if (or
        ;; A reset always re-owners the retained table. The globally unique
        ;; owner is also encoded into every key, so this proves the same stale
        ;; generation and wrong-session facts without two bounds-checked loads.
        (not (= table-owner structural-owner))
        (<= encoded-index 0)
        (> encoded-index table-len))
        InternMaybeStructuralRecord.No
        (let
          [index : i64 (- encoded-index 1)]
          [kinds : (__tl_dyn-array u8)
            (unsafe
              (__tl-project-field (ptr-read table-ptr) kinds))]
          [lefts : (__tl_dyn-array i64)
            (unsafe
              (__tl-project-field (ptr-read table-ptr) lefts))]
          [middles : (__tl_dyn-array i64)
            (unsafe
              (__tl-project-field (ptr-read table-ptr) middles))]
          [rights : (__tl_dyn-array i64)
            (unsafe
              (__tl-project-field (ptr-read table-ptr) rights))]
          (InternMaybeStructuralRecord.Some
            (InternStructuralRecord
              (cast
                (unsafe
                  (ptr-read
                    (ptr-offset
                      (ptr-cast (__tl_array-data kinds) : (Ptr u8))
                      index)))
                : i64)
              (unsafe
                (ptr-read
                  (ptr-offset
                    (ptr-cast (__tl_array-data lefts) : (Ptr i64))
                    index)))
              (unsafe
                (ptr-read
                  (ptr-offset
                    (ptr-cast (__tl_array-data middles) : (Ptr i64))
                    index)))
              (unsafe
                (ptr-read
                  (ptr-offset
                    (ptr-cast (__tl_array-data rights) : (Ptr i64))
                    index))))))))))

(define (intern-structural-session-record
  [handle : InternStructuralSessionHandle]
  [key : InternStructuralKey]) : InternMaybeStructuralRecord
  (intern-structural-session-record-for-raw
    handle
    (intern-structural-key-raw key)))

;; Classification-only paths should not materialize all four record lanes.
;; Ownership is still proven from the explicit session and its re-owned table.
(define (intern-structural-session-record-kind-or
  [handle : InternStructuralSessionHandle]
  [raw : i64]
  [fallback : i64]) : i64
  (if (or (< raw (ci.intern-structural-key-base)) (<= handle.address 0))
    fallback
    (let
      [session-ptr : (Ptr ci.InternSourceNameSession)
        (unsafe
          (int->ptr
            (cast handle.address : u64)
            : (Ptr ci.InternSourceNameSession)))]
      [structural-owner : i64
        (unsafe
          (__tl-project-field (ptr-read session-ptr) structural-owner))]
      [table-cell : (__tl_dyn-array ci.InternStructuralTable)
        (unsafe
          (__tl-project-field (ptr-read session-ptr) structural-table-cell))]
      [table-ptr : (Ptr ci.InternStructuralTable)
        (unsafe
          (ptr-cast
            (__tl_array-data table-cell)
            : (Ptr ci.InternStructuralTable)))]
      [table-owner : i64
        (unsafe
          (__tl-project-field (ptr-read table-ptr) owner))]
      [table-len : i64
        (unsafe
          (__tl-project-field (ptr-read table-ptr) len))]
      [encoded-index : i64
        (-
          raw
          (+
            (ci.intern-structural-key-base)
            (* structural-owner (ci.intern-structural-key-owner-stride))))]
      (if (or
        (not (= table-owner structural-owner))
        (<= encoded-index 0)
        (> encoded-index table-len))
        fallback
        (let
          [kinds : (__tl_dyn-array u8)
            (unsafe
              (__tl-project-field (ptr-read table-ptr) kinds))]
          (cast
            (unsafe
              (ptr-read
                (ptr-offset
                  (ptr-cast (__tl_array-data kinds) : (Ptr u8))
                  (- encoded-index 1))))
            : i64))))))

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

;; Measurement/test boundary: report exact retained records by structural kind
;; without exposing table storage or making callers classify raw handles.
(define (intern-structural-session-kind-count
  [handle : InternStructuralSessionHandle]
  [kind : i64]) : i64
  (if (or
    (not (intern-structural-session-valid? handle))
    (not (ci.intern-structural-kind-valid? kind)))
    0
    (let
      [session : ci.InternSourceNameSession
        (intern-structural-session-handle-session handle)]
      [table : ci.InternStructuralTable
        (array-ref session.structural-table-cell 0)]
      [index : i64 0]
      [count : i64 0]
      (begin
        (while (< index table.len)
          (begin
            (if (= (cast (array-ref table.kinds index) : i64) kind)
              (set! count (+ count 1))
              unit)
            (set! index (+ index 1))))
        count))))

(define (intern-structural-session-macro-definition-identity
  [handle : InternStructuralSessionHandle]
  [definition-module-id : i64]
  [macro-name-id : i64]) : InternMacroDefinitionIdentity
  (InternMacroDefinitionIdentity
    (intern-structural-key-raw
      (intern-structural-session-key
        handle
        (ci.intern-structural-kind-macro-definition)
        definition-module-id
        0
        macro-name-id))))

(define (intern-structural-session-macro-definition-record
  [handle : InternStructuralSessionHandle]
  [identity : InternMacroDefinitionIdentity]) : InternMaybeMacroDefinitionRecord
  (let
    [key : InternStructuralKey
      (InternStructuralKey (intern-macro-definition-identity-raw identity))]
    (if (not (intern-structural-session-key-owned? handle key))
      InternMaybeMacroDefinitionRecord.No
      (let
        [session : ci.InternSourceNameSession
          (intern-structural-session-handle-session handle)]
        [table : ci.InternStructuralTable
          (array-ref session.structural-table-cell 0)]
        [index : i64 (intern-structural-session-key-index key)]
        (if (not
          (=
            (cast (array-ref table.kinds index) : i64)
            (ci.intern-structural-kind-macro-definition)))
          InternMaybeMacroDefinitionRecord.No
          (InternMaybeMacroDefinitionRecord.Some
            (InternMacroDefinitionRecord
              (array-ref table.lefts index)
              (array-ref table.rights index))))))))

(define (intern-structural-session-macro-definition-record-for-raw
  [handle : InternStructuralSessionHandle]
  [raw : i64]) : InternMaybeMacroDefinitionRecord
  (if (< raw (ci.intern-structural-key-base))
    InternMaybeMacroDefinitionRecord.No
    (intern-structural-session-macro-definition-record
      handle
      (InternMacroDefinitionIdentity raw))))

(define (intern-macro-global-role-code [role : InternMacroGlobalRole]) : i64
  (match role
    [(InternMacroGlobalRole.Legacy) 0]
    [(InternMacroGlobalRole.Context) 1]))

(define (intern-structural-session-macro-global-identity
  [handle : InternStructuralSessionHandle]
  [role : InternMacroGlobalRole]
  [definition-module-id : i64]
  [source-name-id : i64]) : InternMacroGlobalIdentity
  (InternMacroGlobalIdentity
    (intern-structural-key-raw
      (intern-structural-session-key
        handle
        (ci.intern-structural-kind-macro-global)
        (intern-macro-global-role-code role)
        definition-module-id
        source-name-id))))

(define (intern-structural-session-macro-global-record
  [handle : InternStructuralSessionHandle]
  [identity : InternMacroGlobalIdentity]) : InternMaybeMacroGlobalRecord
  (let
    [key : InternStructuralKey
      (InternStructuralKey (intern-macro-global-identity-raw identity))]
    (if (not (intern-structural-session-key-owned? handle key))
      InternMaybeMacroGlobalRecord.No
      (let
        [session : ci.InternSourceNameSession
          (intern-structural-session-handle-session handle)]
        [table : ci.InternStructuralTable
          (array-ref session.structural-table-cell 0)]
        [index : i64 (intern-structural-session-key-index key)]
        [kind : i64 (cast (array-ref table.kinds index) : i64)]
        [role : i64 (array-ref table.lefts index)]
        (if (not (= kind (ci.intern-structural-kind-macro-global)))
          InternMaybeMacroGlobalRecord.No
          (cond
            [(= role 0)
              (InternMaybeMacroGlobalRecord.Some
                (InternMacroGlobalRecord
                  InternMacroGlobalRole.Legacy
                  (array-ref table.middles index)
                  (array-ref table.rights index)))]
            [(= role 1)
              (InternMaybeMacroGlobalRecord.Some
                (InternMacroGlobalRecord
                  InternMacroGlobalRole.Context
                  (array-ref table.middles index)
                  (array-ref table.rights index)))]
            [else InternMaybeMacroGlobalRecord.No]))))))

(define (intern-structural-session-macro-global-record-for-raw
  [handle : InternStructuralSessionHandle]
  [raw : i64]) : InternMaybeMacroGlobalRecord
  (if (< raw (ci.intern-structural-key-base))
    InternMaybeMacroGlobalRecord.No
    (intern-structural-session-macro-global-record
      handle
      (InternMacroGlobalIdentity raw))))

(define (intern-structural-session-macro-local-identity
  [handle : InternStructuralSessionHandle]
  [macro-definition : InternMacroDefinitionIdentity]
  [lexical-depth : i64]
  [source-name-id : i64]) : InternMacroLocalIdentity
  (if (or
    (< lexical-depth 0)
    (match (intern-structural-session-macro-definition-record
      handle
      macro-definition)
      [(InternMaybeMacroDefinitionRecord.No) true]
      [(InternMaybeMacroDefinitionRecord.Some _) false]))
    (ci.tl_oob_abort)
    (InternMacroLocalIdentity
      (intern-structural-key-raw
        (intern-structural-session-key
          handle
          (ci.intern-structural-kind-macro-local)
          (intern-macro-definition-identity-raw macro-definition)
          lexical-depth
          source-name-id)))))

(define (intern-structural-session-macro-local-record
  [handle : InternStructuralSessionHandle]
  [identity : InternMacroLocalIdentity]) : InternMaybeMacroLocalRecord
  (let
    [key : InternStructuralKey
      (InternStructuralKey (intern-macro-local-identity-raw identity))]
    (if (not (intern-structural-session-key-owned? handle key))
      InternMaybeMacroLocalRecord.No
      (let
        [session : ci.InternSourceNameSession
          (intern-structural-session-handle-session handle)]
        [table : ci.InternStructuralTable
          (array-ref session.structural-table-cell 0)]
        [index : i64 (intern-structural-session-key-index key)]
        [kind : i64 (cast (array-ref table.kinds index) : i64)]
        [definition : InternMacroDefinitionIdentity
          (InternMacroDefinitionIdentity (array-ref table.lefts index))]
        (if (or
          (not (= kind (ci.intern-structural-kind-macro-local)))
          (match (intern-structural-session-macro-definition-record
            handle
            definition)
            [(InternMaybeMacroDefinitionRecord.No) true]
            [(InternMaybeMacroDefinitionRecord.Some _) false]))
          InternMaybeMacroLocalRecord.No
          (InternMaybeMacroLocalRecord.Some
            (InternMacroLocalRecord
              definition
              (array-ref table.middles index)
              (array-ref table.rights index))))))))

(define (intern-structural-session-macro-local-record-for-raw
  [handle : InternStructuralSessionHandle]
  [raw : i64]) : InternMaybeMacroLocalRecord
  (if (< raw (ci.intern-structural-key-base))
    InternMaybeMacroLocalRecord.No
    (intern-structural-session-macro-local-record
      handle
      (InternMacroLocalIdentity raw))))

;; Render boundary for mixed source/syntax ids. Arithmetic structural families
;; remain self-describing through compiler_intern; table-backed macro identities
;; must prove ownership in the explicit session before exposing their source
;; spelling. Unknown, stale, and wrong-owner handles remain total.
(define (intern-structural-session-syntax-source-name-id-or
  [handle : InternStructuralSessionHandle]
  [raw : i64]
  [fallback : i64]) : i64
  (let
    [direct : i64 (ci.intern-syntax-source-name-id-or raw -1)]
    (if (>= direct 0)
      direct
      (match (intern-structural-session-macro-global-record-for-raw handle raw)
        [(InternMaybeMacroGlobalRecord.Some record) record.source-name-id]
        [(InternMaybeMacroGlobalRecord.No)
          (match (intern-structural-session-macro-local-record-for-raw
            handle
            raw)
            [(InternMaybeMacroLocalRecord.Some record) record.source-name-id]
            [(InternMaybeMacroLocalRecord.No) fallback])]))))

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