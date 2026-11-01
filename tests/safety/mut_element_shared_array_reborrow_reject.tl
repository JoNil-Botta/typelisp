;; A `&mut` element of an array read through a shared reference cannot be
;; passed as a `&mut`: every holder of the shared reference could write
;; through it (Rust E0596; main accepted it, #8449).
(define (touch [p : (&mut i64)]) : unit
  (set! (deref p) (+ (deref p) 10)))

(define (run [p : (& p (Array (&mut p i64) 1))]) : unit
  (touch (array-ref p 0)))

(define (main) : i64
  42)