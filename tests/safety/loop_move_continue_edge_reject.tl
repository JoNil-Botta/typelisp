;: The move occurs before a branch whose continue arm can reach another
;: iteration; the returning sibling does not make that path safe.
(define (bad [run : bool] [leave : bool] [text : String]) : unit
  (while run
    (begin
      (let
        [taken : String text]
        unit)
      (if leave
        (return unit)
        (continue)))))