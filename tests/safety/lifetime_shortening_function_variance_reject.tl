;: Function parameters are contravariant: a callback accepting only the longer
;: reference cannot stand in for one that must accept the shortened reference.
(define (main [callback : (-> (& outer i64) i64)]) : i64
  (let
    [inner : i64 1]
    [too-narrow : (-> (& inner i64) i64) callback]
    0))