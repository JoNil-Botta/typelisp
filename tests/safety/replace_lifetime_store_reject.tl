;: A shorter replacement reference cannot be stored into a longer-lived place.
(define (replace-reference
  [slot : (&mut slot-life (& long-life i64))]
  [replacement : (& short-life i64)]) : (& long-life i64)
  (replace! (deref slot) replacement))

(define (main) : i64
  42)