;; #7976: only `foreign_global_dep` may write its globals; the write through
;; `replace!` is rejected.
(import foreign_global_dep.counter)

(define (main) : i64
  (replace! counter 40))