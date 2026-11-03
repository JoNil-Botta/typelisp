;; #8998: a parameter whose own type carries its name (`[a : (& a T)]`,
;; `[s : (RefBox s)]`) is a self-named carrier: `a` is the caller's region, which
;; outlives the parameter and is unrelated to the other caller regions.
;; Its own stack slot is still the parameter's storage.
; Must fail: `(& p)` borrows the parameter slot, which dies at the return.
(define (slot [p : (& p i64)]) : (& p (& p i64))
  (& p))

(define (main) : i64
  0)