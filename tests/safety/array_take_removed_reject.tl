;: The removed public array-take! names its replace! migration.
(define (main) : i64
  (let
    [items : (Array i64 1) (array 7)]
    (array-take! items 0)))