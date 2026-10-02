(define (clear-second! [xs : (& (Slice i64))]) : unit
  (match xs
    [(slice _ & rest) (set! (array-ref rest 0) 0)]
    [(slice) unit]))

(define (main) : i64
  (let
    [items : (Array i64 2) (array 1 2)]
    (begin
      (clear-second! (& items))
      0)))