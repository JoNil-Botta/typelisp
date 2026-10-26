;; A reborrow of a holder's `&mut program` field through `(&mut Holder)` is
;; bounded by that path, not by `program`: returning it as `program` would
;; leave the holder and the result aliasing. Main 4e46ce356 accepts it.
(defstruct Pt
  (name String)
  (x i64))

(defstruct Holder
  (m (&mut program Pt)))

(define (steal [h : (&mut h Holder)]) : (&mut program Pt)
  (&mut (deref (deref h).m)))

(define (main) : i64
  42)