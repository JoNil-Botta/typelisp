;; #7976: only `foreign_global_dep` may write its globals; the write through a
;; `&mut` borrow of an array element is rejected.
(import foreign_global_dep.slots)

(define (overwrite [value : (&mut i64)]) : unit
  (set! (deref value) 40))

(define (main) : i64
  (begin
    (overwrite (&mut (array-ref slots 1)))
    (array-ref slots 1)))