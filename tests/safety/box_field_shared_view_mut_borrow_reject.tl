;; Lending a Box view's contents mutably writes through the shared reference
;; the view was read through (#8927).
(defstruct Holder
  (b (Box i64)))

(define (write [x : (&mut x i64)]) : unit
  (set! (deref x) 42))

(define (mutate [r : (& r Holder)]) : unit
  (let
    [b r.b]
    (write (&mut (deref b)))))

(define (main) : i64
  (let
    [h : Holder (Holder (box 40))]
    (mutate (& h))
    (deref h.b)))