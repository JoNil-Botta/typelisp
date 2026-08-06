;: &mut may shorten its outer borrow, but its referent type is invariant.
(define (main [value : (&mut owner (& outer i64))]) : i64
  (let
    [inner : i64 1]
    [changed : (&mut owner (& inner i64)) value]
    0))