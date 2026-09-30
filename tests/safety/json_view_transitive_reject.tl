;; `stdlib.json/json-shared-view` reached through another macro
;; from safe code rejects at its raw read: the macro adds no `unsafe` of
;; its own (#7701).
(import stdlib.json)

(defmacro (user-view [a : Expr]) : Expr
  `(json.json-shared-view ,a))

(define (main) : i64
  (let
    [value : json.Json (json.JsonString "owned")]
    [_view : json.Json (user-view value)]
    0))