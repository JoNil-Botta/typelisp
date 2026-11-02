;; A reference to the shadowing local cannot be stored outside its scope.
(define (main) : i64
  (let
    [outer : i64 42]
    [saved (& outer)]
    (let
      [program : i64 0]
      (set! saved (& program program)))
    (deref saved)))