;: A box holding a reference holds that reference's loan: the reference read
;: back out of it keeps the loan, so writing `pair.b` while it is used later
;: conflicts (Rust E0506, #8449).
(defstruct Pair
  (a i64)
  (b i64))

(define (main) : i64
  (let
    [pair : Pair (Pair 1 41)]
    [held : (Box (& pair i64)) (box (& pair.b))]
    [r : (& pair i64) (deref held)]
    (set! pair.b 5)
    (deref r)))