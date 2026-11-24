(defstruct Holder
  (val i64))

(defmacro (assign [place : Expr] [value : Expr]) : Expr
  `(unsafe
    (set! ,place ,value)))

(define (main) : i64
  (let
    [items : (Array Holder 2) (array (Holder 0) (Holder 0))]
    [idx : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of idx))]
    (unsafe
      (assign (array-ref items (ptr-read p)).val 42))
    (array-ref items 1).val))