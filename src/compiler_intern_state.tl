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
  ;; #6468 owns widening the raw handle beyond the current two non-overlapping
  ;; kind lanes. Keep this capability honest until that representation lands.
  (if (or
    (not (intern-structural-session-valid? handle))
    (and
      (not (= kind (ci.intern-structural-kind-pair)))
      (not (= kind (ci.intern-structural-kind-triple)))))
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
      [encoded-index : i64 (bit-and raw (ci.intern-structural-key-index-mask))]
      (and
        (>= raw (ci.intern-structural-key-base))
        (> encoded-index 0)
        (=
          (/
            (- raw (ci.intern-structural-key-base))
            (ci.intern-structural-key-owner-stride))
          session.structural-owner)
        (<= encoded-index table.len)))))

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
    [encoded-index : i64 (bit-and raw (ci.intern-structural-key-index-mask))]
    (and
      (>= raw (ci.intern-structural-key-base))
      (> encoded-index 0)
      (=
        (/
          (- raw (ci.intern-structural-key-base))
          (ci.intern-structural-key-owner-stride))
        table.owner)
      (<= encoded-index table.len))))

(define (intern-state-structural-key-index [key : InternStructuralKey]) : i64
  (-
    (bit-and
      (intern-state-structural-key-raw key)
      (ci.intern-structural-key-index-mask))
    1))

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

(define (intern-state-structural-allocated-bytes [state : InternState]) : i64
  (let
    [table : ci.InternStructuralTable
      (array-ref state.compat.structural-table-cell 0)]
    [records : i64 (array-length table.kinds)]
    [map-capacity : i64 (array-length table.map-slots)]
    [cache-capacity : i64 (array-length table.structural-cache-raws)]
    (+ (+ (* records 25) (* map-capacity 8)) (* cache-capacity 8))))

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