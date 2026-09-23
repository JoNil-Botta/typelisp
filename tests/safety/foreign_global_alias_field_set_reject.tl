;; #7976: only `foreign_global_dep` may write its globals; the write through an
;; alias-qualified field projection is rejected.
(import foreign_global_dep as dep)

(define (main) : i64
  (begin
    (set! dep.pair.left 40)
    dep.pair.left))