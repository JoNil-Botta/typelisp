(defmacro (addr-read [place : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-addr-of ,place))))

(define (main) : i64
  (let
    [items : (Array i64 2) (array 10 42)]
    [idx : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of idx))]
    (addr-read (array-ref items (ptr-read p)))))