(defstruct Callback
  (call (-> String)))

(define (main) : i64
  (let
    [owned : String "once"]
    [stored : Callback
      (Callback
        (lambda () : String
          owned))]
    0))