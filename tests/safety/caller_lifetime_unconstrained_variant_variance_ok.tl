;; #8998: a nullary variant whose formal collides with a binding takes the
;; unconstrained lifetime only where its enum is covariant or bivariant in that
;; formal. An invariant or contravariant formal keeps its declared spelling, as
;; on main, so an annotated local still meets its expectation.
(defenum Inv
  (:lifetimes p)
  (None)
  (Some (&mut program (& p i64))))

(defenum Contra
  (:lifetimes p)
  (None)
  (Some (-> (& p i64) i64)))

; Must pass: a parameter `p` collides, with and without a `program` binding.
(define (param-inv [p : i64] [program : i64]) : i64
  (let
    [v : (Inv p) (Inv.None)]
    0))

(define (param-contra [p : i64] [program : i64]) : i64
  (let
    [v : (Contra p) (Contra.None)]
    0))

(define (param-inv-plain [p : i64]) : i64
  (let
    [v : (Inv p) (Inv.None)]
    0))

; Must pass: a local `p` collides.
(define (local-inv [program : i64]) : i64
  (let
    [p : i64 0]
    [v : (Inv p) (Inv.None)]
    0))

(define (local-contra [program : i64]) : i64
  (let
    [p : i64 0]
    [v : (Contra p) (Contra.None)]
    0))

(define (local-contra-plain) : i64
  (let
    [p : i64 0]
    [v : (Contra p) (Contra.None)]
    0))

(define (main) : i64
  (+
    (param-inv 1 2)
    (param-contra 1 2)
    (param-inv-plain 1)
    (local-inv 2)
    (local-contra 2)
    (local-contra-plain)))