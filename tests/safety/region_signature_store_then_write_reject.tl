;: A reference stored behind a by-value parameter lands in a signature region
;: (`a`), which the caller's memory outlives: the loan stays live to the end
;: of the body, so writing the borrowed `*d.x` afterwards conflicts (Rust
;: E0506; found by the rustc oracle, #8449).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(defstruct Outer
  (:lifetimes j a)
  (inner (&mut j (RefBox a))))

(defstruct Deep
  (:lifetimes i j a)
  (m (&mut i (Outer j a)))
  (x (&mut a i64)))

(define (f [d : (Deep i j a)]) : i64
  (begin
    (set! (deref (deref d.m).inner).value (& (deref d.x)))
    (set! (deref d.x) 9)
    0))

(define (main) : i64
  42)