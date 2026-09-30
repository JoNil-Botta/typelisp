;; `stdlib.serialize/serialize-shared-view`
;; called directly from safe code rejects at its raw read:
;; the macro adds no `unsafe` of its own (#7701).
(import stdlib.serialize)

(define (main) : i64
  (let
    [value : String "owned"]
    [_view : String (serialize.serialize-shared-view value)]
    0))