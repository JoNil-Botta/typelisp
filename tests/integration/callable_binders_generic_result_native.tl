(defstruct Cell
  (value i64))

(defenum Sink
  (:lifetimes store lease)
  (Capture (& store Cell) (& lease Cell)))

(defenum Scrutinee
  (:lifetimes store lease)
  (Ok i64 (Sink store lease))
  (Err String (Sink store lease)))

(defenum Result
  (:lifetimes store lease)
  (Ok (Sink store lease))
  (Err String (Sink store lease)))

(define (helper [sink : (Sink store lease)]) : (Scrutinee store lease)
  (Scrutinee.Ok 7 sink))

(define (forward [sink : (Sink store lease)]) : (Result store lease)
  (Result.Ok sink))

(define (outer [sink : (Sink store lease)]) : (Result store lease)
  (match (helper sink)
    [(Scrutinee.Ok n next)
      (if (= n 7)
        (forward next)
        (return (Result.Err "other" next)))]
    [(Scrutinee.Err message next) (Result.Err message next)]))

(define (main) : i64
  (let
    [x (Cell 40)]
    [y (Cell 2)]
    (match (outer (Sink.Capture (& x) (& y)))
      [(Result.Ok (Sink.Capture first second)) (+ first.value second.value)]
      [(Result.Err _ _) 1])))