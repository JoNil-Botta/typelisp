;: As `mir_reference_loop_reissue_borrowed_holder_reject`, but the holder is a
;: fresh binding each trip, so no earlier borrow outlives its write (#8449).
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
    [i : i64 0]
    [total : i64 0]
    (while (< i 4)
      (set! (array-ref (deref p).a 0) 7)
      (let
        [cur : (RefMut x) (RefMut (&mut (array-ref (deref p).a i)))]
        (set! total (+ total (peek (& cur)))))
      (set! i (+ i 1)))
    total))

(define (main) : i64
  (let
    [p : P (P (__tl_make-array i64 4) (__tl_make-array i64 1))]
    (+ (run (&mut p)) 35)))