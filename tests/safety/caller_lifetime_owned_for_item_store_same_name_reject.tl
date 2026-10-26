;; A `for` item spelled like a caller lifetime owns its storage, even when a
;; top-level name has the same spelling.
(defstruct RefBox
  (:lifetimes t)
  (value (& t i64)))

(define (t) : i64
  1)

(define (store [b : (&mut t (RefBox t))]) : unit
  (let
    [items : (Array i64 3) (make-array i64 3)]
    (for [t items]
      ; Must fail: `(& t)` borrows the loop item.
      (set! b.value (& t)))))

(define (main) : i64
  0)