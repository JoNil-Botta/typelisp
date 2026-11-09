;; A `&` payload bound from a match on a field read through `&mut` is itself
;; the reference a move goes through: it names the shared reference (#9646).
(defstruct Holder
  (b (Box i64)))

(defenum Payload
  (Some (& program Holder) (Box i64))
  (None))

(defstruct Outer
  (o Payload))

(define (sink [b : (Box i64)]) : i64
  (deref b))

(define (take [r : (&mut r Outer)]) : i64
  (match r.o
    [(Payload.Some s _k) (sink s.b)]
    [(Payload.None) 0]))

(define (main) : i64
  0)