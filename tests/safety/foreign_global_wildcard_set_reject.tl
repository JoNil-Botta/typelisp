;; #7976: only `foreign_global_dep` may write its globals; the write through a
;; `.*` import is rejected.
(import foreign_global_dep.*)

(define (main) : i64
  (begin
    (set! counter 40)
    counter))