;; #8998: as `self_named_nominal_slot_return_reject`, through a call that
;; returns its argument.
(defstruct Hold
  (:lifetimes p)
  (value (& p i64)))

(define (pass [h : (& t (Hold p))]) : (& t (Hold p))
  h)

; Must fail: the result is the borrow of the parameter `p`.
(define (slot-call [p : (Hold p)]) : (& p (Hold p))
  (pass (& p)))

(define (main) : i64
  0)