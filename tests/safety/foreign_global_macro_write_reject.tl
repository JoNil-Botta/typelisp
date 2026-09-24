;; #7976: only `foreign_global_dep` may write its globals; the write through a
;; write in the owner's macro template expanded here is rejected.
(import foreign_global_dep as dep)

(define (main) : i64
  (begin
    (dep.foreign-global-bump!)
    dep.counter))