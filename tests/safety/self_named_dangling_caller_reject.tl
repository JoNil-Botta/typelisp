;; #8998: a parameter whose own type carries its name (`[a : (& a T)]`,
;; `[s : (RefBox s)]`) is a self-named carrier: `a` is the caller's region, which
;; outlives the parameter and is unrelated to the other caller regions.
;; Its caller would keep `local` past its scope.
; Must fail: at `bad`'s return.
(define (bad [a : (& a i64)] [q : (& q i64)]) : (& q i64)
  a)

(define (outer [long : (& q i64)]) : (& q i64)
  (let
    [local : i64 1]
    (bad (& local) long)))

(define (main) : i64
  0)