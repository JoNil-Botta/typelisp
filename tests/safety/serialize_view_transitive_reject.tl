;; `stdlib.serialize/serialize-shared-view`
;; reached through another macro from safe code rejects at its raw read:
;; the macro adds no `unsafe` of its own (#7701).
(import stdlib.serialize)

(defmacro (user-view [place : Expr]) : Expr
  `(serialize.serialize-shared-view ,place))

(define (main) : i64
  (let
    [value : String "owned"]
    [_view : String (user-view value)]
    0))