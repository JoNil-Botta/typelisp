;: Raw pointers do not become safe mutable places through replace!.
(define (replace-raw [value : (Ptr i64)]) : i64
  (replace! (deref value) 1))

(define (main) : i64
  42)