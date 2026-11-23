;; #9053: `(clone a)` on a cleanup-owning struct would duplicate its cleanup
;; obligation (double-close / double-free) and must fail E0206.
(define closes : i64
  0)

(define (close-fd [_fd : i64]) : unit
  (set! closes (+ closes 1)))

(defstruct Res
  (:cleanup close-res)
  (fd i64 (:cleanup close-fd)))

(define (run) : i64
  (with ([a (Res 7) close-res]) (with ([b (clone a) close-res]) b.fd)))

(define (main) : i64
  (run)
  closes)