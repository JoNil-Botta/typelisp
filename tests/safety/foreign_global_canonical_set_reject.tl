;; #7976: only `foreign_global_dep` may write its globals; the write through the
;; full canonical module path is rejected.
(import foreign_global_dep)

(define (main) : i64
  (begin
    (set! foreign_global_dep.counter 40)
    foreign_global_dep.counter))