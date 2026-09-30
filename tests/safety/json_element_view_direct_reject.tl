;; `stdlib.json/json-array-element-shared-view` called directly
;; from safe code rejects at its raw read: the macro adds no `unsafe` of
;; its own (#7701).
(import stdlib.json)

(define (main) : i64
  (let
    [items : (__tl_dyn-array json.Json) (__tl_make-array json.Json 1)]
    [_view : json.Json (json.json-array-element-shared-view items 0)]
    0))