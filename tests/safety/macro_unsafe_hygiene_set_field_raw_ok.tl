(defstruct Holder
  (val i64))

(defmacro (assign [place : Expr] [value : Expr]) : Expr
  `(unsafe
    (set! ,place ,value)))

(define (main) : i64
  (let
    [h : Holder (Holder 0)]
    [raw : (MutPtr Holder)
      (unsafe
        (ptr-addr-of h))]
    (unsafe
      (assign (deref raw).val 42))
    h.val))