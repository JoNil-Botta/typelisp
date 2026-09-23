;; #7976: only `foreign_global_dep` may write its globals; the write through an
;; assignment inside a closure is rejected.
(import foreign_global_dep.counter)

(define (main) : i64
  (let
    [write : (-> unit)
      (lambda () : unit
        (set! counter 40))]
    (begin
      (write)
      counter)))