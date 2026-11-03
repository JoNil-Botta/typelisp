;; #8998: a parameter whose own type carries its name (`[a : (& a T)]`,
;; `[s : (RefBox s)]`) is a self-named carrier: `a` is the caller's region, which
;; outlives the parameter and is unrelated to the other caller regions.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

; Must fail: the alias keeps the caller region `p`.
(define (store-carrier-alias [p : (& p i64)] [b : (&mut m (RefBox m))]) : unit
  (let
    [r p]
    (set! b.value r)))

(define (main) : i64
  0)