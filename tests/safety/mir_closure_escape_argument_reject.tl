;; A closure whose environment owns a non-Copy capture cannot be coerced to a
;; plain function type: passing it as an argument would erase that ownership.
(import stdlib.string)

(define (invoke [f : (-> i64)]) : i64
  (f))

(define (main) : i64
  (let
    [owned : String "captured"]
    (invoke
      (lambda () : i64
        (string.string-length owned)))))