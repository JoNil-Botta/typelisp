;: The returned old reference retains the selected place's original lifetime.
(define (replace-reference
  [slot : (&mut source-life (& source-life i64))]
  [replacement : (& source-life i64)]) : (& source-life i64)
  (replace! (deref slot) replacement))

(define (main) : i64
  42)