;: `cur` borrows `p.a` again on every trip, while `prev` still holds the
;: previous trip's borrow and is read after `p.a[0]` is written (Rust E0506).
;: The loan stays live across the back edge while `prev` may hold it (#8449).
(defstruct P
  (a (__tl_dyn-array i64))
  (b (__tl_dyn-array i64)))

(define (read [view : (& v i64)]) : i64
  (deref view))

(define (main) : i64
  (let
    [p : P (P (__tl_make-array i64 4) (__tl_make-array i64 1))]
    [prev : (& p i64) (& (array-ref p.b 0))]
    [i : i64 0]
    [total : i64 0]
    (while (< i 4)
      (set! (array-ref p.a 0) 7)
      (let
        [cur : (& p i64) (& (array-ref p.a i))]
        (set! total (+ total (read prev)))
        (set! prev cur))
      (set! i (+ i 1)))
    total))