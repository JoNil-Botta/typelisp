;; A view returned by a call is shared even when the call borrowed its owner
;; mutably: only a view read through a path of `&mut` references is writable
;; (main 63b900cc8 accepts and loses the write, exit 77).
(defstruct Inner
  (n i64)
  (label String))

(defstruct Holder
  (inner Inner))

(define (inner-view [x : (&mut x Holder)]) : (in x Inner)
  x.inner)

(define (main) : i64
  (let
    [holder : Holder (Holder (Inner 1 "a"))]
    (let
      [view (inner-view (&mut holder))]
      (set! view.n (+ view.n 6)))
    (if (= holder.inner.n 7)
      42
      77)))