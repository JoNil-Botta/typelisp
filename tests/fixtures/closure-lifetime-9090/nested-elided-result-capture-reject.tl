(defstruct RefBox (:lifetimes keep) (value (& keep i64)))
(define (store [p : (& i64)] [long : (& keep i64)] [b : (&mut holder (RefBox keep))]) : unit
  (let [select (lambda ([q : (& i64)]) : (& i64) p)]
    (set! b.value (select long))))
(define (main) : i64 0)
