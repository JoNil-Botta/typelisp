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

;; Two lifetime parameters of different variance: each formal is gated by its
;; own parameter's variance, whatever order the call collects them in.
(defenum InvCov
  (:lifetimes a b)
  (None)
  (Some (&mut program (& a i64)) (& b i64)))

(defenum CovInv
  (:lifetimes a b)
  (None)
  (Some (& a str) (&mut program (& b i64))))

(defstruct HoldInvCov
  (:lifetimes a b)
  (t (InvCov a b)))

; Must pass: invariant first, covariant second.
(define (inv-cov [a : i64] [b : i64]) : i64
  (let
    [v : (InvCov a b) (InvCov.None)]
    0))

; Must pass: covariant first, invariant second.
(define (cov-inv [a : i64] [b : i64]) : i64
  (let
    [v : (CovInv a b) (CovInv.None)]
    0))

; Must pass: the covariant formal still takes the unconstrained lifetime.
(define (cov-inv-carrier [a : (& next str)] [b : i64]) : i64
  (let
    [t : (CovInv next b) (CovInv.None)]
    0))

; Must pass: the nullary variant nested in a constructor.
(define (hold-inv-cov [a : i64] [b : i64]) : i64
  (let
    [h : (HoldInvCov a b) (HoldInvCov (InvCov.None))]
    0))

;; `a` is bivariant here: nothing in a payload spells it.
(defenum BiInv
  (:lifetimes a b)
  (None)
  (Some (&mut program (& b i64))))

; Must pass: the covariant `b` takes the unconstrained lifetime and so
; shortens to the caller region `a` beside the invariant one.
(define (inv-cov-shortening [r : (& a i64)] [b : i64] [program : i64]) : i64
  (let
    [v : (InvCov a a) (InvCov.None)]
    0))

; Must pass: a bivariant formal beside an invariant one.
(define (bi-inv [a : i64] [b : i64] [program : i64]) : i64
  (let
    [v : (BiInv a b) (BiInv.None)]
    0))

; Must pass: two local collisions.
(define (inv-cov-locals [program : i64]) : i64
  (let
    [a : i64 0]
    [b : i64 0]
    [v : (InvCov a b) (InvCov.None)]
    0))

; Must pass: the reserved `program` in the covariant position, which the
; colliding `a` reaches as the unconstrained lifetime.
(define (cov-inv-program [a : i64] [b : i64]) : i64
  (let
    [v : (CovInv program b) (CovInv.None)]
    0))

(define (main) : i64
  (+
    (inv-cov-shortening (& 1) 2 3)
    (bi-inv 1 2 3)
    (inv-cov-locals 3)
    (cov-inv-program 1 2)
    (inv-cov 1 2)
    (cov-inv 1 2)
    (cov-inv-carrier "x" 2)
    (hold-inv-cov 1 2)
    (param-inv 1 2)
    (param-contra 1 2)
    (param-inv-plain 1)
    (local-inv 2)
    (local-contra 2)
    (local-contra-plain)))