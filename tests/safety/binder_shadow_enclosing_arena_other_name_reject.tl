;; Control: a binder of another name keeps the ordinary mismatch (#9609).
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
          [other : i64 1]
          (set! t.value local)))
      (deref t.value))))

(define (main) : i64
  0)