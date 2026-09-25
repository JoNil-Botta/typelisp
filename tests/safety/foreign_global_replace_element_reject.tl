;; #7976: only `foreign_global_dep` may write its globals; replacing an element
;; of its array is rejected.
(import foreign_global_dep.slots)

(define (main) : i64
  (replace! (array-ref slots 0) 8))