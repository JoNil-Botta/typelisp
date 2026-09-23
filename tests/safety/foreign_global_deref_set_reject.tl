;; #7976: only `foreign_global_dep` may write its globals; the write through a
;; `deref` projection through a Box is rejected.
(import foreign_global_dep.boxed)

(define (main) : i64
  (begin
    (set! (deref boxed) 40)
    (deref boxed)))