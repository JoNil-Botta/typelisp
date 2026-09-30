;; `stdlib.serialize/serialize-shared-view`
;; called through an import alias from safe code rejects at its raw read:
;; the macro adds no `unsafe` of its own (#7701).
(import stdlib.serialize as s)

(define (main) : i64
  (let
    [value : String "owned"]
    [_view : String (s.serialize-shared-view value)]
    0))