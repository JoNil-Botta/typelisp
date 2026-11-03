;; A borrow of the shadowing local stored into caller storage is rejected as
;; on main (#9593).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [b : (&mut r (RefBox r))]) : unit
  (with-arena
    r
    (let
      [r : i64 1]
      (set! b.value (& r r)))))

(define (main) : i64
  0)