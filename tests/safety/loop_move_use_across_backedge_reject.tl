;: A use after a conditional first-iteration move remains reachable from the
;: loop backedge.
(define (bad [run : bool] [take : bool] [text : String]) : unit
  (while run
    (begin
      (if take
        (let
          [taken : String text]
          unit)
        unit)
      (let
        [again : String text]
        unit))))