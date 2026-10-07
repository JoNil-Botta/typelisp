;; Operand capture typechecks each binding-clause initializer of a macro such
;; as `for`. The clause list was built through the context's pool cells, which
;; the global pushers used by that check did not see, so a fresh `slice-view`
;; Slice type took an id already in use and reflecting the source type
;; recursed until the checker overflowed its stack. `main` returns 42 only when
;; every source shape checks and sums correctly.
(defstruct Seq
  (slots (__tl_dyn-array i64))
  (len i64))

(define (sum-struct-slots-view [seq : (& seq Seq)]) : i64
  (let
    [total : i64 0]
    (for [item (slice-view seq.slots 0 seq.len)]
      (set! total (+ total (deref item))))
    total))

(define (sum-array-view [items : (& items (Array i64 4))]) : i64
  (let
    [total : i64 0]
    (for [item (slice-view items 0 2)]
      (set! total (+ total (deref item))))
    total))

(define (sum-dyn-array-view [items : (& items (__tl_dyn-array i64))]) : i64
  (let
    [total : i64 0]
    (for [item (slice-view items 0 2)]
      (set! total (+ total (deref item))))
    total))

(define (sum-owned-dyn-array-view [items : (__tl_dyn-array i64)]) : i64
  (let
    [total : i64 0]
    (for [item (slice-view items 0 2)]
      (set! total (+ total (deref item))))
    total))

(define (main) : i64
  (let
    [slots : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    [items : (Array i64 4) (array 5 6 7 8)]
    [dyn-items : (__tl_dyn-array i64) (__tl_make-array i64 3)]
    [owned-items : (__tl_dyn-array i64) (__tl_make-array i64 3)]
    (set! (array-ref slots 0) 1)
    (set! (array-ref slots 1) 2)
    (set! (array-ref slots 2) 3)
    (set! (array-ref slots 3) 4)
    (set! (array-ref dyn-items 0) 10)
    (set! (array-ref dyn-items 1) 20)
    (set! (array-ref owned-items 0) 100)
    (set! (array-ref owned-items 1) 200)
    (let
      [seq : Seq (Seq slots 4)]
      (cond
        [(not (= (sum-struct-slots-view (& seq)) 10)) 1]
        [(not (= (sum-array-view (& items)) 11)) 2]
        [(not (= (sum-dyn-array-view (& dyn-items)) 30)) 3]
        [(not (= (sum-owned-dyn-array-view owned-items) 300)) 4]
        [else 42]))))