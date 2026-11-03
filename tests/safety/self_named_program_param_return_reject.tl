;; #8998: a parameter whose own type carries its name (`[a : (& a T)]`,
;; `[s : (RefBox s)]`) is a self-named carrier: `a` is the caller's region, which
;; outlives the parameter and is unrelated to the other caller regions.
;; A parameter named `program` names its own lifetime (SPEC 3.10).
; Must fail: `program` here is the parameter's, unrelated to `q`.
(define (bad [program : (& program i64)] [q : (& q i64)]) : (& q i64)
  program)

(define (main) : i64
  0)