;; `stdlib.json/json-shared-view` called directly
;; from safe code rejects at its raw read: the macro adds no `unsafe` of
;; its own (#7701).
(import stdlib.json)

(define (main) : i64
  (let
    [value : json.Json (json.JsonString "owned")]
    [_view : json.Json (json.json-shared-view value)]
    0))