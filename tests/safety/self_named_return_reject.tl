;; #8998: a parameter whose own type carries its name (`[a : (& a T)]`,
;; `[s : (RefBox s)]`) is a self-named carrier: `a` is the caller's region, which
;; outlives the parameter and is unrelated to the other caller regions.
; Must fail: `a` is unrelated to `q`.
(define (bad [a : (& a i64)] [q : (& q i64)]) : (& q i64)
  a)

(define (main) : i64
  0)