;; `stdlib.json/json-shared-view` called through an import alias
;; from safe code rejects at its raw read: the macro adds no `unsafe` of
;; its own (#7701).
(import stdlib.json)
(import stdlib.json as j)

(define (main) : i64
  (let
    [value : json.Json (json.JsonString "owned")]
    [_view : json.Json (j.json-shared-view value)]
    0))