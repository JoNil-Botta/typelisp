;: Writing an element of a fixed array field of a foreign sealed handle inside
;; a foreach body mutates the handle (#9783, #10004).
(import sealed_handle_dep as dep)

(define (main) : i64
  (let
    [h : dep.Nested (dep.null-nested)]
    (foreach ([i : i64 0 4]) (set! (array-ref h.buf i) i))
    (array-ref h.buf 0)))