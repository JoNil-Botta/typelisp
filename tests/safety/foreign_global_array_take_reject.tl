;; #7976: only `foreign_global_dep` may write its globals; the write through
;; `array-take!` is rejected.
(import foreign_global_dep.slots)

(define (main) : i64
  (array-take! slots 0))