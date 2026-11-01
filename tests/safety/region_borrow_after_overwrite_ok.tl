;: `hh` is given `&p.r` through `(&mut hh)`, then overwritten whole before
;: `p.r` is written. Its later reads and its later `(&mut hh)` reach only
;: loans of the new value: a reference made by a borrow holds its referent's
;: loans through the borrowed root, whose whole overwrite ends them, as in
;: Rust, where a borrow is a use of the borrowed variable (#8449).
(defstruct P
  (l i64)
  (r i64))

(defstruct Inner
  (:lifetimes a b)
  (x (& a i64))
  (y (& b i64)))

(define (set-y [o : (&mut (Inner a b))] [v : (& b i64)]) : unit
  (set! (deref o).y v))

(define (main) : i64
  (let
    [p : P (P 40 2)]
    [q : P (P 1 2)]
    [hh : (Inner q p) (Inner (& q.l) (& p.l))]
    (set-y (&mut hh) (& p.r))
    (set! hh (Inner (& q.r) (& p.l)))
    (set! p.r 9)
    (set-y (&mut hh) (& p.l))
    (+ (deref hh.y) (deref hh.x))))