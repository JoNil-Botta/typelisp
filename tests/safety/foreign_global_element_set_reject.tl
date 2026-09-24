;; #7976: only `foreign_global_dep` may write its globals; the write through a
;; fixed-array element is rejected.
(import foreign_global_dep.slots)

(define (main) : i64
  (begin
    (set! (array-ref slots 0) 40)
    (array-ref slots 0)))