;: A lambda boundary is not inside the surrounding scalar while for a `break`
;: in a macro operand either.
(define (main) : i64
  (begin
    (while true
      (let
        [f : (-> unit)
          (lambda () : unit
            (when true (break)))]
        (begin
          (f)
          (break))))
    0))