;: Growing a dynamic-array field of a foreign sealed handle inside a foreach
;; body mutates the handle (#9783, #10004).
(import sealed_handle_dep as dep)

(define (main) : i64
  (let
    [h : dep.Vecs (dep.null-vecs)]
    (foreach ([i : i64 0 4]) (__tl_array-push! h.items i))
    (array-ref h.items 0)))