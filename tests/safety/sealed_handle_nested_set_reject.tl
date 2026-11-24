;; Setting a field nested in a sealed owner mutates the owner (#9783).
(import sealed_handle_dep as dep)

(define (main) : i64
  (with
    ([owner (dep.make-owner) dep.close-owner])
    (set! owner.handle.generation 0)
    owner.handle.generation))