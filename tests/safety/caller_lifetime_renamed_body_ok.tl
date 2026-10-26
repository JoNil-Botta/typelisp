;; Bodies checked under a caller identity: a typed `for` item, a lambda
;; passing the caller's reference through, and an SPMD helper inlined into
;; such a body all type as on main, and a renamed body lowers and runs.
(define (sum [arr : (& a (Array i64 4))]) : i64
  (let
    [total : i64 0]
    (for [x : (& a i64) arr]
      (set! total (+ total (deref x))))
    (let
      [a : i64 total]
      a)))

(define (pass [p : (& a i64)]) : (& a i64)
  (let
    [g
      (lambda ([a : i64] [q : (& a i64)]) : (& a i64)
        q)]
    (g 1 p)))

(define (plus [p : (& a i64)] [x : i64]) : i64
  (begin
    (ann p : (& a i64))
    x))

(define (fill [p : (& a i64)] [out : (&mut out (__tl_dyn-array i64))] [n : i64]) : unit
  (let
    [a : i64 0]
    (foreach ([i : i64 0 n]) (set! (array-ref out i) (plus p i)))))

(define (pick [a : i64] [p : (& a i64)] [c : bool]) : i64
  (let
    [r p]
    [q
      (if c
        r
        p)]
    (+ a (deref q))))

(define (main) : i64
  (let
    [x : i64 5]
    (+ (pick 1 (& x) true) (- (deref (pass (& x))) 5))))