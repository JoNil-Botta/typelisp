;; Storing a closure with an owning environment in a function-typed field is
;; the same erasing coercion as passing it.
(import stdlib.string)

(defstruct Holder
  (call (-> i64)))

(define (main) : i64
  (let
    [owned : String "captured"]
    [holder : Holder
      (Holder
        (lambda () : i64
          (string.string-length owned)))]
    0))