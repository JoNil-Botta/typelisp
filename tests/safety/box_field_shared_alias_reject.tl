;; Aliases keep the origin: a copy of the shared reference, and a second
;; binding of the Box view read through it, still write through the shared
;; reference (#8927).
(defstruct Holder
  (b (Box i64)))

(define (mutate [r : (& r Holder)]) : unit
  (let
    [alias r]
    [view alias.b]
    [again view]
    (set! (deref again) 42)))

(define (main) : i64
  (let
    [h : Holder (Holder (box 40))]
    (mutate (& h))
    (deref h.b)))