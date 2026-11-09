;; A value binder spelled like an enclosing arena does not let inner arena
;; data reach that arena (#9609, D-C216).
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
          (set! t.value local)))
      (deref t.value))))

(define (main) : i64
  0)