;; #7976: only `foreign_global_dep` may write its globals; the write through a
;; selected item import renamed with `as` is rejected.
(import foreign_global_dep.counter as c)

(define (main) : i64
  (begin
    (set! c 40)
    c))