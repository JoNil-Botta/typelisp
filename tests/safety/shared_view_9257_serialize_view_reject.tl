;; #9257: `stdlib.serialize/serialize-shared-view` is removed even inside `unsafe`.
(import stdlib.serialize)

(define (main) : i64
  (let
    [value : String "ok"]
    [_alias : String
      (unsafe
        (serialize.serialize-shared-view value))]
    0))