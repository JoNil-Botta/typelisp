;; `stdlib.json/json-box-shared-view` called directly
;; from safe code rejects at its raw read: the macro adds no `unsafe` of
;; its own (#7701).
(import stdlib.json)

(define (main) : i64
  (let
    [items : (Box json.JsonSeq) (box (json.list-empty))]
    [_view : json.JsonSeq (json.json-box-shared-view items)]
    0))