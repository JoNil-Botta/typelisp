;: `__tl_array-take!` also clears a bit in its liveness bitmap, so a
;; dynamic-array field of a foreign sealed handle cannot be that bitmap
;; (#9783, #10004).
(import sealed_handle_dep as dep)

(define (main) : i64
  (let
    [h : dep.Vecs (dep.null-vecs)]
    [items : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    (__tl_array-take! items h.live 0)
    (array-ref h.items 0)))