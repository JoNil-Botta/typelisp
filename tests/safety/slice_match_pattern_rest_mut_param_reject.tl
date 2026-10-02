(define (fill! [xs : (&mut (Slice i64))]) : unit
  (set! (array-ref xs 0) 7))

(define (fill-tail! [xs : (& (Slice i64))]) : unit
  (match xs
    [(slice _ & rest) (fill! rest)]
    [(slice) unit]))

(define (main) : i64
  (let
    [items : (Array i64 2) (array 1 2)]
    (begin
      (fill-tail! (& items))
      0)))