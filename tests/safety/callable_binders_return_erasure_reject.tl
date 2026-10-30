(defstruct RefBox
  (:lifetimes keep)
  (value (& keep i64)))

(define (store [p : (& keep i64)] [b : (&mut holder (RefBox keep))]) : unit
  (let
    [make
      (lambda () : (-> (& keep i64) unit)
        (lambda ([q : (& keep i64)]) : unit
          (set! b.value q)))]
    (let
      [put (make)]
      (put p))))

(define (main) : i64
  0)