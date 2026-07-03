;: A lambda boundary is not inside the surrounding scalar while for break.
(define (main) : i64
  (begin
    (while true
      (let
        [f : (-> unit)
          (lambda () : unit
            (break))]
        (begin
          (f)
          (break))))
    0))