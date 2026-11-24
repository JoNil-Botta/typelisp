;; #9053: `(clone.deep e)` on a cleanup-owning enum must be rejected.
(import stdlib.clone)

(define closes : i64
  0)

(define (close-fd [_fd : i64]) : unit
  (set! closes (+ closes 1)))

(defenum Handle
  (:cleanup close-handle)
  (Open i64 (:cleanup close-fd))
  (Closed))

(define (dup [r : (& r Handle)]) : Handle
  (clone.deep (deref r)))

(define (main) : i64
  (with
    ([h (Handle.Open 7) close-handle])
    (with ([_h2 (dup (& h)) close-handle]) closes)))