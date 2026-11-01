;; One `&mut` element passed twice to one call would give the callee two
;; aliasing mutable references (Rust E0499; main accepted it, #8449).
(define (touch [p : (&mut i64)]) : unit
  (set! (deref p) (+ (deref p) 10)))

(define (touch2 [p : (&mut i64)] [q : (&mut i64)]) : unit
  (begin
    (touch p)
    (touch q)))

(define (run [p : (&mut p (Array (&mut p i64) 2))]) : unit
  (touch2 (array-ref p 0) (array-ref p 0)))

(define (main) : i64
  42)