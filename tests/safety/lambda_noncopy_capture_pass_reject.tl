;: Passing a non-Copy closure through plain function type erases ownership.
(import stdlib.string)

(define (invoke [f : (-> i64)]) : i64
  (f))

(define (main) : i64
  (let
    [owned : String "captured"]
    [f : (-> i64)
      (lambda () : i64
        (string.string-length owned))]
    (invoke f)))