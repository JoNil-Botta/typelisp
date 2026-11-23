;; #9053: `(clone (deref r))` through a reference to a cleanup-owning struct
;; would duplicate its cleanup obligation and must fail E0206.
(define closes : i64
  0)

(define (close-fd [_fd : i64]) : unit
  (set! closes (+ closes 1)))

(defstruct Res
  (:cleanup close-res)
  (fd i64 (:cleanup close-fd)))

(define (dup [r : (& r Res)]) : Res
  (clone (deref r)))

(define (run) : i64
  (with ([a (Res 7) close-res]) (with ([b (dup (& a)) close-res]) b.fd)))

(define (main) : i64
  (run)
  closes)