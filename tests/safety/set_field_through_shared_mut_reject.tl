;; A field of a `&mut` referent behind a shared reference is not writable
;; either: the store reaches the `&mut` through the shared reference.
(defstruct Pt
  (name String)
  (x i64))

(define (sneak [h : (& h (&mut a Pt))]) : unit
  (set! (deref (deref h)).x 5))

(define (main) : i64
  42)