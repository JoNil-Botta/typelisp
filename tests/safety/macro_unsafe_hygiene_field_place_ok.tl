(defstruct Holder
  (val i64))

(defmacro (read-val [place : Expr]) : Expr
  `(unsafe
    (struct-get ,place val)))

(define (main) : i64
  (let
    [items : (Array Holder 2) (array (Holder 10) (Holder 42))]
    [idx : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of idx))]
    (unsafe
      (read-val (array-ref items (ptr-read p))))))