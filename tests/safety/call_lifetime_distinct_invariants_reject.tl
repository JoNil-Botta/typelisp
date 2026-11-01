(defstruct RefBox
  (:lifetimes t)
  (value (& t i64)))

(define (put-pair
  [value : (& t i64)]
  [first : (&mut r (RefBox t))]
  [second : (&mut s (RefBox t))]) : i64
  (set! first.value value)
  (set! second.value value)
  (+ (deref first.value) (deref second.value)))

(define (main) : i64
  (let
    [outer : i64 7]
    [first (RefBox (& outer))]
    [inner : i64 8]
    [second (RefBox (& inner))]
    (put-pair (& outer) (&mut first) (&mut second))
    0))