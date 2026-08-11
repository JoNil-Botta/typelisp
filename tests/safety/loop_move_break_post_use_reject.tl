;: A break avoids the backedge, but its move state still reaches code after the
;: loop and must be joined with the zero-trip state.
(define (bad [run : bool] [text : String]) : String
  (begin
    (while run
      (let
        [taken : String text]
        (break)))
    text))