;; `stdlib.serialize/serialize-array-element-shared-view`
;; reached through another macro from safe code rejects at its raw read:
;; the macro adds no `unsafe` of its own (#7701).
(import stdlib.serialize)

(defmacro (user-view [items : Expr] [index : Expr]) : Expr
  `(serialize.serialize-array-element-shared-view ,items ,index))

(define (main) : i64
  (let
    [items : (__tl_dyn-array String) (__tl_make-array String 1)]
    [_view : String (user-view items 0)]
    0))