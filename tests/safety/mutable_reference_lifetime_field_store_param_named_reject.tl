;; The by-value parameter `a` shadows the lifetime `a`, as in
;; mutable_reference_lifetime_field_store_param_reject, but here the `&mut` has
;; an explicit lifetime name. Signature lifetime markers are bound after the
;; parameters, and that order must not let the parameter's own borrow outlive
;; the caller's `m`: it dies when `store` returns.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

; Must fail: the parameter `a` shadows the lifetime `a`.
(define (store [a : i64] [b : (&mut m (RefBox a))]) : unit
  (set! b.value (& a)))

(define (main) : i64
  0)