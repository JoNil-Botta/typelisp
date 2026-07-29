;; A structural compiler identity is not a renderable intern name. The typed
;; render boundary must reject the raw structural i64 at compile time.
(import "../../src/compiler_intern.tl")

(define (main) : i64
  (let
    [structural : i64 999999999999999]
    [typed : InternId structural]
    (begin
      (intern-id-str typed)
      0)))