;; An array element nested in a sealed handle is the handle's storage (#9783).
(import sealed_handle_dep as dep)

(define (main) : i64
  (let
    [h : dep.Nested (dep.null-nested)]
    (set! (array-ref h.buf 0) 1)
    (array-ref h.buf 0)))