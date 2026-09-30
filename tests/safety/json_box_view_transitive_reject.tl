;; `stdlib.json/json-box-shared-view` reached through another macro
;; from safe code rejects at its raw read: the macro adds no `unsafe` of
;; its own (#7701).
(import stdlib.json)

(defmacro (user-view [a : Expr]) : Expr
  `(json.json-box-shared-view ,a))

(define (main) : i64
  (let
    [items : (Box json.JsonSeq) (box (json.list-empty))]
    [_view : json.JsonSeq (user-view items)]
    0))