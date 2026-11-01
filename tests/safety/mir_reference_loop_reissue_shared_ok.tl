;: `prev` holds the previous trip's shared borrow of `p.a` while `cur` borrows
;: it again: the two shared issues coexist, and `p.a` is written only once
;: `prev` is no longer read (#8449).
(defstruct P
  (a (__tl_dyn-array i64))
  (b (__tl_dyn-array i64)))

(define (read [view : (& v i64)]) : i64
  (deref view))

(define (main) : i64
  (let
    [p : P (P (__tl_make-array i64 4) (__tl_make-array i64 1))]
    [i : i64 0]
    [total : i64 0]
    (set! (array-ref p.a 3) 7)
    (let
      [prev : (& p i64) (& (array-ref p.b 0))]
      (while (< i 4)
        (let
          [cur : (& p i64) (& (array-ref p.a i))]
          (set! total (+ total (read prev)))
          (set! prev cur))
        (set! i (+ i 1)))
      (set! total (+ total (read prev))))
    (set! (array-ref p.a 3) 35)
    (+ total (array-ref p.a 3))))