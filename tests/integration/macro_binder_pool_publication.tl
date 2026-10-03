;; Macro expansion typechecks the binders that enclose a macro call (`let` and
;; `with` bindings, `match` scrutinees) so the call sees their types. Those
;; checks push type nodes through the global pushers, which the context's pool
;; cells did not observe, and the next transformer install rolled the globals
;; back over them. A parameter's type id was then reused: `when` under the
;; binder reported "field projection .slots requires struct, got bool", and a
;; `for` over an inferred view crashed the checker. `main` returns 42 only when
;; every binder shape checks and computes its value.
(defstruct Seq
  (slots (__tl_dyn-array i64))
  (len i64))

(defstruct Handle
  (id i64))

(define (close-handle [_handle : Handle]) : unit
  unit)

(define (let-binder-length [seq : (& seq Seq)]) : i64
  (let
    [view : (& seq (Slice i64)) (slice-view seq.slots 0 2)]
    [total : i64 0]
    (when true (set! total (array-length view)))
    total))

;; The view's type is inferred while expansion checks its binding.
(define (sum-inferred-view [seq : (& seq Seq)]) : i64
  (let
    [view (slice-view seq.slots 0 seq.len)]
    [total : i64 0]
    (for [item view] (set! total (+ total (deref item))))
    total))

(define (match-binder-length [seq : (& seq Seq)]) : i64
  (match (slice-view seq.slots 0 3)
    [view
      (when true unit)
      (array-length view)]))

(define (with-binder-length [seq : (& seq Seq)]) : i64
  (with
    ([handle (Handle (array-length (slice-view seq.slots 0 4))) close-handle])
    (unless false unit)
    handle.id))

(define (main) : i64
  (let
    [slots : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    (set! (array-ref slots 0) 1)
    (set! (array-ref slots 1) 2)
    (set! (array-ref slots 2) 3)
    (set! (array-ref slots 3) 4)
    (let
      [seq : Seq (Seq slots 4)]
      (cond
        [(not (= (let-binder-length (& seq)) 2)) 1]
        [(not (= (sum-inferred-view (& seq)) 10)) 2]
        [(not (= (match-binder-length (& seq)) 3)) 3]
        [(not (= (with-binder-length (& seq)) 4)) 4]
        [else 42]))))