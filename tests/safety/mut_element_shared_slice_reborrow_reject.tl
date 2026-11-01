;; A `&mut` element of a slice read through a shared reference cannot be
;; passed as a `&mut` (Rust E0596; main accepted it, #8449).
(define (touch [p : (&mut i64)]) : unit
  (set! (deref p) (+ (deref p) 10)))

(define (run [p : (& p (Slice (&mut p i64)))]) : unit
  (touch (array-ref p 0)))

(define (main) : i64
  42)