;; A value binder spelled like an enclosing arena does not let inner arena
;; data reach that arena (#9609, D-C216). An annotation under the binder
;; cannot relabel the data.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (leak) : i64
  (with-arena
    outer
    (let
      [ox : (Box i64) (box 7)]
      [t : (RefBox outer) (RefBox (& outer (deref ox)))]
      (with-arena
        inner
        (let
          [x : (Box i64) (box 5)]
          [local : (& inner i64) (& inner (deref x))]
          [outer : i64 1]
          [z : (& outer i64) local]
          (set! t.value z)))
      (deref t.value))))

(define (main) : i64
  0)