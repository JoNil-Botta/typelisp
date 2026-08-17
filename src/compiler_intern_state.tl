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