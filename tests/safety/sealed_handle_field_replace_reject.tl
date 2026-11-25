;; Outside its module family, a field of a sealed handle type is replaced only
;; in unsafe code (#9783).
(import sealed_handle_dep as dep)

(define (main) : i64
  (let
    [handle : dep.Handle (dep.null-handle)]
    (replace! handle.generation 0)))