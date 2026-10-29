(defstruct RefBox
  (:lifetimes keep)
  (value (& keep i64)))

(define (store [p : (& keep i64)] [b : (&mut holder (RefBox keep))]) : unit
  (let
    [put
      (lambda ([q : (& independent i64)]) : unit
        (set! b.value q))]
    (put p)))

(define (main) : i64
  0)