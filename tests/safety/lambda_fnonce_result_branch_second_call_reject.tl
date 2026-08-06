(define (main [flag : bool]) : String
  (let
    [owned : String "once"]
    [take : (-> bool String)
      (lambda ([choose : bool]) : String
        (if choose
          owned
          "other"))]
    [first : String (take flag)]
    (take flag)))