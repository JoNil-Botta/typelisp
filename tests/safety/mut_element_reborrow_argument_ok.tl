;; A `&mut` element passed where a `&mut` is expected is reborrowed, Rust's
;; implicit `&mut *p[i]`, not moved out of the array or slice that holds it:
;; the element stays usable for the next call (#8449, #8695).
(define (touch [p : (&mut i64)]) : unit
  (set! (deref p) (+ (deref p) 10)))

(define (via-array [p : (&mut p (Array (&mut p i64) 1))]) : unit
  (begin
    (touch (array-ref p 0))
    (touch (array-ref p 0))))

(define (via-slice [p : (&mut p (Slice (&mut p i64)))] [i : i64]) : unit
  (begin
    (touch (array-ref p i))
    (touch (array-ref p i))))

(define (main) : i64
  42)