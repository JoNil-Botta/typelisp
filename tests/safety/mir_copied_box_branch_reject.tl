;; A shared field cannot supply an owned Box or exclusive access (#8927).
(defstruct Holder
  (b (Box i64)))

(define (mutate [r : (& r Holder)] [pick : bool]) : unit
  (let
    [b : (Box i64)
      (if pick
        r.b
        r.b)]
    (set! (deref b) 42)))

(define (main) : i64
  0)