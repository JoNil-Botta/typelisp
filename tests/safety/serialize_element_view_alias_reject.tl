;; `stdlib.serialize/serialize-array-element-shared-view`
;; called through an import alias from safe code rejects at its raw read:
;; the macro adds no `unsafe` of its own (#7701).
(import stdlib.serialize as s)

(define (main) : i64
  (let
    [items : (__tl_dyn-array String) (__tl_make-array String 1)]
    [_view : String (s.serialize-array-element-shared-view items 0)]
    0))