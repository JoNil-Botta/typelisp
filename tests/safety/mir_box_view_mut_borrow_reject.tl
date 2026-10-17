;; A shared field cannot supply an owned Box or exclusive access (#8927).
(defstruct Holder
  (b (Box i64)))

(define (write [b : (&mut b (Box i64))]) : unit
  (set! (deref (deref b)) 42))

(define (mutate [r : (& r Holder)]) : unit
  (let
    [b r.b]
    (write (&mut b))))

(define (main) : i64
  0)