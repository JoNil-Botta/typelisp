;; Replacing an array element nested in a sealed handle mutates the handle
;; (#9783).
(import sealed_handle_dep as dep)

(define (main) : i64
  (let
    [h : dep.Nested (dep.null-nested)]
    (replace! (array-ref h.buf 0) 1)))