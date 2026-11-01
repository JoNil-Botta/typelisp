;; Moving a closure local into another local moves its environment; the new
;; local is called, the moved-from one is not used again.
(import stdlib.string)

(define (main) : i64
  (let
    [owned : String "forty-two-characters-long-string-value!!!!"]
    [count : (-> i64)
      (lambda () : i64
        (string.string-length owned))]
    [moved : (-> i64) count]
    (moved)))