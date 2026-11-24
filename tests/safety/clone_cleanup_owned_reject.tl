;; #9053: `(clone.deep a)` on a cleanup-owning struct would duplicate its
;; cleanup obligation (double-close / double-free) and must be rejected.
(import stdlib.clone)

(define closes : i64
  0)

(define (close-fd [_fd : i64]) : unit
  (set! closes (+ closes 1)))

(defstruct Res
  (:cleanup close-res)
  (fd i64 (:cleanup close-fd)))

(define (run) : i64
  (with ([a (Res 7) close-res]) (with ([b (clone.deep a) close-res]) b.fd)))

(define (main) : i64
  (run)
  closes)