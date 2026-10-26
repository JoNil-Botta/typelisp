;; A C function pointer value lends its argument, but only a value the caller
;; still owns: one already moved into an aggregate cannot be passed.
(defstruct Named
  (name String)
  (id i64))

(define (lend-moved [callback : (CFunc non-null (-> String i64))] [s : String]) : i64
  (let
    [n : Named (Named s 1)]
    (+ n.id (callback s))))

(define (main) : i64
  0)