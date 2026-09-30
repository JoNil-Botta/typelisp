;; `stdlib.json/json-box-shared-view` called through an import alias
;; from safe code rejects at its raw read: the macro adds no `unsafe` of
;; its own (#7701).
(import stdlib.json)
(import stdlib.json as j)

(define (main) : i64
  (let
    [items : (Box json.JsonSeq) (box (json.list-empty))]
    [_view : json.JsonSeq (j.json-box-shared-view items)]
    0))