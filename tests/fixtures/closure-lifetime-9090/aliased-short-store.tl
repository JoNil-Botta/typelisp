(defstruct RefBox (:lifetimes keep) (value (& keep i64)))
(define (store [p : (& keep i64)] [b : (&mut holder (RefBox keep))]) : unit
  (let [put (lambda ([q : (& keep i64)]) : unit (set! b.value q))] (let [alias put] (let [short : i64 5] (alias (& short))))))
(define (main) : i64 0)
