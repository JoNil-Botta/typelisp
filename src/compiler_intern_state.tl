;; compiler_intern_state.tl - explicit worker-owned intern table API.
;;
;; The authoritative table layout and lookup implementation live in
;; compiler_intern. This wrapper gives worker code an explicit owner without
;; duplicating that interner or installing it into the process-global state.
(import compiler_intern as ci)

(defstruct InternStructuralKey
  (value i64))

(defmacro (intern-state-structural-key-raw [key : Expr]) : i64
  `(__tl-project-field-name ,key "value"))

;; Nominal one-word structural view of the compile-intern session. Its address
;; points at compiler_intern's combined source-name/structural owner record.
(defstruct InternStructuralSessionHandle
  (address i64))

(define (intern-structural-session-handle-from-source-names
  [session : ci.InternSourceNameSessionHandle]) : InternStructuralSessionHandle
  (InternStructuralSessionHandle session.address))

(define (intern-structural-session-handle-from-state
  [state : ci.InternCompatState]) : InternStructuralSessionHandle
  (let
    [session : ci.InternSourceNameSessionHandle
      (ci.intern-source-name-session-handle-from-state state)]
    (intern-structural-session-handle-from-source-names session)))

;; Serial/test compatibility adapter. Production compile jobs derive their
;; capability from the explicit InternCompatState passed at the driver edge.
(define (intern-structural-session-capture-active-handle) : InternStructuralSessionHandle
  (let
    [session : ci.InternSourceNameSessionHandle
      (ci.intern-source-name-session-capture-active-handle)]
    (intern-structural-session-handle-from-source-names session)))

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

(define (intern-structural-session-handle-owned-by-state?
  [handle : InternStructuralSessionHandle]
  [state : ci.InternCompatState]) : bool
  (if (not (intern-structural-session-valid? handle))
    false
    (let
      [session : ci.InternSourceNameSession
        (intern-structural-session-handle-session handle)]
      (and
        (= session.table-id (ci.intern-compat-state-table-id state))
        (= session.reset-generation (ci.intern-compat-state-generation state))
        (=
          session.structural-owner
          (__tl-project-field (array-ref state.structural-table-cell 0) owner))))))

(define (intern-structural-session-same-owner?
  [left : InternStructuralSessionHandle]
  [right : InternStructuralSessionHandle]) : bool
  (if (or
    (not (intern-structural-session-valid? left))
    (not (intern-structural-session-valid? right)))
    false
    (let
      [left-session : ci.InternSourceNameSession
        (intern-structural-session-handle-session left)]
      [right-session : ci.InternSourceNameSession
        (intern-structural-session-handle-session right)]
      (and
        (= left-session.table-id right-session.table-id)
        (= left-session.reset-generation right-session.reset-generation)
        (= left-session.structural-owner right-session.structural-owner)))))

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
        ;; During the compatibility migration, an explicitly owned session can
        ;; also be the installed owner. Keep that owner's legacy scalar/address
        ;; snapshot coherent without touching an unrelated installed table.
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
      [raw : i64 (intern-state-structural-key-raw key)]
      [prefix : i64
        (+
          (ci.intern-structural-key-base)
          (* session.structural-owner (ci.intern-structural-key-owner-stride)))]
      [encoded-index : i64 (- raw prefix)]
      (and (> encoded-index 0) (<= encoded-index table.len)))))

(define (intern-structural-session-key-index [key : InternStructuralKey]) : i64
  (-
    (bit-and
      (intern-state-structural-key-raw key)
      (ci.intern-structural-key-index-mask))
    1))

(define (intern-structural-session-key-kind
  [handle : InternStructuralSessionHandle]
  [key : InternStructuralKey]) : i64
  (if (intern-structural-session-key-owned? handle key)
    (let
      [session : ci.InternSourceNameSession
        (intern-structural-session-handle-session handle)]
      (cast
        (array-ref
          (__tl-project-field (array-ref session.structural-table-cell 0) kinds)
          (intern-structural-session-key-index key))
        : i64))
    (ci.tl_oob_abort)))

(define (intern-structural-session-key-left
  [handle : InternStructuralSessionHandle]
  [key : InternStructuralKey]) : i64
  (if (intern-structural-session-key-owned? handle key)
    (let
      [session : ci.InternSourceNameSession
        (intern-structural-session-handle-session handle)]
      (array-ref
        (__tl-project-field (array-ref session.structural-table-cell 0) lefts)
        (intern-structural-session-key-index key)))
    (ci.tl_oob_abort)))

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

(define (intern-structural-session-key-right
  [handle : InternStructuralSessionHandle]
  [key : InternStructuralKey]) : i64
  (if (intern-structural-session-key-owned? handle key)
    (let
      [session : ci.InternSourceNameSession
        (intern-structural-session-handle-session handle)]
      (array-ref
        (__tl-project-field (array-ref session.structural-table-cell 0) rights)
        (intern-structural-session-key-index key)))
    (ci.tl_oob_abort)))

(defstruct InternState
  (compat ci.InternCompatState))

(define (intern-state-new) : InternState
  (InternState (ci.intern-compat-state-new)))

(define (intern-state-pool-len [state : InternState]) : i64
  (ci.intern-compat-state-pool-len state.compat))

(define (intern-state-generation [state : InternState]) : i64
  (ci.intern-compat-state-generation state.compat))

(define (intern-state-reset! [state : InternState]) : unit
  (ci.intern-compat-state-reset! state.compat))

(define (intern-state-reset-to! [state : InternState] [mark : i64]) : unit
  (ci.intern-compat-state-reset-to! state.compat mark))

(define (intern-state-intern [state : InternState] [name : String]) : i64
  (ci.intern-compat-state-intern state.compat name))

(define (intern-state-lookup [state : InternState] [name : String]) : ci.InternLookup
  (ci.intern-compat-state-lookup state.compat name))

(define (intern-state-str [state : InternState] [id : i64]) : String
  (ci.intern-compat-state-str state.compat id))

(define (intern-state-structural-key
  [state : InternState]
  [kind : i64]
  [left-id : i64]
  [middle-id : i64]
  [right-id : i64]) : InternStructuralKey
  (let
    [compat : ci.InternCompatState state.compat]
    [raw : i64
      (ci.intern-structural-table-intern
        compat.structural-table-cell
        (ci.intern-compat-state-persistent-arena compat)
        kind
        left-id
        middle-id
        right-id)]
    (begin
      (if (=
        (ci.intern-active-table-id)
        (ci.intern-compat-state-table-id compat))
        (ci.intern-active-structural-sync! compat.structural-table-cell)
        unit)
      (InternStructuralKey raw))))

(define (intern-state-composite-pair-key
  [state : InternState]
  [left-id : i64]
  [right-id : i64]) : InternStructuralKey
  (intern-state-structural-key
    state
    (ci.intern-structural-kind-pair)
    left-id
    0
    right-id))

(define (intern-state-composite-triple-key
  [state : InternState]
  [left-id : i64]
  [middle-id : i64]
  [right-id : i64]) : InternStructuralKey
  (intern-state-structural-key
    state
    (ci.intern-structural-kind-triple)
    left-id
    middle-id
    right-id))

(define (intern-state-structural-key-owned?
  [state : InternState]
  [key : InternStructuralKey]) : bool
  (let
    [table : ci.InternStructuralTable
      (array-ref state.compat.structural-table-cell 0)]
    [raw : i64 (intern-state-structural-key-raw key)]
    [prefix : i64
      (+
        (ci.intern-structural-key-base)
        (* table.owner (ci.intern-structural-key-owner-stride)))]
    [encoded-index : i64 (- raw prefix)]
    (and (> encoded-index 0) (<= encoded-index table.len))))

(define (intern-state-structural-key-index [key : InternStructuralKey]) : i64
  (-
    (bit-and
      (intern-state-structural-key-raw key)
      (ci.intern-structural-key-index-mask))
    1))

(define (intern-state-structural-key-kind
  [state : InternState]
  [key : InternStructuralKey]) : i64
  (if (intern-state-structural-key-owned? state key)
    (cast
      (array-ref
        (__tl-project-field
          (array-ref state.compat.structural-table-cell 0)
          kinds)
        (intern-state-structural-key-index key))
      : i64)
    (ci.tl_oob_abort)))

(define (intern-state-structural-key-left
  [state : InternState]
  [key : InternStructuralKey]) : i64
  (if (intern-state-structural-key-owned? state key)
    (array-ref
      (__tl-project-field
        (array-ref state.compat.structural-table-cell 0)
        lefts)
      (intern-state-structural-key-index key))
    (ci.tl_oob_abort)))

(define (intern-state-structural-key-middle
  [state : InternState]
  [key : InternStructuralKey]) : i64
  (if (intern-state-structural-key-owned? state key)
    (array-ref
      (__tl-project-field
        (array-ref state.compat.structural-table-cell 0)
        middles)
      (intern-state-structural-key-index key))
    (ci.tl_oob_abort)))

(define (intern-state-structural-key-right
  [state : InternState]
  [key : InternStructuralKey]) : i64
  (if (intern-state-structural-key-owned? state key)
    (array-ref
      (__tl-project-field
        (array-ref state.compat.structural-table-cell 0)
        rights)
      (intern-state-structural-key-index key))
    (ci.tl_oob_abort)))

(define (intern-state-structural-record-count [state : InternState]) : i64
  (__tl-project-field (array-ref state.compat.structural-table-cell 0) len))

(define (intern-state-structural-record-slot-bytes) : i64
  (ci.intern-structural-record-slot-bytes))

(define (intern-state-structural-record-capacity [state : InternState]) : i64
  (array-length
    (__tl-project-field (array-ref state.compat.structural-table-cell 0) kinds)))

(define (intern-state-structural-record-bytes [state : InternState]) : i64
  (*
    (intern-state-structural-record-capacity state)
    (intern-state-structural-record-slot-bytes)))

(define (intern-state-structural-map-bytes [state : InternState]) : i64
  (*
    (array-length
      (__tl-project-field
        (array-ref state.compat.structural-table-cell 0)
        map-slots))
    8))

(define (intern-state-structural-cache-bytes [state : InternState]) : i64
  (*
    (array-length
      (__tl-project-field
        (array-ref state.compat.structural-table-cell 0)
        structural-cache-raws))
    8))

(define (intern-state-structural-allocated-bytes [state : InternState]) : i64
  (+
    (intern-state-structural-record-bytes state)
    (+
      (intern-state-structural-map-bytes state)
      (intern-state-structural-cache-bytes state))))

(define (intern-state-qualified? [state : InternState] [id : i64]) : bool
  (ci.intern-compat-state-qualified? state.compat id))

(define (intern-state-qualified-last-slash [state : InternState] [id : i64]) : i64
  (ci.intern-compat-state-qualified-last-slash state.compat id))

(define (intern-state-qualified-module-id [state : InternState] [id : i64]) : i64
  (ci.intern-compat-state-qualified-module-id state.compat id))

(define (intern-state-qualified-base-id [state : InternState] [id : i64]) : i64
  (ci.intern-compat-state-qualified-base-id state.compat id))

(define (intern-state-qualified-module [state : InternState] [id : i64]) : String
  (let
    [module-id : i64 (intern-state-qualified-module-id state id)]
    (if (< module-id 0)
      ""
      (intern-state-str state module-id))))

(define (intern-state-qualified-base [state : InternState] [id : i64]) : String
  (intern-state-str state (intern-state-qualified-base-id state id)))

(define (intern-state-qualified-metadata-case-ok?
  [state : InternState]
  [id : i64]
  [qualified : bool]
  [last-slash : i64]
  [module-name : String]
  [base-name : String]) : bool
  (and
    (= (intern-state-qualified-last-slash state id) last-slash)
    (= (intern-state-qualified? state id) qualified)
    (ci.intern-private-string-eq
      (intern-state-qualified-module state id)
      module-name)
    (ci.intern-private-string-eq
      (intern-state-qualified-base state id)
      base-name)))

(define (intern-state-structural-kind-tests-ok?) : bool
  (let
    [installed : ci.InternCompatState (ci.intern-compat-state-capture-active)]
    [state : InternState (intern-state-new)]
    ;; Allocate these owners consecutively. In the old layout, A/kind 3/index 0
    ;; was numerically identical to B/kind 1/index 0.
    [alias-a : InternState (intern-state-new)]
    [alias-b : InternState (intern-state-new)]
    [former-alias-a : InternStructuralKey
      (intern-state-structural-key
        alias-a
        (ci.intern-structural-kind-template-source)
        17
        0
        23)]
    [next-owner-pair : InternStructuralKey
      (intern-state-composite-pair-key alias-b 17 23)]
    [collision-a : InternStructuralKey
      (intern-state-structural-key
        state
        (ci.intern-structural-kind-arena-phase)
        300
        400
        1)]
    [collision-b : InternStructuralKey
      (intern-state-structural-key
        state
        (ci.intern-structural-kind-arena-phase)
        300
        400
        513)]
    [changed-component : InternStructuralKey
      (intern-state-structural-key
        state
        (ci.intern-structural-kind-arena-phase)
        102
        0
        303)]
    [kind : i64 (ci.intern-structural-kind-pair)]
    [previous-raw : i64 -1]
    [growth-index : i64 0]
    [ok : bool true]
    (begin
      (unless
        (=
          (__tl-project-field
            (array-ref alias-b.compat.structural-table-cell 0)
            owner)
          (+
            (__tl-project-field
              (array-ref alias-a.compat.structural-table-cell 0)
              owner)
            1))
        (set! ok false))
      (unless
        (not
          (=
            (intern-state-structural-key-raw former-alias-a)
            (intern-state-structural-key-raw next-owner-pair)))
        (set! ok false))
      (unless
        (=
          (intern-state-structural-key-kind alias-a former-alias-a)
          (ci.intern-structural-kind-template-source))
        (set! ok false))
      (unless
        (not (intern-state-structural-key-owned? alias-b former-alias-a))
        (set! ok false))
      (unless (not (ci.intern-structural-kind-valid? 0)) (set! ok false))
      (unless (not (ci.intern-structural-kind-valid? 256)) (set! ok false))
      (while (<= kind (ci.intern-structural-kind-arena-phase))
        (let
          [key : InternStructuralKey
            (intern-state-structural-key state kind 101 0 303)]
          [again : InternStructuralKey
            (intern-state-structural-key state kind 101 0 303)]
          [raw : i64 (intern-state-structural-key-raw key)]
          (begin
            (unless
              (intern-state-structural-key-owned? state key)
              (set! ok false))
            (unless
              (= (intern-state-structural-key-kind state key) kind)
              (set! ok false))
            (unless
              (= (intern-state-structural-key-left state key) 101)
              (set! ok false))
            (unless
              (= (intern-state-structural-key-middle state key) 0)
              (set! ok false))
            (unless
              (= (intern-state-structural-key-right state key) 303)
              (set! ok false))
            (unless
              (= raw (intern-state-structural-key-raw again))
              (set! ok false))
            (unless (not (= raw previous-raw)) (set! ok false))
            (set! previous-raw raw)
            (set! kind (+ kind 1)))))
      (unless
        (not
          (= previous-raw (intern-state-structural-key-raw changed-component)))
        (set! ok false))
      ;; The low nine hash bits are identical while the records and decoded
      ;; right components differ, forcing the initial 512-slot map to probe.
      (unless
        (=
          (bit-and
            (ci.intern-structural-hash
              (ci.intern-structural-kind-arena-phase)
              300
              400
              1)
            511)
          (bit-and
            (ci.intern-structural-hash
              (ci.intern-structural-kind-arena-phase)
              300
              400
              513)
            511))
        (set! ok false))
      (unless
        (not
          (=
            (intern-state-structural-key-raw collision-a)
            (intern-state-structural-key-raw collision-b)))
        (set! ok false))
      (unless
        (= (intern-state-structural-key-right state collision-a) 1)
        (set! ok false))
      (unless
        (= (intern-state-structural-key-right state collision-b) 513)
        (set! ok false))
      ;; Cycle all eight reserved kinds while forcing both record and map growth.
      (while (< growth-index 700)
        (let
          [growth-kind : i64
            (+
              (ci.intern-structural-kind-pair)
              (% growth-index (ci.intern-structural-kind-arena-phase)))]
          [key : InternStructuralKey
            (intern-state-structural-key
              state
              growth-kind
              (+ 1000 growth-index)
              (+ 2000 growth-index)
              (+ 3000 growth-index))]
          (begin
            (unless
              (= (intern-state-structural-key-kind state key) growth-kind)
              (set! ok false))
            (unless
              (=
                (intern-state-structural-key-middle state key)
                (+ 2000 growth-index))
              (set! ok false))
            (set! growth-index (+ growth-index 1)))))
      ;; The worker-facing session capability shares the same generalized
      ;; constructor and record lookup, rather than retaining a pair/triple
      ;; restriction behind the state wrapper.
      (let
        [handle : InternStructuralSessionHandle
          (intern-structural-session-handle-from-state state.compat)]
        [session-key : InternStructuralKey
          (intern-structural-session-key
            handle
            (ci.intern-structural-kind-macro-global)
            808
            909
            1001)]
        [state-key : InternStructuralKey
          (intern-state-structural-key
            state
            (ci.intern-structural-kind-macro-global)
            808
            909
            1001)]
        (begin
          (unless
            (=
              (intern-state-structural-key-raw session-key)
              (intern-state-structural-key-raw state-key))
            (set! ok false))
          (unless
            (=
              (intern-structural-session-key-kind handle session-key)
              (ci.intern-structural-kind-macro-global))
            (set! ok false))))
      (unless
        (>= (intern-state-structural-record-capacity state) 1024)
        (set! ok false))
      (unless
        (= (intern-state-structural-record-slot-bytes) 37)
        (set! ok false))
      (unless
        (=
          (intern-state-structural-cache-bytes state)
          (* (ci.intern-structural-cache-capacity) 8))
        (set! ok false))
      (unless
        (=
          (intern-state-structural-allocated-bytes state)
          (+
            (intern-state-structural-record-bytes state)
            (+
              (intern-state-structural-map-bytes state)
              (intern-state-structural-cache-bytes state))))
        (set! ok false))
      ;; A generic kind-1/2 record remains exactly the pair/triple compatibility
      ;; record after the explicit owner is installed; other kinds classify as
      ;; neither even when their index is zero.
      (ci.intern-compat-state-install! state.compat)
      (let
        [pair-key : InternStructuralKey
          (intern-state-structural-key
            state
            (ci.intern-structural-kind-pair)
            101
            0
            303)]
        [triple-key : InternStructuralKey
          (intern-state-structural-key
            state
            (ci.intern-structural-kind-triple)
            101
            0
            303)]
        (begin
          (unless
            (=
              (intern-state-structural-key-raw pair-key)
              (ci.intern-composite-pair-id 101 303))
            (set! ok false))
          (unless
            (=
              (intern-state-structural-key-raw triple-key)
              (ci.intern-composite-triple-id 101 0 303))
            (set! ok false))
          (unless
            (ci.intern-composite-pair-id?
              (intern-state-structural-key-raw pair-key))
            (set! ok false))
          (unless
            (ci.intern-composite-triple-id?
              (intern-state-structural-key-raw triple-key))
            (set! ok false))
          (unless
            (not
              (ci.intern-composite-triple-id?
                (intern-state-structural-key-raw pair-key)))
            (set! ok false))))
      (ci.intern-compat-state-install! alias-a.compat)
      (unless
        (not
          (ci.intern-composite-pair-id?
            (intern-state-structural-key-raw former-alias-a)))
        (set! ok false))
      (unless
        (not
          (ci.intern-composite-triple-id?
            (intern-state-structural-key-raw former-alias-a)))
        (set! ok false))
      (let
        [stale-alias : InternStructuralKey former-alias-a]
        (begin
          (intern-state-reset-to! alias-a 0)
          (unless
            (not (intern-state-structural-key-owned? alias-a stale-alias))
            (set! ok false))
          (unless
            (= (intern-state-structural-record-count alias-a) 0)
            (set! ok false))))
      (let
        [stale-grown : InternStructuralKey collision-a]
        (begin
          (intern-state-reset! state)
          (unless
            (not (intern-state-structural-key-owned? state stale-grown))
            (set! ok false))
          (unless
            (= (intern-state-structural-record-count state) 0)
            (set! ok false))))
      (ci.intern-compat-state-install! installed)
      ok)))

(define (intern-state-isolation-tests-ok?) : bool
  (let
    [installed-state : ci.InternCompatState
      (ci.intern-compat-state-capture-active)]
    [state-a : InternState (intern-state-new)]
    [state-b : InternState (intern-state-new)]
    [a-alpha : i64 (intern-state-intern state-a "alpha")]
    [b-bravo : i64 (intern-state-intern state-b "bravo")]
    [a-qualified : i64 (intern-state-intern state-a "pkg/name")]
    [b-alpha : i64 (intern-state-intern state-b "alpha")]
    [b-mark : i64 (intern-state-pool-len state-b)]
    [_b-drop : i64 (intern-state-intern state-b "drop")]
    [a-generation : i64 (intern-state-generation state-a)]
    [b-generation : i64 (intern-state-generation state-b)]
    [a-pair : InternStructuralKey
      (intern-state-composite-pair-key state-a 131073 262147)]
    [a-pair-again : InternStructuralKey
      (intern-state-composite-pair-key state-a 131073 262147)]
    [b-pair : InternStructuralKey
      (intern-state-composite-pair-key state-b 131073 262147)]
    [session-a : InternStructuralSessionHandle
      (intern-structural-session-handle-from-state state-a.compat)]
    [session-b : InternStructuralSessionHandle
      (intern-structural-session-handle-from-state state-b.compat)]
    [ok : bool true]
    (begin
      (unless (intern-state-structural-kind-tests-ok?) (set! ok false))
      (unless
        (= (comptime (size-of (type InternStructuralKey))) 8)
        (set! ok false))
      (unless
        (= (comptime (size-of (type InternStructuralSessionHandle))) 8)
        (set! ok false))
      (unless (= a-alpha 0) (set! ok false))
      (unless (= b-bravo 0) (set! ok false))
      (unless (= b-alpha 1) (set! ok false))
      (unless
        (=
          (intern-state-structural-key-raw a-pair)
          (intern-state-structural-key-raw a-pair-again))
        (set! ok false))
      (unless
        (= (intern-state-structural-record-count state-a) 1)
        (set! ok false))
      (unless
        (= (intern-state-structural-record-count state-b) 1)
        (set! ok false))
      (unless
        (intern-state-structural-key-owned? state-a a-pair)
        (set! ok false))
      (unless
        (not (intern-state-structural-key-owned? state-b a-pair))
        (set! ok false))
      (unless
        (intern-state-structural-key-owned? state-b b-pair)
        (set! ok false))
      (unless
        (= (intern-state-structural-key-left state-a a-pair) 131073)
        (set! ok false))
      (unless
        (= (intern-state-structural-key-right state-a a-pair) 262147)
        (set! ok false))
      ;; Make B the compatibility-global owner, then grow and decode A only
      ;; through its explicit structural session. Equal record indexes and
      ;; components in the two states must remain owner-distinct.
      (ci.intern-compat-state-install! state-b.compat)
      (let
        [session-a-pair : InternStructuralKey
          (intern-structural-session-composite-pair-key session-a 131073 262147)]
        [session-b-pair : InternStructuralKey
          (intern-structural-session-composite-pair-key session-b 131073 262147)]
        (begin
          (unless
            (=
              (intern-state-structural-key-raw session-a-pair)
              (intern-state-structural-key-raw a-pair))
            (set! ok false))
          (unless
            (=
              (intern-state-structural-key-raw session-b-pair)
              (intern-state-structural-key-raw b-pair))
            (set! ok false))
          (unless
            (not
              (=
                (intern-state-structural-key-raw session-a-pair)
                (intern-state-structural-key-raw session-b-pair)))
            (set! ok false))
          (unless
            (intern-structural-session-key-owned? session-a session-a-pair)
            (set! ok false))
          (unless
            (not
              (intern-structural-session-key-owned? session-b session-a-pair))
            (set! ok false))
          (unless
            (=
              (intern-structural-session-key-kind session-a session-a-pair)
              (ci.intern-structural-kind-pair))
            (set! ok false))))
      (let
        [index : i64 0]
        (while (< index 700)
          (let
            [key : InternStructuralKey
              (intern-structural-session-composite-triple-key
                session-a
                (+ 131073 index)
                (+ 262147 index)
                (+ 524309 index))]
            (begin
              (unless
                (intern-structural-session-key-owned? session-a key)
                (set! ok false))
              (unless
                (=
                  (intern-structural-session-key-middle session-a key)
                  (+ 262147 index))
                (set! ok false))
              (set! index (+ index 1))))))
      (unless
        (=
          (ci.intern-active-table-id)
          (ci.intern-compat-state-table-id state-b.compat))
        (set! ok false))
      (ci.intern-compat-state-install! installed-state)
      (unless
        (= (intern-state-structural-record-count state-a) 701)
        (set! ok false))
      (unless
        (> (intern-state-structural-allocated-bytes state-a) 0)
        (set! ok false))
      (unless
        (intern-state-qualified-metadata-case-ok?
          state-a
          a-qualified
          true
          3
          "pkg"
          "name")
        (set! ok false))
      (intern-state-reset! state-a)
      (unless
        (not (intern-structural-session-valid? session-a))
        (set! ok false))
      (unless
        (not (intern-state-structural-key-owned? state-a a-pair))
        (set! ok false))
      (unless
        (= (intern-state-structural-record-count state-a) 0)
        (set! ok false))
      (unless
        (not (= (intern-state-generation state-a) a-generation))
        (set! ok false))
      (unless
        (= (intern-state-generation state-b) b-generation)
        (set! ok false))
      (unless (= (intern-state-pool-len state-a) 0) (set! ok false))
      (unless (= (intern-state-intern state-a "alpha") 0) (set! ok false))
      (unless (= (intern-state-pool-len state-b) 3) (set! ok false))
      (unless
        (ci.intern-private-string-eq (intern-state-str state-b b-bravo) "bravo")
        (set! ok false))
      (match (intern-state-lookup state-b "alpha")
        [(ci.InternLookupFound found)
          (unless (= found b-alpha) (set! ok false))]
        [(ci.InternLookupMissing) (set! ok false)])
      (match (intern-state-lookup state-b "drop")
        [(ci.InternLookupFound found) (unless (= found b-mark) (set! ok false))]
        [(ci.InternLookupMissing) (set! ok false)])
      (intern-state-reset-to! state-b b-mark)
      (unless
        (not (intern-structural-session-valid? session-b))
        (set! ok false))
      (unless (= (intern-state-pool-len state-b) b-mark) (set! ok false))
      (match (intern-state-lookup state-b "drop")
        [(ci.InternLookupMissing) unit]
        [(ci.InternLookupFound _) (set! ok false)])
      (unless (= (intern-state-intern state-b "drop") b-mark) (set! ok false))
      (unless (= (intern-state-pool-len state-a) 1) (set! ok false))
      (unless
        (ci.intern-private-string-eq (intern-state-str state-a 0) "alpha")
        (set! ok false))
      ok)))