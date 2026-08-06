;: A mutable raw pointer is invariant through its referent.
(define (main [value : (MutPtr (& outer i64))]) : i64
  (let
    [inner : i64 1]
    [changed : (MutPtr (& inner i64)) value]
    0))