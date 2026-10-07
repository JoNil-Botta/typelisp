;; Through `(&mut m (RefBox a))`, only references that live for the field's
;; lifetime `a` may be stored; one that lives only for the `&mut` reference's
;; lifetime `m` is rejected (#8584).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

; Must fail: `v` lives for `m`, not for the field's lifetime `a`.
(define (store [b : (&mut m (RefBox a))] [v : (& m i64)]) : unit
  (set! (deref b).value v))

(define (main) : i64
  0)