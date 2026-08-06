(defstruct Callback
  (call (-> String)))

(define (main) : i64
  (let
    [owned : String "once"]
    [take : (-> String)
      (lambda () : String
        owned)]
    [stored : Callback (Callback take)]
    0))