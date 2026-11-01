;: A shared borrow of a slice element and a mutable reborrow of the slice it
;: lives in cannot be live at once: the callee could overwrite the element the
;: first argument still reads (aliasing `&` and `&mut`). The legacy checker
;: accepted this; the ownership graph rejects it (#8449).
(defstruct Cell
  (n i64)
  (name (Box i64)))

(define (both [a : (& Cell)] [b : (&mut (Slice Cell))]) : i64
  (set! (array-ref b 0) (Cell 7 (box 0)))
  (deref a).n)

(define (through-rest [xs : (&mut (Slice Cell))]) : i64
  (match xs
    [(slice & rest) (both (& (array-ref rest 0)) rest)]))

(define (main) : i64
  0)