;; A `&mut` field passed where a `&mut` is expected is reborrowed, Rust's
;; implicit `&mut *h.r`, not moved out of the holder: the field stays usable
;; for the next call (#8449).
(define (touch [p : (&mut i64)]) : unit
  (set! (deref p) (+ (deref p) 10)))

(defstruct Holder
  (:lifetimes s)
  (r (&mut s i64))
  (n i64))

(define (run [h : (&mut h (Holder s))]) : unit
  (begin
    (touch h.r)
    (touch h.r)))

(define (main) : i64
  42)