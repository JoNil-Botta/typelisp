;: A shared borrow of an element of a mutable slice parameter cannot be live
;: across a mutable reborrow of that parameter (aliasing `&` and `&mut`); the
;: legacy checker accepted it (#8449).
(defstruct Cell
  (n i64)
  (name (Box i64)))

(define (both [a : (& Cell)] [b : (&mut (Slice Cell))]) : i64
  (set! (array-ref b 0) (Cell 7 (box 0)))
  (deref a).n)

(define (through-param [xs : (&mut (Slice Cell))]) : i64
  (both (& (array-ref xs 0)) xs))

(define (main) : i64
  0)