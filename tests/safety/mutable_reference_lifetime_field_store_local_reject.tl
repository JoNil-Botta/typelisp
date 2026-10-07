;; A borrow of a local cannot be stored through `&mut` into a field of a
;; caller-owned lifetime-parameterized struct (#8584).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

; Must fail: `x` dies when `store` returns, but the field lives for `a`.
(define (store [b : (&mut (RefBox a))]) : unit
  (let
    [x : i64 5]
    (set! b.value (& x))))

(define (main) : i64
  0)