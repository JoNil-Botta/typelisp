;; A stack reference cannot escape either, even through an alias inside an
;; arena and an elided-lifetime mutable parameter.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [p : (& r i64)] [b : (&mut (RefBox r))]) : i64
  (with-arena
    q
    (let
      [x : i64 30]
      [alias (& x)]
      (set! b.value alias)
      (deref p))))

(define (main) : i64
  0)