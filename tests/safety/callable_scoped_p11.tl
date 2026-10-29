(defstruct RefBox (:lifetimes keep) (value (& keep i64)))
(define (main) : i64
  (let [inner : i64 1]
       [cell : (RefBox inner) (RefBox (& inner))]
       [b : (&mut cell (RefBox inner)) (&mut cell)]
       [put : (-> (& inner i64) unit) (lambda ([q : (& inner i64)]) : unit (set! b.value q))]
    (let [later : i64 2] (put (& later)))
    0))
