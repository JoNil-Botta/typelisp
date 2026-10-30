;: The callback owns outer, so coercion may instantiate it to the local inner.
;: The annotation fixes inner for later calls.
(define (main [callback : (-> (& outer i64) i64)]) : i64
  (let
    [inner : i64 1]
    [too-narrow : (-> (& inner i64) i64) callback]
    0))