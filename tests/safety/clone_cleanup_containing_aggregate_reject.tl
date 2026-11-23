;; #9053: a struct containing a cleanup-owning field is transitively
;; non-cloneable and must fail E0206 naming the cleanup-owning type.
(define closes : i64
  0)

(define (close-fd [_fd : i64]) : unit
  (set! closes (+ closes 1)))

(defstruct Res
  (:cleanup close-res)
  (fd i64 (:cleanup close-fd)))

(defstruct Wrapper
  (:cleanup close-wrapper)
  (res Res (:owned))
  (tag i64))

(define (dup [r : (& r Wrapper)]) : Wrapper
  (clone (deref r)))

(define (main) : i64
  (with
    ([w (Wrapper (Res 7) 1) close-wrapper])
    (with ([_w2 (dup (& w)) close-wrapper]) closes)))