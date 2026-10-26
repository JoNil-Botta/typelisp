;; Nested locals that shadow a caller lifetime still own their storage.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [b : (&mut a (RefBox a))]) : unit
  (let
    [a : i64 1]
    (let
      [a : i64 2]
      ; Must fail: `(& a)` borrows the inner local.
      (set! b.value (& a)))))

(define (main) : i64
  0)