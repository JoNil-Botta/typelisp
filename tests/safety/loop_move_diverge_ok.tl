(extern (stop-now) : never)

;: A direct call with a statically known `never` result has no iteration edge.
(define (move-then-diverge [run : bool] [text : String]) : String
  (begin
    (while run
      (let
        [taken : String text]
        (stop-now)))
    text))

(define (main) : i64
  0)