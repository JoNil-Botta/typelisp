;; #7976: only `foreign_global_dep` may write its globals; the write through a
;; `&mut` borrow passed to a helper is rejected.
(import foreign_global_dep.counter)

(define (overwrite [value : (&mut i64)]) : unit
  (set! (deref value) 40))

(define (main) : i64
  (begin
    (overwrite (&mut counter))
    counter))