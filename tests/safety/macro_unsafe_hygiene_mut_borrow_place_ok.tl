(defmacro (store-42 [place : Expr]) : Expr
  `(unsafe
    (let
      [r (&mut ,place)]
      (set! (deref r) 42)
      42)))

(define (main) : i64
  (let
    [items : (Array i64 2) (array 10 20)]
    [idx : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of idx))]
    (unsafe
      (store-42 (array-ref items (ptr-read p))))))