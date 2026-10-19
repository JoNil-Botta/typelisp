(defstruct RefBox (:lifetimes keep) (value (& keep i64)))
(define (store [p : (& first i64)] [r : (& second i64)]
               [b : (&mut holder1 (RefBox first))]
               [d : (&mut holder2 (RefBox second))]) : unit
  (let [put (lambda ([q : (& first i64)] [s : (& second i64)]) : unit
               (begin (set! b.value q) (set! d.value s)))]
    (let [short : i64 5] (put (& short) r))))
(define (main) : i64 0)
