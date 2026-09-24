;; #7976: only `foreign_global_dep` may write its globals; the write through a
;; `&mut` borrow of a field is rejected.
(import foreign_global_dep.pair)

(define (overwrite [value : (&mut i64)]) : unit
  (set! (deref value) 40))

(define (main) : i64
  (begin
    (overwrite (&mut pair.left))
    pair.left))