;: `prev` holds the previous trip's `&mut` borrow of `p.a[0]` and is read only
;: through a shared borrow of it, `(& prev)`, after `p.a[0]` is written and
;: borrowed again (Rust E0506/E0499). The borrowed holder keeps the loan live
;: (#8449).
(defstruct RefMut
  (:lifetimes a)
  (value (&mut a i64)))

(defstruct P
  (a (__tl_dyn-array i64))
  (b (__tl_dyn-array i64)))

(define (peek [b : (& s (RefMut v))]) : i64
  (deref (deref b).value))

(define (run [p : (&mut x P)]) : i64
  (let
    [prev : (RefMut x) (RefMut (&mut (array-ref (deref p).b 0)))]
    [i : i64 0]
    [total : i64 0]
    (while (< i 4)
      (set! (array-ref (deref p).a 0) 7)
      (let
        [cur : (RefMut x) (RefMut (&mut (array-ref (deref p).a i)))]
        (set! total (+ total (peek (& prev))))
        (set! prev cur))
      (set! i (+ i 1)))
    total))

(define (main) : i64
  (let
    [p : P (P (__tl_make-array i64 4) (__tl_make-array i64 1))]
    (run (&mut p))))