;; A field of an unsealed struct nested in a sealed handle is the handle's
;; storage (#9783).
(import sealed_handle_dep as dep)

(define (main) : i64
  (let
    [h : dep.Nested (dep.null-nested)]
    (set! h.meta.gen 1)
    h.meta.gen))