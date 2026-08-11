;: Moving a closure whose environment owns a String invalidates the source.
(import stdlib.string)

(define (main) : i64
  (let
    [owned : String "captured"]
    [f : (-> i64)
      (lambda () : i64
        (string.string-length owned))]
    [moved : (-> i64) f]
    (+ (moved) (f))))