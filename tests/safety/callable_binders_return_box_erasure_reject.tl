(defstruct RefBox
  (:lifetimes keep)
  (value (& keep i64)))

(define (make [b : (&mut holder (RefBox keep))]) : (Box (-> (& keep i64) unit))
  (box
    (lambda ([q : (& keep i64)]) : unit
      (set! b.value q))))

(define (main) : i64
  0)