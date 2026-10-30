(defstruct RefBox
  (:lifetimes keep)
  (value (& keep i64)))

(define (store [p : (& keep i64)] [b : (&mut holder (RefBox keep))]) : unit
  (let
    [put
      (lambda ([q : (& keep i64)] [r : (& keep i64)]) : unit
        (set! b.value q))]
    (let
      [short : i64 5]
      (put (& short) (& short)))))

(define (main) : i64
  0)