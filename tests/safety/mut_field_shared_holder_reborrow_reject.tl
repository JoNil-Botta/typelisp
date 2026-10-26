;; A `&mut` field of a holder read through a shared reference cannot be passed
;; as a `&mut` (Rust E0596; main accepted it, #8449).
(define (touch [p : (&mut i64)]) : unit
  (set! (deref p) (+ (deref p) 10)))

(defstruct Holder
  (:lifetimes s)
  (r (&mut s i64))
  (n i64))

(define (run [h : (& h (Holder s))]) : unit
  (touch h.r))

(define (main) : i64
  42)