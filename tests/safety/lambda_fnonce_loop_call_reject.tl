(define (main [again : bool]) : unit
  (let
    [owned : String "once"]
    [take : (-> String)
      (lambda () : String
        owned)]
    (while again
      (let
        [result : String (take)]
        unit))))