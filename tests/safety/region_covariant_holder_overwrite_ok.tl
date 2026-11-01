;: `hh.y` takes `&p.r`, `p.r` is written, then `hh` is overwritten whole
;: before its next read. `Inner`'s lifetimes are covariant (its fields are
;: shared references), so the new value takes none of the old value's loans
;: and the write conflicts with nothing still read, as in Rust (#8449).
(defstruct P
  (l i64)
  (r i64))

(defstruct Inner
  (:lifetimes a b)
  (x (& a i64))
  (y (& b i64)))

(define (main) : i64
  (let
    [p : P (P 40 2)]
    [q : P (P 1 2)]
    [hh : (Inner q p) (Inner (& q.l) (& p.l))]
    (set! hh.y (& p.r))
    (set! p.r 9)
    (set! hh (Inner (& q.r) (& p.l)))
    (+ (deref hh.y) (deref hh.x))))