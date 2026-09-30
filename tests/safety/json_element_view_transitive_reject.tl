;; `stdlib.json/json-array-element-shared-view` reached through another macro
;; from safe code rejects at its raw read: the macro adds no `unsafe` of
;; its own (#7701).
(import stdlib.json)

(defmacro (user-view [items : Expr] [index : Expr]) : Expr
  `(json.json-array-element-shared-view ,items ,index))

(define (main) : i64
  (let
    [items : (__tl_dyn-array json.Json) (__tl_make-array json.Json 1)]
    [_view : json.Json (user-view items 0)]
    0))