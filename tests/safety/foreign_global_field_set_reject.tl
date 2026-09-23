;; #7976: only `foreign_global_dep` may write its globals; the write through a
;; field projection is rejected.
(import foreign_global_dep.pair)

(define (main) : i64
  (begin
    (set! pair.left 40)
    pair.left))