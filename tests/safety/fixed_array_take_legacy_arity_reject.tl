;: The public spelling has no compatibility liveness-bitmap operand.
(define (main) : i64
  (let
    [items : (Array i64 1) (array 7)]
    [live : (Array bool 1) (array true)]
    (array-take! items live 0)))