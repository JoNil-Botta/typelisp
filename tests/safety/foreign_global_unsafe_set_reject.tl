;; #7976: only `foreign_global_dep` may write its globals; the write through an
;; assignment inside `unsafe` is rejected.
(import foreign_global_dep.counter)

(define (main) : i64
  (begin
    (unsafe
      (set! counter 40))
    counter))