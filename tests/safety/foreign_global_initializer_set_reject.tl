;; #7976: only `foreign_global_dep` may write its globals; the write through an
;; assignment in the importer's global initializer is rejected.
(import foreign_global_dep.counter)

(define copied : i64
  (begin
    (set! counter 40)
    counter))

(define (main) : i64
  copied)