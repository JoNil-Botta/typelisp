;; #9053: `(clone e)` on a cleanup-owning enum must fail E0206.
(define closes : i64
  0)

(define (close-fd [_fd : i64]) : unit
  (set! closes (+ closes 1)))

(defenum Handle
  (:cleanup close-handle)
  (Open i64 (:cleanup close-fd))
  (Closed))

(define (dup [r : (& r Handle)]) : Handle
  (clone (deref r)))

(define (main) : i64
  (with
    ([h (Handle.Open 7) close-handle])
    (with ([_h2 (dup (& h)) close-handle]) closes)))