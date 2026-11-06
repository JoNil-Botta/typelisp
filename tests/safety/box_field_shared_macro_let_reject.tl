;; A macro-expanded binder of a Box field read through a shared reference
;; keeps that origin too (#8927).
(defstruct Holder
  (b (Box i64)))

(defmacro (write-copied [place : Expr]) : Expr
  `(let
    [copied : (Box i64) ,place]
    (set! (deref copied) 42)))

(define (mutate [r : (& r Holder)]) : unit
  (write-copied r.b))

(define (main) : i64
  (let
    [h : Holder (Holder (box 40))]
    (mutate (& h))
    (deref h.b)))