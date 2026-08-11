;: Normal body fallthrough reaches the next iteration.
(define (bad [run : bool] [text : String]) : unit
  (while run
    (let
      [taken : String text]
      unit)))