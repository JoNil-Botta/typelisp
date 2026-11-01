;; A `(&mut program T)` parameter takes only a `program` reference: a mutable
;; borrow of a local cannot be stored in a holder that outlives the local.
;; Main 4e46ce356 accepts it, and `bad` returns a dangling holder.
(defstruct Pt
  (name String)
  (x i64))

(defstruct Holder
  (m (&mut program Pt)))

(define (wrap [r : (&mut program Pt)]) : Holder
  (Holder r))

(define (bad) : Holder
  (let
    [p : Pt (Pt "a" 1)]
    (wrap (&mut p))))

(define (main) : i64
  42)