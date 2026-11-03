;; #8998: a parameter whose own type carries its name (`[a : (& a T)]`,
;; `[s : (RefBox s)]`) is a self-named carrier: `a` is the caller's region, which
;; outlives the parameter and is unrelated to the other caller regions.
;; Its own stack slot is still the parameter's storage.
; Must fail: `(& p)` reborrows the referent, a `(& p i64)`, not the declared
; `(& p (& p i64))`; `self_named_nominal_slot_return_reject` borrows a slot.
(define (slot [p : (& p i64)]) : (& p (& p i64))
  (& p))

(define (main) : i64
  0)