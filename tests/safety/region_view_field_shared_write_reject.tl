;; A field returned as `(in x T)` through a shared reference is read under
;; `x`, so it stays shared: a mutable borrow of it is a write through `&`
;; (main 63b900cc8 accepts and exits 99, the element changes in the owner).
(import stdlib.vector)
(import (vector.vector i64) as ivec)

(defstruct Holder
  (items ivec.Vec))

(define (items-view [x : (& x Holder)]) : (in x ivec.Vec)
  x.items)

(define (sneak [x : (& x Holder)]) : unit
  (let
    [view (items-view x)]
    (ivec.set-ref! (&mut view) 0 9)))

(define (main) : i64
  (let
    [holder : Holder (Holder (ivec.new))]
    (ivec.push-ref! (&mut holder.items) 1)
    (sneak (& holder))
    (if (= (ivec.get (& holder.items) 0 -1) 1)
      42
      99)))