;; Call inference should not depend on the arguments' order: a caller reference
;; stored through a `&mut` into a shorter-lived local's box infers the box's
;; lifetime whichever argument comes first, spelled like the caller's lifetime
;; or not. Rust accepts all three bodies. This tree, like main, binds `t` from
;; the first argument that names it: in `other-name-value-first` that is the
;; covariant `(& t i64)`, fixing `t` to the caller's `a` before the invariant
;; `(&mut r (RefBox t))` meets the local box `(RefBox z)`, so the call is
;; rejected (E0206) although `a` outlives `z`. The other two bodies pass only
;; because the local is spelled `a`. The manifest row records the rejection
;; until call inference solves all of a call's lifetime constraints at once
;; (#8890); it is a typing limitation, not a borrow-check verdict.
(defstruct RefBox
  (:lifetimes t)
  (value (& t i64)))

(define (put [v : (& t i64)] [m : (&mut r (RefBox t))]) : unit
  (set! m.value v))

(define (put-swapped [m : (&mut r (RefBox t))] [v : (& t i64)]) : unit
  (set! m.value v))

(define (value-first [xs : (& a (Array i64 2))]) : i64
  (let
    [a : i64 0]
    [rb (RefBox (& a))]
    (put (& (array-ref xs 0)) (&mut rb))
    (deref rb.value)))

(define (box-first [xs : (& a (Array i64 2))]) : i64
  (let
    [a : i64 0]
    [rb (RefBox (& a))]
    (put-swapped (&mut rb) (& (array-ref xs 0)))
    (deref rb.value)))

(define (other-name-value-first [xs : (& a (Array i64 2))]) : i64
  (let
    [z : i64 0]
    [rb (RefBox (& z))]
    (put (& (array-ref xs 0)) (&mut rb))
    (deref rb.value)))

(define (main) : i64
  0)