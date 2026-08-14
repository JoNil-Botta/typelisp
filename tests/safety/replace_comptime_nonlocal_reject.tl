;: Unsupported CTFE non-local storage rejects explicitly.
(define global-value : i64
  1)
(define value : i64
  (comptime (replace! global-value 3)))

(define (main) : i64
  value)