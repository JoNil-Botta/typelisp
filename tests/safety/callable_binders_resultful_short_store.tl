(defstruct RefBox
  (:lifetimes keep)
  (value (& keep i64)))

(define (store [p : (& keep i64)] [b : (&mut holder (RefBox keep))]) : unit
  (let
    [put
      (lambda ([q : (& keep i64)]) : (& keep i64)
        (begin
          (set! b.value q)
          q))]
    (let
      [short : i64 5]
      (begin
        (put (& short))
        unit))))

(define (main) : i64
  0)