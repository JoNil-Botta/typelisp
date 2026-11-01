;: A store into a box's contents through a field puts the loan in the box:
;: after the box moves, writing `p.r` while the stored reference is read later
;: conflicts (Rust E0506, #8449).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(defstruct Pair
  (l i64)
  (r i64))

(define (main) : i64
  (let
    [p : Pair (Pair 1 2)]
    [held : (Box (RefBox p)) (box (RefBox (& p.l)))]
    (set! (deref held).value (& p.r))
    (let
      [h2 held]
      (set! p.r 9)
      (deref (deref h2).value))))