;: A `for` item of an array of references holds the array's loans: a reference
;: carried out of the loop through the item keeps its borrow live (#8449).
(defstruct P
  (l i64)
  (r i64))

(define (keep [view : (& p i64)]) : (& p i64)
  view)

(define (main) : i64
  (let
    [p : P (P 1 2)]
    [views : (Array (& p i64) 1) (array (& p.l))]
    [total : i64 0]
    (for [item views]
      (let
        [kept : (& p i64) (keep item)]
        (set! p.l 5)
        (set! total (+ total (deref kept)))))
    total))