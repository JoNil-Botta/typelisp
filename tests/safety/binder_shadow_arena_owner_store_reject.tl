;; A value binder spelled like a local arena owner does not let inner arena
;; data reach that arena (#9609, D-C216).
(import stdlib.arena)

(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (leak) : i64
  (let
    [o (arena.make)]
    [held : (Box i64) (in-arena o (box 7))]
    [t : (RefBox o) (RefBox (& (deref held)))]
    (with-arena
      inner
      (let
        [x : (Box i64) (box 5)]
        [local : (& inner i64) (& inner (deref x))]
        [o : i64 1]
        (set! t.value local)))
    (deref t.value)))

(define (main) : i64
  0)