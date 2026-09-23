;; #7976: only `foreign_global_dep` may write its globals; the write through
;; caller syntax passed through the owner's macro is rejected.
(import foreign_global_dep as dep)

(define (main) : i64
  (begin
    (dep.foreign-global-assign! dep.pair.left 40)
    dep.pair.left))