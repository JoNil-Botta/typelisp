;: A reborrow of the `&mut` a holder stores, reached through `(&mut o ...)`,
;: lives no longer than `o` (Rust's supporting prefixes, #8449). Typing it with
;: the stored `i` let `inner` hand out the holder's exclusive reference while
;: the holder can still use it: run, `rb.value` would read `p.r` after the
;: write.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(defstruct Holder
  (:lifetimes i a)
  (m (&mut i (RefBox a))))

(defstruct Pair
  (l i64)
  (r i64))

(define (inner [h : (&mut o (Holder i a))]) : (&mut i (RefBox a))
  (&mut (deref h.m)))

(define (main) : i64
  (let
    [p : Pair (Pair 1 2)]
    [rb : (RefBox p) (RefBox (& p.l))]
    [holder : (Holder rb p) (Holder (&mut rb))]
    (let
      [m (inner (&mut holder))]
      (set! (deref m).value (& p.r)))
    (set! p.r 9)
    (deref rb.value)))