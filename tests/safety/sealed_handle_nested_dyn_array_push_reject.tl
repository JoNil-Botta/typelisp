;: A dynamic-array field of an unsealed struct nested in a foreign sealed
;; handle is the handle's storage (#9783, #10004).
(import sealed_handle_dep as dep)

(define (main) : i64
  (let
    [h : dep.VecOwner (dep.null-vec-owner)]
    (__tl_array-push! h.meta.items 7)
    (array-ref h.meta.items 0)))