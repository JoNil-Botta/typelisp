(defmacro (read-borrowed [place : Expr]) : Expr
  `(unsafe
    (deref (& ,place))))

(define (main) : i64
  (let
    [items : (Array i64 2) (array 10 42)]
    [idx : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of idx))]
    (read-borrowed (array-ref items (ptr-read p)))))