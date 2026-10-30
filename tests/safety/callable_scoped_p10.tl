(define (main [callback : (-> (& outer i64) i64)]) : i64
  (let
    [inner : i64 1]
    [too-narrow : (-> (& inner i64) i64) callback]
    [later : i64 2]
    (too-narrow (& later))))