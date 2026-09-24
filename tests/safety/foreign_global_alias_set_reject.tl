;; #7976: only `foreign_global_dep` may write its globals; the write through a
;; module alias is rejected.
(import foreign_global_dep as dep)

(define (main) : i64
  (begin
    (set! dep.counter 40)
    dep.counter))