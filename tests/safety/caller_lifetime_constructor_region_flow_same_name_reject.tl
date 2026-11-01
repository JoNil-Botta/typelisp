;; A constructor result whose lifetime is a local spelled like a caller lifetime
;; keeps that local's lifetime: its reference cannot be stored into caller
;; storage.
(defstruct RefBox
  (:lifetimes t)
  (value (& t i64)))

(defstruct Two
  (:lifetimes s u)
  (boxed (& s (RefBox u)))
  (plain (& u i64)))

; Must fail: `w.plain` borrows the local `a`.
(define (two [xs : (& a (Array i64 2))] [out : (&mut a (RefBox a))]) : unit
  (let
    [a : i64 0]
    [rb (RefBox (& (array-ref xs 0)))]
    [w (Two (& rb) (& a))]
    (set! out.value w.plain)))

(define (main) : i64
  0)