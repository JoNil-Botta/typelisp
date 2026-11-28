(defstruct Address
  (value (Ptr i64)))

(define (replace [p : (Ptr i64)]) : unit
  (let
    [outer : Address (Address p)]
    (with-scratch (set! outer (Address p)))))

(define (main) : i64
  0)