(defstruct RefBox (:lifetimes keep) (value (& keep i64)))
(define (store [p : (& keep i64)] [b : (&mut holder (RefBox keep))]) : unit
  (let [put (lambda ([q : (& keep i64)]) : unit (set! b.value q))] (put p)))
(define (main) : i64
  (let [value : i64 42] [cell (RefBox (& value))]
    (store (& value) (&mut cell))
    (deref cell.value)))
