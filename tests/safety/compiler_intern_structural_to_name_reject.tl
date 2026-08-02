;; A structural compiler identity is not a renderable intern name. The typed
;; render boundary must reject the raw structural i64 at compile time.
(import compiler_intern)

(define (main) : i64
  (let
    [structural : i64 999999999999999]
    [typed : compiler_intern.InternId structural]
    (begin
      (compiler_intern.intern-id-str typed)
      0)))