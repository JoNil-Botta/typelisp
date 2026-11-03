;; #8998: a parameter whose own type carries its name (`[a : (& a T)]`,
;; `[s : (RefBox s)]`) is a self-named carrier: `a` is the caller's region, which
;; outlives the parameter and is unrelated to the other caller regions.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

; Must fail: `s` is unrelated to `q`.
(define (get [s : (RefBox s)] [q : (& q i64)]) : (& q i64)
  s.value)

(define (main) : i64
  0)