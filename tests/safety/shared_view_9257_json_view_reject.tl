;; #9257: `stdlib.json/json-shared-view` is removed even inside `unsafe`.
(import stdlib.json)

(define (main) : i64
  (let
    [value : json.Json json.JsonNull]
    [_alias : json.Json
      (unsafe
        (json.json-shared-view value))]
    0))