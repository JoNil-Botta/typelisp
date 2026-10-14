;: A store through a `&mut` held in a box reaches what that reference points
;: to: `rb` holds `&p.r` afterwards, so writing `p.r` while `rb.value` is read
;: later conflicts (Rust E0506, #8449).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(defstruct Pair
  (l i64)
  (r i64))

(define (main) : i64
  (let
    [p : Pair (Pair 1 2)]
    [rb : (RefBox p) (RefBox (& p.l))]
    (let
      [held : (Box (&mut rb (RefBox p))) (box (&mut rb))]
      (set! (deref (deref held)).value (& p.r)))
    (set! p.r 9)
    (deref rb.value)))