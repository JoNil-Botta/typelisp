;; #9053: a tuple containing a cleanup-owning struct is transitively
;; non-cloneable and must fail E0206.
(define closes : i64
  0)

(define (close-fd [_fd : i64]) : unit
  (set! closes (+ closes 1)))

(defstruct Res
  (:cleanup close-res)
  (fd i64 (:cleanup close-fd)))

(define (dup [r : (& r (Tuple Res i64))]) : (Tuple Res i64)
  (clone (deref r)))

(define (main) : i64
  0)