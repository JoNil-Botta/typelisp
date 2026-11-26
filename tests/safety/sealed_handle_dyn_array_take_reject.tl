;: Removing an element from a dynamic-array field of a foreign sealed handle
;; mutates the handle (#9783, #10004).
(import sealed_handle_dep as dep)

(define (main) : i64
  (let
    [h : dep.Vecs (dep.null-vecs)]
    [live : (__tl_dyn-array bool) (__tl_make-array bool 1)]
    (__tl_array-take! h.items live 0)
    (array-ref h.items 0)))