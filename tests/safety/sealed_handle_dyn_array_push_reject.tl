;: Growing a dynamic-array field of a foreign sealed handle mutates the handle
;; (#9783, #10004).
(import sealed_handle_dep as dep)

(define (main) : i64
  (let
    [h : dep.Vecs (dep.null-vecs)]
    (__tl_array-push! h.items 7)
    (array-ref h.items 0)))