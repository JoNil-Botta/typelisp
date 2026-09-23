;; #7976: only `foreign_global_dep` may write its globals; the write through a
;; tuple element is rejected.
(import foreign_global_dep.tup)

(define (main) : i64
  (begin
    (set! (tuple-ref tup 0) 40)
    (tuple-ref tup 0)))