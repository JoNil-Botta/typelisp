;; A struct embedding a sealed handle type through a non-owned field is sealed
;; too (#9783).
(import sealed_handle_dep as dep)

(define (main) : i64
  (with
    ([owner (dep.Owner (dep.null-handle)) dep.close-owner])
    owner.handle.generation))