;; `stdlib.json/json-array-element-shared-view` called through an import alias
;; from safe code rejects at its raw read: the macro adds no `unsafe` of
;; its own (#7701).
(import stdlib.json)
(import stdlib.json as j)

(define (main) : i64
  (let
    [items : (__tl_dyn-array json.Json) (__tl_make-array json.Json 1)]
    [_view : json.Json (j.json-array-element-shared-view items 0)]
    0))